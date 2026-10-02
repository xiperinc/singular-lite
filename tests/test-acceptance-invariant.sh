#!/usr/bin/env bash
set -euo pipefail

# PublishAccepted(K) <=> G(K) and A(K) and D(K) and E(K)   (0.23.4, protocol 1.1)
#
# Every accepted-packet publication rechecks one predicate for the exact
# candidate: G the host verification passed for this head/tree, A a host-bound
# accepted audit with nothing blocking or unclassified, D the review ledger
# durably holds this run/attempt/head round as accepted, E the evidence
# manifest binds this verdict and host report. Budgets are not inputs.
#
# Predicate (on the artifacts of a real accepted run, one conjunct broken at a
# time): missing gate report, stale gate (other head), mismatched audit head,
# P0 still open, incomplete classification, review-ledger round missing or not
# accepted, evidence manifest invalid/stale, a preserved model failed-product.
#
# Driver: the ordinary path publishes when the predicate holds; --no-audit,
# an enabled legacy accept-waiver, an accepted verdict with an open P0 and a
# model failed-product against a host pass never publish an accepted packet;
# retained accepted-checkpoint recovery republishes only while the predicate
# still holds for the retained certificate.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-acceptance-invariant.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2' in: $1"; }

scratch="$(mktemp -d)"
trap 'chmod -R u+w "$scratch" 2>/dev/null || true; rm -rf "$scratch"' EXIT

with_fixture() {
  FIXTURE_TMP="$scratch/$1"
  local root="$FIXTURE_TMP/repo"
  mkdir -p "$root/docs/orchestration/prompts" "$root/docs/orchestration/tasks" \
    "$root/.singular-state"
  git -C "$root" init -q
  git -C "$root" checkout -q -b target
  cp "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md" "$root/docs/orchestration/prompts/"
  cp "$ENGINE_HOME/templates/prompts/auditor.md" "$root/docs/orchestration/prompts/"
  cp "$ENGINE_HOME/templates/prompts/decider.md" "$root/docs/orchestration/prompts/"
  printf '.singular-state/\n.worktrees/\n.singular-evidence/\n' >"$root/.gitignore"
  cat >"$root/docs/orchestration/tasks/TASK-0001.md" <<'EOF'
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
  git -C "$root" add .
  git -C "$root" -c user.name=test -c user.email=test@example.local commit -q -m init
  export SINGULAR_ROOT="$root"
  export SINGULAR_ORCH_DIR="$root/docs/orchestration"
  export SINGULAR_TASKS_DIR="$SINGULAR_ORCH_DIR/tasks"
  export SINGULAR_STATE_DIR="$root/.singular-state"
  export SINGULAR_RUNS_DIR="$SINGULAR_STATE_DIR/runs"
  export SINGULAR_INBOX_DIR="$SINGULAR_STATE_DIR/inbox"
  export SINGULAR_LEASES_DIR="$SINGULAR_STATE_DIR/leases"
  export SINGULAR_EVENTS_FILE="$SINGULAR_STATE_DIR/events.ndjson"
  export SINGULAR_STOP_FILE="$SINGULAR_STATE_DIR/STOP"
  export SINGULAR_WORKTREES_DIR="$root/.worktrees"
  export SINGULAR_TARGET_BRANCH="target"
  export SINGULAR_ENGINE_HOME="$ENGINE_HOME"
  export SINGULAR_RUNNER="$FIXTURE_TMP/mock-runner.sh"
  export MOCK_COUNTER_DIR="$FIXTURE_TMP/counters"
  export SINGULAR_AUDIT_VERIFY=0
  unset SINGULAR_MODULES SINGULAR_DECIDER_FAST SINGULAR_WORKER_INFRA_MAX \
    SINGULAR_AUDIT_INFRA_MAX SINGULAR_LEGACY_UNBOUND_WAIVERS SINGULAR_REQUIRE_AUDIT \
    SINGULAR_LOCAL_CONFIG_FILE SINGULAR_BASE_REF SINGULAR_DISPATCH_BASE_SHA \
    MOCK_AUDIT_VERDICT MOCK_AUDIT_STATUS MOCK_AUDIT_CLASSIFIED MOCK_DECIDER_ACTION \
    2>/dev/null || true
  make_runner "$SINGULAR_RUNNER"
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib.sh"
}

# Worker writes the owned file; the auditor writes an audit-verdict.v1 that
# echoes the host classification unless MOCK_AUDIT_STATUS overrides it.
make_runner() {
  cat >"$1" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--describe-contract" ]]; then
  printf '%s\n' '{"schema":"singular.runner-contract.v1","version":1,"provider":"codex","arguments":["--worktree","--prompt-file","--level","--run-id","--output-last-message","--role","--capability-profile","--result-file","--describe-contract"],"structuredResult":"singular.orchestration.runner-result.v0","structuredProviderError":"singular.orchestration.provider-error.v0"}'
  exit 0
fi
level=""; out=""; chdir=""; prompt=""; run_id=""; result_file=""
role="${SINGULAR_RUNNER_ROLE:-}"; capability="${SINGULAR_RUNNER_CAPABILITY_PROFILE:-fixture}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --level) level="$2"; shift 2 ;;
    -C|--worktree) chdir="$2"; shift 2 ;;
    --output-last-message) out="$2"; shift 2 ;;
    --prompt-file) prompt="$2"; shift 2 ;;
    --run-id) run_id="$2"; shift 2 ;;
    --role) role="$2"; shift 2 ;;
    --capability-profile) capability="$2"; shift 2 ;;
    --result-file) result_file="$2"; shift 2 ;;
    *) shift ;;
  esac
done
write_result() {
  local rc=$?
  [[ "$rc" -eq 0 && -n "$result_file" ]] || return "$rc"
  python3 - "$result_file" "$run_id" "$role" "$capability" "$out" <<'PY'
import datetime, json, sys
path, run_id, role, capability, output = sys.argv[1:]
json.dump({
    "schema":"singular.orchestration.runner-result.v0", "contractVersion":1,
    "provider":"codex", "runId":run_id, "role":role,
    "capabilityProfile":capability, "exitCode":0, "outcome":"succeeded",
    "failureClass":"none", "providerErrorRef":None, "outputRef":output,
    "recordedAt":datetime.datetime.now(datetime.timezone.utc).replace(
        microsecond=0).isoformat().replace("+00:00", "Z"),
}, open(path, "w", encoding="utf-8"))
PY
}
trap write_result EXIT
cdir="${MOCK_COUNTER_DIR:?}"; mkdir -p "$cdir"
bump() { local f="$cdir/$1" n=0; [[ -f "$f" ]] && n="$(cat "$f")"; n=$((n+1)); printf '%s' "$n" >"$f"; echo "$n"; }
if [[ "$prompt" == *decider-prompt-* ]]; then
  bump decider-calls >/dev/null
  fc="${prompt##*decider-prompt-}"; fc="${fc%.md}"
  python3 - "$out" "${MOCK_DECIDER_ACTION:-escalate-parked}" "$fc" <<'PY'
import json, sys
json.dump({"schema":"singular.orchestration.decider-verdict.v0","failureClass":sys.argv[3],"taskId":"TASK-0001","action":sys.argv[2],"rationale":"mock decider","nextOwner":"l1"}, open(sys.argv[1],"w"))
PY
  exit 0
fi
if [[ "$level" == "l2" ]]; then
  n="$(bump worker-calls)"
  mkdir -p "$chdir/internal/widget" "$chdir/.singular-evidence"
  printf 'package widget\n// v%s\n' "$n" >"$chdir/internal/widget/parser.go"
  printf 'red\n' >"$chdir/.singular-evidence/red.log"; printf 'green\n' >"$chdir/.singular-evidence/green.log"
  printf 'regression\n' >"$chdir/.singular-evidence/regression.log"
  python3 - "$out" <<'PY'
import json, sys
json.dump({"schema":"singular.orchestration.state-packet.v0","packetId":"p","runId":"r","taskId":"TASK-0001","area":"widget","role":"l2-developer","status":"needs-review","baseRef":"target","branch":"agent/widget/TASK-0001-generic","headSha":"uncommitted","workspace":"/tmp","ownedFiles":["internal/widget/parser.go"],"changedFiles":["internal/widget/parser.go"],"commands":[{"cmd":"true","exitCode":0,"logRef":".singular-evidence/green.log"}],"tests":[{"name":"t red","phase":"red","status":"failed-as-expected","logRef":".singular-evidence/red.log"},{"name":"t green","phase":"green","status":"passed","logRef":".singular-evidence/green.log"},{"name":"t regression","phase":"regression","status":"passed","logRef":".singular-evidence/regression.log"}],"evidence":[{"kind":"red-log","ref":".singular-evidence/red.log"},{"kind":"green-log","ref":".singular-evidence/green.log"},{"kind":"regression-log","ref":".singular-evidence/regression.log"}],"blockers":[],"nextAction":"audit","createdAt":"2026-01-01T00:00:00Z"}, open(sys.argv[1],"w"))
PY
  exit 0
fi
bump audit-calls >/dev/null
host_report="$(dirname "$out")/audit-verification.json"
python3 - "$out" "$run_id" "$host_report" <<'PY'
import json, os, sys
out, run_id, host_report = sys.argv[1:4]
status = json.load(open(host_report, encoding="utf-8"))["outcome"]
if status == "passed-with-acknowledged-baseline":
    status = "passed"
status = os.environ.get("MOCK_AUDIT_STATUS") or status
verdict = os.environ.get("MOCK_AUDIT_VERDICT", "accepted")
classified = json.loads(os.environ.get("MOCK_AUDIT_CLASSIFIED", "[]"))
findings = [item["summary"] for item in classified]
record = {
    "schema": "singular.orchestration.audit-verdict.v1",
    "taskId": "TASK-0001", "runId": run_id,
    "branch": "agent/widget/TASK-0001-generic", "verdict": verdict,
    "evidenceReviewed": ["evidence-manifest.json", "audit-verification.json"],
    "verificationResults": [{
        "status": status, "command": "true", "exitCode": 0,
        "evidenceRefs": ["audit-verification.json"], "rationale": "fixture echo",
    }],
    "commandsRun": [], "findings": findings,
    "requiredFixes": findings if verdict == "needs-fix" else [],
    "rationale": "fixture verdict",
}
if classified:
    record["classifiedFindings"] = classified
json.dump(record, open(out, "w", encoding="utf-8"))
PY
exit 0
STUB
  chmod +x "$1"
}

drive() {
  DRIVE_RC=0
  DRIVE_OUT="$("${DRIVE_ENGINE:-$SCRIPT_DIR}/l1-drive.sh" "$@" 2>&1)" || DRIVE_RC=$?
}
edit_json() {  # file python-statement-on-d
  python3 - "$1" "$2" <<'PY'
import json, sys
path, stmt = sys.argv[1:3]
d = json.load(open(path, encoding="utf-8"))
exec(stmt)
json.dump(d, open(path, "w", encoding="utf-8"), indent=2)
PY
}
events() { cat "$SINGULAR_EVENTS_FILE" 2>/dev/null || true; }
only_run_dir() { find "$SINGULAR_RUNS_DIR" -mindepth 1 -maxdepth 1 -type d | head -1; }

# Nothing integrable was published: no inbox packet, lease/packet not accepted.
assert_unpublished() {
  local label="$1" run_dir
  run_dir="$(only_run_dir)"
  [[ -z "$(find "$SINGULAR_INBOX_DIR" -name '*.json' 2>/dev/null)" ]] \
    || fail "$label: an accepted packet reached the inbox"
  [[ "$(singular_lease_field TASK-0001 status 2>/dev/null || true)" != "accepted" ]] \
    || fail "$label: lease was stamped accepted"
  [[ "$(singular_json_field "$run_dir/packet.json" status 2>/dev/null || true)" != "accepted" ]] \
    || fail "$label: packet was marked accepted"
  assert_not_contains "$(events)" '"type":"l1.task_accepted"' "$label: no acceptance event"
}

# =========================== driver: positive ================================
case_positive_and_predicate() {
with_fixture positive
drive TASK-0001
assert_eq "$DRIVE_RC" "0" "positive: accepted run publishes ($DRIVE_OUT)"
pos_run_dir="$(only_run_dir)"
pos_run="$(basename "$pos_run_dir")"
[[ -f "$SINGULAR_INBOX_DIR/$pos_run.json" ]] || fail "positive: packet not queued"
assert_eq "$(singular_lease_field TASK-0001 status)" "accepted" "positive: lease accepted"
python3 - "$pos_run_dir/acceptance-check.json" <<'PY' || fail "positive: acceptance check record"
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
assert value["accepted"] is True and value["attempt"] == 1, value
PY
assert_not_contains "$(events)" '"l1.acceptance_refused"' "positive: no refusal"
pass "a candidate satisfying G, A, D and E publishes an accepted packet"

# ===================== predicate: one conjunct at a time =====================
# The same wrapper the driver calls, extracted verbatim, against the positive
# run's real artifacts. Each case breaks one input and restores it.
pos_head="$(singular_json_field "$pos_run_dir/packet.json" headSha)"
task_id=TASK-0001; run_id="$pos_run"; waiver=no
worker_branch=agent/widget/TASK-0001-generic
task_file="$SINGULAR_TASKS_DIR/TASK-0001.md"
review_logical_change=TASK-0001
l1_campaign_binding="$(singular_campaign_binding)"
# shellcheck disable=SC1090
source <(sed -n '/^l1_acceptance_refusal=""$/,/^# Resume publication for an immutable head/p' \
  "$SCRIPT_DIR/l1-drive.sh")
declare -F l1_validate_acceptance >/dev/null || fail "l1_validate_acceptance not extracted"
l1_validate_acceptance probe "$pos_run" "$pos_run_dir" "$pos_head" 1 \
  || fail "predicate: positive artifacts refused ($l1_acceptance_refusal)"

audit="$pos_run_dir/audit.json"
report="$pos_run_dir/audit-verification.json"
manifest="$pos_run_dir/evidence-manifest.json"
ledger="$SINGULAR_STATE_DIR/review-policy/ledger.json"
for f in "$audit" "$report" "$manifest" "$ledger"; do cp "$f" "$f.keep"; done
restore() { for f in "$audit" "$report" "$manifest" "$ledger"; do cp "$f.keep" "$f"; done; rm -f "$audit.pre-normalize.json"; }

expect_refused() {
  local label="$1" want="$2" head="${3:-$pos_head}"
  if l1_validate_acceptance probe "$pos_run" "$pos_run_dir" "$head" 1; then
    fail "$label: predicate accepted"
  fi
  assert_eq "$l1_acceptance_refusal" "$want" "$label: refusal"
  restore
  pass "$label is refused ($want)"
}

rm -f "$report"
expect_refused "missing gate report" "G:host-report-missing"

edit_json "$report" 'd["verificationRequest"]["headSha"] = "0" * 40'
expect_refused "stale gate (report for another head)" "G:host-report-head-mismatch"

expect_refused "candidate head differs from the verified and audited head" \
  "G:host-report-head-mismatch" "$(git -C "$SINGULAR_ROOT" rev-parse target)"

edit_json "$audit" 'd["evidenceReviewed"] = [x if not x.startswith("reviewed-head-sha:") else "reviewed-head-sha:" + "0" * 40 for x in d["evidenceReviewed"]]'
expect_refused "audit reviewed a different head" "A:audit-identity-mismatch"

edit_json "$audit" 'd["classifiedFindings"] = [{"id": "F1", "severity": "P0", "summary": "Data loss", "trigger": "Write", "impact": "Lost data", "requirement": "Preserve data"}]; d["findings"] = ["Data loss"]'
expect_refused "accepted verdict with a P0 still open" "A:blocking-finding-open"

edit_json "$audit" 'd["classifiedFindings"] = [{"id": "F1", "severity": "P0", "summary": "Data loss", "trigger": "Write", "impact": "Lost data"}]; d["findings"] = ["Data loss"]'
expect_refused "P0 lacking prose is not demoted into acceptance" "A:blocking-finding-open"

edit_json "$audit" 'd["reviewPolicy"]["originalVerdict"] = "needs-fix"; d["findings"] = ["Data loss", "Nit"]; d["requiredFixes"] = ["Data loss"]; d["classifiedFindings"] = [{"id": "F2", "severity": "P3", "summary": "Nit"}]'
expect_refused "incomplete classification" "A:classification-incomplete"

edit_json "$audit" 'd["requiredFixes"] = ["Fix the parser"]'
expect_refused "accepted verdict still requiring an unclassified fix" "A:classification-incomplete"

cp "$audit.keep" "$audit.pre-normalize.json"
edit_json "$audit.pre-normalize.json" 'd["verificationResults"][0]["status"] = "failed-product"'
expect_refused "preserved model failed-product overwritten by the host pass" \
  "A:model-reported-product-failure"

edit_json "$audit" 'd["verdict"] = "needs-fix"'
expect_refused "audit verdict not accepted" "A:audit-not-accepted"

edit_json "$ledger" 'd["logicalChanges"]["TASK-0001"]["rounds"] = []'
expect_refused "review ledger round missing (commit lost)" "D:review-round-missing"

rm -f "$ledger"
expect_refused "review ledger never committed" "D:review-round-missing"

edit_json "$ledger" 'd["logicalChanges"]["TASK-0001"]["rounds"][-1]["effectiveVerdict"] = "needs-fix"'
expect_refused "review ledger round recorded as failed" "D:review-round-not-accepted"

edit_json "$ledger" 'd["logicalChanges"]["TASK-0001"]["rounds"][-1]["attempt"] = 2'
expect_refused "review ledger round for another attempt" "D:review-round-stale"

edit_json "$manifest" 'd["headSha"] = "0" * 40'
expect_refused "evidence manifest for another head" "E:evidence-manifest-identity-mismatch"

edit_json "$manifest" 'del d["diffSha256"]'
expect_refused "evidence manifest schema-invalid" "E:evidence-manifest-schema-invalid"

rm -f "$manifest"
expect_refused "evidence manifest missing" "E:evidence-manifest-missing"

printf '\n' >>"$audit"
expect_refused "audit changed after the evidence manifest bound it" "E:evidence-manifest-stale"

l1_validate_acceptance probe "$pos_run" "$pos_run_dir" "$pos_head" 1 \
  || fail "predicate: restored artifacts refused ($l1_acceptance_refusal)"

# ===================== normalize() narrowing (protocol 4.3) ==================
cp "$audit.keep" "$scratch/fp.json"
edit_json "$scratch/fp.json" 'd["verificationResults"][0]["status"] = "failed-product"'
cp "$scratch/fp.json" "$scratch/fp.before.json"
if python3 "$SCRIPT_DIR/audit-verdict-host-bind.py" --host-report "$report" \
    --verdict "$scratch/fp.json" --normalize --command true \
    --evidence-ref x >/dev/null 2>"$scratch/fp.err"; then
  fail "normalize rewrote a model-reported failed-product to the host pass"
fi
cmp -s "$scratch/fp.json" "$scratch/fp.before.json" \
  || fail "refused normalization still modified the verdict"
[[ ! -e "$scratch/fp.json.pre-normalize.json" ]] || fail "refused normalization wrote a backup"
assert_contains "$(cat "$scratch/fp.err")" "product-failure evidence" "normalize refusal reason"
pass "normalize never overwrites a model-reported failed-product (verdict untouched)"

# ============== stranded accepted packet (E5 auto-heal route) ===============
# The driver died after marking the packet accepted but before the inbox copy.
# accept-existing-packet re-verifies deterministically and writes a
# host-authored audit; that is not a fresh audit, so the route publishes only
# when the original certificate still satisfies the predicate.
rm -f "$SINGULAR_INBOX_DIR/$pos_run.json"
edit_json "$ledger" 'd["logicalChanges"]["TASK-0001"]["rounds"] = []'
SINGULAR_RESUME_ACCEPTED_EVIDENCE=0 drive TASK-0001
assert_eq "$DRIVE_RC" "3" "stranded negative: refused ($DRIVE_OUT)"
[[ ! -e "$SINGULAR_INBOX_DIR/$pos_run.json" ]] || fail "stranded negative: packet queued"
assert_contains "$(events)" '"path":"stranded-packet"' "stranded negative: refusal path"
assert_not_contains "$(events)" '"type":"packet.accepted_existing"' \
  "stranded negative: deterministic re-acceptance never ran"
cmp -s "$audit" "$audit.keep" || fail "stranded negative: original audit was replaced"
restore
pass "a stranded accepted packet without its review-ledger round is not re-published"

SINGULAR_RESUME_ACCEPTED_EVIDENCE=0 drive TASK-0001
assert_eq "$DRIVE_RC" "0" "stranded positive: auto-healed ($DRIVE_OUT)"
[[ -f "$SINGULAR_INBOX_DIR/$pos_run.json" ]] || fail "stranded positive: packet not queued"
assert_contains "$(events)" '"type":"l1.auto_accepted_existing"' "stranded positive: heal event"
pass "a stranded accepted packet whose certificate still holds is re-published"
}

# ======================= driver: refused publications ========================
case_refused_publications() {
# --no-audit: an otherwise acceptable candidate is a diagnostic result only.
(
with_fixture no-audit
drive --no-audit TASK-0001
assert_eq "$DRIVE_RC" "3" "--no-audit: non-accepting exit ($DRIVE_OUT)"
assert_unpublished "--no-audit"
assert_contains "$(events)" '"reason":"audit-disabled"' "--no-audit: refusal reason"
assert_contains "$DRIVE_OUT" "NOT ACCEPTED" "--no-audit: outcome reported"
pass "--no-audit never produces an accepted packet"
)

# --no-audit with a needs-fix audit used to publish outright.
(
with_fixture no-audit-needs-fix
MOCK_AUDIT_VERDICT=needs-fix drive --no-audit TASK-0001
assert_eq "$DRIVE_RC" "3" "--no-audit needs-fix: non-accepting exit ($DRIVE_OUT)"
assert_unpublished "--no-audit needs-fix"
pass "--no-audit cannot turn a needs-fix audit into acceptance"
)

# Enabled legacy waiver: the decider's accept-waiver is routed through the
# predicate, which a needs-fix audit cannot satisfy.
(
with_fixture waiver
SINGULAR_LEGACY_UNBOUND_WAIVERS=1 SINGULAR_DECIDER_FAST=0 \
  MOCK_DECIDER_ACTION=accept-waiver MOCK_AUDIT_VERDICT=needs-fix \
  MOCK_AUDIT_CLASSIFIED='[{"id":"F1","severity":"P1","summary":"Parser drops input","trigger":"empty input","impact":"data loss","requirement":"keep input"}]' \
  drive TASK-0001
assert_eq "$DRIVE_RC" "3" "waiver: non-accepting exit ($DRIVE_OUT)"
assert_unpublished "enabled legacy waiver"
assert_contains "$(events)" '"type":"l1.acceptance_refused"' "waiver: refusal event"
assert_contains "$(events)" '"waiver":"yes"' "waiver: refusal names the waiver"
assert_contains "$(events)" '"conjunct":"A"' "waiver: audit conjunct fails"
pass "an enabled legacy accept-waiver cannot substitute for an accepted audit"
)

# An accepted verdict carrying an open, fully supported P0.
(
with_fixture accepted-p0
MOCK_AUDIT_CLASSIFIED='[{"id":"F1","severity":"P0","summary":"Data loss","trigger":"write","impact":"stored data lost","requirement":"preserve data"}]' \
  drive TASK-0001
assert_eq "$DRIVE_RC" "3" "accepted P0: non-accepting exit ($DRIVE_OUT)"
assert_unpublished "accepted verdict with P0"
# Two independent layers refuse it: review_policy classify() turns the
# accepted label into needs-fix before publication is ever attempted, and the
# acceptance predicate refuses an open P0 if a verdict ever reaches it.
ev="$(events)"
if [[ "$ev" != *'"reason":"blocking-finding-open"'* ]]; then
  assert_contains "$ev" '"originalVerdict":"accepted","effectiveVerdict":"needs-fix"' \
    "accepted P0: refused by classification or by the predicate"
fi
pass "an accepted verdict with an open P0 is not published"
)

# Model reports failed-product while the host passed: never normalized to a
# pass, never accepted.
(
with_fixture model-failed-product
SINGULAR_AUDIT_INFRA_MAX=0 MOCK_AUDIT_STATUS=failed-product drive TASK-0001
assert_eq "$DRIVE_RC" "3" "model failed-product: non-accepting exit ($DRIVE_OUT)"
assert_unpublished "model failed-product vs host passed"
assert_not_contains "$(events)" '"type":"l1.audit_verification_normalized"' \
  "model failed-product: not normalized"
assert_contains "$(events)" '"type":"l1.audit_verification_mismatch"' \
  "model failed-product: recorded as a mismatch"
fp_audit="$(only_run_dir)/audit.json"
assert_eq "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["verificationResults"][0]["status"])' "$fp_audit")" \
  "failed-product" "model failed-product: raw verdict preserved"
pass "a model failed-product against a host pass is not accepted"
)
}

# ================= retained accepted-checkpoint recovery =====================
case_retained_checkpoint() {
# Fail the final evidence refresh (and its one retry) after an accepted audit,
# exactly like the field incident: the run parks as awaiting-evidence.
with_fixture checkpoint
engine_view="$FIXTURE_TMP/engine-view"
mkdir -p "$engine_view"
for entry in "$ENGINE_HOME"/engine/*; do ln -s "$entry" "$engine_view/$(basename "$entry")"; done
rm "$engine_view/evidence-manifest.sh"
cat >"$engine_view/evidence-manifest.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
counter="${MOCK_MANIFEST_COUNTER:?}"
count=0
[[ -f "$counter" ]] && count="$(cat "$counter")"
count=$((count + 1))
printf '%s\n' "$count" >"$counter"
if [[ "$count" -eq 3 || "$count" -eq 4 ]]; then
  echo "injected post-verdict evidence finalization failure" >&2
  exit 77
fi
exec "${REAL_EVIDENCE_MANIFEST:?}" "$@"
STUB
chmod +x "$engine_view/evidence-manifest.sh"
export MOCK_MANIFEST_COUNTER="$FIXTURE_TMP/manifest-calls"
export REAL_EVIDENCE_MANIFEST="$ENGINE_HOME/engine/evidence-manifest.sh"
DRIVE_ENGINE="$engine_view" drive TASK-0001
assert_eq "$DRIVE_RC" "3" "checkpoint: accepted audit awaits evidence ($DRIVE_OUT)"
assert_contains "$DRIVE_OUT" "AWAITING EVIDENCE" "checkpoint: awaiting evidence"
cp_run_dir="$(only_run_dir)"
cp_ledger="$SINGULAR_STATE_DIR/review-policy/ledger.json"
cp "$cp_ledger" "$FIXTURE_TMP/ledger.keep"

# Negative: the retained certificate no longer validates (its review-ledger
# round is gone). Recovery refuses and preserves the checkpoint unpublished.
edit_json "$cp_ledger" 'd["logicalChanges"]["TASK-0001"]["rounds"] = []'
DRIVE_ENGINE="$engine_view" drive TASK-0001
assert_eq "$DRIVE_RC" "3" "checkpoint negative: refused ($DRIVE_OUT)"
assert_unpublished "retained checkpoint without its ledger round"
assert_eq "$(singular_json_field "$cp_run_dir/packet.json" status)" "blocked" \
  "checkpoint negative: checkpoint preserved"
assert_contains "$(events)" '"path":"retained-checkpoint"' "checkpoint negative: refusal path"
assert_contains "$(events)" '"reason":"acceptance-predicate-D-review-round-missing"' \
  "checkpoint negative: resume refusal reason"
assert_eq "$(cat "$MOCK_COUNTER_DIR/worker-calls")" "1" "checkpoint negative: no worker rerun"
assert_eq "$(cat "$MOCK_COUNTER_DIR/audit-calls")" "1" "checkpoint negative: no auditor rerun"
pass "retained-checkpoint recovery refuses when the predicate no longer holds"

# Positive: with the certificate intact the same checkpoint republishes.
cp "$FIXTURE_TMP/ledger.keep" "$cp_ledger"
DRIVE_ENGINE="$engine_view" drive TASK-0001
assert_eq "$DRIVE_RC" "0" "checkpoint positive: resumed ($DRIVE_OUT)"
assert_contains "$DRIVE_OUT" "RESUMED ACCEPTED EVIDENCE" "checkpoint positive: resumed outcome"
[[ -f "$SINGULAR_INBOX_DIR/$(basename "$cp_run_dir").json" ]] \
  || fail "checkpoint positive: packet not queued"
assert_eq "$(singular_lease_field TASK-0001 status)" "accepted" "checkpoint positive: lease accepted"
python3 - "$cp_run_dir/acceptance-check.json" <<'PY' || fail "checkpoint positive: acceptance check record"
import json, sys
assert json.load(open(sys.argv[1], encoding="utf-8"))["accepted"] is True
PY
assert_eq "$(cat "$MOCK_COUNTER_DIR/audit-calls")" "1" "checkpoint positive: no auditor rerun"
pass "retained-checkpoint recovery republishes when the predicate still holds"
}

# Each case builds its own consumer fixture; lib.sh exports per-fixture
# configuration paths, so every case runs in its own subshell.
( case_positive_and_predicate )
( case_refused_publications )
( case_retained_checkpoint )
echo "test-acceptance-invariant: ok"
