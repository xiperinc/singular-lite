#!/usr/bin/env bash
set -euo pipefail

# 0.23.6: a correct audit verdict is not thrown away over its format.
#
# Synthetic verdicts exercise an invited assumptionId, restated P3 priors,
# strict authority fields and retained candidates after format exhaustion.
# Part 1 uses the validation chain; part 2 drives l1-drive.sh with mocks.
#
#   (a) extra finding property        -> normalised, accepted, event emitted
#   (b) accepted + still-open P3 priors not carried -> host carries, accepted
#   (c) same, one prior is P1         -> not accepted, precise reason
#   (d) unknown top-level field / wrong identity -> still rejected
#   (e) format retries exhausted      -> candidate retained as awaiting-audit,
#       re-audited by `drive --audit-only` without an implementer pass

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-audit-verdict-normalisation.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"
BIND="$SCRIPT_DIR/audit-verdict-host-bind.py"
FIXTURES="$ENGINE_HOME/tests/fixtures/audit-verdict-normalisation"
FIXTURE_TASK="TASK-0001"
FIXTURE_RUN="RUN-fixture-audit"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: ${1:0:1500}"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2'"; }

workroot="$(mktemp -d)"
# KEEP_WORKROOT=1 leaves the fixture repository behind for inspection.
trap '[[ -n "${KEEP_WORKROOT:-}" ]] && echo "kept: $workroot" >&2 || rm -rf "$workroot"' EXIT

# ---- Part 1: synthetic refused verdicts through the driver's validation chain --
# normalise -> schema + identity -> findingsStatus/severity -> review policy.
unit="$workroot/unit"
new_case() {
  rm -rf "$unit"; mkdir -p "$unit"
  cp "$FIXTURES/audit-prior-findings-attempt-2.json" "$FIXTURES/findings-status.json" \
    "$FIXTURES/review-policy-attempt-1.json" "$unit/"
  cp "$FIXTURES/$1" "$unit/audit.json"
}
edit() { python3 - "$1" "$2" <<'PY'
import json, sys
path, code = sys.argv[1:3]
d = json.load(open(path, encoding="utf-8"))
exec(code)
json.dump(d, open(path, "w", encoding="utf-8"), indent=2)
PY
}
normalise() {
  env -u SINGULAR_REVIEW_POLICY_JSON -u SINGULAR_REVIEW_BLOCKING_SEVERITIES \
    SINGULAR_ROOT="$unit" python3 "$BIND" --normalize-format --verdict "$unit/audit.json" \
    --prior-findings "$unit/audit-prior-findings-attempt-2.json" --run-dir "$unit" \
    >"$unit/normalise.out" 2>"$unit/normalise.err"
}
schema_check() {
  SINGULAR_ROOT="$unit" SINGULAR_STATE_DIR="$unit/state" \
    SINGULAR_AUDIT_SCHEMA="$ENGINE_HOME/schemas/audit-verdict.v1.schema.json" \
    bash -c 'source "$1" >/dev/null; singular_validate_audit_verdict "$2" "$3" "$4"' \
    fixture "$SCRIPT_DIR/lib.sh" "$unit/audit.json" "${1:-$FIXTURE_TASK}" "$FIXTURE_RUN" \
    >/dev/null 2>"$unit/schema.err"
}
format_check() {
  python3 "$BIND" --validate-audit-format --verdict "$unit/audit.json" \
    --prior-findings "$unit/audit-prior-findings-attempt-2.json" >/dev/null 2>"$unit/format.err"
}
policy() {
  env -u SINGULAR_REVIEW_POLICY_JSON -u SINGULAR_REVIEW_BLOCKING_SEVERITIES \
    python3 - "$SCRIPT_DIR" "$unit/audit.json" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import review_policy
result = review_policy.classify(json.load(open(sys.argv[2], encoding="utf-8")),
                                review_policy.load_policy())
print(json.dumps({k: result[k] for k in
                  ("effectiveVerdict", "blocking", "backlog", "reasons", "unclassifiedCount")}))
PY
}
chain_accepts() {
  normalise || fail "$1: normalisation failed: $(cat "$unit/normalise.err")"
  schema_check || fail "$1: schema/identity rejected: $(cat "$unit/schema.err")"
  format_check || fail "$1: findingsStatus/severity rejected: $(cat "$unit/format.err")"
  policy_out="$(policy)"
  assert_contains "$policy_out" '"effectiveVerdict": "accepted"' "$1: review policy"
  assert_contains "$policy_out" '"blocking": []' "$1: nothing blocking"
}

# (a) Synthetic try 0. assumptionId is invited by the engine's own prompt and is now
# a schema member, so it survives; a property nobody defined is dropped and
# recorded; the still-open P3 priors are carried (b) in the same pass.
grep -q 'assumptionId' "$SCRIPT_DIR/ctx-assumptions-prompt.sh" \
  || fail "the assumption-audit prompt no longer asks for assumptionId; revisit the schema"
new_case audit-attempt-2-try-0.invalid.json
edit "$unit/audit.json" 'd["classifiedFindings"][1]["confidence"] = "high"; d["verificationResults"][0]["durationMs"] = 12'
cp "$unit/audit.json" "$unit/received.json"
chain_accepts "(a) synthetic try 0"
python3 - "$unit" <<'PY' || fail "(a) normalisation record"
import json, sys
unit = sys.argv[1]
verdict = json.load(open(unit + "/audit.json", encoding="utf-8"))
report = json.load(open(unit + "/normalise.out", encoding="utf-8"))
received = json.load(open(unit + "/received.json", encoding="utf-8"))
assert report["normalized"] is True, report
dropped = {item["path"]: item["fields"] for item in report["droppedFields"]}
assert dropped == {"classifiedFindings[1]": ["confidence"],
                   "verificationResults[0]": ["durationMs"]}, dropped
assert verdict["classifiedFindings"][0]["assumptionId"] == "A3", verdict["classifiedFindings"][0]
assert "confidence" not in verdict["classifiedFindings"][1]
assert "durationMs" not in verdict["verificationResults"][0]
note = verdict["hostNormalization"]
assert note["droppedFields"] == report["droppedFields"], note
# Authority fields are untouched, and the response as received is kept.
for key in ("schema", "taskId", "runId", "branch", "verdict", "findingsStatus", "rationale"):
    assert verdict[key] == received[key], key
assert [r["status"] for r in verdict["verificationResults"]] == \
    [r["status"] for r in received["verificationResults"]]
assert json.load(open(unit + "/audit.json.pre-format-normalize.json", encoding="utf-8")) == received
PY
echo "ok: (a) unknown finding properties are dropped and recorded; assumptionId is schema-valid"

# (b) Synthetic try 1: accepted, four P3 priors still-open, restated but not repeated.
new_case audit-attempt-2-try-1.invalid.json
format_check && fail "(b) fixture no longer reproduces the format rejection"
assert_contains "$(cat "$unit/format.err")" "without carrying them" "(b) strict rejection reproduced"
chain_accepts "(b) synthetic try 1"
python3 - "$unit" "$FIXTURES/findings-status.json" <<'PY' || fail "(b) carried priors"
import json, sys
unit, ledger_path = sys.argv[1:3]
verdict = json.load(open(unit + "/audit.json", encoding="utf-8"))
ledger = {e["id"]: e["text"] for e in json.load(open(ledger_path, encoding="utf-8"))["findings"]}
still_open = sorted(k for k, v in verdict["findingsStatus"].items() if v == "still-open")
assert still_open == ['f-0ec31550d9ba', 'f-99fa77a5abf6', 'f-d9d05ae8b846', 'f-ebe0f3724c9f']
carried = verdict["hostNormalization"]["carriedPriorFindings"]
assert sorted(item["id"] for item in carried) == still_open, carried
for item in carried:
    assert item["severity"] == "P3" and item["disposition"] == "backlog", item
    assert item["reason"], item
    assert ledger[item["id"]] in verdict["findings"], item
assert verdict["requiredFixes"] == [], verdict["requiredFixes"]
assert verdict["verdict"] == "accepted"
PY
echo "ok: (b) still-open P3 priors are carried by the host as backlog; the verdict is accepted"

# (c) Same verdict, but the host's record says one still-open prior is P1.
new_case audit-attempt-2-try-1.invalid.json
edit "$unit/review-policy-attempt-1.json" '
for item in d["items"]:
    if item["id"] == "F3":
        item.update({"severity": "P1", "trigger": "request parser help",
                     "impact": "required usage guidance is absent", "requirement": "document empty input"})
'
edit "$unit/findings-status.json" '
for entry in d["findings"]:
    if entry["id"] == "f-d9d05ae8b846":
        assert entry["text"].startswith("F3 (P3):")
'
# The ledger text carries a (P3) tag that now disagrees with the P1 record: the
# host has no consistent severity, so it carries nothing and refuses precisely.
normalise || fail "(c) conflicting record must not fail normalisation itself"
format_check && fail "(c) a prior with no usable severity record was accepted"
assert_contains "$(cat "$unit/format.err")" "f-d9d05ae8b846" "(c) refusal names the prior"
assert_contains "$(cat "$unit/format.err")" "no usable" "(c) refusal says why the host did not carry it"
# A consistent P1 record: the prior is carried as a required fix at P1 and the
# review policy turns the acceptance into needs-fix.
new_case audit-attempt-2-try-1.invalid.json
p1_text="F3 (P1): the parser help omits required empty-input guidance."
p1_id="$(python3 -c 'import hashlib,sys; t=" ".join(sys.argv[1].replace("`","").lower().split()); print("f-"+hashlib.sha256(t.encode()).hexdigest()[:12])' "$p1_text")"
P1_TEXT="$p1_text" P1_ID="$p1_id" python3 - "$unit" <<'PY'
import json, os, sys
unit = sys.argv[1]
text, ident, old = os.environ["P1_TEXT"], os.environ["P1_ID"], "f-d9d05ae8b846"
def rewrite(name, fn):
    path = f"{unit}/{name}"
    d = json.load(open(path, encoding="utf-8")); fn(d)
    json.dump(d, open(path, "w", encoding="utf-8"), indent=2)
def ledger(d):
    for e in d["findings"]:
        if e["id"] == old:
            e["id"], e["text"] = ident, text
def prior(d):
    for key in ("suppliedIds", "requiredIds"):
        d[key] = [ident if i == old else i for i in d[key]]
def record(d):
    for item in d["items"]:
        if item["id"] == "F3":
            item.update({"severity": "P1", "trigger": "request parser help",
                         "impact": "required usage guidance is absent",
                         "requirement": "document empty input"})
def verdict(d):
    d["findingsStatus"][ident] = d["findingsStatus"].pop(old)
rewrite("findings-status.json", ledger)
rewrite("audit-prior-findings-attempt-2.json", prior)
rewrite("review-policy-attempt-1.json", record)
rewrite("audit.json", verdict)
PY
normalise || fail "(c) normalisation failed: $(cat "$unit/normalise.err")"
schema_check || fail "(c) schema rejected the host-completed verdict: $(cat "$unit/schema.err")"
format_check || fail "(c) host-carried blocking prior was rejected as format: $(cat "$unit/format.err")"
policy_out="$(policy)"
assert_contains "$policy_out" '"effectiveVerdict": "needs-fix"' "(c) a still-open P1 prior is not accepted"
assert_contains "$policy_out" "\"blocking\": [\"$p1_id\"]" "(c) exactly the P1 prior blocks"
assert_contains "$policy_out" "blocking-finding" "(c) review-policy reason"
P1_TEXT="$p1_text" P1_ID="$p1_id" python3 - "$unit" <<'PY' || fail "(c) blocking carry record"
import json, os, sys
verdict = json.load(open(sys.argv[1] + "/audit.json", encoding="utf-8"))
ident, text = os.environ["P1_ID"], os.environ["P1_TEXT"]
entry = next(i for i in verdict["hostNormalization"]["carriedPriorFindings"] if i["id"] == ident)
assert entry["severity"] == "P1" and entry["disposition"] == "blocking", entry
assert "blocking under the review policy" in entry["reason"], entry
assert verdict["requiredFixes"] == [text], verdict["requiredFixes"]
item = next(i for i in verdict["classifiedFindings"] if i["id"] == entry["classifiedAs"])
assert item["severity"] == "P1" and item["summary"] == text and item["requirement"], item
others = [i for i in verdict["hostNormalization"]["carriedPriorFindings"] if i["id"] != ident]
assert len(others) == 3 and all(i["disposition"] == "backlog" for i in others), others
assert verdict["verdict"] == "accepted", "the auditor's own label is kept for the pre-policy record"
PY
echo "ok: (c) a still-open P1 prior becomes a required fix (needs-fix); an unprovable severity is refused"

# (d) Authority stays strict.
new_case audit-attempt-2-try-1.invalid.json
edit "$unit/audit.json" 'd["approvedBy"] = "auditor"'
normalise || fail "(d) top-level normalisation errored"
schema_check && fail "(d) an unknown top-level field was accepted"
assert_contains "$(cat "$unit/schema.err")" "unknown field(s): approvedBy" "(d) top-level field named"
assert_not_contains "$(cat "$unit/audit.json")" '"droppedFields"' "(d) top-level field must not be dropped"

new_case audit-attempt-2-try-1.invalid.json
normalise
schema_check TASK-0012 && fail "(d) a verdict for another task was accepted"
assert_contains "$(cat "$unit/schema.err")" "taskId mismatch" "(d) identity"
python3 "$BIND" --validate-identity --verdict "$unit/audit.json" --expected-task "$FIXTURE_TASK" \
  --expected-run "$FIXTURE_RUN" --expected-branch "agent/other/branch" \
  --expected-head "dc13fc4661138bc7fa293b6839032ea4f939bbd8" >/dev/null 2>"$unit/identity.err" \
  && fail "(d) a verdict for another branch was accepted"
assert_contains "$(cat "$unit/identity.err")" "branch does not match" "(d) branch identity"

new_case audit-attempt-2-try-1.invalid.json
edit "$unit/audit.json" 'd["verdict"] = "approved"'
normalise; schema_check && fail "(d) an illegal verdict value was accepted"
new_case audit-attempt-2-try-1.invalid.json
edit "$unit/audit.json" 'd["verificationResults"][0].update({"status": "green", "note": "x"})'
normalise; schema_check && fail "(d) an illegal verification status survived normalisation"
new_case audit-attempt-2-try-1.invalid.json
edit "$unit/audit.json" 'd["classifiedFindings"][0]["severity"] = "P9"'
normalise; schema_check && fail "(d) an illegal severity survived normalisation"
new_case audit-attempt-2-try-1.invalid.json
edit "$unit/audit.json" 'd["hostNormalization"] = {"version": 1}'
normalise && fail "(d) an auditor-written hostNormalization was accepted"
assert_contains "$(cat "$unit/normalise.err")" "host-owned" "(d) host-owned member"
new_case audit-attempt-2-try-1.invalid.json
edit "$unit/audit.json" 'd["findingsStatus"]["f-ffffffffffff"] = "resolved"'
normalise; format_check && fail "(d) an invented prior finding id was accepted"
echo "ok: (d) unknown top-level fields, identity, verdict, status and severity values stay fatal"

# ---- Part 2: the real driver ---------------------------------------------------
root="$workroot/repo"
mkdir -p "$root/docs/orchestration/tasks" "$root/docs/orchestration/prompts" "$root/.singular-state"
printf ".singular-state/\n.worktrees/\n" >"$root/.gitignore"
git -C "$root" init -q
git -C "$root" checkout -q -b target
cp "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md" \
  "$ENGINE_HOME/templates/prompts/auditor.md" "$root/docs/orchestration/prompts/"
printf '# Decider Prompt\n[TASK-ID] [FAILURE CLASS]\n' >"$root/docs/orchestration/prompts/decider.md"
printf '{"schemaVersion":"v2","targetBranch":"target","gateCommand":"bash strict-gate.sh"}\n' \
  >"$root/singular.config.json"
cat >"$root/strict-gate.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"schema":"singular.orchestration.gate-observation.v0","failures":[]}' \
  >"$SINGULAR_GATE_REPORT_FILE"
SH
chmod +x "$root/strict-gate.sh"
cat >"$root/docs/orchestration/tasks/TASK-0001.md" <<'EOF'
# TASK-0001: Audit verdict normalisation fixture

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

# Mock runner. L2 writes fixed content and counts its launches. The auditor is
# scripted by AUDIT_MODE; call numbers come from AUDIT_COUNT_FILE.
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
bump() { local n=0; [[ -f "$1" ]] && n="$(cat "$1" 2>/dev/null || echo 0)"; n=$((n+1)); echo "$n" >"$1"; echo "$n"; }
if [[ "$level" == "l2" ]]; then
  bump "$L2_COUNT_FILE" >/dev/null
  mkdir -p "$worktree/internal/widget"
  printf 'package widget\n// stable content\n' >"$worktree/internal/widget/parser.go"
  [[ -n "$out" ]] && cat >"$out" <<'PKT'
{"schema":"singular.orchestration.state-packet.v0","packetId":"p","runId":"r","taskId":"TASK-0001","area":"widget","role":"l2-developer","status":"needs-review","baseRef":"target","branch":"agent/widget/TASK-0001-generic","headSha":"0","workspace":"w","ownedFiles":["internal/widget/parser.go"],"changedFiles":[],"commands":[],"tests":[],"evidence":[],"blockers":[],"nextAction":"await auditor verdict","createdAt":"2026-01-01T00:00:00Z"}
PKT
  exit 0
fi
ac="$(bump "$AUDIT_COUNT_FILE")"
audit_status=""
[[ -f "$prompt" ]] && audit_status="$(sed -n 's/.*classification is `\([^`]*\)`.*/\1/p' "$prompt" | tail -1)"
[[ -n "$audit_status" ]] || audit_status="passed"
run_id="$(sed -n 's/.*runId[[:space:]]*"\(RUN-[^"]*\)".*/\1/p' "$prompt" 2>/dev/null | head -1)"
[[ -n "$out" ]] || exit 0
AUDIT_OUT="$out" AUDIT_STATUS="$audit_status" AUDIT_CALL="$ac" AUDIT_RUN="${run_id:-r}" \
  AUDIT_MODE="${AUDIT_MODE:-clean}" python3 - <<'PY'
import hashlib, json, os

def ledger_id(text):
    norm = " ".join(str(text).replace("`", "").lower().split())
    return "f-" + hashlib.sha256(norm.encode("utf-8")).hexdigest()[:12]

mode, call = os.environ["AUDIT_MODE"], int(os.environ["AUDIT_CALL"])
F1 = "F1 (P1): the parser drops the last token"
F2 = "F2 (P3) [A1]: the parser name shadows a package"
F1_ITEM = {"id": "F1", "severity": "P1", "summary": "the parser drops the last token",
           "trigger": "input without trailing newline", "impact": "data loss",
           "requirement": "consume the final token"}
record = {
    "schema": "singular.orchestration.audit-verdict.v1",
    "taskId": "TASK-0001",
    "runId": os.environ["AUDIT_RUN"],
    "branch": "agent/widget/TASK-0001-generic",
    "verdict": "accepted",
    "evidenceReviewed": ["evidence-manifest.json", "audit-verification.json"],
    "verificationResults": [{
        "status": os.environ["AUDIT_STATUS"], "command": "bash strict-gate.sh", "exitCode": 0,
        "evidenceRefs": ["audit-verification.json"],
        "rationale": "matches the host-derived classification",
    }],
    "commandsRun": [], "findings": [], "requiredFixes": [], "rationale": "accepted",
}
if mode in ("normalise", "p1-open") and call == 1:
    record.update({
        "verdict": "needs-fix", "findings": [F1, F2], "requiredFixes": [F1],
        "classifiedFindings": [F1_ITEM, {"id": "F2", "severity": "P3",
                                         "summary": "the parser name shadows a package"}],
        "rationale": "one blocking defect",
    })
elif mode == "normalise":
    # Accepted; the P3 prior is still open and restated, not repeated, and its
    # classified item carries the invited assumptionId plus an invented member.
    record.update({
        "findings": ["F2 (P3): unchanged; the parser name still shadows a package"],
        "classifiedFindings": [{"id": "F2", "severity": "P3",
                                "summary": "the parser name still shadows a package",
                                "assumptionId": "A1", "confidence": "high"}],
        "findingsStatus": {ledger_id(F1): "resolved", ledger_id(F2): "still-open"},
    })
elif mode == "p1-open":
    # Contradiction: accepted while the P1 prior is reported still-open.
    record.update({
        "findingsStatus": {ledger_id(F1): "still-open", ledger_id(F2): "resolved"},
    })
elif mode == "toplevel":
    record["approvedBy"] = "auditor"
elif mode == "wrong-identity":
    record["taskId"] = "TASK-9999"
with open(os.environ["AUDIT_OUT"], "w", encoding="utf-8") as handle:
    json.dump(record, handle)
    handle.write("\n")
PY
exit 0
MOCK
chmod +x "$mock"

engine_env=(env SINGULAR_ROOT="$root" SINGULAR_STATE_DIR="$root/.singular-state"
  SINGULAR_ORCH_DIR="$root/docs/orchestration" SINGULAR_TASKS_DIR="$root/docs/orchestration/tasks"
  SINGULAR_LEASES_DIR="$root/.singular-state/leases" SINGULAR_INBOX_DIR="$root/.singular-state/inbox"
  SINGULAR_RUNS_DIR="$root/.singular-state/runs" SINGULAR_WORKTREES_DIR="$root/.worktrees"
  SINGULAR_EVENTS_FILE="$root/.singular-state/events.ndjson"
  SINGULAR_TARGET_BRANCH=target SINGULAR_RUNNER="$mock" SINGULAR_ENGINE_HOME="$ENGINE_HOME"
  SINGULAR_DECIDER_FAST=1 SINGULAR_AUDIT_VERIFY=0
  AUDIT_COUNT_FILE="$workroot/audit-count" L2_COUNT_FILE="$workroot/l2-count")
run_drive() {  # run_drive MODE [driver args...]
  local mode="$1"; shift
  "${engine_env[@]}" AUDIT_MODE="$mode" bash "$SCRIPT_DIR/l1-drive.sh" TASK-0001 "$@" 2>&1
}
reset_fixture() {
  rm -rf "$root/.singular-state/runs" "$root/.singular-state/leases" \
    "$root/.singular-state/inbox" "$root/.singular-state/review-policy" "$root/.worktrees" \
    "$root/.singular-state/retained-worktrees"
  : >"$root/.singular-state/events.ndjson"
  rm -f "$workroot/audit-count" "$workroot/l2-count"
  git -C "$root" worktree prune 2>/dev/null || true
  git -C "$root" branch -D agent/widget/TASK-0001-generic >/dev/null 2>&1 || true
  python3 - "$root/docs/orchestration/tasks/TASK-0001.md" <<'PY'
import re, sys
p = sys.argv[1]; t = open(p).read()
open(p, "w").write(re.sub(r"Status: \w+", "Status: ready", t, count=1))
PY
}
events() { cat "$root/.singular-state/events.ndjson"; }
count() { cat "$1" 2>/dev/null || echo 0; }
task_status() { sed -n 's/^Status: //p' "$root/docs/orchestration/tasks/TASK-0001.md" | head -1; }

# (a)+(b) end to end: needs-fix, repair, then an accepted re-audit that trips
# both format rules. One auditor call per attempt; nothing is retried.
rc=0; out="$(run_drive normalise)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "(a/b) drive should accept: $out"
ev="$(events)"
assert_contains "$ev" '"type":"l1.audit_verdict_normalized"' "(a/b) normalisation event"
assert_contains "$ev" '"fields":["confidence"]' "(a/b) dropped property named in the event"
assert_contains "$ev" '"disposition":"backlog"' "(a/b) carried prior named in the event"
assert_contains "$ev" '"type":"l1.task_accepted"' "(a/b) task accepted"
assert_not_contains "$ev" '"type":"audit.infra_retry"' "(a/b) no auditor retry was spent"
assert_not_contains "$ev" '"type":"l1.audit_invalid_verdict"' "(a/b) verdict was not refused"
[[ "$(count "$workroot/audit-count")" -eq 2 ]] || fail "(a/b) auditor ran $(count "$workroot/audit-count") times, expected 2"
audit_path="$(ls "$root"/.singular-state/runs/*/audit.json | head -1)"
python3 - "$audit_path" <<'PY' || fail "(a/b) stored verdict provenance"
import json, sys
verdict = json.load(open(sys.argv[1], encoding="utf-8"))
note = verdict["hostNormalization"]
assert note["droppedFields"] == [{"path": "classifiedFindings[0]", "fields": ["confidence"]}], note
carried = note["carriedPriorFindings"]
assert len(carried) == 1 and carried[0]["severity"] == "P3" and carried[0]["disposition"] == "backlog", carried
assert verdict["classifiedFindings"][0]["assumptionId"] == "A1"
assert "F2 (P3) [A1]: the parser name shadows a package" in verdict["findings"], verdict["findings"]
assert verdict["verdict"] == "accepted" and verdict["reviewPolicy"]["effectiveVerdict"] == "accepted"
assert verdict["reviewPolicy"]["blocking"] == [], verdict["reviewPolicy"]
received = json.load(open(sys.argv[1] + ".pre-format-normalize.json", encoding="utf-8"))
assert "hostNormalization" not in received and received["classifiedFindings"][0]["confidence"] == "high"
PY
[[ "$(task_status)" == "accepted" ]] || fail "(a/b) task status is $(task_status)"
echo "ok: (a)+(b) the driver accepts a normalised verdict without a second auditor pass"

# (c) end to end: accepted while the P1 prior is still-open. Not accepted, and
# not an infrastructure failure either: the review policy says needs-fix.
reset_fixture
rc=0; out="$(run_drive p1-open)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "(c) an accepted verdict with a still-open P1 prior was accepted"
ev="$(events)"
assert_contains "$ev" '"disposition":"blocking"' "(c) blocking carry recorded in the event"
assert_contains "$ev" '"originalVerdict":"accepted","effectiveVerdict":"needs-fix"' "(c) review policy outcome"
assert_not_contains "$ev" '"type":"l1.task_accepted"' "(c) task must not be accepted"
assert_not_contains "$ev" '"escalate-infra"' "(c) a product finding is not an infrastructure failure"
assert_not_contains "$ev" '"type":"audit.infra_retry"' "(c) no auditor retry was spent"
python3 - "$(ls "$root"/.singular-state/runs/*/review-policy-attempt-2.json | head -1)" <<'PY' \
  || fail "(c) review-policy round record"
import json, sys
record = json.load(open(sys.argv[1], encoding="utf-8"))
assert record["effectiveVerdict"] == "needs-fix" and "blocking-finding" in record["reasons"], record
assert len(record["blocking"]) == 1 and record["blocking"][0].startswith("f-"), record["blocking"]
PY
echo "ok: (c) the driver turns accepted + still-open P1 into needs-fix, with the reason recorded"

# (d) end to end: a wrong identity exhausts the retries and stays an
# infrastructure park; the refused response does not stay in audit.json.
reset_fixture
rc=0; out="$(run_drive wrong-identity)" || rc=$?
[[ "$rc" -eq 3 ]] || fail "(d) wrong identity should park (rc=$rc): $out"
ev="$(events)"
assert_contains "$ev" '"action":"escalate-infra"' "(d) wrong identity remains escalate-infra"
assert_not_contains "$ev" '"type":"l1.task_awaiting_audit"' "(d) wrong identity is not recoverable by re-audit"
assert_not_contains "$ev" '"type":"l1.task_accepted"' "(d) task must not be accepted"
ls "$root"/.singular-state/runs/*/audit.json >/dev/null 2>&1 \
  && fail "(d) a refused response was left on the authority path (audit.json)"
python3 - "$root/.singular-state/leases/TASK-0001.json" <<'PY' || fail "(d) lease"
import json, sys
assert "auditRecheck" not in json.load(open(sys.argv[1], encoding="utf-8"))
PY
echo "ok: (d) a verdict with a wrong identity is still refused and parked as infrastructure"

# (e) format retries exhausted on a response whose authority fields are valid.
reset_fixture
rc=0; out="$(run_drive toplevel)" || rc=$?
[[ "$rc" -eq 3 ]] || fail "(e) exhausted format retries should end non-accepting (rc=$rc): $out"
ev="$(events)"
assert_contains "$ev" '"type":"l1.audit_repair_retry"' "(e) the one repair retry was used"
assert_contains "$ev" '"type":"audit.format_exhausted"' "(e) format exhaustion recorded"
assert_contains "$ev" '"type":"l1.task_awaiting_audit"' "(e) awaiting-audit terminal"
assert_contains "$ev" '"decision":"awaiting-audit"' "(e) decision recorded"
assert_not_contains "$ev" 'escalate-infra' "(e) not an infrastructure escalation"
assert_not_contains "$ev" '"type":"audit.infra_exhausted"' "(e) not charged as infrastructure exhaustion"
assert_not_contains "$ev" '"type":"l1.product_repair_budget_consumed"' "(e) no product repair charged"
assert_contains "$out" "AWAITING AUDIT: TASK-0001" "(e) operator line"
assert_contains "$out" "singular drive TASK-0001 --audit-only" "(e) operator command"
[[ "$(count "$workroot/l2-count")" -eq 1 && "$(count "$workroot/audit-count")" -eq 2 ]] \
  || fail "(e) expected 1 implementer and 2 auditor launches"
first_run="$(basename "$(dirname "$(ls "$root"/.singular-state/runs/*/packet.json | head -1)")")"
ls "$root"/.singular-state/runs/*/audit.json >/dev/null 2>&1 \
  && fail "(e) the refused response was left on the authority path (audit.json)"
[[ -f "$root/.singular-state/runs/$first_run/audit-attempt-1.rejected.json" ]] \
  || fail "(e) the refused response was not preserved"
head_before="$(git -C "$root" rev-parse agent/widget/TASK-0001-generic)"
[[ -d "$root/.worktrees/TASK-0001" ]] || fail "(e) candidate worktree was not retained"
python3 - "$root/.singular-state/leases/TASK-0001.json" "$first_run" "$head_before" <<'PY' \
  || fail "(e) lease auditRecheck record"
import json, sys
lease = json.load(open(sys.argv[1], encoding="utf-8"))
record = lease["auditRecheck"]
assert record["runId"] == sys.argv[2] and record["headSha"] == sys.argv[3], record
assert record["reason"] == "audit-format-exhausted", record
assert "approvedBy" in record["detail"], record
assert record["recoveryCommand"] == "singular drive TASK-0001 --audit-only", record
assert lease["retryCount"] == 0, lease["retryCount"]
# The candidate parked on its repair attempt, with the product budget spent.
# Re-auditing is not product work and must not need budget.
lease["retryCount"] = lease["maxRetries"]
json.dump(lease, open(sys.argv[1], "w", encoding="utf-8"), indent=2)
PY
health="$("${engine_env[@]}" bash "$SCRIPT_DIR/ops.sh" health 2>/dev/null || true)"
assert_contains "$health" "awaiting-audit: TASK-0001" "(e) health lists the retained candidate"
assert_contains "$health" "re-audit: singular drive TASK-0001 --audit-only" "(e) health prints the exact command"
health_json="$("${engine_env[@]}" bash "$SCRIPT_DIR/ops.sh" health --json 2>/dev/null || true)"
assert_contains "$health_json" '"recoveryCommand": "singular drive TASK-0001 --audit-only"' "(e) health --json"

# The printed command, with an auditor that now answers in format: only the
# audit runs. No implementer launch, same head, accepted.
rc=0; out="$(run_drive clean --audit-only)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "(e) audit-only pass should accept: $out"
ev="$(events)"
assert_contains "$ev" '"type":"l1.audit_only_started"' "(e) audit-only start recorded"
assert_contains "$ev" '"type":"l1.worker_replayed"' "(e) worker packet replayed by the host"
assert_contains "$ev" '"type":"l1.task_accepted"' "(e) task accepted by the audit-only pass"
[[ "$(count "$workroot/l2-count")" -eq 1 ]] \
  || fail "(e) the implementer was launched again ($(count "$workroot/l2-count") launches)"
[[ "$(count "$workroot/audit-count")" -eq 3 ]] || fail "(e) expected exactly one more auditor launch"
[[ "$(git -C "$root" rev-parse agent/widget/TASK-0001-generic)" == "$head_before" ]] \
  || fail "(e) the audit-only pass changed the candidate head"
[[ "$(task_status)" == "accepted" ]] || fail "(e) task status is $(task_status)"
python3 - "$root/.singular-state/leases/TASK-0001.json" <<'PY' || fail "(e) lease after audit-only"
import json, sys
lease = json.load(open(sys.argv[1], encoding="utf-8"))
assert "auditRecheck" not in lease and lease["status"] == "accepted", lease
assert lease["retryCount"] == lease["maxRetries"] == 1, lease
PY
assert_not_contains "$ev" '"type":"l1.product_repair_budget_consumed"' "(e) re-audit charged no repair"
# Without a retained candidate the flag refuses instead of running anything.
rc=0; out="$(run_drive clean --audit-only)" || rc=$?
[[ "$rc" -eq 2 ]] || fail "(e) --audit-only without a retained candidate should refuse (rc=$rc): $out"
echo "ok: (e) exhausted format retries retain the candidate; drive --audit-only re-runs only the audit"

# (e, upgrade) A park written before 0.23.6: escalate-infra, the refused
# "accepted" response still in audit.json, no lease record. Every ordinary
# drive is refused as an invalid retained checkpoint; --audit-only adopts it.
reset_fixture
rc=0; out="$(run_drive toplevel)" || rc=$?
[[ "$rc" -eq 3 ]] || fail "(e, upgrade) setup park failed: $out"
old_run="$(basename "$(dirname "$(ls "$root"/.singular-state/runs/*/packet.json | head -1)")")"
python3 - "$root/.singular-state" "$old_run" <<'PY'
import json, shutil, sys
state, run = sys.argv[1:3]
run_dir = f"{state}/runs/{run}"
shutil.copyfile(f"{run_dir}/audit-attempt-1.rejected.json", f"{run_dir}/audit.json")
shutil.copyfile(f"{run_dir}/audit.json", f"{run_dir}/audit.json.invalid.json")
for path, edit in ((f"{state}/leases/TASK-0001.json", lambda d: d.pop("auditRecheck")),
                   (f"{run_dir}/run-status.json", lambda d: d.update(outcome="escalate-infra"))):
    d = json.load(open(path, encoding="utf-8")); edit(d)
    json.dump(d, open(path, "w", encoding="utf-8"), indent=2)
PY
rc=0; out="$(run_drive clean)" || rc=$?
[[ "$rc" -eq 3 ]] || fail "(e, upgrade) an ordinary drive should still refuse the poisoned run (rc=$rc)"
assert_contains "$out" "accepted-checkpoint-invalid-retained-state" "(e, upgrade) retained-state symptom reproduced"
rc=0; out="$(run_drive clean --audit-only)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "(e, upgrade) audit-only should adopt and accept the old park: $out"
ev="$(events)"
assert_contains "$ev" '"type":"l1.audit_recheck_adopted"' "(e, upgrade) adoption recorded"
assert_contains "$ev" '"type":"l1.worker_replayed"' "(e, upgrade) worker packet replayed"
assert_contains "$ev" '"type":"l1.task_accepted"' "(e, upgrade) task accepted"
[[ "$(count "$workroot/l2-count")" -eq 1 ]] || fail "(e, upgrade) the implementer was launched again"
[[ -f "$root/.singular-state/runs/$old_run/audit-legacy.rejected.json" \
    && ! -e "$root/.singular-state/runs/$old_run/audit.json" ]] \
  || fail "(e, upgrade) the refused response was not moved off the authority path"
echo "ok: (e, upgrade) a pre-0.23.6 escalate-infra park is adopted and re-audited without an implementer pass"

echo "PASS: test-audit-verdict-normalisation"
