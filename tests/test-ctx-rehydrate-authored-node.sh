#!/usr/bin/env bash
# Regression contracts for ctx-rehydrate-authored-node.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
CTX="$ENGINE_HOME/engine/ctx-rehydrate-authored-node.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Isolated state: never touch the real repo or its events log -------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state"

export SINGULAR_ROOT="$tmp"
export SINGULAR_STATE_DIR="$tmp/state"
export SINGULAR_EVENTS_FILE="$tmp/state/events.ndjson"
: > "$SINGULAR_EVENTS_FILE"

# shellcheck disable=SC1090
source "$LIB" || fail "sourcing lib.sh failed"

# (a) The engine file must exist and be auto-sourced by lib.sh's ctx-loader; it
#     defines the NEW function (RED before impl).
[[ -f "$CTX" ]] || fail "engine not present yet: $CTX"
[[ "$(type -t singular_ctx_rehydrate_authored_node)" == "function" ]] \
  || fail "singular_ctx_rehydrate_authored_node not defined (auto-source failed?)"

# A helper to append a raw control-state association event (as generate-tasks.sh /
# the l1 importer do): {ts,type,message,data:{taskId,node,...}} NDJSON lines. We write
# the fixture directly so the resolver's purity is measured against a fixed log.
emit_assoc() { # <type> <task_id> <node>
  printf '{"ts":"2026-07-11T00:00:00Z","type":"%s","message":"m","data":{"taskId":"%s","runId":"RUN-X","node":"%s"}}\n' \
    "$1" "$2" "$3" >> "$SINGULAR_EVENTS_FILE"
}

# ---------------------------------------------------------------------------
# (b) node resolution from a recorded (durable) task->node association.
# ---------------------------------------------------------------------------
emit_assoc "planner.staged" "TASK-0007" "rehydrate-path"
# An unrelated task/node pair must not leak into the answer.
emit_assoc "planner.staged" "TASK-0099" "some-other-node"

# Purity fingerprint of the event log + state dir before the read-only call.
events_ck_before="$(cksum < "$SINGULAR_EVENTS_FILE")"
state_fp_before="$(cd "$SINGULAR_STATE_DIR" && find . | sort | cksum)"

node_out="$(singular_ctx_rehydrate_authored_node "TASK-0007")" \
  || fail "resolver must exit 0"
[[ "$node_out" == "rehydrate-path" ]] \
  || fail "resolver must resolve the recorded node (got: '$node_out')"

# (e) determinism: identical bytes + task id -> byte-identical output.
node_out2="$(singular_ctx_rehydrate_authored_node "TASK-0007")" \
  || fail "resolver must exit 0 on repeat"
[[ "$node_out2" == "$node_out" ]] \
  || fail "resolver must be deterministic (got '$node_out2' vs '$node_out')"

# (f) Purity: no events appended, no state written by the read-only resolver.
[[ "$(cksum < "$SINGULAR_EVENTS_FILE")" == "$events_ck_before" ]] \
  || fail "resolver mutated the event log (must be read-only)"
[[ "$(cd "$SINGULAR_STATE_DIR" && find . | sort | cksum)" == "$state_fp_before" ]] \
  || fail "resolver mutated the state dir (must be read-only)"

# ---------------------------------------------------------------------------
# (d) fail-safe on absence.
# ---------------------------------------------------------------------------
# Missing association -> empty output, no crash.
miss="$(singular_ctx_rehydrate_authored_node "TASK-NONE")" \
  || fail "resolver on missing association must not crash"
[[ -z "$miss" ]] || fail "missing association must yield empty output (got: '$miss')"

# Empty task id -> empty output, no crash.
empty_tid="$(singular_ctx_rehydrate_authored_node "")" \
  || fail "resolver on empty task id must not crash"
[[ -z "$empty_tid" ]] || fail "empty task id must yield empty output (got: '$empty_tid')"

# ---------------------------------------------------------------------------
# (c) fail-safe on ambiguity: same task mapped to two DIFFERENT nodes -> empty.
# ---------------------------------------------------------------------------
emit_assoc "planner.generated" "TASK-0055" "node-alpha"
emit_assoc "planner.generated" "TASK-0055" "node-beta"
ambig="$(singular_ctx_rehydrate_authored_node "TASK-0055")" \
  || fail "resolver on ambiguous association must not crash"
[[ -z "$ambig" ]] || fail "ambiguous association must yield empty output (got: '$ambig')"

# A task mapped repeatedly to the SAME node is unambiguous -> resolves.
emit_assoc "planner.staged"    "TASK-0077" "node-gamma"
emit_assoc "planner.generated" "TASK-0077" "node-gamma"
same="$(singular_ctx_rehydrate_authored_node "TASK-0077")" \
  || fail "resolver on repeated same-node association must not crash"
[[ "$same" == "node-gamma" ]] \
  || fail "repeated same-node association must resolve (got: '$same')"

# ---------------------------------------------------------------------------
# (f) fail-soft on malformed input: bad lines skipped, never fatal.
# ---------------------------------------------------------------------------
printf 'not { valid json at all\n' >> "$SINGULAR_EVENTS_FILE"
printf '[]\n' >> "$SINGULAR_EVENTS_FILE"            # valid json, not an object
printf '{"data":"scalar"}\n' >> "$SINGULAR_EVENTS_FILE"  # data not an object
malformed="$(singular_ctx_rehydrate_authored_node "TASK-0007")" \
  || fail "resolver must not crash on malformed lines"
[[ "$malformed" == "rehydrate-path" ]] \
  || fail "malformed lines must be skipped, resolution intact (got: '$malformed')"

# Missing / empty event log -> empty output, no crash.
export SINGULAR_EVENTS_FILE="$tmp/state/no-such-events.ndjson"
noev="$(singular_ctx_rehydrate_authored_node "TASK-0007")" \
  || fail "resolver with absent event log must not crash"
[[ -z "$noev" ]] || fail "absent event log must yield empty output (got: '$noev')"
export SINGULAR_EVENTS_FILE="$tmp/state/events.ndjson"

# ---------------------------------------------------------------------------
# (a) Both expected consumer sites use the resolver. Node-dimension
#     wire-in threads it into the builder's [node] slot at BOTH live consumers —
#     the injection (engine/l1-drive.sh) and the manifest-record
#     (engine/ctx-rehydrate-event.sh). No OTHER engine path may reference it, so
#     the resolver stays a leaf primitive delegated to only from those two sites.
# ---------------------------------------------------------------------------
callers="$(grep -rl "singular_ctx_rehydrate_authored_node" "$ENGINE_HOME/engine" 2>/dev/null \
  | grep -v '/ctx-rehydrate-authored-node.sh$' \
  | sed "s#^$ENGINE_HOME/##" | sort | tr '\n' ' ' | sed 's/ $//' || true)"
[[ "$callers" == "engine/ctx-rehydrate-event.sh engine/l1-drive.sh" ]] \
  || fail "singular_ctx_rehydrate_authored_node must be wired in at exactly the two node-dimension consumer sites (l1-drive.sh, ctx-rehydrate-event.sh); referenced by: $callers"

echo "ctx-rehydrate-authored-node tests passed"
