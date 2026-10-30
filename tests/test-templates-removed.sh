#!/usr/bin/env bash
rails_nonce="${RAILS_NONCE-}" rails_verdict_file="${RAILS_VERDICT_FILE-}"
unset RAILS_NONCE RAILS_VERDICT_FILE
set -euo pipefail

# S0.4-10. Names this test fixes: none beyond the frozen criterion and existing
# public commands/contracts. The prompt inventory is init's templates/*.md
# inventory, not a second maintained list. Only the two retired names are fixed.
# Fixtures follow test-setup.sh, test-v1-to-v2-migration.sh and
# test-l1-drive-armstate.sh; no existing test is invoked by this test.
# Reference checking supplements one accepted stub drive. Dynamically assembled
# paths on other execution branches still need review; see the hand-back report.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" "$BASH" <<'PY'
import ast
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
bash = sys.argv[2]
removed = ("l0-origin.md", "l1-area-orchestrator.md")
failures = []


def check(condition, message):
    print(f"{'PASS' if condition else 'FAIL'}: S0.4-10: {message}", flush=True)
    if not condition:
        failures.append(message)
    return condition


# Keep Unix-domain socket paths below macOS's limit, even when the host's
# TMPDIR is a long /var/folders path. All fixture writes stay below this root.
with tempfile.TemporaryDirectory(prefix="sg-prompts-", dir="/tmp") as scratch:
    tmp = Path(scratch)
    # Provider homes belong only to these subprocesses. Never inspect the real
    # user's credentials, hooks, installation, Git configuration or model cache.
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("SINGULAR_", "GIT_", "RAILS_"))}
    env.update(HOME=str(tmp / "home"), CODEX_HOME=str(tmp / "provider-home"),
               SINGULAR_HOME=str(tmp / "singular-home"),
               SINGULAR_ENGINE_HOME=str(root), SINGULAR_PUSH="0",
               GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
               PYTHONDONTWRITEBYTECODE="1", TMPDIR=str(tmp / "tmp"))
    for key in ("HOME", "CODEX_HOME", "SINGULAR_HOME", "TMPDIR"):
        Path(env[key]).mkdir()

    def run(repo, args, timeout=120, extra=None):
        child_env = dict(env, SINGULAR_ROOT=str(repo))
        child_env.update(extra or {})
        process = subprocess.Popen(args, cwd=repo, env=child_env,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, start_new_session=True)
        try:
            output, _ = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            # Only the process group this test created; no name/pattern kills.
            os.killpg(process.pid, signal.SIGKILL)
            output, _ = process.communicate()
            output += "\nfixture command exceeded its bound"
            return 124, output
        return process.returncode, output

    def successful(repo, args, label, **kwargs):
        code, output = run(repo, args, **kwargs)
        if not check(code == 0, f"{label} (exit {code})"):
            # Failure diagnostics must not publish host paths or identities.
            output = output.replace(str(root), "<engine>").replace(scratch, "<fixture>")
            print("\n".join(output.splitlines()[-16:]), flush=True)
        return code == 0

    def cli(repo, *args, **kwargs):
        return successful(repo, [bash, str(root / "cli/singular"), *args],
                          " ".join(args), **kwargs)

    def new_repo(name):
        repo = tmp / name
        repo.mkdir()
        for args in (["git", "init", "-q"],
                     ["git", "symbolic-ref", "HEAD", "refs/heads/target"],
                     ["git", "config", "user.name", "fixture"],
                     ["git", "config", "user.email", "fixture"]):
            code, _ = run(repo, args)
            if code:
                raise AssertionError("S0.4-10: cannot initialize synthetic Git fixture")
        (repo / ".gitignore").write_text(".singular-state/\n.worktrees/\n")
        commit(repo)
        return repo

    def commit(repo):
        for args in (["git", "add", "."], ["git", "commit", "-qm", "Synthetic fixture"]):
            code, _ = run(repo, args)
            if code:
                raise AssertionError("S0.4-10: cannot commit synthetic Git fixture")

    # Independent assertions accumulate: today's deletion failures must not hide
    # the compatibility assertions that already pass.
    for name in removed:
        path = root / "templates/prompts" / name
        check(not path.exists() and not path.is_symlink(), f"engine template absent: {name}")

    fresh = new_repo("fresh")
    cli(fresh, "init")
    for name in removed:
        path = fresh / "docs/orchestration/prompts" / name
        check(not path.exists() and not path.is_symlink(), f"fresh init omits {name}")
    retained = sorted(p for p in (root / "templates/prompts").glob("*.md")
                      if p.is_file() and p.name not in removed)
    check(bool(retained), "live prompt inventory is nonempty")
    for source in retained:
        destination = fresh / "docs/orchestration/prompts" / source.name
        check(destination.is_file() and destination.read_bytes() == source.read_bytes(),
              f"fresh init scaffolds retained template byte for byte: {source.name}")

    # The criterion fixes the skill tree and console, but not a guide filename
    # or Python variable name. Inspect the whole guide tree and console literals.
    skills = root / "plugin/skills"
    check(skills.is_dir(), "skill references are available to inspect")
    for name in removed:
        hits = [str(p.relative_to(root)) for p in sorted(skills.rglob("*.md"))
                if name[:-3] in p.read_text(encoding="utf-8")]
        check(not hits, f"skill references omit {name}" + (f" ({', '.join(hits)})" if hits else ""))
    console = root / "plugin/scripts/singular_graph_server.py"
    tree = ast.parse(console.read_text(encoding="utf-8"))
    for name in removed:
        check(not any(isinstance(n, ast.Constant) and isinstance(n.value, str)
                      and name[:-3] in n.value for n in ast.walk(tree)),
              f"console prompt map omits {name}")

    # The console's generic viewer may still read an existing project's prompt
    # by a user-supplied name. That is compatibility, not a retired role caller.
    # Its literal role references are checked above. Comments and Markdown are
    # not runtime callers; don't reject an explanation of the deletion.
    for name in removed:
        hits = []
        for directory in ("engine", "cli", "plugin"):
            for path in sorted((root / directory).rglob("*")):
                if (not path.is_file() or path == console or
                        not (path.suffix in (".sh", ".py", ".js", ".ts") or path == root / "cli/singular") or
                        path.name.startswith(("test_", "test-"))):
                    continue
                for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                    if line.lstrip().startswith(("#", "//", "*")):
                        continue
                    if name[:-3] in line:
                        hits.append(f"{path.relative_to(root)}:{line_number}")
        check(not hits, f"no runtime source reference to {name}" + (f" ({', '.join(hits)})" if hits else ""))

    # Setup uses the real adapter contract with a local executable stub, as in
    # test-setup.sh. Even accidental provider dispatch cannot reach a provider.
    provider = tmp / "codex"
    provider.write_text('#!/usr/bin/env bash\ncase "${1:-}" in\n'
                        ' --version) echo "codex-cli 0.0.0-stub" ;;\n'
                        ' login) echo "fixture authenticated" ;;\n'
                        ' *) exit 97 ;;\nesac\n')
    provider.chmod(0o755)
    existing = new_repo("existing")
    prompts = existing / "docs/orchestration/prompts"
    prompts.mkdir(parents=True)
    originals = {}
    for index, name in enumerate(removed):
        # Custom bytes and line endings catch deletion, regeneration, and even
        # a migration that helpfully rewrites a namespace inside user content.
        originals[name] = f"# Consumer prompt {index}\r\nKeep pmgo.orchestration.fixture\n\nEnd".encode()
        (prompts / name).write_bytes(originals[name])

    def preserved(stage):
        for name, content in originals.items():
            path = prompts / name
            check(path.is_file() and path.read_bytes() == content,
                  f"existing {name} preserved byte for byte through {stage}")

    cli(existing, "init")
    preserved("init")
    config_path = existing / "singular.config.json"
    config = json.loads(config_path.read_text())
    config.update(targetBranch="target", gateCommand="true", runner="codex-run.sh")
    config["identity"] = {role: {"name": "fixture", "email": "fixture"} for role in ("l0", "l1")}
    config["env"] = {"SINGULAR_CODEX_BIN": str(provider), "SINGULAR_PUSH": "0"}
    # Exercise a real v1-to-current migration, not the up-to-date no-op.
    # v0's historical namespace rewrite is a separate compatibility question.
    config["schemaVersion"] = "v1"
    config_path.write_text(json.dumps(config))
    cli(existing, "migrate")
    check(json.loads(config_path.read_text())["schemaVersion"] == (root / "SCHEMA_VERSION").read_text().strip(),
          "migration actually advances the existing project's schema")
    preserved("migration")
    commit(existing)
    cli(existing, "setup", "--no-test", timeout=180)
    preserved("setup")

    # A separate task fixture has neither retired file. It must reach accepted,
    # not merely start a worker or return zero from a no-op command.
    drive = new_repo("drive")
    drive_prompts = drive / "docs/orchestration/prompts"
    drive_prompts.mkdir(parents=True)
    for source in retained:
        shutil.copyfile(source, drive_prompts / source.name)
    tasks = drive / "docs/orchestration/tasks"
    tasks.mkdir()
    (tasks / "TASK-0001.md").write_text('''# TASK-0001: Synthetic widget

Status: ready
Area: widget
Target branch: `target`
Worker branch: `agent/widget/TASK-0001-fixture`
Test policy: `strict_test_first`
Gate command: `test -s internal/widget/result.txt`
Dispatch mode: canonical
Depends on: []

## Objective

Write the synthetic widget result.

## Scope

Owned files:

- `internal/widget/result.txt`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- The widget result exists and is nonempty.
''')
    runner = tmp / "runner.sh"
    runner.write_text(f'''#!/usr/bin/env bash
exec {shlex.quote(sys.executable)} {shlex.quote(str(tmp / "runner.py"))} "$@"
''')
    runner.chmod(0o755)
    (tmp / "runner.py").write_text('''import json, os, pathlib, sys
assert "RAILS_NONCE" not in os.environ and "RAILS_VERDICT_FILE" not in os.environ
args = sys.argv[1:]
def value(*names):
    for name in names:
        if name in args:
            return args[args.index(name) + 1]
    return ""
level = value("--level")
workspace = pathlib.Path(value("--worktree", "-C"))
output = value("--output-last-message")
if level == "l2":
    path = workspace / "internal/widget/result.txt"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("synthetic result\\n")
    packet = dict(schema="singular.orchestration.state-packet.v0", packetId="p",
        runId="r", taskId="TASK-0001", area="widget", role="l2-developer",
        status="needs-review", baseRef="target", branch="agent/widget/TASK-0001-fixture",
        headSha="0", workspace="w", ownedFiles=["internal/widget/result.txt"],
        changedFiles=[], commands=[], tests=[], evidence=[], blockers=[],
        nextAction="await auditor verdict", createdAt="2026-01-01T00:00:00Z")
elif level == "readonly" and output:
    directory = pathlib.Path(output).parent
    source = directory / "packet.json"
    packet = json.loads(source.read_text()) if source.is_file() else {}
    packet = dict(schema="singular.orchestration.audit-verdict.v0", taskId="TASK-0001",
        runId=packet.get("runId") or directory.name, branch=packet.get("branch", "unknown"),
        verdict="accepted", evidenceReviewed=[], commandsRun=[], findings=[],
        requiredFixes=[], rationale="synthetic verdict")
else:
    sys.exit(97)
if output:
    pathlib.Path(output).write_text(json.dumps(packet))
''')
    commit(drive)
    for name in removed:
        check(not (drive_prompts / name).exists(), f"drive starts without {name}")
    drive_ok = cli(drive, "drive", "TASK-0001", timeout=600,
        extra={"SINGULAR_RUNNER": str(runner), "SINGULAR_TARGET_BRANCH": "target",
               "SINGULAR_MAX_RETRIES": "0", "SINGULAR_PUSH": "0",
               "SINGULAR_GIT_L0_NAME": "fixture", "SINGULAR_GIT_L0_EMAIL": "fixture",
               "SINGULAR_GIT_L1_NAME": "fixture", "SINGULAR_GIT_L1_EMAIL": "fixture"})
    if not drive_ok:
        for log in sorted((drive / ".singular-state/runs").glob("*/auditor-*.log")):
            text = log.read_text().replace(str(root), "<engine>").replace(scratch, "<fixture>")
            print("\n".join(text.splitlines()[-16:]), flush=True)
    packets = list((drive / ".singular-state/inbox").glob("*.json"))
    check(any((packet := json.loads(p.read_text())).get("taskId") == "TASK-0001"
              and packet.get("status") == "accepted" for p in packets),
          "stub drive publishes an accepted TASK-0001 packet without retired prompts")
    for name in removed:
        check(not (drive_prompts / name).exists(), f"drive does not recreate {name}")

print(f"S0.4-10: {len(failures)} failed assertion(s)", flush=True)
sys.exit(1 if failures else 0)
PY

# The only success receipt, after Python has checked everything and cleaned up.
# Neither receipt variable is exported to any child, including the stub runner.
if [[ -n "$rails_nonce" && -n "$rails_verdict_file" ]]; then
  printf '%s' "$rails_nonce" >"$rails_verdict_file"
fi
