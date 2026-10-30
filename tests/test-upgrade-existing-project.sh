#!/usr/bin/env bash
upgrade_nonce="${RAILS_NONCE:-}"
upgrade_verdict_file="${RAILS_VERDICT_FILE:-}"
unset RAILS_NONCE RAILS_VERDICT_FILE
set -euo pipefail
[[ "${BASH_VERSINFO[0]}" -ge 4 ]] || { echo 'Bash >= 4 required' >&2; exit 1; }

candidate="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$candidate/tests/fixtures/upgrade-existing-project"
while IFS= read -r variable; do unset "$variable"; done < <(compgen -v | grep '^SINGULAR_' || true)
unset variable
scratch="$(mktemp -d "${TMPDIR:-/tmp}/singular-upgrade.XXXXXX")"
scratch="$(cd "$scratch" && pwd -P)"
trap 'rm -rf "$scratch"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture
export SINGULAR_PUSH=0
project="$scratch/project with spaces"
backup="$scratch/backup"
task_id=TASK-0001
mkdir -p "$scratch/isolated-home" "$scratch/steps"
# HOME is passed only to child processes, never repurposed in this shell.
export SINGULAR_HOME="$scratch/isolated-home/engine-home"
export SINGULAR_ENGINE_HOME="$candidate"
export SINGULAR_RESOURCE_CPU_COUNT=4
export SINGULAR_RESOURCE_AVAILABLE_MEMORY_BYTES=17179869184
export SINGULAR_RESOURCE_LOAD_1M=0

# Extract the actual instructions, so a broken or missing documented command
# fails this test instead of leaving a separate test-only procedure green.
python3 - "$candidate/docs/upgrade.md" "$scratch/steps" "$fixture" <<'PY'
import hashlib
import json
from pathlib import Path
import re
import sys
document, steps, fixture = map(Path, sys.argv[1:])
blocks = re.findall(r"<!-- upgrade-step: ([a-z]+) -->\n```bash\n(.*?)\n```", document.read_text(), re.S)
assert [name for name, _ in blocks] == ["backup", "select", "inspect", "continue", "rollback"]
for name, body in blocks:
    (steps / (name + ".sh")).write_text(body + "\n")
scaffold = fixture / "scaffold"
actual = {str(p.relative_to(scaffold)): hashlib.sha256(p.read_bytes()).hexdigest()
          for p in sorted(scaffold.rglob("*")) if p.is_file()}
assert actual == json.loads((fixture / "sha256.json").read_text()), "recorded scaffold changed"
PY
cp -a "$fixture/scaffold" "$project"
git -C "$project" init -q
git -C "$project" checkout -qb agent/integration
git -C "$project" config user.name fixture
git -C "$project" config user.email fixture
export SINGULAR_ROOT="$project"
export SINGULAR_STATE_DIR="$project/.singular-state"

loaded_settings() {
  bash -c '
    source "$SINGULAR_ENGINE_HOME/engine/lib.sh"
    printf "%s\n" "$SINGULAR_ENGINE_DIR" "$SINGULAR_SCHEMA_DIR" \
      "$SINGULAR_RUNNER" "$SINGULAR_TARGET_BRANCH" "$SINGULAR_AREA_PREFIX" \
      "$SINGULAR_MAX_CONCURRENT" "$SINGULAR_CONFIG_SCHEMA_VERSION" \
      "$SINGULAR_MAX_HOURS" "$SINGULAR_MAX_RETRIES" "$SINGULAR_AUDIT_INFRA_MAX" \
      "$SINGULAR_CTX_PACKET" "$SINGULAR_CTX_ROUTING" "${SINGULAR_CTX_ARTIFACT_SCAN:-0}" \
      "${SINGULAR_PAIRED_AUDIT_PCT:-0}" "$SINGULAR_DEFAULT_GATE_CMD"
  '
}
loaded_settings > "$scratch/default-settings"
python3 - "$scratch/default-settings" "$candidate" <<'PY'
from pathlib import Path
import sys
settings = Path(sys.argv[1]).read_text().splitlines()
candidate = sys.argv[2]
assert settings == [candidate + "/engine", candidate + "/schemas",
                    candidate + "/engine/claude-run.sh", "agent/integration", "src/",
                    "3", "v2", "20", "3", "2", "1", "1", "0", "0",
                    "false # replace with your real gate, e.g. npm test && npm run build"], settings
print("Inherited: candidate driver, runner adapter and validation schemas; scaffold defaults verified")
PY

# Consumer work that predates the upgrade. The copied config stays old except
# for this ordinary project setting; the runner is an ignored local override.
python3 - "$project/singular.config.json" <<'PY'
import json
from pathlib import Path
import sys
p = Path(sys.argv[1])
cfg = json.loads(p.read_text())
cfg["env"]["SINGULAR_MAX_CONCURRENT"] = "2"
p.write_text(json.dumps(cfg, indent=2) + "\n")
PY
printf '\nLocal upgrade instruction: preserve the existing result contract.\n' >> \
  "$project/docs/orchestration/prompts/l2-test-first-developer.md"
mkdir -p "$project/.singular-state" "$project/src/core"
cp "$fixture/runner.sh" "$scratch/runner.sh"
chmod +x "$scratch/runner.sh"
printf 'export SINGULAR_RUNNER=%q\n' "$scratch/runner.sh" > "$project/.singular-state/config.local.sh"
printf 'pending\n' > "$project/src/core/result.txt"
cat > "$project/check.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$(cat src/core/result.txt)" == continued ]]
SH
cat > "$project/docs/orchestration/tasks/TASK-0001.md" <<'TASK'
# TASK-0001: Continue the existing result task

Status: ready
Area: core
Target branch: `agent/integration`
Worker branch: `agent/core/TASK-0001-upgrade`
Test policy: `strict_test_first`
Gate command: `bash check.sh`
Dispatch mode: canonical
Depends on: []

## Objective

Continue the pre-upgrade task by changing the pending result to continued.

## Scope

Owned files:

- `src/core/result.txt`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- The existing check.sh gate passes.
TASK
git -C "$project" add .
git -C "$project" commit -qm 'Existing project and ready task'
[[ -z "$(git -C "$project" remote)" ]] || fail 'fixture has a remote'
git -C "$project" check-ignore -q .singular-state/config.local.sh || fail 'state is not ignored'
task_before="$(git -C "$project" rev-parse HEAD:docs/orchestration/tasks/TASK-0001.md)"

run_step() {
  # Do not put source in a conditional: that would disable errexit inside it.
  active_step="$1"
  source "$scratch/steps/$1.sh" > "$scratch/$1.log" 2>&1
}
trap 'rc=$?; if [[ $rc -ne 0 ]]; then tail -n 18 "$scratch/"*.log 2>/dev/null || true; echo "FAIL: upgrade step ${active_step:-setup} (exit $rc)" >&2; fi; rm -rf "$scratch"' EXIT
run_step backup
run_step select
[[ "$(cat .singular-version)" == "$(cat "$candidate/VERSION")" ]] || fail 'candidate pin not applied'
grep -Fq "engine      $candidate_version  ($candidate)" "$scratch/select.log" || fail 'candidate not resolved'
grep -q 'up to date, nothing to do' "$scratch/select.log" || fail 'unexpected migration'

# Selection changes exactly the pin, not config, prompts, state or schema copies.
python3 - "$project" "$backup/project" <<'PY'
from pathlib import Path
import sys
project, backup = map(Path, sys.argv[1:])
for old in backup.rglob("*"):
    rel = old.relative_to(backup)
    if old.is_file() and ".git" not in rel.parts and str(rel) != ".singular-version":
        assert (project / rel).read_bytes() == old.read_bytes(), str(rel)
PY
run_step inspect
loaded_settings > "$scratch/local-settings"
python3 - "$scratch/local-settings" "$scratch/runner.sh" <<'PY'
from pathlib import Path
import sys
settings = Path(sys.argv[1]).read_text().splitlines()
assert settings[2] == sys.argv[2] and settings[5] == "2", settings
PY
run_step continue

python3 - "$project" "$backup/project" "$scratch/inspect.log" <<'PY'
import json
from pathlib import Path
import sys
project, backup, config_log = map(Path, sys.argv[1:])
effective = json.loads(config_log.read_text())["effectiveConfiguration"]
assert effective["runner"].endswith("/runner.sh"), effective
assert effective["paths"]["state"] == str(project / ".singular-state"), effective
state = project / ".singular-state"
runs = list((state / "runs").glob("RUN-*"))
assert len(runs) == 1, runs
run = runs[0]
packet = json.loads((state / "inbox" / (run.name + ".json")).read_text())
assert packet["taskId"] == "TASK-0001" and packet["status"] == "accepted", packet
gate = json.loads((run / "gate-report.json").read_text())
assert gate["outcome"] == "passed" and gate["rawExitCode"] == 0, gate
assert gate["command"].endswith(" -c bash check.sh") and gate["headSha"] == packet["headSha"], gate
assert not (run / "durable-artifacts.manifest").exists(), "artifact scan unexpectedly enabled"
assert not (run / "paired-audit.json").exists(), "paired audit unexpectedly enabled"
lease = json.loads((state / "leases" / "TASK-0001.json").read_text())
assert lease["status"] == "accepted", lease
task = "docs/orchestration/tasks/TASK-0001.md"
assert "Status: ready" in (backup / task).read_text()
assert "Status: accepted" in (project / task).read_text()
assert "Local upgrade instruction: preserve the existing result contract." in (run / "l2-prompt.md").read_text()
assert (backup / "docs/orchestration/prompts/auditor.md").read_text().replace("[TASK-ID]", "TASK-0001") in (run / "auditor-prompt.md").read_text()
events = [json.loads(line) for line in (state / "events.ndjson").read_text().splitlines()]
assert any(e["type"] == "l1.task_accepted" for e in events)
policy = [e for e in events if e["type"] == "l1.review_policy_bound"]
assert len(policy) == 1 and policy[0]["data"]["productRepairMax"] == 1, policy
# The task and decisions legitimately change; copied configuration, prompts,
# gate adapter, schemas, and the ignored local override must not change.
kept = ["singular.config.json", ".singular-state/config.local.sh",
        "docs/orchestration/dag.v0.json", "docs/orchestration/tasks/TEMPLATE.md",
        "docs/orchestration/planner-contract.md", "docs/orchestration/gates/gate.sh"]
kept += [str(p.relative_to(backup)) for directory in ["docs/orchestration/prompts", "schemas/orchestration"]
         for p in (backup / directory).glob("*") if p.is_file()]
for name in kept:
    assert (project / name).read_bytes() == (backup / name).read_bytes(), name
print("Kept: old config, all prompts, local instruction and schema mirrors")
print("Manual refresh: copied prompts/config and schema mirrors; no automatic template merge")
print("Continued: existing TASK-0001 accepted; normal-task product repair ceiling is 1")
PY
[[ "$(git show agent/core/TASK-0001-upgrade:src/core/result.txt)" == continued ]] || fail 'worker result missing'
[[ "$(git show agent/integration:src/core/result.txt)" == pending ]] || fail 'drive unexpectedly integrated'
[[ "$(git -C "$backup/project" rev-parse HEAD:docs/orchestration/tasks/TASK-0001.md)" == "$task_before" ]] || fail 'backup history changed'

# A separate disposable probe proves init is not an upgrade merge: prompts and
# config survive, but even a locally modified schema mirror is synchronized.
probe="$scratch/init probe"
cp -a "$backup/project" "$probe"
printf '\n' >> "$probe/schemas/orchestration/state-packet.v0.schema.json"
(
  cd "$probe"
  SINGULAR_ROOT="$probe" SINGULAR_STATE_DIR="$probe/.singular-state" \
    bash "$candidate/cli/singular" init
) > "$scratch/init.log" 2>&1
cmp "$probe/singular.config.json" "$backup/project/singular.config.json"
diff -r "$probe/docs/orchestration/prompts" "$backup/project/docs/orchestration/prompts"
cmp "$probe/schemas/orchestration/state-packet.v0.schema.json" "$candidate/schemas/state-packet.v0.schema.json"

run_step rollback
[[ -z "${SINGULAR_ENGINE_HOME:-}" ]] || fail 'candidate override survived rollback'
cmp "$project/.singular-version" "$backup/project/.singular-version"
cmp "$project/singular.config.json" "$backup/project/singular.config.json"
grep -q 'Status: accepted' "$project/docs/orchestration/tasks/TASK-0001.md" || fail 'rollback lost task progress'
grep -q 'Status: ready' "$backup/project/docs/orchestration/tasks/TASK-0001.md" || fail 'rollback changed backup'
echo 'PASS: documented upgrade, task continuation, manual refresh boundary and pin rollback'
cd "$candidate"
rm -rf "$scratch"
trap - EXIT
# The nonce is never inherited by the engine or stub, and is emitted only after
# every assertion and cleanup succeeds. This must remain the final operation.
if [[ -n "$upgrade_verdict_file" ]]; then
  printf '%s\n' "$upgrade_nonce" > "$upgrade_verdict_file"
fi
