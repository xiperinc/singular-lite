#!/usr/bin/env bash
set -euo pipefail
# `singular_lease_write` is the compatibility lease writer. Its own comment says
# it "may carry them forward but never invent or rewrite them", but it rebuilds
# the record from a FIXED allowlist, so every key outside that list is silently
# dropped on each write. Across the 25 field leases of BRAIN-RESCUE-20260910 the
# dropped set is operatorReentries, campaignBinding, nextAction and failureReason.
#
# Two consequences are pinned here:
#   1. `operatorReentries` is one of the four history markers that stop finish()
#      from deleting a planned lease (task_lifecycle.py, the _deleteRecord
#      guard added in 0.22.0 after the 2026-09-14 field run). Dropping it
#      defeats that shipped fix: a lease whose only history is an operator
#      re-entry is deleted outright on the next driver refusal.
#   2. failureReason/nextAction are the machine-readable park reason and exit
#      hint that liveness property L1 requires, and operatorReentries is the
#      only durable evidence that a supervisor intervened. Erasing them on the
#      next dispatch makes "no supervisor action" unprovable from the lease.
#
# Future lifecycle/review state (review operations, consumed infrastructure
# allowances, provider-window state) must survive for the same reason, so this
# test also pins preservation of keys this writer does not know about.
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-lease-field-preservation.sh requires bash >= 4" >&2; exit 1
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT/engine"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"; mkdir -p "$repo"; git -C "$repo" init -q
git -C "$repo" commit -q --allow-empty -m base
export SINGULAR_ROOT="$repo" SINGULAR_STATE_DIR="$repo/.singular-state"
source "$ROOT/engine/lib.sh" >/dev/null
source "$ROOT/engine/lifecycle.sh" >/dev/null
singular_ensure_state_dirs
base="$(git -C "$repo" rev-parse HEAD)"

# ---------------------------------------------------------------------------
# 1. A compatibility write preserves every key it does not itself compute.
# ---------------------------------------------------------------------------
lease="$(singular_lease_path TASK-2001)"
mkdir -p "$(dirname "$lease")"
cat >"$lease" <<'JSON'
{"taskId":"TASK-2001","status":"blocked","branch":"agent/brain/TASK-2001","area":"brain",
 "owner":"l2-developer","fileScope":"app.txt","ownedFiles":["app.txt"],"forbiddenFiles":[],
 "baseSha":"oldbase","batchId":"BATCH-OLD","runId":"RUN-OLD","worktree":"/tmp/old",
 "retryCount":1,"maxRetries":1,"productPassStarted":true,
 "campaignBinding":"campaign:rescue:sha256:abc:epoch:deadbeef",
 "failureReason":"worker-no-packet",
 "nextAction":"authorize an exact one-shot continuation or supersede",
 "operatorReentries":[{"at":"2026-09-14T15:40:00Z","previousStatus":"blocked","archivedRunId":"RUN-OLD","previousRetryCount":1}],
 "attemptHistory":[{"runId":"RUN-OLD","state":"terminal"}],
 "terminalDispositionHistory":[{"kind":"blocked","runId":"RUN-OLD"}],
 "reviewOperations":[{"reviewOperationId":"REV-1","status":"completed","round":1}],
 "infrastructureAllowances":{"workerInfra":{"used":1,"limit":1}},
 "providerWindow":{"providerKey":"claude:default","retryAt":"2026-09-16T10:00:00Z"}}
JSON

singular_lease_write TASK-2001 agent/brain/TASK-2001 brain l2-developer "app.txt" \
  running RUN-NEW "$repo/.worktrees/TASK-2001" "$base" BATCH-NEW '["app.txt"]' '[]' \
  || fail "lease write failed"

python3 - "$lease" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
missing = [k for k in (
    "operatorReentries", "campaignBinding", "nextAction", "failureReason",
) if k not in d]
assert not missing, f"compatibility write dropped durable fields: {missing}"
assert d["campaignBinding"] == "campaign:rescue:sha256:abc:epoch:deadbeef"
assert d["failureReason"] == "worker-no-packet"
assert d["operatorReentries"][0]["archivedRunId"] == "RUN-OLD"
# Fields this writer does not know about (future review/allowance/window state)
future = [k for k in ("reviewOperations", "infrastructureAllowances", "providerWindow") if k not in d]
assert not future, f"compatibility write dropped unknown lifecycle state: {future}"
assert d["reviewOperations"][0]["reviewOperationId"] == "REV-1"
assert d["infrastructureAllowances"]["workerInfra"]["used"] == 1
assert d["providerWindow"]["providerKey"] == "claude:default"
# Existing allowlist behaviour is unchanged.
assert d["attemptHistory"][0]["runId"] == "RUN-OLD"
assert d["terminalDispositionHistory"][0]["kind"] == "blocked"
# The writer still owns its computed fields.
assert d["status"] == "running", d["status"]
assert d["runId"] == "RUN-NEW", d["runId"]
assert d["baseSha"] == "" or len(d["baseSha"]) == 40, d["baseSha"]
assert d["batchId"] == "BATCH-NEW", d["batchId"]
assert d["retryCount"] == 1, "retry budget must carry forward, not reset"
assert d["productPassStarted"] is True, "product-pass marker must carry forward"
PY
pass "a compatibility lease write preserves durable and unknown state"

# ---------------------------------------------------------------------------
# 2. unpark, then a compatibility write, keeps the re-entry record and the
#    future review/allowance/window state.
# ---------------------------------------------------------------------------
singular_lease_unpark TASK-2001 || fail "unpark failed"
singular_lease_write TASK-2001 agent/brain/TASK-2001 brain l2-developer "app.txt" \
  planned RUN-NEXT "$repo/.worktrees/TASK-2001" "$base" BATCH-NEXT '["app.txt"]' '[]' \
  || fail "post-unpark lease write failed"
python3 - "$lease" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert len(d["operatorReentries"]) == 2, d.get("operatorReentries")
assert d["reviewOperations"][0]["reviewOperationId"] == "REV-1", "unpark+write lost review operations"
assert d["infrastructureAllowances"]["workerInfra"]["used"] == 1, "unpark+write reset an infrastructure allowance"
assert d["providerWindow"]["providerKey"] == "claude:default", "unpark+write lost provider-window state"
assert d["productPassStarted"] is False, "unpark must still open a new product pass"
assert d["retryCount"] == 0, "unpark must still reset the product-repair budget"
PY
pass "unpark plus a compatibility write preserves review, allowance and window state"

# ---------------------------------------------------------------------------
# 3. The lossy write must not defeat the 0.22.0 _deleteRecord guard: a lease
#    whose ONLY history marker is an operator re-entry survives a driver
#    refusal on a planned lease.
# ---------------------------------------------------------------------------
lease2="$(singular_lease_path TASK-2002)"
cat >"$lease2" <<'JSON'
{"taskId":"TASK-2002","status":"blocked","branch":"agent/brain/TASK-2002","area":"brain",
 "owner":"l2-developer","fileScope":"app.txt","ownedFiles":["app.txt"],"forbiddenFiles":[],
 "baseSha":"oldbase","batchId":"BATCH-OLD","runId":"","worktree":"","retryCount":0,
 "maxRetries":1,"productPassStarted":false,
 "operatorReentries":[{"at":"2026-09-14T16:44:00Z","previousStatus":"blocked","archivedRunId":"","previousRetryCount":0}]}
JSON
# A compatibility write (e.g. `singular lease create`, or the driver's own
# pre-worker lease publication) happens between the operator re-entry and the
# next refusal.
singular_lease_write TASK-2002 agent/brain/TASK-2002 brain l2-developer "app.txt" planned \
  || fail "lease write failed"
gen="$(singular_lifecycle_reserve TASK-2002 o1 ORIGIN-1 agent/brain/TASK-2002 brain '["app.txt"]' \
  "$base" BATCH "$repo/.worktrees/TASK-2002")" || fail "reserve refused the re-entered lease"
singular_lifecycle_dispatch_record_write TASK-2002 ORIGIN-1 "$$" 0 "$tmp/d.log" \
  "$base" BATCH o1 "$gen" >/dev/null
singular_lifecycle_finish TASK-2002 o1 "$gen" BATCH "driver-refused" "inspect" \
  || fail "finish refused the driver-refusal release"
[[ -f "$lease2" ]] \
  || fail "lease deleted: the lossy write erased operatorReentries and defeated the _deleteRecord guard"
python3 - "$lease2" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["operatorReentries"], "re-entry record lost"
PY
pass "an operator re-entry alone keeps a refused planned lease from being deleted"

# ---------------------------------------------------------------------------
# 4. Preservation does not weaken the terminal-lease identity protection.
# ---------------------------------------------------------------------------
lease3="$(singular_lease_path TASK-2003)"
cat >"$lease3" <<'JSON'
{"taskId":"TASK-2003","status":"accepted","branch":"agent/brain/TASK-2003","area":"brain",
 "owner":"l2-developer","fileScope":"app.txt","ownedFiles":["app.txt"],"forbiddenFiles":[],
 "baseSha":"b","batchId":"B","runId":"R","worktree":"","retryCount":0,"maxRetries":1,
 "productPassStarted":true,"acceptedCandidate":{"headSha":"cafe"}}
JSON
if singular_lease_write TASK-2003 agent/brain/OTHER brain l2-developer "app.txt" planned 2>/dev/null; then
  fail "accepted lease was overwritten with a different branch"
fi
python3 - "$lease3" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["status"] == "accepted" and d["acceptedCandidate"]["headSha"] == "cafe"
PY
pass "the accepted/integrated identity-collision refusal still holds"

# ---------------------------------------------------------------------------
# 5. Carry-forward is for durable record state only. Underscore-prefixed
#    lifecycle control sentinels (task_lifecycle.py's _deleteRecord, consumed
#    by locked() before publish) must never be persisted by a lease write.
# ---------------------------------------------------------------------------
lease4="$(singular_lease_path TASK-2004)"
cat >"$lease4" <<'JSON'
{"taskId":"TASK-2004","status":"blocked","branch":"agent/brain/TASK-2004","area":"brain",
 "owner":"l2-developer","fileScope":"app.txt","ownedFiles":["app.txt"],"forbiddenFiles":[],
 "baseSha":"b","batchId":"B","runId":"R","worktree":"","retryCount":0,"maxRetries":1,
 "productPassStarted":false,"_deleteRecord":true,"keepMe":"durable"}
JSON
singular_lease_write TASK-2004 agent/brain/TASK-2004 brain l2-developer "app.txt" planned \
  || fail "lease write failed"
python3 - "$lease4" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert "_deleteRecord" not in d, "a lifecycle control sentinel was persisted into the lease"
assert d["keepMe"] == "durable", "durable unknown state was dropped"
PY
pass "control sentinels are not carried forward, ordinary unknown state is"

echo "test-lease-field-preservation: ok"
