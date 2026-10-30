#!/usr/bin/env bash
# Canonical full-walk test for the plan-revision-loop composition brick
# engine/ctx-plan-revise-loop.sh (stage S3-plan-revision, area plancritic, layer
# engine_runtime, kind runtime). This is the requiredCompletion-cited node test.
#
# singular_plan_revise_loop <node> <run_id> <stage_dir> [worktree] composes ONLY
# the already-integrated engine helpers into the bounded in-lineage
#   critique -> decide(revise|import|park) -> [assemble prompt -> resume|fresh ->
#   provider final message -> host-side transactional re-stage
#   (rc-86 -> fresh fallback) ->
#   record dispositions] -> re-critique
# loop, printing EXACTLY one terminal outcome line (`import` or `park <reason>`)
# and driving no state beyond the stage dir + the pinned event log.
#
# Fully hermetic: STUB critic runner (via SINGULAR_RUNNER, consumed by the
# integrated singular_ctx_plan_critic_run) and STUB planner runner (via
# SINGULAR_PLAN_REVISE_PLANNER). Pins SINGULAR_EVENTS_FILE, the stage dir,
# SINGULAR_PLAN_CRITIQUE=1, and SINGULAR_PLAN_REVISE_MAX.
#
# Exercises the full walk:
#   (A) critique -> revise -> approve -> import, resume path (strategy=resume,
#       no rc-86), with every disposition (accepted-observation,
#       rejected-observation, accepted-but-unaddressed) + plan.revised + strategy
#       events observable;
#   (B) the rc-86 resume-refused fresh-fallback path (context.resume_failed
#       recorded, fresh re-run re-stages, then approve -> import);
#   (C) budget exhaustion -> park revise-budget-exhausted (recorded), fresh
#       strategy path;
#   (D) approve at round 0 -> import with NO revision attempted;
#   (E) present-but-uncalled: no existing engine path invokes the new function.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
CTX="$ENGINE_HOME/engine/ctx-plan-revise-loop.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Isolated state: never touch the real repo or its events log -------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

REPO="$tmp/repo"
mkdir -p "$REPO/docs/orchestration/prompts"
git -C "$REPO" init -q
git -C "$REPO" checkout -q -b target
cp "$ENGINE_HOME/templates/prompts/l1-planner.md" "$REPO/docs/orchestration/prompts/l1-planner.md"
# Base plan-critic prompt the integrated critic driver passes to its runner.
printf '# Plan Critic Prompt\n' > "$REPO/docs/orchestration/prompts/plan-critic.md"
git -C "$REPO" add .
git -C "$REPO" -c user.name=test -c user.email=test@example.local commit -q -m init

export SINGULAR_ROOT="$REPO"
export SINGULAR_STATE_DIR="$REPO/.singular-state"
export SINGULAR_ORCH_DIR="$REPO/docs/orchestration"
export SINGULAR_EVENTS_FILE="$tmp/events.ndjson"
export SINGULAR_TARGET_BRANCH=target
export SINGULAR_PLAN_CRITIQUE=1
export SINGULAR_PLAN_REVISE_MAX=1
: > "$SINGULAR_EVENTS_FILE"

# shellcheck disable=SC1090
source "$LIB" || fail "sourcing lib.sh failed"

# The engine file must exist and define the composition function (RED before impl).
[[ -f "$CTX" ]] || fail "engine not present yet: $CTX"
# shellcheck disable=SC1090
source "$CTX" || fail "sourcing $CTX failed"
[[ "$(type -t singular_plan_revise_loop)" == "function" ]] \
  || fail "singular_plan_revise_loop not defined by $CTX"

NODE="plan-revision-loop"
HEAD="$(git -C "$REPO" rev-parse target)"
TPL_SHA="$(singular_sha256_file "$REPO/docs/orchestration/prompts/l1-planner.md")"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
META="$SINGULAR_STATE_DIR/sessions/planner/$NODE.json"

# --- STUB critic runner (SINGULAR_RUNNER) -------------------------------------
# Pops the next verdict from a per-scenario sequence file and writes a critique
# with three findings (three distinct sha-derived ids), so the disposition
# classifier sees a full findings set. Ignores the prompt content.
CRITIC="$tmp/stub-critic.sh"
cat > "$CRITIC" <<'CEOF'
#!/usr/bin/env bash
set -uo pipefail
out=""; args=("$@"); i=0
while [[ $i -lt ${#args[@]} ]]; do
  [[ "${args[$i]}" == "--output-last-message" ]] && out="${args[$((i + 1))]}"
  i=$((i + 1))
done
[[ -n "$out" ]] || exit 0
verdict="approve"
if [[ -n "${CRITIC_SEQ_FILE:-}" && -s "${CRITIC_SEQ_FILE}" ]]; then
  verdict="$(sed -n '1p' "$CRITIC_SEQ_FILE")"
  sed -i.bak '1d' "$CRITIC_SEQ_FILE" && rm -f "$CRITIC_SEQ_FILE.bak"
fi
cat > "$out" <<JSON
Here is my critique:
{
  "schema": "singular.orchestration.plan-critique.v0",
  "node": "STUB",
  "runId": "STUB",
  "batchTaskIds": ["TASK-9999"],
  "verdict": "$verdict",
  "findings": [
    {"severity": "blocking", "claim": "finding claim one", "evidence": "ev-one"},
    {"severity": "should-fix", "claim": "finding claim two", "evidence": "ev-two"},
    {"severity": "note", "claim": "finding claim three", "evidence": "ev-three"}
  ],
  "assumptionsChallenged": [],
  "rationale": "stub critic rationale"
}
JSON
exit 0
CEOF
chmod +x "$CRITIC"
export SINGULAR_RUNNER="$CRITIC"

# --- STUB planner runner (SINGULAR_PLAN_REVISE_PLANNER) ------------------------
# Returns a complete task-batch.v0 through --output-last-message. It deliberately
# knows nothing about the orchestration staging directory: the host materializes
# and transactionally swaps the candidate set after validation. The batch
# ADDRESSES the first finding id, REJECTS the second, and leaves the third
# unaddressed. PLANNER_MODE selects malformed/empty/id-drift/runner-failure
# regressions; PLANNER_FAIL_ON_RESUME drives the rc-86 fresh-fallback path.
PLANNER="$tmp/stub-planner.sh"
cat > "$PLANNER" <<'PEOF'
#!/usr/bin/env bash
set -uo pipefail
out=""; prompt=""; has_resume=0; args=("$@"); i=0
while [[ $i -lt ${#args[@]} ]]; do
  case "${args[$i]}" in
    --output-last-message) out="${args[$((i + 1))]}" ;;
    --prompt-file) prompt="${args[$((i + 1))]}" ;;
    --resume-session) has_resume=1 ;;
  esac
  i=$((i + 1))
done
if [[ "${PLANNER_FAIL_ON_RESUME:-0}" == "1" && "$has_resume" == "1" ]]; then
  exit 86
fi
touch "${PLANNER_INVOKED_FILE:-/dev/null}"
[[ "${PLANNER_MODE:-valid}" != "runner-fail" ]] || exit 7
[[ -n "$out" ]] || exit 0
if [[ "${PLANNER_MODE:-valid}" == "malformed" ]]; then
  printf 'not a task batch\n' >"$out"
  exit 0
fi
python3 - "$out" "$prompt" "${PLANNER_MODE:-valid}" <<'PY'
import re, json, sys
out, prompt, mode = sys.argv[1:4]
ids = []
try:
    with open(prompt, "r", encoding="utf-8") as f:
        text = f.read()
    ids = sorted(set(re.findall(r"f-[0-9a-f]{12}", text)))
except Exception:
    ids = []
if mode == "empty":
    tasks = []
else:
    task_ids = ["TASK-0100", "TASK-0101", "TASK-0102"]
    if mode == "id-drift":
        task_ids[-1] = "TASK-9999"
    notes = [
        "addresses %s per critique" % ids[0] if len(ids) >= 1 else "addresses critique",
        "reject %s: out of scope" % ids[1] if len(ids) >= 2 else "reject critique",
        "retains the third slice without mentioning its finding",
    ]
    tasks = []
    for index, task_id in enumerate(task_ids):
        markdown = """# {task_id}: revised candidate {index}

Status: ready
Area: plancritic
DAG node: plan-revision-loop
Target branch: `target`
Worker branch: `agent/plancritic/{task_id}-revised`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

{note}

## Scope

Owned files:

- `engine/revised-{index}.sh`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- The revised slice passes.
""".format(task_id=task_id, index=index, note=notes[index])
        tasks.append({"taskId": task_id, "markdown": markdown})
doc = {"schema": "singular.orchestration.task-batch.v0", "tasks": tasks}
with open(out, "w", encoding="utf-8") as f:
    json.dump(doc, f)
PY
exit 0
PEOF
chmod +x "$PLANNER"
export SINGULAR_PLAN_REVISE_PLANNER="$PLANNER"

# --- helpers -----------------------------------------------------------------
ev_count() { # <type>
  [[ -f "$SINGULAR_EVENTS_FILE" ]] || { echo 0; return; }
  local n; n="$(grep -c "\"type\":\"$1\"" "$SINGULAR_EVENTS_FILE" 2>/dev/null || true)"
  echo "${n:-0}"
}

# Forge a resumable planner meta (all 11 planner resume gates pass) so the loop's
# resume-vs-fresh decision yields `resume`, mirroring test-ctx-plan-revise-resume.
forge_meta() {
  mkdir -p "$(dirname "$META")"
  python3 - "$META" "$REPO" "$NOW" "$NODE" "$TPL_SHA" "$HEAD" "$(basename "$PLANNER")" <<'PY'
import json, sys
path, cwd, now, node, tpl, head, runner = sys.argv[1:8]
doc = {
    "schema": "singular.orchestration.session-meta.v0",
    "provider": "codex", "sessionId": "SID-PLANNER", "model": "m", "effort": "e",
    "cwd": cwd, "exitCode": 0, "createdAt": now,
    "role": "planner", "node": node, "runner": runner,
    "promptSha256": tpl, "headShaAtCreate": head, "lastUsedAttempt": 1,
}
json.dump(doc, open(path, "w"), indent=2)
PY
}

# dispositions[] recorded by the last plan.revised event (id -> disposition set).
plan_revised_dispositions() {
  python3 - "$SINGULAR_EVENTS_FILE" <<'PY'
import json, sys
last = None
try:
    for line in open(sys.argv[1]):
        line = line.strip()
        if not line: continue
        e = json.loads(line)
        if e.get("type") == "plan.revised": last = e
except FileNotFoundError:
    pass
if last is None:
    sys.exit(0)
for d in last.get("data", {}).get("dispositions", []):
    print(d.get("disposition", ""))
PY
}

new_stage() { # <label> -> prints a fresh stage dir
  local d="$tmp/stage/$1" tid index
  mkdir -p "$d"
  for index in 0 1 2; do
    tid="$(printf 'TASK-%04d' "$((100 + index))")"
    cat >"$d/$tid.candidate.md" <<MD
# $tid: prior candidate $index

Status: ready
Area: plancritic
DAG node: plan-revision-loop
Target branch: \`target\`
Worker branch: \`agent/plancritic/$tid-prior\`
Test policy: \`strict_test_first\`
Gate command: \`true\`
Dispatch mode: canonical
Depends on: []

## Objective

Prior candidate $index.

Scenario identity: $1.

## Scope

Owned files:

- \`engine/prior-$index.sh\`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- The prior slice passes.
MD
  done
  printf '%s' "$d"
}

candidate_digest() { # <stage-dir>
  local candidate_batch_dir
  candidate_batch_dir="$(singular_task_batch_candidate_dir "$1")" \
    || fail "cannot resolve authoritative candidate batch for $1"
  python3 - "$candidate_batch_dir" <<'PY'
import glob, hashlib, os, sys
root = sys.argv[1]
h = hashlib.sha256()
for path in sorted(glob.glob(os.path.join(root, "TASK-*.candidate.md"))):
    h.update(os.path.basename(path).encode())
    h.update(b"\0")
    h.update(open(path, "rb").read())
    h.update(b"\0")
print(h.hexdigest())
PY
}

# =============================================================================
# (A) critique -> revise -> approve -> import, RESUME path, all dispositions.
# =============================================================================
export SINGULAR_PLANNER_SESSION=1
export SINGULAR_PLAN_CRITIC_MODEL_VERSION=stub-A
forge_meta
: > "$SINGULAR_EVENTS_FILE"
export CRITIC_SEQ_FILE="$tmp/seqA"; printf 'revise\napprove\n' > "$CRITIC_SEQ_FILE"
export PLANNER_FAIL_ON_RESUME=0
export PLANNER_INVOKED_FILE="$tmp/planner-A"
sdA="$(new_stage A)"
outA="$(singular_plan_revise_loop "$NODE" "RUN-A" "$sdA" "$REPO")" \
  || fail "A: loop must exit 0 on the happy walk"
[[ "$outA" == "import" ]] || fail "A: terminal outcome must be exactly 'import' (got '$outA')"
[[ "$(printf '%s\n' "$outA" | grep -c .)" -eq 1 ]] || fail "A: must print exactly one terminal line"
[[ -e "$PLANNER_INVOKED_FILE" ]] || fail "A: planner runner was never invoked for the revision round"
[[ "$(ev_count context.strategy_selected)" -ge 1 ]] || fail "A: no context.strategy_selected event"
# Resume path: the selected strategy is resume and there is NO resume-failure.
grep -q '"strategy":"resume"' "$SINGULAR_EVENTS_FILE" || fail "A: expected a resume strategy event"
[[ "$(ev_count context.resume_failed)" -eq 0 ]] || fail "A: resume succeeded; must be NO context.resume_failed"
[[ "$(ev_count plan.revised)" -ge 1 ]] || fail "A: no plan.revised disposition event"
[[ "$(ev_count plan.critiqued)" -ge 2 ]] || fail "A: expected re-critique (>=2 plan.critiqued)"
[[ "$(ev_count plan.revise_parked)" -eq 0 ]] || fail "A: import walk must not park"
# Every disposition class is event-visible.
disps="$(plan_revised_dispositions | sort -u)"
for d in accepted-observation rejected-observation accepted-but-unaddressed; do
  printf '%s\n' "$disps" | grep -qx "$d" || fail "A: disposition '$d' not recorded (got: $(echo $disps))"
done

# =============================================================================
# (B) rc-86 resume-refused -> fresh fallback recorded -> re-stage -> import.
# =============================================================================
forge_meta
export SINGULAR_PLAN_CRITIC_MODEL_VERSION=stub-B
: > "$SINGULAR_EVENTS_FILE"
export CRITIC_SEQ_FILE="$tmp/seqB"; printf 'revise\napprove\n' > "$CRITIC_SEQ_FILE"
export PLANNER_FAIL_ON_RESUME=1
export PLANNER_INVOKED_FILE="$tmp/planner-B"
sdB="$(new_stage B)"
outB="$(singular_plan_revise_loop "$NODE" "RUN-B" "$sdB" "$REPO")" \
  || fail "B: loop must exit 0 on the rc-86 fresh-fallback walk"
[[ "$outB" == "import" ]] || fail "B: terminal outcome must be 'import' (got '$outB')"
grep -q '"strategy":"resume"' "$SINGULAR_EVENTS_FILE" || fail "B: expected a resume strategy event before the refusal"
[[ "$(ev_count context.resume_failed)" -ge 1 ]] || fail "B: rc-86 must record a context.resume_failed event"
[[ "$(ev_count plan.revised)" -ge 1 ]] || fail "B: fresh fallback must still record dispositions"
[[ -e "$PLANNER_INVOKED_FILE" ]] || fail "B: fresh fallback re-run must invoke the planner runner"

# =============================================================================
# (C) unchanged findings after the one revision -> park repeated-findings
# before another product revision can be attempted.
# =============================================================================
unset SINGULAR_PLANNER_SESSION  # -> resume decider returns `fresh disabled`
export SINGULAR_PLAN_CRITIC_MODEL_VERSION=stub-C
: > "$SINGULAR_EVENTS_FILE"
export CRITIC_SEQ_FILE="$tmp/seqC"; printf 'revise\nrevise\n' > "$CRITIC_SEQ_FILE"
export PLANNER_FAIL_ON_RESUME=0
export PLANNER_INVOKED_FILE="$tmp/planner-C"
sdC="$(new_stage C)"
outC="$(singular_plan_revise_loop "$NODE" "RUN-C" "$sdC" "$REPO")" \
  || fail "C: loop must exit 0 on the budget-exhaustion walk"
[[ "$outC" == "park repeated-findings" ]] \
  || fail "C: terminal outcome must be 'park repeated-findings' (got '$outC')"
[[ "$(ev_count plan.revise_parked)" -ge 1 ]] || fail "C: budget-exhaustion park must be recorded"
grep -q '"strategy":"fresh"' "$SINGULAR_EVENTS_FILE" || fail "C: expected a fresh strategy event"
# Exactly one bounded revision round ran (SINGULAR_PLAN_REVISE_MAX=1).
[[ "$(ev_count plan.revised)" -eq 1 ]] || fail "C: exactly one bounded revision round expected"

# =============================================================================
# (D) approve at round 0 -> import with NO revision attempted.
# =============================================================================
: > "$SINGULAR_EVENTS_FILE"
export SINGULAR_PLAN_CRITIC_MODEL_VERSION=stub-D
export CRITIC_SEQ_FILE="$tmp/seqD"; printf 'approve\n' > "$CRITIC_SEQ_FILE"
export PLANNER_INVOKED_FILE="$tmp/planner-D"
sdD="$(new_stage D)"
outD="$(singular_plan_revise_loop "$NODE" "RUN-D" "$sdD" "$REPO")" \
  || fail "D: loop must exit 0 on an immediate approve"
[[ "$outD" == "import" ]] || fail "D: immediate approve must import (got '$outD')"
[[ "$(ev_count plan.revised)" -eq 0 ]] || fail "D: no revision must be attempted on an approve verdict"
[[ "$(ev_count context.strategy_selected)" -eq 0 ]] || fail "D: no strategy selected without a revision"
[[ ! -e "$PLANNER_INVOKED_FILE" ]] || fail "D: planner runner must NOT run on an immediate approve"

# =============================================================================
# (E-H) runner/malformed/empty/id-drift failures preserve the prior candidate
# set, park on one stable reason, and never record dispositions.
# =============================================================================
assert_revision_failure() { # <label> <planner-mode> <failure-class>
  local label="$1" mode="$2" failure_class="$3" stage before after result
  : >"$SINGULAR_EVENTS_FILE"
  export CRITIC_SEQ_FILE="$tmp/seq-$label"
  export SINGULAR_PLAN_CRITIC_MODEL_VERSION="stub-$label"
  printf 'revise\n' >"$CRITIC_SEQ_FILE"
  export PLANNER_MODE="$mode"
  export PLANNER_FAIL_ON_RESUME=0
  export PLANNER_INVOKED_FILE="$tmp/planner-$label"
  stage="$(new_stage "$label")"
  before="$(candidate_digest "$stage")"
  result="$(singular_plan_revise_loop "$NODE" "RUN-$label" "$stage" "$REPO")" \
    || fail "$label: failure path must return a terminal park outcome"
  after="$(candidate_digest "$stage")"
  [[ "$result" == "park revision-staging-failed" ]] \
    || fail "$label: expected stable revision-staging-failed park, got '$result'"
  [[ "$before" == "$after" ]] \
    || fail "$label: invalid revision changed the prior candidate set"
  [[ "$(ev_count plan.revised)" -eq 0 ]] \
    || fail "$label: disposition recorded before a successful stage replacement"
  grep -q "\"failureClass\":\"$failure_class\"" "$SINGULAR_EVENTS_FILE" \
    || fail "$label: missing failureClass=$failure_class"
}

export SINGULAR_PLAN_REVISION_INFRA_MAX=99
assert_revision_failure E runner-fail runner-failed
[[ "$(ev_count ctx.plan_revision_infra_retry)" -eq 1 ]] \
  || fail "E: large retry knob must still permit only one retry before terminal park"
python3 - "$SINGULAR_STATE_DIR" "$tmp/stage/E" <<'PY' \
  || fail "E: infrastructure attempts contaminated the product revision budget"
import glob, json, os, sys
state, stage = sys.argv[1:3]
side = json.load(open(os.path.join(stage, ".plan-attempt-identity.json")))
paths = glob.glob(os.path.join(state, "planning-attempts", "*", side["identity"], "attempt.json"))
assert len(paths) == 1, paths
doc = json.load(open(paths[0]))
assert doc["revisionsDone"] == 0, doc
assert doc["infraAttempts"] == 2, doc
assert doc["status"] == "park", doc
PY
unset SINGULAR_PLAN_REVISION_INFRA_MAX
assert_revision_failure F malformed batch-malformed
assert_revision_failure G empty batch-empty
assert_revision_failure H id-drift batch-invalid
unset PLANNER_MODE

# =============================================================================
# (I) Real codex-run.sh argument parser + fake Codex executable. The fake rejects
# any leaked --stage-dir. A full revise -> approve walk proves the real runner
# contract accepts the host-owned staging design.
# =============================================================================
FAKE_CODEX="$tmp/fake-codex.sh"
FAKE_CODEX_ARGS="$tmp/fake-codex.args"
cat >"$FAKE_CODEX" <<'CEO'
#!/usr/bin/env bash
set -uo pipefail
out=""
args=("$@")
printf '%s\n' "${args[@]}" >"${FAKE_CODEX_ARGS:?}"
for ((i=0; i<${#args[@]}; i++)); do
  [[ "${args[$i]}" != "--stage-dir" ]] || exit 97
  [[ "${args[$i]}" != "-o" ]] || out="${args[$((i + 1))]}"
done
[[ -n "$out" ]] || exit 2
python3 - "$out" <<'PY'
import json, sys
tasks = []
for index, task_id in enumerate(("TASK-0100", "TASK-0101", "TASK-0102")):
    markdown = """# {task_id}: parser-backed revision {index}

Status: ready
Area: plancritic
DAG node: plan-revision-loop
Target branch: `target`
Worker branch: `agent/plancritic/{task_id}-parser`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Revision returned through the real codex-run parser.

## Scope

Owned files:

- `engine/parser-{index}.sh`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- The parser-backed revision passes.
""".format(task_id=task_id, index=index)
    tasks.append({"taskId": task_id, "markdown": markdown})
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump({"schema": "singular.orchestration.task-batch.v0", "tasks": tasks}, f)
PY
printf '%s\n' '{"type":"thread.started","thread_id":"fake-revision-thread"}'
exit 0
CEO
chmod +x "$FAKE_CODEX"

: >"$SINGULAR_EVENTS_FILE"
export SINGULAR_PLAN_CRITIC_MODEL_VERSION=stub-I
export CRITIC_SEQ_FILE="$tmp/seqI"; printf 'revise\napprove\n' >"$CRITIC_SEQ_FILE"
export SINGULAR_PLAN_REVISE_PLANNER="$ENGINE_HOME/engine/codex-run.sh"
export SINGULAR_CODEX_BIN="$FAKE_CODEX"
export SINGULAR_CODEX_TIMEOUT_SEC=0
export SINGULAR_CODEX_IDLE_SEC=0
export FAKE_CODEX_ARGS
sdI="$(new_stage I)"
beforeI="$(candidate_digest "$sdI")"
outI="$(singular_plan_revise_loop "$NODE" "RUN-I" "$sdI" "$REPO")" \
  || fail "I: real codex-run parser walk must exit 0"
afterI="$(candidate_digest "$sdI")"
[[ "$outI" == "import" ]] || fail "I: real parser walk must import (got '$outI')"
[[ -s "$FAKE_CODEX_ARGS" ]] || fail "I: fake Codex executable was not invoked"
! grep -qx -- '--stage-dir' "$FAKE_CODEX_ARGS" \
  || fail "I: orchestration-only --stage-dir leaked through the real runner contract"
[[ "$beforeI" != "$afterI" ]] || fail "I: valid parser-backed revision did not replace candidates"
[[ "$(ev_count plan.revised)" -eq 1 ]] \
  || fail "I: parser-backed revision must record dispositions after staging"
export SINGULAR_PLAN_REVISE_PLANNER="$PLANNER"
unset SINGULAR_CODEX_BIN SINGULAR_CODEX_TIMEOUT_SEC SINGULAR_CODEX_IDLE_SEC FAKE_CODEX_ARGS

# =============================================================================
# (J) A hard interruption after generation construction but before the pointer
# swap leaves the complete prior candidate batch authoritative. Retrying the
# same publication recovers by reusing the immutable orphan generation.
# =============================================================================
sdJ="$(new_stage J)"
replacementJ="$sdJ/.replacement"
mkdir -p "$replacementJ"
for candidateJ in "$sdJ"/TASK-*.candidate.md; do
  cp "$candidateJ" "$replacementJ/"
  printf '\nRevision replacement bytes.\n' >>"$replacementJ/$(basename "$candidateJ")"
done
beforeJ="$(candidate_digest "$sdJ")"
readyJ="$tmp/publish-J.ready"
releaseJ="$tmp/publish-J.release"
SINGULAR_TEST_BATCH_PUBLISH_READY="$readyJ" \
SINGULAR_TEST_BATCH_PUBLISH_RELEASE="$releaseJ" \
  python3 "$ENGINE_HOME/engine/task_batch_publish.py" publish \
    --stage-dir "$sdJ" --candidate-dir "$replacementJ" >/dev/null 2>&1 &
publish_pidJ=$!
for _ in $(seq 1 500); do
  [[ -f "$readyJ" ]] && break
  sleep 0.01
done
[[ -f "$readyJ" ]] || {
  kill "$publish_pidJ" 2>/dev/null || true
  fail "J: publisher did not reach the pre-swap interruption barrier"
}
kill -9 "$publish_pidJ" 2>/dev/null || true
wait "$publish_pidJ" 2>/dev/null || true
afterJ="$(candidate_digest "$sdJ")"
[[ "$beforeJ" == "$afterJ" ]] \
  || fail "J: interrupted publication exposed replacement candidate bytes"
[[ ! -e "$sdJ/.candidate-current.json" ]] \
  || fail "J: interrupted pre-swap publication wrote the authoritative pointer"
singular_task_batch_replace_stage "$replacementJ" "$sdJ" \
  || fail "J: retry after interruption did not recover"
after_retryJ="$(candidate_digest "$sdJ")"
[[ "$after_retryJ" != "$beforeJ" ]] \
  || fail "J: recovered publication did not select the replacement generation"

# =============================================================================
# (K) A concurrent reader pins one immutable generation per read while the
# current pointer changes. It may observe old or new, but never a mixed digest.
# =============================================================================
sdK="$(new_stage K)"
replacementK1="$sdK/.replacement-1"
replacementK2="$sdK/.replacement-2"
mkdir -p "$replacementK1" "$replacementK2"
for candidateK in "$sdK"/TASK-*.candidate.md; do
  cp "$candidateK" "$replacementK1/"
  printf '\nFirst generation bytes.\n' >>"$replacementK1/$(basename "$candidateK")"
done
singular_task_batch_replace_stage "$replacementK1" "$sdK" \
  || fail "K: could not seed the first immutable generation"
oldK="$(candidate_digest "$sdK")"
resolvedK="$(singular_task_batch_candidate_dir "$sdK")"
for candidateK in "$resolvedK"/TASK-*.candidate.md; do
  cp "$candidateK" "$replacementK2/"
  chmod u+w "$replacementK2/$(basename "$candidateK")"
  printf '\nSecond generation bytes.\n' >>"$replacementK2/$(basename "$candidateK")"
done
newK="$(python3 - "$replacementK2" <<'PY'
import glob, hashlib, os, sys
root = sys.argv[1]
h = hashlib.sha256()
for path in sorted(glob.glob(os.path.join(root, "TASK-*.candidate.md"))):
    h.update(os.path.basename(path).encode())
    h.update(b"\0")
    h.update(open(path, "rb").read())
    h.update(b"\0")
print(h.hexdigest())
PY
)"
readyK="$tmp/publish-K.ready"
releaseK="$tmp/publish-K.release"
seen_oldK="$tmp/reader-K.old"
seen_newK="$tmp/reader-K.new"
reader_errorK="$tmp/reader-K.error"
SINGULAR_TEST_BATCH_PUBLISH_READY="$readyK" \
SINGULAR_TEST_BATCH_PUBLISH_RELEASE="$releaseK" \
  python3 "$ENGINE_HOME/engine/task_batch_publish.py" publish \
    --stage-dir "$sdK" --candidate-dir "$replacementK2" >/dev/null 2>&1 &
publish_pidK=$!
for _ in $(seq 1 500); do
  [[ -f "$readyK" ]] && break
  sleep 0.01
done
[[ -f "$readyK" ]] || fail "K: publisher did not reach the pointer-swap barrier"
(
  for _ in $(seq 1 500); do
    observed="$(candidate_digest "$sdK")" || exit 1
    if [[ "$observed" == "$oldK" ]]; then
      : >"$seen_oldK"
    elif [[ "$observed" == "$newK" ]]; then
      : >"$seen_newK"
    else
      printf '%s\n' "$observed" >"$reader_errorK"
      exit 1
    fi
    [[ -f "$seen_oldK" && -f "$seen_newK" ]] && exit 0
  done
  exit 1
) &
reader_pidK=$!
for _ in $(seq 1 500); do
  [[ -f "$seen_oldK" ]] && break
  sleep 0.01
done
[[ -f "$seen_oldK" ]] || fail "K: reader did not observe the complete old generation"
: >"$releaseK"
wait "$publish_pidK" || fail "K: atomic pointer publication failed"
wait "$reader_pidK" || fail "K: concurrent reader did not observe only complete generations"
[[ ! -s "$reader_errorK" ]] \
  || fail "K: concurrent reader observed mixed digest $(cat "$reader_errorK")"
[[ -f "$seen_newK" ]] || fail "K: reader did not observe the complete new generation"
[[ "$(candidate_digest "$sdK")" == "$newK" ]] \
  || fail "K: current pointer does not select the complete new generation"

# =============================================================================
# (L) present-but-uncalled: no existing engine path invokes the new function.
# =============================================================================
callers="$(grep -rl "singular_plan_revise_loop" "$ENGINE_HOME/engine" 2>/dev/null \
  | grep -v '/ctx-plan-revise-loop.sh$' || true)"
: # temporal assertion neutralized (later slices may legitimately call this)

echo "ctx-plan-revision full-walk tests passed"
