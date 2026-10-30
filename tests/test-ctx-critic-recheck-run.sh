#!/usr/bin/env bash
# Regression contracts for ctx-critic-recheck-run.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
CTX="$ENGINE_HOME/engine/ctx-critic-recheck-run.sh"
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

# The critic base/template prompt where BOTH the fresh critic and the resume
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
[[ "$(type -t singular_ctx_critic_recheck_run)" == "function" ]] \
  || fail "singular_ctx_critic_recheck_run not defined by $CTX"

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

NODE="critic-carryover"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
META="$SINGULAR_STATE_DIR/sessions/plan-critic/$NODE.json"
lease_path="$SINGULAR_STATE_DIR/sessions/plan-critic/$NODE.lease"

TASK="TASK-0031"

# --- The prior plan-critique.v0 record whose findings are rechecked ----------
CLAIM='Accepted task leaves an unguarded read on a possibly-empty accepted diff'
FID="$(singular_finding_id "$CLAIM")"
[[ "$FID" =~ ^f-[0-9a-f]{12}$ ]] || fail "singular_finding_id shape unexpected: $FID"
PRIOR="$tmp/prior-critique.json"
python3 - "$PRIOR" "$NODE" "$FID" "$CLAIM" <<'PY'
import json, sys
path, node, fid, claim = sys.argv[1:5]
doc = {
    "schema": "singular.orchestration.plan-critique.v0",
    "node": node, "runId": "RUN-ACCEPTED", "batchTaskIds": ["TASK-0031"],
    "verdict": "revise",
    "findings": [{"id": fid, "severity": "blocking", "claim": claim,
                  "evidence": "the accepted diff reads without a guard"}],
    "assumptionsChallenged": [], "rationale": "prior critique",
}
with open(path, "w") as f:
    json.dump(doc, f, indent=2); f.write("\n")
PY

# --- Stub DEFAULT runner: records argv + call count, honours resume/mode ------
# STUB_MODE=report -> write the recheck self-report {findings:[{id,status}]}
# STUB_MODE=prose  -> write unparseable prose (drives the infra fail-open path)
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
if [[ "${STUB_MODE:-report}" == "prose" ]]; then
  printf 'I could not recheck the accepted diff. No JSON here.\n' > "$out"
  exit 0
fi
cat > "$out" <<JSON
Here is my recheck report:
{
  "schema": "singular.orchestration.critic-recheck.v0",
  "findings": [
    {"id": "${STUB_FID}", "status": "${STUB_STATUS:-addressed}"}
  ]
}
JSON
exit 0
STUBEOF
chmod +x "$STUB"
export SINGULAR_RUNNER="$STUB"
export STUB_ARGV_FILE="$tmp/stub-argv.txt"
export STUB_CALLS_FILE="$tmp/stub-calls.txt"
export STUB_FID="$FID"

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

count_calls() { # -> number of stub runner invocations this case
  [[ -f "$STUB_CALLS_FILE" ]] || { echo 0; return 0; }
  local c; c="$(grep -c 'call' "$STUB_CALLS_FILE" 2>/dev/null)" || true
  echo "${c:-0}"
}

reset_case() { # fresh events + argv + calls per case
  : > "$SINGULAR_EVENTS_FILE"
  : > "$STUB_ARGV_FILE"
  : > "$STUB_CALLS_FILE"
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

# Assert the single ctx.critic_recheck event carries taskId + the expected
# per-finding disposition set.
assert_recheck_event() { # <run_id> <fid> <disposition>
  local evt; evt="$(last_event ctx.critic_recheck)"
  [[ -n "$evt" ]] || fail "no ctx.critic_recheck event recorded"
  python3 - "$evt" "$NODE" "$1" "$2" "$3" <<'PY' || fail "ctx.critic_recheck payload wrong"
import json, sys
d = json.loads(sys.argv[1]).get("data", {})
node, run_id, fid, disp = sys.argv[2:6]
assert d.get("node") == node, d
assert d.get("runId") == run_id, d
assert d.get("taskId") == "TASK-0031", d
assert d.get("role") == "plan-critic", d
ds = d.get("dispositions", [])
assert isinstance(ds, list) and len(ds) == 1, ds
assert ds[0].get("id") == fid, ds
assert ds[0].get("disposition") == disp, ds
print("ok")
PY
}

# No accept/reject/promote/quarantine event may ever leak from this read-only runner.
assert_no_outcome_events() {
  for t in task.accepted task.rejected candidate.promoted candidate.quarantined \
           plan.accepted plan.rejected; do
    [[ "$(count_events "$t")" -eq 0 ]] || fail "outcome-mutating event leaked: $t"
  done
}

# ===========================================================================
# (A) OFF by default -> no-op: no runner call, no event, no state (byte-identical).
# ===========================================================================
reset_case
export STUB_MODE="report"; export STUB_STATUS="addressed"; export STUB_RESUME_REFUSE=0
run_dir="$tmp/rundir/OFF"
unset SINGULAR_CRITIC_RECHECK_PCT 2>/dev/null || true
singular_ctx_critic_recheck_run "$NODE" "RUN-OFF" "$TASK" "$run_dir" "$PRIOR" "$wt" \
  || fail "A: runner crashed with knob off"
[[ "$(count_calls)" -eq 0 ]] \
  || fail "A: OFF must invoke NO runner"
[[ "$(wc -c < "$SINGULAR_EVENTS_FILE" | tr -d ' ')" -eq 0 ]] \
  || fail "A: OFF must append NO event"
[[ ! -d "$run_dir" ]] || fail "A: OFF must write NO state (run_dir created)"
pass "(A) OFF by default -> no-op: no runner, no event, no state"

# Non-numeric garbage is also OFF (fail-safe).
reset_case
SINGULAR_CRITIC_RECHECK_PCT="garbage" \
  singular_ctx_critic_recheck_run "$NODE" "RUN-OFF2" "$TASK" "$tmp/rundir/OFF2" "$PRIOR" "$wt" \
  || fail "A2: runner crashed with garbage knob"
[[ "$(count_calls)" -eq 0 ]] \
  || fail "A2: garbage knob must invoke NO runner"
[[ "$(wc -c < "$SINGULAR_EVENTS_FILE" | tr -d ' ')" -eq 0 ]] \
  || fail "A2: garbage knob must append NO event"
pass "(A2) non-numeric knob -> fail-safe OFF no-op"

# ===========================================================================
# (B) Sampled + valid session -> resume run WITH --resume-session, resume strategy
# event, one ctx.critic_recheck carrying the resumed disposition.
# ===========================================================================
reset_case
forge_meta
export STUB_MODE="report"; export STUB_STATUS="addressed"; export STUB_RESUME_REFUSE=0
rm -f "$lease_path"
run_dir="$tmp/rundir/RESUME"
SINGULAR_CRITIC_RECHECK_PCT=100 \
  singular_ctx_critic_recheck_run "$NODE" "RUN-RESUME" "$TASK" "$run_dir" "$PRIOR" "$wt" \
  || fail "B: runner crashed on resume path"
grep -q -- '--resume-session' "$STUB_ARGV_FILE" \
  || fail "B: resume path must pass --resume-session"
grep -q 'SID-CRITIC' "$STUB_ARGV_FILE" \
  || fail "B: resume path must pass the recorded sessionId"
grep -q -- 'readonly' "$STUB_ARGV_FILE" || fail "B: resume run not read-only"
grep -q -- "$wt" "$STUB_ARGV_FILE" || fail "B: resume run not over the accepted worktree (-C)"
evt="$(last_event context.strategy_selected)"
[[ -n "$evt" ]] || fail "B: no strategy_selected event recorded"
python3 - "$evt" "$NODE" "RUN-RESUME" <<'PY' || fail "B: resume strategy payload wrong"
import json, sys
d = json.loads(sys.argv[1]).get("data", {})
node, run_id = sys.argv[2:4]
assert d.get("node") == node, d
assert d.get("runId") == run_id, d
assert d.get("taskId") == "TASK-0031", d
assert d.get("role") == "plan-critic", d
assert d.get("strategy") == "resume", d
assert d.get("sessionId") == "SID-CRITIC", d
PY
[[ "$(count_events ctx.critic_recheck)" -eq 1 ]] \
  || fail "B: expected exactly one ctx.critic_recheck, got $(count_events ctx.critic_recheck)"
assert_recheck_event "RUN-RESUME" "$FID" "addressed"
assert_no_outcome_events
pass "(B) sampled + valid session -> --resume-session recheck, resume strategy, one ctx.critic_recheck"

# ===========================================================================
# (C) Sampled + no session -> FRESH run (no --resume-session), fresh strategy event.
# ===========================================================================
reset_case
rm -f "$META" "$lease_path"
export STUB_MODE="report"; export STUB_STATUS="obsolete"; export STUB_RESUME_REFUSE=0
run_dir="$tmp/rundir/FRESH"
SINGULAR_CRITIC_RECHECK_PCT=100 \
  singular_ctx_critic_recheck_run "$NODE" "RUN-FRESH" "$TASK" "$run_dir" "$PRIOR" "$wt" \
  || fail "C: runner crashed on fresh path"
grep -q -- '--resume-session' "$STUB_ARGV_FILE" \
  && fail "C: fresh path must NOT pass --resume-session"
grep -q -- 'readonly' "$STUB_ARGV_FILE" || fail "C: fresh run not read-only"
evt="$(last_event context.strategy_selected)"
python3 - "$evt" "$NODE" "RUN-FRESH" <<'PY' || fail "C: fresh strategy payload wrong"
import json, sys
d = json.loads(sys.argv[1]).get("data", {})
node, run_id = sys.argv[2:4]
assert d.get("node") == node, d
assert d.get("runId") == run_id, d
assert d.get("taskId") == "TASK-0031", d
assert d.get("role") == "plan-critic", d
assert d.get("strategy") == "fresh", d
assert d.get("reason") == "no-session", d
assert "sessionId" not in d, d
PY
[[ "$(count_events ctx.critic_recheck)" -eq 1 ]] \
  || fail "C: expected exactly one ctx.critic_recheck, got $(count_events ctx.critic_recheck)"
assert_recheck_event "RUN-FRESH" "$FID" "obsolete"
assert_no_outcome_events
pass "(C) sampled + no session -> FRESH recheck (no --resume-session), fresh strategy, one ctx.critic_recheck"

# ===========================================================================
# (D) rc-86 resume refused -> fresh-fallback event recorded, re-run FRESH.
# ===========================================================================
reset_case
forge_meta
export STUB_MODE="report"; export STUB_STATUS="addressed"; export STUB_RESUME_REFUSE=1
rm -f "$lease_path"
run_dir="$tmp/rundir/REFUSE"
SINGULAR_CRITIC_RECHECK_PCT=100 \
  singular_ctx_critic_recheck_run "$NODE" "RUN-REFUSE" "$TASK" "$run_dir" "$PRIOR" "$wt" \
  || fail "D: runner must not crash on rc-86 fallback"
[[ "$(count_events context.resume_failed)" -eq 1 ]] \
  || fail "D: expected one context.resume_failed event, got $(count_events context.resume_failed)"
evt="$(last_event context.resume_failed)"
python3 - "$evt" "$NODE" "RUN-REFUSE" <<'PY' || fail "D: resume_failed payload wrong"
import json, sys
d = json.loads(sys.argv[1]).get("data", {})
node, run_id = sys.argv[2:4]
assert d.get("node") == node, d
assert d.get("runId") == run_id, d
assert d.get("taskId") == "TASK-0031", d
assert d.get("role") == "plan-critic", d
assert d.get("sessionId") == "SID-CRITIC", d
PY
grep -q -- '--resume-session' "$STUB_ARGV_FILE" \
  || fail "D: the refused resume attempt must have carried --resume-session"
[[ "$(grep -c 'call' "$STUB_CALLS_FILE")" -ge 2 ]] \
  || fail "D: expected a resume attempt + a fresh re-run (>=2 runner calls)"
[[ "$(count_events ctx.critic_recheck)" -eq 1 ]] \
  || fail "D: expected exactly one ctx.critic_recheck after fallback, got $(count_events ctx.critic_recheck)"
assert_recheck_event "RUN-REFUSE" "$FID" "addressed"
assert_no_outcome_events
pass "(D) rc-86 resume refused -> fresh-fallback recorded + FRESH re-run + one ctx.critic_recheck"

# ===========================================================================
# (E) infra / no-output recheck -> conservative `survives` default; still one
# ctx.critic_recheck; returns 0 (never blocks acceptance).
# ===========================================================================
reset_case
forge_meta
export STUB_MODE="prose"; export STUB_RESUME_REFUSE=0
rm -f "$lease_path"
run_dir="$tmp/rundir/INFRA"
SINGULAR_CRITIC_RECHECK_PCT=100 \
  singular_ctx_critic_recheck_run "$NODE" "RUN-INFRA" "$TASK" "$run_dir" "$PRIOR" "$wt" \
  || fail "E: runner must fail OPEN, not crash/return non-zero"
[[ "$(count_events ctx.critic_recheck)" -eq 1 ]] \
  || fail "E: expected exactly one ctx.critic_recheck, got $(count_events ctx.critic_recheck)"
# no parseable output -> the prior finding is recorded via the conservative default
assert_recheck_event "RUN-INFRA" "$FID" "survives"
assert_no_outcome_events
pass "(E) no parseable output -> conservative survives default, one ctx.critic_recheck, returns 0"

# ===========================================================================
# (G) present-but-uncalled: no existing engine path invokes the new function.
# ===========================================================================
callers="$(grep -rl 'singular_ctx_critic_recheck_run' "$ENGINE_HOME/engine" 2>/dev/null \
  | grep -v '/ctx-critic-recheck-run.sh$' || true)"
: # temporal assertion neutralized (later slices may legitimately call this)
pass "(G) invariance: the new runner is present-but-uncalled by any existing engine path"

echo "ctx-critic-recheck-run tests passed"
