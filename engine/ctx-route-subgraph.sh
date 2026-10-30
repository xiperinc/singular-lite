#!/usr/bin/env bash
# Select the configured graph-backed rehydration mode and render its packet and manifest.
singular_ctx_route_subgraph_manifest() {
  local reason="$1" role="$2" step="$3" meta="$4" key="$5"

  local graph_dir="${SINGULAR_CTX_GRAPH_DIR:-.singular-state/graph}"

  # Subgraph branch: only behind the dedicated knob AND the integrated arm
  # decider's `subgraph` verdict (which itself re-checks the knob, the treatment
  # arm, and a present non-empty corpus — do NOT duplicate those conditions).
  if [[ "${SINGULAR_CTX_SUBGRAPH_REHYDRATE:-0}" == "1" ]] \
     && [[ "$(singular_ctx_rehydrate_subgraph_arm_mode "$key" "$graph_dir")" == "subgraph" ]]; then
    # Deterministic task node id from the integrated identity primitives, so the
    # selected node agrees with every other graph mapper.
    local node
    node="$(singular_graph_node_id "$(singular_graph_identity task "$key")")"
    singular_ctx_rehydrate_subgraph_assemble "$graph_dir" "$node" manifest
    return 0
  fi

  # FLAT branch: byte-identical to the legacy composition the route used before
  # this wire-in — resolve durable sources over the run_dir and render a manifest.
  local run_dir; run_dir="$(dirname "$meta")"
  local -a specs=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && specs+=("$line")
  done < <(singular_ctx_rehydrate_sources "$run_dir")

  singular_ctx_rehydrate_manifest ${specs[@]+"${specs[@]}"}
  return 0
}

# singular_ctx_route_subgraph_render <task_id> <packet|manifest>
#   The SHARED subgraph selector both the l1-drive.sh packet-injection site and the
#   ctx-rehydrate-event.sh manifest-record site key on, so the injected packet and
#   the recorded manifest carry the SAME subgraph sources BY CONSTRUCTION: both
#   pass the SAME task_id, the same arm-mode decider re-checks the same knob /
#   treatment arm / present non-empty corpus, and the SAME deterministic node id is
#   resolved.
#
#   When singular_ctx_rehydrate_subgraph_arm_mode <task_id> <graphDir> == subgraph
#   (graphDir = ${SINGULAR_CTX_GRAPH_DIR:-.singular-state/graph}), resolve
#     node = singular_graph_node_id( singular_graph_identity task <task_id> )
#   and print singular_ctx_rehydrate_subgraph_assemble <graphDir> <node> <mode>,
#   returning 0. Otherwise print NOTHING and return non-zero, signalling the caller
#   to keep its existing FLAT composition. <mode> is `packet` or `manifest`.
#
#   Feature-flag discipline: the arm decider defaults SINGULAR_CTX_SUBGRAPH_REHYDRATE
#   OFF, so this always returns non-zero/empty by default and both sites use the
#   flat path — byte-identical to today. The subgraph branch is reachable only with
#   the knob on, the treatment arm, and a present non-empty corpus (all re-checked
#   by the arm decider — do NOT duplicate those conditions here).
#
#   Evidence invariance: a PURE READ — appends no events, writes/renames/deletes
#   nothing, confers NO independence; the `rehydrate` strategy stays tainted per
#   singular_ctx_route_strategy_tainted regardless of which path is chosen.
singular_ctx_route_subgraph_render() {
  local task_id="$1" mode="$2"

  local graph_dir="${SINGULAR_CTX_GRAPH_DIR:-.singular-state/graph}"
  [[ "$(singular_ctx_rehydrate_subgraph_arm_mode "$task_id" "$graph_dir")" == "subgraph" ]] \
    || return 1

  local node
  node="$(singular_graph_node_id "$(singular_graph_identity task "$task_id")")"
  singular_ctx_rehydrate_subgraph_assemble "$graph_dir" "$node" "$mode"
  return 0
}
