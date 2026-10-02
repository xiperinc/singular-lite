#!/usr/bin/env bash
set -euo pipefail

# TASK-0067 — follow-up wire-in completing the TASK-0064 -> TASK-0065 -> TASK-0066
# node-dimension mini-track.
#
# TASK-0064 shipped the pure builder
#   singular_ctx_rehydrate_authored_triggers <role> <step> [node] [task-id]
# with an optional [node] slot; TASK-0065 wired the role/step/task dimensions into
# both live sites; TASK-0066 shipped the pure, read-only resolver
#   singular_ctx_rehydrate_authored_node <task_id> [worktree]
# (the single distinct executable DAG node owning <task_id> from the durable
# control-state task->node association, or empty fail-safe on absence/ambiguity)
# but left it present-but-uncalled: the two live consumers — the injection at
# engine/l1-drive.sh (TASK-0062) and the manifest-record at
# engine/ctx-rehydrate-event.sh (TASK-0063) — still pass only
# `implementer implement "$task_id"`, omitting the builder's position-3 [node]
# slot. Consequently any authored entry whose `load-when` targets the run's node
# (e.g. `["rehydrate-path"]`) can never become eligible, and both the resolver and
# the builder's [node] parameter remain dead.
#
# This slice substitutes, at BOTH sites, a node-resolution step: resolve
#   node="$(singular_ctx_rehydrate_authored_node "$task_id")"
# and pass it into the builder's position-3 slot —
#   singular_ctx_rehydrate_authored_triggers implementer implement "$node" "$task_id".
# Both sites resolve from the SAME pure deterministic resolver with the SAME
# task_id, so they derive the IDENTICAL node token and therefore the identical
# trigger set, preserving the injected<->recorded consistency invariant.
#
# A single hermetic `rehydrate` drive exercises BOTH sites at once: the injection
# lands in $active_prompt and the record lands in the strategy_selected event, so
# their agreement IS the consistency check. The fixture control-state event log
# associates TASK-0001 with exactly one node (rehydrate-path); the fixture manifest
# carries a NODE-scoped entry whose `load-when` is `["rehydrate-path"]` (NOT the
# role, step, or task id) — inert before the substitution (RED), eligible after
# (GREEN) — plus role/task/implement-scoped entries (backward compat) and a
# planner-only entry (must stay dropped). A separate ambiguous-association scenario
# proves the fail-safe: two distinct nodes for the task -> resolver empty -> the
# node-only entry is NOT injected or recorded.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-ctx-rehydrate-authored-node-wirein.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

# Hermetic guard: scrub inherited SINGULAR_* so a leaked knob can't poison the sandbox.
while IFS= read -r _v; do unset "$_v"; done < <(compgen -v | grep '^SINGULAR_' || true)
unset _v

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }

workroot="$(mktemp -d "${TMPDIR:-/tmp}/singular-rehydrate-node-wirein.XXXXXX")"
trap 'rm -rf "$workroot"' EXIT

# Source lib.sh (auto-sources the ctx-*.sh bricks) so the builder, the resolver,
# and the config-gated render/manifest the driver delegates into are available.
export SINGULAR_ROOT="$workroot/libroot"
export SINGULAR_STATE_DIR="$SINGULAR_ROOT/.singular-state"
export SINGULAR_TARGET_BRANCH="target"
mkdir -p "$SINGULAR_STATE_DIR"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"
[[ "$(type -t singular_ctx_rehydrate_authored_triggers)" == "function" ]] \
  || fail "singular_ctx_rehydrate_authored_triggers not defined (TASK-0064 builder missing)"
[[ "$(type -t singular_ctx_rehydrate_authored_node)" == "function" ]] \
  || fail "singular_ctx_rehydrate_authored_node not defined (TASK-0066 resolver missing)"
[[ "$(type -t singular_ctx_rehydrate_authored_config_render)" == "function" ]] \
  || fail "singular_ctx_rehydrate_authored_config_render not defined (config render missing)"

# --- Driver fixture repo -----------------------------------------------------
drv_root="$workroot/drv"
mkdir -p "$drv_root/docs/orchestration/prompts" "$drv_root/docs/orchestration/tasks" \
  "$drv_root/.singular-state" "$drv_root/internal/widget"
git -C "$drv_root" init -q
git -C "$drv_root" config user.email t@t; git -C "$drv_root" config user.name t
git -C "$drv_root" checkout -q -b target
cp "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md" "$drv_root/docs/orchestration/prompts/l2-test-first-developer.md"
cp "$ENGINE_HOME/templates/prompts/auditor.md" "$drv_root/docs/orchestration/prompts/auditor.md"
printf '# Decider Prompt\n[TASK-ID] [FAILURE CLASS]\n' > "$drv_root/docs/orchestration/prompts/decider.md"

# --- Authored-knowledge manifest fixture + config-gated wiring ----------------
# Five entries exercising every dimension:
#   impl-body : load-when [implement]      -> KEEP (backward compat)
#   role-body : load-when [implementer]    -> role dimension (TASK-0065)
#   task-body : load-when [TASK-0001]      -> task dimension (TASK-0065)
#   node-body : load-when [rehydrate-path] -> INERT before this wire-in (node token
#                                             never supplied), ELIGIBLE after
#   plan-only : load-when [planner]        -> always DROP (no matching dimension)
# A RELATIVE contextManifest resolves against the config file's directory (== $drv_root).
cat >"$drv_root/authored-manifest.json" <<'JSON'
{
  "schema": "singular.orchestration.authored-knowledge-manifest.v0",
  "entries": [
    { "id": "impl-body", "body": "AUTHORED BODY impl", "load-when": ["implement"],      "freshness": "current" },
    { "id": "role-body", "body": "AUTHORED BODY role", "load-when": ["implementer"],    "freshness": "current" },
    { "id": "task-body", "body": "AUTHORED BODY task", "load-when": ["TASK-0001"],      "freshness": "current" },
    { "id": "node-body", "body": "AUTHORED BODY node", "load-when": ["rehydrate-path"], "freshness": "current" },
    { "id": "plan-only", "body": "planner body",       "load-when": ["planner"],        "freshness": "current" }
  ]
}
JSON
cat >"$drv_root/singular.config.json" <<'JSON'
{ "contextManifest": "authored-manifest.json" }
JSON

cat >"$drv_root/docs/orchestration/tasks/TASK-0001.md" <<'EOF'
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
git -C "$drv_root" add .
git -C "$drv_root" commit -qm init

TASK_MD="$drv_root/docs/orchestration/tasks/TASK-0001.md"
EVENTS="$drv_root/.singular-state/events.ndjson"

# Append a durable task->node association line as the planner/importer does:
# {ts,type,message,data:{taskId,node,...}} NDJSON. The resolver reads the DISTINCT
# non-empty nodes across every event carrying data.taskId == the task id.
emit_assoc() { # <type> <task_id> <node>
  printf '{"ts":"2026-07-11T00:00:00Z","type":"%s","message":"m","data":{"taskId":"%s","runId":"RUN-X","node":"%s"}}\n' \
    "$1" "$2" "$3" >> "$EVENTS"
}

# --- Sanity: the enriched trigger set now carries the node token ---------------
# singular_ctx_rehydrate_authored_triggers <role> <step> [node] [task] with a
# non-empty node emits it; the node-scoped entry renders ONLY when the node token
# is supplied, and is dropped under the pre-node-dimension set.
triggers_node="$(singular_ctx_rehydrate_authored_triggers implementer implement "rehydrate-path" "TASK-0001")"
grep -qx "rehydrate-path" <<<"$triggers_node" || fail "sanity: builder must emit the node token when supplied"

render_no_node="$(SINGULAR_CTX_MANIFEST=1 SINGULAR_JSON_CONFIG_FILE="$drv_root/singular.config.json" \
  singular_ctx_rehydrate_authored_config_render implementer implement TASK-0001)"
[[ "$render_no_node" != *"=== authored:node-body ==="* ]] \
  || fail "sanity: node-scoped entry must NOT render without the node token (pre-wire-in)"

render_node="$(SINGULAR_CTX_MANIFEST=1 SINGULAR_JSON_CONFIG_FILE="$drv_root/singular.config.json" \
  singular_ctx_rehydrate_authored_config_render $triggers_node)"
[[ "$render_node" == *"=== authored:node-body ==="* ]] \
  || fail "sanity: node-scoped entry must render once the node token is in the set"
[[ "$render_node" != *"plan-only"* ]] \
  || fail "sanity: planner-only entry must never render (no matching dimension)"
pass "(fixture) node token unlocks the node-scoped entry the pre-wire-in set cannot"

# Mock runner (identical to the sibling triggers-wirein test).
mock_runner="$workroot/mock-runner.sh"
cat >"$mock_runner" <<MOCK
#!/usr/bin/env bash
set -uo pipefail
source "$SCRIPT_DIR/lib.sh"
level=""; worktree=""; out=""; meta=""; resume="none"
args=("\$@")
i=0
while [[ \$i -lt \${#args[@]} ]]; do
  case "\${args[\$i]}" in
    --level) level="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    -C|--worktree) worktree="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    --output-last-message) out="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    --session-meta) meta="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    --resume-session) resume="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    *) i=\$((i+1)) ;;
  esac
done
if [[ "\$level" == "l2" ]]; then
  echo "mock l2 worker ran"
  c=0; [[ -f "\${L2_COUNT_FILE:-/dev/null}" ]] && c="\$(cat "\$L2_COUNT_FILE" 2>/dev/null || echo 0)"
  c=\$((c+1)); [[ -n "\${L2_COUNT_FILE:-}" ]] && echo "\$c" > "\$L2_COUNT_FILE"
  [[ -n "\${RESUME_LOG_FILE:-}" ]] && echo "\$c resume=\$resume" >> "\$RESUME_LOG_FILE"
  if [[ -n "\${WORKER_FAIL_ON:-}" && "\$c" == "\${WORKER_FAIL_ON}" ]]; then
    [[ -n "\$out" ]] && : > "\$out"
    exit 0
  fi
  mkdir -p "\$worktree/internal/widget"
  printf 'package widget\n// attempt %s\n' "\$c" > "\$worktree/internal/widget/parser.go"
  [[ -n "\$out" ]] && cat > "\$out" <<'PKT'
{"schema":"singular.orchestration.state-packet.v0","packetId":"p","runId":"r","taskId":"TASK-0001","area":"widget","role":"l2-developer","status":"needs-review","baseRef":"target","branch":"agent/widget/TASK-0001-generic","headSha":"0","workspace":"w","ownedFiles":["internal/widget/parser.go"],"changedFiles":[],"commands":[],"tests":[],"evidence":[],"blockers":[],"nextAction":"await auditor verdict","createdAt":"2026-01-01T00:00:00Z"}
PKT
  [[ -n "\$meta" ]] && singular_codex_session_meta_write "\$meta" "WORKER-SID" "gpt-5.5" "medium" "\$worktree" 0
  exit 0
fi
# read-only: the auditor.
ac=0; [[ -f "\${AUDIT_COUNT_FILE:-/dev/null}" ]] && ac="\$(cat "\$AUDIT_COUNT_FILE" 2>/dev/null || echo 0)"
ac=\$((ac+1)); [[ -n "\${AUDIT_COUNT_FILE:-}" ]] && echo "\$ac" > "\$AUDIT_COUNT_FILE"
[[ -n "\$meta" ]] && singular_codex_session_meta_write "\$meta" "REVIEWER-SID" "gpt-5.5" "high" "\$worktree" 0
if [[ "\${SCENARIO:-accept}" == "needs-fix-first" && "\$ac" -eq 1 ]]; then
  [[ -n "\$out" ]] && printf '{"verdict":"needs-fix","findings":[{"summary":"fix it"}]}\n' > "\$out"
  exit 0
fi
[[ -n "\$out" ]] && python3 -c 'import json,os,sys; o,v=sys.argv[1:3]; d=os.path.dirname(o); f=os.path.join(d,"packet.json"); p=json.load(open(f)) if os.path.isfile(f) else {}; json.dump({"schema":"singular.orchestration.audit-verdict.v0","taskId":p.get("taskId","TASK-0001"),"runId":p.get("runId") or os.path.basename(d),"branch":p.get("branch","unknown"),"verdict":v,"evidenceReviewed":[],"commandsRun":[],"findings":[],"requiredFixes":[],"rationale":"fixture verdict"},open(o,"w"))' "\$out" "accepted"
exit 0
MOCK
chmod +x "$mock_runner"

reset_state() {
  git -C "$drv_root" checkout -q target 2>/dev/null || true
  rm -rf "$drv_root/.singular-state/runs" "$drv_root/.singular-state/leases" \
    "$drv_root/.singular-state/inbox" "$drv_root/.worktrees" 2>/dev/null || true
  : > "$EVENTS"
  rm -f "$drv_root/docs/orchestration/decisions.md" 2>/dev/null || true
  rm -f "$workroot/l2-count" "$workroot/audit-count" "$workroot/resume-log" 2>/dev/null || true
  python3 - "$TASK_MD" <<'PY'
import re, sys
p = sys.argv[1]; t = open(p).read()
t = re.sub(r"Status: \w+", "Status: ready", t, count=1)
open(p, "w").write(t)
PY
  git -C "$drv_root" worktree prune 2>/dev/null || true
  git -C "$drv_root" branch -D agent/widget/TASK-0001-generic 2>/dev/null || true
}

run_drive() {
  ( cd "$drv_root" && env SINGULAR_ROOT="$drv_root" SINGULAR_STATE_DIR="$drv_root/.singular-state" \
      SINGULAR_ORCH_DIR="$drv_root/docs/orchestration" SINGULAR_TASKS_DIR="$drv_root/docs/orchestration/tasks" \
      SINGULAR_TARGET_BRANCH=target SINGULAR_RUNNER="$mock_runner" SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
      L2_COUNT_FILE="$workroot/l2-count" AUDIT_COUNT_FILE="$workroot/audit-count" \
      RESUME_LOG_FILE="$workroot/resume-log" \
      SINGULAR_MAX_RETRIES=1 \
      "$@" "$SCRIPT_DIR/l1-drive.sh" TASK-0001 ) || true
}

run_dir_of() { ls -d "$drv_root"/.singular-state/runs/RUN-* 2>/dev/null | head -1; }

# Extract, from the recorded context.strategy_selected rehydrate event, the sorted
# ids under data.manifest.authored.sources (empty list if no authored block).
recorded_authored_ids() {
  python3 - "$EVENTS" <<'PY'
import json, sys
ids = []
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except json.JSONDecodeError:
        continue
    d = ev.get("data", {})
    if ev.get("type") != "context.strategy_selected" or d.get("strategy") != "rehydrate":
        continue
    authored = d.get("manifest", {}).get("authored")
    if isinstance(authored, dict):
        ids = sorted(s["id"] for s in authored.get("sources", []))
    elif isinstance(authored, list):
        ids = sorted(s["id"] for s in authored)
print(" ".join(ids))
PY
}

AUTHORED_HEADER="## Injected authored knowledge (reference material, NOT authoritative)"

# ---------------------------------------------------------------------------
# (ON) rehydrate + SINGULAR_CTX_MANIFEST=1 + configured contextManifest, with the
# task associated to EXACTLY ONE node (rehydrate-path). Both sites resolve that
# node and pass `implementer implement rehydrate-path TASK-0001`, so the
# node-scoped entry is BOTH injected into $active_prompt (TASK-0062 path) AND
# recorded in the strategy event manifest (TASK-0063 path), alongside the
# role/task/implement-scoped entries; the planner-only entry stays dropped.
# ---------------------------------------------------------------------------
reset_state
emit_assoc "planner.staged" "TASK-0001" "rehydrate-path"
run_drive SINGULAR_CTX_ROUTING=1 SINGULAR_REHYDRATE=1 SINGULAR_CTX_MANIFEST=1 \
  SINGULAR_SESSION_WINDOW_MAX_PCT=0 SCENARIO=needs-fix-first WORKER_FAIL_ON=2 >/dev/null 2>&1
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "ON: no run dir produced"
active_prompt="$run_dir/l2-active-prompt.md"
[[ -f "$active_prompt" ]] || fail "ON: no active prompt produced"
grep -qF "$AUTHORED_HEADER" "$active_prompt" || fail "ON: authored wrapper header missing (injection did not fire)"

# --- Injection site (engine/l1-drive.sh) ------------------------------------
# Backward compat: the implement/role/task-scoped entries still inject.
grep -qF "=== authored:impl-body ===" "$active_prompt" \
  || fail "ON/inject: implement-scoped entry must still inject (backward compat)"
grep -qF "=== authored:role-body ===" "$active_prompt" \
  || fail "ON/inject: role-scoped entry must still inject (backward compat)"
grep -qF "=== authored:task-body ===" "$active_prompt" \
  || fail "ON/inject: task-scoped entry must still inject (backward compat)"
# Node dimension: the node-scoped entry now injects via the resolved node token.
grep -qF "=== authored:node-body ===" "$active_prompt" \
  || fail "ON/inject: node-scoped entry must inject once the node dimension is wired in"
# The planner-only entry never matches any run dimension.
grep -qF "=== authored:plan-only ===" "$active_prompt" \
  && fail "ON/inject: planner-only entry must never inject"
pass "(ON inject) node/role/task/implement-scoped entries injected; planner-only dropped"

# --- Manifest-record site (engine/ctx-rehydrate-event.sh) --------------------
rec_ids="$(recorded_authored_ids)"
assert_eq "$rec_ids" "impl-body node-body role-body task-body" \
  "ON/record: recorded authored ids must include the node-scoped entry (no planner-only)"
pass "(ON record) node/role/task/implement-scoped entries recorded; planner-only dropped"

# --- Injected<->recorded consistency ----------------------------------------
# Both sites resolve the node via singular_ctx_rehydrate_authored_node "$task_id"
# and pass the identical trigger set, so injected == recorded.
injected_ids=""
for id in impl-body node-body role-body task-body; do
  if grep -qF "=== authored:$id ===" "$active_prompt"; then
    injected_ids="${injected_ids:+$injected_ids }$id"
  fi
done
grep -qF "=== authored:plan-only ===" "$active_prompt" && injected_ids="${injected_ids:+$injected_ids }plan-only"
assert_eq "$injected_ids" "$rec_ids" \
  "consistency: injected authored entries must equal recorded authored entries"
pass "(consistency) injected authored set == recorded authored set (identical trigger set)"

# ---------------------------------------------------------------------------
# (Fail-safe: ambiguous association) The task is recorded against TWO distinct
# nodes -> the resolver returns empty -> the node token is NOT supplied, so the
# node-scoped entry is neither injected nor recorded (no fabricated node match),
# while the role/task/implement-scoped entries still match.
# ---------------------------------------------------------------------------
reset_state
emit_assoc "planner.staged"    "TASK-0001" "rehydrate-path"
emit_assoc "planner.generated" "TASK-0001" "other-node"
run_drive SINGULAR_CTX_ROUTING=1 SINGULAR_REHYDRATE=1 SINGULAR_CTX_MANIFEST=1 \
  SINGULAR_SESSION_WINDOW_MAX_PCT=0 SCENARIO=needs-fix-first WORKER_FAIL_ON=2 >/dev/null 2>&1
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "ambig: no run dir produced"
active_prompt="$run_dir/l2-active-prompt.md"
[[ -f "$active_prompt" ]] || fail "ambig: no active prompt produced"
grep -qF "=== authored:node-body ===" "$active_prompt" \
  && fail "ambig: node-scoped entry must NOT inject when the association is ambiguous"
grep -qF "=== authored:impl-body ===" "$active_prompt" \
  || fail "ambig: implement-scoped entry must still inject (fail-safe is node-only)"
grep -qF "=== authored:role-body ===" "$active_prompt" \
  || fail "ambig: role-scoped entry must still inject (fail-safe is node-only)"
grep -qF "=== authored:task-body ===" "$active_prompt" \
  || fail "ambig: task-scoped entry must still inject (fail-safe is node-only)"
assert_eq "$(recorded_authored_ids)" "impl-body role-body task-body" \
  "ambig: recorded authored ids must exclude the node-scoped entry (empty resolver)"
pass "(fail-safe ambiguity) node-scoped entry dropped; role/task/implement-scoped intact"

# ---------------------------------------------------------------------------
# (OFF-parity, manifest flag) SINGULAR_CTX_MANIFEST unset on a rehydrate run with a
# valid single node association: no authored content is injected or recorded — the
# node token changes nothing because the config gate returns empty regardless.
# ---------------------------------------------------------------------------
reset_state
emit_assoc "planner.staged" "TASK-0001" "rehydrate-path"
run_drive SINGULAR_CTX_ROUTING=1 SINGULAR_REHYDRATE=1 \
  SINGULAR_SESSION_WINDOW_MAX_PCT=0 SCENARIO=needs-fix-first WORKER_FAIL_ON=2 >/dev/null 2>&1
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "OFF-manifest: no run dir produced"
active_prompt="$run_dir/l2-active-prompt.md"
[[ -f "$active_prompt" ]] || fail "OFF-manifest: no active prompt produced"
grep -qF "$AUTHORED_HEADER" "$active_prompt" && fail "OFF-manifest: authored section must be absent"
grep -q "=== authored:" "$active_prompt" && fail "OFF-manifest: no authored entry may inject"
assert_eq "$(recorded_authored_ids)" "" "OFF-manifest: no authored entries may be recorded"
pass "(OFF-parity manifest) SINGULAR_CTX_MANIFEST unset: no authored injection or record"

# ---------------------------------------------------------------------------
# (OFF-parity, rehydrate flag) SINGULAR_REHYDRATE unset -> strategy never
# `rehydrate`, so neither the injection nor the rehydrate event fires at all.
# ---------------------------------------------------------------------------
reset_state
emit_assoc "planner.staged" "TASK-0001" "rehydrate-path"
run_drive SINGULAR_CTX_ROUTING=1 SINGULAR_CTX_MANIFEST=1 \
  SINGULAR_SESSION_WINDOW_MAX_PCT=0 SCENARIO=needs-fix-first WORKER_FAIL_ON=2 >/dev/null 2>&1
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "OFF-rehydrate: no run dir produced"
active_prompt="$run_dir/l2-active-prompt.md"
[[ -f "$active_prompt" ]] || fail "OFF-rehydrate: no active prompt produced"
grep -qF "$AUTHORED_HEADER" "$active_prompt" && fail "OFF-rehydrate: authored section must be absent"
assert_eq "$(recorded_authored_ids)" "" "OFF-rehydrate: no rehydrate event with authored entries"
pass "(OFF-parity rehydrate) SINGULAR_REHYDRATE unset: no rehydrate injection or record"

echo "ALL CTX-REHYDRATE-AUTHORED-NODE-WIREIN TESTS PASSED"
