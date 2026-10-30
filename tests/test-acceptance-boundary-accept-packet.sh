#!/usr/bin/env bash
rails_nonce="${RAILS_NONCE-}" rails_verdict_file="${RAILS_VERDICT_FILE-}"
unset RAILS_NONCE RAILS_VERDICT_FILE
set -euo pipefail

# Names this test fixes:
# Existing public settings: SINGULAR_ACCEPTANCE (unset/driver-only/every-path),
# SINGULAR_RESUME_ACCEPTED_EVIDENCE=0 selects stranded recovery, SINGULAR_PUSH=0.
# Existing authority values: accepted, needs-review, ready, blocked; parking may also
# use parked or awaiting-audit. No new event kind or reason field is fixed.
# Refusal event: taskId TASK-0001, a type containing acceptance + refus;
# park event: same taskId, type/action/message containing park or awaiting-audit.
# The refusal/park record (message plus data, never task text) must name a
# resolver: operator, human, maintainer, reviewer or auditor; and the public
# command singular drive TASK-0001 --audit-only. Reason may be in either record.
# Missing-rule diagnostics name audit and review/round/ledger (whole words).
# Existing certificate files/schema, review-policy ledger, events.ndjson and
# circuit.json/consecFails are fixture inputs/observable host records.
# Existing recovery event l1.auto_accepted_existing pins the default route.
# G/A/D/E are the existing validator's conjunct labels.
# Validator inputs include explicit config, audit requirement, schema mode, shell and policy environment.
# Every assertion below is labelled S0.4-3 or S0.4-4. The explicit two-omission
# diagnostic is required by S0.4-3; isolated guard cases each break one conjunct.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d /tmp/ap.XXXXXX)"
trap 'chmod -R u+w "$scratch" 2>/dev/null || true; rm -rf "$scratch"' EXIT
export PYTHONDONTWRITEBYTECODE=1 TEST_BASH="$BASH"
python3 "$ROOT/tests/fixtures/acceptance-boundary-accept-packet/cases.py" "$ROOT" "$scratch"
chmod -R u+w "$scratch" 2>/dev/null || true
rm -rf "$scratch"
trap - EXIT
if [[ -n "$rails_nonce" && -n "$rails_verdict_file" ]]; then
  printf '%s\n' "$rails_nonce" >"$rails_verdict_file"
fi
