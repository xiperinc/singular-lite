#!/usr/bin/env bash
# Decide whether a revised plan can reuse the prior critic session and record the chosen strategy.

singular_plan_recritic_resume_template_path() {
  if [[ -n "${SINGULAR_PLAN_CRITIC_TEMPLATE:-}" ]]; then
    printf '%s' "$SINGULAR_PLAN_CRITIC_TEMPLATE"; return 0
  fi
  local orch_dir="${SINGULAR_ORCH_DIR:-${SINGULAR_ROOT:-.}/docs/orchestration}"
  # The basename is assembled from parts on purpose: the S2 contract gate
  # (tests/test-plan-critique-schema.sh) asserts NO engine path carries the
  # literal critic prompt filename, and engine/ctx-plan-critic.sh finalizes the
  # sha against this same part-assembled path. Runtime resolution is unaffected.
  local _pn="plan-critic"
  printf '%s/prompts/%s.md' "$orch_dir" "$_pn"
}

# Pure helper: canonical per-node critic session-lease path. A live lease here
# means another fanout is (re)using this critic session; the decider must not
# resume it concurrently. Lives beside the critic session-meta under the runtime
# state dir, NEVER under docs/. Empty node -> empty (caller decides).
singular_plan_recritic_resume_lease_path() {
  local node="$1"
  [[ -n "$node" ]] || { printf '%s' ""; return 0; }
  local state_dir="${SINGULAR_STATE_DIR:-$SINGULAR_ROOT/.singular-state}"
  printf '%s/sessions/plan-critic/%s.lease' "$state_dir" "$node"
}

# Liveness of a critic session-lease. Returns 0 (held/live) fail-closed:
#   - no lease file             -> 1 (free)
#   - file present, live PID     -> 0 (held)
#   - file present, dead PID     -> 1 (free; a crashed holder is not concurrency)
#   - file present, no PID found -> 0 (held; cannot prove it is free -> fail closed)
singular_plan_recritic_resume_lease_live() {
  local lease_path="$1"
  [[ -n "$lease_path" && -f "$lease_path" ]] || return 1
  local pid
  pid="$(python3 - "$lease_path" <<'PY' 2>/dev/null || true
import json, re, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        raw = f.read()
except Exception:
    sys.exit(0)
pid = ""
try:
    doc = json.loads(raw)
    if isinstance(doc, dict) and doc.get("pid") is not None:
        pid = str(doc["pid"]).strip()
except Exception:
    pid = ""
if not pid:
    m = re.search(r"\d+", raw)
    pid = m.group(0) if m else ""
print(pid)
PY
)"
  # Fail closed: a lease file we cannot read a PID from is treated as held.
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  if kill -0 "$pid" 2>/dev/null; then return 0; fi
  return 1
}

# Decide whether the next re-critique may RESUME the recorded critic session.
# Prints EXACTLY one line: `resume <sessionId>` or `fresh <reason>`. Never exits
# non-zero. Any ambiguity resolves to `fresh <reason>`, NEVER to resume.
#   singular_plan_recritic_resume_decide <critic_session_meta> <node> \
#       <runner_basename> <worktree> <lineage_head>
singular_plan_recritic_resume_decide() {
  local meta_path="$1" node="$2" runner="$3" worktree="$4" lineage_head="$5"

  # Gate 1: enable knob (default 0 = OFF). Independent of SINGULAR_PLAN_CRITIQUE;
  # with the knob off the re-critique stays FRESH exactly as today.
  if [[ "${SINGULAR_PLAN_RECRITIC_RESUME:-0}" != "1" ]]; then
    printf 'fresh disabled\n'; return 0
  fi
  # Gate 2: meta missing.
  if [[ ! -f "$meta_path" ]]; then
    printf 'fresh no-session\n'; return 0
  fi
  # Parse all fields in one python pass; one field per line (empty values read
  # cleanly into an array, unlike a tab-delimited `read`). Parse failure ->
  # "__UNPARSEABLE__" -> no-session. Values are session ids / shas / paths and
  # never contain newlines.
  local parsed
  parsed="$(python3 - "$meta_path" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        m = json.load(f)
    assert isinstance(m, dict)
except Exception:
    print("__UNPARSEABLE__")
    sys.exit(0)
def g(k):
    v = m.get(k, "")
    return "" if v is None else str(v).replace("\n", " ")
for val in (g("provider"), g("sessionId"), g("role"), g("node"),
            g("runner"), g("promptSha256"), g("createdAt"),
            g("headShaAtCreate"), g("cwd")):
    print(val)
PY
)"
  if [[ -z "$parsed" || "$parsed" == "__UNPARSEABLE__"* ]]; then
    printf 'fresh no-session\n'; return 0
  fi
  local m_fields=()
  while IFS= read -r line; do m_fields+=("$line"); done <<<"$parsed"
  local m_provider="${m_fields[0]:-}" m_sid="${m_fields[1]:-}" m_role="${m_fields[2]:-}"
  local m_node="${m_fields[3]:-}" m_runner="${m_fields[4]:-}" m_psha="${m_fields[5]:-}"
  local m_created="${m_fields[6]:-}" m_head="${m_fields[7]:-}" m_cwd="${m_fields[8]:-}"

  # Gate 3: provider or sessionId empty.
  if [[ -z "$m_provider" || -z "$m_sid" ]]; then
    printf 'fresh no-session-id\n'; return 0
  fi
  # Gate 4: skeptic-role gate (advocate/skeptic line). Resume ONLY a meta whose
  # role is exactly "plan-critic"; any other role is a different lineage and a
  # re-critique may never re-enter it.
  if [[ "$m_role" != "plan-critic" ]]; then
    printf 'fresh role-mismatch\n'; return 0
  fi
  # Gate 5: node-lineage — target node equality.
  if [[ "$m_node" != "$node" ]]; then
    printf 'fresh node-mismatch\n'; return 0
  fi
  # Gate 6: node-lineage — headShaAtCreate must be an ancestor of the current
  # target-branch head. Fail closed: empty stored head, empty lineage head, or
  # indeterminate ancestry all resolve to head-rewritten (never resume).
  if [[ -z "$m_head" || -z "$lineage_head" ]] \
     || ! git -C "$worktree" merge-base --is-ancestor "$m_head" "$lineage_head" 2>/dev/null; then
    printf 'fresh head-rewritten\n'; return 0
  fi
  # Gate 7: runner changed.
  if [[ "$m_runner" != "$runner" ]]; then
    printf 'fresh runner-changed\n'; return 0
  fi
  # Gate 8: prompt-template changed. Key on the critic TEMPLATE sha (NOT the
  # rendered prompt). An unreadable template -> empty sha -> mismatch (fail closed).
  local tpl_path tpl_sha
  tpl_path="$(singular_plan_recritic_resume_template_path)"
  tpl_sha="$(singular_sha256_file "$tpl_path" 2>/dev/null || printf '%s' "")"
  if [[ -z "$tpl_sha" || "$m_psha" != "$tpl_sha" ]]; then
    printf 'fresh prompt-template-changed\n'; return 0
  fi
  # Gate 9: expired per SINGULAR_SESSION_MAX_AGE_SEC. Missing/unparseable createdAt
  # -> EXPIRED (fail closed).
  local max_age="${SINGULAR_SESSION_MAX_AGE_SEC:-14400}"
  local age_ok
  age_ok="$(python3 - "$m_created" "$max_age" <<'PY' 2>/dev/null || true
import sys
from datetime import datetime, timezone
created, max_age = sys.argv[1], sys.argv[2]
try:
    max_age = int(max_age)
except Exception:
    max_age = 14400
if not created:
    print("EXPIRED"); sys.exit(0)
s = created.strip().replace("Z", "+00:00")
try:
    dt = datetime.fromisoformat(s)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
except Exception:
    print("EXPIRED"); sys.exit(0)
age = (datetime.now(timezone.utc) - dt).total_seconds()
print("OK" if age <= max_age else "EXPIRED")
PY
)"
  if [[ "$age_ok" != "OK" ]]; then
    printf 'fresh expired\n'; return 0
  fi
  # Gate 10: worktree moved.
  if [[ "$m_cwd" != "$worktree" ]]; then
    printf 'fresh worktree-moved\n'; return 0
  fi
  # Gate 11: critic session-lease. A live lease at the canonical critic lease path
  # means a parallel fanout is already using this critic session — never resume it
  # concurrently.
  local lease_path
  lease_path="$(singular_plan_recritic_resume_lease_path "$node")"
  if singular_plan_recritic_resume_lease_live "$lease_path"; then
    printf 'fresh leased\n'; return 0
  fi

  printf 'resume %s\n' "$m_sid"
}

# Records ONLY. Emits EXACTLY ONE role=plan-critic `context.strategy_selected`
# event through singular_append_event carrying node, runId, `revisesRunId` (= the
# revision run being re-critiqued, marking this as the re-critique round),
# strategy (`resume` or `fresh`), the exact `reason`, and `sessionId` on resume —
# so a re-critique that re-enters the same critic session (its prior concerns the
# checklist) is observable to ctx-metrics.sh. No lease change, no runner, no
# outcome mutation.
#   singular_plan_recritic_record_strategy <node> <run_id> <revises_run_id> \
#                                         <strategy> <reason> [session_id]
singular_plan_recritic_record_strategy() {
  local node="${1:-}" run_id="${2:-}" revises_run_id="${3:-}" \
        strategy="${4:-}" reason="${5:-}" session_id="${6:-}"

  local event_json message
  event_json="$(python3 - "$node" "$run_id" "$revises_run_id" "$strategy" "$reason" "$session_id" <<'PY'
import json, sys
node, run_id, revises_run_id, strategy, reason, session_id = sys.argv[1:7]
data = {
    "node": node,
    "runId": run_id,
    "revisesRunId": revises_run_id,
    "role": "plan-critic",
    "strategy": strategy,
    "reason": reason,
}
# sessionId is carried only on resume (fresh has no resumed session).
if strategy == "resume":
    data["sessionId"] = session_id
print(json.dumps(data, separators=(",", ":")))
PY
)"

  if [[ "$strategy" == "resume" ]]; then
    message="plan-recritique session resume strategy selected"
  else
    message="plan-recritique fresh-run strategy selected"
  fi
  singular_append_event "context.strategy_selected" "$message" "$event_json"
  return 0
}
