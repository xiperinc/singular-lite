#!/usr/bin/env bash
# Attempt-open assembler of the per-run assumption ledger (stage S4-context-packets,
# node assumption-ledger). Sourced exactly once by the context module loader block in
# lib.sh (it matches the ctx-*.sh glob). Like engine/ctx-assumptions.sh and its siblings,
# this file defines a PURE helper and is present-but-uncalled by every existing
# engine/CLI/driver path, so with it sourced the engine stays byte-identical to prior
# behavior (notably under SINGULAR_CTX_PACKET=0, which no path here consults).
#
# The seed (engine/ctx-assumptions.sh), the per-attempt carry (engine/ctx-assumptions-carry.sh),
# and the fix/audit render (engine/ctx-assumptions-prompt.sh) are all integrated. This
# slice composes them into ONE attempt-OPEN call the later flag-gated driver hook consumes:
# it computes the current attempt's input ledger as carry(prior, seed(task-file)) and
# renders both prompt sections from it, returning a single envelope JSON carrying the
# `ledger`, the `fixSection`, and the `auditSection`.
#
# ATTEMPT-OPEN path: at attempt open there are no current-attempt findings yet — the prior
# ledger already encodes the previous attempt's host-derived transitions — so this composes
# seed, carry, and render but NOT the transition (the already-integrated
# singular_ctx_assumptions_transition is applied at attempt-close by the later driver hook).
#
# This slice does NOT touch driver files, inject into any prompt, record the capsule, or
# add/consult the flag — those are the later driver-hook slice.

# singular_ctx_assumptions_assemble <task-file> <prior-ledger-json>
#
# Reads <task-file> STRICTLY READ-ONLY (composing singular_ctx_assumptions_seed) and reads
# the prior-ledger JSON argument, then prints a single attempt-open envelope JSON on stdout:
#   {"schema":"singular.orchestration.ctx-assumptions-run.v0",
#    "ledger":{"schema":"singular.orchestration.ctx-assumptions.v0","assumptions":[...]},
#    "fixSection":"...","auditSection":"..."}
#
#   - `ledger` = carry(prior, seed(task-file)): a first attempt (empty/absent/`{}` prior)
#     yields the seed ledger; a retry whose prior holds a `violated` assumption keeps that
#     id `violated` in the envelope ledger (sticky carry).
#   - `fixSection` / `auditSection` = the render helpers applied to the envelope `ledger`;
#     a zero-assumption task yields empty `fixSection` and `auditSection`.
#   - Read-only + deterministic: the task file is byte-identical before/after; identical
#     inputs yield byte-identical output. The ONLY possible side effect is the underlying
#     packet parser's single `ctx.packet_malformed` warning, inherited via the seed on a
#     malformed packet and never re-emitted here.
singular_ctx_assumptions_assemble() {
  local task_file="$1" prior="$2"
  local seed ledger fix audit
  # Compose the integrated bricks. The seed is read-only on the task file; its only
  # possible side effect (the malformed warning) is the parser's, never duplicated here.
  seed="$(singular_ctx_assumptions_seed "$task_file")"
  ledger="$(singular_ctx_assumptions_carry "$prior" "$seed")"
  fix="$(singular_ctx_assumptions_fix_section "$ledger")"
  audit="$(singular_ctx_assumptions_audit_section "$ledger")"
  singular_ctx_assumptions_assemble_py "$ledger" "$fix" "$audit"
}

# Internal: the pure Python envelope builder. Reads the carried ledger JSON plus the two
# rendered sections on argv and prints the run envelope. No I/O beyond stdout; no side
# effects.
singular_ctx_assumptions_assemble_py() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys

try:
    ledger = json.loads(sys.argv[1])
except Exception:
    ledger = {}
if not isinstance(ledger, dict):
    ledger = {}

obj = {
    "schema": "singular.orchestration.ctx-assumptions-run.v0",
    "ledger": ledger,
    "fixSection": sys.argv[2],
    "auditSection": sys.argv[3],
}
sys.stdout.write(json.dumps(obj, sort_keys=True, ensure_ascii=False))
sys.stdout.write("\n")
PY
}
