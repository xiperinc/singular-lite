#!/usr/bin/env bash
# Compose selected, eligible authored knowledge into a bounded rehydration packet.

singular_ctx_rehydrate_authored_render() {
  local manifest="${1-}"
  [[ $# -gt 0 ]] && shift
  singular_ctx_rehydrate_authored_select "$manifest" \
    | singular_ctx_rehydrate_authored_eligible "$@" \
    | _singular_ctx_authored_packet_py packet "${SINGULAR_CONTEXT_SECTION_MAX_CHARS:-4000}"
}

# singular_ctx_rehydrate_authored_manifest <manifest-path> [trigger ...]
singular_ctx_rehydrate_authored_manifest() {
  local manifest="${1-}"
  [[ $# -gt 0 ]] && shift
  singular_ctx_rehydrate_authored_select "$manifest" \
    | singular_ctx_rehydrate_authored_eligible "$@" \
    | _singular_ctx_authored_packet_py manifest "${SINGULAR_CONTEXT_SECTION_MAX_CHARS:-4000}"
}

# Internal: the pure Python renderer. argv: mode (packet|manifest) and the
# section cap. Reads the eligible JSON Lines on stdin (one authored-knowledge
# record per line, each carrying id / source(body|path) / body|path /
# class=authored-knowledge / authoritative=false), resolves each entry's body
# READ-ONLY, and emits either the labeled packet section or the JSON sources
# manifest in a fixed id-sorted order. No I/O beyond reading path-backed bodies
# and writing stdout; no side effects.
_singular_ctx_authored_packet_py() {
  # The program is passed via -c (NOT a heredoc) so python's stdin stays bound to
  # the real eligible JSONL rather than the script text.
  python3 -c '
import hashlib
import json
import sys

mode = sys.argv[1] if len(sys.argv) > 1 else "packet"
try:
    cap = int(sys.argv[2])
except (ValueError, IndexError):
    cap = 4000

# Explicit class marker heading every rendered section: authored-knowledge, human
# curated, and NEVER authoritative. Distinct from durable host-verified artifacts
# and from model-authored (tainted) records.
MARKER = "[authored-knowledge -- not authoritative]"
TRUNC = "\n[... authored section truncated to fit the context budget ...]"


def section_cap(text):
    if len(text) <= cap:
        return text
    keep = max(0, cap - len(TRUNC))
    return text[:keep] + TRUNC


records = []
for raw in sys.stdin:
    line = raw.strip()
    if not line:
        continue
    # Fail-soft: a malformed line contributes nothing.
    try:
        rec = json.loads(line)
    except ValueError:
        continue
    if not isinstance(rec, dict):
        continue
    sid = rec.get("id")
    if not isinstance(sid, str) or not sid:
        continue

    # Resolve the entry body READ-ONLY: an inline body, or the contents of a
    # path-backed entry. Quarantine/exclusion has already been applied upstream by
    # the integrated select/eligible leaves.
    source = rec.get("source")
    body = None
    if source == "body":
        b = rec.get("body")
        if isinstance(b, str):
            body = b.encode("utf-8")
    elif source == "path":
        path = rec.get("path")
        if isinstance(path, str) and path:
            try:
                with open(path, "rb") as fh:
                    body = fh.read()
            except OSError:
                # A declared-but-unreadable path-backed body contributes nothing;
                # stay pure and non-fatal.
                body = None
    if body is None:
        continue

    records.append((sid, body))

# Deterministic, fixed order: sort by id (the same id sort select/eligible use).
records.sort(key=lambda r: r[0])

if mode == "manifest":
    obj = {
        "schema": "singular.orchestration.ctx-rehydrate-authored-manifest.v0",
        "sources": [
            {
                "id": sid,
                "sha256": hashlib.sha256(body).hexdigest(),
                "class": "authored-knowledge",
                "authoritative": False,
            }
            for sid, body in records
        ],
    }
    sys.stdout.write(json.dumps(obj, sort_keys=True, ensure_ascii=False))
    sys.stdout.write("\n")
else:
    # An empty selection yields an empty section (no stray output), fail-soft.
    if not records:
        sys.exit(0)
    parts = []
    for sid, body in records:
        parts.append("=== authored:%s ===" % sid)
        parts.append(MARKER)
        parts.append(section_cap(body.decode("utf-8", "replace")))
    sys.stdout.write("\n".join(parts))
    sys.stdout.write("\n")
' "$1" "$2"
}
