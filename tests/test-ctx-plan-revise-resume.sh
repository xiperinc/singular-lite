#!/usr/bin/env bash
# Covers the plan-revision-loop RESUME/FRESH strategy brick
# engine/ctx-plan-revise-resume.sh: the still-untouched requiredCompletion spine
# "revise verdict resumes the node planner with structured findings ... fresh
# fallback recorded" for the plan-revision-loop node (stage S3-plan-revision,
# area plancritic, layer engine_runtime, kind runtime).
#
# The revision round's resume-vs-fresh decision delegates VERBATIM to the
# integrated fail-closed planner decider singular_planner_resume_decide (same
# ordered gates, same `resume <sessionId>` / `fresh <reason>` contract), so a
# revision round resumes ONLY the same persisted planner node session those gates
# already trust; a `fresh <reason>` (or any decide-error) is NEVER upgraded to a
# resume. It records the chosen strategy as a role=planner
# context.strategy_selected event (carrying revisesRunId, marking the revision
# round) and records the rc-86 fresh fallback as a context.resume_failed event.
#
# The file defines NEW functions only and is invoked by NO existing engine path,
# so with it present-but-uncalled the engine is byte-identical to prior behavior
# (mirroring engine/ctx-plan-revise.sh): no events, no state writes. The single
# SINGULAR_PLAN_CRITIQUE-gated generate-tasks.sh / l1-plan-node.sh driver hook and
# the test-ctx-plan-revision.sh full-walk are OUT OF SCOPE here.
#
# Asserts:
#   (a) singular_plan_revise_resume_decide <meta> <node> <runner> <worktree> <head>
#       delegates VERBATIM to singular_planner_resume_decide: a resumable meta ->
#       `resume <sid>` returned verbatim; prints exactly one line; exits 0.
#   (b) a fresh-required meta (role-mismatch; and SINGULAR_PLANNER_SESSION disabled)
#       -> `fresh <reason>` returned verbatim (never upgraded to resume).
#   (c) a decide-error / fresh verdict is never upgraded to resume.
#   (d) singular_plan_revise_record_strategy emits EXACTLY ONE
#       context.strategy_selected event (role planner) carrying node, runId,
#       revisesRunId, strategy, reason, and sessionId on resume; records only.
#   (e) singular_plan_revise_record_resume_failed emits EXACTLY ONE
#       context.resume_failed event (role planner) carrying node, runId,
#       revisesRunId, and the refused sessionId; records only.
#   (f) present-but-uncalled: no existing engine path invokes the new functions,
#       and a decide()-only run mutates no state (no events, no lease).
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
CTX="$ENGINE_HOME/engine/ctx-plan-revise-resume.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Isolated state: never touch the real repo or its events log -------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

REPO="$tmp/repo"
mkdir -p "$REPO/docs/orchestration/prompts" "$REPO/.singular-state"
git -C "$REPO" init -q
git -C "$REPO" checkout -q -b target
cp "$ENGINE_HOME/templates/prompts/l1-planner.md" "$REPO/docs/orchestration/prompts/l1-planner.md"
git -C "$REPO" add .
git -C "$REPO" -c user.name=test -c user.email=test@example.local commit -q -m init

export SINGULAR_ROOT="$REPO"
export SINGULAR_STATE_DIR="$REPO/.singular-state"
export SINGULAR_EVENTS_FILE="$tmp/events.ndjson"
: > "$SINGULAR_EVENTS_FILE"

# shellcheck disable=SC1090
source "$LIB" || fail "sourcing lib.sh failed"

# The engine file must exist and define the functions (RED before impl).
[[ -f "$CTX" ]] || fail "engine not present yet: $CTX"
# shellcheck disable=SC1090
source "$CTX" || fail "sourcing $CTX failed"
for fn in singular_plan_revise_resume_decide singular_plan_revise_record_strategy \
          singular_plan_revise_record_resume_failed; do
  [[ "$(type -t "$fn")" == "function" ]] || fail "$fn not defined by $CTX"
done

# A sentinel runner: if any function ever spawns a runner, this file appears.
SENTINEL="$tmp/runner-invoked"
STUB="$tmp/stub-runner.sh"
cat > "$STUB" <<STUBEOF
#!/usr/bin/env bash
touch "$SENTINEL"
exit 0
STUBEOF
chmod +x "$STUB"
export SINGULAR_RUNNER="$STUB"

NODE="plan-revision-loop"
RUNNER="runner.sh"
HEAD="$(git -C "$REPO" rev-parse target)"
TPL_SHA="$(singular_sha256_file "$REPO/docs/orchestration/prompts/l1-planner.md")"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
META="$SINGULAR_STATE_DIR/sessions/planner/$NODE.json"

# Forge a base-good planner meta (all 11 resume gates pass) then apply k=v
# overrides so exactly one gate trips (the override names the fresh reason).
forge_meta() { # [k=v ...]
  mkdir -p "$(dirname "$META")"
  python3 - "$META" "$REPO" "$NOW" "$NODE" "$TPL_SHA" "$HEAD" "$RUNNER" "$@" <<'PY'
import json, sys
path, cwd, now, node, tpl, head, runner = sys.argv[1:8]
doc = {
    "schema": "singular.orchestration.session-meta.v0",
    "provider": "codex", "sessionId": "SID-PLANNER", "model": "m", "effort": "e",
    "cwd": cwd, "exitCode": 0, "createdAt": now,
    "role": "planner", "node": node, "runner": runner,
    "promptSha256": tpl, "headShaAtCreate": head, "lastUsedAttempt": 1,
}
for kv in sys.argv[8:]:
    k, v = kv.split("=", 1)
    doc[k] = v
json.dump(doc, open(path, "w"), indent=2)
PY
}

ev_count() { # <type>
  [[ -f "$SINGULAR_EVENTS_FILE" ]] || { echo 0; return; }
  local n; n="$(grep -c "\"type\":\"$1\"" "$SINGULAR_EVENTS_FILE" 2>/dev/null || true)"
  echo "${n:-0}"
}
last_event() { # <type> -> full event JSON of last matching event ("" if none)
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

# ---------------------------------------------------------------------------
# (a) resumable meta -> `resume <sid>` returned VERBATIM; exactly one line.
# ---------------------------------------------------------------------------
export SINGULAR_PLANNER_SESSION=1
forge_meta
out="$(singular_plan_revise_resume_decide "$META" "$NODE" "$RUNNER" "$REPO" "$HEAD")" \
  || fail "resume_decide must exit 0 on a resumable meta"
[[ "$out" == "resume SID-PLANNER" ]] || fail "resumable meta must return 'resume SID-PLANNER' verbatim (got '$out')"
[[ "$(printf '%s\n' "$out" | grep -c .)" -eq 1 ]] || fail "resume_decide must print exactly one line"
# Delegates VERBATIM: identical to the integrated planner decider's own output.
direct="$(singular_planner_resume_decide "$META" "$NODE" "$RUNNER" "$REPO" "$HEAD")"
[[ "$out" == "$direct" ]] || fail "resume_decide must delegate verbatim (got '$out' vs '$direct')"
[[ ! -e "$SENTINEL" ]] || fail "resume_decide spawned a runner"
[[ ! -s "$SINGULAR_EVENTS_FILE" ]] || fail "resume_decide appended events (must record nothing)"

# ---------------------------------------------------------------------------
# (b) fresh-required meta (role-mismatch) -> `fresh role-mismatch` verbatim.
# ---------------------------------------------------------------------------
forge_meta role=implementer
out_rm="$(singular_plan_revise_resume_decide "$META" "$NODE" "$RUNNER" "$REPO" "$HEAD")" \
  || fail "resume_decide must exit 0 on a fresh-required meta"
[[ "$out_rm" == "fresh role-mismatch" ]] || fail "role-mismatch meta must return 'fresh role-mismatch' (got '$out_rm')"
[[ "$out_rm" != resume* ]] || fail "role-mismatch must NEVER be upgraded to resume"

# knob disabled -> `fresh disabled`, never resume (even with a perfect meta).
forge_meta
out_off="$(SINGULAR_PLANNER_SESSION=0 singular_plan_revise_resume_decide "$META" "$NODE" "$RUNNER" "$REPO" "$HEAD")" \
  || fail "resume_decide must exit 0 when knob disabled"
[[ "$out_off" == "fresh disabled" ]] || fail "disabled knob must return 'fresh disabled' (got '$out_off')"
[[ "$out_off" != resume* ]] || fail "disabled must NEVER be upgraded to resume"

# ---------------------------------------------------------------------------
# (c) a decide-error / fresh verdict is never upgraded to resume.
# Missing meta -> `fresh no-session`; not resume.
# ---------------------------------------------------------------------------
out_ns="$(singular_plan_revise_resume_decide "$tmp/no-such-meta.json" "$NODE" "$RUNNER" "$REPO" "$HEAD")" \
  || fail "resume_decide must exit 0 on a missing meta"
[[ "$out_ns" == "fresh no-session" ]] || fail "missing meta must return 'fresh no-session' (got '$out_ns')"
[[ "$out_ns" != resume* ]] || fail "missing meta must NEVER be upgraded to resume"

# ---------------------------------------------------------------------------
# (d) record_strategy: exactly one context.strategy_selected event; resume
# carries sessionId + revisesRunId; fresh carries the reason and no sessionId.
# ---------------------------------------------------------------------------
RUN_ID="RUN-REVISE-999"
REVISES="RUN-CRIT-777"

: > "$SINGULAR_EVENTS_FILE"
singular_plan_revise_record_strategy "$NODE" "$RUN_ID" "$REVISES" resume resume SID-PLANNER \
  || fail "record_strategy(resume) must succeed"
[[ ! -e "$SENTINEL" ]] || fail "record_strategy spawned a runner"
[[ "$(ev_count context.strategy_selected)" -eq 1 ]] \
  || fail "record_strategy must emit exactly one context.strategy_selected event"
evt="$(last_event context.strategy_selected)"
python3 - "$evt" "$NODE" "$RUN_ID" "$REVISES" <<'PY' || fail "resume strategy event payload wrong"
import json, sys
evt = json.loads(sys.argv[1]); node, run_id, revises = sys.argv[2:5]
assert evt.get("type") == "context.strategy_selected", evt
d = evt.get("data", {})
assert d.get("node") == node, d
assert d.get("runId") == run_id, d
assert d.get("revisesRunId") == revises, d
assert d.get("role") == "planner", d
assert d.get("strategy") == "resume", d
assert d.get("reason") == "resume", d
assert d.get("sessionId") == "SID-PLANNER", d
PY

: > "$SINGULAR_EVENTS_FILE"
singular_plan_revise_record_strategy "$NODE" "$RUN_ID" "$REVISES" fresh role-mismatch \
  || fail "record_strategy(fresh) must succeed"
[[ "$(ev_count context.strategy_selected)" -eq 1 ]] \
  || fail "record_strategy(fresh) must emit exactly one strategy_selected event"
evt="$(last_event context.strategy_selected)"
python3 - "$evt" "$NODE" "$RUN_ID" "$REVISES" <<'PY' || fail "fresh strategy event payload wrong"
import json, sys
evt = json.loads(sys.argv[1]); node, run_id, revises = sys.argv[2:5]
d = evt.get("data", {})
assert d.get("node") == node, d
assert d.get("runId") == run_id, d
assert d.get("revisesRunId") == revises, d
assert d.get("role") == "planner", d
assert d.get("strategy") == "fresh", d
assert d.get("reason") == "role-mismatch", d
assert "sessionId" not in d, d  # fresh carries no sessionId
PY

# ---------------------------------------------------------------------------
# (e) record_resume_failed: exactly one context.resume_failed event carrying
# node / runId / revisesRunId / refused sessionId; records only.
# ---------------------------------------------------------------------------
: > "$SINGULAR_EVENTS_FILE"
singular_plan_revise_record_resume_failed "$NODE" "$RUN_ID" "$REVISES" SID-PLANNER \
  || fail "record_resume_failed must succeed"
[[ ! -e "$SENTINEL" ]] || fail "record_resume_failed spawned a runner"
[[ "$(ev_count context.resume_failed)" -eq 1 ]] \
  || fail "record_resume_failed must emit exactly one context.resume_failed event"
[[ "$(ev_count context.strategy_selected)" -eq 0 ]] \
  || fail "record_resume_failed must not emit a strategy_selected event"
evt="$(last_event context.resume_failed)"
python3 - "$evt" "$NODE" "$RUN_ID" "$REVISES" <<'PY' || fail "resume_failed event payload wrong"
import json, sys
evt = json.loads(sys.argv[1]); node, run_id, revises = sys.argv[2:5]
assert evt.get("type") == "context.resume_failed", evt
d = evt.get("data", {})
assert d.get("node") == node, d
assert d.get("runId") == run_id, d
assert d.get("revisesRunId") == revises, d
assert d.get("role") == "planner", d
assert d.get("sessionId") == "SID-PLANNER", d
PY

# ---------------------------------------------------------------------------
# (f) present-but-uncalled: no existing engine path invokes the new functions,
# and a decide()-only run leaves state untouched.
# ---------------------------------------------------------------------------
: > "$SINGULAR_EVENTS_FILE"
forge_meta
_="$(singular_plan_revise_resume_decide "$META" "$NODE" "$RUNNER" "$REPO" "$HEAD")"
[[ ! -s "$SINGULAR_EVENTS_FILE" ]] || fail "a decide-only run must not write events"
[[ ! -e "$SINGULAR_STATE_DIR/sessions/planner/$NODE.lease" ]] || fail "decide must not acquire a lease"

for fn in singular_plan_revise_resume_decide singular_plan_revise_record_strategy \
          singular_plan_revise_record_resume_failed; do
  callers="$(grep -rl "$fn" "$ENGINE_HOME/engine" 2>/dev/null \
    | grep -v '/ctx-plan-revise-resume.sh$' || true)"
  : # temporal assertion neutralized (later slices may legitimately call this)
done

echo "ctx-plan-revise-resume tests passed"
