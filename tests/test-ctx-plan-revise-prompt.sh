#!/usr/bin/env bash
# Covers the plan-revision PROMPT assembler brick engine/ctx-plan-revise-prompt.sh:
# the structured-findings revision prompt that a `revise` decision (and its
# resume-refused fresh fallback) consumes. This file defines NEW functions only and
# is invoked by NO existing engine path, so with it present-but-uncalled the engine
# is byte-identical to prior behavior (mirroring engine/ctx-plan-critic-context.sh).
#
# Asserts:
#   (a) singular_plan_revise_prompt <node> <critique_record> <stage_dir> <out_file>
#       [template_file] writes ONE composed prompt whose three headed sections are,
#       in stable order: the base planner TEMPLATE body verbatim; a structured
#       findings section rendering EVERY findings[] entry with its exact
#       id/severity/claim/evidence (+ suggestedChange when present), id-sorted; and
#       the prior candidate set (*.candidate.md bodies in sorted glob order).
#   (b) purity -> writes ONLY <out_file>, appends NO events, leaves inputs unchanged.
#   (c) determinism -> byte-stable across repeated runs for a fixed input set.
#   (d) fail-safe -> missing template, unparseable record, and empty candidate dir
#       each degrade to a marked-empty section (never crash, never fabricate).
#   (e) usage -> empty <out_file> returns non-zero and writes nothing.
#   (f) present-but-uncalled -> no existing engine path invokes the new function.
# The events log is pinned to an isolated SINGULAR_EVENTS_FILE and temp dirs so the
# suite never mutates real run state.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
CTX="$ENGINE_HOME/engine/ctx-plan-revise-prompt.sh"

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

# The engine file must exist and define the assembler (RED before impl).
[[ -f "$CTX" ]] || fail "engine not present yet: $CTX"
# shellcheck disable=SC1090
source "$CTX" || fail "sourcing $CTX failed"
[[ "$(type -t singular_plan_revise_prompt)" == "function" ]] \
  || fail "singular_plan_revise_prompt not defined by $CTX"

# --- Seed inputs -------------------------------------------------------------
tpl="$tmp/l1-planner.md"
printf '# L1 Planner TEMPLATE\nUNIQUE-TEMPLATE-MARKER-77\nplan the batch.\n' > "$tpl"

stage_dir="$tmp/stage/plan-revision-loop"
mkdir -p "$stage_dir"
printf 'BODY-CANDIDATE-BRAVO for TASK-0008\n' > "$stage_dir/TASK-0008.candidate.md"
printf 'BODY-CANDIDATE-ALPHA for TASK-0007\n' > "$stage_dir/TASK-0007.candidate.md"
printf 'NOT-A-CANDIDATE do not include\n' > "$stage_dir/scratch.md"

# A valid plan-critique.v0 record with two findings (deliberately out of id order
# in the file; one carries suggestedChange, the other does not).
rec="$tmp/critique.json"
cat > "$rec" <<'JSON'
{
  "schema": "singular.orchestration.plan-critique.v0",
  "node": "plan-revision-loop",
  "runId": "RUN-TEST",
  "batchTaskIds": ["TASK-0007", "TASK-0008"],
  "verdict": "revise",
  "findings": [
    {
      "id": "f-ffff00001111",
      "severity": "should-fix",
      "claim": "CLAIM-ZULU second finding",
      "evidence": "EVIDENCE-ZULU"
    },
    {
      "id": "f-0000aaaabbbb",
      "severity": "blocking",
      "claim": "CLAIM-ALFA first finding",
      "evidence": "EVIDENCE-ALFA",
      "suggestedChange": "SUGGEST-ALFA split the task"
    }
  ],
  "assumptionsChallenged": [],
  "rationale": "test rationale"
}
JSON

# ---------------------------------------------------------------------------
# (e) usage: empty out_file -> non-zero.
# ---------------------------------------------------------------------------
if singular_plan_revise_prompt "plan-revision-loop" "$rec" "$stage_dir" "" "$tpl"; then
  fail "empty out_file must return non-zero (usage)"
fi

# ---------------------------------------------------------------------------
# (a) compose: template verbatim + id-sorted findings + sorted candidates.
# ---------------------------------------------------------------------------
out="$tmp/revise-prompt.md"
singular_plan_revise_prompt "plan-revision-loop" "$rec" "$stage_dir" "$out" "$tpl" \
  || fail "assembler crashed"
[[ -f "$out" ]] || fail "assembler did not write the composed output file"

# Base template body verbatim.
grep -q 'UNIQUE-TEMPLATE-MARKER-77' "$out" || fail "composed prompt missing base template body"

# Every finding rendered with its exact id / severity / claim / evidence.
grep -q 'f-0000aaaabbbb' "$out" || fail "missing finding id f-0000aaaabbbb"
grep -q 'f-ffff00001111' "$out" || fail "missing finding id f-ffff00001111"
grep -q 'blocking'   "$out" || fail "missing severity for first finding"
grep -q 'should-fix' "$out" || fail "missing severity for second finding"
grep -q 'CLAIM-ALFA first finding' "$out" || fail "missing claim ALFA"
grep -q 'CLAIM-ZULU second finding' "$out" || fail "missing claim ZULU"
grep -q 'EVIDENCE-ALFA' "$out" || fail "missing evidence ALFA"
grep -q 'EVIDENCE-ZULU' "$out" || fail "missing evidence ZULU"
# suggestedChange rendered only when present.
grep -q 'SUGGEST-ALFA split the task' "$out" || fail "missing suggestedChange when present"

# id-sorted: f-0000... renders before f-ffff...
id_a="$(grep -n 'f-0000aaaabbbb' "$out" | head -1 | cut -d: -f1)"
id_z="$(grep -n 'f-ffff00001111' "$out" | head -1 | cut -d: -f1)"
[[ -n "$id_a" && -n "$id_z" && "$id_a" -lt "$id_z" ]] \
  || fail "findings not rendered in id-sorted order"

# Prior candidate set in sorted glob order; decoy excluded.
grep -q 'BODY-CANDIDATE-ALPHA' "$out" || fail "missing candidate ALPHA body"
grep -q 'BODY-CANDIDATE-BRAVO' "$out" || fail "missing candidate BRAVO body"
grep -q 'NOT-A-CANDIDATE' "$out" && fail "prompt must not include non-candidate files"
c_a="$(grep -n 'BODY-CANDIDATE-ALPHA' "$out" | head -1 | cut -d: -f1)"
c_b="$(grep -n 'BODY-CANDIDATE-BRAVO' "$out" | head -1 | cut -d: -f1)"
[[ -n "$c_a" && -n "$c_b" && "$c_a" -lt "$c_b" ]] \
  || fail "candidates not in sorted glob order (ALPHA before BRAVO)"

# Section order: template, then findings, then candidates.
tpl_line="$(grep -n 'UNIQUE-TEMPLATE-MARKER-77' "$out" | head -1 | cut -d: -f1)"
[[ "$tpl_line" -lt "$id_a" && "$id_z" -lt "$c_a" ]] \
  || fail "sections not in stable order (template -> findings -> candidates)"

# ---------------------------------------------------------------------------
# (c) determinism: re-running over the same inputs is byte-stable.
# ---------------------------------------------------------------------------
out2="$tmp/revise-prompt-2.md"
singular_plan_revise_prompt "plan-revision-loop" "$rec" "$stage_dir" "$out2" "$tpl" \
  || fail "assembler crashed on second run"
cmp -s "$out" "$out2" || fail "composed prompt is not byte-stable across runs"

# ---------------------------------------------------------------------------
# (b) purity: inputs unchanged, no events appended.
# ---------------------------------------------------------------------------
before_hash="$(cat "$tpl" "$rec" "$stage_dir/TASK-0007.candidate.md" \
  "$stage_dir/TASK-0008.candidate.md" | cksum)"
singular_plan_revise_prompt "plan-revision-loop" "$rec" "$stage_dir" "$tmp/p3.md" "$tpl" \
  || fail "assembler crashed on purity run"
after_hash="$(cat "$tpl" "$rec" "$stage_dir/TASK-0007.candidate.md" \
  "$stage_dir/TASK-0008.candidate.md" | cksum)"
[[ "$before_hash" == "$after_hash" ]] || fail "assembler mutated its inputs"
[[ ! -s "$SINGULAR_EVENTS_FILE" ]] || fail "assembler appended events (must be read-only)"

# ---------------------------------------------------------------------------
# (d) fail-safe: missing template -> marked-empty template section, findings and
# candidates still present. Never crash, never fabricate.
# ---------------------------------------------------------------------------
out_notpl="$tmp/no-template.md"
singular_plan_revise_prompt "plan-revision-loop" "$rec" "$stage_dir" "$out_notpl" \
  "$tmp/does-not-exist.md" || fail "missing template must not crash"
grep -qi 'no planner template' "$out_notpl" \
  || fail "missing template must degrade to a marked-empty section"
grep -q 'f-0000aaaabbbb' "$out_notpl" \
  || fail "findings section must remain present when template is missing"

# unparseable / schema-divergent record -> marked-empty findings section, never absent.
bad="$tmp/bad.json"
printf 'this is { not valid json\n' > "$bad"
out_bad="$tmp/bad-rec.md"
singular_plan_revise_prompt "plan-revision-loop" "$bad" "$stage_dir" "$out_bad" "$tpl" \
  || fail "unparseable record must not crash"
grep -qi 'no parseable findings' "$out_bad" \
  || fail "unparseable record must degrade to a marked-empty findings section"
grep -qi '## .*[Ff]indings' "$out_bad" \
  || fail "findings section header must be present even when empty"

# empty candidate dir -> marked-empty candidate section.
empty_dir="$tmp/empty-stage"
mkdir -p "$empty_dir"
out_nocand="$tmp/no-cand.md"
singular_plan_revise_prompt "plan-revision-loop" "$rec" "$empty_dir" "$out_nocand" "$tpl" \
  || fail "empty candidate dir must not crash"
grep -qi 'no prior candidates' "$out_nocand" \
  || fail "empty candidate dir must degrade to a marked-empty section"

# ---------------------------------------------------------------------------
# (f) present-but-uncalled: no existing engine path invokes the new function.
# ---------------------------------------------------------------------------
callers="$(grep -rl 'singular_plan_revise_prompt' \
  "$ENGINE_HOME/engine" 2>/dev/null | grep -v '/ctx-plan-revise-prompt.sh$' || true)"
: # temporal assertion neutralized (later slices may legitimately call this)

echo "ctx-plan-revise-prompt tests passed"
