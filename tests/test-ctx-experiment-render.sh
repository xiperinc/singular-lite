#!/usr/bin/env bash
# Covers the read-only experiment-render PRESENTATION capstone tooling
# engine/ctx-experiment-render.sh. This brick ships NO metric of its own: it
# RENDERS the already-computed values of the integrated summary bundle
# (singular.orchestration.ctx-experiment-summary.v0) into the deterministic
# markdown metrics tables the operator drops into experiment-report.md.
#
# The renderer computes nothing, reclassifies nothing, and writes nothing: it
# formats the bundle's verbatim numbers to STDOUT ONLY and reads/writes no other
# file. When no summary source is supplied it obtains the bundle by delegating to
# singular_ctx_experiment_summary_json with the standard env defaults.
#
# Guarantees pinned BEHAVIORALLY over a fixture (no absence greps):
#   - verbatim rendering: every rendered cell equals the corresponding bundle
#     value formatted with the shared numeric convention (no recompute/reclassify);
#     representative cells are cross-checked against the fixture.
#   - deterministic markdown: byte-identical across repeated runs on one input,
#     via file path AND via stdin ("-").
#   - no-source delegation: with no arg the entry renders exactly what rendering
#     the delegated summary bundle produces (standard env defaults).
#   - fail-safe: a zeroed/empty bundle renders well-formed tables with zero values
#     and a zero exit, never an error or partial output.
#   - STDOUT ONLY / read-only: the input fixture tree is byte-identical after
#     every call (no file created, moved, or mutated — in particular no
#     experiment-report.md), and the sibling ctx-experiment-*.sh files plus
#     engine/ctx-metrics.sh are byte-unchanged.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ENGINE_HOME/engine/ctx-experiment-render.sh"
SIB_METRICS="$ENGINE_HOME/engine/ctx-metrics.sh"
SIB_SUMMARY="$ENGINE_HOME/engine/ctx-experiment-summary.sh"
SIB_REPORT="$ENGINE_HOME/engine/ctx-experiment-report.sh"
SIB_STRATEGY="$ENGINE_HOME/engine/ctx-experiment-strategy.sh"
SIB_ATTEMPTS="$ENGINE_HOME/engine/ctx-experiment-attempts.sh"
REPORT_MD="$ENGINE_HOME/docs/context-build-plan/experiment-report.md"

fail() { echo "FAIL: $*" >&2; exit 1; }

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
# The no-arg path delegates to the summary composer, which delegates to the three
# per-family composers; source them all so the delegation path is exercisable.
# shellcheck disable=SC1090
source "$SIB_REPORT"   || fail "sourcing $SIB_REPORT failed"
# shellcheck disable=SC1090
source "$SIB_STRATEGY" || fail "sourcing $SIB_STRATEGY failed"
# shellcheck disable=SC1090
source "$SIB_ATTEMPTS" || fail "sourcing $SIB_ATTEMPTS failed"
# shellcheck disable=SC1090
source "$SIB_SUMMARY"  || fail "sourcing $SIB_SUMMARY failed"
# shellcheck disable=SC1090
source "$TOOL" || fail "sourcing $TOOL failed"
[[ "$(type -t singular_ctx_experiment_render_md)" == "function" ]] \
  || fail "singular_ctx_experiment_render_md is not defined by $TOOL"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Input fixtures live in a dedicated read-only subtree; test outputs go to $tmp
# root, so the read-only fingerprint over $indir isolates the renderer's effect.
indir="$tmp/in"
mkdir -p "$indir"

# --- Synthetic summary-bundle fixture conforming to v0 ------------------------
# Distinctive values so representative cells cross-check unambiguously. Floats and
# integers are mixed to pin the shared numeric-formatting convention.
fix="$indir/bundle.json"
cat > "$fix" <<'EOF'
{
  "schema": "singular.orchestration.ctx-experiment-summary.v0",
  "report": {
    "schema": "singular.orchestration.ctx-experiment-report.v0",
    "arms": {
      "A": {"escapeRate": 0.25, "accepted": 4, "flagged": 2,
            "cost": {"tasks": 2, "tokensTotal": 300, "wallClockMsTotal": 4000,
                     "tokensPerTask": 150.5, "wallClockMsPerTask": 2000.75}},
      "B": {"escapeRate": 0.1, "accepted": 5, "flagged": 1,
            "cost": {"tasks": 2, "tokensTotal": 700, "wallClockMsTotal": 8000,
                     "tokensPerTask": 275.25, "wallClockMsPerTask": 1234.5}}
    },
    "bias": {"flaggedFindings": 7, "directionalDisagreements": 3,
             "directionalDisagreementRate": 0.375}
  },
  "strategy": {
    "schema": "singular.orchestration.ctx-experiment-strategy.v0",
    "hitRates": {
      "overall": {"total": 4, "resume": 2, "rehydrate": 1,
                  "resumeHitRate": 0.5, "rehydrateHitRate": 0.25},
      "byArm": {
        "A": {"total": 2, "resume": 1, "rehydrate": 1,
              "resumeHitRate": 0.8, "rehydrateHitRate": 0.2},
        "B": {"total": 2, "resume": 1, "rehydrate": 0,
              "resumeHitRate": 0.6, "rehydrateHitRate": 0.4}
      },
      "byRole": {
        "implementer": {"total": 2, "resume": 2, "rehydrate": 0,
                        "resumeHitRate": 0.9, "rehydrateHitRate": 0.1},
        "planner": {"total": 1, "resume": 0, "rehydrate": 0,
                    "resumeHitRate": 0.55, "rehydrateHitRate": 0.45},
        "reviewer": {"total": 1, "resume": 0, "rehydrate": 1,
                     "resumeHitRate": 0.7, "rehydrateHitRate": 0.3}
      }
    },
    "refusalMix": {
      "reasonMix": {"stale_lease": 2, "no_snapshot": 1},
      "resumeFailed": 4
    }
  },
  "attempts": {
    "schema": "singular.orchestration.ctx-experiment-attempts.v0",
    "attemptsToAccept": {
      "A": {"acceptedTasks": 2, "attemptsToAcceptSum": 3, "attemptsToAcceptMean": 1.75},
      "B": {"acceptedTasks": 2, "attemptsToAcceptSum": 5, "attemptsToAcceptMean": 2.25}
    },
    "findingsPerAttempt": {
      "A": {"attempts": 4, "findingsTotal": 2, "findingsPerAttemptMean": 0.5},
      "B": {"attempts": 4, "findingsTotal": 5, "findingsPerAttemptMean": 1.25}
    }
  }
}
EOF

before="$(tree_hash "$indir")"
m_before="$(file_hash "$SIB_METRICS")"
r_before="$(file_hash "$SIB_REPORT")"
s_before="$(file_hash "$SIB_STRATEGY")"
a_before="$(file_hash "$SIB_ATTEMPTS")"
u_before="$(file_hash "$SIB_SUMMARY")"
report_before="$(report_state)"

# --- Render from a file path --------------------------------------------------
md="$(singular_ctx_experiment_render_md "$fix")" \
  || fail "renderer exited non-zero on a valid fixture"
printf '%s\n' "$md" > "$tmp/out.md"
[[ -n "$md" ]] || fail "renderer produced empty output on a valid fixture"

# --- Verbatim cross-check: every representative cell equals the bundle value,
# formatted with the shared numeric convention (int -> str(int); float that is an
# integer -> str(int); else str(float)). Exact table rows are asserted present. --
python3 - "$fix" "$tmp/out.md" <<'PY' || fail "rendered cells are not the bundle's verbatim values"
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
    "| Role: planner | %s | %s |" % (fmt(strat["hitRates"]["byRole"]["planner"]["resumeHitRate"]), fmt(strat["hitRates"]["byRole"]["planner"]["rehydrateHitRate"])),
    "| Role: reviewer | %s | %s |" % (fmt(strat["hitRates"]["byRole"]["reviewer"]["resumeHitRate"]), fmt(strat["hitRates"]["byRole"]["reviewer"]["rehydrateHitRate"])),
    "| no_snapshot | 1 |",
    "| stale_lease | 2 |",
    "| resume_failed | %s |" % fmt(strat["refusalMix"]["resumeFailed"]),
]
missing = [r for r in expect_rows if r not in md]
if missing:
    print("missing rows:\n" + "\n".join(missing), file=sys.stderr)
    sys.exit(1)
print("verbatim-ok")
PY

# --- Determinism: identical input -> byte-identical output -------------------
md2="$(singular_ctx_experiment_render_md "$fix")"
[[ "$md" == "$md2" ]] || fail "render not deterministic across identical runs"

# --- Stdin ("-") path renders byte-identically to the file path --------------
md_stdin="$(singular_ctx_experiment_render_md - < "$fix")" \
  || fail "renderer exited non-zero reading the bundle from stdin"
[[ "$md" == "$md_stdin" ]] || fail "stdin render differs from file-path render"

# --- No-source delegation: with no arg, render == rendering the delegated
# summary bundle produced under the standard env defaults --------------------
export SINGULAR_RUNS_DIR="$tmp/no-runs"
export SINGULAR_EVENTS_FILE="$tmp/no-events.ndjson"
export SINGULAR_CTX_EXPERIMENT_METRICS_FILE="$tmp/no-metrics.json"
delegated_bundle="$(singular_ctx_experiment_summary_json)" \
  || fail "summary delegate exited non-zero"
printf '%s' "$delegated_bundle" > "$tmp/delegated.json"
expected_default="$(singular_ctx_experiment_render_md "$tmp/delegated.json")" \
  || fail "renderer exited non-zero on the delegated bundle"
got_default="$(singular_ctx_experiment_render_md)" \
  || fail "no-arg renderer exited non-zero (should delegate + render)"
[[ "$got_default" == "$expected_default" ]] \
  || fail "no-arg render does not match rendering the delegated summary bundle"
unset SINGULAR_RUNS_DIR SINGULAR_EVENTS_FILE SINGULAR_CTX_EXPERIMENT_METRICS_FILE

# --- Fail-safe: a zeroed/empty bundle renders well-formed tables, zero exit ---
zero="$tmp/zero.json"
cat > "$zero" <<'EOF'
{
  "schema": "singular.orchestration.ctx-experiment-summary.v0",
  "report": {
    "schema": "singular.orchestration.ctx-experiment-report.v0",
    "arms": {
      "A": {"escapeRate": 0, "accepted": 0, "flagged": 0,
            "cost": {"tasks": 0, "tokensTotal": 0, "wallClockMsTotal": 0,
                     "tokensPerTask": 0, "wallClockMsPerTask": 0}},
      "B": {"escapeRate": 0, "accepted": 0, "flagged": 0,
            "cost": {"tasks": 0, "tokensTotal": 0, "wallClockMsTotal": 0,
                     "tokensPerTask": 0, "wallClockMsPerTask": 0}}
    },
    "bias": {"flaggedFindings": 0, "directionalDisagreements": 0,
             "directionalDisagreementRate": 0}
  },
  "strategy": {
    "schema": "singular.orchestration.ctx-experiment-strategy.v0",
    "hitRates": {
      "overall": {"total": 0, "resume": 0, "rehydrate": 0, "resumeHitRate": 0, "rehydrateHitRate": 0},
      "byArm": {
        "A": {"total": 0, "resume": 0, "rehydrate": 0, "resumeHitRate": 0, "rehydrateHitRate": 0},
        "B": {"total": 0, "resume": 0, "rehydrate": 0, "resumeHitRate": 0, "rehydrateHitRate": 0}
      },
      "byRole": {
        "implementer": {"total": 0, "resume": 0, "rehydrate": 0, "resumeHitRate": 0, "rehydrateHitRate": 0},
        "planner": {"total": 0, "resume": 0, "rehydrate": 0, "resumeHitRate": 0, "rehydrateHitRate": 0},
        "reviewer": {"total": 0, "resume": 0, "rehydrate": 0, "resumeHitRate": 0, "rehydrateHitRate": 0}
      }
    },
    "refusalMix": {"reasonMix": {}, "resumeFailed": 0}
  },
  "attempts": {
    "schema": "singular.orchestration.ctx-experiment-attempts.v0",
    "attemptsToAccept": {
      "A": {"acceptedTasks": 0, "attemptsToAcceptSum": 0, "attemptsToAcceptMean": 0},
      "B": {"acceptedTasks": 0, "attemptsToAcceptSum": 0, "attemptsToAcceptMean": 0}
    },
    "findingsPerAttempt": {
      "A": {"attempts": 0, "findingsTotal": 0, "findingsPerAttemptMean": 0},
      "B": {"attempts": 0, "findingsTotal": 0, "findingsPerAttemptMean": 0}
    }
  }
}
EOF
zero_md="$(singular_ctx_experiment_render_md "$zero")" \
  || fail "renderer exited non-zero on a zeroed bundle (should fail safe)"
[[ -n "$zero_md" ]] || fail "zeroed bundle rendered empty output (not well-formed)"
# Well-formed tables: each section header + separator + zero-valued rows present.
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
    *) fail "zeroed bundle table missing well-formed row: $needle" ;;
  esac
done

# --- STDOUT ONLY / read-only: fixture tree + sibling engine files unchanged,
# no experiment-report.md created or mutated ---------------------------------
after="$(tree_hash "$indir")"
[[ "$before" == "$after" ]] || fail "input fixture tree mutated (renderer is not read-only vs its inputs)"
[[ "$m_before" == "$(file_hash "$SIB_METRICS")" ]]  || fail "engine/ctx-metrics.sh was mutated"
[[ "$r_before" == "$(file_hash "$SIB_REPORT")" ]]   || fail "engine/ctx-experiment-report.sh was mutated"
[[ "$s_before" == "$(file_hash "$SIB_STRATEGY")" ]] || fail "engine/ctx-experiment-strategy.sh was mutated"
[[ "$a_before" == "$(file_hash "$SIB_ATTEMPTS")" ]] || fail "engine/ctx-experiment-attempts.sh was mutated"
[[ "$u_before" == "$(file_hash "$SIB_SUMMARY")" ]]  || fail "engine/ctx-experiment-summary.sh was mutated"
[[ "$report_before" == "$(report_state)" ]] \
  || fail "renderer created or mutated docs/context-build-plan/experiment-report.md (must not)"

echo "ctx-experiment-render tests passed"
