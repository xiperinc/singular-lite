#!/usr/bin/env bash
set -euo pipefail
[[ -z "${RAILS_NONCE+x}" && -z "${RAILS_VERDICT_FILE+x}" ]]
[[ $(cat value.txt) == candidate ]]
[[ $(cat target-owned.txt) == clean ]]
# The integration gate is a public, deterministic interleaving point: candidate
# admission has completed, but the tested merge has not been published yet.
if [[ -n "${BOUNDARY_DRIFT_FILE:-}" ]]; then
  printf '\n' >>"$BOUNDARY_DRIFT_FILE"
  printf 'changed\n' >"$BOUNDARY_DRIFT_MARKER"
fi
printf '%s\n' '{"schema":"singular.orchestration.gate-observation.v0","failures":[]}' >"$SINGULAR_GATE_REPORT_FILE"
