#!/usr/bin/env bash
# Covers the read-only experiment-attempts secondary raw-metrics tooling
# engine/ctx-experiment-attempts.sh. Given a synthetic runs directory of
# attempts indexes (runs/<runId>/attempts/index.json, each carrying taskId and a
# list of attempts with a per-attempt ordinal `n`, a `failureClass`, and a
# `findings` array) joined to an events.ndjson (ctx.arm_assigned {taskId, arm in
# A|B}) for per-arm grouping, the aggregators compute:
#   1. per-arm attempts-to-accept: for each accepted task (accepted = a
#      failureClass in "" / "accepted" / "none", the ctx-metrics.sh convention
#      verbatim) the ordinal of its FIRST accepted attempt; per arm (A and B) the
#      acceptedTasks count, attemptsToAcceptSum, and attemptsToAcceptMean.
#   2. per-arm findings-per-attempt: per arm the attempts count (attempt entries),
#      findingsTotal (sum over attempts of the per-attempt findings array length,
#      absent/empty counted as 0), and findingsPerAttemptMean = findingsTotal /
#      attempts.
#   3. one deterministic, sorted-key JSON artifact merging both per-arm rollups;
#      it validates against the shipped v0 schema.
#
# Guarantees pinned BEHAVIORALLY over a fixture (no absence greps):
#   - strictly read-only: the whole input fixture tree is byte-identical after
#     every call (no run artifact / index / event / lease / task file created,
#     moved, or mutated), and engine/ctx-metrics.sh plus the sibling experiment
#     aggregators are byte-unchanged.
#   - fail-safe: missing / empty inputs yield a well-formed zeroed artifact and a
#     zero exit, never an error, divide error, or partial output.
#   - deterministic: identical inputs -> byte-identical stdout.
#   - evidence invariance: the aggregator only MEASURES; it reclassifies no
#     attempt's acceptance or failureClass (accepted-task counts plus the
#     never-accepted tasks partition the arm's tasks exactly).
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ENGINE_HOME/engine/ctx-experiment-attempts.sh"
SCHEMA="$ENGINE_HOME/schemas/orchestration/ctx-experiment-attempts.v0.schema.json"
SIB_METRICS="$ENGINE_HOME/engine/ctx-metrics.sh"
SIB_REPORT="$ENGINE_HOME/engine/ctx-experiment-report.sh"
SIB_STRATEGY="$ENGINE_HOME/engine/ctx-experiment-strategy.sh"

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
for fn in singular_ctx_experiment_attempts_to_accept \
          singular_ctx_experiment_findings_per_attempt \
          singular_ctx_experiment_attempts_json; do
  [[ "$(type -t "$fn")" == "function" ]] || fail "$fn is not defined by $TOOL"
done

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

# --- Fixture: runs/<runId>/attempts/index.json + events.ndjson ---------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp" "$VALIDATOR"' EXIT
fix="$tmp/fixture"
mkdir -p "$fix"
runs="$fix/runs"
events="$fix/events.ndjson"

# Arms: A={T1,T2}, B={T3,T4}; T5 has NO arm assignment (excluded from per-arm).
mk_index() { # runId taskId <json-attempts-array>
  local rid="$1" tid="$2" attempts="$3"
  mkdir -p "$runs/$rid/attempts"
  cat > "$runs/$rid/attempts/index.json" <<EOF
{"runId":"$rid","taskId":"$tid","attempts":$attempts}
EOF
}

# Arm A
#  T1: n1 taint findings[2]; n2 accepted findings[0] -> first accepted ordinal 2
#  T2: n1 none  findings[1]                          -> first accepted ordinal 1
mk_index R1 T1 '[{"n":1,"failureClass":"taint","findings":["f1","f2"]},{"n":2,"failureClass":"accepted","findings":[]}]'
mk_index R2 T2 '[{"n":1,"failureClass":"none","findings":["f1"]}]'
# Arm B
#  T3: n1 window findings[3]; n2 taint findings[0]   -> NOT accepted
#  T4: n1 "" (empty->accepted) findings ABSENT (=0); n2 accepted findings[1]
#      -> first accepted ordinal 1
mk_index R3 T3 '[{"n":1,"failureClass":"window","findings":["f1","f2","f3"]},{"n":2,"failureClass":"taint","findings":[]}]'
mk_index R4 T4 '[{"n":1,"failureClass":""},{"n":2,"failureClass":"accepted","findings":["f1"]}]'
# T5: no arm assignment -> excluded from A and B despite being accepted.
mk_index R5 T5 '[{"n":1,"failureClass":"accepted","findings":["x","y"]}]'

cat > "$events" <<'EOF'
{"ts":"2026-07-12T00:00:00Z","type":"ctx.arm_assigned","message":"m","data":{"taskId":"T1","arm":"A"}}
{"ts":"2026-07-12T00:00:01Z","type":"ctx.arm_assigned","message":"m","data":{"taskId":"T2","arm":"A"}}
{"ts":"2026-07-12T00:00:02Z","type":"ctx.arm_assigned","message":"m","data":{"taskId":"T3","arm":"B"}}
{"ts":"2026-07-12T00:00:03Z","type":"ctx.arm_assigned","message":"m","data":{"taskId":"T4","arm":"B"}}
{"ts":"2026-07-12T00:00:09Z","type":"note.other","message":"m","data":{"taskId":"T9"}}
EOF

# Expected per-arm attempts-to-accept:
#   A: acceptedTasks=2 sum=2+1=3 mean=1.5
#   B: acceptedTasks=1 (only T4) sum=1 mean=1.0
# Expected per-arm findings-per-attempt:
#   A: attempts=3 findingsTotal=2+0+1=3 mean=1.0
#   B: attempts=4 findingsTotal=3+0(T3)+0+1(T4)=4 mean=1.0

before="$(tree_hash "$fix")"
m_before="$(file_hash "$SIB_METRICS")"
r_before="$(file_hash "$SIB_REPORT")"
s_before="$(file_hash "$SIB_STRATEGY")"

# --- Slice 1: per-arm attempts-to-accept -------------------------------------
a2a="$(singular_ctx_experiment_attempts_to_accept "$runs" "$events")" \
  || fail "attempts-to-accept aggregator exited non-zero on a valid fixture"
printf '%s' "$a2a" > "$tmp/a2a.json"
python3 - "$tmp/a2a.json" <<'PY' || fail "attempts-to-accept did not match expected"
import json, sys
m = json.load(open(sys.argv[1]))
def close(a, b): return abs(a - b) < 1e-9
def chk(s, tasks, ssum, mean):
    assert s["acceptedTasks"] == tasks, s
    assert s["attemptsToAcceptSum"] == ssum, s
    assert close(s["attemptsToAcceptMean"], mean), s
chk(m["A"], 2, 3, 1.5)
chk(m["B"], 1, 1, 1.0)
print("a2a-ok")
PY

# --- Slice 2: per-arm findings-per-attempt -----------------------------------
fpa="$(singular_ctx_experiment_findings_per_attempt "$runs" "$events")" \
  || fail "findings-per-attempt aggregator exited non-zero on a valid fixture"
printf '%s' "$fpa" > "$tmp/fpa.json"
python3 - "$tmp/fpa.json" <<'PY' || fail "findings-per-attempt did not match expected"
import json, sys
m = json.load(open(sys.argv[1]))
def close(a, b): return abs(a - b) < 1e-9
def chk(s, attempts, total, mean):
    assert s["attempts"] == attempts, s
    assert s["findingsTotal"] == total, s
    assert close(s["findingsPerAttemptMean"], mean), s
    # divide convention: mean == total/attempts (0 when no attempts)
    assert close(s["findingsPerAttemptMean"], (total/attempts) if attempts else 0.0), s
chk(m["A"], 3, 3, 1.0)
chk(m["B"], 4, 4, 1.0)
print("fpa-ok")
PY

# --- Slice 3: composed, schema-valid, deterministic artifact -----------------
art="$(singular_ctx_experiment_attempts_json "$runs" "$events")" \
  || fail "attempts aggregator exited non-zero on a valid fixture"
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
def close(a, b): return abs(a - b) < 1e-9
assert m["schema"] == "singular.orchestration.ctx-experiment-attempts.v0", m["schema"]
a2a = m["attemptsToAccept"]
assert a2a["A"]["acceptedTasks"] == 2 and a2a["A"]["attemptsToAcceptSum"] == 3, a2a["A"]
assert close(a2a["A"]["attemptsToAcceptMean"], 1.5), a2a["A"]
assert a2a["B"]["acceptedTasks"] == 1 and a2a["B"]["attemptsToAcceptSum"] == 1, a2a["B"]
fpa = m["findingsPerAttempt"]
assert fpa["A"]["attempts"] == 3 and fpa["A"]["findingsTotal"] == 3, fpa["A"]
assert close(fpa["A"]["findingsPerAttemptMean"], 1.0), fpa["A"]
assert fpa["B"]["attempts"] == 4 and fpa["B"]["findingsTotal"] == 4, fpa["B"]
# Evidence invariance: mean is exactly sum/tasks and total/attempts, no reclass.
for s in (a2a["A"], a2a["B"]):
    t = s["acceptedTasks"]
    assert close(s["attemptsToAcceptMean"], (s["attemptsToAcceptSum"]/t) if t else 0.0), s
print("composed-ok")
PY

# --- Determinism: identical inputs -> byte-identical output ------------------
art2="$(singular_ctx_experiment_attempts_json "$runs" "$events")"
[[ "$art" == "$art2" ]] || fail "composed artifact not deterministic across identical runs"

# --- Read-only: input fixture tree + sibling engine files byte-unchanged ------
after="$(tree_hash "$fix")"
[[ "$before" == "$after" ]] || fail "input fixture mutated by tooling (not read-only)"
[[ "$m_before" == "$(file_hash "$SIB_METRICS")" ]]  || fail "engine/ctx-metrics.sh was mutated"
[[ "$r_before" == "$(file_hash "$SIB_REPORT")" ]]   || fail "engine/ctx-experiment-report.sh was mutated"
[[ "$s_before" == "$(file_hash "$SIB_STRATEGY")" ]] || fail "engine/ctx-experiment-strategy.sh was mutated"

# --- Fail-safe: missing runs dir + missing events -> zeroed artifact ----------
out_empty="$(singular_ctx_experiment_attempts_json "$tmp/no-such-runs" "$tmp/no-such-events.ndjson")" \
  || fail "attempts aggregator crashed on missing input (should fail safe)"
printf '%s' "$out_empty" > "$tmp/empty.json"
printf '%s' "$out_empty" | validates "$SCHEMA" || fail "zeroed artifact did not validate against schema"
python3 - "$tmp/empty.json" <<'PY' || fail "empty-input artifact not well-formed/zeroed"
import json, sys
m = json.load(open(sys.argv[1]))
a2a = m["attemptsToAccept"]
for s in (a2a["A"], a2a["B"]):
    assert s["acceptedTasks"] == 0 and s["attemptsToAcceptSum"] == 0, s
    assert s["attemptsToAcceptMean"] == 0, s
fpa = m["findingsPerAttempt"]
for s in (fpa["A"], fpa["B"]):
    assert s["attempts"] == 0 and s["findingsTotal"] == 0, s
    assert s["findingsPerAttemptMean"] == 0, s
print("empty-ok")
PY

# empty events file + present runs dir with no arm assignment -> also fail-safe
# and zeroed (no task joins to any arm), never a divide error.
: > "$tmp/empty-events.ndjson"
noarm="$(singular_ctx_experiment_findings_per_attempt "$runs" "$tmp/empty-events.ndjson")" \
  || fail "findings-per-attempt crashed on an empty events file"
python3 - <<PY || fail "no-arm slice not zeroed"
import json
m = json.loads('''$noarm''')
for s in (m["A"], m["B"]):
    assert s["attempts"] == 0 and s["findingsTotal"] == 0, s
    assert s["findingsPerAttemptMean"] == 0, s
print("noarm-ok")
PY

# --- No-arg default invocation is also fail-safe -----------------------------
SINGULAR_RUNS_DIR="$tmp/no-such-runs" SINGULAR_EVENTS_FILE="$tmp/no-such-events.ndjson" \
  singular_ctx_experiment_attempts_json >/dev/null \
  || fail "no-arg default invocation crashed instead of failing safe"

echo "ctx-experiment-attempts tests passed"
