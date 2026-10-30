#!/usr/bin/env bash
set -euo pipefail

# Operator commands wait for the origin lock (0.23.7), allowing intervention
# while loop cycles repeatedly take the lock. The "loop" here is a shell
# holding the real lock; no provider.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-origin-lock-wait.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2' in: $1"; }

tmp="$(mktemp -d)"
pids=()
cleanup() { local p; for p in "${pids[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done; rm -rf "$tmp"; }
trap cleanup EXIT
root="$tmp/repo"
mkdir -p "$root/docs/orchestration/tasks" "$root/.singular-state"
git -C "$root" init -q
git -C "$root" checkout -q -b target
task() {
  cat >"$root/docs/orchestration/tasks/$1.md" <<TASK
# $1: lock fixture

Status: blocked
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

- \`src/$1.txt\`

## Acceptance Criteria

- The gate command passes.
TASK
}
for t in TASK-0001 TASK-0002 TASK-0003 TASK-0004 TASK-0005; do task "$t"; done
git -C "$root" add . && git -C "$root" -c user.name=t -c user.email=t@t commit -q -m init

fx() {
  env SINGULAR_ROOT="$root" SINGULAR_STATE_DIR="$root/.singular-state" \
    SINGULAR_ORCH_DIR="$root/docs/orchestration" SINGULAR_TASKS_DIR="$root/docs/orchestration/tasks" \
    SINGULAR_LEASES_DIR="$root/.singular-state/leases" SINGULAR_WORKTREES_DIR="$root/.worktrees" \
    SINGULAR_DISPATCH_DIR="$root/.singular-state/dispatch" \
    SINGULAR_EVENTS_FILE="$root/.singular-state/events.ndjson" SINGULAR_TARGET_BRANCH=target "$@"
}
status() { fx bash -c "source '$SCRIPT_DIR/lib.sh'; singular_task_status '$root/docs/orchestration/tasks/$1.md'"; }
events() { grep -c "\"type\":\"$1\"" "$root/.singular-state/events.ndjson" 2>/dev/null || true; }

# A "loop cycle": takes the real origin lock, holds it, releases it.
# hold <seconds> -> returns once the lock is held; the holder runs on.
hold() {
  rm -f "$tmp/held"
  fx bash -c "source '$SCRIPT_DIR/lib.sh'; singular_acquire_lock RUN-HOLD >/dev/null 2>&1 || exit 9
    : >'$tmp/held'; sleep $1; singular_release_lock RUN-HOLD" &
  pids+=("$!")
  local n=0
  until [[ -f "$tmp/held" ]]; do sleep 0.05; n=$((n + 1)); [[ "$n" -lt 400 ]] || fail "holder never took the lock"; done
}
settle() { wait "${pids[@]}" 2>/dev/null || true; pids=(); }

# --- 1. SINGULAR_LOCK_WAIT_SEC=0 keeps the fail-fast behaviour -----------------
hold 3
start=$SECONDS; rc=0
out="$(fx SINGULAR_LOCK_WAIT_SEC=0 bash "$SCRIPT_DIR/ops.sh" unpark TASK-0001 2>&1)" || rc=$?
assert_eq "$rc" "2" "fail-fast: busy lock is an error"
assert_contains "$out" "origin lock busy" "fail-fast: message unchanged"
assert_not_contains "$out" "waiting for the loop" "fail-fast: no wait line"
[[ $((SECONDS - start)) -le 2 ]] || fail "fail-fast took $((SECONDS - start))s"
assert_eq "$(status TASK-0001)" "blocked" "fail-fast: nothing changed"
settle
echo "ok: SINGULAR_LOCK_WAIT_SEC=0 fails fast as before"

# --- 2. default: the verb waits for the cycle to end, says so once, succeeds ---
before_skips="$(events origin.lock_skipped)"
hold 3
rc=0
out="$(fx bash "$SCRIPT_DIR/ops.sh" unpark TASK-0001 2>&1)" || rc=$?
assert_eq "$rc" "0" "the verb waited and ran ($out)"
assert_eq "$(status TASK-0001)" "ready" "the task was unparked after the wait"
assert_eq "$(grep -c "waiting for the loop's lock" <<<"$out")" "1" "exactly one waiting line"
assert_contains "$out" "unpark: waiting for the loop's lock… (up to 120s" "the line names the verb and the default bound"
assert_eq "$(events origin.lock_skipped)" "$before_skips" "waiting does not write one event per probe"
[[ -z "$(ls "$root/.singular-state/locks/origin.waiters" 2>/dev/null)" ]] || fail "a waiter marker was left behind"
settle
echo "ok: an operator verb waits for the loop's lock by default"

# --- 3. the wait is bounded: --wait=SECONDS, and a clear timeout ---------------
hold 6
start=$SECONDS; rc=0
out="$(fx bash "$SCRIPT_DIR/ops.sh" unpark TASK-0002 --wait=1 2>&1)" || rc=$?
elapsed=$((SECONDS - start))
assert_eq "$rc" "2" "a wait that runs out is an error"
assert_contains "$out" "the loop still holds the origin lock after 1s" "the timeout says what happened"
assert_contains "$out" "origin lock busy" "the verb's own busy message is kept"
[[ "$elapsed" -ge 1 && "$elapsed" -le 4 ]] || fail "--wait=1 waited ${elapsed}s"
assert_eq "$(status TASK-0002)" "blocked" "timeout: nothing changed"
assert_eq "$(events origin.lock_wait_timeout)" "1" "one timeout event"
[[ -z "$(ls "$root/.singular-state/locks/origin.waiters" 2>/dev/null)" ]] || fail "timeout left a waiter marker"
# --no-wait and SINGULAR_LOCK_WAIT_SEC behave the same way; a bad value is usage.
rc=0; out="$(fx bash "$SCRIPT_DIR/ops.sh" unpark TASK-0002 --no-wait 2>&1)" || rc=$?
assert_eq "$rc" "2" "--no-wait fails fast"
assert_not_contains "$out" "waiting for the loop" "--no-wait does not wait"
rc=0; out="$(fx bash "$SCRIPT_DIR/ops.sh" unpark TASK-0002 --wait=soon 2>&1)" || rc=$?
assert_eq "$rc" "2" "a malformed --wait is rejected"
assert_contains "$out" "--wait takes whole seconds" "and explained"
rc=0; out="$(fx SINGULAR_LOCK_WAIT_SEC=30 bash "$SCRIPT_DIR/ops.sh" supersede TASK-0003 --reason fixture 2>&1)" || rc=$?
assert_eq "$rc" "0" "supersede waits too, with the env bound ($out)"
assert_contains "$out" "supersede: waiting for the loop's lock… (up to 30s" "supersede names itself and the env bound"
settle
echo "ok: the wait is bounded and configurable"

# --- 4. a loop that never naps still lets the operator in at a cycle boundary --
# Twelve back-to-back cycles with no gap between them: without the loop
# yielding, a 0.5s poll has to land in a window of a few milliseconds.
fx bash -c "source '$SCRIPT_DIR/lib.sh'
  for i in \$(seq 1 12); do
    singular_origin_lock_yield_to_waiters || true
    singular_acquire_lock RUN-LOOP-\$i >/dev/null 2>&1 || { sleep 0.2; continue; }
    : >'$tmp/loop-running'
    sleep 0.7
    singular_release_lock RUN-LOOP-\$i
  done" 2>"$tmp/loop.err" &
pids+=("$!"); loop_pid=$!
n=0; until [[ -f "$tmp/loop-running" ]]; do sleep 0.05; n=$((n + 1)); [[ "$n" -lt 400 ]] || fail "loop never started"; done
start=$SECONDS; rc=0
out="$(fx bash "$SCRIPT_DIR/ops.sh" unpark TASK-0004 --wait=20 2>&1)" || rc=$?
elapsed=$((SECONDS - start))
assert_eq "$rc" "0" "the operator got the lock from a loop with no idle gap ($out)"
assert_eq "$(status TASK-0004)" "ready" "and its command ran"
[[ "$elapsed" -le 6 ]] || fail "the operator waited ${elapsed}s; it should get in at the next cycle boundary"
kill -0 "$loop_pid" 2>/dev/null || fail "the loop should still be cycling when the operator is done"
settle
assert_eq "$(events origin.lock_yielded)" "1" "the loop records that it yielded, once"
assert_contains "$(cat "$tmp/loop.err")" "waited for a queued operator command" "the loop log says so"
echo "ok: a cycle boundary lets a queued operator command in"

# --- 5. nobody waiting: the loop's boundary costs nothing and stays silent -----
before="$(events origin.lock_yielded)"
start=$SECONDS
fx bash -c "source '$SCRIPT_DIR/lib.sh'; singular_origin_lock_yield_to_waiters" 2>"$tmp/idle.err"
[[ $((SECONDS - start)) -le 1 ]] || fail "an idle yield check took $((SECONDS - start))s"
assert_eq "$(events origin.lock_yielded)" "$before" "no yield event without a waiter"
[[ ! -s "$tmp/idle.err" ]] || fail "idle yield printed: $(cat "$tmp/idle.err")"
# A marker left by a dead process is discarded, not obeyed.
mkdir -p "$root/.singular-state/locks/origin.waiters"
printf '99999999\nunpark\n0\n' >"$root/.singular-state/locks/origin.waiters/99999999.waiter"
start=$SECONDS
fx bash -c "source '$SCRIPT_DIR/lib.sh'; singular_origin_lock_yield_to_waiters" 2>/dev/null
[[ $((SECONDS - start)) -le 1 ]] || fail "a stale waiter marker held the loop"
[[ ! -e "$root/.singular-state/locks/origin.waiters/99999999.waiter" ]] || fail "the stale waiter marker was not removed"
echo "ok: with nobody waiting the loop does not pause"

# --- 6. integrate (operator invocation) waits as well --------------------------
grep -q 'singular_acquire_lock_wait "$run_id" "integrate"' "$SCRIPT_DIR/integrate.sh" \
  || fail "integrate does not wait for the origin lock"
hold 3
rc=0
out="$(fx SINGULAR_PUSH=0 bash "$SCRIPT_DIR/integrate.sh" --task TASK-0005 --wait=30 2>&1)" || rc=$?
assert_contains "$out" "integrate: waiting for the loop's lock… (up to 30s" "integrate --task waits"
assert_not_contains "$out" "active origin lock exists" "integrate does not fail on the busy lock"
settle
echo "PASS: test-origin-lock-wait"
