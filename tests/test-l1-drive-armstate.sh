#!/usr/bin/env bash
set -euo pipefail

# Drives a task through l1-drive.sh's acceptance path in a hermetic SINGULAR_ROOT
# (isolated events log, stub SINGULAR_RUNNER yielding an accepted verdict, default
# provisioning) and asserts the per-run arm knob-state finalize hook this task
# owns (DAG node experiment-run, layer evaluation): a call site placed in the
# finalize region beside the sibling per-run provenance blocks (the
# SINGULAR_CTX_ARTIFACT_SCAN durable-artifacts block, the paired-audit recorder,
# and the critic-recheck block), behind the default-OFF SINGULAR_CTX_ARMSTATE knob
# (default 0). The hook is a minimal delegating call site: when the knob is set
# and not 0 it writes the output of the integrated read-only emitter
# singular_ctx_experiment_armstate_json (TASK-0093) to a durable
# arm-knob-state.json under the run directory, non-fatal; it inlines no
# knob-state logic of its own.
#
#   (a) default-OFF (SINGULAR_CTX_ARMSTATE unset AND =0): the accepted path is
#       byte-identical to pre-hook behavior — NO arm-knob-state.json is written
#       under the run directory, acceptance outcome + exit status unchanged.
#   (b) ON (=1), control arm (no continuity knobs set): arm-knob-state.json is
#       written under the run directory and its bytes EQUAL
#       singular_ctx_experiment_armstate_json for the run's (control / M0) env —
#       pure delegation. Acceptance outcome + exit status unchanged.
#   (c) ON (=1), treatment arm (a continuity knob set): arm-knob-state.json bytes
#       EQUAL singular_ctx_experiment_armstate_json for the run's treatment env
#       (the knob recorded active). Acceptance outcome + exit status unchanged.
#   (d) The write is confined to the run directory's arm-knob-state.json — the
#       hook mutates nothing else: no new event type, no task-file/lease change
#       beyond the normal accepted outcome (asserted by comparing the ON accepted
#       outcome to the OFF one and confirming no armstate-specific event fires).

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-l1-drive-armstate.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

# Hermetic guard: scrub any inherited SINGULAR_* env so the sandbox sees only the
# knobs each subtest sets. run.sh does this for the suite; do it here so a direct
# invocation is hermetic too (a leaked continuity knob would poison both the
# drive's env and the expected-emitter env).
while IFS= read -r _v; do unset "$_v"; done < <(compgen -v | grep '^SINGULAR_' || true)
unset _v

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }

workroot="$(mktemp -d "${TMPDIR:-/tmp}/singular-l1-drive-armstate.XXXXXX")"
trap 'rm -rf "$workroot"' EXIT

drv_root="$workroot/drv"
mkdir -p "$drv_root/docs/orchestration/prompts" "$drv_root/docs/orchestration/tasks" \
  "$drv_root/.singular-state" "$drv_root/internal/widget"
git -C "$drv_root" init -q
git -C "$drv_root" config user.email t@t; git -C "$drv_root" config user.name t
git -C "$drv_root" checkout -q -b target
cp "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md" "$drv_root/docs/orchestration/prompts/l2-test-first-developer.md"
cp "$ENGINE_HOME/templates/prompts/auditor.md" "$drv_root/docs/orchestration/prompts/auditor.md"
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

# Mock runner. On --level l2 it writes the owned worker file and a schema-valid
# worker packet. On --level readonly it writes the auditor verdict record.
mock_runner="$workroot/mock-runner.sh"
cat >"$mock_runner" <<'MOCK'
#!/usr/bin/env bash
set -uo pipefail
level=""; worktree=""; out=""
args=("$@")
i=0
while [[ $i -lt ${#args[@]} ]]; do
  case "${args[$i]}" in
    --level) level="${args[$((i+1))]}"; i=$((i+2)) ;;
    -C|--worktree) worktree="${args[$((i+1))]}"; i=$((i+2)) ;;
    --output-last-message) out="${args[$((i+1))]}"; i=$((i+2)) ;;
    *) i=$((i+1)) ;;
  esac
done
if [[ "$level" == "l2" ]]; then
  mkdir -p "$worktree/internal/widget"
  printf 'package widget\n' > "$worktree/internal/widget/parser.go"
  if [[ -n "$out" ]]; then
    cat > "$out" <<'PKT'
{"schema":"singular.orchestration.state-packet.v0","packetId":"p","runId":"r","taskId":"TASK-0001","area":"widget","role":"l2-developer","status":"needs-review","baseRef":"target","branch":"agent/widget/TASK-0001-generic","headSha":"0","workspace":"w","ownedFiles":["internal/widget/parser.go"],"changedFiles":[],"commands":[],"tests":[],"evidence":[],"blockers":[],"nextAction":"await auditor verdict","createdAt":"2026-01-01T00:00:00Z"}
PKT
  fi
  exit 0
fi
# read-only: auditor / decider run at --level readonly.
[[ -n "$out" ]] && python3 -c 'import json,os,sys; o,v=sys.argv[1:3]; d=os.path.dirname(o); f=os.path.join(d,"packet.json"); p=json.load(open(f)) if os.path.isfile(f) else {}; json.dump({"schema":"singular.orchestration.audit-verdict.v0","taskId":p.get("taskId","TASK-0001"),"runId":p.get("runId") or os.path.basename(d),"branch":p.get("branch","unknown"),"verdict":v,"evidenceReviewed":[],"commandsRun":[],"findings":[],"requiredFixes":[],"rationale":"fixture verdict"},open(o,"w"))' "$out" "${MOCK_AUDIT_VERDICT:-accepted}"
exit 0
MOCK
chmod +x "$mock_runner"

EVENTS="$drv_root/.singular-state/events.ndjson"

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

# Drive TASK-0001. Leading VAR=val args are passed to the drive's env.
run_drive() {
  ( cd "$drv_root" && env SINGULAR_ROOT="$drv_root" SINGULAR_STATE_DIR="$drv_root/.singular-state" \
      SINGULAR_ORCH_DIR="$drv_root/docs/orchestration" SINGULAR_TASKS_DIR="$drv_root/docs/orchestration/tasks" \
      SINGULAR_TARGET_BRANCH=target SINGULAR_RUNNER="$mock_runner" SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
      SINGULAR_MAX_RETRIES=0 \
      "$@" "$SCRIPT_DIR/l1-drive.sh" TASK-0001 )
}

run_dir_of() { ls -d "$drv_root"/.singular-state/runs/RUN-* 2>/dev/null | head -1; }
json_field() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2"; }

# The reference emitter output for a given continuity-knob env — the exact bytes
# the hook must write (pure delegation). Leading VAR=val args are the continuity
# knobs the drive was run with; SINGULAR_CTX_ARMSTATE itself is NOT a continuity
# knob and does not affect the emitter's output.
gen_expected() {
  local out_file="$1"; shift
  ( env "$@" bash -c 'source "'"$SCRIPT_DIR"'/ctx-experiment-armstate.sh"; singular_ctx_experiment_armstate_json' ) > "$out_file"
}

# Assert the standard accepted outcome for a run (independent of the arm hook).
assert_accepted() {
  local run_dir="$1"
  local run_id; run_id="$(basename "$run_dir")"
  local inbox="$drv_root/.singular-state/inbox/$run_id.json"
  [[ -f "$inbox" ]] || fail "accepted: no inbox packet at $inbox"
  assert_eq "$(json_field "$inbox" status)" "accepted" "accepted: inbox packet status"
  assert_eq "$(SINGULAR_ROOT="$drv_root" SINGULAR_STATE_DIR="$drv_root/.singular-state" \
    bash -c 'source "'"$SCRIPT_DIR"'/lib.sh"; singular_lease_status TASK-0001')" "accepted" "accepted: lease status"
  grep -q 'Status: accepted' "$TASK_MD" || fail "accepted: task md not set to accepted"
  grep -q 'accept' "$drv_root/docs/orchestration/decisions.md" || fail "accepted: no accept decision recorded"
  grep -q '"type":"l1.task_accepted"' "$EVENTS" || fail "accepted: no l1.task_accepted event"
}

armstate_file() { echo "$1/arm-knob-state.json"; }

# ---------------------------------------------------------------------------
# (a) default-OFF (unset): accepted, NO arm-knob-state.json written.
# ---------------------------------------------------------------------------
reset_state
out="$(run_drive 2>&1)" || { echo "$out" | tail -20; fail "OFF (unset): drive failed"; }
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "OFF (unset): no run dir"
assert_accepted "$run_dir"
[[ ! -e "$(armstate_file "$run_dir")" ]] || fail "OFF (unset): arm-knob-state.json must NOT be written"
pass "(a) default-OFF (unset): accepted, no arm-knob-state.json"

# default-OFF: explicit =0.
reset_state
out="$(run_drive SINGULAR_CTX_ARMSTATE=0 2>&1)" || { echo "$out" | tail -20; fail "OFF (=0): drive failed"; }
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "OFF (=0): no run dir"
assert_accepted "$run_dir"
[[ ! -e "$(armstate_file "$run_dir")" ]] || fail "OFF (=0): arm-knob-state.json must NOT be written"
pass "(a) default-OFF (=0): accepted, no arm-knob-state.json"

# ---------------------------------------------------------------------------
# (b) ON (=1), control arm: arm-knob-state.json written and byte-identical to the
#     emitter for the M0 control env; outcome unchanged.
#
# As of 0.20.0 the M0 control arm is NOT "the environment with nothing set":
# SINGULAR_CTX_PACKET and SINGULAR_CTX_ROUTING default to 1 in engine/lib.sh, so a
# control arm must zero them EXPLICITLY. An arm is defined by its knob-state, and
# the engine's baseline moved; leaving these unset would silently compare a
# 2-knob-active run against a control snapshot.
# ---------------------------------------------------------------------------
M0_CONTROL=(SINGULAR_CTX_PACKET=0 SINGULAR_CTX_ROUTING=0)
reset_state
ec=0
out="$(run_drive SINGULAR_CTX_ARMSTATE=1 "${M0_CONTROL[@]}" 2>&1)" || ec=$?
assert_eq "$ec" "0" "ON control: drive exit status unchanged (accepted)"
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "ON control: no run dir"
assert_accepted "$run_dir"
armfile="$(armstate_file "$run_dir")"
[[ -f "$armfile" ]] || fail "ON control: arm-knob-state.json must be written"
gen_expected "$workroot/expected-control.json" "${M0_CONTROL[@]}"
diff "$workroot/expected-control.json" "$armfile" \
  || fail "ON control: arm-knob-state.json must be byte-identical to the emitter (M0 control)"
# The control snapshot is the M0 knob-state: zero active continuity knobs.
assert_eq "$(json_field "$armfile" activeCount)" "0" "ON control: activeCount is 0 (M0 knob-state)"
# No armstate-specific event fires (the hook writes only a file). Scope the check
# to the event "type" field so an incidental path mention (the sandbox dir name)
# in event data is not a false positive.
! grep -qE '"type":"[^"]*(armstate|arm[_.-]knob)' "$EVENTS" \
  || fail "ON control: hook must emit no armstate event"
pass "(b) ON control: arm-knob-state.json == emitter (M0 control), outcome unchanged"

# ---------------------------------------------------------------------------
# (c) ON (=1), treatment arm: set SINGULAR_CTX_MANIFEST=1 (a continuity knob that
#     does not alter the drive path with SINGULAR_REHYDRATE unset). The recorded
#     arm-knob-state.json must reflect the treatment env (that knob active) and
#     stay byte-identical to the emitter; outcome unchanged.
# ---------------------------------------------------------------------------
reset_state
ec=0
out="$(run_drive SINGULAR_CTX_ARMSTATE=1 "${M0_CONTROL[@]}" SINGULAR_CTX_MANIFEST=1 2>&1)" || ec=$?
assert_eq "$ec" "0" "ON treatment: drive exit status unchanged (accepted)"
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "ON treatment: no run dir"
assert_accepted "$run_dir"
armfile="$(armstate_file "$run_dir")"
[[ -f "$armfile" ]] || fail "ON treatment: arm-knob-state.json must be written"
gen_expected "$workroot/expected-treatment.json" "${M0_CONTROL[@]}" SINGULAR_CTX_MANIFEST=1
diff "$workroot/expected-treatment.json" "$armfile" \
  || fail "ON treatment: arm-knob-state.json must be byte-identical to the emitter (treatment env)"
assert_eq "$(json_field "$armfile" activeCount)" "1" "ON treatment: activeCount reflects the active knob"
pass "(c) ON treatment: arm-knob-state.json == emitter (treatment env), outcome unchanged"

echo "ALL L1-DRIVE-ARMSTATE TESTS PASSED"
