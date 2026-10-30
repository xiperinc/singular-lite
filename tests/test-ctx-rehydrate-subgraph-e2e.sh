#!/usr/bin/env bash
# Regression contracts for ctx-rehydrate-subgraph-e2e.
set -uo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-ctx-rehydrate-subgraph-e2e.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
SCHEMA_CORE="$ENGINE_HOME/schemas/orchestration/ctx-rehydrate-manifest.v0.schema.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# Hermetic guard: scrub inherited SINGULAR_* so a leaked knob can't poison the run.
while IFS= read -r _v; do unset "$_v"; done < <(compgen -v | grep '^SINGULAR_' || true)
unset _v

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export SINGULAR_ROOT="$tmp"
export SINGULAR_STATE_DIR="$tmp/state"
mkdir -p "$SINGULAR_STATE_DIR"
export SINGULAR_EVENTS_FILE="$tmp/events.ndjson"
: > "$SINGULAR_EVENTS_FILE"

# shellcheck source=/dev/null
source "$LIB" || fail "sourcing lib.sh failed"

# The whole integrated + wired toolchain must be present (compose, not reimpl).
for fn in singular_ctx_rehydrate_subgraph_select singular_ctx_rehydrate_subgraph_sources \
          singular_ctx_rehydrate_subgraph_packet singular_ctx_rehydrate_subgraph_manifest \
          singular_ctx_rehydrate_subgraph_assemble singular_ctx_rehydrate_subgraph_arm_mode \
          singular_ctx_route_subgraph_render singular_ctx_route_subgraph_manifest \
          singular_graph_identity singular_graph_node_id singular_graph_emit_node \
          singular_graph_emit_edge singular_graph_write_corpus singular_ctx_ab_arm_for \
          singular_ctx_rehydrate_sources singular_ctx_rehydrate_manifest \
          singular_ctx_route_strategy_tainted; do
  [[ "$(type -t "$fn")" == "function" ]] || fail "$fn not available (integrated path incomplete)"
done

count_events() {
  [[ -f "$SINGULAR_EVENTS_FILE" ]] || { echo 0; return 0; }
  local c; c="$(grep -c '"type":' "$SINGULAR_EVENTS_FILE" 2>/dev/null)" || true
  echo "${c:-0}"
}
before_ev="$(count_events)"

sha256_of() { # <file> -> bare 64-hex digest
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# section headers, in output order, from a packet on stdin
packet_ids() { grep -E '^=== .* ===$' | sed -E 's/^=== (.*) ===$/\1/'; }
# manifest ids, in output order
manifest_ids() {
  python3 -c 'import json,sys; print("\n".join(s["id"] for s in json.load(sys.stdin)["sources"]))'
}
# body of the FIRST section whose header id == $1, from a packet on stdin
section_body() {
  SINGULAR_SB_ID="$1" python3 -c '
import os, sys
want = os.environ["SINGULAR_SB_ID"]
lines = sys.stdin.read().splitlines()
i = 0
while i < len(lines):
    ln = lines[i]
    if ln.startswith("=== ") and ln.endswith(" ==="):
        sid = ln[4:-4]
        body = []
        i += 1
        while i < len(lines) and not (lines[i].startswith("=== ") and lines[i].endswith(" ===")):
            body.append(lines[i]); i += 1
        if sid == want:
            sys.stdout.write("\n".join(body)); sys.exit(0)
        continue
    i += 1
'
}

# --- Pick a treatment (B) id and a control (A) id at runtime -----------------
treat_id=""; ctrl_id=""
for id in TASK-0001 TASK-0002 TASK-0003 TASK-0004 TASK-0005 TASK-0006 \
          TASK-0007 TASK-0008 TASK-0009 TASK-0010 TASK-0011 TASK-0012; do
  arm="$(singular_ctx_ab_arm_for "$id")"
  [[ -z "$treat_id" && "$arm" == "B" ]] && treat_id="$id"
  [[ -z "$ctrl_id"  && "$arm" == "A" ]] && ctrl_id="$id"
done
[[ -n "$treat_id" ]] || fail "setup: no treatment (B) id found in fixture set"
[[ -n "$ctrl_id"  ]] || fail "setup: no control (A) id found in fixture set"

# =============================================================================
# ONE deep-lineage fixture corpus. Durable artifacts live on disk at each node's
# provenance.sourcePath. The task node identity is singular_graph_identity task
# <treat_id> so the WIRED selectors resolve the SAME node by construction.
#
# Provenance chain (deep lineage):
#   task T  <-implements-  attempt A  <-derived_from-  plan-version P
#   critique C  -critiques->  P                    (deep critique layer)
#   finding F   -derived_from-> C, and D -accepts_observation-> F   (SURVIVING)
#   assumption AS -derived_from-> P                (OPEN assumption)
#   decision D  -revises-> T                       (closes a cycle: visited guard)
#   RO (finding) reached ONLY via D -rejects_observation-> RO   -> EXCLUDED
#   CON (plan-version) -contradicts-> AS  (OPEN, never superseded) -> AS FIRST;
#       CON is joined only by a non-provenance edge -> NEVER selected.
#
# Durable source classes (per ctx-rehydrate-subgraph-sources.sh):
#   task->task-packet  critique->critique-record  finding->findings-ledger
#   assumption->assumptions-ledger  decision->decision-record
#   attempt/plan-version -> no durable class (in selection, not in packet)
# =============================================================================
export SINGULAR_CTX_GRAPH_DIR="$tmp/graph"
GDIR="$SINGULAR_CTX_GRAPH_DIR"
art="$tmp/art"; mkdir -p "$art"

a_task="$art/task-packet.json";       printf '{"task":"%s"}\n' "$treat_id"     > "$a_task"
a_crit="$art/critique-record.json";   printf '{"critique":"deep-C"}\n'          > "$a_crit"
a_assume="$art/assumptions.json";     printf '{"assumption":"open-AS"}\n'       > "$a_assume"
a_dec="$art/decision-record.json";    printf '{"decision":"disposition-D"}\n'   > "$a_dec"
a_reject="$art/rejected.json";        printf '{"finding":"REJECTED-OBSERVATION-must-not-appear"}\n' > "$a_reject"
# The surviving finding is deliberately LARGE so caps are exercised end-to-end.
a_find="$art/findings-ledger.json"
{ printf '{"finding":"surviving-critique-finding:'; printf 'F%.0s' $(seq 1 9000); printf '"}\n'; } > "$a_find"

task_identity="$(singular_graph_identity task "$treat_id")"
T="$(singular_graph_node_id "$task_identity")"
A="$(singular_graph_node_id 'attempt:A')"
P="$(singular_graph_node_id 'pv:P')"
C="$(singular_graph_node_id 'crit:C')"
AS="$(singular_graph_node_id 'assume:AS')"
F="$(singular_graph_node_id 'find:F')"
RO="$(singular_graph_node_id 'find:RO')"
D="$(singular_graph_node_id 'disp:D')"
CON="$(singular_graph_node_id 'pv:CON')"

nodes_in="$tmp/nodes.in"; edges_in="$tmp/edges.in"
{
  singular_graph_emit_node task         "$task_identity" "$a_task"   'cT'
  singular_graph_emit_node attempt      'attempt:A'      'src/A'     'cA'
  singular_graph_emit_node plan-version 'pv:P'           'src/P'     'cP'
  singular_graph_emit_node critique     'crit:C'         "$a_crit"   'cC'
  singular_graph_emit_node assumption   'assume:AS'      "$a_assume" 'cAS'
  singular_graph_emit_node finding      'find:F'         "$a_find"   'cF'
  singular_graph_emit_node finding      'find:RO'        "$a_reject" 'cRO'
  singular_graph_emit_node decision     'disp:D'         "$a_dec"    'cD'
  singular_graph_emit_node plan-version 'pv:CON'         'src/CON'   'cCON'
} > "$nodes_in"
{
  singular_graph_emit_edge implements          "$A"   "$T"  'src/e1'  'c1'
  singular_graph_emit_edge derived_from        "$P"   "$A"  'src/e2'  'c2'
  singular_graph_emit_edge critiques           "$C"   "$P"  'src/e3'  'c3'
  singular_graph_emit_edge derived_from        "$AS"  "$P"  'src/e4'  'c4'
  singular_graph_emit_edge derived_from        "$F"   "$C"  'src/e5'  'c5'
  singular_graph_emit_edge accepts_observation "$D"   "$F"  'src/e6'  'c6'
  singular_graph_emit_edge rejects_observation "$D"   "$RO" 'src/e7'  'c7'
  singular_graph_emit_edge revises             "$D"   "$T"  'src/e8'  'c8'
  singular_graph_emit_edge contradicts         "$CON" "$AS" 'src/e9'  'c9'
} > "$edges_in"
singular_graph_write_corpus "$GDIR" "$nodes_in" "$edges_in" || fail "setup: write_corpus failed"
[[ -s "$GDIR/nodes.jsonl" ]] || fail "setup: corpus nodes.jsonl empty"

# ===========================================================================
# (1) Deep lineage walked; rejected-only observation excluded; off-lineage
#     contradiction source never selected.
# ===========================================================================
sel="$(singular_ctx_rehydrate_subgraph_select "$GDIR" "$T")" || fail "1: select nonzero exit"
sel_ids="$(printf '%s\n' "$sel" | python3 -c 'import json,sys
for ln in sys.stdin:
    ln=ln.strip()
    if ln: print(json.loads(ln)["id"])')"
for want in "$T" "$P" "$C" "$F" "$AS" "$D" "$A"; do
  printf '%s\n' "$sel_ids" | grep -qx "$want" \
    || fail "1: deep-lineage selection missing node $want"
done
printf '%s\n' "$sel_ids" | grep -qx "$RO" \
  && fail "1: rejected-only observation RO leaked into the selection"
printf '%s\n' "$sel_ids" | grep -qx "$CON" \
  && fail "1: off-lineage contradiction source CON leaked into the selection"
pass "(1) deep lineage walked (task/plan-version/critique-finding/assumption/decision); rejected-only + off-lineage excluded"

# ===========================================================================
# (2) Composed assembler: contradictions surfaced FIRST; rejected bytes absent.
# ===========================================================================
export SINGULAR_CTX_SUBGRAPH_REHYDRATE=1   # gates the WIRED selectors only.
packet="$(singular_ctx_rehydrate_subgraph_assemble "$GDIR" "$T" packet)" \
  || fail "2: assemble packet nonzero exit"
p_ids="$(printf '%s\n' "$packet" | packet_ids)"
first="$(printf '%s\n' "$p_ids" | head -n1)"
[[ "$first" == "assumptions-ledger" ]] \
  || fail "2: contradictions-first violated (first section [$first], want assumptions-ledger)"
# The durable-class sections of the surviving lineage are all present.
for cls in task-packet critique-record findings-ledger assumptions-ledger decision-record; do
  printf '%s\n' "$p_ids" | grep -qx "$cls" || fail "2: packet missing $cls section"
done
# The rejected observation's distinctive bytes never reach the packet.
[[ "$packet" != *"REJECTED-OBSERVATION-must-not-appear"* ]] \
  || fail "2: rejected-only observation bytes leaked into the packet"
# The off-lineage contradiction source never renders.
[[ "$packet" != *"src/CON"* ]] || fail "2: off-lineage source leaked into the packet"
pass "(2) assembled packet: contradiction-flagged assumption first; all surviving classes present; rejected bytes excluded"

# ===========================================================================
# (3) Manifest unchanged: conforms to the core schema; same-sources invariant
#     (manifest ids + sha256s EXACTLY match the packet's included sources).
# ===========================================================================
manifest="$(singular_ctx_rehydrate_subgraph_assemble "$GDIR" "$T" manifest)" \
  || fail "3: assemble manifest nonzero exit"
m_ids="$(printf '%s\n' "$manifest" | manifest_ids)"
[[ "$m_ids" == "$p_ids" ]] || fail "3: manifest ids != packet section ids (same-sources order).
manifest: $m_ids
packet:   $p_ids"
# Manifest conforms to the SHIPPED core schema via a minimal schema-driven validator.
VALIDATOR="$tmp/validator.py"
cat > "$VALIDATOR" <<'PY'
import json, re, sys
def validate(data, schema, path, errs):
    if "const" in schema and data != schema["const"]:
        errs.append(f"{path}: const mismatch")
    t = schema.get("type")
    if t == "object":
        if not isinstance(data, dict):
            errs.append(f"{path}: expected object"); return
        for r in schema.get("required", []):
            if r not in data: errs.append(f"{path}: missing required '{r}'")
        props = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            for k in data:
                if k not in props: errs.append(f"{path}: unknown property '{k}'")
        for k, v in data.items():
            if k in props: validate(v, props[k], f"{path}/{k}", errs)
    elif t == "array":
        if not isinstance(data, list):
            errs.append(f"{path}: expected array"); return
        items = schema.get("items")
        if items is not None:
            for i, el in enumerate(data): validate(el, items, f"{path}[{i}]", errs)
    elif t == "string":
        if not isinstance(data, str):
            errs.append(f"{path}: expected string"); return
        if "minLength" in schema and len(data) < schema["minLength"]:
            errs.append(f"{path}: shorter than minLength")
        if "pattern" in schema and not re.search(schema["pattern"], data):
            errs.append(f"{path}: pattern mismatch")
with open(sys.argv[1], encoding="utf-8") as f:
    schema = json.load(f)
errs = []
validate(json.load(sys.stdin), schema, "$", errs)
if errs:
    print("\n".join(errs), file=sys.stderr); sys.exit(1)
PY
printf '%s\n' "$manifest" | python3 "$VALIDATOR" "$SCHEMA_CORE" \
  || fail "3: manifest does not conform to $SCHEMA_CORE"
# Each manifest sha256 EXACTLY matches the bytes of the class's durable artifact.
declare -A CLASS_ART=(
  [task-packet]="$a_task"
  [critique-record]="$a_crit"
  [findings-ledger]="$a_find"
  [assumptions-ledger]="$a_assume"
  [decision-record]="$a_dec"
)
while IFS=$'\t' read -r mid msha; do
  [[ -n "$mid" ]] || continue
  af="${CLASS_ART[$mid]:-}"
  [[ -n "$af" ]] || fail "3: manifest carries an unexpected source id [$mid]"
  want_sha="$(sha256_of "$af")"
  [[ "$msha" == "$want_sha" ]] \
    || fail "3: manifest sha256 for $mid not derived from artifact bytes (got $msha want $want_sha)"
done < <(printf '%s\n' "$manifest" | python3 -c 'import json,sys
for s in json.load(sys.stdin)["sources"]: print(s["id"]+"\t"+s["sha256"])')
pass "(3) manifest conforms to core schema; same-sources invariant holds (ids + sha256s match the packet)"

# ===========================================================================
# (4) Caps unchanged: shrinking SINGULAR_CONTEXT_SECTION_MAX_CHARS shrinks the big
#     findings-ledger section deterministically; default cap 4000 honored.
# ===========================================================================
default_body="$(printf '%s\n' "$packet" | section_body findings-ledger)"
(( ${#default_body} == 4000 )) \
  || fail "4: default cap 4000 not honored for the big findings section (body=${#default_body})"
[[ "$default_body" == *"truncated"* ]] || fail "4: capped section missing truncation marker (default)"

small_packet="$(SINGULAR_CONTEXT_SECTION_MAX_CHARS=200 \
  singular_ctx_rehydrate_subgraph_assemble "$GDIR" "$T" packet)" \
  || fail "4: assemble under shrunk cap nonzero exit"
small_body="$(printf '%s\n' "$small_packet" | section_body findings-ledger)"
(( ${#small_body} <= 200 )) || fail "4: shrunk section body ${#small_body} exceeds cap 200"
(( ${#small_body} < ${#default_body} )) \
  || fail "4: shrinking the cap knob did not shrink the section (${#small_body} !< ${#default_body})"
[[ "$small_body" == *"truncated"* ]] || fail "4: shrunk section missing truncation marker"
# Deterministic under the shrunk knob.
small_packet2="$(SINGULAR_CONTEXT_SECTION_MAX_CHARS=200 \
  singular_ctx_rehydrate_subgraph_assemble "$GDIR" "$T" packet)" || fail "4: repeat shrunk assemble failed"
[[ "$small_packet" == "$small_packet2" ]] || fail "4: shrunk-cap packet not deterministic"
pass "(4) caps unchanged: default 4000 honored, shrinking the knob shrinks the section deterministically"

# ===========================================================================
# (5) Determinism: the packet and manifest are byte-identical across repeat runs.
# ===========================================================================
packet2="$(singular_ctx_rehydrate_subgraph_assemble "$GDIR" "$T" packet)"   || fail "5: repeat packet failed"
manifest2="$(singular_ctx_rehydrate_subgraph_assemble "$GDIR" "$T" manifest)" || fail "5: repeat manifest failed"
[[ "$packet" == "$packet2" ]]     || fail "5: packet not byte-identical on repeat"
[[ "$manifest" == "$manifest2" ]] || fail "5: manifest not byte-identical on repeat"
pass "(5) determinism: packet and manifest byte-identical across repeated runs"

# ===========================================================================
# (6) WIRED selectors ON: they carry the SAME subgraph sources by construction —
#     both resolve the deterministic task node and delegate to the assembler.
# ===========================================================================
node="$(singular_graph_node_id "$(singular_graph_identity task "$treat_id")")"
[[ "$node" == "$T" ]] || fail "6: wired node resolution [$node] != corpus task node [$T]"

# singular_ctx_route_subgraph_render (the shared inject/record selector).
r_packet="$(singular_ctx_route_subgraph_render "$treat_id" packet)" \
  || fail "6: render(packet) returned non-zero on treatment arm"
[[ "$r_packet" == "$packet" ]] || fail "6: render(packet) != composed subgraph assembler packet"
r_manifest="$(singular_ctx_route_subgraph_render "$treat_id" manifest)" \
  || fail "6: render(manifest) returned non-zero on treatment arm"
[[ "$r_manifest" == "$manifest" ]] || fail "6: render(manifest) != composed subgraph assembler manifest"

# A flat run_dir so the route manifest selector's FLAT branch is well-defined.
run_dir="$tmp/run"; mkdir -p "$run_dir"
meta="$run_dir/session-meta.json"
printf '{"origin":"flat-run-dir"}\n' > "$run_dir/packet.json"
: > "$meta"
flat_manifest() {
  local -a specs=(); local line
  while IFS= read -r line; do [[ -n "$line" ]] && specs+=("$line"); done \
    < <(singular_ctx_rehydrate_sources "$run_dir")
  singular_ctx_rehydrate_manifest ${specs[@]+"${specs[@]}"}
}
expected_flat="$(flat_manifest)"

# singular_ctx_route_subgraph_manifest ON -> the subgraph manifest at the same node.
route_m="$(singular_ctx_route_subgraph_manifest diff-volume implementer some-step "$meta" "$treat_id")" \
  || fail "6: route manifest selector nonzero exit (ON)"
[[ "$route_m" == "$manifest" ]] \
  || fail "6: route manifest selector did not delegate to the subgraph assembler"
[[ "$route_m" != "$expected_flat" ]] || fail "6: route manifest selector still returned the flat manifest"
pass "(6) wired selectors ON: render + route-manifest resolve the SAME node and delegate to the assembler"

# ===========================================================================
# (7) OFF-parity: knob unset/0 -> wired selectors yield flat/empty, byte-identical
#     to flat capsule behavior. Control arm / absent corpus fall back too.
# ===========================================================================
unset SINGULAR_CTX_SUBGRAPH_REHYDRATE
if got="$(singular_ctx_route_subgraph_render "$treat_id" packet)"; then
  fail "7 OFF(unset): render(packet) returned 0 (should signal flat via non-zero)"
fi
[[ -z "$got" ]] || fail "7 OFF(unset): render(packet) printed output: [$got]"
if got="$(singular_ctx_route_subgraph_render "$treat_id" manifest)"; then
  fail "7 OFF(unset): render(manifest) returned 0"
fi
[[ -z "$got" ]] || fail "7 OFF(unset): render(manifest) printed output"

got="$(singular_ctx_route_subgraph_manifest diff-volume implementer some-step "$meta" "$treat_id")" \
  || fail "7 OFF(unset): route manifest selector nonzero exit"
[[ "$got" == "$expected_flat" ]] || fail "7 OFF(unset): route manifest selector not byte-identical to flat"

export SINGULAR_CTX_SUBGRAPH_REHYDRATE=0
if singular_ctx_route_subgraph_render "$treat_id" packet >/dev/null; then
  fail "7 OFF(=0): render(packet) returned 0"
fi
got="$(singular_ctx_route_subgraph_manifest diff-volume implementer some-step "$meta" "$treat_id")" \
  || fail "7 OFF(=0): route manifest selector nonzero exit"
[[ "$got" == "$expected_flat" ]] || fail "7 OFF(=0): route manifest selector not byte-identical to flat"

# Knob ON but CONTROL arm -> flat/empty (fail-closed via the arm decider).
export SINGULAR_CTX_SUBGRAPH_REHYDRATE=1
if got="$(singular_ctx_route_subgraph_render "$ctrl_id" packet)"; then
  fail "7 ON+control: render(packet) returned 0 (control arm must stay flat)"
fi
[[ -z "$got" ]] || fail "7 ON+control: render(packet) printed output"
got="$(singular_ctx_route_subgraph_manifest diff-volume implementer some-step "$meta" "$ctrl_id")" \
  || fail "7 ON+control: route manifest selector nonzero exit"
[[ "$got" == "$expected_flat" ]] || fail "7 ON+control: expected flat manifest on control arm"

# Knob ON, treatment, but ABSENT corpus -> flat/empty.
if got="$(SINGULAR_CTX_GRAPH_DIR="$tmp/graph-missing" \
          singular_ctx_route_subgraph_render "$treat_id" packet)"; then
  fail "7 ON+missing corpus: render(packet) returned 0"
fi
[[ -z "$got" ]] || fail "7 ON+missing corpus: render(packet) printed output"
got="$(SINGULAR_CTX_GRAPH_DIR="$tmp/graph-missing" \
       singular_ctx_route_subgraph_manifest diff-volume implementer some-step "$meta" "$treat_id")" \
  || fail "7 ON+missing corpus: route manifest selector nonzero exit"
[[ "$got" == "$expected_flat" ]] || fail "7 ON+missing corpus: expected flat manifest"
unset SINGULAR_CTX_SUBGRAPH_REHYDRATE
pass "(7) OFF-parity: wired selectors yield flat/empty (knob off, control arm, absent corpus)"

# ===========================================================================
# (8) Taint-unreachability / evidence invariance: the composed path appended no
#     events, wrote nothing into the state dir, mutated no corpus, and left the
#     rehydrate strategy tainted (confers no independence, nothing authoritative).
# ===========================================================================
corpus_snap() { ( cd "$GDIR" && find . | LC_ALL=C sort; cat "$GDIR/nodes.jsonl" "$GDIR/edges.jsonl" | sha256_of /dev/stdin 2>/dev/null || cat "$GDIR/nodes.jsonl" "$GDIR/edges.jsonl" | shasum | awk '{print $1}' ); }
snap_before="$(corpus_snap)"
export SINGULAR_CTX_SUBGRAPH_REHYDRATE=1
singular_ctx_rehydrate_subgraph_assemble "$GDIR" "$T" packet   >/dev/null || fail "8: read-only assemble failed"
singular_ctx_rehydrate_subgraph_assemble "$GDIR" "$T" manifest >/dev/null || fail "8: read-only assemble(manifest) failed"
singular_ctx_route_subgraph_render "$treat_id" packet >/dev/null || fail "8: read-only render failed"
snap_after="$(corpus_snap)"
[[ "$snap_before" == "$snap_after" ]] || fail "8: composed path mutated the corpus (must be read-only)"

after_ev="$(count_events)"
[[ "$after_ev" -eq "$before_ev" ]] || fail "8: composed path appended events ($before_ev -> $after_ev)"
[[ -z "$(ls -A "$SINGULAR_STATE_DIR" 2>/dev/null)" ]] || fail "8: composed path wrote into the state dir"
[[ "$(singular_ctx_route_strategy_tainted rehydrate)" == "1" ]] \
  || fail "8: evidence invariance broken — rehydrate strategy is no longer tainted"
unset SINGULAR_CTX_SUBGRAPH_REHYDRATE
pass "(8) evidence invariance: no events, no writes, corpus untouched, rehydrate stays tainted"

echo "ALL CTX-REHYDRATE-SUBGRAPH-E2E TESTS PASSED"
