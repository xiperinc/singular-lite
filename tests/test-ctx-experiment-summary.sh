#!/usr/bin/env bash
# Covers the read-only experiment-summary CAPSTONE record-merge tooling
# engine/ctx-experiment-summary.sh. This brick ships NO metric of its own: it
# DELEGATES to the three integrated per-family composers and nests their outputs
# verbatim into ONE referenceable raw-metrics bundle — the single merged artifact
# the operator's experiment-report.md points at.
#
#   * report   <- singular_ctx_experiment_report_json   [events_file] [metrics_file]
#   * strategy <- singular_ctx_experiment_strategy_json  [events_file]
#   * attempts <- singular_ctx_experiment_attempts_json  [runs_dir]    [events_file]
#
# The composers take DIFFERENT parameter lists; the summary routes each input to
# the correct sub-composer per that function's EXISTING signature, capturing each
# JSON output and merging them under stable keys (report, strategy, attempts) plus
# a schema field.
#
# Guarantees pinned BEHAVIORALLY over a fixture (no absence greps):
#   - loss-preserving delegation: each nested sub-object is byte-identical to
#     invoking the corresponding composer directly on the same inputs (no
#     re-derivation, nothing dropped or reshaped).
#   - one deterministic, sorted-key JSON object that validates against the shipped
#     v0 schema and carries the schema field plus all three sub-artifacts.
#   - fail-safe: missing / empty inputs yield a well-formed bundle with each
#     sub-object present and zeroed (as its own composer emits), a zero exit,
#     never an error or partial output.
#   - strictly read-only: the whole input fixture tree is byte-identical after
#     every call (no run artifact / index / event / lease / task file created,
#     moved, or mutated), and engine/ctx-metrics.sh plus the three sibling
#     aggregators are byte-unchanged.
#   - evidence invariance / advocate-skeptic line: the bundle only MEASURES; it
#     confers no independence and reclassifies nothing (delegation is verbatim).
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ENGINE_HOME/engine/ctx-experiment-summary.sh"
SCHEMA="$ENGINE_HOME/schemas/orchestration/ctx-experiment-summary.v0.schema.json"
SIB_METRICS="$ENGINE_HOME/engine/ctx-metrics.sh"
SIB_REPORT="$ENGINE_HOME/engine/ctx-experiment-report.sh"
SIB_STRATEGY="$ENGINE_HOME/engine/ctx-experiment-strategy.sh"
SIB_ATTEMPTS="$ENGINE_HOME/engine/ctx-experiment-attempts.sh"

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
# The summary DELEGATES to the three sibling composers; they must be sourced too.
# shellcheck disable=SC1090
source "$SIB_REPORT"   || fail "sourcing $SIB_REPORT failed"
# shellcheck disable=SC1090
source "$SIB_STRATEGY" || fail "sourcing $SIB_STRATEGY failed"
# shellcheck disable=SC1090
source "$SIB_ATTEMPTS" || fail "sourcing $SIB_ATTEMPTS failed"
# shellcheck disable=SC1090
source "$TOOL" || fail "sourcing $TOOL failed"
[[ "$(type -t singular_ctx_experiment_summary_json)" == "function" ]] \
  || fail "singular_ctx_experiment_summary_json is not defined by $TOOL"

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

# --- Fixture: runs/<runId>/attempts/index.json + events.ndjson + metrics.json -
# Exercises ALL THREE metric families across BOTH arms in one input set.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp" "$VALIDATOR"' EXIT
fix="$tmp/fixture"
mkdir -p "$fix"
runs="$fix/runs"
events="$fix/events.ndjson"
metrics="$fix/metrics.json"

mk_index() { # runId taskId <json-attempts-array>
  local rid="$1" tid="$2" attempts="$3"
  mkdir -p "$runs/$rid/attempts"
  cat > "$runs/$rid/attempts/index.json" <<EOF
{"runId":"$rid","taskId":"$tid","attempts":$attempts}
EOF
}

# Arms: A={T1,T2}, B={T3,T4}. Attempts indexes for the attempts family.
mk_index R1 T1 '[{"n":1,"failureClass":"taint","findings":["f1","f2"]},{"n":2,"failureClass":"accepted","findings":[]}]'
mk_index R2 T2 '[{"n":1,"failureClass":"none","findings":["f1"]}]'
mk_index R3 T3 '[{"n":1,"failureClass":"window","findings":["f1","f2","f3"]},{"n":2,"failureClass":"taint","findings":[]}]'
mk_index R4 T4 '[{"n":1,"failureClass":""},{"n":2,"failureClass":"accepted","findings":["f1"]}]'

# Events: arm assignments (all families), paired audits + critic rechecks (report
# family escape/bias), and strategy selections + a resume failure (strategy fam).
cat > "$events" <<'EOF'
{"ts":"2026-07-12T00:00:00Z","type":"ctx.arm_assigned","data":{"taskId":"T1","arm":"A"}}
{"ts":"2026-07-12T00:00:01Z","type":"ctx.arm_assigned","data":{"taskId":"T2","arm":"A"}}
{"ts":"2026-07-12T00:00:02Z","type":"ctx.arm_assigned","data":{"taskId":"T3","arm":"B"}}
{"ts":"2026-07-12T00:00:03Z","type":"ctx.arm_assigned","data":{"taskId":"T4","arm":"B"}}
{"ts":"2026-07-12T00:00:10Z","type":"ctx.paired_audit","data":{"taskId":"T1","verdict":"accepted","findingsCount":0}}
{"ts":"2026-07-12T00:00:11Z","type":"ctx.paired_audit","data":{"taskId":"T2","verdict":"rejected","findingsCount":2}}
{"ts":"2026-07-12T00:00:12Z","type":"ctx.paired_audit","data":{"taskId":"T3","verdict":"accepted","findingsCount":0}}
{"ts":"2026-07-12T00:00:13Z","type":"ctx.paired_audit","data":{"taskId":"T4","verdict":"accepted","findingsCount":1}}
{"ts":"2026-07-12T00:00:20Z","type":"ctx.critic_recheck","data":{"taskId":"T2","dispositions":[{"id":"a","disposition":"addressed"},{"id":"b","disposition":"survives"}]}}
{"ts":"2026-07-12T00:00:21Z","type":"ctx.critic_recheck","data":{"taskId":"T4","dispositions":[{"id":"c","disposition":"obsolete"}]}}
{"ts":"2026-07-12T00:00:30Z","type":"context.strategy_selected","data":{"taskId":"T1","role":"implementer","strategy":"resume","reason":""}}
{"ts":"2026-07-12T00:00:31Z","type":"context.strategy_selected","data":{"taskId":"T2","role":"reviewer","strategy":"rehydrate","reason":"stale_lease"}}
{"ts":"2026-07-12T00:00:32Z","type":"context.strategy_selected","data":{"taskId":"T3","role":"planner","strategy":"fresh","reason":"no_snapshot"}}
{"ts":"2026-07-12T00:00:33Z","type":"context.strategy_selected","data":{"taskId":"T4","role":"implementer","strategy":"fresh","reason":""}}
{"ts":"2026-07-12T00:00:40Z","type":"context.resume_failed","data":{"taskId":"T1"}}
{"ts":"2026-07-12T00:00:50Z","type":"note.other","data":{"taskId":"T9"}}
EOF

# Per-task metrics (report family cost rollup).
cat > "$metrics" <<'EOF'
{"perTask":[
  {"taskId":"T1","tokens":100,"wallClockMs":1000},
  {"taskId":"T2","tokens":200,"wallClockMs":2000},
  {"taskId":"T3","tokens":300,"wallClockMs":3000},
  {"taskId":"T4","tokens":400,"wallClockMs":4000}
]}
EOF

before="$(tree_hash "$fix")"
m_before="$(file_hash "$SIB_METRICS")"
r_before="$(file_hash "$SIB_REPORT")"
s_before="$(file_hash "$SIB_STRATEGY")"
a_before="$(file_hash "$SIB_ATTEMPTS")"

# --- Direct composer outputs (the ground truth the bundle must nest verbatim) --
direct_report="$(singular_ctx_experiment_report_json "$events" "$metrics")"      || fail "report composer exited non-zero"
direct_strategy="$(singular_ctx_experiment_strategy_json "$events")"             || fail "strategy composer exited non-zero"
direct_attempts="$(singular_ctx_experiment_attempts_json "$runs" "$events")"     || fail "attempts composer exited non-zero"
printf '%s' "$direct_report"   > "$tmp/d_report.json"
printf '%s' "$direct_strategy" > "$tmp/d_strategy.json"
printf '%s' "$direct_attempts" > "$tmp/d_attempts.json"

# --- The composed bundle ------------------------------------------------------
# Signature: singular_ctx_experiment_summary_json [runs_dir] [events_file] [metrics_file]
bundle="$(singular_ctx_experiment_summary_json "$runs" "$events" "$metrics")" \
  || fail "summary aggregator exited non-zero on a valid fixture"
printf '%s' "$bundle" > "$tmp/bundle.json"
printf '%s' "$bundle" | validates "$SCHEMA" || fail "bundle did not validate against $SCHEMA"

# sorted-key determinism: bytes equal a re-serialization with sort_keys.
python3 - "$tmp/bundle.json" <<'PY' || fail "bundle keys not sorted / not canonical"
import json, sys
raw = open(sys.argv[1]).read().rstrip("\n")
obj = json.loads(raw)
canon = json.dumps(obj, indent=2, sort_keys=True)
assert raw == canon, "bundle bytes are not sorted-key canonical JSON"
print("sorted-ok")
PY

# schema field + all three nested sub-artifacts present, and loss-preserving:
# each nested sub-object is byte-identical to the direct composer invocation.
python3 - "$tmp/bundle.json" "$tmp/d_report.json" "$tmp/d_strategy.json" "$tmp/d_attempts.json" \
  <<'PY' || fail "bundle nesting not loss-preserving / not byte-identical to composers"
import json, sys
bundle = json.load(open(sys.argv[1]))
assert bundle["schema"] == "singular.orchestration.ctx-experiment-summary.v0", bundle["schema"]
for key, argi, subschema in (
    ("report", 2, "singular.orchestration.ctx-experiment-report.v0"),
    ("strategy", 3, "singular.orchestration.ctx-experiment-strategy.v0"),
    ("attempts", 4, "singular.orchestration.ctx-experiment-attempts.v0"),
):
    assert key in bundle, f"missing nested sub-artifact '{key}'"
    sub = bundle[key]
    assert sub.get("schema") == subschema, (key, sub.get("schema"))
    # composer's own canonical bytes (command substitution strips the trailing
    # newline the composer writes, so compare on the newline-normalized form).
    direct_text = open(sys.argv[argi]).read().rstrip("\n")
    # verbatim, loss-preserving delegation: re-serializing the nested object with
    # the composer's own canonical form reproduces the composer's exact bytes.
    nested_text = json.dumps(sub, indent=2, sort_keys=True)
    assert nested_text == direct_text, f"nested '{key}' is not byte-identical to its composer"
    # semantic equality too (no value dropped or reshaped).
    assert sub == json.loads(direct_text), f"nested '{key}' lost data vs its composer"
print("loss-preserving-ok")
PY

# --- Determinism: identical inputs -> byte-identical output -------------------
bundle2="$(singular_ctx_experiment_summary_json "$runs" "$events" "$metrics")"
[[ "$bundle" == "$bundle2" ]] || fail "bundle not deterministic across identical runs"

# --- Read-only: input fixture tree + sibling engine files byte-unchanged ------
after="$(tree_hash "$fix")"
[[ "$before" == "$after" ]] || fail "input fixture mutated by tooling (not read-only)"
[[ "$m_before" == "$(file_hash "$SIB_METRICS")" ]]  || fail "engine/ctx-metrics.sh was mutated"
[[ "$r_before" == "$(file_hash "$SIB_REPORT")" ]]   || fail "engine/ctx-experiment-report.sh was mutated"
[[ "$s_before" == "$(file_hash "$SIB_STRATEGY")" ]] || fail "engine/ctx-experiment-strategy.sh was mutated"
[[ "$a_before" == "$(file_hash "$SIB_ATTEMPTS")" ]] || fail "engine/ctx-experiment-attempts.sh was mutated"

# --- Fail-safe: every input missing -> well-formed, zeroed, schema-valid ------
empty_report="$(singular_ctx_experiment_report_json "$tmp/no-events.ndjson" "$tmp/no-metrics.json")"
empty_strategy="$(singular_ctx_experiment_strategy_json "$tmp/no-events.ndjson")"
empty_attempts="$(singular_ctx_experiment_attempts_json "$tmp/no-runs" "$tmp/no-events.ndjson")"
printf '%s' "$empty_report"   > "$tmp/e_report.json"
printf '%s' "$empty_strategy" > "$tmp/e_strategy.json"
printf '%s' "$empty_attempts" > "$tmp/e_attempts.json"

empty_bundle="$(singular_ctx_experiment_summary_json "$tmp/no-runs" "$tmp/no-events.ndjson" "$tmp/no-metrics.json")" \
  || fail "summary aggregator crashed on missing input (should fail safe)"
printf '%s' "$empty_bundle" > "$tmp/e_bundle.json"
printf '%s' "$empty_bundle" | validates "$SCHEMA" || fail "zeroed bundle did not validate against schema"
python3 - "$tmp/e_bundle.json" "$tmp/e_report.json" "$tmp/e_strategy.json" "$tmp/e_attempts.json" \
  <<'PY' || fail "empty-input bundle not well-formed / not the composers' own zeroed sub-objects"
import json, sys
b = json.load(open(sys.argv[1]))
assert b["schema"] == "singular.orchestration.ctx-experiment-summary.v0", b["schema"]
for key, argi in (("report", 2), ("strategy", 3), ("attempts", 4)):
    assert key in b, f"missing nested sub-artifact '{key}' on empty input"
    assert b[key] == json.load(open(sys.argv[argi])), f"nested '{key}' not the composer's own zeroed object"
# spot-check the fail-safe zeros propagate through the merge.
assert b["report"]["arms"]["A"]["accepted"] == 0, b["report"]["arms"]["A"]
assert b["strategy"]["hitRates"]["overall"]["total"] == 0, b["strategy"]["hitRates"]["overall"]
assert b["attempts"]["attemptsToAccept"]["A"]["acceptedTasks"] == 0, b["attempts"]["attemptsToAccept"]["A"]
print("empty-ok")
PY

# --- No-arg default invocation is also fail-safe -----------------------------
SINGULAR_RUNS_DIR="$tmp/no-runs" \
SINGULAR_EVENTS_FILE="$tmp/no-events.ndjson" \
SINGULAR_CTX_EXPERIMENT_METRICS_FILE="$tmp/no-metrics.json" \
  singular_ctx_experiment_summary_json >/dev/null \
  || fail "no-arg default invocation crashed instead of failing safe"

echo "ctx-experiment-summary tests passed"
