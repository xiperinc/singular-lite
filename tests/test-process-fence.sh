#!/usr/bin/env bash
set -uo pipefail
# Process-group fence: producer and exit verb, which ship together.
#
# reconcile's bind-failure cleanup killed a bare $dispatch_pid. In detached mode
# the child has already setsid into its own session, so provider grandchildren
# survived and kept writing the candidate while the reservation was marked
# failed. singular_dispatch_tree_alive cannot close that gap: it does not
# establish absence (it does not even check the exit status of its `ps`).
#
# The fence is PID-keyed on purpose. singular_kill_dispatch_pgroup reads the
# dispatch record -- and at the bind-failure site the record write is exactly
# what failed, so it returns 1 at its [[ -f "$record" ]] guard and cannot act.
# singular_kill_tree takes the pid and resolves the group through a LIVE
# os.getpgid(), instead of comparing two integers read from the same JSON file.
#
# Termination is delivery, not absence. quarantined -> parked requires PROVEN
# absence (ProcessLookupError). EPERM means a process exists that cannot be
# queried, and a getpgid that SUCCEEDS proves nothing either, because a recycled
# leader pid makes an unrelated process answer. Both stay quarantined.
#
# A fence that can produce a state nothing can clear would reintroduce the bug
# class this sequence exists to remove, so `singular fence` is the exit.
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-process-fence.sh requires bash >= 4" >&2; exit 1
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

write_record() {
  local tid="$1" pid="$2"
  local record; record="$(singular_dispatch_record_path "$tid")"
  mkdir -p "$(dirname "$record")"
  cat >"$record" <<JSON
{"taskId":"$tid","runId":"RUN-F","pid":$pid,"pidStart":"x","pgid":$pid,
 "baseSha":"b","batchId":"B","state":"launched",
 "reservationOwner":"o","reservationGeneration":1,"campaignBinding":"legacy"}
JSON
}
fence() { "$SCRIPT_DIR/fence.sh" "$@" 2>&1; }

# Name the absence explicitly: without this the assertions below fail on empty
# output and the reason is a bare exit 127.
[[ -x "$SCRIPT_DIR/fence.sh" ]] \
  || fail "engine/fence.sh does not exist; a quarantined dispatch has no engine-executable exit"

# --- 1. alive: a live session leader is observed, not assumed dead -----------
setsid_leader() {
  python3 -c 'import os,sys,time
os.setsid()
sys.stdout.write(str(os.getpid()) + "\n"); sys.stdout.flush()
time.sleep(60)' &
  sleep 0.5
}
setsid_leader
leader=$!
write_record TASK-7001 "$leader"
out="$(fence TASK-7001 --observe-only)"
[[ "$out" == *"observed alive"* ]] || fail "a live leader was not observed alive: $out"
pass "a live process group is observed alive, never assumed absent"

# --- 2. dead: proven absence parks -------------------------------------------
kill -9 "$leader" 2>/dev/null || true
wait "$leader" 2>/dev/null || true
out="$(fence TASK-7001)"
rc=$?
[[ "$out" == *"observed dead"* ]] || fail "a reaped leader was not observed dead: $out"
[[ "$out" == *"parked"* ]] || fail "proven absence did not park: $out"
[[ "$rc" == 0 ]] || fail "parking did not exit 0 (got $rc)"
python3 - "$(singular_dispatch_record_path TASK-7001)" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
f = d.get("fence") or {}
assert f.get("state") == "parked", f
assert f.get("observation") == "dead", f
assert f.get("reason") == "proven-absent", f
PY
pass "a provably absent group transitions quarantined -> parked"

# --- 3. unknown: EPERM must NOT transition -----------------------------------
# pid 1 exists and cannot be signalled or queried by an unprivileged user on
# macOS; it stands in for "a process is there but cannot be proven ours".
# pid 1 is only ever OBSERVED here, never signalled: the non-observe path is
# not run against a process this test did not spawn.
write_record TASK-7002 1
out="$(fence TASK-7002 --observe-only)"
if [[ "$out" == *"observed dead"* ]]; then
  fail "an unqueryable process was reported as provably absent: $out"
fi
[[ "$out" == *"observed alive"* || "$out" == *"observed unknown"* ]] \
  || fail "unexpected observation for an unqueryable pid: $out"
pass "an unqueryable process is never reported as provably absent"

# --- 4. unknown: a pid that answers is not proof it is OURS ------------------
# Checked at source level, deliberately. Exercising this end to end would mean
# running the kill path against a process this test did not spawn, which is
# exactly the thing the fence exists to avoid doing carelessly. The invariant is
# that `parked` is reachable ONLY from a proven-absent observation.
python3 - "$SCRIPT_DIR/fence.sh" <<'PY' || exit 1
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
assert 'fence_state="quarantined"' in src, "quarantined is not the default state"
m = re.search(r'fence_state="quarantined"\s*\n\s*(.+)', src)
promote = m.group(1).strip()
assert promote == '[[ "$state" == "dead" ]] && fence_state="parked"', \
    "parked is reachable from something other than a proven-absent observation: " + promote
# A kill that did not prove the group must not leave the state at dead.
assert 'group-unproven-' in src, "an unproven group kill is treated as absence"
# EPERM and any other errno map to unknown, never to dead.
assert 'print("unknown eperm-process-exists")' in src, "EPERM is not mapped to unknown"
assert re.search(r'except OSError as exc:\s*\n\s*print\(f"unknown errno', src), \
    "a non-ProcessLookupError errno is not mapped to unknown"
# Only ProcessLookupError yields dead.
assert src.count('print("dead ') == 1, "more than one route produces a dead observation"
assert re.search(r'except ProcessLookupError:\s*\n\s*print\("dead proven-absent"\)', src), \
    "dead is not gated on ProcessLookupError"
PY
pass "parked is reachable only from proven absence; EPERM and other errnos stay unknown"

# --- 4b. a quarantined fence exits 3, keeps the fence, and names the exit ----
# Source level: fabricating a genuinely unprovable pid at runtime would mean
# signalling a process this test does not own. (A pid that never existed is
# PROVABLY absent and correctly parks -- that is case 2, not this one.)
python3 - "$SCRIPT_DIR/fence.sh" <<'PY' || exit 1
import sys
src = open(sys.argv[1], encoding="utf-8").read()
tail = src[src.index('if [[ "$fence_state" == "parked" ]]'):]
assert "exit 0" in tail, "parked does not exit 0"
assert "exit 3" in tail, "quarantined does not exit 3"
assert "stays quarantined" in tail, "quarantine is not reported"
assert "the resource fence is retained" in tail, "the resource fence is not retained"
assert "singular fence" in tail, "quarantined names no engine-executable exit"
PY
pass "a quarantined fence exits 3, retains the resource fence and names its exit verb"

# --- 5. every state the fence produces has an engine-executable exit ---------
grep -q 'fence)' "$ROOT/cli/singular" || fail "singular fence is not a public verb"
[[ -x "$SCRIPT_DIR/fence.sh" ]] || fail "fence.sh is not executable"
# The producer must hand over a next action rather than a dead end.
grep -q 'singular fence \$tid' "$SCRIPT_DIR/reconcile.sh" \
  || fail "the bind-failure producer names no exit verb"
grep -q 'singular_kill_tree "\$dispatch_pid"' "$SCRIPT_DIR/reconcile.sh" \
  || fail "the bind-failure cleanup still kills a bare pid"
python3 - "$SCRIPT_DIR/reconcile.sh" <<'PY' || exit 1
import sys
src = open(sys.argv[1], encoding="utf-8").read()
assert 'kill "$dispatch_pid"' not in src, "a bare single-pid kill survives in reconcile"
PY
pass "quarantined has a public exit verb and the producer names it"

# --- 6. Q-OPEN-2: the session-leader outcome is recorded at bind -------------
setsid_leader
leader2=$!
singular_lifecycle_dispatch_record_write TASK-7003 RUN-F "$leader2" x "$tmp/l.log" b B o 1 >/dev/null
python3 - "$(singular_dispatch_record_path TASK-7003)" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert "sessionLeader" in d, "bind did not record whether setsid succeeded"
PY
kill -9 "$leader2" 2>/dev/null || true; wait "$leader2" 2>/dev/null || true
pass "the session-leader outcome is recorded at bind, not inferred later"

echo "test-process-fence: ok"
