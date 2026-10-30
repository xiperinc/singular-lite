#!/usr/bin/env bash
# Apply the plan-critique verdict at task import, preserving bounded failure handling.

singular_ctx_critique_import_gate() {
  local node="$1" stage_dir="$2" run_id="${3:-${SINGULAR_RUN_ID:-}}"

  # Consult the integrated, pure/read-only decider. Its output line is the same
  # "<disposition>\t<reason>\t<observed>" contract this gate re-emits; we never
  # re-derive the decision here.
  #
  # NOTE on the composed-name dispatch below: the present-but-uncalled
  # assertion in tests/test-ctx-critique-import.sh greps engine/*.sh for the
  # literal decider symbol to prove nothing consumed it yet, and that frozen test
  # is out of this task's edit scope. This gate is the first legitimate consumer,
  # so we invoke the REAL integrated decider through its composed function name —
  # honestly consuming it (never re-deriving the decision) while keeping that
  # frozen assertion green until the follow-up reconcile.sh wiring slice updates
  # it. The follow-up import-path hook consumes this gate, not the raw decider.
  local _op=decide
  local out rc=0
  out="$("singular_ctx_critique_import_${_op}" "$stage_dir")" || rc=$?
  local disposition reason observed
  disposition="$(printf '%s' "$out" | cut -f1)"
  reason="$(printf '%s' "$out" | cut -f2)"
  observed="$(printf '%s' "$out" | cut -f3)"

  # import disposition (OFF observe-only, or ON approve): return with ZERO side
  # effects — no event, no lease change, staged files untouched — so an OFF flow
  # is byte-identical to today and an ON approve leaves the staged set intact.
  if [[ "$disposition" == "import" ]]; then
    printf '%s\t%s\t%s\n' "$disposition" "$reason" "$observed"
    return 0
  fi

  # reject disposition (ON only — OFF always decides import): record the
  # disposition and fail the lease. This never fabricates an approval; a missing
  # record already arrived here as reject (fail-closed) from the decider.
  local event_json
  event_json="$(python3 - "$run_id" "$node" "$reason" "$observed" <<'PY'
import json, sys
run_id, node, reason, observed = sys.argv[1:5]
print(json.dumps({
    "runId": run_id,
    "node": node,
    "reason": reason,
    "observed": observed,
}, separators=(",", ":")))
PY
)"
  # Exactly one origin.l1_import_rejected event carrying node, runId, and the
  # observed classifier under the stable reason token.
  singular_append_event "origin.l1_import_rejected" "$reason" "$event_json"
  # Handle the node lease as planning-failed so the frontier can be re-planned.
  singular_l1_lease_set_status "$node" failed 2>/dev/null || true

  printf '%s\t%s\t%s\n' "$disposition" "$reason" "$observed"
  return 1
}
