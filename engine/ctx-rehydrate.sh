#!/usr/bin/env bash
# ctx-rehydrate.sh — pure, read-only rehydration packet assembler (stage
# S5-routing, node `rehydrate-path`, layer engine_runtime). Sourced exactly once
# by the context module loader block in lib.sh (it matches the ctx-*.sh glob).
# This file DEFINES new helpers and is present-but-uncalled by every existing
# engine/CLI/driver path, so with it sourced the engine stays byte-identical to
# prior behavior. The `rehydrate` strategy is already a reserved alphabet slot in
# the integrated engine/ctx-route.sh; the routing wire-in (routing `rehydrate`
# on a refused resume behind SINGULAR_REHYDRATE=1, recording the manifest into the
# strategy event) and the l1-drive.sh injection hook are SEPARATE later slices and
# are OUT OF SCOPE here. SINGULAR_REHYDRATE gates that future wire-in, not this
# pure assembler.
#
#   singular_ctx_rehydrate_packet   <id>=<path> [<id>=<path> ...]
#   singular_ctx_rehydrate_manifest <id>=<path> [<id>=<path> ...]
#
# Both assemble a deterministic, section-capped, quarantine-aware view over a
# fixed set of durable artifact sources, each tagged with a source-class id
# (task-packet, implementer-capsule, reviewer-capsule, findings-ledger,
# assumptions-ledger, critique-record, decision-record):
#
#   - `..._packet`  prints the rehydration packet on stdout: one labeled section
#     per surviving source, `=== <id> ===` header then the artifact's text body,
#     each body truncated to at most SINGULAR_CONTEXT_SECTION_MAX_CHARS (default
#     4000, honoring the engine/lib.sh knob) with a stable truncation marker.
#   - `..._manifest` prints a deterministic JSON manifest on stdout: the INCLUDED
#     source ids together with the sha256 of each artifact's bytes ("which
#     artifacts, which hashes") for a later routing slice to embed in a strategy
#     event.
#
# Deterministic: identical artifact bytes yield byte-identical packet and
# byte-identical manifest across runs; sources are emitted in a fixed, documented
# order (the source-class order above), independent of argument or on-disk
# enumeration order.
#
# Quarantine-aware: each candidate is filtered through the integrated
# singular_ctx_artifact_exclude, so a `*.quarantined` source, or any source with a
# `.quarantined` sibling on disk, never reaches the packet or the manifest.
#
# Pure and READ-ONLY: it reads artifact paths and hashes their contents but never
# writes, renames, or deletes anything, and never exits non-zero on well-formed
# input. It confers NO independence: it neither marks a session as satisfying an
# independence-required step nor records any source as `authoritative` evidence
# (rehydrated sessions remain tainted, pinned in engine/ctx-route.sh).

# singular_ctx_rehydrate_packet <id>=<path> ...
singular_ctx_rehydrate_packet() {
  _singular_ctx_rehydrate_emit packet "$@"
}

# singular_ctx_rehydrate_manifest <id>=<path> ...
singular_ctx_rehydrate_manifest() {
  _singular_ctx_rehydrate_emit manifest "$@"
}

# Internal: collect surviving <id>\t<path> specs (quarantine-filtered) and hand
# them to the pure Python renderer for ordering, capping, hashing, and emission.
_singular_ctx_rehydrate_emit() {
  local mode="$1"; shift
  local spec id path survivor specs=""
  for spec in "$@"; do
    [[ "$spec" == *"="* ]] || continue
    id="${spec%%=*}"
    path="${spec#*=}"
    [[ -n "$id" && -n "$path" ]] || continue
    # Compose the integrated quarantine filter: a quarantined candidate (a
    # *.quarantined path or an original with a .quarantined sibling) yields no
    # survivor and is silently excluded from the packet and the manifest.
    survivor="$(singular_ctx_artifact_exclude "$path")"
    [[ -n "$survivor" ]] || continue
    specs+="$id"$'\t'"$path"$'\n'
  done
  _singular_ctx_rehydrate_py "$mode" "${SINGULAR_CONTEXT_SECTION_MAX_CHARS:-4000}" "$specs"
}

# Internal: the pure Python renderer. Takes mode, section cap, and the newline-
# delimited surviving <id>\t<path> specs on argv (stdin is the heredoc script).
# Reads each artifact READ-ONLY, orders by the fixed source-class rank, and emits
# either the labeled packet or the JSON manifest. No I/O beyond reading artifacts
# and writing stdout; no side effects.
_singular_ctx_rehydrate_py() {
  python3 - "$1" "$2" "$3" <<'PY'
import hashlib
import json
import sys

mode = sys.argv[1]
try:
    cap = int(sys.argv[2])
except (ValueError, IndexError):
    cap = 4000
specs = sys.argv[3] if len(sys.argv) > 3 else ""

# Fixed, documented emission order for the durable source classes. Ordering is by
# this rank (then id, then path) so output is independent of argument or on-disk
# order; unknown ids sort deterministically after the known classes.
RANK = {
    "task-packet": 0,
    "implementer-capsule": 1,
    "reviewer-capsule": 2,
    "findings-ledger": 3,
    "assumptions-ledger": 4,
    "critique-record": 5,
    "decision-record": 6,
}
TRUNC = "\n[... rehydration section truncated to fit the context budget ...]"


def section_cap(text):
    if len(text) <= cap:
        return text
    keep = max(0, cap - len(TRUNC))
    return text[:keep] + TRUNC


sources = []
for line in specs.splitlines():
    if "\t" not in line:
        continue
    sid, path = line.split("\t", 1)
    if not sid or not path:
        continue
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError:
        # A declared-but-missing/unreadable durable artifact contributes nothing;
        # stay pure and non-fatal on well-formed input.
        continue
    sources.append((sid, path, data))

sources.sort(key=lambda s: (RANK.get(s[0], len(RANK)), s[0], s[1]))

if mode == "manifest":
    obj = {
        "schema": "singular.orchestration.ctx-rehydrate-manifest.v0",
        "sources": [
            {"id": sid, "sha256": hashlib.sha256(data).hexdigest()}
            for sid, _path, data in sources
        ],
    }
    sys.stdout.write(json.dumps(obj, sort_keys=True, ensure_ascii=False))
    sys.stdout.write("\n")
else:
    parts = []
    for sid, _path, data in sources:
        parts.append("=== %s ===" % sid)
        parts.append(section_cap(data.decode("utf-8", "replace")))
    sys.stdout.write("\n".join(parts))
    sys.stdout.write("\n")
PY
}
