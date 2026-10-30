#!/usr/bin/env bash
# Filter authored knowledge by freshness and load-when triggers before context assembly.

singular_ctx_rehydrate_authored_eligible() {
  # Triggers arrive as argv; the selector JSONL arrives on stdin. The pure
  # renderer reads stdin and receives the trigger context as its own argv. The
  # program is passed via -c (NOT a heredoc) so python's stdin stays bound to the
  # real selector JSONL rather than the script text.
  python3 -c '
import json
import sys

# Documented stale/expired freshness states. An authored-knowledge record whose
# freshness is one of these is non-current and is NEVER emitted as current, so it
# can never be presented as current or authoritative (mirrors the
# description_unverified rule from the selector slice). Matching is case-
# insensitive; every other freshness value (including "current", "fresh", and the
# empty string) passes the gate.
STALE_FRESHNESS = {"stale", "expired"}

# The current trigger context (may be empty). Order/duplication is irrelevant:
# load-when matching is set membership.
triggers = set(sys.argv[1:])

selected = []
for raw in sys.stdin:
    line = raw.strip()
    if not line:
        continue
    # Fail-soft: a malformed JSONL line is skipped, not fatal.
    try:
        rec = json.loads(line)
    except ValueError:
        continue
    if not isinstance(rec, dict):
        continue

    sid = rec.get("id")
    if not isinstance(sid, str) or not sid:
        continue

    # freshness gate: drop documented stale/expired records outright.
    fresh = rec.get("freshness")
    if isinstance(fresh, str) and fresh.strip().lower() in STALE_FRESHNESS:
        continue

    # load-when matching: eligible iff empty (unconditional baseline) or it
    # intersects the supplied trigger context.
    lw = rec.get("load-when")
    if not isinstance(lw, list):
        lw = []
    load_when = {v for v in lw if isinstance(v, str)}
    if load_when and load_when.isdisjoint(triggers):
        continue

    # Class markers pass through unchanged: the filter never elevates an entry to
    # authoritative. Re-serialize with sort_keys so the eligible subset is
    # byte-for-byte a subset of the selector emission.
    selected.append(rec)

# Deterministic, fixed order: the same id sort the selector uses.
selected.sort(key=lambda r: r["id"])
for rec in selected:
    sys.stdout.write(json.dumps(rec, sort_keys=True, ensure_ascii=False))
    sys.stdout.write("\n")
' _ "$@"
}
