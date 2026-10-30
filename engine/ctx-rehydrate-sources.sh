#!/usr/bin/env bash
# Select durable rehydration sources under the configured context policy.

singular_ctx_rehydrate_sources() {
  local run_dir="${1-}"
  [[ $# -gt 0 ]] && shift

  # Fixed source-class order: <id> <run_dir-relative file>. Kept in the
  # assembler's documented rank order so the resolver's stdout composes directly
  # as assembler arguments.
  local map=(
    "task-packet=packet.json"
    "implementer-capsule=implementer-capsule.json"
    "reviewer-capsule=reviewer-capsule.json"
    "findings-ledger=findings-status.json"
    "assumptions-ledger=assumptions-ledger.json"
    "critique-record=plan-critique.json"
  )

  local entry id file path
  if [[ -n "$run_dir" ]]; then
    for entry in "${map[@]}"; do
      id="${entry%%=*}"
      file="${entry#*=}"
      path="$run_dir/$file"
      [[ -f "$path" ]] && printf '%s=%s\n' "$id" "$path"
    done
  fi

  # Caller-supplied extra specs appended verbatim after the run_dir-resolved set.
  local spec
  for spec in "$@"; do
    printf '%s\n' "$spec"
  done
}
