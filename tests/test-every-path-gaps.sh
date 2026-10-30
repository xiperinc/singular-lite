#!/usr/bin/env bash
verdict_nonce=${RAILS_NONCE-}
verdict_file=${RAILS_VERDICT_FILE-}
unset RAILS_NONCE RAILS_VERDICT_FILE
set -euo pipefail

# Three every-path gaps (S0.4-1, S0.4-2, S0.4-4), each also pinned unchanged
# under driver-only:
# - Re-import: an explicit re-import of a refused, moved-aside inbox packet
#   restores the newest retained regular copy and imports it; reconcile never
#   does.
# - Refusal subjects: integrate's and import's acceptance refusals name their
#   subject in words (G host gate verification, A audit, D review round,
#   E evidence manifest, V red proof).
# - Whole manifest: the evidence manifest is checked whole: every listed
#   artifact inside the run is present and unchanged; a ref outside the run is
#   incomplete.
# Reuses the acceptance-boundary-import harness; only the provider is stubbed.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 -B "$root/tests/fixtures/every-path-gaps/check.py" "$root" "$BASH"

# Deliberately last: no child (including the runner) inherits these variables.
if [[ -n "$verdict_nonce" && -n "$verdict_file" ]]; then
  printf '%s' "$verdict_nonce" >"$verdict_file"
fi
