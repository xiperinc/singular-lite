#!/usr/bin/env bash
# Build the role, step, node and task trigger set used for authored-knowledge eligibility.

singular_ctx_rehydrate_authored_triggers() {
  local role="${1-}" step="${2-}" node="${3-}" task="${4-}"
  local dim
  # Fixed dimension order: role, step, node, task. Non-empty dimensions are
  # emitted once each; a `seen` set collapses repeats while the first occurrence
  # fixes the token's position, keeping the output order-stable and deterministic.
  local -A seen=()
  for dim in "$role" "$step" "$node" "$task"; do
    [[ -n "$dim" ]] || continue
    [[ -n "${seen[$dim]+x}" ]] && continue
    seen[$dim]=1
    printf '%s\n' "$dim"
  done
}
