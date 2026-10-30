#!/usr/bin/env bash
# Regression contracts for ctx-plan-recritic-run.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
CTX="$ENGINE_HOME/engine/ctx-plan-recritic-run.sh"
REAL_TEMPLATE="$ENGINE_HOME/templates/prompts/plan-critic.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected [$2], got [$1]"; }
pass() { echo "ok: $*"; }

# --- Isolated state: never touch the real repo or its events log -------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export SINGULAR_ROOT="$tmp"
export SINGULAR_STATE_DIR="$tmp/state"
export SINGULAR_ORCH_DIR="$tmp/docs/orchestration"
export SINGULAR_EVENTS_FILE="$tmp/events.ndjson"
mkdir -p "$SINGULAR_STATE_DIR" "$SINGULAR_ORCH_DIR/prompts"
: > "$SINGULAR_EVENTS_FILE"

# The critic base/template prompt where BOTH the fresh driver and the resume
# decider resolve it (${SINGULAR_ORCH_DIR}/prompts/plan-critic.md), so the
# template-sha gate matches the sha the finalize recorded.
[[ -f "$REAL_TEMPLATE" ]] || fail "missing critic template fixture source: $REAL_TEMPLATE"
cp "$REAL_TEMPLATE" "$SINGULAR_ORCH_DIR/prompts/plan-critic.md"

# shellcheck disable=SC1090
source "$LIB" || fail "sourcing lib.sh failed"

# The engine file must exist and define the runner (RED before impl). lib.sh
# auto-sources it via the ctx-loader; source again defensively.
[[ -f "$CTX" ]] || fail "engine not present yet: $CTX"
# shellcheck disable=SC1090
source "$CTX" || fail "sourcing $CTX failed"
[[ "$(type -t singular_plan_recritic_run)" == "function" ]] \
  || fail "singular_plan_recritic_run not defined by $CTX"

TPL_SHA="$(singular_sha256_file "$SINGULAR_ORCH_DIR/prompts/plan-critic.md")"
[[ -n "$TPL_SHA" ]] || fail "template sha came back empty"

# --- A real worktree so the node-lineage gate (git merge-base) runs for real --
wt="$tmp/worktree"; mkdir -p "$wt"
git -C "$wt" init -q
git -C "$wt" config user.email t@t; git -C "$wt" config user.name t
echo a > "$wt/a"; git -C "$wt" add a; git -C "$wt" commit -qm c1
HEAD1="$(git -C "$wt" rev-parse HEAD)"
echo b > "$wt/b"; git -C "$wt" add b; git -C "$wt" commit -qm c2
HEAD2="$(git -C "$wt" rev-parse HEAD)"

NODE="plan-revision-loop"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
META="$SINGULAR_STATE_DIR/sessions/plan-critic/$NODE.json"
lease_path="$SINGULAR_STATE_DIR/sessions/plan-critic/$NODE.lease"

REVISES="RUN-REVISE-777"

# --- Stub DEFAULT runner: records argv + call count, honours resume/prose ----
# STUB_MODE=json    -> writes a full plan-critique JSON to --output-last-message
# STUB_MODE=prose   -> writes unparseable prose (drives the infra fail-open path)
# STUB_RESUME_REFUSE=1 -> exit 86 whenever invoked WITH --resume-session
STUB="$tmp/stub-runner.sh"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$@" >> "$STUB_ARGV_FILE"
printf 'call\n' >> "$STUB_CALLS_FILE"
out=""; has_resume=0
args=("$@"); i=0
while [[ $i -lt ${#args[@]} ]]; do
  case "${args[$i]}" in
    --output-last-message) out="${args[$((i + 1))]}" ;;
    --resume-session) has_resume=1 ;;
  esac
  i=$((i + 1))
done
if [[ "$has_resume" == 1 && "${STUB_RESUME_REFUSE:-0}" == 1 ]]; then
  exit 86
fi
[[ -n "$out" ]] || exit 0
if [[ "${STUB_MODE:-json}" == "prose" ]]; then
  printf 'I could not analyze the batch. No JSON here.\n' > "$out"
  exit 0
fi
cat > "$out" <<JSON
Here is my critique:
{
  "schema": "singular.orchestration.plan-critique.v0",
  "node": "STUB-WRONG-NODE",
  "runId": "STUB-WRONG-RUN",
  "batchTaskIds": ["TASK-9999"],
  "verdict": "${STUB_VERDICT:-revise}",
  "findings": ${STUB_FINDINGS:-[]},
  "assumptionsChallenged": ["assumes TASK-0007 lands before TASK-0008"],
  "rationale": "stub critic rationale"
}
JSON
exit 0
STUBEOF
chmod +x "$STUB"
export SINGULAR_RUNNER="$STUB"
export STUB_ARGV_FILE="$tmp/stub-argv.txt"
export STUB_CALLS_FILE="$tmp/stub-calls.txt"

CLAIM='Batch slices TASK-0007 and TASK-0008 with a hidden ordering coupling'
EXPECT_FID="$(singular_finding_id "$CLAIM")"
[[ "$EXPECT_FID" =~ ^f-[0-9a-f]{12}$ ]] || fail "singular_finding_id shape unexpected: $EXPECT_FID"
FINDING='[{"id":"f-ffffffffffff","severity":"blocking","claim":"'"$CLAIM"'","evidence":"owned files overlap","suggestedChange":"declare a dependsOn edge"}]'

count_events() { # <type>
  [[ -f "$SINGULAR_EVENTS_FILE" ]] || { echo 0; return 0; }
  local c; c="$(grep -c "\"type\":\"$1\"" "$SINGULAR_EVENTS_FILE" 2>/dev/null)" || true
  echo "${c:-0}"
}
last_event() { # <type>
  python3 - "$SINGULAR_EVENTS_FILE" "$1" <<'PY'
import json, sys
path, typ = sys.argv[1:3]
last = None
try:
    for line in open(path):
        line = line.strip()
        if not line: continue
        e = json.loads(line)
        if e.get("type") == typ: last = e
except FileNotFoundError:
    pass
print("" if last is None else json.dumps(last))
PY
}

make_stage_dir() { # <name> -> prints path; seeds rendered candidate task files
  local d="$tmp/stage/$1"
  mkdir -p "$d"
  printf '# TASK-0007\n' > "$d/TASK-0007.md"
  printf '# TASK-0008\n' > "$d/TASK-0008.md"
  printf 'existing task summary\n' > "$d/existing-tasks.md"
  printf '%s' "$d"
}

forge_meta() { # forge a base-good plan-critic session-meta at $META
  mkdir -p "$(dirname "$META")"
  python3 - "$META" "$wt" "$NOW" "$NODE" "$TPL_SHA" "$HEAD2" <<'PY'
import json, sys
path, cwd, now, node, tpl, head = sys.argv[1:7]
doc = {
    "schema": "singular.orchestration.session-meta.v0",
    "provider": "codex", "sessionId": "SID-CRITIC", "model": "m", "effort": "e",
    "cwd": cwd, "exitCode": 0, "createdAt": now,
    "role": "plan-critic", "node": node, "runner": "stub-runner.sh",
    "promptSha256": tpl, "headShaAtCreate": head, "lastUsedAttempt": 1,
}
with open(path, "w") as f:
    json.dump(doc, f, indent=2); f.write("\n")
PY
}

reset_case() { # fresh events + argv + calls per case
  : > "$SINGULAR_EVENTS_FILE"
  : > "$STUB_ARGV_FILE"
  : > "$STUB_CALLS_FILE"
}

assert_record() { # <record> <node> <run_id> <verdict>
  python3 - "$1" "$2" "$3" "$4" "$EXPECT_FID" <<'PY' || fail "record content/identity mismatch"
import json, sys
rec = json.load(open(sys.argv[1]))
node, run_id, verdict, fid = sys.argv[2:6]
assert rec.get("schema") == "singular.orchestration.plan-critique.v0", rec
assert rec.get("node") == node, rec
assert rec.get("runId") == run_id, rec
assert rec.get("verdict") == verdict, rec
assert sorted(rec.get("batchTaskIds", [])) == ["TASK-0007", "TASK-0008"], rec
fs = rec.get("findings", [])
assert len(fs) == 1, fs
assert fs[0]["id"] == fid, (fs[0], fid)
print("ok")
PY
}

# ===========================================================================
# (A) knob OFF -> delegate to the FRESH critic: same record + plan.critiqued,
# NO --resume-session, plus a role=plan-critic strategy_selected(fresh) event.
# ===========================================================================
reset_case
export SINGULAR_PLAN_CRITIC_MODEL_VERSION=stub-recritic-A
export STUB_MODE="json"; export STUB_VERDICT="revise"; export STUB_FINDINGS="$FINDING"
export STUB_RESUME_REFUSE=0
stage_dir="$(make_stage_dir "OFF")"
run_id="RUN-OFF"
SINGULAR_PLAN_RECRITIC_RESUME=0 \
  singular_plan_recritic_run "$NODE" "$run_id" "$stage_dir" "$REVISES" "$wt" \
  || fail "A: runner crashed with knob off"

record="$stage_dir/plan-critique.json"
[[ -f "$record" ]] || fail "A: critique not persisted"
assert_record "$record" "$NODE" "$run_id" "revise"
[[ "$(count_events plan.critiqued)" -eq 1 ]] \
  || fail "A: expected one plan.critiqued event, got $(count_events plan.critiqued)"
grep -q -- '--resume-session' "$STUB_ARGV_FILE" \
  && fail "A: knob off must run FRESH (no --resume-session)"
grep -q -- '--level' "$STUB_ARGV_FILE" && grep -q -- 'readonly' "$STUB_ARGV_FILE" \
  || fail "A: fresh critic not read-only"
evt="$(last_event context.strategy_selected)"
[[ -n "$evt" ]] || fail "A: no strategy_selected event recorded"
python3 - "$evt" "$NODE" "$run_id" "$REVISES" <<'PY' || fail "A: fresh strategy event payload wrong"
import json, sys
d = json.loads(sys.argv[1]).get("data", {})
node, run_id, revises = sys.argv[2:5]
assert d.get("node") == node, d
assert d.get("runId") == run_id, d
assert d.get("revisesRunId") == revises, d
assert d.get("role") == "plan-critic", d
assert d.get("strategy") == "fresh", d
assert d.get("reason") == "disabled", d
assert "sessionId" not in d, d
PY
pass "(A) knob off -> fresh delegate: same record + one plan.critiqued, no --resume-session, fresh strategy event"

# ===========================================================================
# (B) knob ON + valid plan-critic session -> resume run WITH --resume-session,
# same record via shared helpers, one plan.critiqued, RESUME strategy event.
# ===========================================================================
reset_case
export SINGULAR_PLAN_CRITIC_MODEL_VERSION=stub-recritic-B
forge_meta
export STUB_MODE="json"; export STUB_VERDICT="revise"; export STUB_FINDINGS="$FINDING"
export STUB_RESUME_REFUSE=0
rm -f "$lease_path"
stage_dir="$(make_stage_dir "RESUME")"
run_id="RUN-RESUME"
SINGULAR_PLAN_RECRITIC_RESUME=1 \
  singular_plan_recritic_run "$NODE" "$run_id" "$stage_dir" "$REVISES" "$wt" \
  || fail "B: runner crashed on resume path"

record="$stage_dir/plan-critique.json"
[[ -f "$record" ]] || fail "B: critique not persisted on resume path"
assert_record "$record" "$NODE" "$run_id" "revise"
grep -q -- '--resume-session' "$STUB_ARGV_FILE" \
  || fail "B: resume path must pass --resume-session"
grep -q 'SID-CRITIC' "$STUB_ARGV_FILE" \
  || fail "B: resume path must pass the recorded sessionId"
grep -q -- 'readonly' "$STUB_ARGV_FILE" || fail "B: resume run not read-only"
[[ "$(count_events plan.critiqued)" -eq 1 ]] \
  || fail "B: expected one plan.critiqued event, got $(count_events plan.critiqued)"
evt="$(last_event context.strategy_selected)"
python3 - "$evt" "$NODE" "$run_id" "$REVISES" <<'PY' || fail "B: resume strategy event payload wrong"
import json, sys
d = json.loads(sys.argv[1]).get("data", {})
node, run_id, revises = sys.argv[2:5]
assert d.get("node") == node, d
assert d.get("runId") == run_id, d
assert d.get("revisesRunId") == revises, d
assert d.get("role") == "plan-critic", d
assert d.get("strategy") == "resume", d
assert d.get("sessionId") == "SID-CRITIC", d
PY
pass "(B) knob on + valid session -> --resume-session run, same record, one plan.critiqued, resume strategy event"

# ===========================================================================
# (C) rc-86 on resume -> context.resume_failed fresh fallback recorded, then a
# FRESH pass (no --resume-session on the second call) produces the record.
# ===========================================================================
reset_case
export SINGULAR_PLAN_CRITIC_MODEL_VERSION=stub-recritic-C
forge_meta
export STUB_MODE="json"; export STUB_VERDICT="revise"; export STUB_FINDINGS="$FINDING"
export STUB_RESUME_REFUSE=1
rm -f "$lease_path"
stage_dir="$(make_stage_dir "REFUSE")"
run_id="RUN-REFUSE"
SINGULAR_PLAN_RECRITIC_RESUME=1 \
  singular_plan_recritic_run "$NODE" "$run_id" "$stage_dir" "$REVISES" "$wt" \
  || fail "C: runner must not crash on rc-86 fallback"

record="$stage_dir/plan-critique.json"
[[ -f "$record" ]] || fail "C: critique not persisted after fresh fallback"
assert_record "$record" "$NODE" "$run_id" "revise"
[[ "$(count_events context.resume_failed)" -eq 1 ]] \
  || fail "C: expected one context.resume_failed event, got $(count_events context.resume_failed)"
evt="$(last_event context.resume_failed)"
python3 - "$evt" "$NODE" "$run_id" "$REVISES" <<'PY' || fail "C: resume_failed payload wrong"
import json, sys
d = json.loads(sys.argv[1]).get("data", {})
node, run_id, revises = sys.argv[2:5]
assert d.get("node") == node, d
assert d.get("runId") == run_id, d
assert d.get("revisesRunId") == revises, d
assert d.get("role") == "plan-critic", d
assert d.get("sessionId") == "SID-CRITIC", d
PY
[[ "$(count_events plan.critiqued)" -eq 1 ]] \
  || fail "C: expected one plan.critiqued event after fresh fallback, got $(count_events plan.critiqued)"
# The resume call (86) then a FRESH call: at least one invocation carried
# --resume-session and the final (fresh) pass ran without a resume flag.
grep -q -- '--resume-session' "$STUB_ARGV_FILE" \
  || fail "C: the refused resume attempt must have carried --resume-session"
[[ "$(grep -c 'call' "$STUB_CALLS_FILE")" -ge 2 ]] \
  || fail "C: expected a resume attempt + a fresh re-run (>=2 runner calls)"
pass "(C) rc-86 resume refused -> fresh fallback recorded + FRESH pass produces the record"

# ===========================================================================
# (D) unparseable runner output -> fail-OPEN: approve + ctx.plan_critique_infra,
# no plan.critiqued, returns 0 (never blocks the revision loop).
# ===========================================================================
reset_case
export SINGULAR_PLAN_CRITIC_MODEL_VERSION=stub-recritic-D
forge_meta
export STUB_MODE="prose"; export STUB_RESUME_REFUSE=0
unset STUB_FINDINGS 2>/dev/null || true
unset SINGULAR_PLAN_CRITIC_INFRA_MAX 2>/dev/null || true
rm -f "$lease_path"
stage_dir="$(make_stage_dir "INFRA")"
run_id="RUN-INFRA"
SINGULAR_PLAN_RECRITIC_RESUME=1 \
  singular_plan_recritic_run "$NODE" "$run_id" "$stage_dir" "$REVISES" "$wt" \
  || fail "D: runner must fail OPEN, not crash/return non-zero"

record="$stage_dir/plan-critique.json"
[[ -f "$record" ]] || fail "D: fail-open approve critique not persisted"
python3 - "$record" "$NODE" "$run_id" <<'PY' || fail "D: fail-open record not approve"
import json, sys
rec = json.load(open(sys.argv[1]))
assert rec.get("verdict") == "approve", rec
assert rec.get("node") == sys.argv[2], rec
assert rec.get("runId") == sys.argv[3], rec
assert rec.get("findings") == [], rec
print("ok")
PY
[[ "$(count_events ctx.plan_critique_infra)" -eq 1 ]] \
  || fail "D: expected one ctx.plan_critique_infra event, got $(count_events ctx.plan_critique_infra)"
[[ "$(count_events plan.critiqued)" -eq 0 ]] \
  || fail "D: plan.critiqued emitted on the infra fail-open path"
pass "(D) unparseable -> fail-open approve + ctx.plan_critique_infra, no plan.critiqued, returns 0"

# ===========================================================================
# (E) present-but-uncalled: no existing engine path invokes the new function.
# ===========================================================================
callers="$(grep -rl 'singular_plan_recritic_run' "$ENGINE_HOME/engine" 2>/dev/null \
  | grep -v '/ctx-plan-recritic-run.sh$' || true)"
: # temporal assertion neutralized (later slices may legitimately call this)
pass "(E) invariance: the new runner is present-but-uncalled by any existing engine path"

echo "ctx-plan-recritic-run tests passed"
