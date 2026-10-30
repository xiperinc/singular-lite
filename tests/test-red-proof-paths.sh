#!/usr/bin/env bash
proof_paths_nonce="${RAILS_NONCE:-}"
proof_paths_verdict="${RAILS_VERDICT_FILE:-}"
unset RAILS_NONCE RAILS_VERDICT_FILE
set -euo pipefail
# singular-test: serial
# S1.1-3, S1.1-9. At most two offline fixture jobs; no providers or remotes.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/vp.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
export PYTHONDONTWRITEBYTECODE=1
python3 "$ROOT/tests/fixtures/red-proof-paths/suite.py" "$ROOT" "$scratch" "$BASH"
# Clean up before the verdict, so writing it is the final successful action.
rm -rf "$scratch"
trap - EXIT
if [[ -n "$proof_paths_nonce" && -n "$proof_paths_verdict" ]]; then
  printf '%s\n' "$proof_paths_nonce" >"$proof_paths_verdict"
fi
