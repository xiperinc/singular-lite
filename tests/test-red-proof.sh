#!/usr/bin/env bash
red_proof_verdict_nonce="${RAILS_NONCE:-}"
red_proof_verdict_file="${RAILS_VERDICT_FILE:-}"
unset RAILS_NONCE RAILS_VERDICT_FILE
set -euo pipefail
# singular-test: serial
# S1.1-1,2,4,5,7. See fixtures/red-proof/README.md for the phase seam,
# record interface, case matrix, and deliberately separate integration checks.
# Two fixture jobs maximum, no providers/network/loop, no source checkout edits.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "$root/tests/fixtures/red-proof/suite.py" "$root"
if [[ -n "$red_proof_verdict_nonce" && -n "$red_proof_verdict_file" ]]; then
  printf '%s\n' "$red_proof_verdict_nonce" >"$red_proof_verdict_file"
fi
