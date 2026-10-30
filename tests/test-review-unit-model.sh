#!/usr/bin/env bash
# Review unit model (0.23.7). Synthetic sibling-task and replacement-task cases:
#   a. two sibling tasks of one DAG node: the accepted round of one closed the
#      node-keyed logical change and the other, gate green, was refused;
#   b. a planner-issued successor (`Supersedes:`) inherited an exhausted budget
#      and was refused before any product work;
#   c. a recorded round whose outcome was infrastructure still counted.
# The unit is the supersession chain keyed by its root task; a supersession
# extends the shared budget by a fixed, capped amount; a voided round does not
# count. Old node-keyed ledgers stay readable. No provider is launched.
set -euo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${SINGULAR_TEST_PYTHON:-$(command -v python3 2>/dev/null || true)}"
[[ -n "$PYTHON_BIN" && -x "$PYTHON_BIN" ]] || { echo "missing python3" >&2; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2', got '$1'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/singular-review-unit.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
STATE="$tmp/state"
TASKS="$tmp/tasks"
CONFIG="$tmp/singular.config.json"
LEDGER="$STATE/review-policy/ledger.json"
mkdir -p "$STATE" "$TASKS/superseded" "$tmp/evidence"
printf '%s\n' '{"schemaVersion":"v2","targetBranch":"target"}' >"$CONFIG"
printf 'authority evidence\n' >"$tmp/evidence/note.txt"
while IFS= read -r name; do unset "$name"; done < <(compgen -e | grep '^SINGULAR_REVIEW_' || true)
export SINGULAR_REVIEW_MAX_ROUNDS=2

rp() {
  "$PYTHON_BIN" "$ENGINE_HOME/engine/review_policy.py" \
    --config "$CONFIG" --state-dir "$STATE" "$@"
}
field() {
  "$PYTHON_BIN" -c 'import json,sys
d=json.loads(sys.stdin.read())
out=[]
for key in sys.argv[1:]:
    v=d
    for part in key.split("."):
        v=v.get(part) if isinstance(v,dict) else None
    out.append(",".join(map(str,v)) if isinstance(v,list) else str(v))
print(" ".join(out))' "$@"
}
entry() {
  "$PYTHON_BIN" -c 'import json,sys
d=json.load(open(sys.argv[1]))["logicalChanges"][sys.argv[2]]
print(eval(sys.argv[3], {"e": d, "len": len}))' "$LEDGER" "$@"
}
# task <id> <node> [supersedes] [subdir]
task() {
  local dir="$TASKS${4:+/$4}"
  {
    printf '# %s: fixture\n\nStatus: ready\nArea: %s\nDAG node: %s\n' "$1" "$2" "$2"
    [[ -z "${3:-}" ]] || printf 'Supersedes: %s\n' "$3"
    printf '\n## Objective\n\nSupersedes: TASK-9999 in prose is not a header.\n'
  } >"$dir/$1.md"
}
write_verdict() {
  "$PYTHON_BIN" - "$@" <<'PY'
import json, sys
path, verdict = sys.argv[1:3]
classified = json.loads(sys.argv[3]) if len(sys.argv) > 3 else []
findings = [item["summary"] for item in classified]
record = {
    "schema": "singular.orchestration.audit-verdict.v1",
    "taskId": "TASK-0001", "runId": "RUN-1", "branch": "agent/x/TASK-0001",
    "verdict": verdict, "evidenceReviewed": ["host-report.json"],
    "verificationResults": [{"status": "passed", "command": "true",
                             "evidenceRefs": ["host-report.json"], "rationale": "ok"}],
    "commandsRun": [], "findings": findings, "requiredFixes": list(findings),
    "rationale": "fixture",
}
if classified:
    record["classifiedFindings"] = classified
json.dump(record, open(path, "w", encoding="utf-8"), indent=2)
PY
}
BLOCKER='[{"id":"F1","severity":"P1","summary":"broken contract","trigger":"t","impact":"i","requirement":"r"}]'
write_verdict "$tmp/needs-fix.json" needs-fix "$BLOCKER"
write_verdict "$tmp/accepted.json" accepted

unit() { rp resolve --task "$1" --dag-node "$2" --tasks-dir "$TASKS"; }
# round <task> <node> <run> <attempt> <verdict-file>: what the L1 driver does.
round() {
  local lc
  lc="$(unit "$1" "$2" | field logicalChange)"
  rp record --logical-change "$lc" --task "$1" --run "$3" --attempt "$4" \
    --verdict "$5" --head "head-$3-$4"
}
admit() {
  local lc
  lc="$(unit "$1" "$2" | field logicalChange)"
  rp check --logical-change "$lc" --task "$1"
}

# --- a. sibling tasks of one node -------------------------------------------
task TASK-0021 fixture-widget
task TASK-0022 fixture-widget
assert_eq "$(unit TASK-0021 fixture-widget | field logicalChange unit changed)" "TASK-0021 task False" \
  "a task with no predecessor is its own unit"
[[ ! -e "$LEDGER" ]] || fail "resolving an own-unit task must not create ledger state"
out="$(round TASK-0022 fixture-widget RUN-22 1 "$tmp/accepted.json")"
assert_eq "$(field logicalChange effectiveVerdict status <<<"$out")" "TASK-0022 accepted accepted" \
  "sibling TASK-0022 accepted in its own unit"
out="$(admit TASK-0021 fixture-widget)" || fail "sibling TASK-0021 refused after TASK-0022 was accepted: $out"
assert_eq "$(field allowed closed used allowedRounds <<<"$out")" "True False 0 2" \
  "the accepted sibling neither closes nor charges TASK-0021"
out="$(round TASK-0021 fixture-widget RUN-21 1 "$tmp/accepted.json")"
assert_eq "$(field logicalChange effectiveVerdict <<<"$out")" "TASK-0021 accepted" "sibling TASK-0021 accepted"
# Each unit is still closed by its own acceptance.
rc=0; out="$(admit TASK-0022 fixture-widget)" || rc=$?
assert_eq "$rc" "4" "an accepted unit stays closed"
assert_eq "$(field closed <<<"$out")" "True" "closed flag"
echo "ok: sibling tasks of one DAG node have separate review series"

# --- b. supersession chain: one budget, bounded extension -------------------
task TASK-0025 fixture-plan
round TASK-0025 fixture-plan RUN-25 1 "$tmp/needs-fix.json" >/dev/null
round TASK-0025 fixture-plan RUN-25 2 "$tmp/needs-fix.json" >/dev/null
rc=0; out="$(admit TASK-0025 fixture-plan)" || rc=$?
assert_eq "$rc $(field used allowedRounds <<<"$out")" "4 2 2" "TASK-0025 exhausts its two rounds"
mv "$TASKS/TASK-0025.md" "$TASKS/superseded/TASK-0025.md"
task TASK-0035 fixture-plan TASK-0025
out="$(unit TASK-0035 fixture-plan)"
assert_eq "$(field logicalChange unit chain supersessions changed <<<"$out")" \
  "TASK-0025 task TASK-0025,TASK-0035 1 True" "the successor joins its predecessor's unit"
out="$(admit TASK-0035 fixture-plan)" || fail "engine-issued successor refused: $out"
assert_eq "$(field allowed used allowedRounds supersessionExtension <<<"$out")" "True 2 3 1" \
  "the chain shares the budget, extended by one round for the supersession"
# Registering is idempotent: resolving again mints nothing.
unit TASK-0035 fixture-plan >/dev/null
unit TASK-0035 fixture-plan >/dev/null
assert_eq "$(entry TASK-0025 'len(e["supersessions"])')" "1" "one supersession registered once"
round TASK-0035 fixture-plan RUN-35 1 "$tmp/needs-fix.json" >/dev/null
rc=0; out="$(admit TASK-0035 fixture-plan)" || rc=$?
assert_eq "$rc $(field used allowedRounds <<<"$out")" "4 3 3" "the extension is one round, not a fresh budget"
# A second successor extends once more; a third is capped.
task TASK-0036 fixture-plan TASK-0035
out="$(admit TASK-0036 fixture-plan)" || fail "second successor refused: $out"
assert_eq "$(field used allowedRounds <<<"$out")" "3 4" "second supersession extends by one"
round TASK-0036 fixture-plan RUN-36 1 "$tmp/needs-fix.json" >/dev/null
task TASK-0037 fixture-plan TASK-0036
rc=0; out="$(admit TASK-0037 fixture-plan)" || rc=$?
assert_eq "$rc $(field used allowedRounds <<<"$out")" "4 4 4" \
  "supersession extensions are capped (maxSupersessionExtensions=2)"
assert_eq "$(entry TASK-0025 'e["chain"]')" "['TASK-0025', 'TASK-0035', 'TASK-0036', 'TASK-0037']" "chain recorded"
# grant still works on a chain unit, on top of the extension.
out="$(rp grant --logical-change TASK-0025 --rounds 1 --reason "operator exception" \
  --evidence "$tmp/evidence/note.txt" --authority operator)"
assert_eq "$(field used allowedRounds <<<"$out")" "4 5" "grant extends a chain unit"
out="$(round TASK-0037 fixture-plan RUN-37 1 "$tmp/accepted.json")"
assert_eq "$(field logicalChange effectiveVerdict <<<"$out")" "TASK-0025 accepted" "chain accepted on the granted round"
# reopen still works on a chain unit and starts from the base budget.
out="$(rp reopen --logical-change TASK-0025 --reason "authorized repair" \
  --evidence "$tmp/evidence/note.txt" --authority recovery)"
assert_eq "$(field reopened series used allowedRounds <<<"$out")" "True 2 0 2" "reopen opens a base-budget series"
# A header naming a task that was never published extends nothing; neither does prose.
task TASK-0050 solo TASK-7777
assert_eq "$(unit TASK-0050 solo | field logicalChange supersessions)" "TASK-0050 0" \
  "an unpublished predecessor is not a supersession"
# The knobs: extension size and cap.
task TASK-0060 knob
round TASK-0060 knob RUN-60 1 "$tmp/needs-fix.json" >/dev/null
round TASK-0060 knob RUN-60 2 "$tmp/needs-fix.json" >/dev/null
task TASK-0061 knob TASK-0060
rc=0; out="$(SINGULAR_REVIEW_MAX_SUPERSESSION_EXTENSIONS=0 admit TASK-0061 knob)" || rc=$?
assert_eq "$rc $(field used allowedRounds <<<"$out")" "4 2 2" "maxSupersessionExtensions=0 restores the strict cap"
out="$(SINGULAR_REVIEW_SUPERSESSION_EXTRA_ROUNDS=2 admit TASK-0061 knob)"
assert_eq "$(field used allowedRounds <<<"$out")" "2 4" "supersessionExtraRounds is honoured"
printf '%s\n' '{"schemaVersion":"v2","reviewPolicy":{"supersessionExtraRounds":-1}}' >"$tmp/bad.json"
rc=0; "$PYTHON_BIN" "$ENGINE_HOME/engine/review_policy.py" --config "$tmp/bad.json" effective >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "2" "an invalid supersession knob is a hard error"
echo "ok: a supersession chain shares one budget with a fixed, capped extension"

# --- c. an infrastructure outcome does not count ----------------------------
task TASK-0070 infra
lc="$(unit TASK-0070 infra | field logicalChange)"
out="$(rp reserve --logical-change "$lc" --task TASK-0070 --run RUN-70 --attempt 1 --head h1)"
op="$(field operationId <<<"$out")"
rp record --logical-change "$lc" --task TASK-0070 --run RUN-70 --attempt 1 --head h1 \
  --verdict "$tmp/needs-fix.json" --operation "$op" >/dev/null
assert_eq "$(admit TASK-0070 infra | field used)" "1" "a recorded round counts"
out="$(rp void --logical-change "$lc" --operation "$op" --reason "evidence writer failed")"
assert_eq "$(field voided idempotent used allowedRounds status <<<"$out")" "True False 0 2 open" \
  "a voided round is not charged"
assert_eq "$(rp void --logical-change "$lc" --operation "$op" --reason again | field voided idempotent)" \
  "True True" "void is idempotent"
assert_eq "$(entry TASK-0070 'len(e["rounds"]), e["rounds"][0]["voided"]["class"]')" \
  "(1, 'infrastructure')" "the voided round is kept for audit"
assert_eq "$(rp void --logical-change "$lc" --operation rop-none --reason x | field voided)" "False" \
  "void of an operation with no round is a no-op"
# A voided accepted round does not close the unit.
out="$(rp reserve --logical-change "$lc" --task TASK-0070 --run RUN-70 --attempt 2 --head h2)"
op2="$(field operationId <<<"$out")"
rp record --logical-change "$lc" --task TASK-0070 --run RUN-70 --attempt 2 --head h2 \
  --verdict "$tmp/accepted.json" --operation "$op2" >/dev/null
rp void --logical-change "$lc" --operation "$op2" --reason "host verification inconclusive" >/dev/null
out="$(admit TASK-0070 infra)" || fail "voided accepted round closed the unit: $out"
assert_eq "$(field closed used status <<<"$out")" "False 0 open" "voided acceptance neither closes nor counts"
# The driver voids on its infrastructure exits and emits an event.
grep -q 'l1_void_review_round "review policy could not record or apply the verdict"' "$ENGINE_HOME/engine/l1-drive.sh" \
  || fail "l1-drive does not void a round it could not apply"
grep -q 'l1_void_review_round "host verification was inconclusive infrastructure"' "$ENGINE_HOME/engine/l1-drive.sh" \
  || fail "l1-drive does not void a round on inconclusive host verification"
grep -q 'review_policy.py" resolve --task' "$ENGINE_HOME/engine/l1-drive.sh" \
  || fail "l1-drive does not resolve the review unit"
echo "ok: a round voided as infrastructure is kept and not counted"

# --- old ledgers stay readable ----------------------------------------------
# A node-keyed entry written by 0.23.6: TASK-0080 used one round on node `old`.
"$PYTHON_BIN" - "$LEDGER" <<'PY'
import json, sys
path = sys.argv[1]
d = json.load(open(path))
def row(n, task, verdict):
    return {"round": n, "kind": "initial" if n == 1 else "followup", "taskId": task,
            "runId": f"RUN-{task}", "attempt": n, "head": f"h{n}", "lane": "native",
            "originalVerdict": verdict, "effectiveVerdict": verdict, "series": 1,
            "seriesRound": n, "operationId": f"rop-{task}-{n}", "recordedAt": "2000-01-01T00:00:00Z"}
d["logicalChanges"]["old"] = {"status": "open", "exceptions": [], "rounds": [row(1, "TASK-0080", "needs-fix")]}
d["logicalChanges"]["oldsib"] = {"status": "accepted", "exceptions": [],
    "rounds": [row(1, "TASK-0090", "needs-fix"), row(2, "TASK-0091", "accepted")]}
json.dump(d, open(path, "w"), indent=2)
PY
task TASK-0080 old
assert_eq "$(unit TASK-0080 old | field logicalChange unit)" "old legacy-node" \
  "a task with rounds in a node-keyed entry stays on it"
assert_eq "$(admit TASK-0080 old | field used allowedRounds)" "1 2" "its used rounds are not reset by the upgrade"
task TASK-0081 old TASK-0080
out="$(unit TASK-0081 old)"
assert_eq "$(field logicalChange unit supersessions <<<"$out")" "old legacy-node 1" \
  "its successor shares the node-keyed entry"
assert_eq "$(admit TASK-0081 old | field used allowedRounds)" "1 3" "and gets the bounded extension"
task TASK-0082 old
assert_eq "$(unit TASK-0082 old | field logicalChange unit)" "TASK-0082 task" \
  "an unrelated task of that node gets its own unit"
# A node entry closed by a sibling does not bind the other chain (case a, after upgrade).
task TASK-0090 oldsib
out="$(admit TASK-0090 oldsib)" || fail "task refused by a sibling's legacy acceptance: $out"
assert_eq "$(field logicalChange closed <<<"$out")" "TASK-0090 False" \
  "a node entry closed by a sibling does not close this task"
rp show >/dev/null || fail "ledger unreadable after the mixed-model writes"
echo "ok: node-keyed ledgers from older engines stay readable and bounded"
echo "PASS: review unit model"
