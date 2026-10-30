#!/usr/bin/env bash
prompts_verdict_nonce="${RAILS_NONCE:-}"
prompts_verdict_file="${RAILS_VERDICT_FILE:-}"
unset RAILS_NONCE RAILS_VERDICT_FILE
set -euo pipefail

# S1.1-6, S1.1-10: real planner/worker dry-run renderers, the critic's real
# runner input, and the scaffold's task template, for both shipped prompt roots.
# Frozen off/unset bytes come from cfe5afb. Only the worker's generated run ID
# and base SHA, and the critic's initial commit SHA are normalized. No whitespace
# is erased.
# The accepted-drive worker/auditor byte pin remains in the existing parity test.
# Enabled worker assertions exclude the verbatim task-document appendix: merely
# echoing user fields there does not teach the worker the proof-field contract.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/red-proof-prompts.XXXXXX")"
cleanup() { rm -rf "$scratch"; }
trap cleanup EXIT
export PYTHONDONTWRITEBYTECODE=1
python3 "$ROOT/tests/fixtures/red-proof-prompts/suite.py" "$ROOT" "$scratch"
echo 'PASS: red-proof prompt fields and disabled prompt byte parity'
cleanup
trap - EXIT
if [[ -n "$prompts_verdict_nonce" && -n "$prompts_verdict_file" ]]; then
  printf '%s' "$prompts_verdict_nonce" >"$prompts_verdict_file"
fi
