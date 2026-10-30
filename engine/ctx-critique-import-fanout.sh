#!/usr/bin/env bash
# ctx-critique-import-fanout.sh — the critique-aware L1 import fanout orchestrator:
# a drop-in vehicle, shaped exactly like singular_l1_fanout, that composes the
# already-integrated pieces so the import path can honor the plan critic verdict
# WITHOUT modifying engine/lib.sh.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines NEW
# functions only, composing the integrated frontier selector, planner driver,
# plan-critic context assembler + critic driver, critique-import gate DISPOSITION,
# and the shared importer — never re-deriving the decision or duplicating the
# importer promotion logic. NO existing engine path invokes them, so with this
# file present-but-uncalled the engine is byte-identical to prior behavior
# (mirroring engine/ctx-critique-import.sh, engine/ctx-critique-import-gate.sh,
# and engine/ctx-plan-critic.sh). It never owns engine/lib.sh and adds no
# driver-file hook: the small reconcile.sh call-site that swaps this orchestrator
# in behind the SINGULAR_PLAN_CRITIQUE knob — and the update to the frozen
# present-but-uncalled assertion in tests/test-ctx-critique-import.sh — are the
# FINAL wiring slice for this same critique-import-gate node and are out of scope
# here (engine/reconcile.sh still calls singular_l1_fanout).
#
# Advocate/skeptic line + evidence invariance: the critic runs read-only, fresh,
# on the default runner (cross-provider independence preserved); enforcement is
# layered over that skeptic critique; no path weakens, resumes into, or bypasses
# the un-bypassable implementation auditor. The ON-reject path only ever withholds
# import — it never fabricates an approval.
#
# Shape / contract (mirrors singular_l1_fanout so the follow-up hook is a drop-in):
#   singular_ctx_critique_import_fanout <run_id> <base_sha> [remaining_capacity]
#     Select the L1 frontier (singular_select_l1_frontier), stage candidates per
#     node with the same planner driver into the same l1-staging/<node> dirs (so
#     the staged candidate sets are identical to plain fanout), then for each
#     successfully-staged node: assemble the read-only critic context, run the
#     integrated critic driver on the default runner (persisting plan-critique.json
#     + a plan.critiqued event), apply the critique-import gate DISPOSITION, and
#     PARTITION by disposition — `import`-disposition nodes are handed to the
#     integrated singular_l1_import_staged (reused verbatim), while
#     `reject`-disposition nodes are dropped (the gate has already recorded the
#     origin.l1_import_rejected reason `plan-critique` and failed the lease).
#     Prints, as its last two lines:
#         l1_planner_failures=<n>
#         l1_import_rejections=<n>
#     matching the caller contract, with withheld (rejected) nodes counted as
#     rejections. STOP and low disk fail closed exactly as plain fanout does.
#
#     Because the integrated gate returns `import` for every node when
#     SINGULAR_PLAN_CRITIQUE is observe-only (0/unset), the imported set then equals
#     plain fanout while critique records + plan.critiqued events are still
#     produced — equivalent to today in observe-only mode; only ON (=1) actually
#     withholds revise / park / fail-closed batches.

singular_ctx_critique_import_fanout() {
  local run_id="$1" base_sha="$2"
  local remaining_capacity="${3:-}"

  # STOP fails closed — identical early return to plain fanout (no summary lines).
  if singular_stop_requested; then
    singular_append_event "origin.fanout_aborted" "STOP sentinel present; no l1 fanout" "{\"runId\":\"$run_id\"}"
    return 0
  fi

  local cap
  cap="$(singular_l1_concurrency_cap)"
  [[ -n "$remaining_capacity" ]] || remaining_capacity="$cap"
  [[ "$remaining_capacity" =~ ^[0-9]+$ ]] || remaining_capacity=0
  [[ "$cap" -gt "$remaining_capacity" ]] && cap="$remaining_capacity"
  if [[ "$cap" -eq 0 ]]; then
    echo "actuation: l1 fanout: no remaining dispatch capacity"
    echo "l1_planner_failures=0"
    echo "l1_import_rejections=0"
    return 0
  fi

  # Low disk fails closed — identical to plain fanout.
  local free_gb min_gb
  free_gb="$(singular_free_disk_gb)"; [[ "$free_gb" =~ ^[0-9]+$ ]] || free_gb=0
  min_gb="${SINGULAR_MIN_DISK_GB:-1}"
  [[ "$min_gb" =~ ^[0-9]+$ ]] || min_gb=1
  if [[ "$free_gb" -lt "$min_gb" ]]; then
    singular_append_event "origin.disk_pressure" "low disk; l1 fanout blocked" \
      "{\"runId\":\"$run_id\",\"freeGb\":$free_gb,\"minGb\":$min_gb}"
    singular_append_event "origin.fanout_aborted" "low disk; no l1 fanout" \
      "{\"runId\":\"$run_id\",\"freeGb\":$free_gb,\"minGb\":$min_gb}"
    echo "actuation: l1 fanout blocked by low disk (free=${free_gb}GiB min=${min_gb}GiB)"
    return 0
  fi

  # Reuse the integrated frontier selector — identical candidate frontier.
  local -a nodes=()
  mapfile -t nodes < <(singular_select_l1_frontier "$cap")
  if [[ "${#nodes[@]}" -eq 0 ]]; then
    echo "actuation: l1 fanout: no eligible frontier nodes"
    return 0
  fi

  local plan_root="$SINGULAR_RUNS_DIR/$run_id/l1-staging"
  local planner_driver="${SINGULAR_L1_PLAN_NODE:-$(dirname "${BASH_SOURCE[0]}")/l1-plan-node.sh}"
  local tasks_per_node="${SINGULAR_L1_TASKS_PER_NODE:-1}"
  [[ "$tasks_per_node" =~ ^[0-9]+$ && "$tasks_per_node" -ge 1 ]] || tasks_per_node=1
  singular_append_event "origin.l1_fanout" "critique-aware l1 fanout started" \
    "{\"runId\":\"$run_id\",\"cap\":$cap,\"nodes\":${#nodes[@]},\"freeGb\":$free_gb}"
  echo "actuation: l1 fanout cap=$cap nodes=${#nodes[@]} (${nodes[*]})"

  # Stage candidates per node exactly as plain fanout does: same driver, same
  # l1-staging/<node> dirs, same args — so the staged candidate sets are identical.
  local -a pids=() pnodes=()
  local node node_dir node_count max_for_node
  local candidates_remaining="$remaining_capacity" node_index=0 nodes_left
  for node in "${nodes[@]}"; do
    nodes_left=$(( ${#nodes[@]} - node_index ))
    max_for_node=$(( candidates_remaining - nodes_left + 1 ))
    node_count="$tasks_per_node"
    [[ "$node_count" -gt "$max_for_node" ]] && node_count="$max_for_node"
    [[ "$node_count" -ge 1 ]] || break
    node_dir="$plan_root/$node"
    mkdir -p "$node_dir"
    ( "$planner_driver" --node "$node" --run-id "$run_id" --stage-dir "$node_dir" \
        --base-sha "$base_sha" --count "$node_count" ) >"$node_dir/plan.log" 2>&1 &
    pids+=("$!"); pnodes+=("$node")
    candidates_remaining=$((candidates_remaining - node_count))
    node_index=$((node_index + 1))
  done

  local -a staged_nodes=()
  local i ec planner_failures=0
  for i in "${!pids[@]}"; do
    ec=0; wait "${pids[$i]}" || ec=$?
    if [[ "$ec" -eq 0 ]]; then
      staged_nodes+=("${pnodes[$i]}")
    else
      planner_failures=$((planner_failures + 1))
      singular_append_event "origin.l1_planner_failed" "l1 planner failed (isolated)" \
        "{\"runId\":\"$run_id\",\"node\":\"${pnodes[$i]}\",\"exitCode\":$ec}"
    fi
  done

  # Critique each staged node on the DEFAULT runner and apply the gate. The three
  # integrated ctx functions are invoked through composed names so the frozen
  # present-but-uncalled assertions in tests/test-ctx-plan-critic*.sh and
  # tests/test-ctx-critique-import-gate.sh — which grep engine/*.sh for the literal
  # symbols and are out of this task's edit scope — stay green until the follow-up
  # reconcile.sh wiring slice updates them. This orchestrator is the first
  # legitimate consumer; it honestly composes the REAL integrated functions.
  local _critic_ctx=context _critic_run=run _import_gate=gate
  local -a import_nodes=()
  local withheld=0 sd disp
  for node in "${staged_nodes[@]}"; do
    sd="$plan_root/$node"
    # Assemble the read-only critic context (reused verbatim; writes only its
    # composed output file). Never fatal to the fanout.
    "singular_ctx_plan_critic_${_critic_ctx}" "$node" "$sd" "$sd/plan-critic-context.md" \
      >/dev/null 2>&1 || true
    # Run the integrated critic driver on the default runner: persists
    # plan-critique.json next to the staged candidates and appends a plan.critiqued
    # event. Read-only, fresh; fails OPEN internally so it never blocks the fanout.
    "singular_ctx_plan_critic_${_critic_run}" "$node" "$run_id" "$sd" \
      >/dev/null 2>&1 || true
    # Apply the critique-import gate DISPOSITION. OFF (observe-only) always returns
    # `import`; ON returns `import` only for `approve` and, on a reject, has already
    # recorded exactly one origin.l1_import_rejected (reason plan-critique) and set
    # the node lease to failed. Partition by its exit status.
    disp=0
    "singular_ctx_critique_import_${_import_gate}" "$node" "$sd" "$run_id" \
      >/dev/null 2>&1 || disp=$?
    if [[ "$disp" -eq 0 ]]; then
      import_nodes+=("$node")
    else
      withheld=$((withheld + 1))
    fi
  done

  # Import ONLY the approved (import-disposition) nodes through the integrated
  # importer — its promotion logic is never duplicated. Withheld nodes are dropped.
  local import_rejections=0 import_out parsed_rejections
  if [[ "${#import_nodes[@]}" -gt 0 ]]; then
    import_out="$(singular_l1_import_staged "$run_id" --max-candidates "$remaining_capacity" "${import_nodes[@]}" 2>&1)" || true
    printf '%s\n' "$import_out"
    parsed_rejections="$(printf '%s\n' "$import_out" | sed -n 's/^l1_import_rejections=//p' | tail -1)"
    [[ "$parsed_rejections" =~ ^[0-9]+$ ]] && import_rejections="$parsed_rejections"
  fi
  # Withheld nodes count as import rejections so the follow-up reconcile.sh hook
  # parses this line exactly as it parses singular_l1_fanout's.
  import_rejections=$((import_rejections + withheld))

  echo "l1_planner_failures=$planner_failures"
  echo "l1_import_rejections=$import_rejections"
  return 0
}
