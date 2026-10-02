#!/usr/bin/env bash
set -euo pipefail

# Drives a task through engine/l1-drive.sh in a hermetic SINGULAR_ROOT (isolated
# events log, stub SINGULAR_RUNNER acting as both implementer and auditor) and
# asserts this slice's driver wire-in: the FINAL requiredCompletion behavior of
# node `rehydrate-path` — INJECTION. When the implementer routing decision at the
# non-pinned `implement` step is `rehydrate` (a refused resume upgraded behind
# SINGULAR_REHYDRATE=1), the otherwise-fresh implementer run's already-rendered
# $active_prompt ($run_dir/l2-active-prompt.md) receives the assembled, capped,
# quarantine-aware rehydration packet under a provenance/taint header — assembled
# by delegating into the integrated pure bricks singular_ctx_rehydrate_packet over
# singular_ctx_rehydrate_sources "$run_dir". The run stays FRESH (worker_resume_id
# empty -> no --resume-session). With SINGULAR_REHYDRATE unset the hook never fires
# and $active_prompt carries no injected section (OFF-parity).
#
# The scenario forces the implementer decision to `rehydrate <reason>` at the
# non-pinned `implement` step, exactly as the sibling event-drive test does:
#   attempt 1 : worker OK (writes a valid packet + a session meta carrying a
#               session id) but the auditor returns needs-fix -> a retry is queued
#               and the implementer session meta is finalized (resumable).
#   attempt 2 : the routing spine would `resume` the finalized session, but the
#               window-pressure resume gate (SINGULAR_SESSION_WINDOW_MAX_PCT=0)
#               refuses it. Behind SINGULAR_REHYDRATE=1 the refusal upgrades to
#               `rehydrate window-pressure` (run_dir holds attempt-1 durable
#               artifacts). The worker then emits no packet, so the attempt fails
#               BEFORE any durable artifact under run_dir is rewritten -> run_dir
#               is frozen at its attempt-1 state, so the packet recomputed over
#               run_dir at drive end equals the packet injected at attempt-2 open.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-ctx-rehydrate-inject-drive.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

# Hermetic guard: scrub inherited SINGULAR_* so a leaked knob can't poison the sandbox.
while IFS= read -r _v; do unset "$_v"; done < <(compgen -v | grep '^SINGULAR_' || true)
unset _v

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }

workroot="$(mktemp -d "${TMPDIR:-/tmp}/singular-rehydrate-inject-drive.XXXXXX")"
trap 'rm -rf "$workroot"' EXIT

# Source lib.sh (which auto-sources the ctx-*.sh bricks) so the test can recompute
# the expected packet with the SAME pure helpers the driver delegates into.
export SINGULAR_ROOT="$workroot/libroot"
export SINGULAR_STATE_DIR="$SINGULAR_ROOT/.singular-state"
export SINGULAR_TARGET_BRANCH="target"
mkdir -p "$SINGULAR_STATE_DIR"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"
[[ "$(type -t singular_ctx_rehydrate_packet)" == "function" ]] \
  || fail "singular_ctx_rehydrate_packet not defined (assembler missing)"
[[ "$(type -t singular_ctx_rehydrate_sources)" == "function" ]] \
  || fail "singular_ctx_rehydrate_sources not defined (resolver missing)"

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

# Mock runner. L2 (implementer): records whether it received --resume-session (so
# the test can assert the rehydrate attempt runs FRESH). On the attempt named by
# WORKER_FAIL_ON it emits an EMPTY last-message (worker-no-packet -> the attempt
# fails before any durable artifact under run_dir is rewritten); otherwise it
# writes an attempt-varying owned file, a schema-valid packet, and a session meta
# carrying a session id (so the NEXT attempt's meta is resumable). Read-only
# (auditor): first call needs-fix, then accepted, driving exactly one retry.
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
  # Record the resume disposition of this l2 invocation for the FRESH assertion.
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

# The rehydration packet the assembler would inject for this run, recomputed over
# the (frozen) run_dir with the SAME pure helpers the driver delegates into.
expected_packet() {
  local run_dir="$1"
  local -a specs=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && specs+=("$line")
  done < <(singular_ctx_rehydrate_sources "$run_dir")
  singular_ctx_rehydrate_packet ${specs[@]+"${specs[@]}"}
}

# Provenance/taint header marker the injected section is headed with.
PROV_HEADER="## Injected durable context (rehydrated from a refused-resume lineage)"

# ---------------------------------------------------------------------------
# (RED core) ON injection: the fresh rehydrate attempt's $active_prompt carries
# the assembled packet under the provenance/taint header, and that packet equals
# singular_ctx_rehydrate_packet over singular_ctx_rehydrate_sources "$run_dir".
# ---------------------------------------------------------------------------
reset_state
run_drive SINGULAR_CTX_ROUTING=1 SINGULAR_REHYDRATE=1 SINGULAR_SESSION_WINDOW_MAX_PCT=0 \
  SCENARIO=needs-fix-first WORKER_FAIL_ON=2 >/dev/null 2>&1
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "ON: no run dir produced"
active_prompt="$run_dir/l2-active-prompt.md"
[[ -f "$active_prompt" ]] || fail "ON: no active prompt produced"

want_packet="$(expected_packet "$run_dir")"
[[ -n "$want_packet" && "$want_packet" == *"=== "* ]] \
  || fail "ON: expected a non-empty labeled packet over run_dir (sanity)"

printf '%s' "$want_packet" > "$workroot/want-packet.txt"
# The injected packet must appear VERBATIM in the active prompt, AND it must appear
# under the provenance header (header offset < packet offset).
python3 - "$active_prompt" "$workroot/want-packet.txt" "$PROV_HEADER" <<'PY' || fail "ON: active prompt missing injected packet under provenance header"
import sys
prompt = open(sys.argv[1], encoding="utf-8").read()
packet = open(sys.argv[2], encoding="utf-8").read()
header = sys.argv[3]
pk = prompt.find(packet)
hd = prompt.find(header)
assert pk != -1, "injected packet not found verbatim in active prompt"
assert hd != -1, "provenance header not found in active prompt"
assert hd < pk, "provenance header must precede the injected packet"
PY
pass "(ON) rehydrate attempt: assembled packet injected under provenance header, equals brick output"

# (fresh) the rehydrate attempt ran without --resume-session (worker_resume_id empty).
# The LAST l2 invocation is the rehydrate attempt; it must be resume=none.
last_resume="$(tail -1 "$workroot/resume-log" 2>/dev/null | awk '{print $2}')"
assert_eq "$last_resume" "resume=none" "fresh: rehydrate attempt runs without --resume-session"
pass "(fresh) rehydrate attempt is a fresh session (no --resume-session), not a resume"

# (provenance/taint) the injected header frames the section as reference-only, not authoritative.
grep -q "$PROV_HEADER" "$active_prompt" || fail "provenance: header missing"
grep -qi "not authoritative" "$active_prompt" || fail "provenance: taint framing (not authoritative) missing"
pass "(provenance) injected section headed reference-only / not authoritative"

# (idempotent) the packet is injected exactly once at attempt-open (not re-appended).
prov_count="$(grep -cF "$PROV_HEADER" "$active_prompt" || true)"
assert_eq "$prov_count" "1" "idempotent: provenance header appears exactly once"
pass "(idempotent) rehydration packet injected once at attempt-open"

# ---------------------------------------------------------------------------
# (OFF-parity) SINGULAR_REHYDRATE unset -> the strategy is never `rehydrate`, the
# hook never fires, and $active_prompt carries NO injected section.
# ---------------------------------------------------------------------------
reset_state
run_drive SINGULAR_CTX_ROUTING=1 SINGULAR_SESSION_WINDOW_MAX_PCT=0 \
  SCENARIO=needs-fix-first WORKER_FAIL_ON=2 >/dev/null 2>&1
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "OFF: no run dir produced"
active_prompt="$run_dir/l2-active-prompt.md"
[[ -f "$active_prompt" ]] || fail "OFF: no active prompt produced"
grep -qF "$PROV_HEADER" "$active_prompt" && fail "OFF: provenance header must be absent (hook must not fire)"
grep -q "=== task-packet ===" "$active_prompt" && fail "OFF: no injected packet section may appear"
pass "(OFF) SINGULAR_REHYDRATE unset: no injection, active prompt free of rehydration packet"

echo "ALL CTX-REHYDRATE-INJECT-DRIVE TESTS PASSED"
