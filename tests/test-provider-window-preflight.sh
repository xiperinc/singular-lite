#!/usr/bin/env bash
set -euo pipefail

# Provider window at invocation boundaries (0.23.4, action-plan item 10).
#
# A validated provider limit on the CURRENT invocation's runner-result /
# provider-error pair outranks every packet or transport classification, and a
# still-closed window keyed to the provider a role would launch is checked
# before every actual launch. A deferral launches nothing further, charges no
# product repair and no infrastructure allowance, and ends non-accepting
# (exit 3) with the pending phase recorded. Exit 86 means "resume refused before
# any provider work" (free fresh fallback); 87 means "resume started and failed"
# (the fresh relaunch pays the worker-infrastructure allowance).
#
# Three layers:
#   A. codex-run.sh exit codes against a mock `codex` on PATH.
#   B. helper/extracted-function cases: role-keyed windows, stale sidecars,
#      role binding, resumed-invocation quota, 86 vs 87 in run_worker_phase.
#   C. full l1-drive runs with a stub runner: quota + missing packet, overload,
#      closed known window, expiry, auditor quota, decider quota, model prose.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-provider-window-preflight.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"
BASH_BIN="$BASH"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2' in: $1"; }
assert_file() { [[ -f "$1" ]] || fail "$2: missing file $1"; }
assert_no_file() { [[ ! -f "$1" ]] || fail "$2: unexpected file $1"; }
json_field() {
  python3 - "$1" "$2" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
for part in sys.argv[2].split("."):
    value = value.get(part) if isinstance(value, dict) else None
print("" if value is None else (json.dumps(value) if isinstance(value, (dict, list, bool)) else value))
PY
}

QUOTA_ENVELOPE='{"type":"turn.failed","error":{"status":429,"code":"rate_limit_exceeded","message":"request rejected"}}'
OVERLOAD_ENVELOPE='{"type":"turn.failed","error":{"status":503,"code":"service_unavailable","message":"provider unavailable"}}'

scratch="$(mktemp -d "${TMPDIR:-/tmp}/sg-pwp.XXXXXX")"
trap 'chmod -R u+w "$scratch" 2>/dev/null; rm -rf "$scratch"' EXIT

# ============================== A. codex-run.sh ================================
test_codex_run_exit_split() {
  local root="$scratch/codex" bindir repo meta out result ec
  bindir="$root/bin"; repo="$root/repo"
  mkdir -p "$bindir"
  cat >"$bindir/codex" <<'MOCK'
#!/usr/bin/env bash
[[ -n "${MOCK_CALLS:-}" ]] && printf 'x\n' >>"$MOCK_CALLS"
cat >/dev/null 2>&1 || true
printf '%s\n' '{"type":"thread.started","thread_id":"mock-thread"}'
[[ -n "${MOCK_ENVELOPE:-}" ]] && printf '%s\n' "$MOCK_ENVELOPE"
exit "${MOCK_EXIT:-0}"
MOCK
  chmod +x "$bindir/codex"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$repo" branch test-target
  run_codex() {
    ( cd "$repo" && PATH="$bindir:$PATH" SINGULAR_TARGET_BRANCH=test-target \
        SINGULAR_ROOT="$repo" SINGULAR_STATE_DIR="$repo/.singular-state" \
        SINGULAR_CODEX_COMPLETION_GRACE_SEC=0 \
        "$SCRIPT_DIR/codex-run.sh" "$@" )
  }

  # A1: affinity refusal -> 86, provider never invoked.
  meta="$root/meta-mismatch.json"
  printf '{"model":"some-other-model","effort":"low"}\n' >"$meta"
  out="$root/a1.json"; result="$root/a1-result.json"; ec=0
  MOCK_CALLS="$root/a1.calls" run_codex --level l2 -C "$repo" --run-id RUN-A1 \
    --role implementer --result-file "$result" --output-last-message "$out" \
    --session-meta "$meta" --resume-session sid-1 >/dev/null 2>&1 || ec=$?
  assert_eq "$ec" "86" "A1 affinity refusal exit code"
  assert_no_file "$root/a1.calls" "A1 provider must not be launched on refusal"

  # A2: a resume that started and failed with no output -> 87, not 86.
  out="$root/a2.json"; result="$root/a2-result.json"; ec=0
  MOCK_EXIT=1 MOCK_CALLS="$root/a2.calls" run_codex --level l2 -C "$repo" --run-id RUN-A2 \
    --role implementer --result-file "$result" --output-last-message "$out" \
    --resume-session sid-2 >/dev/null 2>&1 || ec=$?
  assert_eq "$ec" "87" "A2 started resume failure exit code"
  assert_file "$root/a2.calls" "A2 provider was launched"
  assert_eq "$(json_field "$result" exitCode)" "87" "A2 runner result exit code"
  assert_eq "$(json_field "$result" failureClass)" "provider-exit" "A2 failure class"

  # A3: a resumed invocation that hit quota still exits 87, and its runner
  # result carries validated quota evidence (which outranks the exit code).
  out="$root/a3.json"; result="$root/a3-result.json"; ec=0
  MOCK_EXIT=1 MOCK_ENVELOPE="$QUOTA_ENVELOPE" run_codex --level l2 -C "$repo" \
    --run-id RUN-A3 --role implementer --result-file "$result" \
    --output-last-message "$out" --resume-session sid-3 >/dev/null 2>&1 || ec=$?
  assert_eq "$ec" "87" "A3 resumed quota exit code"
  assert_eq "$(json_field "$result" failureClass)" "quota" "A3 runner result class"
  ( export SINGULAR_ROOT="$repo" SINGULAR_STATE_DIR="$repo/.singular-state"
    source "$SCRIPT_DIR/lib.sh"
    [[ "$(singular_runner_provider_window_class "$result" implementer)" == "quota" ]] ) \
    || fail "A3 resumed quota result is not validated provider-window evidence"
  pass "codex-run: 86 = refused before provider work, 87 = started resume failed, quota evidence kept"
}

# ===================== B. helpers and extracted worker phase ===================
# A sourced lib.sh against an isolated state tree, plus the driver's provider
# window helpers and run_worker_phase extracted verbatim from l1-drive.sh.
setup_unit_env() {
  local base="$1"
  mkdir -p "$base/root" "$base/state/runs"
  git -C "$base/root" init -q
  git -C "$base/root" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  export SINGULAR_ROOT="$base/root"
  export SINGULAR_ENGINE_HOME="$ENGINE_HOME"
  export SINGULAR_ENGINE_DIR="$SCRIPT_DIR"
  export SINGULAR_STATE_DIR="$base/state"
  export SINGULAR_RUNS_DIR="$base/state/runs"
  export SINGULAR_EVENTS_FILE="$base/state/events.ndjson"
  export SINGULAR_LEASES_DIR="$base/state/leases"
  export SINGULAR_PLANNER_BACKOFF_FILE="$base/state/planner-backoff.json"
  export SINGULAR_PROVIDER_PRESSURE_FILE="$base/state/provider-pressure.json"
  unset SINGULAR_JSON_CONFIG_FILE SINGULAR_CONFIG_FILE SINGULAR_LOCAL_CONFIG_FILE SINGULAR_RUNNER SINGULAR_ROLE_RUNNER_AUDITOR SINGULAR_ROLE_RUNNER_DECIDER \
    SINGULAR_ROLE_RUNNER_IMPLEMENTER 2>/dev/null || true
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib.sh"
  eval "$(awk '/^l1_provider_deferral_json=""$/{copy=1} copy && /^# Worker invocation through/{exit} copy{print}' \
    "$SCRIPT_DIR/l1-drive.sh")"
  declare -F l1_provider_window_preflight >/dev/null || fail "provider window helpers not extracted"
}

# args: provider envelope result_file role
write_window_result() {
  local provider="$1" envelope="$2" result="$3" role="$4" env_file
  env_file="$(mktemp "${TMPDIR:-/tmp}/sg-pwp-env.XXXXXX")"
  printf '%s\n' "$envelope" >"$env_file"
  mkdir -p "$(dirname "$result")"
  singular_runner_result_write "$provider" "RUN-UNIT" "$role" default "$result" 1 \
    "$env_file" "" "" >/dev/null 2>&1
  rm -f "$env_file"
}

test_role_keyed_window() {
  (
  setup_unit_env "$scratch/role"
  local evidence="$scratch/role/evidence/codex-runner-result.json"
  task_id=TASK-UNIT run_id=RUN-UNIT
  write_window_result codex "$QUOTA_ENVELOPE" "$evidence" implementer
  singular_planner_backoff_set quota RUN-UNIT TASK-UNIT "$evidence" >/dev/null 2>&1 \
    || fail "role: valid codex quota evidence did not arm the shared window"

  l1_provider_window_preflight implementer "$SCRIPT_DIR/codex-run.sh" implement 1 >/dev/null \
    || fail "role: codex worker must be deferred while the codex window is closed"
  assert_contains "$l1_provider_deferral_json" '"invocationStarted":false' "role: preflight deferral"
  assert_contains "$l1_provider_deferral_json" '"provider":"codex"' "role: deferral names the provider"
  if l1_provider_window_preflight auditor "$SCRIPT_DIR/claude-run.sh" audit 1 >/dev/null; then
    fail "role: a claude auditor must not be deferred by a codex window"
  fi
  # Routed through roleRunners exactly as the driver resolves it.
  local auditor_runner decider_runner
  auditor_runner="$(SINGULAR_ROLE_RUNNER_AUDITOR=claude-run.sh singular_role_runner auditor "$SCRIPT_DIR/codex-run.sh")"
  if l1_provider_window_preflight auditor "$auditor_runner" audit 1 >/dev/null; then
    fail "role: roleRunners.auditor=claude must launch through a codex window"
  fi
  decider_runner="$(singular_role_runner decider "$SCRIPT_DIR/codex-run.sh")"
  l1_provider_window_preflight decider "$decider_runner" decide 1 >/dev/null \
    || fail "role: a codex decider must be deferred by the codex window"
  # A custom runner has no trusted identity: the window stays conservative.
  l1_provider_window_preflight implementer "$scratch/role/custom-runner.sh" implement 1 >/dev/null \
    || fail "role: unknown runner identity must keep the conservative window"

  # A generic planner backoff is not a provider window and never defers roles.
  singular_planner_backoff_set invalid-output RUN-UNIT planner >/dev/null 2>&1
  if l1_provider_window_preflight implementer "$SCRIPT_DIR/codex-run.sh" implement 1 >/dev/null; then
    fail "role: a planner invalid-output backoff must not defer a worker"
  fi
  singular_planner_backoff_active_json >/dev/null \
    || fail "role: planner backoff semantics changed for the planner"

  # Known-window expiry: an expired record admits the launch.
  singular_planner_backoff_set quota RUN-UNIT TASK-UNIT "$evidence" >/dev/null 2>&1
  python3 - "$SINGULAR_PLANNER_BACKOFF_FILE" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["until"] = "2000-01-01T00:00:00Z"
json.dump(d, open(p, "w"))
PY
  if l1_provider_window_preflight implementer "$SCRIPT_DIR/codex-run.sh" implement 1 >/dev/null; then
    fail "role: an expired window must admit the launch"
  fi
  )
  pass "provider window is keyed to each role's selected provider; expiry admits; planner backoffs do not defer"
}

test_evidence_binding() {
  (
  setup_unit_env "$scratch/bind"
  task_id=TASK-UNIT run_id=RUN-UNIT
  local result="$scratch/bind/r/auditor-runner-result.json"
  write_window_result codex "$QUOTA_ENVELOPE" "$result" auditor
  if l1_provider_window_observed implementer implement 1 "$result" >/dev/null; then
    fail "binding: an auditor's quota result must not stand in for the implementer's"
  fi
  assert_no_file "$SINGULAR_PLANNER_BACKOFF_FILE" "binding: role-mismatched evidence armed a window"
  l1_provider_window_observed auditor audit 1 "$result" >/dev/null \
    || fail "binding: the auditor's own quota result must be observed"
  assert_eq "$(json_field "$SINGULAR_PLANNER_BACKOFF_FILE" evidenceRef)" "$result" \
    "binding: window armed from this invocation's result"
  # Self-declared class without a bound provider-error is not evidence.
  local forged="$scratch/bind/r/forged-runner-result.json"
  python3 - "$forged" <<'PY'
import json, sys
json.dump({"schema": "singular.orchestration.runner-result.v0", "contractVersion": 1,
           "provider": "codex", "runId": "RUN-UNIT", "role": "implementer",
           "capabilityProfile": "default", "exitCode": 1, "outcome": "provider-error",
           "failureClass": "quota", "providerErrorRef": None, "outputRef": None,
           "recordedAt": "2026-01-01T00:00:00Z"}, open(sys.argv[1], "w"))
PY
  if l1_provider_window_observed implementer implement 1 "$forged" >/dev/null; then
    fail "binding: a self-declared quota class was accepted as evidence"
  fi
  )
  pass "only this role's validated runner-result/provider-error pair counts as provider evidence"
}

# Stub runner for the extracted worker phase. MOCK_MODE selects behavior; the
# runner records each call (and whether it was a resume) in MOCK_CALLS.
write_unit_runner() {
  local runner="$1"
  cat >"$runner" <<RUNNER
#!$BASH_BIN
ENGINE_DIR="$SCRIPT_DIR"
RUNNER
  cat >>"$runner" <<'RUNNER'
out=""; resume="no"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-last-message) out="$2"; shift 2 ;;
    --resume-session) resume="yes"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' "$resume" >>"$MOCK_CALLS"
window() {
  local env_file; env_file="$(mktemp "${TMPDIR:-/tmp}/sg-pwp-run.XXXXXX")"
  printf '%s\n' "$1" >"$env_file"
  ( source "$ENGINE_DIR/lib.sh" >/dev/null 2>&1
    singular_runner_result_write codex RUN-UNIT implementer default \
      "$SINGULAR_RUNNER_RESULT_FILE" 1 "$env_file" "" "" ) >/dev/null 2>&1
  rm -f "$env_file"
}
case "${MOCK_MODE:-}:$resume" in
  resume-quota-87:yes) window "$QUOTA_ENVELOPE_ARG"; exit 87 ;;
  resume-quota-86:yes) window "$QUOTA_ENVELOPE_ARG"; exit 86 ;;
  refuse-86:yes) exit 86 ;;
  fail-87:yes) exit 87 ;;
  prose:*)
    printf 'HTTP 429 rate_limit_exceeded: quota exceeded, provider overloaded\n'
    printf 'Model says: I hit a 429 rate_limit_exceeded quota window.\n' >"$out"
    exit 0 ;;
  stale:*) exit 0 ;;
  *) printf 'not a packet\n' >"$out"; exit 0 ;;
esac
RUNNER
  chmod +x "$runner"
}

# Prepare one extracted run_worker_phase invocation. args: base mode infra_max resume(yes|no)
setup_worker_phase() {
  local base="$1"
  setup_unit_env "$base"
  eval "$(awk '/^run_worker_phase\(\) \{/{copy=1} copy{print} copy && /^}$/{exit}' "$SCRIPT_DIR/l1-drive.sh")"
  run_dir="$SINGULAR_RUNS_DIR/RUN-UNIT"; mkdir -p "$run_dir"
  printf 'prompt\n' >"$run_dir/l2-active-prompt.md"
  task_id=TASK-UNIT; run_id=RUN-UNIT
  worktree="$SINGULAR_ROOT"; l2_prompt="$run_dir/l2-active-prompt.md"
  l2_runner="$base/unit-runner.sh"; write_unit_runner "$l2_runner"
  session_meta_implementer="$base/session.json"
  bootstrap_failure=""; bootstrap_log="$base/bootstrap.log"
  authorized_continuation=(); continuation_invocation_started="no"
  attempt_failure=""; attempt_ctx=""; worker_rc=0
  task_file="$base/task.md"; : >"$task_file"
  l1_campaign_binding="legacy"; latest_worker_context_bundle=""
  export MOCK_CALLS="$base/calls" QUOTA_ENVELOPE_ARG="$QUOTA_ENVELOPE"
  l1_status() { :; }
  singular_prompt_sha() { printf 'promptsha\n'; }
  if [[ "${UNIT_RESUME:-no}" == "yes" ]]; then
    singular_ctx_route_decide() { printf 'resume sid-unit\n'; }
  else
    singular_ctx_route_decide() { printf 'fresh test\n'; }
  fi
  rehydrate_inject_packet() { :; }
  singular_runner_contract_prepare() { SINGULAR_RUNNER_CONTRACT_ARGS=(); }
  singular_context_worktree_path() { printf '%s\n' "$1"; }
  singular_context_invocation_settings() { printf '0\t\n'; }
  singular_context_receipt_status() { :; }
  singular_context_invocation_run() {
    while [[ $# -gt 0 && "$1" != "--" ]]; do shift; done
    shift
    "$@"
  }
  singular_l1_prepare_worker_packet() { [[ -s "$1" ]] && return 11 || return 10; }
}

worker_calls() { [[ -f "$MOCK_CALLS" ]] && tr '\n' ' ' <"$MOCK_CALLS" | sed 's/ $//' || true; }
events_text() { cat "$SINGULAR_EVENTS_FILE" 2>/dev/null || true; }

test_worker_phase_resumed_quota() {
  local mode
  for mode in resume-quota-87 resume-quota-86; do
    (
    UNIT_RESUME=yes setup_worker_phase "$scratch/rq-$mode"
    export MOCK_MODE="$mode" SINGULAR_WORKER_INFRA_MAX=1
    local rc=0
    run_worker_phase 1 >"$scratch/rq-$mode.out" 2>&1 || rc=$?
    assert_eq "$rc" "1" "$mode: phase ends"
    assert_eq "$attempt_failure" "provider-deferred" "$mode: provider evidence outranks the resume exit code"
    assert_eq "$(worker_calls)" "yes" "$mode: no fresh fallback or infra retry launched into the window"
    assert_contains "$(events_text)" '"l1.provider_deferred"' "$mode: deferral event"
    assert_not_contains "$(events_text)" '"worker.infra_retry"' "$mode: no infra allowance consumed"
    assert_eq "$(json_field "$SINGULAR_PLANNER_BACKOFF_FILE" failureClass)" "quota" "$mode: window armed"
    )
  done
  pass "a resumed invocation's quota defers the phase; neither 86 nor 87 relaunches into the window"
}

test_worker_phase_exit_86_is_free() {
  (
  UNIT_RESUME=yes setup_worker_phase "$scratch/r86"
  export MOCK_MODE=refuse-86 SINGULAR_WORKER_INFRA_MAX=1
  local rc=0
  run_worker_phase 1 >"$scratch/r86.out" 2>&1 || rc=$?
  assert_eq "$attempt_failure" "worker-no-packet" "86: fallback output reaches packet validation"
  assert_eq "$(worker_calls)" "yes no" "86: one refused resume then one fresh fallback"
  assert_file "$run_dir/worker-attempt-1-try-0-resume-fallback.log" "86: fallback stays in try 0"
  assert_no_file "$run_dir/worker-attempt-1-try-1.log" "86: no infra try consumed"
  assert_not_contains "$(events_text)" '"worker.infra_retry"' "86: no infra retry event"
  assert_contains "$(events_text)" '"resumeOutcome":"refused"' "86: refusal recorded as free"
  )
  pass "exit 86 (refused before provider work) keeps the free same-try fresh fallback"
}

test_worker_phase_exit_87_consumes_infra() {
  (
  UNIT_RESUME=yes setup_worker_phase "$scratch/r87"
  export MOCK_MODE=fail-87 SINGULAR_WORKER_INFRA_MAX=1
  local rc=0
  run_worker_phase 1 >"$scratch/r87.out" 2>&1 || rc=$?
  assert_eq "$attempt_failure" "worker-no-packet" "87: fresh relaunch output reaches packet validation"
  assert_eq "$(worker_calls)" "yes no" "87: resume then a fresh infra retry"
  assert_no_file "$run_dir/worker-attempt-1-try-0-resume-fallback.log" "87: no free same-try fallback"
  assert_file "$run_dir/worker-attempt-1-try-1.log" "87: relaunch is infra try 1"
  assert_contains "$(events_text)" '"worker.infra_retry"' "87: infra retry event"
  assert_contains "$(events_text)" '"reason":"resume-failed"' "87: infra retry names the resume failure"
  assert_contains "$(events_text)" '"resumeOutcome":"started-and-failed"' "87: started failure recorded"
  )
  (
  UNIT_RESUME=yes setup_worker_phase "$scratch/r87-exhausted"
  export MOCK_MODE=fail-87 SINGULAR_WORKER_INFRA_MAX=0
  local rc=0
  run_worker_phase 1 >"$scratch/r87-exhausted.out" 2>&1 || rc=$?
  assert_eq "$attempt_failure" "worker-infra" "87 with no allowance left: worker-infra"
  assert_eq "$(worker_calls)" "yes" "87 with no allowance left: no relaunch"
  assert_contains "$(events_text)" '"worker.infra_exhausted"' "87: allowance exhausted event"
  )
  pass "exit 87 (started resume failed) pays the worker-infrastructure allowance"
}

test_worker_phase_stale_sidecar_and_prose() {
  (
  setup_worker_phase "$scratch/stale"
  export MOCK_MODE=stale SINGULAR_WORKER_INFRA_MAX=1
  # A quota sidecar left at this exact path by an earlier invocation.
  write_window_result codex "$QUOTA_ENVELOPE" \
    "$run_dir/implementer-attempt-1-try-0-runner-result.json" implementer
  local rc=0
  run_worker_phase 1 >"$scratch/stale.out" 2>&1 || rc=$?
  assert_eq "$attempt_failure" "worker-no-packet" "stale: earlier invocation's sidecar is ignored"
  assert_no_file "$SINGULAR_PLANNER_BACKOFF_FILE" "stale: no window armed from a stale sidecar"
  assert_not_contains "$(events_text)" '"l1.provider_deferred"' "stale: no deferral"
  )
  (
  setup_worker_phase "$scratch/prose"
  export MOCK_MODE=prose SINGULAR_WORKER_INFRA_MAX=1
  # An earlier try's quota text also sits in the cumulative worker log.
  printf 'HTTP 429 rate_limit_exceeded quota\n' >"$run_dir/worker-codex.log"
  local rc=0
  run_worker_phase 1 >"$scratch/prose.out" 2>&1 || rc=$?
  assert_eq "$attempt_failure" "worker-no-packet" "prose: model-written quota text is packet output, not a window"
  assert_no_file "$SINGULAR_PLANNER_BACKOFF_FILE" "prose: no window armed from model prose"
  assert_not_contains "$(events_text)" '"l1.provider_deferred"' "prose: no deferral"
  )
  pass "stale sidecars, model-written quota prose and cumulative logs never become provider evidence"
}

# ============================== C. full driver ==================================
make_repo() {
  local root="$1"
  mkdir -p "$root/docs/orchestration/prompts" "$root/docs/orchestration/tasks" "$root/.singular-state"
  git -C "$root" init -q
  git -C "$root" checkout -q -b target
  cp "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md" "$root/docs/orchestration/prompts/l2-test-first-developer.md"
  cp "$ENGINE_HOME/templates/prompts/auditor.md" "$root/docs/orchestration/prompts/auditor.md"
  cp "$ENGINE_HOME/templates/prompts/decider.md" "$root/docs/orchestration/prompts/decider.md"
  printf '.singular-state/\n.worktrees/\n.singular-evidence/\n' >"$root/.gitignore"
  git -C "$root" add .
  git -C "$root" -c user.name=test -c user.email=test@example.local commit -q -m init
}

with_fixture() {
  FIXTURE_TMP="$1"
  mkdir -p "$FIXTURE_TMP"
  make_repo "$FIXTURE_TMP/repo"
  export SINGULAR_ROOT="$FIXTURE_TMP/repo"
  export SINGULAR_ORCH_DIR="$SINGULAR_ROOT/docs/orchestration"
  export SINGULAR_TASKS_DIR="$SINGULAR_ORCH_DIR/tasks"
  export SINGULAR_STATE_DIR="$SINGULAR_ROOT/.singular-state"
  export SINGULAR_RUNS_DIR="$SINGULAR_STATE_DIR/runs"
  export SINGULAR_INBOX_DIR="$SINGULAR_STATE_DIR/inbox"
  export SINGULAR_LEASES_DIR="$SINGULAR_STATE_DIR/leases"
  export SINGULAR_EVENTS_FILE="$SINGULAR_STATE_DIR/events.ndjson"
  export SINGULAR_STOP_FILE="$SINGULAR_STATE_DIR/STOP"
  export SINGULAR_WORKTREES_DIR="$SINGULAR_ROOT/.worktrees"
  export SINGULAR_PLANNER_BACKOFF_FILE="$SINGULAR_STATE_DIR/planner-backoff.json"
  export SINGULAR_TARGET_BRANCH="target"
  export SINGULAR_ENGINE_HOME="$ENGINE_HOME"
  export SINGULAR_REVIEW_MAX_ROUNDS=3
  unset SINGULAR_MODULES SINGULAR_WORKER_RED_LOG SINGULAR_WORKER_CONTRACT_EXTRA \
    SINGULAR_PREFLIGHT_REQUIRE_ACCEPTANCE SINGULAR_ATTEMPT_TASK_ID SINGULAR_ATTEMPT_STARTED_AT \
    SINGULAR_DECIDER_FAST SINGULAR_WORKER_INFRA_MAX SINGULAR_AUDIT_INFRA_MAX \
    SINGULAR_AUDIT_VERIFY_INFRA_MAX SINGULAR_EVIDENCE_INFRA_MAX \
    SINGULAR_TASK_RISK_TIER SINGULAR_DEFAULT_RISK_TIER SINGULAR_JSON_CONFIG_FILE \
    SINGULAR_CONFIG_FILE SINGULAR_LOCAL_CONFIG_FILE SINGULAR_BASE_REF SINGULAR_DISPATCH_BASE_SHA \
    SINGULAR_DISPATCH_BATCH_ID SINGULAR_PAIRED_AUDIT_PCT SINGULAR_ROLE_RUNNER_AUDITOR \
    SINGULAR_ROLE_RUNNER_DECIDER SINGULAR_ROLE_RUNNER_IMPLEMENTER SINGULAR_RUNS_DIR_UNUSED \
    MOCK_WORKER_WINDOW MOCK_AUDIT_WINDOW MOCK_DECIDER_WINDOW 2>/dev/null || true
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib.sh"
  cat >"$SINGULAR_TASKS_DIR/TASK-0001.md" <<'EOF'
# TASK-0001: Generic widget parser

Status: ready
Area: widget
Target branch: `target`
Worker branch: `agent/widget/TASK-0001-generic`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Implement the widget parser.

## Scope

Owned files:

- `internal/widget/parser.go`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- Parser handles empty input.
EOF
  local stub="$FIXTURE_TMP/mock-runner.sh"
  make_driver_runner "$stub"
  export SINGULAR_RUNNER="$stub"
  export MOCK_COUNTER_DIR="$FIXTURE_TMP/counters"
  export MOCK_ENGINE_DIR="$SCRIPT_DIR"
  export MOCK_QUOTA_ENVELOPE="$QUOTA_ENVELOPE" MOCK_OVERLOAD_ENVELOPE="$OVERLOAD_ENVELOPE"
}

# Worker/auditor/decider stub (same drop-in contract as test-decider-fastpath).
# MOCK_<ROLE>_WINDOW=quota|overload writes validated codex provider evidence for
# that invocation and exits 1 without any model output.
make_driver_runner() {
  local stub="$1"
  cat >"$stub" <<STUB
#!$BASH_BIN
STUB
  cat >>"$stub" <<'STUB'
if [[ "${1:-}" == "--describe-contract" ]]; then
  printf '%s\n' '{"schema":"singular.runner-contract.v1","version":1,"provider":"codex","arguments":["--worktree","--prompt-file","--level","--run-id","--output-last-message","--role","--capability-profile","--result-file","--describe-contract"],"structuredResult":"singular.orchestration.runner-result.v0","structuredProviderError":"singular.orchestration.provider-error.v0"}'
  exit 0
fi
level=""; out=""; chdir=""; prompt=""; run_id=""; result_file=""
role="${SINGULAR_RUNNER_ROLE:-}"; capability="${SINGULAR_RUNNER_CAPABILITY_PROFILE:-fixture}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --level) level="$2"; shift 2 ;;
    -C|--worktree) chdir="$2"; shift 2 ;;
    --output-last-message) out="$2"; shift 2 ;;
    --prompt-file) prompt="$2"; shift 2 ;;
    --run-id) run_id="$2"; shift 2 ;;
    --role) role="$2"; shift 2 ;;
    --capability-profile) capability="$2"; shift 2 ;;
    --result-file) result_file="$2"; shift 2 ;;
    *) shift ;;
  esac
done
write_result() {
  local rc=$?
  [[ "$rc" -eq 0 && -n "$result_file" ]] || return "$rc"
  python3 - "$result_file" "$run_id" "$role" "$capability" "$out" <<'PY'
import datetime, json, sys
path, run_id, role, capability, output = sys.argv[1:]
json.dump({
    "schema":"singular.orchestration.runner-result.v0", "contractVersion":1,
    "provider":"codex", "runId":run_id, "role":role,
    "capabilityProfile":capability, "exitCode":0, "outcome":"succeeded",
    "failureClass":"none", "providerErrorRef":None, "outputRef":output,
    "recordedAt":datetime.datetime.now(datetime.timezone.utc).replace(
        microsecond=0).isoformat().replace("+00:00", "Z"),
}, open(path, "w", encoding="utf-8"))
PY
}
trap write_result EXIT
window() {
  local envelope env_file
  case "$1" in
    quota) envelope="$MOCK_QUOTA_ENVELOPE" ;;
    overload) envelope="$MOCK_OVERLOAD_ENVELOPE" ;;
    *) return 0 ;;
  esac
  env_file="$(mktemp "${TMPDIR:-/tmp}/sg-pwp-drv.XXXXXX")"
  printf '%s\n' "$envelope" >"$env_file"
  ( source "$MOCK_ENGINE_DIR/lib.sh" >/dev/null 2>&1
    singular_runner_result_write codex "$run_id" "$role" "$capability" "$result_file" 1 \
      "$env_file" "" "" ) >/dev/null 2>&1
  rm -f "$env_file"
  trap - EXIT
  exit 1
}
bump() {
  local file="$MOCK_COUNTER_DIR/$1-calls" n=0
  mkdir -p "$MOCK_COUNTER_DIR"
  [[ -f "$file" ]] && n="$(cat "$file")"
  n=$((n + 1)); printf '%s' "$n" >"$file"; printf '%s' "$n"
}
if [[ "$prompt" == *decider-prompt-* ]]; then
  bump decider >/dev/null
  window "${MOCK_DECIDER_WINDOW:-}"
  fc="${prompt##*decider-prompt-}"; fc="${fc%.md}"
  python3 - "$out" "$fc" <<'PY'
import json, sys
json.dump({"schema":"singular.orchestration.decider-verdict.v0","failureClass":sys.argv[2],"taskId":"TASK-0001","action":"retry","rationale":"mock decider","nextOwner":"l1"}, open(sys.argv[1],"w"))
PY
  exit 0
fi
if [[ "$level" == "l2" ]]; then
  n="$(bump worker)"
  window "${MOCK_WORKER_WINDOW:-}"
  mkdir -p "$chdir/internal/widget" "$chdir/.singular-evidence"
  printf 'package widget\n// v%s\n' "$n" >"$chdir/internal/widget/parser.go"
  printf 'red\n' >"$chdir/.singular-evidence/red.log"; printf 'green\n' >"$chdir/.singular-evidence/green.log"; printf 'reg\n' >"$chdir/.singular-evidence/regression.log"
  python3 - "$out" <<'PY'
import json, sys
json.dump({"schema":"singular.orchestration.state-packet.v0","packetId":"p","runId":"r","taskId":"TASK-0001","area":"widget","role":"l2-developer","status":"needs-review","baseRef":"target","branch":"agent/widget/TASK-0001-generic","headSha":"uncommitted","workspace":"/tmp","ownedFiles":["internal/widget/parser.go"],"changedFiles":["internal/widget/parser.go"],"commands":[{"cmd":"true","exitCode":0,"logRef":""}],"tests":[{"name":"t","phase":"red","status":"fail","logRef":""},{"name":"t","phase":"green","status":"pass","logRef":""}],"evidence":[{"kind":"red","ref":".singular-evidence/red.log"}],"blockers":[],"nextAction":"audit","createdAt":"2026-01-01T00:00:00Z"}, open(sys.argv[1],"w"))
PY
  exit 0
fi
n="$(bump audit)"
window "${MOCK_AUDIT_WINDOW:-}"
seq=(${MOCK_AUDIT_VERDICT_SEQ:-accepted})
vi=$((n - 1)); verdict="${seq[$vi]:-${seq[${#seq[@]}-1]}}"
python3 - "$out" "$verdict" "$run_id" <<'PY'
import json, sys
json.dump({"schema":"singular.orchestration.audit-verdict.v0","taskId":"TASK-0001","runId":sys.argv[3],"branch":"agent/widget/TASK-0001-generic","verdict":sys.argv[2],"evidenceReviewed":[],"commandsRun":[],"findings":[],"requiredFixes":[],"rationale":"ok"}, open(sys.argv[1],"w"))
PY
exit 0
STUB
  chmod +x "$stub"
}

calls() { cat "$MOCK_COUNTER_DIR/$1-calls" 2>/dev/null || printf '0'; }
attempt_index() { find "$SINGULAR_RUNS_DIR" -name index.json -path '*/attempts/*' | head -1; }

# Common assertions for a provider-deferred drive. args: label out rc phase
assert_deferred_drive() {
  local label="$1" out="$2" rc="$3" phase="$4" events lease
  assert_eq "$rc" "3" "$label: non-accepting exit ($out)"
  assert_contains "$out" "PROVIDER DEFERRED" "$label: deferral outcome"
  events="$(cat "$SINGULAR_EVENTS_FILE")"
  assert_contains "$events" '"l1.task_provider_deferred"' "$label: terminal deferral event"
  assert_not_contains "$events" '"worker-no-packet"' "$label: never worker-no-packet"
  assert_not_contains "$events" '"l1.product_repair_budget_consumed"' "$label: no product charge"
  assert_eq "$(singular_lease_field TASK-0001 retryCount)" "0" "$label: product retry count unchanged"
  lease="$(singular_lease_path TASK-0001)"
  assert_eq "$(json_field "$lease" providerDeferral.phase)" "$phase" "$label: pending phase recorded"
  assert_eq "$(json_field "$lease" providerDeferral.consumesProductRepairBudget)" "false" \
    "$label: deferral record carries no product charge"
  assert_contains "$(cat "$(attempt_index)")" '"deciderAction": "provider-deferred"' \
    "$label: attempt archived as provider-deferred"
}

test_driver_worker_quota_missing_packet() {
  (
  with_fixture "$scratch/drv-quota"
  export MOCK_WORKER_WINDOW=quota SINGULAR_WORKER_INFRA_MAX=1
  local out rc=0
  out="$("$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_deferred_drive "worker quota" "$out" "$rc" implement
  assert_eq "$(calls worker)" "1" "worker quota: no infra retry into the window"
  assert_eq "$(calls audit)" "0" "worker quota: auditor never launched"
  assert_eq "$(calls decider)" "0" "worker quota: decider never launched"
  assert_not_contains "$(cat "$SINGULAR_EVENTS_FILE")" '"worker.infra_retry"' "worker quota: no infra retry"
  assert_eq "$(json_field "$SINGULAR_PLANNER_BACKOFF_FILE" failureClass)" "quota" "worker quota: window armed"
  assert_contains "$(json_field "$SINGULAR_PLANNER_BACKOFF_FILE" evidenceRef)" \
    "implementer-attempt-1-try-0-runner-result.json" "worker quota: window bound to this invocation"
  assert_eq "$(json_field "$(singular_lease_path TASK-0001)" providerDeferral.invocationStarted)" "true" \
    "worker quota: deferral records a started invocation"
  )
  pass "driver: worker quota with no packet is provider-deferred, not worker-no-packet; retryCount unchanged"
}

test_driver_worker_overload() {
  (
  with_fixture "$scratch/drv-overload"
  export MOCK_WORKER_WINDOW=overload
  local out rc=0
  out="$("$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_deferred_drive "worker overload" "$out" "$rc" implement
  assert_eq "$(calls worker)" "1" "worker overload: single invocation"
  assert_eq "$(json_field "$SINGULAR_PLANNER_BACKOFF_FILE" failureClass)" "provider-overloaded" \
    "worker overload: short overload window armed, not quota"
  )
  pass "driver: worker overload is provider-deferred under its own window class"
}

arm_unit_window() {
  local evidence="$FIXTURE_TMP/prior/codex-runner-result.json" env_file
  env_file="$(mktemp "${TMPDIR:-/tmp}/sg-pwp-arm.XXXXXX")"
  printf '%s\n' "$QUOTA_ENVELOPE" >"$env_file"
  mkdir -p "$(dirname "$evidence")"
  singular_runner_result_write codex RUN-PRIOR implementer default "$evidence" 1 \
    "$env_file" "" "" >/dev/null 2>&1
  rm -f "$env_file"
  singular_planner_backoff_set quota RUN-PRIOR TASK-0001 "$evidence" >/dev/null 2>&1 \
    || fail "could not arm the prior window"
}

test_driver_closed_window_then_expiry() {
  (
  with_fixture "$scratch/drv-closed"
  arm_unit_window
  local out rc=0
  out="$("$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_deferred_drive "closed window" "$out" "$rc" implement
  assert_eq "$(calls worker)" "0" "closed window: worker never launched"
  assert_eq "$(json_field "$(singular_lease_path TASK-0001)" providerDeferral.invocationStarted)" "false" \
    "closed window: no invocation started"
  )
  (
  with_fixture "$scratch/drv-expired"
  arm_unit_window
  python3 - "$SINGULAR_PLANNER_BACKOFF_FILE" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["until"] = "2000-01-01T00:00:00Z"
json.dump(d, open(p, "w"))
PY
  local out rc=0
  out="$("$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_eq "$rc" "0" "expired window: drive admitted and accepted ($out)"
  assert_eq "$(calls worker)" "1" "expired window: worker launched"
  assert_eq "$(calls audit)" "1" "expired window: auditor launched"
  )
  pass "driver: a known closed window launches nothing; after expiry the launch is admitted"
}

test_driver_auditor_quota() {
  (
  with_fixture "$scratch/drv-audit"
  export MOCK_AUDIT_WINDOW=quota SINGULAR_AUDIT_INFRA_MAX=1
  local out rc=0
  out="$("$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_deferred_drive "auditor quota" "$out" "$rc" audit
  assert_eq "$(calls worker)" "1" "auditor quota: one worker pass"
  assert_eq "$(calls audit)" "1" "auditor quota: no auditor infra retry into the window"
  assert_not_contains "$(cat "$SINGULAR_EVENTS_FILE")" '"audit.infra_retry"' "auditor quota: no infra retry"
  assert_not_contains "$(cat "$SINGULAR_EVENTS_FILE")" '"audit.infra_exhausted"' "auditor quota: not audit-infra"
  )
  pass "driver: auditor quota is provider-deferred, not audit-infra"
}

test_driver_decider_quota() {
  (
  with_fixture "$scratch/drv-decider"
  export MOCK_DECIDER_WINDOW=quota MOCK_AUDIT_VERDICT_SEQ="needs-fix accepted" SINGULAR_DECIDER_FAST=0
  local out rc=0
  out="$(SINGULAR_DECIDER_TIMEOUT_SEC=60 "$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  assert_deferred_drive "decider quota" "$out" "$rc" decide
  assert_eq "$(calls decider)" "1" "decider quota: one decider invocation"
  assert_eq "$(calls worker)" "1" "decider quota: no repair pass authorized"
  assert_contains "$(cat "$SINGULAR_EVENTS_FILE")" '"lastFailure":"audit-needs-fix"' \
    "decider quota: the failure needing a decision stays recorded"
  )
  pass "driver: a decider provider window defers the decision; no product repair is charged"
}

run_case() {
  local name="$1" filter=",${SINGULAR_TEST_CASES:-},"
  if [[ "$filter" == ",," || "$filter" == *",$name,"* ]]; then
    "$name"
  fi
}

run_case test_codex_run_exit_split
run_case test_role_keyed_window
run_case test_evidence_binding
run_case test_worker_phase_resumed_quota
run_case test_worker_phase_exit_86_is_free
run_case test_worker_phase_exit_87_consumes_infra
run_case test_worker_phase_stale_sidecar_and_prose
run_case test_driver_worker_quota_missing_packet
run_case test_driver_worker_overload
run_case test_driver_closed_window_then_expiry
run_case test_driver_auditor_quota
run_case test_driver_decider_quota

echo "provider-window-preflight tests passed"
