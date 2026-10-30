#!/usr/bin/env bash
# Public distributions contain user contracts and reusable scaffolding only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import fnmatch
import subprocess
import sys
root = Path(sys.argv[1])
tracked = set(filter(None, subprocess.check_output(
    ["git", "-C", str(root), "ls-files", "-z"]).decode().split("\0")))
for name in ('docs/context-adoption.md', 'docs/context-graph.md',
             'docs/orchestration/tasks/TEMPLATE.md'):
    assert (root / name).is_file(), f"missing public contract: {name}"
for name in ('claudedocs', 'docs/brain-build-plan', 'docs/context-build-plan',
             'docs/handoffs', 'docs/governance.md', 'docs/orchestration/archive',
             'docs/orchestration/areas', 'docs/orchestration/brain-tasks',
             'docs/orchestration/gates', 'docs/orchestration/handoffs',
             'docs/orchestration/packets', 'docs/orchestration/rescue-tasks',
             'docs/orchestration/dag.v0.json', 'docs/orchestration/decisions.md',
             'docs/orchestration/planner-contract.md', 'docs/orchestration/project-state.md',
             'tools/brain-campaign', 'tools/promote-gate.sh',
             'vendor/singular-brain/docs/AUDIT-BRIEF.md',
             'tests/fixtures/doc-contract/historical.txt'):
    assert not any(path == name or path.startswith(name + "/") for path in tracked), f"working record in public tree: {name}"
assert not any(fnmatch.fnmatchcase(path, 'docs/orchestration/tasks/TASK-*.md') for path in tracked), 'tracked task record in public tree'
for name in ('l1-planner.md', 'decider.md', 'auditor.md'):
    assert (root / 'docs/orchestration/prompts' / name).read_bytes() == (root / 'templates/prompts' / name).read_bytes(), name
assert 'placeholder' in (root / 'docs/orchestration/tasks/TEMPLATE.md').read_text().lower()
print('public contracts and reusable scaffolding passed')
PY
