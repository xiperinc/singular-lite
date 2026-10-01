#!/usr/bin/env bash
set -euo pipefail

# E5 (0.5.0): a dispatch against an `accepted` lease whose packet never reached
# the inbox auto-heals via accept-existing-packet (exit 0, packet enqueued)
# instead of refusing forever (0.4.0: infinite exit-2 loop -> breaker).
# Since 0.23.4 the auto-heal publishes only through the acceptance predicate;
# this fixture has no accepted certificate, so every route must refuse
# (a decided exit 3, not the old exit-2 refusal loop) and publish nothing.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-dispatch-auto-accept.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

root="$tmp/repo"
mkdir -p "$root/docs/orchestration/tasks" "$root/docs/orchestration/packets/imported" \
  "$root/schemas/orchestration" "$root/.singular-state/leases" "$root/.singular-state/inbox" \
  "$root/.singular-state/runs" "$root/docs/orchestration/prompts"
git -C "$root" init -q
git -C "$root" checkout -q -b target
cp "$ENGINE_HOME/schemas/state-packet.v0.schema.json" "$root/schemas/orchestration/"
cp "$ENGINE_HOME/schemas/audit-verdict.v0.schema.json" "$root/schemas/orchestration/"
cp "$ENGINE_HOME/schemas/audit-verdict.v1.schema.json" "$root/schemas/orchestration/"
cp "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md" "$root/docs/orchestration/prompts/"
cp "$ENGINE_HOME/templates/prompts/auditor.md" "$root/docs/orchestration/prompts/"
cat >"$root/singular.config.json" <<'JSON'
{"schemaVersion":"v2","targetBranch":"target","gateCommand":"true"}
JSON
mkdir -p "$root/internal/artifact"
echo "package artifact" >"$root/internal/artifact/doc.go"
git -C "$root" add . && git -C "$root" -c user.name=t -c user.email=t@t commit -q -m init

export SINGULAR_ROOT="$root"
export SINGULAR_ORCH_DIR="$root/docs/orchestration"
export SINGULAR_TASKS_DIR="$SINGULAR_ORCH_DIR/tasks"
export SINGULAR_STATE_DIR="$root/.singular-state"
export SINGULAR_LEASES_DIR="$SINGULAR_STATE_DIR/leases"
export SINGULAR_INBOX_DIR="$SINGULAR_STATE_DIR/inbox"
export SINGULAR_RUNS_DIR="$SINGULAR_STATE_DIR/runs"
export SINGULAR_DISPATCH_DIR="$SINGULAR_STATE_DIR/dispatch"
export SINGULAR_EVENTS_FILE="$SINGULAR_STATE_DIR/events.ndjson"
export SINGULAR_WORKTREES_DIR="$root/.worktrees"
export SINGULAR_AUDIT_SCHEMA="$root/schemas/orchestration/audit-verdict.v0.schema.json"
export SINGULAR_TARGET_BRANCH="target"

cat >"$SINGULAR_TASKS_DIR/TASK-9001.md" <<'EOF'
# TASK-9001: Auto-accept fixture

Status: accepted
Area: artifact
Target branch: `target`
Worker branch: `agent/artifact/TASK-9001-test`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Heal a stranded accepted packet.

## Scope

Owned files:

- `internal/artifact/a.go`
- `internal/artifact/a_test.go`

Forbidden files:

- `internal/artifact/doc.go`

## Acceptance Criteria

- Pass.
EOF

run_id="RUN-HEAL-9001"
branch="agent/artifact/TASK-9001-test"
base="$(git -C "$root" rev-parse target)"
# The worktree at l1-drive's own derived path triggers the accepted-lease arm.
worktree="$SINGULAR_WORKTREES_DIR/TASK-9001"
mkdir -p "$SINGULAR_WORKTREES_DIR"
git -C "$root" branch "$branch" target
git -C "$root" worktree add -q "$worktree" "$branch"
echo "package artifact" >"$worktree/internal/artifact/a.go"
printf 'package artifact\n\nimport "testing"\n\nfunc TestFixture(t *testing.T) {}\n' \
  >"$worktree/internal/artifact/a_test.go"
mkdir -p "$worktree/.singular-evidence"
echo red >"$worktree/.singular-evidence/red.log"
echo green >"$worktree/.singular-evidence/green.log"
echo regression >"$worktree/.singular-evidence/regression.log"
git -C "$worktree" add internal/artifact/a.go internal/artifact/a_test.go
git -C "$worktree" -c user.name=t -c user.email=t@t commit -q -m "TASK-9001 worker"
head="$(git -C "$worktree" rev-parse HEAD)"

run_dir="$SINGULAR_RUNS_DIR/$run_id"
mkdir -p "$run_dir"
cat >"$run_dir/packet.json" <<EOF
{
  "schema": "singular.orchestration.state-packet.v0",
  "packetId": "TASK-9001-$run_id",
  "runId": "$run_id",
  "taskId": "TASK-9001",
  "area": "artifact",
  "role": "l2-developer",
  "status": "needs-review",
  "baseRef": "$base",
  "branch": "$branch",
  "headSha": "$head",
  "workspace": "$worktree",
  "ownedFiles": ["internal/artifact/a.go", "internal/artifact/a_test.go"],
  "changedFiles": ["internal/artifact/a.go", "internal/artifact/a_test.go"],
  "commands": [
    {"cmd": "test -f internal/artifact/a.go", "exitCode": 0, "logRef": ".singular-evidence/green.log"}
  ],
  "tests": [
    {"name": "fixture red", "phase": "red", "status": "failed-as-expected", "logRef": ".singular-evidence/red.log"},
    {"name": "fixture green", "phase": "green", "status": "passed", "logRef": ".singular-evidence/green.log"},
    {"name": "fixture regression", "phase": "regression", "status": "passed", "logRef": ".singular-evidence/regression.log"}
  ],
  "evidence": [
    {"kind": "red-log", "ref": ".singular-evidence/red.log"},
    {"kind": "green-log", "ref": ".singular-evidence/green.log"},
    {"kind": "regression-log", "ref": ".singular-evidence/regression.log"}
  ],
  "blockers": [],
  "nextAction": "await review",
  "createdAt": "2026-06-03T00:00:00Z"
}
EOF

cat >"$SINGULAR_LEASES_DIR/TASK-9001.json" <<EOF
{
  "taskId": "TASK-9001",
  "branch": "$branch",
  "area": "artifact",
  "owner": "l2-developer",
  "fileScope": "internal/artifact/a.go internal/artifact/a_test.go",
  "ownedFiles": ["internal/artifact/a.go", "internal/artifact/a_test.go"],
  "forbiddenFiles": ["internal/artifact/doc.go"],
  "baseSha": "$base",
  "status": "accepted",
  "runId": "$run_id",
  "worktree": "$worktree",
  "retryCount": 0,
  "createdAt": "2026-06-03T00:00:00Z",
  "updatedAt": "2026-06-03T00:00:00Z"
}
EOF

# 0.23.4: an accepted packet is published only when the acceptance predicate
# (host gate G, fresh accepted audit A, review-ledger round D, evidence E)
# holds for the exact candidate. This fixture has none of them -- no fresh
# audit, no ledger round, no host verification -- so no route may publish it.
# The positive auto-heal path, with a genuine accepted certificate, is pinned
# in tests/test-acceptance-invariant.sh.
assert_unpublished() {
  [[ ! -f "$SINGULAR_INBOX_DIR/$run_id.json" ]] || fail "$1: packet was enqueued"
  [[ ! -f "$run_dir/audit.json" ]] || fail "$1: an audit was manufactured"
  [[ "$(cat "$SINGULAR_EVENTS_FILE" 2>/dev/null || true)" != *'"type":"packet.accepted_existing"'* ]] \
    || fail "$1: deterministic re-acceptance ran"
}

# 1. Accepted lease, unaccepted packet, no audit: recognized as an invalid
#    retained acceptance and refused with the checkpoint preserved.
rc=0
out="$(bash "$SCRIPT_DIR/l1-drive.sh" TASK-9001 2>&1)" || rc=$?
assert_eq "$rc" "3" "invalid retained acceptance is refused (out: $out)"
assert_contains "$out" "accepted-checkpoint-invalid-retained-state" "refusal reason"
assert_unpublished "invalid retained acceptance"
assert_eq "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$run_dir/packet.json")" \
  "needs-review" "packet left unaccepted"

# 2. A stranded packet marked accepted but carrying no fresh audit reaches the
#    E5 auto-heal route (evidence resume disabled). The acceptance predicate
#    refuses before accept-existing-packet can author an audit of its own.
python3 - "$run_dir/packet.json" <<'PY2'
import json, sys
p = json.load(open(sys.argv[1]))
p["status"] = "accepted"
json.dump(p, open(sys.argv[1], "w"), indent=2)
PY2
rc=0
out="$(SINGULAR_RESUME_ACCEPTED_EVIDENCE=0 bash "$SCRIPT_DIR/l1-drive.sh" TASK-9001 2>&1)" || rc=$?
assert_eq "$rc" "3" "stranded packet without an audit is refused (out: $out)"
assert_unpublished "stranded packet without an audit"
assert_contains "$(cat "$SINGULAR_EVENTS_FILE")" '"type":"l1.acceptance_refused"' "predicate refusal event"
assert_contains "$(cat "$SINGULAR_EVENTS_FILE")" '"path":"stranded-packet"' "refusal names the auto-heal route"
assert_contains "$(cat "$SINGULAR_EVENTS_FILE")" '"reason":"audit-missing"' "refusal reason"

# 3. The same packet through the default evidence-resume route is refused too.
rc=0
out="$(bash "$SCRIPT_DIR/l1-drive.sh" TASK-9001 2>&1)" || rc=$?
assert_eq "$rc" "3" "accepted packet without an audit is not resumed (out: $out)"
assert_unpublished "accepted packet without an audit"

echo "PASS: test-dispatch-auto-accept"
