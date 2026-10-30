#!/usr/bin/env bash
set -euo pipefail

# The planner gets the real parser error and one repair (0.23.7). Field
# 2026-10-05: a planner wrote, under `Forbidden files:`, one bullet naming four
# backticked paths. The task parser rejected it; the batch validator swallowed
# the diagnostic and reported `batch/markdown task id mismatch: batch=TASK-0001
# markdown=`; the node failed planning three times (invalid-output twice, then
# terminal-lineage initial-planner-infra-exhausted) and the breaker reached 3/5.
# The planner here is a stub script; no provider is reached.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-planner-output-repair.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2' in: $1"; }

export SINGULAR_ROOT="$(mktemp -d)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp" "$SINGULAR_ROOT"' EXIT
root="$tmp/repo"
mkdir -p "$root/docs/orchestration/gates" "$root/docs/orchestration/prompts" \
  "$root/docs/orchestration/tasks" "$root/schemas/orchestration" "$root/.singular-state"
git -C "$root" init -q
git -C "$root" checkout -q -b target
cp "$ENGINE_HOME/templates/prompts/l1-planner.md" "$root/docs/orchestration/prompts/"
for s in task-batch dag gate-result l1-lease; do
  cp "$ENGINE_HOME/schemas/$s.v0.schema.json" "$root/schemas/orchestration/"
done
cat >"$root/docs/orchestration/dag.v0.json" <<'JSON'
{
  "schema": "singular.orchestration.dag.v0",
  "nodes": [
    { "id": "S0.base", "stage": "S0", "area": "storage", "layer": "substrate", "kind": "substrate", "dependsOn": [], "requiredCompletion": "ready" }
  ]
}
JSON
git -C "$root" add . && git -C "$root" -c user.name=t -c user.email=t@t commit -q -m init

export SINGULAR_ROOT="$root"
export SINGULAR_ORCH_DIR="$root/docs/orchestration"
export SINGULAR_TASKS_DIR="$SINGULAR_ORCH_DIR/tasks"
export SINGULAR_STATE_DIR="$root/.singular-state"
export SINGULAR_RUNS_DIR="$SINGULAR_STATE_DIR/runs"
export SINGULAR_LEASES_DIR="$SINGULAR_STATE_DIR/leases"
export SINGULAR_L1_LEASES_DIR="$SINGULAR_STATE_DIR/l1-leases"
export SINGULAR_EVENTS_FILE="$SINGULAR_STATE_DIR/events.ndjson"
export SINGULAR_TARGET_BRANCH=target
export SINGULAR_TASKBATCH_SCHEMA="$root/schemas/orchestration/task-batch.v0.schema.json"
export SINGULAR_PLAN_CRITIQUE=0 SINGULAR_PLANNER_SESSION=0
export SINGULAR_CODEX_BIN=/usr/bin/false

# A task batch whose single task has the given Forbidden-files bullet.
batch() {
  python3 - "$1" <<'PY'
import json, sys
forbidden = sys.argv[1]
markdown = f"""# TASK-0001: Storage substrate

Status: ready
Area: storage
DAG node: S0.base
Target branch: `target`
Worker branch: `agent/storage/TASK-0001-substrate`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Build the substrate.

## Scope

Owned files:

- `src/storage/base.ts`

Forbidden files:

{forbidden}

## Acceptance Criteria

- The gate command passes.
"""
print(json.dumps({"schema": "singular.orchestration.task-batch.v0",
                  "tasks": [{"taskId": "TASK-0001", "markdown": markdown}]}))
PY
}
BAD='- Any file outside the owned scope, including `A.tsx`, `B.tsx`, `C.tsx` and `d.ts`.'
GOOD='- Any file outside the owned scope.'

# The stub planner: answer N comes from $tmp/answer-N.json; every call is
# counted and its prompt kept.
stub="$tmp/planner.sh"
cat >"$stub" <<SH
#!/usr/bin/env bash
out=""; prompt=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --output-last-message) out="\$2"; shift 2 ;;
    --prompt-file) prompt="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
n=\$(( \$(cat "$tmp/calls" 2>/dev/null || echo 0) + 1 ))
echo "\$n" >"$tmp/calls"
[[ -z "\$prompt" ]] || cp "\$prompt" "$tmp/prompt-\$n.md"
answer="$tmp/answer-\$n.json"
[[ -f "\$answer" ]] || answer="$tmp/answer-last.json"
[[ -n "\$out" ]] && cat "\$answer" >"\$out"
cat "\$answer"
SH
chmod +x "$stub"
calls() { cat "$tmp/calls" 2>/dev/null || echo 0; }
reset() { rm -f "$tmp"/calls "$tmp"/answer-*.json "$tmp"/prompt-*.md; : >"$SINGULAR_EVENTS_FILE"; }
plan() { # <run> [env...]: staged planning of S0.base
  local run="$1"; shift
  env "$@" SINGULAR_CODEX_RUNNER="$stub" SINGULAR_RUNNER="$stub" \
    "$SCRIPT_DIR/generate-tasks.sh" --node S0.base \
    --stage-dir "$SINGULAR_STATE_DIR/runs/$run/l1-staging/S0.base" --count 1 2>&1
}
events() { cat "$SINGULAR_EVENTS_FILE" 2>/dev/null || true; }

# --- 0. the validator reports the parser's own diagnostic --------------------
batch "$BAD" >"$tmp/bad.json"
rc=0
err="$(singular_task_batch_materialize "$tmp/bad.json" "$tmp/norm.json" "$tmp/cand" storage \
  '["TASK-0001"]' assign "$SINGULAR_TASKBATCH_SCHEMA" 2>&1 >/dev/null)" || rc=$?
assert_eq "$rc" "2" "a batch the task parser rejects is invalid"
assert_contains "$err" "task-parser:" "the parser's diagnostic is surfaced"
assert_contains "$err" "scope entry has malformed or multiple backtick spans" "the exact parser rule is named"
assert_contains "$err" "TASK-0001.md:" "the diagnostic names the task and line, not a private path"
assert_not_contains "$err" "markdown task id mismatch" "the misleading id-mismatch message is gone"
assert_not_contains "$err" "$tmp" "no host path leaks into the diagnostic"
echo "ok: the batch validator surfaces the task parser's diagnostic"

# --- 1. one repair round: the planner fixes its own output -------------------
reset
batch "$BAD" >"$tmp/answer-1.json"
batch "$GOOD" >"$tmp/answer-2.json"
rc=0; out="$(plan RUN-R1)" || rc=$?
assert_eq "$rc" "0" "a repaired batch is a successful plan ($out)"
assert_eq "$(calls)" "2" "exactly one repair invocation"
assert_contains "$out" "staged:TASK-" "the repaired task is staged"
assert_not_contains "$out" "planner-failed" "no planner failure is reported"
ev="$(events)"
assert_contains "$ev" '"type":"planner.output_repair_requested"' "repair request event"
assert_contains "$ev" "scope entry has malformed or multiple backtick spans" "the event carries the diagnostic"
assert_contains "$ev" '"type":"planner.output_repaired"' "repaired event"
assert_not_contains "$ev" '"type":"planner.failed"' "no planner.failed before the repair is exhausted"
repair_prompt="$(cat "$tmp/prompt-2.md")"
assert_contains "$repair_prompt" "scope entry has malformed or multiple backtick spans" "the planner is shown the exact error"
assert_contains "$repair_prompt" 'including `A.tsx`, `B.tsx`, `C.tsx` and `d.ts`' "the planner is shown its own output"
assert_contains "$repair_prompt" "EXACTLY ONE repository-relative path" "the planner is shown the rule"
staged="$(find "$SINGULAR_STATE_DIR/runs/RUN-R1/l1-staging/S0.base" -name 'TASK-*.candidate.md' | head -1)"
[[ -n "$staged" ]] || fail "no staged candidate after repair"
grep -q '^- Any file outside the owned scope\.$' "$staged" || fail "the staged candidate is not the repaired one"
echo "ok: a malformed batch is repaired in one round with the real diagnostic"

# --- 2. still malformed after the round: a distinct failure class -------------
reset
batch "$BAD" >"$tmp/answer-last.json"
rc=0; out="$(plan RUN-R2)" || rc=$?
assert_eq "$rc" "4" "malformed output after the repair round exits 4"
assert_eq "$(calls)" "2" "the repair is bounded to one round"
assert_contains "$out" "planner-failed (malformed-output: " "the failure line names the class"
assert_contains "$out" "scope entry has malformed or multiple backtick spans" "the failure line carries the diagnostic"
ev="$(events)"
failed="$(grep '"type":"planner.failed"' "$SINGULAR_EVENTS_FILE" | tail -1)"
assert_contains "$failed" '"failureClass":"malformed-output"' "planner.failed is classified malformed-output"
assert_contains "$failed" '"failureDomain":"planner-output"' "the domain is the planner's output, not the provider"
assert_contains "$failed" '"repairOutcome":"still-malformed"' "the event records the repair outcome"
assert_contains "$failed" "scope entry has malformed or multiple backtick spans" "the event carries the diagnostic"
assert_eq "$(grep -c '"type":"planner.failed"' "$SINGULAR_EVENTS_FILE")" "1" "one failure event, after the repair"
[[ ! -f "$SINGULAR_STATE_DIR/planner-backoff.json" ]] || fail "malformed output must not arm a provider backoff"
echo "ok: malformed output after one repair is a malformed-output failure with the diagnostic"

# --- 3. the knob; and a provider failure during repair is not 'malformed' -----
reset
batch "$BAD" >"$tmp/answer-last.json"
rc=0; out="$(plan RUN-R3 SINGULAR_PLANNER_OUTPUT_REPAIR=0)" || rc=$?
assert_eq "$rc $(calls)" "4 1" "SINGULAR_PLANNER_OUTPUT_REPAIR=0 disables the round"
assert_contains "$(grep '"type":"planner.failed"' "$SINGULAR_EVENTS_FILE" | tail -1)" '"repairOutcome":"disabled"' "disabled is recorded"
reset
batch "$BAD" >"$tmp/answer-1.json"
failing="$tmp/planner-fail-on-2.sh"
cat >"$failing" <<SH
#!/usr/bin/env bash
if [[ "\$(cat "$tmp/calls" 2>/dev/null || echo 0)" -ge 1 ]]; then
  echo "\$(( \$(cat "$tmp/calls") + 1 ))" >"$tmp/calls"
  echo "provider exploded" >&2; exit 9
fi
exec "$stub" "\$@"
SH
chmod +x "$failing"
rc=0; out="$(env SINGULAR_CODEX_RUNNER="$failing" SINGULAR_RUNNER="$failing" \
  "$SCRIPT_DIR/generate-tasks.sh" --node S0.base \
  --stage-dir "$SINGULAR_STATE_DIR/runs/RUN-R4/l1-staging/S0.base" --count 1 2>&1)" || rc=$?
assert_eq "$rc" "1" "a provider failure during repair is an ordinary planner failure (rc 1)"
assert_not_contains "$(grep '"type":"planner.failed"' "$SINGULAR_EVENTS_FILE" | tail -1)" '"failureClass":"malformed-output"' \
  "a provider failure is not classified as malformed output"
assert_contains "$(grep '"type":"planner.failed"' "$SINGULAR_EVENTS_FILE" | tail -1)" '"stage":"output-repair"' "the stage is named"
echo "ok: the repair round is a knob, and a provider failure keeps its own class"

# --- 4. a valid batch is untouched: no repair, one call ------------------------
reset
batch "$GOOD" >"$tmp/answer-last.json"
rc=0; out="$(plan RUN-R5)" || rc=$?
assert_eq "$rc $(calls)" "0 1" "a valid batch needs no repair"
assert_not_contains "$(events)" "output_repair" "no repair event on a valid batch"
echo "ok: a valid batch is planned in one call"

# --- 5. the node driver does not spend its infra retry on malformed output ----
reset
batch "$BAD" >"$tmp/answer-last.json"
sdir="$SINGULAR_STATE_DIR/runs/RUN-N1/l1-staging/S0.base"
mkdir -p "$sdir"
rc=0
out="$(env SINGULAR_CODEX_RUNNER="$stub" SINGULAR_RUNNER="$stub" \
  "$SCRIPT_DIR/l1-plan-node.sh" --node S0.base --run-id RUN-N1 --stage-dir "$sdir" \
  --base-sha "$(git -C "$root" rev-parse target)" --count 1 2>&1)" || rc=$?
assert_eq "$rc" "4" "the node driver reports malformed planner output with its own exit code ($out)"
assert_contains "$out" "plan-failed:S0.base (planner-output-malformed: malformed-output: " "the node failure line names the class"
assert_contains "$out" "scope entry has malformed or multiple backtick spans" "and carries the diagnostic"
assert_eq "$(calls)" "2" "one planner call plus one repair: no infrastructure retry was spent"
assert_not_contains "$(events)$out" "initial-planner-infra-exhausted" "malformed output is not recorded as infrastructure exhaustion"
assert_not_contains "$(events)" "ctx.plan_initial_infra_retry" "no infrastructure retry event"
echo "ok: the node driver classifies malformed planner output distinctly from infrastructure"
echo "PASS: test-planner-output-repair"
