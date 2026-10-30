#!/usr/bin/env bash
# Regression contracts for ctx-experiment-render-delta.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ENGINE_HOME/engine/ctx-experiment-render-delta.sh"
SIB_RENDER="$ENGINE_HOME/engine/ctx-experiment-render.sh"
SIB_DELTA="$ENGINE_HOME/engine/ctx-experiment-delta.sh"
SIB_ARMAUDIT="$ENGINE_HOME/engine/ctx-experiment-armaudit.sh"
SIB_ARMSTATE="$ENGINE_HOME/engine/ctx-experiment-armstate.sh"
SIB_REPORT="$ENGINE_HOME/engine/ctx-experiment-report.sh"
SIB_STRATEGY="$ENGINE_HOME/engine/ctx-experiment-strategy.sh"
SIB_ATTEMPTS="$ENGINE_HOME/engine/ctx-experiment-attempts.sh"
SIB_SUMMARY="$ENGINE_HOME/engine/ctx-experiment-summary.sh"
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
# The no-source path delegates to the delta + armaudit composers, which delegate
# further to the summary / per-family composers and the armstate emitter — source
# them all so the delegation path is exercisable.
# shellcheck disable=SC1090
source "$SIB_REPORT"   || fail "sourcing $SIB_REPORT failed"
# shellcheck disable=SC1090
source "$SIB_STRATEGY" || fail "sourcing $SIB_STRATEGY failed"
# shellcheck disable=SC1090
source "$SIB_ATTEMPTS" || fail "sourcing $SIB_ATTEMPTS failed"
# shellcheck disable=SC1090
source "$SIB_SUMMARY"  || fail "sourcing $SIB_SUMMARY failed"
# shellcheck disable=SC1090
source "$SIB_ARMSTATE" || fail "sourcing $SIB_ARMSTATE failed"
# shellcheck disable=SC1090
source "$SIB_DELTA"    || fail "sourcing $SIB_DELTA failed"
# shellcheck disable=SC1090
source "$SIB_ARMAUDIT" || fail "sourcing $SIB_ARMAUDIT failed"
# shellcheck disable=SC1090
source "$TOOL" || fail "sourcing $TOOL failed"
for fn in singular_ctx_experiment_render_delta_table \
          singular_ctx_experiment_render_armaudit_table \
          singular_ctx_experiment_render_result_md; do
  [[ "$(type -t "$fn")" == "function" ]] || fail "$fn is not defined by $TOOL"
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Input fixtures live in a dedicated read-only subtree; test outputs go to $tmp
# root, so the read-only fingerprint over $indir isolates the renderer's effect.
indir="$tmp/in"
mkdir -p "$indir"

# ============================================================================
# Slice 1: treatment-effect table renderer, over a clean delta-artifact fixture.
# Distinctive int/float values so representative cells cross-check unambiguously.
# ============================================================================
delta_fix="$indir/delta.json"
cat > "$delta_fix" <<'EOF'
{
  "schema": "singular.orchestration.ctx-experiment-delta.v0",
  "deltas": {
    "escapeRate": {"a": 0.5, "b": 0.2, "delta": -0.3, "direction": "lower"},
    "costTokensPerTask": {"a": 100, "b": 150, "delta": 50, "direction": "higher"},
    "findingsPerAttemptMean": {"a": 1, "b": 1, "delta": 0, "direction": "equal"}
  }
}
EOF

dtab="$(singular_ctx_experiment_render_delta_table "$(cat "$delta_fix")")" \
  || fail "delta-table renderer exited non-zero on a valid artifact"
[[ -n "$dtab" ]] || fail "delta-table renderer produced empty output"
printf '%s\n' "$dtab" > "$tmp/dtab.md"

python3 - "$delta_fix" "$tmp/dtab.md" <<'PY' || fail "delta-table cells are not the artifact's verbatim values"
import json, sys
art = json.load(open(sys.argv[1]))
md = open(sys.argv[2]).read()

def fmt(x):
    if isinstance(x, bool):
        return str(x)
    if isinstance(x, int):
        return str(x)
    if isinstance(x, float):
        return str(int(x)) if x.is_integer() else str(x)
    return str(x)

d = art["deltas"]
# every metric renders one row carrying metric, a, b, delta, direction verbatim.
expect = [
    "| escapeRate | %s | %s | %s | %s |" % (fmt(d["escapeRate"]["a"]), fmt(d["escapeRate"]["b"]), fmt(d["escapeRate"]["delta"]), d["escapeRate"]["direction"]),
    "| costTokensPerTask | %s | %s | %s | %s |" % (fmt(d["costTokensPerTask"]["a"]), fmt(d["costTokensPerTask"]["b"]), fmt(d["costTokensPerTask"]["delta"]), d["costTokensPerTask"]["direction"]),
    "| findingsPerAttemptMean | %s | %s | %s | %s |" % (fmt(d["findingsPerAttemptMean"]["a"]), fmt(d["findingsPerAttemptMean"]["b"]), fmt(d["findingsPerAttemptMean"]["delta"]), d["findingsPerAttemptMean"]["direction"]),
]
missing = [r for r in expect if r not in md]
if missing:
    print("missing delta rows:\n" + "\n".join(missing), file=sys.stderr)
    sys.exit(1)
# rows are emitted in a stable (sorted-key) order for determinism.
i_cost = md.index("| costTokensPerTask |")
i_esc = md.index("| escapeRate |")
i_find = md.index("| findingsPerAttemptMean |")
assert i_cost < i_esc < i_find, "delta rows are not in stable sorted-key order"
print("delta-table-ok")
PY

# ============================================================================
# Slice 2: arm-integrity table renderer, over a clean audit-artifact fixture.
# ============================================================================
audit_fix="$indir/audit.json"
cat > "$audit_fix" <<'EOF'
{
  "schema": "singular.orchestration.ctx-experiment-armaudit.v0",
  "arms": {
    "A": {"arm": "A", "expectation": "activeCount==0", "runsRecorded": 2,
          "runsUnrecorded": 1, "consistent": 1, "inconsistent": 1,
          "inconsistentRuns": [{"runId": "RA2", "classification": "contaminated",
                                "activeCount": 2,
                                "activeKnobs": ["SINGULAR_CTX_PACKET", "SINGULAR_CTX_ROUTING"]}]},
    "B": {"arm": "B", "expectation": "activeCount>0", "runsRecorded": 3,
          "runsUnrecorded": 0, "consistent": 1, "inconsistent": 2,
          "inconsistentRuns": [{"runId": "RB2", "classification": "misconfigured-as-M0",
                                "activeCount": 0, "activeKnobs": []},
                               {"runId": "RB5", "classification": "misconfigured-as-M0",
                                "activeCount": 0, "activeKnobs": []}]}
  }
}
EOF

atab="$(singular_ctx_experiment_render_armaudit_table "$(cat "$audit_fix")")" \
  || fail "armaudit-table renderer exited non-zero on a valid artifact"
[[ -n "$atab" ]] || fail "armaudit-table renderer produced empty output"
printf '%s\n' "$atab" > "$tmp/atab.md"

python3 - "$audit_fix" "$tmp/atab.md" <<'PY' || fail "armaudit-table cells are not the artifact's verbatim values"
import json, sys
art = json.load(open(sys.argv[1]))
md = open(sys.argv[2]).read()
arms = art["arms"]

def row(arm):
    s = arms[arm]
    flagged = ", ".join(r["runId"] for r in s["inconsistentRuns"])
    return "| %s | %s | %s | %s | %s | %s |" % (
        arm, s["runsRecorded"], s["runsUnrecorded"], s["consistent"], s["inconsistent"], flagged)

expect = [row("A"), row("B")]
missing = [r for r in expect if r not in md]
if missing:
    print("missing audit rows:\n" + "\n".join(missing), file=sys.stderr)
    sys.exit(1)
# arm A precedes arm B (stable order); both flagged runIds surfaced verbatim.
assert md.index("| A |") < md.index("| B |"), "arm rows not in stable A-before-B order"
assert "RA2" in md and "RB2" in md and "RB5" in md, "flagged runIds not surfaced"
print("armaudit-table-ok")
PY

# ============================================================================
# Determinism: identical input -> byte-identical output, both slices.
# ============================================================================
dtab2="$(singular_ctx_experiment_render_delta_table "$(cat "$delta_fix")")"
[[ "$dtab" == "$dtab2" ]] || fail "delta-table render not deterministic across identical runs"
atab2="$(singular_ctx_experiment_render_armaudit_table "$(cat "$audit_fix")")"
[[ "$atab" == "$atab2" ]] || fail "armaudit-table render not deterministic across identical runs"

# ============================================================================
# Slice 3: no-source delegation. Build a synthetic corpus, then prove the entry
# renders exactly what rendering the delegated delta + audit artifacts produces.
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
mk_armstate R1                                   # arm A, M0            -> consistent
mk_armstate R2 SINGULAR_CTX_PACKET=1              # arm A, contaminated  -> inconsistent
mk_armstate R3 SINGULAR_CTX_PACKET=1 SINGULAR_CTX_ROUTING=1  # arm B, active -> consistent
mk_armstate R4                                   # arm B, M0            -> misconfigured

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
rd_before="$(file_hash "$SIB_RENDER")"
dl_before="$(file_hash "$SIB_DELTA")"
au_before="$(file_hash "$SIB_ARMAUDIT")"
as_before="$(file_hash "$SIB_ARMSTATE")"
rp_before="$(file_hash "$SIB_REPORT")"
st_before="$(file_hash "$SIB_STRATEGY")"
at_before="$(file_hash "$SIB_ATTEMPTS")"
su_before="$(file_hash "$SIB_SUMMARY")"
report_before="$(report_state)"

# The delegated artifacts, obtained directly from the composers (threaded args).
direct_delta="$(singular_ctx_experiment_delta_json "$runs" "$events" "$metrics")" \
  || fail "delta composer exited non-zero"
direct_audit="$(singular_ctx_experiment_armaudit_json "$runs" "$events")" \
  || fail "armaudit composer exited non-zero"

# The composed entry, threading the same corpus args.
composed="$(singular_ctx_experiment_render_result_md "$runs" "$events" "$metrics")" \
  || fail "result renderer exited non-zero on a threaded corpus"
[[ -n "$composed" ]] || fail "result renderer produced empty output on a valid corpus"
printf '%s\n' "$composed" > "$tmp/composed.md"

# The entry renders exactly what rendering the delegated artifacts produces: the
# delta table over direct_delta and the armaudit table over direct_audit both
# appear verbatim inside the composed fragment.
expect_dtab="$(singular_ctx_experiment_render_delta_table "$direct_delta")"
expect_atab="$(singular_ctx_experiment_render_armaudit_table "$direct_audit")"
case "$composed" in
  *"$expect_dtab"*) : ;;
  *) fail "composed fragment does not contain the rendered delegated delta table" ;;
esac
case "$composed" in
  *"$expect_atab"*) : ;;
  *) fail "composed fragment does not contain the rendered delegated audit table" ;;
esac

# Delta section precedes the audit section (stable order).
python3 - "$tmp/composed.md" <<'PY' || fail "composed sections not in a stable order"
import sys
md = open(sys.argv[1]).read()
# treatment-effect (delta) direction column values only exist in the delta table;
# the arm expectation strings only exist in the audit table.
assert "Direction" in md, "delta table header missing"
assert ("activeCount==0" in md) or ("| A |" in md), "audit table missing"
print("order-ok")
PY

# Determinism of the composed entry.
composed2="$(singular_ctx_experiment_render_result_md "$runs" "$events" "$metrics")"
[[ "$composed" == "$composed2" ]] || fail "composed entry not deterministic across identical runs"

# No-arg env-default delegation renders identically to the threaded-arg form.
env_composed="$(SINGULAR_RUNS_DIR="$runs" SINGULAR_EVENTS_FILE="$events" \
  SINGULAR_CTX_EXPERIMENT_METRICS_FILE="$metrics" \
  singular_ctx_experiment_render_result_md)" \
  || fail "no-arg result renderer exited non-zero (should delegate over env defaults)"
[[ "$env_composed" == "$composed" ]] \
  || fail "no-arg env-default render differs from threaded-arg render"

# ============================================================================
# Fail-safe: zeroed / empty artifacts render well-formed zero tables, zero exit.
# ============================================================================
# The slice renderers on empty artifacts render a well-formed table skeleton.
zero_dtab="$(singular_ctx_experiment_render_delta_table '{"schema":"singular.orchestration.ctx-experiment-delta.v0","deltas":{}}')" \
  || fail "delta-table renderer non-zero on an empty deltas map (should fail safe)"
[[ -n "$zero_dtab" ]] || fail "empty delta artifact rendered nothing (not well-formed)"
case "$zero_dtab" in *"| --- |"*) : ;; *) fail "empty delta table missing a separator row" ;; esac

zero_atab="$(singular_ctx_experiment_render_armaudit_table '{"schema":"singular.orchestration.ctx-experiment-armaudit.v0","arms":{}}')" \
  || fail "armaudit-table renderer non-zero on an empty arms map (should fail safe)"
[[ -n "$zero_atab" ]] || fail "empty audit artifact rendered nothing (not well-formed)"
case "$zero_atab" in *"| --- |"*) : ;; *) fail "empty audit table missing a separator row" ;; esac

# The composed entry over a missing corpus renders well-formed zero tables, exit 0.
zero_md="$(singular_ctx_experiment_render_result_md "$tmp/no-runs" "$tmp/no-events.ndjson" "$tmp/no-metrics.json")" \
  || fail "result renderer non-zero on a missing corpus (should fail safe)"
[[ -n "$zero_md" ]] || fail "missing-corpus render produced empty output (not well-formed)"
printf '%s\n' "$zero_md" > "$tmp/zero.md"
python3 - "$tmp/zero.md" <<'PY' || fail "missing-corpus render is not a well-formed zero fragment"
import sys
md = open(sys.argv[1]).read()
# The delegated delta composer yields 8 zeroed metric rows; each carries the
# neutral "equal" direction and a zero delta cell "| 0 |".
assert md.count("| 0 | equal |") >= 8, "expected 8 zeroed delta rows with equal direction"
# The delegated audit composer yields zeroed arm rows for A and B.
assert "| A | 0 | 0 | 0 | 0 |" in md, "arm A zero row missing"
assert "| B | 0 | 0 | 0 | 0 |" in md, "arm B zero row missing"
print("fail-safe-ok")
PY

# ============================================================================
# STDOUT ONLY / read-only: fixture tree + sibling engine files byte-unchanged,
# no experiment-report.md created or mutated.
# ============================================================================
after="$(tree_hash "$indir")"
[[ "$before" == "$after" ]] || fail "input fixture tree mutated (renderer is not read-only vs its inputs)"
[[ "$rd_before" == "$(file_hash "$SIB_RENDER")" ]]   || fail "engine/ctx-experiment-render.sh was mutated"
[[ "$dl_before" == "$(file_hash "$SIB_DELTA")" ]]    || fail "engine/ctx-experiment-delta.sh was mutated"
[[ "$au_before" == "$(file_hash "$SIB_ARMAUDIT")" ]] || fail "engine/ctx-experiment-armaudit.sh was mutated"
[[ "$as_before" == "$(file_hash "$SIB_ARMSTATE")" ]] || fail "engine/ctx-experiment-armstate.sh was mutated"
[[ "$rp_before" == "$(file_hash "$SIB_REPORT")" ]]   || fail "engine/ctx-experiment-report.sh was mutated"
[[ "$st_before" == "$(file_hash "$SIB_STRATEGY")" ]] || fail "engine/ctx-experiment-strategy.sh was mutated"
[[ "$at_before" == "$(file_hash "$SIB_ATTEMPTS")" ]] || fail "engine/ctx-experiment-attempts.sh was mutated"
[[ "$su_before" == "$(file_hash "$SIB_SUMMARY")" ]]  || fail "engine/ctx-experiment-summary.sh was mutated"
[[ "$report_before" == "$(report_state)" ]] \
  || fail "renderer created or mutated docs/context-build-plan/experiment-report.md (must not)"

echo "ctx-experiment-render-delta tests passed"
