#!/usr/bin/env bash
# Review-ledger integrity (0.23.4 item 7; loop-economics protocol 5.4):
# atomic reservation, idempotent completion, under-lock ceiling, explicit
# closure + reopen, series-bound grants, legacy migration, malformed ledgers.
set -euo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-review-ledger-admission.sh requires bash >= 4" >&2
  exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${SINGULAR_TEST_PYTHON:-$(command -v python3 2>/dev/null || true)}"
[[ -n "$PYTHON_BIN" && -x "$PYTHON_BIN" ]] || { echo "missing python3" >&2; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2', got '$1'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2'"; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/singular-review-ledger.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
STATE="$tmp/state"
CONFIG="$tmp/singular.config.json"
LEDGER="$STATE/review-policy/ledger.json"
mkdir -p "$STATE" "$tmp/evidence"
printf '%s\n' '{"schemaVersion":"v2","targetBranch":"target"}' >"$CONFIG"
printf 'authority evidence\n' >"$tmp/evidence/note.txt"
printf 'second authority evidence\n' >"$tmp/evidence/note2.txt"
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

sha() { shasum -a 256 "$1" | awk '{print $1}'; }

# write_verdict <path> <verdict> [classified-json]
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
write_verdict "$tmp/p2.json" needs-fix '[{"id":"F2","severity":"P2","summary":"style leftover"}]'

# rec <lc> <task> <run> <attempt> <verdict> [extra...]
rec() {
  local lc="$1" task="$2" run="$3" attempt="$4" verdict="$5"
  shift 5
  rp record --logical-change "$lc" --task "$task" --run "$run" --attempt "$attempt" \
    --verdict "$verdict" --head "head-$run-$attempt" "$@"
}
# res <lc> <task> <run> <attempt>
res() {
  rp reserve --logical-change "$1" --task "$2" --run "$3" --attempt "$4" --head "head-$3-$4"
}

# --- concurrent last-slot reservation: exactly one of two writers wins --------
for trial in 1 2 3 4 5; do
  lc="RACE-$trial"
  rec "$lc" TASK-A RUN-0 1 "$tmp/needs-fix.json" >/dev/null
  rc_a=0; rc_b=0
  res "$lc" TASK-A "RUN-A$trial" 1 >"$tmp/race-a.json" 2>/dev/null & pid_a=$!
  res "$lc" TASK-B "RUN-B$trial" 1 >"$tmp/race-b.json" 2>/dev/null & pid_b=$!
  wait "$pid_a" || rc_a=$?
  wait "$pid_b" || rc_b=$?
  assert_eq "$(printf '%s\n' "$rc_a" "$rc_b" | sort | tr '\n' ' ')" "0 4 " \
    "trial $trial: exactly one concurrent last-slot reservation wins"
  assert_eq "$(entry "$lc" 'sum(1 for op in e["operations"].values() if op["status"] == "reserved")')" "1" \
    "trial $trial: one reserved operation"
done
echo "ok: concurrent last-slot reserve admits exactly one"

# Auditor transport retries reuse one operation: re-reserving the same binding
# is idempotent and never takes a second slot.
out1="$(res RETRY TASK-A RUN-R 1)"
out2="$(res RETRY TASK-A RUN-R 1)"
assert_eq "$(field operationId <<<"$out1")" "$(field operationId <<<"$out2")" "same binding, same operation"
assert_eq "$(field idempotent pending used <<<"$out2")" "True 0 0" "retry reservation is idempotent"
assert_eq "$(entry RETRY 'len(e["operations"])')" "1" "one operation for retries"
# A new attempt by the same task supersedes its unfinished reservation.
res RETRY TASK-A RUN-R 2 >/dev/null
assert_eq "$(entry RETRY 'sorted(op["status"] for op in e["operations"].values())')" \
  "['abandoned', 'reserved']" "same-task reservation supersedes the stale one"
echo "ok: retries stay inside one review operation"

# --- duplicate completion is a no-op; conflicting replay is refused ----------
out="$(res DUP TASK-A RUN-D 1)"
op="$(field operationId <<<"$out")"
cp "$tmp/p2.json" "$tmp/dup.json"
out="$(rec DUP TASK-A RUN-D 1 "$tmp/dup.json" --operation "$op" --apply)"
assert_eq "$(field effectiveVerdict round idempotent appliedToVerdict <<<"$out")" "accepted 1 False True" \
  "first completion"
backlog_before="$(grep -c . "$STATE/review-policy/backlog.ndjson")"
rounds_before="$(entry DUP 'e["rounds"]')"
# Replay with the applied file, then with the raw (pre-policy) content.
out="$(rec DUP TASK-A RUN-D 1 "$tmp/dup.json" --operation "$op" --apply)"
assert_eq "$(field effectiveVerdict round idempotent appliedToVerdict <<<"$out")" "accepted 1 True True" \
  "replay of the applied verdict is a no-op"
cp "$tmp/dup.json.pre-policy.json" "$tmp/dup-raw.json"
out="$(rec DUP TASK-A RUN-D 1 "$tmp/dup-raw.json" --operation "$op")"
assert_eq "$(field round idempotent <<<"$out")" "1 True" "replay of the raw verdict is a no-op"
assert_eq "$(entry DUP 'e["rounds"]')" "$rounds_before" "no round added by replays"
assert_eq "$(grep -c . "$STATE/review-policy/backlog.ndjson")" "$backlog_before" "no backlog added by replays"

before="$(sha "$LEDGER")"
rc=0
rec DUP TASK-A RUN-D 1 "$tmp/needs-fix.json" --operation "$op" >/dev/null 2>"$tmp/conflict.err" || rc=$?
assert_eq "$rc" "5" "replay with different content is a conflict"
assert_contains "$(cat "$tmp/conflict.err")" "different verdict content" "conflict names the cause"
assert_eq "$(sha "$LEDGER")" "$before" "conflicting replay writes nothing"

out="$(res BIND TASK-A RUN-X 1)"
op_bind="$(field operationId <<<"$out")"
rc=0
rec BIND TASK-A RUN-OTHER 1 "$tmp/needs-fix.json" --operation "$op_bind" >/dev/null 2>"$tmp/bind.err" || rc=$?
assert_eq "$rc" "5" "completing an operation with a different binding is refused"
rc=0
rec BIND TASK-A RUN-X 1 "$tmp/needs-fix.json" --operation rop-unknown >/dev/null 2>/dev/null || rc=$?
assert_eq "$rc" "5" "unknown operation is refused"
rp release --logical-change BIND --operation "$op_bind" --reason "auditor infra exhausted" >/dev/null
rc=0
rec BIND TASK-A RUN-X 1 "$tmp/needs-fix.json" --operation "$op_bind" >/dev/null 2>/dev/null || rc=$?
assert_eq "$rc" "5" "a released operation cannot be completed"
echo "ok: idempotent completion, conflicting replay refused"

# --- record enforces the ceiling under the lock ------------------------------
rec CEIL TASK-A RUN-1 1 "$tmp/needs-fix.json" >/dev/null
rec CEIL TASK-A RUN-1 2 "$tmp/needs-fix.json" >/dev/null
cp "$tmp/p2.json" "$tmp/ceil.json"
before="$(sha "$LEDGER")"
rc=0
rec CEIL TASK-A RUN-1 3 "$tmp/ceil.json" --apply >"$tmp/ceil.out" 2>/dev/null || rc=$?
assert_eq "$rc" "4" "record over the ceiling is refused"
assert_eq "$(field allowed used allowedRounds <<<"$(cat "$tmp/ceil.out")")" "False 2 2" "refusal payload"
assert_eq "$(sha "$LEDGER")" "$before" "refused record writes nothing"
assert_eq "$("$PYTHON_BIN" -c 'import json,sys; print(json.load(open(sys.argv[1]))["verdict"])' "$tmp/ceil.json")" \
  "needs-fix" "refused record does not rewrite the verdict"
[[ ! -e "$tmp/ceil.json.pre-policy.json" ]] || fail "refused record wrote a pre-policy copy"
rc=0
res CEIL TASK-B RUN-2 1 >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "4" "reserve over the ceiling is refused"
# A pending reservation by another task holds its slot for record as well.
rec HOLD TASK-A RUN-1 1 "$tmp/needs-fix.json" >/dev/null
res HOLD TASK-B RUN-2 1 >/dev/null
rc=0
rec HOLD TASK-A RUN-1 2 "$tmp/needs-fix.json" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "4" "implicit record cannot take a slot reserved by another task"
out="$(rp check --logical-change HOLD --task TASK-A 2>/dev/null || true)"
assert_eq "$(field allowed used pending <<<"$out")" "False 1 1" "check counts other tasks' reservations"
op_hold="$(entry HOLD '[k for k,v in e["operations"].items() if v["status"] == "reserved"][0]')"
rp release --logical-change HOLD --operation "$op_hold" --reason "auditor infra exhausted" >/dev/null
rec HOLD TASK-A RUN-1 2 "$tmp/needs-fix.json" >/dev/null
echo "ok: ceiling enforced under the lock; reserved slots are held until released"

# --- explicit closure and reopen ---------------------------------------------
rec CLOSE TASK-A RUN-1 1 "$tmp/needs-fix.json" >/dev/null
out="$(rec CLOSE TASK-A RUN-1 2 "$tmp/accepted.json")"
assert_eq "$(field effectiveVerdict status series <<<"$out")" "accepted accepted 1" "accepted round closes"
op_closed="$(field operationId <<<"$out")"
rc=0
out="$(rp check --logical-change CLOSE --task TASK-A 2>/dev/null)" || rc=$?
assert_eq "$rc" "4" "check on a closed change is refused"
assert_eq "$(field allowed closed used <<<"$out")" "False True 2" "closed is not a fresh budget"
assert_contains "$(field reason <<<"$out")" "reopen" "closure reason names reopen"
rc=0
res CLOSE TASK-B RUN-9 1 >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "4" "a successor task cannot reserve on a closed change"
rc=0
rec CLOSE TASK-A RUN-NEW 1 "$tmp/accepted.json" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "4" "a new run cannot record on a closed change"
out="$(rec CLOSE TASK-A RUN-1 2 "$tmp/accepted.json")"
assert_eq "$(field idempotent operationId <<<"$out")" "True $op_closed" \
  "re-publication of the same accepted operation is idempotent"
rc=0
rp grant --logical-change CLOSE --rounds 1 --reason r --evidence "$tmp/evidence/note.txt" \
  --authority operator >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "2" "grant cannot extend a closed series"
rc=0
rp reopen --logical-change CLOSE --reason "new scope" --evidence "$tmp/evidence/note.txt" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "2" "reopen requires --authority"
rc=0
rp reopen --logical-change CLOSE --reason "new scope" --evidence "$tmp/evidence/missing.txt" \
  --authority operator >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "2" "reopen requires existing evidence"
out="$(rp reopen --logical-change CLOSE --reason "new scope" --evidence "$tmp/evidence/note.txt" \
  --authority operator --task TASK-A)"
assert_eq "$(field reopened series used allowedRounds status <<<"$out")" "True 2 0 2 open" "reopen starts series 2"
out="$(rp check --logical-change CLOSE --task TASK-A)"
assert_eq "$(field allowed used series closed <<<"$out")" "True 0 2 False" "reopened change admits a review"
assert_eq "$(entry CLOSE 'len(e["rounds"])')" "2" "history is preserved across reopen"
rc=0
rp reopen --logical-change CLOSE --reason "again" --evidence "$tmp/evidence/note.txt" \
  --authority operator >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "2" "reopen of an open series is refused"
out="$(rp reopen --logical-change CLOSE --reason "again" --evidence "$tmp/evidence/note.txt" \
  --authority operator --if-closed)"
assert_eq "$(field reopened series <<<"$out")" "False 2" "--if-closed is a no-op on an open series"
rec CLOSE TASK-A RUN-2 1 "$tmp/accepted.json" >/dev/null
rc=0
rp reopen --logical-change CLOSE --reason "new scope" --evidence "$tmp/evidence/note.txt" \
  --authority operator >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "2" "a replayed reopen authority cannot open another series"
out="$(rp reopen --logical-change CLOSE --reason "third scope" --evidence "$tmp/evidence/note2.txt" \
  --authority operator)"
assert_eq "$(field series <<<"$out")" "3" "a distinct authorization opens series 3"
echo "ok: acceptance closes; only an explicit reopen starts a new series"

# --- a consumed grant cannot be consumed again -------------------------------
rec GRANT TASK-A RUN-1 1 "$tmp/needs-fix.json" >/dev/null
rec GRANT TASK-A RUN-1 2 "$tmp/needs-fix.json" >/dev/null
rp grant --logical-change GRANT --rounds 1 --reason "operator exception" \
  --evidence "$tmp/evidence/note.txt" --authority operator --task TASK-A >/dev/null
out="$(res GRANT TASK-A RUN-1 3)"
assert_eq "$(field operation.grantId <<<"$out")" "$(entry GRANT 'e["exceptions"][0]["id"]')" \
  "the third slot is supplied by the grant"
rec GRANT TASK-A RUN-1 3 "$tmp/accepted.json" --operation "$(field operationId <<<"$out")" >/dev/null
rp reopen --logical-change GRANT --reason "follow-up scope" --evidence "$tmp/evidence/note.txt" \
  --authority operator >/dev/null
rec GRANT TASK-A RUN-2 1 "$tmp/needs-fix.json" >/dev/null
rec GRANT TASK-A RUN-2 2 "$tmp/needs-fix.json" >/dev/null
rc=0
out="$(rp check --logical-change GRANT --task TASK-A 2>/dev/null)" || rc=$?
assert_eq "$rc" "4" "series 2 does not inherit the consumed series-1 grant"
assert_eq "$(field used allowedRounds <<<"$out")" "2 2" "series 2 budget is the base budget"
echo "ok: grants are bound to their series"

# --- host verification failed-product never closes the change ---------------
out="$(rec HOSTFAIL TASK-A RUN-1 1 "$tmp/accepted.json" --host-verification failed-product)"
assert_eq "$(field originalVerdict effectiveVerdict status <<<"$out")" "accepted needs-fix open" \
  "accepted label on a host failed-product head is recorded as needs-fix"
out="$(rp check --logical-change HOSTFAIL --task TASK-A)"
assert_eq "$(field allowed closed <<<"$out")" "True False" "failed-product round leaves the change open"

# --- legacy ledger migration -------------------------------------------------
legacy_state="$tmp/legacy"
mkdir -p "$legacy_state/review-policy"
cat >"$legacy_state/review-policy/ledger.json" <<'JSON'
{
  "schema": "singular.review-policy.ledger.v1",
  "updatedAt": "2026-09-14T17:00:01Z",
  "logicalChanges": {
    "legacy-accepted": {
      "status": "accepted",
      "rounds": [
        {"round": 1, "kind": "initial", "taskId": "TASK-1105", "runId": "R1", "attempt": 1, "head": "a", "originalVerdict": "needs-fix", "effectiveVerdict": "needs-fix", "recordedAt": "2026-09-13T01:00:00Z", "historical": true},
        {"round": 2, "kind": "followup", "taskId": "TASK-1105", "runId": "R1", "attempt": 2, "head": "b", "originalVerdict": "needs-fix", "effectiveVerdict": "needs-fix", "recordedAt": "2026-09-13T02:00:00Z", "historical": true},
        {"round": 3, "kind": "followup", "taskId": "TASK-1117", "runId": "R2", "attempt": 1, "head": "c", "originalVerdict": "accepted", "effectiveVerdict": "accepted", "recordedAt": "2026-09-14T17:00:01Z", "historical": false}
      ],
      "exceptions": [
        {"id": "exc-old", "grantedAt": "2026-09-14T10:00:00Z", "additionalRounds": 2, "reason": "r", "evidence": [], "taskId": "TASK-1117", "authority": "operator"}
      ]
    },
    "legacy-reaudit": {
      "status": "open",
      "rounds": [
        {"round": 1, "kind": "initial", "taskId": "M", "runId": "R1", "attempt": 1, "head": "a", "originalVerdict": "needs-fix", "effectiveVerdict": "needs-fix", "recordedAt": "2026-09-10T00:00:00Z"},
        {"round": 2, "kind": "followup", "taskId": "M", "runId": "R2", "attempt": 2, "head": "b", "originalVerdict": "accepted", "effectiveVerdict": "accepted", "recordedAt": "2026-09-11T00:00:00Z"},
        {"round": 3, "kind": "followup", "taskId": "M", "runId": "R3", "attempt": 1, "head": "c", "originalVerdict": "needs-fix", "effectiveVerdict": "needs-fix", "recordedAt": "2026-09-12T00:00:00Z"}
      ],
      "exceptions": []
    },
    "legacy-exhausted": {
      "status": "exhausted",
      "rounds": [
        {"round": 1, "kind": "initial", "taskId": "T", "runId": "R1", "attempt": 1, "head": "a", "originalVerdict": "needs-fix", "effectiveVerdict": "needs-fix", "recordedAt": "2026-09-10T00:00:00Z"},
        {"round": 2, "kind": "followup", "taskId": "T", "runId": "R1", "attempt": 2, "head": "b", "originalVerdict": "needs-fix", "effectiveVerdict": "needs-fix", "recordedAt": "2026-09-10T01:00:00Z"}
      ],
      "exceptions": [
        {"id": "exc-live", "grantedAt": "2026-09-10T02:00:00Z", "additionalRounds": 1, "reason": "r", "evidence": [], "taskId": null, "authority": "operator"}
      ]
    }
  }
}
JSON
cp "$legacy_state/review-policy/ledger.json" "$tmp/legacy-before.json"
lrp() {
  "$PYTHON_BIN" "$ENGINE_HOME/engine/review_policy.py" \
    --config "$CONFIG" --state-dir "$legacy_state" "$@"
}
out="$(lrp check --logical-change legacy-accepted --task TASK-1117)"
assert_eq "$(field allowed used allowedRounds closed status <<<"$out")" "True 0 2 False accepted" \
  "a legacy accepted row is still a series boundary, and its spent grant does not return"
out="$(lrp check --logical-change legacy-reaudit --task M)"
assert_eq "$(field allowed used allowedRounds closed <<<"$out")" "True 1 2 False" \
  "legacy rounds after a legacy acceptance count toward series 1"
out="$(lrp check --logical-change legacy-exhausted --task T)"
assert_eq "$(field allowed used allowedRounds <<<"$out")" "True 2 3" \
  "a legacy grant granted after the last legacy acceptance still applies"
LEDGER="$legacy_state/review-policy/ledger.json"
"$PYTHON_BIN" "$ENGINE_HOME/engine/review_policy.py" --config "$CONFIG" --state-dir "$legacy_state" \
  record --logical-change legacy-accepted --task TASK-1117 --run R9 --attempt 1 \
  --verdict "$tmp/accepted.json" --head d >/dev/null
assert_eq "$("$PYTHON_BIN" - "$tmp/legacy-before.json" "$LEDGER" <<'PY'
import json, sys
before = json.load(open(sys.argv[1]))["logicalChanges"]
after = json.load(open(sys.argv[2]))["logicalChanges"]
same = all(after[k]["rounds"][:len(v["rounds"])] == v["rounds"] for k, v in before.items())
same = same and all(after[k]["exceptions"] == v["exceptions"] for k, v in before.items())
print(same, len(after["legacy-accepted"]["rounds"]), after["legacy-accepted"]["rounds"][-1]["series"])
PY
)" "True 4 1" "legacy rows and grants are preserved; new rows carry a series"
rc=0
lrp check --logical-change legacy-accepted --task TASK-1117 >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "4" "a new-style accepted round closes the migrated change"
LEDGER="$STATE/review-policy/ledger.json"
echo "ok: legacy ledgers migrate without becoming exhausted or closed"

# --- malformed ledgers fail closed, never reset ------------------------------
bad_state="$tmp/bad"
mkdir -p "$bad_state/review-policy"
brp() {
  "$PYTHON_BIN" "$ENGINE_HOME/engine/review_policy.py" \
    --config "$CONFIG" --state-dir "$bad_state" "$@"
}
for body in \
  '{"schema":"singular.review-policy.ledger.v1","logicalChanges":' \
  '[]' \
  '{"logicalChanges":[]}' \
  '{"logicalChanges":{"LC":"oops"}}' \
  '{"logicalChanges":{"LC":{"rounds":{"1":{}},"exceptions":[]}}}' \
  '{"logicalChanges":{"LC":{"rounds":["x"],"exceptions":[]}}}' \
  '{"logicalChanges":{"LC":{"rounds":[],"exceptions":[],"series":0}}}' \
  '{"logicalChanges":{"LC":{"rounds":[],"exceptions":[],"operations":{"rop-1":{"operationId":"rop-2"}}}}}'; do
  printf '%s\n' "$body" >"$bad_state/review-policy/ledger.json"
  before="$(sha "$bad_state/review-policy/ledger.json")"
  for verb in check reserve record; do
    rc=0
    case "$verb" in
      check) brp check --logical-change LC --task T >/dev/null 2>&1 || rc=$? ;;
      reserve) brp reserve --logical-change LC --task T --run R --attempt 1 --head h >/dev/null 2>&1 || rc=$? ;;
      record) brp record --logical-change LC --task T --run R --attempt 1 --head h \
        --verdict "$tmp/accepted.json" >/dev/null 2>&1 || rc=$? ;;
    esac
    assert_eq "$rc" "3" "$verb on malformed ledger $body"
  done
  assert_eq "$(sha "$bad_state/review-policy/ledger.json")" "$before" "malformed ledger left untouched: $body"
done
printf '%s\n' '{"logicalChanges":{"LC":"oops"}}' >"$bad_state/review-policy/ledger.json"
brp show >/dev/null || fail "show still prints a malformed ledger for diagnosis"
echo "ok: malformed ledgers are refused (exit 3) and never reset"

echo "PASS: test-review-ledger-admission"
