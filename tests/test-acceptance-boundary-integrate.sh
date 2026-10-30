#!/usr/bin/env bash
boundary_nonce=${RAILS_NONCE-}
boundary_verdict=${RAILS_VERDICT_FILE-}
unset RAILS_NONCE RAILS_VERDICT_FILE
set -euo pipefail

# Names this test fixes
# SINGULAR_ACCEPTANCE: unset/empty/driver-only or every-path;
# legacyCompatibility.unboundWaivers; existing public commands and schemas.
# Direct refusal reasons may use command output; cycle reasons must use the
# refusal record alone; decider.* events cannot supply reasons, advice or parks.
# Default host/audit skips keep the exact line: skip TASK-0412: no accepted
# auditor verdict or recorded accept-waiver.
# Diagnostic subject words: host/verification, audit, review round/ledger/round,
# manifest/evidence, drift's stale/changed, waiver/audit (case insensitive).
# Subject matching excludes public recovery commands and their remaining line.
# Refusal event type contains refus/reject/park/blocked or integration.failed;
# park event type contains park/blocked. Each event must name TASK-0412.
# Every-path direct refusal exits nonzero; default skips exit zero. Direct
# refusal leaves target HEAD unchanged (including no status-only commit).
# Task Status: accepted initially; blocked/parked/failed on refusal.
# Diagnostic values live under keys matching reason/message/detail/advice/next/
# resolv/remed/recover in refusal events (including nested data). Recovery advice
# may also use those keys in the task lease, or newly added task-file lines.
# Resolver prose: human/operator/maintainer/person/user; command: singular
# drive/unpark/recover/review/integrate. An owner key alone is not a resolver.
# Existing integration.integrated, integration.failed,
# autonomate.breaker_incremented and health JSON breaker.consecFails are fixed.
# Synthetic records retain today's task/run/lease/ledger/manifest formats.
# Fixture baseline depends on engine/acceptance_validator.py and its current
# --task/--run/--branch/--head/--campaign/--run-dir/--repo-root/--state-dir/
# --logical-change/--task-contract/--config/--require-audit/--legacy-schema-mode/
# --trusted-shell/--policy-env-json command-line interface.
# Ruling I-10: only every-path refusals require the new exit lifecycle. Unset
# and driver-only retain today's successful skip, no new refusal/park event,
# unchanged task/lease and zero breaker. Default-loop controls pin this.
# A repeat is a successful no-op on an already integrated candidate; it does
# not demand another acceptance evaluation. Target-gate recovery restores only
# task control text, retaining the engine's candidate lease and failure history;
# it does not require another row's recovery verb to work.
# S0.4-2: G/A/D/E, publication-time evidence drift, valid/repeat/recovery, defaults.
# S0.4-4: real auto/reconcile cycles, breaker, durable parking and recovery advice.
# S0.4-11: an eligible waiver with admission enabled and disabled.

boundary_root=$(cd "$(dirname "$0")/.." && pwd)
BOUNDARY_BASH="$BASH" PYTHONDONTWRITEBYTECODE=1 python3 "$boundary_root/tests/fixtures/acceptance-boundary-integrate/suite.py" "$boundary_root"
# All children and temporary folders are gone before the verdict is published.
if [[ -n "$boundary_nonce" && -n "$boundary_verdict" ]]; then
  printf '%s' "$boundary_nonce" >"$boundary_verdict"
fi
