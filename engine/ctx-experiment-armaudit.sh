#!/usr/bin/env bash
# Audit experiment arm assignments against their captured settings and observed events.

_singular_ctx_experiment_armaudit_py() {
  cat <<'PY'
import json
import os

ARMS = ("A", "B")


def _read_json(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def load_arms(events_file):
    arm_of = {}  # taskId -> "A"/"B"
    if not events_file:
        return arm_of
    try:
        f = open(events_file, "r", encoding="utf-8")
    except OSError:
        return arm_of
    with f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(ev, dict):
                continue
            if ev.get("type") != "ctx.arm_assigned":
                continue
            data = ev.get("data")
            if not isinstance(data, dict):
                continue
            tid = str(data.get("taskId", ""))
            arm = str(data.get("arm", ""))
            if tid and arm in ARMS:
                arm_of[tid] = arm
    return arm_of


def _knobstate(run_path):
    # Read this run's arm-knob-state.json (a ctx-experiment-armstate.v0 artifact).
    # Returns (recorded, activeCount, activeKnobs). A missing / unparseable file is
    # classified unrecorded (fail-safe, not an error).
    state = _read_json(os.path.join(run_path, "arm-knob-state.json"))
    if not isinstance(state, dict):
        return False, None, []
    knobs = state.get("knobs")
    active = []
    if isinstance(knobs, dict):
        for name, rec in knobs.items():
            if isinstance(rec, dict) and rec.get("active") is True:
                active.append(str(name))
    active.sort()
    ac = state.get("activeCount")
    # Generic boundary is on activeCount; fall back to the derived active-knob
    # count if the recorded field is absent or not a plain integer.
    if isinstance(ac, bool) or not isinstance(ac, int):
        ac = len(active)
    return True, ac, active


def load_runs(runs_dir):
    runs = []  # {runId, taskId, recorded, activeCount, activeKnobs}
    if not runs_dir or not os.path.isdir(runs_dir):
        return runs
    for run in sorted(os.listdir(runs_dir)):
        run_path = os.path.join(runs_dir, run)
        if not os.path.isdir(run_path):
            continue
        index = _read_json(os.path.join(run_path, "attempts", "index.json"))
        tid = str(index.get("taskId", "")) if isinstance(index, dict) else ""
        recorded, active_count, active_knobs = _knobstate(run_path)
        runs.append({
            "runId": run,
            "taskId": tid,
            "recorded": recorded,
            "activeCount": active_count,
            "activeKnobs": active_knobs,
        })
    return runs


def classify(runs, arm_of):
    out = {}
    for arm in ARMS:
        recorded = unrecorded = consistent = inconsistent = 0
        inconsistent_runs = []
        for r in runs:
            if arm_of.get(r["taskId"]) != arm:
                continue
            if not r["recorded"]:
                unrecorded += 1
                continue
            recorded += 1
            active_count = r["activeCount"]
            if arm == "A":
                # control expects the M0 knob-state (activeCount 0)
                ok = (active_count == 0)
                classification = "contaminated"
            else:
                # treatment expects activeCount greater than 0
                ok = (active_count > 0)
                classification = "misconfigured-as-M0"
            if ok:
                consistent += 1
            else:
                inconsistent += 1
                inconsistent_runs.append({
                    "runId": r["runId"],
                    "classification": classification,
                    "activeCount": active_count,
                    "activeKnobs": r["activeKnobs"],
                })
        inconsistent_runs.sort(key=lambda x: x["runId"])
        out[arm] = {
            "arm": arm,
            "expectation": "activeCount==0" if arm == "A" else "activeCount>0",
            "runsRecorded": recorded,
            "runsUnrecorded": unrecorded,
            "consistent": consistent,
            "inconsistent": inconsistent,
            "inconsistentRuns": inconsistent_runs,
        }
    return out
PY
}

# Per-run knob-state read from each run's arm-knob-state.json. Read-only, fail-safe.
singular_ctx_experiment_armaudit_runstate() {
  local runs_dir="${1:-${SINGULAR_RUNS_DIR:-}}"
  python3 - "$runs_dir" <<PY || true
import json, sys
$(_singular_ctx_experiment_armaudit_py)

runs = load_runs(sys.argv[1])
out = {
    r["runId"]: {
        "recorded": r["recorded"],
        "activeCount": r["activeCount"],
        "activeKnobs": r["activeKnobs"],
    }
    for r in runs
}
json.dump(out, sys.stdout, sort_keys=True)
PY
  return 0
}

# Per-arm join + classification. Read-only, fail-safe.
singular_ctx_experiment_armaudit_classify() {
  local runs_dir="${1:-${SINGULAR_RUNS_DIR:-}}"
  local events_file="${2:-${SINGULAR_EVENTS_FILE:-}}"
  python3 - "$runs_dir" "$events_file" <<PY || true
import json, sys
$(_singular_ctx_experiment_armaudit_py)

runs_dir, events_file = sys.argv[1], sys.argv[2]
arm_of = load_arms(events_file)
runs = load_runs(runs_dir)
json.dump(classify(runs, arm_of), sys.stdout, sort_keys=True)
PY
  return 0
}

# Composed audit artifact: ONE deterministic sorted-key JSON object conforming to
# singular.orchestration.ctx-experiment-armaudit.v0. Read-only, fail-safe.
singular_ctx_experiment_armaudit_json() {
  local runs_dir="${1:-${SINGULAR_RUNS_DIR:-}}"
  local events_file="${2:-${SINGULAR_EVENTS_FILE:-}}"
  python3 - "$runs_dir" "$events_file" <<PY || true
import json, sys
$(_singular_ctx_experiment_armaudit_py)

runs_dir, events_file = sys.argv[1], sys.argv[2]
arm_of = load_arms(events_file)
runs = load_runs(runs_dir)
artifact = {
    "schema": "singular.orchestration.ctx-experiment-armaudit.v0",
    "arms": classify(runs, arm_of),
}
json.dump(artifact, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
PY
  return 0
}
