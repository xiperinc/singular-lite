#!/usr/bin/env bash
# Resolve a task's unique owning DAG node from durable planner events. Ambiguous or absent
# associations yield no node; the resolver is deterministic and read-only.

singular_ctx_rehydrate_authored_node() {
  local task_id="${1:-}" worktree="${2:-.}"
  # Indeterminate/empty task -> empty output (fail-safe).
  [[ -n "$task_id" ]] || { printf '%s' ""; return 0; }
  local events_file="${SINGULAR_EVENTS_FILE:-}"
  [[ -n "$events_file" && -f "$events_file" ]] || { printf '%s' ""; return 0; }

  # Scan the NDJSON control-state log read-only. Collect the DISTINCT non-empty node
  # values across every event carrying data.taskId == <task_id>. Exactly one distinct
  # node -> that node; zero or more-than-one (ambiguous) -> empty. A parse failure on
  # any single line is skipped (never fatal). Prints nothing but the resolved node.
  python3 - "$events_file" "$task_id" <<'PY' 2>/dev/null || true
import json, sys
path, task_id = sys.argv[1], sys.argv[2]
nodes = set()
try:
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except Exception:
                continue
            if not isinstance(ev, dict):
                continue
            data = ev.get("data")
            if not isinstance(data, dict):
                continue
            if str(data.get("taskId", "")) != task_id:
                continue
            node = data.get("node", "")
            if isinstance(node, str) and node:
                nodes.add(node)
except Exception:
    nodes = set()
# Fail safe: only an unambiguous single association resolves.
if len(nodes) == 1:
    sys.stdout.write(next(iter(nodes)))
PY
  return 0
}
