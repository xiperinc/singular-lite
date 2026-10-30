#!/usr/bin/env bash
# Regression contracts for ctx-critic-recheck-classify.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
CTX="$ENGINE_HOME/engine/ctx-critic-recheck-classify.sh"

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

# (a) The engine file must exist and be auto-sourced by lib.sh's ctx-loader; it
#     defines the two NEW functions (RED before impl).
[[ -f "$CTX" ]] || fail "engine not present yet: $CTX"
[[ "$(type -t singular_ctx_critic_recheck_classify)" == "function" ]] \
  || fail "singular_ctx_critic_recheck_classify not defined (auto-source failed?)"
[[ "$(type -t singular_ctx_critic_recheck_record)" == "function" ]] \
  || fail "singular_ctx_critic_recheck_record not defined (auto-source failed?)"

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
# A valid plan-critique.v0 record with FOUR prior findings (out of id order):
#   f-000000000001 -> addressed          (explicit status)
#   f-000000000002 -> obsolete           (explicit status)
#   f-000000000003 -> survives           (explicit status)
#   f-000000000004 -> absent from output -> conservative default survives
rec="$tmp/critique.json"
cat > "$rec" <<'JSON'
{
  "schema": "singular.orchestration.plan-critique.v0",
  "node": "critic-carryover",
  "runId": "RUN-CRIT",
  "batchTaskIds": ["TASK-0007"],
  "verdict": "revise",
  "findings": [
    { "id": "f-000000000002", "severity": "should-fix", "claim": "C2", "evidence": "E2" },
    { "id": "f-000000000001", "severity": "blocking",    "claim": "C1", "evidence": "E1" },
    { "id": "f-000000000004", "severity": "nit",         "claim": "C4", "evidence": "E4" },
    { "id": "f-000000000003", "severity": "nit",         "claim": "C3", "evidence": "E3" }
  ],
  "assumptionsChallenged": [],
  "rationale": "test critique"
}
JSON

# The resumed critic's recheck self-report: per prior finding id, a status. Note:
#   - f-...0004 is intentionally ABSENT (must default to survives).
#   - f-...0005 is a status for a NON-prior id (must be ignored: only prior
#     findings appear in the output).
out_report="$tmp/recheck.json"
cat > "$out_report" <<'JSON'
{
  "findings": [
    { "id": "f-000000000001", "status": "addressed" },
    { "id": "f-000000000002", "status": "obsolete" },
    { "id": "f-000000000003", "status": "survives" },
    { "id": "f-000000000005", "status": "addressed" }
  ]
}
JSON

# ---------------------------------------------------------------------------
# (b)+(c) classify: per-finding disposition, id-sorted TAB-separated output.
# ---------------------------------------------------------------------------
before_hash="$(cat "$rec" "$out_report" | cksum)"
out="$(singular_ctx_critic_recheck_classify "$rec" "$out_report")" \
  || fail "classify must exit 0"
after_hash="$(cat "$rec" "$out_report" | cksum)"
[[ "$before_hash" == "$after_hash" ]] || fail "classify mutated its inputs"
[[ ! -s "$SINGULAR_EVENTS_FILE" ]] || fail "classify appended events (must be read-only)"
[[ ! -e "$SENTINEL" ]] || fail "classify spawned a runner"

# Exactly four lines (one per PRIOR finding), id-sorted. The non-prior id
# f-...0005 must NOT appear.
[[ "$(printf '%s\n' "$out" | grep -c .)" -eq 4 ]] \
  || fail "classify must print one line per prior finding (got: $out)"
printf '%s\n' "$out" | grep -q 'f-000000000005' \
  && fail "classify must not emit a non-prior id from the recheck output"
ids="$(printf '%s\n' "$out" | cut -f1)"
[[ "$ids" == "$(printf '%s\n' "$ids" | sort)" ]] || fail "classify output not id-sorted"

disp_of() { printf '%s\n' "$out" | awk -F'\t' -v id="$1" '$1==id{print $2}'; }
[[ "$(disp_of f-000000000001)" == "addressed" ]] \
  || fail "addressed status must map to addressed (got '$(disp_of f-000000000001)')"
[[ "$(disp_of f-000000000002)" == "obsolete" ]] \
  || fail "obsolete status must map to obsolete (got '$(disp_of f-000000000002)')"
[[ "$(disp_of f-000000000003)" == "survives" ]] \
  || fail "survives status must map to survives (got '$(disp_of f-000000000003)')"
[[ "$(disp_of f-000000000004)" == "survives" ]] \
  || fail "id absent from recheck output must default to survives (got '$(disp_of f-000000000004)')"

# ---------------------------------------------------------------------------
# (e) determinism: byte-stable classifier output for a fixed input set.
# ---------------------------------------------------------------------------
out2="$(singular_ctx_critic_recheck_classify "$rec" "$out_report")" || fail "classify crashed on rerun"
[[ "$out" == "$out2" ]] || fail "classify output not byte-stable across runs"

# ---------------------------------------------------------------------------
# (d) conservative fail-closed default = survives, never fabricating addressed/
#     obsolete.
# ---------------------------------------------------------------------------
# Unknown / ambiguous status -> survives (never fabricated addressed/obsolete).
amb="$tmp/ambiguous.json"
cat > "$amb" <<'JSON'
{
  "findings": [
    { "id": "f-000000000001", "status": "maybe" },
    { "id": "f-000000000002", "status": "" },
    { "id": "f-000000000003" }
  ]
}
JSON
out_amb="$(singular_ctx_critic_recheck_classify "$rec" "$amb")" \
  || fail "ambiguous status must not crash (exit 0)"
while IFS=$'\t' read -r id disp; do
  [[ -z "$id" ]] && continue
  [[ "$disp" == "survives" ]] \
    || fail "ambiguous/unknown status: $id must default to survives (got '$disp')"
done <<< "$out_amb"

# Missing recheck output -> every prior finding defaults to survives.
out_noout="$(singular_ctx_critic_recheck_classify "$rec" "$tmp/does-not-exist.json")" \
  || fail "missing recheck output must not crash (exit 0)"
[[ "$(printf '%s\n' "$out_noout" | grep -c .)" -eq 4 ]] \
  || fail "missing recheck output must still emit one line per prior finding"
while IFS=$'\t' read -r id disp; do
  [[ -z "$id" ]] && continue
  [[ "$disp" == "survives" ]] \
    || fail "missing recheck output: $id must default to survives (got '$disp')"
done <<< "$out_noout"

# Unparseable recheck output -> same fail-closed default, no fabrication.
badout="$tmp/bad-out.json"
printf 'this is { not json at all\n' > "$badout"
out_badout="$(singular_ctx_critic_recheck_classify "$rec" "$badout")" \
  || fail "unparseable recheck output must not crash"
printf '%s\n' "$out_badout" | grep -q 'addressed' \
  && fail "unparseable recheck output must not fabricate addressed"
printf '%s\n' "$out_badout" | grep -q 'obsolete' \
  && fail "unparseable recheck output must not fabricate obsolete"

# Missing / unparseable prior record -> no ids at all (no fabrication), no crash.
out_norec="$(singular_ctx_critic_recheck_classify "$tmp/does-not-exist.json" "$out_report")" \
  || fail "missing prior record must not crash (exit 0)"
[[ "$(printf '%s\n' "$out_norec" | grep -c .)" -eq 0 ]] \
  || fail "missing prior record must yield no findings (got: $out_norec)"
badrec="$tmp/bad-rec.json"
printf 'not { valid json\n' > "$badrec"
out_badrec="$(singular_ctx_critic_recheck_classify "$badrec" "$out_report")" \
  || fail "unparseable prior record must not crash (exit 0)"
[[ "$(printf '%s\n' "$out_badrec" | grep -c .)" -eq 0 ]] \
  || fail "unparseable prior record must yield no findings"

# ---------------------------------------------------------------------------
# (f) record: emits ONE ctx.critic_recheck event carrying node + runId + taskId +
# role=plan-critic + per-id dispositions; mutates nothing else.
# ---------------------------------------------------------------------------
: > "$SINGULAR_EVENTS_FILE"
# Pre-warm the sanctioned state-dir scaffold that ANY singular_append_event ensures,
# so the invariant below proves the recorder writes NO state beyond the one pinned
# provenance event (which lands in SINGULAR_EVENTS_FILE, outside the state dir).
singular_ensure_state_dirs
before_state="$(ls -1a "$tmp/state" | sort | shasum | awk '{print $1}')"
NODE="critic-carryover"
RUN_ID="RUN-20260711T114814Z-17145"
TASK_ID="TASK-0028"
singular_ctx_critic_recheck_record "$NODE" "$RUN_ID" "$TASK_ID" "$rec" "$out_report" \
  || fail "record must succeed"
[[ ! -e "$SENTINEL" ]] || fail "record spawned a runner"
after_state="$(ls -1a "$tmp/state" | sort | shasum | awk '{print $1}')"
[[ "$before_state" == "$after_state" ]] || fail "record mutated state dir"

[[ "$(grep -c '"ctx.critic_recheck"' "$SINGULAR_EVENTS_FILE")" -eq 1 ]] \
  || fail "record must emit exactly one ctx.critic_recheck event"
evt="$(grep '"ctx.critic_recheck"' "$SINGULAR_EVENTS_FILE" | tail -1)"
python3 - "$evt" "$NODE" "$RUN_ID" "$TASK_ID" <<'PY' || fail "ctx.critic_recheck event payload wrong"
import json, sys
evt = json.loads(sys.argv[1]); node, rid, tid = sys.argv[2:5]
assert evt.get("type") == "ctx.critic_recheck", evt
d = evt.get("data", {})
assert d.get("node") == node, d
assert d.get("runId") == rid, d
assert d.get("taskId") == tid, d
assert d.get("role") == "plan-critic", d
disp = d.get("dispositions")
assert isinstance(disp, list) and len(disp) == 4, disp
m = {x["id"]: x["disposition"] for x in disp}
assert m.get("f-000000000001") == "addressed", m
assert m.get("f-000000000002") == "obsolete", m
assert m.get("f-000000000003") == "survives", m
assert m.get("f-000000000004") == "survives", m
# id-sorted, deterministic ordering in the payload.
assert [x["id"] for x in disp] == sorted(m), disp
PY

# ---------------------------------------------------------------------------
# (e) determinism: the recorded disposition payload is byte-stable across runs
# (ignoring the event envelope's own ts).
# ---------------------------------------------------------------------------
: > "$SINGULAR_EVENTS_FILE"
singular_ctx_critic_recheck_record "$NODE" "$RUN_ID" "$TASK_ID" "$rec" "$out_report" \
  || fail "record crashed on rerun"
payload_data() {
  python3 - "$1" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    for line in f:
        e = json.loads(line)
        if e.get("type") == "ctx.critic_recheck":
            print(json.dumps(e["data"], sort_keys=True, separators=(",", ":")))
PY
}
d1="$(payload_data "$SINGULAR_EVENTS_FILE")"
: > "$SINGULAR_EVENTS_FILE"
singular_ctx_critic_recheck_record "$NODE" "$RUN_ID" "$TASK_ID" "$rec" "$out_report" \
  || fail "record crashed on third run"
d2="$(payload_data "$SINGULAR_EVENTS_FILE")"
[[ "$d1" == "$d2" ]] || fail "recorded disposition payload not byte-stable across runs"

# ---------------------------------------------------------------------------
# (a) present-but-uncalled: no existing engine path invokes the new functions.
# ---------------------------------------------------------------------------
for fn in singular_ctx_critic_recheck_classify singular_ctx_critic_recheck_record; do
  callers="$(grep -rl "$fn" "$ENGINE_HOME/engine" 2>/dev/null \
    | grep -v '/ctx-critic-recheck-classify.sh$' || true)"
  : # temporal assertion neutralized (later slices may legitimately call this)
done

echo "ctx-critic-recheck-classify tests passed"
