#!/usr/bin/env bash
set -euo pipefail
# A small seam around the driver's phase, following its existing phase API.
# Nothing here classifies outcomes, retries a proof, or writes proof evidence.
engine="$1"; fixture_root="$2"; definitions="$3"; n="$4"
SCRIPT_DIR="$engine/engine"
source "$SCRIPT_DIR/lib.sh"
source "$definitions"
declare -F run_red_proof_phase >/dev/null || {
  echo 'S1.1: host red-proof phase is absent (run_red_proof_phase)' >&2
  exit 90
}
task_id=TASK-0001
run_id=RUN-PROOF
run_dir="$SINGULAR_STATE_DIR/runs/$run_id"
task_file="$SINGULAR_TASKS_DIR/$task_id.md"
lease_path="$SINGULAR_STATE_DIR/leases/$task_id.json"
task_json="$(singular_task_json "$task_file")"
tf() { printf '%s' "$task_json" | python3 -c 'import json,sys; v=json.load(sys.stdin)[sys.argv[1]]; print(json.dumps(v) if isinstance(v,(list,dict)) else v)' "$1"; }
test_policy="$(tf testPolicy)"
worktree="$fixture_root/worker"
worker_branch=agent/widget/TASK-0001-fixture
target_branch=target
head_sha="$(git -C "$worktree" rev-parse HEAD)"
base_sha="$(git -C "$SINGULAR_ROOT" rev-parse target)"
branch_base="$base_sha"; packet_base_ref="$base_sha"
attempt_failure=""; attempt_ctx=""; verdict=unknown
product_repairs_used=0
# Status UI is outside this seam; event emission and lease helpers stay real.
l1_status() { :; }
rc=0
run_red_proof_phase "$n" || rc=$?
python3 - "$fixture_root/phase-result.json" "$rc" "$attempt_failure" "$attempt_ctx" "$product_repairs_used" <<'PY'
import json, sys
path, rc, failure, context, used = sys.argv[1:]
with open(path, "w") as out:
    json.dump(dict(exit=int(rc), failure=failure, context=context, repairs=int(used)), out)
PY
