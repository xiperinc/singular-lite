#!/usr/bin/env bash
# Assemble bounded context for a critic recheck of an accepted diff and its prior critique.

singular_ctx_critic_recheck_accepted_diff() {
  local base_ref="${1:-}" head_ref="${2:-}" worktree="${3:-.}"
  # Indeterminate/empty refs or a missing worktree -> empty output (fail-safe).
  [[ -n "$base_ref" && -n "$head_ref" ]] || return 0
  [[ -d "$worktree" ]] || return 0
  # Not a git repo -> empty output.
  git -C "$worktree" rev-parse --git-dir >/dev/null 2>&1 || return 0
  # Both refs must resolve to commits, else empty output (never a crash).
  git -C "$worktree" rev-parse --verify --quiet "${base_ref}^{commit}" >/dev/null 2>&1 || return 0
  git -C "$worktree" rev-parse --verify --quiet "${head_ref}^{commit}" >/dev/null 2>&1 || return 0
  # Read-only diff. `git diff <base> <head>` inspects committed trees only.
  git -C "$worktree" diff "$base_ref" "$head_ref" 2>/dev/null || true
  return 0
}

# Pure assembler: compose the read-only recheck context into <out_file>. Reads the
# prior plan-critique.v0 record and the accepted-diff file; writes ONLY the named output
# and mutates nothing else. Deterministic: findings emit id-sorted, so the output is
# byte-stable across runs for a fixed input set. A missing/unparseable record degrades
# to an empty checklist and a missing/empty diff file to an empty diff section (never a
# crash, never a fabricated finding).
singular_ctx_critic_recheck_context() {
  local node="${1:-}" task_id="${2:-}" prior_record="${3:-}" \
        diff_file="${4:-}" out_file="${5:-}"
  [[ -n "$out_file" ]] || return 2

  mkdir -p "$(dirname "$out_file")"

  {
    printf '# Critic Recheck Context: %s\n\n' "$node"
    printf 'Task: %s\n\n' "$task_id"
    printf 'Read-only post-acceptance recheck context for the resumed plan critic (skeptic).\n'
    printf 'For each of your prior concerns, answer: addressed | survives | obsolete.\n\n'

    printf '## Prior Findings Checklist\n\n'
    # Emit the id-sorted per-finding checklist from the plan-critique.v0 record. A
    # missing / unparseable / schema-divergent record yields NO findings (no
    # fabrication); the section header above still frames a well-formed context.
    python3 - "$prior_record" <<'PY' 2>/dev/null || true
import json, re, sys

path = sys.argv[1]
strict = re.compile(r"^f-[0-9a-f]{12}$")

def as_str(v):
    return v if isinstance(v, str) else ""

findings = []
try:
    with open(path, "r", encoding="utf-8") as f:
        doc = json.load(f)
    if isinstance(doc, dict) and doc.get("schema") == "singular.orchestration.plan-critique.v0":
        fl = doc.get("findings")
        if isinstance(fl, list):
            for it in fl:
                if not isinstance(it, dict):
                    continue
                fid = it.get("id", "")
                if isinstance(fid, str) and strict.match(fid):
                    findings.append({
                        "id": fid,
                        "severity": as_str(it.get("severity", "")),
                        "claim": as_str(it.get("claim", "")),
                        "evidence": as_str(it.get("evidence", "")),
                    })
except Exception:
    findings = []

findings.sort(key=lambda x: x["id"])
out = []
for it in findings:
    out.append("### {}".format(it["id"]))
    out.append("- severity: {}".format(it["severity"]))
    out.append("- claim: {}".format(it["claim"]))
    out.append("- evidence: {}".format(it["evidence"]))
    out.append("- recheck: is this prior concern addressed | survives | obsolete?")
    out.append("")
sys.stdout.write("\n".join(out))
if out:
    sys.stdout.write("\n")
PY

    printf '\n## Accepted Diff\n\n'
    # Embed the accepted-diff content. A missing/empty file degrades to an empty diff
    # section (no fabricated diff content).
    if [[ -n "$diff_file" && -f "$diff_file" ]]; then
      cat "$diff_file"
      printf '\n'
    fi
  } > "$out_file"

  return 0
}
