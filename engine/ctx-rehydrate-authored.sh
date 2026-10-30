#!/usr/bin/env bash
# ctx-rehydrate-authored.sh — pure, read-only authored-knowledge manifest
# selector (stage S5-routing, node `rehydrate-path`, layer engine_runtime;
# singular-brain integration point 3). Sourced exactly once by the
# context module loader block in lib.sh (it matches the ctx-*.sh glob). This
# file DEFINES new functions only and is present-but-uncalled by every existing
# engine/CLI/driver path, so with it sourced the engine stays byte-identical to
# prior behavior.
#
# This is the FIRST slice of the explicitly-OPTIONAL authored-knowledge
# deliverable. It parses a FIXTURE authored-knowledge manifest JSON and selects
# the injectable entries; it does NOT yet wire into singular.config.json or the
# packet assembler (those are later slices). SINGULAR_CTX_MANIFEST (default 0)
# gates that future wire-in, NOT this pure leaf. The JSON contract is the whole
# interface: it takes NO dependency on any singular-brain runtime.
#
#   singular_ctx_rehydrate_authored_select <manifest-json-path>
#
# Reads a machine-readable authored-knowledge manifest of the form
#   { "entries": [ { "id", <"body"|"path">, "load-when":[...], "freshness",
#                    "description_unverified"? }, ... ] }
# and prints, one JSON object per line, the SELECTED injectable entries under the
# AUTHORED-KNOWLEDGE class rules:
#
#   - Each surviving entry is emitted with its id and tagged
#     "class":"authored-knowledge" — human-curated content, DISTINCT from durable
#     host-verified artifacts AND from model-authored (tainted) records. It is
#     NEVER marked authoritative: every emitted object carries
#     "authoritative": false and no host-verified / tainted marker.
#   - An entry flagged `description_unverified` is NEVER emitted as current: it is
#     skipped, so it can never be treated as current or authoritative.
#   - A path-backed entry is filtered through the integrated
#     singular_ctx_artifact_exclude, so a quarantined path (a `*.quarantined` path,
#     or an original whose `.quarantined` sibling exists on disk) never survives.
#     A single quarantine authority is thereby preserved.
#   - Output is deterministic: entries are emitted in a fixed id-sorted order, so
#     identical manifest bytes yield byte-identical output.
#
# The emission form is suitable for a LATER slice to ingest into the rehydration
# packet and to record the injected entry ids in the packet manifest like any
# other source.
#
# Pure and READ-ONLY: it reads the manifest (and, for the quarantine check, tests
# for `.quarantined` siblings) but never writes, renames, or deletes anything;
# appends no events; and never exits non-zero on well-formed input. A malformed
# or absent manifest yields an empty selection (fail-soft).

# singular_ctx_rehydrate_authored_select <manifest-json-path>
singular_ctx_rehydrate_authored_select() {
  local manifest="${1-}"
  # Absent / unreadable manifest -> empty selection, non-fatal (fail-soft).
  [[ -n "$manifest" && -f "$manifest" ]] || return 0

  # Pass 1: extract the path-backed entries' candidate paths (one per line, in
  # original manifest order). A malformed manifest yields no paths.
  local paths survivors=""
  paths="$(_singular_ctx_authored_paths "$manifest")" || return 0

  # Compose the integrated quarantine authority: a quarantined candidate never
  # survives, so its authored-knowledge entry is dropped from the selection.
  if [[ -n "$paths" ]]; then
    survivors="$(printf '%s\n' "$paths" | singular_ctx_artifact_exclude)"
  fi

  # Pass 2: emit the deterministic, id-sorted authored-knowledge selection,
  # skipping description_unverified entries and quarantined path entries (a path
  # not among the survivors).
  _singular_ctx_authored_emit "$manifest" "$survivors"
}

# Internal: print the path of every path-backed entry (one per line, original
# order). Read-only; empty and exit 0 on malformed/absent manifest.
_singular_ctx_authored_paths() {
  python3 - "$1" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        obj = json.load(fh)
except (OSError, ValueError):
    sys.exit(0)

entries = obj.get("entries") if isinstance(obj, dict) else None
if not isinstance(entries, list):
    sys.exit(0)

for entry in entries:
    if not isinstance(entry, dict):
        continue
    path = entry.get("path")
    if isinstance(path, str) and path:
        sys.stdout.write(path + "\n")
PY
}

# Internal: the pure JSONL renderer. argv: manifest path, then the newline-
# delimited set of quarantine-surviving paths. Reads the manifest READ-ONLY,
# applies the authored-knowledge class rules, and emits one JSON object per
# selected entry in a fixed id-sorted order. No side effects.
_singular_ctx_authored_emit() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        obj = json.load(fh)
except (OSError, ValueError):
    # Malformed / unreadable manifest -> empty selection (fail-soft).
    sys.exit(0)

survivors = set()
for line in (sys.argv[2] if len(sys.argv) > 2 else "").splitlines():
    if line:
        survivors.add(line)

entries = obj.get("entries") if isinstance(obj, dict) else None
if not isinstance(entries, list):
    sys.exit(0)

selected = []
for idx, entry in enumerate(entries):
    if not isinstance(entry, dict):
        continue
    sid = entry.get("id")
    if not isinstance(sid, str) or not sid:
        continue
    # description_unverified entries are NEVER emitted as current: skip them so
    # they can never be treated as current or authoritative.
    if entry.get("description_unverified"):
        continue

    path = entry.get("path")
    body = entry.get("body")
    rec = {
        # AUTHORED-KNOWLEDGE class marker — human-curated content, distinct from
        # durable host-verified artifacts AND from model-authored (tainted)
        # records, and NEVER authoritative.
        "class": "authored-knowledge",
        "authoritative": False,
        "id": sid,
    }
    if isinstance(path, str) and path:
        # Quarantined path-backed entries were filtered out by the integrated
        # singular_ctx_artifact_exclude; a path not among survivors is dropped.
        if path not in survivors:
            continue
        rec["source"] = "path"
        rec["path"] = path
    elif isinstance(body, str) and body:
        rec["source"] = "body"
        rec["body"] = body
    else:
        # No usable content -> nothing to inject.
        continue

    lw = entry.get("load-when")
    rec["load-when"] = lw if isinstance(lw, list) else []
    fresh = entry.get("freshness")
    rec["freshness"] = fresh if isinstance(fresh, str) else ""

    selected.append(rec)

# Deterministic, fixed order: sort by id (then original index for stability).
selected.sort(key=lambda r: r["id"])
for rec in selected:
    sys.stdout.write(json.dumps(rec, sort_keys=True, ensure_ascii=False))
    sys.stdout.write("\n")
PY
}
