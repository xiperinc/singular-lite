#!/usr/bin/env bash
# Regression contracts for ctx-experiment-armaudit.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ENGINE_HOME/engine/ctx-experiment-armaudit.sh"
SCHEMA="$ENGINE_HOME/schemas/orchestration/ctx-experiment-armaudit.v0.schema.json"
EMITTER="$ENGINE_HOME/engine/ctx-experiment-armstate.sh"
SIB_DRIVE="$ENGINE_HOME/engine/l1-drive.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Directory-tree fingerprint (path + content sha) to prove read-only behavior.
tree_hash() {
  local dir="$1"
  [[ -d "$dir" ]] || { echo "MISSING:$dir"; return 0; }
  find "$dir" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s ' "$f"; shasum "$f" | awk '{print $1}'
  done
}
file_hash() { shasum "$1" 2>/dev/null | awk '{print $1}'; }

# The tool + schema must exist and source cleanly (RED before they are written).
[[ -f "$TOOL" ]]   || fail "tool not present yet: $TOOL"
[[ -f "$SCHEMA" ]] || fail "schema not present yet: $SCHEMA"
# shellcheck disable=SC1090
source "$TOOL" || fail "sourcing $TOOL failed"
for fn in singular_ctx_experiment_armaudit_runstate \
          singular_ctx_experiment_armaudit_classify \
          singular_ctx_experiment_armaudit_json; do
  [[ "$(type -t "$fn")" == "function" ]] || fail "$fn is not defined by $TOOL"
done

# The emitter is the integrated writer of arm-knob-state.json; source it to
# produce GENUINE ctx-experiment-armstate.v0 provenance for the fixture.
# shellcheck disable=SC1090
source "$EMITTER" || fail "sourcing $EMITTER failed"

# --- minimal schema-driven validator (no jsonschema module ships here) --------
VALIDATOR="$(mktemp)"
cat > "$VALIDATOR" <<'PY'
import json, sys

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

# --- Fixture: runs/<runId>/{arm-knob-state.json, attempts/index.json} ---------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp" "$VALIDATOR"' EXIT
fix="$tmp/fixture"
mkdir -p "$fix"
runs="$fix/runs"
events="$fix/events.ndjson"

mk_index() { # runId taskId
  local rid="$1" tid="$2"
  mkdir -p "$runs/$rid/attempts"
  cat > "$runs/$rid/attempts/index.json" <<EOF
{"runId":"$rid","taskId":"$tid","attempts":[{"n":1,"failureClass":"accepted"}]}
EOF
}

# Emit a GENUINE arm-knob-state.json for a run by running the integrated emitter
# with a scrubbed env and only the requested knobs set (so activeCount / active
# knob names are exactly what the operator's run would have recorded).
mk_armstate() { # runId  [KNOB=value ...]
  local rid="$1"; shift
  mkdir -p "$runs/$rid"
  (
    unset SINGULAR_CTX_PACKET SINGULAR_CTX_ROUTING SINGULAR_REHYDRATE \
          SINGULAR_PAIRED_AUDIT_PCT SINGULAR_CRITIC_RECHECK_PCT \
          SINGULAR_CTX_ARTIFACT_SCAN SINGULAR_CTX_MANIFEST
    local kv
    for kv in "$@"; do export "$kv"; done
    singular_ctx_experiment_armstate_json
  ) > "$runs/$rid/arm-knob-state.json"
}

# Arm A (control, expects activeCount 0):
#   RA1: recorded M0 (activeCount 0)                 -> consistent
#   RA2: recorded 2 active (PACKET,ROUTING)          -> contaminated
#   RA3: NO arm-knob-state.json                      -> unrecorded
mk_index RA1 TA1; mk_armstate RA1
mk_index RA2 TA2; mk_armstate RA2 SINGULAR_CTX_PACKET=1 SINGULAR_CTX_ROUTING=1
mk_index RA3 TA3   # deliberately no arm-knob-state.json

# Arm B (treatment, expects activeCount > 0):
#   RB1: recorded 3 active (PACKET,ROUTING,REHYDRATE) -> consistent
#   RB2: recorded M0 (activeCount 0)                  -> misconfigured-as-M0
#   RB3: NO arm-knob-state.json                       -> unrecorded
mk_index RB1 TB1; mk_armstate RB1 SINGULAR_CTX_PACKET=1 SINGULAR_CTX_ROUTING=1 SINGULAR_REHYDRATE=1
mk_index RB2 TB2; mk_armstate RB2
mk_index RB3 TB3   # deliberately no arm-knob-state.json

# RX: has an arm-knob-state.json but NO arm assignment -> excluded from A and B.
mk_index RX TX; mk_armstate RX SINGULAR_CTX_MANIFEST=1

cat > "$events" <<'EOF'
{"ts":"2026-07-12T00:00:00Z","type":"ctx.arm_assigned","message":"m","data":{"taskId":"TA1","arm":"A"}}
{"ts":"2026-07-12T00:00:01Z","type":"ctx.arm_assigned","message":"m","data":{"taskId":"TA2","arm":"A"}}
{"ts":"2026-07-12T00:00:02Z","type":"ctx.arm_assigned","message":"m","data":{"taskId":"TA3","arm":"A"}}
{"ts":"2026-07-12T00:00:03Z","type":"ctx.arm_assigned","message":"m","data":{"taskId":"TB1","arm":"B"}}
{"ts":"2026-07-12T00:00:04Z","type":"ctx.arm_assigned","message":"m","data":{"taskId":"TB2","arm":"B"}}
{"ts":"2026-07-12T00:00:05Z","type":"ctx.arm_assigned","message":"m","data":{"taskId":"TB3","arm":"B"}}
{"ts":"2026-07-12T00:00:09Z","type":"note.other","message":"m","data":{"taskId":"TX"}}
EOF

before="$(tree_hash "$fix")"
d_before="$(file_hash "$SIB_DRIVE")"
e_before="$(file_hash "$EMITTER")"

# --- Slice 1: per-run knob-state reader ---------------------------------------
rs="$(singular_ctx_experiment_armaudit_runstate "$runs")" \
  || fail "runstate reader exited non-zero on a valid fixture"
printf '%s' "$rs" > "$tmp/rs.json"
python3 - "$tmp/rs.json" <<'PY' || fail "runstate reader did not match expected"
import json, sys
m = json.load(open(sys.argv[1]))
# RA1 recorded, M0 (activeCount 0, no active knobs)
assert m["RA1"]["recorded"] is True, m["RA1"]
assert m["RA1"]["activeCount"] == 0, m["RA1"]
assert m["RA1"]["activeKnobs"] == [], m["RA1"]
# RA2 recorded, 2 active knobs listed (sorted)
assert m["RA2"]["recorded"] is True, m["RA2"]
assert m["RA2"]["activeCount"] == 2, m["RA2"]
assert m["RA2"]["activeKnobs"] == ["SINGULAR_CTX_PACKET", "SINGULAR_CTX_ROUTING"], m["RA2"]
# RA3 unrecorded (fail-safe, not an error)
assert m["RA3"]["recorded"] is False, m["RA3"]
assert m["RA3"]["activeKnobs"] == [], m["RA3"]
# RB1 recorded, 3 active
assert m["RB1"]["recorded"] is True and m["RB1"]["activeCount"] == 3, m["RB1"]
assert m["RB1"]["activeKnobs"] == ["SINGULAR_CTX_PACKET", "SINGULAR_CTX_ROUTING", "SINGULAR_REHYDRATE"], m["RB1"]
assert m["RB2"]["recorded"] is True and m["RB2"]["activeCount"] == 0, m["RB2"]
assert m["RB3"]["recorded"] is False, m["RB3"]
print("runstate-ok")
PY

# --- Slice 2: arm-join + per-run classification -------------------------------
cls="$(singular_ctx_experiment_armaudit_classify "$runs" "$events")" \
  || fail "classify aggregator exited non-zero on a valid fixture"
printf '%s' "$cls" > "$tmp/cls.json"
python3 - "$tmp/cls.json" <<'PY' || fail "classification did not match expected"
import json, sys
m = json.load(open(sys.argv[1]))
A, B = m["A"], m["B"]
# Arm A: 2 recorded (RA1,RA2), 1 unrecorded (RA3), 1 consistent, 1 contaminated.
assert A["runsRecorded"] == 2, A
assert A["runsUnrecorded"] == 1, A
assert A["consistent"] == 1, A
assert A["inconsistent"] == 1, A
ia = A["inconsistentRuns"]
assert len(ia) == 1 and ia[0]["runId"] == "RA2", ia
assert ia[0]["classification"] == "contaminated", ia
assert ia[0]["activeCount"] == 2, ia
assert ia[0]["activeKnobs"] == ["SINGULAR_CTX_PACKET", "SINGULAR_CTX_ROUTING"], ia
# Arm B: 2 recorded (RB1,RB2), 1 unrecorded (RB3), 1 consistent, 1 misconfigured.
assert B["runsRecorded"] == 2, B
assert B["runsUnrecorded"] == 1, B
assert B["consistent"] == 1, B
assert B["inconsistent"] == 1, B
ib = B["inconsistentRuns"]
assert len(ib) == 1 and ib[0]["runId"] == "RB2", ib
assert ib[0]["classification"] == "misconfigured-as-M0", ib
assert ib[0]["activeCount"] == 0, ib
assert ib[0]["activeKnobs"] == [], ib
# Evidence invariance: consistent + inconsistent + unrecorded partition the arm.
for s in (A, B):
    assert s["consistent"] + s["inconsistent"] == s["runsRecorded"], s
print("classify-ok")
PY

# --- Slice 3: composed, schema-valid, deterministic artifact -----------------
art="$(singular_ctx_experiment_armaudit_json "$runs" "$events")" \
  || fail "audit aggregator exited non-zero on a valid fixture"
printf '%s' "$art" > "$tmp/art.json"
printf '%s' "$art" | validates "$SCHEMA" || fail "artifact did not validate against $SCHEMA"

# sorted-key determinism: bytes equal a re-serialization with sort_keys.
python3 - "$tmp/art.json" <<'PY' || fail "artifact keys not sorted / not canonical"
import json, sys
raw = open(sys.argv[1]).read().rstrip("\n")
obj = json.loads(raw)
canon = json.dumps(obj, indent=2, sort_keys=True)
assert raw == canon, "artifact bytes are not sorted-key canonical JSON"
print("sorted-ok")
PY

python3 - "$tmp/art.json" <<'PY' || fail "composed artifact fields did not match expected"
import json, sys
m = json.load(open(sys.argv[1]))
assert m["schema"] == "singular.orchestration.ctx-experiment-armaudit.v0", m["schema"]
arms = m["arms"]
A, B = arms["A"], arms["B"]
assert A["arm"] == "A" and B["arm"] == "B", arms
assert A["runsRecorded"] == 2 and A["runsUnrecorded"] == 1, A
assert A["consistent"] == 1 and A["inconsistent"] == 1, A
assert A["inconsistentRuns"][0]["runId"] == "RA2", A
assert B["runsRecorded"] == 2 and B["runsUnrecorded"] == 1, B
assert B["consistent"] == 1 and B["inconsistent"] == 1, B
assert B["inconsistentRuns"][0]["classification"] == "misconfigured-as-M0", B
print("composed-ok")
PY

# --- Determinism: identical inputs -> byte-identical output ------------------
art2="$(singular_ctx_experiment_armaudit_json "$runs" "$events")"
[[ "$art" == "$art2" ]] || fail "composed artifact not deterministic across identical runs"

# --- Read-only: input fixture tree + sibling engine files byte-unchanged ------
after="$(tree_hash "$fix")"
[[ "$before" == "$after" ]] || fail "input fixture mutated by tooling (not read-only)"
[[ "$d_before" == "$(file_hash "$SIB_DRIVE")" ]] || fail "engine/l1-drive.sh was mutated"
[[ "$e_before" == "$(file_hash "$EMITTER")" ]]   || fail "engine/ctx-experiment-armstate.sh was mutated"

# --- Fail-safe: missing runs dir + missing events -> zeroed artifact ----------
out_empty="$(singular_ctx_experiment_armaudit_json "$tmp/no-such-runs" "$tmp/no-such-events.ndjson")" \
  || fail "audit aggregator crashed on missing input (should fail safe)"
printf '%s' "$out_empty" > "$tmp/empty.json"
printf '%s' "$out_empty" | validates "$SCHEMA" || fail "zeroed artifact did not validate against schema"
python3 - "$tmp/empty.json" <<'PY' || fail "empty-input artifact not well-formed/zeroed"
import json, sys
m = json.load(open(sys.argv[1]))
assert m["schema"] == "singular.orchestration.ctx-experiment-armaudit.v0", m
for arm in ("A", "B"):
    s = m["arms"][arm]
    assert s["runsRecorded"] == 0 and s["runsUnrecorded"] == 0, s
    assert s["consistent"] == 0 and s["inconsistent"] == 0, s
    assert s["inconsistentRuns"] == [], s
print("empty-ok")
PY

# present runs dir + empty events (no arm joins) -> also fail-safe and zeroed.
: > "$tmp/empty-events.ndjson"
noarm="$(singular_ctx_experiment_armaudit_json "$runs" "$tmp/empty-events.ndjson")" \
  || fail "audit crashed on an empty events file"
python3 - <<PY || fail "no-arm audit not zeroed"
import json
m = json.loads('''$noarm''')
for arm in ("A", "B"):
    s = m["arms"][arm]
    assert s["runsRecorded"] == 0 and s["runsUnrecorded"] == 0, s
    assert s["consistent"] == 0 and s["inconsistent"] == 0 and s["inconsistentRuns"] == [], s
print("noarm-ok")
PY

# --- No-arg default invocation is also fail-safe -----------------------------
SINGULAR_RUNS_DIR="$tmp/no-such-runs" SINGULAR_EVENTS_FILE="$tmp/no-such-events.ndjson" \
  singular_ctx_experiment_armaudit_json >/dev/null \
  || fail "no-arg default invocation crashed instead of failing safe"

echo "ctx-experiment-armaudit tests passed"
