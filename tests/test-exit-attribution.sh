#!/usr/bin/env bash
set -euo pipefail
# Exit-path attribution: two ends of one defect.
#
# (1) The dispatch exit file was per-TASK (<DISPATCH_DIR>/<task>.exit), not per
#     dispatch. A predecessor generation's exit therefore sat on the path a
#     successor's record would be read against, and read-exit rejected it --
#     correctly, since the attribution does not match.
# (2) The reaper's answer to that rejection was to count the record as a running
#     worker and `continue`, every cycle, forever. A third deadlock, distinct
#     from the reserve-before-bind one: here finish() is never even reached.
#
# Fixing (2) alone leaves the misattribution; fixing (1) alone leaves the arm
# reachable for genuinely corrupt evidence. Both ship together.
#
# Unusable exit evidence must be ARCHIVED (bytes preserved, out of the read
# path) and the reaper must fall through to process observation, which is the
# only thing that can actually decide whether a worker is alive.
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-exit-attribution.sh requires bash >= 4" >&2; exit 1
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

# The run id must be unique on the host: with no live tree the reaper falls back
# to `pgrep -f <runId>`, and a bare "RUN-2" matches every live RUN-2026... run.
# Record at <generation>, owned by <owner>; lease already at generation 2 so the
# reaper's closure path (item 2a) applies and never blocks on the lease.
write_record() {
  local tid="$1" owner="$2" generation="$3"
  local record; record="$(singular_dispatch_record_path "$tid")"
  mkdir -p "$(dirname "$record")"
  cat >"$record" <<JSON
{"taskId":"$tid","runId":"RUN-EXITATTR-$$-$generation","pid":999995,"pidStart":"gone","pgid":0,
 "baseSha":"b","batchId":"batch","state":"launched",
 "reservationOwner":"$owner","reservationGeneration":$generation,"campaignBinding":"legacy"}
JSON
}
write_lease_at_gen3() {
  local tid="$1"; local lease; lease="$(singular_lease_path "$tid")"
  mkdir -p "$(dirname "$lease")"
  cat >"$lease" <<JSON
{"taskId":"$tid","runId":"RUN-SUCC","branch":"agent/test/$tid","area":"test","ownedFiles":[],
 "baseSha":"b","batchId":"batch","worktree":"/tmp/unused","status":"planned",
 "reservationOwner":"succ-owner","reservationGeneration":3,"reservationRunId":"RUN-SUCC",
 "campaignBinding":"legacy"}
JSON
}
retire() {
  local tid="$1"
  rm -f "$(singular_dispatch_record_path "$tid")" "$(singular_lease_path "$tid")" \
        "$SINGULAR_DISPATCH_DIR/$tid".*exit* 2>/dev/null || true
}

# --- 1. a predecessor's exit must not pin the successor's record -------------
# gen-1 wrote an exit; gen-2 then took the dispatch record. The gen-1 exit is
# not attributable to gen-2 and must not stall it.
tid=TASK-4001
write_record "$tid" old-owner 1
write_lease_at_gen3 "$tid"
singular_lifecycle_exit_write "$tid" 3 old-owner 1 >/dev/null 2>&1 || true
write_record "$tid" new-owner 2          # successor binds the record
out="$(singular_lifecycle_reap_dispatches REAPER-1)"
[[ "$out" == *"workers_running=0"* ]] \
  || fail "a predecessor's exit pinned the successor's record as a running worker: $out"
[[ "$(singular_json_field "$(singular_dispatch_record_path "$tid")" state)" == reaped ]] \
  || fail "record was left launched by an unattributable predecessor exit"
pass "a predecessor's exit does not pin the successor's dispatch record"
retire "$tid"

# --- 2. corrupt exit evidence is archived, not treated as a live worker ------
tid=TASK-4002
write_record "$tid" old-owner 1
write_lease_at_gen3 "$tid"
printf 'not json at all\n' >"$(singular_dispatch_exit_path "$tid")"
out="$(singular_lifecycle_reap_dispatches REAPER-2)"
[[ "$out" == *"workers_running=0"* ]] || fail "corrupt exit evidence pinned the record: $out"
[[ "$(singular_json_field "$(singular_dispatch_record_path "$tid")" state)" == reaped ]] \
  || fail "record left launched after corrupt exit evidence"
archived="$(ls "$SINGULAR_DISPATCH_DIR/$tid".*unattributed* 2>/dev/null | head -1 || true)"
[[ -n "$archived" ]] || fail "corrupt exit evidence was discarded rather than archived"
grep -q "not json at all" "$archived" || fail "archived exit evidence lost its bytes"
[[ ! -f "$(singular_dispatch_exit_path "$tid")" ]] \
  || fail "corrupt evidence left on the read path; it would be re-read every cycle"
pass "corrupt exit evidence is archived and the record is not pinned"
retire "$tid"

# --- 3. two generations' exits occupy distinct paths -------------------------
tid=TASK-4003
write_record "$tid" old-owner 1
singular_lifecycle_exit_write "$tid" 3 old-owner 1 >/dev/null 2>&1 || true
first="$(singular_dispatch_exit_resolve "$tid" 1 || true)"
[[ -n "$first" ]] || fail "generation 1 exit was not written where generation 1 reads it"
write_record "$tid" new-owner 2
singular_lifecycle_exit_write "$tid" 0 new-owner 2 >/dev/null 2>&1 || true
second="$(singular_dispatch_exit_resolve "$tid" 2 || true)"
[[ -n "$second" ]] || fail "generation 2 exit was not written where generation 2 reads it"
[[ "$first" != "$second" ]] || fail "both generations share one exit path: $first"
[[ "$(singular_json_field "$first" exitCode)" == 3 ]] || fail "generation 1 exit was overwritten"
[[ "$(singular_json_field "$second" exitCode)" == 0 ]] || fail "generation 2 exit is wrong"
pass "each generation's exit occupies its own path and neither overwrites the other"
retire "$tid"

# --- 4. legacy shared-path records still reap (dual read) -------------------
tid=TASK-4004
write_record "$tid" old-owner 1
write_lease_at_gen3 "$tid"
# A record written before 0.23.3: exit at the legacy shared path, attributed
# correctly to this record's own generation.
python3 "$SINGULAR_TASK_LIFECYCLE" write-exit \
  --record "$(singular_dispatch_record_path "$tid")" \
  --exit-file "$(singular_dispatch_exit_path "$tid")" \
  --owner old-owner --generation 1 --exit-code 3
out="$(singular_lifecycle_reap_dispatches REAPER-4)"
[[ "$out" == *"workers_running=0"* ]] || fail "legacy-path record was not reaped: $out"
[[ "$out" == *"reaped_terminal=1"* ]] || fail "legacy exit code 3 lost its outcome: $out"
[[ "$(singular_json_field "$(singular_dispatch_record_path "$tid")" state)" == reaped ]] \
  || fail "legacy-path record left launched"
[[ ! -f "$(singular_dispatch_exit_path "$tid")" ]] || fail "legacy exit file was not consumed"
pass "a record whose exit is on the legacy shared path still reaps"
retire "$tid"

echo "test-exit-attribution: ok"
