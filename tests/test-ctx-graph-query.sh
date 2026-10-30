#!/usr/bin/env bash
# Covers the graph-projector `query` read API in engine/ctx-graph-query.sh — the
# third and final requiredCompletion verb (alongside rebuild + sync). It is a
# read-only, deterministic reader over the materialized canonical corpus
# <graphDir>/nodes.jsonl + <graphDir>/edges.jsonl. Three mutually-independent read
# modes:
#   singular_graph_query_neighbors <graphDir> <nodeId>
#       -> every edge incident to <nodeId> (as `from` or `to`) plus the adjacent
#          node records, deterministically ordered. Unknown node id -> empty
#          result with a zero exit (fail-safe).
#   singular_graph_query_lineage <graphDir> <startNodeId>
#       -> the provenance lineage reachable from the start node by following the
#          provenance-edge taxonomy (task -> attempt -> plan-version -> critique ->
#          finding -> disposition), deterministically ordered, with a visited-set
#          guard so cycles terminate.
#   singular_graph_query_open_contradictions <graphDir>
#       -> exactly the `contradicts`/`invalidates` edges that have NO superseding
#          resolution (no `supersedes` edge whose target is the contradicted/
#          invalidated node), deterministically ordered.
#
# The lineage walk is defined over the GENERAL edge taxonomy, so this test
# builds a self-contained fixture corpus containing the
# lineage edges rather than asserting which edges today's mappers emit.
#
# Asserts: neighbors returns exactly the incident edges + adjacent node ids,
# deterministically ordered; an unknown node id yields an empty zero-exit result;
# lineage returns the connected provenance component (non-provenance edges do NOT
# expand it) and terminates on a corpus containing a cycle; open-contradictions
# returns exactly the unresolved contradicts/invalidates edges and excludes any
# resolved by a supersedes edge; every query is read-only (corpus byte-identical,
# no files created) and emits byte-identical output on repeat; a missing/empty
# corpus yields a well-formed empty result; and OFF-parity — sourcing the file
# invokes nothing and writes nothing.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRAPH="$ENGINE_HOME/engine/ctx-graph.sh"
CORPUS="$ENGINE_HOME/engine/ctx-graph-corpus.sh"
QUERY="$ENGINE_HOME/engine/ctx-graph-query.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- strict-test-first RED precondition: fail closed with no impl present -----
[[ -f "$GRAPH" ]]  || fail "missing projection primitives: $GRAPH"
[[ -f "$CORPUS" ]] || fail "missing corpus writer: $CORPUS"
[[ -f "$QUERY" ]]  || fail "impl not present yet: $QUERY (strict-test-first RED)"

work_root="$(mktemp -d)"
snap_dir="$(mktemp -d)"
trap 'rm -rf "$work_root" "$snap_dir"' EXIT

# --- OFF-parity / no-writes on source: sourcing invokes nothing, writes nothing.
before="$(cd "$snap_dir" && find . | LC_ALL=C sort)"
unset SINGULAR_CTX_GRAPH 2>/dev/null || true
# shellcheck disable=SC1090
( cd "$snap_dir" && source "$GRAPH" && source "$CORPUS" && source "$QUERY" ) \
  || fail "sourcing $QUERY failed"
after="$(cd "$snap_dir" && find . | LC_ALL=C sort)"
[[ "$before" == "$after" ]] || fail "sourcing $QUERY created filesystem artifacts (OFF-parity)"

# shellcheck disable=SC1090
source "$GRAPH"  || fail "sourcing $GRAPH failed"
# shellcheck disable=SC1090
source "$CORPUS" || fail "sourcing $CORPUS failed"
# shellcheck disable=SC1090
source "$QUERY"  || fail "sourcing $QUERY failed"
for fn in singular_graph_query_neighbors singular_graph_query_lineage singular_graph_query_open_contradictions; do
  [[ "$(type -t "$fn")" == "function" ]] || fail "$fn is not defined by $QUERY"
done

# --- small parsing helpers ----------------------------------------------------
# Print the `id` of each JSONL record on stdin whose `kind` matches $1 (or all
# records when $1 is empty), one per line, sorted ascending.
kind_ids() {
  local want="${1:-}"
  SINGULAR_TQ_KIND="$want" python3 -c '
import json, os, sys
want = os.environ["SINGULAR_TQ_KIND"]
out = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line.strip():
        continue
    o = json.loads(line)
    if not want or o.get("kind") == want:
        out.append(o["id"])
for i in sorted(out):
    print(i)
'
}
sorted_lines() { LC_ALL=C sort; }
expect_eq() { # <label> <actual> <expected>
  [[ "$2" == "$3" ]] || fail "$1: got [$2] want [$3]"
}

# =============================================================================
# CORPUS A — lineage + neighbors.
# Node chain (provenance): task T -> attempt A -> plan-version P -> critique C ->
# finding F -> disposition D. Plus an off-lineage node U joined to T only by a
# NON-provenance (contradicts) edge, and a cycle edge D -> T (revises) to prove
# the visited-set guard terminates.
# =============================================================================
GDIR_A="$work_root/graph-a"
NODES_A="$work_root/nodes-a.in"
EDGES_A="$work_root/edges-a.in"

T="$(singular_graph_node_id 'task:T')"
A="$(singular_graph_node_id 'attempt:A')"
P="$(singular_graph_node_id 'pv:P')"
C="$(singular_graph_node_id 'crit:C')"
F="$(singular_graph_node_id 'find:F')"
D="$(singular_graph_node_id 'disp:D')"
U="$(singular_graph_node_id 'unrelated:U')"

{
  singular_graph_emit_node task         'task:T'       'src/T' 'cT'
  singular_graph_emit_node attempt      'attempt:A'    'src/A' 'cA'
  singular_graph_emit_node plan-version 'pv:P'         'src/P' 'cP'
  singular_graph_emit_node critique     'crit:C'       'src/C' 'cC'
  singular_graph_emit_node finding      'find:F'       'src/F' 'cF'
  singular_graph_emit_node decision     'disp:D'       'src/D' 'cD'
  singular_graph_emit_node goal         'unrelated:U'  'src/U' 'cU'
} > "$NODES_A"

# Provenance-taxonomy edges (implements/derived_from/critiques/accepts_observation/
# revises) plus one non-provenance edge (contradicts) that must NOT expand lineage.
E_A_impl_T="$(singular_graph_edge_id "$A" implements "$T")"
E_P_df_A="$(singular_graph_edge_id "$P" derived_from "$A")"
E_C_crit_P="$(singular_graph_edge_id "$C" critiques "$P")"
E_F_df_C="$(singular_graph_edge_id "$F" derived_from "$C")"
E_D_acc_F="$(singular_graph_edge_id "$D" accepts_observation "$F")"
E_D_rev_T="$(singular_graph_edge_id "$D" revises "$T")"
E_U_con_T="$(singular_graph_edge_id "$U" contradicts "$T")"

{
  singular_graph_emit_edge implements          "$A" "$T" 'src/e1' 'c1'
  singular_graph_emit_edge derived_from        "$P" "$A" 'src/e2' 'c2'
  singular_graph_emit_edge critiques           "$C" "$P" 'src/e3' 'c3'
  singular_graph_emit_edge derived_from        "$F" "$C" 'src/e4' 'c4'
  singular_graph_emit_edge accepts_observation "$D" "$F" 'src/e5' 'c5'
  singular_graph_emit_edge revises             "$D" "$T" 'src/e6' 'c6'
  singular_graph_emit_edge contradicts         "$U" "$T" 'src/e7' 'c7'
} > "$EDGES_A"

singular_graph_write_corpus "$GDIR_A" "$NODES_A" "$EDGES_A" || fail "write_corpus A failed"

# --- Neighbors of T: incident edges e1 (A->T), e6 (D->T), e7 (U->T); adjacent A,D,U.
neigh_T="$(singular_graph_query_neighbors "$GDIR_A" "$T")" || fail "neighbors(T) nonzero exit"
got_edges="$(printf '%s\n' "$neigh_T" | kind_ids edge)"
want_edges="$(printf '%s\n%s\n%s\n' "$E_A_impl_T" "$E_D_rev_T" "$E_U_con_T" | sorted_lines)"
expect_eq "neighbors(T) incident edges" "$got_edges" "$want_edges"
got_nodes="$(printf '%s\n' "$neigh_T" | kind_ids node)"
want_nodes="$(printf '%s\n%s\n%s\n' "$A" "$D" "$U" | sorted_lines)"
expect_eq "neighbors(T) adjacent nodes" "$got_nodes" "$want_nodes"

# --- Neighbors of P: incident edges e2 (P->A), e3 (C->P); adjacent A,C.
neigh_P="$(singular_graph_query_neighbors "$GDIR_A" "$P")" || fail "neighbors(P) nonzero exit"
got_edges="$(printf '%s\n' "$neigh_P" | kind_ids edge)"
want_edges="$(printf '%s\n%s\n' "$E_P_df_A" "$E_C_crit_P" | sorted_lines)"
expect_eq "neighbors(P) incident edges" "$got_edges" "$want_edges"
got_nodes="$(printf '%s\n' "$neigh_P" | kind_ids node)"
want_nodes="$(printf '%s\n%s\n' "$A" "$C" | sorted_lines)"
expect_eq "neighbors(P) adjacent nodes" "$got_nodes" "$want_nodes"

# --- Unknown node id -> empty result, zero exit (fail-safe).
unknown="n-000000000000"
neigh_unknown="$(singular_graph_query_neighbors "$GDIR_A" "$unknown")" \
  || fail "neighbors(unknown) must exit zero (fail-safe)"
[[ -z "$neigh_unknown" ]] || fail "neighbors(unknown) must be empty, got [$neigh_unknown]"

# --- Determinism: neighbors emits byte-identical output on repeat.
neigh_T2="$(singular_graph_query_neighbors "$GDIR_A" "$T")" || fail "neighbors(T) repeat nonzero exit"
[[ "$neigh_T" == "$neigh_T2" ]] || fail "neighbors(T) not byte-identical on repeat"

# --- Lineage from T: connected provenance component {T,A,P,C,F,D}. U is joined
#     only by a non-provenance (contradicts) edge, so it must be EXCLUDED.
lin_T="$(singular_graph_query_lineage "$GDIR_A" "$T")" || fail "lineage(T) nonzero exit"
got_lin="$(printf '%s\n' "$lin_T" | kind_ids node)"
want_lin="$(printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$T" "$A" "$P" "$C" "$F" "$D" | sorted_lines)"
expect_eq "lineage(T) reachable nodes" "$got_lin" "$want_lin"
printf '%s\n' "$got_lin" | grep -qx "$U" && fail "lineage(T) must exclude off-provenance node U"

# --- Lineage is the connected component: walking from a mid node (C) yields the
#     same set, and the cycle (D -> T revises) terminates via the visited guard.
lin_C="$(singular_graph_query_lineage "$GDIR_A" "$C")" || fail "lineage(C) nonzero exit"
got_lin_C="$(printf '%s\n' "$lin_C" | kind_ids node)"
expect_eq "lineage(C) equals connected component" "$got_lin_C" "$want_lin"

# --- Lineage of an unknown start -> empty, zero exit.
lin_unknown="$(singular_graph_query_lineage "$GDIR_A" "$unknown")" \
  || fail "lineage(unknown) must exit zero (fail-safe)"
[[ -z "$lin_unknown" ]] || fail "lineage(unknown) must be empty, got [$lin_unknown]"

# =============================================================================
# CORPUS B — open-contradictions.
# X contradicts Y  (Y NOT superseded)          -> OPEN
# X invalidates  Z (Z NOT superseded)          -> OPEN
# M invalidates  N (N superseded by S)         -> RESOLVED (excluded)
# =============================================================================
GDIR_B="$work_root/graph-b"
NODES_B="$work_root/nodes-b.in"
EDGES_B="$work_root/edges-b.in"

X="$(singular_graph_node_id 'src:X')"
Y="$(singular_graph_node_id 'con:Y')"
Z="$(singular_graph_node_id 'con:Z')"
M="$(singular_graph_node_id 'src:M')"
N="$(singular_graph_node_id 'con:N')"
S="$(singular_graph_node_id 'sup:S')"

{
  singular_graph_emit_node plan-version 'src:X' 'src/X' 'cX'
  singular_graph_emit_node plan-version 'con:Y' 'src/Y' 'cY'
  singular_graph_emit_node plan-version 'con:Z' 'src/Z' 'cZ'
  singular_graph_emit_node plan-version 'src:M' 'src/M' 'cM'
  singular_graph_emit_node plan-version 'con:N' 'src/N' 'cN'
  singular_graph_emit_node plan-version 'sup:S' 'src/S' 'cS'
} > "$NODES_B"

E_X_con_Y="$(singular_graph_edge_id "$X" contradicts "$Y")"
E_X_inv_Z="$(singular_graph_edge_id "$X" invalidates "$Z")"
E_M_inv_N="$(singular_graph_edge_id "$M" invalidates "$N")"
E_S_sup_N="$(singular_graph_edge_id "$S" supersedes "$N")"

{
  singular_graph_emit_edge contradicts "$X" "$Y" 'src/b1' 'b1'
  singular_graph_emit_edge invalidates "$X" "$Z" 'src/b2' 'b2'
  singular_graph_emit_edge invalidates "$M" "$N" 'src/b3' 'b3'
  singular_graph_emit_edge supersedes  "$S" "$N" 'src/b4' 'b4'
} > "$EDGES_B"

singular_graph_write_corpus "$GDIR_B" "$NODES_B" "$EDGES_B" || fail "write_corpus B failed"

open_con="$(singular_graph_query_open_contradictions "$GDIR_B")" || fail "open_contradictions nonzero exit"
got_open="$(printf '%s\n' "$open_con" | kind_ids edge)"
want_open="$(printf '%s\n%s\n' "$E_X_con_Y" "$E_X_inv_Z" | sorted_lines)"
expect_eq "open_contradictions unresolved set" "$got_open" "$want_open"
# The supersedes-resolved invalidation (M -> N) must be excluded.
printf '%s\n' "$got_open" | grep -qx "$E_M_inv_N" && fail "open_contradictions must exclude the resolved M->N edge"
# The supersedes edge itself is never reported.
printf '%s\n' "$got_open" | grep -qx "$E_S_sup_N" && fail "open_contradictions must not emit the supersedes edge"

# Determinism: byte-identical on repeat.
open_con2="$(singular_graph_query_open_contradictions "$GDIR_B")" || fail "open_contradictions repeat nonzero exit"
[[ "$open_con" == "$open_con2" ]] || fail "open_contradictions not byte-identical on repeat"

# =============================================================================
# Read-only + fail-safe.
# =============================================================================
# Every query above must have left CORPUS A byte-identical and created no files.
snapshot_a_before="$(cd "$GDIR_A" && find . | LC_ALL=C sort)"
sum_before="$(cat "$GDIR_A/nodes.jsonl" "$GDIR_A/edges.jsonl" | shasum | awk '{print $1}')"
singular_graph_query_neighbors "$GDIR_A" "$T" >/dev/null || fail "read-only neighbors failed"
singular_graph_query_lineage "$GDIR_A" "$T" >/dev/null || fail "read-only lineage failed"
singular_graph_query_open_contradictions "$GDIR_A" >/dev/null || fail "read-only open_contradictions failed"
snapshot_a_after="$(cd "$GDIR_A" && find . | LC_ALL=C sort)"
sum_after="$(cat "$GDIR_A/nodes.jsonl" "$GDIR_A/edges.jsonl" | shasum | awk '{print $1}')"
[[ "$snapshot_a_before" == "$snapshot_a_after" ]] || fail "a query created/removed files under <graphDir> (must be read-only)"
[[ "$sum_before" == "$sum_after" ]] || fail "a query mutated the corpus (must be read-only)"

# Missing corpus -> well-formed empty result, zero exit.
GDIR_MISSING="$work_root/graph-missing"
mres="$(singular_graph_query_neighbors "$GDIR_MISSING" "$T")" \
  || fail "neighbors on missing corpus must exit zero"
[[ -z "$mres" ]] || fail "neighbors on missing corpus must be empty"
mres="$(singular_graph_query_lineage "$GDIR_MISSING" "$T")" \
  || fail "lineage on missing corpus must exit zero"
[[ -z "$mres" ]] || fail "lineage on missing corpus must be empty"
mres="$(singular_graph_query_open_contradictions "$GDIR_MISSING")" \
  || fail "open_contradictions on missing corpus must exit zero"
[[ -z "$mres" ]] || fail "open_contradictions on missing corpus must be empty"
[[ ! -e "$GDIR_MISSING" ]] || fail "querying a missing corpus created <graphDir> (must be read-only)"

# Empty corpus -> well-formed empty result, zero exit.
GDIR_EMPTY="$work_root/graph-empty"
mkdir -p "$GDIR_EMPTY"
: > "$GDIR_EMPTY/nodes.jsonl"
: > "$GDIR_EMPTY/edges.jsonl"
eres="$(singular_graph_query_neighbors "$GDIR_EMPTY" "$T")" || fail "neighbors on empty corpus must exit zero"
[[ -z "$eres" ]] || fail "neighbors on empty corpus must be empty"
eres="$(singular_graph_query_lineage "$GDIR_EMPTY" "$T")" || fail "lineage on empty corpus must exit zero"
[[ -z "$eres" ]] || fail "lineage on empty corpus must be empty"
eres="$(singular_graph_query_open_contradictions "$GDIR_EMPTY")" || fail "open_contradictions on empty corpus must exit zero"
[[ -z "$eres" ]] || fail "open_contradictions on empty corpus must be empty"

echo "test-ctx-graph-query: all assertions passed"
