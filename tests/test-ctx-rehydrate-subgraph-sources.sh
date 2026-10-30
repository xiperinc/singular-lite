#!/usr/bin/env bash
# Regression contracts for ctx-rehydrate-subgraph-sources.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export SINGULAR_ROOT="$tmp"

# Resolver invocation: stdin-driven, optional file arg.
subgraph() {
  bash -c '
    source "'"$LIB"'"
    singular_ctx_rehydrate_subgraph_sources "$@"
  ' _ "$@"
}
manifest() {
  bash -c '
    source "'"$LIB"'"
    singular_ctx_rehydrate_manifest "$@"
  ' _ "$@"
}
manifest_ids() {
  python3 -c 'import json,sys; print(" ".join(s["id"] for s in json.load(sys.stdin)["sources"]))'
}

# Emit one canonical context-graph.v0 node record (JSONL line).
#   node <type> <sourcePath> [role]
node() {
  local type="$1" sp="$2" role="${3-}"
  if [[ -n "$role" ]]; then
    printf '{"schema":"singular.orchestration.context-graph.v0","kind":"node","id":"n-000000000000","type":"%s","evidenceClass":"claim","provenance":{"sourcePath":"%s","contentHash":"sha256:%064d"},"attributes":{"role":"%s"}}\n' "$type" "$sp" 0 "$role"
  else
    printf '{"schema":"singular.orchestration.context-graph.v0","kind":"node","id":"n-000000000000","type":"%s","evidenceClass":"claim","provenance":{"sourcePath":"%s","contentHash":"sha256:%064d"}}\n' "$type" "$sp" 0
  fi
}

# Durable-source artifact files the selected nodes' provenance points at (so the
# resolver output composes directly as assembler arguments over real bytes).
art="$tmp/art"; mkdir -p "$art"
p_task="$art/packet.json";           printf '{"task":"T"}\n'        >"$p_task"
p_impl="$art/implementer-capsule.json"; printf '{"impl":"cap"}\n'   >"$p_impl"
p_rev="$art/reviewer-capsule.json";  printf '{"rev":"cap"}\n'       >"$p_rev"
p_find="$art/findings-status.json";  printf '{"findings":[]}\n'     >"$p_find"
p_asm="$art/assumptions-ledger.json"; printf '{"assumptions":[]}\n' >"$p_asm"
p_crit="$art/plan-critique.json";    printf '{"critique":"c"}\n'    >"$p_crit"
p_dec="$art/decision-record.json";   printf '{"decision":"d"}\n'    >"$p_dec"

before_hash="$(find "$tmp" -type f -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}')"

# --- Case 1: full mapping, contradictions-first selection order preserved ----
# Input order is the selector's order (critique/finding first), interleaved with
# non-durable nodes that must emit nothing. Output MUST preserve this order and
# NOT be re-sorted into source-class rank order.
stream="$(
  node critique     "$p_crit"
  node goal         "$art/ignored-goal"
  node finding      "$p_find"
  node task         "$p_task"
  node gate-result  "$art/ignored-gate"
  node decision     "$p_dec"
  node capsule      "$p_impl" implementer
  node plan-batch   "$art/ignored-planbatch"
  node assumption   "$p_asm"
  node commit       "$art/ignored-commit"
  node capsule      "$p_rev" reviewer
  node audit        "$art/ignored-audit"
)"

out="$(printf '%s\n' "$stream" | subgraph)" || fail "case1: resolver exited non-zero"
want="critique-record=$p_crit
findings-ledger=$p_find
task-packet=$p_task
decision-record=$p_dec
implementer-capsule=$p_impl
assumptions-ledger=$p_asm
reviewer-capsule=$p_rev"
[[ "$out" == "$want" ]] || fail "case1: mapping/order wrong.
got:
$out
want:
$want"

# --- Case 2: NOT re-sorted by source-class rank -----------------------------
# The rank order would put task-packet first; the input puts critique-record
# first. Assert the first emitted spec follows input order, not rank.
first="$(printf '%s\n' "$out" | head -n1)"
[[ "$first" == "critique-record=$p_crit" ]] \
  || fail "case2: output re-sorted by rank (first line [$first], expected critique-record)"

# --- Case 3: nodes with no durable source class emit nothing -----------------
nada="$(
  { node goal "$art/g"; node plan-batch "$art/pb"; node plan-version "$art/pv"
    node attempt "$art/at"; node commit "$art/cm"; node gate-result "$art/gr"
    node audit "$art/au"; } | subgraph
)" || fail "case3: resolver exited non-zero"
[[ -z "$nada" ]] || fail "case3: non-durable node types emitted specs: [$nada]"

# --- Case 4: ids match the assembler vocabulary EXACTLY ----------------------
# Feed the resolver output straight into the manifest assembler; every emitted
# id must be an assembler source class (the manifest RANK), so the manifest
# accepts all of them and reports the SAME set (rank-ordered).
IFS=$'\n' read -r -d '' -a out_specs < <(printf '%s\0' "$out")
m="$(manifest "${out_specs[@]}")" || fail "case4: manifest exited non-zero"
m_ids="$(printf '%s\n' "$m" | manifest_ids)"
want_m="task-packet implementer-capsule reviewer-capsule findings-ledger assumptions-ledger critique-record decision-record"
[[ "$m_ids" == "$want_m" ]] || fail "case4: emitted ids not the exact assembler vocabulary.
got:  [$m_ids]
want: [$want_m]"

# --- Case 5: file arg parity with stdin -------------------------------------
fixture="$tmp/subgraph.jsonl"
printf '%s\n' "$stream" >"$fixture"
out_file="$(subgraph "$fixture")" || fail "case5: file-arg resolver exited non-zero"
[[ "$out_file" == "$out" ]] || fail "case5: file arg differs from stdin.
file:
$out_file
stdin:
$out"

# --- Case 6: determinism ----------------------------------------------------
out2="$(printf '%s\n' "$stream" | subgraph)" || fail "case6: resolver(2) exited non-zero"
[[ "$out" == "$out2" ]] || fail "case6: resolver not deterministic (byte-identical specs expected)"

# --- Case 7: fail-safe empty input ------------------------------------------
empty="$(printf '' | subgraph)" || fail "case7: empty input exited non-zero"
[[ -z "$empty" ]] || fail "case7: empty input yielded specs: [$empty]"
blank="$(printf '\n\n' | subgraph)" || fail "case7: blank-line input exited non-zero"
[[ -z "$blank" ]] || fail "case7: blank-line input yielded specs: [$blank]"

# --- Case 8: capsule role discrimination ------------------------------------
# A capsule with an unknown/absent role has no durable class -> emits nothing.
cap_amb="$(node capsule "$p_impl" | subgraph)" || fail "case8: resolver exited non-zero"
[[ -z "$cap_amb" ]] || fail "case8: role-less capsule emitted a spec: [$cap_amb]"
cap_impl="$(node capsule "$p_impl" implementer | subgraph)" || fail "case8: impl capsule exited non-zero"
[[ "$cap_impl" == "implementer-capsule=$p_impl" ]] || fail "case8: implementer capsule wrong: [$cap_impl]"
cap_rev="$(node capsule "$p_rev" reviewer | subgraph)" || fail "case8: rev capsule exited non-zero"
[[ "$cap_rev" == "reviewer-capsule=$p_rev" ]] || fail "case8: reviewer capsule wrong: [$cap_rev]"

# --- Case 9: purity / evidence invariance -----------------------------------
after_hash="$(find "$tmp" -type f -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}')"
# (fixtures added between snapshots, so a lone resolver call is snapshotted below)
snap_before="$(find "$art" -type f -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}')"
printf '%s\n' "$stream" | subgraph >/dev/null 2>&1 || fail "case9: resolver exited non-zero"
snap_after="$(find "$art" -type f -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}')"
[[ "$snap_before" == "$snap_after" ]] || fail "case9: resolver mutated the source tree (not read-only)"

# grants no independence: rehydrate strategy stays tainted
tainted="$(bash -c 'source "'"$LIB"'"; singular_ctx_route_strategy_tainted rehydrate')" \
  || fail "case9: taint query exited non-zero"
[[ "$tainted" == "1" ]] || fail "case9: rehydrate strategy no longer tainted (got [$tainted])"

echo "ctx-rehydrate-subgraph-sources tests passed"
