#!/usr/bin/env bash
# Assemble bounded planning context for the read-only critic from staged tasks and source records.

singular_ctx_plan_critic_stage_file() {
  local node="$1"
  [[ -n "$node" ]] || { printf '%s' ""; return 0; }
  local plan_dir="${SINGULAR_PLAN_DIR:-$SINGULAR_ROOT/docs/context-build-plan}"
  [[ -d "$plan_dir" ]] || { printf '%s' ""; return 0; }
  local bt='`' pat f
  pat="${bt}${node}${bt}"
  for f in "$plan_dir"/*.md; do
    [[ -e "$f" ]] || continue
    if grep -qF -- "$pat" "$f" 2>/dev/null; then
      printf '%s' "$f"
      return 0
    fi
  done
  printf '%s' ""
}

# Pure assembler: compose the read-only critic context into <out_file>. Reads the
# staged candidate bodies, the existing-task summary, and the node stage file;
# writes ONLY the named output file and mutates nothing else. Deterministic: the
# `*.candidate.md` glob expands in sorted order, so the output is byte-stable
# across runs for a fixed input set.
singular_ctx_plan_critic_context() {
  local node="$1" stage_dir="$2" out_file="$3" summary_file="${4:-}"
  local prompt_file="${5:-}" base_sha="${6:-}"
  [[ -n "$out_file" ]] || return 2
  local candidate_batch_dir
  candidate_batch_dir="$(singular_task_batch_candidate_dir "$stage_dir")" || return 2

  [[ -n "$summary_file" ]] || summary_file="$stage_dir/existing-tasks.md"
  local stage_file; stage_file="$(singular_ctx_plan_critic_stage_file "$node")"

  mkdir -p "$(dirname "$out_file")"

  {
    if [[ -n "$prompt_file" && -f "$prompt_file" ]]; then
      printf '# Critic Policy\n\n'
      cat "$prompt_file"
      singular_red_proof_prompt
      printf '\n\n---\n\n'
    fi
    printf '# Plan Critic Context: %s\n\n' "$node"
    printf 'Read-only staged-candidate context for the S2 plan critic (skeptic).\n\n'

    printf '## Bound Lineage\n\n'
    printf -- '- base SHA: `%s`\n\n' "${base_sha:-unknown}"

    printf '## Candidate Tasks\n\n'
    local c
    for c in "$candidate_batch_dir"/*.candidate.md; do
      [[ -e "$c" ]] || continue
      printf '### %s\n\n' "$(basename "$c")"
      cat "$c"
      printf '\n'
    done

    printf '## Existing Task Summary\n\n'
    if [[ -f "$summary_file" ]]; then
      cat "$summary_file"
      printf '\n'
    fi

    printf '## Node Stage File\n\n'
    if [[ -n "$stage_file" && -f "$stage_file" ]]; then
      cat "$stage_file"
      printf '\n'
    fi
  } > "$out_file"

  return 0
}
