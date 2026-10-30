#!/usr/bin/env bash
set -euo pipefail

# Re-run a committed worker gate in a disposable writable worktree. The
# original audited worktree is never used as the command's cwd.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

run_dir=""
task_id=""
source_worktree=""
head_sha=""
gate_command=""
worker_gate_report=""
worker_gate_command=""
attempt="1"
try_number="0"
evidence_only="no"
verification_request=""
verification_task_contract=""
verification_policy_contract=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-dir) run_dir="${2:-}"; shift 2 ;;
    --task-id) task_id="${2:-}"; shift 2 ;;
    --source-worktree) source_worktree="${2:-}"; shift 2 ;;
    --head-sha) head_sha="${2:-}"; shift 2 ;;
    --gate-command) gate_command="${2:-}"; shift 2 ;;
    --worker-gate-report) worker_gate_report="${2:-}"; shift 2 ;;
    --worker-gate-command) worker_gate_command="${2:-}"; shift 2 ;;
    --attempt) attempt="${2:-}"; shift 2 ;;
    --try) try_number="${2:-}"; shift 2 ;;
    --evidence-only) evidence_only="yes"; shift ;;
    --verification-request) verification_request="${2:-}"; shift 2 ;;
    --task-contract) verification_task_contract="${2:-}"; shift 2 ;;
    --policy-contract) verification_policy_contract="${2:-}"; shift 2 ;;
    *) echo "audit-verify: unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$verification_request" && -n "$verification_task_contract" \
    && -n "$verification_policy_contract" ]] || {
  echo "audit-verify: identity-bound verification request, task contract, and policy contract are required" >&2
  exit 2
}
[[ -n "$run_dir" && -d "$run_dir" ]] || { echo "audit-verify: --run-dir is required" >&2; exit 2; }
[[ "$task_id" =~ ^TASK-[0-9]{4,}$ ]] || { echo "audit-verify: valid --task-id is required" >&2; exit 2; }
[[ -n "$source_worktree" && -d "$source_worktree" ]] || { echo "audit-verify: --source-worktree is required" >&2; exit 2; }
[[ "$head_sha" =~ ^[0-9a-fA-F]{40,64}$ ]] || { echo "audit-verify: valid --head-sha is required" >&2; exit 2; }
[[ "$attempt" =~ ^[1-9][0-9]*$ ]] || { echo "audit-verify: positive --attempt is required" >&2; exit 2; }

# Compare the complete host invocation identity before creating a disposable
# workspace, copying evidence, or launching the trusted command.
expected_run_id="${run_dir##*/}"
expected_head_sha="$(git -C "$source_worktree" rev-parse "$head_sha^{commit}" 2>/dev/null || true)"
expected_tree_sha="$(git -C "$source_worktree" rev-parse "$head_sha^{tree}" 2>/dev/null || true)"
[[ "$expected_head_sha" == "$head_sha" && "$expected_tree_sha" =~ ^[0-9a-f]{40,64}$ ]] || {
  echo "audit-verify: invocation commit/tree identity is invalid" >&2
  exit 2
}
expected_campaign="$(singular_campaign_binding 2>/dev/null)" || {
  echo "audit-verify: current campaign identity is unavailable" >&2
  exit 2
}
resolve_args=(
  resolve-verification-request
  --request "$verification_request"
  --task-contract "$verification_task_contract"
  --policy-contract "$verification_policy_contract"
  --expected-task "$task_id"
  --expected-run "$expected_run_id"
  --expected-head "$expected_head_sha"
  --expected-tree "$expected_tree_sha"
  --expected-attempt "$attempt"
  --expected-suite task-contract-gate
  --expected-campaign "$expected_campaign"
)
current_task_contract="$SINGULAR_TASKS_DIR/$task_id.md"
[[ -f "$current_task_contract" ]] \
  && resolve_args+=(--current-task-contract "$current_task_contract")
trusted_gate_command="$(python3 "$SCRIPT_DIR/gate-report.py" "${resolve_args[@]}")" || exit 2
if [[ -n "$gate_command" && "$gate_command" != "$trusted_gate_command" ]]; then
  echo "audit-verify: caller gate command differs from trusted verification contract" >&2
  exit 2
fi
gate_command="$trusted_gate_command"
[[ -n "$gate_command" ]] || { echo "audit-verify: --gate-command is required" >&2; exit 2; }
[[ -n "$worker_gate_report" ]] || worker_gate_report="$run_dir/gate-check.json"
[[ -n "$worker_gate_command" ]] || worker_gate_command="$gate_command"

output="$run_dir/audit-verification.json"
if [[ "$evidence_only" == "yes" ]]; then
  [[ -n "$verification_request" ]] || {
    echo "audit-verify: evidence-only verification requires an identity-bound request" >&2
    exit 2
  }
  "$SCRIPT_DIR/gate-report.py" copy-evidence \
    --report "$worker_gate_report" \
    --output "$output" \
    --expected-head "$head_sha" \
    --expected-command "$worker_gate_command"
  "$SCRIPT_DIR/gate-report.py" bind-verification-result \
    --request "$verification_request" --report "$output" \
    --task-contract "$verification_task_contract" \
    --policy-contract "$verification_policy_contract" \
    --evidence-source-command "$worker_gate_command"
  "$SCRIPT_DIR/gate-report.py" verify-verification-result \
    --request "$verification_request" --report "$output" \
    --task-contract "$verification_task_contract" \
    --policy-contract "$verification_policy_contract" \
    --expected-task "$task_id" --expected-run "$expected_run_id" \
    --expected-head "$expected_head_sha" --expected-tree "$expected_tree_sha" \
    --expected-attempt "$attempt" --expected-suite task-contract-gate \
    --expected-campaign "$expected_campaign" --require-pass
  printf '%s\n' "$output"
  exit 0
fi

safe_run_id="${run_dir##*/}"
safe_run_id="${safe_run_id//[^A-Za-z0-9_.-]/_}"
log="$run_dir/audit-verification-${attempt}-${try_number}.log"
observation="$run_dir/audit-gate-observation-${attempt}-${try_number}.json"
gate_timeout="${SINGULAR_AUDIT_GATE_TIMEOUT_SEC:-1200}"
[[ "$gate_timeout" =~ ^[0-9]+$ ]] || gate_timeout=1200
scratch_args=(
  --commit "$head_sha" --command "$gate_command" --log "$log"
  --timeout "$gate_timeout" --scratch-parent "${TMPDIR:-/tmp}"
  --scratch-prefix "singular-audit-${safe_run_id}"
  --dependency-source "$source_worktree" --source-worktree "$source_worktree"
  --observation "$observation" --log-label "audit verification"
)
[[ "${SINGULAR_AUDIT_VERIFY_FORCE_SETUP_FAILURE:-0}" != 1 ]] \
  || scratch_args+=(--force-setup-failure)
# scratch-run uses singular_worktree_prepare for the same preparation as workers.
# Explicit overrides keep this audit path's existing location and dependencies.
scratch_rc=0
scratch_result="$(SINGULAR_ROOT="$SINGULAR_ROOT" SINGULAR_STATE_DIR="$SINGULAR_STATE_DIR" \
  SINGULAR_ENGINE_HOME="$SINGULAR_ENGINE_HOME" \
  "$SINGULAR_LIB_DIR/scratch-run.sh" "${scratch_args[@]}")" || scratch_rc=$?
mapfile -t scratch_fields < <(python3 - "$scratch_result" <<'PY'
import json
import sys
result = json.loads(sys.argv[1])
print(result["setupError"] or "")
print(result["rawExitCode"] if result["rawExitCode"] is not None else 125)
print(result["durationMs"])
print(result["sourceIntegrity"]["status"])
for path in result["sourceIntegrity"]["changedPaths"]:
    print(path)
PY
)
emit_setup_failure() {
  local reason="$1"
  printf 'audit verification setup failed: %s\n' "$reason" >"$log"
  local report_rc=0
  "$SCRIPT_DIR/gate-report.py" create \
    --output "$output" \
    --task-id "$task_id" \
    --run-id "${run_dir##*/}" \
    --head-sha "$head_sha" \
    --command "$gate_command" \
    --exit-code 125 \
    --log "$log" \
    --phase audit-verification \
    --workspace-kind disposable \
    --integrity-status not-checked \
    --setup-error "$reason" || report_rc=$?
  printf '%s\n' "$output"
  [[ "$report_rc" -eq 0 ]] && report_rc=20
  return "$report_rc"
}

if [[ "$scratch_rc" -ne 0 || ${#scratch_fields[@]} -lt 4 || -n "${scratch_fields[0]}" ]]; then
  emit_setup_failure "${scratch_fields[0]:-scratch-run-failed}"
  exit $?
fi
gate_exit="${scratch_fields[1]}"
duration_ms="${scratch_fields[2]}"
integrity_status="${scratch_fields[3]}"
changed_paths=("${scratch_fields[@]:4}")

report_args=(
  --task-id "$task_id"
  --run-id "${run_dir##*/}"
  --head-sha "$head_sha"
  --command "$gate_command"
  --duration-ms "$duration_ms"
  --phase audit-verification
  --workspace-kind disposable
  --integrity-status "$integrity_status"
)
for changed in "${changed_paths[@]}"; do
  report_args+=(--changed-path "$changed")
done
report_rc=0
if [[ "${SINGULAR_CONFIG_SCHEMA_VERSION:-}" == "v2" ]]; then
  strict_args=(
    "${report_args[@]}"
    --raw-exit-code "$gate_exit"
    --log-ref "$log"
    --log-path "$log"
    --output "$output"
    --require-observation
  )
  [[ -f "$observation" ]] && strict_args+=(--observation "$observation")
  normalize_rc=0
  "$SCRIPT_DIR/gate_report.py" "${strict_args[@]}" \
    >"$run_dir/audit-gate-normalize-${attempt}-${try_number}.out" \
    2>"$run_dir/audit-gate-normalize-${attempt}-${try_number}.err" \
    || normalize_rc=$?
  if [[ "$normalize_rc" -ne 0 || ! -f "$output" ]]; then
    setup_reason="gate-report-normalization-failed"
    [[ -f "$observation" ]] || setup_reason="strict-gate-observation-missing"
    fallback_args=(
      create
      --output "$output"
      --exit-code "$gate_exit"
      --log "$log"
      --setup-error "$setup_reason"
      "${report_args[@]}"
    )
    if [[ "$gate_exit" -eq 124 || "$gate_exit" -eq 137 || "$gate_exit" -eq 143 ]]; then
      fallback_args+=(--setup-error gate-command-timeout)
    fi
    "$SCRIPT_DIR/gate-report.py" "${fallback_args[@]}" || report_rc=$?
  else
    normalized_outcome="$(singular_json_field "$output" outcome 2>/dev/null || true)"
    case "$normalized_outcome" in
      passed|passed-with-acknowledged-baseline) report_rc=0 ;;
      failed-product) report_rc=10 ;;
      *) report_rc=20 ;;
    esac
  fi
else
  legacy_args=(
    create
    --output "$output"
    --exit-code "$gate_exit"
    --log "$log"
    "${report_args[@]}"
  )
  "$SCRIPT_DIR/gate-report.py" "${legacy_args[@]}" || report_rc=$?
fi
"$SCRIPT_DIR/gate-report.py" bind-verification-result \
  --request "$verification_request" --report "$output" \
  --task-contract "$verification_task_contract" \
  --policy-contract "$verification_policy_contract" || report_rc=20
"$SCRIPT_DIR/gate-report.py" verify-verification-result \
  --request "$verification_request" --report "$output" \
  --task-contract "$verification_task_contract" \
  --policy-contract "$verification_policy_contract" \
  --expected-task "$task_id" --expected-run "$expected_run_id" \
  --expected-head "$expected_head_sha" --expected-tree "$expected_tree_sha" \
  --expected-attempt "$attempt" --expected-suite task-contract-gate \
  --expected-campaign "$expected_campaign" || report_rc=20
printf '%s\n' "$output"
exit "$report_rc"
