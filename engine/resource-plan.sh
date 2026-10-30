#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# `auto` (the default) sizes the ceiling from the machine; an explicit integer
# keeps the disk-only rule this script has always applied. See
# resource_governor.py for the formula and its constants.
configured="${SINGULAR_MAX_CONCURRENT:-auto}"
reserve="${SINGULAR_DISK_RESERVE_BYTES:-2147483648}"
estimate="${SINGULAR_ESTIMATED_WORKTREE_BYTES:-}"
free_bytes=""
json="no"
# Machine facts. Empty means "probe it"; a flag (or the SINGULAR_RESOURCE_*
# env of the same name) injects the fact so callers and tests are hermetic.
cpu_count=""
available_memory=""
load_1m=""
cpu_busy=""
active_workers=""
active_planners=""
governor_state="${SINGULAR_RESOURCE_GOVERNOR_STATE_FILE:-$SINGULAR_STATE_DIR/resource-governor.json}"
update_state="no"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configured-slots) configured="${2:-}"; shift 2 ;;
    --reserve-bytes) reserve="${2:-}"; shift 2 ;;
    --estimated-worktree-bytes) estimate="${2:-}"; shift 2 ;;
    --free-bytes) free_bytes="${2:-}"; shift 2 ;;
    --cpu-count) cpu_count="${2:-}"; shift 2 ;;
    --available-memory-bytes) available_memory="${2:-}"; shift 2 ;;
    --load-1m) load_1m="${2:-}"; shift 2 ;;
    --cpu-busy) cpu_busy="${2:-}"; shift 2 ;;
    --active-workers) active_workers="${2:-}"; shift 2 ;;
    --active-planners) active_planners="${2:-}"; shift 2 ;;
    --governor-state) governor_state="${2:-}"; shift 2 ;;
    # Only the reconcile cycle records throttle state. health and doctor read
    # the same file but must stay read-only, or merely looking at capacity
    # would move the hysteresis.
    --update-governor-state) update_state="yes"; shift ;;
    --json) json="yes"; shift ;;
    *) echo "resource-plan: unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ "$configured" == "auto" || "$configured" =~ ^[0-9]+$ ]] || {
  echo "resource-plan: slots must be 'auto' or a non-negative integer" >&2
  exit 2
}
[[ "$reserve" =~ ^[0-9]+$ ]] || {
  echo "resource-plan: slots and reserve must be non-negative integers" >&2
  exit 2
}
if [[ -z "$estimate" ]]; then
  estimate="$(python3 - "$SINGULAR_ROOT" <<'PY'
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
excluded = {".git", ".worktrees", ".singular-state"}
total = 0
for base, dirs, files in os.walk(root):
    dirs[:] = [name for name in dirs if name not in excluded]
    for name in files:
        try:
            total += (pathlib.Path(base) / name).stat().st_size
        except OSError:
            pass
# A writable worktree needs headroom for build output; use at least 256 MiB and
# otherwise twice the tracked/source footprint.
print(max(268435456, total * 2))
PY
)"
fi
[[ "$estimate" =~ ^[1-9][0-9]*$ ]] || {
  echo "resource-plan: estimate must be a positive integer" >&2
  exit 2
}
if [[ -z "$free_bytes" ]]; then
  free_bytes="$(python3 - "$SINGULAR_ROOT" <<'PY'
import shutil, sys
print(shutil.disk_usage(sys.argv[1]).free)
PY
)"
fi
[[ "$free_bytes" =~ ^[0-9]+$ ]] || {
  echo "resource-plan: free bytes must be a non-negative integer" >&2
  exit 2
}

if [[ -z "$active_workers" ]]; then
  active_workers="$(singular_active_lease_count 2>/dev/null || echo 0)"
fi
[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
# Planners in flight (live L1 leases). Only the minimum-progress floor reads
# this: it admits one unit of work under a hold only when nothing is running.
if [[ -z "$active_planners" ]]; then
  active_planners="$(singular_l1_list_active 2>/dev/null | grep -c . || true)"
fi
[[ "$active_planners" =~ ^[0-9]+$ ]] || active_planners=0

governor_args=(
  --configured "$configured" --free-bytes "$free_bytes" --reserve-bytes "$reserve"
  --estimated-worktree-bytes "$estimate" --active-workers "$active_workers"
  --active-planners "$active_planners"
  --state-file "$governor_state"
)
[[ -z "$cpu_count" ]] || governor_args+=(--cpu-count "$cpu_count")
[[ -z "$available_memory" ]] || governor_args+=(--available-memory-bytes "$available_memory")
[[ -z "$load_1m" ]] || governor_args+=(--load-1m "$load_1m")
[[ -z "$cpu_busy" ]] || governor_args+=(--cpu-busy "$cpu_busy")
[[ "$update_state" != "yes" ]] || governor_args+=(--update-state)
base_record="$(python3 "$SCRIPT_DIR/resource_governor.py" "${governor_args[@]}")" || {
  echo "resource-plan: resource governor failed" >&2
  exit 2
}
configured_slots="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["configuredSlots"])' "$base_record")"

# Provider-pressure ceiling (opt-in, default off). Read-only: with adaptation
# disabled this prints nothing, no state is created, and the record below is
# the governor's record unchanged.
pressure_json=""
if singular_provider_pressure_enabled; then
  # Hand the controller the very baseline this plan is using, so its stored cap
  # is bounded by the same configured ceiling the min() below applies.
  pressure_json="$(SINGULAR_MAX_CONCURRENT="$configured_slots" \
    singular_provider_pressure_status_json 2>/dev/null || true)"
fi

python3 - "$base_record" "$json" "$pressure_json" <<'PY'
import json
import math
import sys

record = json.loads(sys.argv[1])
effective = record["effectiveSlots"]

# Disk decides first, then provider pressure lowers the result further — never
# raises it. Taking the min here is what makes recovery structurally unable to
# exceed configured or disk-affordable capacity, whatever the stored cap says.
pressure_raw = sys.argv[3] if len(sys.argv) > 3 else ""
if pressure_raw:
    try:
        pressure = json.loads(pressure_raw)
    except ValueError:
        pressure = None
    if isinstance(pressure, dict):
        cap = pressure.get("cap")
        applied = (
            isinstance(cap, int) and not isinstance(cap, bool) and cap < effective
        )
        if applied:
            effective = cap
            record["effectiveSlots"] = effective
            record["capacityReason"] = "provider-pressure-limited"
            # A live-pressure throttle still names itself: it is what is
            # holding this cycle, the pressure cap only lowered the ceiling.
            if record.get("admission") != "throttled" or effective <= 0:
                record["reason"] = "provider-pressure-limited"
            # Planners follow the ceiling that is actually in force.
            fraction = record.get("plannerFraction") or 0.5
            record["plannerSlots"] = 0 if effective <= 0 else max(
                1, min(effective, math.ceil(effective * fraction)))
        record["providerPressure"] = {
            "enabled": True,
            "provider": pressure.get("provider"),
            "cap": cap if isinstance(cap, int) and not isinstance(cap, bool) else None,
            "events": pressure.get("events"),
            "pendingEvents": pressure.get("pendingEvents"),
            "quietSuccesses": pressure.get("quietSuccesses"),
            "recoverQuiet": pressure.get("recoverQuiet"),
            "clusterThreshold": pressure.get("clusterThreshold"),
            "applied": applied,
        }
if sys.argv[2] == "yes":
    print(json.dumps(record, separators=(",", ":")))
else:
    print(effective)
PY
