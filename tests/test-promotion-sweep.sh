#!/usr/bin/env bash
# Promotion is re-attempted after a stale sibling is superseded, even while
# other work keeps the dispatch queue non-empty. Repeated unchanged attempts
# are suppressed; a changed target head permits a new attempt.
# No provider is launched: the promoter is a fixture and nothing is dispatched.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-promotion-sweep.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2' in: $1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
root="$tmp/repo"
mkdir -p "$root/docs/orchestration/tasks/superseded" "$root/docs/orchestration/gates" "$root/.singular-state"
git -C "$root" init -q
git -C "$root" checkout -q -b target
cat >"$root/docs/orchestration/dag.v0.json" <<'JSON'
{
  "schema": "singular.orchestration.dag.v0",
  "nodes": [
    {"id":"fixture-widget","stage":"W3","area":"ws","layer":"feature","kind":"build","dependsOn":[],"requiredCompletion":"done"},
    {"id":"other","stage":"W3","area":"other","layer":"feature","kind":"build","dependsOn":[],"requiredCompletion":"done"}
  ]
}
JSON
# task <id> <node> <status> [subdir]
task() {
  cat >"$root/docs/orchestration/tasks${4:+/$4}/$1.md" <<TASK
# $1: fixture

Status: $3
Area: $2
DAG node: $2
Target branch: \`target\`
Worker branch: \`agent/$2/$1-fixture\`
Test policy: \`strict_test_first\`
Gate command: \`true\`
Dispatch mode: canonical
Depends on: []

## Objective

Fixture.

## Scope

Owned files:

- \`src/$2/$1.txt\`

## Acceptance Criteria

- The gate command passes.
TASK
}
task TASK-0022 fixture-widget integrated
task TASK-0021 fixture-widget ready      # the stale sibling, still open
printf '.singular-state/\n.worktrees/\n' >"$root/.gitignore"
git -C "$root" add . && git -C "$root" -c user.email=t@t -c user.name=t commit -q -m init

promoter="$tmp/fake-promoter.sh"
cat >"$promoter" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PROMOTER_LOG"
echo "FAKE-PROMOTER argv:$*"
node="${*: -1}"
if [[ "${FAKE_PROMOTE:-0}" == "1" && "$node" != --* ]]; then
  cat >"$SINGULAR_ORCH_DIR/gates/$node.gate-result.json" <<JSON
{"schema":"singular.orchestration.gate-result.v0","node":"$node","status":"passed","authoritative":true,"evidenceClass":"grandfathered","evidence":[{"kind":"source-path","ref":"docs/orchestration/dag.v0.json"}],"decidedBy":"test-promoter","recordedAt":"2000-01-01T00:00:00Z"}
JSON
  echo "promoted node=$node"
else
  echo "not ready"
fi
SH
chmod +x "$promoter"
export PROMOTER_LOG="$tmp/promoter.log"; : >"$PROMOTER_LOG"

common_env() {
  env SINGULAR_ROOT="$root" SINGULAR_STATE_DIR="$root/.singular-state" \
    SINGULAR_ORCH_DIR="$root/docs/orchestration" SINGULAR_TASKS_DIR="$root/docs/orchestration/tasks" \
    SINGULAR_LEASES_DIR="$root/.singular-state/leases" SINGULAR_INBOX_DIR="$root/.singular-state/inbox" \
    SINGULAR_RUNS_DIR="$root/.singular-state/runs" SINGULAR_WORKTREES_DIR="$root/.worktrees" \
    SINGULAR_DISPATCH_DIR="$root/.singular-state/dispatch" \
    SINGULAR_EVENTS_FILE="$root/.singular-state/events.ndjson" \
    SINGULAR_TARGET_BRANCH=target SINGULAR_PUSH=0 SINGULAR_GENERATE=0 SINGULAR_AUTO_INTEGRATE=0 \
    SINGULAR_L1_DRIVER=/usr/bin/false SINGULAR_RUNNER=/nonexistent/runner SINGULAR_CODEX_RUNNER=/nonexistent/runner \
    SINGULAR_L1_PLAN_NODE=/usr/bin/false SINGULAR_PLAN_CRITIQUE=0 SINGULAR_CODEX_BIN=/usr/bin/false \
    SINGULAR_MAX_DISPATCH=0 SINGULAR_RESOURCE_THROTTLE=0 \
    SINGULAR_PROMOTER="$promoter" "$@"
}
node_calls() { grep -c -- "--from-reconcile --if-ready $1\$" "$PROMOTER_LOG" || true; }
sweeps() { grep -c '"type":"origin.promotion_reattempted"' "$root/.singular-state/events.ndjson" 2>/dev/null || true; }

# --- 1. while the sibling is open the node is not pending: no attempt --------
out="$(common_env "$SCRIPT_DIR/reconcile.sh" --actuate 2>&1 || true)"
assert_eq "$(node_calls fixture-widget)" "0" "no promotion attempt while a sibling task is open"

# --- 2. the sibling is superseded; nothing integrates; the queue is not empty --
git -C "$root" mv docs/orchestration/tasks/TASK-0021.md docs/orchestration/tasks/superseded/TASK-0021.md
sed -i.bak 's/^Status: ready$/Status: superseded/' "$root/docs/orchestration/tasks/superseded/TASK-0021.md"
rm -f "$root/docs/orchestration/tasks/superseded/TASK-0021.md.bak"
printf 'Superseded by: TASK-0022\n' >/dev/null
python3 - "$root/docs/orchestration/tasks/superseded/TASK-0021.md" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read().replace("Status: superseded\n", "Status: superseded\nSuperseded by: TASK-0022\n", 1)
open(path, "w", encoding="utf-8").write(text)
PY
task TASK-0099 other ready            # keeps the dispatch queue non-empty
git -C "$root" add -A && git -C "$root" -c user.email=t@t -c user.name=t commit -q -m "supersede the stale sibling"
out="$(common_env "$SCRIPT_DIR/reconcile.sh" --actuate 2>&1 || true)"
assert_not_contains "$out" "completion frontier eligible" "precondition: the queue is not empty, so the frontier pass does not run"
assert_contains "$out" "promotion sweep: node fixture-widget is pending promotion" "the cycle re-attempts promotion of the completed node"
assert_eq "$(node_calls fixture-widget)" "1" "the promoter was invoked for the node"
assert_eq "$(node_calls other)" "0" "a node with open work is not attempted"
assert_eq "$(sweeps)" "1" "one origin.promotion_reattempted event"
assert_contains "$(grep '"type":"origin.promotion_reattempted"' "$root/.singular-state/events.ndjson")" \
  '"node":"fixture-widget","outcome":"not-promoted"' "the event names the node and outcome"
assert_contains "$out" "gates_promoted_this_run=0" "an attempt that promotes nothing reports no progress"
echo "ok: a completed node is re-attempted on a later cycle, with work still queued"

# --- 3. unchanged task set and HEAD: skipped --------------------------------
out="$(common_env "$SCRIPT_DIR/reconcile.sh" --actuate 2>&1 || true)"
assert_eq "$(node_calls fixture-widget)" "1" "no second promoter run while nothing changed"
assert_not_contains "$out" "promotion sweep: node fixture-widget" "the unchanged node is skipped quietly"
assert_eq "$(sweeps)" "1" "no event for a skipped node"
echo "ok: a node whose task set and HEAD are unchanged is not re-attempted"

# --- 4. HEAD moves: attempted again, and a real transition counts as progress -
git -C "$root" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "target moves"
out="$(common_env env FAKE_PROMOTE=1 "$SCRIPT_DIR/reconcile.sh" --actuate 2>&1 || true)"
assert_eq "$(node_calls fixture-widget)" "2" "a new HEAD is a new attempt"
assert_contains "$out" "gates_promoted_this_run=1" "a validated gate transition is reported as progress"
assert_contains "$(grep '"type":"origin.promotion_reattempted"' "$root/.singular-state/events.ndjson" | tail -1)" \
  '"outcome":"promoted"' "the event records the promotion"
out="$(common_env env FAKE_PROMOTE=1 "$SCRIPT_DIR/reconcile.sh" --actuate 2>&1 || true)"
assert_eq "$(node_calls fixture-widget)" "2" "a promoted node is never attempted again"
echo "ok: a changed HEAD re-attempts, and promotion is counted"

# --- 5. bounded per cycle; opt-out ------------------------------------------
for n in 1 2 3; do
  task "TASK-020$n" "n$n" integrated
done
git -C "$root" add -A && git -C "$root" -c user.email=t@t -c user.name=t commit -q -m "three more completed nodes"
before="$(grep -c -- '--if-ready' "$PROMOTER_LOG" || true)"
out="$(common_env env SINGULAR_PROMOTION_SWEEP_MAX=2 "$SCRIPT_DIR/reconcile.sh" --actuate 2>&1 || true)"
after="$(grep -c -- '--if-ready' "$PROMOTER_LOG" || true)"
assert_eq "$((after - before))" "2" "SINGULAR_PROMOTION_SWEEP_MAX bounds the promoter runs per cycle"
assert_contains "$out" "per-cycle bound (2) reached" "the bound is reported"
out="$(common_env "$SCRIPT_DIR/reconcile.sh" --actuate 2>&1 || true)"
assert_eq "$(( $(grep -c -- '--if-ready' "$PROMOTER_LOG" || true) - after ))" "1" "the remaining node is attempted on the next cycle"
git -C "$root" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "target moves again"
before="$(grep -c -- '--if-ready' "$PROMOTER_LOG" || true)"
out="$(common_env env SINGULAR_AUTO_PROMOTE_GATES=0 "$SCRIPT_DIR/reconcile.sh" --actuate 2>&1 || true)"
assert_eq "$(grep -c -- '--if-ready' "$PROMOTER_LOG" || true)" "$before" "SINGULAR_AUTO_PROMOTE_GATES=0 disables the sweep"
echo "ok: the sweep is bounded per cycle and honours the opt-out"
echo "PASS: test-promotion-sweep"
