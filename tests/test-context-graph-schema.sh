#!/usr/bin/env bash
# Contract test for schemas/context-graph.v0.schema.json — one line of the
# append-only JSONL provenance-graph corpus under .singular-state/graph/
# (nodes.jsonl + edges.jsonl). This is the PURE-PROJECTION contract only: no
# projector, no CLI, no engine wiring exist yet (they belong to the downstream
# graph-projector node). Fail-closed: the record is an additive, closed object
# (additionalProperties:false) in the singular.orchestration.*.v0 family, and
# every invalid class below is rejected.
#
# No jsonschema module ships in this environment, so this test carries a tiny
# schema-driven validator (const/enum/pattern/minLength/required/additional
# Properties/items + $ref/$defs resolution + oneOf) that reads the ACTUAL schema
# file — fixtures are checked against the shipped contract, not a hand-rolled
# copy of it. It mirrors tests/test-plan-critique-schema.sh.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEMA="$ENGINE_HOME/schemas/context-graph.v0.schema.json"
NODES="$ENGINE_HOME/tests/fixtures/context-graph/nodes.jsonl"
EDGES="$ENGINE_HOME/tests/fixtures/context-graph/edges.jsonl"
MAPPING="$ENGINE_HOME/docs/context-graph.md"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- strict-test-first RED precondition: fail closed with no schema present ---
[[ -f "$SCHEMA" ]] || fail "missing schema: $SCHEMA (strict-test-first RED)"

# --- minimal schema-driven validator (resolves $ref/$defs + oneOf) -----------
VALIDATOR="$(mktemp)"
trap 'rm -f "$VALIDATOR"' EXIT
cat > "$VALIDATOR" <<'PY'
import json, re, sys

def resolve(ref, root):
    # local pointers only, e.g. "#/$defs/node"
    if not ref.startswith("#/"):
        raise ValueError("only local $ref supported: %s" % ref)
    node = root
    for part in ref[2:].split("/"):
        node = node[part]
    return node

def validate(data, schema, path, root, errs):
    if "$ref" in schema:
        validate(data, resolve(schema["$ref"], root), path, root, errs)
        return
    if "oneOf" in schema:
        matches = 0
        for sub in schema["oneOf"]:
            sub_errs = []
            validate(data, sub, path, root, sub_errs)
            if not sub_errs:
                matches += 1
        if matches != 1:
            errs.append(f"{path}: oneOf matched {matches} subschemas (want exactly 1)")
        return
    if "const" in schema and data != schema["const"]:
        errs.append(f"{path}: const mismatch")
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
                validate(v, props[k], f"{path}/{k}", root, errs)
    elif t == "array":
        if not isinstance(data, list):
            errs.append(f"{path}: expected array"); return
        items = schema.get("items")
        if items is not None:
            for i, el in enumerate(data):
                validate(el, items, f"{path}[{i}]", root, errs)
    elif t == "string":
        if not isinstance(data, str):
            errs.append(f"{path}: expected string"); return
        if "minLength" in schema and len(data) < schema["minLength"]:
            errs.append(f"{path}: shorter than minLength {schema['minLength']}")
        if "pattern" in schema and not re.search(schema["pattern"], data):
            errs.append(f"{path}: does not match {schema['pattern']}")

with open(sys.argv[1], "r", encoding="utf-8") as f:
    root = json.load(f)
data = json.load(sys.stdin)
errs = []
validate(data, root, "$", root, errs)
if errs:
    print("\n".join(errs), file=sys.stderr)
    sys.exit(1)
print("ok")
PY

validates() { python3 "$VALIDATOR" "$SCHEMA" >/dev/null 2>&1; }
assert_valid()   { printf '%s' "$1" | validates || fail "$2: should VALIDATE but did not"; }
assert_invalid() { printf '%s' "$1" | validates && fail "$2: should be REJECTED but validated"; return 0; }

# --- schema identity: $id/const in the singular.orchestration.*.v0 family ------
python3 - "$SCHEMA" <<'PY' || fail "schema \$id/const not in singular.orchestration.*.v0 family"
import json, sys
s = json.load(open(sys.argv[1]))
sid = s.get("$id", "")
assert sid == "singular.orchestration.context-graph.v0", f"bad $id: {sid}"
for defn in ("node", "edge"):
    c = s["$defs"][defn]["properties"]["schema"].get("const")
    assert c == "singular.orchestration.context-graph.v0", f"bad {defn} schema const: {c}"
PY

# --- taxonomy completeness: full node + edge enums asserted from the schema ---
NODE_TYPES=(goal plan-batch plan-version critique finding assumption task \
            attempt commit gate-result audit decision capsule)
EDGE_TYPES=(depends_on derived_from revises critiques accepts_observation \
            rejects_observation implements verifies contradicts invalidates \
            supersedes)

# node type enum contains exactly the taxonomy (both directions).
python3 - "$SCHEMA" "${NODE_TYPES[@]}" <<'PY' || fail "node-type enum != full taxonomy"
import json, sys
s = json.load(open(sys.argv[1]))
want = set(sys.argv[2:])
got = set(s["$defs"]["node"]["properties"]["type"]["enum"])
assert got == want, f"node type enum mismatch: missing={want-got} extra={got-want}"
PY

python3 - "$SCHEMA" "${EDGE_TYPES[@]}" <<'PY' || fail "edge-type enum != full taxonomy"
import json, sys
s = json.load(open(sys.argv[1]))
want = set(sys.argv[2:])
got = set(s["$defs"]["edge"]["properties"]["type"]["enum"])
assert got == want, f"edge type enum mismatch: missing={want-got} extra={got-want}"
PY

# evidenceClass is EXACTLY authoritative | claim, and required on every node.
python3 - "$SCHEMA" <<'PY' || fail "evidenceClass enum must be exactly authoritative|claim and required"
import json, sys
s = json.load(open(sys.argv[1]))
node = s["$defs"]["node"]
ev = node["properties"]["evidenceClass"]["enum"]
assert set(ev) == {"authoritative", "claim"}, f"evidenceClass enum: {ev}"
assert "evidenceClass" in node["required"], "evidenceClass not required on node"
assert "provenance" in node["required"], "provenance not required on node"
PY

# --- valid node/edge line builders -------------------------------------------
HASH="sha256:a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"
node_line() { # type evidenceClass
  cat <<JSON
{"schema":"singular.orchestration.context-graph.v0","kind":"node","id":"n-000000000abc","type":"${1}","evidenceClass":"${2}","provenance":{"sourcePath":"docs/orchestration/tasks/TASK-0001.md","contentHash":"$HASH","recordType":"task"},"label":"demo"}
JSON
}
edge_line() { # type
  cat <<JSON
{"schema":"singular.orchestration.context-graph.v0","kind":"edge","id":"e-000000000abc","type":"${1}","from":"n-000000000abc","to":"n-000000000def","provenance":{"sourcePath":".singular-state/events/log.jsonl","contentHash":"$HASH"}}
JSON
}

# --- every node-type taxonomy member is ACCEPTED -----------------------------
for t in "${NODE_TYPES[@]}"; do
  case "$t" in
    commit|gate-result) ec="authoritative" ;;
    *) ec="claim" ;;
  esac
  assert_valid "$(node_line "$t" "$ec")" "node type '$t' should validate"
done

# --- every edge-type taxonomy member is ACCEPTED -----------------------------
for t in "${EDGE_TYPES[@]}"; do
  assert_valid "$(edge_line "$t")" "edge type '$t' should validate"
done

# --- the shipped fixture corpus validates LINE-BY-LINE ------------------------
[[ -f "$NODES" ]] || fail "missing fixture: $NODES"
[[ -f "$EDGES" ]] || fail "missing fixture: $EDGES"
lineno=0
while IFS= read -r line; do
  lineno=$((lineno+1))
  [[ -z "$line" ]] && continue
  assert_valid "$line" "nodes.jsonl line $lineno"
done < "$NODES"
[[ "$lineno" -ge 13 ]] || fail "nodes.jsonl must cover the full node taxonomy (>=13 lines, got $lineno)"

lineno=0
while IFS= read -r line; do
  lineno=$((lineno+1))
  [[ -z "$line" ]] && continue
  assert_valid "$line" "edges.jsonl line $lineno"
done < "$EDGES"
[[ "$lineno" -ge 11 ]] || fail "edges.jsonl must cover the full edge taxonomy (>=11 lines, got $lineno)"

# The fixture corpus must exercise every taxonomy member at least once.
for t in "${NODE_TYPES[@]}"; do
  grep -q "\"type\":\"$t\"" "$NODES" || fail "nodes.jsonl missing node type '$t'"
done
for t in "${EDGE_TYPES[@]}"; do
  grep -q "\"type\":\"$t\"" "$EDGES" || fail "edges.jsonl missing edge type '$t'"
done

# --- invalid classes, one fixture each (the required rejections) --------------

# (a) unknown node type
assert_invalid "$(node_line "banana" "claim")" "unknown node type rejected"

# (b) unknown edge type
assert_invalid "$(edge_line "correlates_with")" "unknown edge type rejected"

# (c) node missing provenance
assert_invalid '{"schema":"singular.orchestration.context-graph.v0","kind":"node","id":"n-000000000abc","type":"finding","evidenceClass":"claim"}' \
  "node missing provenance rejected"

# (d) evidenceClass outside authoritative|claim
assert_invalid "$(node_line "finding" "hearsay")" "evidenceClass out of enum rejected"

# (e) unknown top-level property (closed object)
assert_invalid "{\"schema\":\"singular.orchestration.context-graph.v0\",\"kind\":\"node\",\"id\":\"n-000000000abc\",\"type\":\"finding\",\"evidenceClass\":\"claim\",\"provenance\":{\"sourcePath\":\"x\",\"contentHash\":\"$HASH\"},\"rogue\":true}" \
  "unknown top-level property rejected"

# (f) provenance missing contentHash (host-verifiable identity is mandatory)
assert_invalid '{"schema":"singular.orchestration.context-graph.v0","kind":"node","id":"n-000000000abc","type":"commit","evidenceClass":"authoritative","provenance":{"sourcePath":"x"}}' \
  "provenance missing contentHash rejected"

# (g) contentHash not a sha256 digest
assert_invalid '{"schema":"singular.orchestration.context-graph.v0","kind":"node","id":"n-000000000abc","type":"commit","evidenceClass":"authoritative","provenance":{"sourcePath":"x","contentHash":"deadbeef"}}' \
  "contentHash bad pattern rejected"

# (h) bad node id shape
assert_invalid "$(printf '{"schema":"singular.orchestration.context-graph.v0","kind":"node","id":"NODE-1","type":"goal","evidenceClass":"claim","provenance":{"sourcePath":"x","contentHash":"%s"}}' "$HASH")" \
  "bad node id rejected"

# (i) edge missing an endpoint
assert_invalid "$(printf '{"schema":"singular.orchestration.context-graph.v0","kind":"edge","id":"e-000000000abc","type":"implements","from":"n-000000000abc","provenance":{"sourcePath":"x","contentHash":"%s"}}' "$HASH")" \
  "edge missing 'to' endpoint rejected"

# (j) missing kind discriminator (ambiguous line)
assert_invalid "$(printf '{"schema":"singular.orchestration.context-graph.v0","id":"n-000000000abc","type":"goal","evidenceClass":"claim","provenance":{"sourcePath":"x","contentHash":"%s"}}' "$HASH")" \
  "missing kind discriminator rejected"

# --- mapping doc names every S0-S5 durable record/event type ------------------
[[ -f "$MAPPING" ]] || fail "missing mapping doc: $MAPPING"

# S0-S5 durable record/event types produced by the engine.
# Each must be named in the mapping table so every projected line has a source.
S0_S5_RECORDS=(
  # S0 — baseline / instrumentation
  "ctx.arm_assigned"
  "ctx.paired_audit"
  "attempts/index.json"
  "gate-result"
  "audit-verdict"
  "commit"
  "secret-scan"
  "scope-check"
  # S1 — planner session persistence
  "session-meta"
  "context.strategy_selected"
  # S2 — plan critique
  "plan-critique"
  "plan.critiqued"
  "ctx.plan_critique_infra"
  "ctx.plan_critique_retry"
  # S3 — plan revision
  "plan.revised"
  "plan.revise_parked"
  "accepted-observation"
  "rejected-observation"
  "ctx.critic_recheck"
  # S4 — context packets
  "context packet"
  "assumption ledger"
  "capsule"
  "ctx.artifact_secret"
  "ctx.packet_malformed"
  # S5 — routing / rehydration
  "rehydrate"
  "decision record"
  "decision.recorded"
  "context.resume_failed"
)
for rec in "${S0_S5_RECORDS[@]}"; do
  grep -qF "$rec" "$MAPPING" || fail "mapping doc must name S0-S5 record type: '$rec'"
done

# The mapping doc must classify authoritative vs claim and cover both.
grep -qi "authoritative" "$MAPPING" || fail "mapping doc must mark authoritative records"
grep -qi "claim" "$MAPPING" || fail "mapping doc must mark claim records"

# Every node/edge taxonomy member must appear in the mapping doc so each has a
# documented projection source.
for t in "${NODE_TYPES[@]}"; do
  grep -qF "$t" "$MAPPING" || fail "mapping doc missing node type '$t'"
done
for t in "${EDGE_TYPES[@]}"; do
  grep -qF "$t" "$MAPPING" || fail "mapping doc missing edge type '$t'"
done

# --- pure-projection guard (POSITIVE, durable): the contract pins the
# pure-projection / never-authored-directly-by-a-model invariant in the mapping
# doc, so the guarantee is asserted behaviorally rather than by a temporal
# absence-grep over engine/cli (which goes red the instant graph-projector
# legitimately references the schema). ----------------
grep -qi "pure projection" "$MAPPING" \
  || fail "mapping doc must document the graph as a PURE PROJECTION"
grep -qi "never authored" "$MAPPING" \
  || fail "mapping doc must document the never-authored-directly-by-a-model invariant"
grep -qi "directly by a model" "$MAPPING" \
  || fail "mapping doc must document the never-authored-directly-by-a-model invariant"

echo "test-context-graph-schema: all assertions passed"
