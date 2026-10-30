#!/usr/bin/env bash
# Public instructions must describe automatic setup and opt-in graph commands.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import ast
from pathlib import Path
import re
import subprocess
import sys
root = Path(sys.argv[1])
readme = (root / 'README.md').read_text()
setup = re.search(r'For an existing consumer, setup\s+(.*?)(?:\n\n|$)', readme, re.S)
assert setup, 'missing existing-consumer setup instructions'
assert re.search(r'prints.*plan.*runs.*automatic', setup[1], re.S), 'setup must disclose the plan and automatic migration'
graph = (root / 'docs/context-graph.md').read_text().split('\n\n')[1]
assert 'singular graph' in graph and 'SINGULAR_CTX_GRAPH=1' in graph, 'graph command must disclose its opt-in flag'
# Literal script paths in code spans are checkout references; placeholders and
# consumer record paths are deliberately outside this assertion.
tracked = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z']).decode().split('\0')
for name in tracked:
    if not name.endswith('.md'):
        continue
    for span in re.findall(r'(?<!`)`([^`\n]+)`(?!`)', (root / name).read_text()):
        if re.fullmatch(r'(?:tools|engine)/[\w./-]+\.(?:sh|py)', span):
            assert (root / span).is_file(), f'{name}: missing shipped script: {span}'
# Remediation strings must not refer operators to scripts absent from a checkout.
for node in ast.walk(ast.parse((root / 'engine/doctor.py').read_text())):
    if isinstance(node, ast.keyword) and node.arg == 'remediation':
        for value in ast.walk(node.value):
            if isinstance(value, ast.Constant) and isinstance(value.value, str):
                for name in re.findall(r'\btools/[\w./-]+\.sh\b', value.value):
                    assert (root / name).is_file(), f'doctor remediation names missing script: {name}'
print('PASS: public setup, graph availability and shipped script references')
PY
