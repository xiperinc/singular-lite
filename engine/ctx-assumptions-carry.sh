#!/usr/bin/env bash
# Per-attempt carry brick of the per-run assumption ledger (stage S4-context-packets,
# node assumption-ledger). Sourced exactly once by the context module loader block in
# lib.sh (it matches the ctx-*.sh glob). Like engine/ctx-assumptions.sh and its siblings,
# this file defines a PURE helper and is present-but-uncalled by every existing
# engine/CLI/driver path, so with it sourced the engine stays byte-identical to prior
# behavior (notably under SINGULAR_CTX_PACKET=0, which no path here consults).
#
# The seed (engine/ctx-assumptions.sh) emits a fresh per-run ledger for each attempt from
# the task packet (the per-run source of truth, unchanged between attempts). This slice
# ships the per-attempt carry: it merges the PRIOR attempt's ledger into the CURRENT
# attempt's fresh seed so a host-observed `violated` status carries forward across retries
# — like an open finding that persists until addressed — while the current seed stays the
# STRUCTURAL AUTHORITY for which assumptions exist and what they claim.
#
# This is later composed by the wire-in slices (composed per-run assembler, capsule
# recording, fix/audit prompt injection behind SINGULAR_CTX_PACKET). This slice does NOT
# touch driver files, compose the assembler, record the capsule, inject into any prompt,
# or add/consult the flag.

# singular_ctx_assumptions_carry <prior-ledger-json> <seed-ledger-json>
#
# A PURE ledger->ledger transform. Reads BOTH JSON arguments (no file I/O, no events,
# reads no flag) and prints the merged ledger JSON on stdout:
#   {"schema":"singular.orchestration.ctx-assumptions.v0",
#    "assumptions":[{"id":"A1","status":..,"claim":..,"basis":..}, ...]}
#
#   - STRUCTURAL AUTHORITY = the seed: the output has EXACTLY the seed's assumption ids in
#     id order, each carrying the seed's `claim` and `basis`. Ids present only in the prior
#     ledger are NOT resurrected; ids new in the seed keep their seed `status`.
#   - STICKY VIOLATION: for a seed entry whose id appears in the prior ledger with `status`
#     `violated`, the output status is `violated`; otherwise it is the seed's status. A
#     host-observed violation thus carries forward like an open finding until addressed.
#   - FIRST ATTEMPT / EMPTY PRIOR: an empty, absent, or `{}` prior ledger yields the seed
#     ledger unchanged (carry is identity on the seed).
#   - Deterministic + read-only: identical inputs yield byte-identical output; re-carrying
#     an already-carried ledger against the same prior is a fixed point; neither input JSON
#     nor any file is mutated.
singular_ctx_assumptions_carry() {
  singular_ctx_assumptions_carry_py "$1" "$2"
}

# Internal: the pure Python transform. Reads prior + seed ledger JSON on argv and prints
# the merged ledger. No I/O beyond stdout; no side effects.
singular_ctx_assumptions_carry_py() {
  python3 - "$1" "$2" <<'PY'
import json, sys


def _load(raw):
    try:
        v = json.loads(raw)
    except Exception:
        return {}
    return v if isinstance(v, dict) else {}


def _assumptions(ledger):
    a = ledger.get("assumptions", [])
    return a if isinstance(a, list) else []


prior = _load(sys.argv[1])
seed = _load(sys.argv[2])

# Which prior ids were host-observed `violated`; only those are sticky.
prior_violated = set()
for a in _assumptions(prior):
    if not isinstance(a, dict):
        continue
    aid = a.get("id")
    if isinstance(aid, str) and a.get("status") == "violated":
        prior_violated.add(aid)

# The seed is the structural authority: emit exactly its entries, carrying its claim/basis,
# flipping a status to `violated` only when that id was sticky-violated in the prior.
out = []
for a in _assumptions(seed):
    a = a if isinstance(a, dict) else {}
    aid = a.get("id")
    status = a.get("status")
    if isinstance(aid, str) and aid in prior_violated:
        status = "violated"
    out.append({
        "id": aid,
        "status": status,
        "claim": a.get("claim"),
        "basis": a.get("basis"),
    })

obj = {
    "schema": "singular.orchestration.ctx-assumptions.v0",
    "assumptions": out,
}
sys.stdout.write(json.dumps(obj, sort_keys=True, ensure_ascii=False))
sys.stdout.write("\n")
PY
}
