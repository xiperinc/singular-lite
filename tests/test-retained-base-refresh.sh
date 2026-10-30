#!/usr/bin/env bash
set -euo pipefail
# A retained worker branch falls behind the target whenever the reconciler
# commits control state there; the fresh-dispatch guard then refused it forever
# ("admitted base is not an ancestor"). singular_refresh_retained_branch merges
# the base in, once, without touching owned content — via the live checkout when
# one exists, via plumbing otherwise — and refuses real conflicts.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"; mkdir -p "$repo"
git -C "$repo" init -q; git -C "$repo" config user.name f; git -C "$repo" config user.email f@x
git -C "$repo" checkout -qb target
printf 'base\n' >"$repo/owned.txt"; printf 'ctl0\n' >"$repo/control.txt"
git -C "$repo" add .; git -C "$repo" commit -qm base
git -C "$repo" branch work
git -C "$repo" checkout -q work; printf 'candidate\n' >"$repo/owned.txt"; git -C "$repo" commit -qam candidate
cand="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -q target; printf 'ctl1\n' >"$repo/control.txt"; git -C "$repo" commit -qam "control-state update"
target="$(git -C "$repo" rev-parse HEAD)"
export SINGULAR_ROOT="$repo" SINGULAR_STATE_DIR="$repo/.singular-state"
source "$ROOT/engine/lib.sh" >/dev/null

# 1. Plumbing path (branch not checked out anywhere).
new="$(singular_refresh_retained_branch "$repo" work "$target")" || fail "plumbing refresh failed"
git -C "$repo" merge-base --is-ancestor "$target" "$new" || fail "target not an ancestor after refresh"
git -C "$repo" merge-base --is-ancestor "$cand" "$new" || fail "candidate lost"
[[ "$(git -C "$repo" show "$new:owned.txt")" == candidate ]] || fail "owned content altered"
[[ "$(git -C "$repo" show "$new:control.txt")" == ctl1 ]] || fail "base content missing"
[[ "$(git -C "$repo" rev-parse work)" == "$new" ]] || fail "branch ref not moved"
[[ "$(git -C "$repo" rev-parse target)" == "$target" ]] || fail "target moved"
pass "plumbing refresh merges the base under the candidate without a checkout"

# 2. Idempotent: already a descendant -> prints the head, no new commit.
again="$(singular_refresh_retained_branch "$repo" work "$target")" || fail "idempotent call failed"
[[ "$again" == "$new" ]] || fail "idempotent call created a commit"
pass "already-fresh branch is left alone"

# 3. Checkout path: branch checked out in a clean linked worktree.
git -C "$repo" checkout -q target; printf 'ctl2\n' >"$repo/control.txt"; git -C "$repo" commit -qam "control-state update 2"
target2="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" worktree add -q "$tmp/wt" work
new2="$(singular_refresh_retained_branch "$repo" work "$target2" "$tmp/wt")" || fail "checkout refresh failed"
[[ "$(git -C "$tmp/wt" rev-parse HEAD)" == "$new2" ]] || fail "worktree HEAD not advanced with the ref"
[[ -z "$(git -C "$tmp/wt" status --porcelain)" ]] || fail "worktree left dirty"
[[ "$(cat "$tmp/wt/control.txt")" == ctl2 && "$(cat "$tmp/wt/owned.txt")" == candidate ]] || fail "worktree content wrong"
pass "checkout refresh advances the live worktree together with the ref"

# 4. Dirty checkout refuses; ref untouched.
git -C "$repo" checkout -q target; printf 'ctl3\n' >"$repo/control.txt"; git -C "$repo" commit -qam "control-state update 3"
target3="$(git -C "$repo" rev-parse HEAD)"
printf 'partial\n' >>"$tmp/wt/owned.txt"
if singular_refresh_retained_branch "$repo" work "$target3" "$tmp/wt" 2>/dev/null; then fail "dirty checkout was merged"; fi
[[ "$(git -C "$repo" rev-parse work)" == "$new2" ]] || fail "ref moved despite refusal"
git -C "$tmp/wt" checkout -q -- owned.txt
pass "dirty checkout is refused and the ref stays put"

# 5. Conflict refuses; ref untouched, no merge state left behind.
git -C "$repo" checkout -q target; printf 'conflict\n' >"$repo/owned.txt"; git -C "$repo" commit -qam "conflicting target edit"
target4="$(git -C "$repo" rev-parse HEAD)"
if singular_refresh_retained_branch "$repo" work "$target4" "$tmp/wt" 2>"$tmp/err"; then fail "conflict was merged"; fi
grep -q conflict "$tmp/err" || fail "conflict not reported: $(cat "$tmp/err")"
[[ "$(git -C "$repo" rev-parse work)" == "$new2" ]] || fail "ref moved despite conflict"
[[ ! -f "$tmp/wt/.git/MERGE_HEAD" && ! -f "$repo/.git/worktrees/wt/MERGE_HEAD" ]] || fail "merge state left behind"
pass "conflicting base is refused cleanly"

# 6. (0.23.7) A task parked on a red gate can leave uncommitted work in the
# retained checkout, preventing a later base refresh. The engine commits
# that work on the worker branch as a labelled WIP commit, owned scope only,
# and then refreshes.
repo2="$tmp/repo2"; mkdir -p "$repo2/src"
git -C "$repo2" init -q; git -C "$repo2" config user.name f; git -C "$repo2" config user.email f@x
git -C "$repo2" checkout -qb target
printf 'base\n' >"$repo2/src/owned.txt"; printf 'other0\n' >"$repo2/outside.txt"
git -C "$repo2" add .; git -C "$repo2" commit -qm base
git -C "$repo2" branch work
git -C "$repo2" worktree add -q "$tmp/wt2" work
printf 'other1\n' >"$repo2/outside.txt"; git -C "$repo2" commit -qam "operator fixes the target"
t2="$(git -C "$repo2" rev-parse HEAD)"
export SINGULAR_ROOT="$repo2" SINGULAR_STATE_DIR="$repo2/.singular-state"
before="$(git -C "$repo2" rev-parse work)"
# Nothing to do on a clean checkout.
out="$(singular_retained_wip_commit "$repo2" work TASK-0045 "$tmp/wt2" "src/")" || fail "clean checkout refused"
[[ -z "$out" ]] || fail "clean checkout produced a commit"
# Dirty inside the owned scope: tracked edit plus a new file.
printf 'worker edit\n' >"$tmp/wt2/src/owned.txt"; printf 'new\n' >"$tmp/wt2/src/new.txt"
if singular_refresh_retained_branch "$repo2" work "$t2" "$tmp/wt2" >/dev/null 2>&1; then fail "precondition: dirty checkout merged without a WIP commit"; fi
wip="$(singular_retained_wip_commit "$repo2" work TASK-0045 "$tmp/wt2" "src/" 2>"$tmp/wip.err")" \
  || fail "owned-scope dirt was refused: $(cat "$tmp/wip.err")"
[[ -n "$wip" && "$wip" != "$before" ]] || fail "no WIP commit made"
[[ "$(git -C "$repo2" rev-parse work)" == "$wip" ]] || fail "WIP commit is not on the worker branch"
[[ "$(git -C "$repo2" rev-parse "$wip^")" == "$before" ]] || fail "WIP commit is not a child of the retained head"
git -C "$repo2" log -1 --format=%B "$wip" | grep -q '^wip(singular): preserve uncommitted TASK-0045' || fail "WIP commit is not labelled"
git -C "$repo2" log -1 --format=%B "$wip" | grep -q '^Singular-WIP: TASK-0045' || fail "WIP trailer missing"
git -C "$repo2" log -1 --format=%B "$wip" | grep -q 'No gate and no audit' || fail "WIP commit claims verification"
[[ "$(git -C "$repo2" show "$wip:src/owned.txt")" == "worker edit" && "$(git -C "$repo2" show "$wip:src/new.txt")" == new ]] || fail "worker work not in the WIP commit"
[[ -z "$(git -C "$tmp/wt2" status --porcelain)" ]] || fail "checkout still dirty after the WIP commit"
new="$(singular_refresh_retained_branch "$repo2" work "$t2" "$tmp/wt2")" || fail "refresh after WIP commit failed"
git -C "$repo2" merge-base --is-ancestor "$t2" "$new" || fail "target not an ancestor after WIP + refresh"
git -C "$repo2" merge-base --is-ancestor "$wip" "$new" || fail "WIP commit lost by the refresh"
[[ "$(cat "$tmp/wt2/outside.txt")" == other1 && "$(cat "$tmp/wt2/src/owned.txt")" == "worker edit" ]] || fail "refreshed checkout content wrong"
pass "uncommitted owned work is committed as a labelled WIP commit, then refreshed"

# 7. Dirt outside the owned scope is refused with the path; nothing is committed.
head7="$(git -C "$repo2" rev-parse work)"
printf 'more\n' >>"$tmp/wt2/src/owned.txt"; printf 'stray\n' >"$tmp/wt2/stray.txt"
if singular_retained_wip_commit "$repo2" work TASK-0045 "$tmp/wt2" "src/" >"$tmp/out7" 2>"$tmp/err7"; then fail "out-of-scope dirt was committed"; fi
grep -q 'outside the owned scope of TASK-0045' "$tmp/err7" || fail "refusal does not say why: $(cat "$tmp/err7")"
grep -q 'stray.txt' "$tmp/err7" || fail "refusal does not name the path: $(cat "$tmp/err7")"
[[ ! -s "$tmp/out7" ]] || fail "refusal printed a head"
[[ "$(git -C "$repo2" rev-parse work)" == "$head7" ]] || fail "branch moved despite the refusal"
[[ -z "$(git -C "$tmp/wt2" diff --cached --name-only)" ]] || fail "refusal left paths staged"
[[ -f "$tmp/wt2/stray.txt" && "$(tail -1 "$tmp/wt2/src/owned.txt")" == more ]] || fail "refusal altered the worker's files"
# A forbidden path inside an owned prefix is refused too.
rm -f "$tmp/wt2/stray.txt"; printf 'x\n' >"$tmp/wt2/src/secret.txt"
if singular_retained_wip_commit "$repo2" work TASK-0045 "$tmp/wt2" "src/" "src/secret.txt" >/dev/null 2>"$tmp/err7b"; then fail "forbidden path was committed"; fi
grep -q 'secret.txt' "$tmp/err7b" || fail "forbidden refusal does not name the path: $(cat "$tmp/err7b")"
pass "dirt outside the owned scope is refused with a precise reason"

# 8. The driver preserves the work before it refreshes, and says so.
grep -q 'singular_retained_wip_commit "$SINGULAR_ROOT" "$worker_branch" "$task_id"' "$ROOT/engine/l1-drive.sh" \
  || fail "l1-drive does not commit retained work before the base refresh"
grep -q '"l1.retained_wip_committed"' "$ROOT/engine/l1-drive.sh" || fail "l1-drive emits no WIP event"
grep -q 'retained work could not be preserved before the base refresh' "$ROOT/engine/l1-drive.sh" \
  || fail "l1-drive does not name the WIP refusal"
pass "l1-drive is wired to preserve retained work before the refresh"

# 9. End to end through the driver (dry run: no provider, exits after base
# admission). The observed loop: unpark, dispatch, "checkout is dirty; not
# merging", "admitted base is not an ancestor", exit 2, every cycle.
repo3="$tmp/repo3"
mkdir -p "$repo3/docs/orchestration/tasks" "$repo3/docs/orchestration/prompts" "$repo3/src"
git -C "$repo3" init -q; git -C "$repo3" config user.name f; git -C "$repo3" config user.email f@x
git -C "$repo3" checkout -qb target
cp "$ROOT/templates/prompts/l2-test-first-developer.md" "$ROOT/templates/prompts/auditor.md" "$repo3/docs/orchestration/prompts/" 2>/dev/null || true
printf '.worktrees/\n.singular-state/\n' >"$repo3/.gitignore"
printf 'base\n' >"$repo3/src/owned.txt"; printf 'broken\n' >"$repo3/outside.txt"
cat >"$repo3/docs/orchestration/tasks/TASK-0045.md" <<'TASK'
# TASK-0045: Retained WIP fixture

Status: ready
Area: widget
Target branch: `target`
Worker branch: `agent/widget/TASK-0045-fixture`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Fixture task for the retained-work refresh.

## Scope

Owned files:

- `src/`

## Acceptance Criteria

- The gate command passes.
TASK
git -C "$repo3" add .; git -C "$repo3" commit -qm base
git -C "$repo3" branch agent/widget/TASK-0045-fixture
git -C "$repo3" worktree add -q "$repo3/.worktrees/TASK-0045" agent/widget/TASK-0045-fixture
printf 'worker work\n' >"$repo3/.worktrees/TASK-0045/src/owned.txt"
printf 'fixed\n' >"$repo3/outside.txt"; git -C "$repo3" commit -qam "operator fixes the file outside the task scope"
drive3() {
  env -u SINGULAR_STATE_DIR -u SINGULAR_ROOT \
    SINGULAR_ROOT="$repo3" SINGULAR_STATE_DIR="$repo3/.singular-state" \
    SINGULAR_ORCH_DIR="$repo3/docs/orchestration" SINGULAR_TASKS_DIR="$repo3/docs/orchestration/tasks" \
    SINGULAR_LEASES_DIR="$repo3/.singular-state/leases" SINGULAR_DISPATCH_DIR="$repo3/.singular-state/dispatch" \
    SINGULAR_RUNS_DIR="$repo3/.singular-state/runs" SINGULAR_WORKTREES_DIR="$repo3/.worktrees" \
    SINGULAR_EVENTS_FILE="$repo3/.singular-state/events.ndjson" SINGULAR_TARGET_BRANCH=target \
    SINGULAR_RUNNER=/nonexistent/runner SINGULAR_CODEX_RUNNER=/nonexistent/runner \
    bash "$ROOT/engine/l1-drive.sh" TASK-0045 --dry-run
}
wb=agent/widget/TASK-0045-fixture
rc=0; drive3 >"$tmp/drive3.out" 2>"$tmp/drive3.err" || rc=$?
[[ "$rc" -eq 0 ]] || fail "driver refused a retained dirty checkout (rc=$rc): $(tail -3 "$tmp/drive3.err")"
git -C "$repo3" merge-base --is-ancestor target "$wb" || fail "driver did not refresh the retained branch onto the target"
[[ "$(git -C "$repo3" show "$wb:src/owned.txt")" == "worker work" ]] || fail "driver lost the worker's work"
git -C "$repo3" log --format=%s "$wb" | grep -q '^wip(singular): preserve uncommitted TASK-0045' || fail "no labelled WIP commit on the worker branch"
grep -q '"type":"l1.retained_wip_committed"' "$repo3/.singular-state/events.ndjson" || fail "no l1.retained_wip_committed event"
grep -q '"type":"l1.base_refreshed"' "$repo3/.singular-state/events.ndjson" || fail "no l1.base_refreshed event"
pass "the driver commits retained work and refreshes instead of refusing"
# Now with dirt outside the scope: refused, with the reason on the driver's last line.
printf 'again\n' >"$repo3/outside.txt"; git -C "$repo3" commit -qam "target moves again"
printf 'more work\n' >>"$repo3/.worktrees/TASK-0045/src/owned.txt"; printf 'x\n' >"$repo3/.worktrees/TASK-0045/stray.txt"
head9="$(git -C "$repo3" rev-parse "$wb")"
rc=0; drive3 >"$tmp/drive3.out" 2>"$tmp/drive3.err" || rc=$?
[[ "$rc" -eq 2 ]] || fail "out-of-scope dirt: want refusal exit 2, got $rc"
grep '^l1-drive: ' "$tmp/drive3.err" | tail -1 | grep -q 'retained work could not be preserved before the base refresh: .*outside the owned scope of TASK-0045.*stray.txt' \
  || fail "refusal reason is not precise: $(grep '^l1-drive: ' "$tmp/drive3.err" | tail -1)"
[[ "$(git -C "$repo3" rev-parse "$wb")" == "$head9" ]] || fail "branch moved on a refused drive"
pass "the driver refuses out-of-scope dirt with the precise reason as its final line"
echo "test-retained-base-refresh: ok"
