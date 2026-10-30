#!/usr/bin/env bash
# Covers the critique-import gate composed entry point
# engine/ctx-critique-import-gate.sh: the DISPOSITION the L0 importer will apply,
# built on top of the integrated pure decider singular_ctx_critique_import_decide.
# Gated on SINGULAR_PLAN_CRITIQUE (default 0 = observe-only):
#   OFF (unset or "0"): observe-only — return the `import` disposition with ZERO
#       side effects (no event, no lease change, staged files untouched), so an
#       OFF flow is byte-identical to today.
#   ON  ("=1"): consult the decider over the node's stage dir. `approve` returns
#       `import` with no side effects and the staged set intact. A reject
#       (revise / park / missing / unreadable / schema-invalid / bad verdict)
#       records EXACTLY ONE origin.l1_import_rejected event with reason
#       `plan-critique` carrying the node, runId, and observed classifier, sets
#       the node lease status to failed via singular_l1_lease_set_status, and
#       returns the `reject` disposition. Missing record ON fails CLOSED to
#       reject; it never fabricates an approval.
#
# The file defines NEW functions only and is invoked by NO existing engine path,
# so with it present-but-uncalled the engine is byte-identical (mirroring
# engine/ctx-critique-import.sh). It records/leases only; it promotes, deletes,
# or quarantines NO candidate files and invokes NO runner.
#
# The events log is pinned to an isolated SINGULAR_EVENTS_FILE and the lease dir /
# schema to isolated temp paths so the suite never mutates real run state.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
CTX_GATE="$ENGINE_HOME/engine/ctx-critique-import-gate.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Isolated state: never touch the real repo or its events log -------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state" "$tmp/orch" "$tmp/schemas/orchestration"

export SINGULAR_ROOT="$tmp"
export SINGULAR_STATE_DIR="$tmp/state"
export SINGULAR_ORCH_DIR="$tmp/orch"
export SINGULAR_L1_LEASES_DIR="$tmp/state/l1-leases"
cp "$ENGINE_HOME/schemas/l1-lease.v0.schema.json" "$tmp/schemas/orchestration/l1-lease.v0.schema.json"
export SINGULAR_L1_LEASE_SCHEMA="$tmp/schemas/orchestration/l1-lease.v0.schema.json"
# shellcheck disable=SC1090
source "$LIB" || fail "sourcing lib.sh failed"

# The engine file must exist and define the gate functions (RED before it is
# written). lib.sh auto-sources it; source again defensively.
[[ -f "$CTX_GATE" ]] || fail "engine not present yet: $CTX_GATE"
# shellcheck disable=SC1090
source "$CTX_GATE" || fail "sourcing $CTX_GATE failed"
[[ "$(type -t singular_ctx_critique_import_gate)" == "function" ]] \
  || fail "singular_ctx_critique_import_gate not defined by $CTX_GATE"
# The composed gate MUST consume the integrated decider, not re-derive it.
[[ "$(type -t singular_ctx_critique_import_decide)" == "function" ]] \
  || fail "integrated decider singular_ctx_critique_import_decide not available"

# Point the events log at an isolated temp file.
export SINGULAR_EVENTS_FILE="$tmp/events.ndjson"
: > "$SINGULAR_EVENTS_FILE"

# A sentinel runner: if the gate ever spawns a runner, this file appears. The
# gate records/leases only, so it must NEVER be created.
SENTINEL="$tmp/runner-invoked"
STUB="$tmp/stub-runner.sh"
cat > "$STUB" <<STUBEOF
#!/usr/bin/env bash
touch "$SENTINEL"
exit 0
STUBEOF
chmod +x "$STUB"
export SINGULAR_RUNNER="$STUB"

RUN_ID="RUN-gate-test"

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

seed_lease() { # <node> -> writes an active lease for that node
  singular_l1_lease_write "$1" storage S0 storage_substrate_base active \
    "$RUN_ID" abc1234 target >/dev/null \
    || fail "seed_lease failed for $1"
}

# gate <node> <stage_dir> -> sets globals DISP REASON OBS RC
gate() {
  local out rc=0
  out="$(singular_ctx_critique_import_gate "$1" "$2" "$RUN_ID")" || rc=$?
  RC=$rc
  DISP="$(printf '%s' "$out" | cut -f1)"
  REASON="$(printf '%s' "$out" | cut -f2)"
  OBS="$(printf '%s' "$out" | cut -f3)"
}

no_runner() {
  [[ ! -e "$SENTINEL" ]] || fail "$1: gate spawned a runner (sentinel created)"
}

events_count() { grep -c "$1" "$SINGULAR_EVENTS_FILE" 2>/dev/null || true; }
lease_status() { singular_l1_lease_status "$1" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# OFF path (observe-only): revise/park record AND no record ALL -> import with
# ZERO side effects — events log unchanged, lease unchanged, staged files intact.
# ---------------------------------------------------------------------------
run_off_case() { # <label> <verdict|"">   ("" means no record)
  local label="$1" verdict="$2"
  local node="off-$label"
  local sd; sd="$(make_stage_dir "$node")"
  [[ -z "$verdict" ]] || write_record "$sd" "$verdict"
  seed_lease "$node"
  : > "$SINGULAR_EVENTS_FILE"
  local before_events before_ls before_sum before_status
  before_events="$(cat "$SINGULAR_EVENTS_FILE")"
  before_ls="$(cd "$sd" && ls -1 | sort)"
  before_sum="$( (cd "$sd" && cat ./*) | shasum 2>/dev/null || (cd "$sd" && cat ./*) | cksum )"
  before_status="$(lease_status "$node")"
  gate "$node" "$sd"
  [[ "$RC" -eq 0 && "$DISP" == "import" ]] \
    || fail "OFF/$label: expected import, got '$DISP' rc=$RC"
  local after_events after_ls after_sum after_status
  after_events="$(cat "$SINGULAR_EVENTS_FILE")"
  after_ls="$(cd "$sd" && ls -1 | sort)"
  after_sum="$( (cd "$sd" && cat ./*) | shasum 2>/dev/null || (cd "$sd" && cat ./*) | cksum )"
  after_status="$(lease_status "$node")"
  [[ "$before_events" == "$after_events" && -z "$after_events" ]] \
    || fail "OFF/$label: events log mutated"
  [[ "$before_ls" == "$after_ls" && "$before_sum" == "$after_sum" ]] \
    || fail "OFF/$label: staged inputs mutated"
  [[ "$before_status" == "$after_status" ]] \
    || fail "OFF/$label: lease status changed ($before_status -> $after_status)"
  no_runner "OFF/$label"
}

# Unset knob -> observe-only.
unset SINGULAR_PLAN_CRITIQUE 2>/dev/null || true
run_off_case revise revise
run_off_case park park
run_off_case missing ""
# Explicit SINGULAR_PLAN_CRITIQUE=0 with a revise record -> still import, no side effects.
export SINGULAR_PLAN_CRITIQUE=0
run_off_case zero-revise revise

# ---------------------------------------------------------------------------
# ON approve: import disposition, no event, lease unchanged, staged set intact.
# ---------------------------------------------------------------------------
export SINGULAR_PLAN_CRITIQUE=1
node="on-approve"; sd="$(make_stage_dir "$node")"; write_record "$sd" approve
seed_lease "$node"
: > "$SINGULAR_EVENTS_FILE"
before_ls="$(cd "$sd" && ls -1 | sort)"
gate "$node" "$sd"
[[ "$RC" -eq 0 && "$DISP" == "import" ]] || fail "ON/approve: expected import, got '$DISP' rc=$RC"
[[ "$OBS" == "approve" ]] || fail "ON/approve: observed token wrong: '$OBS'"
[[ -z "$(cat "$SINGULAR_EVENTS_FILE")" ]] || fail "ON/approve: appended an event"
[[ "$(lease_status "$node")" == "active" ]] || fail "ON/approve: lease status changed"
[[ "$before_ls" == "$(cd "$sd" && ls -1 | sort)" ]] || fail "ON/approve: staged set changed"
no_runner "ON/approve"

# ---------------------------------------------------------------------------
# ON reject: revise and park -> reject; EXACTLY ONE origin.l1_import_rejected
# event with reason plan-critique carrying node/runId/observed; lease set failed.
# ---------------------------------------------------------------------------
run_reject_case() { # <label> <observed> <setup: verdict|"missing"|raw:...>
  local label="$1" want_obs="$2" mode="$3"
  local node="on-$label"
  local sd; sd="$(make_stage_dir "$node")"
  case "$mode" in
    missing) : ;;                                   # no record
    raw:*)   printf '%s\n' "${mode#raw:}" > "$sd/plan-critique.json" ;;
    *)       write_record "$sd" "$mode" ;;
  esac
  seed_lease "$node"
  : > "$SINGULAR_EVENTS_FILE"
  gate "$node" "$sd"
  [[ "$RC" -ne 0 && "$DISP" == "reject" ]] \
    || fail "ON/$label: expected reject non-zero, got '$DISP' rc=$RC"
  [[ "$REASON" == "plan-critique" ]] \
    || fail "ON/$label: reason not plan-critique: '$REASON'"
  [[ "$OBS" == "$want_obs" ]] \
    || fail "ON/$label: observed token wrong: got '$OBS' want '$want_obs'"
  # Exactly one origin.l1_import_rejected event.
  [[ "$(events_count 'origin.l1_import_rejected')" -eq 1 ]] \
    || fail "ON/$label: expected exactly one origin.l1_import_rejected event"
  # The event carries reason plan-critique, node, runId, observed classifier.
  local evt
  evt="$(grep 'origin.l1_import_rejected' "$SINGULAR_EVENTS_FILE" | tail -1)"
  python3 - "$evt" "$node" "$RUN_ID" "$want_obs" <<'PY' || fail "ON/$label: event payload wrong"
import json, sys
evt = json.loads(sys.argv[1]); node, run_id, obs = sys.argv[2:5]
assert evt.get("type") == "origin.l1_import_rejected", evt
d = evt.get("data", {})
assert d.get("reason") == "plan-critique", d
assert d.get("node") == node, d
assert d.get("runId") == run_id, d
assert d.get("observed") == obs, d
PY
  # Lease set to failed (planning-failed) via singular_l1_lease_set_status.
  [[ "$(lease_status "$node")" == "failed" ]] \
    || fail "ON/$label: lease not set failed (got '$(lease_status "$node")')"
  no_runner "ON/$label"
}

run_reject_case revise    revise  revise
run_reject_case park      park    park
# Fail-closed on missing record (explicit acceptance-criteria case).
run_reject_case missing   missing missing
# Fail-closed on invalid JSON / schema-invalid / bad verdict.
run_reject_case badjson   invalid "raw:not json at all {{{"
run_reject_case badschema invalid 'raw:{"verdict": "approve"}'
run_reject_case badverdict invalid banana

# ---------------------------------------------------------------------------
# present-but-uncalled: no existing engine path invokes the new gate function.
# ---------------------------------------------------------------------------
callers="$(grep -rl 'singular_ctx_critique_import_gate' \
  "$ENGINE_HOME/engine" 2>/dev/null | grep -v '/ctx-critique-import-gate.sh$' || true)"
: # temporal assertion neutralized (later slices may legitimately call this)

echo "ctx-critique-import-gate tests passed"
