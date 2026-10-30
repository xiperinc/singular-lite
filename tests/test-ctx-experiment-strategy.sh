#!/usr/bin/env bash
# Covers the read-only experiment-strategy secondary raw-metrics tooling
# engine/ctx-experiment-strategy.sh. Given a synthetic events.ndjson
# (context.strategy_selected + context.resume_failed + ctx.arm_assigned, mixed
# resume/rehydrate/fresh across arms A/B and roles implementer/planner/reviewer),
# the aggregators compute:
#   1. resume + rehydrate hit rates (each = selections of that strategy / total
#      strategy selections), sliceable per arm (A and B) and per role; the
#      denominator is routing decisions, not accepted tasks.
#   2. the gate-refusal reason mix: a stable sorted reason-to-count map over the
#      reason field of NON-resume (fresh + rehydrate) selections, plus a distinct
#      context.resume_failed count; an absent/empty reason buckets under a stable
#      'unspecified' key, never dropped.
#   3. one deterministic, sorted-key JSON artifact merging the per-arm and per-role
#      hit rates with the refusal reason mix; it validates against the shipped v0
#      schema.
#
# Guarantees pinned BEHAVIORALLY over a fixture (no absence greps):
#   - strictly read-only: the whole input fixture tree is byte-identical after
#     every call (no run artifact / index / event / lease / task file created,
#     moved, or mutated), and engine/ctx-experiment-report.sh is byte-unchanged.
#   - fail-safe: missing / empty inputs yield a well-formed zeroed artifact and a
#     zero exit, never an error or partial output.
#   - deterministic: identical inputs -> byte-identical stdout.
#   - evidence invariance: the aggregator only MEASURES routing outcomes; it never
#     reclassifies a resume/rehydrate selection as fresh or vice versa (the tallies
#     partition selections exactly by their recorded strategy).
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ENGINE_HOME/engine/ctx-experiment-strategy.sh"
SCHEMA="$ENGINE_HOME/schemas/orchestration/ctx-experiment-strategy.v0.schema.json"
SIBLING="$ENGINE_HOME/engine/ctx-experiment-report.sh"

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
for fn in singular_ctx_experiment_hit_rates \
          singular_ctx_experiment_refusal_mix \
          singular_ctx_experiment_strategy_json; do
  [[ "$(type -t "$fn")" == "function" ]] || fail "$fn is not defined by $TOOL"
done

# --- minimal schema-driven validator (no jsonschema module ships here) --------
# Mirrors tests/test-ctx-experiment-report.sh: object/array/string/number/integer
# with const/enum/required/additionalProperties/minimum so the emitted artifact is
# checked against the SHIPPED schema.
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

# --- Fixture: events.ndjson --------------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp" "$VALIDATOR"' EXIT
# Tool inputs live in an isolated fixture dir so the read-only assertion sees ONLY
# what the tool might touch, never the test's own output files written to $tmp.
fix="$tmp/fixture"
mkdir -p "$fix"
events="$fix/events.ndjson"

# Arms: A={T1,T2}, B={T3,T4}; T5 has NO arm assignment (overall-only).
# strategy_selected events (9 total routing decisions):
#   1 T1/A implementer resume
#   2 T1/A implementer fresh      reason=window-pressure
#   3 T2/A reviewer    rehydrate  reason=diff-volume
#   4 T2/A planner     resume
#   5 T3/B implementer fresh      reason=""            (empty  -> unspecified)
#   6 T3/B reviewer    resume
#   7 T4/B planner     rehydrate  (reason key absent   -> unspecified)
#   8 T4/B implementer fresh      reason=taint
#   9 T5/- reviewer    resume
# Expected hit rates (resume/total, rehydrate/total):
#   overall total=9 resume=4 rehydrate=2  -> 4/9, 2/9
#   arm A   total=4 resume=2 rehydrate=1  -> 2/4, 1/4
#   arm B   total=4 resume=1 rehydrate=1  -> 1/4, 1/4   (T5 excluded, no arm)
#   role implementer total=4 resume=1 rehydrate=0 -> 1/4, 0
#   role reviewer    total=3 resume=2 rehydrate=1 -> 2/3, 1/3
#   role planner     total=2 resume=1 rehydrate=1 -> 1/2, 1/2
# Reason mix over non-resume (fresh+rehydrate) selections {2,3,5,7,8}:
#   {"diff-volume":1,"taint":1,"unspecified":2,"window-pressure":1}
# resume_failed events: 2.
cat > "$events" <<'EOF'
{"ts":"2026-07-12T00:00:00Z","type":"ctx.arm_assigned","message":"m","data":{"taskId":"T1","arm":"A"}}
{"ts":"2026-07-12T00:00:01Z","type":"ctx.arm_assigned","message":"m","data":{"taskId":"T2","arm":"A"}}
{"ts":"2026-07-12T00:00:02Z","type":"ctx.arm_assigned","message":"m","data":{"taskId":"T3","arm":"B"}}
{"ts":"2026-07-12T00:00:03Z","type":"ctx.arm_assigned","message":"m","data":{"taskId":"T4","arm":"B"}}
{"ts":"2026-07-12T00:01:00Z","type":"context.strategy_selected","message":"m","data":{"taskId":"T1","role":"implementer","attempt":1,"strategy":"resume","reason":"eligible"}}
{"ts":"2026-07-12T00:01:01Z","type":"context.strategy_selected","message":"m","data":{"taskId":"T1","role":"implementer","attempt":2,"strategy":"fresh","reason":"window-pressure"}}
{"ts":"2026-07-12T00:01:02Z","type":"context.strategy_selected","message":"m","data":{"taskId":"T2","role":"reviewer","attempt":1,"strategy":"rehydrate","reason":"diff-volume"}}
{"ts":"2026-07-12T00:01:03Z","type":"context.strategy_selected","message":"m","data":{"taskId":"T2","role":"planner","attempt":1,"strategy":"resume","reason":"eligible"}}
{"ts":"2026-07-12T00:01:04Z","type":"context.strategy_selected","message":"m","data":{"taskId":"T3","role":"implementer","attempt":1,"strategy":"fresh","reason":""}}
{"ts":"2026-07-12T00:01:05Z","type":"context.strategy_selected","message":"m","data":{"taskId":"T3","role":"reviewer","attempt":1,"strategy":"resume","reason":"eligible"}}
{"ts":"2026-07-12T00:01:06Z","type":"context.strategy_selected","message":"m","data":{"taskId":"T4","role":"planner","attempt":1,"strategy":"rehydrate"}}
{"ts":"2026-07-12T00:01:07Z","type":"context.strategy_selected","message":"m","data":{"taskId":"T4","role":"implementer","attempt":1,"strategy":"fresh","reason":"taint"}}
{"ts":"2026-07-12T00:01:08Z","type":"context.strategy_selected","message":"m","data":{"taskId":"T5","role":"reviewer","attempt":1,"strategy":"resume","reason":"eligible"}}
{"ts":"2026-07-12T00:02:00Z","type":"context.resume_failed","message":"m","data":{"taskId":"T1","role":"implementer","attempt":1}}
{"ts":"2026-07-12T00:02:01Z","type":"context.resume_failed","message":"m","data":{"taskId":"T3","role":"reviewer","attempt":1}}
{"ts":"2026-07-12T00:02:02Z","type":"note.other","message":"m","data":{"taskId":"T9"}}
EOF

before="$(tree_hash "$fix")"
sibling_before="$(file_hash "$SIBLING")"

# --- Slice 1: resume / rehydrate hit rates, sliced per arm and per role -------
hr="$(singular_ctx_experiment_hit_rates "$events")" \
  || fail "hit-rate aggregator exited non-zero on a valid fixture"
printf '%s' "$hr" > "$tmp/hr.json"
python3 - "$tmp/hr.json" <<'PY' || fail "hit rates did not match expected"
import json, sys
m = json.load(open(sys.argv[1]))
def close(a, b): return abs(a - b) < 1e-9
def chk(s, total, resume, rehydrate):
    assert s["total"] == total, s
    assert s["resume"] == resume, s
    assert s["rehydrate"] == rehydrate, s
    assert close(s["resumeHitRate"], (resume/total) if total else 0.0), s
    assert close(s["rehydrateHitRate"], (rehydrate/total) if total else 0.0), s
chk(m["overall"], 9, 4, 2)
chk(m["byArm"]["A"], 4, 2, 1)
chk(m["byArm"]["B"], 4, 1, 1)
chk(m["byRole"]["implementer"], 4, 1, 0)
chk(m["byRole"]["reviewer"], 3, 2, 1)
chk(m["byRole"]["planner"], 2, 1, 1)
print("hit-rate-ok")
PY

# --- Slice 2: gate-refusal reason mix + resume_failed count -------------------
rm_="$(singular_ctx_experiment_refusal_mix "$events")" \
  || fail "refusal-mix aggregator exited non-zero on a valid fixture"
printf '%s' "$rm_" > "$tmp/rm.json"
python3 - "$tmp/rm.json" <<'PY' || fail "refusal mix did not match expected"
import json, sys
m = json.load(open(sys.argv[1]))
rmix = m["reasonMix"]
assert rmix == {"diff-volume":1,"taint":1,"unspecified":2,"window-pressure":1}, rmix
# stable sorted key order (empty AND missing reason both bucket to 'unspecified').
assert list(rmix.keys()) == sorted(rmix.keys()), list(rmix.keys())
assert m["resumeFailed"] == 2, m
print("refusal-mix-ok")
PY

# --- Slice 3: composed, schema-valid, deterministic artifact -----------------
art="$(singular_ctx_experiment_strategy_json "$events")" \
  || fail "strategy aggregator exited non-zero on a valid fixture"
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
assert m["schema"] == "singular.orchestration.ctx-experiment-strategy.v0", m["schema"]
hr = m["hitRates"]
assert hr["overall"]["total"] == 9 and hr["overall"]["resume"] == 4, hr["overall"]
assert close(hr["overall"]["resumeHitRate"], 4/9), hr["overall"]
assert close(hr["overall"]["rehydrateHitRate"], 2/9), hr["overall"]
assert close(hr["byArm"]["A"]["resumeHitRate"], 2/4), hr["byArm"]["A"]
assert close(hr["byArm"]["B"]["rehydrateHitRate"], 1/4), hr["byArm"]["B"]
assert close(hr["byRole"]["reviewer"]["resumeHitRate"], 2/3), hr["byRole"]["reviewer"]
rmix = m["refusalMix"]["reasonMix"]
assert rmix == {"diff-volume":1,"taint":1,"unspecified":2,"window-pressure":1}, rmix
assert m["refusalMix"]["resumeFailed"] == 2, m["refusalMix"]
# Evidence invariance: strategy tallies partition the selections exactly; the
# resume/rehydrate counts plus non-resume (reason-mix) selections sum to total.
nonresume = sum(rmix.values())
assert hr["overall"]["resume"] + nonresume == hr["overall"]["total"], (hr, nonresume)
print("composed-ok")
PY

# --- Determinism: identical inputs -> byte-identical output ------------------
art2="$(singular_ctx_experiment_strategy_json "$events")"
[[ "$art" == "$art2" ]] || fail "composed artifact not deterministic across identical runs"

# --- Read-only: input fixture tree + sibling report tool byte-unchanged -------
after="$(tree_hash "$fix")"
[[ "$before" == "$after" ]] || fail "input fixture mutated by tooling (not read-only)"
sibling_after="$(file_hash "$SIBLING")"
[[ "$sibling_before" == "$sibling_after" ]] \
  || fail "engine/ctx-experiment-report.sh was mutated by this tooling"

# --- Fail-safe: missing input -> well-formed zeroed artifact ------------------
missing_events="$tmp/no-such-events.ndjson"
out_empty="$(singular_ctx_experiment_strategy_json "$missing_events")" \
  || fail "strategy aggregator crashed on missing input (should fail safe)"
printf '%s' "$out_empty" > "$tmp/empty.json"
printf '%s' "$out_empty" | validates "$SCHEMA" || fail "zeroed artifact did not validate against schema"
python3 - "$tmp/empty.json" <<'PY' || fail "empty-input artifact not well-formed/zeroed"
import json, sys
m = json.load(open(sys.argv[1]))
hr = m["hitRates"]
for s in (hr["overall"], hr["byArm"]["A"], hr["byArm"]["B"],
          hr["byRole"]["implementer"], hr["byRole"]["planner"], hr["byRole"]["reviewer"]):
    assert s["total"] == 0 and s["resume"] == 0 and s["rehydrate"] == 0, s
    assert s["resumeHitRate"] == 0 and s["rehydrateHitRate"] == 0, s
assert m["refusalMix"]["reasonMix"] == {}, m["refusalMix"]
assert m["refusalMix"]["resumeFailed"] == 0, m["refusalMix"]
print("empty-ok")
PY

# empty events file (present but zero records) is also fail-safe.
: > "$tmp/empty-events.ndjson"
singular_ctx_experiment_hit_rates "$tmp/empty-events.ndjson" >/dev/null \
  || fail "hit-rate aggregator crashed on an empty events file"
singular_ctx_experiment_refusal_mix "$tmp/empty-events.ndjson" >/dev/null \
  || fail "refusal-mix aggregator crashed on an empty events file"

# --- No-arg default invocation is also fail-safe -----------------------------
SINGULAR_EVENTS_FILE="$missing_events" \
  singular_ctx_experiment_strategy_json >/dev/null \
  || fail "no-arg default invocation crashed instead of failing safe"

echo "ctx-experiment-strategy tests passed"
