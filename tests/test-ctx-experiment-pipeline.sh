#!/usr/bin/env bash
# End-to-end requiredCompletion guard for the composed experiment PIPELINE entry
# engine/ctx-experiment-pipeline.sh. This brick ships NO metric of its own: it is
# the single explicit-corpus operator entry that threads raw runs/events/metrics
# through singular_ctx_experiment_summary_json to build the raw-metrics bundle and
# renders it through singular_ctx_experiment_render_md (fed the in-memory bundle,
# no file written) to the full report-metrics markdown tables.
#
# The five per-family bricks are each unit-tested in isolation, but NO existing
# test walks a live runs/events corpus through the WHOLE pipeline to the rendered
# report tables. This guard closes that gap: it constructs a synthetic BOTH-ARM
# corpus exercising every metric family and drives
# singular_ctx_experiment_pipeline_md over it, asserting the whole walk at once.
#
# Guarantees pinned BEHAVIORALLY over the corpus (no absence greps):
#   - whole walk: from raw ctx.arm_assigned / ctx.paired_audit / ctx.critic_recheck
#     / context.strategy_selected / context.resume_failed events + attempts indexes
#     the rendered tables carry the expected per-arm escape-rate, cost,
#     attempts-to-accept, findings-per-attempt, bias, and resume/rehydrate
#     hit-rate + gate-refusal reason-mix values for arms A and B.
#   - loss-preserving delegation: the emitted markdown is byte-identical to feeding
#     the SAME corpus through singular_ctx_experiment_summary_json and
#     singular_ctx_experiment_render_md directly (no recomputation).
#   - deterministic: byte-identical across repeated runs on the same corpus.
#   - evidence invariance / advocate-skeptic line: a context-aware
#     ctx.critic_recheck disposition of "addressed" NEVER removes a fresh
#     ctx.paired_audit escape flag from the rendered escape counts.
#   - fail-safe: an empty corpus (no runs, empty events) yields well-formed zeroed
#     tables and a zero exit, never an error or partial output.
#   - strictly read-only: the corpus tree is byte-identical after every call (no
#     run artifact / index / event / lease / task file created, moved, or mutated;
#     no docs/context-build-plan/experiment-report.md), and the five sibling
#     ctx-experiment-*.sh files plus engine/ctx-metrics.sh are byte-unchanged.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ENGINE_HOME/engine/ctx-experiment-pipeline.sh"
SIB_METRICS="$ENGINE_HOME/engine/ctx-metrics.sh"
SIB_REPORT="$ENGINE_HOME/engine/ctx-experiment-report.sh"
SIB_STRATEGY="$ENGINE_HOME/engine/ctx-experiment-strategy.sh"
SIB_ATTEMPTS="$ENGINE_HOME/engine/ctx-experiment-attempts.sh"
SIB_SUMMARY="$ENGINE_HOME/engine/ctx-experiment-summary.sh"
SIB_RENDER="$ENGINE_HOME/engine/ctx-experiment-render.sh"
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
# The pipeline DELEGATES the full chain: summary (which itself delegates to the
# three per-family composers) then render. Source them all so the walk is live.
# shellcheck disable=SC1090
source "$SIB_REPORT"   || fail "sourcing $SIB_REPORT failed"
# shellcheck disable=SC1090
source "$SIB_STRATEGY" || fail "sourcing $SIB_STRATEGY failed"
# shellcheck disable=SC1090
source "$SIB_ATTEMPTS" || fail "sourcing $SIB_ATTEMPTS failed"
# shellcheck disable=SC1090
source "$SIB_SUMMARY"  || fail "sourcing $SIB_SUMMARY failed"
# shellcheck disable=SC1090
source "$SIB_RENDER"   || fail "sourcing $SIB_RENDER failed"
# shellcheck disable=SC1090
source "$TOOL" || fail "sourcing $TOOL failed"
[[ "$(type -t singular_ctx_experiment_pipeline_md)" == "function" ]] \
  || fail "singular_ctx_experiment_pipeline_md is not defined by $TOOL"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- Synthetic BOTH-ARM corpus exercising ALL metric families -----------------
# Arms: A={T1,T2}, B={T3,T4,T5}. The corpus lives in a dedicated subtree so the
# read-only fingerprint isolates the pipeline's effect on its inputs.
corpus="$tmp/corpus"
mkdir -p "$corpus"
runs="$corpus/runs"
events="$corpus/events.ndjson"
metrics="$corpus/metrics.json"

mk_index() { # runId taskId <json-attempts-array>
  local rid="$1" tid="$2" attempts="$3"
  mkdir -p "$runs/$rid/attempts"
  cat > "$runs/$rid/attempts/index.json" <<EOF
{"runId":"$rid","taskId":"$tid","attempts":$attempts}
EOF
}

# Attempts indexes carry per-attempt findings (attempts family).
mk_index R1 T1 '[{"n":1,"failureClass":"taint","findings":["f1","f2"]},{"n":2,"failureClass":"accepted","findings":[]}]'
mk_index R2 T2 '[{"n":1,"failureClass":"none","findings":["f1"]}]'
mk_index R3 T3 '[{"n":1,"failureClass":"window","findings":["f1","f2","f3"]},{"n":2,"failureClass":"taint","findings":[]}]'
mk_index R4 T4 '[{"n":1,"failureClass":""},{"n":2,"failureClass":"accepted","findings":["f1"]}]'
mk_index R5 T5 '[{"n":1,"failureClass":"accepted","findings":[]}]'

# Events: arm assignments (all families), paired audits WITH and WITHOUT
# disagreements (report escape/bias family), critic rechecks (bias dispositions),
# strategy selections resume/rehydrate/fresh + a resume failure (strategy family).
#   T1 A: audit accepted / 0 findings -> NOT flagged
#   T2 A: audit rejected / 2 findings -> FLAGGED ; recheck addressed+survives
#   T3 B: audit accepted / 0 findings -> NOT flagged
#   T4 B: audit accepted / 1 finding  -> FLAGGED ; recheck obsolete
#   T5 B: audit accepted / 0 findings -> NOT flagged
write_events() { # dest include_t2_addressed(0|1)
  local dest="$1" t2_addressed="$2"
  {
    printf '%s\n' '{"ts":"2026-07-12T00:00:00Z","type":"ctx.arm_assigned","data":{"taskId":"T1","arm":"A"}}'
    printf '%s\n' '{"ts":"2026-07-12T00:00:01Z","type":"ctx.arm_assigned","data":{"taskId":"T2","arm":"A"}}'
    printf '%s\n' '{"ts":"2026-07-12T00:00:02Z","type":"ctx.arm_assigned","data":{"taskId":"T3","arm":"B"}}'
    printf '%s\n' '{"ts":"2026-07-12T00:00:03Z","type":"ctx.arm_assigned","data":{"taskId":"T4","arm":"B"}}'
    printf '%s\n' '{"ts":"2026-07-12T00:00:04Z","type":"ctx.arm_assigned","data":{"taskId":"T5","arm":"B"}}'
    printf '%s\n' '{"ts":"2026-07-12T00:00:10Z","type":"ctx.paired_audit","data":{"taskId":"T1","verdict":"accepted","findingsCount":0}}'
    printf '%s\n' '{"ts":"2026-07-12T00:00:11Z","type":"ctx.paired_audit","data":{"taskId":"T2","verdict":"rejected","findingsCount":2}}'
    printf '%s\n' '{"ts":"2026-07-12T00:00:12Z","type":"ctx.paired_audit","data":{"taskId":"T3","verdict":"accepted","findingsCount":0}}'
    printf '%s\n' '{"ts":"2026-07-12T00:00:13Z","type":"ctx.paired_audit","data":{"taskId":"T4","verdict":"accepted","findingsCount":1}}'
    printf '%s\n' '{"ts":"2026-07-12T00:00:14Z","type":"ctx.paired_audit","data":{"taskId":"T5","verdict":"accepted","findingsCount":0}}'
    # T2's context-aware recheck: "addressed" is directional; the differential arm
    # of the guard toggles it to pin the advocate/skeptic invariance behaviorally.
    if [[ "$t2_addressed" == "1" ]]; then
      printf '%s\n' '{"ts":"2026-07-12T00:00:20Z","type":"ctx.critic_recheck","data":{"taskId":"T2","dispositions":[{"id":"a","disposition":"addressed"},{"id":"b","disposition":"survives"}]}}'
    else
      printf '%s\n' '{"ts":"2026-07-12T00:00:20Z","type":"ctx.critic_recheck","data":{"taskId":"T2","dispositions":[{"id":"b","disposition":"survives"}]}}'
    fi
    printf '%s\n' '{"ts":"2026-07-12T00:00:21Z","type":"ctx.critic_recheck","data":{"taskId":"T4","dispositions":[{"id":"c","disposition":"obsolete"}]}}'
    printf '%s\n' '{"ts":"2026-07-12T00:00:30Z","type":"context.strategy_selected","data":{"taskId":"T1","role":"implementer","strategy":"resume","reason":""}}'
    printf '%s\n' '{"ts":"2026-07-12T00:00:31Z","type":"context.strategy_selected","data":{"taskId":"T2","role":"reviewer","strategy":"rehydrate","reason":"stale_lease"}}'
    printf '%s\n' '{"ts":"2026-07-12T00:00:32Z","type":"context.strategy_selected","data":{"taskId":"T3","role":"planner","strategy":"fresh","reason":"no_snapshot"}}'
    printf '%s\n' '{"ts":"2026-07-12T00:00:33Z","type":"context.strategy_selected","data":{"taskId":"T4","role":"implementer","strategy":"fresh","reason":""}}'
    printf '%s\n' '{"ts":"2026-07-12T00:00:34Z","type":"context.strategy_selected","data":{"taskId":"T5","role":"planner","strategy":"resume","reason":""}}'
    printf '%s\n' '{"ts":"2026-07-12T00:00:40Z","type":"context.resume_failed","data":{"taskId":"T1"}}'
    printf '%s\n' '{"ts":"2026-07-12T00:00:50Z","type":"note.other","data":{"taskId":"T9"}}'
  } > "$dest"
}
write_events "$events" 1

# Per-task metrics (report cost rollup). Arm A totals: 100+200; arm B: 300+400+50.
cat > "$metrics" <<'EOF'
{"perTask":[
  {"taskId":"T1","tokens":100,"wallClockMs":1000},
  {"taskId":"T2","tokens":200,"wallClockMs":2000},
  {"taskId":"T3","tokens":300,"wallClockMs":3000},
  {"taskId":"T4","tokens":400,"wallClockMs":4000},
  {"taskId":"T5","tokens":50,"wallClockMs":500}
]}
EOF

before="$(tree_hash "$corpus")"
m_before="$(file_hash "$SIB_METRICS")"
r_before="$(file_hash "$SIB_REPORT")"
s_before="$(file_hash "$SIB_STRATEGY")"
a_before="$(file_hash "$SIB_ATTEMPTS")"
u_before="$(file_hash "$SIB_SUMMARY")"
d_before="$(file_hash "$SIB_RENDER")"
report_before="$(report_state)"

# --- Drive the whole pipeline over the explicit corpus ------------------------
# Signature: singular_ctx_experiment_pipeline_md [runs_dir] [events_file] [metrics_file]
md="$(singular_ctx_experiment_pipeline_md "$runs" "$events" "$metrics")" \
  || fail "pipeline exited non-zero on a valid corpus"
[[ -n "$md" ]] || fail "pipeline produced empty output on a valid corpus"
printf '%s\n' "$md" > "$tmp/pipeline.md"

# --- Loss-preserving delegation: byte-identical to summary_json | render_md ----
direct_bundle="$(singular_ctx_experiment_summary_json "$runs" "$events" "$metrics")" \
  || fail "summary composer exited non-zero on the corpus"
printf '%s' "$direct_bundle" > "$tmp/bundle.json"
direct_md="$(printf '%s' "$direct_bundle" | singular_ctx_experiment_render_md -)" \
  || fail "direct render of the delegated bundle exited non-zero"
[[ "$md" == "$direct_md" ]] \
  || fail "pipeline markdown differs from summary_json | render_md (delegation lost data)"

# --- Whole walk: every rendered cell equals the corpus-derived bundle value,
# formatted with the shared numeric convention. Representative cells across ALL
# families (escape, cost, attempts, findings, bias, hit rates, refusal mix) are
# asserted present, plus a hand-computed literal pin so the check is not circular.
python3 - "$tmp/bundle.json" "$tmp/pipeline.md" <<'PY' || fail "rendered tables do not carry the expected per-arm values from the corpus"
import json, sys
b = json.load(open(sys.argv[1]))
md = open(sys.argv[2]).read()

def fmt(x):
    if isinstance(x, bool):
        return str(x)
    if isinstance(x, int):
        return str(x)
    if isinstance(x, float):
        return str(int(x)) if x.is_integer() else str(x)
    return str(x)

rep = b["report"]; arms = rep["arms"]; A = arms["A"]; B = arms["B"]
att = b["attempts"]; strat = b["strategy"]

# Independent hand-computed pins from the raw corpus (not read from the bundle):
#   Arm A: audited {T1 not-flagged, T2 flagged} -> escapeRate 1/2 = 0.5
#   Arm B: audited {T3,T5 not-flagged, T4 flagged} -> escapeRate 1/3
#   Bias : flagged tasks T2 (addressed,survives) + T4 (obsolete) -> 3 findings,
#          2 directional (addressed,obsolete) -> rate 2/3
assert A["escapeRate"] == 0.5, ("escape A", A["escapeRate"])
assert abs(B["escapeRate"] - (1.0 / 3.0)) < 1e-12, ("escape B", B["escapeRate"])
assert rep["bias"]["flaggedFindings"] == 3, rep["bias"]
assert rep["bias"]["directionalDisagreements"] == 2, rep["bias"]
# Arm A cost: (100+200)/2 = 150 tokens per accepted task.
assert A["cost"]["tokensPerTask"] == 150, A["cost"]

expect_rows = [
    "| Escape rate | %s | %s |" % (fmt(A["escapeRate"]), fmt(B["escapeRate"])),
    "| Tokens per accepted task | %s | %s |" % (fmt(A["cost"]["tokensPerTask"]), fmt(B["cost"]["tokensPerTask"])),
    "| Wall-clock ms per accepted task | %s | %s |" % (fmt(A["cost"]["wallClockMsPerTask"]), fmt(B["cost"]["wallClockMsPerTask"])),
    "| Attempts-to-accept (mean) | %s | %s |" % (fmt(att["attemptsToAccept"]["A"]["attemptsToAcceptMean"]), fmt(att["attemptsToAccept"]["B"]["attemptsToAcceptMean"])),
    "| Findings-per-attempt (mean) | %s | %s |" % (fmt(att["findingsPerAttempt"]["A"]["findingsPerAttemptMean"]), fmt(att["findingsPerAttempt"]["B"]["findingsPerAttemptMean"])),
    "| Flagged findings | %s |" % fmt(rep["bias"]["flaggedFindings"]),
    "| Directional disagreements | %s |" % fmt(rep["bias"]["directionalDisagreements"]),
    "| Directional-disagreement rate | %s |" % fmt(rep["bias"]["directionalDisagreementRate"]),
    "| Arm A | %s | %s |" % (fmt(strat["hitRates"]["byArm"]["A"]["resumeHitRate"]), fmt(strat["hitRates"]["byArm"]["A"]["rehydrateHitRate"])),
    "| Arm B | %s | %s |" % (fmt(strat["hitRates"]["byArm"]["B"]["resumeHitRate"]), fmt(strat["hitRates"]["byArm"]["B"]["rehydrateHitRate"])),
    "| Role: implementer | %s | %s |" % (fmt(strat["hitRates"]["byRole"]["implementer"]["resumeHitRate"]), fmt(strat["hitRates"]["byRole"]["implementer"]["rehydrateHitRate"])),
    "| resume_failed | %s |" % fmt(strat["refusalMix"]["resumeFailed"]),
]
# Gate-refusal reason-mix rows: every measured reason renders as its own row.
for reason in sorted(strat["refusalMix"].get("reasonMix", {})):
    expect_rows.append("| %s | %s |" % (reason, fmt(strat["refusalMix"]["reasonMix"][reason])))

missing = [r for r in expect_rows if r not in md]
if missing:
    print("missing rows:\n" + "\n".join(missing), file=sys.stderr)
    sys.exit(1)
print("whole-walk-ok")
PY

# --- Determinism: identical corpus -> byte-identical output -------------------
md2="$(singular_ctx_experiment_pipeline_md "$runs" "$events" "$metrics")"
[[ "$md" == "$md2" ]] || fail "pipeline not deterministic across identical runs"

# --- Evidence invariance / advocate-skeptic line ------------------------------
# A context-aware ctx.critic_recheck disposition of "addressed" must NEVER remove
# a fresh ctx.paired_audit escape flag. Toggle T2's "addressed" off and confirm
# the rendered escape-rate row is byte-identical (the flag is unchanged), while
# the bias directional count DOES drop (proving the disposition was live and the
# invariance is not vacuous).
alt_events="$tmp/events-no-addressed.ndjson"
write_events "$alt_events" 0
alt_md="$(singular_ctx_experiment_pipeline_md "$runs" "$alt_events" "$metrics")" \
  || fail "pipeline exited non-zero on the invariance-variant corpus"
printf '%s\n' "$alt_md" > "$tmp/pipeline-alt.md"

escape_row() { grep -F '| Escape rate |' "$1"; }
[[ "$(escape_row "$tmp/pipeline.md")" == "$(escape_row "$tmp/pipeline-alt.md")" ]] \
  || fail "dropping an 'addressed' recheck changed the rendered escape flags (evidence invariance violated)"

bias_row() { grep -F '| Directional disagreements |' "$1"; }
[[ "$(bias_row "$tmp/pipeline.md")" != "$(bias_row "$tmp/pipeline-alt.md")" ]] \
  || fail "toggling the 'addressed' disposition changed nothing — invariance check is vacuous"

# --- Fail-safe: an empty corpus yields well-formed zeroed tables, zero exit ---
empty_runs="$tmp/empty-runs"
empty_events="$tmp/empty-events.ndjson"
: > "$empty_events"
zero_md="$(singular_ctx_experiment_pipeline_md "$empty_runs" "$empty_events" "$tmp/no-metrics.json")" \
  || fail "pipeline exited non-zero on an empty corpus (should fail safe)"
[[ -n "$zero_md" ]] || fail "empty corpus rendered empty output (not well-formed)"
for needle in \
  "| Escape rate | 0 | 0 |" \
  "| Attempts-to-accept (mean) | 0 | 0 |" \
  "| Findings-per-attempt (mean) | 0 | 0 |" \
  "| Flagged findings | 0 |" \
  "| Directional-disagreement rate | 0 |" \
  "| Arm A | 0 | 0 |" \
  "| Arm B | 0 | 0 |" \
  "| Role: implementer | 0 | 0 |" \
  "| resume_failed | 0 |" \
  "| --- | --- | --- |" ; do
  case "$zero_md" in
    *"$needle"*) : ;;
    *) fail "empty corpus table missing well-formed zeroed row: $needle" ;;
  esac
done

# --- Strictly read-only: corpus tree + sibling engine files byte-unchanged,
# no experiment-report.md created or mutated ---------------------------------
after="$(tree_hash "$corpus")"
[[ "$before" == "$after" ]] || fail "corpus tree mutated (pipeline is not read-only vs its inputs)"
[[ "$m_before" == "$(file_hash "$SIB_METRICS")" ]]  || fail "engine/ctx-metrics.sh was mutated"
[[ "$r_before" == "$(file_hash "$SIB_REPORT")" ]]   || fail "engine/ctx-experiment-report.sh was mutated"
[[ "$s_before" == "$(file_hash "$SIB_STRATEGY")" ]] || fail "engine/ctx-experiment-strategy.sh was mutated"
[[ "$a_before" == "$(file_hash "$SIB_ATTEMPTS")" ]] || fail "engine/ctx-experiment-attempts.sh was mutated"
[[ "$u_before" == "$(file_hash "$SIB_SUMMARY")" ]]  || fail "engine/ctx-experiment-summary.sh was mutated"
[[ "$d_before" == "$(file_hash "$SIB_RENDER")" ]]   || fail "engine/ctx-experiment-render.sh was mutated"
[[ "$report_before" == "$(report_state)" ]] \
  || fail "pipeline created or mutated docs/context-build-plan/experiment-report.md (must not)"

echo "ctx-experiment-pipeline tests passed"
