#!/usr/bin/env bash
# Regression contracts for ctx-rehydrate-authored-triggers.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
LEAF="$ENGINE_HOME/engine/ctx-rehydrate-authored-triggers.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Invoke the trigger-set builder in a clean subshell: dimensions arrive as argv,
# tokens print to stdout one per line.
triggers() {
  bash -c '
    source "'"$LIB"'"
    singular_ctx_rehydrate_authored_triggers "$@"
  ' _ "$@"
}

# --- Case 1: full four-dimension set ----------------------------------------
out="$(triggers implementer implement rehydrate-path TASK-0063)" \
  || fail "case1: builder exited non-zero"
for tok in implementer implement rehydrate-path TASK-0063; do
  grep -qxF "$tok" <<<"$out" \
    || fail "case1: expected token '$tok' not emitted. got:[$out]"
done
n="$(grep -c . <<<"$out")"
[[ "$n" == "4" ]] || fail "case1: expected exactly 4 tokens, got $n. out:[$out]"

# --- Case 2: backward compatibility — literal `implement` present -----------
grep -qxF implement <<<"$out" \
  || fail "case2: literal implement token missing when step=implement. got:[$out]"

# --- Case 3: optional args absent contribute nothing ------------------------
# Only <role> <step> supplied -> exactly {role, step}, no empty tokens.
out_min="$(triggers implementer implement)" \
  || fail "case3: builder exited non-zero with only role+step"
grep -qxF implementer <<<"$out_min" \
  || fail "case3: role token missing. got:[$out_min]"
grep -qxF implement <<<"$out_min" \
  || fail "case3: step token missing. got:[$out_min]"
nm="$(grep -c . <<<"$out_min")"
[[ "$nm" == "2" ]] || fail "case3: expected exactly 2 tokens, got $nm. out:[$out_min]"
grep -qx '' <<<"$out_min" \
  && fail "case3: an empty token was emitted. out:[$out_min]"

# Explicit empty-string optional args also contribute nothing.
out_empties="$(triggers implementer implement '' '')" \
  || fail "case3: builder exited non-zero with empty optional args"
[[ "$(grep -c . <<<"$out_empties")" == "2" ]] \
  || fail "case3: empty optional args produced tokens. out:[$out_empties]"

# --- Case 4: dedup — repeated dimensions collapse to one token --------------
# Here role == step == node so only one distinct token survives.
out_dup="$(triggers implement implement implement)" \
  || fail "case4: builder exited non-zero on duplicate dimensions"
nd="$(grep -c . <<<"$out_dup")"
[[ "$nd" == "1" ]] || fail "case4: duplicates not collapsed, got $nd tokens. out:[$out_dup]"
grep -qxF implement <<<"$out_dup" \
  || fail "case4: collapsed token is not 'implement'. out:[$out_dup]"

# --- Case 5: determinism + stable order -------------------------------------
out2="$(triggers implementer implement rehydrate-path TASK-0063)" \
  || fail "case5: builder exited non-zero on rerun"
[[ "$out" == "$out2" ]] \
  || fail "case5: non-deterministic output.\n1:[$out]\n2:[$out2]"

# Role precedes step precedes node precedes task in the fixed order.
l_role="$(grep -nxF implementer <<<"$out" | head -1 | cut -d: -f1)"
l_step="$(grep -nxF implement <<<"$out" | head -1 | cut -d: -f1)"
l_node="$(grep -nxF rehydrate-path <<<"$out" | head -1 | cut -d: -f1)"
l_task="$(grep -nxF TASK-0063 <<<"$out" | head -1 | cut -d: -f1)"
[[ "$l_role" -lt "$l_step" && "$l_step" -lt "$l_node" && "$l_node" -lt "$l_task" ]] \
  || fail "case5: tokens not in fixed role<step<node<task order. out:[$out]"

# --- Case 6: purity / read-only ---------------------------------------------
# Writes nothing into a sentinel workdir.
sentinel="$tmp/sentinel"
mkdir -p "$sentinel"
before="$(find "$sentinel" -type f | wc -l | tr -d ' ')"
( cd "$sentinel" && triggers implementer implement rehydrate-path TASK-0063 >/dev/null )
after="$(find "$sentinel" -type f | wc -l | tr -d ' ')"
[[ "$before" == "$after" ]] \
  || fail "case6: builder wrote files to disk (before=$before after=$after)"

# --- Case 7: OFF-parity — the leaf DEFINES a function only, present-but-uncalled
# The file must not invoke the function it defines (no live call site here).
grep -Eq '^[[:space:]]*singular_ctx_rehydrate_authored_triggers[[:space:]]' "$LEAF" \
  && fail "case7: leaf invokes singular_ctx_rehydrate_authored_triggers (must be present-but-uncalled). file:[$LEAF]"

echo "ctx-rehydrate-authored-triggers tests passed"
