#!/usr/bin/env bash
rails_nonce="${RAILS_NONCE-}" rails_verdict_file="${RAILS_VERDICT_FILE-}"
unset RAILS_NONCE RAILS_VERDICT_FILE
set -euo pipefail

# Names this test fixes:
# S0.4-8 uses existing events audit.infra_retry, audit.infra_exhausted,
# and authority status blocked. The parked advice is the
# Rationale in the task's terminal decisions.md entry (escalate-infra), not
# the runner transcript or generic task text. It must name audit/auditor and
# must not claim the gate could not run. Existing public verb: singular unpark.
# Settings: default/unset acceptance and every-path; SINGULAR_AUDIT_INFRA_MAX=1.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d /tmp/pa.XXXXXX)"
trap 'chmod -R u+w "$scratch" 2>/dev/null || true; rm -rf "$scratch"' EXIT
export PYTHONDONTWRITEBYTECODE=1 TEST_BASH="$BASH"
python3 "$ROOT/tests/fixtures/park-advice/cases.py" "$ROOT" "$scratch"
chmod -R u+w "$scratch" 2>/dev/null || true
rm -rf "$scratch"
trap - EXIT
if [[ -n "$rails_nonce" && -n "$rails_verdict_file" ]]; then
  printf '%s\n' "$rails_nonce" >"$rails_verdict_file"
fi
