#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$1/engine"
source "$SCRIPT_DIR/lib.sh"
source "$2"
run_id=RUN-PROOF
task_id=TASK-0001
run_dir="$SINGULAR_RUNS_DIR/$run_id"
task_file="$SINGULAR_TASKS_DIR/$task_id.md"
lease_path="$SINGULAR_LEASES_DIR/$task_id.json"
task_json="$(singular_task_json "$task_file")"
worktree="$SINGULAR_WORKTREES_DIR/$task_id"
worker_branch=agent/widget/TASK-0001-fixture
target_branch=target
head_sha="$(git -C "$worktree" rev-parse HEAD)"
packet_base_ref="$(singular_lease_field "$task_id" baseSha)"
branch_base="$packet_base_ref"
packet="$run_dir/packet.json"
audit_record="$run_dir/audit.json"
review_logical_change="$task_id"
l1_campaign_binding=legacy
_l1_campaign_lock_held=no
_l1_git_lock_held=no
l1_acceptance_refusal=""
accepted=yes
waiver=no
verdict=accepted
n=1
require_audit=1
terminal_action=""
terminal_authority=policy
terminal_rationale=""
attempt_failure=""
test_policy=strict_test_first
# Only status presentation is outside the acceptance/publication seam.
l1_status() { :; }
if [[ "$4" == check ]]; then
  l1_validate_acceptance ordinary "$run_id" "$run_dir" "$head_sha" 1 1
else
  source "$3"
fi
