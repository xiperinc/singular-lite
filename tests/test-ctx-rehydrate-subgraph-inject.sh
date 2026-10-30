#!/usr/bin/env bash
# Regression coverage for matching injected subgraph packets and recorded manifests.
set -uo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-ctx-rehydrate-subgraph-inject.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
SEL="$ENGINE_HOME/engine/ctx-route-subgraph.sh"
L1DRIVE="$ENGINE_HOME/engine/l1-drive.sh"
EVENT="$ENGINE_HOME/engine/ctx-rehydrate-event.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# Hermetic guard: scrub inherited SINGULAR_* so a leaked knob can't poison the sandbox.
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

# --- The new shared selector must exist -------------------------------------
[[ -f "$SEL" ]] || fail "selector file not present: $SEL"
[[ "$(type -t singular_ctx_route_subgraph_render)" == "function" ]] \
  || fail "singular_ctx_route_subgraph_render is not defined (strict-test-first RED)"

# Integrated pieces the selector composes must be available (compose, not reimpl).
for fn in singular_ctx_rehydrate_subgraph_arm_mode singular_ctx_rehydrate_subgraph_assemble \
          singular_graph_node_id singular_graph_identity singular_graph_write_corpus \
          singular_ctx_rehydrate_sources singular_ctx_rehydrate_packet singular_ctx_rehydrate_manifest \
          singular_ctx_rehydrate_event_data singular_ctx_ab_arm_for singular_ctx_route_strategy_tainted; do
  [[ "$(type -t "$fn")" == "function" ]] || fail "$fn not available"
done

count_events() {
  [[ -f "$SINGULAR_EVENTS_FILE" ]] || { echo 0; return 0; }
  local c; c="$(grep -c '"type":' "$SINGULAR_EVENTS_FILE" 2>/dev/null)" || true
  echo "${c:-0}"
}
before_ev="$(count_events)"

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

# --- A present, non-empty graph corpus whose task node maps to a durable source
# The task node identity MUST be singular_graph_identity task <treat_id> so the
# selector's node resolution finds it. Its sourcePath points at real bytes that
# DIFFER from the flat run_dir source, so a subgraph packet/manifest is visibly
# distinct from the flat one.
export SINGULAR_CTX_GRAPH_DIR="$tmp/graph"
corpus_art="$tmp/corpus-task-packet.json"
printf '{"origin":"subgraph-corpus"}\n' > "$corpus_art"
task_node="$(singular_graph_node_id "$(singular_graph_identity task "$treat_id")")"
nodes_in="$tmp/nodes.in"; edges_in="$tmp/edges.in"
singular_graph_emit_node task "$(singular_graph_identity task "$treat_id")" "$corpus_art" 'cT' > "$nodes_in"
: > "$edges_in"
singular_graph_write_corpus "$SINGULAR_CTX_GRAPH_DIR" "$nodes_in" "$edges_in" \
  || fail "setup: write_corpus failed"
[[ -s "$SINGULAR_CTX_GRAPH_DIR/nodes.jsonl" ]] || fail "setup: corpus nodes.jsonl empty"

# --- A flat run_dir with one durable source (non-empty flat packet/manifest) --
run_dir="$tmp/run"; mkdir -p "$run_dir"
printf '{"origin":"flat-run-dir"}\n' > "$run_dir/packet.json"

flat_specs() {
  local -a specs=(); local line
  while IFS= read -r line; do [[ -n "$line" ]] && specs+=("$line"); done \
    < <(singular_ctx_rehydrate_sources "$run_dir")
  printf '%s\n' ${specs[@]+"${specs[@]}"}
}
expected_flat_packet="$(singular_ctx_rehydrate_packet $(flat_specs) 2>/dev/null)"
expected_flat_manifest="$(singular_ctx_rehydrate_manifest $(flat_specs) 2>/dev/null)"
[[ -n "$expected_flat_packet" && "$expected_flat_packet" == *"flat-run-dir"* ]] \
  || fail "setup: flat packet unexpectedly empty / missing run_dir bytes"

# The subgraph packet/manifest the selector must delegate to.
expected_sub_packet="$(singular_ctx_rehydrate_subgraph_assemble "$SINGULAR_CTX_GRAPH_DIR" "$task_node" packet)"
expected_sub_manifest="$(singular_ctx_rehydrate_subgraph_assemble "$SINGULAR_CTX_GRAPH_DIR" "$task_node" manifest)"
[[ -n "$expected_sub_packet" && "$expected_sub_packet" == *"subgraph-corpus"* ]] \
  || fail "setup: subgraph packet unexpectedly empty / missing corpus bytes"
[[ "$expected_sub_packet" != "$expected_flat_packet" ]] \
  || fail "setup: subgraph and flat packet must differ for a meaningful test"

# ===========================================================================
# (A) The shared selector singular_ctx_route_subgraph_render.
# ===========================================================================
# OFF-parity: knob unset -> non-zero + empty, for BOTH modes.
unset SINGULAR_CTX_SUBGRAPH_REHYDRATE
if got="$(singular_ctx_route_subgraph_render "$treat_id" packet)"; then
  fail "A OFF(unset): render(packet) returned 0 (should signal flat via non-zero)"
fi
[[ -z "$got" ]] || fail "A OFF(unset): render(packet) printed output: [$got]"
if got="$(singular_ctx_route_subgraph_render "$treat_id" manifest)"; then
  fail "A OFF(unset): render(manifest) returned 0"
fi
[[ -z "$got" ]] || fail "A OFF(unset): render(manifest) printed output"

export SINGULAR_CTX_SUBGRAPH_REHYDRATE=0
if singular_ctx_route_subgraph_render "$treat_id" packet >/dev/null; then
  fail "A OFF(=0): render(packet) returned 0"
fi
unset SINGULAR_CTX_SUBGRAPH_REHYDRATE

# ON + treatment + non-empty corpus -> subgraph assembler at the deterministic node.
export SINGULAR_CTX_SUBGRAPH_REHYDRATE=1
got="$(singular_ctx_route_subgraph_render "$treat_id" packet)" \
  || fail "A ON+treat+corpus: render(packet) returned non-zero"
[[ "$got" == "$expected_sub_packet" ]] \
  || fail "A ON+treat+corpus: render(packet) != subgraph assembler at node $task_node"
[[ "$got" != "$expected_flat_packet" ]] \
  || fail "A ON+treat+corpus: render(packet) still returned the flat packet"
got="$(singular_ctx_route_subgraph_render "$treat_id" manifest)" \
  || fail "A ON+treat+corpus: render(manifest) returned non-zero"
[[ "$got" == "$expected_sub_manifest" ]] \
  || fail "A ON+treat+corpus: render(manifest) != subgraph assembler manifest"

# Control arm -> non-zero + empty even with knob on + corpus present.
if got="$(singular_ctx_route_subgraph_render "$ctrl_id" packet)"; then
  fail "A ON+control: render(packet) returned 0 (control arm must stay flat)"
fi
[[ -z "$got" ]] || fail "A ON+control: render(packet) printed output"

# Absent corpus -> non-zero + empty (fail-closed via the arm decider).
if got="$(SINGULAR_CTX_GRAPH_DIR="$tmp/graph-missing" \
          singular_ctx_route_subgraph_render "$treat_id" packet)"; then
  fail "A ON+missing corpus: render(packet) returned 0"
fi
[[ -z "$got" ]] || fail "A ON+missing corpus: render(packet) printed output"
unset SINGULAR_CTX_SUBGRAPH_REHYDRATE
pass "(A) shared selector: OFF-parity non-zero/empty; ON+treat+corpus == subgraph assembler; control/absent -> flat"

# ===========================================================================
# (B) engine/l1-drive.sh rehydrate_inject_packet — inject the SUBGRAPH packet.
# The driver script isn't sourceable (it runs main), so extract just the
# self-contained function text and eval it into this shell.
# ===========================================================================
inject_fn="$(awk '/^rehydrate_inject_packet\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$L1DRIVE")"
[[ -n "$inject_fn" ]] || fail "B: could not extract rehydrate_inject_packet from $L1DRIVE"
eval "$inject_fn"
[[ "$(type -t rehydrate_inject_packet)" == "function" ]] \
  || fail "B: rehydrate_inject_packet not defined after eval"

PROV_HEADER="## Injected durable context (rehydrated from a refused-resume lineage)"

# Variables the function reads from driver scope.
worker_strategy="rehydrate"
task_id="$treat_id"
decision_source_extra=""

inject_into() {
  local ap="$1"; : > "$ap"
  rehydrate_inject_packet "$ap"
}

# (D) gate: without a rehydrate strategy the hook is a no-op.
worker_strategy="fresh"
ap="$tmp/ap-nogate.md"; inject_into "$ap"
[[ ! -s "$ap" ]] || fail "D: rehydrate_inject_packet injected without a rehydrate strategy"
worker_strategy="rehydrate"

# OFF path (subgraph knob off): the FLAT packet is injected, byte-identical.
unset SINGULAR_CTX_SUBGRAPH_REHYDRATE
ap="$tmp/ap-flat.md"; inject_into "$ap"
grep -qF "$PROV_HEADER" "$ap" || fail "B OFF: provenance header missing on flat inject"
grep -qF "flat-run-dir" "$ap" || fail "B OFF: flat packet bytes missing"
grep -qF "subgraph-corpus" "$ap" && fail "B OFF: subgraph bytes leaked into flat inject"

# ON path (knob=1 + treatment + corpus): the SUBGRAPH packet is injected instead,
# still under the reference-only / NOT-authoritative provenance header.
export SINGULAR_CTX_SUBGRAPH_REHYDRATE=1
ap="$tmp/ap-sub.md"; inject_into "$ap"
grep -qF "$PROV_HEADER" "$ap" || fail "B ON: provenance header missing on subgraph inject"
grep -qi "not authoritative" "$ap" || fail "B ON: reference-only / NOT-authoritative framing missing"
grep -qF "subgraph-corpus" "$ap" || fail "B ON: subgraph packet bytes missing (flat still injected?)"
grep -qF "flat-run-dir" "$ap" && fail "B ON: flat packet bytes still present (branch did not diverge)"
# The injected packet must contain the subgraph packet verbatim.
grep -qF "$(printf '%s' "$expected_sub_packet" | head -1)" "$ap" \
  || fail "B ON: injected packet not the subgraph packet"
# Idempotent: exactly one provenance header.
[[ "$(grep -cF "$PROV_HEADER" "$ap")" == "1" ]] || fail "B ON: provenance header not exactly once"

# ON path but CONTROL arm -> flat injection (fail-closed via selector).
task_id="$ctrl_id"
ap="$tmp/ap-ctrl.md"; inject_into "$ap"
grep -qF "flat-run-dir" "$ap" || fail "B ON+control: expected flat packet"
grep -qF "subgraph-corpus" "$ap" && fail "B ON+control: subgraph bytes leaked on control arm"
task_id="$treat_id"
unset SINGULAR_CTX_SUBGRAPH_REHYDRATE
pass "(B) inject hook: subgraph packet injected under provenance header on treatment arm; flat elsewhere"

# ===========================================================================
# (C) engine/ctx-rehydrate-event.sh singular_ctx_rehydrate_event_data — record
# the SUBGRAPH manifest on the subgraph branch, flat elsewhere.
# ===========================================================================
manifest_of() {  # extract the recorded .manifest object, canonicalized
  python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["manifest"], sort_keys=True))'
}
canon() { python3 -c 'import json,sys; print(json.dumps(json.loads(sys.stdin.read()), sort_keys=True))'; }

# OFF path: recorded manifest == flat manifest.
unset SINGULAR_CTX_SUBGRAPH_REHYDRATE
ev="$(singular_ctx_rehydrate_event_data implementer "$treat_id" RUN-1 1 window-pressure "$run_dir")" \
  || fail "C OFF: event_data exited non-zero"
got_m="$(printf '%s' "$ev" | manifest_of)"
want_flat_m="$(printf '%s' "$expected_flat_manifest" | canon)"
[[ "$got_m" == "$want_flat_m" ]] || fail "C OFF: recorded manifest != flat manifest
got:  $got_m
want: $want_flat_m"

# ON path (treatment + corpus): recorded manifest == subgraph manifest.
export SINGULAR_CTX_SUBGRAPH_REHYDRATE=1
ev="$(singular_ctx_rehydrate_event_data implementer "$treat_id" RUN-1 1 window-pressure "$run_dir")" \
  || fail "C ON: event_data exited non-zero"
got_m="$(printf '%s' "$ev" | manifest_of)"
want_sub_m="$(printf '%s' "$expected_sub_manifest" | canon)"
[[ "$got_m" == "$want_sub_m" ]] || fail "C ON: recorded manifest != subgraph manifest
got:  $got_m
want: $want_sub_m"
[[ "$got_m" != "$want_flat_m" ]] || fail "C ON: recorded manifest still the flat manifest"

# ON but CONTROL arm -> flat manifest recorded.
ev="$(singular_ctx_rehydrate_event_data implementer "$ctrl_id" RUN-1 1 window-pressure "$run_dir")" \
  || fail "C ON+control: event_data exited non-zero"
got_m="$(printf '%s' "$ev" | manifest_of)"
[[ "$got_m" == "$want_flat_m" ]] || fail "C ON+control: expected flat manifest on control arm"
unset SINGULAR_CTX_SUBGRAPH_REHYDRATE
pass "(C) record hook: subgraph manifest recorded on treatment arm; flat elsewhere; same sources as the inject site"

# ===========================================================================
# (E) evidence invariance: no events appended by the pure selector calls above,
# and rehydrate stays tainted.
# ===========================================================================
after_ev="$(count_events)"
[[ "$after_ev" -eq "$before_ev" ]] || fail "E: selector/render appended events ($before_ev -> $after_ev)"
[[ "$(singular_ctx_route_strategy_tainted rehydrate)" == "1" ]] \
  || fail "E: rehydrate strategy no longer tainted"
pass "(E) evidence invariance: no events appended by the selector; rehydrate stays tainted"

echo "ALL CTX-REHYDRATE-SUBGRAPH-INJECT TESTS PASSED"
