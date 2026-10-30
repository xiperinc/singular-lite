#!/usr/bin/env bash
# A red integration gate must leave the retained candidate recoverable.
#
# Regression for the 0.23.4 consumer incident: the acceptance header
# (`Status: accepted`) is uncommitted control state when integration starts, so
# aborting the staged merge fell back to the committed `Status: ready` while the
# lease kept the hash of the accepted bytes. Every later path then refused the
# candidate: an ordinary retry ("accepted candidate identity changed without a
# fresh lifecycle") and the documented regate ("recovery task contract
# changed"). The only way through was to hand-edit the header.
#
# Three fixtures, none of which edits a task file by hand to recover:
#   A  capacity remains  -> fix the target branch, plain `integrate` retries.
#   B  budget exhausted  -> the skip line and `health` print the exact regate
#                           command; running it verbatim integrates the task.
#   C  0.23.4 on-disk state (header already rolled back to `ready`) -> both the
#      ordinary retry and the regate authorization still verify.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-integration-gate-red-recovery.sh requires bash >= 4" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# The `singular` the printed commands name. It routes the two verbs the
# recovery path uses to the engine under test, exactly as cli/singular does.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/singular" <<SH
#!/usr/bin/env bash
set -euo pipefail
verb="\${1:-}"; shift || true
case "\$verb" in
  recover) exec "$ROOT/engine/recover.sh" "\$@" ;;
  integrate) exec bash "$ROOT/engine/integrate.sh" "\$@" ;;
  *) echo "fixture singular: unsupported verb \$verb" >&2; exit 2 ;;
esac
SH
chmod +x "$tmp/bin/singular"

repo="" orch="" state="" head="" task="" lease=""
declare -a engine_env=()

# build_fixture NAME TASK-ID MAX-RETRIES
# A target branch that is red for a reason unrelated to the candidate (a "lint
# error" in a target-owned file), one accepted candidate, and the task contract
# in the state the engine leaves it at acceptance: committed `Status: ready`,
# uncommitted `Status: accepted`.
build_fixture() {
  local name="$1" task_id="$2" max_retries="$3" run="RUN-ACCEPTED" branch tree run_path
  repo="$tmp/$name"
  orch="$repo/docs/orchestration"
  state="$repo/.singular-state"
  task="$orch/tasks/$task_id.md"
  lease="$state/leases/$task_id.json"
  branch="agent/core/$task_id-feature"
  mkdir -p "$orch/tasks" "$orch/packets/imported/$task_id" "$state/leases"
  git -C "$repo" init -q
  git -C "$repo" checkout -qb target
  git -C "$repo" config user.name fixture
  git -C "$repo" config user.email fixture@example.local
  cat >"$repo/singular.config.json" <<'JSON'
{"schemaVersion":"v2","targetBranch":"target","gateCommand":"bash lint-gate.sh","bootstrap":{"required":false,"commands":[]}}
JSON
  cat >"$repo/lint-gate.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ -z "${GATE_RUN_COUNTER:-}" ]] || printf 'gate\n' >>"$GATE_RUN_COUNTER"
if grep -q 'lint-error' target-owned.txt; then
  printf '%s\n' '{"schema":"singular.orchestration.gate-observation.v0","failures":[{"signature":"lint:target-owned","title":"lint error in target-owned.txt"}]}' >"$SINGULAR_GATE_REPORT_FILE"
  echo "AssertionError: lint error in target-owned.txt" >&2
  exit 1
fi
printf '%s\n' '{"schema":"singular.orchestration.gate-observation.v0","failures":[]}' >"$SINGULAR_GATE_REPORT_FILE"
SH
  chmod +x "$repo/lint-gate.sh"
  printf 'clean\n' >"$repo/target-owned.txt"
  cat >"$task" <<MD
# $task_id: gate-red recovery fixture

Status: ready
Area: core
Target branch: \`target\`
Worker branch: \`$branch\`
Test policy: \`strict_test_first\`
Gate command: \`bash lint-gate.sh\`
Dispatch mode: canonical
Depends on: []

## Objective

Exercise recovery from a red integration gate.

## Scope

Owned files:

- \`feature.txt\`
MD
  printf '%s\n' '.singular-state/' '.singular-cache/' '.singular-evidence/' '.worktrees/' \
    >"$repo/.gitignore"
  git -C "$repo" add .
  git -C "$repo" commit -qm base

  engine_env=(env -i PATH="$tmp/bin:$PATH" HOME="$tmp" TMPDIR="${TMPDIR:-/tmp}"
    SINGULAR_ROOT="$repo" SINGULAR_ORCH_DIR="$orch" SINGULAR_TASKS_DIR="$orch/tasks"
    SINGULAR_STATE_DIR="$state" SINGULAR_LEASES_DIR="$state/leases"
    SINGULAR_RUNS_DIR="$state/runs" SINGULAR_WORKTREES_DIR="$repo/.worktrees"
    SINGULAR_ENGINE_HOME="$ROOT" SINGULAR_JSON_CONFIG_FILE="$repo/singular.config.json"
    SINGULAR_CONFIG_FILE=/dev/null SINGULAR_LOCAL_CONFIG_FILE=/dev/null
    SINGULAR_AUTO_PROMOTE_GATES=0 SINGULAR_PUSH=0 GATE_RUN_COUNTER="$tmp/$name.gate-runs")
  : >"$tmp/$name.gate-runs"

  # The worker's candidate, verified against the `Status: ready` contract.
  git -C "$repo" checkout -qb "$branch"
  printf 'feature\n' >"$repo/feature.txt"
  git -C "$repo" add feature.txt
  git -C "$repo" commit -qm candidate
  head="$(git -C "$repo" rev-parse HEAD)"
  tree="$(git -C "$repo" rev-parse "HEAD^{tree}")"
  run_path="$state/runs/$run"
  mkdir -p "$run_path"
  cp "$task" "$run_path/verification-task-contract-1.md"
  printf '%s\n' '{"campaign":"legacy","policy":"legacy"}' >"$run_path/verification-policy-1.json"
  python3 "$ROOT/engine/gate-report.py" create-verification-request \
    --output "$run_path/verification-request-1.json" --task-id "$task_id" --run-id "$run" \
    --attempt 1 --head-sha "$head" --tree-sha "$tree" --campaign legacy \
    --task-contract "$run_path/verification-task-contract-1.md" \
    --policy-contract "$run_path/verification-policy-1.json" \
    --suite-id task-contract-gate >/dev/null
  (cd "$repo" && "${engine_env[@]}" "$ROOT/engine/gate-check.sh" "$run" \
    --task-id "$task_id" --verification-request "$run_path/verification-request-1.json" \
    --task-contract "$run_path/verification-task-contract-1.md" \
    --policy-contract "$run_path/verification-policy-1.json" --attempt 1) >/dev/null
  mv "$run_path/gate-report.json" "$run_path/audit-verification.json"
  : >"$tmp/$name.gate-runs"
  git -C "$repo" checkout -q target

  cat >"$orch/packets/imported/$task_id/$run.json" <<JSON
{"schema":"singular.orchestration.state-packet.v0","packetId":"$run","runId":"$run","taskId":"$task_id","area":"core","role":"l2-developer","status":"accepted","baseRef":"target","branch":"$branch","headSha":"$head","workspace":"$repo","ownedFiles":["feature.txt"],"changedFiles":["feature.txt"],"commands":[{"cmd":"bash lint-gate.sh","exitCode":0}],"tests":[{"name":"fixture","phase":"regression","status":"passed"}],"evidence":[{"kind":"test","ref":"fixture"},{"kind":"audit-verification","ref":"runs/$run/audit-verification.json"}],"blockers":[],"nextAction":"integrate","createdAt":"2026-10-05T00:00:00Z"}
JSON
  cat >"$orch/packets/imported/$task_id/$run.audit.json" <<JSON
{"schema":"singular.orchestration.audit-verdict.v1","taskId":"$task_id","runId":"$run","branch":"$branch","verdict":"accepted","evidenceReviewed":["fixture","audit-verification.json","reviewed-head-sha:$head"],"verificationResults":[{"status":"passed","command":"bash lint-gate.sh","exitCode":0,"evidenceRefs":["audit-verification.json"],"rationale":"host-bound fixture gate"}],"commandsRun":[],"findings":[],"requiredFixes":[],"rationale":"fixture accepted"}
JSON
  git -C "$repo" add docs/orchestration/packets
  git -C "$repo" commit -qm packet

  # Acceptance, as l1-drive publishes it: the lease and the task header move to
  # `accepted`, and the header edit stays uncommitted until the cycle ends.
  cat >"$lease" <<JSON
{"taskId":"$task_id","status":"accepted","branch":"$branch","runId":"$run","maxRetries":$max_retries}
JSON
  "${engine_env[@]}" bash -c 'source "$SINGULAR_ENGINE_HOME/engine/lib.sh" >/dev/null && singular_task_set_status "$1" accepted' _ "$task"
  grep -q '^Status: accepted$' "$task" || fail "$name: fixture could not publish acceptance"
  [[ "$(git -C "$repo" show "HEAD:docs/orchestration/tasks/$task_id.md" | grep -c '^Status: ready$')" == 1 ]] \
    || fail "$name: fixture must keep the committed header at ready"

  # The target branch goes red for a reason the candidate does not own.
  printf 'lint-error\n' >"$repo/target-owned.txt"
  git -C "$repo" add target-owned.txt
  git -C "$repo" commit -qm 'target: introduce a lint error'
}

integrate() {
  local out="$1"; shift
  "${engine_env[@]}" bash "$ROOT/engine/integrate.sh" "$@" >"$out" 2>&1
}

gate_runs() { wc -l <"$tmp/$1.gate-runs" | tr -d ' '; }

fix_target() {
  printf 'clean\n' >"$repo/target-owned.txt"
  git -C "$repo" add target-owned.txt
  git -C "$repo" commit -qm 'target: fix the lint error'
}

# The lease binds the exact task-contract bytes; after a red gate they must
# still be the bytes on disk.
assert_red_but_recoverable() {
  local name="$1" task_id="$2" out="$3"
  grep -q "FAILED $task_id: post-merge gate failed-product" "$out" \
    || fail "$name: red target gate was not recorded: $(cat "$out")"
  [[ ! -e "$repo/.git/MERGE_HEAD" ]] || fail "$name: red gate left a merge in progress"
  git -C "$repo" diff --cached --quiet || fail "$name: red gate left staged bytes"
  grep -q '^Status: accepted$' "$task" \
    || fail "$name: red integration gate rolled the task header back to '$(grep '^Status:' "$task")' while the lease stays accepted"
  python3 - "$lease" "$task" <<'PY' || fail "$name: lease no longer binds the task contract on disk"
import hashlib, json, sys
lease = json.load(open(sys.argv[1], encoding="utf-8"))
candidate = lease["acceptedCandidate"]
assert lease["status"] == "accepted", lease
assert candidate["state"] == "integration-failed", candidate
assert candidate["failures"][-1]["failureClass"] == "gate-red", candidate
assert candidate["failures"][-1]["domain"] == "product", candidate
observed = hashlib.sha256(open(sys.argv[2], "rb").read()).hexdigest()
assert candidate["taskContractSha256"] == observed, (candidate["taskContractSha256"], observed)
PY
}

assert_integrated() {
  local name="$1" task_id="$2" out="$3"
  grep -q "^INTEGRATED $task_id:" "$out" || fail "$name: task did not integrate: $(cat "$out")"
  git -C "$repo" merge-base --is-ancestor "$head" target \
    || fail "$name: candidate head is not on the target branch"
  [[ "$(git -C "$repo" show "HEAD:docs/orchestration/tasks/$task_id.md" | grep -c '^Status: integrated$')" == 1 ]] \
    || fail "$name: integration commit does not carry the integrated status"
  python3 - "$lease" <<'PY' || fail "$name: lease did not record the integration"
import json, sys
lease = json.load(open(sys.argv[1], encoding="utf-8"))
assert lease["acceptedCandidate"]["state"] == "integrated", lease
PY
}

# ---- A: capacity remains, the target is fixed, an ordinary retry integrates --
build_fixture capacity TASK-0001 3
integrate "$tmp/a-red.out" --task TASK-0001 --run-id RUN-A-RED \
  && fail "A: red target gate unexpectedly integrated"
assert_red_but_recoverable A TASK-0001 "$tmp/a-red.out"
[[ "$(gate_runs capacity)" == 1 ]] || fail "A: expected exactly one gate run"
# Nothing changed: the recorded failure is suppressed without another gate run.
integrate "$tmp/a-replay.out" --task TASK-0001 --run-id RUN-A-REPLAY \
  || fail "A: unchanged replay did not stop cleanly: $(cat "$tmp/a-replay.out")"
grep -q 'unchanged failed integration' "$tmp/a-replay.out" \
  || fail "A: unchanged replay was not suppressed: $(cat "$tmp/a-replay.out")"
[[ "$(gate_runs capacity)" == 1 ]] || fail "A: unchanged replay reran the gate"
fix_target
integrate "$tmp/a-retry.out" --task TASK-0001 --run-id RUN-A-RETRY \
  || fail "A: ordinary retry after the target fix failed: $(cat "$tmp/a-retry.out")"
assert_integrated A TASK-0001 "$tmp/a-retry.out"

# ---- B: budget exhausted (the consumer's product 1/1) -> printed regate ------
build_fixture exhausted TASK-0002 1
integrate "$tmp/b-red.out" --task TASK-0002 --run-id RUN-B-RED \
  && fail "B: red target gate unexpectedly integrated"
assert_red_but_recoverable B TASK-0002 "$tmp/b-red.out"
fix_target
integrate "$tmp/b-plain.out" --task TASK-0002 --run-id RUN-B-PLAIN \
  || fail "B: exhausted ordinary retry did not stop cleanly: $(cat "$tmp/b-plain.out")"
grep -q 'product recovery budget is exhausted' "$tmp/b-plain.out" \
  || fail "B: exhausted ordinary retry lacked its durable reason: $(cat "$tmp/b-plain.out")"
[[ "$(gate_runs exhausted)" == 1 ]] || fail "B: exhausted ordinary retry reran the gate"
health="$("${engine_env[@]}" "$ROOT/engine/ops.sh" health --json 2>/dev/null)" || fail "B: health failed"
regate_command="$(python3 - "$health" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
candidate = next(c for c in doc["lifecycle"]["candidates"] if c["taskId"] == "TASK-0002")
assert candidate["state"] == "integration-failed", candidate
assert candidate["blockedReason"] == "gate-red", candidate
assert candidate["failureBudgets"]["product"] == candidate["failureLimits"]["product"] == 1, candidate
command = candidate["recoveryCommand"]
assert command.startswith("singular recover candidate TASK-0002 --action regate "), candidate
assert candidate["failureId"] in command, candidate
print(command)
PY
)" || fail "B: health did not expose the exact regate command"
grep -qF "$regate_command" "$tmp/b-plain.out" \
  || fail "B: the skipped integration did not print the same regate command: $(cat "$tmp/b-plain.out")"
"${engine_env[@]}" "$ROOT/engine/ops.sh" health 2>/dev/null | grep -qF "regate: $regate_command" \
  || fail "B: text health did not print the regate command"
# Run the printed commands verbatim.
regate_out="$("${engine_env[@]}" bash -c "$regate_command")" \
  || fail "B: the printed regate command was refused"
next_action="$(printf '%s\n' "$regate_out" | sed -n 's/^nextAction=//p')"
[[ "$next_action" == SINGULAR_RECOVERY_AUTHORIZATION_ID=*" singular integrate --task TASK-0002 --run-id "* ]] \
  || fail "B: regate did not print its bound integrate command: $regate_out"
"${engine_env[@]}" bash -c "$next_action" >"$tmp/b-regate.out" 2>&1 \
  || fail "B: authorized regate failed: $(cat "$tmp/b-regate.out")"
assert_integrated B TASK-0002 "$tmp/b-regate.out"
python3 - "$lease" <<'PY' || fail "B: regate accounting is wrong"
import json, sys
lease = json.load(open(sys.argv[1], encoding="utf-8"))
assert lease["failureBudgets"] == {"infrastructure": 0, "product": 1, "regate": 0}, lease
PY

# ---- C: state already written by 0.23.4 (header rolled back to ready) --------
# This reproduces the old engine's output, it is not a repair: the lease keeps
# the accepted hash and the file carries the committed `Status: ready`.
leave_0_23_4_state() {
  git -C "$repo" checkout -q -- "$1"
  grep -q '^Status: ready$' "$1" || fail "C: could not reproduce the 0.23.4 header rollback"
}
build_fixture legacy-retry TASK-0003 3
integrate "$tmp/c1-red.out" --task TASK-0003 --run-id RUN-C1-RED \
  && fail "C1: red target gate unexpectedly integrated"
leave_0_23_4_state "$task"
fix_target
integrate "$tmp/c1-retry.out" --task TASK-0003 --run-id RUN-C1-RETRY \
  || fail "C1: ordinary retry over a 0.23.4 lease failed: $(cat "$tmp/c1-retry.out")"
assert_integrated C1 TASK-0003 "$tmp/c1-retry.out"
grep -q 'integration.task_contract_restored' "$state/events.ndjson" \
  || fail "C1: restoring the bound header left no event"

build_fixture legacy-regate TASK-0004 1
integrate "$tmp/c2-red.out" --task TASK-0004 --run-id RUN-C2-RED \
  && fail "C2: red target gate unexpectedly integrated"
leave_0_23_4_state "$task"
fix_target
health="$("${engine_env[@]}" "$ROOT/engine/ops.sh" health --json 2>/dev/null)" || fail "C2: health failed"
regate_command="$(python3 -c 'import json,sys
print(next(c for c in json.loads(sys.argv[1])["lifecycle"]["candidates"] if c["taskId"]=="TASK-0004")["recoveryCommand"])' "$health")"
regate_out="$("${engine_env[@]}" bash -c "$regate_command")" \
  || fail "C2: regate over a 0.23.4 lease was refused"
"${engine_env[@]}" bash -c "$(printf '%s\n' "$regate_out" | sed -n 's/^nextAction=//p')" \
  >"$tmp/c2-regate.out" 2>&1 || fail "C2: authorized regate failed: $(cat "$tmp/c2-regate.out")"
assert_integrated C2 TASK-0004 "$tmp/c2-regate.out"

# The restore is exact-hash gated: a contract whose body changed is NOT healed
# and the strict verifiers keep refusing it.
build_fixture tampered TASK-0005 1
integrate "$tmp/d-red.out" --task TASK-0005 --run-id RUN-D-RED \
  && fail "D: red target gate unexpectedly integrated"
leave_0_23_4_state "$task"
printf '\n- `another-file.txt`\n' >>"$task"
tampered_sha="$(shasum -a 256 "$task" | awk '{print $1}')"
fix_target
if "${engine_env[@]}" "$ROOT/engine/recover.sh" candidate TASK-0005 --action regate \
    --successor-run RUN-D-REGATE --successor-branch agent/core/TASK-0005-feature \
    --successor-worktree "$repo/.worktrees/RUN-D-REGATE" >"$tmp/d-regate.out" 2>&1; then
  fail "D: regate accepted a task contract whose body changed"
fi
grep -q 'recovery task contract changed' "$tmp/d-regate.out" \
  || fail "D: changed contract was not refused for the right reason: $(cat "$tmp/d-regate.out")"
integrate "$tmp/d-plain.out" --task TASK-0005 --run-id RUN-D-PLAIN || true
if grep -q '^INTEGRATED' "$tmp/d-plain.out" \
    || git -C "$repo" merge-base --is-ancestor "$head" target; then
  fail "D: ordinary integration accepted a changed contract: $(cat "$tmp/d-plain.out")"
fi
[[ "$(gate_runs tampered)" == 1 ]] || fail "D: a changed contract reached the integration gate"
[[ "$(shasum -a 256 "$task" | awk '{print $1}')" == "$tampered_sha" ]] \
  || fail "D: a non-matching contract was rewritten"

echo "PASS: test-integration-gate-red-recovery"
