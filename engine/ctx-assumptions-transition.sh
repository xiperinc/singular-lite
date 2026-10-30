#!/usr/bin/env bash
# Host-derived status-transition brick of the per-run assumption ledger
# (stage S4-context-packets, node assumption-ledger). Sourced exactly once by the
# context module loader block in lib.sh (it matches the ctx-*.sh glob). Like
# engine/ctx-assumptions.sh, this file defines a PURE helper and is
# present-but-uncalled by every existing engine/CLI/driver path, so with it sourced
# the engine stays byte-identical to prior behavior (notably under
# SINGULAR_CTX_PACKET=0, which no path here consults).
#
# The seed (engine/ctx-assumptions.sh) emits a per-run ledger whose assumptions carry
# stable positional ids A1..An. This slice advances that ledger from an attempt's
# auditor findings. An auditor finding that references an assumption's id IS the
# host-observable evidence the assumption was violated, so the HOST deterministically
# flips that entry's status to `violated` — authoritatively, regardless of any status
# the model asserted on the finding. Model-only status assertions that do not resolve
# to a ledger id are segregated into a non-authoritative `claims` array and never move
# an authoritative status; that is the host/model boundary the planner contract's
# evidence-invariance rule requires.
#
# This is later composed by the wire-in slices (fix/audit prompt injection behind
# SINGULAR_CTX_PACKET, per-attempt carry, capsule recording). This slice does NOT
# touch driver files, inject into any prompt, add per-attempt carry, or add the flag.

# singular_ctx_assumptions_transition <ledger-json> <findings-json>
#
# A PURE ledger->ledger transform. Reads BOTH JSON arguments (no file I/O, no events,
# does NOT read capsules) and prints the updated ledger JSON on stdout:
#   {"schema":"singular.orchestration.ctx-assumptions.v0",
#    "assumptions":[{"id":"A1","status":..,"claim":..,"basis":..}, ...],
#    "claims":[{"assumptionId":..,"status":..,"source":"model"}, ...]}
#
#   - Host-derived: every finding whose `assumptionId` matches a ledger entry `id`
#     flips that entry's `status` to `violated`, regardless of any model-asserted
#     status on the finding. Entries referenced by no resolvable finding keep their
#     seeded `status`, `claim`, `basis` unchanged.
#   - Host/model boundary: a finding whose `assumptionId` is missing or resolves to no
#     ledger `id` NEVER mutates `assumptions`; it is appended to the additive,
#     non-authoritative top-level `claims` array, marked model-sourced.
#   - Idempotent + deterministic: re-applying the transform, or passing several
#     findings that reference the same id, yields byte-identical output; `assumptions`
#     stay in id order (A1, A2, ...). `claims` is derived purely from the findings, so
#     feeding a transition output back in with the same findings is a fixed point.
#   - `claims` is an additive field, so a transition output is still a valid
#     singular.orchestration.ctx-assumptions.v0 ledger for existing consumers.
singular_ctx_assumptions_transition() {
  singular_ctx_assumptions_transition_py "$1" "$2"
}

# Internal: the pure Python transform. Reads ledger + findings JSON on argv and prints
# the updated ledger. No I/O beyond stdout; no side effects.
singular_ctx_assumptions_transition_py() {
  python3 - "$1" "$2" <<'PY'
import json, sys


def _load(raw, empty):
    try:
        v = json.loads(raw)
    except Exception:
        return empty
    return v


ledger = _load(sys.argv[1], {})
if not isinstance(ledger, dict):
    ledger = {}

assumptions_in = ledger.get("assumptions", [])
if not isinstance(assumptions_in, list):
    assumptions_in = []

findings_in = _load(sys.argv[2], [])
if not isinstance(findings_in, list):
    findings_in = []

# Normalize the ledger entries, keyed by their stable id so findings can resolve.
by_id = {}
entries = []
for a in assumptions_in:
    a = dict(a) if isinstance(a, dict) else {}
    entries.append(a)
    aid = a.get("id")
    if isinstance(aid, str):
        by_id[aid] = a

# HOST authority: a finding that resolves to a ledger id IS the evidence of violation;
# flip that entry's status to `violated`. A finding that does not resolve is a
# non-authoritative model claim — it never touches an authoritative status.
claims = []
for f in findings_in:
    f = f if isinstance(f, dict) else {}
    aid = f.get("assumptionId")
    if isinstance(aid, str) and aid in by_id:
        by_id[aid]["status"] = "violated"
    else:
        claims.append({
            "assumptionId": aid if isinstance(aid, str) else None,
            "status": f.get("status"),
            "source": "model",
        })


def _order_key(entry):
    aid = entry.get("id")
    if isinstance(aid, str) and len(aid) > 1 and aid[0] == "A" and aid[1:].isdigit():
        return (0, int(aid[1:]), "")
    return (1, 0, aid if isinstance(aid, str) else "")


entries.sort(key=_order_key)

obj = {
    "schema": "singular.orchestration.ctx-assumptions.v0",
    "assumptions": entries,
    "claims": claims,
}
sys.stdout.write(json.dumps(obj, sort_keys=True, ensure_ascii=False))
sys.stdout.write("\n")
PY
}
