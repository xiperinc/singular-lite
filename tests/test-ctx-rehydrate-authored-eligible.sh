#!/usr/bin/env bash
# Regression contracts for ctx-rehydrate-authored-eligible.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Invoke the eligibility filter in a clean subshell: stdin is the selector JSONL,
# argv is the current trigger context.
eligible() {
  bash -c '
    source "'"$LIB"'"
    singular_ctx_rehydrate_authored_eligible "$@"
  ' _ "$@"
}

# One selector-shaped JSON record per line, in the selector's own key order
# (json.dumps sort_keys=True). Records are given deliberately NON-sorted ids so
# the id-sorted emission order is exercised.
#   A alpha-impl  load-when ["implement"]  freshness current   -> eligible on `implement`
#   B mid-plan    load-when ["planner"]    freshness current   -> ineligible on `implement`
#   C zed-base    load-when []             freshness current   -> unconditional, always eligible
#   D old-impl    load-when ["implement"]  freshness stale     -> load-when matches but STALE -> dropped
selector_jsonl() {
  cat <<'JSONL'
{"authoritative": false, "body": "impl guidance", "class": "authored-knowledge", "freshness": "current", "id": "alpha-impl", "load-when": ["implement"], "source": "body"}
{"authoritative": false, "body": "planner guidance", "class": "authored-knowledge", "freshness": "current", "id": "mid-plan", "load-when": ["planner"], "source": "body"}
{"authoritative": false, "body": "baseline", "class": "authored-knowledge", "freshness": "current", "id": "zed-base", "load-when": [], "source": "body"}
{"authoritative": false, "body": "aged impl note", "class": "authored-knowledge", "freshness": "stale", "id": "old-impl", "load-when": ["implement"], "source": "body"}
JSONL
}

# --- Case 1: load-when match ------------------------------------------------
# `implement` emits alpha-impl (matching trigger) and zed-base (empty = uncondi-
# tional) and drops mid-plan (non-matching trigger).
out="$(selector_jsonl | eligible implement)" || fail "case1: filter exited non-zero"

grep -q '"id": "alpha-impl"' <<<"$out" \
  || fail "case1: matching-trigger entry alpha-impl not emitted. got:[$out]"
grep -q '"id": "zed-base"' <<<"$out" \
  || fail "case1: unconditional (empty load-when) entry zed-base not emitted. got:[$out]"
grep -q '"id": "mid-plan"' <<<"$out" \
  && fail "case1: non-matching-trigger entry mid-plan emitted. got:[$out]"

# --- Case 2: freshness gate -------------------------------------------------
# old-impl's load-when matches `implement` but its freshness is stale, so it is
# never emitted as current; the fresh alpha-impl with the same trigger is.
grep -q '"id": "old-impl"' <<<"$out" \
  && fail "case2: stale entry old-impl emitted as current. got:[$out]"
grep -q '"id": "alpha-impl"' <<<"$out" \
  || fail "case2: fresh matching entry alpha-impl not emitted. got:[$out]"

# Exactly two survivors, one per line.
n="$(grep -c . <<<"$out")"
[[ "$n" == "2" ]] || fail "case2: expected 2 eligible entries, got $n. out:[$out]"

# --- Case 3: class markers pass through, never authoritative ----------------
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  grep -q '"class": "authored-knowledge"' <<<"$line" \
    || fail "case3: emitted entry missing authored-knowledge class. line:[$line]"
  grep -q '"authoritative": false' <<<"$line" \
    || fail "case3: emitted entry not explicitly non-authoritative. line:[$line]"
done <<<"$out"
grep -Eq '"(host-verified|host_verified|tainted|authoritative)": true' <<<"$out" \
  && fail "case3: an entry was elevated to authoritative/host-verified/tainted. out:[$out]"

# --- Case 4: determinism + fixed id-sorted order ----------------------------
out2="$(selector_jsonl | eligible implement)" || fail "case4: filter exited non-zero on rerun"
[[ "$out" == "$out2" ]] || fail "case4: non-deterministic output.\n1:[$out]\n2:[$out2]"

line_alpha="$(grep -n '"id": "alpha-impl"' <<<"$out" | head -1 | cut -d: -f1)"
line_zed="$(grep -n '"id": "zed-base"' <<<"$out" | head -1 | cut -d: -f1)"
[[ -n "$line_alpha" && -n "$line_zed" && "$line_alpha" -lt "$line_zed" ]] \
  || fail "case4: entries not in fixed id-sorted order (alpha-impl before zed-base). out:[$out]"

# --- Case 5: multiple triggers OR together ----------------------------------
out_multi="$(selector_jsonl | eligible planner startup)" \
  || fail "case5: filter exited non-zero with multiple triggers"
grep -q '"id": "mid-plan"' <<<"$out_multi" \
  || fail "case5: mid-plan not emitted when one of several triggers (planner) matches. got:[$out_multi]"
grep -q '"id": "zed-base"' <<<"$out_multi" \
  || fail "case5: unconditional zed-base not emitted with multiple triggers. got:[$out_multi]"
grep -q '"id": "alpha-impl"' <<<"$out_multi" \
  && fail "case5: non-matching alpha-impl emitted for triggers [planner startup]. got:[$out_multi]"

# --- Case 6: purity / fail-soft ---------------------------------------------
# Malformed lines are skipped, valid lines still processed.
mixed="$(printf '%s\n' \
  '{ not json at all ,,,' \
  '{"authoritative": false, "body": "ok", "class": "authored-knowledge", "freshness": "current", "id": "keep-me", "load-when": [], "source": "body"}' \
  'plain text line')"
out_mixed="$(eligible implement <<<"$mixed")" || fail "case6: filter exited non-zero on malformed input"
grep -q '"id": "keep-me"' <<<"$out_mixed" \
  || fail "case6: valid line dropped alongside malformed lines. got:[$out_mixed]"
nm="$(grep -c . <<<"$out_mixed")"
[[ "$nm" == "1" ]] || fail "case6: expected 1 survivor from mixed input, got $nm. out:[$out_mixed]"

# Empty stdin -> empty output.
out_empty="$(printf '' | eligible implement)" || fail "case6: filter exited non-zero on empty stdin"
[[ -z "$out_empty" ]] || fail "case6: empty stdin produced output. got:[$out_empty]"

# No triggers at all: only the unconditional (empty load-when) entries survive.
out_notrig="$(selector_jsonl | eligible)" || fail "case6: filter exited non-zero with no triggers"
grep -q '"id": "zed-base"' <<<"$out_notrig" \
  || fail "case6: unconditional zed-base dropped when no triggers supplied. got:[$out_notrig]"
grep -q '"id": "alpha-impl"' <<<"$out_notrig" \
  && fail "case6: load-when entry alpha-impl emitted with no triggers. got:[$out_notrig]"

# Read-only: the filter writes nothing into a sentinel workdir.
sentinel="$tmp/sentinel"
mkdir -p "$sentinel"
before="$(find "$sentinel" -type f | wc -l | tr -d ' ')"
( cd "$sentinel" && selector_jsonl | eligible implement >/dev/null )
after="$(find "$sentinel" -type f | wc -l | tr -d ' ')"
[[ "$before" == "$after" ]] || fail "filter wrote files to disk (before=$before after=$after)"

echo "ctx-rehydrate-authored-eligible tests passed"
