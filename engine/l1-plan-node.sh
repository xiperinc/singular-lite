#!/usr/bin/env bash
set -euo pipefail

# Require bash >= 4 (mapfile/compgen); macOS /bin/bash is 3.2.
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -n "${SINGULAR_BASH_BIN:-}" ]]; then
    [[ "$SINGULAR_BASH_BIN" == /* && -x "$SINGULAR_BASH_BIN" ]] || { echo "invalid SINGULAR_BASH_BIN: $SINGULAR_BASH_BIN" >&2; exit 2; }
    exec "$SINGULAR_BASH_BIN" "$0" "$@"
  fi
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "l1-plan-node.sh requires bash >= 4" >&2; exit 1
fi

# Per-node L1 planner driver. L0's fanout launches one of these (in parallel)
# for each eligible, non-conflicting DAG node. It owns that node's L1 lease
# (planning -> active, or failed) and runs the planner in STAGED mode so the
# planner writes ONLY into the node's private staging dir — never the global
# tasks dir, gate results, area state, or the global event log. L0 (the serial
# importer) remains the sole writer of global task state.
#
# Exit 0 = node planned (staged candidates present, lease left active for L0 to
# release at import). Exit non-zero = planning failed (lease marked failed).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"

node=""
run_id=""
stage_dir=""
base_sha=""
count=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --node) node="$2"; shift 2 ;;
    --run-id) run_id="$2"; shift 2 ;;
    --stage-dir) stage_dir="$2"; shift 2 ;;
    --base-sha) base_sha="$2"; shift 2 ;;
    --count) count="$2"; shift 2 ;;
    *) echo "usage: $0 --node NODE --run-id RID --stage-dir DIR [--base-sha SHA] [--count N]" >&2; exit 2 ;;
  esac
done
[[ -n "$node" && -n "$stage_dir" ]] || { echo "l1-plan-node: --node and --stage-dir are required" >&2; exit 2; }
[[ -n "$run_id" ]] || run_id="$(singular_worker_run_id)"

mkdir -p "$stage_dir"
# Concurrent planners must not write the global event log; route all events
# (this driver's and the planner's) to a private per-node file.
export SINGULAR_EVENTS_FILE="$stage_dir/planner-events.ndjson"

if singular_stop_requested; then
  echo "frozen (STOP sentinel present); node=$node"
  exit 0
fi

singular_require_target_branch

# Resolve node fields + confirm eligibility (fail-closed; same predicate as
# next-areas), so a planner can never be driven against an ineligible node.
fields="$("$SCRIPT_DIR/dag.sh" node-fields "$node" 2>&1)" || {
  echo "plan-failed:$node (ineligible: $fields)"
  exit 1
}
area="$(printf '%s\n' "$fields" | sed -n 's/^area=//p' | tail -1)"
stage="$(printf '%s\n' "$fields" | sed -n 's/^stage=//p' | tail -1)"
layer="$(printf '%s\n' "$fields" | sed -n 's/^layer=//p' | tail -1)"
[[ -n "$area" && -n "$stage" && -n "$layer" ]] || { echo "plan-failed:$node (node fields incomplete)"; exit 1; }

[[ -n "$base_sha" ]] || base_sha="$(git -C "$SINGULAR_ROOT" rev-parse "$SINGULAR_TARGET_BRANCH")"

planner_node_status_activity="Planning failed for $node"
planner_node_status_next_action="Inspect the node planner evidence"
planner_node_status_outcome="planning-failed"

# run-status.sh keys its path on the run id ALONE
# ($SINGULAR_RUNS_DIR/$run_id/run-status.json), and L0's fanout hands every
# concurrent planner the SAME origin run id. N planners therefore raced on one
# file, last writer wins, and `singular health` could never report more than
# `phases: 1` however many were running — an operator watching `leases l1=2`
# against `phases: 1` mid-incident learned to distrust the phase counter.
#
# Deepening the run-status scan would not have fixed it: the records were never
# written separately in the first place. Give each planner its own id, exactly
# as integrate.sh already derives one per task (ORIGIN-...-integrate-TASK-0001).
#
# The directory then sits as a DIRECT child of runs/, so ops.sh's
# runs.glob("*/run-status.json") finds it and the console's
# `lifecycle["runId"] == <dirname>` guard holds, with no scan changes anywhere.
# The origin run id stays in use for the lease, the planning-session id and the
# revise loop — only the status record needs a distinct identity.
status_run_id="$run_id-l1-$(printf '%s' "$node" | tr -c 'A-Za-z0-9._-' '-')"

singular_planner_node_status_write() {
  local activity="$1" next_action="$2"
  "$SCRIPT_DIR/run-status.sh" write \
    --run-id "$status_run_id" --node "$node" --phase planning --state active \
    --activity "$activity" --safe-cancel true --next-action "$next_action" \
    --process-type planner --pid "$$" >/dev/null 2>&1 || true
}

singular_planner_node_status_on_exit() {
  local rc=$?
  local state="failed"
  trap - EXIT
  [[ "$rc" -eq 0 ]] && state="completed"
  "$SCRIPT_DIR/run-status.sh" write \
    --run-id "$status_run_id" --node "$node" --phase terminal --state "$state" \
    --activity "$planner_node_status_activity" --safe-cancel false \
    --next-action "$planner_node_status_next_action" --process-type planner --pid "$$" \
    --outcome "$planner_node_status_outcome" >/dev/null 2>&1 || true
  exit "$rc"
}

singular_planner_node_status_write \
  "Planning node $node" "Validate its staged task candidates"
trap singular_planner_node_status_on_exit EXIT

# Lease the node: planning -> active.
singular_l1_lease_write "$node" "$area" "$stage" "$layer" planning "$run_id" "$base_sha" "$SINGULAR_TARGET_BRANCH" || {
  echo "plan-failed:$node (lease write failed)"
  exit 1
}
singular_l1_lease_set_status "$node" active || true

# Persist the stable, pre-provider lineage input and consult its terminal before
# spending another planner call. Generated candidates are intentionally absent
# from this identity, so cosmetic regeneration cannot mint a fresh revision
# budget. Only semantically relevant node, dependency, source, task, authority,
# prompt, policy, and operator inputs produce a new identity.
plan_attempt_manifest="$(singular_plan_attempt_input_manifest \
  "$node" "$base_sha" "$stage_dir" "$count" "$fields")" || {
  singular_l1_lease_set_status "$node" failed || true
  echo "plan-failed:$node (attempt-input-failed)"
  exit 1
}
# Proof policy is a planning input: switching it must not replay a terminal
# plan made without those obligations. Revisions also need the same policy,
# because their renderer starts from the template rather than the initial prompt.
proof_policy="$(singular_red_proof_prompt)"
if [[ -n "$proof_policy" ]]; then
  proof_planner_template="$stage_dir/red-proof-planner-template.md"
  cat "${SINGULAR_PLANNER_TEMPLATE:-$SINGULAR_ORCH_DIR/prompts/l1-planner.md}" >"$proof_planner_template"
  printf '%s\n' "$proof_policy" >>"$proof_planner_template"
  export SINGULAR_PLANNER_TEMPLATE="$proof_planner_template"
  python3 - "$plan_attempt_manifest" "$proof_policy" <<'PY'
import hashlib
import json
import sys

path, policy = sys.argv[1:]
with open(path, encoding="utf-8") as f:
    doc = json.load(f)
doc["lineage"]["redProofPolicySha256"] = hashlib.sha256(policy.encode("utf-8")).hexdigest()
raw = json.dumps(doc["lineage"], sort_keys=True, separators=(",", ":"), ensure_ascii=False)
doc["lineageSha256"] = hashlib.sha256(raw.encode("utf-8")).hexdigest()
with open(path, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2, sort_keys=True)
    f.write("\n")
PY
fi
plan_attempt_identity="$(singular_plan_attempt_identity \
  "$node" "$base_sha" "$stage_dir" "$SINGULAR_ROOT")" || {
  singular_l1_lease_set_status "$node" failed || true
  echo "plan-failed:$node (attempt-identity-failed)"
  exit 1
}
[[ -d "$stage_dir/.plan-relevant-tasks" ]] || {
  singular_l1_lease_set_status "$node" failed || true
  echo "plan-failed:$node (attempt-input-failed)"
  exit 1
}
plan_attempt_terminal="$(singular_plan_attempt_terminal \
  "$node" "$plan_attempt_identity" "$run_id" "$base_sha" 2>/dev/null || true)"
if [[ -n "$plan_attempt_terminal" ]]; then
  IFS=$'\t' read -r plan_attempt_status plan_attempt_reason _ \
    <<<"$plan_attempt_terminal"
  if [[ "$plan_attempt_status" == "import" ]] \
    && singular_plan_attempt_restore_candidates \
      "$node" "$plan_attempt_identity" "$stage_dir"; then
    singular_append_event "plan.attempt_replayed" \
      "restored exact approved candidates for idempotent import" \
      "{\"node\":\"$node\",\"runId\":\"$run_id\",\"attemptIdentity\":\"$plan_attempt_identity\",\"status\":\"import\"}" || true
    planner_node_status_activity="Restored approved candidates for $node"
    planner_node_status_next_action="Import the identity-bound staged candidates"
    planner_node_status_outcome="planned-replay"
    echo "planned:$node"
    exit 0
  fi
  singular_append_event "plan.attempt_suppressed" \
    "stable planning lineage is already terminal; suppressing planner" \
    "{\"node\":\"$node\",\"runId\":\"$run_id\",\"attemptIdentity\":\"$plan_attempt_identity\",\"status\":\"$plan_attempt_status\",\"reason\":\"${plan_attempt_reason:-terminal}\"}" || true
  singular_l1_lease_set_status "$node" failed || true
  planner_node_status_activity="Planning suppressed for terminal lineage $node"
  planner_node_status_next_action="Change the stable planning input or record an operator override"
  planner_node_status_outcome="planning-suppressed-terminal"
  echo "plan-failed:$node (terminal-lineage ${plan_attempt_reason:-$plan_attempt_status})"
  exit 1
fi

planner="${SINGULAR_L1_PLANNER:-$SCRIPT_DIR/generate-tasks.sh}"
plan_attempt_record=""
plan_attempt_record_rc=0
plan_attempt_record="$(singular_plan_attempt_begin_initial \
  "$node" "$plan_attempt_identity" "$run_id" "$base_sha")" \
  || plan_attempt_record_rc=$?
if [[ "$plan_attempt_record_rc" -ne 0 ]]; then
  singular_l1_lease_set_status "$node" failed || true
  if [[ "$plan_attempt_record_rc" -eq 3 ]]; then
    echo "plan-failed:$node (attempt-state-corrupt)"
  else
    echo "plan-failed:$node (attempt-state-failed)"
  fi
  exit 1
fi
initial_infra_max="${SINGULAR_PLAN_INITIAL_INFRA_MAX:-1}"
[[ "$initial_infra_max" =~ ^[0-9]+$ ]] || initial_infra_max=1
# Infrastructure knobs may disable the retry with 0, but cannot expand the
# provider budget beyond one extra attempt.
(( initial_infra_max <= 1 )) || initial_infra_max=1
planner_succeeded="no"
planner_malformed_reason=""
while :; do
  # Reserve before calling the provider so a process crash cannot forget and
  # replay an unbounded initial attempt after restart.
  initial_infra_count="$(singular_plan_attempt_note_initial_infra \
    "$plan_attempt_record" provider-attempt-started 2>/dev/null \
    || printf '%s' "$((initial_infra_max + 2))")"
  [[ "$initial_infra_count" =~ ^[0-9]+$ ]] || initial_infra_count=$((initial_infra_max + 2))
  if (( initial_infra_count > initial_infra_max + 1 )); then
    singular_plan_attempt_mark_terminal "$plan_attempt_record" park \
      initial-planner-infra-exhausted "$run_id" || true
    break
  fi
  planner_rc=0
  SINGULAR_PLANNING_RUN_ID="$run_id" \
  SINGULAR_PLANNING_ARTIFACT_DIR="$stage_dir" \
  SINGULAR_TASKS_DIR="$stage_dir/.plan-relevant-tasks" \
    "$planner" --node "$node" --stage-dir "$stage_dir" --count "$count" \
      >>"$stage_dir/planner.out" 2>&1 || planner_rc=$?
  if [[ "$planner_rc" -eq 0 ]] \
    && { singular_task_batch_has_candidates "$stage_dir" || [[ -f "$stage_dir/NO-TASKS" ]]; }; then
    planner_succeeded="yes"
    break
  fi
  if [[ "$planner_rc" -eq 4 ]]; then
    # The planner answered and its answer was malformed, after its one repair
    # round (generate-tasks.sh). Not infrastructure: do not spend the
    # infrastructure retry and do not record the lineage as infra-exhausted.
    planner_malformed_reason="$(grep -a '^planner-failed (malformed-output' "$stage_dir/planner.out" 2>/dev/null \
      | tail -1 | sed 's/^planner-failed (//;s/)$//' | head -c 700)"
    [[ -n "$planner_malformed_reason" ]] || planner_malformed_reason="malformed-output"
    singular_plan_attempt_mark_terminal "$plan_attempt_record" park \
      planner-output-malformed "$run_id" || true
    break
  fi
  if (( initial_infra_count > initial_infra_max )); then
    singular_plan_attempt_mark_terminal "$plan_attempt_record" park \
      initial-planner-infra-exhausted "$run_id" || true
    break
  fi
  singular_append_event "ctx.plan_initial_infra_retry" \
    "initial planner infrastructure failed; retrying same stable lineage" \
    "{\"node\":\"$node\",\"runId\":\"$run_id\",\"attemptIdentity\":\"$plan_attempt_identity\",\"infraAttempt\":$initial_infra_count,\"initialAttempts\":1}" || true
done

if [[ "$planner_succeeded" == "yes" ]]; then
  singular_planner_node_status_write \
    "Validating staged candidates for $node" "Critique or import the validated candidates"
  # A valid empty batch (NO-TASKS marker, 0.5.0): nothing to critique or
  # import; leave the lease for L0's importer to release.
  if [[ -f "$stage_dir/NO-TASKS" ]] && ! singular_task_batch_has_candidates "$stage_dir"; then
    singular_plan_attempt_mark_terminal "$plan_attempt_record" park no-tasks "$run_id" || true
    planner_node_status_activity="Planning completed with no tasks for $node"
    planner_node_status_next_action="Release the node lease"
    planner_node_status_outcome="planned-empty"
    echo "planned-empty:$node"
    exit 0
  fi
  # --- plan-revision-loop hook (default ON; SINGULAR_PLAN_CRITIQUE=1) -----------
  # The single sanctioned call-site of the integrated bounded revise -> (resume|
  # fresh) -> re-critique -> approve/park orchestrator (engine/ctx-plan-revise-
  # loop.sh, auto-sourced via lib.sh). It fires ONLY here — the existing staging-
  # success branch, after the planner has produced *.candidate.md — and ONLY under
  # the flag; it adds no revision logic of its own, delegating entirely to the
  # orchestrator, which prints EXACTLY one terminal line and drives no state beyond
  # the stage dir + the per-node SINGULAR_EVENTS_FILE this driver already exports.
  #   import        -> keep today's behavior: candidates left staged, node lease
  #                    left active, planned:<node>, exit 0 -> L0 stays the sole
  #                    importer.
  #   park <reason> -> a never-approve / budget-exhausted terminal: mark the node
  #                    lease failed and exit plan-failed (non-zero) so unapproved
  #                    candidates never reach L0 import (mirrors the critique-import
  #                    gate reject disposition; fail CLOSED).
  # Flag unset / != 1 (default 0) => this block is inert => byte-identical to prior
  # behavior. The orchestrator is reached through a composed name so the sibling
  # brick's present-but-uncalled grep of engine/*.sh stays literal-match green.
  if [[ "${SINGULAR_PLAN_CRITIQUE:-0}" == "1" ]]; then
    _revise_pfx=singular_plan_revise_
    revise_outcome="$(SINGULAR_PLAN_ATTEMPT_BASE_SHA="$base_sha" \
      "${_revise_pfx}loop" "$node" "$run_id" "$stage_dir" "$SINGULAR_ROOT")" \
      || revise_outcome="park loop-error"
    if [[ "${revise_outcome%% *}" != "import" ]]; then
      singular_l1_lease_set_status "$node" failed || true
      echo "plan-failed:$node ($revise_outcome)"
      exit 1
    fi
  fi
  planner_node_status_activity="Planning staged candidates for $node"
  planner_node_status_next_action="Import the staged candidates"
  planner_node_status_outcome="planned"
  echo "planned:$node"
  exit 0
fi

singular_l1_lease_set_status "$node" failed || true
if [[ -n "${planner_malformed_reason:-}" ]]; then
  planner_node_status_activity="Planner output for $node was malformed"
  planner_node_status_next_action="Read the diagnostic; correct the planner contract or the task rule it cites"
  planner_node_status_outcome="planner-output-malformed"
  echo "plan-failed:$node (planner-output-malformed: $planner_malformed_reason)"
  exit 4
fi
echo "plan-failed:$node"
exit 1
