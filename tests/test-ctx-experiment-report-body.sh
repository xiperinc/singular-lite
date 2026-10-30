#!/usr/bin/env bash
# Regression contracts for ctx-experiment-report-body.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ENGINE_HOME/engine/ctx-experiment-report-body.sh"
SIB_PIPELINE="$ENGINE_HOME/engine/ctx-experiment-pipeline.sh"
SIB_RENDER_DELTA="$ENGINE_HOME/engine/ctx-experiment-render-delta.sh"
SIB_RENDER="$ENGINE_HOME/engine/ctx-experiment-render.sh"
SIB_SUMMARY="$ENGINE_HOME/engine/ctx-experiment-summary.sh"
SIB_REPORT="$ENGINE_HOME/engine/ctx-experiment-report.sh"
SIB_STRATEGY="$ENGINE_HOME/engine/ctx-experiment-strategy.sh"
SIB_ATTEMPTS="$ENGINE_HOME/engine/ctx-experiment-attempts.sh"
SIB_ARMSTATE="$ENGINE_HOME/engine/ctx-experiment-armstate.sh"
SIB_DELTA="$ENGINE_HOME/engine/ctx-experiment-delta.sh"
SIB_ARMAUDIT="$ENGINE_HOME/engine/ctx-experiment-armaudit.sh"
REPORT_MD="$ENGINE_HOME/docs/context-build-plan/experiment-report.md"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Directory-tree fingerprint (path + content sha) to prove read-only behavior.
tree_hash() {
  local dir="$1"
  [[ -d "$dir" ]] || { echo "MISSING:$dir"; return 0; }
  find "$dir" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s ' "$f"; shasum "$f" | awk '{print $1}'
  done
}
file_hash() { shasum "$1" 2>/dev/null | awk '{print $1}'; }
report_state() { if [[ -e "$REPORT_MD" ]]; then file_hash "$REPORT_MD"; else echo "ABSENT"; fi; }

# The tool must exist and source cleanly (RED before it is written).
[[ -f "$TOOL" ]] || fail "tool not present yet: $TOOL"
# The composer DELEGATES to the two integrated corpus renderers, which delegate
# further to the summary / per-family composers, the two render capstones, and
# the armstate emitter — source the whole set so both delegation paths are live.
# shellcheck disable=SC1090
source "$SIB_REPORT"       || fail "sourcing $SIB_REPORT failed"
# shellcheck disable=SC1090
source "$SIB_STRATEGY"     || fail "sourcing $SIB_STRATEGY failed"
# shellcheck disable=SC1090
source "$SIB_ATTEMPTS"     || fail "sourcing $SIB_ATTEMPTS failed"
# shellcheck disable=SC1090
source "$SIB_SUMMARY"      || fail "sourcing $SIB_SUMMARY failed"
# shellcheck disable=SC1090
source "$SIB_RENDER"       || fail "sourcing $SIB_RENDER failed"
# shellcheck disable=SC1090
source "$SIB_ARMSTATE"     || fail "sourcing $SIB_ARMSTATE failed"
# shellcheck disable=SC1090
source "$SIB_DELTA"        || fail "sourcing $SIB_DELTA failed"
# shellcheck disable=SC1090
source "$SIB_ARMAUDIT"     || fail "sourcing $SIB_ARMAUDIT failed"
# shellcheck disable=SC1090
source "$SIB_PIPELINE"     || fail "sourcing $SIB_PIPELINE failed"
# shellcheck disable=SC1090
source "$SIB_RENDER_DELTA" || fail "sourcing $SIB_RENDER_DELTA failed"
# shellcheck disable=SC1090
source "$TOOL" || fail "sourcing $TOOL failed"
for fn in singular_ctx_experiment_report_body_compose \
          singular_ctx_experiment_report_body_md; do
  [[ "$(type -t "$fn")" == "function" ]] || fail "$fn is not defined by $TOOL"
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Input fixtures live in a dedicated read-only subtree; test outputs go to $tmp
# root, so the read-only fingerprint over $indir isolates the composer's effect.
indir="$tmp/in"
mkdir -p "$indir"

# ============================================================================
# Slice 1: the section-composition helper preserves both fragments verbatim,
# per-arm first, under stable section headers.
# ============================================================================
frag_a=$'## Per-arm demo\n\n| Arm | X |\n| --- | --- |\n| A | 1 |'
frag_b=$'## Result demo\n\n| Metric | D |\n| --- | --- |\n| escapeRate | 0 |'
composed_helper="$(singular_ctx_experiment_report_body_compose "$frag_a" "$frag_b")" \
  || fail "compose helper exited non-zero on valid fragments"
[[ -n "$composed_helper" ]] || fail "compose helper produced empty output"
# Both fragments appear verbatim as substrings.
case "$composed_helper" in *"$frag_a"*) : ;; *) fail "helper dropped/mutated the per-arm fragment" ;; esac
case "$composed_helper" in *"$frag_b"*) : ;; *) fail "helper dropped/mutated the result fragment" ;; esac
# Per-arm fragment precedes the result fragment (fixed order).
printf '%s\n' "$composed_helper" > "$tmp/helper.md"
python3 - "$tmp/helper.md" <<'PY' || fail "helper fragments not in the fixed per-arm-first order"
import sys
md = open(sys.argv[1]).read()
assert md.index("## Per-arm demo") < md.index("## Result demo"), "per-arm fragment must come first"
print("helper-order-ok")
PY
# Determinism of the helper.
composed_helper2="$(singular_ctx_experiment_report_body_compose "$frag_a" "$frag_b")"
[[ "$composed_helper" == "$composed_helper2" ]] || fail "compose helper not deterministic"

# ============================================================================
# Slice 2: composed public entry over a synthetic BOTH-ARM corpus.
# The corpus exercises the delta + audit families (arm-knob-state emitted by the
# genuine integrated emitter) and the per-arm/strategy/attempts families.
# ============================================================================
fix="$indir/corpus"
mkdir -p "$fix"
runs="$fix/runs"
events="$fix/events.ndjson"
metrics="$fix/metrics.json"

mk_index() { # runId taskId <json-attempts-array>
  local rid="$1" tid="$2" attempts="$3"
  mkdir -p "$runs/$rid/attempts"
  cat > "$runs/$rid/attempts/index.json" <<EOF
{"runId":"$rid","taskId":"$tid","attempts":$attempts}
EOF
}
# Genuine arm-knob-state.json via the integrated emitter (scrubbed env).
mk_armstate() { # runId  [KNOB=value ...]
  local rid="$1"; shift
  mkdir -p "$runs/$rid"
  (
    unset SINGULAR_CTX_PACKET SINGULAR_CTX_ROUTING SINGULAR_REHYDRATE \
          SINGULAR_PAIRED_AUDIT_PCT SINGULAR_CRITIC_RECHECK_PCT \
          SINGULAR_CTX_ARTIFACT_SCAN SINGULAR_CTX_MANIFEST
    local kv
    for kv in "$@"; do export "$kv"; done
    singular_ctx_experiment_armstate_json
  ) > "$runs/$rid/arm-knob-state.json"
}

mk_index R1 T1 '[{"n":1,"failureClass":"taint","findings":["f1","f2"]},{"n":2,"failureClass":"accepted","findings":[]}]'
mk_index R2 T2 '[{"n":1,"failureClass":"none","findings":["f1"]}]'
mk_index R3 T3 '[{"n":1,"failureClass":"window","findings":["f1","f2","f3"]},{"n":2,"failureClass":"taint","findings":[]}]'
mk_index R4 T4 '[{"n":1,"failureClass":""},{"n":2,"failureClass":"accepted","findings":["f1"]}]'
mk_armstate R1                                            # arm A, M0
mk_armstate R2 SINGULAR_CTX_PACKET=1                       # arm A, contaminated
mk_armstate R3 SINGULAR_CTX_PACKET=1 SINGULAR_CTX_ROUTING=1 # arm B, active
mk_armstate R4                                            # arm B, M0 (misconfigured)

cat > "$events" <<'EOF'
{"ts":"2026-07-12T00:00:00Z","type":"ctx.arm_assigned","data":{"taskId":"T1","arm":"A"}}
{"ts":"2026-07-12T00:00:01Z","type":"ctx.arm_assigned","data":{"taskId":"T2","arm":"A"}}
{"ts":"2026-07-12T00:00:02Z","type":"ctx.arm_assigned","data":{"taskId":"T3","arm":"B"}}
{"ts":"2026-07-12T00:00:03Z","type":"ctx.arm_assigned","data":{"taskId":"T4","arm":"B"}}
{"ts":"2026-07-12T00:00:10Z","type":"ctx.paired_audit","data":{"taskId":"T1","verdict":"accepted","findingsCount":0}}
{"ts":"2026-07-12T00:00:11Z","type":"ctx.paired_audit","data":{"taskId":"T2","verdict":"rejected","findingsCount":2}}
{"ts":"2026-07-12T00:00:12Z","type":"ctx.paired_audit","data":{"taskId":"T3","verdict":"accepted","findingsCount":0}}
{"ts":"2026-07-12T00:00:13Z","type":"ctx.paired_audit","data":{"taskId":"T4","verdict":"accepted","findingsCount":1}}
{"ts":"2026-07-12T00:00:30Z","type":"context.strategy_selected","data":{"taskId":"T1","role":"implementer","strategy":"resume","reason":""}}
{"ts":"2026-07-12T00:00:31Z","type":"context.strategy_selected","data":{"taskId":"T2","role":"reviewer","strategy":"rehydrate","reason":"stale_lease"}}
{"ts":"2026-07-12T00:00:32Z","type":"context.strategy_selected","data":{"taskId":"T3","role":"planner","strategy":"fresh","reason":"no_snapshot"}}
{"ts":"2026-07-12T00:00:33Z","type":"context.strategy_selected","data":{"taskId":"T4","role":"implementer","strategy":"fresh","reason":""}}
EOF

cat > "$metrics" <<'EOF'
{"perTask":[
  {"taskId":"T1","tokens":100,"wallClockMs":1000},
  {"taskId":"T2","tokens":200,"wallClockMs":2000},
  {"taskId":"T3","tokens":300,"wallClockMs":3000},
  {"taskId":"T4","tokens":400,"wallClockMs":4000}
]}
EOF

before="$(tree_hash "$indir")"
pl_before="$(file_hash "$SIB_PIPELINE")"
rd_before="$(file_hash "$SIB_RENDER_DELTA")"
rn_before="$(file_hash "$SIB_RENDER")"
su_before="$(file_hash "$SIB_SUMMARY")"
rp_before="$(file_hash "$SIB_REPORT")"
st_before="$(file_hash "$SIB_STRATEGY")"
at_before="$(file_hash "$SIB_ATTEMPTS")"
as_before="$(file_hash "$SIB_ARMSTATE")"
dl_before="$(file_hash "$SIB_DELTA")"
au_before="$(file_hash "$SIB_ARMAUDIT")"
report_before="$(report_state)"

# The two delegated fragments, obtained DIRECTLY from the integrated composers
# over the same resolved corpus args.
direct_pipeline="$(singular_ctx_experiment_pipeline_md "$runs" "$events" "$metrics")" \
  || fail "pipeline_md exited non-zero on the corpus"
direct_result="$(singular_ctx_experiment_render_result_md "$runs" "$events" "$metrics")" \
  || fail "render_result_md exited non-zero on the corpus"
[[ -n "$direct_pipeline" ]] || fail "pipeline_md produced empty output"
[[ -n "$direct_result" ]]   || fail "render_result_md produced empty output"

# The composed entry, threading the same corpus args.
body="$(singular_ctx_experiment_report_body_md "$runs" "$events" "$metrics")" \
  || fail "report_body_md exited non-zero on the corpus"
[[ -n "$body" ]] || fail "report_body_md produced empty output on a valid corpus"
printf '%s\n' "$body" > "$tmp/body.md"
printf '%s' "$direct_pipeline" > "$tmp/pl.txt"
printf '%s' "$direct_result" > "$tmp/rs.txt"

# byte-identical composition: the per-arm fragment (pipeline_md) and the
# treatment-effect/arm-integrity fragment (render_result_md) both appear VERBATIM
# inside the body, and every value traces to a delegated renderer.
case "$body" in
  *"$direct_pipeline"*) : ;;
  *) fail "body does not contain the pipeline_md per-arm fragment verbatim" ;;
esac
case "$body" in
  *"$direct_result"*) : ;;
  *) fail "body does not contain the render_result_md fragment verbatim" ;;
esac

# Stable order: the per-arm (pipeline) section precedes the result section.
python3 - "$tmp/body.md" "$tmp/pl.txt" "$tmp/rs.txt" <<'PY' || fail "body sections not in the stable per-arm-first order"
import sys
body = open(sys.argv[1]).read()
pl = open(sys.argv[2]).read()
rs = open(sys.argv[3]).read()
i_pl = body.index(pl)
i_rs = body.index(rs)
assert i_pl < i_rs, "per-arm (pipeline) section must precede the result section"
print("body-order-ok")
PY

# Determinism of the composed entry.
body2="$(singular_ctx_experiment_report_body_md "$runs" "$events" "$metrics")"
[[ "$body" == "$body2" ]] || fail "report_body_md not deterministic across identical runs"

# No-arg env-default delegation renders identically to the threaded-arg form.
env_body="$(SINGULAR_RUNS_DIR="$runs" SINGULAR_EVENTS_FILE="$events" \
  SINGULAR_CTX_EXPERIMENT_METRICS_FILE="$metrics" \
  singular_ctx_experiment_report_body_md)" \
  || fail "no-arg report_body_md exited non-zero (should delegate over env defaults)"
[[ "$env_body" == "$body" ]] \
  || fail "no-arg env-default body differs from threaded-arg body"

# ============================================================================
# Fail-safe: an empty / missing corpus renders a well-formed body with zeroed
# tables and a zero exit, never an error or partial output.
# ============================================================================
zero_body="$(singular_ctx_experiment_report_body_md "$tmp/no-runs" "$tmp/no-events.ndjson" "$tmp/no-metrics.json")" \
  || fail "report_body_md non-zero on a missing corpus (should fail safe)"
[[ -n "$zero_body" ]] || fail "missing-corpus body produced empty output (not well-formed)"
# The zeroed body is byte-identical to composing the two delegated zeroed
# fragments — every value still traces to a delegated renderer.
zero_pipeline="$(singular_ctx_experiment_pipeline_md "$tmp/no-runs" "$tmp/no-events.ndjson" "$tmp/no-metrics.json")"
zero_result="$(singular_ctx_experiment_render_result_md "$tmp/no-runs" "$tmp/no-events.ndjson" "$tmp/no-metrics.json")"
expect_zero_body="$(singular_ctx_experiment_report_body_compose "$zero_pipeline" "$zero_result")"
[[ "$zero_body" == "$expect_zero_body" ]] \
  || fail "missing-corpus body is not the composition of the two delegated zeroed fragments"
printf '%s\n' "$zero_body" > "$tmp/zero.md"
python3 - "$tmp/zero.md" <<'PY' || fail "missing-corpus body is not a well-formed zero fragment"
import sys
md = open(sys.argv[1]).read()
# The delegated result composer yields zeroed arm rows for A and B and 8 zeroed
# delta rows — a well-formed body with zeroed tables, not an error/partial.
assert "| A | 0 | 0 | 0 | 0 |" in md, "arm A zero row missing"
assert "| B | 0 | 0 | 0 | 0 |" in md, "arm B zero row missing"
assert md.count("| 0 | equal |") >= 8, "expected 8 zeroed delta rows with equal direction"
# Well-formed markdown tables (separator rows present).
assert "| --- |" in md, "no markdown table separators in the zeroed body"
print("fail-safe-ok")
PY

# ============================================================================
# STDOUT ONLY / read-only: fixture tree + composed sibling renderers (and their
# delegates) byte-unchanged; no experiment-report.md created or mutated.
# ============================================================================
after="$(tree_hash "$indir")"
[[ "$before" == "$after" ]] || fail "input fixture tree mutated (composer is not read-only vs its inputs)"
[[ "$pl_before" == "$(file_hash "$SIB_PIPELINE")" ]]     || fail "engine/ctx-experiment-pipeline.sh was mutated"
[[ "$rd_before" == "$(file_hash "$SIB_RENDER_DELTA")" ]] || fail "engine/ctx-experiment-render-delta.sh was mutated"
[[ "$rn_before" == "$(file_hash "$SIB_RENDER")" ]]       || fail "engine/ctx-experiment-render.sh was mutated"
[[ "$su_before" == "$(file_hash "$SIB_SUMMARY")" ]]      || fail "engine/ctx-experiment-summary.sh was mutated"
[[ "$rp_before" == "$(file_hash "$SIB_REPORT")" ]]       || fail "engine/ctx-experiment-report.sh was mutated"
[[ "$st_before" == "$(file_hash "$SIB_STRATEGY")" ]]     || fail "engine/ctx-experiment-strategy.sh was mutated"
[[ "$at_before" == "$(file_hash "$SIB_ATTEMPTS")" ]]     || fail "engine/ctx-experiment-attempts.sh was mutated"
[[ "$as_before" == "$(file_hash "$SIB_ARMSTATE")" ]]     || fail "engine/ctx-experiment-armstate.sh was mutated"
[[ "$dl_before" == "$(file_hash "$SIB_DELTA")" ]]        || fail "engine/ctx-experiment-delta.sh was mutated"
[[ "$au_before" == "$(file_hash "$SIB_ARMAUDIT")" ]]     || fail "engine/ctx-experiment-armaudit.sh was mutated"
[[ "$report_before" == "$(report_state)" ]] \
  || fail "composer created or mutated docs/context-build-plan/experiment-report.md (must not)"

echo "ctx-experiment-report-body tests passed"
