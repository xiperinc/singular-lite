#!/usr/bin/env bash
# Render treatment-versus-control deltas and arm-integrity findings in experiment reports.

singular_ctx_experiment_render_delta_table() {
  SINGULAR_RENDER_DELTA="${1-}" python3 - <<'PY' || true
import json, os, sys

def fmt(x):
    if isinstance(x, bool):
        return str(x)
    if isinstance(x, int):
        return str(x)
    if isinstance(x, float):
        return str(int(x)) if x.is_integer() else str(x)
    return str(x)

def load(s):
    try:
        return json.loads(s)
    except Exception:
        return {}

art = load(os.environ.get("SINGULAR_RENDER_DELTA", ""))
if not isinstance(art, dict):
    art = {}
deltas = art.get("deltas")
if not isinstance(deltas, dict):
    deltas = {}

out = []
out.append("### Treatment effect (arm B − arm A)")
out.append("")
out.append("| Metric | Arm A (control) | Arm B (treatment) | Delta (B − A) | Direction |")
out.append("| --- | --- | --- | --- | --- |")
for key in sorted(deltas):
    rec = deltas[key]
    if not isinstance(rec, dict):
        rec = {}
    a = rec.get("a", 0)
    b = rec.get("b", 0)
    delta = rec.get("delta", 0)
    direction = rec.get("direction", "equal")
    out.append("| %s | %s | %s | %s | %s |" % (key, fmt(a), fmt(b), fmt(delta), fmt(direction)))
sys.stdout.write("\n".join(out) + "\n")
PY
}

# --- Slice 2: arm-integrity table renderer -----------------------------------
# Reads the audit artifact (singular.orchestration.ctx-experiment-armaudit.v0)
# passed as the first argument, and renders per arm the recorded / unrecorded /
# consistent / inconsistent counts plus the flagged inconsistent runIds into a
# deterministic markdown table. Arms render in the stable A-before-B order; the
# flagged runIds are the inconsistentRuns' runIds joined verbatim. A missing /
# empty arms map renders the table skeleton (header + separator) only.
singular_ctx_experiment_render_armaudit_table() {
  SINGULAR_RENDER_ARMAUDIT="${1-}" python3 - <<'PY' || true
import json, os, sys

def fmt(x):
    if isinstance(x, bool):
        return str(x)
    if isinstance(x, int):
        return str(x)
    if isinstance(x, float):
        return str(int(x)) if x.is_integer() else str(x)
    return str(x)

def load(s):
    try:
        return json.loads(s)
    except Exception:
        return {}

art = load(os.environ.get("SINGULAR_RENDER_ARMAUDIT", ""))
if not isinstance(art, dict):
    art = {}
arms = art.get("arms")
if not isinstance(arms, dict):
    arms = {}

out = []
out.append("### Arm knob-state integrity")
out.append("")
out.append("| Arm | Recorded | Unrecorded | Consistent | Inconsistent | Flagged runIds |")
out.append("| --- | --- | --- | --- | --- | --- |")
for arm in ("A", "B"):
    s = arms.get(arm)
    if not isinstance(s, dict):
        s = {}
    recorded = s.get("runsRecorded", 0)
    unrecorded = s.get("runsUnrecorded", 0)
    consistent = s.get("consistent", 0)
    inconsistent = s.get("inconsistent", 0)
    runs = s.get("inconsistentRuns")
    if not isinstance(runs, list):
        runs = []
    flagged = ", ".join(str(r.get("runId", "")) for r in runs if isinstance(r, dict))
    out.append("| %s | %s | %s | %s | %s | %s |" % (
        arm, fmt(recorded), fmt(unrecorded), fmt(consistent), fmt(inconsistent), flagged))
sys.stdout.write("\n".join(out) + "\n")
PY
}

# --- Slice 3: composed public entry ------------------------------------------
# Obtain the delta and audit artifacts by delegating to their integrated json
# composers (threading the resolved corpus args per each composer's signature:
# the delta composer takes runs_dir/events_file/metrics_file; the armaudit
# composer takes runs_dir/events_file), then render both sections in a stable
# order to stdout as ONE markdown fragment. Fail-safe / always exit 0.
singular_ctx_experiment_render_result_md() {
  local runs_dir="${1-}"
  local events_file="${2-}"
  local metrics_file="${3-}"
  local delta audit

  # Each composer is itself fail-safe and emits a zeroed artifact when its inputs
  # are missing; an empty arg falls back to the composer's own env defaults.
  delta="$(singular_ctx_experiment_delta_json "$runs_dir" "$events_file" "$metrics_file")"
  audit="$(singular_ctx_experiment_armaudit_json "$runs_dir" "$events_file")"

  printf '## Experiment result\n\n'
  singular_ctx_experiment_render_delta_table "$delta"
  printf '\n'
  singular_ctx_experiment_render_armaudit_table "$audit"
  return 0
}
