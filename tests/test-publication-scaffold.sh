#!/usr/bin/env bash
# Publication checks distinguish tracked records from locally generated state.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" "$BASH" <<'PY'
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
bash = sys.argv[2]
with tempfile.TemporaryDirectory(prefix='publication-scaffold-') as tmp:
    repo = Path(tmp) / 'repo'
    repo.mkdir()
    names = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z']).decode().split('\0')
    for name in filter(None, names):
        source = root / name
        if source.is_file():
            target = repo / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
    env = {k: v for k, v in os.environ.items() if not k.startswith('SINGULAR_')}
    env.update(SINGULAR_ROOT=str(repo), SINGULAR_PUSH='0')
    (repo / 'singular.config.json').write_text('{"schemaVersion":"v2"}\n')
    with (repo / '.gitignore').open('a') as stream:
        stream.write('\n.singular-state/\n')
    def run(*args, **kwargs):
        return subprocess.run(args, cwd=repo, env=env, text=True, capture_output=True, **kwargs)
    def ok(*args):
        result = run(*args)
        assert result.returncode == 0, result.stdout + result.stderr
    ok('git', 'init', '-q')
    ok('git', 'add', '.')
    ok('git', '-c', 'user.name=fixture', '-c', 'user.email=fixture', 'commit', '-qm', 'Synthetic publication tree')
    ok(bash, 'engine/scaffold.sh')
    for name in ('areas/core', 'gates', 'packets/imported', 'decisions.md',
                 'project-state.md', 'planner-contract.md'):
        assert (repo / 'docs/orchestration' / name).exists(), name
    # init also writes a DAG; local tasks and record files may coexist with it.
    (repo / 'docs/orchestration/dag.v0.json').write_text('{}\n')
    (repo / 'docs/orchestration/tasks/TASK-0001.md').write_text('# Synthetic local task\n')
    ok(bash, 'tests/test-publication-tree.sh')
    print('engine scaffold plus untracked records: exit 0')
    # Put a removed file back in the index. Its absence on disk must not hide it.
    restored = repo / 'tools/promote-gate.sh'
    restored.parent.mkdir(exist_ok=True)
    restored.write_text('# Synthetic removed-file mutation\n')
    ok('git', 'add', '-f', 'tools/promote-gate.sh')
    restored.unlink()
    result = run(bash, 'tests/test-publication-tree.sh')
    assert result.returncode == 1, 'tracked removed file escaped publication check'
    assert 'working record in public tree: tools/promote-gate.sh' in result.stderr, result.stderr
    print('removed file restored to index, absent on disk: exit 1')
    ok('git', 'rm', '--cached', 'tools/promote-gate.sh')
    ok('git', 'add', '-f', 'docs/orchestration/tasks/TASK-0001.md')
    result = run(bash, 'tests/test-publication-tree.sh')
    assert result.returncode == 1, 'tracked task record escaped publication check'
    assert 'tracked task record' in result.stderr, result.stderr
    print('task record restored to index: exit 1')
    print('PASS: engine scaffold and untracked records allowed; tracked removed file and task rejected')
PY
