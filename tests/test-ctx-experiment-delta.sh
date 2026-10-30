#!/usr/bin/env bash
# Covers the read-only experiment treatment-vs-control DELTA tooling
# engine/ctx-experiment-delta.sh. This brick computes the A-vs-B CONTRAST the
# per-arm aggregators do not: arm B (treatment) minus arm A (control / M0 knob
# state) for each headline metric. It ships NO base metric of its own — it reads
# ONLY the summary bundle (delegating to singular_ctx_experiment_summary_json, or
# a supplied bundle source) and DIFFERENCES the already-computed per-arm values.
#
# Three chained slices, all inside engine/ctx-experiment-delta.sh:
#   1. singular_ctx_experiment_delta_record  — pure helper: two arm sub-objects +
#      a value path -> {a, b, delta=b-a, direction in {lower,higher,equal}};
#      a missing arm value is treated as zero.
#   2. singular_ctx_experiment_delta_metrics — applies the helper across the
#      headline metric set read from the summary bundle.
#   3. singular_ctx_experiment_delta_json    — public entry: obtain bundle, emit
#      ONE deterministic sorted-key JSON object under the v0 schema.
#
# Guarantees pinned BEHAVIORALLY over a fixture (no absence greps):
#   - per headline metric a record carries a, b, delta=B-A, neutral direction.
#   - each delta equals the difference of the corresponding per-arm bundle values
#     verbatim (no re-derivation; single upstream definition site).
#   - one deterministic, sorted-key JSON object that validates against the shipped
#     v0 schema.
#   - fail-safe: missing / empty inputs yield well-formed zeroed deltas and a zero
#     exit, never an error or partial output.
#   - NO better/worse or knob-flip judgment and NO per-knob attribution — only
#     numeric deltas and the neutral direction.
#   - strictly read-only: the input fixture tree is byte-identical after every
#     call, and engine/ctx-metrics.sh plus the sibling ctx-experiment-*.sh files
#     are byte-unchanged.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ENGINE_HOME/engine/ctx-experiment-delta.sh"
SCHEMA="$ENGINE_HOME/schemas/orchestration/ctx-experiment-delta.v0.schema.json"
SIB_METRICS="$ENGINE_HOME/engine/ctx-metrics.sh"
SIB_REPORT="$ENGINE_HOME/engine/ctx-experiment-report.sh"
SIB_STRATEGY="$ENGINE_HOME/engine/ctx-experiment-strategy.sh"
SIB_ATTEMPTS="$ENGINE_HOME/engine/ctx-experiment-attempts.sh"
SIB_SUMMARY="$ENGINE_HOME/engine/ctx-experiment-summary.sh"

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
# The delta delegates to the summary bundle, which delegates to the three
# per-family composers; all must be sourced too.
# shellcheck disable=SC1090
source "$SIB_REPORT"   || fail "sourcing $SIB_REPORT failed"
# shellcheck disable=SC1090
source "$SIB_STRATEGY" || fail "sourcing $SIB_STRATEGY failed"
# shellcheck disable=SC1090
source "$SIB_ATTEMPTS" || fail "sourcing $SIB_ATTEMPTS failed"
# shellcheck disable=SC1090
source "$SIB_SUMMARY"  || fail "sourcing $SIB_SUMMARY failed"
# shellcheck disable=SC1090
source "$TOOL" || fail "sourcing $TOOL failed"
for fn in singular_ctx_experiment_delta_record \
          singular_ctx_experiment_delta_metrics \
          singular_ctx_experiment_delta_json; do
  [[ "$(type -t "$fn")" == "function" ]] || fail "$fn is not defined by $TOOL"
done

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
    elif t in ("number", "integer"):
        if isinstance(data, bool) or not isinstance(data, (int, float)):
            errs.append(f"{path}: expected {t}"); return
        if "minimum" in schema and data < schema["minimum"]:
            errs.append(f"{path}: below minimum {schema['minimum']}")

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

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp" "$VALIDATOR"' EXIT

# ============================================================================
# Slice 1: pure helper — {a, b, delta=b-a, direction}, missing arm value -> 0.
# ============================================================================
rec="$(singular_ctx_experiment_delta_record '{"x":5}' '{"x":3}' x)"
python3 - <<PY || fail "helper record wrong for b<a"
import json
r = json.loads('''$rec''')
assert r == {"a":5,"b":3,"delta":-2,"direction":"lower"}, r
PY

rec="$(singular_ctx_experiment_delta_record '{}' '{"x":3}' x)"
python3 - <<PY || fail "helper did not treat missing arm A value as zero"
import json
r = json.loads('''$rec''')
assert r == {"a":0,"b":3,"delta":3,"direction":"higher"}, r
PY

rec="$(singular_ctx_experiment_delta_record '{"c":{"v":7}}' '{"c":{"v":7}}' c v)"
python3 - <<PY || fail "helper did not resolve nested path / equal direction"
import json
r = json.loads('''$rec''')
assert r == {"a":7,"b":7,"delta":0,"direction":"equal"}, r
PY

# ============================================================================
# Slice 2+3: synthetic summary-bundle fixture with distinct A / B values.
# Supplied via the bundle-source override so no runs corpus is needed.
# ============================================================================
bundle_file="$tmp/bundle.json"
cat > "$bundle_file" <<'EOF'
{
  "schema": "singular.orchestration.ctx-experiment-summary.v0",
  "report": {
    "arms": {
      "A": {"escapeRate": 0.5, "cost": {"tokensPerTask": 100, "wallClockMsPerTask": 1000}},
      "B": {"escapeRate": 0.2, "cost": {"tokensPerTask": 150, "wallClockMsPerTask": 800}}
    },
    "bias": {"directionalDisagreementRate": 0.25}
  },
  "attempts": {
    "attemptsToAccept": {
      "A": {"attemptsToAcceptMean": 2.0},
      "B": {"attemptsToAcceptMean": 1.5}
    },
    "findingsPerAttempt": {
      "A": {"findingsPerAttemptMean": 1.0},
      "B": {"findingsPerAttemptMean": 1.0}
    }
  },
  "strategy": {
    "hitRates": {
      "byArm": {
        "A": {"resumeHitRate": 0.4, "rehydrateHitRate": 0.7},
        "B": {"resumeHitRate": 0.6, "rehydrateHitRate": 0.3}
      }
    }
  }
}
EOF

out="$(SINGULAR_CTX_EXPERIMENT_DELTA_BUNDLE="$bundle_file" singular_ctx_experiment_delta_json)" \
  || fail "delta aggregator exited non-zero on a supplied bundle"
printf '%s' "$out" > "$tmp/out.json"
printf '%s' "$out" | validates "$SCHEMA" || fail "delta output did not validate against $SCHEMA"

# sorted-key determinism: bytes equal a re-serialization with sort_keys.
python3 - "$tmp/out.json" <<'PY' || fail "delta keys not sorted / not canonical"
import json, sys
raw = open(sys.argv[1]).read().rstrip("\n")
obj = json.loads(raw)
canon = json.dumps(obj, indent=2, sort_keys=True)
assert raw == canon, "delta bytes are not sorted-key canonical JSON"
PY

# Cross-check representative entries against the fixture and the schema field;
# also assert NO judgment / attribution fields leak in.
python3 - "$tmp/out.json" "$bundle_file" <<'PY' || fail "delta records do not match the fixture"
import json, sys
out = json.load(open(sys.argv[1]))
bundle = json.load(open(sys.argv[2]))
assert out["schema"] == "singular.orchestration.ctx-experiment-delta.v0", out["schema"]
d = out["deltas"]

want_keys = {
    "attemptsToAcceptMean", "biasDirectionalDisagreementRate",
    "costTokensPerTask", "costWallClockMsPerTask", "escapeRate",
    "findingsPerAttemptMean", "rehydrateHitRate", "resumeHitRate",
}
assert set(d) == want_keys, set(d) ^ want_keys

# every record has exactly {a,b,delta,direction} — no better/worse/knob field.
for k, r in d.items():
    assert set(r) == {"a", "b", "delta", "direction"}, (k, set(r))
    assert r["direction"] in ("lower", "higher", "equal"), (k, r["direction"])
    assert r["delta"] == r["b"] - r["a"], (k, r)

# representative fixture cross-checks (B minus A).
assert d["escapeRate"]["a"] == 0.5 and d["escapeRate"]["b"] == 0.2
assert d["escapeRate"]["delta"] < 0 and d["escapeRate"]["direction"] == "lower"
assert d["costTokensPerTask"]["delta"] == 50 and d["costTokensPerTask"]["direction"] == "higher"
assert d["costWallClockMsPerTask"]["delta"] == -200 and d["costWallClockMsPerTask"]["direction"] == "lower"
assert d["attemptsToAcceptMean"]["direction"] == "lower"
assert d["findingsPerAttemptMean"]["delta"] == 0 and d["findingsPerAttemptMean"]["direction"] == "equal"
assert d["resumeHitRate"]["direction"] == "higher"
assert d["rehydrateHitRate"]["direction"] == "lower"
# bias is a single cross-arm aggregate: surfaced without arm attribution.
assert d["biasDirectionalDisagreementRate"]["a"] == 0.25
assert d["biasDirectionalDisagreementRate"]["b"] == 0.25
assert d["biasDirectionalDisagreementRate"]["delta"] == 0

# each delta equals the difference of the corresponding per-arm bundle values
# VERBATIM (no re-derivation): the a/b of every record are the bundle's own
# per-arm numbers, read straight through.
def at(obj, *path):
    for p in path:
        obj = obj[p]
    return obj
assert d["escapeRate"]["a"] == at(bundle,"report","arms","A","escapeRate")
assert d["escapeRate"]["b"] == at(bundle,"report","arms","B","escapeRate")
assert d["costTokensPerTask"]["a"] == at(bundle,"report","arms","A","cost","tokensPerTask")
assert d["resumeHitRate"]["b"] == at(bundle,"strategy","hitRates","byArm","B","resumeHitRate")
assert d["attemptsToAcceptMean"]["a"] == at(bundle,"attempts","attemptsToAccept","A","attemptsToAcceptMean")
print("fixture-ok")
PY

# Determinism: identical input -> byte-identical output.
out2="$(SINGULAR_CTX_EXPERIMENT_DELTA_BUNDLE="$bundle_file" singular_ctx_experiment_delta_json)"
[[ "$out" == "$out2" ]] || fail "delta output not deterministic across identical runs"

# ============================================================================
# Delegation path: threaded corpus args -> the real summary bundle. Prove the
# delta's a/b are the summary bundle's per-arm values verbatim (single upstream
# definition site; the delta re-derives no base metric).
# ============================================================================
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
mk_index R1 T1 '[{"n":1,"failureClass":"taint","findings":["f1","f2"]},{"n":2,"failureClass":"accepted","findings":[]}]'
mk_index R2 T2 '[{"n":1,"failureClass":"none","findings":["f1"]}]'
mk_index R3 T3 '[{"n":1,"failureClass":"window","findings":["f1","f2","f3"]},{"n":2,"failureClass":"taint","findings":[]}]'
mk_index R4 T4 '[{"n":1,"failureClass":""},{"n":2,"failureClass":"accepted","findings":["f1"]}]'

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
EOF

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
u_before="$(file_hash "$SIB_SUMMARY")"

direct_bundle="$(singular_ctx_experiment_summary_json "$runs" "$events" "$metrics")" \
  || fail "summary composer exited non-zero"
printf '%s' "$direct_bundle" > "$tmp/direct_bundle.json"

delegated="$(singular_ctx_experiment_delta_json "$runs" "$events" "$metrics")" \
  || fail "delta aggregator exited non-zero on threaded corpus args"
printf '%s' "$delegated" > "$tmp/delegated.json"
printf '%s' "$delegated" | validates "$SCHEMA" || fail "delegated delta did not validate"

python3 - "$tmp/delegated.json" "$tmp/direct_bundle.json" <<'PY' || fail "delegated deltas are not the bundle's per-arm values verbatim"
import json, sys
d = json.load(open(sys.argv[1]))["deltas"]
b = json.load(open(sys.argv[2]))
def at(obj, *path):
    for p in path:
        obj = obj[p]
    return obj
checks = {
    "escapeRate": (("report","arms","A","escapeRate"), ("report","arms","B","escapeRate")),
    "costTokensPerTask": (("report","arms","A","cost","tokensPerTask"), ("report","arms","B","cost","tokensPerTask")),
    "costWallClockMsPerTask": (("report","arms","A","cost","wallClockMsPerTask"), ("report","arms","B","cost","wallClockMsPerTask")),
    "attemptsToAcceptMean": (("attempts","attemptsToAccept","A","attemptsToAcceptMean"), ("attempts","attemptsToAccept","B","attemptsToAcceptMean")),
    "findingsPerAttemptMean": (("attempts","findingsPerAttempt","A","findingsPerAttemptMean"), ("attempts","findingsPerAttempt","B","findingsPerAttemptMean")),
    "resumeHitRate": (("strategy","hitRates","byArm","A","resumeHitRate"), ("strategy","hitRates","byArm","B","resumeHitRate")),
    "rehydrateHitRate": (("strategy","hitRates","byArm","A","rehydrateHitRate"), ("strategy","hitRates","byArm","B","rehydrateHitRate")),
}
for key, (pa, pb) in checks.items():
    va, vb = at(b, *pa), at(b, *pb)
    assert d[key]["a"] == va, (key, d[key]["a"], va)
    assert d[key]["b"] == vb, (key, d[key]["b"], vb)
    assert d[key]["delta"] == vb - va, (key, d[key])
# bias: aggregate surfaced in both a and b, delta 0.
brate = at(b, "report", "bias", "directionalDisagreementRate")
assert d["biasDirectionalDisagreementRate"]["a"] == brate
assert d["biasDirectionalDisagreementRate"]["b"] == brate
assert d["biasDirectionalDisagreementRate"]["delta"] == 0
print("delegation-verbatim-ok")
PY

# --- Read-only: input fixture tree + sibling engine files byte-unchanged ------
after="$(tree_hash "$fix")"
[[ "$before" == "$after" ]] || fail "input fixture mutated by tooling (not read-only)"
[[ "$m_before" == "$(file_hash "$SIB_METRICS")" ]]  || fail "engine/ctx-metrics.sh was mutated"
[[ "$r_before" == "$(file_hash "$SIB_REPORT")" ]]   || fail "engine/ctx-experiment-report.sh was mutated"
[[ "$s_before" == "$(file_hash "$SIB_STRATEGY")" ]] || fail "engine/ctx-experiment-strategy.sh was mutated"
[[ "$a_before" == "$(file_hash "$SIB_ATTEMPTS")" ]] || fail "engine/ctx-experiment-attempts.sh was mutated"
[[ "$u_before" == "$(file_hash "$SIB_SUMMARY")" ]]  || fail "engine/ctx-experiment-summary.sh was mutated"

# ============================================================================
# Fail-safe: missing inputs -> well-formed zeroed deltas, schema-valid, exit 0.
# ============================================================================
empty="$(singular_ctx_experiment_delta_json "$tmp/no-runs" "$tmp/no-events.ndjson" "$tmp/no-metrics.json")" \
  || fail "delta aggregator crashed on missing input (should fail safe)"
printf '%s' "$empty" > "$tmp/empty.json"
printf '%s' "$empty" | validates "$SCHEMA" || fail "zeroed delta did not validate against schema"
python3 - "$tmp/empty.json" <<'PY' || fail "empty-input delta not well-formed / not fully zeroed"
import json, sys
out = json.load(open(sys.argv[1]))
assert out["schema"] == "singular.orchestration.ctx-experiment-delta.v0"
d = out["deltas"]
assert len(d) == 8, list(d)
for k, r in d.items():
    assert r == {"a": 0, "b": 0, "delta": 0, "direction": "equal"}, (k, r)
print("fail-safe-ok")
PY

# A supplied-but-unreadable bundle source is also fail-safe.
empty2="$(SINGULAR_CTX_EXPERIMENT_DELTA_BUNDLE="$tmp/nope.json" singular_ctx_experiment_delta_json)" \
  || fail "delta aggregator crashed on unreadable bundle source (should fail safe)"
printf '%s' "$empty2" | validates "$SCHEMA" || fail "unreadable-source delta did not validate"

# No-arg default invocation is also fail-safe.
SINGULAR_RUNS_DIR="$tmp/no-runs" \
SINGULAR_EVENTS_FILE="$tmp/no-events.ndjson" \
SINGULAR_CTX_EXPERIMENT_METRICS_FILE="$tmp/no-metrics.json" \
  singular_ctx_experiment_delta_json >/dev/null \
  || fail "no-arg default invocation crashed instead of failing safe"

echo "ctx-experiment-delta tests passed"
