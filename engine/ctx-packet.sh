#!/usr/bin/env bash
# Context-packet contract parser (stage S4-context-packets, node
# context-packet-contract). Sourced exactly once by the context module loader
# block in lib.sh (it matches the ctx-*.sh glob). This file defines a PURE helper
# and is present-but-uncalled by every existing engine/CLI/driver path, so with
# it sourced the engine stays byte-identical to prior behavior.
#
# The context packet is an OPTIONAL, additive `## Context packet` block in a task
# markdown carrying up to four subsections — Decisions, Assumptions, Rejected
# alternatives, Inspected symbols. The block and every subsection are optional and
# parsed tolerantly: a task with no block, or with only some subsections, stays
# valid forever, so every existing TEMPLATE-based task keeps parsing.
#
# Assumption entries follow the grammar: `- [open|validated|violated] <claim> — <basis>`.

# singular_ctx_packet_json <task-file>
#
# Reads <task-file> STRICTLY READ-ONLY and prints normalized JSON on stdout:
#   - well-formed block -> stable object with sorted keys and deterministic
#     ordering:
#       {"schema":"singular.orchestration.ctx-packet.v0","decisions":[...],
#        "assumptions":[{"status":...,"claim":...,"basis":...},...],
#        "rejectedAlternatives":[...],"inspectedSymbols":[...]}
#   - NO `## Context packet` block -> exactly `{}`
#   - block present but malformed (an assumption entry not matching the grammar)
#     -> fails closed to `{}` AND appends exactly one `ctx.packet_malformed`
#        warning event via singular_append_event (its only side effect; the task
#        file itself is never touched).
singular_ctx_packet_json() {
  local task_file="$1"
  local out rc=0
  out="$(singular_ctx_packet_json_py "$task_file")" || rc=$?
  printf '%s\n' "$out"
  if [[ "$rc" -eq 3 ]]; then
    singular_append_event "ctx.packet_malformed" \
      "context packet block malformed; failed closed to {}" \
      "{\"task\":\"$task_file\"}"
  fi
  return 0
}

# Internal: the pure Python parser. Prints normalized JSON (or `{}`) and signals a
# malformed block with exit code 3 (stdout is still `{}`) so the shell wrapper can
# append the single warning event. No side effects of its own.
singular_ctx_packet_json_py() {
  python3 - "$1" <<'PY'
import json, re, sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    lines = f.read().splitlines()

# Locate the OPTIONAL `## Context packet` block. Absent -> exactly {}.
start = None
for i, ln in enumerate(lines):
    if ln.strip() == "## Context packet":
        start = i
        break
if start is None:
    sys.stdout.write("{}")
    sys.exit(0)

# Body runs until the next level-2 heading (or EOF).
body = []
for ln in lines[start + 1:]:
    if re.match(r'^##\s', ln) or ln.strip() == "##":
        break
    body.append(ln)

# Split the body into subsections keyed by their `### <name>` heading. Unknown
# subsections are collected but simply ignored below (tolerant parsing).
sections = {}
cur = None
for ln in body:
    m = re.match(r'^###\s+(.*\S)\s*$', ln)
    if m:
        cur = m.group(1).strip().lower()
        sections.setdefault(cur, [])
        continue
    if cur is not None:
        sections[cur].append(ln)

def list_items(name):
    items = []
    for ln in sections.get(name, []):
        m = re.match(r'^\s*[-*]\s+(.*\S)\s*$', ln)
        if m:
            items.append(m.group(1).strip())
    return items

assump_re = re.compile(r'^\[(open|validated|violated)\]\s+(.+?)\s+—\s+(.+)$')
assumptions = []
for item in list_items("assumptions"):
    m = assump_re.match(item)
    if not m:
        # Fail closed: any assumption entry off-grammar voids the whole packet.
        sys.stdout.write("{}")
        sys.exit(3)
    assumptions.append({
        "status": m.group(1),
        "claim": m.group(2).strip(),
        "basis": m.group(3).strip(),
    })

obj = {
    "schema": "singular.orchestration.ctx-packet.v0",
    "decisions": list_items("decisions"),
    "assumptions": assumptions,
    "rejectedAlternatives": list_items("rejected alternatives"),
    "inspectedSymbols": list_items("inspected symbols"),
}
sys.stdout.write(json.dumps(obj, sort_keys=True, ensure_ascii=False))
PY
}
