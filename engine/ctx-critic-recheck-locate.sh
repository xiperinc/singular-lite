#!/usr/bin/env bash
# Locate the owning plan node and prior critique from durable task and session records.

singular_ctx_critic_recheck_locate_record_path() {
  local node="$1"
  [[ -n "$node" ]] || { printf '%s' ""; return 0; }
  local record_dir="${SINGULAR_CRITIC_RECHECK_RECORD_DIR:-${SINGULAR_STATE_DIR:-$SINGULAR_ROOT/.singular-state}/critique}"
  printf '%s/%s/plan-critique.json' "$record_dir" "$node"
}

# Resolve the executable DAG node owning an accepted task's critiqued batch from the
# durable control-state event log. Pure/read-only; prints the node when unambiguous,
# else empty. Never exits non-zero. See header for the contract.
#   singular_ctx_critic_recheck_locate_node <task_id> [worktree]
singular_ctx_critic_recheck_locate_node() {
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

# Resolve the path to the prior plan-critique.v0 record for <node>. Pure/read-only;
# prints the path only when a candidate exists AND parses as a
# singular.orchestration.plan-critique.v0 record whose node matches <node> and whose
# batch included <task_id> (or, when <task_id> is empty, node-only). Else empty. Never
# exits non-zero. See header for the contract.
#   singular_ctx_critic_recheck_locate_record <node> <task_id> [worktree]
singular_ctx_critic_recheck_locate_record() {
  local node="${1:-}" task_id="${2:-}" worktree="${3:-.}"
  # Indeterminate/empty node -> empty output (fail-safe).
  [[ -n "$node" ]] || { printf '%s' ""; return 0; }

  # Candidate paths, in deterministic preference order:
  #   1. the durable per-node archive convention;
  #   2. every per-run stage-dir record for this node (<runs>/*/l1-staging/<node>/
  #      plan-critique.json), sorted for stability.
  local candidates=()
  local durable
  durable="$(singular_ctx_critic_recheck_locate_record_path "$node")"
  [[ -n "$durable" ]] && candidates+=("$durable")

  local runs_dir="${SINGULAR_RUNS_DIR:-${SINGULAR_STATE_DIR:-$SINGULAR_ROOT/.singular-state}/runs}"
  if [[ -d "$runs_dir" ]]; then
    local staged
    while IFS= read -r staged; do
      [[ -n "$staged" ]] && candidates+=("$staged")
    done < <(find "$runs_dir" -type f -path "*/l1-staging/$node/plan-critique.json" 2>/dev/null | sort)
  fi

  local cand
  for cand in "${candidates[@]}"; do
    [[ -f "$cand" ]] || continue
    # Validate read-only: parses, schema matches, node matches, batch includes task
    # (unless task is empty -> node-only). Any failure -> skip (never a crash, never a
    # fabricated path). Exit 0 = valid; prints nothing.
    if python3 - "$cand" "$node" "$task_id" <<'PY' 2>/dev/null
import json, sys
path, node, task_id = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path, "r", encoding="utf-8") as f:
        doc = json.load(f)
except Exception:
    sys.exit(1)
if not isinstance(doc, dict):
    sys.exit(1)
if doc.get("schema") != "singular.orchestration.plan-critique.v0":
    sys.exit(1)
if str(doc.get("node", "")) != node:
    sys.exit(1)
if task_id:
    batch = doc.get("batchTaskIds")
    if not isinstance(batch, list) or task_id not in [str(x) for x in batch]:
        sys.exit(1)
sys.exit(0)
PY
    then
      printf '%s' "$cand"
      return 0
    fi
  done

  printf '%s' ""
  return 0
}
