#!/usr/bin/env bash
set -euo pipefail
# Acceptance publication must prove ownership BEFORE it publishes anything.
#
# singular_lease_set_status performs no ownership check at all, and it was what
# stamped `accepted` on the lease. The owner-bound transition
# (l1_record_attempt terminal completed) ran LAST -- after the lease said
# accepted, after the task file said accepted, after the decision was recorded,
# and after the packet had been copied into the inbox, which is where the
# reconciler integrates from. A stale-generation driver reaching the accept path
# therefore clobbered a successor's lease and queued its own packet, and the
# owner check could only report the damage afterwards.
#
# This is the one safety item in 0.23.3: S1 (a stale owner must never publish
# over a newer attempt) and S6 (the successor's record is not the predecessor's
# to overwrite). The candidate itself is genuine -- it passed gate and audit --
# so the damage is lost successor work and false provenance, not a fabricated
# acceptance.
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-stale-acceptance-refused.sh requires bash >= 4" >&2; exit 1
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
lease="$(singular_lease_path TASK-5001)"
mkdir -p "$(dirname "$lease")"

# A lease reserved by generation 2, while a generation-1 driver is still alive
# and about to publish its acceptance.
cat >"$lease" <<'JSON'
{"taskId":"TASK-5001","status":"planned","branch":"agent/test/TASK-5001","area":"test",
 "owner":"l2-developer","fileScope":"app.txt","ownedFiles":["app.txt"],"forbiddenFiles":[],
 "baseSha":"b","batchId":"BATCH","runId":"RUN-NEW","worktree":"/tmp/unused",
 "retryCount":0,"maxRetries":1,"productPassStarted":true,
 "reservationOwner":"new-owner","reservationGeneration":2,"reservationRunId":"RUN-NEW",
 "campaignBinding":"legacy"}
JSON
cp "$lease" "$tmp/successor-before.json"

# --- 1. the stale generation is refused, and changes nothing ----------------
# Assert the helper exists first: without this the negative assertion below
# would "pass" merely because the function is undefined and the call fails.
declare -F singular_lease_set_status_owned >/dev/null \
  || fail "singular_lease_set_status_owned is not defined; acceptance publication has no ownership check"
if singular_lease_set_status_owned TASK-5001 accepted old-owner 1 2>/dev/null; then
  fail "a stale generation published an accepted status over the successor's lease"
fi
cmp -s "$lease" "$tmp/successor-before.json" \
  || fail "the refused write still modified the successor's lease"
pass "a stale generation cannot publish acceptance over a successor's lease"

# --- 2. the refusal is recorded, not silent ---------------------------------
[[ -f "$SINGULAR_EVENTS_FILE" ]] && grep -q "lease.status_write_refused_stale" "$SINGULAR_EVENTS_FILE" \
  || fail "the refused publication produced no event"
pass "a refused status publication is recorded as an event"

# --- 3. the owner in possession still publishes normally --------------------
singular_lease_set_status_owned TASK-5001 accepted new-owner 2 \
  || fail "the owning reservation could not publish its own acceptance"
[[ "$(singular_lease_field TASK-5001 status)" == accepted ]] \
  || fail "the owning reservation's status did not land"
pass "the reservation that owns the lease publishes normally"

# --- 4. asymmetry is staleness, in both directions --------------------------
# An identified driver whose lease no longer carries a reservation has had it
# released out from under it; an unidentified writer over a RESERVED lease is a
# stale or legacy publisher. Both are refused.
python3 - "$lease" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
d.pop("reservationOwner", None); d.pop("reservationGeneration", None)
d["status"] = "planned"
json.dump(d, open(p, "w", encoding="utf-8"), indent=2)
PY
if singular_lease_set_status_owned TASK-5001 accepted new-owner 2 2>/dev/null; then
  fail "a driver published after its reservation was released"
fi
python3 - "$lease" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
d["reservationOwner"] = "new-owner"; d["reservationGeneration"] = 2
d["status"] = "planned"
json.dump(d, open(p, "w", encoding="utf-8"), indent=2)
PY
if singular_lease_set_status_owned TASK-5001 accepted "" "" 2>/dev/null; then
  fail "an unidentified writer published over a reserved lease"
fi
pass "an asymmetric reservation claim is refused in both directions"

# --- 4b. the legacy path still works ----------------------------------------
# Direct invocation reserves nothing and l1_record_attempt is a no-op there, so
# a lease with no reservation and a writer with no claim is the legacy contract.
# Refusing it would break every non-scheduler driver run -- which is exactly
# what the first cut of this change did, caught by test-decider-fastpath and
# test-fresh-consumer.
python3 - "$lease" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
d.pop("reservationOwner", None); d.pop("reservationGeneration", None)
d["status"] = "planned"
json.dump(d, open(p, "w", encoding="utf-8"), indent=2)
PY
singular_lease_set_status_owned TASK-5001 accepted "" "" \
  || fail "the legacy unreserved path was refused"
[[ "$(singular_lease_field TASK-5001 status)" == accepted ]] \
  || fail "the legacy unreserved publication did not land"
pass "an unreserved lease with an unidentified writer is the legacy path and still publishes"

# --- 5. the accept path proves ownership before it publishes ----------------
# Pin the ORDER in the driver, not just the helper: the owner-bound transition
# and the owned status write must both precede the inbox publication.
drive="$SCRIPT_DIR/l1-drive.sh"
order_check="$(python3 - "$drive" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
start = src.index('_l1_outcome="accepted"')
block = src[start:start + 2000]
def at(needle):
    i = block.find(needle)
    return i if i >= 0 else 10**9
record = at("l1_record_attempt terminal completed")
owned = at("singular_lease_set_status_owned")
inbox = at('mv "$inbox_packet.tmp" "$inbox_packet"')
problems = []
if record > inbox: problems.append("owner-bound disposition is published after the inbox packet")
if owned > inbox: problems.append("lease status is published after the inbox packet")
if record > owned: problems.append("status is published before the owner-bound disposition")
print("; ".join(problems) if problems else "ok")
PY
)"
[[ "$order_check" == ok ]] || fail "accept path publishes before proving ownership: $order_check"
# And the unchecked helper is no longer what stamps acceptance there.
python3 - "$drive" <<'PY' || exit 1
import sys
src = open(sys.argv[1], encoding="utf-8").read()
start = src.index('_l1_outcome="accepted"')
block = src[start:start + 2000]
assert 'singular_lease_set_status "$task_id" "accepted"' not in block, \
    "the unchecked status helper still stamps acceptance on the accept path"
PY
pass "the accept path proves ownership before publishing the lease, task and packet"

echo "test-stale-acceptance-refused: ok"
