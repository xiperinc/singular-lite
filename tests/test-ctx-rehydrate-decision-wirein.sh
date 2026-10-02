#!/usr/bin/env bash
set -euo pipefail

# Drives a task through engine/l1-drive.sh in a hermetic SINGULAR_ROOT and asserts
# this slice's driver wire-in for the CORE durable-artifact class `decision-record`
# of DAG node `rehydrate-path` (stage S5-routing, layer engine_runtime).
#
# The repo-level decision record lives OUTSIDE run_dir, so the pure resolver
# singular_ctx_rehydrate_sources never emits it; it must be supplied by the caller
# as a class-tagged extra spec. This slice computes that spec via the pure leaf
# singular_ctx_rehydrate_decision_source "$SINGULAR_ROOT" and threads the IDENTICAL
# spec into BOTH rehydrate sites in the driver:
#   - the packet-injection hook appends it to singular_ctx_rehydrate_sources so the
#     decision record is rendered into $active_prompt, and
#   - the strategy-event record appends it as a trailing extra-id=path to
#     singular_ctx_rehydrate_event_data so the SAME decision record (id + content
#     hash) is recorded in the manifest.
#
# The scenario forces the implementer decision to `rehydrate window-pressure` at
# the non-pinned `implement` step exactly as the sibling inject/event drive tests
# do (attempt 1 OK but auditor needs-fix -> resumable meta; attempt 2 refuses the
# resume under window pressure and upgrades to rehydrate behind SINGULAR_REHYDRATE=1,
# then emits no packet so run_dir is frozen at its attempt-1 state). A durable
# decision log is present under SINGULAR_ROOT.
#
# Assertions:
#   (RED core) ON rehydrate: the injected $active_prompt carries a
#     `=== decision-record ===` section with the decision-log body; the recorded
#     manifest.sources contains an entry id `decision-record` whose sha256 equals
#     sha256(decisions.md); and both resolve to the SAME path + content hash.
#   (OFF-parity) SINGULAR_REHYDRATE unset -> no rehydrate run; neither $active_prompt
#     nor the recorded event data introduces a decision-record source.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-ctx-rehydrate-decision-wirein.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

# Hermetic guard: scrub inherited SINGULAR_* so a leaked knob can't poison the sandbox.
while IFS= read -r _v; do unset "$_v"; done < <(compgen -v | grep '^SINGULAR_' || true)
unset _v

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }

workroot="$(mktemp -d "${TMPDIR:-/tmp}/singular-rehydrate-decision-wirein.XXXXXX")"
trap 'rm -rf "$workroot"' EXIT

# Source lib.sh (which auto-sources the ctx-*.sh bricks) so the test can recompute
# the expected specs with the SAME pure helpers the driver delegates into.
export SINGULAR_ROOT="$workroot/libroot"
export SINGULAR_STATE_DIR="$SINGULAR_ROOT/.singular-state"
export SINGULAR_TARGET_BRANCH="target"
mkdir -p "$SINGULAR_STATE_DIR"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"
[[ "$(type -t singular_ctx_rehydrate_decision_source)" == "function" ]] \
  || fail "singular_ctx_rehydrate_decision_source not defined (leaf missing)"
[[ "$(type -t singular_ctx_rehydrate_sources)" == "function" ]] \
  || fail "singular_ctx_rehydrate_sources not defined (resolver missing)"
[[ "$(type -t singular_ctx_rehydrate_packet)" == "function" ]] \
  || fail "singular_ctx_rehydrate_packet not defined (assembler missing)"

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
DECISION_LOG="$drv_root/docs/orchestration/decisions.md"

# The distinctive decision-log body. A marker string lets us assert the body is
# rendered into the injected packet verbatim.
DECISION_MARKER="DECISION-RECORD-BODY-MARKER-8f3a"

# Mock runner (identical structure to the sibling inject/event drive tests).
mock_runner="$workroot/mock-runner.sh"
cat >"$mock_runner" <<MOCK
#!/usr/bin/env bash
set -uo pipefail
source "$SCRIPT_DIR/lib.sh"
level=""; worktree=""; out=""; meta=""
args=("\$@")
i=0
while [[ \$i -lt \${#args[@]} ]]; do
  case "\${args[\$i]}" in
    --level) level="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    -C|--worktree) worktree="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    --output-last-message) out="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    --session-meta) meta="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    *) i=\$((i+1)) ;;
  esac
done
if [[ "\$level" == "l2" ]]; then
  echo "mock l2 worker ran"
  c=0; [[ -f "\${L2_COUNT_FILE:-/dev/null}" ]] && c="\$(cat "\$L2_COUNT_FILE" 2>/dev/null || echo 0)"
  c=\$((c+1)); [[ -n "\${L2_COUNT_FILE:-}" ]] && echo "\$c" > "\$L2_COUNT_FILE"
  if [[ -n "\${WORKER_FAIL_ON:-}" && "\$c" == "\${WORKER_FAIL_ON}" ]]; then
    # Snapshot the (mutating) decision log at exactly rehydrate time: the event
    # record + packet injection for this attempt have already fired, and the next
    # decider append happens only AFTER this worker returns. So this snapshot is the
    # byte-exact decision-record state both rehydrate sites resolved.
    [[ -n "\${DECISION_SNAPSHOT:-}" && -f "\$SINGULAR_ROOT/docs/orchestration/decisions.md" ]] \
      && cp "\$SINGULAR_ROOT/docs/orchestration/decisions.md" "\$DECISION_SNAPSHOT"
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
  rm -f "$workroot/l2-count" "$workroot/audit-count" 2>/dev/null || true
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
      DECISION_SNAPSHOT="$workroot/decision-snapshot.md" \
      SINGULAR_MAX_RETRIES=1 \
      "$@" "$SCRIPT_DIR/l1-drive.sh" TASK-0001 ) || true
}

run_dir_of() { ls -d "$drv_root"/.singular-state/runs/RUN-* 2>/dev/null | head -1; }

# The LAST implementer context.strategy_selected event's `data` object.
last_impl_strategy_data() {
  python3 - "$1" <<'PY'
import json, sys
last = None
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except json.JSONDecodeError:
        continue
    if ev.get("type") != "context.strategy_selected":
        continue
    d = ev.get("data", {})
    if isinstance(d, dict) and d.get("role") == "implementer":
        last = d
if last is None:
    sys.exit(3)
sys.stdout.write(json.dumps(last, sort_keys=True, separators=(",", ":")))
PY
}

sha256_of() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

# ---------------------------------------------------------------------------
# (RED core) ON rehydrate with a durable decision log present under SINGULAR_ROOT:
# the injected packet carries the decision-record body, and the recorded manifest
# records the decision-record id + content hash; both agree by construction.
# ---------------------------------------------------------------------------
reset_state
rm -f "$workroot/decision-snapshot.md"
printf '# Orchestration Decisions\n\n%s\n\n- rehydrate closes the last core coverage gap\n' "$DECISION_MARKER" > "$DECISION_LOG"

run_drive SINGULAR_CTX_ROUTING=1 SINGULAR_REHYDRATE=1 SINGULAR_SESSION_WINDOW_MAX_PCT=0 \
  SCENARIO=needs-fix-first WORKER_FAIL_ON=2 >/dev/null 2>&1
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "ON: no run dir produced"
active_prompt="$run_dir/l2-active-prompt.md"
[[ -f "$active_prompt" ]] || fail "ON: no active prompt produced"

# The decision log MUTATES during a drive (the decider appends records), so the
# consistency invariant is checked against the byte-exact decision-log state at
# rehydrate time, snapshotted by the mock worker on the failing (rehydrate) attempt
# AFTER both rehydrate sites fired and BEFORE the next decider append.
snap="$workroot/decision-snapshot.md"
[[ -f "$snap" ]] || fail "ON: rehydrate-time decision snapshot missing (worker never reached rehydrate attempt)"
rehydrate_time_sha="$(sha256_of "$snap")"
grep -qF "$DECISION_MARKER" "$snap" || fail "ON: rehydrate-time decision log lost its body marker (sanity)"

# (packet injection) the decision-record section + its body appear in the packet.
grep -qF "=== decision-record ===" "$active_prompt" \
  || fail "ON: injected packet missing '=== decision-record ===' section"
grep -qF "$DECISION_MARKER" "$active_prompt" \
  || fail "ON: injected packet missing the decision-log body marker"
pass "(ON packet) decision-record section + body injected into active prompt"

# (manifest recording) the strategy event records id decision-record + its hash.
data="$(last_impl_strategy_data "$EVENTS")" || fail "ON: no implementer strategy_selected event"
assert_eq "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("strategy"))' "$data")" \
  "rehydrate" "ON: strategy recorded as rehydrate"
recorded_sha="$(python3 -c '
import json, sys
d = json.loads(sys.argv[1])
srcs = d.get("manifest", {}).get("sources", [])
hit = [s for s in srcs if s.get("id") == "decision-record"]
print(hit[0]["sha256"] if hit else "")' "$data")"
[[ -n "$recorded_sha" ]] || fail "ON: manifest.sources has no decision-record entry"
pass "(ON manifest) decision-record id + content sha256 recorded in the event manifest"

# (consistency) the recorded manifest hash equals the sha256 of the decision log
# AS RESOLVED at rehydrate time (the same bytes rendered into the injected packet),
# so the injected and recorded decision-record share the SAME path + content hash.
assert_eq "$recorded_sha" "$rehydrate_time_sha" "ON: recorded decision-record sha256 == sha256(decision log at rehydrate time)"
pass "(ON consistency) injected and recorded decision-record share path + content hash"

# ---------------------------------------------------------------------------
# (OFF-parity) SINGULAR_REHYDRATE unset -> no rehydrate run; neither the active
# prompt nor the recorded event data introduces a decision-record source, even
# though the decision log is present.
# ---------------------------------------------------------------------------
reset_state
printf '# Orchestration Decisions\n\n%s\n' "$DECISION_MARKER" > "$DECISION_LOG"
run_drive SINGULAR_CTX_ROUTING=1 SINGULAR_SESSION_WINDOW_MAX_PCT=0 \
  SCENARIO=needs-fix-first WORKER_FAIL_ON=2 >/dev/null 2>&1
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "OFF: no run dir produced"
active_prompt="$run_dir/l2-active-prompt.md"
[[ -f "$active_prompt" ]] || fail "OFF: no active prompt produced"
grep -qF "=== decision-record ===" "$active_prompt" \
  && fail "OFF: decision-record section must be absent (no rehydrate run)"
data="$(last_impl_strategy_data "$EVENTS")" || fail "OFF: no implementer strategy_selected event"
[[ "$data" != *"decision-record"* ]] \
  || fail "OFF: event data must not introduce a decision-record source"
pass "(OFF) SINGULAR_REHYDRATE unset: no decision-record injected or recorded"

echo "ALL CTX-REHYDRATE-DECISION-WIREIN TESTS PASSED"
