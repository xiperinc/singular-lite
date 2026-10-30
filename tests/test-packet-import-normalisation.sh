#!/usr/bin/env bash
set -euo pipefail

# 0.23.6: a state packet is not refused over free text, and a packet that
# cannot be imported is parked and reported instead of retried forever.
#
# A synthetic accepted packet contains a plain-string nonblocking note in
# blockers. It must normalize before import, while malformed authority fields
# remain fatal and repeated import failures park with a visible reason.
#
#   1. string blockers/evidence entries are wrapped as objects, recorded in an
#      event; commands[] and identity stay strict
#   2. the driver normalises at worker exit (before any hash binds packet.json)
#      and the accepted packet imports; a packet queued by an older engine is
#      normalised at import
#   3. a packet that keeps failing is parked after N identical failures, shown
#      in `singular health` as ATTENTION, and retried only when the file changes

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-packet-import-normalisation.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"
FIXTURE="$ENGINE_HOME/tests/fixtures/packet-import-normalisation/string-blocker.json"
SCHEMA="$ENGINE_HOME/schemas/state-packet.v0.schema.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: ${1:0:1500}"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2'"; }

workroot="$(mktemp -d)"
trap '[[ -n "${KEEP_WORKROOT:-}" ]] && echo "kept: $workroot" >&2 || rm -rf "$workroot"' EXIT

# ---- 1. The synthetic packet through the import validators -------------------------
unit="$workroot/unit"; mkdir -p "$unit/state"
lib() {
  SINGULAR_ROOT="$unit" SINGULAR_STATE_DIR="$unit/state" \
    SINGULAR_EVENTS_FILE="$unit/state/events.ndjson" \
    bash -c 'source "$1" >/dev/null; shift; "$@"' fixture "$SCRIPT_DIR/lib.sh" "$@"
}
schema_check() {
  lib singular_json_schema_check "$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))))' "$1")" \
    "$SCHEMA" "state packet" >/dev/null 2>"$unit/schema.err"
}
cp "$FIXTURE" "$unit/packet.json"
schema_check "$unit/packet.json" && fail "fixture no longer reproduces the schema rejection"
assert_contains "$(cat "$unit/schema.err")" "state packet.blockers[0] must be an object" "schema error reproduced"
python3 - "$unit/packet.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
d["evidence"].append("Gate: passed.")
json.dump(d, open(sys.argv[1], "w", encoding="utf-8"), indent=2)
PY
report="$(lib singular_packet_normalize_free_text "$unit/packet.json")"
assert_contains "$report" '"normalized":true' "normalisation report"
assert_contains "$report" '{"path":"blockers[0]","as":"summary"}' "blocker named in the report"
schema_check "$unit/packet.json" || fail "normalised packet still fails the schema: $(cat "$unit/schema.err")"
python3 - "$unit/packet.json" "$FIXTURE" <<'PY' || fail "normalised packet content"
import json, sys
after = json.load(open(sys.argv[1], encoding="utf-8"))
before = json.load(open(sys.argv[2], encoding="utf-8"))
assert after["blockers"] == [{"summary": before["blockers"][0]}], after["blockers"]
assert after["evidence"][-1] == {"kind": "note", "ref": "Gate: passed."}, after["evidence"][-1]
assert after["evidence"][:-1] == before["evidence"]
for key in ("schema", "packetId", "runId", "taskId", "area", "role", "status", "baseRef",
            "branch", "headSha", "workspace", "ownedFiles", "changedFiles", "commands",
            "tests", "nextAction", "createdAt"):
    assert after[key] == before[key], key
PY
before_sha="$(shasum -a 256 "$unit/packet.json" | awk '{print $1}')"
assert_contains "$(lib singular_packet_normalize_free_text "$unit/packet.json")" '"normalized":false' "second pass is a no-op"
[[ "$(shasum -a 256 "$unit/packet.json" | awk '{print $1}')" == "$before_sha" ]] || fail "no-op pass rewrote the packet"
# Authority stays strict: a command or test that is a bare string is not wrapped.
for mutation in 'd["commands"] = ["pnpm test"]' 'd["tests"] = ["registry.test.ts"]' \
    'd["blockers"] = [42]' 'd["status"] = "done"' 'd["risks"] = ["x"]'; do
  cp "$FIXTURE" "$unit/strict.json"
  python3 - "$unit/strict.json" "$mutation" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8")); d["blockers"] = []
exec(sys.argv[2])
json.dump(d, open(sys.argv[1], "w", encoding="utf-8"), indent=2)
PY
  lib singular_packet_normalize_free_text "$unit/strict.json" >/dev/null
  schema_check "$unit/strict.json" && fail "strict member was accepted after normalisation: $mutation"
done
# The worker-exit path: normalised before validation, with an event.
cp "$FIXTURE" "$unit/last-message.json"
lib singular_l1_prepare_worker_packet "$unit/last-message.json" "$unit/last-message.json" "$unit/validation.log" \
  || fail "worker packet with a string blocker was refused: $(cat "$unit/validation.log")"
schema_check "$unit/last-message.json" || fail "worker-exit packet is not schema-valid"
assert_contains "$(cat "$unit/state/events.ndjson")" '"type":"packet.normalized"' "worker-exit normalisation event"
assert_contains "$(cat "$unit/state/events.ndjson")" '"stage":"worker"' "worker-exit stage recorded"
echo "ok: string blockers/evidence are wrapped and recorded; commands, tests, status and unknown members stay strict"

# ---- 2 + 3. The real driver, importer and reconciler ---------------------------
root="$workroot/repo"
mkdir -p "$root/docs/orchestration/tasks" "$root/docs/orchestration/prompts" "$root/.singular-state"
git -C "$root" init -q
git -C "$root" checkout -q -b target
cp "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md" \
  "$ENGINE_HOME/templates/prompts/auditor.md" "$root/docs/orchestration/prompts/"
printf '# Decider Prompt\n[TASK-ID] [FAILURE CLASS]\n' >"$root/docs/orchestration/prompts/decider.md"
printf '{"schemaVersion":"v2","targetBranch":"target","gateCommand":"bash strict-gate.sh"}\n' \
  >"$root/singular.config.json"
printf '.singular-state/\n.worktrees/\n' >"$root/.gitignore"
cat >"$root/strict-gate.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"schema":"singular.orchestration.gate-observation.v0","failures":[]}' \
  >"$SINGULAR_GATE_REPORT_FILE"
SH
chmod +x "$root/strict-gate.sh"
cat >"$root/docs/orchestration/tasks/TASK-0001.md" <<'EOF'
# TASK-0001: Packet import normalisation fixture

Status: ready
Area: widget
Target branch: `target`
Worker branch: `agent/widget/TASK-0001-generic`
Test policy: `strict_test_first`
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
git -C "$root" add . && git -C "$root" -c user.name=t -c user.email=t@t commit -qm init

mock="$workroot/mock-runner.sh"
cat >"$mock" <<'MOCK'
#!/usr/bin/env bash
set -uo pipefail
level=""; worktree=""; out=""; prompt=""
args=("$@"); i=0
while [[ $i -lt ${#args[@]} ]]; do
  case "${args[$i]}" in
    --level) level="${args[$((i+1))]}"; i=$((i+2)) ;;
    -C|--worktree) worktree="${args[$((i+1))]}"; i=$((i+2)) ;;
    --prompt-file) prompt="${args[$((i+1))]}"; i=$((i+2)) ;;
    --output-last-message) out="${args[$((i+1))]}"; i=$((i+2)) ;;
    *) i=$((i+1)) ;;
  esac
done
if [[ "$level" == "l2" ]]; then
  mkdir -p "$worktree/internal/widget"
  printf 'package widget\n// stable content\n' >"$worktree/internal/widget/parser.go"
  # The field shape: one plain sentence in blockers that does not block.
  [[ -n "$out" ]] && cat >"$out" <<'PKT'
{"schema":"singular.orchestration.state-packet.v0","packetId":"p","runId":"r","taskId":"TASK-0001","area":"widget","role":"l2-developer","status":"needs-review","baseRef":"target","branch":"agent/widget/TASK-0001-generic","headSha":"0","workspace":"w","ownedFiles":["internal/widget/parser.go"],"changedFiles":[],"commands":[],"tests":[],"evidence":[],"blockers":["For the data area (does not block this task): the contract has no procedure for this."],"nextAction":"await auditor verdict","createdAt":"2026-01-01T00:00:00Z"}
PKT
  exit 0
fi
audit_status=""
[[ -f "$prompt" ]] && audit_status="$(sed -n 's/.*classification is `\([^`]*\)`.*/\1/p' "$prompt" | tail -1)"
[[ -n "$audit_status" ]] || audit_status="passed"
# Import binds the audit to the packet's run, so echo the real run id.
audit_run="$(python3 -c 'import re,sys; m=re.search(r"runId\s*\"(RUN-[^\"]+)\"", open(sys.argv[1], encoding="utf-8").read()); print(m.group(1) if m else "r")' "$prompt" 2>/dev/null || echo r)"
[[ -n "$out" ]] && cat >"$out" <<JSON
{"schema":"singular.orchestration.audit-verdict.v1","taskId":"TASK-0001","runId":"$audit_run","branch":"agent/widget/TASK-0001-generic","verdict":"accepted","evidenceReviewed":["evidence-manifest.json"],"verificationResults":[{"status":"$audit_status","command":"bash strict-gate.sh","exitCode":0,"evidenceRefs":["audit-verification.json"],"rationale":"matches the host classification"}],"commandsRun":[],"findings":[],"requiredFixes":[],"rationale":"accepted"}
JSON
exit 0
MOCK
chmod +x "$mock"

engine_env=(env SINGULAR_ROOT="$root" SINGULAR_STATE_DIR="$root/.singular-state"
  SINGULAR_ORCH_DIR="$root/docs/orchestration" SINGULAR_TASKS_DIR="$root/docs/orchestration/tasks"
  SINGULAR_LEASES_DIR="$root/.singular-state/leases" SINGULAR_INBOX_DIR="$root/.singular-state/inbox"
  SINGULAR_RUNS_DIR="$root/.singular-state/runs" SINGULAR_WORKTREES_DIR="$root/.worktrees"
  SINGULAR_EVENTS_FILE="$root/.singular-state/events.ndjson"
  SINGULAR_TARGET_BRANCH=target SINGULAR_RUNNER="$mock" SINGULAR_ENGINE_HOME="$ENGINE_HOME"
  SINGULAR_DECIDER_FAST=1 SINGULAR_AUDIT_VERIFY=0 SINGULAR_AUTO_INTEGRATE=0)
events() { cat "$root/.singular-state/events.ndjson"; }
event_count() { grep -c "\"type\":\"$1\"" "$root/.singular-state/events.ndjson" || true; }

rc=0; out="$("${engine_env[@]}" bash "$SCRIPT_DIR/l1-drive.sh" TASK-0001 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "drive with a string blocker should accept: $out"
inbox_packet="$(ls "$root"/.singular-state/inbox/*.json | head -1)"
run_dir="$(dirname "$(ls "$root"/.singular-state/runs/*/packet.json | head -1)")"
assert_contains "$(events)" '"type":"packet.normalized"' "driver normalisation event"
python3 - "$inbox_packet" "$run_dir/packet.json" "$run_dir/evidence-manifest.json" <<'PY' || fail "queued packet shape"
import hashlib, json, sys
inbox, run_packet, manifest = sys.argv[1:4]
for path in (inbox, run_packet):
    blockers = json.load(open(path, encoding="utf-8"))["blockers"]
    assert blockers and all(isinstance(item, dict) for item in blockers), (path, blockers)
    assert blockers[0]["summary"].startswith("For the data area"), blockers
PY
cp "$inbox_packet" "$workroot/good-packet.json"

# A packet queued by an engine that did not normalise at worker exit.
python3 - "$inbox_packet" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
d["blockers"] = [d["blockers"][0]["summary"]]
json.dump(d, open(sys.argv[1], "w", encoding="utf-8"), indent=2)
PY
rc=0; out="$("${engine_env[@]}" bash "$SCRIPT_DIR/import-packet.sh" "$inbox_packet" 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "a queued packet with a string blocker should import: $out"
ev="$(events)"
assert_contains "$ev" '"stage":"import"' "import-time normalisation event"
assert_contains "$ev" '"type":"packet.imported"' "packet imported"
imported="$(ls "$root"/docs/orchestration/packets/imported/TASK-0001/*.json | grep -v audit | head -1)"
python3 -c 'import json,sys; b=json.load(open(sys.argv[1]))["blockers"]; assert isinstance(b[0], dict) and b[0]["summary"], b' \
  "$imported" || fail "imported packet kept a string blocker"
echo "ok: the driver normalises at worker exit and the importer normalises an already queued packet"

# ---- 3. A packet that cannot be repaired by normalisation ----------------------
bad="$root/.singular-state/inbox/RUN-BAD.json"
python3 - "$workroot/good-packet.json" "$bad" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
d["commands"] = ["pnpm test (all green)"]
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"), indent=2)
PY
: >"$root/.singular-state/events.ndjson"
reconcile() { "${engine_env[@]}" bash "$SCRIPT_DIR/reconcile.sh" --apply >"$workroot/reconcile.log" 2>&1 || true; }
for cycle in 1 2; do reconcile; done
[[ "$(event_count packet.import_failed)" -eq 2 ]] \
  || fail "expected 2 import failures after 2 cycles, got $(event_count packet.import_failed): $(tail -5 "$workroot/reconcile.log")"
[[ "$(event_count packet.import_parked)" -eq 0 ]] || fail "parked before the limit"
health="$("${engine_env[@]}" bash "$SCRIPT_DIR/ops.sh" health 2>/dev/null || true)"
assert_not_contains "$health" "packet import parked" "no attention before the limit"
reconcile
[[ "$(event_count packet.import_failed)" -eq 3 && "$(event_count packet.import_parked)" -eq 1 ]] \
  || fail "third identical failure should park once (failed=$(event_count packet.import_failed) parked=$(event_count packet.import_parked))"
assert_contains "$(grep '"type":"packet.import_parked"' "$root/.singular-state/events.ndjson")" \
  "commands[0] must be an object" "parked event carries the validation error"
assert_contains "$(grep '"type":"packet.import_parked"' "$root/.singular-state/events.ndjson")" \
  '"taskId":"TASK-0001"' "parked event names the task"
for cycle in 4 5; do reconcile; done
[[ "$(event_count packet.import_failed)" -eq 3 && "$(event_count packet.import_parked)" -eq 1 ]] \
  || fail "a parked packet was validated again (failed=$(event_count packet.import_failed))"
[[ -f "$bad" ]] || fail "the parked packet was removed from the inbox"
health="$("${engine_env[@]}" bash "$SCRIPT_DIR/ops.sh" health 2>/dev/null || true)"
attention="$(printf '%s\n' "$health" | grep '^ATTENTION:' || true)"
assert_contains "$attention" "packet import parked: TASK-0001" "health ATTENTION names the task"
assert_contains "$attention" "commands[0] must be an object" "health ATTENTION carries the exact error"
health_json="$("${engine_env[@]}" bash "$SCRIPT_DIR/ops.sh" health --json 2>/dev/null || true)"
assert_contains "$health_json" '"parkedImports"' "health --json lists parked imports"
# The file changes: it is tried again, and the failure count starts over.
python3 - "$bad" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
d["commands"] = ["pnpm test"]
json.dump(d, open(sys.argv[1], "w", encoding="utf-8"), indent=2)
PY
reconcile
[[ "$(event_count packet.import_failed)" -eq 4 && "$(event_count packet.import_parked)" -eq 1 ]] \
  || fail "a changed packet was not retried (failed=$(event_count packet.import_failed))"
health="$("${engine_env[@]}" bash "$SCRIPT_DIR/ops.sh" health 2>/dev/null || true)"
assert_not_contains "$health" "packet import parked" "a retried packet is no longer reported as parked"
echo "ok: an unimportable packet is parked after 3 identical failures, shown in health, and retried when it changes"

echo "PASS: test-packet-import-normalisation"
