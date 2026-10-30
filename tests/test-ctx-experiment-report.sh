#!/usr/bin/env bash
# Covers the read-only experiment-report raw-metrics tooling
# engine/ctx-experiment-report.sh. Given a synthetic events.ndjson (ctx.arm_assigned
# + ctx.paired_audit + ctx.critic_recheck across arms A/B) and a per-task metrics
# file, the aggregators compute:
#   1. per-arm escape rate  = flagged / accepted-and-audited, per arm
#   2. bias directional-disagreement rate = fraction of findings in fresh-paired-
#      audit-flagged tasks that the context-aware ctx.critic_recheck dispositioned
#      addressed|obsolete (NOT survives)
#   3. one deterministic, sorted-key JSON artifact merging both arms' escape rates,
#      a per-arm cost rollup (tokens + wall-clock per accepted task), and the bias
#      rate; the artifact validates against the shipped v0 schema.
#
# Guarantees pinned BEHAVIORALLY over a fixture (no absence greps):
#   - strictly read-only: the whole workspace tree is byte-identical after every
#     call (no run artifact / index / event / lease / task file created, moved, or
#     mutated).
#   - fail-safe: missing / empty inputs yield a well-formed zeroed artifact and a
#     zero exit, never an error or partial output.
#   - deterministic: identical inputs -> byte-identical stdout.
#   - evidence invariance: a context-aware "addressed" disposition never removes a
#     fresh paired-audit flag from the escape/flag set; it is only MEASURED as bias.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ENGINE_HOME/engine/ctx-experiment-report.sh"
SCHEMA="$ENGINE_HOME/schemas/orchestration/ctx-experiment-report.v0.schema.json"

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
for fn in singular_ctx_experiment_escape_rates \
          singular_ctx_experiment_bias_rate \
          singular_ctx_experiment_report_json; do
  [[ "$(type -t "$fn")" == "function" ]] || fail "$fn is not defined by $TOOL"
done

# --- minimal schema-driven validator (no jsonschema module ships here) --------
# Mirrors tests/test-ctx-rehydrate-manifest-schema.sh, extended with number/
# integer/minimum so the emitted artifact is checked against the SHIPPED schema.
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
        if schema.get("additionalProperties") is False:
            for k in data:
                if k not in props:
                    errs.append(f"{path}: unknown property '{k}'")
        for k, v in data.items():
            if k in props:
                validate(v, props[k], f"{path}/{k}", errs)
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

# --- Fixture: events.ndjson + per-task metrics -------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp" "$VALIDATOR"' EXIT
# Tool inputs live in an isolated fixture dir so the read-only assertion sees ONLY
# what the tool might touch — never the test's own output files written to $tmp.
fix="$tmp/fixture"
mkdir -p "$fix"
events="$fix/events.ndjson"
metrics="$fix/metrics.json"

# Arms: A={T1,T2,T3}, B={T4,T5}. Paired audits mark disagreements (escapes):
#   A audited={T1,T2,T3}, flagged={T1,T3}   -> escapeRate 2/3
#   B audited={T4,T5},    flagged={T5}       -> escapeRate 1/2
# critic_recheck dispositions on FLAGGED tasks feed the bias rate; a recheck on
# the NON-flagged T2 must be excluded (only paired-audit-flagged findings count).
cat > "$events" <<'EOF'
{"ts":"2026-07-12T00:00:00Z","type":"ctx.arm_assigned","message":"m","data":{"taskId":"T1","arm":"A"}}
{"ts":"2026-07-12T00:00:01Z","type":"ctx.arm_assigned","message":"m","data":{"taskId":"T2","arm":"A"}}
{"ts":"2026-07-12T00:00:02Z","type":"ctx.arm_assigned","message":"m","data":{"taskId":"T3","arm":"A"}}
{"ts":"2026-07-12T00:00:03Z","type":"ctx.arm_assigned","message":"m","data":{"taskId":"T4","arm":"B"}}
{"ts":"2026-07-12T00:00:04Z","type":"ctx.arm_assigned","message":"m","data":{"taskId":"T5","arm":"B"}}
{"ts":"2026-07-12T00:00:10Z","type":"ctx.paired_audit","message":"m","data":{"taskId":"T1","runId":"R1","verdict":"reject","findingsCount":1,"disagreement":true,"agreement":false}}
{"ts":"2026-07-12T00:00:11Z","type":"ctx.paired_audit","message":"m","data":{"taskId":"T2","runId":"R2","verdict":"accepted","findingsCount":0,"disagreement":false,"agreement":true}}
{"ts":"2026-07-12T00:00:12Z","type":"ctx.paired_audit","message":"m","data":{"taskId":"T3","runId":"R3","verdict":"accepted","findingsCount":2,"disagreement":true,"agreement":false}}
{"ts":"2026-07-12T00:00:13Z","type":"ctx.paired_audit","message":"m","data":{"taskId":"T4","runId":"R4","verdict":"accepted","findingsCount":0,"disagreement":false,"agreement":true}}
{"ts":"2026-07-12T00:00:14Z","type":"ctx.paired_audit","message":"m","data":{"taskId":"T5","runId":"R5","verdict":"reject","findingsCount":1,"disagreement":true,"agreement":false}}
{"ts":"2026-07-12T00:00:20Z","type":"ctx.critic_recheck","message":"m","data":{"taskId":"T1","runId":"R1","role":"plan-critic","dispositions":[{"id":"f-000000000001","disposition":"addressed"},{"id":"f-000000000002","disposition":"survives"},{"id":"f-000000000003","disposition":"obsolete"}]}}
{"ts":"2026-07-12T00:00:21Z","type":"ctx.critic_recheck","message":"m","data":{"taskId":"T3","runId":"R3","role":"plan-critic","dispositions":[{"id":"f-000000000004","disposition":"survives"},{"id":"f-000000000005","disposition":"survives"}]}}
{"ts":"2026-07-12T00:00:22Z","type":"ctx.critic_recheck","message":"m","data":{"taskId":"T5","runId":"R5","role":"plan-critic","dispositions":[{"id":"f-000000000006","disposition":"addressed"}]}}
{"ts":"2026-07-12T00:00:23Z","type":"ctx.critic_recheck","message":"m","data":{"taskId":"T2","runId":"R2","role":"plan-critic","dispositions":[{"id":"f-000000000007","disposition":"addressed"}]}}
{"ts":"2026-07-12T00:00:24Z","type":"note.other","message":"m","data":{"taskId":"T9"}}
EOF

cat > "$metrics" <<'EOF'
[
  {"taskId":"T1","tokens":100,"wallClockMs":1000},
  {"taskId":"T2","tokens":200,"wallClockMs":2000},
  {"taskId":"T3","tokens":300,"wallClockMs":3000},
  {"taskId":"T4","tokens":400,"wallClockMs":4000},
  {"taskId":"T5","tokens":500,"wallClockMs":5000}
]
EOF

before="$(tree_hash "$fix")"

# --- Slice 1: per-arm escape rate --------------------------------------------
esc="$(singular_ctx_experiment_escape_rates "$events")" \
  || fail "escape-rate aggregator exited non-zero on a valid fixture"
printf '%s' "$esc" > "$tmp/esc.json"
python3 - "$tmp/esc.json" <<'PY' || fail "escape rates did not match expected"
import json, sys
m = json.load(open(sys.argv[1]))
def close(a, b): return abs(a - b) < 1e-9
A, B = m["A"], m["B"]
assert A["accepted"] == 3, A
assert A["flagged"] == 2, A
assert close(A["escapeRate"], 2/3), A
assert B["accepted"] == 2, B
assert B["flagged"] == 1, B
assert close(B["escapeRate"], 1/2), B
print("escape-ok")
PY

# --- Slice 2: bias directional-disagreement rate -----------------------------
bias="$(singular_ctx_experiment_bias_rate "$events")" \
  || fail "bias aggregator exited non-zero on a valid fixture"
printf '%s' "$bias" > "$tmp/bias.json"
python3 - "$tmp/bias.json" <<'PY' || fail "bias rate did not match expected"
import json, sys
m = json.load(open(sys.argv[1]))
# Flagged tasks T1(3 findings; addressed,survives,obsolete), T3(2; survives*2),
# T5(1; addressed). T2's recheck excluded (not paired-audit-flagged).
assert m["flaggedFindings"] == 6, m
assert m["directionalDisagreements"] == 3, m
assert abs(m["directionalDisagreementRate"] - 0.5) < 1e-9, m
print("bias-ok")
PY

# --- Slice 3: composed, schema-valid, deterministic artifact -----------------
art="$(singular_ctx_experiment_report_json "$events" "$metrics")" \
  || fail "report aggregator exited non-zero on a valid fixture"
printf '%s' "$art" > "$tmp/art.json"
printf '%s' "$art" | validates "$SCHEMA" || fail "artifact did not validate against $SCHEMA"

# sorted-key determinism: bytes equal a re-serialization with sort_keys.
python3 - "$tmp/art.json" <<'PY' || fail "artifact keys not sorted / not canonical"
import json, sys
# Trailing newline is stripped by the shell's $(...) capture; compare the body.
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
assert m["schema"] == "singular.orchestration.ctx-experiment-report.v0", m["schema"]
A, B = m["arms"]["A"], m["arms"]["B"]
assert close(A["escapeRate"], 2/3) and A["accepted"] == 3 and A["flagged"] == 2, A
assert close(B["escapeRate"], 1/2) and B["accepted"] == 2 and B["flagged"] == 1, B
# cost rollup over accepted (audited) tasks, grouped by arm.
ca, cb = A["cost"], B["cost"]
assert ca["tasks"] == 3 and ca["tokensTotal"] == 600 and ca["wallClockMsTotal"] == 6000, ca
assert close(ca["tokensPerTask"], 200) and close(ca["wallClockMsPerTask"], 2000), ca
assert cb["tasks"] == 2 and cb["tokensTotal"] == 900 and cb["wallClockMsTotal"] == 9000, cb
assert close(cb["tokensPerTask"], 450) and close(cb["wallClockMsPerTask"], 4500), cb
bz = m["bias"]
assert bz["flaggedFindings"] == 6 and bz["directionalDisagreements"] == 3, bz
assert close(bz["directionalDisagreementRate"], 0.5), bz
print("composed-ok")
PY

# --- Determinism: identical inputs -> byte-identical output ------------------
art2="$(singular_ctx_experiment_report_json "$events" "$metrics")"
[[ "$art" == "$art2" ]] || fail "composed artifact not deterministic across identical runs"

# --- Read-only: input fixture tree byte-unchanged after every call -----------
after="$(tree_hash "$fix")"
[[ "$before" == "$after" ]] || fail "input fixture mutated by tooling (not read-only)"

# --- Fail-safe: missing / empty inputs -> well-formed zeroed artifact --------
missing_events="$tmp/no-such-events.ndjson"
missing_metrics="$tmp/no-such-metrics.json"
out_empty="$(singular_ctx_experiment_report_json "$missing_events" "$missing_metrics")" \
  || fail "report aggregator crashed on missing inputs (should fail safe)"
printf '%s' "$out_empty" > "$tmp/empty.json"
printf '%s' "$out_empty" | validates "$SCHEMA" || fail "zeroed artifact did not validate against schema"
python3 - "$tmp/empty.json" <<'PY' || fail "empty-input artifact not well-formed/zeroed"
import json, sys
m = json.load(open(sys.argv[1]))
for arm in ("A", "B"):
    a = m["arms"][arm]
    assert a["accepted"] == 0 and a["flagged"] == 0 and a["escapeRate"] == 0, a
    c = a["cost"]
    assert c["tasks"] == 0 and c["tokensTotal"] == 0 and c["wallClockMsTotal"] == 0, c
    assert c["tokensPerTask"] == 0 and c["wallClockMsPerTask"] == 0, c
b = m["bias"]
assert b["flaggedFindings"] == 0 and b["directionalDisagreements"] == 0, b
assert b["directionalDisagreementRate"] == 0, b
print("empty-ok")
PY

# empty events file (present but zero records) is also fail-safe.
: > "$tmp/empty-events.ndjson"
singular_ctx_experiment_escape_rates "$tmp/empty-events.ndjson" >/dev/null \
  || fail "escape aggregator crashed on an empty events file"
singular_ctx_experiment_bias_rate "$tmp/empty-events.ndjson" >/dev/null \
  || fail "bias aggregator crashed on an empty events file"

# --- No-arg default invocation is also fail-safe -----------------------------
SINGULAR_EVENTS_FILE="$missing_events" SINGULAR_CTX_EXPERIMENT_METRICS_FILE="$missing_metrics" \
  singular_ctx_experiment_report_json >/dev/null \
  || fail "no-arg default invocation crashed instead of failing safe"

echo "ctx-experiment-report tests passed"
