#!/usr/bin/env bash
# Contract test for the two rehydrate-path manifest schemas:
#   schemas/orchestration/ctx-rehydrate-manifest.v0.schema.json          (core)
#   schemas/orchestration/ctx-rehydrate-authored-manifest.v0.schema.json (authored)
#
# The `rehydrate-path` node (stage S5-routing, layer engine_runtime) records two
# versioned manifest contracts into the `context.strategy_selected` event, yet
# neither had a backing JSON Schema while every other versioned contract under
# schemas/orchestration/ does. This is the strict-test-first conformance guard
# that pins both schemas to the REAL emitted bytes: it drives the actual
# emitters over fixtures and asserts the emitted bytes conform, that the schemas
# are additive (a payload WITHOUT the optional key validates too), and that the
# authored schema can never certify an entry as authoritative.
#
# Faithful-to-emitter: assertions validate LIVE emitter output (from
# singular_ctx_rehydrate_manifest / singular_ctx_rehydrate_authored_manifest via
# engine/lib.sh), not a hand-authored sample, so a schema that diverges from
# what the engine emits fails.
#
# No jsonschema module ships in this environment, so this test carries a tiny
# schema-driven validator (const/enum/pattern/minLength/required/additional
# Properties/items/type) that reads the ACTUAL schema files — fixtures are
# checked against the shipped contract, not a hand-rolled copy of it. This
# mirrors tests/test-plan-critique-schema.sh.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEMA_CORE="$ENGINE_HOME/schemas/orchestration/ctx-rehydrate-manifest.v0.schema.json"
SCHEMA_AUTHORED="$ENGINE_HOME/schemas/orchestration/ctx-rehydrate-authored-manifest.v0.schema.json"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Source the engine so the real emitters are in scope (the ctx-*.sh files load
# via the context module glob block in engine/lib.sh).
source "$ENGINE_HOME/engine/lib.sh"
type singular_ctx_rehydrate_manifest >/dev/null 2>&1 \
  || fail "singular_ctx_rehydrate_manifest not defined after sourcing engine/lib.sh"
type singular_ctx_rehydrate_authored_manifest >/dev/null 2>&1 \
  || fail "singular_ctx_rehydrate_authored_manifest not defined after sourcing engine/lib.sh"

# RED precondition: the schema files must be absent before they are authored, so
# validation cannot resolve them and this guard fails.
[[ -f "$SCHEMA_CORE" ]]     || fail "missing schema: $SCHEMA_CORE"
[[ -f "$SCHEMA_AUTHORED" ]] || fail "missing schema: $SCHEMA_AUTHORED"

# --- minimal schema-driven validator -----------------------------------------
VALIDATOR="$(mktemp)"
trap 'rm -f "$VALIDATOR"' EXIT
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

validates()      { python3 "$VALIDATOR" "$1" >/dev/null 2>&1; }
assert_valid()   { printf '%s' "$2" | validates "$1" || fail "$3: should VALIDATE but did not"; }
assert_invalid() { printf '%s' "$2" | validates "$1" && fail "$3: should be REJECTED but validated"; return 0; }

# --- deterministic durable-source fixtures -----------------------------------
TMP="$(mktemp -d)"
trap 'rm -f "$VALIDATOR"; rm -rf "$TMP"' EXIT
printf 'task packet body'        > "$TMP/task-packet.txt"
printf 'implementer capsule body'> "$TMP/impl-capsule.txt"
printf 'decision record body'    > "$TMP/decision.txt"

# --- core-manifest conformance (LIVE emitter, multiple sources) --------------
CORE="$(singular_ctx_rehydrate_manifest \
  "task-packet=$TMP/task-packet.txt" \
  "implementer-capsule=$TMP/impl-capsule.txt" \
  "decision-record=$TMP/decision.txt")"
assert_valid "$SCHEMA_CORE" "$CORE" "live core manifest (multi-source)"

core_schema_const="$(printf '%s' "$CORE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["schema"])')"
[[ "$core_schema_const" == "singular.orchestration.ctx-rehydrate-manifest.v0" ]] \
  || fail "core manifest schema const unexpected: $core_schema_const"

# --- empty-source robustness (sources: []) -----------------------------------
CORE_EMPTY="$(singular_ctx_rehydrate_manifest)"
assert_valid "$SCHEMA_CORE" "$CORE_EMPTY" "live core manifest (empty sources)"

# --- authored-manifest conformance (LIVE emitter) ----------------------------
cat > "$TMP/authored.json" <<JSON
{"entries":[
  {"id":"auth-guide-a","body":"authored knowledge body A","load-when":["implement"],"freshness":"2026-07-10"},
  {"id":"auth-guide-b","body":"authored knowledge body B","load-when":["implement"],"freshness":"2026-07-10"}
]}
JSON
AUTHORED="$(singular_ctx_rehydrate_authored_manifest "$TMP/authored.json" implement)"
[[ -n "$AUTHORED" ]] || fail "authored manifest emitter produced no output over fixture"
assert_valid "$SCHEMA_AUTHORED" "$AUTHORED" "live authored manifest"

auth_schema_const="$(printf '%s' "$AUTHORED" | python3 -c 'import json,sys; print(json.load(sys.stdin)["schema"])')"
[[ "$auth_schema_const" == "singular.orchestration.ctx-rehydrate-authored-manifest.v0" ]] \
  || fail "authored manifest schema const unexpected: $auth_schema_const"

# Every emitted authored entry must carry class=authored-knowledge /
# authoritative=false (the schema pins them; assert the live bytes agree).
printf '%s' "$AUTHORED" | python3 -c '
import json, sys
obj = json.load(sys.stdin)
for s in obj["sources"]:
    assert s["class"] == "authored-knowledge", s
    assert s["authoritative"] is False, s
' || fail "authored entries must be class=authored-knowledge / authoritative=false"

# --- authored schema pins authoritative to const false (mutation REJECTED) ---
AUTHORED_MUTATED="$(printf '%s' "$AUTHORED" | python3 -c '
import json, sys
obj = json.load(sys.stdin)
obj["sources"][0]["authoritative"] = True
sys.stdout.write(json.dumps(obj, sort_keys=True))
')"
assert_invalid "$SCHEMA_AUTHORED" "$AUTHORED_MUTATED" "authored entry with authoritative:true"

# --- additive `authored` key (authored source shape) -------------------------------
# The event builder merges the whole authored manifest object under an optional
# additive `authored` key on the core manifest. Build that shape from the two
# LIVE emitter outputs (exactly as engine/ctx-rehydrate-event.sh does) and prove
# the core schema is additive: a payload WITH the key AND one WITHOUT both
# validate.
CORE_WITH_AUTHORED="$(python3 -c '
import json, sys
core = json.loads(sys.argv[1])
authored = json.loads(sys.argv[2])
core["authored"] = authored
sys.stdout.write(json.dumps(core, sort_keys=True))
' "$CORE" "$AUTHORED")"
assert_valid "$SCHEMA_CORE" "$CORE_WITH_AUTHORED" "core manifest WITH additive authored key"
assert_valid "$SCHEMA_CORE" "$CORE"               "core manifest WITHOUT authored key (backward-compatible)"

# --- closed-object discipline: an unknown top-level key is rejected -----------
assert_invalid "$SCHEMA_CORE" \
  '{"schema":"singular.orchestration.ctx-rehydrate-manifest.v0","sources":[],"bogus":1}' \
  "core manifest with unknown top-level property"
assert_invalid "$SCHEMA_AUTHORED" \
  '{"schema":"singular.orchestration.ctx-rehydrate-authored-manifest.v0","sources":[],"bogus":1}' \
  "authored manifest with unknown top-level property"

# --- additive-schema discipline: neither schema is referenced by any emitter --
# Both files describe already-emitted data and constrain no emitter (no
# engine/CLI/driver path loads them as a validator).
wired="$(grep -rl "ctx-rehydrate-manifest.v0.schema.json\|ctx-rehydrate-authored-manifest.v0.schema.json" \
  "$ENGINE_HOME/engine" "$ENGINE_HOME/cli" 2>/dev/null || true)"
[[ -z "$wired" ]] || fail "rehydrate manifest schemas must be additive/unwired but are referenced by: $wired"

echo "test-ctx-rehydrate-manifest-schema: all assertions passed"
