#!/usr/bin/env bash
set -euo pipefail
# Deadlock #6 (field 2026-09-14, stall 8).
#
# The retained-worktree guard in engine/l1-drive.sh refused whenever a worktree
# already existed and the lease status was running|planned|needs-review|
# integrated -- without asking WHOSE reservation that was. In detached dispatch
# the scheduler writes a `planned` lease before l1-drive starts, so the driver
# was refused by its own reservation. The task could only proceed if an operator
# removed the worktree by hand and then unparked.
#
# The fix compares the lease's reservation identity with the driver's own
# (SINGULAR_RESERVATION_OWNER/_GENERATION, exported by dispatch-wrap.sh).
# Simply dropping `planned` from the list would have admitted a FOREIGN worker
# to a live candidate -- an S1 violation -- so ownership is the discriminator,
# and accepted/integrated still refuse regardless of who owns them.
#
# Dedicated test: tests/test-detached-dispatch.sh is recorded red in
# tests/BASELINE-FAILURES.md and cannot be extended for coverage.
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-retained-worktree-ownership.sh requires bash >= 4" >&2; exit 1
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT/engine"
ENGINE_HOME="$ROOT"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
FIXTURE_TMP=""
cleanup() { [[ -n "$FIXTURE_TMP" ]] && rm -rf "$FIXTURE_TMP"; }
trap cleanup EXIT

make_repo() {
  local root="$1"
  mkdir -p "$root/docs/orchestration/prompts" "$root/docs/orchestration/tasks" "$root/.singular-state"
  git -C "$root" init -q
  git -C "$root" checkout -q -b target
  cp "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md" "$root/docs/orchestration/prompts/"
  cp "$ENGINE_HOME/templates/prompts/auditor.md" "$root/docs/orchestration/prompts/"
  cp "$ENGINE_HOME/templates/prompts/decider.md" "$root/docs/orchestration/prompts/"
  printf '.singular-state/\n.worktrees/\n.singular-evidence/\n' >"$root/.gitignore"
  mkdir -p "$root/internal/widget"; printf 'package widget\n' >"$root/internal/widget/parser.go"
  git -C "$root" add .
  git -C "$root" -c user.name=test -c user.email=test@example.local commit -q -m init
}

with_fixture() {
  FIXTURE_TMP="$(mktemp -d)"
  make_repo "$FIXTURE_TMP/repo"
  export SINGULAR_ROOT="$FIXTURE_TMP/repo"
  export SINGULAR_ORCH_DIR="$SINGULAR_ROOT/docs/orchestration"
  export SINGULAR_TASKS_DIR="$SINGULAR_ORCH_DIR/tasks"
  export SINGULAR_STATE_DIR="$SINGULAR_ROOT/.singular-state"
  export SINGULAR_RUNS_DIR="$SINGULAR_STATE_DIR/runs"
  export SINGULAR_INBOX_DIR="$SINGULAR_STATE_DIR/inbox"
  export SINGULAR_LEASES_DIR="$SINGULAR_STATE_DIR/leases"
  export SINGULAR_EVENTS_FILE="$SINGULAR_STATE_DIR/events.ndjson"
  export SINGULAR_STOP_FILE="$SINGULAR_STATE_DIR/STOP"
  export SINGULAR_WORKTREES_DIR="$SINGULAR_ROOT/.worktrees"
  export SINGULAR_TARGET_BRANCH="target" SINGULAR_ENGINE_HOME="$ENGINE_HOME"
  # Each case builds a fresh repo. lib.sh exports the resolved JSON-config
  # location on every source, so a second fixture would inherit the FIRST
  # repo's path, flip SINGULAR_JSON_CONFIG_SOURCE to "selector", and die on the
  # missing-file guard at lib.sh:210. (That is the same mechanism recorded for
  # baseline entries 1 and 4.) Clear the resolution before re-sourcing.
  unset SINGULAR_RUNNER SINGULAR_RESERVATION_OWNER SINGULAR_RESERVATION_GENERATION \
    SINGULAR_JSON_CONFIG_FILE SINGULAR_JSON_CONFIG_SOURCE \
    SINGULAR_JSON_CONFIG_DEFAULT_ROOT SINGULAR_JSON_CONFIG_DEFAULT_FILE \
    SINGULAR_CONFIG_FILE SINGULAR_LOCAL_CONFIG_FILE 2>/dev/null || true
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib.sh"
  cat >"$SINGULAR_TASKS_DIR/TASK-0001.md" <<'EOF'
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
  # A runner that records its invocation and stops; this test is about the
  # admission decision, not about what a worker produces.
  RUNNER_CALLS="$SINGULAR_STATE_DIR/runner-calls"; : >"$RUNNER_CALLS"
  local stub="$FIXTURE_TMP/runner.sh"
  cat >"$stub" <<SH
#!/usr/bin/env bash
printf 'invoked\n' >>"$RUNNER_CALLS"
exit 124
SH
  chmod +x "$stub"; export SINGULAR_RUNNER="$stub"
}

# A retained worktree holding a committed candidate, plus a lease at the given
# status owned by <owner>@<generation>.
retain_worktree_with_lease() {
  local status="$1" owner="$2" generation="$3"
  local branch=agent/widget/TASK-0001-generic
  local wt="$SINGULAR_WORKTREES_DIR/TASK-0001"
  local base; base="$(git -C "$SINGULAR_ROOT" rev-parse target)"
  mkdir -p "$SINGULAR_WORKTREES_DIR"
  git -C "$SINGULAR_ROOT" branch "$branch" target 2>/dev/null || true
  git -C "$SINGULAR_ROOT" worktree add -q "$wt" "$branch"
  printf 'package widget // retained\n' >"$wt/internal/widget/parser.go"
  git -C "$wt" add internal/widget/parser.go
  git -C "$wt" -c user.name=test -c user.email=test@example.local commit -qm 'retained candidate'
  singular_lease_write TASK-0001 "$branch" widget l2-developer \
    "internal/widget/parser.go" "$status" RUN-X "$wt" "$base" BATCH \
    '["internal/widget/parser.go"]' '[]'
  python3 - "$(singular_lease_path TASK-0001)" "$owner" "$generation" <<'PY'
import json, sys
p, owner, gen = sys.argv[1], sys.argv[2], int(sys.argv[3])
d = json.load(open(p, encoding="utf-8"))
d["reservationOwner"] = owner; d["reservationGeneration"] = gen
d["reservationRunId"] = "RUN-X"
json.dump(d, open(p, "w", encoding="utf-8"), indent=2)
PY
}

drive() {
  local rc=0 out
  out="$("$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
  DRIVE_OUT="$out"; DRIVE_RC="$rc"
}

REFUSAL='active/accepted worktree'

# --- 1. self-owned planned lease: the driver's own reservation --------------
with_fixture
retain_worktree_with_lease planned self-owner 4
export SINGULAR_RESERVATION_OWNER=self-owner SINGULAR_RESERVATION_GENERATION=4
drive
[[ "$DRIVE_OUT" != *"$REFUSAL"* ]] \
  || fail "driver refused its own reservation on a retained worktree: $DRIVE_OUT"
[[ "$DRIVE_OUT" == *"assessing retained worktree"* ]] \
  || fail "driver did not reach retained-candidate assessment: $DRIVE_OUT"
pass "a self-owned planned lease admits the driver to its own retained worktree"
cleanup

# --- 2. foreign-owned planned lease: still refused (S1) ---------------------
with_fixture
retain_worktree_with_lease planned other-owner 7
export SINGULAR_RESERVATION_OWNER=self-owner SINGULAR_RESERVATION_GENERATION=4
drive
[[ "$DRIVE_OUT" == *"$REFUSAL"* ]] \
  || fail "driver admitted a FOREIGN reservation's retained worktree: $DRIVE_OUT"
[[ "$DRIVE_RC" == 2 ]] || fail "foreign-owned refusal did not exit 2 (got $DRIVE_RC)"
[[ ! -s "$RUNNER_CALLS" ]] || fail "a worker ran against a foreign reservation's candidate"
pass "a foreign-owned planned lease is still refused"
cleanup

# --- 3. no reservation identity at all: fail closed -------------------------
with_fixture
retain_worktree_with_lease planned self-owner 4
unset SINGULAR_RESERVATION_OWNER SINGULAR_RESERVATION_GENERATION
drive
[[ "$DRIVE_OUT" == *"$REFUSAL"* ]] \
  || fail "driver admitted itself without proving its own reservation: $DRIVE_OUT"
pass "a driver that cannot prove its own reservation is refused"
cleanup

# --- 4. accepted and integrated refuse regardless of ownership --------------
for terminal_status in accepted integrated; do
  with_fixture
  retain_worktree_with_lease "$terminal_status" self-owner 4
  export SINGULAR_RESERVATION_OWNER=self-owner SINGULAR_RESERVATION_GENERATION=4
  drive
  # `accepted` is refused by the accepted-checkpoint path (exit 3) rather than
  # the retained-worktree guard (exit 2); both are refusals. The invariant is
  # that a terminal lease never reaches implementation, whoever owns it.
  [[ "$DRIVE_RC" != 0 ]] \
    || fail "$terminal_status lease was admitted to implementation: $DRIVE_OUT"
  [[ ! -s "$RUNNER_CALLS" ]] || fail "$terminal_status lease reached a worker"
  [[ "$DRIVE_OUT" != *"ACCEPTED: TASK-0001"* ]] \
    || fail "$terminal_status lease minted an acceptance: $DRIVE_OUT"
  pass "a $terminal_status lease is refused even for its own owner"
  cleanup
done

echo "test-retained-worktree-ownership: ok"
