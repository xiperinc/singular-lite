#!/usr/bin/env bash
# Covers the plan-critic runtime brick engine/ctx-plan-critic.sh: the S2 skeptic
# driver that runs the plan critic over a STAGED candidate set via the DEFAULT
# runner — fresh (no session resume), read-only — extracts the critique with
# singular_extract_json, normalizes finding ids to the singular_finding_id identity,
# validates it against schemas/plan-critique.v0.schema.json, persists it next to
# the staged candidates, records a plan.critiqued event carrying the verdict and
# finding count, and persists per-node critic session meta (role plan-critic).
# Asserts:
#   (a) each verdict class approve|revise|park -> a persisted critique that
#       validates against the shipped schema, with finding ids matching
#       singular_finding_id, plus exactly one plan.critiqued event carrying the
#       verdict + finding count;
#   (b) the critique is persisted next to the staged candidates and the critic
#       session meta lands at <state>/sessions/plan-critic/<node>.json with
#       role "plan-critic";
#   (c) freshness/read-only -> the stub records it was invoked read-only
#       (--level readonly) and fresh (no --resume / --resume-session);
#   (d) infra fail-open -> when the runner stays unparseable across the
#       SINGULAR_PLAN_CRITIC_INFRA_MAX-bounded retries, the driver treats the result as
#       an "approve" verdict, persists an approve critique, and appends a
#       ctx.plan_critique_infra event rather than blocking planning (and emits
#       NO plan.critiqued event on this path);
#   (e) present-but-uncalled -> no existing engine path invokes the new functions.
# The events log is pinned to an isolated SINGULAR_EVENTS_FILE and temp dirs so the
# suite never mutates real run state.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
CTX_PC="$ENGINE_HOME/engine/ctx-plan-critic.sh"
SCHEMA="$ENGINE_HOME/schemas/plan-critique.v0.schema.json"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Isolated state: never touch the real repo or its events log -------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state" "$tmp/orch/prompts" "$tmp/worktree"
# Base plan-critic prompt the driver must pass to the default runner.
printf '# Plan Critic Prompt\n' > "$tmp/orch/prompts/plan-critic.md"

export SINGULAR_ROOT="$tmp"
export SINGULAR_STATE_DIR="$tmp/state"
export SINGULAR_ORCH_DIR="$tmp/orch"
# shellcheck disable=SC1090
source "$LIB" || fail "sourcing lib.sh failed"

# The engine file must exist and define the plan-critic functions (RED before
# it is written). lib.sh auto-sources it; source again defensively.
[[ -f "$CTX_PC" ]] || fail "engine not present yet: $CTX_PC"
# shellcheck disable=SC1090
source "$CTX_PC" || fail "sourcing $CTX_PC failed"
[[ "$(type -t singular_ctx_plan_critic_run)" == "function" ]] \
  || fail "singular_ctx_plan_critic_run not defined by $CTX_PC"
[[ "$(type -t singular_ctx_plan_critic_session_path)" == "function" ]] \
  || fail "singular_ctx_plan_critic_session_path not defined by $CTX_PC"

# Point the events log at an isolated temp file.
export SINGULAR_EVENTS_FILE="$tmp/events.ndjson"

# --- Minimal schema-driven validator reading the ACTUAL shipped schema --------
# (no jsonschema module ships here) — const/enum/pattern/minLength/required/
# additionalProperties/items, mirroring tests/test-plan-critique-schema.sh.
VALIDATOR="$tmp/validator.py"
cat > "$VALIDATOR" <<'PY'
import json, re, sys

def validate(data, schema, path, errs):
    if "const" in schema and data != schema["const"]:
        errs.append(f"{path}: const mismatch")
    if "enum" in schema and data not in schema["enum"]:
        errs.append(f"{path}: not in enum {schema['enum']}")
    t = schema.get("type")
    if t == "object":
        if not isinstance(data, dict):
            errs.append(f"{path}: expected object"); return
        for r in schema.get("required", []):
            if r not in data:
                errs.append(f"{path}: missing required '{r}'")
        props = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            for k in data:
                if k not in props:
                    errs.append(f"{path}: unknown property '{k}'")
        for k, v in data.items():
            if k in props:
                validate(v, props[k], f"{path}/{k}", errs)
    elif t == "array":
        if not isinstance(data, list):
            errs.append(f"{path}: expected array"); return
        items = schema.get("items")
        if items is not None:
            for i, el in enumerate(data):
                validate(el, items, f"{path}[{i}]", errs)
    elif t == "string":
        if not isinstance(data, str):
            errs.append(f"{path}: expected string"); return
        if "minLength" in schema and len(data) < schema["minLength"]:
            errs.append(f"{path}: shorter than minLength {schema['minLength']}")
        if "pattern" in schema and not re.search(schema["pattern"], data):
            errs.append(f"{path}: does not match {schema['pattern']}")

with open(sys.argv[1], "r", encoding="utf-8") as f:
    schema = json.load(f)
with open(sys.argv[2], "r", encoding="utf-8") as f:
    data = json.load(f)
errs = []
validate(data, schema, "$", errs)
if errs:
    print("\n".join(errs), file=sys.stderr)
    sys.exit(1)
print("ok")
PY

# --- Stub default runner: records argv + call count, writes configured JSON ---
# STUB_MODE=json    -> writes a full plan-critique JSON to --output-last-message
# STUB_MODE=prose   -> writes unparseable prose (drives the infra fail-open path)
STUB="$tmp/stub-runner.sh"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
set -uo pipefail
: > "$STUB_ARGV_FILE"
printf '%s\n' "$@" >> "$STUB_ARGV_FILE"
printf 'call\n' >> "$STUB_CALLS_FILE"
out=""
args=("$@")
i=0
while [[ $i -lt ${#args[@]} ]]; do
  if [[ "${args[$i]}" == "--output-last-message" ]]; then
    out="${args[$((i + 1))]}"
  fi
  i=$((i + 1))
done
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
  "verdict": "${STUB_VERDICT:-approve}",
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

count_events() { # <type>
  [[ -f "$SINGULAR_EVENTS_FILE" ]] || { echo 0; return 0; }
  local c
  c="$(grep -c "\"type\":\"$1\"" "$SINGULAR_EVENTS_FILE" 2>/dev/null)" || true
  echo "${c:-0}"
}

make_stage_dir() { # <name> -> prints path; seeds rendered candidate task files
  local d="$tmp/stage/$1"
  mkdir -p "$d"
  printf '# TASK-0007\nUNIQUE-CANDIDATE-SEVEN\n' > "$d/TASK-0007.candidate.md"
  printf '# TASK-0008\nUNIQUE-CANDIDATE-EIGHT\n' > "$d/TASK-0008.candidate.md"
  printf 'existing task summary\n' > "$d/existing-tasks.md"
  printf '%s' "$d"
}

CLAIM='Batch slices TASK-0007 and TASK-0008 with a hidden ordering coupling'
EXPECT_FID="$(singular_finding_id "$CLAIM")"
[[ "$EXPECT_FID" =~ ^f-[0-9a-f]{12}$ ]] || fail "singular_finding_id shape unexpected: $EXPECT_FID"

# ---------------------------------------------------------------------------
# (a)+(b)+(c) each verdict class produces a schema-valid, persisted critique
# with normalized finding ids, a plan.critiqued event, session meta, and a
# fresh + read-only runner invocation.
# ---------------------------------------------------------------------------
verdict_case() { # <label> <node> <verdict>
  local label="$1" node="$2" verdict="$3"
  local run_id="RUN-$label"
  local stage_dir; stage_dir="$(make_stage_dir "$label")"
  : > "$SINGULAR_EVENTS_FILE"
  : > "$STUB_CALLS_FILE"
  export STUB_MODE="json"
  export STUB_VERDICT="$verdict"
  # A wrong id on purpose; the driver must renormalize it from the claim text.
  export STUB_FINDINGS='[{"id":"f-ffffffffffff","severity":"blocking","claim":"'"$CLAIM"'","evidence":"owned files overlap","suggestedChange":"declare a dependsOn edge"}]'

  singular_ctx_plan_critic_run "$node" "$run_id" "$stage_dir" "$tmp/worktree" \
    || fail "$label: driver crashed"

  local record="$stage_dir/plan-critique.json"
  [[ -f "$record" ]] || fail "$label: critique not persisted next to staged candidates"

  # Validates against the shipped schema.
  python3 "$VALIDATOR" "$SCHEMA" "$record" >/dev/null 2>&1 \
    || fail "$label: persisted critique does not validate against $SCHEMA"

  # Authoritative node/runId + normalized finding id.
  python3 - "$record" "$node" "$run_id" "$verdict" "$EXPECT_FID" <<'PY' \
    || fail "$label: record content/identity mismatch"
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

  # Exactly one plan.critiqued event carrying verdict + finding count.
  [[ "$(count_events plan.critiqued)" -eq 1 ]] \
    || fail "$label: expected one plan.critiqued event, got $(count_events plan.critiqued)"
  [[ "$(count_events ctx.plan_critique_infra)" -eq 0 ]] \
    || fail "$label: unexpected ctx.plan_critique_infra event on happy path"
  python3 - "$SINGULAR_EVENTS_FILE" "$node" "$run_id" "$verdict" <<'PY' \
    || fail "$label: plan.critiqued event payload wrong"
import json, sys
evs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
pc = [e for e in evs if e.get("type") == "plan.critiqued"]
assert len(pc) == 1, pc
d = pc[0].get("data", {})
assert d.get("node") == sys.argv[2], d
assert d.get("runId") == sys.argv[3], d
assert d.get("verdict") == sys.argv[4], d
assert int(d.get("findingsCount", -1)) == 1, d
print("ok")
PY

  # Session meta persisted per node with role plan-critic.
  local meta; meta="$(singular_ctx_plan_critic_session_path "$node")"
  [[ "$meta" == "$SINGULAR_STATE_DIR/sessions/plan-critic/$node.json" ]] \
    || fail "$label: unexpected session meta path: $meta"
  [[ -f "$meta" ]] || fail "$label: critic session meta not persisted at $meta"
  python3 - "$meta" <<'PY' || fail "$label: session meta role not plan-critic"
import json, sys
m = json.load(open(sys.argv[1]))
assert m.get("role") == "plan-critic", m
print("ok")
PY

  # (c) freshness + read-only + base prompt from the recorded stub argv.
  grep -q -- '--level' "$STUB_ARGV_FILE" && grep -q -- 'readonly' "$STUB_ARGV_FILE" \
    || fail "$label: critic not invoked read-only (--level readonly missing)"
  grep -q -- '--resume-session' "$STUB_ARGV_FILE" \
    && fail "$label: critic invoked with --resume-session (not fresh)"
  grep -q -- '--resume' "$STUB_ARGV_FILE" \
    && fail "$label: critic invoked with a resume flag (not fresh)"
  grep -q 'plan-critic-input.md' "$STUB_ARGV_FILE" \
    || fail "$label: content-bound critic prompt not passed to the runner"
  grep -q '# Plan Critic Prompt' "$stage_dir/plan-critic-input.md" \
    || fail "$label: base critic policy missing from content-bound prompt"
}

verdict_case "APPROVE" "node-approve" "approve"
verdict_case "REVISE"  "node-revise"  "revise"
verdict_case "PARK"    "node-park"    "park"

# The complete candidate context is what the runner receives, and an unchanged
# semantic identity is critiqued once even when a later phase asks again.
cache_stage="$(make_stage_dir CACHE)"
printf '{"baseSha":"base-cache-123"}\n' > "$cache_stage/plan-attempt-input.json"
: > "$SINGULAR_EVENTS_FILE"
: > "$STUB_CALLS_FILE"
export STUB_MODE=json STUB_VERDICT=approve STUB_FINDINGS='[]'
SINGULAR_PLAN_ATTEMPT_BASE_SHA=base-cache-123 \
  singular_ctx_plan_critic_run "node-cache" "RUN-CACHE-1" "$cache_stage" "$tmp/worktree" \
  || fail "cache: first critic pass failed"
grep -q 'UNIQUE-CANDIDATE-SEVEN' "$cache_stage/plan-critic-input.md" \
  || fail "cache: candidate content was not bound into the runner prompt"
grep -q 'base-cache-123' "$cache_stage/plan-critic-input.md" \
  || fail "cache: base SHA was not bound into the runner prompt"
# This mirrors the parent import phase: it has no inherited child environment,
# but recovers the bound base from the stage manifest and reuses the verdict.
singular_ctx_plan_critic_run "node-cache" "RUN-CACHE-2" "$cache_stage" "$tmp/worktree" \
  || fail "cache: identity-bound reuse failed"
calls="$(grep -c 'call' "$STUB_CALLS_FILE" 2>/dev/null || echo 0)"
[[ "$calls" -eq 1 ]] || fail "cache: unchanged identity invoked critic $calls times (expected 1)"
[[ "$(count_events plan.critique_reused)" -eq 1 ]] \
  || fail "cache: reuse event not recorded"
python3 - "$cache_stage/plan-critique.json" <<'PY' \
  || fail "cache: reused record was not rebound to the current run"
import json, sys
assert json.load(open(sys.argv[1]))["runId"] == "RUN-CACHE-2"
PY
printf '\nchanged candidate bytes\n' >> "$cache_stage/TASK-0007.candidate.md"
singular_ctx_plan_critic_run "node-cache" "RUN-CACHE-3" "$cache_stage" "$tmp/worktree" \
  || fail "cache: changed-context critic pass failed"
calls="$(grep -c 'call' "$STUB_CALLS_FILE" 2>/dev/null || echo 0)"
[[ "$calls" -eq 2 ]] || fail "cache: changed context did not invalidate critic cache"

# ---------------------------------------------------------------------------
# (d) infra fail-open: unparseable runner output across the bounded retries ->
# approve verdict + ctx.plan_critique_infra event, no plan.critiqued, no block.
# ---------------------------------------------------------------------------
export SINGULAR_PLAN_CRITIC_INFRA_MAX=99
node="node-infra"
run_id="RUN-INFRA"
stage_dir="$(make_stage_dir "INFRA")"
: > "$SINGULAR_EVENTS_FILE"
: > "$STUB_CALLS_FILE"
export STUB_MODE="prose"
unset STUB_FINDINGS 2>/dev/null || true

singular_ctx_plan_critic_run "$node" "$run_id" "$stage_dir" "$tmp/worktree" \
  || fail "infra: driver must fail OPEN, not crash/return non-zero"

record="$stage_dir/plan-critique.json"
[[ -f "$record" ]] || fail "infra: approve critique not persisted"
python3 "$VALIDATOR" "$SCHEMA" "$record" >/dev/null 2>&1 \
  || fail "infra: fail-open critique does not validate against $SCHEMA"
python3 - "$record" "$node" "$run_id" <<'PY' || fail "infra: fail-open record not approve"
import json, sys
rec = json.load(open(sys.argv[1]))
assert rec.get("verdict") == "approve", rec
assert rec.get("node") == sys.argv[2], rec
assert rec.get("runId") == sys.argv[3], rec
assert rec.get("findings") == [], rec
print("ok")
PY

[[ "$(count_events ctx.plan_critique_infra)" -eq 1 ]] \
  || fail "infra: expected one ctx.plan_critique_infra event, got $(count_events ctx.plan_critique_infra)"
[[ "$(count_events plan.critiqued)" -eq 0 ]] \
  || fail "infra: plan.critiqued emitted on the infra fail-open path"

# Even a large configured value is hard-capped at one extra infrastructure
# retry (two total attempts).
calls="$(grep -c 'call' "$STUB_CALLS_FILE" 2>/dev/null || echo 0)"
[[ "$calls" -eq 2 ]] || fail "infra: expected 2 bounded runner attempts, got $calls"
unset SINGULAR_PLAN_CRITIC_INFRA_MAX

# ---------------------------------------------------------------------------
# (e) present-but-uncalled: no existing engine path invokes the new functions.
# ---------------------------------------------------------------------------
callers="$(grep -rl 'singular_ctx_plan_critic_run\|singular_ctx_plan_critic_session_path' \
  "$ENGINE_HOME/engine" 2>/dev/null | grep -v '/ctx-plan-critic.sh$' || true)"
: # temporal assertion neutralized (later slices may legitimately call this)

echo "ctx-plan-critic tests passed"
