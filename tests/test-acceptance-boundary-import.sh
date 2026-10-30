#!/usr/bin/env bash
verdict_nonce=${RAILS_NONCE-}
verdict_file=${RAILS_VERDICT_FILE-}
unset RAILS_NONCE RAILS_VERDICT_FILE
set -euo pipefail

# Names this test fixes:
# - SINGULAR_ACCEPTANCE: unset/driver-only/every-path; existing waiver switch
#   legacyCompatibility.unboundWaivers and schemaVersion v1/v2; audit validation
#   SINGULAR_AUDIT_VERDICT_VALIDATE: unset/warn/strict.
# - Existing packet.imported publication event. Refusal event types contain
#   reject/refus/fail; task park event types contain park and name TASK-0001.
#   Multiple park-related events are allowed; the next cycle adds none.
# - Task Status: parked/blocked/failed. Breaker is read via breaker show.
# - Advice is new task text or diagnostic values in refusal/park events or
#   changed lease fields matching reason/advice/resolv/remed/recover/message/
#   detail/error, or nextOwner/resolver/resolutionOwner. Ordinary owner metadata
#   does not count. Resolver prose: operator/human/person/maintainer/user, or a
#   nonempty nextOwner/resolver/resolutionOwner. Verb: singular drive/unpark/
#   recover. Actual command efficacy needs review alongside the driver's row.
# - Diagnostics name host/verification, audit/verdict/schema/rationale/identity/
#   blocking/P0, review/round, evidence/manifest/chang, or waiver/audit/legacy
#   as applicable (see cases).
# - Existing default refusal events: packet.import_rejected/packet.import_failed.
# - Race relies on campaign lock and locks/git-op.lock, acquired git then
#   campaign by publication. Both waits are bounded and report the criterion.
# I-10: new refusal exits apply only under every-path. Unset/driver-only keep
# today's first-cycle events, unchanged breaker/task, and no park. Byte-identical
# already-published packets succeed without rejudgment or duplicate publication.
# S0.4-1 / S0.4-4 / S0.4-11. Fixtures are generated, never recorded runs.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 -B "$root/tests/fixtures/acceptance-boundary-import/check.py" "$root" "$BASH"

# Deliberately last: no child (including the runner) inherits these variables.
if [[ -n "$verdict_nonce" && -n "$verdict_file" ]]; then
  printf '%s' "$verdict_nonce" >"$verdict_file"
fi
