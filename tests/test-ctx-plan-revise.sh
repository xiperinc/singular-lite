#!/usr/bin/env bash
# Covers the plan-revision-loop bound authority library brick
# engine/ctx-plan-revise.sh:
#   singular_plan_revise_decide <verdict> <revisions_done> — pure, deterministic
#     decider mapping a plan-critic verdict + rounds-already-spent to the next
#     loop action, bounded by SINGULAR_PLAN_REVISE_MAX (default 1). Prints EXACTLY
#     one line, NEVER exits non-zero, and NEVER resolves ambiguity to `revise`
#     (so no unbounded revision path can exist).
#   singular_plan_revise_max — pure helper centralizing the default-1 bound.
#
# Contract asserted here:
#   approve                       -> import
#   revise, done < effectiveMax   -> revise <done+1>
#   revise, done >= effectiveMax  -> park revise-budget-exhausted
#   park (explicit terminal)      -> park park
#   empty / unknown verdict       -> park <reason> (fail-closed)
#   non-int/negative revisions    -> park <reason> (fail-closed)
#   non-int/negative MAX          -> park <reason> (fail-closed)
# The effective max reads SINGULAR_PLAN_REVISE_MAX, defaulting to 1 when unset or
# empty; an override is honored.
#
# The engine file defines NEW functions only and is invoked by no existing engine
# path; this test runs against isolated state (no real run state mutated).
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
CTX_PR="$ENGINE_HOME/engine/ctx-plan-revise.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }
assert_eq() { # <got> <want> <label>
  [[ "$1" == "$2" ]] || fail "$3: expected [$2], got [$1]"
}

# --- Isolated state: never touch the real repo or its state dir --------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state"
export SINGULAR_ROOT="$tmp"
export SINGULAR_STATE_DIR="$tmp/state"
# shellcheck disable=SC1090
source "$LIB" || fail "sourcing lib.sh failed"

# lib.sh auto-sources the ctx file; source again defensively (RED before it is
# written: the file must exist and define the decider).
[[ -f "$CTX_PR" ]] || fail "engine not present yet: $CTX_PR"
# shellcheck disable=SC1090
source "$CTX_PR" || fail "sourcing $CTX_PR failed"
[[ "$(type -t singular_plan_revise_decide)" == "function" ]] \
  || fail "singular_plan_revise_decide not defined by $CTX_PR"
[[ "$(type -t singular_plan_revise_max)" == "function" ]] \
  || fail "singular_plan_revise_max not defined by $CTX_PR"

# decide <verdict> <revisions_done>: capture output AND exit code; the decider
# must ALWAYS exit 0 and print EXACTLY one line.
decide() { # <verdict> <revisions_done> -> echoes single line; asserts rc0 + 1 line
  local out rc=0
  out="$(singular_plan_revise_decide "$@")" || rc=$?
  assert_eq "$rc" "0" "decide($*): exit code"
  [[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" == "1" ]] \
    || fail "decide($*): expected exactly one line, got [$out]"
  printf '%s' "$out"
}

# --- Helper: default bound is 1; empty is treated as unset --------------------
out="$(unset SINGULAR_PLAN_REVISE_MAX; singular_plan_revise_max)"
assert_eq "$out" "1" "max: default when unset"
out="$(SINGULAR_PLAN_REVISE_MAX= singular_plan_revise_max)"
assert_eq "$out" "1" "max: default when empty"
out="$(SINGULAR_PLAN_REVISE_MAX=2 singular_plan_revise_max)"
assert_eq "$out" "2" "max: honors override"
pass "singular_plan_revise_max: default 1, empty->1, override honored"

# --- approve -> import (terminal accept, independent of round count) ----------
assert_eq "$(unset SINGULAR_PLAN_REVISE_MAX; decide approve 0)" "import" "approve@0"
assert_eq "$(unset SINGULAR_PLAN_REVISE_MAX; decide approve 5)" "import" "approve@5"
pass "verdict approve -> import"

# --- revise within budget -> revise <next_round> (done+1) --------------------
assert_eq "$(unset SINGULAR_PLAN_REVISE_MAX; decide revise 0)" "revise 1" "revise@0 default-max"
pass "verdict revise, done<max -> revise <done+1>"

# --- revise at/over budget -> park revise-budget-exhausted (never revise) -----
assert_eq "$(unset SINGULAR_PLAN_REVISE_MAX; decide revise 1)" "park revise-budget-exhausted" "revise@1 default-max"
assert_eq "$(unset SINGULAR_PLAN_REVISE_MAX; decide revise 2)" "park revise-budget-exhausted" "revise@2 default-max"
pass "verdict revise, done>=max -> park revise-budget-exhausted (still-non-approve, no budget -> park, never revise)"

# --- default effective max is exactly 1 --------------------------------------
# With the default, round 0 is allowed (revise 1) and round 1 is exhausted.
assert_eq "$(unset SINGULAR_PLAN_REVISE_MAX; decide revise 0)" "revise 1" "default-max allows first round"
assert_eq "$(unset SINGULAR_PLAN_REVISE_MAX; decide revise 1)" "park revise-budget-exhausted" "default-max parks second"
pass "default SINGULAR_PLAN_REVISE_MAX=1: exactly one revise round then park"

# --- SINGULAR_PLAN_REVISE_MAX override honored: second round allowed, third parks
assert_eq "$(SINGULAR_PLAN_REVISE_MAX=2 singular_plan_revise_decide revise 0)" "revise 1" "max=2 round0"
assert_eq "$(SINGULAR_PLAN_REVISE_MAX=2 singular_plan_revise_decide revise 1)" "revise 2" "max=2 round1"
assert_eq "$(SINGULAR_PLAN_REVISE_MAX=2 singular_plan_revise_decide revise 2)" "park revise-budget-exhausted" "max=2 round2 parks"
pass "SINGULAR_PLAN_REVISE_MAX=2 honored: second round allowed (revise 2), third parks"

# --- park (explicit terminal non-approve, non-revise verdict) -> park park -----
assert_eq "$(unset SINGULAR_PLAN_REVISE_MAX; decide park 0)" "park park" "park verdict"
pass "verdict park -> park park"

# --- Fail-closed: empty / unknown verdict -> park <reason>, never revise -------
out="$(unset SINGULAR_PLAN_REVISE_MAX; decide '' 0)"
[[ "$out" == park\ * ]] || fail "empty verdict: expected a park line, got [$out]"
[[ "$out" != revise* ]] || fail "empty verdict resolved to revise (unbounded path)"
out="$(unset SINGULAR_PLAN_REVISE_MAX; decide bogus 0)"
[[ "$out" == park\ * ]] || fail "unknown verdict: expected a park line, got [$out]"
[[ "$out" != revise* ]] || fail "unknown verdict resolved to revise (unbounded path)"
pass "fail-closed: empty/unknown verdict -> park <reason>, never revise"

# --- Fail-closed: non-integer / negative revisions_done -> park, never revise --
for bad in "" "abc" "-1" "1.5" "0x1" " " "3a"; do
  out="$(unset SINGULAR_PLAN_REVISE_MAX; decide revise "$bad")"
  [[ "$out" == park\ * ]] || fail "revise bad-revisions [$bad]: expected park, got [$out]"
  [[ "$out" != revise* ]] || fail "revise bad-revisions [$bad] resolved to revise (unbounded path)"
done
pass "fail-closed: non-integer/negative revisions_done -> park <reason>, never revise"

# --- Fail-closed: non-integer / negative SINGULAR_PLAN_REVISE_MAX -> park -------
for bad in "abc" "-1" "1.5" "0x2" " " "2a"; do
  out="$(SINGULAR_PLAN_REVISE_MAX="$bad" singular_plan_revise_decide revise 0)"
  [[ "$out" == park\ * ]] || fail "bad max [$bad]: expected park, got [$out]"
  [[ "$out" != revise* ]] || fail "bad max [$bad] resolved to revise (unbounded path)"
done
pass "fail-closed: non-integer/negative SINGULAR_PLAN_REVISE_MAX -> park <reason>, never revise"

# --- Contract: exactly one line and exit 0 across representative inputs --------
for args in "approve 0" "revise 0" "revise 9" "park 0" "bogus 0"; do
  rc=0
  # shellcheck disable=SC2086
  lines="$(singular_plan_revise_decide $args)" || rc=$?
  assert_eq "$rc" "0" "contract rc0: $args"
  [[ "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" == "1" ]] \
    || fail "contract one-line: [$args] printed more than one line"
done
pass "contract: exactly one line, exit 0 on every path"

echo "ctx-plan-revise tests passed"
