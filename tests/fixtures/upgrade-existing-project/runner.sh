#!/usr/bin/env bash
# A provider substitute only: the real driver, gates, schemas and lifecycle run.
set -euo pipefail
level= worktree= output=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --level) level="$2"; shift 2 ;;
    -C|--worktree) worktree="$2"; shift 2 ;;
    --output-last-message) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$output" ]]
[[ -z "${RAILS_NONCE:-}" && -z "${RAILS_VERDICT_FILE:-}" ]]
if [[ "$level" == l2 ]]; then
  cd "$worktree"
  mkdir -p .singular-evidence
  if bash check.sh > .singular-evidence/red.log 2>&1; then
    echo 'fixture expected the existing task gate to start red' >&2
    exit 1
  fi
  printf 'continued\n' > src/core/result.txt
  bash check.sh > .singular-evidence/green.log 2>&1
  cat > "$output" <<'JSON'
{"schema":"singular.orchestration.state-packet.v0","packetId":"fixture","runId":"fixture","taskId":"TASK-0001","area":"core","role":"l2-developer","status":"needs-review","baseRef":"agent/integration","branch":"agent/core/TASK-0001-upgrade","headSha":"0","workspace":"fixture","ownedFiles":["src/core/result.txt"],"changedFiles":["src/core/result.txt"],"commands":[{"cmd":"bash check.sh","exitCode":0}],"tests":[],"evidence":[],"blockers":[],"nextAction":"await audit","createdAt":"2026-10-12T00:00:00Z"}
JSON
elif [[ "$level" == readonly ]]; then
  python3 - "$output" <<'PY'
import json
from pathlib import Path
import sys
output = Path(sys.argv[1])
packet = json.loads((output.parent / "packet.json").read_text())
output.write_text(json.dumps({
    "schema": "singular.orchestration.audit-verdict.v0",
    "taskId": packet["taskId"], "runId": packet["runId"],
    "branch": packet["branch"], "verdict": "accepted",
    "evidenceReviewed": [], "commandsRun": [], "findings": [],
    "requiredFixes": [], "findingsStatus": {}, "rationale": "Fixture audit"
}) + "\n")
PY
else
  echo 'unexpected fixture provider level' >&2
  exit 1
fi
