#!/usr/bin/env bash
set -euo pipefail
# Review/repair budget coupling (loop-economics protocol 5.3): the three
# sequences of the 5.3 table in both risk tiers, plus a granted third review
# that must not expand the product-repair ceiling. The cases share the frozen
# campaign lifecycle fixture in test-first-audit-correction.sh, which keeps
# them out of its own "all" run so each case executes once per suite.
ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIRST_AUDIT_CASE=risk-review-coupling exec bash "$ENGINE_HOME/tests/test-first-audit-correction.sh"
