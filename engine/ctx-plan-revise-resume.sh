#!/usr/bin/env bash
# Apply planner session authority checks before resuming a plan revision.

singular_plan_revise_resume_decide() {
  singular_planner_resume_decide "$@"
}

# Records ONLY. Emits EXACTLY ONE role=planner `context.strategy_selected` event
# through singular_append_event carrying node, runId, `revisesRunId` (= the
# critique run being revised, marking this as the revision round), strategy
# (`resume` or `fresh`), the exact `reason`, and `sessionId` on resume. No lease
# change, no runner, no outcome mutation.
#   singular_plan_revise_record_strategy <node> <run_id> <revises_run_id> \
#                                       <strategy> <reason> [session_id]
singular_plan_revise_record_strategy() {
  local node="${1:-}" run_id="${2:-}" revises_run_id="${3:-}" \
        strategy="${4:-}" reason="${5:-}" session_id="${6:-}"

  local event_json message
  event_json="$(python3 - "$node" "$run_id" "$revises_run_id" "$strategy" "$reason" "$session_id" <<'PY'
import json, sys
node, run_id, revises_run_id, strategy, reason, session_id = sys.argv[1:7]
data = {
    "node": node,
    "runId": run_id,
    "revisesRunId": revises_run_id,
    "role": "planner",
    "strategy": strategy,
    "reason": reason,
}
# sessionId is carried only on resume (fresh has no resumed session).
if strategy == "resume":
    data["sessionId"] = session_id
print(json.dumps(data, separators=(",", ":")))
PY
)"

  if [[ "$strategy" == "resume" ]]; then
    message="plan-revision session resume strategy selected"
  else
    message="plan-revision fresh-run strategy selected"
  fi
  singular_append_event "context.strategy_selected" "$message" "$event_json"
  return 0
}

# Records ONLY. Emits the rc-86 fresh-fallback record: EXACTLY ONE role=planner
# `context.resume_failed` event carrying node, runId, revisesRunId, and the
# refused sessionId, so the resume-refused -> fresh transition of a revision round
# is observable to ctx-metrics.sh. This is the "fresh fallback recorded" predicate
# of the node requiredCompletion. No lease change, no runner, no outcome mutation.
#   singular_plan_revise_record_resume_failed <node> <run_id> <revises_run_id> \
#                                            <session_id>
singular_plan_revise_record_resume_failed() {
  local node="${1:-}" run_id="${2:-}" revises_run_id="${3:-}" session_id="${4:-}"

  local event_json
  event_json="$(python3 - "$node" "$run_id" "$revises_run_id" "$session_id" <<'PY'
import json, sys
node, run_id, revises_run_id, session_id = sys.argv[1:5]
print(json.dumps({
    "node": node,
    "runId": run_id,
    "revisesRunId": revises_run_id,
    "role": "planner",
    "sessionId": session_id,
}, separators=(",", ":")))
PY
)"

  singular_append_event "context.resume_failed" "plan-revision planner resume failed; re-running fresh" "$event_json"
  return 0
}
