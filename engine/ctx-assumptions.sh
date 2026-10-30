#!/usr/bin/env bash
# Per-run assumption ledger seed (stage S4-context-packets, node assumption-ledger).
# Sourced exactly once by the context module loader block in lib.sh (it matches
# the ctx-*.sh glob). Like engine/ctx-packet.sh, this file defines a PURE helper and
# is present-but-uncalled by every existing engine/CLI/driver path, so with it
# sourced the engine stays byte-identical to prior behavior (notably under
# SINGULAR_CTX_PACKET=0, which no path here consults).
#
# This is the foundational data-structure slice the later wire-in slices (fix/audit
# prompt injection behind SINGULAR_CTX_PACKET, per-attempt carry, host-derived status
# transitions) build on. It seeds a per-run assumption ledger from a task's context
# packet by composing the already-integrated singular_ctx_packet_json parser. Each
# seeded assumption gets a stable, deterministic id (A1, A2, … over the packet's
# declared order) so a later host-derived transition — an auditor finding that
# references an assumption's id — has a fixed anchor.

# singular_ctx_assumptions_seed <task-file>
#
# Reads <task-file> STRICTLY READ-ONLY (composing singular_ctx_packet_json) and
# prints a normalized per-run assumption ledger JSON on stdout:
#   {"schema":"singular.orchestration.ctx-assumptions.v0",
#    "assumptions":[{"id":"A1","status":..,"claim":..,"basis":..}, ...]}
#
#   - packet declaring assumptions -> one ledger entry per assumption, in the
#     packet's declared order, each carrying a stable positional id (A1, A2, …) and
#     preserving that assumption's status (open|validated|violated), claim, basis.
#   - no `## Context packet` block, an empty packet ({}), or zero assumptions ->
#     stable empty ledger {"schema":...,"assumptions":[]}.
#   - a malformed packet fails closed THROUGH the underlying parser (which prints {}
#     and appends its single ctx.packet_malformed warning) -> empty ledger; the seed
#     re-emits nothing and has no side effects of its own.
singular_ctx_assumptions_seed() {
  local task_file="$1"
  local packet
  # singular_ctx_packet_json is read-only on the task; its ONLY possible side effect
  # (the malformed warning event) is the parser's, deliberately not duplicated here.
  packet="$(singular_ctx_packet_json "$task_file")"
  singular_ctx_assumptions_seed_py "$packet"
}

# Internal: the pure Python transform. Reads the parser's packet JSON on argv and
# prints the normalized ledger. No I/O beyond stdout; no side effects.
singular_ctx_assumptions_seed_py() {
  python3 - "$1" <<'PY'
import json, sys

raw = sys.argv[1]
try:
    packet = json.loads(raw)
except Exception:
    packet = {}
if not isinstance(packet, dict):
    packet = {}

assumptions_in = packet.get("assumptions", [])
if not isinstance(assumptions_in, list):
    assumptions_in = []

ledger = []
for idx, a in enumerate(assumptions_in, start=1):
    a = a if isinstance(a, dict) else {}
    ledger.append({
        "id": "A%d" % idx,
        "status": a.get("status"),
        "claim": a.get("claim"),
        "basis": a.get("basis"),
    })

obj = {
    "schema": "singular.orchestration.ctx-assumptions.v0",
    "assumptions": ledger,
}
sys.stdout.write(json.dumps(obj, sort_keys=True, ensure_ascii=False))
sys.stdout.write("\n")
PY
}
