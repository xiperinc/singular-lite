#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
command="npm test"
command_sha="$(printf '%s' "$command" | shasum -a 256 | awk '{print $1}')"
printf 'known failure\n' >"$tmp/gate.log"
cat >"$tmp/observation.json" <<'JSON'
{
  "schema": "singular.orchestration.gate-observation.v0",
  "failures": [{"signature": "known-1", "title": "known failure"}]
}
JSON
cat >"$tmp/baseline.json" <<JSON
{
  "schema": "singular.orchestration.gate-baseline.v0",
  "commandSha256": "$command_sha",
  "failures": [
    {"signature": "known-1", "title": "known failure"},
    {"signature": "resolved-1", "title": "already fixed"}
  ],
  "acknowledgedBy": "owner",
  "recordedAt": "2026-07-24T10:00:00Z"
}
JSON

python3 "$ROOT/engine/gate_report.py" \
  --task-id TASK-0001 --run-id RUN-1 \
  --head-sha 0123456789012345678901234567890123456789 \
  --command "$command" --raw-exit-code 1 \
  --log-ref gate.log --log-path "$tmp/gate.log" \
  --observation "$tmp/observation.json" --baseline "$tmp/baseline.json" \
  --output "$tmp/report.json" >/dev/null

python3 - "$tmp/report.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data["outcome"] == "passed-with-acknowledged-baseline"
assert [f["signature"] for f in data["expectedFailures"]] == ["known-1"]
assert data["unexpectedFailures"] == []
assert [f["signature"] for f in data["resolvedExpectedFailures"]] == ["resolved-1"]
PY

python3 - "$tmp/observation.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["failures"].append({"signature": "new-1"})
json.dump(data, open(path, "w"))
PY
python3 "$ROOT/engine/gate_report.py" \
  --task-id TASK-0001 --run-id RUN-2 \
  --head-sha 0123456789012345678901234567890123456789 \
  --command "$command" --raw-exit-code 1 \
  --log-ref gate.log --log-path "$tmp/gate.log" \
  --observation "$tmp/observation.json" --baseline "$tmp/baseline.json" \
  --output "$tmp/report-new.json" >/dev/null
[[ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["outcome"])' "$tmp/report-new.json")" == "failed-product" ]]

# A genuine unexpected failure wins over an unrelated infrastructure signal.
python3 - "$tmp/observation.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["infrastructureFailure"] = True
data["infrastructureReason"] = "cache permission warning"
json.dump(data, open(path, "w"))
PY
python3 "$ROOT/engine/gate_report.py" \
  --task-id TASK-0001 --run-id RUN-mixed \
  --head-sha 0123456789012345678901234567890123456789 \
  --command "$command" --raw-exit-code 1 \
  --log-ref gate.log --log-path "$tmp/gate.log" \
  --observation "$tmp/observation.json" --baseline "$tmp/baseline.json" \
  --output "$tmp/report-mixed.json" >/dev/null
[[ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["outcome"])' "$tmp/report-mixed.json")" == "failed-product" ]]

if python3 "$ROOT/engine/gate_report.py" \
  --task-id TASK-0001 --run-id RUN-3 \
  --head-sha 0123456789012345678901234567890123456789 \
  --command "changed command" --raw-exit-code 1 \
  --log-ref gate.log --log-path "$tmp/gate.log" \
  --observation "$tmp/observation.json" --baseline "$tmp/baseline.json" \
  --output "$tmp/report-stale.json" >/dev/null 2>&1; then
  echo "stale baseline command hash must fail closed" >&2
  exit 1
fi

# An acknowledged baseline cannot infer "resolved" from a missing strict
# observation, even when the raw command happens to exit zero.
if python3 "$ROOT/engine/gate_report.py" \
  --task-id TASK-0001 --run-id RUN-missing \
  --head-sha 0123456789012345678901234567890123456789 \
  --command "$command" --raw-exit-code 0 \
  --log-ref gate.log --log-path "$tmp/gate.log" \
  --baseline "$tmp/baseline.json" \
  --output "$tmp/report-missing.json" >/dev/null 2>&1; then
  echo "missing strict observation with a baseline must fail closed" >&2
  exit 1
fi

# A PASSING gate that emits no observation passes. The strict observation is a
# baseline-reconciliation input, not a universal precondition.
#
# This used to assert the opposite — exit 20 and inconclusive-infrastructure —
# and that assertion was the bug, written down. schemaVersion v2 implied
# --require-observation for every gate, and gate_report.py raises before it
# reads the exit code, so a green suite normalized to infrastructure-broken,
# which the decider parks unconditionally. Nothing shipped or documented an
# emitter: `singular init` suggests `npm test && npm run build`, which cannot
# satisfy it. Every task in every fresh v2 repo parked on a passing gate.
strict_missing_rc=0
SINGULAR_ROOT="$ROOT" \
SINGULAR_STATE_DIR="$tmp/state" \
SINGULAR_EVENTS_FILE="$tmp/state/events.ndjson" \
  "$ROOT/engine/gate-check.sh" RUN-strict-missing \
    --task-id TASK-0001 -- true >"$tmp/strict-missing.out" 2>&1 \
  || strict_missing_rc=$?
[[ "$strict_missing_rc" -eq 0 ]] || {
  echo "a green v2 gate without an observation must pass, got exit $strict_missing_rc" >&2
  cat "$tmp/strict-missing.out" >&2
  exit 1
}
python3 - "$tmp/state/runs/RUN-strict-missing/gate-report.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
assert data["outcome"] == "passed", data["outcome"]
assert data["rawExitCode"] == 0
PY

# ...but once a baseline IS registered, the observation becomes load-bearing —
# expected/unexpected classification is impossible without it — so gate-check
# must still fail closed rather than silently treat acknowledged failures as
# absent. This is the invariant the blanket requirement was over-applying.
baseline_missing_rc=0
SINGULAR_ROOT="$ROOT" \
SINGULAR_STATE_DIR="$tmp/state" \
SINGULAR_EVENTS_FILE="$tmp/state/events.ndjson" \
SINGULAR_GATE_BASELINE_FILE="$tmp/baseline.json" \
  "$ROOT/engine/gate-check.sh" RUN-baseline-missing \
    --task-id TASK-0001 -- true >"$tmp/baseline-missing.out" 2>&1 \
  || baseline_missing_rc=$?
[[ "$baseline_missing_rc" -ne 0 ]] || {
  echo "a registered baseline without an observation must fail closed" >&2
  cat "$tmp/baseline-missing.out" >&2
  exit 1
}
python3 - "$tmp/state/runs/RUN-baseline-missing/gate-report.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
assert data["outcome"] == "inconclusive-infrastructure", data["outcome"]
assert "gate-report-normalization-failed" in data["infrastructureSignals"]
PY

# Explicit legacy schema mode retains the v0 exit-code-only adapter while old
# consumers migrate; strict observation enforcement is a v2 write policy.
mkdir -p "$tmp/legacy"
cat >"$tmp/legacy/singular.config.json" <<'JSON'
{
  "schemaVersion": "v1",
  "targetBranch": "main",
  "gateCommand": "true"
}
JSON
legacy_rc=0
SINGULAR_ROOT="$tmp/legacy" \
SINGULAR_ENGINE_HOME="$ROOT" \
SINGULAR_STATE_DIR="$tmp/legacy-state" \
SINGULAR_EVENTS_FILE="$tmp/legacy-state/events.ndjson" \
  "$ROOT/engine/gate-check.sh" RUN-legacy \
    --task-id TASK-0001 -- true >"$tmp/legacy.out" 2>&1 \
  || legacy_rc=$?
[[ "$legacy_rc" -eq 0 ]] || {
  echo "explicit v1 gate compatibility should accept a clean zero exit" >&2
  cat "$tmp/legacy.out" >&2
  exit 1
}
[[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["outcome"])' \
  "$tmp/legacy-state/runs/RUN-legacy/gate-report.json")" == "passed" ]]

# The gate wrapper emits a durable stale-baseline warning when every expected
# failure has disappeared from a valid strict observation.
cat >"$tmp/resolved-gate.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"schema":"singular.orchestration.gate-observation.v0","failures":[]}' \
  >"$SINGULAR_GATE_REPORT_FILE"
SH
chmod +x "$tmp/resolved-gate.sh"
resolved_command="$tmp/resolved-gate.sh"
resolved_command_sha="$(printf '%s' "$resolved_command" | shasum -a 256 | awk '{print $1}')"
cat >"$tmp/resolved-baseline.json" <<JSON
{
  "schema": "singular.orchestration.gate-baseline.v0",
  "commandSha256": "$resolved_command_sha",
  "failures": [{"signature": "known-1"}],
  "acknowledgedBy": "owner",
  "recordedAt": "2026-07-24T10:00:00Z"
}
JSON
wrapper_output="$(
  SINGULAR_ROOT="$ROOT" \
  SINGULAR_STATE_DIR="$tmp/state" \
  SINGULAR_EVENTS_FILE="$tmp/state/events.ndjson" \
  SINGULAR_GATE_BASELINE_FILE="$tmp/resolved-baseline.json" \
    "$ROOT/engine/gate-check.sh" RUN-resolved \
      --task-id TASK-0001 -- "$resolved_command" 2>&1
)"
[[ "$wrapper_output" == *"acknowledged gate baseline failure(s) are now resolved"* ]]
grep -q '"type":"gate.baseline_stale"' "$tmp/state/events.ndjson"

# Evidence-only verification requires the report's composite binding; a report
# with individually plausible fields but no binding must fail closed.
printf 'verified log\n' >"$tmp/verified.log"
python3 "$ROOT/engine/gate-report.py" create \
  --output "$tmp/verified-report.json" \
  --task-id TASK-0001 --run-id RUN-verified \
  --head-sha 0123456789012345678901234567890123456789 \
  --command "npm test" --exit-code 0 --log "$tmp/verified.log" \
  --integrity-status verified >/dev/null
python3 "$ROOT/engine/gate-report.py" verify-evidence \
  --report "$tmp/verified-report.json" \
  --expected-head 0123456789012345678901234567890123456789 \
  --expected-command "npm test"
python3 - "$tmp/verified-report.json" <<'PY'
import json
import sys

path = sys.argv[1]
report = json.load(open(path, encoding="utf-8"))
report.pop("evidenceBindingSha256")
with open(path, "w", encoding="utf-8") as stream:
    json.dump(report, stream)
PY
if python3 "$ROOT/engine/gate-report.py" verify-evidence \
  --report "$tmp/verified-report.json" \
  --expected-head 0123456789012345678901234567890123456789 \
  --expected-command "npm test" >/dev/null 2>&1
then
  echo "missing gate report evidence binding must fail verification" >&2
  exit 1
fi

# A gate that could not RUN is infrastructure, not a product defect — on the v2
# path too. The log heuristics existed only in engine/gate-report.py, a module
# the v2 normalizer never calls, so every non-zero gate without an adapter report
# normalized to failed-product. A disposable audit worktree missing its
# dependencies therefore read as a code defect, and the decider spent the entire
# retry budget asking a model to fix code that was never broken.
classify() { # <log text> -> "<outcome> <signals>"
  printf '%s\n' "$1" >"$tmp/classify.log"
  python3 "$ROOT/engine/gate_report.py" \
    --task-id TASK-0001 --run-id RUN-classify \
    --head-sha 0123456789012345678901234567890123456789 \
    --command "npm test" --raw-exit-code 1 \
    --log-ref gate.log --log-path "$tmp/classify.log" \
    --output "$tmp/classify.json" >/dev/null
  python3 - "$tmp/classify.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
print(data["outcome"], ",".join(data["infrastructureSignals"]))
PY
}

# TS2688 signals a missing dependency: a worktree without the
# monorepo's nested node_modules cannot resolve the @types tsconfig asks for.
[[ "$(classify "error TS2688: Cannot find type definition file for 'node'.")" \
   == "inconclusive-infrastructure missing-type-definitions" ]] \
  || { echo "TS2688 must classify as infrastructure, not a product defect" >&2; exit 1; }
[[ "$(classify "Error: ENOSPC: no space left on device, write")" \
   == "inconclusive-infrastructure disk-full" ]] \
  || { echo "a full disk must not read as a product defect" >&2; exit 1; }

# The other direction matters more, and is why the pattern table has a scope
# column. An infrastructure verdict maps to audit-infra, which the decider parks
# UNCONDITIONALLY — it does not even consult the retry budget. So a signature
# that ordinary application code can produce must NOT be trusted here, or fixing
# a budget-burn bug would have bought a task-death bug. All three below are
# everyday product failures.
for product_log in \
  "Error: ENOENT: no such file or directory, open 'fixtures/a.json'" \
  "AggregateError: ECONNREFUSED 127.0.0.1:5432" \
  "Error: EACCES: permission denied, open '/tmp/out'" \
  "AssertionError: expected 1 to equal 2"
do
  [[ "$(classify "$product_log")" == "failed-product "* ]] || {
    echo "a product failure must not be parked as infrastructure: $product_log" >&2
    exit 1
  }
done

# The v0 adapter keeps the full table, strict plus heuristic, because there the
# classification only annotates a result rather than deciding a task's fate.
python3 - "$ROOT/engine" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import infra_patterns

strict = {label for label, _ in infra_patterns.load(infra_patterns.STRICT)}
every = {label for label, _ in infra_patterns.load(infra_patterns.ALL)}
assert strict, "strict tier is empty"
assert "missing-type-definitions" in strict, "TS2688 must reach the v2 path"
assert "network" in every - strict, "network must stay heuristic-only"
assert "missing-path" in every - strict, "ENOENT must stay heuristic-only"
assert "permission-denied" in every - strict, "EACCES must stay heuristic-only"
PY

# A hung gate is killed, tree and all, and reported as infrastructure.
#
# There was no bound at all here: no timeout, no watchdog, no kill. A gate
# waiting on a port or a package-manager prompt held the worker slot forever,
# and because the STOP sentinel is only checked between cycles, one hung gate
# made cooperative STOP never work.
cat >"$tmp/hanging-gate.sh" <<'SH'
#!/usr/bin/env bash
# The sleep is a grandchild: killing only the direct child leaves it running,
# which is the whole reason this uses a kill-tree.
bash -c 'sleep 45; touch "$1"' _ "$1" &
wait
SH
chmod +x "$tmp/hanging-gate.sh"
hang_marker="$tmp/hang.marker"
hang_rc=0
hang_start=$SECONDS
SINGULAR_ROOT="$ROOT" \
SINGULAR_STATE_DIR="$tmp/state" \
SINGULAR_EVENTS_FILE="$tmp/state/events.ndjson" \
SINGULAR_GATE_TIMEOUT_SEC=3 \
SINGULAR_KILL_GRACE_SEC=1 \
  "$ROOT/engine/gate-check.sh" RUN-hang --task-id TASK-0001 -- \
    "$tmp/hanging-gate.sh" "$hang_marker" >"$tmp/hang.out" 2>&1 || hang_rc=$?
hang_elapsed=$((SECONDS - hang_start))
[[ "$hang_elapsed" -lt 30 ]] || {
  echo "a hung gate must be killed at the timeout, took ${hang_elapsed}s" >&2
  exit 1
}
[[ "$hang_rc" -eq 20 ]] || {
  echo "a timed-out gate must be inconclusive-infrastructure (exit 20), got $hang_rc" >&2
  cat "$tmp/hang.out" >&2
  exit 1
}
python3 - "$tmp/state/runs/RUN-hang/gate-report.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
assert data["outcome"] == "inconclusive-infrastructure", data["outcome"]
# 124 already maps to gate-command-timeout, so a hung gate never reaches a model
# as a product defect to fix.
assert "gate-command-timeout" in data["infrastructureSignals"], data["infrastructureSignals"]
PY
sleep 4   # past nothing in particular; the grandchild had 45s of work to do
[[ ! -e "$hang_marker" ]] || {
  echo "the gate's grandchild survived the timeout kill" >&2
  exit 1
}

# Zero disables the bound, for a consumer whose gate is legitimately unbounded.
fast_rc=0
SINGULAR_ROOT="$ROOT" \
SINGULAR_STATE_DIR="$tmp/state" \
SINGULAR_EVENTS_FILE="$tmp/state/events.ndjson" \
SINGULAR_GATE_TIMEOUT_SEC=0 \
  "$ROOT/engine/gate-check.sh" RUN-unbounded --task-id TASK-0001 -- true \
  >"$tmp/unbounded.out" 2>&1 || fast_rc=$?
[[ "$fast_rc" -eq 0 ]] || {
  echo "SINGULAR_GATE_TIMEOUT_SEC=0 must run the gate unbounded and pass, got $fast_rc" >&2
  cat "$tmp/unbounded.out" >&2
  exit 1
}

echo "gate report tests passed"
