#!/usr/bin/env bash
rails_nonce="${RAILS_NONCE-}" rails_verdict_file="${RAILS_VERDICT_FILE-}"
unset RAILS_NONCE RAILS_VERDICT_FILE
set -euo pipefail

# Names this test fixes: none beyond the shared brief. JSON configuration uses
# the existing env{} map; no new declarative configuration key is prescribed.
# S0.4-5: compatibility, plus the accept-setting row's setting contract.
# S0.4-11: positive legacy-waiver admission only. Strict path enforcement is
# owned by other rows; every-path is exercised only on an operator command.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Keep Unix-domain evidence-delivery socket paths below the platform limit.
scratch="$(mktemp -d /tmp/ad.XXXXXX)"
trap 'chmod -R u+w "$scratch" 2>/dev/null || true; rm -rf "$scratch"' EXIT
while IFS= read -r key; do unset "$key"; done < <(compgen -v | grep '^SINGULAR_' || true)
export SINGULAR_ENGINE_HOME="$ROOT" SINGULAR_PUSH=0
export SINGULAR_HOME="$scratch/machine" PYTHONDONTWRITEBYTECODE=1
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=fixture GIT_COMMITTER_NAME=fixture
export GIT_AUTHOR_EMAIL=fixture GIT_COMMITTER_EMAIL=fixture
export TMPDIR="$scratch/tmp"
mkdir -p "$TMPDIR"
failures=0
check() {
  local label="$1"; shift
  if "$@"; then printf 'ok: %s\n' "$label"
  else printf 'FAIL: %s\n' "$label"; failures=$((failures + 1)); fi
}
json_field() {
  python3 - "$1" "$2" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))[sys.argv[2]])
PY
}
counter_value() {
  if [[ -f "$DEFAULTS_COUNTERS/$1" ]]; then cat "$DEFAULTS_COUNTERS/$1"
  else printf '0\n'; fi
}
invoke() {
  command_rc=0
  "$@" >"$case_dir/command.log" 2>&1 || command_rc=$?
}
fixture() {
  case_dir="$scratch/$1"
  export SINGULAR_ROOT="$case_dir/repo"
  export SINGULAR_ORCH_DIR="$SINGULAR_ROOT/docs/orchestration"
  export SINGULAR_TASKS_DIR="$SINGULAR_ORCH_DIR/tasks"
  export SINGULAR_STATE_DIR="$SINGULAR_ROOT/.singular-state"
  export SINGULAR_RUNS_DIR="$SINGULAR_STATE_DIR/runs"
  export SINGULAR_LEASES_DIR="$SINGULAR_STATE_DIR/leases"
  export SINGULAR_INBOX_DIR="$SINGULAR_STATE_DIR/inbox"
  export SINGULAR_EVENTS_FILE="$SINGULAR_STATE_DIR/events.ndjson"
  export SINGULAR_STOP_FILE="$SINGULAR_STATE_DIR/STOP"
  export SINGULAR_WORKTREES_DIR="$SINGULAR_ROOT/.worktrees"
  export SINGULAR_TARGET_BRANCH=target
  export SINGULAR_RUNNER="$case_dir/runner"
  export DEFAULTS_COUNTERS="$case_dir/counters"
  unset SINGULAR_ACCEPTANCE SINGULAR_AUDIT_VERDICT_VALIDATE DEFAULTS_MALFORMED
  mkdir -p "$SINGULAR_TASKS_DIR" "$SINGULAR_ORCH_DIR/prompts" "$SINGULAR_STATE_DIR"
  cp "$ROOT/tests/fixtures/acceptance-defaults/runner.py" "$SINGULAR_RUNNER"
  chmod +x "$SINGULAR_RUNNER"
  cp "$ROOT/templates/prompts/"{l2-test-first-developer,auditor,decider}.md "$SINGULAR_ORCH_DIR/prompts/"
  printf '.singular-state/\n.worktrees/\n.singular-evidence/\n.singular-cache/\n' >"$SINGULAR_ROOT/.gitignore"
  printf '{"schemaVersion":"v1","targetBranch":"target","gateCommand":"true"}\n' >"$SINGULAR_ROOT/singular.config.json"
  cat >"$SINGULAR_TASKS_DIR/TASK-0001.md" <<'TASK'
# TASK-0001: Synthetic widget

Status: ready
Area: widget
Target branch: `target`
Worker branch: `agent/widget/TASK-0001-fixture`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Write a synthetic widget.

## Scope

Owned files:

- `widget.txt`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- The widget exists and the gate passes.
TASK
  git -C "$SINGULAR_ROOT" init -q
  git -C "$SINGULAR_ROOT" symbolic-ref HEAD refs/heads/target
  git -C "$SINGULAR_ROOT" add .
  git -C "$SINGULAR_ROOT" -c commit.gpgsign=false commit -qm initial
}

# A historically eligible packet with a bound host report and audit, but no
# completed review ledger or evidence manifest. This must keep landing under
# driver-only even after the later every-path rows are implemented.
legacy_packet() {
  local waiver="$1" base head tree run_dir worker
  base="$(git -C "$SINGULAR_ROOT" rev-parse HEAD)"
  worker="$case_dir/worker"
  git -C "$SINGULAR_ROOT" worktree add -qb agent/widget/TASK-0001-fixture "$worker"
  printf 'synthetic candidate\n' >"$worker/widget.txt"
  git -C "$worker" add widget.txt
  git -C "$worker" -c commit.gpgsign=false commit -qm candidate
  head="$(git -C "$worker" rev-parse HEAD)"
  tree="$(git -C "$worker" rev-parse 'HEAD^{tree}')"
  run_dir="$SINGULAR_RUNS_DIR/RUN-fixture"
  mkdir -p "$run_dir" "$SINGULAR_LEASES_DIR"
  packet="$run_dir/packet.json"
  python3 - "$SINGULAR_ROOT" "$base" "$head" "$worker" "$waiver" <<'PY'
import json, pathlib, sys
root, base, head, worker, waiver = sys.argv[1:]
state = pathlib.Path(root) / '.singular-state'
run = state / 'runs/RUN-fixture'
def write(path, value):
    path.write_text(json.dumps(value) + '\n')
identity = dict(taskId='TASK-0001', runId='RUN-fixture', branch='agent/widget/TASK-0001-fixture')
evidence = [dict(kind='audit-verification', ref='runs/RUN-fixture/audit-verification.json')]
if waiver == 'yes':
    evidence.append(dict(kind='waiver', ref='decider:accept-waiver'))
write(run / 'packet.json', dict(identity,
    schema='singular.orchestration.state-packet.v0', packetId='synthetic',
    area='widget', role='l2-developer', status='accepted', baseRef=base,
    headSha=head, workspace=worker, ownedFiles=['widget.txt'], changedFiles=['widget.txt'],
    commands=[dict(cmd='true', exitCode=0, logRef='gate.log')], tests=[], evidence=evidence,
    blockers=[], nextAction='integrate', createdAt='2026-01-01T00:00:00Z'))
write(state / 'leases/TASK-0001.json', dict(identity, status='accepted', baseSha=base,
    worktree=worker, ownedFiles=['widget.txt'], forbiddenFiles=[], area='widget', owner='l2-developer'))
write(run / 'audit.json', dict(identity, schema='singular.orchestration.audit-verdict.v0',
    verdict='needs-fix' if waiver == 'yes' else 'accepted',
    evidenceReviewed=['reviewed-head-sha:' + head], commandsRun=[], findings=[],
    requiredFixes=[], rationale='synthetic legacy audit'))
if waiver == 'yes':
    write(run / 'decision-audit-needs-fix.json', dict(
        schema='singular.orchestration.decider-verdict.v0', taskId='TASK-0001',
        failureClass='audit-needs-fix', action='accept-waiver',
        rationale='synthetic legacy waiver', nextOwner='l1'))
PY
  cp "$SINGULAR_TASKS_DIR/TASK-0001.md" "$run_dir/verification-task-contract-1.md"
  printf '{"campaign":"legacy"}\n' >"$run_dir/verification-policy-1.json"
  printf 'synthetic green gate\n' >"$run_dir/audit-verification.log"
  python3 "$ROOT/engine/gate-report.py" create-verification-request \
    --output "$run_dir/verification-request-1.json" --task-id TASK-0001 \
    --run-id RUN-fixture --attempt 1 --head-sha "$head" --tree-sha "$tree" \
    --campaign legacy --task-contract "$run_dir/verification-task-contract-1.md" \
    --policy-contract "$run_dir/verification-policy-1.json" --suite-id task-contract-gate >/dev/null
  python3 "$ROOT/engine/gate-report.py" create --output "$run_dir/audit-verification.json" \
    --task-id TASK-0001 --run-id RUN-fixture --head-sha "$head" --command true \
    --exit-code 0 --log "$run_dir/audit-verification.log" --phase audit-verification \
    --workspace-kind disposable --integrity-status verified >/dev/null
  python3 "$ROOT/engine/gate-report.py" bind-verification-result \
    --request "$run_dir/verification-request-1.json" --report "$run_dir/audit-verification.json" \
    --task-contract "$run_dir/verification-task-contract-1.md" \
    --policy-contract "$run_dir/verification-policy-1.json" >/dev/null
}
import_and_integrate() {
  local criterion="$1" label="$2" imported
  imported="$SINGULAR_ORCH_DIR/packets/imported/TASK-0001/RUN-fixture.json"
  invoke bash "$ROOT/engine/import-packet.sh" "$packet"
  check "$criterion: $label import succeeds" test "$command_rc" -eq 0
  check "$criterion: $label packet published byte-for-byte" cmp -s "$packet" "$imported"
  check "$criterion: $label audit sidecar preserved" cmp -s \
    "$SINGULAR_RUNS_DIR/RUN-fixture/audit.json" "${imported%.json}.audit.json"
  invoke bash "$ROOT/engine/integrate.sh" --task TASK-0001
  check "$criterion: $label integration succeeds" test "$command_rc" -eq 0
  check "$criterion: $label candidate merged into target" git -C "$SINGULAR_ROOT" \
    merge-base --is-ancestor agent/widget/TASK-0001-fixture target
  check "$criterion: $label lease integrated" test \
    "$(json_field "$SINGULAR_LEASES_DIR/TASK-0001.json" status)" = integrated
}
event_count() {
  python3 - "$SINGULAR_EVENTS_FILE" "$1" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
events = [json.loads(line) for line in p.read_text().splitlines()] if p.exists() else []
print(sum(e.get('type') == sys.argv[2] for e in events))
PY
}
unpublished() {
  python3 - "$SINGULAR_STATE_DIR" <<'PY'
import json, pathlib, sys
state = pathlib.Path(sys.argv[1])
assert not list((state / 'inbox').glob('*.json')), 'inbox publication'
for p in list((state / 'runs').glob('*/packet.json')) + list((state / 'leases').glob('*.json')):
    assert json.loads(p.read_text()).get('status') != 'accepted', 'accepted packet or lease'
events = [json.loads(line) for line in (state / 'events.ndjson').read_text().splitlines()]
assert not any(e.get('type') == 'l1.task_accepted' for e in events), 'acceptance event'
PY
}
published() {
  python3 - "$SINGULAR_STATE_DIR" <<'PY'
import json, pathlib, sys
state = pathlib.Path(sys.argv[1])
packets = list((state / 'inbox').glob('*.json'))
assert len(packets) == 1, 'one inbox packet required'
packet = json.loads(packets[0].read_text())
assert packet['status'] == 'accepted', 'inbox packet accepted'
run_packet = state / 'runs' / packet['runId'] / 'packet.json'
assert json.loads(run_packet.read_text())['status'] == 'accepted', 'run packet accepted'
assert json.loads((state / 'leases/TASK-0001.json').read_text())['status'] == 'accepted', 'lease accepted'
events = [json.loads(line) for line in (state / 'events.ndjson').read_text().splitlines()]
assert sum(e.get('type') == 'l1.task_accepted' for e in events) == 1, 'one acceptance event required'
PY
}

printf 'GROUP: existing behavior (S0.4-5, S0.4-11)\n'
fixture default-packet
legacy_packet no
import_and_integrate S0.4-5 unset
for waiver_config in v1-default v2-opt-in; do
  fixture "waiver-$waiver_config"
  if [[ "$waiver_config" == v2-opt-in ]]; then
    printf '{"schemaVersion":"v2","targetBranch":"target","gateCommand":"true","legacyCompatibility":{"unboundWaivers":true}}\n' >"$SINGULAR_ROOT/singular.config.json"
    git -C "$SINGULAR_ROOT" add singular.config.json
    git -C "$SINGULAR_ROOT" -c commit.gpgsign=false commit -qm configuration
  fi
  legacy_packet yes
  import_and_integrate S0.4-11 "$waiver_config"
done

# The valid control must publish before the same runner's one-field defect is
# tried. No internal parser function is called: events expose parse decisions,
# runner counters expose actual retries, and authority files expose publication.
fixture audit-valid
invoke bash "$ROOT/engine/l1-drive.sh" TASK-0001
check 'S0.4-5: valid legacy verdict driver succeeds' test "$command_rc" -eq 0
check 'S0.4-5: valid legacy verdict publishes' published
for mode in strict warn unset; do
  fixture "audit-$mode"
  [[ "$mode" == unset ]] || export SINGULAR_AUDIT_VERDICT_VALIDATE="$mode"
  export DEFAULTS_MALFORMED=1
  invoke bash "$ROOT/engine/l1-drive.sh" TASK-0001
  check "S0.4-5: $mode malformed verdict exits nonzero" test "$command_rc" -ne 0
  if [[ "$mode" == strict ]]; then
    check 'S0.4-5: strict parsing rejects malformed legacy verdict' test "$(event_count l1.audit_invalid_verdict)" -gt 0
    check 'S0.4-5: strict parsing never completes a review round' test "$(event_count review.policy_applied)" -eq 0
    check 'S0.4-5: strict attempts the default one audit repair' test "$(event_count l1.audit_repair_retry)" -eq 1
    check 'S0.4-5: strict launches two auditors' test "$(counter_value audit)" = 2
  else
    check "S0.4-5: $mode parsing warns about malformed legacy verdict" test "$(event_count l1.audit_verdict_warned)" -eq 1
    check "S0.4-5: $mode parsing completes a review round" test "$(event_count review.policy_applied)" -eq 1
    check "S0.4-5: $mode makes no audit repair attempt" test "$(event_count l1.audit_repair_retry)" -eq 0
    check "S0.4-5: $mode launches one auditor" test "$(counter_value audit)" = 1
  fi
  check "S0.4-5: $mode never launches a product repair" test "$(counter_value worker)" = 1
  check "S0.4-5: $mode publication refuses malformed legacy verdict" unpublished
done
printf 'EXISTING BEHAVIOR failures: %s\n' "$failures"

printf 'GROUP: acceptance setting (S0.4-5 accept-setting)\n'
for value in '' driver-only; do
  fixture "packet-${value:-empty}"
  export SINGULAR_ACCEPTANCE="$value"
  legacy_packet no
  import_and_integrate S0.4-5 "acceptance=${value:-empty}"
done

fingerprint() {
  python3 - "$SINGULAR_ROOT" <<'PY'
import hashlib, pathlib, stat, sys
root = pathlib.Path(sys.argv[1])
h = hashlib.sha256()
for p in sorted(root.rglob('*')):
    h.update(str(p.relative_to(root)).encode())
    h.update(str(stat.S_IMODE(p.lstat().st_mode)).encode())
    if p.is_symlink():
        h.update(str(p.readlink()).encode())
    elif p.is_file():
        h.update(p.read_bytes())
print(h.hexdigest())
PY
}
setting_case() {
  local label="$1" expected="$2" env_value="$3" json_value="$4" shell_value="$5" local_value="$6" before
  fixture "setting-$label"
  [[ "$env_value" == absent ]] || export SINGULAR_ACCEPTANCE="$env_value"
  if [[ "$json_value" != absent ]]; then
    python3 - "$SINGULAR_ROOT/singular.config.json" "$json_value" <<'PY'
import json, sys
p, value = sys.argv[1:]
d = json.load(open(p)); d['env'] = {'SINGULAR_ACCEPTANCE': value}
with open(p, 'w') as f:
    json.dump(d, f)
PY
  fi
  [[ "$shell_value" == absent ]] || printf 'export SINGULAR_ACCEPTANCE=%q\n' "$shell_value" >"$SINGULAR_ROOT/singular.config.sh"
  [[ "$local_value" == absent ]] || printf 'export SINGULAR_ACCEPTANCE=%q\n' "$local_value" >"$SINGULAR_STATE_DIR/config.local.sh"
  printf 'synthetic stop\n' >"$SINGULAR_STOP_FILE"
  before="$(fingerprint)"
  invoke bash "$ROOT/engine/ops.sh" resume
  if [[ "$expected" == accept ]]; then
    check "S0.4-5 setting: $label accepts value" test "$command_rc" -eq 0
    check "S0.4-5 setting: $label executes resume" test ! -e "$SINGULAR_STOP_FILE"
  else
    check "S0.4-5 setting: $label rejects invalid value" test "$command_rc" -ne 0
    check "S0.4-5 setting: $label explains invalid acceptance value" \
      grep -iq 'acceptance' "$case_dir/command.log"
    check "S0.4-5 setting: $label refuses before any change" test "$(fingerprint)" = "$before"
  fi
}
setting_case unset accept absent absent absent absent
setting_case empty accept '' absent absent absent
setting_case driver-only accept driver-only absent absent absent
setting_case every-path accept every-path absent absent absent
setting_case bad-env refuse bogus absent absent absent
setting_case bad-json refuse driver-only bogus absent absent
setting_case json-over-env accept bogus driver-only absent absent
setting_case bad-shell refuse every-path driver-only bogus absent
setting_case shell-over-json accept bogus bogus every-path absent
setting_case bad-local refuse driver-only every-path driver-only bogus
setting_case local-over-shell accept bogus bogus bogus driver-only
setting_case local-empty-default accept bogus bogus bogus ''
setting_case case-sensitive refuse DRIVER-ONLY absent absent absent
setting_case whitespace refuse ' driver-only ' absent absent absent

printf 'TOTAL assertion failures: %s\n' "$failures"
[[ "$failures" -eq 0 ]] || exit 1
printf 'PASS: test-acceptance-defaults\n'
# Cleanup precedes the success receipt: no subprocess can inherit its nonce.
chmod -R u+w "$scratch" 2>/dev/null || true
rm -rf "$scratch"
trap - EXIT
if [[ -n "$rails_nonce" && -n "$rails_verdict_file" ]]; then
  printf '%s\n' "$rails_nonce" >"$rails_verdict_file"
fi
