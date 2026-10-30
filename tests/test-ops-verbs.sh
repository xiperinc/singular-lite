#!/usr/bin/env bash
ops_verdict_nonce="${RAILS_NONCE:-}"
ops_verdict_file="${RAILS_VERDICT_FILE:-}"
unset RAILS_NONCE RAILS_VERDICT_FILE
set -euo pipefail

# P5 (0.5.0): operator verbs — supersede (four surfaces atomically, live-pid
# guard, idempotent), clear-backoff, breaker, stop/resume, wake.
# S0.4-7 free-word exception: ask alone joins positional words into one question
# (engine/ops.sh:1917); trailing-argument refusal does not apply to ask.
# report has no free-word grammar: engine/ops.sh:1948-1950 ignores argv and
# invokes supervise.sh --once. Its trailing-argument refusal remains required.
# The other mutators have fixed arguments/options (engine/ops.sh:69-74,
# 188-199, 237-250, 429-435, 475-484, 588-595, 690-705, 710-715,
# 760-764, 1315-1323, 1560-1566), or consume no argv (resume at 740-752,
# clear-backoff dispatch at 1960). None intentionally consumes free words.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  echo "S0.4-7: run through tests/run.sh (requires bash >= 4)" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() { echo "FAIL: S0.4-7: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }

tmp="$(mktemp -d)"
live_pid=""
cleanup() {
  if [[ -n "$live_pid" ]]; then
    kill "$live_pid" 2>/dev/null || true
    wait "$live_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
export TMPDIR="$tmp" PYTHONDONTWRITEBYTECODE=1
export SINGULAR_HOME="$tmp/machine" SINGULAR_ENGINE_HOME="$ENGINE_HOME"
export SINGULAR_BASH_BIN="$BASH" SINGULAR_PUSH=0
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export SINGULAR_LOCAL_CONFIG_FILE=/dev/null
printf '{}\n' >"$tmp/config.json"
export SINGULAR_JSON_CONFIG_FILE="$tmp/config.json"
root="$tmp/repo"
mkdir -p "$root/docs/orchestration/tasks" "$root/.singular-state/leases" \
  "$root/.singular-state/inbox" "$root/.singular-state/dispatch" "$root/.singular-state/runs"
git -C "$root" init -q
git -C "$root" checkout -q -b target
printf '%s\n' '.singular-state/' '.worktrees/' >"$root/.gitignore"
git -C "$root" add .gitignore
git -C "$root" -c user.email=fixture -c user.name=fixture commit -q -m init

ops() {
  (
  cd "$root"
  env SINGULAR_ROOT="$root" SINGULAR_STATE_DIR="$root/.singular-state" \
    SINGULAR_ORCH_DIR="$root/docs/orchestration" SINGULAR_TASKS_DIR="$root/docs/orchestration/tasks" \
    SINGULAR_LEASES_DIR="$root/.singular-state/leases" SINGULAR_INBOX_DIR="$root/.singular-state/inbox" \
    SINGULAR_DISPATCH_DIR="$root/.singular-state/dispatch" SINGULAR_RUNS_DIR="$root/.singular-state/runs" \
    SINGULAR_WORKTREES_DIR="$root/.worktrees" \
    SINGULAR_EVENTS_FILE="$root/.singular-state/events.ndjson" \
    SINGULAR_TARGET_BRANCH=target \
    "$BASH" "$ENGINE_HOME/cli/singular" "$@"
  )
}

# --- supersede ---------------------------------------------------------------
cat >"$root/docs/orchestration/tasks/TASK-0001.md" <<'EOF'
# TASK-0001: doomed attempt

Status: blocked
Area: core
DAG node: node-a
Dispatch mode: canonical

## Objective

First attempt.

## Scope

Owned files:

- `src/a.ts`
EOF
cat >"$root/docs/orchestration/tasks/TASK-0002.md" <<'EOF'
# TASK-0002: replacement

Status: ready
Area: core
DAG node: node-a
Dispatch mode: canonical

## Objective

Second attempt.

## Scope

Owned files:

- `src/a.ts`
EOF
printf '%s\n' '{"taskId":"TASK-0001","status":"blocked","branch":"agent/core/TASK-0001"}' \
  >"$root/.singular-state/leases/TASK-0001.json"
printf '%s\n' '{"taskId":"TASK-0001","runId":"RUN-1","status":"needs-review"}' \
  >"$root/.singular-state/inbox/RUN-1.json"

out="$(ops supersede TASK-0001 --by TASK-0002 --reason "fixture")"
assert_contains "$out" "superseded TASK-0001 -> TASK-0002" "supersede completes"
[[ -f "$root/docs/orchestration/tasks/superseded/TASK-0001.md" ]] || fail "task file moved"
grep -q "^Status: superseded" "$root/docs/orchestration/tasks/superseded/TASK-0001.md" || fail "status set"
grep -q "^Superseded by: TASK-0002" "$root/docs/orchestration/tasks/superseded/TASK-0001.md" || fail "successor header"
[[ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$root/.singular-state/leases/TASK-0001.json")" == "superseded" ]] \
  || fail "lease status"
[[ -f "$root/.singular-state/inbox/superseded/RUN-1.json" ]] || fail "inbox packet quarantined"
grep -q "supersede" "$root/docs/orchestration/decisions.md" || fail "decision recorded"
assert_contains "$(cat "$root/.singular-state/events.ndjson")" '"type":"task.superseded"' "event"

# Idempotent re-run.
out="$(ops supersede TASK-0001)"
assert_contains "$out" "already superseded" "idempotent"

# Live-dispatch guard: refuse without --force.
cat >"$root/docs/orchestration/tasks/TASK-0003.md" <<'EOF'
# TASK-0003: live one

Status: running
Area: core
Dispatch mode: canonical

## Objective

Running attempt.

## Scope

Owned files:

- `src/b.ts`
EOF
python3 -c 'import signal; signal.pause()' RUN-live-ops &
live_pid=$!
python3 - "$root/.singular-state/dispatch/TASK-0003.json" "$live_pid" <<'PY'
import json, sys
json.dump({"taskId": "TASK-0003", "runId": "RUN-live-ops", "pid": int(sys.argv[2]),
           "pidStart": "", "pgid": 0, "log": "", "baseSha": "", "batchId": "",
           "state": "launched"}, open(sys.argv[1], "w"), indent=2)
PY
rc=0
ops supersede TASK-0003 >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] || fail "live dispatch must refuse without --force (rc=$rc)"
out="$(ops supersede TASK-0003 --force)"
assert_contains "$out" "superseded TASK-0003" "--force supersedes"
kill "$live_pid" 2>/dev/null || true
wait "$live_pid" 2>/dev/null || true
live_pid=""

# --- clear-backoff / breaker / stop / resume / wake ---------------------------
env_lib() {
  env SINGULAR_ROOT="$root" SINGULAR_STATE_DIR="$root/.singular-state" \
    SINGULAR_EVENTS_FILE="$root/.singular-state/events.ndjson" \
    bash -c "source '$SCRIPT_DIR/lib.sh'; $1"
}
printf '%s\n' \
  '{"schema":"singular.orchestration.planner-backoff.v0","failureClass":"quota","until":"2999-01-01T00:00:00Z"}' \
  >"$root/.singular-state/planner-backoff.json"
out="$(ops clear-backoff)"
assert_contains "$out" "backoff cleared" "clear-backoff"

env_lib "singular_breaker_trip >/dev/null; singular_breaker_trip >/dev/null"
out="$(ops breaker show)"
assert_contains "$out" "breaker: 2/" "breaker show"
out="$(ops breaker reset)"
assert_contains "$out" "breaker reset (was 2" "breaker reset"

out="$(ops stop)"
assert_contains "$out" "STOP written" "stop"
[[ -f "$root/.singular-state/STOP" ]] || fail "STOP file"
out="$(ops resume)"
assert_contains "$out" "STOP removed" "resume"
[[ -f "$root/.singular-state/STOP" ]] && fail "STOP gone"

printf '%s\n' \
  '{"schema":"singular.orchestration.planner-backoff.v0","failureClass":"quota","until":"2999-01-01T00:00:00Z"}' \
  >"$root/.singular-state/planner-backoff.json"
env_lib "singular_breaker_trip >/dev/null"
touch "$root/.singular-state/STOP"
out="$(ops wake)"
assert_contains "$out" "backoff cleared" "wake clears backoff"
assert_contains "$out" "breaker reset" "wake resets breaker"
assert_contains "$out" "STOP removed" "wake drops STOP"
assert_contains "$out" "wake requested" "wake touches WAKE"
[[ -f "$root/.singular-state/WAKE" ]] || fail "WAKE file present"

# --- unpark ------------------------------------------------------------------
# A transient environment fault used to kill a task permanently: escalate-parked
# writes Status: blocked, dispatch selects only Status: ready, recover.sh filters
# to running|planned|needs-review before it could help, and the only operator
# verb was `supersede` — which buries the task in tasks/superseded/ rather than
# repairing it.
cat >"$root/docs/orchestration/tasks/TASK-0010.md" <<'EOF'
# TASK-0010: parked on a missing dependency

Status: blocked
Area: core
DAG node: node-z
Dispatch mode: canonical

## Objective

Parked by audit-infra.

## Scope

Owned files:

- `src/z.ts`
EOF
# retryCount at the ceiling and a refusals counter: both are what make an
# unpark that only flips the task status useless.
printf '%s\n' '{"taskId":"TASK-0010","status":"blocked","retryCount":3,"branch":"agent/core/TASK-0010"}' \
  >"$root/.singular-state/leases/TASK-0010.json"
printf '3\n' >"$root/.singular-state/dispatch/TASK-0010.refusals"

out="$(ops unpark TASK-0010 --reason "dependency installed")"
assert_contains "$out" "unparked TASK-0010" "unpark completes"
grep -q "^Status: ready" "$root/docs/orchestration/tasks/TASK-0010.md" || fail "unpark: task status"
[[ -f "$root/docs/orchestration/tasks/TASK-0010.md" ]] || fail "unpark: task file must stay in place"
lease_json="$root/.singular-state/leases/TASK-0010.json"
[[ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$lease_json")" == "ready" ]] \
  || fail "unpark: lease status"
# Nothing else in the engine ever resets retryCount, and decide.sh reads it to
# decide whether any budget remains — an unpark that leaves it at the ceiling
# parks again on the first failure with no attempt left to spend.
[[ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["retryCount"])' "$lease_json")" == "0" ]] \
  || fail "unpark: retryCount not reset"
# Only cleared on a successful dispatch otherwise, so an unparked task would
# inherit the old count and re-park at the threshold.
[[ ! -f "$root/.singular-state/dispatch/TASK-0010.refusals" ]] || fail "unpark: refusals counter"
grep -q "unpark" "$root/docs/orchestration/decisions.md" || fail "unpark: decision recorded"
assert_contains "$(cat "$root/.singular-state/events.ndjson")" '"type":"task.unparked"' "unpark event"

# The task is dispatch-eligible again — the point of the whole verb.
readyish="$(env SINGULAR_ROOT="$root" SINGULAR_STATE_DIR="$root/.singular-state" \
  SINGULAR_ORCH_DIR="$root/docs/orchestration" SINGULAR_TASKS_DIR="$root/docs/orchestration/tasks" \
  SINGULAR_LEASES_DIR="$root/.singular-state/leases" SINGULAR_TARGET_BRANCH=target \
  bash -c 'source "$0"/lib.sh; singular_list_status_ready_tasks' "$SCRIPT_DIR")"
assert_contains "$readyish" "TASK-0010" "unpark returns the task to the ready set"

# Idempotent.
out="$(ops unpark TASK-0010)"
assert_contains "$out" "already ready" "unpark idempotent"

# A partial prior unpark (or old engine bug) can leave the task ready while the
# lease still says failed with an exhausted, started product lineage. Do not
# claim an idempotent success without reconciling the durable budget.
python3 - "$lease_json" <<'PY'
import json
import os
import sys

path = sys.argv[1]
lease = json.load(open(path, encoding="utf-8"))
lease["status"] = "failed"
lease["retryCount"] = 3
lease["productPassStarted"] = True
temporary = path + ".tmp"
with open(temporary, "w", encoding="utf-8") as stream:
    json.dump(lease, stream)
os.replace(temporary, path)
PY
out="$(ops unpark TASK-0010)"
assert_contains "$out" "stale lease budget reconciled" \
  "unpark reconciles a ready task's exhausted lease"
[[ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["retryCount"])' "$lease_json")" == "0" ]] \
  || fail "unpark ready reconciliation: retryCount not reset"
[[ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["productPassStarted"])' "$lease_json")" == "False" ]] \
  || fail "unpark ready reconciliation: productPassStarted not reset"

# If a lease exists but cannot be decoded/replaced, unpark must fail before
# changing the task to ready. The old path printed "no lease (ok)" and exposed
# a task that immediately re-parked against the unreconciled budget.
cat >"$root/docs/orchestration/tasks/TASK-0012.md" <<'EOF'
# TASK-0012: corrupt parked lease

Status: blocked
Area: core
Dispatch mode: canonical

## Objective

Remain blocked when durable budget state cannot be reconciled.

## Scope

Owned files:

- `src/corrupt.ts`
EOF
printf '%s\n' '{not-json' >"$root/.singular-state/leases/TASK-0012.json"
rc=0
out="$(ops unpark TASK-0012 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "unpark: corrupt existing lease must fail"
assert_contains "$out" "lease budget reset FAILED" \
  "unpark reports durable lease reset failure"
grep -q '^Status: blocked$' "$root/docs/orchestration/tasks/TASK-0012.md" \
  || fail "unpark: task must remain blocked when lease reset fails"

# It must not override a live status — that would race a running worker.
# A task of its own: the supersede cases above have already moved TASK-0003 into
# tasks/superseded/, so reusing it would exercise the wrong refusal.
cat >"$root/docs/orchestration/tasks/TASK-0011.md" <<'EOF'
# TASK-0011: live worker

Status: running
Area: core
Dispatch mode: canonical

## Objective

In flight.

## Scope

Owned files:

- `src/live.ts`
EOF
rc=0
out="$(ops unpark TASK-0011 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "unpark: must refuse a running task"
assert_contains "$out" "refusing to override a live status" "unpark refuses running"

# A superseded task is buried, not parked; say so instead of resurrecting it.
rc=0
out="$(ops unpark TASK-0001 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "unpark: must refuse a superseded task"
assert_contains "$out" "is superseded, not parked" "unpark refuses superseded"

echo "PASS: S0.4-7: existing operator compatibility assertions"

# Names this test fixes: none beyond existing public commands, options, state
# records and event kinds. S0.4-7 uses the CLI's successful --help convention.
# No-value verbs have no real missing-value form: --reason without a value is
# an unsupported incomplete option. stop --wait is valid; --wait= is incomplete.
# Both a quoted ask question and separate positional words are valid; see the
# free-word exception and parser references in the header.
python3 - "$ENGINE_HOME" "$tmp/matrix" "$BASH" <<'PY'
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys

engine, scratch, bash = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
scratch.mkdir()
failures = []
checks = 0


def check(condition, message):
    global checks
    checks += 1
    if not condition:
        failures.append(message)
        print('FAIL: S0.4-7: ' + message, flush=True)


def require(condition, message):
    if not condition:
        raise AssertionError('S0.4-7: fixture/inventory: ' + message)


# Fail closed on new dispatch entries, including routes exposed by recover.
# Parsing is for coverage discovery only; behaviour below uses the public CLI.
cli = (engine / 'cli/singular').read_text()
ops_source = (engine / 'engine/ops.sh').read_text()
recover = (engine / 'engine/recover.sh').read_text()
direct = dict(re.findall(r'^\s*([\w-]+)\)\s*run_engine\s+ops\.sh\s+([\w-]+)', cli, re.M))
expected_direct = set('supersede unpark clear-backoff breaker stop resume wake gates health gc plan ask report'.split())
require(set(direct) == expected_direct and all(k == v for k, v in direct.items()),
        'CLI operator routes changed; classify and cover every new route')
recovery = dict(re.findall(r'if \[\[ "\$\{1:-\}" == "([\w-]+)" \]\]; then\s+shift\s+exec "\$SCRIPT_DIR/ops.sh" ([\w-]+)', recover))
require(recovery == {'candidate': 'recover-candidate',
                     'orphan-reservation': 'reconcile-orphan-reservation',
                     'continuation': 'authorize-continuation',
                     'continuation-preparation': 'rearm-continuation-preparation'},
        'recovery operator routes changed; classify and cover every new route')
dispatch = ops_source.rsplit('case "$verb" in', 1)[-1]
engine_verbs = set(re.findall(r'^\s*([\w-]+)\)', dispatch, re.M))
require(engine_verbs == set(direct.values()) | set(recovery.values()),
        'ops dispatch differs from classified public routes')
for verb, expected in [('plan', {'archive', 'list'}), ('breaker', {'show', 'reset'})]:
    target = re.search(r'^\s*' + verb + r'\)\s*(\w+)\s+"\$@"', dispatch, re.M)
    require(target is not None, verb + ' routing changed; update coverage discovery')
    # Derive the implementation symbol, rather than fixing its name in a test.
    definition = re.search(r'^' + target[1] + r'\s*\(\)\s*\{(.*?)^\}', ops_source, re.M | re.S)
    require(definition is not None, verb + ' subcommand routing could not be inventoried')
    body = definition[1]
    require(set(re.findall(r'^\s*([\w-]+)\)', body, re.M)) == expected,
            verb + ' subcommands changed; classify new mutators')
print('PASS: S0.4-7: dispatch inventory (15 mutating routes; gates/health, breaker show, plan list read-only)', flush=True)


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value)


def put(path, value):
    write(path, json.dumps(value, sort_keys=True) + '\n')


def read(path):
    return json.loads(path.read_text())


class Fixture:
    def __init__(self, name):
        self.base = scratch / name
        self.repo = self.base / 'repo'
        self.state = self.repo / '.singular-state'
        self.orch = self.repo / 'docs/orchestration'
        self.tasks = self.orch / 'tasks'
        self.task = self.tasks / 'TASK-0001.md'
        self.lease = self.state / 'leases/TASK-0001.json'
        self.worktree = self.repo / '.worktrees/TASK-0001'
        self.repo.mkdir(parents=True)
        # Drop inherited project configuration and Git routing, without reading
        # credentials or a machine install. Every runner is an inert stub.
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('SINGULAR_', 'GIT_'))}
        self.env.update(SINGULAR_ROOT=str(self.repo), SINGULAR_ENGINE_HOME=str(engine),
                        SINGULAR_HOME=str(self.base / 'machine'), SINGULAR_BASH_BIN=bash,
                        SINGULAR_LOCAL_CONFIG_FILE='/dev/null', SINGULAR_PUSH='0',
                        SINGULAR_TARGET_BRANCH='target', SINGULAR_LOCK_WAIT_SEC='0',
                        SINGULAR_RUNS_KEEP='1', SINGULAR_RUNS_MIN_AGE_HOURS='0',
                        SINGULAR_GC_WORKTREES='0', PYTHONDONTWRITEBYTECODE='1',
                        GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
                        GIT_AUTHOR_NAME='fixture', GIT_AUTHOR_EMAIL='fixture',
                        GIT_COMMITTER_NAME='fixture', GIT_COMMITTER_EMAIL='fixture',
                        TMPDIR=str(self.base / 'tmp'))
        Path(self.env['TMPDIR']).mkdir()
        for setting, path in {
            'STATE_DIR': self.state, 'ORCH_DIR': self.orch, 'TASKS_DIR': self.tasks,
            'LEASES_DIR': self.state / 'leases', 'DISPATCH_DIR': self.state / 'dispatch',
            'INBOX_DIR': self.state / 'inbox', 'RUNS_DIR': self.state / 'runs',
            'WORKTREES_DIR': self.repo / '.worktrees',
        }.items():
            path.mkdir(parents=True, exist_ok=True)
            self.env['SINGULAR_' + setting] = str(path)
        self.env['SINGULAR_EVENTS_FILE'] = str(self.state / 'events.ndjson')
        write(self.repo / '.gitignore', '.singular-state/\n.worktrees/\n')
        put(self.repo / 'singular.config.json', {'schemaVersion': 'v2', 'targetBranch': 'target',
                                              'gateCommand': 'true',
                                              'bootstrap': {'required': False, 'commands': []}})
        self.env['SINGULAR_JSON_CONFIG_FILE'] = str(self.repo / 'singular.config.json')
        for tid in ('TASK-0001', 'TASK-0002'):
            write(self.tasks / (tid + '.md'), f'''# {tid}: synthetic operator fixture
Status: blocked
Area: core
Target branch: `target`
Worker branch: `agent/core/{tid}`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective
Preserve synthetic state until an operator requests a valid transition.

## Scope
Owned files:
- `app.txt`

## Acceptance Criteria
- The public operator transition is recorded.
''')
        write(self.repo / 'app.txt', 'synthetic base\n')
        for prompt in ('l2-test-first-developer.md', 'auditor.md', 'supervisor.md', 'supervisor-ask.md'):
            destination = self.orch / 'prompts' / prompt
            destination.parent.mkdir(exist_ok=True)
            shutil.copyfile(engine / 'templates/prompts' / prompt, destination)
        put(self.orch / 'dag.v0.json', {'schema': 'singular.orchestration.dag.v0', 'nodes': []})
        self.run(['git', 'init', '-q'])
        self.run(['git', 'checkout', '-qb', 'target'])
        self.run(['git', 'add', '.'])
        self.run(['git', 'commit', '-qm', 'synthetic fixture'])
        self.head = self.run(['git', 'rev-parse', 'HEAD']).stdout.strip()
        self.tree = self.run(['git', 'rev-parse', 'HEAD^{tree}']).stdout.strip()
        require(not self.run(['git', 'remote']).stdout.strip(), 'fixture must have no remote')
        write(self.state / 'STOP', 'synthetic stop sentinel\n')
        put(self.state / 'planner-backoff.json', {
            'schema': 'singular.orchestration.planner-backoff.v0',
            'failureClass': 'quota', 'until': '2999-01-01T00:00:00Z'})
        put(self.state / 'circuit.json', {'consecFails': 3, 'updatedAt': '2000-01-01T00:00:00Z'})
        put(self.lease, {'taskId': 'TASK-0001', 'status': 'blocked', 'retryCount': 3,
                         'productPassStarted': True, 'branch': 'agent/core/TASK-0001'})
        put(self.state / 'leases/TASK-0002.json', {'taskId': 'TASK-0002', 'status': 'blocked'})
        write(self.state / 'dispatch/TASK-0001.refusals', '3\n')
        put(self.state / 'inbox/RUN-OLD.json', {'taskId': 'TASK-0001', 'runId': 'RUN-OLD',
                                              'status': 'needs-review'})
        put(self.state / 'events.ndjson', {'ts': '2000-01-01T00:00:00Z', 'type': 'fixture.seed',
                                          'message': 'synthetic history', 'data': {}})
        self.runner = self.base / 'runner.sh'
        write(self.runner, '''#!/usr/bin/env bash
set -euo pipefail
[[ -z "${RAILS_NONCE+x}" && -z "${RAILS_VERDICT_FILE+x}" ]] || exit 98
out=""; meta=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-last-message) out="$2"; shift 2 ;;
    --session-meta) meta="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$meta" ]] && printf '%s\\n' '{"provider":"fake","model":"fixture","exitCode":0}' >"$meta"
if [[ "${SINGULAR_RUNNER_ROLE:-}" == supervisor ]]; then
  printf '%s\\n' '{"schema":"singular.orchestration.supervisor-report.v0","stage":"fixture","narrative":"Synthetic briefing.","risks":[],"nextSteps":[],"proposedSettings":{}}' >"$out"
else
  printf '%s\\n' 'Synthetic answer.' >"$out"
fi
''')
        self.runner.chmod(0o755)
        self.env['SINGULAR_RUNNER'] = str(self.runner)
        self.env['SINGULAR_ROLE_RUNNER_SUPERVISOR'] = str(self.runner)

    def run(self, argv, must_succeed=True):
        # Bound every child; on a timeout kill only our own process group.
        with subprocess.Popen([str(a) for a in argv], cwd=self.repo, env=self.env,
                              stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True, start_new_session=True) as proc:
            try:
                out, _ = proc.communicate(timeout=45)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.communicate()
                raise AssertionError('S0.4-7: bounded command timed out: ' + str(argv[0]))
        result = subprocess.CompletedProcess(argv, proc.returncode, out)
        if must_succeed:
            # Redact scratch/source roots before reporting fixture diagnostics.
            safe = out.replace(str(self.base), '<fixture>').replace(str(engine), '<engine>')
            require(result.returncode == 0, 'valid command failed: ' + safe[-1500:])
        return result

    def cli(self, args, must_succeed=True):
        return self.run([bash, engine / 'cli/singular', *args], must_succeed)

    def lifecycle(self, *args):
        return self.run(['python3', engine / 'engine/task_lifecycle.py', *args])

    def snapshot(self):
        # Exact bytes and path membership, no hashes that could hide differences.
        # Include ALL persistent state and orchestration files, plus retained
        # worktree bytes. This includes the six mandated surfaces and catches
        # new authority records, archives and supervisor dispatches as well.
        result = {}
        for parent in (self.state, self.orch, self.repo / '.worktrees'):
            for path in sorted(parent.rglob('*')):
                key = str(path.relative_to(self.repo))
                if path.is_symlink():
                    result[key] = ('symlink', os.readlink(path))
                elif path.is_file():
                    result[key] = ('file', path.read_bytes())
        return result

    def orphan(self):
        write(self.task, self.task.read_text().replace('Status: blocked', 'Status: ready'))
        self.run(['git', 'add', '.'])
        self.run(['git', 'commit', '-qm', 'ready recovery task'])
        self.head = self.run(['git', 'rev-parse', 'HEAD']).stdout.strip()
        self.run(['git', 'worktree', 'add', '-qb', 'agent/core/TASK-0001', self.worktree])
        write(self.worktree / 'app.txt', 'retained partial bytes\n')
        put(self.lease, {'taskId': 'TASK-0001', 'status': 'planned', 'retryCount': 0,
                         'maxRetries': 1, 'productPassStarted': True,
                         'productPassStartedRunId': 'RUN-PREVIOUS',
                         'branch': 'agent/core/TASK-0001', 'reservationOwner': 'fixture-owner',
                         'reservationGeneration': 1, 'reservationRunId': 'RUN-OLD',
                         'campaignBinding': 'legacy', 'baseSha': self.head,
                         'worktree': str(self.worktree)})
        return ['recover', 'orphan-reservation', 'TASK-0001', '--owner', 'fixture-owner',
                '--generation', '1', '--run', 'RUN-OLD', '--campaign', 'legacy',
                '--reservation-base', self.head, '--candidate-source', self.head,
                '--worktree', str(self.worktree)]

    def candidate(self):
        # Produce internally bound synthetic authorities through the real
        # lifecycle/gate-report tools; no accepted-packet fixture is copied.
        run = self.state / 'runs/RUN-OLD'
        run.mkdir()
        packet, audit = run / 'packet.json', run / 'audit.json'
        request, report = run / 'verification-request-1.json', run / 'audit-verification.json'
        bound_task = run / 'verification-task-contract-1.md'
        policy, log = run / 'verification-policy-1.json', run / 'gate.log'
        shutil.copyfile(self.task, bound_task)
        put(policy, {'campaign': 'legacy', 'policy': 'legacy'})
        write(log, 'synthetic host gate passed\n')
        put(packet, {'taskId': 'TASK-0001', 'runId': 'RUN-OLD', 'branch': 'agent/old',
                     'headSha': self.head, 'status': 'accepted'})
        put(audit, {'schema': 'singular.orchestration.audit-verdict.v1',
                    'taskId': 'TASK-0001', 'runId': 'RUN-OLD', 'branch': 'agent/old',
                    'verdict': 'accepted', 'evidenceReviewed': ['reviewed-head-sha:' + self.head]})
        gate = ['python3', engine / 'engine/gate-report.py']
        self.run([*gate, 'create-verification-request', '--output', request, '--task-id', 'TASK-0001',
                  '--run-id', 'RUN-OLD', '--attempt', '1', '--head-sha', self.head,
                  '--tree-sha', self.tree, '--campaign', 'legacy', '--task-contract', bound_task,
                  '--policy-contract', policy, '--suite-id', 'task-contract-gate'])
        self.run([*gate, 'create', '--output', report, '--task-id', 'TASK-0001', '--run-id', 'RUN-OLD',
                  '--head-sha', self.head, '--command', 'true', '--exit-code', '0', '--log', log,
                  '--phase', 'audit-verification', '--workspace-kind', 'disposable',
                  '--integrity-status', 'verified'])
        self.run([*gate, 'bind-verification-result', '--request', request, '--report', report,
                  '--task-contract', bound_task, '--policy-contract', policy])
        self.lifecycle('retain-candidate', '--lease', self.lease, '--packet', packet, '--audit', audit,
                       '--task-file', self.task, '--task', 'TASK-0001', '--run', 'RUN-OLD',
                       '--branch', 'agent/old', '--head', self.head, '--tree', self.tree,
                       '--campaign', 'legacy', '--acceptance-mode', 'accepted')
        self.lifecycle('candidate-failed', '--lease', self.lease, '--head', self.head,
                       '--tree', self.tree, '--campaign', 'legacy', '--failure-class', 'gate-red',
                       '--target-head', self.head, '--invalidation-key', 'fixture-inputs',
                       '--failure-id', 'fixture-failure', '--domain', 'product',
                       '--next-action', 'authorize repair')
        return ['recover', 'candidate', 'TASK-0001', '--action', 'repair', '--successor-run', 'RUN-REPAIR',
                '--successor-branch', 'agent/repair', '--successor-worktree', str(self.base / 'repair'),
                '--failure-id', 'fixture-failure']


def prepare(name):
    f = Fixture(name)
    if name == 'supersede':
        args = ['supersede', 'TASK-0001', '--by', 'TASK-0002', '--reason', 'fixture']
    elif name == 'unpark':
        args = ['unpark', 'TASK-0001', '--reason', 'fixture']
    elif name == 'breaker':
        args = ['breaker', 'reset']
    elif name == 'stop':
        args = ['stop', '--wait=0']  # no live loop; never actually waits
    elif name == 'wake':
        args = ['wake']
    elif name == 'plan':
        args = ['plan', 'archive', '--force', '--no-commit', '--name', 'fixture']
    elif name == 'ask':
        args = ['ask', 'What is the fixture status?', '--wait']
    elif name == 'gc':
        args = ['gc']
        for index in range(2):
            run = f.state / ('runs/RUN-GC-' + str(index))
            write(run / 'fixture.txt', 'retired synthetic run\n')
            os.utime(run, (100000 + index, 100000 + index))
    elif name == 'orphan-reservation':
        args = f.orphan()
    elif name in ('continuation', 'continuation-preparation'):
        f.cli(f.orphan())
        args = ['recover', 'continuation', 'TASK-0001', '--predecessor-owner', 'fixture-owner',
                '--predecessor-generation', '1', '--predecessor-run', 'RUN-OLD',
                '--predecessor-campaign', 'legacy', '--predecessor-reservation-base', f.head,
                '--candidate-source', f.head, '--integration-target', f.head,
                '--worktree', str(f.worktree)]
        if name == 'continuation-preparation':
            f.cli(args)
            lease = read(f.lease)
            authority = lease['continuationAuthorization']
            authority['state'] = 'preparation-blocked'
            lease['status'] = 'blocked'
            put(f.lease, lease)
            write(f.task, f.task.read_text().replace('Status: ready', 'Status: blocked'))
            evidence = f.base / 'repair-evidence.txt'
            write(evidence, 'synthetic host condition repaired\n')
            args = ['recover', name, 'TASK-0001', '--authorization-id', authority['authorizationId'],
                    '--evidence', str(evidence)]
    elif name == 'candidate':
        args = f.candidate()
    else:
        args = [name]
    return f, args


def valid_effect(f, name):
    state = f.state
    if name == 'stop':
        return (state / 'STOP').is_file() and (state / 'STOP').read_bytes() == b''
    if name == 'resume':
        return not (state / 'STOP').exists()
    if name == 'clear-backoff':
        return not (state / 'planner-backoff.json').exists()
    if name == 'breaker':
        return read(state / 'circuit.json')['consecFails'] == 0
    if name == 'wake':
        return (not (state / 'STOP').exists() and not (state / 'planner-backoff.json').exists()
                and read(state / 'circuit.json')['consecFails'] == 0 and (state / 'WAKE').exists())
    if name == 'unpark':
        lease = read(f.lease)
        return ('Status: ready' in f.task.read_text() and lease['status'] == 'ready'
                and lease['retryCount'] == 0 and not lease['productPassStarted']
                and not (state / 'dispatch/TASK-0001.refusals').exists())
    if name == 'supersede':
        return (not f.task.exists() and (f.tasks / 'superseded/TASK-0001.md').is_file()
                and read(f.lease)['status'] == 'superseded'
                and (state / 'inbox/superseded/RUN-OLD.json').exists())
    if name == 'gc':
        return not (state / 'runs/RUN-GC-0').exists() and (state / 'runs/RUN-GC-1').exists()
    if name == 'plan':
        plans = read(state / 'plans/index.json')['plans']
        return (len(plans) == 1 and plans[0]['name'] == 'fixture'
                and (state / 'plans' / plans[0]['id'] / 'docs/orchestration/tasks/TASK-0001.md').exists())
    if name == 'ask':
        return any(p.read_text().strip() == 'Synthetic answer.' for p in (state / 'runs').glob('ASK-*/answer.md'))
    if name == 'report':
        return read(state / 'supervisor/latest.json')['narrative'] == 'Synthetic briefing.'
    if name == 'orphan-reservation':
        lease = read(f.lease)
        return lease['status'] == 'blocked' and lease['terminalDisposition']['kind'] == 'orphan-reservation'
    if name in ('continuation', 'continuation-preparation'):
        authority = read(f.lease)['continuationAuthorization']
        return (authority['state'] == 'issued' and authority['additionalWorkerAttemptsRemaining'] == 1
                and authority['additionalWorkerAttemptsClaimed'] == 0
                and (f.worktree / 'app.txt').read_text() == 'retained partial bytes\n')
    if name == 'candidate':
        lease = read(f.lease)
        return (lease['status'] == 'ready' and lease['recoveryAuthorization']['state'] == 'issued'
                and lease['candidateHistory'][0]['runId'] == 'RUN-OLD')
    raise AssertionError('S0.4-7: missing valid-effect assertion for ' + name)


mutators = sorted((set(direct) - {'gates', 'health'}) | set(recovery))
require(len(mutators) == 15, 'expected fifteen mutating routes')
valid_count = 0
bad_count = 0
help_status = None
valid_events = {
    'supersede': 'task.superseded', 'unpark': 'task.unparked',
    'breaker': 'breaker.reset', 'clear-backoff': 'backoff.cleared',
    'stop': 'operator.stop_requested', 'resume': 'operator.resume_requested',
    'wake': 'operator.wake', 'gc': 'gc.completed', 'plan': 'plan.archived',
    'ask': 'supervisor.ask_answered', 'report': 'supervisor.report',
    'orphan-reservation': 'recovery.orphan_reservation_reconciled',
    'continuation': 'recovery.continuation_authorized',
    'continuation-preparation': 'recovery.continuation_preparation_rearmed',
    'candidate': 'candidate.recovery_authorized',
}
for name in mutators:
    f, good = prepare(name)
    if help_status is None:
        reference = f.cli(['--help'])
        require(bool(re.search(r'\busage\b', reference.stdout, re.I)), 'global help prints usage')
        help_status = reference.returncode
    original = f.snapshot()
    backup = f.base / 'pristine'
    shutil.copytree(f.repo, backup, symlinks=True)
    result = f.cli(good)
    require(valid_effect(f, name), name + ' valid invocation did not perform its transition')
    events = [json.loads(line)['type'] for line in (f.state / 'events.ndjson').read_text().splitlines()]
    require(valid_events[name] in events, name + ' valid invocation did not record its action event')
    require(f.snapshot() != original, name + ' valid case was a no-op')
    valid_count += 1
    print('PASS: S0.4-7: valid ' + ' '.join(good[:2] if good[0] in ('recover', 'plan', 'breaker') else good[:1]), flush=True)

    if name == 'ask':
        shutil.rmtree(f.repo)
        shutil.copytree(backup, f.repo, symlinks=True)
        # Separate argv entries model: singular ask what is the status --wait.
        f.cli(['ask', 'what', 'is', 'the', 'status', '--wait'])
        questions = list((f.state / 'runs').glob('ASK-*/question.md'))
        require(len(questions) == 1 and questions[0].read_bytes() == b'what is the status',
                'ask/free-words must stage exactly one question with all words joined')
        require((questions[0].parent / 'answer.md').read_text().strip() == 'Synthetic answer.',
                'ask/free-words must answer the joined question')
        events = [json.loads(line)['type'] for line in (f.state / 'events.ndjson').read_text().splitlines()]
        require(events.count(valid_events[name]) == 1,
                'ask/free-words must record exactly one answer event')
        valid_count += 1
        print('PASS: S0.4-7: valid ask/free-words (one joined question)', flush=True)

    route = good[:2] if good[0] in ('recover', 'plan') else good[:1]
    # Explicit empty option values are additionally checked for the numeric
    # wait form. Appending help to a fully valid mutating prefix catches parsers
    # that validate only their first argument (the known stop/breaker bugs).
    bad = [('help', route + ['--help']), ('help-after-valid-prefix', good + ['--help']),
           ('unknown-option', good + ['--not-an-ops-option'])]
    if name != 'ask':
        bad.append(('trailing-argument', good + ['trailing-junk']))
    if name in ('supersede', 'unpark', 'plan', *recovery):
        bad.append(('missing-value', good[:-1]))
    elif name == 'stop':
        bad.append(('missing-value', ['stop', '--wait=']))
    elif name == 'ask':
        bad.append(('missing-value', ['ask', '--wait']))
    elif name == 'gc':
        bad.append(('missing-value', ['gc', '--from-reconcile']))
    else:
        bad.append(('missing-value/unsupported-option', good + ['--reason']))
    if name in ('supersede', 'unpark'):
        bad.append(('trailing-task-id', good + ['TASK-0002']))

    for category, args in bad:
        # Only synthetic fixture files are restored, never the source checkout.
        shutil.rmtree(f.repo)
        shutil.copytree(backup, f.repo, symlinks=True)
        before = f.snapshot()
        result = f.cli(args, must_succeed=False)
        after = f.snapshot()
        label = name + '/' + category
        if category.startswith('help'):
            check(result.returncode == help_status,
                  label + ': help exit should match CLI help (0), got ' + str(result.returncode))
            check(bool(re.search(r'\busage\b', result.stdout, re.I)), label + ': help must print usage')
        else:
            check(result.returncode > 0, label + ': invalid argv must exit nonzero, got ' + str(result.returncode))
        changed = sorted(k for k in before.keys() | after.keys() if before.get(k) != after.get(k))
        check(not changed, label + ': changed state: ' + ', '.join(changed[:8]))
        bad_count += 1

print(f'S0.4-7: {valid_count} valid transitions passed; {bad_count} malformed/help calls; {checks} assertions; {len(failures)} failed', flush=True)
if failures:
    raise SystemExit(1)
PY

echo "PASS: S0.4-7: test-ops-verbs"
# Cleanup precedes the trusted verdict. No child receives either rails variable.
cleanup
trap - EXIT
if [[ -n "$ops_verdict_nonce" && -n "$ops_verdict_file" ]]; then
  printf '%s' "$ops_verdict_nonce" >"$ops_verdict_file"
fi
