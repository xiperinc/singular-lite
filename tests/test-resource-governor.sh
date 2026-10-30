#!/usr/bin/env bash
set -euo pipefail

# Machine-aware resource governor.
#
# Field evidence (a 12-core / 24 GiB host shared with other heavy processes):
# a fixed ceiling of 3 left the machine mostly idle, a fixed 5 plus a test
# suite pushed the 1-minute load to 13 and long planner/critic calls started
# failing as infrastructure failures. A fixed number is wrong in both
# directions, so `auto` sizes the worker ceiling from the machine and a
# separate live-pressure gate stops ADMITTING work while it is saturated.
#
# Everything here injects the machine facts. Nothing depends on the host this
# runs on: cores, available memory, load and CPU utilisation all arrive as
# flags. A case that injects the load and no CPU fraction exercises the
# load-average fallback: the real CPU is never sampled here.

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"
GIB=1073741824

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in output"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2'"; }
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | tail -1; }
# jget '<json>' key -> the value as JSON (null, 3, "cpu-bound", ...)
jget() { python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1]).get(sys.argv[2])))' "$1" "$2"; }
assert_json() { # <json> <key> <expected-json> <label>
  local got; got="$(jget "$1" "$2")"
  [[ "$got" == "$3" ]] || fail "$4: $2 = $got, want $3 in $1"
}

tmp="$(mktemp -d)"
root="$tmp/repo"

mkdir -p "$root/docs/orchestration/tasks" "$root/docs/orchestration/gates" \
  "$root/docs/orchestration/areas/core" "$root/docs/orchestration/packets/imported" \
  "$root/docs/orchestration/prompts" "$root/schemas/orchestration" "$root/.singular-state"
git -C "$root" init -q
git -C "$root" checkout -q -b target
for s in dag task-batch state-packet audit-verdict decider-verdict gate-result; do
  cp "$ENGINE_HOME/schemas/$s.v0.schema.json" "$root/schemas/orchestration/" 2>/dev/null || true
done
cp "$ENGINE_HOME/templates/prompts/l1-planner.md" "$root/docs/orchestration/prompts/" 2>/dev/null || true
cat >"$root/docs/orchestration/dag.v0.json" <<'EOF'
{"schema":"singular.orchestration.dag.v0","nodes":[
 {"id":"D0.contract","stage":"D0","area":"core","layer":"contract","kind":"contract",
  "dependsOn":[],"requiredCompletion":"contract_complete"}]}
EOF
printf '# Project State\n' >"$root/docs/orchestration/project-state.md"
printf '# Area State: Core\n\nCurrent status: active\n' >"$root/docs/orchestration/areas/core/state.md"
cat >"$root/docs/orchestration/tasks/TASK-0001.md" <<'EOF'
# TASK-0001: governor fixture

Status: ready
Area: core
Target branch: `target`
Worker branch: `agent/core/TASK-0001-governor`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Exercise the resource governor's admission gate.

## Scope

Owned files:

- `src/a.txt`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- Pass.
EOF
git -C "$root" add .
git -C "$root" -c user.name=test -c user.email=test@example.local commit -q -m init

cat >"$tmp/driver.sh" <<SH
#!/usr/bin/env bash
echo "dispatched \$1" >>"$tmp/driver-ran"
# While this file exists the "worker" stays running, so a later cycle sees an
# active lease. Bounded, so a failed test cannot leave a process behind.
for _ in \$(seq 1 600); do
  [[ -f "$tmp/hold-worker" ]] || break
  sleep 0.1
done
SH
cat >"$tmp/promoter.sh" <<SH
#!/usr/bin/env bash
echo "promotion: none"
SH
# A planner that returns a valid empty batch (NO-TASKS), so a cycle that does
# reach it finishes at once instead of walking the import-rejection path.
cat >"$tmp/planner.sh" <<SH
#!/usr/bin/env bash
echo planned >>"$tmp/planner-ran"
stage=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --stage-dir) stage="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -z "\$stage" ]] || { mkdir -p "\$stage"; : >"\$stage/NO-TASKS"; }
exit 0
SH
# No case here may reach a model. Three independent layers, because the first
# version of this file had only stub planners and still reached the real plan
# critic (plan critique ships ON and hands a planner's batch to the critic
# runner):
#   1. planning and dispatch go to the stubs above (SINGULAR_L1_PLAN_NODE,
#      SINGULAR_L1_DRIVER) and SINGULAR_PLAN_CRITIQUE=0;
#   2. the explicit provider binary (SINGULAR_CODEX_BIN) is this tripwire;
#   3. every provider CLI name resolves, first on PATH, to the same tripwire,
#      for every engine call this file makes (engine_env).
# The tripwire records its argv and fails; the last assertion in the file
# checks it never fired.
cat >"$tmp/no-provider.sh" <<SH
#!/usr/bin/env bash
echo "\$(basename "\$0") \$*" >>"$tmp/provider-called"
echo "test-resource-governor: provider CLI invoked: \$(basename "\$0") \$*" >&2
exit 97
SH
chmod +x "$tmp/driver.sh" "$tmp/promoter.sh" "$tmp/planner.sh" "$tmp/no-provider.sh"
mkdir -p "$tmp/shim"
for provider_cli in codex claude opencode gemini cursor-agent grok; do
  cp "$tmp/no-provider.sh" "$tmp/shim/$provider_cli"
done

# Every engine call goes through this: a private repo, a private state dir and
# NO inherited SINGULAR_* (the suite harness pins machine facts through
# SINGULAR_RESOURCE_*; this file must prove its own injection, so they go too).
engine_env() {
  (
    while IFS= read -r _v; do unset "$_v"; done < <(compgen -v | grep '^SINGULAR_' || true)
    env PATH="$tmp/shim:$PATH" SINGULAR_ROOT="$root" \
      SINGULAR_ORCH_DIR="$root/docs/orchestration" \
      SINGULAR_TASKS_DIR="$root/docs/orchestration/tasks" \
      SINGULAR_STATE_DIR="$root/.singular-state" \
      SINGULAR_LEASES_DIR="$root/.singular-state/leases" \
      SINGULAR_INBOX_DIR="$root/.singular-state/inbox" \
      SINGULAR_RUNS_DIR="$root/.singular-state/runs" \
      SINGULAR_WORKTREES_DIR="$root/.worktrees" \
      SINGULAR_EVENTS_FILE="$root/.singular-state/events.ndjson" \
      SINGULAR_ORIGIN_STATE_FILE="$root/.singular-state/origin-state.json" \
      SINGULAR_SCHEMA_DIR="$root/schemas/orchestration" \
      SINGULAR_CONFIG_FILE="$root/singular.config.sh" \
      SINGULAR_LOCAL_CONFIG_FILE="$root/.singular-state/config.local.sh" \
      SINGULAR_TARGET_BRANCH=target \
      "$@"
  )
}

# resource-plan.sh with disk fixed and roomy (100 slots) unless a case says
# otherwise, and a private throttle-state file per call unless one is passed.
plan() {
  engine_env "$SCRIPT_DIR/resource-plan.sh" --json \
    --reserve-bytes 0 --estimated-worktree-bytes 1 --free-bytes 100 \
    --active-workers 0 --governor-state "$tmp/unused-state.json" "$@"
}

cleanup() {
  local rc=$?
  trap - EXIT
  rm -f "$tmp/hold-worker"
  if [[ -d "$root/.singular-state" ]]; then
    engine_env SINGULAR_DRAIN_TIMEOUT_SECS=10 SINGULAR_DRAIN_POLL_SECS=0.05 \
      bash "$SCRIPT_DIR/reconcile.sh" --drain >"$tmp/drain.log" 2>&1 || true
  fi
  rm -rf "$tmp"
  exit "$rc"
}
trap cleanup EXIT

# --- 1. auto ceiling = min(cpu, memory, disk), reason names the binder ------
# 12 cores -> (12 - 2) * 1 = 10, capped at 8. 24 GiB available -> (24 - 2) / 1
# = 22. Disk 100. CPU binds.
p="$(plan --configured-slots auto --cpu-count 12 --available-memory-bytes $((24 * GIB)) --load-1m 0)"
assert_json "$p" mode '"auto"' "auto mode"
assert_json "$p" cpuSlots 8 "cpu slots are capped at 8"
assert_json "$p" memorySlots 22 "memory slots"
assert_json "$p" diskSlots 100 "disk slots"
assert_json "$p" configuredSlots 8 "auto: configured ceiling is the machine ceiling"
assert_json "$p" effectiveSlots 8 "auto: effective is the min of the three"
assert_json "$p" reason '"cpu-bound"' "cpu binds"
assert_json "$p" admission '"open"' "idle machine admits"

# Below the cap the core count itself binds: 6 cores -> 4.
p="$(plan --configured-slots auto --cpu-count 6 --available-memory-bytes $((24 * GIB)) --load-1m 0)"
assert_json "$p" cpuSlots 4 "6 cores leave 4 worker slots"
assert_json "$p" effectiveSlots 4 "small machine"
assert_json "$p" reason '"cpu-bound"' "small machine is cpu-bound"

# Memory binds: 5 GiB available -> (5 - 2) / 1 = 3.
p="$(plan --configured-slots auto --cpu-count 12 --available-memory-bytes $((5 * GIB)) --load-1m 0)"
assert_json "$p" memorySlots 3 "memory slots after reserve"
assert_json "$p" effectiveSlots 3 "memory binds"
assert_json "$p" reason '"memory-bound"' "memory binds"

# Disk binds: room for 2 worktrees only.
p="$(plan --configured-slots auto --cpu-count 12 --available-memory-bytes $((24 * GIB)) --load-1m 0 \
  --free-bytes 2)"
assert_json "$p" diskSlots 2 "disk slots"
assert_json "$p" effectiveSlots 2 "disk binds"
assert_json "$p" configuredSlots 8 "disk does not change the machine ceiling"
assert_json "$p" reason '"disk-bound"' "disk binds"

# A one-core machine still gets a worker; so does a machine with no headroom
# above the memory reserve (admission, not the ceiling, handles that — case 5).
p="$(plan --configured-slots auto --cpu-count 1 --available-memory-bytes $((24 * GIB)) --load-1m 0)"
assert_json "$p" effectiveSlots 1 "ceiling never falls below one for cpu"
p="$(plan --configured-slots auto --cpu-count 12 --available-memory-bytes $((3 * GIB)) --load-1m 0)"
assert_json "$p" effectiveSlots 1 "ceiling never falls below one for memory"

# Running workers already occupy the memory that was measured, so the memory
# ceiling is "running + what still fits" — otherwise a busy healthy machine
# would see its ceiling fall below its own active count.
p="$(plan --configured-slots auto --cpu-count 12 --available-memory-bytes $((5 * GIB)) --load-1m 0 \
  --active-workers 4)"
assert_json "$p" memorySlots 7 "active workers are added back to memory slots"

# Unset means auto.
p="$(plan --cpu-count 6 --available-memory-bytes $((24 * GIB)) --load-1m 0)"
assert_json "$p" mode '"auto"' "unset SINGULAR_MAX_CONCURRENT defaults to auto"
assert_json "$p" effectiveSlots 4 "default auto sizing"
p="$(engine_env SINGULAR_MAX_CONCURRENT=auto "$SCRIPT_DIR/resource-plan.sh" --json \
  --reserve-bytes 0 --estimated-worktree-bytes 1 --free-bytes 100 --active-workers 0 \
  --governor-state "$tmp/unused-state.json" \
  --cpu-count 6 --available-memory-bytes $((24 * GIB)) --load-1m 0)"
assert_json "$p" mode '"auto"' "SINGULAR_MAX_CONCURRENT=auto"

# Tunables: resources{} keys arrive as these env vars.
p="$(engine_env SINGULAR_AUTO_MAX_CONCURRENT=20 SINGULAR_CPU_RESERVE_CORES=0 \
  SINGULAR_WORKERS_PER_CORE=0.5 SINGULAR_ESTIMATED_WORKER_BYTES=$((2 * GIB)) \
  SINGULAR_MEMORY_RESERVE_BYTES=$((4 * GIB)) \
  "$SCRIPT_DIR/resource-plan.sh" --json --configured-slots auto \
  --reserve-bytes 0 --estimated-worktree-bytes 1 --free-bytes 100 --active-workers 0 \
  --governor-state "$tmp/unused-state.json" \
  --cpu-count 12 --available-memory-bytes $((24 * GIB)) --load-1m 0)"
assert_json "$p" cpuSlots 6 "workersPerCore and cpuReserveCores apply"
assert_json "$p" memorySlots 10 "estimatedWorkerBytes and memoryReserveBytes apply"
echo "  ok  auto ceiling is the minimum of cpu, memory and disk"

# --- 2. an explicit integer keeps the old record, byte for byte -------------
# The eight pre-governor fields, in their original order, with their original
# values and reasons — on a machine that auto would have sized very differently.
old_fields() {
  python3 -c '
import json, sys
record = json.loads(sys.argv[1], object_pairs_hook=list)
print(json.dumps(dict(record[:8]), separators=(",", ":")))' "$1"
}
p="$(plan --configured-slots 5 --reserve-bytes 100 --estimated-worktree-bytes 100 --free-bytes 350 \
  --cpu-count 2 --available-memory-bytes $((3 * GIB)) --load-1m 0)"
[[ "$(old_fields "$p")" == '{"schema":"singular.orchestration.resource-plan.v0","configuredSlots":5,"effectiveSlots":2,"freeBytes":350,"reserveBytes":100,"estimatedWorktreeBytes":100,"affordableSlots":2,"reason":"disk-limited-concurrency"}' ]] \
  || fail "explicit, disk-limited: old fields changed: $(old_fields "$p")"
assert_json "$p" mode '"explicit"' "explicit mode"
p="$(plan --configured-slots 5 --cpu-count 2 --available-memory-bytes $((3 * GIB)) --load-1m 0)"
[[ "$(old_fields "$p")" == '{"schema":"singular.orchestration.resource-plan.v0","configuredSlots":5,"effectiveSlots":5,"freeBytes":100,"reserveBytes":0,"estimatedWorktreeBytes":1,"affordableSlots":100,"reason":"configured-capacity-available"}' ]] \
  || fail "explicit, roomy: old fields changed: $(old_fields "$p")"
# CPU and memory are reported for doctor but do not lower an explicit ceiling.
assert_json "$p" cpuSlots 1 "explicit still reports cpu slots"
assert_json "$p" memorySlots 1 "explicit still reports memory slots"
p="$(plan --configured-slots 5 --reserve-bytes 100 --estimated-worktree-bytes 100 --free-bytes 150 \
  --cpu-count 12 --available-memory-bytes $((24 * GIB)) --load-1m 0)"
[[ "$(old_fields "$p")" == '{"schema":"singular.orchestration.resource-plan.v0","configuredSlots":5,"effectiveSlots":0,"freeBytes":150,"reserveBytes":100,"estimatedWorktreeBytes":100,"affordableSlots":0,"reason":"insufficient-disk-after-reserve"}' ]] \
  || fail "explicit, no disk: old fields changed: $(old_fields "$p")"
# Without --json the script still prints the bare effective number.
bare="$(engine_env "$SCRIPT_DIR/resource-plan.sh" --configured-slots 5 --reserve-bytes 100 \
  --estimated-worktree-bytes 100 --free-bytes 350 --governor-state "$tmp/unused-state.json" \
  --cpu-count 12 --available-memory-bytes $((24 * GIB)) --load-1m 0)"
[[ "$bare" == "2" ]] || fail "plain output should be the effective slot count, got '$bare'"
# A value that is neither auto nor an integer is still a usage error.
if plan --configured-slots many >/dev/null 2>&1; then fail "garbage slot count must be rejected"; fi
echo "  ok  explicit integer preserves the pre-governor record"

# --- 3. high load admits nothing new, and recovers with hysteresis ----------
# One worker is running throughout (--active-workers 1): with nothing running
# the minimum-progress floor applies instead, which is case 4b.
state="$tmp/throttle-state.json"
governed() { # <load-1m> [extra flags] — 10 cores, so load/core = load / 10
  local load="$1"; shift
  plan --configured-slots auto --cpu-count 10 --available-memory-bytes $((24 * GIB)) \
    --load-1m "$load" --governor-state "$state" --update-governor-state \
    --active-workers 1 "$@"
}
p="$(governed 14)"                      # 1.4 per core: under the 1.5 high-water mark
assert_json "$p" admission '"open"' "below high-water admits"
assert_json "$p" reason '"cpu-bound"' "below high-water keeps the capacity reason"
p="$(governed 16)"                      # 1.6: over
assert_json "$p" admission '"throttled"' "over high-water throttles"
assert_json "$p" admissionReason '"load-high"' "load is named"
assert_json "$p" reason '"load-high"' "reason names load"
assert_json "$p" capacityReason '"cpu-bound"' "the ceiling's own reason is kept alongside"
assert_json "$p" loadPerCore 1.6 "load per core is reported"
assert_json "$p" effectiveSlots 8 "throttling never changes the ceiling"
p="$(governed 14)"                      # back to 1.4: between the marks, stays shut
assert_json "$p" admission '"throttled"' "hysteresis: still throttled between the marks"
p="$(governed 10.5)"                    # 1.05: still above low-water
assert_json "$p" admission '"throttled"' "hysteresis: still throttled just above low-water"
p="$(governed 9.9)"                     # 0.99: below low-water, resumes
assert_json "$p" admission '"open"' "resumes below low-water"
assert_json "$p" reason '"cpu-bound"' "capacity reason returns"
p="$(governed 14)"                      # and 1.4 admits again now that it is open
assert_json "$p" admission '"open"' "no flapping: open stays open between the marks"

# A read-only caller (health, doctor) sees the throttle but never moves it.
p="$(governed 16)"; assert_json "$p" admission '"throttled"' "re-throttle"
p="$(plan --configured-slots auto --cpu-count 10 --available-memory-bytes $((24 * GIB)) \
  --load-1m 9 --governor-state "$state")"
assert_json "$p" admission '"open"' "a read-only reader computes its own answer"
p="$(governed 14)"
assert_json "$p" admission '"throttled"' "the read-only reader did not clear the stored throttle"
rm -f "$state"

# Marks are tunable, and an explicit ceiling is throttled just the same.
p="$(engine_env SINGULAR_LOAD_HIGH_WATER=1.0 SINGULAR_LOAD_LOW_WATER=0.75 \
  "$SCRIPT_DIR/resource-plan.sh" --json --configured-slots 5 \
  --reserve-bytes 0 --estimated-worktree-bytes 1 --free-bytes 100 --active-workers 1 \
  --governor-state "$tmp/unused-state.json" \
  --cpu-count 12 --available-memory-bytes $((24 * GIB)) --load-1m 13)"
assert_json "$p" admission '"throttled"' "13 on 12 cores throttles at a 1.0 high-water mark"
assert_json "$p" effectiveSlots 5 "explicit ceiling is untouched by the throttle"
p="$(engine_env SINGULAR_RESOURCE_THROTTLE=0 \
  "$SCRIPT_DIR/resource-plan.sh" --json --configured-slots auto \
  --reserve-bytes 0 --estimated-worktree-bytes 1 --free-bytes 100 --active-workers 0 \
  --governor-state "$tmp/unused-state.json" \
  --cpu-count 10 --available-memory-bytes $((1 * GIB)) --load-1m 99)"
assert_json "$p" admission '"open"' "SINGULAR_RESOURCE_THROTTLE=0 disables the live gate"
echo "  ok  high load throttles admission and recovers with hysteresis"

# --- 4. low memory likewise -------------------------------------------------
mem() { # <available GiB, may be fractional via bytes> [flags]
  local bytes="$1"; shift
  plan --configured-slots auto --cpu-count 10 --available-memory-bytes "$bytes" \
    --load-1m 0 --governor-state "$state" --update-governor-state \
    --active-workers 1 "$@"
}
p="$(mem $((3 * GIB)))"
assert_json "$p" admission '"open"' "above the reserve admits"
p="$(mem $((1 * GIB)))"                  # under the 2 GiB reserve
assert_json "$p" admission '"throttled"' "under the memory reserve throttles"
assert_json "$p" reason '"memory-low"' "reason names memory"
assert_json "$p" effectiveSlots 1 "low memory does not zero the ceiling"
p="$(mem $((2 * GIB + GIB / 2)))"        # above reserve, but one worker does not fit yet
assert_json "$p" admission '"throttled"' "hysteresis: stays shut until a worker fits"
p="$(mem $((3 * GIB)))"                  # reserve + one worker
assert_json "$p" admission '"open"' "resumes once reserve + one worker is available"
rm -f "$state"
echo "  ok  low memory throttles admission and recovers with hysteresis"

# --- 4b. minimum-progress floor ---------------------------------------------
# A host saturated by OTHER processes never drops under the low-water mark, so
# a strict hold would stop the loop for good. With nothing of ours running the
# hold admits exactly one unit; with anything running it is strict again.
floor() { # <active workers> <active planners> [flags] — 10 cores at load 16
  local workers="$1" planners="$2"; shift 2
  plan --configured-slots auto --cpu-count 10 --available-memory-bytes $((24 * GIB)) \
    --load-1m 16 --active-workers "$workers" --active-planners "$planners" "$@"
}
p="$(floor 0 0)"                         # saturated + idle -> one unit
assert_json "$p" admission '"floor"' "saturated and idle: floor"
assert_json "$p" progressFloor true "saturated and idle: progressFloor"
assert_json "$p" reason '"load-high-floor"' "saturated and idle: reason"
assert_json "$p" admissionReason '"load-high"' "the underlying pressure is still named"
assert_json "$p" effectiveSlots 8 "the floor does not change the ceiling"
p="$(floor 1 0)"                         # saturated + one worker running -> strict hold
assert_json "$p" admission '"throttled"' "saturated with a worker running: hold"
assert_json "$p" progressFloor false "saturated with a worker running: no floor"
assert_json "$p" reason '"load-high"' "saturated with a worker running: reason"
p="$(floor 0 1)"                         # a running planner is work too
assert_json "$p" admission '"throttled"' "saturated with a planner running: hold"
assert_json "$p" progressFloor false "saturated with a planner running: no floor"
p="$(engine_env SINGULAR_PROGRESS_FLOOR=0 "$SCRIPT_DIR/resource-plan.sh" --json \
  --configured-slots auto --reserve-bytes 0 --estimated-worktree-bytes 1 --free-bytes 100 \
  --governor-state "$tmp/unused-state.json" --active-workers 0 --active-planners 0 \
  --cpu-count 10 --available-memory-bytes $((24 * GIB)) --load-1m 16)"
assert_json "$p" admission '"throttled"' "floor disabled: strict hold even when idle"
assert_json "$p" progressFloor false "floor disabled: progressFloor"
assert_json "$p" reason '"load-high"' "floor disabled: reason"
p="$(plan --configured-slots auto --cpu-count 10 --available-memory-bytes $((1 * GIB)) --load-1m 0 \
  --active-workers 0 --active-planners 0)"
assert_json "$p" reason '"memory-low-floor"' "low memory and idle: floor"
assert_json "$p" progressFloor true "low memory and idle: progressFloor"
p="$(plan --configured-slots auto --cpu-count 10 --available-memory-bytes $((24 * GIB)) --load-1m 0 \
  --active-workers 0 --active-planners 0)"
assert_json "$p" progressFloor false "an idle machine is simply open"
assert_json "$p" admission '"open"' "an idle machine is simply open"
# The floor remembers the hold for hysteresis: 1.2 after a floor cycle is
# still pressure, not a reopened gate.
rm -f "$state"
p="$(floor 0 0 --governor-state "$state" --update-governor-state)"
p="$(plan --configured-slots auto --cpu-count 10 --available-memory-bytes $((24 * GIB)) \
  --load-1m 12 --active-workers 1 --governor-state "$state" --update-governor-state)"
assert_json "$p" admission '"throttled"' "hysteresis carries across a floor cycle"
rm -f "$state"
# No disk, no floor: low-disk mode is a different state with its own exit.
p="$(floor 0 0 --free-bytes 0)"
assert_json "$p" progressFloor false "the floor never overrides low disk"
echo "  ok  minimum-progress floor admits one unit only when nothing is running"

# --- 5. broken or missing probes never produce zero slots -------------------
p="$(plan --configured-slots auto --cpu-count banana --available-memory-bytes $((24 * GIB)) --load-1m 0)"
assert_json "$p" effectiveSlots 3 "garbage cpu count falls back to 3"
assert_json "$p" reason '"probe-unavailable"' "garbage cpu count is named"
assert_json "$p" probeFailures '["cpu"]' "the failed probe is listed"
assert_json "$p" admission '"open"' "an unmeasurable load cannot throttle"
p="$(plan --configured-slots auto --cpu-count 12 --available-memory-bytes -5 --load-1m 0)"
assert_json "$p" effectiveSlots 3 "garbage memory falls back to 3"
assert_json "$p" reason '"probe-unavailable"' "garbage memory is named"
p="$(plan --configured-slots auto --cpu-count 0 --available-memory-bytes "" --load-1m nan)"
assert_json "$p" reason '"probe-unavailable"' "zero cores is not a machine"
p="$(plan --configured-slots auto --cpu-count 12 --available-memory-bytes $((24 * GIB)) --load-1m garbage)"
assert_json "$p" effectiveSlots 8 "a failed load probe does not affect sizing"
assert_json "$p" admission '"open"' "a failed load probe does not throttle"
assert_json "$p" loadPerCore null "unknown load is reported as unknown"
assert_json "$p" probeFailures '["load"]' "the failed load probe is listed"
# The fallback is still bounded by disk, and says so.
p="$(plan --configured-slots auto --cpu-count banana --available-memory-bytes $((24 * GIB)) --load-1m 0 \
  --free-bytes 1)"
assert_json "$p" effectiveSlots 1 "fallback is still disk-bounded"
assert_json "$p" reason '"disk-bound"' "disk is named when it binds the fallback"
# An explicit ceiling does not care that the probes are broken.
p="$(plan --configured-slots 4 --cpu-count banana --available-memory-bytes nope --load-1m x)"
assert_json "$p" effectiveSlots 4 "explicit ceiling survives broken probes"
assert_json "$p" reason '"configured-capacity-available"' "explicit reason survives broken probes"
# A corrupt throttle-state file is ignored, not fatal.
printf 'not json' >"$state"
p="$(governed 14)"
assert_json "$p" admission '"open"' "corrupt throttle state is ignored"
rm -f "$state"
# The real probes work on this host (macOS vm_stat or Linux /proc/meminfo):
# no injection at all must still produce a sized, positive plan.
p="$(plan --configured-slots auto)"
[[ "$(jget "$p" effectiveSlots)" =~ ^[1-9][0-9]*$ ]] || fail "live probes produced no slots: $p"
[[ "$(jget "$p" reason)" != '"probe-unavailable"' ]] || fail "live probes unavailable on this host: $p"
# The parsers behind them, on captured output from both platforms.
python3 - "$SCRIPT_DIR" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import resource_governor as g

vm_stat = """Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                                   100.
Pages active:                                 451102.
Pages inactive:                               200.
Pages speculative:                             30.
Pages throttled:                                   0.
Pages wired down:                             235172.
Pages purgeable:                                4.
"""
assert g.parse_vm_stat(vm_stat) == (100 + 200 + 30 + 4) * 16384
assert g.parse_vm_stat("vm_stat: command not found") is None
assert g.parse_vm_stat("Mach Virtual Memory Statistics: (page size of 4096 bytes)\n") is None
meminfo = "MemTotal:       16000000 kB\nMemFree:          500000 kB\nMemAvailable:    8000000 kB\n"
assert g.parse_meminfo(meminfo) == 8000000 * 1024
assert g.parse_meminfo("MemTotal: 16000000 kB\n") is None
PY
echo "  ok  failed probes fall back to 3 slots and say probe-unavailable"

# --- 6. planner concurrency follows the worker ceiling ----------------------
p="$(plan --configured-slots auto --cpu-count 12 --available-memory-bytes $((24 * GIB)) --load-1m 0)"
assert_json "$p" plannerSlots 4 "half of 8"
p="$(plan --configured-slots 5 --cpu-count 12 --available-memory-bytes $((24 * GIB)) --load-1m 0)"
assert_json "$p" plannerSlots 3 "half of 5, rounded up"
p="$(plan --configured-slots 1 --cpu-count 12 --available-memory-bytes $((24 * GIB)) --load-1m 0)"
assert_json "$p" plannerSlots 1 "at least one planner"
p="$(plan --configured-slots 5 --reserve-bytes 100 --estimated-worktree-bytes 100 --free-bytes 150 \
  --cpu-count 12 --available-memory-bytes $((24 * GIB)) --load-1m 0)"
assert_json "$p" plannerSlots 0 "no planners without a worker slot"
p="$(engine_env SINGULAR_L1_AUTO_FRACTION=0.25 "$SCRIPT_DIR/resource-plan.sh" --json \
  --configured-slots auto --reserve-bytes 0 --estimated-worktree-bytes 1 --free-bytes 100 \
  --active-workers 0 --governor-state "$tmp/unused-state.json" \
  --cpu-count 12 --available-memory-bytes $((24 * GIB)) --load-1m 0)"
assert_json "$p" plannerSlots 2 "the fraction is tunable"

l1_cap() { engine_env "$@" bash -c "source '$SCRIPT_DIR/lib.sh'; singular_l1_concurrency_cap"; }
[[ "$(l1_cap SINGULAR_L1_AUTO_CONCURRENT=4)" == "4" ]] || fail "auto L1 cap should follow the plan's planner slots"
[[ "$(l1_cap SINGULAR_MAX_L1_CONCURRENT=auto SINGULAR_L1_AUTO_CONCURRENT=2)" == "2" ]] || fail "explicit auto L1 cap"
[[ "$(l1_cap)" == "3" ]] || fail "auto L1 cap without a plan keeps the historical default of 3"
[[ "$(l1_cap SINGULAR_MAX_L1_CONCURRENT=6 SINGULAR_L1_AUTO_CONCURRENT=2)" == "6" ]] || fail "an integer L1 cap wins"
[[ "$(l1_cap SINGULAR_MAX_L1_CONCURRENT=0)" == "1" ]] || fail "a zero L1 cap floors to 1, as before"
[[ "$(l1_cap SINGULAR_MAX_L1_CONCURRENT=lots)" == "1" ]] || fail "a garbage L1 cap floors to 1, as before"

# Provider pressure halves "the configured ceiling". Under auto that number
# only exists once a cycle has measured it, so the cycle records it and the
# pressure baseline reads it back; before any cycle it is the old default.
pressure_baseline() {
  engine_env SINGULAR_RESOURCE_GOVERNOR_STATE_FILE="$state" "$@" \
    bash -c "source '$SCRIPT_DIR/lib.sh'; singular_provider_pressure_configured_slots"
}
rm -f "$state"
[[ "$(pressure_baseline)" == "3" ]] || fail "auto pressure baseline without a measured ceiling should be 3"
governed 0 >/dev/null
[[ "$(pressure_baseline)" == "8" ]] || fail "auto pressure baseline should be the measured ceiling, got '$(pressure_baseline)'"
[[ "$(pressure_baseline SINGULAR_MAX_CONCURRENT=5)" == "5" ]] || fail "explicit pressure baseline is the integer"
rm -f "$state"
echo "  ok  planner concurrency is derived from the worker ceiling"

# --- 7. reconcile: saturated machine holds, floors, and recovers -------------
reconcile() {
  engine_env SINGULAR_L1_DRIVER="$tmp/driver.sh" SINGULAR_PROMOTER="$tmp/promoter.sh" \
    SINGULAR_L1_PLAN_NODE="$tmp/planner.sh" SINGULAR_ENABLE_L1_PARALLEL=1 \
    SINGULAR_AUTO_INTEGRATE=0 SINGULAR_AUTO_PROMOTE_GATES=0 SINGULAR_DETACHED_DISPATCH=1 \
    SINGULAR_PLAN_CRITIQUE=0 SINGULAR_CODEX_BIN="$tmp/no-provider.sh" \
    SINGULAR_DISK_RESERVE_BYTES=1024 SINGULAR_ESTIMATED_WORKTREE_BYTES=1024 \
    SINGULAR_RESOURCE_CPU_COUNT=10 SINGULAR_RESOURCE_AVAILABLE_MEMORY_BYTES=$((24 * GIB)) \
    "$@" bash "$SCRIPT_DIR/reconcile.sh" --actuate 2>&1
}
last_plan_event() {
  grep '"type":"origin.resource_plan"' "$root/.singular-state/events.ndjson" | tail -1
}
dispatch_count() { [[ -f "$tmp/driver-ran" ]] && grep -c . "$tmp/driver-ran" || echo 0; }
planner_count() { [[ -f "$tmp/planner-ran" ]] && grep -c . "$tmp/planner-ran" || echo 0; }
wait_for_dispatches() { # <count>
  local deadline=$((SECONDS + 15))
  while (( SECONDS < deadline )); do
    [[ "$(dispatch_count)" -ge "$1" ]] && return 0
    sleep 0.05
  done
  return 1
}
set_status() { # <task> <from> <to>
  sed -i.bak "s/^Status: $2\$/Status: $3/" "$root/docs/orchestration/tasks/$1.md"
  rm -f "$root/docs/orchestration/tasks/$1.md.bak"
}
drain() {
  rm -f "$tmp/hold-worker"
  engine_env SINGULAR_DRAIN_TIMEOUT_SECS=20 SINGULAR_DRAIN_POLL_SECS=0.05 \
    bash "$SCRIPT_DIR/reconcile.sh" --drain >"$tmp/drain.log" 2>&1 \
    || { cat "$tmp/drain.log" >&2; fail "drain failed"; }
}

# A second runnable task, disjoint from the first, so "exactly one" is a real
# choice between two candidates.
sed -e 's/TASK-0001/TASK-0002/g' -e 's|src/a.txt|src/b.txt|' \
  "$root/docs/orchestration/tasks/TASK-0001.md" >"$root/docs/orchestration/tasks/TASK-0002.md"
git -C "$root" add . && git -C "$root" -c user.name=test -c user.email=test@example.local commit -q -m second

# 7a. Floor disabled: the strict hold. Two runnable tasks, nothing running,
#     saturated -> nothing is admitted.
out="$(reconcile SINGULAR_GENERATE=0 SINGULAR_PROGRESS_FLOOR=0 SINGULAR_RESOURCE_LOAD_1M=16)" || true
[[ "$(field "$out" dispatch_gate)" == "load-high" ]] \
  || { printf '%s\n' "$out" >&2; fail "strict: gate should be load-high, got '$(field "$out" dispatch_gate)'"; }
[[ "$(field "$out" effective_slots)" == "8" ]] || fail "strict: ceiling must stay 8, got '$(field "$out" effective_slots)'"
[[ "$(field "$out" available_slots)" == "0" ]] || fail "strict: nothing is available to new work"
[[ "$(field "$out" resource_reason)" == "load-high" ]] || fail "strict: reason should be load-high"
[[ "$(field "$out" resource_progress_floor)" == "0" ]] || fail "strict: floor must be off"
[[ "$(field "$out" resource_gc_attempted)" == "0" ]] || fail "load must not trigger the low-disk GC sweep"
assert_contains "$out" "MACHINE SATURATED (load-high)" "saturated banner"
assert_contains "$out" "held by the load-high gate" "the ready tasks are reported as held"
assert_not_contains "$out" "LOW DISK" "load is not low disk"
sleep 0.3
[[ "$(dispatch_count)" == "0" ]] || fail "floor disabled: a worker was dispatched while saturated"
event="$(last_plan_event)"
for key in '"cpuSlots":8' '"memorySlots":22' '"diskSlots":' '"loadPerCore":1.6' \
    '"availableMemoryBytes":25769803776' '"reason":"load-high"' '"admission":"throttled"' \
    '"progressFloor":false' '"mode":"auto"' '"configuredSlots":8' '"effectiveSlots":8' \
    '"availableSlots":0' '"activeLeases":0'; do
  assert_contains "$event" "$key" "origin.resource_plan event (strict hold)"
done
grep -q '"type":"origin.reconcile_completed"' "$root/.singular-state/events.ndjson" \
  || fail "a held cycle must still complete"
! grep -q '"type":"origin.degraded_low_disk"' "$root/.singular-state/events.ndjson" \
  || fail "load must not be reported as low disk"
#     ... and no planner either (nothing dispatchable, planning ON).
set_status TASK-0001 ready integrated; set_status TASK-0002 ready integrated
out="$(reconcile SINGULAR_GENERATE=1 SINGULAR_PROGRESS_FLOOR=0 SINGULAR_RESOURCE_LOAD_1M=16)" || true
[[ "$(field "$out" dispatch_gate)" == "load-high" ]] || fail "strict planner case: gate should be load-high"
assert_not_contains "$out" "L1 parallel fanout" "no fanout under the strict hold"
assert_not_contains "$out" "invoking task generator" "no serial planner under the strict hold"
[[ "$(planner_count)" == "0" ]] || fail "floor disabled: a planner was started while saturated"

# 7b. Floor, planner side: saturated, nothing running, nothing runnable ->
#     exactly one planner, and no worker in the same cycle.
out="$(reconcile SINGULAR_GENERATE=1 SINGULAR_RESOURCE_LOAD_1M=16)" || true
[[ "$(field "$out" resource_progress_floor)" == "1" ]] \
  || { printf '%s\n' "$out" >&2; fail "floor (planner): floor should be on"; }
[[ "$(field "$out" resource_reason)" == "load-high-floor" ]] || fail "floor (planner): reason, got '$(field "$out" resource_reason)'"
assert_contains "$out" "minimum-progress floor admits one unit" "floor banner"
assert_contains "$out" "L1 parallel fanout (cap 4, remaining capacity 1)" "the floor leaves one planning slot"
assert_contains "$out" "l1 fanout cap=1 " "exactly one planner is started"
[[ "$(planner_count)" == "1" ]] || fail "floor (planner): want exactly 1 planner, got $(planner_count)"
[[ "$(dispatch_count)" == "0" ]] || fail "floor (planner): the planner was the unit; no worker in the same cycle"
set_status TASK-0001 integrated ready; set_status TASK-0002 integrated ready

# 7c. Floor, worker side: saturated, nothing running, two runnable tasks ->
#     exactly one worker. It stays running (hold-worker).
: >"$tmp/hold-worker"
out="$(reconcile SINGULAR_GENERATE=1 SINGULAR_RESOURCE_LOAD_1M=16)" || true
[[ "$(field "$out" dispatch_gate)" == "open" ]] \
  || { printf '%s\n' "$out" >&2; fail "floor (worker): gate should be open for the one unit"; }
[[ "$(field "$out" resource_progress_floor)" == "1" ]] || fail "floor (worker): floor should be on"
[[ "$(field "$out" available_slots)" == "1" ]] || fail "floor (worker): exactly one slot, got '$(field "$out" available_slots)'"
[[ "$(field "$out" effective_slots)" == "8" ]] || fail "floor (worker): the ceiling stays 8"
wait_for_dispatches 1 || { printf '%s\n' "$out" >&2; fail "floor (worker): the one admitted worker did not start"; }
sleep 0.5
[[ "$(dispatch_count)" == "1" ]] || fail "floor (worker): want exactly 1 worker of 2 runnable, got $(dispatch_count)"
[[ "$(planner_count)" == "1" ]] || fail "floor (worker): a task was runnable, so no planner; got $(planner_count)"
event="$(last_plan_event)"
for key in '"reason":"load-high-floor"' '"progressFloor":true' '"admission":"floor"' \
    '"availableSlots":1' '"effectiveSlots":8' '"activeLeases":0' '"loadPerCore":1.6'; do
  assert_contains "$event" "$key" "origin.resource_plan event (floor)"
done

# 7d. Saturated with that one worker still running -> the strict hold is back:
#     the second runnable task is NOT admitted, and no planner starts.
out="$(reconcile SINGULAR_GENERATE=1 SINGULAR_RESOURCE_LOAD_1M=16)" || true
[[ "$(field "$out" dispatch_gate)" == "load-high" ]] \
  || { printf '%s\n' "$out" >&2; fail "running: gate should be load-high, got '$(field "$out" dispatch_gate)'"; }
[[ "$(field "$out" resource_progress_floor)" == "0" ]] || fail "running: no floor while a worker runs"
[[ "$(field "$out" resource_reason)" == "load-high" ]] || fail "running: reason should be load-high"
assert_contains "$(last_plan_event)" '"activeLeases":1' "the running worker is counted"
assert_contains "$(last_plan_event)" '"progressFloor":false' "no floor in the event while a worker runs"
sleep 0.3
[[ "$(dispatch_count)" == "1" ]] || fail "running: a second worker was admitted under the hold, got $(dispatch_count)"
[[ "$(planner_count)" == "1" ]] || fail "running: a planner was admitted under the hold"

# 7e. Hysteresis across cycles: 1.2 per core is under the high-water mark but
#     the previous cycles throttled, so it stays shut ...
out="$(reconcile SINGULAR_GENERATE=0 SINGULAR_RESOURCE_LOAD_1M=12)" || true
[[ "$(field "$out" dispatch_gate)" == "load-high" ]] || fail "hysteresis: gate should still be load-high at 1.2"
sleep 0.3
[[ "$(dispatch_count)" == "1" ]] || fail "a worker was dispatched between the water marks"
#     ... and reopens under the low-water mark, dispatching the held task.
out="$(reconcile SINGULAR_GENERATE=0 SINGULAR_RESOURCE_LOAD_1M=9)" || true
[[ "$(field "$out" dispatch_gate)" == "open" ]] \
  || { printf '%s\n' "$out" >&2; fail "recovery: gate should reopen, got '$(field "$out" dispatch_gate)'"; }
[[ "$(field "$out" resource_reason)" == "cpu-bound" ]] || fail "recovery: reason should be cpu-bound"
[[ "$(field "$out" resource_progress_floor)" == "0" ]] || fail "recovery: no floor on an open gate"
wait_for_dispatches 2 || { printf '%s\n' "$out" >&2; fail "recovery: the held task was not dispatched"; }
assert_contains "$(last_plan_event)" '"admission":"open"' "recovered event"
drain

# 7f. Positive control for the planner hold in 7a, and the wiring of the auto
#     planner cap: on the idle machine the same configuration reaches the
#     fanout capped at half the 8-slot worker ceiling.
set_status TASK-0001 ready integrated; set_status TASK-0002 ready integrated
out="$(reconcile SINGULAR_GENERATE=1 SINGULAR_RESOURCE_LOAD_1M=0)" || true
assert_contains "$out" "L1 parallel fanout (cap 4," "idle machine plans with the derived planner cap"
[[ "$(planner_count)" == "2" ]] || { printf '%s\n' "$out" >&2; fail "control: the planner should run on an idle machine"; }

echo "  ok  reconcile holds, floors and resumes workers and planners under load"

# --- 8. the pressure signal is CPU utilisation, not load average (0.23.7) ----
# Field, 12-core macOS host: load average 15-30 with the CPU 55% idle (the
# governor throttled an idle machine), and load 30 with 0% idle (where it was
# right). Load counts threads blocked on I/O and lags by a minute.
busy_state="$tmp/busy-state.json"
busy() { # <cpu-busy fraction> <load-1m> [flags] — 12 cores, one worker running
  local fraction="$1" load="$2"; shift 2
  plan --configured-slots auto --cpu-count 12 --available-memory-bytes $((24 * GIB)) \
    --cpu-busy "$fraction" --load-1m "$load" --governor-state "$busy_state" \
    --update-governor-state --active-workers 1 "$@"
}
p="$(busy 0.45 30)"                     # load 2.5 per core, CPU 55% idle
assert_json "$p" admission '"open"' "a high load average with an idle CPU does not throttle"
assert_json "$p" pressureSignal '"cpu-busy"' "CPU utilisation is the signal"
assert_json "$p" cpuBusy 0.45 "the busy fraction is reported"
assert_json "$p" loadPerCore 2.5 "load per core is still reported"
assert_json "$p" reason '"cpu-bound"' "the capacity reason is kept"
p="$(busy 1.0 30)"                      # same load, CPU 0% idle
assert_json "$p" admission '"throttled"' "a saturated CPU throttles"
assert_json "$p" admissionReason '"cpu-busy"' "the reason names the CPU"
assert_json "$p" reason '"cpu-busy"' "reason names the CPU"
assert_json "$p" effectiveSlots 8 "throttling never changes the ceiling"
rm -f "$busy_state"
p="$(busy 0.97 2)"                      # low load average, busy CPU
assert_json "$p" admission '"throttled"' "a busy CPU throttles even while the load average is low"
# Hysteresis on the busy fraction: shut above 0.90, open again below 0.75.
p="$(busy 0.80 2)"; assert_json "$p" admission '"throttled"' "hysteresis: still throttled between the marks"
p="$(busy 0.76 2)"; assert_json "$p" admission '"throttled"' "hysteresis: still throttled just above low-water"
p="$(busy 0.74 2)"; assert_json "$p" admission '"open"' "resumes below the CPU low-water mark"
p="$(busy 0.89 2)"; assert_json "$p" admission '"open"' "no flapping: open stays open between the marks"
p="$(busy 0.91 2)"; assert_json "$p" admission '"throttled"' "just over the high-water mark throttles"
rm -f "$busy_state"
assert_json "$p" cpuBusyHighWater 0.9 "default high-water mark"
assert_json "$p" cpuBusyLowWater 0.75 "default low-water mark"
# The marks are tunable (env here; resources.cpuBusyHighWater/LowWater in config).
p="$(engine_env SINGULAR_CPU_BUSY_HIGH_WATER=0.5 SINGULAR_CPU_BUSY_LOW_WATER=0.3 \
  "$SCRIPT_DIR/resource-plan.sh" --json --configured-slots auto \
  --reserve-bytes 0 --estimated-worktree-bytes 1 --free-bytes 100 --active-workers 1 \
  --governor-state "$tmp/unused-state.json" \
  --cpu-count 12 --available-memory-bytes $((24 * GIB)) --cpu-busy 0.6 --load-1m 0)"
assert_json "$p" admission '"throttled"' "SINGULAR_CPU_BUSY_HIGH_WATER is honoured"
assert_json "$p" cpuBusyLowWater 0.3 "SINGULAR_CPU_BUSY_LOW_WATER is honoured"
grep -q 'setv("SINGULAR_CPU_BUSY_HIGH_WATER", resources.get("cpuBusyHighWater"))' "$SCRIPT_DIR/lib.sh" \
  || fail "resources.cpuBusyHighWater is not projected from singular.config.json"
grep -q 'setv("SINGULAR_CPU_BUSY_LOW_WATER", resources.get("cpuBusyLowWater"))' "$SCRIPT_DIR/lib.sh" \
  || fail "resources.cpuBusyLowWater is not projected from singular.config.json"
# The injected fact also arrives by env, and the throttle switch still wins.
p="$(engine_env SINGULAR_RESOURCE_CPU_BUSY=0.99 SINGULAR_RESOURCE_LOAD_1M=0 \
  "$SCRIPT_DIR/resource-plan.sh" --json --configured-slots auto \
  --reserve-bytes 0 --estimated-worktree-bytes 1 --free-bytes 100 --active-workers 1 \
  --governor-state "$tmp/unused-state.json" --cpu-count 12 --available-memory-bytes $((24 * GIB)))"
assert_json "$p" admissionReason '"cpu-busy"' "SINGULAR_RESOURCE_CPU_BUSY injects the fact"
p="$(engine_env SINGULAR_RESOURCE_THROTTLE=0 \
  "$SCRIPT_DIR/resource-plan.sh" --json --configured-slots auto \
  --reserve-bytes 0 --estimated-worktree-bytes 1 --free-bytes 100 --active-workers 1 \
  --governor-state "$tmp/unused-state.json" --cpu-count 12 --available-memory-bytes $((24 * GIB)) \
  --cpu-busy 1 --load-1m 99)"
assert_json "$p" admission '"open"' "SINGULAR_RESOURCE_THROTTLE=0 disables the CPU gate too"
# Load average is the FALLBACK: used only when the CPU cannot be measured.
p="$(plan --configured-slots auto --cpu-count 10 --available-memory-bytes $((24 * GIB)) \
  --load-1m 16 --active-workers 1)"
assert_json "$p" pressureSignal '"load-average"' "without a CPU sample the load average decides"
assert_json "$p" admissionReason '"load-high"' "and it still throttles on its own marks"
assert_json "$p" cpuBusy null "an unsampled CPU is reported as unknown"
assert_json "$p" probeFailures '[]' "a CPU that was deliberately not sampled is not a probe failure"
p="$(plan --configured-slots auto --cpu-count 10 --available-memory-bytes $((24 * GIB)) \
  --cpu-busy banana --load-1m 16 --active-workers 1)"
assert_json "$p" cpuBusy null "a garbage CPU sample is unavailable, never a probe of the real machine"
assert_json "$p" probeFailures '["cpu-busy"]' "the failed CPU sample is listed"
assert_json "$p" admissionReason '"load-high"' "and the load average takes over"
p="$(plan --configured-slots auto --cpu-count 10 --available-memory-bytes $((24 * GIB)) \
  --cpu-busy 1.7 --load-1m 2 --active-workers 1)"
assert_json "$p" cpuBusy null "a fraction outside [0,1] is rejected"
assert_json "$p" admission '"open"' "a rejected sample cannot throttle"
# A hold taken on one signal is released by the other's low-water mark.
rm -f "$busy_state"
p="$(plan --configured-slots auto --cpu-count 10 --available-memory-bytes $((24 * GIB)) \
  --load-1m 16 --governor-state "$busy_state" --update-governor-state --active-workers 1)"
assert_json "$p" admissionReason '"load-high"' "throttled on the fallback signal"
p="$(busy 0.80 16)"
assert_json "$p" admissionReason '"cpu-busy"' "the hold carries over between the CPU marks"
p="$(busy 0.50 16)"
assert_json "$p" admission '"open"' "and is released by the CPU low-water mark, whatever the load says"
rm -f "$busy_state"
# The minimum-progress floor is kept: saturated CPU, nothing of ours running.
p="$(plan --configured-slots auto --cpu-count 12 --available-memory-bytes $((24 * GIB)) \
  --cpu-busy 0.99 --load-1m 0 --active-workers 0 --active-planners 0)"
assert_json "$p" admission '"floor"' "the progress floor admits one unit under a CPU hold"
assert_json "$p" reason '"cpu-busy-floor"' "the floor names the CPU hold"
assert_json "$p" progressFloor true "progressFloor is set"
p="$(plan --configured-slots auto --cpu-count 12 --available-memory-bytes $((24 * GIB)) \
  --cpu-busy 0.99 --load-1m 0 --active-workers 0 --active-planners 1)"
assert_json "$p" admission '"throttled"' "with a planner running the CPU hold is strict"
# The memory gate is independent of the signal.
p="$(plan --configured-slots auto --cpu-count 12 --available-memory-bytes $((1 * GIB)) \
  --cpu-busy 0.10 --load-1m 0 --active-workers 1)"
assert_json "$p" admissionReason '"memory-low"' "low memory still throttles on an idle CPU"
# The probes' parsers, on recorded output.
python3 - "$SCRIPT_DIR" <<'PY' || fail "CPU sample parsers"
import sys
sys.path.insert(0, sys.argv[1])
import resource_governor as g

top = """Processes: 812 total, 5 running, 807 sleeping, 4521 threads
2026/10/05 07:50:01
Load Avg: 19.06, 24.05, 22.92
CPU usage: 9.52% user, 14.28% sys, 76.19% idle
SharedLibs: 1021M resident, 181M data, 147M linkedit.

Processes: 812 total, 9 running, 803 sleeping, 4530 threads
2026/10/05 07:50:02
Load Avg: 19.06, 24.05, 22.92
CPU usage: 30.68% user, 26.17% sys, 43.14% idle
"""
assert g.parse_top_cpu_usage(top) == 0.5686, g.parse_top_cpu_usage(top)
# One sample only is the since-boot average, not a window: unusable.
assert g.parse_top_cpu_usage(top.split("\n\n")[0] + "\n") is None
assert g.parse_top_cpu_usage("garbage") is None
first = g.parse_proc_stat("cpu  100 0 100 700 100 0 0 0 0 0\ncpu0 1 2 3 4\n")
second = g.parse_proc_stat("cpu  400 0 200 1100 300 0 0 0 0 0\n")
assert first == (800, 1000) and second == (1400, 2000), (first, second)
# 1000 jiffies elapsed, 600 of them idle or waiting on I/O: 40% busy.
assert g.cpu_busy_between(first, second) == 0.4
assert g.cpu_busy_between(second, first) is None and g.cpu_busy_between(None, second) is None
assert g.parse_proc_stat("no cpu line") is None
assert g.parse_fraction("0.9") == 0.9 and g.parse_fraction("1.01") is None and g.parse_fraction("x") is None
PY
# The loop's view of the plan carries the CPU reason and the new fields.
busy 0.97 30 >"$tmp/busy-plan.json"
view="$(engine_env python3 "$SCRIPT_DIR/resource_governor.py" --event-view "$tmp/busy-plan.json")"
[[ "$(sed -n '1p' <<<"$view")" == "throttled" && "$(sed -n '2p' <<<"$view")" == "cpu-busy" ]] \
  || fail "event view does not carry the cpu-busy hold: $view"
assert_contains "$(sed -n '4p' <<<"$view")" '"cpuBusy":0.97' "event fields carry the busy fraction"
assert_contains "$(sed -n '4p' <<<"$view")" '"pressureSignal":"cpu-busy"' "event fields carry the signal"
rm -f "$busy_state"
echo "  ok  CPU utilisation is the pressure signal; load average is the fallback"

# 8b. Through reconcile: a busy CPU holds planning; a high load average with an
#     idle CPU does not.
planners_before="$(planner_count)"
out="$(reconcile SINGULAR_GENERATE=1 SINGULAR_PROGRESS_FLOOR=0 \
  SINGULAR_RESOURCE_LOAD_1M=0 SINGULAR_RESOURCE_CPU_BUSY=0.97)" || true
[[ "$(field "$out" dispatch_gate)" == "cpu-busy" ]] \
  || { printf '%s\n' "$out" >&2; fail "cpu: gate should be cpu-busy, got '$(field "$out" dispatch_gate)'"; }
[[ "$(field "$out" resource_reason)" == "cpu-busy" ]] || fail "cpu: reason should be cpu-busy"
assert_contains "$out" "MACHINE SATURATED (cpu-busy)" "saturated banner names the CPU"
[[ "$(planner_count)" == "$planners_before" ]] || fail "a planner was admitted while the CPU was saturated"
event="$(last_plan_event)"
assert_contains "$event" '"admission":"throttled"' "the cycle event records the hold"
assert_contains "$event" '"cpuBusy":0.97' "the cycle event records the busy fraction"
assert_contains "$event" '"pressureSignal":"cpu-busy"' "the cycle event records the signal"
out="$(reconcile SINGULAR_GENERATE=1 SINGULAR_PROGRESS_FLOOR=0 \
  SINGULAR_RESOURCE_LOAD_1M=30 SINGULAR_RESOURCE_CPU_BUSY=0.45)" || true
[[ "$(field "$out" dispatch_gate)" == "open" ]] \
  || { printf '%s\n' "$out" >&2; fail "idle CPU under a high load average: gate should be open, got '$(field "$out" dispatch_gate)'"; }
[[ "$(planner_count)" -gt "$planners_before" ]] \
  || { printf '%s\n' "$out" >&2; fail "planning was not admitted on an idle CPU with a high load average"; }
assert_contains "$(last_plan_event)" '"admission":"open"' "the open cycle is recorded"

[[ ! -f "$tmp/provider-called" ]] || fail "a test case reached a provider CLI: $(cat "$tmp/provider-called")"
echo "  ok  reconcile follows the CPU signal"

echo "resource governor tests passed"
