#!/usr/bin/env bash
set -euo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CALLER_CHECKOUT="$ENGINE_HOME"
CALLER_STATE_DIR="${SINGULAR_STATE_DIR:-$CALLER_CHECKOUT/.singular-state}"
CALLER_EVENTS_FILE="${SINGULAR_EVENTS_FILE:-$CALLER_STATE_DIR/events.ndjson}"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_file() { [[ -f "$1" ]] || fail "$2: missing $1"; }
assert_not_file() { [[ ! -f "$1" ]] || fail "$2: unexpected $1"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2'"; }
tree_inventory() {
  local root="$1" path rel digest target mode
  if [[ ! -e "$root" && ! -L "$root" ]]; then
    printf 'MISSING\t%s\n' "$root"
    return
  fi
  while IFS= read -r path; do
    rel="${path#"$root"}"
    [[ -n "$rel" ]] || rel=.
    mode="$(stat -f '%Lp' "$path" 2>/dev/null || stat -c '%a' "$path")"
    if [[ -L "$path" ]]; then
      target="$(readlink "$path")"
      digest="$(printf '%s' "$target" | shasum -a 256 | awk '{print $1}')"
      printf 'L\t%s\t%s\t%s\n' "$mode" "$rel" "$digest"
    elif [[ -f "$path" ]]; then
      digest="$(shasum -a 256 "$path" | awk '{print $1}')"
      printf 'F\t%s\t%s\t%s\n' "$mode" "$rel" "$digest"
    elif [[ -d "$path" ]]; then
      printf 'D\t%s\t%s\n' "$mode" "$rel"
    else
      printf 'O\t%s\t%s\n' "$mode" "$rel"
    fi
  done < <(find "$root" -print | LC_ALL=C sort)
}
path_fingerprint() {
  local path="$1" kind mode digest target
  if [[ -L "$path" ]]; then
    kind=L; target="$(readlink "$path")"
    digest="$(printf '%s' "$target" | shasum -a 256 | awk '{print $1}')"
  elif [[ -f "$path" ]]; then
    kind=F; digest="$(shasum -a 256 "$path" | awk '{print $1}')"
  elif [[ -d "$path" ]]; then
    kind=D; digest=-
  else
    printf 'MISSING\t%s\n' "$path"
    return
  fi
  mode="$(stat -f '%Lp' "$path" 2>/dev/null || stat -c '%a' "$path")"
  printf '%s\t%s\t%s\t%s\n' "$kind" "$mode" "$digest" "$path"
}
protected_inventory() {
  local path
  for path in .gitignore engine/lib.sh engine/l1-drive.sh tests/test-per-try-artifacts.sh; do
    path_fingerprint "$CALLER_CHECKOUT/$path"
  done
}
assert_archive_isolated() {
  local label="$1" current leaked
  current="$(protected_inventory)"
  [[ "$current" == "$caller_protected_before" ]] \
    || fail "$label: protected caller checkout files changed"
  current="$(tree_inventory "$source_decoy_root")"
  [[ "$current" == "$source_decoy_before" ]] \
    || fail "$label: source-time decoy inventory changed"
  if [[ -f "$CALLER_EVENTS_FILE" ]] && grep -Fq -- "$archive_nonce" "$CALLER_EVENTS_FILE"; then
    fail "$label: archive nonce leaked to literal authoritative event file"
  fi
  leaked="$(find "$CALLER_STATE_DIR" -name "*$archive_nonce*" -print -quit 2>/dev/null || true)"
  [[ -z "$leaked" ]] || fail "$label: archive nonce leaked beneath literal caller state: $leaked"
}

tmp="$(mktemp -d)"
archive_nonce="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
decoy_canary="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
[[ "$decoy_canary" != "$archive_nonce" && "$decoy_canary" != *"$archive_nonce"* ]] \
  || fail "decoy canary must be independent from archive nonce"
sibling_writer_path="$CALLER_STATE_DIR/archive-hermeticity-sibling-$$.log"
# The worker phase runs in this shell with its output captured to a file under
# $tmp; an unbound driver global kills the shell there (set -u) and the file
# would vanish with $tmp. Surface it on any non-zero exit, on the test's own
# stderr (fd 9): the trap inherits the dying function's redirection.
exec 9>&2
on_exit() {
  local status=$? out
  rm -f "$sibling_writer_path"
  if [[ "$status" -ne 0 ]]; then
    for out in "$tmp"/worker-phase-*.out; do
      [[ -f "$out" ]] || continue
      echo "--- $(basename "$out") (tail) ---" >&9
      tail -20 "$out" >&9
    done
  fi
  rm -rf "$tmp"
}
trap on_exit EXIT
caller_protected_before="$(protected_inventory)"
run_dir="$tmp/run"
mkdir -p "$run_dir"
printf 'prompt\n' >"$run_dir/l2-active-prompt.md"

# Extract only the worker phase so this remains a focused unit test rather than
# provisioning a real worktree and provider session.
eval "$(awk '/^run_worker_phase\(\) \{/{copy=1} copy{print} copy && /^}$/{exit}' "$ENGINE_HOME/engine/l1-drive.sh")"
# The worker phase launches every provider argv through the host-owned context
# boundary (831e1ae). Use the real helpers: with no context configuration the
# boundary is feature-off and must invoke the runner argv unchanged.
source "$ENGINE_HOME/engine/ctx-rehydrate-event.sh"

runner="$tmp/runner.sh"
cat >"$runner" <<'SH'
#!/usr/bin/env bash
count_file="$SINGULAR_TEST_RUNNER_COUNT"
count=0
[[ -f "$count_file" ]] && count="$(cat "$count_file")"
printf '%s\n' "$((count + 1))" >"$count_file"
output_last_message=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-last-message) output_last_message="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ "${SINGULAR_TEST_RUNNER_MODE:-retry}" == "stale-output" ]]; then
  if [[ "$count" -eq 0 ]]; then
    printf '{"valid":"try-zero"}\n' >"$output_last_message"
    printf 'try-zero-wrote-output-then-timed-out\n'
    exit 124
  fi
  exit 1
fi
if [[ "${SINGULAR_TEST_RUNNER_MODE:-retry}" == "resume" ]]; then
  if [[ "$count" -eq 0 ]]; then
    printf '{"stale":"resume-refused"}\n' >"$output_last_message"
    printf '{"call":"resume","exitCode":86}\n' >"$SINGULAR_RUNNER_RESULT_FILE"
    printf 'live-resume-envelope\n' >"${SINGULAR_RUNNER_RESULT_FILE%.json}.provider-envelope.raw"
    printf 'resume-refused-diagnostic\n' >&2
    exit 86
  fi
  printf '{"call":"resume-fallback","exitCode":1}\n' >"$SINGULAR_RUNNER_RESULT_FILE"
  printf 'live-resume-fallback-envelope\n' >"${SINGULAR_RUNNER_RESULT_FILE%.json}.provider-envelope.raw"
  exit 1
fi
if [[ "$count" -eq 0 ]]; then
  printf 'try-zero-timeout-marker\n'
  exit 124
fi
printf 'try-one-success-marker\n'
exit 0
SH
chmod +x "$runner"

export SINGULAR_TEST_RUNNER_COUNT="$tmp/runner-count"
export SINGULAR_WORKER_INFRA_MAX=1
task_id=TASK-0109
run_id=RUN-TRY-TEST
worktree="$tmp/worktree"
mkdir -p "$worktree"
l2_runner="$runner"
l2_prompt="$run_dir/l2-active-prompt.md"
session_meta_implementer="$tmp/session.json"
bootstrap_failure=""
bootstrap_log="$tmp/bootstrap.log"
worker_rc=0
attempt_failure=""
attempt_ctx=""
worker_strategy=""
worker_strategy_reason=""
# Driver globals (l1-drive.sh): no authorized continuation, no prior attempt's
# context bundle, no campaign binding, and no context configuration selected.
authorized_continuation=()
continuation_invocation_started="no"
latest_worker_context_bundle=""
l1_campaign_binding=""
SINGULAR_ROOT="$tmp/root"
SINGULAR_TASKS_DIR="$SINGULAR_ROOT/docs/orchestration/tasks"
task_file="$SINGULAR_TASKS_DIR/$task_id.md"
unset SINGULAR_CONTEXT_CONFIG_FILE SINGULAR_JSON_CONFIG_FILE
SINGULAR_RUNNER_CONTRACT_ARGS=()

l1_status() { :; }
git() { printf 'deadbeef\n'; }
singular_prompt_sha() { printf 'promptsha\n'; }
singular_ctx_route_decide() { printf 'fresh test\n'; }
singular_append_event() { :; }
singular_ctx_rehydrate_authored_node() { return 1; }
singular_ctx_rehydrate_authored_triggers() { :; }
singular_ctx_rehydrate_authored_config_render() { :; }
rehydrate_inject_packet() { :; }
singular_runner_contract_prepare() { SINGULAR_RUNNER_CONTRACT_ARGS=(); }
singular_planner_failure_class() {
  local log="$1" rc="$2" output_file="$3"
  printf '%s|%s|%s\n' "$(basename "$log")" "$rc" "$(cat "$log" 2>/dev/null || true)" \
    >>"$tmp/classifier-inputs"
  if [[ "$rc" -eq 124 ]]; then
    printf 'timeout\n'
  elif [[ "$rc" -ne 0 && ! -s "$output_file" ]]; then
    printf 'empty-output\n'
  elif [[ "$rc" -ne 0 ]]; then
    printf 'codex-exit-with-output\n'
  elif [[ "$rc" -eq 0 ]]; then
    printf 'clean\n'
  else
    printf 'empty-output\n'
  fi
}
singular_l1_prepare_worker_packet() { return 10; }

rc=0
run_worker_phase 3 >"$tmp/worker-phase-3.out" 2>&1 || rc=$?
[[ "$rc" -eq 1 && "$attempt_failure" == "worker-no-packet" ]] \
  || fail "successful retry must proceed to packet validation"
assert_file "$run_dir/worker-attempt-3-try-0.log" "try 0 log"
assert_file "$run_dir/worker-attempt-3-try-1.log" "try 1 log"
assert_contains "$(sed -n '1p' "$tmp/classifier-inputs")" \
  'worker-attempt-3-try-0.log|124|try-zero-timeout-marker' \
  "try 0 classification uses only try 0 output"
[[ "$(sed -n '2p' "$tmp/classifier-inputs")" == 'worker-attempt-3-try-1.log|0|try-one-success-marker' ]] \
  || fail "try 1 classification must use only its own successful output"
printf 'try-zero-timeout-marker\n' >"$tmp/expected-try-0"
printf 'try-one-success-marker\n' >"$tmp/expected-try-1"
cmp -s "$tmp/expected-try-0" "$run_dir/worker-attempt-3-try-0.log" \
  || fail "try 0 bytes differ from runner output"
cmp -s "$tmp/expected-try-1" "$run_dir/worker-attempt-3-try-1.log" \
  || fail "try 1 bytes differ from runner output"
{
  printf '%s\n' '--- worker try 0 (attempt 3) ---'
  cat "$tmp/expected-try-0"
  printf '%s\n' '--- worker try 1 (attempt 3) ---'
  cat "$tmp/expected-try-1"
} >"$tmp/expected-aggregate"
cmp -s "$tmp/expected-aggregate" "$run_dir/worker-codex.log" \
  || fail "aggregate separators, ordering, or copied bytes differ"

# Try 0 writes valid output and times out; try 1 fails before writing output.
# The second invocation must classify its own empty output as worker-infra.
run_dir="$tmp/stale-output-run"
mkdir -p "$run_dir"
printf 'prompt\n' >"$run_dir/l2-active-prompt.md"
l2_prompt="$run_dir/l2-active-prompt.md"
rm -f "$SINGULAR_TEST_RUNNER_COUNT"
export SINGULAR_TEST_RUNNER_MODE=stale-output
export SINGULAR_WORKER_INFRA_MAX=1
attempt_failure=""
rc=0
run_worker_phase 5 >"$tmp/worker-phase-5.out" 2>&1 || rc=$?
[[ "$rc" -eq 1 && "$attempt_failure" == "worker-infra" ]] \
  || fail "try 1 with no output must classify as worker-infra, not reuse try 0 output"
[[ "$(cat "$SINGULAR_TEST_RUNNER_COUNT")" == "2" ]] \
  || fail "stale-output fixture must execute both infra tries"
assert_not_file "$run_dir/last-message.json" \
  "failed try 1 must leave no stale last-message artifact"

# Resume refusal bytes and the fresh fallback rerun each remain independently
# durable, while classification follows the fallback output for this try.
run_dir="$tmp/resume-run"
mkdir -p "$run_dir"
printf 'prompt\n' >"$run_dir/l2-active-prompt.md"
l2_prompt="$run_dir/l2-active-prompt.md"
rm -f "$SINGULAR_TEST_RUNNER_COUNT"
export SINGULAR_TEST_RUNNER_MODE=resume
export SINGULAR_WORKER_INFRA_MAX=0
singular_ctx_route_decide() { printf 'resume session-123\n'; }
attempt_failure=""
rc=0
run_worker_phase 4 >"$tmp/worker-phase-4.out" 2>&1 || rc=$?
[[ "$rc" -eq 1 && "$attempt_failure" == "worker-infra" ]] \
  || fail "failed fresh fallback with no output must classify as worker-infra"
assert_file "$run_dir/worker-attempt-4-try-0.log" "resume-refused log"
assert_file "$run_dir/worker-attempt-4-try-0-resume-fallback.log" "resume fallback log"
resume_result="$run_dir/implementer-attempt-4-try-0-resume-runner-result.json"
resume_envelope="$run_dir/implementer-attempt-4-try-0-resume-runner-result.provider-envelope.raw"
fallback_result="$run_dir/implementer-attempt-4-try-0-resume-fallback-runner-result.json"
fallback_envelope="$run_dir/implementer-attempt-4-try-0-resume-fallback-runner-result.provider-envelope.raw"
assert_file "$resume_result" "live resumed-call runner result uses attempt 4 try 0 name"
assert_file "$resume_envelope" "live resumed-call provider envelope uses attempt 4 try 0 name"
assert_file "$fallback_result" "live fallback runner result stays in attempt 4 try 0"
assert_file "$fallback_envelope" "live fallback provider envelope stays in attempt 4 try 0"
[[ "$(cat "$resume_result")" == '{"call":"resume","exitCode":86}' ]] \
  || fail "live resumed-call result bytes are not from the rc-86 invocation"
[[ "$(cat "$resume_envelope")" == 'live-resume-envelope' ]] \
  || fail "live resumed-call envelope bytes differ"
[[ "$(cat "$fallback_result")" == '{"call":"resume-fallback","exitCode":1}' ]] \
  || fail "live fallback result bytes are not from the fresh invocation"
[[ "$(cat "$fallback_envelope")" == 'live-resume-fallback-envelope' ]] \
  || fail "live fallback envelope bytes differ"
assert_not_file "$run_dir/implementer-attempt-4-try-1-runner-result.json" \
  "resume fallback must not consume an infra try"
assert_contains "$(cat "$run_dir/worker-attempt-4-try-0.log")" \
  'resume-refused-diagnostic' "resume refusal diagnostic retained"
assert_contains "$(cat "$run_dir/worker-codex.log")" \
  'resume-refused-diagnostic' "aggregate retains refused resume bytes"
assert_not_file "$run_dir/last-message.json" \
  "failed fresh fallback must remove resume refusal's stale last-message"
printf 'resume-refused-diagnostic\n' >"$tmp/expected-resume-refusal"
: >"$tmp/expected-resume-fallback"
{
  printf '%s\n' '--- worker try 0 (attempt 4) ---'
  cat "$tmp/expected-resume-refusal"
  printf '%s\n' '--- worker resume-fallback try 0 (attempt 4) ---'
  cat "$tmp/expected-resume-fallback"
} >"$tmp/expected-resume-aggregate"
cmp -s "$tmp/expected-resume-refusal" "$run_dir/worker-attempt-4-try-0.log" \
  || fail "resume-refusal log bytes differ from live runner output"
cmp -s "$tmp/expected-resume-fallback" "$run_dir/worker-attempt-4-try-0-resume-fallback.log" \
  || fail "resume-fallback log bytes differ from live runner output"
cmp -s "$tmp/expected-resume-aggregate" "$run_dir/worker-codex.log" \
  || fail "resume aggregate headers, same-try ordering, or copied bytes differ"
assert_contains "$(tail -1 "$tmp/classifier-inputs")" \
  'worker-attempt-4-try-0-resume-fallback.log|1|' \
  "fallback classification uses the empty fallback output"

unset SINGULAR_TEST_RUNNER_MODE

# Archive selection is attempt-scoped and additive. Source lib.sh against
# canary-filled decoy paths, then rebind every stateful path per iteration.
source_decoy_root="$tmp/source-decoy"
source_decoy_state="$source_decoy_root/state"
mkdir -p "$source_decoy_root/root" "$source_decoy_state/nested"
printf 'decoy-state-%s\n' "$decoy_canary" >"$source_decoy_state/nested/canary.txt"
printf 'decoy-event-%s\n' "$decoy_canary" >"$source_decoy_state/events.decoy.ndjson"
printf '{"canary":"%s"}\n' "$decoy_canary" >"$source_decoy_root/config.decoy.json"
printf 'decoy_config=%s\n' "$decoy_canary" >"$source_decoy_root/config.decoy.sh"
printf 'decoy_local=%s\n' "$decoy_canary" >"$source_decoy_root/config.local.decoy.sh"
grep -RFq -- "$archive_nonce" "$source_decoy_root" \
  && fail "archive nonce must be absent from source-time decoys"
source_decoy_before="$(tree_inventory "$source_decoy_root")"
export SINGULAR_ROOT="$source_decoy_root/root"
export SINGULAR_ENGINE_HOME="$ENGINE_HOME"
export SINGULAR_ENGINE_DIR="$ENGINE_HOME/engine"
export SINGULAR_SCHEMA_DIR="$ENGINE_HOME/schemas"
export SINGULAR_ORCH_DIR="$source_decoy_root/root/docs/orchestration"
export SINGULAR_STATE_DIR="$source_decoy_state"
export SINGULAR_EVENTS_FILE="$source_decoy_state/events.decoy.ndjson"
export SINGULAR_TASKS_DIR="$source_decoy_root/root/docs/orchestration/tasks"
export SINGULAR_LEASES_DIR="$source_decoy_state/leases"
export SINGULAR_INBOX_DIR="$source_decoy_state/inbox"
export SINGULAR_RUNS_DIR="$source_decoy_state/runs"
export SINGULAR_WORKTREES_DIR="$source_decoy_root/root/.worktrees"
export SINGULAR_ORIGIN_STATE_FILE="$source_decoy_state/origin-state.json"
export SINGULAR_GIT_LOCK_DIR="$source_decoy_state/locks/git-op.lock"
export SINGULAR_STOP_FILE="$source_decoy_state/STOP"
export SINGULAR_STATUS_FILE="$source_decoy_state/STATUS.md"
export SINGULAR_BREAKER_FILE="$source_decoy_state/circuit.json"
export SINGULAR_PLANNER_BACKOFF_FILE="$source_decoy_state/planner-backoff.json"
export SINGULAR_PROVIDER_PRESSURE_FILE="$source_decoy_state/provider-pressure.json"
export SINGULAR_DISPATCH_DIR="$source_decoy_state/dispatch"
export SINGULAR_L1_LEASES_DIR="$source_decoy_state/l1-leases"
export SINGULAR_JSON_CONFIG_FILE="$source_decoy_root/config.decoy.json"
export SINGULAR_CONFIG_FILE="$source_decoy_root/config.decoy.sh"
export SINGULAR_LOCAL_CONFIG_FILE="$source_decoy_root/config.local.decoy.sh"
source "$ENGINE_HOME/engine/lib.sh"

archive_execution_count=0
iteration_state_inventories=()
run_archive_iteration() {
  local iteration="$1" archive event_count other_iteration marker
  fixture_root="$tmp/archive-iteration-$iteration/root"
  fixture_state="$tmp/archive-iteration-$iteration/state"
  run_id="resume-run-$archive_nonce-iteration-$iteration"
  marker="archive-marker-$archive_nonce-iteration-$iteration"
  run_dir="$fixture_state/runs/$run_id"
  mkdir -p "$fixture_root" "$fixture_state" "$run_dir"
  export SINGULAR_ROOT="$fixture_root"
  export SINGULAR_ORCH_DIR="$fixture_root/docs/orchestration"
  export SINGULAR_STATE_DIR="$fixture_state"
  export SINGULAR_EVENTS_FILE="$fixture_state/events.ndjson"
  export SINGULAR_TASKS_DIR="$fixture_root/docs/orchestration/tasks"
  export SINGULAR_LEASES_DIR="$fixture_state/leases"
  export SINGULAR_INBOX_DIR="$fixture_state/inbox"
  export SINGULAR_RUNS_DIR="$fixture_state/runs"
  export SINGULAR_WORKTREES_DIR="$fixture_root/.worktrees"
  export SINGULAR_ORIGIN_STATE_FILE="$fixture_state/origin-state.json"
  export SINGULAR_GIT_LOCK_DIR="$fixture_state/locks/git-op.lock"
  export SINGULAR_STOP_FILE="$fixture_state/STOP"
  export SINGULAR_STATUS_FILE="$fixture_state/STATUS.md"
  export SINGULAR_BREAKER_FILE="$fixture_state/circuit.json"
  export SINGULAR_PLANNER_BACKOFF_FILE="$fixture_state/planner-backoff.json"
  export SINGULAR_PROVIDER_PRESSURE_FILE="$fixture_state/provider-pressure.json"
  export SINGULAR_DISPATCH_DIR="$fixture_state/dispatch"
  export SINGULAR_L1_LEASES_DIR="$fixture_state/l1-leases"
  export SINGULAR_JSON_CONFIG_FILE="$tmp/archive-iteration-$iteration/config.absent.json"
  export SINGULAR_CONFIG_FILE="$tmp/archive-iteration-$iteration/config.absent.sh"
  export SINGULAR_LOCAL_CONFIG_FILE="$tmp/archive-iteration-$iteration/config.local.absent.sh"

  printf 'audit aggregate %s %s\n' "$iteration" "$marker" >"$run_dir/auditor-codex.log"
  printf 'worker a1 %s %s\n' "$iteration" "$marker" >"$run_dir/worker-attempt-1-try-0.log"
  printf 'worker a1 fallback %s\n' "$iteration" >"$run_dir/worker-attempt-1-try-0-resume-fallback.log"
  printf 'worker a2 %s\n' "$iteration" >"$run_dir/worker-attempt-2-try-0.log"
  printf '{}\n' >"$run_dir/implementer-attempt-1-try-0-runner-result.json"
  printf 'implementer envelope a1 %s\n' "$iteration" >"$run_dir/implementer-attempt-1-try-0-runner-result.provider-envelope.raw"
  printf '{}\n' >"$run_dir/auditor-attempt-1-try-0-runner-result.json"
  printf 'auditor envelope a1 %s\n' "$iteration" >"$run_dir/auditor-attempt-1-try-0-runner-result.provider-envelope.raw"
  printf '{}\n' >"$run_dir/implementer-attempt-2-try-0-runner-result.json"
  printf '{}\n' >"$run_dir/auditor-attempt-2-try-0-runner-result.json"
  printf 'implementer envelope a2 %s\n' "$iteration" >"$run_dir/implementer-attempt-2-try-0-runner-result.provider-envelope.raw"
  printf 'auditor envelope a2 %s\n' "$iteration" >"$run_dir/auditor-attempt-2-try-0-runner-result.provider-envelope.raw"
  SINGULAR_ATTEMPT_TASK_ID=TASK-0109 singular_attempt_archive \
    "$run_dir" 1 "$marker" unknown '' retry decider
  archive_execution_count=$((archive_execution_count + 1))

  archive="$run_dir/attempts/1"
  assert_file "$archive/auditor-codex.log" "iteration $iteration auditor aggregate archive"
  assert_file "$archive/worker-attempt-1-try-0.log" "iteration $iteration worker per-try archive"
  assert_file "$archive/worker-attempt-1-try-0-resume-fallback.log" "iteration $iteration worker fallback archive"
  assert_file "$archive/implementer-attempt-1-try-0-runner-result.json" "iteration $iteration implementer result archive"
  assert_file "$archive/auditor-attempt-1-try-0-runner-result.json" "iteration $iteration auditor result archive"
  assert_file "$archive/implementer-attempt-1-try-0-runner-result.provider-envelope.raw" "iteration $iteration implementer provider envelope archive"
  assert_file "$archive/auditor-attempt-1-try-0-runner-result.provider-envelope.raw" "iteration $iteration auditor provider envelope archive"
  assert_not_file "$archive/worker-attempt-2-try-0.log" "iteration $iteration other attempt worker log excluded"
  assert_not_file "$archive/implementer-attempt-2-try-0-runner-result.json" "iteration $iteration other attempt implementer result excluded"
  assert_not_file "$archive/auditor-attempt-2-try-0-runner-result.json" "iteration $iteration other attempt auditor result excluded"
  assert_not_file "$archive/implementer-attempt-2-try-0-runner-result.provider-envelope.raw" "iteration $iteration other attempt implementer envelope excluded"
  assert_not_file "$archive/auditor-attempt-2-try-0-runner-result.provider-envelope.raw" "iteration $iteration other attempt auditor envelope excluded"
  assert_file "$run_dir/auditor-codex.log" "iteration $iteration root auditor log retained"
  assert_file "$run_dir/worker-attempt-1-try-0.log" "iteration $iteration root worker log retained"
  event_count="$(grep -c '"type":"l1.attempt_archived"' "$SINGULAR_EVENTS_FILE" || true)"
  [[ "$event_count" -eq 1 && "$(wc -l <"$SINGULAR_EVENTS_FILE" | tr -d ' ')" -eq 1 ]] \
    || fail "iteration $iteration must contain exactly one synthetic archive event"
  assert_contains "$(cat "$SINGULAR_EVENTS_FILE")" \
    '"runId":"'"$run_id"'"' \
    "iteration $iteration archive event uses its own run root"
  assert_contains "$(cat "$SINGULAR_EVENTS_FILE")" "$marker" \
    "iteration $iteration archive event includes its nonce marker"
  other_iteration=$((3 - iteration))
  if grep -Fq -- "iteration-$other_iteration" "$SINGULAR_EVENTS_FILE"; then
    fail "iteration $iteration event log contains a cross-iteration event"
  fi
  iteration_state_inventories[$iteration]="$(tree_inventory "$fixture_state")"
  assert_archive_isolated "after archive iteration $iteration"
}

# Preserve the real event helper, then synchronize a deterministic unrelated
# caller-state writer from inside each archive call's event-emission stack.
eval "$(declare -f singular_append_event | sed '1s/singular_append_event/singular_append_event_real/')"
sibling_control="$tmp/sibling-control"
mkdir -p "$sibling_control" "$CALLER_STATE_DIR"
(
  printf '%s\n' "$BASHPID" >"$sibling_control/pid"
  : >"$sibling_control/ready"
  for sibling_write in 1 2 final; do
    while [[ ! -f "$sibling_control/request-$sibling_write" ]]; do sleep 0.01; done
    printf 'unrelated sibling lifecycle write %s\n' "$sibling_write" >>"$sibling_writer_path"
    : >"$sibling_control/ack-$sibling_write"
  done
) &
sibling_writer_pid=$!
ready_deadline=$((SECONDS + 5))
while [[ ! -f "$sibling_control/ready" ]]; do
  (( SECONDS < ready_deadline )) || fail "sibling writer did not become ready"
  sleep 0.01
done
[[ "$(cat "$sibling_control/pid")" == "$sibling_writer_pid" ]] \
  || fail "sibling writer must publish its captured PID"

archive_event_index=0
singular_append_event() {
  if [[ "${1:-}" == "l1.attempt_archived" ]]; then
    archive_event_index=$((archive_event_index + 1))
    : >"$sibling_control/request-$archive_event_index"
    local ack_deadline=$((SECONDS + 5))
    while [[ ! -f "$sibling_control/ack-$archive_event_index" ]]; do
      (( SECONDS < ack_deadline )) || fail "sibling writer did not acknowledge archive $archive_event_index on-stack"
      sleep 0.01
    done
  fi
  singular_append_event_real "$@"
}

run_archive_iteration 1
run_archive_iteration 2
[[ "$archive_execution_count" -eq 2 ]] \
  || fail "archive fixture must execute twice in the same shell process"
[[ "$archive_event_index" -eq 2 ]] \
  || fail "both archive calls must synchronize an on-stack sibling write"
assert_not_file "$tmp/archive-iteration-1/state/runs/resume-run-$archive_nonce-iteration-2/attempts/1/failure.txt" \
  "iteration 2 archive must not appear in iteration 1 root"
assert_not_file "$tmp/archive-iteration-2/state/runs/resume-run-$archive_nonce-iteration-1/attempts/1/failure.txt" \
  "iteration 1 archive must not appear in iteration 2 root"

# Demand a final sibling mutation before the bounded late-writer drain.
: >"$sibling_control/request-final"
drain_deadline=$((SECONDS + 5))
while [[ ! -f "$sibling_control/ack-final" ]]; do
  (( SECONDS < drain_deadline )) || fail "sibling writer did not perform final requested write"
  sleep 0.01
done
wait "$sibling_writer_pid" || fail "sibling writer must exit zero"
[[ "$(wc -l <"$sibling_writer_path" | tr -d ' ')" -eq 3 ]] \
  || fail "sibling writer must leave exactly three acknowledged writes"
for iteration in 1 2; do
  fixture_event="$tmp/archive-iteration-$iteration/state/events.ndjson"
  [[ "$(tree_inventory "$tmp/archive-iteration-$iteration/state")" == "${iteration_state_inventories[$iteration]}" ]] \
    || fail "delayed write changed iteration $iteration fixture inventory"
  [[ "$(grep -c '"type":"l1.attempt_archived"' "$fixture_event" || true)" -eq 1 ]] \
    || fail "iteration $iteration synthetic archive event count changed after drain"
  assert_contains "$(cat "$fixture_event")" \
    '"runId":"resume-run-'"$archive_nonce"'-iteration-'"$iteration"'"' \
    "iteration $iteration event remains fixture-local after drain"
done
assert_archive_isolated "after bounded final drain"

echo "PASS: test-per-try-artifacts"
