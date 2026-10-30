#!/usr/bin/env bash
# Pure prompt-render brick of the per-run assumption ledger (stage S4-context-packets,
# node assumption-ledger). Sourced exactly once by the context module loader block in
# lib.sh (it matches the ctx-*.sh glob). Like engine/ctx-assumptions.sh and
# engine/ctx-assumptions-transition.sh, this file defines PURE helpers and is
# present-but-uncalled by every existing engine/CLI/driver path, so with it sourced the
# engine stays byte-identical to prior behavior (notably under SINGULAR_CTX_PACKET=0,
# which no path here consults; the flag gate lives at the later wire-in site).
#
# The seed emits a ledger whose assumptions carry stable ids A1..An; the host-derived
# transition flips violated entries' status to `violated`. This slice turns that ledger
# into prompt text for the two consumers that close the loop:
#   - the implementer/fix prompt, which must ADDRESS violated assumptions like open
#     findings while keeping the rest true for context, and
#   - the auditor prompt, which must VERIFY the assumptions were not silently violated
#     and raise a finding CITING the assumption's id for any violation — the assumptionId
#     the host-derived transition then resolves to flip that entry to `violated`.
#
# Both helpers are pure string->string transforms over the ledger argument: they read no
# files, consult no flag, and emit no events. A ledger with zero assumptions (or an
# absent/empty/malformed ledger argument) renders the empty string, so a later wire-in
# injects nothing and prompts stay unchanged. This slice does NOT touch driver files,
# inject into any real prompt, add per-attempt carry or capsule recording, or add/consult
# the flag — those are later slices for this node.

# singular_ctx_assumptions_fix_section <ledger-json>
#
# Renders the implementer/fix-prompt section on stdout. Violated assumptions are
# foregrounded as open findings to address (each with its id and claim); the remaining
# non-violated assumptions follow for context. Both lists are in id order (A1, A2, ...).
# A ledger with zero assumptions (or an absent/empty/malformed argument) renders "".
singular_ctx_assumptions_fix_section() {
  singular_ctx_assumptions_prompt_py fix "$1"
}

# singular_ctx_assumptions_audit_section <ledger-json>
#
# Renders the auditor-prompt section on stdout. It instructs the auditor to verify the
# listed assumptions were not silently violated and to raise a finding CITING the
# assumption's id (the `assumptionId` the host-derived transition consumes) for any
# violation, then lists every assumption with its id in id order (A1, A2, ...). A ledger
# with zero assumptions (or an absent/empty/malformed argument) renders "".
singular_ctx_assumptions_audit_section() {
  singular_ctx_assumptions_prompt_py audit "$1"
}

# Internal: the pure Python render. Reads the section kind + ledger JSON on argv and
# prints the rendered section (or nothing). No I/O beyond stdout; no side effects.
singular_ctx_assumptions_prompt_py() {
  python3 - "$1" "$2" <<'PY'
import json, sys

kind = sys.argv[1]

try:
    ledger = json.loads(sys.argv[2])
except Exception:
    ledger = {}
if not isinstance(ledger, dict):
    ledger = {}

assumptions = ledger.get("assumptions", [])
if not isinstance(assumptions, list):
    assumptions = []


def _order_key(entry):
    aid = entry.get("id")
    if isinstance(aid, str) and len(aid) > 1 and aid[0] == "A" and aid[1:].isdigit():
        return (0, int(aid[1:]), "")
    return (1, 0, aid if isinstance(aid, str) else "")


# Normalize to dicts with a string id and claim, then order by id (A1, A2, ...).
entries = []
for a in assumptions:
    a = a if isinstance(a, dict) else {}
    aid = a.get("id")
    if not isinstance(aid, str):
        continue
    claim = a.get("claim")
    entries.append({
        "id": aid,
        "status": a.get("status"),
        "claim": claim if isinstance(claim, str) else "",
    })
entries.sort(key=_order_key)

# Empty ledger -> empty string; a later wire-in then injects nothing.
if not entries:
    sys.stdout.write("")
    sys.exit(0)


def _line(e):
    return "- [%s] %s" % (e["id"], e["claim"])


out = []
if kind == "fix":
    violated = [e for e in entries if e["status"] == "violated"]
    context = [e for e in entries if e["status"] != "violated"]
    out.append("## Assumptions to uphold")
    out.append("")
    if violated:
        out.append(
            "Violated assumptions — address each like an open finding:")
        out.extend(_line(e) for e in violated)
        out.append("")
    out.append("Assumptions to hold true (context — do not regress):")
    if context:
        out.extend(_line(e) for e in context)
    else:
        out.append("- (none)")
else:  # audit
    out.append("## Assumption audit")
    out.append("")
    out.append(
        "Verify each assumption below was not silently violated. If one was "
        "violated, raise a finding that cites the assumption's id via the "
        "`assumptionId` field so the host can resolve it (in audit-verdict.v1, "
        "on that finding's `classifiedFindings` item; add no other field):")
    out.extend(_line(e) for e in entries)

sys.stdout.write("\n".join(out))
sys.stdout.write("\n")
PY
}
