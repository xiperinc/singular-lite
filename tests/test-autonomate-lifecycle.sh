#!/usr/bin/env bash
set -euo pipefail

# E10 (0.5.0): interruptible naps (STOP/WAKE/backoff-clear honored mid-sleep)
# and `autonomate.sh --detach` (supported daemonized launch).

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-autonomate-lifecycle.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
root="$tmp/repo"
mkdir -p "$root/.singular-state" "$root/docs/orchestration/tasks"
git -C "$root" init -q
git -C "$root" checkout -q -b target
git -C "$root" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

env_common() {
  env SINGULAR_ROOT="$root" SINGULAR_STATE_DIR="$root/.singular-state" \
    SINGULAR_ORCH_DIR="$root/docs/orchestration" SINGULAR_TASKS_DIR="$root/docs/orchestration/tasks" \
    SINGULAR_EVENTS_FILE="$root/.singular-state/events.ndjson" \
    SINGULAR_TARGET_BRANCH=target SINGULAR_PUSH=0 SINGULAR_SLEEP_POLL_SEC=1 "$@"
}

# --- 1. singular_interruptible_sleep unit behavior ---------------------------
lib_sleep() {
  env_common bash -c "source '$SCRIPT_DIR/lib.sh'; $1"
}

start=$SECONDS
( sleep 2 && touch "$root/.singular-state/WAKE" ) &
rc=0; lib_sleep "singular_interruptible_sleep 30" || rc=$?
elapsed=$((SECONDS - start))
[[ "$rc" -eq 1 ]] || fail "WAKE should end the nap with rc 1 (rc=$rc)"
[[ "$elapsed" -lt 10 ]] || fail "WAKE should end the nap early (took ${elapsed}s)"
[[ -f "$root/.singular-state/WAKE" ]] && fail "WAKE file must be consumed"

( sleep 2 && touch "$root/.singular-state/STOP" ) &
rc=0; lib_sleep "singular_interruptible_sleep 30" || rc=$?
[[ "$rc" -eq 2 ]] || fail "STOP should end the nap with rc 2 (rc=$rc)"
rm -f "$root/.singular-state/STOP"

# watch_backoff: clearing the backoff ends the nap.
printf '%s\n' \
  '{"schema":"singular.orchestration.planner-backoff.v0","failureClass":"quota","until":"2999-01-01T00:00:00Z"}' \
  >"$root/.singular-state/planner-backoff.json"
( sleep 2 && rm -f "$root/.singular-state/planner-backoff.json" ) &
rc=0; lib_sleep "singular_interruptible_sleep 30 1" || rc=$?
[[ "$rc" -eq 1 ]] || fail "backoff clear should end a watched nap (rc=$rc)"

# --- 2. --detach: parent returns fast, loop runs, STOP ends it --------------
stub="$root/stub-reconcile.sh"
cat >"$stub" <<'SH'
#!/usr/bin/env bash
echo "dispatched_this_run=0"
echo "integrated_this_run=1"
echo "failed_dispatches=0"
echo "failed_integrations=0"
echo "planner_failures_this_run=0"
echo "l1_import_rejections_this_run=0"
SH
chmod +x "$stub"

out="$(env_common SINGULAR_RECONCILE_SCRIPT="$stub" SINGULAR_SLEEP=2 \
  bash "$SCRIPT_DIR/autonomate.sh" --detach 2>&1)"
assert_contains "$out" "detached pid=" "detach reports the pid"
pid="$(sed -n 's/.*detached pid=\([0-9]*\).*/\1/p' <<<"$out")"
kill -0 "$pid" 2>/dev/null || fail "detached loop not alive"
# The pidfile stays a bare number — ops.sh, doctor and the console all `cat` it
# and expect exactly that, so the process identity lives in a sibling file. The
# start time is what makes the single-instance check safe against pid reuse:
# `kill -0` alone cannot tell a live predecessor from an unrelated process that
# inherited a recycled pid, and treating a recycled pid as "still running" locks
# the loop out permanently — worse than the race the check was there to prevent.
[[ "$(cat "$root/.singular-state/autonomate.pid")" == "$pid" ]] \
  || fail "pidfile owned by detached loop"
[[ -s "$root/.singular-state/autonomate.pid.identity" ]] \
  || fail "no process identity recorded beside the pidfile"

# Second --detach is a no-op while running.
out2="$(env_common SINGULAR_RECONCILE_SCRIPT="$stub" SINGULAR_SLEEP=2 \
  bash "$SCRIPT_DIR/autonomate.sh" --detach 2>&1)"
assert_contains "$out2" "already running" "second detach refuses"

# A pidfile whose recorded identity does not match the live process is stale, no
# matter how alive that pid looks. This is the pid-reuse case: some unrelated
# long-running process now owns the number, and without the identity check the
# loop could never start again.
cp "$root/.singular-state/autonomate.pid" "$root/.singular-state/pid.real"
cp "$root/.singular-state/autonomate.pid.identity" "$root/.singular-state/id.real"
printf '%s\n' "$$" >"$root/.singular-state/autonomate.pid"
printf 'Sun Jan  1 00:00:00 2000\n' >"$root/.singular-state/autonomate.pid.identity"
out3="$(env_common SINGULAR_RECONCILE_SCRIPT="$stub" SINGULAR_SLEEP=2 \
  bash "$SCRIPT_DIR/autonomate.sh" --detach 2>&1)"
assert_contains "$out3" "detached pid=" "a recycled pid must not lock the loop out"
pid3="$(sed -n 's/.*detached pid=\([0-9]*\).*/\1/p' <<<"$out3")"
kill "$pid3" 2>/dev/null || true
cp "$root/.singular-state/pid.real" "$root/.singular-state/autonomate.pid"
cp "$root/.singular-state/id.real" "$root/.singular-state/autonomate.pid.identity"

# STOP written mid-nap ends the detached loop within a few poll chunks.
touch "$root/.singular-state/STOP"
for _ in $(seq 1 20); do
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.5
done
kill -0 "$pid" 2>/dev/null && { kill "$pid"; fail "STOP did not end the detached loop"; }
[[ -f "$root/.singular-state/autonomate.pid" ]] && fail "pidfile must be removed on exit"
grep -q "STOP sentinel" "$root/.singular-state/autonomate.log" || fail "loop logged the STOP halt"

# --- 3. Unattended actuation is gated on provable process-group cleanup -----
#
# This loop dispatches agents nobody is watching and kills them on timeout. On a
# host where the group kill does not contain the tree, that cleanup silently
# leaves descendants writing to a worktree. Refusing to start must release
# the claim just taken, or one degraded start would
# lock every later `singular auto` out of the pidfile.
rm -f "$root/.singular-state/STOP" "$root/.singular-state/autonomate.pid" \
  "$root/.singular-state/autonomate.pid.identity"
: >"$root/.singular-state/events.ndjson"

rc=0
out="$(env_common SINGULAR_TEST_PROCESS_CONTROL=1 SINGULAR_TEST_PROCESS_CONTROL_STATE=no-group-kill \
  SINGULAR_RECONCILE_SCRIPT="$stub" SINGULAR_SLEEP=1 \
  bash "$SCRIPT_DIR/autonomate.sh" --once 2>&1)" || rc=$?
[[ "$rc" -eq 2 ]] || fail "unprovable group cleanup must refuse to actuate (rc=$rc): $out"
assert_contains "$out" "singular doctor" "the refusal points at the diagnostic"
assert_contains "$out" "SINGULAR_ALLOW_DEGRADED_KILL=1" "the refusal names the override"
grep -q '"type":"autonomate.preflight_unsafe"' "$root/.singular-state/events.ndjson" \
  || fail "the refusal must be on the event stream, not only on stderr"
[[ -f "$root/.singular-state/autonomate.pid" ]] \
  && fail "a refused start must not leave its pidfile claim behind"
[[ "$out" != *"iteration 1"* ]] || fail "the refusal must happen before any actuation"

# The documented override is an operator accepting the risk, not a bypass that
# hides it: the loop runs, and the warning is on the record.
rc=0
out="$(env_common SINGULAR_TEST_PROCESS_CONTROL=1 SINGULAR_TEST_PROCESS_CONTROL_STATE=no-group-kill \
  SINGULAR_ALLOW_DEGRADED_KILL=1 SINGULAR_RECONCILE_SCRIPT="$stub" SINGULAR_SLEEP=1 \
  bash "$SCRIPT_DIR/autonomate.sh" --once 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "the documented override must let the loop start (rc=$rc): $out"
assert_contains "$out" "iteration 1" "the override reaches the actuation cycle"
assert_contains "$out" "SINGULAR_ALLOW_DEGRADED_KILL=1" "the override is warned about"
grep -q '"type":"autonomate.preflight_degraded_override"' "$root/.singular-state/events.ndjson" \
  || fail "the accepted risk must be on the event stream"

# No seam: this host is process-capable, the real probe says so, and the gate is
# invisible to every case above.
state="$(env_common bash -c "source '$SCRIPT_DIR/lib.sh'; singular_process_control_preflight")"
[[ "$state" == "ok" ]] || fail "the real preflight probe must pass here (got '$state')"
rc=0
out="$(env_common SINGULAR_RECONCILE_SCRIPT="$stub" SINGULAR_SLEEP=1 \
  bash "$SCRIPT_DIR/autonomate.sh" --once 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "an ungated host must actuate normally (rc=$rc): $out"
assert_contains "$out" "iteration 1" "the ungated loop runs its iteration"
[[ "$out" != *"REFUSING to start"* ]] || fail "a process-capable host must not be gated"

echo "PASS: test-autonomate-lifecycle"
