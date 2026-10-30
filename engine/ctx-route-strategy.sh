#!/usr/bin/env bash
# ctx-route-strategy.sh — the continue/resume classifier leaf: the missing brick
# that lets the later engine/ctx-route.sh spine split a would-be `resume` verdict
# into the stage's two distinct strategies instead of framing every wrapped-decider
# `resume` as the bare `resume` strategy.
#
#   continue = "same session, same lineage, next phase" — the actor re-engaging
#              its OWN lineage: the planner revising its node's plan; the
#              implementer/worker retry-resuming its own task. Untainted.
#   resume   = "a persisted specialist re-engaged over accepted work" — critic
#              recheck, reviewer re-audit, and any skeptic/advocate re-invoked as
#              an auditor. Tainted (carries prior specialist session state).
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines a new
# function only; NO existing engine path invokes it, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior (OFF-parity
# by construction, mirroring engine/ctx-route-taint.sh and
# engine/ctx-route-window.sh). The engine/ctx-route.sh relabel wire-in that
# consumes this classifier is a SEPARATE later slice of the routing-module node
# and is OUT OF SCOPE here.
#
# The function is a PURE predicate: it prints EXACTLY one line — one token from
# {continue, resume} — appends no events, writes no files, and never exits
# non-zero on any input.

# singular_ctx_route_strategy_classify <role> <step>
#
# Classifies a would-be resume into `continue` vs `resume` from the re-engaging
# actor's <role> and the phase <step> it re-enters.
#
# Primary-lineage continuation -> continue. Only a primary-lineage role paired
# with its OWN continuation step qualifies:
#   planner + {revise, revise-plan}         (planner revising its node's plan)
#   implementer|worker + {retry, retry-resume}  (retry-resuming its own task)
#
# Everything else -> resume, which is also the fail-closed default:
#   - specialist roles (critic, reviewer, skeptic, advocate, auditor) are resume
#     regardless of step — a persisted specialist re-engaged over accepted work;
#   - a primary-lineage role with a non-continuation step is resume;
#   - an unrecognized or empty role/step is resume.
#
# Fail-closed rationale: `continue` is untainted and
# `resume` is tainted, so defaulting an unknown case to `continue` could let a
# tainted session appear independence-eligible. Defaulting to the tainted label
# `resume` upholds the advocate/skeptic line and evidence invariance. This keeps
# the classifier taint-consistent with singular_ctx_route_strategy_tainted:
# `continue` -> 0, `resume` -> 1 for every input.
singular_ctx_route_strategy_classify() {
  local role="$1" step="$2"

  case "$role" in
    planner)
      case "$step" in
        revise|revise-plan) printf 'continue\n'; return 0 ;;
      esac
      ;;
    implementer|worker)
      case "$step" in
        retry|retry-resume) printf 'continue\n'; return 0 ;;
      esac
      ;;
  esac

  # Fail closed: specialist roles, non-continuation steps, and unrecognized or
  # empty role/step all classify as the tainted `resume`, never `continue`.
  printf 'resume\n'
  return 0
}
