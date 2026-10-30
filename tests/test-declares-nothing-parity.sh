#!/usr/bin/env bash
set -euo pipefail

# S1.1-6: one ordinary accepted drive of the synthetic-widget project, declaring
# no proof or verification contract. Golden files come from v0.23.7 (2a13ebb).
# Reuses the acceptance-defaults fixture's runner and sandbox setup.
# Normalisations (only in the captured prompt bytes):
# - disposable project/scratch and engine checkout absolute paths;
# - resolved Bash executable path, commandSha256 and evidenceSourceCommandIdentity;
# - the generated run ID and base/head commit IDs (commit timestamps vary);
# - audit-verification recordedAt, evidenceBindingSha256, requestIdentity,
#   verificationResultBindingSha256, and the two delivered artifact SHA256s
#   (their inputs include the above paths/IDs/times).
# In run-file names, the SHA256 in delivery-prompt-<SHA256>.md is normalised;
# its raw digest must still match the file bytes. No other digests are erased.
# File names are sorted relative paths; event kinds retain order and duplicates.
# Prompts are the actual --prompt-file bytes received by each stub runner.
# No snapshot update switch: the committed expectations are never rewritten.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$ROOT/tests/fixtures/declares-nothing-parity"
while IFS= read -r key; do unset "$key"; done < <(compgen -v | grep '^SINGULAR_' || true)
unset RAILS_NONCE RAILS_VERDICT_FILE
scratch="$(mktemp -d "${TMPDIR:-/tmp}/parity.XXXXXX")"
trap 'chmod -R u+w "$scratch" 2>/dev/null || true; rm -rf "$scratch"' EXIT
export SINGULAR_ENGINE_HOME="$ROOT" SINGULAR_PUSH=0
export SINGULAR_HOME="$scratch/machine" PYTHONDONTWRITEBYTECODE=1
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=fixture GIT_COMMITTER_NAME=fixture
export GIT_AUTHOR_EMAIL=fixture GIT_COMMITTER_EMAIL=fixture
export TMPDIR="$scratch/tmp"
export SINGULAR_ROOT="$scratch/synthetic-widget"
export SINGULAR_STATE_DIR="$SINGULAR_ROOT/.singular-state"
export SINGULAR_ORCH_DIR="$SINGULAR_ROOT/docs/orchestration"
export SINGULAR_TASKS_DIR="$SINGULAR_ORCH_DIR/tasks"
export SINGULAR_TARGET_BRANCH=target
export SINGULAR_RUNNER="$scratch/runner.py"
export PARITY_CAPTURES="$scratch/captures"
mkdir -p "$TMPDIR" "$SINGULAR_ROOT" "$SINGULAR_ORCH_DIR/prompts"
cp -R "$fixture/project/." "$SINGULAR_ROOT/"
cp "$fixture/runner.py" "$SINGULAR_RUNNER"
chmod +x "$SINGULAR_RUNNER"
cp "$ROOT/templates/prompts/"{l2-test-first-developer,auditor,decider}.md "$SINGULAR_ORCH_DIR/prompts/"
git -C "$SINGULAR_ROOT" init -q
git -C "$SINGULAR_ROOT" symbolic-ref HEAD refs/heads/target
git -C "$SINGULAR_ROOT" add .
git -C "$SINGULAR_ROOT" -c commit.gpgsign=false commit -qm initial
[[ -z "$(git -C "$SINGULAR_ROOT" remote)" ]]

if ! (cd "$SINGULAR_ROOT" && bash "$ROOT/engine/l1-drive.sh" TASK-0001) >"$scratch/drive.log" 2>&1; then
  echo 'FAIL: ordinary parity drive did not succeed' >&2
  tail -15 "$scratch/drive.log" >&2
  exit 1
fi
python3 "$fixture/compare.py" "$ROOT" "$scratch" "$fixture/expected"
echo 'PASS: declares-nothing run files, ordered events, and worker/auditor prompt bytes'
