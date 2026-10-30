#!/usr/bin/env bash
# ctx-route-taint.sh — the taint / independence pin: the structural guarantee
# that resumed/rehydrated sessions can never satisfy an independence-required
# step (final audit, paired audit). Honors the advocate/skeptic line and evidence
# invariance: no knob may reroute an independence step.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines new
# functions only; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior (OFF-parity
# by construction, mirroring engine/ctx-route-window.sh). The engine/ctx-route.sh
# spine that stamps `tainted=1` into the strategy event and composes this pin is a
# later slice of the routing-module node and is OUT OF SCOPE here.
#
# Both functions are PURE predicates: they print exactly one line, append no
# events, write no files, and never exit non-zero.

# singular_ctx_route_strategy_tainted <strategy>
#
# Classifies a resume strategy for the tainted=1 flag the spine will stamp:
#   resume, rehydrate           -> 1 (tainted; carries prior-session state)
#   continue, fork, fresh       -> 0 (untainted)
#   anything else (incl. empty) -> 1 (fail closed; an unrecognized strategy is
#                                     treated as tainted so it cannot slip past
#                                     the independence pin)
singular_ctx_route_strategy_tainted() {
  case "$1" in
    resume|rehydrate)     printf '1\n' ;;
    continue|fork|fresh)  printf '0\n' ;;
    *)                    printf '1\n' ;;
  esac
  return 0
}

# singular_ctx_route_independence_admit <strategy> <role> <step>
#
# Pins the independence-required steps to `fresh`. For those steps:
#   fresh                -> admit
#   resume | rehydrate   -> refuse tainted
#   any other non-fresh  -> refuse pinned-fresh
# For any non-independence-required step -> admit. The <role> is accepted for the
# call shape and future per-role pins; the current independence set is role-generic.
#
# THE INDEPENDENCE SET (the single source of truth; four steps):
#
#   final-audit     the implementation auditor's verdict on a diff. LIVE — routed
#                   from l1-drive.sh. Without this pin the reviewer resumes the
#                   session that rejected the previous attempt and grades the fix
#                   from inside the opinion it already formed.
#   paired-audit    the sampled post-acceptance paired audit. Also structurally
#                   fresh at its call site (engine/ctx-paired-audit.sh invokes the
#                   runner with NO --session-meta and NO --resume-session), so this
#                   arm is defense-in-depth rather than load-bearing today.
#   re-critique     the in-loop re-critique of REVISED plan candidates
#                   (engine/ctx-plan-recritic-resume.sh).
#   critic-recheck  the post-acceptance recheck over an ACCEPTED diff
#                   (engine/ctx-critic-recheck-resume.sh).
#
# The last two are pinned BEFORE their consult hooks are wired, deliberately. Both
# resume authorities are already written and both are inert (no engine path calls
# them). A skeptic re-entering its own prior session to judge work is the exact
# anchoring the pin exists to prevent, and the fact that a step happens not to be
# wired yet is not a reason to leave its independence undecided: the asymmetry
# would otherwise be an emergent consequence of a hard-coded set rather than a
# decision on the record. Whichever hook lands first is born pinned. The cost is
# bounded — a fresh critic invocation per revise cycle, itself bounded by
# SINGULAR_PLAN_REVISE_MAX (default 1).
#
# No SINGULAR_* knob is consulted anywhere in this function, and the caller
# (engine/ctx-route.sh) evaluates it ABOVE its SINGULAR_CTX_ROUTING check, so the
# pin binds in every configuration. Adding a step here is the ONLY way to pin one.
singular_ctx_route_independence_admit() {
  local strategy="$1" role="$2" step="$3"
  : "$role"  # accepted for call shape; the documented independence set is role-generic

  case "$step" in
    final-audit|paired-audit|re-critique|critic-recheck) ;;
    *) printf 'admit\n'; return 0 ;;
  esac

  # Independence-required step: only `fresh` is admissible. resume/rehydrate are
  # tainted; everything else is refused because the step is pinned to fresh. No
  # SINGULAR_* knob is consulted here — the pin is structural.
  case "$strategy" in
    fresh)              printf 'admit\n' ;;
    resume|rehydrate)   printf 'refuse tainted\n' ;;
    *)                  printf 'refuse pinned-fresh\n' ;;
  esac
  return 0
}
