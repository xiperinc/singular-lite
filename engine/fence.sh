#!/usr/bin/env bash
set -uo pipefail
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -n "${SINGULAR_BASH_BIN:-}" ]]; then
    [[ "$SINGULAR_BASH_BIN" == /* && -x "$SINGULAR_BASH_BIN" ]] || { echo "invalid SINGULAR_BASH_BIN" >&2; exit 2; }
    exec "$SINGULAR_BASH_BIN" "$0" "$@"
  fi
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "fence.sh requires bash >= 4" >&2; exit 1
fi

# `singular fence TASK-XXXX` -- the engine-executable exit from a quarantined
# dispatch, and the answer to Q-OPEN-1 in claudedocs/design-pgid-fencing.md.
#
# A fence that can produce `quarantined` with no way out reintroduces the bug
# class this whole sequence exists to remove, so the producer (reconcile's
# bind-failure cleanup) and this verb ship together.
#
# Semantics, in order:
#   1. Terminate via singular_kill_tree with the recorded leader PID and the
#      `session` claim. PID-keyed, not pgid-keyed: the helper resolves the group
#      itself through a LIVE os.getpgid(), whereas the record-keyed helper
#      compares two integers read from the same JSON file and proves nothing.
#   2. Re-observe afterwards. A successful kill is delivery, not absence.
#   3. quarantined -> parked ONLY on proven absence: os.getpgid(leader) raising
#      ProcessLookupError/ESRCH.
#   4. Anything else stays quarantined with the resource fence retained and a
#      machine-readable reason. `unknown` includes EPERM (a process exists that
#      cannot be queried), any other errno, a non-zero ps exit, kill_tree
#      reporting `group-asserted` or `tree` rather than `group-proven`, and a
#      getpgid that SUCCEEDS -- because a recycled leader PID makes an unrelated
#      process answer, and that is indistinguishable from our own.
#   5. `parked` is safe for re-dispatch or manual intervention.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/lifecycle.sh"

task_id="${1:-}"
observe_only=no
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --observe-only) observe_only=yes; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$task_id" ]] || { echo "usage: singular fence TASK-XXXX [--observe-only]" >&2; exit 2; }

record="$(singular_dispatch_record_path "$task_id")"
[[ -f "$record" ]] || { echo "fence: no dispatch record for $task_id" >&2; exit 2; }

leader_pid="$(singular_json_field "$record" pid 2>/dev/null || true)"
generation="$(singular_json_field "$record" reservationGeneration 2>/dev/null || true)"
owner="$(singular_json_field "$record" reservationOwner 2>/dev/null || true)"
[[ "$leader_pid" =~ ^[1-9][0-9]*$ ]] \
  || { echo "fence: dispatch record for $task_id has no usable leader pid" >&2; exit 2; }

# Tri-state observation of the recorded leader. Never collapses `unknown` into
# `dead`: absence must be proven, not assumed from a failure to look.
observe() {
  python3 - "$1" <<'PY'
import errno
import os
import sys

try:
    pid = int(sys.argv[1])
except ValueError:
    print("unknown no-usable-pid")
    raise SystemExit(0)
try:
    os.getpgid(pid)
except ProcessLookupError:
    print("dead proven-absent")
except PermissionError:
    # A process exists under that pid; it just cannot be queried.
    print("unknown eperm-process-exists")
except OSError as exc:
    print(f"unknown errno-{exc.errno or 'unspecified'}")
else:
    print("alive leader-answers")
PY
}

read -r state reason <<<"$(observe "$leader_pid")"
echo "fence: $task_id observed $state ($reason)"

if [[ "$observe_only" == yes ]]; then
  echo "state=$state"; echo "reason=$reason"
  exit 0
fi

kill_mode="not-attempted"
if [[ "$state" == "alive" ]]; then
  singular_kill_tree "$leader_pid" "$(singular_kill_grace_sec 2>/dev/null || echo 5)" session
  kill_mode="${SINGULAR_KILL_TREE_MODE:-unknown}"
  echo "fence: kill_tree mode=$kill_mode result=${SINGULAR_KILL_TREE_RESULT:-unknown}"
  # Delivery is not absence: re-observe rather than trusting the signal.
  read -r state reason <<<"$(observe "$leader_pid")"
  echo "fence: $task_id re-observed $state ($reason)"
  if [[ "$state" == dead && "$kill_mode" != "group-proven" ]]; then
    # The leader is gone but the group was never proven, so descendants may have
    # escaped the signal. Absence of the leader is not absence of the group.
    state="unknown"; reason="group-unproven-$kill_mode"
  fi
fi

fence_state="quarantined"
[[ "$state" == "dead" ]] && fence_state="parked"

python3 - "$record" "$fence_state" "$state" "$reason" "$kill_mode" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

path, fence_state, observation, reason, kill_mode = sys.argv[1:6]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
data["fence"] = {
    "state": fence_state,
    "observation": observation,
    "reason": reason,
    "killMode": kill_mode,
    "observedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
os.replace(tmp, path)
PY

singular_append_event "dispatch.fenced" "process-group fence applied" \
  "{\"taskId\":\"$task_id\",\"leaderPid\":$leader_pid,\"reservationOwner\":\"$owner\",\"reservationGeneration\":\"$generation\",\"fenceState\":\"$fence_state\",\"observation\":\"$state\",\"reason\":\"$reason\",\"killMode\":\"$kill_mode\"}" \
  2>/dev/null || true

if [[ "$fence_state" == "parked" ]]; then
  echo "fence: $task_id parked; the recorded process group is provably absent and the task is safe to re-dispatch"
  exit 0
fi
echo "fence: $task_id stays quarantined ($reason); the resource fence is retained" >&2
echo "fence: re-run 'singular fence $task_id' once the condition clears" >&2
exit 3
