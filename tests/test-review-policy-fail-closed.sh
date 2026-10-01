#!/usr/bin/env bash
# Fail-closed review classification (0.23.4 item 8; loop-economics protocol 5.1).
# Seeded with the three reproduced acceptance counterexamples, copied verbatim
# from the consultation bundle (singular-loop-economics-repro/*.json). Before
# 0.23.4 `review_policy.py record --apply` rewrote each of them to
# verdict=accepted, and l1-drive.sh gates acceptance on that rewritten field.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-review-policy-fail-closed.sh requires bash >= 4" >&2
  exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${SINGULAR_TEST_PYTHON:-$(command -v python3 2>/dev/null || true)}"
[[ -n "$PYTHON_BIN" && -x "$PYTHON_BIN" ]] || { echo "missing python3" >&2; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2', got '$1'"; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/singular-review-fail-closed.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
STATE="$tmp/state"
CONFIG="$tmp/singular.config.json"
mkdir -p "$STATE"
printf '%s\n' '{"schemaVersion":"v2","targetBranch":"target"}' >"$CONFIG"

rp() {
  "$PYTHON_BIN" "$ENGINE_HOME/engine/review_policy.py" \
    --config "$CONFIG" --state-dir "$STATE" "$@"
}

# record_case <verdict-file> [extra record args...]: record under a fresh
# logical change (no budget interaction) and print the result JSON. The counter
# lives in a file because callers run this inside command substitutions.
record_case() {
  local file="$1" lc_seq
  shift
  lc_seq=$(( $(cat "$tmp/lc-seq" 2>/dev/null || echo 0) + 1 ))
  echo "$lc_seq" >"$tmp/lc-seq"
  rp record --logical-change "LC-$lc_seq" --task TASK-0001 --run "RUN-$lc_seq" \
    --attempt 1 --verdict "$file" --head "head$lc_seq" "$@"
}

field() {
  "$PYTHON_BIN" -c 'import json,sys
d=json.loads(sys.stdin.read())
out=[]
for key in sys.argv[1:]:
    v=d.get(key)
    out.append(",".join(map(str,v)) if isinstance(v,list) else str(v))
print(" ".join(out))' "$@"
}

file_verdict() {
  "$PYTHON_BIN" -c 'import json,sys; print(json.load(open(sys.argv[1]))["verdict"])' "$1"
}

# --- the three reproduced counterexamples, verbatim --------------------------
cat >"$tmp/missing_p0_prose.json" <<'JSON'
{
  "schema": "singular.orchestration.audit-verdict.v1",
  "taskId": "TASK-0001",
  "runId": "RUN-REPRO",
  "branch": "agent/repro",
  "verdict": "needs-fix",
  "evidenceReviewed": [
    "host-report.json"
  ],
  "verificationResults": [
    {
      "status": "passed",
      "command": "bash gate.sh",
      "evidenceRefs": [
        "host-report.json"
      ],
      "rationale": "Fixture host gate passed"
    }
  ],
  "commandsRun": [],
  "findings": [
    "Data loss"
  ],
  "requiredFixes": [
    "Data loss"
  ],
  "rationale": "Counterexample fixture",
  "classifiedFindings": [
    {
      "id": "F1",
      "severity": "P0",
      "summary": "Data loss",
      "trigger": "Write operation",
      "impact": "Stored data is lost"
    }
  ]
}
JSON
cat >"$tmp/accepted_with_p0.json" <<'JSON'
{
  "schema": "singular.orchestration.audit-verdict.v1",
  "taskId": "TASK-0001",
  "runId": "RUN-REPRO",
  "branch": "agent/repro",
  "verdict": "accepted",
  "evidenceReviewed": [
    "host-report.json"
  ],
  "verificationResults": [
    {
      "status": "passed",
      "command": "bash gate.sh",
      "evidenceRefs": [
        "host-report.json"
      ],
      "rationale": "Fixture host gate passed"
    }
  ],
  "commandsRun": [],
  "findings": [
    "Data loss"
  ],
  "requiredFixes": [],
  "rationale": "Counterexample fixture",
  "classifiedFindings": [
    {
      "id": "F1",
      "severity": "P0",
      "summary": "Data loss",
      "trigger": "Write operation",
      "impact": "Stored data is lost",
      "requirement": "Preserve data"
    }
  ]
}
JSON
cat >"$tmp/partial_classification.json" <<'JSON'
{
  "schema": "singular.orchestration.audit-verdict.v1",
  "taskId": "TASK-0001",
  "runId": "RUN-REPRO",
  "branch": "agent/repro",
  "verdict": "needs-fix",
  "evidenceReviewed": [
    "host-report.json"
  ],
  "verificationResults": [
    {
      "status": "passed",
      "command": "bash gate.sh",
      "evidenceRefs": [
        "host-report.json"
      ],
      "rationale": "Fixture host gate passed"
    }
  ],
  "commandsRun": [],
  "findings": [
    "Data loss",
    "Nit"
  ],
  "requiredFixes": [
    "Data loss"
  ],
  "rationale": "Counterexample fixture",
  "classifiedFindings": [
    {
      "id": "F2",
      "severity": "P3",
      "summary": "Nit"
    }
  ]
}
JSON

# Classification of each counterexample.
out="$(record_case "$tmp/missing_p0_prose.json")"
assert_eq "$(field originalVerdict effectiveVerdict blocking unsupported downgraded reason <<<"$out")" \
  "needs-fix needs-fix F1 F1  unsupported-blocking-claim" \
  "missing P0 prose keeps P0 and blocks (never downgraded)"

out="$(record_case "$tmp/accepted_with_p0.json")"
assert_eq "$(field originalVerdict effectiveVerdict blocking backlog reason <<<"$out")" \
  "accepted needs-fix F1  blocking-finding" \
  "accepted label with a supported P0 is inspected and blocks"

out="$(record_case "$tmp/partial_classification.json")"
assert_eq "$(field originalVerdict effectiveVerdict blocking backlog unclassifiedCount reason <<<"$out")" \
  "needs-fix needs-fix unclassified-1 F2 1 classification-incomplete" \
  "unclassified 'Data loss' finding blocks the P3-only classification"

# End to end: record --apply must not rewrite any counterexample to accepted.
for name in missing_p0_prose accepted_with_p0 partial_classification; do
  cp "$tmp/$name.json" "$tmp/$name.apply.json"
  record_case "$tmp/$name.apply.json" --apply >"$tmp/$name.apply.out"
  assert_eq "$(file_verdict "$tmp/$name.apply.json")" "needs-fix" \
    "$name: applied verdict file"
  assert_eq "$("$PYTHON_BIN" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["reviewPolicy"]["effectiveVerdict"])' "$tmp/$name.apply.json")" \
    "needs-fix" "$name: reviewPolicy stamp"
  SINGULAR_ROOT="$tmp" SINGULAR_STATE_DIR="$STATE" SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
  SINGULAR_AUDIT_SCHEMA="$ENGINE_HOME/schemas/audit-verdict.v1.schema.json" \
    bash -c "source '$ENGINE_HOME/engine/lib.sh'; singular_validate_audit_verdict '$tmp/$name.apply.json' TASK-0001 RUN-REPRO" \
    || fail "$name: applied verdict failed schema validation"
done
assert_eq "$(file_verdict "$tmp/accepted_with_p0.apply.json.pre-policy.json")" "accepted" \
  "accepted_with_p0 keeps the auditor's label in the pre-policy copy"
echo "ok: three reproduced counterexamples never become accepted"

# --- fixture builder for the remaining cases ---------------------------------
# write_verdict <path> <verdict> <findings-json> <fixes-json> <classified-json|ABSENT>
write_verdict() {
  "$PYTHON_BIN" - "$@" <<'PY'
import json, sys
path, verdict, findings, fixes, classified = sys.argv[1:6]
record = {
    "schema": "singular.orchestration.audit-verdict.v1",
    "taskId": "TASK-0001",
    "runId": "RUN-1",
    "branch": "agent/x/TASK-0001",
    "verdict": verdict,
    "evidenceReviewed": ["host-report.json"],
    "verificationResults": [{
        "status": "passed", "command": "true",
        "evidenceRefs": ["host-report.json"], "rationale": "host passed",
    }],
    "commandsRun": [],
    "findings": json.loads(findings),
    "requiredFixes": json.loads(fixes),
    "rationale": "fixture",
}
if classified != "ABSENT":
    record["classifiedFindings"] = json.loads(classified)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(record, handle, indent=2)
    handle.write("\n")
PY
}

P1_OK='{"id":"F1","severity":"P1","summary":"broken contract","trigger":"t","impact":"i","requirement":"r"}'

# --- conflicting duplicate ids -----------------------------------------------
write_verdict "$tmp/dup-conflict.json" needs-fix '["F1: broken contract"]' '[]' \
  "[$P1_OK,{\"id\":\"F1\",\"severity\":\"P3\",\"summary\":\"broken contract\"}]"
out="$(record_case "$tmp/dup-conflict.json")"
assert_eq "$(field effectiveVerdict blocking unresolved reason <<<"$out")" \
  "needs-fix F1 F1 classification-conflict" "conflicting duplicate id is unresolved"

write_verdict "$tmp/dup-conflict-acc.json" accepted '["F1: nit"]' '[]' \
  '[{"id":"F1","severity":"P3","summary":"nit"},{"id":"F1","severity":"P2","summary":"nit"}]'
out="$(record_case "$tmp/dup-conflict-acc.json")"
assert_eq "$(field effectiveVerdict unresolved <<<"$out")" "needs-fix F1" \
  "conflicting duplicate id blocks an accepted label too"

write_verdict "$tmp/dup-same.json" needs-fix '["F1: nit"]' '[]' \
  '[{"id":"F1","severity":"P3","summary":"nit"},{"id":"F1","severity":"P3","summary":"nit"}]'
out="$(record_case "$tmp/dup-same.json")"
assert_eq "$(field effectiveVerdict backlog unresolved <<<"$out")" "accepted F1 " \
  "an identical duplicate collapses to one item"
echo "ok: conflicting ids block"

# --- malformed classified entries --------------------------------------------
for bad in \
  '[{"id":"F1","severity":"p3","summary":"nit"}]' \
  '[{"id":"F1","severity":"P3","summary":"   "}]' \
  '[{"id":"","severity":"P3","summary":"nit"}]' \
  '[{"id":"F1","severity":"P3","summary":"nit","trigger":7}]' \
  '["F1"]' \
  '{"id":"F1","severity":"P3","summary":"nit"}'; do
  for label in needs-fix accepted; do
    write_verdict "$tmp/malformed.json" "$label" '["nit"]' '[]' "$bad"
    out="$(record_case "$tmp/malformed.json")"
    assert_eq "$(field effectiveVerdict reason <<<"$out")" "needs-fix classification-malformed" \
      "malformed classification $bad ($label) blocks"
  done
done
# A malformed entry beside a valid P3 still blocks.
write_verdict "$tmp/malformed-mixed.json" needs-fix '["nit"]' '[]' \
  '[{"id":"F1","severity":"P3","summary":"nit"},{"severity":"P3","summary":"lost id"}]'
out="$(record_case "$tmp/malformed-mixed.json")"
assert_eq "$(field effectiveVerdict blocking backlog <<<"$out")" "needs-fix malformed-2 F1" \
  "malformed entry next to a valid one is unresolved"
echo "ok: malformed classified entries block"

# --- accepted with unclassified / uncovered findings -------------------------
write_verdict "$tmp/acc-uncovered.json" accepted '["F1 (P3): nit","Data loss on write"]' '[]' \
  '[{"id":"F1","severity":"P3","summary":"style nit"}]'
out="$(record_case "$tmp/acc-uncovered.json")"
assert_eq "$(field effectiveVerdict blocking backlog unclassifiedCount reason <<<"$out")" \
  "needs-fix unclassified-1 F1 1 classification-incomplete" \
  "accepted with an uncovered finding is not accepted"

write_verdict "$tmp/acc-unclassified.json" accepted '["Data loss on write"]' '[]' ABSENT
out="$(record_case "$tmp/acc-unclassified.json")"
assert_eq "$(field effectiveVerdict unclassifiedCount reason <<<"$out")" \
  "needs-fix 1 classification-missing" "accepted v1 with no classification is not accepted"

write_verdict "$tmp/acc-fixes.json" accepted '[]' '["must fix the parser"]' \
  '[{"id":"F1","severity":"P3","summary":"nit"}]'
out="$(record_case "$tmp/acc-fixes.json")"
assert_eq "$(field effectiveVerdict blocking <<<"$out")" "needs-fix unclassified-1" \
  "requiredFixes text is coverage-checked too"

write_verdict "$tmp/acc-covered.json" accepted '["F1 (P3): style nit in parser.py","F2: rename helper"]' '[]' \
  '[{"id":"F1","severity":"P3","summary":"style nit"},{"id":"F2","severity":"P2","summary":"helper name"}]'
out="$(record_case "$tmp/acc-covered.json")"
assert_eq "$(field effectiveVerdict applied backlog blocking <<<"$out")" "accepted False F1,F2 " \
  "accepted with every finding covered by explicit ids stays accepted"

write_verdict "$tmp/acc-empty.json" accepted '[]' '[]' ABSENT
out="$(record_case "$tmp/acc-empty.json")"
assert_eq "$(field effectiveVerdict applied <<<"$out")" "accepted False" \
  "accepted with no findings stays accepted"

# Exact coverage only: an id must be a whole token followed by a delimiter.
write_verdict "$tmp/acc-prefix.json" accepted '["F10: data loss","F1x: nit"]' '[]' \
  '[{"id":"F1","severity":"P3","summary":"nit"}]'
out="$(record_case "$tmp/acc-prefix.json")"
assert_eq "$(field effectiveVerdict unclassifiedCount <<<"$out")" "needs-fix 2" \
  "an id prefix inside another token does not cover a finding"

write_verdict "$tmp/acc-tag.json" accepted '["F1 (P0): data loss"]' '[]' \
  '[{"id":"F1","severity":"P3","summary":"nit"}]'
out="$(record_case "$tmp/acc-tag.json")"
assert_eq "$(field effectiveVerdict reason <<<"$out")" "needs-fix classification-conflict" \
  "a severity tag that disagrees with the classified severity blocks"
echo "ok: accepted verdicts are inspected; coverage is exact"

# --- preserved: fully classified P2/P3-only needs-fix is accepted-with-backlog -
write_verdict "$tmp/p2-only.json" needs-fix '["style leftover","dead comment"]' '["style leftover"]' \
  '[{"id":"f-style","severity":"P2","summary":"style leftover"},{"id":"f-dead","severity":"P3","summary":"dead comment"}]'
out="$(record_case "$tmp/p2-only.json" --apply)"
assert_eq "$(field originalVerdict effectiveVerdict applied backlog blocking <<<"$out")" \
  "needs-fix accepted True f-style,f-dead " "P2/P3-only needs-fix accepted with backlog"
assert_eq "$(file_verdict "$tmp/p2-only.json")" "accepted" "P2-only applied verdict"

write_verdict "$tmp/p2-ids.json" needs-fix '["AF-1 (P2): gate log is coarse","AF-2 - vacuous assertion"]' '[]' \
  '[{"id":"AF-1","severity":"P2","summary":"coarse gate evidence"},{"id":"AF-2","severity":"P3","summary":"vacuous assertion"}]'
out="$(record_case "$tmp/p2-ids.json")"
assert_eq "$(field effectiveVerdict backlog <<<"$out")" "accepted AF-1,AF-2" \
  "P2-only accepted when findings reference explicit ids"

# The preserved path never applies when anything was dropped or is blocking.
write_verdict "$tmp/p2-plus-p1.json" needs-fix '["style leftover","broken contract"]' '[]' \
  "[{\"id\":\"f-style\",\"severity\":\"P2\",\"summary\":\"style leftover\"},$P1_OK]"
out="$(record_case "$tmp/p2-plus-p1.json")"
assert_eq "$(field effectiveVerdict blocking backlog <<<"$out")" "needs-fix F1 f-style" \
  "P2 plus a supported P1 stays needs-fix"
echo "ok: P2-only acceptance preserved"

# --- verdict labels other than accepted/needs-fix are never upgraded ---------
for label in blocked needs-human; do
  write_verdict "$tmp/label.json" "$label" '["nit"]' '[]' '[{"id":"F1","severity":"P3","summary":"nit"}]'
  out="$(record_case "$tmp/label.json")"
  assert_eq "$(field effectiveVerdict <<<"$out")" "$label" "$label stays $label"
done

# --- policy knobs cannot open the holes --------------------------------------
write_verdict "$tmp/nf-unclassified.json" needs-fix '["raw finding"]' '[]' ABSENT
out="$(SINGULAR_REVIEW_REQUIRE_CLASSIFICATION=0 record_case "$tmp/nf-unclassified.json")"
assert_eq "$(field effectiveVerdict applied <<<"$out")" "needs-fix False" \
  "requireClassification=0 never upgrades an unclassified needs-fix"
out="$(SINGULAR_REVIEW_REQUIRE_CLASSIFICATION=0 record_case "$tmp/partial_classification.json")"
assert_eq "$(field effectiveVerdict <<<"$out")" "needs-fix" \
  "requireClassification=0 never upgrades a partially classified needs-fix"
out="$(SINGULAR_REVIEW_REQUIRE_CLASSIFICATION=0 record_case "$tmp/missing_p0_prose.json")"
assert_eq "$(field effectiveVerdict <<<"$out")" "needs-fix" \
  "requireClassification=0 keeps an unsupported P0 blocking"
out="$(SINGULAR_REVIEW_REQUIRE_CLASSIFICATION=0 record_case "$tmp/accepted_with_p0.json")"
assert_eq "$(field effectiveVerdict <<<"$out")" "needs-fix" \
  "requireClassification=0 still inspects an accepted label"
out="$(SINGULAR_REVIEW_REQUIRE_CLASSIFICATION=0 record_case "$tmp/acc-unclassified.json")"
assert_eq "$(field effectiveVerdict <<<"$out")" "accepted" \
  "requireClassification=0 lets an unclassified accepted label stand"
out="$(SINGULAR_REVIEW_BLOCKING_SEVERITIES=P0,P1,P2 record_case "$tmp/p2-only.json.pre-policy.json")"
assert_eq "$(field effectiveVerdict blocking <<<"$out")" "needs-fix f-style" \
  "a stricter blocking set keeps P2 blocking"
rc=0
SINGULAR_REVIEW_BLOCKING_SEVERITIES=P0 record_case "$tmp/missing_p0_prose.json" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "2" "a blocking set without P1 is refused"
echo "ok: requireClassification/blockingSeverities cannot weaken the floor"

echo "PASS: test-review-policy-fail-closed"
