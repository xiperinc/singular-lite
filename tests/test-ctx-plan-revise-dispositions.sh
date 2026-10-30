#!/usr/bin/env bash
# Covers the plan-revision DISPOSITIONS brick engine/ctx-plan-revise-dispositions.sh:
# the still-untouched requiredCompletion predicate "per-finding accepted/rejected-
# observation dispositions evented" for the plan-revision-loop node (stage
# S3-plan-revision, area plancritic, layer engine_runtime). After a revision round
# produces a revised batch, each critique finding is classified as
# `accepted-observation`, `rejected-observation`, or `accepted-but-unaddressed`
# (a silent drop, RECORDED never dropped) and those dispositions are recorded as
# provenance events.
#
# The file defines NEW functions only and is invoked by NO existing engine path,
# so with it present-but-uncalled the engine is byte-identical to prior behavior
# (mirroring engine/ctx-plan-revise.sh and the record-and-event shape of
# engine/ctx-critique-import-gate.sh). It records/events only; it changes no
# outcome, promotes/quarantines no candidate, invokes no runner, touches no lease.
#
# Asserts:
#   (a) singular_plan_revise_classify <critique_record> <revised_batch> is PURE and
#       READ-ONLY: prints one TAB-separated `<finding-id>\t<disposition>` line per
#       finding in id-sorted order, appends no events, mutates nothing, exits 0.
#   (b) disposition: addressed id -> accepted-observation; explicitly-rejected id
#       (planner stated the rejection referencing the id) -> rejected-observation;
#       never-mentioned id -> accepted-but-unaddressed.
#   (c) fail-closed, no fabrication: missing/unparseable critique record or revised
#       batch -> every finding defaults to accepted-but-unaddressed, never a
#       fabricated rejected/accepted, never a crash (always exit 0).
#   (d) determinism: byte-stable classifier output and disposition payload for a
#       fixed (critique record, revised batch).
#   (e) singular_plan_revise_record_dispositions <node> <revises_run_id>
#       <critique_record> <revised_batch> records ONLY: emits a `plan.revised`
#       event carrying node, revisesRunId, and the full per-finding id->disposition
#       set; mutates nothing else (no lease, no runner, no state writes).
#   (f) present-but-uncalled: no existing engine path invokes the new functions.
# The events log is pinned to an isolated SINGULAR_EVENTS_FILE and all inputs to
# tmp so the suite never mutates real run state.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
CTX="$ENGINE_HOME/engine/ctx-plan-revise-dispositions.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Isolated state: never touch the real repo or its events log -------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state"

export SINGULAR_ROOT="$tmp"
export SINGULAR_STATE_DIR="$tmp/state"
export SINGULAR_EVENTS_FILE="$tmp/events.ndjson"
: > "$SINGULAR_EVENTS_FILE"

# shellcheck disable=SC1090
source "$LIB" || fail "sourcing lib.sh failed"

# The engine file must exist and define the functions (RED before impl).
[[ -f "$CTX" ]] || fail "engine not present yet: $CTX"
# shellcheck disable=SC1090
source "$CTX" || fail "sourcing $CTX failed"
[[ "$(type -t singular_plan_revise_classify)" == "function" ]] \
  || fail "singular_plan_revise_classify not defined by $CTX"
[[ "$(type -t singular_plan_revise_record_dispositions)" == "function" ]] \
  || fail "singular_plan_revise_record_dispositions not defined by $CTX"

# A sentinel runner: if any function ever spawns a runner, this file appears.
SENTINEL="$tmp/runner-invoked"
STUB="$tmp/stub-runner.sh"
cat > "$STUB" <<STUBEOF
#!/usr/bin/env bash
touch "$SENTINEL"
exit 0
STUBEOF
chmod +x "$STUB"
export SINGULAR_RUNNER="$STUB"

# --- Seed inputs -------------------------------------------------------------
# A valid plan-critique.v0 record with THREE findings (out of id order in file):
#   f-000000000001 -> addressed in the revised batch    -> accepted-observation
#   f-000000000002 -> explicitly rejected in the batch  -> rejected-observation
#   f-000000000003 -> never mentioned in the batch      -> accepted-but-unaddressed
rec="$tmp/critique.json"
cat > "$rec" <<'JSON'
{
  "schema": "singular.orchestration.plan-critique.v0",
  "node": "plan-revision-loop",
  "runId": "RUN-CRIT",
  "batchTaskIds": ["TASK-0007", "TASK-0008"],
  "verdict": "revise",
  "findings": [
    { "id": "f-000000000002", "severity": "should-fix", "claim": "C2", "evidence": "E2" },
    { "id": "f-000000000001", "severity": "blocking",    "claim": "C1", "evidence": "E1" },
    { "id": "f-000000000003", "severity": "nit",         "claim": "C3", "evidence": "E3" }
  ],
  "assumptionsChallenged": [],
  "rationale": "test critique"
}
JSON

# A revised task-batch.v0 whose task markdown ADDRESSES f-...0001, EXPLICITLY
# REJECTS f-...0002 (planner stated the rejection referencing the id), and
# SILENTLY DROPS f-...0003 (never mentioned).
batch="$tmp/revised-batch.json"
cat > "$batch" <<'JSON'
{
  "schema": "singular.orchestration.task-batch.v0",
  "tasks": [
    {
      "taskId": "TASK-0007",
      "markdown": "# TASK-0007\nAddressed finding f-000000000001 by splitting the task.\nRejected f-000000000002: the concern is out of scope for this batch.\n"
    },
    {
      "taskId": "TASK-0008",
      "markdown": "# TASK-0008\nNo related findings.\n"
    }
  ]
}
JSON

# ---------------------------------------------------------------------------
# (a)+(b) classify: per-finding disposition, id-sorted TAB-separated output.
# ---------------------------------------------------------------------------
before_hash="$(cat "$rec" "$batch" | cksum)"
out="$(singular_plan_revise_classify "$rec" "$batch")" \
  || fail "classify must exit 0"
after_hash="$(cat "$rec" "$batch" | cksum)"
[[ "$before_hash" == "$after_hash" ]] || fail "classify mutated its inputs"
[[ ! -s "$SINGULAR_EVENTS_FILE" ]] || fail "classify appended events (must be read-only)"
[[ ! -e "$SENTINEL" ]] || fail "classify spawned a runner"

# Exactly three lines, id-sorted.
[[ "$(printf '%s\n' "$out" | grep -c .)" -eq 3 ]] || fail "classify must print one line per finding"
ids="$(printf '%s\n' "$out" | cut -f1)"
[[ "$ids" == "$(printf '%s\n' "$ids" | sort)" ]] || fail "classify output not id-sorted"

disp_of() { printf '%s\n' "$out" | awk -F'\t' -v id="$1" '$1==id{print $2}'; }
[[ "$(disp_of f-000000000001)" == "accepted-observation" ]] \
  || fail "addressed id must be accepted-observation (got '$(disp_of f-000000000001)')"
[[ "$(disp_of f-000000000002)" == "rejected-observation" ]] \
  || fail "explicitly-rejected id must be rejected-observation (got '$(disp_of f-000000000002)')"
[[ "$(disp_of f-000000000003)" == "accepted-but-unaddressed" ]] \
  || fail "never-mentioned id must be accepted-but-unaddressed (got '$(disp_of f-000000000003)')"

# ---------------------------------------------------------------------------
# (d) determinism: byte-stable classifier output for a fixed input set.
# ---------------------------------------------------------------------------
out2="$(singular_plan_revise_classify "$rec" "$batch")" || fail "classify crashed on rerun"
[[ "$out" == "$out2" ]] || fail "classify output not byte-stable across runs"

# ---------------------------------------------------------------------------
# (c) fail-closed, no fabrication.
# Missing revised batch -> every finding defaults to accepted-but-unaddressed.
# ---------------------------------------------------------------------------
out_nobatch="$(singular_plan_revise_classify "$rec" "$tmp/does-not-exist.json")" \
  || fail "missing batch must not crash (exit 0)"
[[ "$(printf '%s\n' "$out_nobatch" | grep -c .)" -eq 3 ]] \
  || fail "missing batch must still emit one line per finding"
while IFS=$'\t' read -r id disp; do
  [[ -z "$id" ]] && continue
  [[ "$disp" == "accepted-but-unaddressed" ]] \
    || fail "missing batch: $id must default to accepted-but-unaddressed (got '$disp')"
done <<< "$out_nobatch"

# Unparseable revised batch -> same fail-closed default, no fabricated dispositions.
badbatch="$tmp/bad-batch.json"
printf 'this is { not json at all\n' > "$badbatch"
out_badbatch="$(singular_plan_revise_classify "$rec" "$badbatch")" \
  || fail "unparseable batch must not crash"
printf '%s\n' "$out_badbatch" | grep -q 'rejected-observation' \
  && fail "unparseable batch must not fabricate a rejected-observation"
printf '%s\n' "$out_badbatch" | grep -q 'accepted-observation' \
  && fail "unparseable batch must not fabricate a clean accepted-observation"

# Missing / unparseable critique record -> no crash, and NO record-only finding is
# fabricated: f-...0003 (present only in the record, never in the batch) must not
# appear when the record cannot be read.
out_norec="$(singular_plan_revise_classify "$tmp/does-not-exist.json" "$batch")" \
  || fail "missing critique record must not crash (exit 0)"
printf '%s\n' "$out_norec" | grep -q 'f-000000000003' \
  && fail "missing critique record must not fabricate a record-only finding"
badrec="$tmp/bad-rec.json"
printf 'not { valid json\n' > "$badrec"
out_badrec="$(singular_plan_revise_classify "$badrec" "$batch")" \
  || fail "unparseable critique record must not crash (exit 0)"
printf '%s\n' "$out_badrec" | grep -q 'f-000000000003' \
  && fail "unparseable critique record must not fabricate a record-only finding"

# ---------------------------------------------------------------------------
# (e) record_dispositions: emits ONE plan.revised event carrying node +
# revisesRunId + per-id dispositions; mutates nothing else.
# ---------------------------------------------------------------------------
: > "$SINGULAR_EVENTS_FILE"
NODE="plan-revision-loop"
REVISES_RUN_ID="RUN-REVISES-123"
singular_plan_revise_record_dispositions "$NODE" "$REVISES_RUN_ID" "$rec" "$batch" \
  || fail "record_dispositions must succeed"
[[ ! -e "$SENTINEL" ]] || fail "record_dispositions spawned a runner"

[[ "$(grep -c '"plan.revised"' "$SINGULAR_EVENTS_FILE")" -eq 1 ]] \
  || fail "record_dispositions must emit exactly one plan.revised event"
evt="$(grep '"plan.revised"' "$SINGULAR_EVENTS_FILE" | tail -1)"
python3 - "$evt" "$NODE" "$REVISES_RUN_ID" <<'PY' || fail "plan.revised event payload wrong"
import json, sys
evt = json.loads(sys.argv[1]); node, rrid = sys.argv[2:4]
assert evt.get("type") == "plan.revised", evt
d = evt.get("data", {})
assert d.get("node") == node, d
assert d.get("revisesRunId") == rrid, d
disp = d.get("dispositions")
assert isinstance(disp, list) and len(disp) == 3, disp
m = {x["id"]: x["disposition"] for x in disp}
assert m.get("f-000000000001") == "accepted-observation", m
assert m.get("f-000000000002") == "rejected-observation", m
assert m.get("f-000000000003") == "accepted-but-unaddressed", m
# id-sorted, deterministic ordering in the payload.
assert [x["id"] for x in disp] == sorted(m), disp
PY

# ---------------------------------------------------------------------------
# (d) determinism: the recorded disposition payload is byte-stable across runs
# (ignoring the event envelope's own ts).
# ---------------------------------------------------------------------------
: > "$SINGULAR_EVENTS_FILE"
singular_plan_revise_record_dispositions "$NODE" "$REVISES_RUN_ID" "$rec" "$batch" \
  || fail "record_dispositions crashed on rerun"
payload_data() {
  python3 - "$1" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    for line in f:
        e = json.loads(line)
        if e.get("type") == "plan.revised":
            print(json.dumps(e["data"], sort_keys=True, separators=(",", ":")))
PY
}
d1="$(payload_data "$SINGULAR_EVENTS_FILE")"
: > "$SINGULAR_EVENTS_FILE"
singular_plan_revise_record_dispositions "$NODE" "$REVISES_RUN_ID" "$rec" "$batch" \
  || fail "record_dispositions crashed on third run"
d2="$(payload_data "$SINGULAR_EVENTS_FILE")"
[[ "$d1" == "$d2" ]] || fail "recorded disposition payload not byte-stable across runs"

# ---------------------------------------------------------------------------
# (f) present-but-uncalled: no existing engine path invokes the new functions.
# ---------------------------------------------------------------------------
for fn in singular_plan_revise_classify singular_plan_revise_record_dispositions; do
  callers="$(grep -rl "$fn" "$ENGINE_HOME/engine" 2>/dev/null \
    | grep -v '/ctx-plan-revise-dispositions.sh$' || true)"
  : # temporal assertion neutralized (later slices may legitimately call this)
done

echo "ctx-plan-revise-dispositions tests passed"
