#!/usr/bin/env bash
# Covers the sanctioned `cli/singular experiment-report` subcommand: a thin
# driver-hook that DELEGATES into the already-integrated experiment raw-metrics
# engine suite (singular_ctx_experiment_summary_json / _delta_json /
# _pipeline_md), behind SINGULAR_CTX_EXPERIMENT (default 0). It mirrors the
# `singular graph` / SINGULAR_CTX_GRAPH hook EXACTLY. Asserts:
#   * with the flag ON, `experiment-report summary|delta|tables ...` produce
#     byte-identical output to the underlying engine functions over the same
#     resolved inputs (delegation adds no metric logic of its own);
#   * defaults resolve from SINGULAR_RUNS_DIR / SINGULAR_EVENTS_FILE /
#     SINGULAR_CTX_EXPERIMENT_METRICS_FILE when positionals are omitted;
#   * with the flag OFF (unset or 0), `singular experiment-report ...` refuses
#     exactly as an unknown command did, and help output is byte-identical to
#     the pre-hook binary (no `experiment-report` line leaks) — OFF-parity is
#     asserted behaviorally, never by grepping the source;
#   * bad/missing sub-subcommands produce a clear usage error, non-zero exit;
#   * the command is strictly read-only: it creates / moves / mutates no run
#     artifact, index, event, lease, or task file, and writes no
#     docs/context-build-plan/experiment-report.md.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SINGULAR_SRC="$ENGINE_HOME/cli/singular"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$SINGULAR_SRC" ]] || fail "cli/singular not present: $SINGULAR_SRC"
for m in "$ENGINE_HOME"/engine/ctx-experiment-*.sh; do
  [[ -f "$m" ]] || fail "integrated experiment module missing: $m"
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Hermetic engine home: only engine/lib.sh (resolver needs it present) + the
# integrated experiment modules + the CLI under test. Keeps the delegation
# assertions independent of whatever .singular-state the suite host carries.
EHOME="$tmp/engine-home"
mkdir -p "$EHOME/engine" "$EHOME/cli"
: > "$EHOME/engine/lib.sh"
cp "$ENGINE_HOME"/engine/ctx-experiment-*.sh "$EHOME/engine/"
cp "$SINGULAR_SRC" "$EHOME/cli/singular"
SINGULAR="$EHOME/cli/singular"
export SINGULAR_ENGINE_HOME="$EHOME"

# --- Fixture: runs/<runId>/attempts/index.json + events.ndjson + metrics.json -
# Exercises all three metric families across BOTH arms in one input set (mirrors
# the engine-suite fixtures so summary/delta/tables have non-trivial content).
STATE="$tmp/state"
runs="$STATE/runs"
events="$STATE/events.ndjson"
metrics="$STATE/metrics.json"

mk_index() { # runId taskId <json-attempts-array>
  local rid="$1" tid="$2" attempts="$3"
  mkdir -p "$runs/$rid/attempts"
  cat > "$runs/$rid/attempts/index.json" <<EOF
{"runId":"$rid","taskId":"$tid","attempts":$attempts}
EOF
}

mk_index R1 T1 '[{"n":1,"failureClass":"taint","findings":["f1","f2"]},{"n":2,"failureClass":"accepted","findings":[]}]'
mk_index R2 T2 '[{"n":1,"failureClass":"none","findings":["f1"]}]'
mk_index R3 T3 '[{"n":1,"failureClass":"window","findings":["f1","f2","f3"]},{"n":2,"failureClass":"taint","findings":[]}]'
mk_index R4 T4 '[{"n":1,"failureClass":""},{"n":2,"failureClass":"accepted","findings":["f1"]}]'

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

# Directory-tree fingerprint (path + content sha) to prove read-only behavior.
tree_hash() {
  local dir="$1"
  [[ -d "$dir" ]] || { echo "MISSING:$dir"; return 0; }
  find "$dir" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s ' "$f"; shasum "$f" | awk '{print $1}'
  done
}

# Ground truth: source the integrated modules and call the entry points directly
# in the SAME sorted glob order the CLI hook (and the ctx-loader) uses.
source_exp='for m in "'"$EHOME"'"/engine/ctx-experiment-*.sh; do source "$m"; done'

before="$(tree_hash "$STATE")"

# ---------------------------------------------------------------------------
# FLAG ON: summary|delta|tables delegate byte-identically to the entry points.
# ---------------------------------------------------------------------------
declare -A FN=(
  [summary]=singular_ctx_experiment_summary_json
  [delta]=singular_ctx_experiment_delta_json
  [tables]=singular_ctx_experiment_pipeline_md
)
for sub in summary delta tables; do
  fn="${FN[$sub]}"
  ( set -uo pipefail; eval "$source_exp"; "$fn" "$runs" "$events" "$metrics" ) \
    > "$tmp/gt-$sub.out" 2>/dev/null || fail "ground-truth $fn failed"
  SINGULAR_CTX_EXPERIMENT=1 "$SINGULAR" experiment-report "$sub" "$runs" "$events" "$metrics" \
    > "$tmp/cli-$sub.out" 2>"$tmp/cli-$sub.err" \
    || fail "singular experiment-report $sub exited non-zero: $(cat "$tmp/cli-$sub.err")"
  cmp -s "$tmp/gt-$sub.out" "$tmp/cli-$sub.out" \
    || fail "experiment-report $sub output not byte-identical to $fn"
done

# ---------------------------------------------------------------------------
# FLAG ON: positionals omitted -> defaults resolve from the metrics-file env
# trio (SINGULAR_RUNS_DIR / SINGULAR_EVENTS_FILE / SINGULAR_CTX_EXPERIMENT_METRICS_FILE),
# still byte-identical to the direct entry point on the same resolved inputs.
# ---------------------------------------------------------------------------
SINGULAR_CTX_EXPERIMENT=1 \
SINGULAR_RUNS_DIR="$runs" \
SINGULAR_EVENTS_FILE="$events" \
SINGULAR_CTX_EXPERIMENT_METRICS_FILE="$metrics" \
  "$SINGULAR" experiment-report summary \
  > "$tmp/cli-summary-envdefault.out" 2>"$tmp/cli-summary-envdefault.err" \
  || fail "singular experiment-report summary (env defaults) exited non-zero: $(cat "$tmp/cli-summary-envdefault.err")"
cmp -s "$tmp/gt-summary.out" "$tmp/cli-summary-envdefault.out" \
  || fail "experiment-report summary via env defaults not byte-identical to summary via positionals"

# ---------------------------------------------------------------------------
# FLAG ON: usage() lists an experiment-report line.
# ---------------------------------------------------------------------------
SINGULAR_CTX_EXPERIMENT=1 "$SINGULAR" help > "$tmp/help-on.txt" 2>&1 \
  || fail "singular help (flag on) exited non-zero"
grep -q 'experiment-report' "$tmp/help-on.txt" \
  || fail "experiment-report line not listed in usage() when SINGULAR_CTX_EXPERIMENT=1"

# ---------------------------------------------------------------------------
# FLAG ON: bad/missing sub-subcommand -> clear usage error, non-zero exit.
# ---------------------------------------------------------------------------
if SINGULAR_CTX_EXPERIMENT=1 "$SINGULAR" experiment-report bogus-sub >/dev/null 2>"$tmp/badsub.err"; then
  fail "experiment-report with an unknown sub-subcommand should exit non-zero"
fi
grep -qi 'usage' "$tmp/badsub.err" || fail "unknown experiment-report sub-subcommand gave no usage hint"

if SINGULAR_CTX_EXPERIMENT=1 "$SINGULAR" experiment-report >/dev/null 2>&1; then
  fail "bare 'experiment-report' (no sub-subcommand) should exit non-zero"
fi

# ---------------------------------------------------------------------------
# READ-ONLY: the input fixture tree is byte-identical after every flag-on call,
# and no docs/context-build-plan/experiment-report.md was authored anywhere.
# ---------------------------------------------------------------------------
after="$(tree_hash "$STATE")"
[[ "$before" == "$after" ]] || fail "input fixture mutated by experiment-report (not read-only)"
[[ ! -e "$EHOME/docs/context-build-plan/experiment-report.md" ]] \
  || fail "experiment-report authored a report doc (must be read-only)"
[[ ! -e "$STATE/docs/context-build-plan/experiment-report.md" ]] \
  || fail "experiment-report authored a report doc under the state tree (must be read-only)"

# ---------------------------------------------------------------------------
# OFF-PARITY: flag unset/0 -> experiment-report refuses as unknown command;
# help unchanged (no experiment-report line leaks).
# ---------------------------------------------------------------------------
for flag in "unset" "0"; do
  if [[ "$flag" == "unset" ]]; then
    env -u SINGULAR_CTX_EXPERIMENT "$SINGULAR" help > "$tmp/help-off.txt" 2>&1 \
      || fail "singular help (flag $flag) exited non-zero"
    env -u SINGULAR_CTX_EXPERIMENT "$SINGULAR" experiment-report summary "$runs" "$events" "$metrics" \
      >/dev/null 2>"$tmp/off-exp.err" && fail "experiment-report must refuse when flag $flag"
    env -u SINGULAR_CTX_EXPERIMENT "$SINGULAR" totally-unknown-xyz \
      >/dev/null 2>"$tmp/off-unknown.err" && fail "control unknown command should be non-zero"
  else
    SINGULAR_CTX_EXPERIMENT=0 "$SINGULAR" help > "$tmp/help-off.txt" 2>&1 \
      || fail "singular help (flag $flag) exited non-zero"
    SINGULAR_CTX_EXPERIMENT=0 "$SINGULAR" experiment-report summary "$runs" "$events" "$metrics" \
      >/dev/null 2>"$tmp/off-exp.err" && fail "experiment-report must refuse when flag $flag"
    SINGULAR_CTX_EXPERIMENT=0 "$SINGULAR" totally-unknown-xyz \
      >/dev/null 2>"$tmp/off-unknown.err" && fail "control unknown command should be non-zero"
  fi
  grep -q 'experiment-report' "$tmp/help-off.txt" \
    && fail "usage() leaked an experiment-report line when SINGULAR_CTX_EXPERIMENT=$flag (OFF-parity broken)"
  # experiment-report's refusal must read exactly like an unknown command's,
  # modulo the command token (experiment-report vs totally-unknown-xyz).
  off_exp="$(sed 's/experiment-report/CMD/' "$tmp/off-exp.err")"
  off_unknown="$(sed 's/totally-unknown-xyz/CMD/' "$tmp/off-unknown.err")"
  [[ "$off_exp" == "$off_unknown" ]] \
    || fail "experiment-report OFF refusal differs from unknown-command refusal ($flag): [$off_exp] vs [$off_unknown]"
done

echo "cli-experiment tests passed"
