#!/usr/bin/env bash
# The circuit breaker speaks in events (0.23.7). Breaker increments and halts
# must appear in events.ndjson so event consumers can detect a stopped loop.
# Reconcile is a stub: no provider, no dispatch.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-autonomate-breaker-events.sh requires bash >= 4" >&2; exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p "$repo/.singular-state" "$repo/docs/orchestration/tasks"
git -C "$tmp" init -q repo
git -C "$repo" checkout -q -b target
git -C "$repo" -c user.email=test@example.com -c user.name=test commit -q --allow-empty -m init
events="$repo/.singular-state/events.ndjson"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2' in: $1"; }

env_common() {
  env SINGULAR_ROOT="$repo" SINGULAR_STATE_DIR="$repo/.singular-state" \
    SINGULAR_ORCH_DIR="$repo/docs/orchestration" \
    SINGULAR_TASKS_DIR="$repo/docs/orchestration/tasks" \
    SINGULAR_EVENTS_FILE="$events" \
    SINGULAR_TARGET_BRANCH=target SINGULAR_PUSH=0 SINGULAR_SLEEP=0 \
    SINGULAR_TEST_PROCESS_CONTROL=1 SINGULAR_TEST_PROCESS_CONTROL_STATE=ok \
    SINGULAR_RUNNER=/nonexistent/runner SINGULAR_CODEX_RUNNER=/nonexistent/runner \
    SINGULAR_LIMIT_SLEEPTHROUGH=0 SINGULAR_MAX_CONSEC_FAILS=5 \
    "$@"
}
lib() { env_common bash -c "source '$ROOT/engine/lib.sh'; $1"; }
set_breaker() { lib "singular_breaker_reset; for _ in \$(seq 1 $1); do singular_breaker_trip >/dev/null; done"; }
count() { grep -c "\"type\":\"$1\"" "$events" 2>/dev/null || true; }
last() { grep "\"type\":\"$1\"" "$events" | tail -1; }

# stub <accepted> <failed_dispatches> <planner_failures>
stub() {
  cat >"$repo/reconcile-stub.sh" <<SH
#!/usr/bin/env bash
echo "imported_this_run=$1"
echo "dispatched_this_run=1"
echo "integrated_this_run=0"
echo "failed_dispatches=$2"
echo "failed_integrations=0"
echo "planner_failures_this_run=$3"
echo "planner_backoff_active_this_run=0"
echo "l1_import_rejections_this_run=0"
echo "reaped_ok=0"
echo "reaped_failures=0"
echo "workers_running=0"
echo "gates_promoted_this_run=0"
SH
  chmod +x "$repo/reconcile-stub.sh"
}
run_once() {
  env_common SINGULAR_RECONCILE_SCRIPT="$repo/reconcile-stub.sh" \
    bash "$ROOT/engine/autonomate.sh" --once >"$tmp/autonomate.log" 2>&1 || {
      cat "$tmp/autonomate.log" >&2; return 1; }
}
health() { env_common bash "$ROOT/engine/ops.sh" health 2>/dev/null; }

# --- an increment is an event that names its cause ---------------------------
lib singular_breaker_reset
stub 0 0 2
run_once
assert_eq "$(lib singular_breaker_count)" "1" "a failed cycle increments the breaker"
assert_eq "$(count autonomate.breaker_incremented)" "1" "one autonomate.breaker_incremented event"
ev="$(last autonomate.breaker_incremented)"
assert_contains "$ev" '"breaker":1' "the event carries the new count"
assert_contains "$ev" '"previous":0' "the event carries the previous count"
assert_contains "$ev" '"threshold":5' "the event carries the threshold"
assert_contains "$ev" '"reason":"no progress and planner-failures=2"' "the event names the reason"
assert_contains "$ev" '"plannerFailures":2' "the event carries the counters"
assert_eq "$(count autonomate.breaker_open)" "0" "not open at 1/5"
assert_contains "$(last autonomate.exited)" '"reason":"once"' "autonomate.exited carries the exit reason"
assert_not_contains "$(health)" "circuit breaker" "health is quiet at 1/5"
echo "ok: a breaker increment emits an event with its reason and counters"

# --- progress resets without an increment event ------------------------------
stub 1 0 0
run_once
assert_eq "$(lib singular_breaker_count)" "0" "progress resets the breaker"
assert_eq "$(count autonomate.breaker_incremented)" "1" "progress emits no increment event"

# --- health ATTENTION from 3/5 ------------------------------------------------
set_breaker 2
stub 0 1 0
run_once
assert_eq "$(lib singular_breaker_count)" "3" "third consecutive failure"
assert_contains "$(last autonomate.breaker_incremented)" '"reason":"no progress and failed-dispatches=1"' "reason follows the counters"
h="$(health)"
assert_contains "$h" "ATTENTION:  circuit breaker at 3/5; the loop halts at 5" "health ATTENTION at 3/5"
assert_contains "$h" "last increment: no progress and failed-dispatches=1" "health names the last reason"
set_breaker 2
assert_not_contains "$(health)" "circuit breaker" "health is quiet at 2/5"
echo "ok: singular health prints ATTENTION from 3/5"

# --- the trip to 5/5 emits breaker_open; the halted loop says why it exited ---
set_breaker 4
stub 0 1 0
run_once
assert_eq "$(lib singular_breaker_count)" "5" "breaker reaches the threshold"
assert_eq "$(count autonomate.breaker_open)" "1" "autonomate.breaker_open emitted at the trip"
assert_contains "$(last autonomate.breaker_open)" '"breaker":5,"threshold":5,"observedAt":"increment"' "breaker_open payload"
assert_contains "$(health)" "ATTENTION:  circuit breaker OPEN (5/5); the loop is halted" "health reports the open breaker"
run_once
assert_contains "$(cat "$tmp/autonomate.log")" "circuit breaker open (5/5); halting" "the loop halts"
assert_eq "$(count autonomate.breaker_open)" "2" "a loop that refuses to start on an open breaker says so"
assert_contains "$(last autonomate.breaker_open)" '"observedAt":"loop-entry"' "loop-entry breaker_open"
ex="$(last autonomate.exited)"
assert_contains "$ex" '"reason":"circuit-breaker-open"' "autonomate.exited names the halt"
assert_contains "$ex" '"breaker":5,"threshold":5' "autonomate.exited carries the breaker state"
# Every event line is valid JSON.
python3 - "$events" <<'PY'
import json, sys
for n, line in enumerate(open(sys.argv[1], encoding="utf-8"), 1):
    if line.strip():
        json.loads(line)
PY
echo "ok: an open breaker emits autonomate.breaker_open and autonomate.exited says why"

# --- STOP is named too ---------------------------------------------------------
lib singular_breaker_reset
: >"$repo/.singular-state/STOP"
stop_file="$(lib 'printf %s "$SINGULAR_STOP_FILE"')"
: >"$stop_file"
run_once
assert_contains "$(last autonomate.exited)" '"reason":"stop-sentinel"' "a STOP exit is named"
rm -f "$stop_file" "$repo/.singular-state/STOP"
echo "PASS: test-autonomate-breaker-events"
