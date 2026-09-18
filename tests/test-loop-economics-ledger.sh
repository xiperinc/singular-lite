#!/usr/bin/env bash
set -euo pipefail
# Instrumentation for the 0.23.3 proof bar.
#
# Two things the loop could not evidence about itself:
#
# (a) Scheduler reservation refusals advanced no counter the breaker reads.
#     reconcile logged origin.reservation_refused and moved on; autonomate never
#     looked. A task refused every cycle spun at the poll interval with no bound
#     and no park (field 2026-09-14: 28 refusals in nine minutes). The count must
#     key on a STABLE condition: keying on runId or reservation generation would
#     reset it every attempt, which is exactly why the spin was unbounded.
#
# (b) runner.completed could not support a cost-per-landed-change figure. It
#     carried no task lineage (only a runId, so planner and decider calls were
#     attributed to whichever task shared their scheduler run), no host wall time
#     as distinct from provider duration, and no way to tell absent usage from
#     zero usage -- which understates spend and silently biases every aggregate
#     built on it.
#
# Without these the qualification campaign cannot evidence "no supervisor
# action", which is the bar 0.23.3 exists to make measurable.
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-loop-economics-ledger.sh requires bash >= 4" >&2; exit 1
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT/engine"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"; mkdir -p "$repo"; git -C "$repo" init -q
git -C "$repo" commit -q --allow-empty -m base
export SINGULAR_ROOT="$repo" SINGULAR_STATE_DIR="$repo/.singular-state"
source "$ROOT/engine/lib.sh" >/dev/null
singular_ensure_state_dirs

field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | tail -1; }

# --- (a) 1. the same condition accumulates; a different one restarts ---------
out="$(singular_refusal_note TASK-6001 'reservation refused: behind base sha deadbeef1234 run RUN-AAA')"
[[ "$(field "$out" count)" == 1 ]] || fail "first refusal did not count: $out"
[[ "$(field "$out" new)" == yes ]] || fail "first refusal was not a new condition: $out"
[[ "$(field "$out" park)" == no ]] || fail "first refusal parked immediately: $out"

# Same condition, different run id / sha / generation. These MUST normalize to
# the same key -- keying on them is what made the spin unbounded.
out="$(singular_refusal_note TASK-6001 'reservation refused: behind base sha 99887766aabb run RUN-BBB')"
[[ "$(field "$out" count)" == 2 ]] || fail "a varying run id restarted the count: $out"
[[ "$(field "$out" new)" == no ]] || fail "the same condition was treated as new: $out"
pass "refusal accounting keys on the condition, not on the run id or sha"

# --- (a) 2. the threshold parks -------------------------------------------
out="$(singular_refusal_note TASK-6001 'reservation refused: behind base sha cafebabe0001 run RUN-CCC')"
[[ "$(field "$out" count)" == 3 ]] || fail "third refusal miscounted: $out"
[[ "$(field "$out" park)" == yes ]] || fail "threshold did not request a park: $out"
pass "a repeatedly refused condition reaches the park threshold"

# --- (a) 3. a genuinely different condition restarts the count --------------
out="$(singular_refusal_note TASK-6001 'reservation refused: terminal or started work requires explicit successor authority')"
[[ "$(field "$out" count)" == 1 ]] || fail "a different condition did not restart the count: $out"
[[ "$(field "$out" new)" == yes ]] || fail "a different condition was not reported as new: $out"
pass "a different refusal condition restarts the count"

# --- (a) 4. progress clears the history ------------------------------------
singular_refusal_note TASK-6001 'reservation refused: terminal or started work requires explicit successor authority' >/dev/null
singular_refusal_clear TASK-6001
out="$(singular_refusal_note TASK-6001 'reservation refused: terminal or started work requires explicit successor authority')"
[[ "$(field "$out" count)" == 1 ]] || fail "a successful reservation did not clear refusal history: $out"
pass "a successful reservation clears the refusal history"

# --- (a) 5. the breaker actually reads the refusal counter ------------------
grep -q 'new_refusals_this_run' "$SCRIPT_DIR/reconcile.sh" \
  || fail "reconcile does not publish a refusal counter"
grep -q 'new_refusals="\$(field new_refusals_this_run)"' "$SCRIPT_DIR/autonomate.sh" \
  || fail "autonomate does not read the refusal counter"
grep -q '"\$new_refusals" -gt 0' "$SCRIPT_DIR/autonomate.sh" \
  || fail "the breaker failure branch ignores new refusals"
# Refusals are deterministic host decisions, never provider-limit evidence.
python3 - "$SCRIPT_DIR/autonomate.sh" <<'PY' || exit 1
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"limit_eligible=\$\(\((.*?)\)\)", src, re.S)
assert m, "limit_eligible not found"
assert "new_refusals" not in m.group(1), \
    "refusals were counted as provider-limit evidence: " + m.group(1)
PY
pass "the breaker counts new refusals and never treats them as provider-limit evidence"

# --- (b) missing usage is distinguishable from zero usage -------------------
emit() {
  local result="$1"
  SINGULAR_ATTEMPT_TASK_ID="${2:-}" SINGULAR_RUNNER_OPERATION_ID="${3:-}" \
  SINGULAR_RUNNER_HOST_STARTED_EPOCH="${4:-}" \
  python3 - "$result" <<'PY'
import json, os, sys, time
path = sys.argv[1]
result = json.load(open(path, encoding="utf-8"))
record = {"runnerResultRef": path, "provider": result.get("provider")}
for f, v in (("taskId", os.environ.get("SINGULAR_ATTEMPT_TASK_ID", "")),
             ("operationId", os.environ.get("SINGULAR_RUNNER_OPERATION_ID", ""))):
    if v:
        record[f] = v
started = os.environ.get("SINGULAR_RUNNER_HOST_STARTED_EPOCH", "")
if started.isdigit():
    record["hostWallSeconds"] = max(0, int(time.time()) - int(started))
d = result.get("durationSeconds")
if isinstance(d, (int, float)):
    record["providerDurationSeconds"] = d
usage = result.get("usage")
if isinstance(usage, dict):
    record["usage"] = usage
    missing = [f for f in ("inputTokens", "outputTokens")
               if not isinstance(usage.get(f), (int, float))]
    record["usageComplete"] = not missing
    if missing:
        record["usageMissingFields"] = missing
else:
    record["usageComplete"] = False
    record["usageMissingFields"] = ["usage"]
print(json.dumps(record))
PY
}
# The emitter above mirrors engine/lib.sh; assert the real file agrees so the
# two cannot drift apart.
for needle in usageComplete usageMissingFields hostWallSeconds providerDurationSeconds operationId; do
  grep -q "$needle" "$SCRIPT_DIR/lib.sh" || fail "lib.sh does not record $needle"
done
grep -q 'SINGULAR_ATTEMPT_TASK_ID' "$SCRIPT_DIR/lib.sh" || fail "lib.sh records no task lineage"

printf '%s\n' '{"provider":"claude","usage":{"inputTokens":10,"outputTokens":20},"durationSeconds":7}' >"$tmp/complete.json"
printf '%s\n' '{"provider":"claude","usage":{"inputTokens":10}}' >"$tmp/partial.json"
printf '%s\n' '{"provider":"claude"}' >"$tmp/absent.json"

rec="$(emit "$tmp/complete.json" TASK-6002 op-1 "$(( $(date +%s) - 5 ))")"
[[ "$(python3 -c 'import json,sys;print(json.loads(sys.stdin.read())["usageComplete"])' <<<"$rec")" == True ]] \
  || fail "complete usage was not marked complete: $rec"
[[ "$(python3 -c 'import json,sys;print(json.loads(sys.stdin.read())["taskId"])' <<<"$rec")" == TASK-6002 ]] \
  || fail "task lineage missing: $rec"
[[ "$(python3 -c 'import json,sys;print(json.loads(sys.stdin.read())["providerDurationSeconds"])' <<<"$rec")" == 7 ]] \
  || fail "provider duration missing: $rec"
hw="$(python3 -c 'import json,sys;print(json.loads(sys.stdin.read())["hostWallSeconds"])' <<<"$rec")"
[[ "$hw" -ge 5 ]] || fail "host wall time was not measured independently of provider duration: $rec"
[[ "$hw" != 7 ]] || fail "host wall time was taken from the provider duration"
pass "host wall time and provider duration are recorded as separate measurements"

rec="$(emit "$tmp/partial.json")"
[[ "$(python3 -c 'import json,sys;print(json.loads(sys.stdin.read())["usageComplete"])' <<<"$rec")" == False ]] \
  || fail "partial usage was reported as complete: $rec"
[[ "$rec" == *outputTokens* ]] || fail "the missing usage field was not named: $rec"
rec="$(emit "$tmp/absent.json")"
[[ "$(python3 -c 'import json,sys;print(json.loads(sys.stdin.read())["usageComplete"])' <<<"$rec")" == False ]] \
  || fail "absent usage was reported as complete: $rec"
python3 -c 'import json,sys; d=json.load(sys.stdin); assert "usage" not in d, d' <<<"$rec" \
  || fail "absent usage was materialized rather than left out: $rec"
pass "missing usage is distinguishable from zero usage and is never filled in"

echo "test-loop-economics-ledger: ok"
