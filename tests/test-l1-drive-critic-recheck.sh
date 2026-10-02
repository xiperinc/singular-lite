#!/usr/bin/env bash
set -euo pipefail

# Drives a task through l1-drive.sh's acceptance path in a hermetic SINGULAR_ROOT
# (isolated events log, stub SINGULAR_RUNNER yielding an accepted verdict, default
# provisioning) and asserts the terminal post-acceptance CRITIC-RECHECK hook this
# node (critic-carryover) owns: a SINGLE call site placed STRICTLY AFTER
# acceptance is finalized (packet status accepted, lease/task status accepted,
# accept decision recorded, inbox packet written, l1.task_accepted appended, and
# beside the integrated paired-audit hook) that resolves the node + prior
# plan-critique record via singular_ctx_critic_recheck_locate_node /
# singular_ctx_critic_recheck_locate_record (TASK-0032) and, when BOTH resolve,
# delegates into singular_ctx_critic_recheck_run (TASK-0031) guarded by `|| true`.
# The hook adds no recheck logic of its own.
#
#   (a) default-OFF (SINGULAR_CRITIC_RECHECK_PCT unset AND =0), even WITH a
#       resolvable node + prior critique record: the accepted path is
#       byte-identical to pre-hook behavior — the same acceptance artifacts and
#       events, NO ctx.critic_recheck event, and NO critic-recheck files. The
#       runner's sampling gate no-ops.
#   (b) PCT=100 on an accepted task WITH a resolvable node + record: EXACTLY ONE
#       ctx.critic_recheck event carrying per-finding dispositions, while the
#       acceptance outcome (packet status accepted, lease/task status accepted,
#       the accept decision, the inbox packet at $SINGULAR_INBOX_DIR/$run_id.json,
#       and the l1.task_accepted event) is unchanged; the ctx.critic_recheck event
#       is ordered STRICTLY after l1.task_accepted.
#   (c) invariance: a FAILING recheck runner never changes the accept/reject
#       decision or the process exit status — the accepted outcome is untouched.
#   (d) safe skip: PCT=100 but the locator cannot resolve the node (no durable
#       task->node association) — the hook skips the recheck, records nothing (NO
#       ctx.critic_recheck event, NO recheck file), and acceptance is unchanged.
#   (e) a non-accepted (needs-fix/parked) run invokes NO recheck and writes NO
#       recheck record.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-l1-drive-critic-recheck.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

# Hermetic guard: scrub any inherited SINGULAR_* env (a leaked SINGULAR_DISPATCH_*
# or SINGULAR_RUNNER from a real drive would otherwise poison the sandbox). run.sh
# does this for the suite; do it here so a direct invocation is hermetic too.
while IFS= read -r _v; do unset "$_v"; done < <(compgen -v | grep '^SINGULAR_' || true)
unset _v

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }

workroot="$(mktemp -d "${TMPDIR:-/tmp}/singular-recheck-hook.XXXXXX")"
trap 'rm -rf "$workroot"' EXIT

drv_root="$workroot/drv"
mkdir -p "$drv_root/docs/orchestration/prompts" "$drv_root/docs/orchestration/tasks" \
  "$drv_root/.singular-state" "$drv_root/internal/widget"
git -C "$drv_root" init -q
git -C "$drv_root" config user.email t@t; git -C "$drv_root" config user.name t
git -C "$drv_root" checkout -q -b target
cp "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md" "$drv_root/docs/orchestration/prompts/l2-test-first-developer.md"
cp "$ENGINE_HOME/templates/prompts/auditor.md" "$drv_root/docs/orchestration/prompts/auditor.md"
# A minimal plan-critic base prompt (the recheck runner assembles this path); the
# mock runner ignores its content but the file existing keeps things realistic.
printf '# Plan Critic Prompt\n' > "$drv_root/docs/orchestration/prompts/plan-critic.md"
# A minimal decider prompt so decide.sh (non-accepted path) can assemble a prompt.
printf '# Decider Prompt\n[TASK-ID] [FAILURE CLASS]\n' > "$drv_root/docs/orchestration/prompts/decider.md"

TASK_MD="$drv_root/docs/orchestration/tasks/TASK-0001.md"
cat >"$TASK_MD" <<'EOF'
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

NODE="critic-carryover"
# Durable per-node prior plan-critique record dir the record locator consults.
RECORD_DIR="$drv_root/.singular-state/critique"
mkdir -p "$RECORD_DIR/$NODE"
cat >"$RECORD_DIR/$NODE/plan-critique.json" <<EOF
{"schema":"singular.orchestration.plan-critique.v0","node":"$NODE","batchTaskIds":["TASK-0001"],"findings":[{"id":"f-0123456789ab","severity":"major","summary":"prior concern"}]}
EOF

# Mock runner. Writes a schema-valid worker packet (l2) and a verdict record
# (readonly). The critic-recheck pass is distinguishable by its output path
# (.../critic-recheck-raw.json): when FAIL_RECHECK=1 that specific invocation
# fails (rc 1, no output) to prove a failing recheck runner does not disturb
# acceptance. The auditor verdict is MOCK_AUDIT_VERDICT (default accepted).
mock_runner="$workroot/mock-runner.sh"
cat >"$mock_runner" <<MOCK
#!/usr/bin/env bash
set -uo pipefail
level=""; worktree=""; out=""
args=("\$@")
i=0
while [[ \$i -lt \${#args[@]} ]]; do
  case "\${args[\$i]}" in
    --level) level="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    -C|--worktree) worktree="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    --output-last-message) out="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    *) i=\$((i+1)) ;;
  esac
done
if [[ "\$level" == "l2" ]]; then
  mkdir -p "\$worktree/internal/widget"
  printf 'package widget\n' > "\$worktree/internal/widget/parser.go"
  [[ -n "\$out" ]] && cat > "\$out" <<'PKT'
{"schema":"singular.orchestration.state-packet.v0","packetId":"p","runId":"r","taskId":"TASK-0001","area":"widget","role":"l2-developer","status":"needs-review","baseRef":"target","branch":"agent/widget/TASK-0001-generic","headSha":"0","workspace":"w","ownedFiles":["internal/widget/parser.go"],"changedFiles":[],"commands":[],"tests":[],"evidence":[],"blockers":[],"nextAction":"await auditor verdict","createdAt":"2026-01-01T00:00:00Z"}
PKT
  exit 0
fi
# read-only: auditor / critic-recheck / decider all run at --level readonly.
if [[ "\$out" == *critic-recheck-raw.json ]]; then
  # The critic-recheck pass. Optionally fail it to prove acceptance invariance.
  if [[ "\${FAIL_RECHECK:-0}" == "1" ]]; then exit 1; fi
  [[ -n "\$out" ]] && printf '{"findings":[{"id":"f-0123456789ab","status":"addressed"}]}\n' > "\$out"
  exit 0
fi
[[ -n "\$out" ]] && printf '{"verdict":"%s","findings":[]}\n' "\${MOCK_AUDIT_VERDICT:-accepted}" > "\$out"
exit 0
MOCK
chmod +x "$mock_runner"

EVENTS="$drv_root/.singular-state/events.ndjson"

# Reset all mutable state so each scenario drives from a clean, ready task.
reset_state() {
  git -C "$drv_root" checkout -q target 2>/dev/null || true
  rm -rf "$drv_root/.singular-state/runs" "$drv_root/.singular-state/leases" \
    "$drv_root/.singular-state/inbox" "$drv_root/.singular-state/review-policy" \
    "$drv_root/.worktrees" 2>/dev/null || true
  : > "$EVENTS"
  rm -f "$drv_root/docs/orchestration/decisions.md" 2>/dev/null || true
  python3 - "$TASK_MD" <<'PY'
import re, sys
p = sys.argv[1]; t = open(p).read()
t = re.sub(r"Status: \w+", "Status: ready", t, count=1)
open(p, "w").write(t)
PY
  git -C "$drv_root" worktree prune 2>/dev/null || true
  git -C "$drv_root" branch -D agent/widget/TASK-0001-generic 2>/dev/null || true
}

# Seed the durable task->node association the node locator reads from the
# control-state event log (data.taskId + data.node). Appended AFTER reset so it
# precedes every drive event; l1.task_accepted (and thus the recheck) come later.
seed_node_association() {
  printf '%s\n' '{"ts":"2026-01-01T00:00:00Z","type":"planner.staged","message":"seed","data":{"taskId":"TASK-0001","node":"'"$NODE"'"}}' >> "$EVENTS"
}

# Drive TASK-0001. Leading VAR=val args are passed to the drive's env.
run_drive() {
  ( cd "$drv_root" && env SINGULAR_ROOT="$drv_root" SINGULAR_STATE_DIR="$drv_root/.singular-state" \
      SINGULAR_ORCH_DIR="$drv_root/docs/orchestration" SINGULAR_TASKS_DIR="$drv_root/docs/orchestration/tasks" \
      SINGULAR_TARGET_BRANCH=target SINGULAR_RUNNER="$mock_runner" SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
      SINGULAR_CRITIC_RECHECK_RECORD_DIR="$RECORD_DIR" \
      SINGULAR_MAX_RETRIES=0 \
      "$@" "$SCRIPT_DIR/l1-drive.sh" TASK-0001 )
}

run_dir_of() { ls -d "$drv_root"/.singular-state/runs/RUN-* 2>/dev/null | head -1; }
cr_event_count() {
  [[ -f "$EVENTS" ]] || { echo 0; return 0; }
  local c; c="$(grep -c '"type":"ctx.critic_recheck"' "$EVENTS" 2>/dev/null)" || true
  echo "${c:-0}"
}
json_field() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2"; }

# Assert the standard accepted outcome for a run (independent of the recheck hook).
assert_accepted() {
  local run_dir="$1"
  local run_id; run_id="$(basename "$run_dir")"
  # Packet status accepted (inbox copy is the accepted artifact).
  local inbox="$drv_root/.singular-state/inbox/$run_id.json"
  [[ -f "$inbox" ]] || fail "accepted: no inbox packet at $inbox"
  assert_eq "$(json_field "$inbox" status)" "accepted" "accepted: inbox packet status"
  # Lease + task status accepted.
  assert_eq "$(SINGULAR_ROOT="$drv_root" SINGULAR_STATE_DIR="$drv_root/.singular-state" \
    bash -c 'source "'"$SCRIPT_DIR"'/lib.sh"; singular_lease_status TASK-0001')" "accepted" "accepted: lease status"
  grep -q 'Status: accepted' "$TASK_MD" || fail "accepted: task md not set to accepted"
  # The accept decision was recorded.
  grep -q 'accept' "$drv_root/docs/orchestration/decisions.md" || fail "accepted: no accept decision recorded"
  # The l1.task_accepted event fired.
  grep -q '"type":"l1.task_accepted"' "$EVENTS" || fail "accepted: no l1.task_accepted event"
}

# ---------------------------------------------------------------------------
# (a) default-OFF (unset) WITH a resolvable node+record: accepted path, no
#     recheck event/record (the sampling gate no-ops).
# ---------------------------------------------------------------------------
reset_state; seed_node_association
out="$(run_drive 2>&1)" || { echo "$out" | tail -20; fail "OFF (unset): drive failed"; }
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "OFF (unset): no run dir"
assert_accepted "$run_dir"
assert_eq "$(cr_event_count)" "0" "OFF (unset): ctx.critic_recheck events"
[[ ! -e "$run_dir/critic-recheck.json" && ! -e "$run_dir/critic-recheck-raw.json" ]] \
  || fail "OFF (unset): critic-recheck file written"
pass "(a) default-OFF (unset): accepted with no recheck event/record"

# default-OFF: explicit =0.
reset_state; seed_node_association
out="$(run_drive SINGULAR_CRITIC_RECHECK_PCT=0 2>&1)" || { echo "$out" | tail -20; fail "OFF (=0): drive failed"; }
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "OFF (=0): no run dir"
assert_accepted "$run_dir"
assert_eq "$(cr_event_count)" "0" "OFF (=0): ctx.critic_recheck events"
[[ ! -e "$run_dir/critic-recheck.json" && ! -e "$run_dir/critic-recheck-raw.json" ]] \
  || fail "OFF (=0): critic-recheck file written"
pass "(a) default-OFF (=0): accepted with no recheck event/record"

# ---------------------------------------------------------------------------
# (b) PCT=100 WITH resolvable node+record: exactly one recheck event carrying
#     per-finding dispositions, acceptance unchanged, ordered STRICTLY after
#     l1.task_accepted.
# ---------------------------------------------------------------------------
reset_state; seed_node_association
out="$(run_drive SINGULAR_CRITIC_RECHECK_PCT=100 2>&1)" || { echo "$out" | tail -20; fail "PCT=100: drive failed"; }
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "PCT=100: no run dir"
assert_accepted "$run_dir"
assert_eq "$(cr_event_count)" "1" "PCT=100: exactly one ctx.critic_recheck event"
# The event carries per-finding dispositions for the prior finding.
grep '"type":"ctx.critic_recheck"' "$EVENTS" | grep -q 'f-0123456789ab' \
  || fail "PCT=100: ctx.critic_recheck event missing per-finding disposition"
# Ordering: ctx.critic_recheck strictly after l1.task_accepted.
accepted_ln="$(grep -n '"type":"l1.task_accepted"' "$EVENTS" | head -1 | cut -d: -f1)"
recheck_ln="$(grep -n '"type":"ctx.critic_recheck"' "$EVENTS" | head -1 | cut -d: -f1)"
[[ -n "$accepted_ln" && -n "$recheck_ln" ]] || fail "PCT=100: missing accepted/recheck event line"
[[ "$recheck_ln" -gt "$accepted_ln" ]] \
  || fail "PCT=100: ctx.critic_recheck ($recheck_ln) not after l1.task_accepted ($accepted_ln)"
pass "(b) PCT=100: one recheck event+dispositions, acceptance unchanged, ordered after l1.task_accepted"

# ---------------------------------------------------------------------------
# (c) invariance: a FAILING recheck runner leaves the accepted outcome and exit
#     status untouched.
# ---------------------------------------------------------------------------
reset_state; seed_node_association
ec=0
out="$(run_drive SINGULAR_CRITIC_RECHECK_PCT=100 FAIL_RECHECK=1 2>&1)" || ec=$?
assert_eq "$ec" "0" "(c) failing recheck runner: drive exit status unchanged (accepted)"
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "(c): no run dir"
assert_accepted "$run_dir"
pass "(c) failing recheck runner: accepted outcome and exit status untouched"

# ---------------------------------------------------------------------------
# (d) safe skip: PCT=100 but NO node association seeded -> locator cannot resolve
#     the node; the hook skips, records nothing, acceptance unchanged.
# ---------------------------------------------------------------------------
reset_state    # deliberately NO seed_node_association
out="$(run_drive SINGULAR_CRITIC_RECHECK_PCT=100 2>&1)" || { echo "$out" | tail -20; fail "(d) safe-skip: drive failed"; }
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "(d) safe-skip: no run dir"
assert_accepted "$run_dir"
assert_eq "$(cr_event_count)" "0" "(d) safe-skip: no ctx.critic_recheck event when node unresolved"
[[ ! -e "$run_dir/critic-recheck.json" && ! -e "$run_dir/critic-recheck-raw.json" ]] \
  || fail "(d) safe-skip: critic-recheck file written when node unresolved"
pass "(d) safe skip: node unresolved -> no recheck invoked, acceptance unchanged"

# ---------------------------------------------------------------------------
# (e) non-accepted (needs-fix -> parked): NO recheck is invoked.
# ---------------------------------------------------------------------------
reset_state; seed_node_association
ec=0
out="$(run_drive SINGULAR_CRITIC_RECHECK_PCT=100 MOCK_AUDIT_VERDICT=needs-fix 2>&1)" || ec=$?
[[ "$ec" -ne 0 ]] || fail "(e) needs-fix: drive should NOT accept (expected non-zero exit)"
grep -q 'Status: accepted' "$TASK_MD" && fail "(e) needs-fix: task must not be accepted"
run_dir="$(run_dir_of)"
assert_eq "$(cr_event_count)" "0" "(e) needs-fix: no ctx.critic_recheck event on non-accepted path"
[[ -z "$run_dir" || ! -e "$run_dir/critic-recheck.json" ]] || fail "(e) needs-fix: recheck file written on non-accepted path"
pass "(e) non-accepted path: no recheck invoked, no recheck record"

echo "ALL L1-DRIVE CRITIC-RECHECK-HOOK TESTS PASSED"
