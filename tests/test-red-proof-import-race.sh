#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset RAILS_NONCE RAILS_VERDICT_FILE
export PYTHONDONTWRITEBYTECODE=1 SINGULAR_PUSH=0
python3 "$ROOT/tests/fixtures/red-proof-validation/import-race.py" "$ROOT" "$BASH"
