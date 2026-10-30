#!/usr/bin/env bash
# Covers the continue/resume classifier leaf brick engine/ctx-route-strategy.sh:
#   singular_ctx_route_strategy_classify <role> <step>
#
# The stage-distinct split of a would-be `resume` verdict into two strategies:
#   continue = "same session, same lineage, next phase" — the actor re-engaging
#              its OWN lineage (planner revising its node's plan; implementer /
#              worker retry-resuming its own task).
#   resume   = "a persisted specialist re-engaged over accepted work" — critic
#              recheck, reviewer re-audit, and any skeptic/advocate re-invoked as
#              an auditor.
#
# It is a PURE predicate: prints EXACTLY one token from {continue, resume} on one
# line, appends no events, writes no files, and never exits non-zero.
#
# Contract asserted here (each strategy enumerated with its role/step reason):
#   - Primary-lineage continuation -> continue:
#       planner revising its node's plan; implementer/worker retry-resuming.
#   - Specialist re-engagement -> resume:
#       critic recheck, reviewer re-audit, skeptic/advocate re-invoked as auditor.
#   - Fail closed: unrecognized or empty role/step -> resume, NEVER continue.
#       (A primary-lineage role with a non-continuation step is still resume; a
#        specialist role is resume regardless of step.)
#   - Taint consistency (behavioral pin): feeding the
#       classifier's output into singular_ctx_route_strategy_tainted yields 0 for
#       every `continue` and 1 for every `resume`.
# The predicate is defined only; NO existing engine path invokes it, so with the
# file present-but-uncalled the engine is byte-identical to prior behavior.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
CTX_S="$ENGINE_HOME/engine/ctx-route-strategy.sh"
CTX_T="$ENGINE_HOME/engine/ctx-route-taint.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { # <got> <want> <label>
  [[ "$1" == "$2" ]] || fail "$3: expected [$2], got [$1]"
}
pass() { echo "ok: $*"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export SINGULAR_ROOT="$tmp"
export SINGULAR_STATE_DIR="$tmp/state"
mkdir -p "$SINGULAR_STATE_DIR"
# shellcheck disable=SC1090
source "$LIB" || fail "sourcing lib.sh failed"

[[ -f "$CTX_S" ]] || fail "engine not present yet: $CTX_S"
# shellcheck disable=SC1090
source "$CTX_S" || fail "sourcing $CTX_S failed"
# shellcheck disable=SC1090
source "$CTX_T" || fail "sourcing $CTX_T failed"
[[ "$(type -t singular_ctx_route_strategy_classify)" == "function" ]] \
  || fail "singular_ctx_route_strategy_classify not defined by $CTX_S"

# --- Primary-lineage continuation -> continue --------------------------------
# The actor re-engaging its OWN lineage's next phase.
assert_eq "$(singular_ctx_route_strategy_classify planner revise)" \
  "continue" "planner revising its node plan -> continue"
assert_eq "$(singular_ctx_route_strategy_classify planner revise-plan)" \
  "continue" "planner revise-plan -> continue"
assert_eq "$(singular_ctx_route_strategy_classify implementer retry-resume)" \
  "continue" "implementer retry-resuming its own task -> continue"
assert_eq "$(singular_ctx_route_strategy_classify implementer retry)" \
  "continue" "implementer retry -> continue"
assert_eq "$(singular_ctx_route_strategy_classify worker retry-resume)" \
  "continue" "worker retry-resuming its own task -> continue"
assert_eq "$(singular_ctx_route_strategy_classify worker retry)" \
  "continue" "worker retry -> continue"
pass "primary-lineage continuation (planner revise / implementer|worker retry) -> continue"

# --- Specialist re-engagement -> resume --------------------------------------
# A persisted specialist re-invoked over accepted work.
assert_eq "$(singular_ctx_route_strategy_classify critic recheck)" \
  "resume" "critic recheck -> resume"
assert_eq "$(singular_ctx_route_strategy_classify reviewer re-audit)" \
  "resume" "reviewer re-audit -> resume"
assert_eq "$(singular_ctx_route_strategy_classify skeptic audit)" \
  "resume" "skeptic re-invoked as auditor -> resume"
assert_eq "$(singular_ctx_route_strategy_classify advocate audit)" \
  "resume" "advocate re-invoked as auditor -> resume"
assert_eq "$(singular_ctx_route_strategy_classify auditor re-audit)" \
  "resume" "auditor re-audit -> resume"
# A specialist role is resume regardless of a continuation-looking step.
assert_eq "$(singular_ctx_route_strategy_classify critic retry-resume)" \
  "resume" "specialist critic never continues even with a retry-resume step -> resume"
pass "specialist re-engagement (critic/reviewer/skeptic/advocate/auditor) -> resume"

# --- Fail closed: unrecognized/empty role or step -> resume ------------------
# A primary-lineage role with a non-continuation step is still resume.
assert_eq "$(singular_ctx_route_strategy_classify planner audit)" \
  "resume" "primary role planner with non-continuation step audit -> resume (fail closed)"
# Empty step, empty role, both empty, and fully unknown -> resume.
assert_eq "$(singular_ctx_route_strategy_classify planner '')" \
  "resume" "empty step -> resume (fail closed)"
assert_eq "$(singular_ctx_route_strategy_classify '' revise)" \
  "resume" "empty role -> resume (fail closed)"
assert_eq "$(singular_ctx_route_strategy_classify '' '')" \
  "resume" "empty role and step -> resume (fail closed)"
assert_eq "$(singular_ctx_route_strategy_classify bogus bogus)" \
  "resume" "unknown role and step -> resume (fail closed)"
pass "fail closed: unrecognized/empty role or step -> resume, never continue"

# --- Taint consistency: continue is untainted, resume is tainted --------------
# For EVERY fixture input, feeding the classifier output into _tainted yields
# 0 for continue and 1 for resume (behavioral pin).
taint_check() { # <role> <step>
  local strat tainted
  strat="$(singular_ctx_route_strategy_classify "$1" "$2")"
  tainted="$(singular_ctx_route_strategy_tainted "$strat")"
  case "$strat" in
    continue) assert_eq "$tainted" "0" "continue is untainted [$1/$2]" ;;
    resume)   assert_eq "$tainted" "1" "resume is tainted [$1/$2]" ;;
    *)        fail "classifier emitted non-{continue,resume} token [$strat] for [$1/$2]" ;;
  esac
}
taint_check planner revise
taint_check planner revise-plan
taint_check implementer retry-resume
taint_check implementer retry
taint_check worker retry-resume
taint_check worker retry
taint_check critic recheck
taint_check reviewer re-audit
taint_check skeptic audit
taint_check advocate audit
taint_check auditor re-audit
taint_check critic retry-resume
taint_check planner audit
taint_check planner ''
taint_check '' revise
taint_check '' ''
taint_check bogus bogus
pass "taint consistency: continue->tainted 0, resume->tainted 1 for every fixture"

# --- Pure predicate: exactly one token/line, exit 0, writes no files ----------
before="$(find "$SINGULAR_STATE_DIR" -type f | sort)"
for pair in "planner revise" "critic recheck" "bogus bogus" "'' ''"; do
  # shellcheck disable=SC2086
  set -- $pair
  rc=0; line="$(singular_ctx_route_strategy_classify "${1:-}" "${2:-}")" || rc=$?
  assert_eq "$rc" "0" "classify exit 0 for [$pair]"
  [[ "$(printf '%s\n' "$line" | wc -l | tr -d ' ')" == "1" ]] \
    || fail "classify printed more than one line for [$pair]"
  case "$line" in
    continue|resume) ;;
    *) fail "classify printed a non-{continue,resume} token [$line] for [$pair]" ;;
  esac
done
after="$(find "$SINGULAR_STATE_DIR" -type f | sort)"
assert_eq "$after" "$before" "predicate writes no files"
pass "contract: pure predicate prints one {continue,resume} token, exit 0, writes no files"

echo "ctx-route-strategy tests passed"
