#!/usr/bin/env bash
# A dispatch refused for the same reason on consecutive cycles parks (0.23.7).
# Repeated l1-drive refusals (exit 2) must park the task, record the reason
# in an event, and surface it in health. No provider is launched: the dispatches
# here are records with exit files, as the reaper sees them.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-dispatch-refusal-park.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }
assert_absent() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2'"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export SINGULAR_ROOT="$tmp/repo"
export SINGULAR_STATE_DIR="$SINGULAR_ROOT/.singular-state"
export SINGULAR_DISPATCH_DIR="$SINGULAR_STATE_DIR/dispatch"
export SINGULAR_LEASES_DIR="$SINGULAR_STATE_DIR/leases"
export SINGULAR_RUNS_DIR="$SINGULAR_STATE_DIR/runs"
export SINGULAR_ORCH_DIR="$SINGULAR_ROOT/docs/orchestration"
export SINGULAR_TASKS_DIR="$SINGULAR_ORCH_DIR/tasks"
export SINGULAR_EVENTS_FILE="$SINGULAR_STATE_DIR/events.ndjson"
export SINGULAR_WORKTREES_DIR="$SINGULAR_ROOT/.worktrees"
export SINGULAR_TARGET_BRANCH=target
mkdir -p "$SINGULAR_DISPATCH_DIR" "$SINGULAR_LEASES_DIR" "$SINGULAR_RUNS_DIR" "$SINGULAR_TASKS_DIR" \
  "$SINGULAR_ORCH_DIR/gates"
git -C "$SINGULAR_ROOT" init -q
git -C "$SINGULAR_ROOT" checkout -q -b target
printf '%s\n' '{"schema":"singular.orchestration.dag.v0","nodes":[{"id":"a","stage":"S0","area":"core","layer":"x","kind":"contract","dependsOn":[],"requiredCompletion":"done"}]}' \
  >"$SINGULAR_ORCH_DIR/dag.v0.json"
task() {
  cat >"$SINGULAR_TASKS_DIR/$1.md" <<TASK
# $1: refusal fixture

Status: ready
Area: core
Target branch: \`target\`
Worker branch: \`agent/core/$1-fixture\`
Test policy: \`strict_test_first\`
Gate command: \`true\`
Dispatch mode: canonical
Depends on: []

## Objective

Fixture.

## Scope

Owned files:

- \`src/a.txt\`

## Acceptance Criteria

- The gate command passes.
TASK
}
task TASK-0045; task TASK-0047
git -C "$SINGULAR_ROOT" add . && git -C "$SINGULAR_ROOT" -c user.name=t -c user.email=t@t commit -q -m init

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"

# One reconcile cycle's worth of a dispatch that the driver refused / finished.
# cycle <task> <exit-code> <cycle-no> <driver stderr...>
cycle() {
  local tid="$1" ec="$2" n="$3"; shift 3
  local log="$SINGULAR_RUNS_DIR/dispatch-$tid-$n.log"
  printf '%s\n' "$@" >"$log"
  python3 - "$SINGULAR_DISPATCH_DIR/$tid.json" "$tid" "$log" "$n" <<'PY'
import json, sys
path, tid, log, n = sys.argv[1:5]
json.dump({"taskId": tid, "runId": f"RUN-2026100{n}T00000{n}Z-{n}", "pid": 99999999, "pidStart": "gone",
           "pgid": 0, "log": log, "baseSha": "", "batchId": "", "state": "launched"},
          open(path, "w"), indent=2)
PY
  printf '%s\n' "$ec" >"$SINGULAR_DISPATCH_DIR/$tid.exit"
  singular_reap_dispatches "RUN-CYCLE-$n"
}
status() { singular_task_status "$SINGULAR_TASKS_DIR/$1.md"; }
events() { grep -c "\"type\":\"$1\"" "$SINGULAR_EVENTS_FILE" 2>/dev/null || true; }
health() { bash "$SCRIPT_DIR/ops.sh" health "$@" 2>/dev/null; }
refusal() {
  # The driver's real words, with the per-cycle noise (paths, shas) that must
  # not restart the count.
  printf 'l1-drive: base refresh of retained branch failed: refresh: checkout %s/.worktrees/TASK-0045 is dirty; not merging\n' "$1"
  printf 'l1-drive: admitted base is not an ancestor of the retained/fresh candidate lineage\n'
}

# --- the same reason three cycles in a row parks, once -----------------------
out="$(cycle TASK-0045 2 1 "noise before" "$(refusal /tmp/a1)")"
assert_contains "$out" "reaped_refused=1" "cycle 1 counted as refused"
assert_eq "$(status TASK-0045)" "ready" "one refusal does not park"
out="$(cycle TASK-0045 2 2 "$(refusal /tmp/other/b2)")"
assert_eq "$(status TASK-0045)" "ready" "two refusals do not park"
assert_eq "$(events origin.dispatch_refusal_parked)" "0" "no park event before the threshold"
assert_absent "$(health)" "dispatch refused" "health is quiet before the threshold"
out="$(cycle TASK-0045 2 3 "$(refusal /tmp/c3)" 2>"$tmp/park.err")"
assert_contains "$out" "reaped_refused=1" "the reaper's counter protocol is intact on the parking cycle"
assert_eq "$(printf '%s\n' "$out" | grep -c .)" "5" "the reaper prints only its five counters on stdout"
assert_eq "$(status TASK-0045)" "blocked" "the third consecutive refusal parks the task"
assert_eq "$(events origin.dispatch_refusal_parked)" "1" "exactly one park event"
event="$(grep '"type":"origin.dispatch_refusal_parked"' "$SINGULAR_EVENTS_FILE")"
assert_contains "$event" '"taskId":"TASK-0045"' "event names the task"
assert_contains "$event" 'is dirty; not merging' "event carries the driver's reason"
assert_contains "$event" 'admitted base is not an ancestor' "event carries the final refusal line"
assert_contains "$event" '"refusals":3' "event carries the count"
assert_contains "$event" '"suggestedCommand":"singular unpark TASK-0045"' "event carries the suggested command"
assert_contains "$(cat "$tmp/park.err")" "parked TASK-0045 after 3 consecutive dispatch refusals" "reconcile log line"
h="$(health)"
assert_contains "$h" "ATTENTION:  dispatch refused 3 consecutive times, task parked: TASK-0045" "health ATTENTION names the task"
assert_contains "$h" "is dirty; not merging" "health ATTENTION carries the reason"
assert_contains "$h" 'singular unpark TASK-0045' "health ATTENTION carries the command"
hj="$(health --json)"
assert_eq "$(python3 -c 'import json,sys; d=json.load(sys.stdin); r=d["refusedDispatches"]; print(d["ok"], len(r), r[0]["taskId"], r[0]["count"])' <<<"$hj")" \
  "False 1 TASK-0045 3" "health --json reports the parked refusal"
echo "ok: three consecutive refusals for one reason park the task with one event and a health ATTENTION"

# --- unpark clears the record; the count starts again ------------------------
bash "$SCRIPT_DIR/ops.sh" unpark TASK-0045 >/dev/null 2>&1 || fail "unpark failed"
assert_eq "$(status TASK-0045)" "ready" "unpark returns the task to ready"
[[ ! -e "$(singular_dispatch_refusal_path TASK-0045)" ]] || fail "unpark left the dispatch-refusal record"
assert_absent "$(health)" "dispatch refused" "health is quiet after unpark"
cycle TASK-0045 2 4 "$(refusal /tmp/d4)" >/dev/null
assert_eq "$(status TASK-0045)" "ready" "the count restarts after unpark"
echo "ok: unpark clears the refusal record"

# --- a different reason, or progress, restarts the count ---------------------
cycle TASK-0047 2 1 "l1-drive: target branch does not resolve to a local commit: target" >/dev/null
cycle TASK-0047 2 2 "l1-drive: target branch does not resolve to a local commit: target" >/dev/null
cycle TASK-0047 2 3 "$(refusal /tmp/e)" >/dev/null
assert_eq "$(status TASK-0047)" "ready" "a different reason restarts the count"
cycle TASK-0047 2 4 "$(refusal /tmp/f)" >/dev/null
cycle TASK-0047 0 5 "accepted" >/dev/null
[[ ! -e "$(singular_dispatch_refusal_path TASK-0047)" ]] || fail "a dispatch that ran did not clear the refusal count"
cycle TASK-0047 2 6 "$(refusal /tmp/g)" >/dev/null
cycle TASK-0047 2 7 "$(refusal /tmp/h)" >/dev/null
assert_eq "$(status TASK-0047)" "ready" "refusals are consecutive: a dispatch that ran resets them"
# The threshold is a knob.
SINGULAR_DISPATCH_REFUSAL_PARK_THRESHOLD=5 cycle TASK-0047 2 8 "$(refusal /tmp/i)" >/dev/null
assert_eq "$(status TASK-0047)" "ready" "SINGULAR_DISPATCH_REFUSAL_PARK_THRESHOLD is honoured"
cycle TASK-0047 2 9 "$(refusal /tmp/j)" >/dev/null 2>&1
assert_eq "$(status TASK-0047)" "blocked" "default threshold parks"
assert_eq "$(events origin.dispatch_refusal_parked)" "2" "one park event per parked task"
echo "ok: the count is per reason and consecutive"

# --- both reapers account refusals --------------------------------------------
grep -q 'singular_dispatch_refusal_account "$tid" "$run_id" "$refused_log"' "$SCRIPT_DIR/lifecycle.sh" \
  || fail "the lifecycle reaper does not account refusals"
echo "PASS: test-dispatch-refusal-park"
