#!/usr/bin/env bash
# Covers the read-only experiment-armstate emitter engine/ctx-experiment-armstate.sh:
# a deterministic snapshot of the OBSERVED continuity knob-state that distinguishes
# the treatment arm from the M0 control baseline (control = every continuity knob
# inactive at its documented default; treatment = the continuity knobs set/enabling).
# It is the per-arm configuration provenance the experiment-report attributes
# escape-rate / cost / bias to; it neither declares nor gates node completion.
#
# Three chained slices, all inside engine/ctx-experiment-armstate.sh:
#   1. singular_ctx_experiment_armstate_read <knob>  -> {knob,value,active} for one
#      canonical continuity knob, read from the environment with the knob's
#      documented default and the engine's own active interpretation.
#   2. singular_ctx_experiment_armstate_snapshot     -> the {knob,value,active}
#      record for EVERY continuity knob, keyed by canonical knob name.
#   3. singular_ctx_experiment_armstate_json         -> ONE deterministic, sorted-key
#      JSON object composing the snapshot; validates against the shipped v0 schema.
#
# Guarantees pinned BEHAVIORALLY over environment fixtures (no absence greps, no
# temporal negative / present-but-uncalled assertions):
#   - control arm: with all continuity knobs UNSET, every knob is reported inactive
#     at its documented default (the M0 control knob-state).
#   - treatment arm: with the treatment knobs SET, each is reported active with its
#     observed value (the treatment knob-state).
#   - fail-safe: a partial / non-enabling value (non-numeric percent, empty string)
#     is reported verbatim with active=false, never a nonzero exit or partial output.
#   - strictly read-only: an isolated fixture tree (run artifact, index, event log,
#     lease, task file) is byte-identical after every call and no file is created,
#     moved, or mutated; the emitter reads ONLY the environment.
#   - deterministic: a fixed environment yields byte-identical stdout.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ENGINE_HOME/engine/ctx-experiment-armstate.sh"
SCHEMA="$ENGINE_HOME/schemas/orchestration/ctx-experiment-armstate.v0.schema.json"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Directory-tree fingerprint (path + content sha) to prove read-only behavior.
tree_hash() {
  local dir="$1"
  [[ -d "$dir" ]] || { echo "MISSING:$dir"; return 0; }
  find "$dir" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s ' "$f"; shasum "$f" | awk '{print $1}'
  done
}

# The tool + schema must exist and source cleanly (RED before they are written).
[[ -f "$TOOL" ]]   || fail "tool not present yet: $TOOL"
[[ -f "$SCHEMA" ]] || fail "schema not present yet: $SCHEMA"
# shellcheck disable=SC1090
source "$TOOL" || fail "sourcing $TOOL failed"
for fn in singular_ctx_experiment_armstate_read \
          singular_ctx_experiment_armstate_snapshot \
          singular_ctx_experiment_armstate_json; do
  [[ "$(type -t "$fn")" == "function" ]] || fail "$fn is not defined by $TOOL"
done

# The canonical continuity knobs that distinguish treatment from the M0 control.
KNOBS=(SINGULAR_CTX_PACKET SINGULAR_CTX_ROUTING SINGULAR_REHYDRATE \
       SINGULAR_PAIRED_AUDIT_PCT SINGULAR_CRITIC_RECHECK_PCT \
       SINGULAR_CTX_ARTIFACT_SCAN SINGULAR_CTX_MANIFEST)
# Clear the whole slate so the default-arm assertions see a pristine environment.
unset "${KNOBS[@]}"

# --- minimal schema-driven validator (no jsonschema module ships here) --------
VALIDATOR="$(mktemp)"
cat > "$VALIDATOR" <<'PY'
import json, re, sys

def validate(data, schema, path, errs):
    if "const" in schema and data != schema["const"]:
        errs.append(f"{path}: const mismatch (want {schema['const']!r})")
    if "enum" in schema and data not in schema["enum"]:
        errs.append(f"{path}: not in enum {schema['enum']}")
    t = schema.get("type")
    if t == "object":
        if not isinstance(data, dict):
            errs.append(f"{path}: expected object"); return
        for r in schema.get("required", []):
            if r not in data:
                errs.append(f"{path}: missing required '{r}'")
        props = schema.get("properties", {})
        addl = schema.get("additionalProperties")
        if addl is False:
            for k in data:
                if k not in props:
                    errs.append(f"{path}: unknown property '{k}'")
        for k, v in data.items():
            if k in props:
                validate(v, props[k], f"{path}/{k}", errs)
            elif isinstance(addl, dict):
                validate(v, addl, f"{path}/{k}", errs)
    elif t == "array":
        if not isinstance(data, list):
            errs.append(f"{path}: expected array"); return
        items = schema.get("items")
        if items is not None:
            for i, el in enumerate(data):
                validate(el, items, f"{path}[{i}]", errs)
    elif t == "string":
        if not isinstance(data, str):
            errs.append(f"{path}: expected string"); return
        if "minLength" in schema and len(data) < schema["minLength"]:
            errs.append(f"{path}: shorter than minLength {schema['minLength']}")
        if "pattern" in schema and not re.search(schema["pattern"], data):
            errs.append(f"{path}: does not match {schema['pattern']}")
    elif t in ("number", "integer"):
        if isinstance(data, bool) or not isinstance(data, (int, float)):
            errs.append(f"{path}: expected {t}"); return
        if t == "integer" and isinstance(data, float) and not data.is_integer():
            errs.append(f"{path}: expected integer")
        if "minimum" in schema and data < schema["minimum"]:
            errs.append(f"{path}: below minimum {schema['minimum']}")
    elif t == "boolean":
        if not isinstance(data, bool):
            errs.append(f"{path}: expected boolean")

with open(sys.argv[1], "r", encoding="utf-8") as f:
    schema = json.load(f)
data = json.load(sys.stdin)
errs = []
validate(data, schema, "$", errs)
if errs:
    print("\n".join(errs), file=sys.stderr)
    sys.exit(1)
print("ok")
PY
validates() { python3 "$VALIDATOR" "$1" >/dev/null 2>&1; }

# --- Isolated fixture tree the read-only assertion fingerprints ---------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp" "$VALIDATOR"' EXIT
fix="$tmp/fixture"
mkdir -p "$fix/run" "$fix/index" "$fix/tasks"
printf '{"runId":"RUN-x"}\n'                 > "$fix/run/packet.json"
printf '{"type":"note"}\n'                   > "$fix/run/events.ndjson"
printf 'lease-holder\n'                      > "$fix/run/l1.lease"
printf 'TASK-0093\n'                         > "$fix/index/index.txt"
printf '{"taskId":"TASK-0093"}\n'            > "$fix/tasks/task.json"

before="$(tree_hash "$fix")"

# --- Slice 3 default arm: all continuity knobs UNSET -> M0 control knob-state --
ctrl="$(singular_ctx_experiment_armstate_json)" \
  || fail "emitter exited non-zero with a pristine (control) environment"
printf '%s' "$ctrl" > "$tmp/ctrl.json"
printf '%s' "$ctrl" | validates "$SCHEMA" || fail "control artifact did not validate against $SCHEMA"
python3 - "$tmp/ctrl.json" <<'PY' || fail "control-arm knob-state not all-inactive at defaults"
import json, sys
m = json.load(open(sys.argv[1]))
assert m["schema"] == "singular.orchestration.ctx-experiment-armstate.v0", m["schema"]
knobs = m["knobs"]
expected = {"SINGULAR_CTX_PACKET","SINGULAR_CTX_ROUTING","SINGULAR_REHYDRATE",
            "SINGULAR_PAIRED_AUDIT_PCT","SINGULAR_CRITIC_RECHECK_PCT",
            "SINGULAR_CTX_ARTIFACT_SCAN","SINGULAR_CTX_MANIFEST"}
assert set(knobs.keys()) == expected, set(knobs.keys())
for name, rec in knobs.items():
    assert rec["knob"] == name, rec
    assert rec["active"] is False, (name, rec)   # M0 control: every knob inactive
    assert isinstance(rec["value"], str), rec
assert m["activeCount"] == 0, m["activeCount"]
print("control-ok")
PY

# sorted-key determinism: bytes equal a re-serialization with sort_keys.
python3 - "$tmp/ctrl.json" <<'PY' || fail "control artifact keys not sorted / not canonical"
import json, sys
raw = open(sys.argv[1]).read().rstrip("\n")
obj = json.loads(raw)
canon = json.dumps(obj, indent=2, sort_keys=True)
assert raw == canon, "artifact bytes are not sorted-key canonical JSON"
print("sorted-ok")
PY

# determinism: identical (empty) environment -> byte-identical output.
ctrl2="$(singular_ctx_experiment_armstate_json)"
[[ "$ctrl" == "$ctrl2" ]] || fail "control artifact not deterministic across identical runs"

# --- Slice 1 helper: a single knob record, read from the environment ----------
SINGULAR_CTX_PACKET= singular_ctx_experiment_armstate_read SINGULAR_CTX_PACKET > "$tmp/rec_off.json"
python3 - "$tmp/rec_off.json" <<'PY' || fail "read helper (unset knob) not inactive at default"
import json, sys
r = json.load(open(sys.argv[1]))
assert r["knob"] == "SINGULAR_CTX_PACKET", r
assert r["active"] is False, r
print("read-off-ok")
PY
(export SINGULAR_CTX_PACKET=1; singular_ctx_experiment_armstate_read SINGULAR_CTX_PACKET) > "$tmp/rec_on.json"
python3 - "$tmp/rec_on.json" <<'PY' || fail "read helper (set knob) not active with observed value"
import json, sys
r = json.load(open(sys.argv[1]))
assert r["value"] == "1", r
assert r["active"] is True, r
print("read-on-ok")
PY

# --- Slice 2 snapshot: every continuity knob keyed by canonical name ----------
singular_ctx_experiment_armstate_snapshot > "$tmp/snap.json"
python3 - "$tmp/snap.json" <<'PY' || fail "snapshot did not cover every canonical continuity knob"
import json, sys
s = json.load(open(sys.argv[1]))
expected = {"SINGULAR_CTX_PACKET","SINGULAR_CTX_ROUTING","SINGULAR_REHYDRATE",
            "SINGULAR_PAIRED_AUDIT_PCT","SINGULAR_CRITIC_RECHECK_PCT",
            "SINGULAR_CTX_ARTIFACT_SCAN","SINGULAR_CTX_MANIFEST"}
assert set(s.keys()) == expected, set(s.keys())
for name, rec in s.items():
    assert set(rec.keys()) == {"knob","value","active"}, rec
print("snapshot-ok")
PY

# --- Treatment arm: the continuity knobs SET -> treatment knob-state ----------
treat="$(export SINGULAR_CTX_PACKET=1 SINGULAR_CTX_ROUTING=1 SINGULAR_REHYDRATE=1 \
                SINGULAR_PAIRED_AUDIT_PCT=25 SINGULAR_CRITIC_RECHECK_PCT=25 \
                SINGULAR_CTX_ARTIFACT_SCAN=1 SINGULAR_CTX_MANIFEST=1
         singular_ctx_experiment_armstate_json)" \
  || fail "emitter exited non-zero with the treatment environment"
printf '%s' "$treat" > "$tmp/treat.json"
printf '%s' "$treat" | validates "$SCHEMA" || fail "treatment artifact did not validate against $SCHEMA"
python3 - "$tmp/treat.json" <<'PY' || fail "treatment-arm knob-state not all-active with observed values"
import json, sys
m = json.load(open(sys.argv[1]))
knobs = m["knobs"]
obs = {"SINGULAR_CTX_PACKET":"1","SINGULAR_CTX_ROUTING":"1","SINGULAR_REHYDRATE":"1",
       "SINGULAR_PAIRED_AUDIT_PCT":"25","SINGULAR_CRITIC_RECHECK_PCT":"25",
       "SINGULAR_CTX_ARTIFACT_SCAN":"1","SINGULAR_CTX_MANIFEST":"1"}
for name, want in obs.items():
    rec = knobs[name]
    assert rec["value"] == want, (name, rec)   # observed value carried verbatim
    assert rec["active"] is True, (name, rec)  # treatment: knob active
assert m["activeCount"] == 7, m["activeCount"]
print("treatment-ok")
PY

# The two arms are distinct knob-states from the SAME emitter (control != treatment).
[[ "$ctrl" != "$treat" ]] || fail "control and treatment emitted identical knob-state"

# --- Fail-safe: partial / non-enabling values reported verbatim, active=false --
fs="$(export SINGULAR_CRITIC_RECHECK_PCT=abc SINGULAR_PAIRED_AUDIT_PCT= SINGULAR_CTX_PACKET=0
      singular_ctx_experiment_armstate_json)" \
  || fail "emitter exited non-zero on partial / non-enabling values (should fail safe)"
printf '%s' "$fs" > "$tmp/fs.json"
printf '%s' "$fs" | validates "$SCHEMA" || fail "fail-safe artifact did not validate against schema"
python3 - "$tmp/fs.json" <<'PY' || fail "partial/non-enabling values not reported verbatim + inactive"
import json, sys
m = json.load(open(sys.argv[1]))
k = m["knobs"]
# non-numeric percent -> verbatim, inactive
assert k["SINGULAR_CRITIC_RECHECK_PCT"]["value"] == "abc", k["SINGULAR_CRITIC_RECHECK_PCT"]
assert k["SINGULAR_CRITIC_RECHECK_PCT"]["active"] is False, k["SINGULAR_CRITIC_RECHECK_PCT"]
# empty string -> verbatim, inactive
assert k["SINGULAR_PAIRED_AUDIT_PCT"]["value"] == "", k["SINGULAR_PAIRED_AUDIT_PCT"]
assert k["SINGULAR_PAIRED_AUDIT_PCT"]["active"] is False, k["SINGULAR_PAIRED_AUDIT_PCT"]
# explicit "0" -> verbatim, inactive
assert k["SINGULAR_CTX_PACKET"]["value"] == "0", k["SINGULAR_CTX_PACKET"]
assert k["SINGULAR_CTX_PACKET"]["active"] is False, k["SINGULAR_CTX_PACKET"]
print("fail-safe-ok")
PY

# --- Strictly read-only: the fixture tree is byte-identical after every call ---
after="$(tree_hash "$fix")"
[[ "$before" == "$after" ]] || fail "fixture tree mutated by the emitter (not read-only)"

echo "ctx-experiment-armstate tests passed"
