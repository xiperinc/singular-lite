#!/usr/bin/env bash
# Regression contracts for ctx-critic-recheck-locate.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
CTX="$ENGINE_HOME/engine/ctx-critic-recheck-locate.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Isolated state: never touch the real repo or its events log -------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state"

export SINGULAR_ROOT="$tmp"
export SINGULAR_STATE_DIR="$tmp/state"
export SINGULAR_EVENTS_FILE="$tmp/state/events.ndjson"
export SINGULAR_RUNS_DIR="$tmp/state/runs"
: > "$SINGULAR_EVENTS_FILE"

# shellcheck disable=SC1090
source "$LIB" || fail "sourcing lib.sh failed"

# (a) The engine file must exist and be auto-sourced by lib.sh's ctx-loader; it
#     defines the two NEW functions (RED before impl).
[[ -f "$CTX" ]] || fail "engine not present yet: $CTX"
[[ "$(type -t singular_ctx_critic_recheck_locate_node)" == "function" ]] \
  || fail "singular_ctx_critic_recheck_locate_node not defined (auto-source failed?)"
[[ "$(type -t singular_ctx_critic_recheck_locate_record)" == "function" ]] \
  || fail "singular_ctx_critic_recheck_locate_record not defined (auto-source failed?)"

# A sentinel runner: if any locator ever spawns a runner, this file appears.
SENTINEL="$tmp/runner-invoked"
STUB="$tmp/stub-runner.sh"
cat > "$STUB" <<STUBEOF
#!/usr/bin/env bash
touch "$SENTINEL"
exit 0
STUBEOF
chmod +x "$STUB"
export SINGULAR_RUNNER="$STUB"

# A helper to append a raw control-state association event (as generate-tasks.sh /
# the l1 importer do): {ts,type,message,data:{taskId,node,...}} NDJSON lines. We write
# the fixture directly (not via singular_append_event) so the locator's own purity can
# be measured against a fixed pre-populated log.
emit_assoc() { # <type> <task_id> <node>
  printf '{"ts":"2026-07-11T00:00:00Z","type":"%s","message":"m","data":{"taskId":"%s","runId":"RUN-X","node":"%s"}}\n' \
    "$1" "$2" "$3" >> "$SINGULAR_EVENTS_FILE"
}

# ---------------------------------------------------------------------------
# (b) node resolution from a recorded (durable) task->node association.
# ---------------------------------------------------------------------------
emit_assoc "planner.staged" "TASK-0007" "critic-carryover"
# An unrelated task/node pair must not leak into the answer.
emit_assoc "planner.staged" "TASK-0099" "some-other-node"

# Purity fingerprint of the event log + state dir before the read-only call.
events_ck_before="$(cksum < "$SINGULAR_EVENTS_FILE")"
state_fp_before="$(cd "$SINGULAR_STATE_DIR" && find . | sort | cksum)"

node_out="$(singular_ctx_critic_recheck_locate_node "TASK-0007")" \
  || fail "locate_node must exit 0"
[[ "$node_out" == "critic-carryover" ]] \
  || fail "locate_node must resolve the recorded node (got: '$node_out')"

# Purity: no events appended, no state written by the read-only locator.
[[ "$(cksum < "$SINGULAR_EVENTS_FILE")" == "$events_ck_before" ]] \
  || fail "locate_node mutated the event log (must be read-only)"
[[ "$(cd "$SINGULAR_STATE_DIR" && find . | sort | cksum)" == "$state_fp_before" ]] \
  || fail "locate_node mutated the state dir (must be read-only)"
[[ ! -e "$SENTINEL" ]] || fail "locate_node spawned a runner"

# Missing association -> empty output, no crash.
miss="$(singular_ctx_critic_recheck_locate_node "TASK-NONE")" \
  || fail "locate_node on missing association must not crash"
[[ -z "$miss" ]] || fail "missing association must yield empty output (got: '$miss')"

# Empty task id -> empty output, no crash.
empty_tid="$(singular_ctx_critic_recheck_locate_node "")" \
  || fail "locate_node on empty task id must not crash"
[[ -z "$empty_tid" ]] || fail "empty task id must yield empty output (got: '$empty_tid')"

# Ambiguous association (same task mapped to two DIFFERENT nodes) -> empty output.
emit_assoc "planner.generated" "TASK-0055" "node-alpha"
emit_assoc "planner.generated" "TASK-0055" "node-beta"
ambig="$(singular_ctx_critic_recheck_locate_node "TASK-0055")" \
  || fail "locate_node on ambiguous association must not crash"
[[ -z "$ambig" ]] || fail "ambiguous association must yield empty output (got: '$ambig')"

# A task mapped repeatedly to the SAME node is unambiguous -> resolves.
emit_assoc "planner.staged"    "TASK-0077" "node-gamma"
emit_assoc "planner.generated" "TASK-0077" "node-gamma"
same="$(singular_ctx_critic_recheck_locate_node "TASK-0077")" \
  || fail "locate_node on repeated same-node association must not crash"
[[ "$same" == "node-gamma" ]] \
  || fail "repeated same-node association must resolve (got: '$same')"

# Missing / empty event log -> empty output, no crash.
export SINGULAR_EVENTS_FILE="$tmp/state/no-such-events.ndjson"
noev="$(singular_ctx_critic_recheck_locate_node "TASK-0007")" \
  || fail "locate_node with absent event log must not crash"
[[ -z "$noev" ]] || fail "absent event log must yield empty output (got: '$noev')"
export SINGULAR_EVENTS_FILE="$tmp/state/events.ndjson"

# ---------------------------------------------------------------------------
# (c) record resolution: durable per-node convention + stage-dir convention.
# ---------------------------------------------------------------------------
NODE="critic-carryover"

valid_record() { # <path> <node> <task_in_batch>
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<JSON
{
  "schema": "singular.orchestration.plan-critique.v0",
  "node": "$2",
  "runId": "RUN-CRIT",
  "batchTaskIds": ["$3"],
  "verdict": "revise",
  "findings": [],
  "assumptionsChallenged": [],
  "rationale": "test critique"
}
JSON
}

# --- Durable per-node convention: $SINGULAR_STATE_DIR/critique/<node>/plan-critique.json
durable="$SINGULAR_STATE_DIR/critique/$NODE/plan-critique.json"
valid_record "$durable" "$NODE" "TASK-0007"

events_ck_before="$(cksum < "$SINGULAR_EVENTS_FILE")"
rec_ck_before="$(cksum < "$durable")"

rec_out="$(singular_ctx_critic_recheck_locate_record "$NODE" "TASK-0007")" \
  || fail "locate_record must exit 0"
[[ "$rec_out" == "$durable" ]] \
  || fail "locate_record must resolve the durable per-node record (got: '$rec_out')"

# Purity: no events appended, record not mutated, no runner.
[[ "$(cksum < "$SINGULAR_EVENTS_FILE")" == "$events_ck_before" ]] \
  || fail "locate_record mutated the event log (must be read-only)"
[[ "$(cksum < "$durable")" == "$rec_ck_before" ]] \
  || fail "locate_record mutated the prior record (must be read-only)"
[[ ! -e "$SENTINEL" ]] || fail "locate_record spawned a runner"

# --- Stage-dir convention: $SINGULAR_RUNS_DIR/<run>/l1-staging/<node>/plan-critique.json
rm -rf "$SINGULAR_STATE_DIR/critique"   # remove the durable copy; only stage-dir remains
staged="$SINGULAR_RUNS_DIR/RUN-STAGE/l1-staging/$NODE/plan-critique.json"
valid_record "$staged" "$NODE" "TASK-0007"
stage_out="$(singular_ctx_critic_recheck_locate_record "$NODE" "TASK-0007")" \
  || fail "locate_record via stage-dir must exit 0"
[[ "$stage_out" == "$staged" ]] \
  || fail "locate_record must resolve the stage-dir record (got: '$stage_out')"

# ---------------------------------------------------------------------------
# (d) fail-safe: missing / unparseable / wrong-schema / node-mismatch -> empty.
# ---------------------------------------------------------------------------
rm -rf "$SINGULAR_RUNS_DIR" "$SINGULAR_STATE_DIR/critique"

# Missing record entirely.
missrec="$(singular_ctx_critic_recheck_locate_record "$NODE" "TASK-0007")" \
  || fail "locate_record on missing record must not crash"
[[ -z "$missrec" ]] || fail "missing record must yield empty output (got: '$missrec')"

# Empty node -> empty.
emptynode="$(singular_ctx_critic_recheck_locate_record "" "TASK-0007")" \
  || fail "locate_record on empty node must not crash"
[[ -z "$emptynode" ]] || fail "empty node must yield empty output (got: '$emptynode')"

# Unparseable record at the durable path -> empty (never a crash).
mkdir -p "$SINGULAR_STATE_DIR/critique/$NODE"
printf 'not { valid json\n' > "$durable"
badrec="$(singular_ctx_critic_recheck_locate_record "$NODE" "TASK-0007")" \
  || fail "locate_record on unparseable record must not crash"
[[ -z "$badrec" ]] || fail "unparseable record must yield empty output (got: '$badrec')"

# Wrong-schema record -> empty (never a fabricated path).
cat > "$durable" <<'JSON'
{ "schema": "singular.orchestration.state-packet.v0", "node": "critic-carryover" }
JSON
wrongschema="$(singular_ctx_critic_recheck_locate_record "$NODE" "TASK-0007")" \
  || fail "locate_record on wrong-schema record must not crash"
[[ -z "$wrongschema" ]] || fail "wrong-schema record must yield empty output (got: '$wrongschema')"

# Node-mismatch record (right schema, wrong node) -> empty (fail closed).
valid_record "$durable" "some-other-node" "TASK-0007"
nodemismatch="$(singular_ctx_critic_recheck_locate_record "$NODE" "TASK-0007")" \
  || fail "locate_record on node-mismatch record must not crash"
[[ -z "$nodemismatch" ]] || fail "node-mismatch record must yield empty output (got: '$nodemismatch')"

# Wrong-batch record (right node+schema, task NOT in batch) -> empty (fail closed).
valid_record "$durable" "$NODE" "TASK-9999"
wrongbatch="$(singular_ctx_critic_recheck_locate_record "$NODE" "TASK-0007")" \
  || fail "locate_record on wrong-batch record must not crash"
[[ -z "$wrongbatch" ]] || fail "wrong-batch record must yield empty output (got: '$wrongbatch')"

# ...but with an empty task id (node-only resolution), a node-matching record resolves.
nodeonly="$(singular_ctx_critic_recheck_locate_record "$NODE" "")" \
  || fail "locate_record node-only must not crash"
[[ "$nodeonly" == "$durable" ]] \
  || fail "node-only resolution must accept a node-matching record (got: '$nodeonly')"

# Final purity sweep: neither locator ever appended an event to the pinned log.
[[ ! -s "$SINGULAR_EVENTS_FILE" || -n "$(head -c1 "$SINGULAR_EVENTS_FILE")" ]] || true
# The only lines in the events log are our fixture associations (no locator appended).
appended="$(grep -c '"type":"context' "$SINGULAR_EVENTS_FILE" 2>/dev/null || true)"
appended="${appended:-0}"
[[ "$appended" == "0" ]] || fail "a locator appended a context event (must be read-only)"

# ---------------------------------------------------------------------------
# (a) present-but-uncalled: no existing engine path invokes the new functions.
# ---------------------------------------------------------------------------
for fn in singular_ctx_critic_recheck_locate_node singular_ctx_critic_recheck_locate_record; do
  callers="$(grep -rl "$fn" "$ENGINE_HOME/engine" 2>/dev/null \
    | grep -v '/ctx-critic-recheck-locate.sh$' || true)"
  [[ -z "$callers" ]] || fail "$fn must be present-but-uncalled; referenced by: $callers"
done

echo "ctx-critic-recheck-locate tests passed"
