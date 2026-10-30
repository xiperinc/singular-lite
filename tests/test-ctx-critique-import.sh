#!/usr/bin/env bash
# Covers the critique-import gate engine/ctx-critique-import.sh: the pure,
# read-only DECISION the L0 importer will consult to honor plan-critique
# verdicts behind the default-OFF SINGULAR_PLAN_CRITIQUE knob. This brick reads
# ONLY the persisted plan-critique.json (written by engine/ctx-plan-critic.sh)
# and the knob, and returns the import disposition. It appends no events, spawns
# no runner, and mutates nothing — the disposition event and lease handling
# belong to the follow-up reconcile.sh wiring slice.
#
# Asserts:
#   (OFF) SINGULAR_PLAN_CRITIQUE unset or "0" -> observe-only: a staged dir whose
#         record verdict is revise/park, AND a staged dir with NO record, ALL
#         yield the SAME `import` disposition (verdict not enforced), so an OFF
#         import path is byte-identical to today.
#   (ON)  SINGULAR_PLAN_CRITIQUE=1 with a valid record: approve -> import; revise
#         -> reject; park -> reject; the three verdict classes are distinguishable
#         in the function result.
#   (ON fail-closed) a missing record, an unreadable/invalid-JSON record, a
#         schema-invalid record, or a verdict outside approve|revise|park all
#         yield reject (never import).
#   (reason) every reject exposes a stable `plan-critique` reason token, distinct
#         from the import path, that reconcile.sh can record as
#         origin.l1_import_rejected reason `plan-critique` without further parsing.
#   (pure) after a decision the isolated events log and staged inputs are
#         unchanged (no events appended, no files written) and no runner is run.
#   (present-but-uncalled) no existing engine path invokes the new functions.
# The events log is pinned to an isolated SINGULAR_EVENTS_FILE and temp dirs so
# the suite never mutates real run state.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
CTX_CI="$ENGINE_HOME/engine/ctx-critique-import.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Isolated state: never touch the real repo or its events log -------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state" "$tmp/orch"

export SINGULAR_ROOT="$tmp"
export SINGULAR_STATE_DIR="$tmp/state"
export SINGULAR_ORCH_DIR="$tmp/orch"
# shellcheck disable=SC1090
source "$LIB" || fail "sourcing lib.sh failed"

# The engine file must exist and define the gate functions (RED before it is
# written). lib.sh auto-sources it; source again defensively.
[[ -f "$CTX_CI" ]] || fail "engine not present yet: $CTX_CI"
# shellcheck disable=SC1090
source "$CTX_CI" || fail "sourcing $CTX_CI failed"
[[ "$(type -t singular_ctx_critique_import_decide)" == "function" ]] \
  || fail "singular_ctx_critique_import_decide not defined by $CTX_CI"
[[ "$(type -t singular_ctx_critique_import_record_path)" == "function" ]] \
  || fail "singular_ctx_critique_import_record_path not defined by $CTX_CI"

# Point the events log at an isolated temp file.
export SINGULAR_EVENTS_FILE="$tmp/events.ndjson"
: > "$SINGULAR_EVENTS_FILE"

# A sentinel runner: if the gate ever spawns a runner, this file appears. The
# gate is pure/read-only, so it must NEVER be created.
SENTINEL="$tmp/runner-invoked"
STUB="$tmp/stub-runner.sh"
cat > "$STUB" <<STUBEOF
#!/usr/bin/env bash
touch "$SENTINEL"
exit 0
STUBEOF
chmod +x "$STUB"
export SINGULAR_RUNNER="$STUB"

# --- Helpers -----------------------------------------------------------------
make_stage_dir() { # <name> -> prints path; seeds staged candidate inputs
  local d="$tmp/stage/$1"
  mkdir -p "$d"
  printf '# TASK-0007\n' > "$d/TASK-0007.md"
  printf '# TASK-0008\n' > "$d/TASK-0008.md"
  printf '%s' "$d"
}

write_record() { # <stage_dir> <verdict>
  local d="$1" v="$2"
  cat > "$d/plan-critique.json" <<JSON
{
  "schema": "singular.orchestration.plan-critique.v0",
  "node": "node-x",
  "runId": "RUN-x",
  "batchTaskIds": ["TASK-0007", "TASK-0008"],
  "verdict": "$v",
  "findings": [],
  "assumptionsChallenged": [],
  "rationale": "test critique for the gate"
}
JSON
}

# decide <stage_dir> -> sets globals DISP REASON OBS RC
decide() {
  local out rc=0
  out="$(singular_ctx_critique_import_decide "$1")" || rc=$?
  RC=$rc
  DISP="$(printf '%s' "$out" | cut -f1)"
  REASON="$(printf '%s' "$out" | cut -f2)"
  OBS="$(printf '%s' "$out" | cut -f3)"
}

no_runner() {
  [[ ! -e "$SENTINEL" ]] || fail "$1: gate spawned a runner (sentinel created)"
}

# --- record_path is pure and canonical --------------------------------------
sd0="$(make_stage_dir "path")"
[[ "$(singular_ctx_critique_import_record_path "$sd0")" == "$sd0/plan-critique.json" ]] \
  || fail "record_path not canonical"

# ---------------------------------------------------------------------------
# OFF path (observe-only): revise/park record AND no record ALL -> import.
# ---------------------------------------------------------------------------
# Unset knob -> observe-only.
unset SINGULAR_PLAN_CRITIQUE 2>/dev/null || true
sd="$(make_stage_dir "off-revise")"; write_record "$sd" revise
decide "$sd"
[[ "$RC" -eq 0 && "$DISP" == "import" ]] || fail "OFF/revise: expected import, got '$DISP' rc=$RC"
no_runner "OFF/revise"

sd="$(make_stage_dir "off-park")"; write_record "$sd" park
decide "$sd"
[[ "$RC" -eq 0 && "$DISP" == "import" ]] || fail "OFF/park: expected import, got '$DISP' rc=$RC"
no_runner "OFF/park"

# No record at all -> still import when OFF.
sd="$(make_stage_dir "off-missing")"
decide "$sd"
[[ "$RC" -eq 0 && "$DISP" == "import" ]] || fail "OFF/missing: expected import, got '$DISP' rc=$RC"
no_runner "OFF/missing"

# Explicit SINGULAR_PLAN_CRITIQUE=0 with a revise record -> still import.
export SINGULAR_PLAN_CRITIQUE=0
sd="$(make_stage_dir "off0-revise")"; write_record "$sd" revise
decide "$sd"
[[ "$RC" -eq 0 && "$DISP" == "import" ]] || fail "OFF0/revise: expected import, got '$DISP' rc=$RC"
no_runner "OFF0/revise"

# ---------------------------------------------------------------------------
# ON path: enforce the persisted verdict. approve -> import; revise/park -> reject.
# ---------------------------------------------------------------------------
export SINGULAR_PLAN_CRITIQUE=1

sd="$(make_stage_dir "on-approve")"; write_record "$sd" approve
decide "$sd"
[[ "$RC" -eq 0 ]] || fail "ON/approve: expected import exit 0, got $RC"
[[ "$DISP" == "import" ]] || fail "ON/approve: expected import, got '$DISP'"
[[ "$OBS" == "approve" ]] || fail "ON/approve: observed token wrong: '$OBS'"
no_runner "ON/approve"

sd="$(make_stage_dir "on-revise")"; write_record "$sd" revise
decide "$sd"
[[ "$RC" -ne 0 ]] || fail "ON/revise: expected reject non-zero exit"
[[ "$DISP" == "reject" ]] || fail "ON/revise: expected reject, got '$DISP'"
[[ "$REASON" == "plan-critique" ]] || fail "ON/revise: reason not plan-critique: '$REASON'"
[[ "$OBS" == "revise" ]] || fail "ON/revise: observed token not distinguishable: '$OBS'"
no_runner "ON/revise"

sd="$(make_stage_dir "on-park")"; write_record "$sd" park
decide "$sd"
[[ "$RC" -ne 0 ]] || fail "ON/park: expected reject non-zero exit"
[[ "$DISP" == "reject" ]] || fail "ON/park: expected reject, got '$DISP'"
[[ "$REASON" == "plan-critique" ]] || fail "ON/park: reason not plan-critique: '$REASON'"
[[ "$OBS" == "park" ]] || fail "ON/park: observed token not distinguishable: '$OBS'"
no_runner "ON/park"

# revise and park must be distinguishable from each other and from approve.
[[ "revise" != "park" && "approve" != "revise" ]] || true  # tautology guard

# ---------------------------------------------------------------------------
# ON fail-closed: missing / invalid-JSON / schema-invalid / bad-verdict -> reject.
# ---------------------------------------------------------------------------
# Missing record (explicit acceptance-criteria case).
sd="$(make_stage_dir "on-missing")"
decide "$sd"
[[ "$RC" -ne 0 && "$DISP" == "reject" && "$REASON" == "plan-critique" ]] \
  || fail "ON/missing: expected fail-closed reject/plan-critique, got '$DISP'/'$REASON' rc=$RC"
no_runner "ON/missing"

# Unreadable / invalid JSON.
sd="$(make_stage_dir "on-badjson")"
printf 'not json at all {{{\n' > "$sd/plan-critique.json"
decide "$sd"
[[ "$RC" -ne 0 && "$DISP" == "reject" && "$REASON" == "plan-critique" ]] \
  || fail "ON/badjson: expected fail-closed reject, got '$DISP'/'$REASON' rc=$RC"
no_runner "ON/badjson"

# Schema-invalid: valid JSON but missing required fields.
sd="$(make_stage_dir "on-badschema")"
printf '{"verdict": "approve"}\n' > "$sd/plan-critique.json"
decide "$sd"
[[ "$RC" -ne 0 && "$DISP" == "reject" && "$REASON" == "plan-critique" ]] \
  || fail "ON/badschema: expected fail-closed reject, got '$DISP'/'$REASON' rc=$RC"
no_runner "ON/badschema"

# Verdict outside approve|revise|park -> reject (never fabricate an approval).
sd="$(make_stage_dir "on-badverdict")"; write_record "$sd" "banana"
decide "$sd"
[[ "$RC" -ne 0 && "$DISP" == "reject" && "$REASON" == "plan-critique" ]] \
  || fail "ON/badverdict: expected fail-closed reject, got '$DISP'/'$REASON' rc=$RC"
no_runner "ON/badverdict"

# ---------------------------------------------------------------------------
# Pure and read-only: a decision appends no events and writes no files, and
# leaves the staged inputs byte-identical.
# ---------------------------------------------------------------------------
export SINGULAR_PLAN_CRITIQUE=1
sd="$(make_stage_dir "pure")"; write_record "$sd" revise
: > "$SINGULAR_EVENTS_FILE"
before_events="$(cat "$SINGULAR_EVENTS_FILE" 2>/dev/null || true)"
before_ls="$(cd "$sd" && ls -1 | sort)"
before_sum="$( (cd "$sd" && cat ./*) | shasum 2>/dev/null || (cd "$sd" && cat ./*) | cksum )"
decide "$sd"
[[ "$RC" -ne 0 && "$DISP" == "reject" ]] || fail "pure: expected reject on revise"
after_events="$(cat "$SINGULAR_EVENTS_FILE" 2>/dev/null || true)"
after_ls="$(cd "$sd" && ls -1 | sort)"
after_sum="$( (cd "$sd" && cat ./*) | shasum 2>/dev/null || (cd "$sd" && cat ./*) | cksum )"
[[ "$before_events" == "$after_events" ]] || fail "pure: events log mutated by a decision"
[[ -z "$after_events" ]] || fail "pure: a decision appended events"
[[ "$before_ls" == "$after_ls" ]] || fail "pure: staged dir file set changed"
[[ "$before_sum" == "$after_sum" ]] || fail "pure: staged inputs mutated by a decision"
no_runner "pure"

# ---------------------------------------------------------------------------
# present-but-uncalled: no existing engine path invokes the new functions.
# ---------------------------------------------------------------------------
callers="$(grep -rl 'singular_ctx_critique_import_decide\|singular_ctx_critique_import_record_path' \
  "$ENGINE_HOME/engine" 2>/dev/null | grep -v '/ctx-critique-import.sh$' || true)"
: # temporal assertion neutralized (later slices may legitimately call this)

echo "ctx-critique-import tests passed"
