#!/usr/bin/env bash
set -euo pipefail

# Drives a task through engine/l1-drive.sh in a hermetic SINGULAR_ROOT (isolated
# events log, stub SINGULAR_RUNNER acting as both implementer and auditor) and
# asserts THIS slice's driver wire-in: the OPTIONAL authored-knowledge
# augmentation of the rehydration packet for node `rehydrate-path`. On a
# `rehydrate` implementer decision (a refused resume upgraded behind
# SINGULAR_REHYDRATE=1), AFTER the durable rehydration packet (TASK-0057) is
# appended, the driver ALSO appends the eligible authored-knowledge entries —
# equal to `singular_ctx_rehydrate_authored_config_render implement` — under a
# reference-only / NOT-authoritative wrapper. The append is delegated entirely
# into the integrated config-gated render; with SINGULAR_CTX_MANIFEST unset (or no
# contextManifest configured) that render is empty and nothing is appended, so
# $active_prompt stays byte-identical to the durable-only injection.
#
# The rehydrate scenario mirrors the sibling inject-drive test:
#   attempt 1 : worker OK (valid packet + resumable session meta) but the auditor
#               returns needs-fix -> a retry is queued.
#   attempt 2 : the routing spine would `resume`, but the window-pressure resume
#               gate (SINGULAR_SESSION_WINDOW_MAX_PCT=0) refuses it. Behind
#               SINGULAR_REHYDRATE=1 the refusal upgrades to `rehydrate`. The worker
#               then emits no packet, so run_dir is frozen at its attempt-1 state.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-ctx-rehydrate-authored-inject-drive.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

# Hermetic guard: scrub inherited SINGULAR_* so a leaked knob can't poison the sandbox.
while IFS= read -r _v; do unset "$_v"; done < <(compgen -v | grep '^SINGULAR_' || true)
unset _v

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }

workroot="$(mktemp -d "${TMPDIR:-/tmp}/singular-rehydrate-authored-inject-drive.XXXXXX")"
trap 'rm -rf "$workroot"' EXIT

# Source lib.sh (which auto-sources the ctx-*.sh bricks) so the test can recompute
# the expected packet + authored section with the SAME pure helpers the driver
# delegates into.
export SINGULAR_ROOT="$workroot/libroot"
export SINGULAR_STATE_DIR="$SINGULAR_ROOT/.singular-state"
export SINGULAR_TARGET_BRANCH="target"
mkdir -p "$SINGULAR_STATE_DIR"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"
[[ "$(type -t singular_ctx_rehydrate_packet)" == "function" ]] \
  || fail "singular_ctx_rehydrate_packet not defined (assembler missing)"
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
# One eligible `implement`-triggered entry (KEEP) plus a planner-only entry (DROP
# on the `implement` trigger the driver passes). The config file lives at the
# origin root's default SINGULAR_JSON_CONFIG_FILE path; a RELATIVE contextManifest
# resolves against the config file's directory (== $drv_root).
cat >"$drv_root/authored-manifest.json" <<'JSON'
{
  "schema": "singular.orchestration.authored-knowledge-manifest.v0",
  "entries": [
    { "id": "impl-body",   "body": "AUTHORED BODY impl", "load-when": ["implement"], "freshness": "current" },
    { "id": "plan-only",   "body": "planner body",       "load-when": ["planner"],   "freshness": "current" }
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

# Mock runner (identical to the sibling inject-drive test).
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

# The durable rehydration packet the assembler would inject for this run.
expected_packet() {
  local run_dir="$1"
  local -a specs=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && specs+=("$line")
  done < <(singular_ctx_rehydrate_sources "$run_dir")
  singular_ctx_rehydrate_packet ${specs[@]+"${specs[@]}"}
}

# The authored section the config-gated render emits for the `implement` trigger
# the driver passes — computed against the origin root's config file, exactly as
# the driver's delegation resolves it.
expected_authored() {
  SINGULAR_CTX_MANIFEST=1 SINGULAR_JSON_CONFIG_FILE="$drv_root/singular.config.json" \
    singular_ctx_rehydrate_authored_config_render implement
}

# Durable provenance/taint header (TASK-0057) and the authored wrapper header.
PROV_HEADER="## Injected durable context (rehydrated from a refused-resume lineage)"
AUTHORED_HEADER="## Injected authored knowledge (reference material, NOT authoritative)"

# ---------------------------------------------------------------------------
# (ON) rehydrate + SINGULAR_CTX_MANIFEST=1 + configured contextManifest: the
# authored section is appended AFTER the durable packet, under a reference-only
# header, and equals singular_ctx_rehydrate_authored_config_render implement.
# ---------------------------------------------------------------------------
reset_state
run_drive SINGULAR_CTX_ROUTING=1 SINGULAR_REHYDRATE=1 SINGULAR_CTX_MANIFEST=1 \
  SINGULAR_SESSION_WINDOW_MAX_PCT=0 SCENARIO=needs-fix-first WORKER_FAIL_ON=2 >/dev/null 2>&1
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "ON: no run dir produced"
active_prompt="$run_dir/l2-active-prompt.md"
[[ -f "$active_prompt" ]] || fail "ON: no active prompt produced"

want_packet="$(expected_packet "$run_dir")"
[[ -n "$want_packet" && "$want_packet" == *"=== "* ]] \
  || fail "ON: expected a non-empty labeled durable packet over run_dir (sanity)"
want_authored="$(expected_authored)"
[[ -n "$want_authored" && "$want_authored" == *"=== authored:impl-body ==="* ]] \
  || fail "ON: expected a non-empty authored section with impl-body (fixture sanity). got:[$want_authored]"
[[ "$want_authored" != *"plan-only"* ]] \
  || fail "ON: planner-only entry must not be eligible for the implement trigger"

printf '%s' "$want_packet" > "$workroot/want-packet.txt"
printf '%s' "$want_authored" > "$workroot/want-authored.txt"

# The durable packet AND the authored section must both appear verbatim, with the
# authored section AFTER the durable packet, and the authored wrapper header must
# precede the authored section.
python3 - "$active_prompt" "$workroot/want-packet.txt" "$workroot/want-authored.txt" \
  "$PROV_HEADER" "$AUTHORED_HEADER" <<'PY' || fail "ON: active prompt missing durable+authored layout"
import sys
prompt = open(sys.argv[1], encoding="utf-8").read()
packet = open(sys.argv[2], encoding="utf-8").read()
authored = open(sys.argv[3], encoding="utf-8").read()
prov_h, auth_h = sys.argv[4], sys.argv[5]
pk = prompt.find(packet)
au = prompt.find(authored)
ph = prompt.find(prov_h)
ah = prompt.find(auth_h)
assert pk != -1, "durable packet not found verbatim in active prompt"
assert au != -1, "authored section not found verbatim in active prompt"
assert ph != -1, "durable provenance header not found"
assert ah != -1, "authored wrapper header not found"
assert ph < pk, "durable provenance header must precede the durable packet"
assert pk < ah, "authored section must come AFTER the durable packet"
assert ah < au, "authored wrapper header must precede the authored section"
PY
pass "(ON) authored section appended after durable packet, equals config render, under reference-only header"

# (never authoritative) the authored wrapper frames the section reference-only.
grep -q "$AUTHORED_HEADER" "$active_prompt" || fail "authored: wrapper header missing"
grep -qi "not authoritative" "$active_prompt" || fail "authored: taint framing (not authoritative) missing"
pass "(never authoritative) authored section headed reference-only / not authoritative"

# (idempotent) the authored wrapper header appears exactly once.
auth_count="$(grep -cF "$AUTHORED_HEADER" "$active_prompt" || true)"
assert_eq "$auth_count" "1" "idempotent: authored wrapper header appears exactly once"
pass "(idempotent) authored section injected once at attempt-open"

# ---------------------------------------------------------------------------
# (OFF-parity, manifest flag) SINGULAR_CTX_MANIFEST unset on a rehydrate run:
# the durable packet still injects, but NO authored section is appended.
# ---------------------------------------------------------------------------
reset_state
run_drive SINGULAR_CTX_ROUTING=1 SINGULAR_REHYDRATE=1 \
  SINGULAR_SESSION_WINDOW_MAX_PCT=0 SCENARIO=needs-fix-first WORKER_FAIL_ON=2 >/dev/null 2>&1
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "OFF-manifest: no run dir produced"
active_prompt="$run_dir/l2-active-prompt.md"
[[ -f "$active_prompt" ]] || fail "OFF-manifest: no active prompt produced"
grep -qF "$PROV_HEADER" "$active_prompt" || fail "OFF-manifest: durable packet must still inject"
grep -qF "$AUTHORED_HEADER" "$active_prompt" && fail "OFF-manifest: authored section must be absent"
grep -q "=== authored:" "$active_prompt" && fail "OFF-manifest: no authored section may appear"
pass "(OFF-parity manifest) SINGULAR_CTX_MANIFEST unset: durable-only injection, no authored section"

# ---------------------------------------------------------------------------
# (OFF-parity, rehydrate flag) SINGULAR_REHYDRATE unset -> strategy never
# `rehydrate`, so neither durable nor authored injection fires.
# ---------------------------------------------------------------------------
reset_state
run_drive SINGULAR_CTX_ROUTING=1 SINGULAR_CTX_MANIFEST=1 \
  SINGULAR_SESSION_WINDOW_MAX_PCT=0 SCENARIO=needs-fix-first WORKER_FAIL_ON=2 >/dev/null 2>&1
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "OFF-rehydrate: no run dir produced"
active_prompt="$run_dir/l2-active-prompt.md"
[[ -f "$active_prompt" ]] || fail "OFF-rehydrate: no active prompt produced"
grep -qF "$PROV_HEADER" "$active_prompt" && fail "OFF-rehydrate: durable packet must be absent"
grep -qF "$AUTHORED_HEADER" "$active_prompt" && fail "OFF-rehydrate: authored section must be absent"
pass "(OFF-parity rehydrate) SINGULAR_REHYDRATE unset: no durable and no authored injection"

echo "ALL CTX-REHYDRATE-AUTHORED-INJECT-DRIVE TESTS PASSED"
