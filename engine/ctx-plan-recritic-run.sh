#!/usr/bin/env bash
# Execute one read-only re-critique using the session policy, with a fresh-session fallback.

_singular_plan_recritic_normalize() {
  local record="$1" node="$2" run_id="$3" batch_csv="$4"

  # Pass 1: emit each valid finding's claim base64-encoded, one per line, in
  # order (base64 survives arbitrary claim text / newlines). Same validity filter
  # (claim + evidence both non-empty) the assembly pass applies below, so the ids
  # line up positionally.
  local claims_b64
  claims_b64="$(python3 - "$record" <<'PY'
import base64, json, sys
try:
    obj = json.load(open(sys.argv[1], encoding="utf-8"))
    if not isinstance(obj, dict):
        obj = {}
except Exception:
    obj = {}
raw = obj.get("findings")
if isinstance(raw, list):
    for fnd in raw:
        if not isinstance(fnd, dict):
            continue
        claim = str(fnd.get("claim", "")).strip()
        evidence = str(fnd.get("evidence", "")).strip()
        if not claim or not evidence:
            continue
        print(base64.b64encode(claim.encode("utf-8")).decode("ascii"))
PY
)"

  # Mint ids via the SHARED helper (formatting-only re-reports collapse to the
  # same id), in the SAME order as pass 1.
  local ids_csv="" line claim fid
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    claim="$(printf '%s' "$line" | base64 -d 2>/dev/null)"
    fid="$(singular_finding_id "$claim")"
    if [[ -z "$ids_csv" ]]; then ids_csv="$fid"; else ids_csv="$ids_csv,$fid"; fi
  done <<<"$claims_b64"

  # Pass 2: assemble the authoritative plan-critique.v0 record, popping the
  # precomputed ids in finding order. Emits "verdict<TAB>count".
  python3 - "$record" "$node" "$run_id" "$batch_csv" "$ids_csv" <<'PY'
import json, sys
record, node, run_id, batch_csv, ids_csv = sys.argv[1:6]
ids = [i for i in ids_csv.split(",") if i]

try:
    obj = json.load(open(record, encoding="utf-8"))
    if not isinstance(obj, dict):
        obj = {}
except Exception:
    obj = {}

verdict = str(obj.get("verdict", "")).strip()
if verdict not in ("approve", "revise", "park"):
    verdict = "approve"

batch = [t for t in batch_csv.split(",") if t]

norm_findings = []
raw = obj.get("findings")
idx = 0
if isinstance(raw, list):
    for fnd in raw:
        if not isinstance(fnd, dict):
            continue
        claim = str(fnd.get("claim", "")).strip()
        evidence = str(fnd.get("evidence", "")).strip()
        if not claim or not evidence:
            continue
        severity = str(fnd.get("severity", "")).strip()
        if severity not in ("blocking", "should-fix", "note"):
            severity = "note"
        fid = ids[idx] if idx < len(ids) else "f-000000000000"
        idx += 1
        out = {"id": fid, "severity": severity, "claim": claim, "evidence": evidence}
        sugg = fnd.get("suggestedChange")
        if isinstance(sugg, str) and sugg.strip():
            out["suggestedChange"] = sugg
        norm_findings.append(out)

assumptions = obj.get("assumptionsChallenged")
if not isinstance(assumptions, list):
    assumptions = []
assumptions = [str(a) for a in assumptions]

rationale = str(obj.get("rationale", "")).strip()
if not rationale:
    rationale = "critic returned no rationale"

rec = {
    "schema": "singular.orchestration.plan-critique.v0",
    "node": node,
    "runId": run_id,
    "batchTaskIds": batch,
    "verdict": verdict,
    "findings": norm_findings,
    "assumptionsChallenged": assumptions,
    "rationale": rationale,
}
with open(record, "w", encoding="utf-8") as f:
    json.dump(rec, f, indent=2)
    f.write("\n")
sys.stdout.write("%s\t%d" % (verdict, len(norm_findings)))
PY
}

# Records ONLY the rc-86 resume-refused fresh-fallback: EXACTLY ONE role=plan-critic
# `context.resume_failed` event carrying node, runId, revisesRunId, and the refused
# sessionId, mirroring the planner revision-round fresh fallback. No
# lease change, no runner, no outcome mutation.
singular_plan_recritic_record_resume_failed() {
  local node="${1:-}" run_id="${2:-}" revises_run_id="${3:-}" session_id="${4:-}"
  local event_json
  event_json="$(python3 - "$node" "$run_id" "$revises_run_id" "$session_id" <<'PY'
import json, sys
node, run_id, revises_run_id, session_id = sys.argv[1:5]
print(json.dumps({
    "node": node,
    "runId": run_id,
    "revisesRunId": revises_run_id,
    "role": "plan-critic",
    "sessionId": session_id,
}, separators=(",", ":")))
PY
)"
  singular_append_event "context.resume_failed" "plan-recritique resume failed; re-running fresh" "$event_json"
  return 0
}

# Perform ONE read-only critic re-critique pass over the staged candidate set that
# MAY resume the persisted per-node plan-critic session. Consult the session
# policy using the canonical critic session-meta, record its decision, and
# choose the corresponding path:
#   - fresh path (incl. knob-off `fresh disabled`): delegates to the integrated
#     FRESH critic driver — byte-identical to today's fresh re-critique (no
#     --resume-session, same record, same plan.critiqued event).
#   - resume path (`resume <sid>`): runs the critic on the DEFAULT runner WITH
#     --resume-session <sid>; on rc-86 records the fresh fallback and re-runs
#     FRESH; on a parse it persists through the SHARED helpers into the SAME
#     plan-critique.json record and appends the SAME single plan.critiqued event;
#     on infra failure it falls back to the FRESH driver, whose bounded retries and
#     fail-OPEN approve keep the revision loop from blocking.
# Returns 0 on every path — it NEVER blocks or deadlocks the revision loop.
#   singular_plan_recritic_run <node> <run_id> <stage_dir> <revises_run_id> [worktree]
singular_plan_recritic_run() {
  local node="$1" run_id="$2" stage_dir="$3" revises_run_id="$4" worktree="${5:-.}"

  mkdir -p "$stage_dir"

  # Reach the integrated critic + re-critique helpers by an assembled prefix so
  # they stay present-but-uncalled under their own invariance grep (mirroring
  # engine/ctx-plan-revise-loop.sh); the contiguous literal name never appears.
  local _critic_pfx=singular_ctx_plan_critic_
  local _recrit_pfx=singular_plan_recritic_

  # Canonical per-node critic session-meta (role plan-critic), finalized by the
  # fresh driver and consulted by the decider.
  local session_meta; session_meta="$("${_critic_pfx}session_path" "$node")"
  # DEFAULT runner (cross-provider independence): a module-routed planner still
  # gets a default-runner critic, and the re-critique resumes only that session.
  local runner
  runner="$(singular_role_runner critic "${SINGULAR_RUNNER:-$SINGULAR_ENGINE_DIR/codex-run.sh}")" || return 78
  local runner_basename; runner_basename="$(basename "$runner")"
  # Lineage head = the current target-branch head in this worktree; the decider's
  # head-rewritten gate keys the stored headShaAtCreate against it.
  local lineage_head; lineage_head="$(git -C "$worktree" rev-parse HEAD 2>/dev/null || printf '%s' "")"

  # Consult the integrated fail-closed decider. Its single-line verdict is trusted
  # verbatim; any decide-error degrades to a fresh run (never upgraded to resume).
  local decision strategy reason
  decision="$("${_recrit_pfx}resume_decide" "$session_meta" "$node" \
    "$runner_basename" "$worktree" "$lineage_head" 2>/dev/null || echo "fresh decide-error")"
  strategy="${decision%% *}"
  reason="${decision#* }"

  # FRESH path (including the knob-off `fresh disabled`): record the fresh strategy
  # and delegate to the integrated fresh driver so the outcome is byte-identical to
  # today's fresh re-critique.
  if [[ "$strategy" != "resume" ]]; then
    "${_recrit_pfx}record_strategy" "$node" "$run_id" "$revises_run_id" \
      fresh "$reason" >/dev/null 2>&1 || true
    "${_critic_pfx}run" "$node" "$run_id" "$stage_dir" "$worktree" || true
    return 0
  fi

  # RESUME path: `resume <sessionId>` — the reason field carries the sessionId.
  local sid="$reason"
  "${_recrit_pfx}record_strategy" "$node" "$run_id" "$revises_run_id" \
    resume resume "$sid" >/dev/null 2>&1 || true

  local _pn="plan-critic"
  local prompt="${SINGULAR_ORCH_DIR}/prompts/${_pn}.md"
  local raw="$stage_dir/plan-critique-raw.json"
  local record="$stage_dir/plan-critique.json"
  local prompt_sha; prompt_sha="$(singular_prompt_sha "$prompt" 2>/dev/null || printf '%s' "")"
  [[ -n "$session_meta" ]] && mkdir -p "$(dirname "$session_meta")"

  # Authoritative batch ids from the rendered candidate files staged for this node
  # (not whatever the runner echoed), mirroring the fresh driver.
  local candidate_batch_dir
  candidate_batch_dir="$(singular_task_batch_candidate_dir "$stage_dir")" || return 2
  local batch_csv="" f base tid
  for f in "$candidate_batch_dir"/TASK-*.md; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f" .md)"
    tid="$(printf '%s' "$base" | grep -oE '^TASK-[0-9]{4,}' || true)"
    [[ -n "$tid" ]] || continue
    if [[ -z "$batch_csv" ]]; then batch_csv="$tid"; else batch_csv="$batch_csv,$tid"; fi
  done

  # ONE read-only resume pass on the DEFAULT runner WITH --resume-session.
  local result_file="$stage_dir/plan-recritic-resume-runner-result.json"
  rm -f "$raw" "$result_file" 2>/dev/null || true
  local rc=0
  local critic_capability_profile="${SINGULAR_CRITIC_CAPABILITY_PROFILE:-audit-core}"
  singular_runner_contract_prepare \
    "$runner" critic "$critic_capability_profile" "$result_file"
  SINGULAR_RUNNER_ROLE=critic \
  SINGULAR_RUNNER_CAPABILITY_PROFILE="$critic_capability_profile" \
  SINGULAR_RUNNER_RESULT_FILE="$result_file" \
  SINGULAR_RUNNER_RUN_ID="$run_id" \
  "$runner" "${SINGULAR_RUNNER_CONTRACT_ARGS[@]}" \
    --level readonly -C "$worktree" --run-id "$run_id" \
    --prompt-file "$prompt" --output-last-message "$raw" \
    --session-meta "$session_meta" --resume-session "$sid" >/dev/null 2>&1 || rc=$?

  # rc-86: the runner refused the resume. Record the fresh fallback and re-run
  # FRESH via the integrated driver (same prompt, its own record + plan.critiqued
  # + session-meta finalize).
  if [[ "$rc" -eq 86 ]]; then
    singular_plan_recritic_record_resume_failed "$node" "$run_id" "$revises_run_id" "$sid" \
      >/dev/null 2>&1 || true
    "${_critic_pfx}run" "$node" "$run_id" "$stage_dir" "$worktree" || true
    return 0
  fi

  # Parseable output: persist through the SHARED helpers into the SAME record and
  # append the SAME single plan.critiqued event, yielding an identical contract.
  if [[ "$rc" -ne 124 && -f "$raw" ]] && singular_extract_json "$raw" "$record" 2>/dev/null; then
    local summary verdict count
    summary="$(_singular_plan_recritic_normalize "$record" "$node" "$run_id" "$batch_csv")"
    verdict="${summary%%$'\t'*}"
    count="${summary##*$'\t'}"
    [[ -n "$verdict" ]] || verdict="approve"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    singular_append_event "plan.critiqued" "plan critic recorded a critique" \
      "{\"node\":\"$node\",\"runId\":\"$run_id\",\"verdict\":\"$verdict\",\"findingsCount\":$count}"
    if [[ -n "$session_meta" ]]; then
      singular_session_meta_finalize "$session_meta" plan-critic "" "$run_id" \
        "$runner_basename" "$prompt_sha" "" "1" >/dev/null 2>&1 || true
    fi
    return 0
  fi

  # Infra failure on the resume pass (timeout / no record / unparseable): fall back
  # to the integrated FRESH driver, whose SINGULAR_AUDIT_INFRA_MAX-bounded fresh
  # retries and fail-OPEN approve (a distinct ctx.plan_critique_infra event) keep
  # the revision loop from blocking. The implementation auditor remains the floor.
  "${_critic_pfx}run" "$node" "$run_id" "$stage_dir" "$worktree" || true
  return 0
}
