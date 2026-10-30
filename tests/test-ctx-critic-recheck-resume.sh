#!/usr/bin/env bash
# Regression contracts for ctx-critic-recheck-resume.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
CTX="$ENGINE_HOME/engine/ctx-critic-recheck-resume.sh"
REAL_TEMPLATE="$ENGINE_HOME/templates/prompts/plan-critic.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { # <got> <want> <label>
  [[ "$1" == "$2" ]] || fail "$3: expected [$2], got [$1]"
}
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

# shellcheck disable=SC1090
source "$LIB" || fail "sourcing lib.sh failed"

# The engine file must exist and define the functions (RED before impl). lib.sh
# auto-sources it via the ctx-loader; source again defensively.
[[ -f "$CTX" ]] || fail "engine not present yet: $CTX"
# shellcheck disable=SC1090
source "$CTX" || fail "sourcing $CTX failed"
for fn in singular_ctx_critic_recheck_resume_decide singular_ctx_critic_recheck_record_strategy; do
  [[ "$(type -t "$fn")" == "function" ]] || fail "$fn not defined by $CTX"
done

# The engine file must be auto-sourced by the ctx-loader glob in lib.sh (proven by
# a fresh subshell that sources ONLY lib.sh and finds the functions defined).
sub_defined="$(bash -c '
  set -uo pipefail
  export SINGULAR_ROOT="'"$tmp"'"
  export SINGULAR_STATE_DIR="'"$tmp"'/state"
  export SINGULAR_ORCH_DIR="'"$tmp"'/docs/orchestration"
  export SINGULAR_EVENTS_FILE="'"$tmp"'/events.ndjson"
  source "'"$LIB"'" >/dev/null 2>&1
  type -t singular_ctx_critic_recheck_resume_decide
')"
assert_eq "$sub_defined" "function" "auto-sourced by lib.sh ctx-loader glob"
pass "invariance: engine file auto-sourced by the ctx-loader glob in lib.sh"

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

# The critic TEMPLATE must live where the plan-critic driver finalizes it from
# (\${SINGULAR_ORCH_DIR}/prompts/plan-critic.md) so the template-sha gate matches
# the sha the finalize recorded. Copy the real fixture and derive the sha.
[[ -f "$REAL_TEMPLATE" ]] || fail "missing critic template fixture source: $REAL_TEMPLATE"
cp "$REAL_TEMPLATE" "$SINGULAR_ORCH_DIR/prompts/plan-critic.md"
TPL_SHA="$(singular_sha256_file "$SINGULAR_ORCH_DIR/prompts/plan-critic.md")"
[[ -n "$TPL_SHA" ]] || fail "template sha came back empty"

# A real worktree so the node-lineage gate (git merge-base --is-ancestor) runs
# against real commits (the accepted-diff lineage head).
wt="$tmp/worktree"; mkdir -p "$wt"
git -C "$wt" init -q
git -C "$wt" config user.email t@t; git -C "$wt" config user.name t
echo a > "$wt/a"; git -C "$wt" add a; git -C "$wt" commit -qm c1
HEAD1="$(git -C "$wt" rev-parse HEAD)"
echo b > "$wt/b"; git -C "$wt" add b; git -C "$wt" commit -qm c2
HEAD2="$(git -C "$wt" rev-parse HEAD)"
# A divergent branch so HEAD2 is NOT an ancestor of HEAD_FORK (head-rewritten).
git -C "$wt" checkout -q -b fork "$HEAD1"
echo x > "$wt/x"; git -C "$wt" add x; git -C "$wt" commit -qm fork1
HEAD_FORK="$(git -C "$wt" rev-parse HEAD)"
git -C "$wt" checkout -q master 2>/dev/null || git -C "$wt" checkout -q main 2>/dev/null || git -C "$wt" checkout -q "$HEAD2"

NODE="critic-carryover"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
META="$SINGULAR_STATE_DIR/sessions/plan-critic/$NODE.json"
lease_path="$SINGULAR_STATE_DIR/sessions/plan-critic/$NODE.lease"
rm -f "$lease_path"

# Forge a base-good plan-critic meta (all gates pass) then apply k=v overrides so
# exactly one gate trips (the override names the fresh reason).
forge_meta() { # <path> [k=v ...]
  local path="$1"; shift
  mkdir -p "$(dirname "$path")"
  python3 - "$path" "$wt" "$NOW" "$NODE" "$TPL_SHA" "$HEAD2" "$@" <<'PY'
import json, sys
path, cwd, now, node, tpl, head = sys.argv[1:7]
doc = {
    "schema": "singular.orchestration.session-meta.v0",
    "provider": "codex", "sessionId": "SID-CRITIC", "model": "m", "effort": "e",
    "cwd": cwd, "exitCode": 0, "createdAt": now,
    "role": "plan-critic", "node": node, "runner": "codex-run.sh",
    "promptSha256": tpl, "headShaAtCreate": head, "lastUsedAttempt": 1,
}
for kv in sys.argv[7:]:
    k, v = kv.split("=", 1)
    doc[k] = v
with open(path, "w") as f:
    json.dump(doc, f, indent=2); f.write("\n")
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

# decide <meta> <node> <runner> <worktree> <lineage_head>. Default: knob ON (100%).
decide() { SINGULAR_CRITIC_RECHECK_PCT="${SINGULAR_CRITIC_RECHECK_PCT:-100}" \
  singular_ctx_critic_recheck_resume_decide "$@"; }

RUNNER="codex-run.sh"

# ---------------------------------------------------------------------------
# Gate: feature-flag disabled (default 0 = OFF; unset / 0 / non-numeric garbage).
# The whole recheck feature is OFF, so no session is ever resumed.
# ---------------------------------------------------------------------------
m="$tmp/g-dis.json"; forge_meta "$m"
out="$(SINGULAR_CRITIC_RECHECK_PCT=0 singular_ctx_critic_recheck_resume_decide "$m" "$NODE" "$RUNNER" "$wt" "$HEAD2")"
assert_eq "$out" "fresh disabled" "disabled(=0)"
out="$(unset SINGULAR_CRITIC_RECHECK_PCT; singular_ctx_critic_recheck_resume_decide "$m" "$NODE" "$RUNNER" "$wt" "$HEAD2")"
assert_eq "$out" "fresh disabled" "disabled(unset)"
out="$(SINGULAR_CRITIC_RECHECK_PCT=abc singular_ctx_critic_recheck_resume_decide "$m" "$NODE" "$RUNNER" "$wt" "$HEAD2")"
assert_eq "$out" "fresh disabled" "disabled(non-numeric garbage)"
out="$(SINGULAR_CRITIC_RECHECK_PCT="12x" singular_ctx_critic_recheck_resume_decide "$m" "$NODE" "$RUNNER" "$wt" "$HEAD2")"
assert_eq "$out" "fresh disabled" "disabled(partly-numeric garbage)"
[[ "$out" != resume* ]] || fail "disabled must NEVER be upgraded to resume"
pass "gate: SINGULAR_CRITIC_RECHECK_PCT unset/0/non-numeric -> fresh disabled"

# ---------------------------------------------------------------------------
# Gate: no-session (missing + unparseable meta).
# ---------------------------------------------------------------------------
out="$(decide "$tmp/does-not-exist.json" "$NODE" "$RUNNER" "$wt" "$HEAD2")"
assert_eq "$out" "fresh no-session" "missing meta"
printf 'not json{' > "$tmp/g-bad.json"
out="$(decide "$tmp/g-bad.json" "$NODE" "$RUNNER" "$wt" "$HEAD2")"
assert_eq "$out" "fresh no-session" "unparseable meta"
pass "gate: missing/unparseable meta -> fresh no-session"

# ---------------------------------------------------------------------------
# Gate: no-session-id (empty provider or sessionId).
# ---------------------------------------------------------------------------
m="$tmp/g-sid.json"; forge_meta "$m" "sessionId="
out="$(decide "$m" "$NODE" "$RUNNER" "$wt" "$HEAD2")"
assert_eq "$out" "fresh no-session-id" "empty sid"
m="$tmp/g-prov.json"; forge_meta "$m" "provider="
out="$(decide "$m" "$NODE" "$RUNNER" "$wt" "$HEAD2")"
assert_eq "$out" "fresh no-session-id" "empty provider"
pass "gate: empty provider/sessionId -> fresh no-session-id"

# ---------------------------------------------------------------------------
# Gate: role-mismatch (skeptic-role gate). A recheck may ONLY re-enter a
# plan-critic session; a planner/implementer/reviewer session is NEVER resumed.
# ---------------------------------------------------------------------------
for r in planner implementer reviewer advocate skeptic task ""; do
  m="$tmp/g-role.json"; forge_meta "$m" "role=$r"
  out="$(decide "$m" "$NODE" "$RUNNER" "$wt" "$HEAD2")"
  assert_eq "$out" "fresh role-mismatch" "role=$r"
  [[ "$out" != resume* ]] || fail "role=$r must NEVER be upgraded to resume"
done
pass "gate: role != plan-critic -> fresh role-mismatch (never resume a non-critic session)"

# ---------------------------------------------------------------------------
# Gate: node-mismatch.
# ---------------------------------------------------------------------------
m="$tmp/g-node.json"; forge_meta "$m" "node=some-other-node"
out="$(decide "$m" "$NODE" "$RUNNER" "$wt" "$HEAD2")"
assert_eq "$out" "fresh node-mismatch" "node differs"
pass "gate: meta.node != target node -> fresh node-mismatch"

# ---------------------------------------------------------------------------
# Gate: head-rewritten (headShaAtCreate not an ancestor of the accepted-diff
# lineage head; incl. empty/indeterminate ancestry).
# ---------------------------------------------------------------------------
m="$tmp/g-head.json"; forge_meta "$m"
out="$(decide "$m" "$NODE" "$RUNNER" "$wt" "$HEAD_FORK")"
assert_eq "$out" "fresh head-rewritten" "non-ancestor head"
m="$tmp/g-head2.json"; forge_meta "$m" "headShaAtCreate="
out="$(decide "$m" "$NODE" "$RUNNER" "$wt" "$HEAD2")"
assert_eq "$out" "fresh head-rewritten" "empty stored head"
out="$(decide "$tmp/g-head.json" "$NODE" "$RUNNER" "$wt" "")"
assert_eq "$out" "fresh head-rewritten" "empty lineage head"
pass "gate: non-ancestor/indeterminate head -> fresh head-rewritten"

# ---------------------------------------------------------------------------
# Gate: runner-changed.
# ---------------------------------------------------------------------------
m="$tmp/g-runner.json"; forge_meta "$m" "runner=claude-run.sh"
out="$(decide "$m" "$NODE" "$RUNNER" "$wt" "$HEAD2")"
assert_eq "$out" "fresh runner-changed" "runner differs"
pass "gate: runner changed -> fresh runner-changed"

# ---------------------------------------------------------------------------
# Gate: prompt-template-changed (keyed on the critic TEMPLATE sha).
# ---------------------------------------------------------------------------
m="$tmp/g-tpl.json"; forge_meta "$m" "promptSha256=0000000000000000000000000000000000000000000000000000000000000000"
out="$(decide "$m" "$NODE" "$RUNNER" "$wt" "$HEAD2")"
assert_eq "$out" "fresh prompt-template-changed" "wrong template sha"
rendered_sha="$(printf 'rendered-accepted-diff-specific-prompt' | shasum -a 256 | awk '{print $1}')"
m="$tmp/g-tpl2.json"; forge_meta "$m" "promptSha256=$rendered_sha"
out="$(decide "$m" "$NODE" "$RUNNER" "$wt" "$HEAD2")"
assert_eq "$out" "fresh prompt-template-changed" "rendered-prompt sha"
# Unreadable template -> empty sha -> fail closed.
out="$(SINGULAR_PLAN_CRITIC_TEMPLATE=/no/such/template.md decide "$tmp/g-dis.json" "$NODE" "$RUNNER" "$wt" "$HEAD2")"
assert_eq "$out" "fresh prompt-template-changed" "unreadable template"
pass "gate: stored sha != template sha / unreadable template -> fresh prompt-template-changed"

# ---------------------------------------------------------------------------
# Gate: expired (age > SINGULAR_SESSION_MAX_AGE_SEC, or missing createdAt).
# ---------------------------------------------------------------------------
m="$tmp/g-exp.json"; forge_meta "$m" "createdAt=2000-01-01T00:00:00Z"
out="$(decide "$m" "$NODE" "$RUNNER" "$wt" "$HEAD2")"
assert_eq "$out" "fresh expired" "old createdAt"
m="$tmp/g-exp2.json"; forge_meta "$m" "createdAt="
out="$(decide "$m" "$NODE" "$RUNNER" "$wt" "$HEAD2")"
assert_eq "$out" "fresh expired" "missing createdAt"
pass "gate: age > SINGULAR_SESSION_MAX_AGE_SEC / missing createdAt -> fresh expired"

# ---------------------------------------------------------------------------
# Gate: worktree-moved.
# ---------------------------------------------------------------------------
m="$tmp/g-cwd.json"; forge_meta "$m" "cwd=/some/other/place"
out="$(decide "$m" "$NODE" "$RUNNER" "$wt" "$HEAD2")"
assert_eq "$out" "fresh worktree-moved" "cwd differs"
pass "gate: cwd != worktree -> fresh worktree-moved"

# ---------------------------------------------------------------------------
# Gate: leased (a live critic session-lease at the canonical path).
# ---------------------------------------------------------------------------
m="$tmp/g-lease.json"; forge_meta "$m"
mkdir -p "$(dirname "$lease_path")"
printf '{"pid": %s}\n' "$$" > "$lease_path"   # live: our own PID (kill -0 succeeds)
out="$(decide "$m" "$NODE" "$RUNNER" "$wt" "$HEAD2")"
assert_eq "$out" "fresh leased" "live lease present"
rm -f "$lease_path"
pass "gate: live critic session-lease -> fresh leased"

# ---------------------------------------------------------------------------
# Happy path: every gate satisfied, no held lease -> resume <sessionId>.
# ---------------------------------------------------------------------------
m="$tmp/happy.json"; forge_meta "$m"
rm -f "$lease_path"
out="$(decide "$m" "$NODE" "$RUNNER" "$wt" "$HEAD2")"
assert_eq "$out" "resume SID-CRITIC" "all-pass resume"
[[ ! -e "$SENTINEL" ]] || fail "decide spawned a runner"
pass "happy: all gates pass (role plan-critic, node equal, ancestor head, template sha, unexpired, cwd, no lease) -> resume SID-CRITIC"

# ---------------------------------------------------------------------------
# Contract: exactly one line; never non-zero on resume OR fresh.
# ---------------------------------------------------------------------------
rc=0
lines="$(decide "$m" "$NODE" "$RUNNER" "$wt" "$HEAD2")" || rc=$?
assert_eq "$rc" "0" "decider exit code is 0 on resume"
[[ "$(printf '%s\n' "$lines" | grep -c .)" == "1" ]] || fail "decider printed more than one line"
rc=0
out="$(SINGULAR_CRITIC_RECHECK_PCT=0 singular_ctx_critic_recheck_resume_decide "$m" "$NODE" "$RUNNER" "$wt" "$HEAD2")" || rc=$?
assert_eq "$rc" "0" "decider exit code is 0 on fresh"
# A decide-only run mutates no state (no events, no lease).
[[ ! -s "$SINGULAR_EVENTS_FILE" ]] || fail "a decide-only run must not write events"
[[ ! -e "$lease_path" ]] || fail "decide must not acquire a lease"
pass "contract: exactly one line, exit 0 on resume and fresh, no ambiguity upgraded to resume, no state mutation"

# ---------------------------------------------------------------------------
# record_strategy(resume): EXACTLY ONE context.strategy_selected event (role
# plan-critic) carrying node, runId, taskId, strategy, reason, sessionId.
# ---------------------------------------------------------------------------
RUN_ID="RUN-RECHECK-999"
TASK_ID="TASK-ACCEPTED-777"

: > "$SINGULAR_EVENTS_FILE"
singular_ctx_critic_recheck_record_strategy "$NODE" "$RUN_ID" "$TASK_ID" resume resume SID-CRITIC \
  || fail "record_strategy(resume) must succeed"
[[ ! -e "$SENTINEL" ]] || fail "record_strategy spawned a runner"
[[ ! -e "$lease_path" ]] || fail "record_strategy acquired a lease"
[[ "$(ev_count context.strategy_selected)" -eq 1 ]] \
  || fail "record_strategy must emit exactly one context.strategy_selected event"
evt="$(last_event context.strategy_selected)"
python3 - "$evt" "$NODE" "$RUN_ID" "$TASK_ID" <<'PY' || fail "resume strategy event payload wrong"
import json, sys
evt = json.loads(sys.argv[1]); node, run_id, task_id = sys.argv[2:5]
assert evt.get("type") == "context.strategy_selected", evt
d = evt.get("data", {})
assert d.get("node") == node, d
assert d.get("runId") == run_id, d
assert d.get("taskId") == task_id, d
assert d.get("role") == "plan-critic", d
assert d.get("strategy") == "resume", d
assert d.get("reason") == "resume", d
assert d.get("sessionId") == "SID-CRITIC", d
PY
pass "record_strategy(resume): one plan-critic strategy_selected event with taskId + sessionId"

# ---------------------------------------------------------------------------
# record_strategy(fresh): one strategy_selected event, no sessionId, reason kept.
# ---------------------------------------------------------------------------
: > "$SINGULAR_EVENTS_FILE"
singular_ctx_critic_recheck_record_strategy "$NODE" "$RUN_ID" "$TASK_ID" fresh role-mismatch \
  || fail "record_strategy(fresh) must succeed"
[[ "$(ev_count context.strategy_selected)" -eq 1 ]] \
  || fail "record_strategy(fresh) must emit exactly one strategy_selected event"
evt="$(last_event context.strategy_selected)"
python3 - "$evt" "$NODE" "$RUN_ID" "$TASK_ID" <<'PY' || fail "fresh strategy event payload wrong"
import json, sys
evt = json.loads(sys.argv[1]); node, run_id, task_id = sys.argv[2:5]
d = evt.get("data", {})
assert d.get("node") == node, d
assert d.get("runId") == run_id, d
assert d.get("taskId") == task_id, d
assert d.get("role") == "plan-critic", d
assert d.get("strategy") == "fresh", d
assert d.get("reason") == "role-mismatch", d
assert "sessionId" not in d, d  # fresh carries no sessionId
PY
pass "record_strategy(fresh): one plan-critic strategy_selected event, reason kept, no sessionId"

# ---------------------------------------------------------------------------
# present-but-uncalled: no existing engine path invokes the new functions.
# ---------------------------------------------------------------------------
for fn in singular_ctx_critic_recheck_resume_decide singular_ctx_critic_recheck_record_strategy; do
  callers="$(grep -rl "$fn" "$ENGINE_HOME/engine" 2>/dev/null \
    | grep -v '/ctx-critic-recheck-resume.sh$' || true)"
  [[ -z "$callers" ]] || fail "$fn must be present-but-uncalled; referenced by: $callers"
done
pass "invariance: new functions are present-but-uncalled by any existing engine path"

echo "ctx-critic-recheck-resume tests passed"
