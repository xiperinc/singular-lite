#!/usr/bin/env bash
# Resolve graph-node provenance into contained source references for rehydration.

singular_ctx_rehydrate_subgraph_sources() {
  local src="${1-}"
  if [[ -n "$src" ]]; then
    _singular_ctx_rehydrate_subgraph_py <"$src"
  else
    _singular_ctx_rehydrate_subgraph_py
  fi
}

# Internal: the pure Python mapper. Reads canonical context-graph.v0 node records
# (JSONL) from stdin and writes one `<source-class-id>=<provenance.sourcePath>`
# spec per durable-class selected node, in INPUT order. The script is passed via
# `-c` (NOT a heredoc) so python3 stdin stays bound to the node-record stream. No
# I/O beyond reading stdin and writing stdout; no side effects.
_singular_ctx_rehydrate_subgraph_py() {
  python3 -c '
import json
import sys

# Node-type -> durable source-class id. Ids match the assembler vocabulary
# (RANK in engine/ctx-rehydrate.sh) exactly. capsule is resolved by role
# below (implementer-capsule / reviewer-capsule); node types absent from this
# map and absent from the capsule branch have no durable rehydration source
# class and emit nothing.
TYPE_CLASS = {
    "task": "task-packet",
    "finding": "findings-ledger",
    "assumption": "assumptions-ledger",
    "critique": "critique-record",
    "decision": "decision-record",
}
CAPSULE_ROLE_CLASS = {
    "implementer": "implementer-capsule",
    "reviewer": "reviewer-capsule",
}

out = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
    except ValueError:
        # A malformed line is not a canonical node record; stay pure and
        # non-fatal — contribute nothing.
        continue
    if not isinstance(rec, dict):
        continue
    # Only node records carry a durable source; edges and other kinds emit
    # nothing.
    if rec.get("kind") != "node":
        continue
    node_type = rec.get("type")
    if node_type == "capsule":
        role = ""
        attrs = rec.get("attributes")
        if isinstance(attrs, dict):
            role = str(attrs.get("role", ""))
        cls = CAPSULE_ROLE_CLASS.get(role)
    else:
        cls = TYPE_CLASS.get(node_type)
    if not cls:
        continue
    prov = rec.get("provenance")
    if not isinstance(prov, dict):
        continue
    path = prov.get("sourcePath")
    if not isinstance(path, str) or not path:
        continue
    out.append("%s=%s" % (cls, path))

if out:
    sys.stdout.write("\n".join(out))
    sys.stdout.write("\n")
'
}
