#!/usr/bin/env bash
# Choose session continuation, resume, fork, fresh start or rehydration under the context policy.
singular_ctx_route() {
  local role="$1" step="$2" meta="$3" key="$4" run_id="$5" runner="$6" \
        prompt_sha="$7" worktree="$8" lineage_head="$9"
  shift 9 || true
  local transcript="${1:-}" lease_key="${2:-}" base_sha="${3:-}"
  shift 3 2>/dev/null || true
  # Remaining "$@" is the role-relevant pathspec for the diff gate (may be empty).

  # --- Baseline resume/fresh decision from the role's WRAPPED decider ----------
  # The router adds only the lease/window/diff gates and the strategy/taint
  # framing; the baseline resume/fresh gates come entirely from these functions.
  local baseline strategy
  case "$role" in
    planner)
      baseline="$(singular_planner_resume_decide "$meta" "$key" "$runner" "$worktree" "$lineage_head")"
      ;;
    *)
      baseline="$(singular_session_resume_decide "$meta" "$role" "$key" "$run_id" "$runner" "$prompt_sha" "$worktree" "$lineage_head")"
      ;;
  esac
  strategy="${baseline%% *}"

  # --- 1. Independence pin FIRST — ABOVE the routing flag (structural) ---------
  # The pin is a CORRECTNESS INVARIANT, not a routing feature, so it is evaluated
  # before the SINGULAR_CTX_ROUTING check and binds in EVERY configuration
  # (routing unset, 0, or 1). A safety property that holds only when a flag is set
  # is not a safety property: with the pin below the OFF-parity return, a default
  # install let the reviewer resume the very session that rejected the previous
  # attempt, because the wrapped decider is step-BLIND (it takes no <step> and no
  # gate in its ladder names final-audit) and SINGULAR_SESSION_AFFINITY is ON by
  # default. The pin is the only thing in this file that knows the step, so it is
  # the only thing that can refuse it.
  #
  # This is the ONE deliberate departure from OFF-parity: with routing OFF the
  # router is byte-identical to the legacy decider for every step EXCEPT an
  # independence-required one, which is pinned to fresh unconditionally. No knob
  # reroutes it — there is no escape hatch for independence, by design.
  local admit
  admit="$(singular_ctx_route_independence_admit "$strategy" "$role" "$step")"
  case "$admit" in
    admit)
      : # step admissible for this strategy; fall through
      ;;
    "refuse tainted")
      # A would-be resume/rehydrate at an independence-required step.
      printf 'fresh tainted\n'; return 0
      ;;
    *)
      # `refuse pinned-fresh` (or any unrecognized refusal) — fail closed to fresh.
      printf 'fresh pinned-fresh\n'; return 0
      ;;
  esac

  # --- OFF-parity: byte-identical to the legacy decide path --------------------
  # With the flag unset or != 1 the router emits the decider's line VERBATIM — no
  # lease/window/diff gate and no strategy outside {resume,fresh}. The
  # independence pin above has ALREADY bound; only the additive resume gates are
  # behind the flag.
  if [[ "${SINGULAR_CTX_ROUTING:-1}" != "1" ]]; then
    printf '%s\n' "$baseline"
    return 0
  fi

  # --- 2. Only a would-be `resume` is subject to the additional gates ----------
  # Any other baseline strategy (fresh, and the reserved continue/fork/rehydrate)
  # passes through with its reason intact — the gates only refuse resume.
  if [[ "$strategy" != "resume" ]]; then
    printf '%s\n' "$baseline"
    return 0
  fi

  # --- Resume gates, fail-closed, first refusal wins ---------------------------
  # Each refusal is a refused-resume lineage-continuation step: emit its reason
  # through the rehydrate wire-in, which upgrades `fresh <reason>` to `rehydrate
  # <reason>` only behind SINGULAR_REHYDRATE=1 with a non-empty run_dir packet and
  # otherwise stays byte-identical to the bare `fresh <reason>` line.
  # (a) live generalized session lease: another fanout is using the role's session.
  local lease_path
  lease_path="$(singular_ctx_route_session_lease_path "$role" "$lease_key")"
  if [[ -n "$lease_path" ]] && singular_ctx_route_session_lease_live "$lease_path"; then
    _singular_ctx_route_refuse_resume session-lease "$role" "$step" "$meta" "$key"; return 0
  fi
  # (b) window pressure: the session transcript is over the usage threshold.
  # The runner basename is threaded so the gate resolves the window budget from
  # the PROVIDER actually selected for this role (engine/providers.json), instead
  # of assuming one global constant for every provider the engine can drive.
  if [[ "$(singular_ctx_route_window_gate "$role" "$transcript" "$runner")" != "pass" ]]; then
    _singular_ctx_route_refuse_resume window-pressure "$role" "$step" "$meta" "$key"; return 0
  fi
  # (c) diff volume: role-relevant churn since headShaAtCreate is over the limit.
  if [[ "$(singular_ctx_route_diff_gate "$role" "$worktree" "$base_sha" "$lineage_head" "$@")" != "pass" ]]; then
    _singular_ctx_route_refuse_resume diff-volume "$role" "$step" "$meta" "$key"; return 0
  fi

  # Every gate passed -> the wrapped decider's `resume <id>` stands, verbatim.
  printf '%s\n' "$baseline"
  return 0
}

# _singular_ctx_route_refuse_resume <reason> <role> <step> <meta> <key>
#
# The rehydrate wire-in for a refused-resume lineage step. Prints exactly one
# line: `rehydrate <reason>` when SINGULAR_REHYDRATE=1 and the manifest chosen for
# this step yields at least one surviving rehydration source, otherwise the byte-
# identical `fresh <reason>` this spine emitted before the wire-in. The
# manifest composition is guarded behind SINGULAR_REHYDRATE so the OFF path spawns
# no extra work; the decision leaf (which independently re-checks OFF-parity, the
# independence pin, and the empty-packet guard) makes the final call.
#
# WHICH manifest the leaf sees is delegated to the flat-vs-subgraph selector
# singular_ctx_route_subgraph_manifest (engine/ctx-route-subgraph.sh): with
# SINGULAR_CTX_SUBGRAPH_REHYDRATE default 0 it returns the flat manifest and this
# path is byte-identical to today; only with the subgraph knob on, the treatment
# arm, and a present non-empty graph corpus does it hand the leaf the graph-
# selected packet instead of the flat capsule. <key> is the taskId the route
# contract already carries for task roles and is threaded here so the selector can
# resolve the deterministic task node id.
#
# Appends no events and never exits non-zero — the spine keeps its one-line,
# no-event contract, and `rehydrate` stays tainted.
_singular_ctx_route_refuse_resume() {
  local reason="$1" role="$2" step="$3" meta="$4" key="${5:-}"

  # OFF-parity: with the knob unset or != 1, stay byte-identical to `fresh
  # <reason>` and do NO resolver/manifest work at all.
  if [[ "${SINGULAR_REHYDRATE:-0}" != "1" ]]; then
    printf 'fresh %s\n' "$reason"; return 0
  fi

  # Select the manifest (flat by default; graph-selected only under the subgraph
  # knob + treatment arm + present corpus) and let the decision leaf render the
  # verdict.
  local manifest
  manifest="$(singular_ctx_route_subgraph_manifest "$reason" "$role" "$step" "$meta" "$key")"

  singular_ctx_route_rehydrate_decide "$reason" "$role" "$step" "$manifest"
  return 0
}
