#!/usr/bin/env bash
set -euo pipefail

# Audit protocol shape at its source (loop-economics protocol 4.1-4.3, 5.2):
#   - the v1 schema keeps findingsStatus an object with nonblank IDs and states
#     the conditional P0/P1 support requirement (byte-identical mirrors);
#   - all three auditor prompt renderers (initial, re-audit, validation-feedback
#     repair) carry the exact shared findingsStatus fragment exactly once, and
#     the repair prompt no longer lists reviewPolicy as model-permitted;
#   - "first round" is the host's prior-finding set, not the attempt number;
#   - the host validator checks shape, permitted IDs and required coverage
#     against the host record, mirrors the P0/P1 rule the generic schema
#     checker cannot express, and never rewrites model output.
# The lifecycle consequence (one fresh auditor correction, no worker rerun) is
# pinned by test-first-audit-correction.sh FIRST_AUDIT_CASE=format-correction.

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIND="$ENGINE_HOME/engine/audit-verdict-host-bind.py"
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2'"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpectedly contained '$2'"; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/singular-findings-status.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# ---- 1. Schema: object shape kept, nonblank names, conditional P0/P1 --------
cmp -s "$ENGINE_HOME/schemas/audit-verdict.v1.schema.json" \
  "$ENGINE_HOME/schemas/orchestration/audit-verdict.v1.schema.json" \
  || fail "audit-verdict.v1 schema mirrors diverged"
python3 - "$ENGINE_HOME/schemas/audit-verdict.v1.schema.json" <<'PY' || fail "schema shape"
import json, sys
schema = json.load(open(sys.argv[1], encoding="utf-8"))
fs = schema["properties"]["findingsStatus"]
assert fs["type"] == "object", fs
assert fs["additionalProperties"] == {"type": "string", "enum": ["resolved", "still-open"]}, fs
assert fs["propertyNames"] == {"type": "string", "minLength": 1, "pattern": "\\S"}, fs
assert "Omit when no prior findings were supplied" in fs["description"], fs
assert "findingsStatus" not in schema["required"]
items = schema["properties"]["classifiedFindings"]["items"]
rule = items["allOf"][0]
assert rule["if"]["properties"]["severity"]["enum"] == ["P0", "P1"], rule
assert rule["then"]["required"] == ["trigger", "impact", "requirement"], rule
for field in ("trigger", "impact", "requirement"):
    assert rule["then"]["properties"][field]["pattern"] == "\\S", rule
PY
echo "ok: v1 schema keeps the object shape and states the P0/P1 rule"

# ---- 2. Host validator ------------------------------------------------------
verdict_base() {
  python3 - "$1" "$2" <<'PY'
import json, sys
path, extra = sys.argv[1], json.loads(sys.argv[2])
record = {
    "schema": "singular.orchestration.audit-verdict.v1",
    "taskId": "TASK-0001", "runId": "RUN-1", "branch": "agent/x",
    "verdict": "needs-fix", "evidenceReviewed": ["m"],
    "verificationResults": [{"status": "passed", "command": "c",
                             "evidenceRefs": ["r"], "rationale": "r"}],
    "commandsRun": [], "findings": [], "requiredFixes": [], "rationale": "r",
}
for key, value in extra.items():
    if value is None and key.startswith("-"):
        record.pop(key[1:], None)
    else:
        record[key] = value
json.dump(record, open(path, "w", encoding="utf-8"))
PY
}
prior() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
json.dump({"schema": "singular.orchestration.audit-prior-findings.v0", "attempt": 2,
           "suppliedIds": json.loads(sys.argv[2]), "requiredIds": json.loads(sys.argv[3])},
          open(sys.argv[1], "w", encoding="utf-8"))
PY
}
expect_ok() {
  local label="$1" extra="$2" supplied="$3" required="$4"
  verdict_base "$tmp/v.json" "$extra"; prior "$tmp/p.json" "$supplied" "$required"
  python3 "$BIND" --validate-audit-format --verdict "$tmp/v.json" \
    --prior-findings "$tmp/p.json" >/dev/null 2>"$tmp/err" \
    || fail "$label: rejected: $(cat "$tmp/err")"
}
expect_reject() {
  local label="$1" extra="$2" supplied="$3" required="$4" message="$5" before after
  verdict_base "$tmp/v.json" "$extra"; prior "$tmp/p.json" "$supplied" "$required"
  before="$(shasum -a 256 "$tmp/v.json")"
  if python3 "$BIND" --validate-audit-format --verdict "$tmp/v.json" \
      --prior-findings "$tmp/p.json" >/dev/null 2>"$tmp/err"; then
    fail "$label: accepted"
  fi
  assert_contains "$(cat "$tmp/err")" "$message" "$label diagnostic"
  after="$(shasum -a 256 "$tmp/v.json")"
  [[ "$before" == "$after" ]] || fail "$label: validator rewrote model output"
}

# First review (host supplied nothing): omitted or {} only.
expect_ok "first-round omitted" '{}' '[]' '[]'
expect_ok "first-round empty map" '{"findingsStatus":{}}' '[]' '[]'
expect_reject "first-round invented ids" '{"findingsStatus":{"F1":"resolved"}}' '[]' '[]' \
  "invented"
expect_reject "array shape" '{"findingsStatus":[]}' '[]' '[]' "must be a JSON object"
expect_reject "array of objects" '{"findingsStatus":[{"id":"f-a","status":"resolved"}]}' \
  '["f-a"]' '["f-a"]' "must be a JSON object"
expect_reject "null" '{"findingsStatus":null}' '[]' '[]' "must be a JSON object"
expect_reject "nested status object" '{"findingsStatus":{"f-a":{"status":"resolved"}}}' \
  '["f-a"]' '["f-a"]' 'must be exactly "resolved" or "still-open"'
expect_reject "unknown status word" '{"findingsStatus":{"f-a":"fixed"}}' \
  '["f-a"]' '["f-a"]' 'must be exactly "resolved" or "still-open"'
expect_reject "blank id" '{"findingsStatus":{" ":"resolved","f-a":"resolved"}}' \
  '["f-a"]' '["f-a"]' "blank finding id"
# Follow-up review: every required ID, only supplied IDs.
expect_ok "valid follow-up map" '{"findingsStatus":{"f-a":"resolved","f-b":"still-open"}}' \
  '["f-a","f-b","f-c"]' '["f-a","f-b"]'
expect_ok "resolved supplied id may be reported" \
  '{"findingsStatus":{"f-a":"resolved","f-b":"resolved","f-c":"resolved"}}' \
  '["f-a","f-b","f-c"]' '["f-a","f-b"]'
expect_reject "missing required id" '{"findingsStatus":{"f-a":"resolved"}}' \
  '["f-a","f-b"]' '["f-a","f-b"]' "omits required prior finding ids: f-b"
expect_reject "omitted map with prior findings" '{}' '["f-a"]' '["f-a"]' \
  "findingsStatus is missing"
expect_reject "unknown id" '{"findingsStatus":{"f-a":"resolved","f-zz":"resolved"}}' \
  '["f-a"]' '["f-a"]' "did not supply: f-zz"
# Acceptance consistency: a still-open prior finding must be carried forward.
still_open_text="FINDING_ALPHA: replace the seeded implementation"
still_open_id="$(python3 -c 'import hashlib,sys; t=" ".join(sys.argv[1].replace("`","").lower().split()); print("f-"+hashlib.sha256(t.encode()).hexdigest()[:12])' "$still_open_text")"
expect_reject "accepted drops still-open" \
  "{\"verdict\":\"accepted\",\"findingsStatus\":{\"$still_open_id\":\"still-open\"}}" \
  "[\"$still_open_id\"]" "[\"$still_open_id\"]" "without carrying them"
expect_ok "accepted carries still-open as backlog" \
  "{\"verdict\":\"accepted\",\"findings\":[\"$still_open_text\"],\"classifiedFindings\":[{\"id\":\"p2\",\"severity\":\"P2\",\"summary\":\"$still_open_text\"}],\"findingsStatus\":{\"$still_open_id\":\"still-open\"}}" \
  "[\"$still_open_id\"]" "[\"$still_open_id\"]"
echo "ok: findingsStatus shape, permitted ids and coverage are host-validated"

# P0/P1 support (schema allOf/if/then, mirrored on the host).
expect_reject "P0 missing requirement" \
  '{"classifiedFindings":[{"id":"a","severity":"P0","summary":"s","trigger":"t","impact":"i"}]}' \
  '[]' '[]' "requires nonblank requirement"
expect_reject "P1 blank trigger" \
  '{"classifiedFindings":[{"id":"a","severity":"P1","summary":"s","trigger":"  ","impact":"i","requirement":"r"}]}' \
  '[]' '[]' "requires nonblank trigger"
expect_ok "supported P1" \
  '{"classifiedFindings":[{"id":"a","severity":"P1","summary":"s","trigger":"t","impact":"i","requirement":"r"}]}' \
  '[]' '[]'
expect_ok "P2 without support" '{"classifiedFindings":[{"id":"a","severity":"P2","summary":"s"}]}' \
  '[]' '[]'
# The generic checker's result is irrelevant to the decision: the host mirror
# is what rejects, so record which way the checker goes rather than trusting it.
verdict_base "$tmp/p0.json" \
  '{"classifiedFindings":[{"id":"a","severity":"P0","summary":"s","trigger":"t","impact":"i"}]}'
if SINGULAR_ROOT="$tmp" SINGULAR_STATE_DIR="$tmp/state" \
    SINGULAR_AUDIT_SCHEMA="$ENGINE_HOME/schemas/audit-verdict.v1.schema.json" \
    bash -c 'source "$1" >/dev/null; singular_validate_audit_verdict "$2"' \
    fixture "$ENGINE_HOME/engine/lib.sh" "$tmp/p0.json" >/dev/null 2>&1; then
  echo "note: generic schema checker ignores allOf/if/then; host mirror enforces P0/P1 support"
fi
prior "$tmp/none.json" '[]' '[]'
python3 "$BIND" --validate-audit-format --verdict "$tmp/p0.json" \
  --prior-findings "$tmp/none.json" >/dev/null 2>&1 \
  && fail "host mirror accepted unsupported P0"
printf '{"suppliedIds":["f-a"],"requiredIds":["f-b"]}\n' >"$tmp/bad-prior.json"
python3 "$BIND" --validate-audit-format --verdict "$tmp/v.json" \
  --prior-findings "$tmp/bad-prior.json" >/dev/null 2>&1 \
  && fail "inconsistent host prior-finding record was not refused"
echo "ok: P0/P1 support is enforced by the host mirror"

# ---- 3. Renderers -----------------------------------------------------------
fragment="$(SINGULAR_ROOT="$tmp" SINGULAR_STATE_DIR="$tmp/state" bash -c \
  'source "$1" >/dev/null; singular_audit_findings_status_contract' fixture "$ENGINE_HOME/engine/lib.sh")"
python3 - "$fragment" <<'PY' || fail "shared fragment is not the protocol 4.2 text"
import sys
expected = '''findingsStatus describes only findings supplied by the host from an earlier
review. It is a JSON object mapping finding IDs to the exact string
"resolved" or "still-open".

Correct: "findingsStatus": {"F1": "resolved", "F2": "still-open"}
Incorrect: "findingsStatus": []
Incorrect: "findingsStatus": [{"id": "F1", "status": "resolved"}]
Incorrect: "findingsStatus": {"F1": {"status": "resolved"}}

When the host supplied no prior findings, OMIT findingsStatus.
Do not invent prior finding IDs.

When prior findings were supplied, report the required prior IDs using the
object shape above. Missing or unknown IDs do not establish resolution.

P0/P1 findings require nonblank trigger, impact, and requirement.
Missing support never downgrades a finding or authorizes acceptance.

Use accepted when there are no blocking findings, including reviews with
only P2/P3 backlog items. Do not emit reviewPolicy; it is host-owned.'''
assert sys.argv[1] == expected, sys.argv[1]
PY
count_fragment() {
  python3 - "$1" "$fragment" <<'PY'
import sys
print(open(sys.argv[1], encoding="utf-8").read().count(sys.argv[2]))
PY
}

# 3a. Initial prompt from the real driver (dry run, v1 contract).
repo="$tmp/driver"
mkdir -p "$repo/docs/orchestration/tasks" "$repo/docs/orchestration/prompts" "$repo/.singular-state"
cp "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md" "$ENGINE_HOME/templates/prompts/auditor.md" \
  "$repo/docs/orchestration/prompts/"
printf '{"schemaVersion":"v2","targetBranch":"target","gateCommand":"true"}\n' \
  >"$repo/singular.config.json"
cat >"$repo/docs/orchestration/tasks/TASK-0001.md" <<'TASK'
# TASK-0001: Findings status prompt

Status: ready
Area: widget
Target branch: `target`
Worker branch: `agent/widget/TASK-0001`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Render prompts.

## Scope

Owned files:

- `widget.txt`

## Acceptance Criteria

- Prompts render.
TASK
git -C "$repo" init -q
git -C "$repo" checkout -q -b target
git -C "$repo" add .
git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q -m init
SINGULAR_ROOT="$repo" SINGULAR_ORCH_DIR="$repo/docs/orchestration" \
  SINGULAR_TASKS_DIR="$repo/docs/orchestration/tasks" SINGULAR_STATE_DIR="$repo/.singular-state" \
  SINGULAR_CONFIG_FILE=/dev/null SINGULAR_LOCAL_CONFIG_FILE=/dev/null \
  SINGULAR_TARGET_BRANCH=target SINGULAR_WORKTREES_DIR="$repo/.worktrees" \
  bash "$ENGINE_HOME/engine/l1-drive.sh" TASK-0001 --dry-run >"$tmp/dry.log" 2>&1 \
  || { cat "$tmp/dry.log" >&2; fail "driver dry run failed"; }
run_dir="$(find "$repo/.singular-state/runs" -mindepth 1 -maxdepth 1 -type d | head -1)"
initial="$run_dir/auditor-prompt.md"
assert_contains "$(cat "$initial")" "audit-verdict.v1.schema.json" "initial prompt uses v1 contract"
[[ "$(count_fragment "$initial")" == 1 ]] || fail "initial prompt must carry the fragment once"
echo "ok: initial auditor prompt carries the shared fragment once"

# 3b. Re-audit renderer: first round is decided by the supplied set.
rd="$tmp/reaudit"; wt="$tmp/wt"
mkdir -p "$rd" "$wt"
git -C "$wt" init -q
printf 'a\n' >"$wt/f"; git -C "$wt" add f; git -C "$wt" -c user.name=t -c user.email=t@e commit -qm one
s1="$(git -C "$wt" rev-parse HEAD)"
printf 'b\n' >"$wt/f"; git -C "$wt" -c user.name=t -c user.email=t@e commit -qam two
s2="$(git -C "$wt" rev-parse HEAD)"
render() {
  SINGULAR_ROOT="$tmp" SINGULAR_STATE_DIR="$tmp/state" bash -c \
    'source "$1" >/dev/null; singular_render_reaudit_prompt "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"' \
    fixture "$ENGINE_HOME/engine/lib.sh" "$1" "$2" "$rd" "$3" "$s1" "$s2" "$wt" "$4"
}
# Attempt 1: plain copy, byte-identical, no prior findings recorded.
render "$rd/a1.md" "$initial" 1 "$rd/prior-1.json"
cmp -s "$initial" "$rd/a1.md" || fail "attempt-1 re-audit render is not byte-identical"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["suppliedIds"]==[] and d["requiredIds"]==[], d' \
  "$rd/prior-1.json" || fail "attempt-1 prior record not empty"
# Attempt 2 without a reviewer capsule (e.g. a new run continuing old history):
# still a first review of the host-held set, whatever the attempt number.
render "$rd/a2-nocap.md" "$initial" 2 "$rd/prior-2-nocap.json"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["suppliedIds"]==[], d' \
  "$rd/prior-2-nocap.json" || fail "capsule-less attempt-2 prior record not empty"
# Attempt 2 with prior findings: one open, one resolved.
printf '{"auditedHeadSha":"%s"}\n' "$s1" >"$rd/reviewer-capsule.json"
cat >"$rd/findings-status.json" <<'JSON'
{"schema":"singular.orchestration.findings-ledger.v0","findings":[
 {"id":"f-open1","text":"open finding","status":"open"},
 {"id":"f-done1","text":"resolved finding","status":"resolved"}]}
JSON
render "$rd/a2.md" "$initial" 2 "$rd/prior-2.json"
body="$(cat "$rd/a2.md")"
[[ "$(count_fragment "$rd/a2.md")" == 1 ]] || fail "re-audit over a fragment-bearing base duplicated it"
assert_contains "$body" "MUST report every one of these IDs: f-open1." "re-audit required ids"
assert_contains "$body" "MAY also be reported: f-done1" "re-audit permitted resolved ids"
python3 - "$rd/prior-2.json" <<'PY' || fail "attempt-2 prior record"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["suppliedIds"] == ["f-open1", "f-done1"], d
assert d["requiredIds"] == ["f-open1"], d
PY
# A base without the fragment (legacy/consumer template) still gets it once.
printf '# legacy audit base\n' >"$rd/legacy-base.md"
render "$rd/a2-legacy.md" "$rd/legacy-base.md" 2 "$rd/prior-2-legacy.json"
[[ "$(count_fragment "$rd/a2-legacy.md")" == 1 ]] || fail "re-audit renderer did not supply the fragment"
# No supplied findings at all: the prompt tells the auditor to omit the map.
printf '{"findings":[]}\n' >"$rd/findings-status.json"
render "$rd/a2-none.md" "$initial" 2 "$rd/prior-2-none.json"
assert_contains "$(cat "$rd/a2-none.md")" "supplied no prior findings for this review: OMIT findingsStatus" \
  "empty prior set instructs omission"
echo "ok: re-audit renderer records the host prior-finding set and decides first round from it"

# 3c. Validation-feedback repair prompt (extracted from the driver).
repair() {
  bash -c '
    source "$1" >/dev/null
    source <(sed -n "/^render_audit_repair_prompt() {$/,/^}$/p" "$2")
    render_audit_repair_prompt "$3" "$4" "$5" "$6" v1
  ' fixture "$ENGINE_HOME/engine/lib.sh" "$ENGINE_HOME/engine/l1-drive.sh" "$@"
}
printf 'findingsStatus must be a JSON object\n' >"$tmp/err.txt"
printf '{"findingsStatus":[]}\n' >"$tmp/invalid.json"
SINGULAR_ROOT="$tmp" SINGULAR_STATE_DIR="$tmp/state" \
  repair "$rd/legacy-base.md" "$tmp/repair-legacy.md" "$tmp/err.txt" "$tmp/invalid.json"
SINGULAR_ROOT="$tmp" SINGULAR_STATE_DIR="$tmp/state" \
  repair "$initial" "$tmp/repair-initial.md" "$tmp/err.txt" "$tmp/invalid.json"
[[ "$(count_fragment "$tmp/repair-legacy.md")" == 1 ]] || fail "repair prompt did not supply the fragment"
[[ "$(count_fragment "$tmp/repair-initial.md")" == 1 ]] || fail "repair prompt duplicated the fragment"
repair_body="$(cat "$tmp/repair-legacy.md")"
assert_contains "$repair_body" "except optional
findingsStatus and classifiedFindings." "repair permitted members"
assert_not_contains "$repair_body" "classifiedFindings, and reviewPolicy" \
  "repair prompt no longer permits reviewPolicy"
assert_contains "$repair_body" "do not drop or demote a
finding the invalid response reported as P0 or P1" "repair is not an appeal"
echo "ok: repair prompt carries the fragment once and no longer permits reviewPolicy"

# 3d. Consumer template mirrors stay aligned and no longer promise a downgrade.
cmp -s "$ENGINE_HOME/templates/prompts/auditor.md" "$ENGINE_HOME/docs/orchestration/prompts/auditor.md" \
  || fail "auditor template mirrors diverged"
template="$(cat "$ENGINE_HOME/templates/prompts/auditor.md")"
assert_not_contains "$template" "is downgraded by the host" "template downgrade promise removed"
assert_contains "$template" "Missing support never downgrades a finding" "template support rule"
echo "PASS: test-audit-findings-status"
