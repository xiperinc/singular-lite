#!/usr/bin/env bash
# Covers singular_kill_tree, singular_setsid_exec and singular_session_record_write
# in engine/lib.sh.
#
# Field failure: in a sandbox that denies `ps`, a timed-out run killed
# its direct child and the DESCENDANT survived. The 0.16 kill built its target
# list solely from `ps -A -o pid= -o ppid=`, ignored that command's return code,
# and wrapped the whole interpreter in `2>/dev/null || true` — so a denied
# enumeration was indistinguishable from a childless process, and the failure was
# invisible. Cleanup reported success while a provider kept writing to a
# worktree.
#
# Every case here therefore denies `ps`. The two that matter most also deny
# os.getpgid on other pids (c1b), which is the shape of the restricted sandbox
# from the field report: there the caller's own `session` claim is the only
# remaining containment proof.
#
# NOTE: bash announces the death of the background jobs these cases kill
# ("Killed: 9" / "Terminated:" lines on stderr). That is this shell's job reaper
# reporting a job it started, not a test failure — a real session leader has to
# be a background job of this shell for the un-reaped-pid guarantee to hold.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  echo "SKIP: test-kill-tree needs bash >= 4 (found ${BASH_VERSION:-unknown})" >&2
  exit 0
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp="$(mktemp -d)"
# Backstop only: every case cleans up after itself, but a case that fails
# mid-flight must not leak a 60s sleep into the host.
_pids=()
cleanup() {
  local p
  for p in ${_pids[@]+"${_pids[@]}"}; do
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    kill -KILL "$p" 2>/dev/null || true
  done
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# The engine writes its events into $SINGULAR_STATE_DIR, and the degraded path of
# singular_kill_tree has to land a kill.unverified event there.
export SINGULAR_ROOT="$tmp/root"
export SINGULAR_STATE_DIR="$tmp/root/.singular-state"
export SINGULAR_EVENTS_FILE="$tmp/root/.singular-state/events.ndjson"
mkdir -p "$SINGULAR_STATE_DIR"
# shellcheck source=/dev/null
source "$ENGINE_HOME/engine/lib.sh"

# --- sandbox stubs ------------------------------------------------------------
# python's subprocess.run(["ps", ...]) resolves through PATH, so a stub is enough
# to reproduce the denial without any privileges.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/ps" <<'SH'
#!/usr/bin/env bash
echo 'ps: operation not permitted' >&2
exit 1
SH
chmod +x "$tmp/bin/ps"

# sitecustomize is imported at interpreter startup, so this denies os.getpgid on
# every pid but the caller's own group — the introspection half of the sandbox.
mkdir -p "$tmp/pyshim"
cat >"$tmp/pyshim/sitecustomize.py" <<'PY'
import os

_real = os.getpgid


def _denied(pid):
    if pid == 0 or pid == os.getpid():
        return _real(pid)
    raise PermissionError(1, "Operation not permitted")


os.getpgid = _denied
PY

with_sandbox() {
  # args: ps|ps+getpgid command...   PATH/PYTHONPATH are restored afterwards so
  # a `VAR=x func` prefix cannot leak the stubs into later cases (bash keeps
  # those assignments after a *function* returns).
  local kind="$1"; shift
  local saved_path="$PATH" saved_pp="${PYTHONPATH:-}" had_pp="${PYTHONPATH+set}" rc=0
  PATH="$tmp/bin:$PATH"
  if [[ "$kind" == "ps+getpgid" ]]; then
    export PYTHONPATH="$tmp/pyshim${saved_pp:+:$saved_pp}"
  fi
  "$@" || rc=$?
  PATH="$saved_path"
  if [[ -n "$had_pp" ]]; then export PYTHONPATH="$saved_pp"; else unset PYTHONPATH; fi
  return "$rc"
}

# --- fixtures -----------------------------------------------------------------
# A root that owns exactly one descendant and then waits, so "the descendant
# survived" is observable. `ignore-term` makes that descendant survive SIGTERM,
# which is what forces the KILL escalation.
cat >"$tmp/leader.sh" <<'SH'
#!/usr/bin/env bash
if [[ "${2:-plain}" == "ignore-term" ]]; then
  bash -c 'trap "" TERM; sleep 60' &
else
  sleep 60 &
fi
child=$!
printf '%s\n' "$child" >"$1"
wait "$child"
SH
chmod +x "$tmp/leader.sh"

# The last command of a background job, so $! is the session leader itself.
spawn_session() { singular_setsid_exec "$tmp/leader.sh" "$1" "${2:-plain}"; }

await_pidfile() {
  local f="$1" i
  for i in $(seq 1 100); do
    if [[ -s "$f" ]]; then tr -d '[:space:]' <"$f"; return 0; fi
    sleep 0.1
  done
  fail "no descendant pid ever appeared in $f"
}

dead_within() {
  # rc 0 once every pid is gone. A zombie still answers `kill -0`, so this also
  # waits out bash's reaper rather than racing it.
  local deadline=$((SECONDS + 6)) p gone
  while (( SECONDS < deadline )); do
    gone=1
    for p in "$@"; do
      if kill -0 "$p" 2>/dev/null; then gone=0; break; fi
    done
    (( gone == 1 )) && return 0
    sleep 0.2
  done
  return 1
}

json_field() {
  python3 -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1])).get(sys.argv[2])))' \
    "$1" "$2"
}

# --- c1: a proven session survives a denied `ps` ------------------------------
# The exact field case: descendant enumeration is impossible, and the kill must
# still take the whole tree down AND still call itself verified, because the
# process group is a stronger proof than the enumeration ever was.
rm -f "$tmp/c1.child"
spawn_session "$tmp/c1.child" & c1_leader=$!
_pids+=("$c1_leader")
c1_child="$(await_pidfile "$tmp/c1.child")"
_pids+=("$c1_child")
with_sandbox ps singular_kill_tree "$c1_leader" 0 session 2>"$tmp/c1.err"
[[ "$SINGULAR_KILL_TREE_MODE" == group-* ]] \
  || fail "c1: want a group mode, got '$SINGULAR_KILL_TREE_MODE'"
[[ "$SINGULAR_KILL_TREE_RESULT" == "verified" ]] \
  || fail "c1: result=$SINGULAR_KILL_TREE_RESULT reason=$SINGULAR_KILL_TREE_REASON"
! grep -q 'UNVERIFIED' "$tmp/c1.err" \
  || fail "c1: reported UNVERIFIED with the group proven"
dead_within "$c1_leader" "$c1_child" \
  || fail "c1: the descendant survived a ps-denied kill"
# A verified group kill that could not enumerate says so informationally, and
# must NOT have degraded.
grep -q '"type":"kill.enumeration_unavailable"' "$SINGULAR_EVENTS_FILE" \
  || fail "c1: no kill.enumeration_unavailable event"
! grep -q '"type":"kill.unverified"' "$SINGULAR_EVENTS_FILE" \
  || fail "c1: a verified group kill must not emit kill.unverified"

# --- c1b: the caller's `session` claim is what unlocks the group kill ---------
# Same sandbox, but os.getpgid is denied too, so nothing about the pid can be
# proven from outside. With the claim the group is signalled; without it the
# kill must refuse to touch a negative pid and report itself degraded instead.
rm -f "$tmp/c1b.child"
spawn_session "$tmp/c1b.child" & c1b_leader=$!
_pids+=("$c1b_leader")
c1b_child="$(await_pidfile "$tmp/c1b.child")"
_pids+=("$c1b_child")
with_sandbox ps+getpgid singular_kill_tree "$c1b_leader" 0 session 2>"$tmp/c1b.err"
[[ "$SINGULAR_KILL_TREE_MODE" == "group-asserted" ]] \
  || fail "c1b: want group-asserted, got '$SINGULAR_KILL_TREE_MODE'"
[[ "$SINGULAR_KILL_TREE_RESULT" == "verified" ]] \
  || fail "c1b: result=$SINGULAR_KILL_TREE_RESULT reason=$SINGULAR_KILL_TREE_REASON"
dead_within "$c1b_leader" "$c1b_child" \
  || fail "c1b: the asserted group kill left the descendant alive"

rm -f "$tmp/c1c.child"
spawn_session "$tmp/c1c.child" & c1c_leader=$!
_pids+=("$c1c_leader")
c1c_child="$(await_pidfile "$tmp/c1c.child")"
_pids+=("$c1c_child")
with_sandbox ps+getpgid singular_kill_tree "$c1c_leader" 0 2>"$tmp/c1c.err"
[[ "$SINGULAR_KILL_TREE_MODE" == "tree" ]] \
  || fail "c1c: an unclaimed pid must not be treated as a group (got '$SINGULAR_KILL_TREE_MODE')"
[[ "$SINGULAR_KILL_TREE_RESULT" == "degraded" ]] \
  || fail "c1c: an unprovable tree must report degraded"
dead_within "$c1c_leader" || fail "c1c: the root itself must still die"

# --- c2: a TERM-ignoring descendant is escalated to KILL ----------------------
rm -f "$tmp/c2.child"
spawn_session "$tmp/c2.child" ignore-term & c2_leader=$!
_pids+=("$c2_leader")
c2_child="$(await_pidfile "$tmp/c2.child")"
_pids+=("$c2_child")
with_sandbox ps singular_kill_tree "$c2_leader" 1 session 2>"$tmp/c2.err"
[[ "$SINGULAR_KILL_TREE_RESULT" == "verified" ]] \
  || fail "c2: result=$SINGULAR_KILL_TREE_RESULT reason=$SINGULAR_KILL_TREE_REASON"
dead_within "$c2_leader" "$c2_child" \
  || fail "c2: a TERM-ignoring descendant must be SIGKILLed after the grace"

# --- c3: nothing outside the target is ever signalled -------------------------
# Two independent sessions; killing one must not disturb the other.
rm -f "$tmp/c3v.child" "$tmp/c3b.child"
spawn_session "$tmp/c3v.child" & c3_victim=$!
_pids+=("$c3_victim")
c3_victim_child="$(await_pidfile "$tmp/c3v.child")"
_pids+=("$c3_victim_child")
spawn_session "$tmp/c3b.child" & c3_bystander=$!
_pids+=("$c3_bystander")
c3_bystander_child="$(await_pidfile "$tmp/c3b.child")"
_pids+=("$c3_bystander_child")
with_sandbox ps singular_kill_tree "$c3_victim" 0 session 2>"$tmp/c3.err"
dead_within "$c3_victim" "$c3_victim_child" || fail "c3: the targeted session survived"
kill -0 "$c3_bystander" 2>/dev/null || fail "c3: an unrelated session leader was signalled"
kill -0 "$c3_bystander_child" 2>/dev/null \
  || fail "c3: an unrelated session's descendant was signalled"
singular_kill_tree "$c3_bystander" 0 session 2>/dev/null
dead_within "$c3_bystander" "$c3_bystander_child" || fail "c3: bystander cleanup failed"

# A pid that is NOT a session leader must fall back to the tree walk. If it were
# treated as a group id, `kill -0 -<pgid>` would hit this test's own group: the
# sibling below (and this script) still running is the assertion.
sleep 30 & c3_sibling=$!
_pids+=("$c3_sibling")
sleep 60 & c3_plain=$!
_pids+=("$c3_plain")
with_sandbox ps singular_kill_tree "$c3_plain" 0 session 2>"$tmp/c3b.err"
[[ "$SINGULAR_KILL_TREE_MODE" == "tree" ]] \
  || fail "c3: a non-leader pid must resolve to tree mode (got '$SINGULAR_KILL_TREE_MODE')"
[[ "$SINGULAR_KILL_TREE_RESULT" == "degraded" ]] \
  || fail "c3: a ps-denied tree kill must report degraded"
dead_within "$c3_plain" || fail "c3: the targeted plain child survived"
kill -0 "$c3_sibling" 2>/dev/null || fail "c3: this test's own process group was signalled"
kill -KILL "$c3_sibling" 2>/dev/null || true

# --- c4: an unprovable cleanup is reported, not swallowed ---------------------
# No session, no enumeration: the descendant genuinely can outlive the root, and
# the whole point of the fix is that the caller is told so.
: >"$SINGULAR_EVENTS_FILE"
rm -f "$tmp/c4.child"
"$tmp/leader.sh" "$tmp/c4.child" & c4_root=$!
_pids+=("$c4_root")
c4_child="$(await_pidfile "$tmp/c4.child")"
_pids+=("$c4_child")
with_sandbox ps singular_kill_tree "$c4_root" 0 2>"$tmp/c4.err"
dead_within "$c4_root" || fail "c4: the root itself must still die"
[[ "$SINGULAR_KILL_TREE_RESULT" == "degraded" ]] \
  || fail "c4: result=$SINGULAR_KILL_TREE_RESULT (want degraded)"
[[ "$SINGULAR_KILL_TREE_REASON" == "enumeration-unavailable" ]] \
  || fail "c4: reason=$SINGULAR_KILL_TREE_REASON (want enumeration-unavailable)"
grep -q 'UNVERIFIED' "$tmp/c4.err" || fail "c4: no UNVERIFIED warning on stderr"
grep -q '"type":"kill.unverified"' "$SINGULAR_EVENTS_FILE" \
  || fail "c4: no kill.unverified event in $SINGULAR_EVENTS_FILE"
kill -KILL "$c4_child" 2>/dev/null || true

# --- c5: the c21 grace contract is unchanged ----------------------------------
# The runners hold their read-only restore guard in an EXIT trap. A grace must
# still run it; a bare kill must still run nothing. (tests/test-readonly-guard.sh
# owns this contract; it is replicated here so a kill-tree change fails in the
# file it broke, and the real suite is re-run below.)
cat >"$tmp/trapped.sh" <<'SH'
#!/usr/bin/env bash
cleanup() { printf 'cleaned\n' >"$1"; exit 143; }
trap 'cleanup "$1"' TERM
sleep 30 & child=$!
wait "$child"
SH
chmod +x "$tmp/trapped.sh"

"$tmp/trapped.sh" "$tmp/graceful.marker" & c5_graceful=$!
_pids+=("$c5_graceful")
sleep 1
singular_kill_tree "$c5_graceful" 5
wait "$c5_graceful" 2>/dev/null || true
[[ -f "$tmp/graceful.marker" ]] || fail "c5: a graceful kill must let the EXIT trap run"
[[ "$SINGULAR_KILL_TREE_RESULT" == "verified" ]] \
  || fail "c5: an enumerable tree kill must verify (got $SINGULAR_KILL_TREE_RESULT/$SINGULAR_KILL_TREE_REASON)"

"$tmp/trapped.sh" "$tmp/hard.marker" & c5_hard=$!
_pids+=("$c5_hard")
sleep 1
singular_kill_tree "$c5_hard"
dead_within "$c5_hard" || fail "c5: a bare kill must actually kill"
[[ ! -f "$tmp/hard.marker" ]] || fail "c5: a bare kill must not run handlers"

# The contract's own suite, unmodified. Run with this file's SINGULAR_* unset so
# it builds its fixtures exactly as it does standalone.
env -u SINGULAR_ROOT -u SINGULAR_STATE_DIR -u SINGULAR_EVENTS_FILE \
  bash "$ENGINE_HOME/tests/test-readonly-guard.sh" >"$tmp/readonly.log" 2>&1 \
  || { cat "$tmp/readonly.log" >&2; fail "c5: tests/test-readonly-guard.sh must stay green"; }

# --- c6: the session record proves what it claims -----------------------------
rm -f "$tmp/c6.child"
spawn_session "$tmp/c6.child" & c6_leader=$!
_pids+=("$c6_leader")
c6_child="$(await_pidfile "$tmp/c6.child")"
_pids+=("$c6_child")
singular_session_record_write "$tmp/records/live.json" "$c6_leader"
[[ -f "$tmp/records/live.json" ]] || fail "c6: no record written"
python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$tmp/records/live.json" \
  || fail "c6: the live record is not valid JSON"
[[ "$(json_field "$tmp/records/live.json" pid)" == "$c6_leader" ]] \
  || fail "c6: recorded pid $(json_field "$tmp/records/live.json" pid) != $c6_leader"
[[ "$(json_field "$tmp/records/live.json" pgid)" == "$c6_leader" ]] \
  || fail "c6: a setsid'd child must record pgid == pid"
[[ "$(json_field "$tmp/records/live.json" verified)" == "true" ]] \
  || fail "c6: a proven session leader must record verified true"
[[ "$(json_field "$tmp/records/live.json" sessionSpawn)" == "true" ]] \
  || fail "c6: sessionSpawn must reflect the spawn topology"
[[ "$(json_field "$tmp/records/live.json" startedAt)" == \"20*Z\" ]] \
  || fail "c6: startedAt is not an ISO-8601 Z timestamp"

singular_kill_tree "$c6_leader" 0 session 2>/dev/null
dead_within "$c6_leader" "$c6_child" || fail "c6: cleanup failed"
# A dead pid must still produce a record — an unprovable group is recorded as 0,
# never guessed, and never an error the spawner has to handle.
singular_session_record_write "$tmp/records/dead.json" "$c6_leader"
[[ -f "$tmp/records/dead.json" ]] || fail "c6: no record written for a dead pid"
[[ "$(json_field "$tmp/records/dead.json" pgid)" == "0" ]] \
  || fail "c6: an unresolvable pgid must be recorded as 0"
[[ "$(json_field "$tmp/records/dead.json" verified)" == "false" ]] \
  || fail "c6: an unresolvable pgid must not be recorded as verified"

echo "PASS: test-kill-tree"
