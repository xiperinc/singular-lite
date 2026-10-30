#!/usr/bin/env bash
set -euo pipefail

# 0.17.0: the DAG lens's placement maths lives in a pure, import-free
# module (plugin/assets/plan/dag_layout.js) so dependency-wave layout can be
# asserted without a browser. This wrapper hands tests/console/dag_layout.test.mjs
# to node's built-in runner and guards the one invariant that would silently
# break the arrangement: an import in the module under test would drag the whole
# console app (app.js, the DOM) into a bare node run and the suite could never
# load it again. Without node the suite skips — the engine must stay testable on
# a box with no JS toolchain.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-plan-dag-layout.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$ENGINE_HOME/plugin/assets/plan/dag_layout.js"
SUITE="$ENGINE_HOME/tests/console/dag_layout.test.mjs"

fail() { echo "FAIL: $*" >&2; exit 1; }

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 0; }

[[ -f "$MODULE" ]] || fail "module under test not present: $MODULE"
[[ -f "$SUITE" ]] || fail "suite not present: $SUITE"

if grep -Eq '^[[:space:]]*import[[:space:]]' "$MODULE"; then
  fail "dag_layout.js must stay import-free (it has to load under bare node --test)"
fi

if ! out="$(node --test "$SUITE" 2>&1)"; then
  printf '%s\n' "$out" >&2
  fail "node --test dag_layout.test.mjs"
fi

# Guard against a vacuous green: node exits 0 for a run in which every test was
# filtered out, so require the zero-failure summary AND the one test that would
# catch a regression back to stage-ordered columns. (The summary prefix differs
# between node's spec and tap reporters, hence the loose leading match.)
grep -Eq '(^|[[:space:]])fail 0[[:space:]]*$' <<<"$out" || fail "unexpected node --test summary: $out"
grep -q "no node is placed before a prerequisite" <<<"$out" \
  || fail "the prerequisite-ordering test did not run: $out"

printf '%s\n' "$out" | tail -8

echo "PASS: test-plan-dag-layout.sh"
