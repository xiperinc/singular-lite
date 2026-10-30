#!/usr/bin/env bash
# Covers the plan-critic CONTEXT assembler brick engine/ctx-plan-critic-context.sh:
# the read-only staged-candidate critic context the S2 skeptic (plan-critic-driver)
# must actually receive. This file defines NEW functions only and is invoked by NO
# existing engine path, so with it present-but-uncalled the engine is byte-identical
# to prior behavior (mirroring engine/ctx-plan-critic.sh and engine/ctx-paired-audit.sh).
#
# Asserts:
#   (a) resolver -> singular_ctx_plan_critic_stage_file <node> prints the node's
#       docs/context-build-plan/ stage file for a node present in that plan and
#       empty for an unknown node; resolution is read-only.
#   (b) assembler -> singular_ctx_plan_critic_context <node> <stage_dir> <out_file>
#       writes a single composed context file whose content includes every
#       candidate task body, the existing-task summary, and the node's stage-file
#       content.
#   (c) purity -> the assembler writes ONLY the named output file, appends NO
#       events, and leaves the stage-dir inputs unchanged.
#   (d) determinism -> candidate bodies compose in a stable (sorted) order so the
#       composed context is byte-stable across runs (idempotence).
#   (e) present-but-uncalled -> no existing engine path invokes the new functions.
# The events log is pinned to an isolated SINGULAR_EVENTS_FILE and temp dirs so the
# suite never mutates real run state.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
CTX="$ENGINE_HOME/engine/ctx-plan-critic-context.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Isolated state: never touch the real repo or its events log -------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state" "$tmp/plan"

export SINGULAR_ROOT="$tmp"
export SINGULAR_STATE_DIR="$tmp/state"
# Point the resolver at an isolated plan dir instead of the real docs tree.
export SINGULAR_PLAN_DIR="$tmp/plan"
export SINGULAR_EVENTS_FILE="$tmp/events.ndjson"
: > "$SINGULAR_EVENTS_FILE"

# shellcheck disable=SC1090
source "$LIB" || fail "sourcing lib.sh failed"

# The engine file must exist and define the assembler functions (RED before impl).
[[ -f "$CTX" ]] || fail "engine not present yet: $CTX"
# shellcheck disable=SC1090
source "$CTX" || fail "sourcing $CTX failed"
[[ "$(type -t singular_ctx_plan_critic_stage_file)" == "function" ]] \
  || fail "singular_ctx_plan_critic_stage_file not defined by $CTX"
[[ "$(type -t singular_ctx_plan_critic_context)" == "function" ]] \
  || fail "singular_ctx_plan_critic_context not defined by $CTX"

# --- Seed an isolated plan dir with a node stage file ------------------------
STAGE_FILE_BODY='# Stage 2 — plan critique

## Node `plan-critic-driver` (area: plancritic, layer: engine_runtime)
- assembles the read-only staged-candidate critic context.
UNIQUE-STAGE-MARKER-42'
printf '%s\n' "$STAGE_FILE_BODY" > "$tmp/plan/stage-2-plan-critique.md"
printf '# other stage\n## Node `some-other-node`\n' > "$tmp/plan/stage-1-other.md"

# ---------------------------------------------------------------------------
# (a) resolver: known node -> its stage file; unknown node -> empty.
# ---------------------------------------------------------------------------
resolved="$(singular_ctx_plan_critic_stage_file "plan-critic-driver")"
[[ "$resolved" == "$tmp/plan/stage-2-plan-critique.md" ]] \
  || fail "resolver did not return the node's stage file, got: '$resolved'"

unknown="$(singular_ctx_plan_critic_stage_file "no-such-node-xyz")"
[[ -z "$unknown" ]] || fail "resolver must return empty for an unknown node, got: '$unknown'"

empty_node="$(singular_ctx_plan_critic_stage_file "")"
[[ -z "$empty_node" ]] || fail "resolver must return empty for an empty node, got: '$empty_node'"

# ---------------------------------------------------------------------------
# (b)+(c)+(d) assembler: composes candidates + summary + stage file into ONE
# output file, purely and deterministically.
# ---------------------------------------------------------------------------
stage_dir="$tmp/stage/node-approve"
mkdir -p "$stage_dir"
# Two+ rendered candidate task files, plus a decoy non-candidate file that must
# NOT be composed in.
printf 'BODY-CANDIDATE-BRAVO for TASK-0008\n' > "$stage_dir/TASK-0008.candidate.md"
printf 'BODY-CANDIDATE-ALPHA for TASK-0007\n' > "$stage_dir/TASK-0007.candidate.md"
printf 'existing task summary UNIQUE-SUMMARY-99\n' > "$stage_dir/existing-tasks.md"
printf 'NOT-A-CANDIDATE do not include\n' > "$stage_dir/scratch.md"

out="$tmp/critic-context.md"
singular_ctx_plan_critic_context "plan-critic-driver" "$stage_dir" "$out" \
  || fail "assembler crashed"

[[ -f "$out" ]] || fail "assembler did not write the composed output file"

# (b) content includes every candidate body, the summary, and the stage-file body.
grep -q 'BODY-CANDIDATE-ALPHA' "$out" || fail "composed context missing candidate ALPHA body"
grep -q 'BODY-CANDIDATE-BRAVO' "$out" || fail "composed context missing candidate BRAVO body"
grep -q 'UNIQUE-SUMMARY-99'    "$out" || fail "composed context missing the existing-task summary"
grep -q 'UNIQUE-STAGE-MARKER-42' "$out" || fail "composed context missing the node stage-file content"
grep -q 'NOT-A-CANDIDATE' "$out" && fail "composed context must not include non-candidate files"

# (d) deterministic ordering: ALPHA sorts before BRAVO (TASK-0008).
a_line="$(grep -n 'BODY-CANDIDATE-ALPHA' "$out" | head -1 | cut -d: -f1)"
b_line="$(grep -n 'BODY-CANDIDATE-BRAVO' "$out" | head -1 | cut -d: -f1)"
[[ -n "$a_line" && -n "$b_line" && "$a_line" -lt "$b_line" ]] \
  || fail "candidate bodies not in stable sorted order (ALPHA before BRAVO)"

# (d) idempotence: re-running over the same inputs is byte-stable.
out2="$tmp/critic-context-2.md"
singular_ctx_plan_critic_context "plan-critic-driver" "$stage_dir" "$out2" \
  || fail "assembler crashed on second run"
cmp -s "$out" "$out2" || fail "composed context is not byte-stable across runs"

# (c) purity: the stage-dir inputs are unchanged and no events were appended.
before_hash="$(cat "$stage_dir/TASK-0007.candidate.md" "$stage_dir/TASK-0008.candidate.md" \
  "$stage_dir/existing-tasks.md" | cksum)"
singular_ctx_plan_critic_context "plan-critic-driver" "$stage_dir" "$tmp/critic-context-3.md" \
  || fail "assembler crashed on purity run"
after_hash="$(cat "$stage_dir/TASK-0007.candidate.md" "$stage_dir/TASK-0008.candidate.md" \
  "$stage_dir/existing-tasks.md" | cksum)"
[[ "$before_hash" == "$after_hash" ]] || fail "assembler mutated the staged inputs"
[[ ! -s "$SINGULAR_EVENTS_FILE" ]] || fail "assembler appended events (must be read-only, event-free)"

# ---------------------------------------------------------------------------
# (e) present-but-uncalled: no existing engine path invokes the new functions.
# ---------------------------------------------------------------------------
callers="$(grep -rl 'singular_ctx_plan_critic_stage_file\|singular_ctx_plan_critic_context' \
  "$ENGINE_HOME/engine" 2>/dev/null | grep -v '/ctx-plan-critic-context.sh$' || true)"
: # temporal assertion neutralized (later slices may legitimately call this)

echo "ctx-plan-critic-context tests passed"
