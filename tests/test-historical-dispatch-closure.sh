#!/usr/bin/env bash
set -euo pipefail
# Reserve-before-bind deadlock (field 2026-09-14, stall 7).
#
# A STOP-frozen or crashed driver leaves its dispatch record `launched`. By the
# time the reaper sees it, the next reconcile has already reserved the lease for
# a successor generation. finish() then refuses -- "stale owner cannot finish
# successor lease" (task_lifecycle.py) -- which is CORRECT for lease mutation:
# the predecessor has no authority over the successor's lease. The bug was the
# reaper's answer to that refusal: it counted the record as a running worker and
# left it `launched`, so the successor could never bind and the task stalled
# until an operator finalized the record by hand.
#
# A dispatch record is historical process bookkeeping for ONE generation. Its
# closure is independent of who owns the lease now. This pins that closure, and
# pins that it cannot be used to skip lease settlement or to touch a successor.
#
# Dedicated test because tests/test-detached-dispatch.sh and
# tests/test-orphan-continuation.sh -- the two suites that would otherwise cover
# this path end to end -- are recorded red in tests/BASELINE-FAILURES.md.
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-historical-dispatch-closure.sh requires bash >= 4" >&2; exit 1
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

# Fixture: dead predecessor at old-owner@1, lease already reserved for
# new-owner@2, predecessor exit attributed to generation 1.
setup_case() {
  local tid="$1" with_exit="$2"
  local record lease
  record="$(singular_dispatch_record_path "$tid")"
  lease="$(singular_lease_path "$tid")"
  mkdir -p "$(dirname "$record")" "$(dirname "$lease")"
  cat >"$record" <<JSON
{"taskId":"$tid","runId":"RUN-OLD","pid":999995,"pidStart":"gone","pgid":0,
 "baseSha":"old-base","batchId":"old-batch","state":"launched",
 "reservationOwner":"old-owner","reservationGeneration":1,"campaignBinding":"legacy"}
JSON
  cat >"$lease" <<JSON
{"taskId":"$tid","runId":"RUN-NEW","branch":"agent/test/$tid","area":"test","ownedFiles":[],
 "baseSha":"new-base","batchId":"new-batch","worktree":"/tmp/unused","status":"planned",
 "reservationOwner":"new-owner","reservationGeneration":2,"reservationRunId":"RUN-NEW",
 "campaignBinding":"legacy"}
JSON
  if [[ "$with_exit" == yes ]]; then
    python3 "$SINGULAR_TASK_LIFECYCLE" write-exit --record "$record" \
      --exit-file "$(singular_dispatch_exit_path "$tid")" \
      --owner old-owner --generation 1 --exit-code 3
  fi
}

# The reaper scans every record in the dispatch directory, so each case must
# retire its own fixture or it is re-reaped (and re-counted) by the next one.
retire_case() {
  local tid="$1"
  rm -f "$(singular_dispatch_record_path "$tid")" \
        "$(singular_dispatch_exit_path "$tid")" \
        "$(singular_lease_path "$tid")"
}

# --- 1. exit-file path: the deadlock itself, and the successor proceeds -------
tid=TASK-3001
setup_case "$tid" yes
record="$(singular_dispatch_record_path "$tid")"
lease="$(singular_lease_path "$tid")"
cp "$lease" "$tmp/successor-before.json"
out="$(singular_lifecycle_reap_dispatches REAPER-1)"
[[ "$out" == *"workers_running=0"* ]] || fail "dead predecessor still counted as a running worker"
[[ "$out" == *"reaped_terminal=1"* ]] || fail "exit code 3 was not accounted as terminal: $out"
[[ "$(singular_json_field "$record" state)" == reaped ]] || fail "historical dispatch left launched"
cmp -s "$lease" "$tmp/successor-before.json" || fail "successor lease was rewritten"
pass "a dead predecessor's dispatch closes without touching the successor lease"

# The successor can now bind and complete -- the deadlock is actually gone, not
# merely reported differently.
singular_lifecycle_dispatch_record_write "$tid" RUN-NEW "$$" 0 "$tmp/new.log" \
  new-base new-batch new-owner 2 >/dev/null || fail "successor could not bind after closure"
[[ "$(singular_json_field "$record" reservationOwner)" == new-owner ]] \
  || fail "successor did not take the dispatch record"
singular_lifecycle_finish "$tid" new-owner 2 new-batch "driver-exit-1" "classify" \
  || fail "successor could not finish its own dispatch"
pass "the successor binds and finishes after the historical dispatch is closed"
retire_case "$tid"

# --- 2. exit evidence is retained and the shared exit file consumed ----------
tid=TASK-3002
setup_case "$tid" yes
record="$(singular_dispatch_record_path "$tid")"
singular_lifecycle_reap_dispatches REAPER-2 >/dev/null
[[ ! -f "$(singular_dispatch_exit_path "$tid")" ]] \
  || fail "predecessor exit file survived; it would misattribute the successor's exit"
python3 - "$record" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["exitEvidence"]["exitCode"] == 3, d.get("exitEvidence")
assert d["exitEvidence"]["reservationOwner"] == "old-owner", d.get("exitEvidence")
assert d["closure"]["leaseAction"] == "preserved-successor", d.get("closure")
PY
pass "exit evidence is retained in the closed record and the shared exit file is consumed"
retire_case "$tid"

# --- 3. closure may not substitute for settling a lease we still own ---------
tid=TASK-3003
setup_case "$tid" yes
lease="$(singular_lease_path "$tid")"
python3 - "$lease" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
d["reservationOwner"] = "old-owner"; d["reservationGeneration"] = 1
json.dump(d, open(p, "w", encoding="utf-8"), indent=2)
PY
if singular_lifecycle_close_dispatch "$tid" 3 terminal old-owner 1 test-reason >/dev/null 2>&1; then
  fail "closure skipped settlement of a lease this dispatch still owns"
fi
[[ "$(singular_json_field "$(singular_dispatch_record_path "$tid")" state)" == launched ]] \
  || fail "refused closure still mutated the record"
pass "closure refuses when the lease is still owned by this dispatch"
# This case deliberately leaves a `launched` record.
retire_case "$tid"

# --- 4. a stale reaper cannot close another generation's dispatch ------------
tid=TASK-3004
setup_case "$tid" yes
if singular_lifecycle_close_dispatch "$tid" 3 terminal wrong-owner 9 test-reason >/dev/null 2>&1; then
  fail "a non-owning reaper closed the dispatch"
fi
[[ "$(singular_json_field "$(singular_dispatch_record_path "$tid")" state)" == launched ]] \
  || fail "stale closure mutated the record"
pass "a stale reaper cannot close a dispatch it does not own"
retire_case "$tid"

# --- 5. closure is idempotent ------------------------------------------------
tid=TASK-3005
setup_case "$tid" yes
singular_lifecycle_close_dispatch "$tid" 3 terminal old-owner 1 test-reason >/dev/null \
  || fail "first closure failed"
second="$(singular_lifecycle_close_dispatch "$tid" 3 terminal old-owner 1 test-reason)" \
  || fail "replayed closure failed"
[[ "$second" == "already-closed" ]] || fail "replayed closure was not idempotent: $second"
pass "closing an already-closed dispatch is an idempotent no-op"
retire_case "$tid"

# --- 6. vanished-process path (no exit file) --------------------------------
tid=TASK-3006
setup_case "$tid" no
record="$(singular_dispatch_record_path "$tid")"
lease="$(singular_lease_path "$tid")"
cp "$lease" "$tmp/successor-before-6.json"
out="$(singular_lifecycle_reap_dispatches REAPER-6)"
[[ "$out" == *"workers_running=0"* ]] || fail "vanished predecessor counted as running: $out"
[[ "$(singular_json_field "$record" state)" == reaped ]] || fail "vanished dispatch left launched"
cmp -s "$lease" "$tmp/successor-before-6.json" || fail "successor lease rewritten on the vanished path"
pass "a vanished predecessor with no exit file also closes historically"

echo "test-historical-dispatch-closure: ok"
