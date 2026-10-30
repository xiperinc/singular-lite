#!/usr/bin/env bash
# Classify prior findings after an accepted-change recheck and record their dispositions.

singular_ctx_critic_recheck_classify() {
  local critique_record="${1:-}" recheck_output="${2:-}"
  python3 - "$critique_record" "$recheck_output" <<'PY' 2>/dev/null || true
import json, re, sys

crit_path, out_path = sys.argv[1], sys.argv[2]
strict = re.compile(r"^f-[0-9a-f]{12}$")
VALID = {"addressed", "survives", "obsolete"}

# --- Prior finding ids from the plan-critique record (authoritative universe). A
# missing / unparseable / schema-divergent record yields NO ids (no fabrication).
record_ids = set()
try:
    with open(crit_path, "r", encoding="utf-8") as f:
        doc = json.load(f)
    if isinstance(doc, dict) and doc.get("schema") == "singular.orchestration.plan-critique.v0":
        findings = doc.get("findings")
        if isinstance(findings, list):
            for it in findings:
                if isinstance(it, dict):
                    fid = it.get("id", "")
                    if isinstance(fid, str) and strict.match(fid):
                        record_ids.add(fid)
except Exception:
    pass

# --- The resumed critic's recheck self-report: per prior finding id, a status. A
# missing / unparseable output degrades to NO statuses -> every prior finding
# defaults to `survives` (fail-closed, no fabricated addressed/obsolete). Only a
# positively-parsed status in {addressed, survives, obsolete} for a PRIOR id is
# honored; an unknown/ambiguous status, or an id absent from the output, defaults
# to `survives`. A status for a non-prior id is ignored.
status_of = {}
try:
    with open(out_path, "r", encoding="utf-8") as f:
        rdoc = json.load(f)
    if isinstance(rdoc, dict):
        rf = rdoc.get("findings")
        if isinstance(rf, list):
            for it in rf:
                if not isinstance(it, dict):
                    continue
                fid = it.get("id", "")
                st = it.get("status", "")
                if (isinstance(fid, str) and strict.match(fid)
                        and isinstance(st, str) and st in VALID):
                    # First positively-established status wins (deterministic).
                    status_of.setdefault(fid, st)
except Exception:
    pass

out = []
for fid in sorted(record_ids):
    disp = status_of.get(fid, "survives")
    out.append("{}\t{}".format(fid, disp))
sys.stdout.write("\n".join(out))
if out:
    sys.stdout.write("\n")
PY
  return 0
}

# Records ONLY. Emits exactly one `ctx.critic_recheck` provenance event carrying
# node, runId, taskId, role=plan-critic, and the full id-sorted per-finding
# id->disposition set. Mutates nothing else.
singular_ctx_critic_recheck_record() {
  local node="${1:-}" run_id="${2:-}" task_id="${3:-}" \
        critique_record="${4:-}" recheck_output="${5:-}"

  # Classify (pure/read-only); feed the deterministic id-sorted dispositions into
  # the event payload verbatim.
  local classified
  classified="$(singular_ctx_critic_recheck_classify "$critique_record" "$recheck_output")"

  # Build the deterministic (id-sorted) disposition payload. python turns the
  # TAB-separated classifier lines into the structured id->disposition set.
  local event_json
  event_json="$(python3 - "$node" "$run_id" "$task_id" <<PY
import json, sys
node, run_id, task_id = sys.argv[1], sys.argv[2], sys.argv[3]
classified = """$classified"""
dispositions = []
for line in classified.splitlines():
    if not line.strip():
        continue
    parts = line.split("\t")
    if len(parts) != 2:
        continue
    dispositions.append({"id": parts[0], "disposition": parts[1]})
dispositions.sort(key=lambda x: x["id"])
print(json.dumps({
    "node": node,
    "runId": run_id,
    "taskId": task_id,
    "role": "plan-critic",
    "dispositions": dispositions,
}, separators=(",", ":")))
PY
)"

  # Exactly one ctx.critic_recheck provenance event. Records only — no lease, no
  # runner, no candidate promotion/quarantine, no accept/reject mutation.
  singular_append_event "ctx.critic_recheck" "per-finding critic recheck dispositions recorded" "$event_json"
  return 0
}
