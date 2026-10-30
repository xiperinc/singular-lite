#!/usr/bin/env bash
# Non-destructive promotion canary for orchestration regressions.
# Intentionally excluded from tests/run.sh because it composes focused tests
# that the ordinary suite already executes separately.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAPTURE="$ROOT/tests/fixtures/field-report/synthetic-26.capture.v0.json"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p "$repo"
git -C "$tmp" init -q repo
printf ".singular-state/\n" >"$repo/.gitignore"
printf '{"schemaVersion":"v2","targetBranch":"main"}\n' \
  >"$repo/singular.config.json"

printf 'CANARY %-32s' "synthetic-26-node-replay"
replay_log="$tmp/captured-replay.log"
if ! python3 "$ROOT/tests/field_report_canary_replay.py" \
  --root "$ROOT" --repo "$repo" --capture "$CAPTURE" \
  >"$replay_log" 2>&1; then
  printf ' FAIL\n'
  cat "$replay_log" >&2
  exit 1
fi
printf ' PASS\n'

run_case() {
  local label="$1" script="$2"
  local log="$tmp/test-case.log"
  printf 'CANARY %-32s' "$label"
  if ! bash "$ROOT/tests/$script" </dev/null >"$log" 2>&1; then
    printf ' FAIL\n'
    cat "$log" >&2
    return 1
  fi
  printf ' PASS\n'
}

# Lifecycle and diagnostic presentation are release requirements, not optional
# smoke checks. The captured replay exercises every phase/category through
# health; these focused contracts keep both public surfaces independently bound.
run_case "run-status-lifecycle" "test-run-status.sh"
run_case "diagnostic-category-rendering" "test-ops-health.sh"

# The ten named field-report regressions. The provider contract test is run once
# because it jointly proves scenarios 2 and 3 across every built-in adapter.
run_case "1-critique-revision-parser" "test-ctx-plan-revision.sh"
printf 'CANARY %-32s' "2-legal-prose-no-backoff"
provider_log="$tmp/provider-contract.log"
if ! bash "$ROOT/tests/test-provider-failure-contract.sh" \
  </dev/null >"$provider_log" 2>&1; then
  printf ' FAIL\n'
  cat "$provider_log" >&2
  exit 1
fi
printf ' PASS\n'
printf 'CANARY %-32s PASS\n' "3-structured-provider-quota"
run_case "4-auditor-cache-immutable" "test-audit-verification.sh"
run_case "5-idle-snapshot-bound" "test-control-commit-throttle.sh"
run_case "6-optional-mcp-warning-once" "test-doctor-json.sh"
run_case "7-large-assertion-truncated" "test-evidence-manifest.sh"
run_case "8-acknowledged-inherited" "test-gate-report.sh"
run_case "9-adaptive-disk-concurrency" "test-resource-bootstrap.sh"
run_case "10-human-artifact-invalidation" "test-human-gate.sh"

# Provider, evidence-path and DAG-diagnostic regression cases.
# Each is a case of the engine holding the right information and discarding it.
#
# 11: a 503/529 was classified `overloaded` and then bucketed as `quota`, so a
#     capacity blip selected the 1800s usage-limit window -- and because that nap
#     `continue`s past reconcile, it idled the whole graph for half an hour.
# 12: gate-check.sh cited an absolute logRef, which dag.sh's safe_repo_artifact
#     rejects before any other check, so no report the engine produced could ever
#     back a deterministic-proof gate-result.
# 13: dag.sh's precise diagnostic went to /dev/null at every call site, so an
#     invalid DAG was indistinguishable from having no ready work.
run_case "11-provider-overload-class" "test-provider-failure-contract.sh"
run_case "12-strict-gate-evidence-path" "test-gate-strict-evidence-path.sh"
run_case "13-dag-evaluation-diagnostics" "test-dag-evaluation-diagnostics.sh"

# Planner concurrency and graph validation regression cases.
#
# 14: concurrent L1 planners shared one origin run id, so run-status.sh (which
#     keys its path on the id alone) let them race on a single record and
#     `health` could never report more than one of them.
# 15: the shipped promoter registers only its own project's node ids and
#     silently skipped everything else in frontier mode, so a consumer's graph
#     stalled with `no promotable frontier gates` as the only symptom.
# 16: dag.sh reported one contract violation per run, each hiding the next.
run_case "14-parallel-planner-visibility" "test-l1-parallel.sh"
run_case "15-graph-promotability" "test-graph-promotability.sh"
run_case "16-gate-validate-all-violations" "test-gate-validate-verb.sh"

echo "FIELD-REPORT CANARY PASS: synthetic events/artifacts + 26-node run + 16 regression scenarios"
