#!/usr/bin/env bash
# Assemble a bounded rehydration packet from selected graph nodes and their resolved sources.

singular_ctx_rehydrate_subgraph_packet() {
  _singular_ctx_rehydrate_subgraph_render packet
}

# singular_ctx_rehydrate_subgraph_manifest (specs on stdin)
singular_ctx_rehydrate_subgraph_manifest() {
  _singular_ctx_rehydrate_subgraph_render manifest
}

# Internal: read <id>=<path> specs from stdin IN ORDER, filter each through the
# integrated quarantine authority, and hand the surviving <id>\t<path> specs to
# the pure Python renderer for order-preserving capping, hashing, and emission.
_singular_ctx_rehydrate_subgraph_render() {
  local mode="$1"
  local spec id path survivor specs=""
  while IFS= read -r spec; do
    [[ "$spec" == *"="* ]] || continue
    id="${spec%%=*}"
    path="${spec#*=}"
    [[ -n "$id" && -n "$path" ]] || continue
    # Compose the single integrated quarantine filter: a quarantined candidate (a
    # *.quarantined path or an original with a .quarantined sibling) yields no
    # survivor and is silently excluded from the packet and the manifest.
    survivor="$(singular_ctx_artifact_exclude "$path")"
    [[ -n "$survivor" ]] || continue
    specs+="$id"$'\t'"$path"$'\n'
  done
  _singular_ctx_rehydrate_subgraph_render_py \
    "$mode" "${SINGULAR_CONTEXT_SECTION_MAX_CHARS:-4000}" "$specs"
}

# Internal: the pure Python renderer. Takes mode, section cap, and the newline-
# delimited surviving <id>\t<path> specs on argv (stdin is the heredoc script).
# Reads each artifact READ-ONLY and emits either the labeled packet or the JSON
# manifest, PRESERVING the input spec order (NO rank re-sort). Caps and manifest
# schema match the flat assembler exactly. No I/O beyond reading artifacts and
# writing stdout; no side effects.
_singular_ctx_rehydrate_subgraph_render_py() {
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

# Same stable truncation marker convention as the flat assembler
# (engine/ctx-rehydrate.sh); caps UNCHANGED.
TRUNC = "\n[... rehydration section truncated to fit the context budget ...]"


def section_cap(text):
    if len(text) <= cap:
        return text
    keep = max(0, cap - len(TRUNC))
    return text[:keep] + TRUNC


# PRESERVE input order — the selector's contradictions-first ordering. Unlike the
# flat assembler this does NOT sort by source-class rank; one durable source per
# selected node, so a class label may repeat (per-node sections, not per-class
# dedup).
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

# singular_ctx_rehydrate_subgraph_assemble <graphDir> <taskNodeId> <packet|manifest>
# Pipe the integrated read path end-to-end: select the subgraph -> resolve source
# specs -> render (slice 1), producing a contradictions-first, capped packet or
# its matching manifest directly from a graph dir + task node id. Pure read-only.
singular_ctx_rehydrate_subgraph_assemble() {
  local graph_dir="${1:-${SINGULAR_CTX_GRAPH_DIR:-.singular-state/graph}}"
  local task_node="${2:-}"
  local mode="${3:-packet}"
  case "$mode" in
    packet|manifest) ;;
    *) mode="packet" ;;
  esac
  singular_ctx_rehydrate_subgraph_select "$graph_dir" "$task_node" \
    | singular_ctx_rehydrate_subgraph_sources \
    | singular_ctx_rehydrate_subgraph_"$mode"
}
