#!/usr/bin/env bash
# Compose the experiment pipeline and result sections into a report body.

singular_ctx_experiment_report_body_compose() {
  local pipeline_md="${1-}"
  local result_md="${2-}"

  printf '# Experiment report body\n\n'
  printf '## Per-arm metrics\n\n'
  printf '%s\n' "$pipeline_md"
  printf '\n'
  printf '## Treatment effect and arm integrity\n\n'
  printf '%s\n' "$result_md"
  return 0
}

# --- Slice 2: composed public entry ------------------------------------------
# Obtain both rendered fragments by delegating to the two integrated corpus
# renderers over the SAME resolved corpus args (threaded verbatim so each renderer
# performs its own resolution / env-default fallback), compose them via the
# helper, and emit the complete report body to stdout. Deterministic; fail-safe /
# always exit 0.
singular_ctx_experiment_report_body_md() {
  local runs_dir="${1-}"
  local events_file="${2-}"
  local metrics_file="${3-}"
  local pipeline_md result_md

  # The per-arm metrics fragment (escape/cost/bias, strategy, attempts tables).
  pipeline_md="$(singular_ctx_experiment_pipeline_md "$runs_dir" "$events_file" "$metrics_file")"
  # The treatment-effect delta + arm-integrity audit fragment.
  result_md="$(singular_ctx_experiment_render_result_md "$runs_dir" "$events_file" "$metrics_file")"

  singular_ctx_experiment_report_body_compose "$pipeline_md" "$result_md"
  return 0
}
