#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/acceptance-rule.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
python3 - "$ROOT" "$scratch" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

root, scratch = map(Path, sys.argv[1:])
fixtures = root / 'tests/fixtures/acceptance-rule'
engine = root / 'engine'
repo = scratch / 'repo'
repo.mkdir()
(repo / '.gitignore').write_text('.singular-state/\n')
env = {key: value for key, value in os.environ.items() if not key.startswith(('SINGULAR_', 'GIT_'))}
env['PYTHONDONTWRITEBYTECODE'] = '1'

def command(*args, **kwargs):
    return subprocess.run(list(map(str, args)), env=env, text=True, capture_output=True, check=True, **kwargs).stdout.strip()

command('git', '-C', repo, 'init', '-q')
tree = command('git', '-C', repo, 'mktree', input='')
# An anonymous, deterministic synthetic commit; no configured identity is read.
head = command('git', '-C', repo, 'hash-object', '-t', 'commit', '-w', '--stdin',
               input=f'tree {tree}\nauthor Fixture <> 0 +0000\ncommitter Fixture <> 0 +0000\n\nSynthetic candidate\n')
run = scratch / 'run'
run.mkdir()
state = scratch / 'state'
(state / 'review-policy').mkdir(parents=True)
(run / 'verification-task-contract-1.md').write_bytes((fixtures / 'task.md').read_bytes())
(run / 'verification-policy-1.json').write_bytes((fixtures / 'policy.json').read_bytes())
(run / 'gate.log').write_text('Synthetic host pass\n')
(repo / 'singular.config.json').write_text('{}\n')
common = ['--task-contract', run / 'verification-task-contract-1.md', '--policy-contract', run / 'verification-policy-1.json']
command(sys.executable, engine / 'gate-report.py', 'create-verification-request',
        '--output', run / 'verification-request-1.json', '--task-id', 'TASK-0001',
        '--run-id', 'RUN-fixture', '--head-sha', head, '--tree-sha', tree,
        '--campaign', 'legacy', '--attempt', '1', '--suite-id', 'task-contract-gate', *common)
command(sys.executable, engine / 'gate-report.py', 'create', '--output', run / 'audit-verification.json',
        '--task-id', 'TASK-0001', '--run-id', 'RUN-fixture', '--head-sha', head,
        '--command', 'true', '--exit-code', '0', '--log', run / 'gate.log', '--integrity-status', 'verified')
command(sys.executable, engine / 'gate-report.py', 'bind-verification-result',
        '--request', run / 'verification-request-1.json', '--report', run / 'audit-verification.json', *common)
files = {name: run / name for name in ('audit.json', 'audit-verification.json', 'evidence-manifest.json')}
files['ledger.json'] = state / 'review-policy/ledger.json'
for name in ('audit.json', 'evidence-manifest.json', 'ledger.json'):
    files[name].write_text((fixtures / name).read_text().replace('@HEAD@', head))
manifest = json.loads(files['evidence-manifest.json'].read_text())
manifest['artifacts'] = [{'ref': name, 'sha256': hashlib.sha256(files[name].read_bytes()).hexdigest(),
                          'bytes': files[name].stat().st_size} for name in ('audit.json', 'audit-verification.json')]
files['evidence-manifest.json'].write_text(json.dumps(manifest))
pristine = {name: path.read_bytes() for name, path in files.items()}
args = [sys.executable, engine / 'acceptance_validator.py', '--task', 'TASK-0001', '--run', 'RUN-fixture',
        '--branch', 'candidate', '--head', head, '--campaign', 'legacy', '--run-dir', run,
        '--repo-root', repo, '--state-dir', state, '--logical-change', 'TASK-0001',
        '--audit', files['audit.json'], '--task-contract', run / 'verification-task-contract-1.md',
        '--config', repo / 'singular.config.json', '--attempt', '1',
        '--policy-env-json', '{}', '--trusted-shell', '', '--legacy-schema-mode', 'warn', '--require-audit', '1']
# Check the real driver decision block with observable side-effect stand-ins.
# No worker/provider is involved; the program and shell branching both run.
driver = (engine / 'l1-drive.sh').read_text()
start = driver.index('  local audit_attempt_result')
end = driver.index('\n}\n', start)
branch_script = r'''set -euo pipefail
SINGULAR_LIB_DIR="$1"
run_dir="$2"
require_audit=1
verdict="$3"
model_verification_status="$4"
audit_record="$run_dir/audit.json"
accepted_audit_pending_evidence=no
task_id=TASK-0001
run_id=RUN-fixture
head_sha=fixture
l1_void_review_round() { printf 'voided\n' > "$run_dir/round-state"; touch "$run_dir/review-policy-void-attempt-1.json"; }
singular_append_event() { printf '%s\n' "$1" >> "$run_dir/events"; }
attempt() {
''' + driver[start:end] + r'''
}
if attempt; then
  rc=0
  touch "$run_dir/accept-transition"
else
  rc=$?
fi
printf '%s|%s|%s\n' "$rc" "${attempt_failure:-}" "$accepted_audit_pending_evidence"
'''
regression_errors = []
for verdict, verification, expected, voided in (
    ('infra', '', '1|audit-infra|no', False),
    ('infra', 'passed', '1|audit-infra|no', False),
    ('needs-fix', 'inconclusive-infrastructure', '1|audit-infra|no', True),
    ('accepted', 'inconclusive-infrastructure', '1|evidence-infra-after-accept|yes', False),
):
    branch_run = scratch / ('branch-' + verdict + '-' + verification)
    branch_run.mkdir()
    (branch_run / 'round-state').write_text('counted\n')
    result = command(os.environ.get('BASH', 'bash'), '-c', branch_script, 'fixture', engine, branch_run, verdict, verification)
    actual_voided = (branch_run / 'review-policy-void-attempt-1.json').exists()
    if result != expected or actual_voided != voided or (branch_run / 'round-state').read_text() != ('voided\n' if voided else 'counted\n'):
        regression_errors.append(('F1', verdict, verification, result, actual_voided))
    if verdict == 'infra' and (branch_run / 'events').exists():
        regression_errors.append(('F1', 'verdict emitted an infrastructure event'))
# G1: agent-written option-like verdicts remain values. A failed or unreadable
# decision must never take the caller's successful-attempt accept transition.
g1_cases = [(f'verdict-{index}', engine, verdict, '1|audit-' + verdict + '|no')
            for index, verdict in enumerate(('-needs-fix', '-x', '--needs-fix'))]
for name, output, status in (
    ('exit-2', '', 2),
    ('continue-exit-2', 'continue\t', 2),
    ('unknown-branch', 'unexpected\t', 0),
    ('empty-answer', '', 0),
):
    stub = scratch / name
    stub.mkdir()
    (stub / 'acceptance_validator.py').write_text(
        f'import sys\nsys.stdout.write({output!r})\nsys.exit({status})\n')
    g1_cases.append((name, stub, 'accepted', '1|audit-infra|no'))
g1_cases.append(('accepted-control', engine, 'accepted', '0||no'))
for name, program_dir, verdict, expected in g1_cases:
    branch_run = scratch / ('g1-' + name)
    branch_run.mkdir()
    (branch_run / 'round-state').write_text('counted\n')
    result = subprocess.run([os.environ.get('BASH', 'bash'), '-c', branch_script,
                             'fixture', str(program_dir), str(branch_run), verdict, ''],
                            env=env, text=True, capture_output=True)
    accepted = (branch_run / 'accept-transition').exists()
    passed = (result.returncode == 0 and result.stdout.strip() == expected
              and accepted == (name == 'accepted-control')
              and (branch_run / 'round-state').read_text() == 'counted\n'
              and not (branch_run / 'review-policy-void-attempt-1.json').exists()
              and not (branch_run / 'events').exists()
              and not result.stderr)
    print(f'G1 {name}: {"PASS" if passed else "FAIL"}', flush=True)
    if not passed:
        regression_errors.append(('G1', name, result.returncode, result.stdout.strip(),
                                  'accept-transition', accepted, result.stderr))
for flag in ('--config', '--policy-env-json', '--trusted-shell', '--legacy-schema-mode', '--require-audit'):
    omitted = list(args)
    index = omitted.index(flag)
    del omitted[index:index + 2]
    result = subprocess.run(list(map(str, omitted)), env=env, text=True, capture_output=True)
    if result.returncode != 2 or result.stdout or flag not in result.stderr:
        regression_errors.append(('F6', flag, result.returncode))
# A usage error must still produce the classic redirected diagnostic pair.
for flag in ('--require-audit', '--legacy-schema-mode'):
    invalid = list(args)
    invalid[invalid.index(flag) + 1] = '--invalid-value'
    for name in ('acceptance-check.json', 'acceptance-check.err'):
        (run / name).unlink(missing_ok=True)
    result = subprocess.run(list(map(str, invalid + ['--driver-records'])), env=env, text=True, capture_output=True)
    output = run / 'acceptance-check.json'
    error = run / 'acceptance-check.err'
    if result.returncode != 2 or result.stdout or result.stderr or not output.is_file() or not error.is_file():
        regression_errors.append(('F8', flag, result.returncode, output.exists(), error.exists()))
    elif output.read_text() != '\n' or 'expected one argument' not in error.read_text():
        regression_errors.append(('F8', flag, 'diagnostic content'))
for error in regression_errors:
    print('regression:', error, flush=True)
assert not regression_errors, regression_errors
print('ok: verdict cannot void a round; explicit policy inputs; usage diagnostics')
for case in json.loads((fixtures / 'cases.json').read_text()):
    for name, data in pristine.items():
        files[name].write_bytes(data)
    for change in case['changes']:
        path = files[change['file']]
        data = json.loads(path.read_text())
        parent = data
        for part in change['path'][:-1]:
            parent = parent[part]
        key = change['path'][-1]
        if change.get('delete'):
            del parent[key]
        else:
            parent[key] = change['value']
        path.write_text(json.dumps(data))
    if case.get('rebindArtifacts'):
        manifest = json.loads(files['evidence-manifest.json'].read_text())
        for artifact in manifest['artifacts']:
            data = files[artifact['ref']].read_bytes()
            artifact.update(sha256=hashlib.sha256(data).hexdigest(), bytes=len(data))
        files['evidence-manifest.json'].write_text(json.dumps(manifest))
    call_env = dict(env, **case.get('env', {}))
    before = {path: path.read_bytes() for path in scratch.rglob('*') if path.is_file()}
    result = subprocess.run(list(map(str, args + case.get('args', []))), cwd=scratch, env=call_env, text=True, capture_output=True)
    after = {path: path.read_bytes() for path in scratch.rglob('*') if path.is_file()}
    assert before == after, (case['name'], 'standalone check wrote files')
    elsewhere = subprocess.run(list(map(str, args + case.get('args', []))), cwd=repo, env=call_env, text=True, capture_output=True)
    assert (result.returncode, result.stdout) == (elsewhere.returncode, elsewhere.stdout), (case['name'], 'CWD changed the answer')
    assert result.returncode == (0 if case.get('accepted') else 1), (case['name'], result.returncode, result.stdout, result.stderr)
    answer = json.loads(result.stdout)
    assert answer['accepted'] == case.get('accepted', False), (case['name'], answer)
    assert answer.get('legacyAudit', False) == case.get('legacyAudit', False), (case['name'], answer)
    if not case.get('accepted'):
        assert (answer['conjunct'], answer['reason']) == (case['conjunct'], case['reason']), (case['name'], answer)
    print('ok:', case['name'])
for case in json.loads((fixtures / 'attempts.json').read_text()):
    failure = command(sys.executable, engine / 'acceptance_validator.py', 'attempt-result',
                      '--require-audit', case['audit'], '--verdict', case['verdict'],
                      '--verification', case['verification'])
    assert failure == (case['branch'] + '\t' + case['failure']).strip(), (case, failure)
print('ok: audit attempt dispositions')
sys.path.insert(0, str(engine))
sys.dont_write_bytecode = True
import acceptance_validator
# I-10: transport size must not replace a content decision. Use compact JSON
# above 1 MiB, then corrupt an entry while retaining that size.
for name, data in pristine.items():
    files[name].write_bytes(data)
large_manifest = json.loads(pristine['evidence-manifest.json'])
large_manifest['checks'] = {name: {'status': 'passed'} for name in ('scope', 'secret', 'gate')}
large_manifest['files'] = [{'path': f'synthetic/file-{index:05d}.txt', 'sha256': '0' * 64}
                           for index in range(12000)]
for invalid in (False, True):
    if invalid:
        large_manifest['files'][-1]['sha256'] = 'invalid-digest'
    compact = json.dumps(large_manifest, separators=(',', ':'))
    assert len(compact.encode()) > 1024 * 1024
    files['evidence-manifest.json'].write_text(compact)
    structure_args = acceptance_validator.parse_args(list(map(str, args[2:])))
    try:
        acceptance_validator.check_structure(structure_args, files['audit.json'], files['evidence-manifest.json'])
    except acceptance_validator.Refusal as refusal:
        assert invalid and (refusal.conjunct, refusal.reason) == ('E', 'evidence-manifest-schema-invalid'), refusal
    else:
        assert not invalid, 'oversized invalid content passed structure check'
    result = subprocess.run(list(map(str, args)), env=env, text=True, capture_output=True)
    assert result.returncode == int(invalid), (invalid, result)
    answer = json.loads(result.stdout)
    assert answer['accepted'] == (not invalid), answer
    if invalid:
        assert (answer['conjunct'], answer['reason']) == ('E', 'evidence-manifest-schema-invalid'), answer
    print('ok: oversized manifest', 'refused for invalid digest' if invalid else 'passes structure and certificate')
for case in json.loads((fixtures / 'reviews.json').read_text()):
    answer = acceptance_validator.classify_review(json.loads(pristine['audit.json']), {}, case['host'])
    assert answer['effectiveVerdict'] == case['effectiveVerdict'], (case['name'], answer)
    assert answer['blocking'] == case['blocking'], (case['name'], answer)
print('ok: review classification uses host outcome')
# Preserve the driver's diagnostic files even when a required executable fails.
for name, data in pristine.items():
    files[name].write_bytes(data)
result = subprocess.run(list(map(str, args + ['--driver-records'])), cwd=scratch,
                        env=dict(env, PATH=''), text=True, capture_output=True)
assert result.returncode == 1 and result.stdout == '' and result.stderr == '', result
assert (run / 'acceptance-check.json').read_text() == '\n'
assert 'FileNotFoundError' in (run / 'acceptance-check.err').read_text()
print('ok: driver keeps unexpected-error diagnostics')
audit = json.loads(pristine['audit.json'])
audit['schema'] = 'pmgo.orchestration.audit-verdict.v0'
del audit['verificationResults']
del audit['reviewPolicy']
files['audit.json'].write_text(json.dumps(audit))
result = subprocess.run(list(map(str, args + ['--driver-records'])), cwd=scratch,
                        env=dict(env, PATH=''), text=True, capture_output=True)
assert result.returncode == 1 and result.stderr == '', result
assert json.loads(result.stdout) == {'legacyAudit': True}, result
assert (run / 'acceptance-check.json').read_text() == '\n'
assert 'FileNotFoundError' in (run / 'acceptance-check.err').read_text()
print('ok: driver keeps legacy tolerance notice on unexpected failure')
PY
