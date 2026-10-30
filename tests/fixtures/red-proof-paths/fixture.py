"""Public-command fixture, adapted from acceptance-invariant/defaults tests."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys

TASK = "TASK-0001"
BRANCH = "agent/widget/TASK-0001-fixture"


def read(path):
    return json.loads(Path(path).read_text())


def write(path, value):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(json.dumps(value, indent=2) + "\n")


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class Checks:
    def __init__(self):
        self.failures = 0

    def check(self, criterion, label, condition):
        print(("ok: " if condition else "FAIL: ") + criterion + ": " + label, flush=True)
        if not condition:
            print("CRITERION " + criterion, flush=True)
            self.failures += 1
        return condition

    def require(self, criterion, label, condition):
        if not self.check(criterion, label, condition):
            raise AssertionError(criterion + ": fixture precondition failed: " + label)


class Fixture:
    def __init__(self, root, scratch, checks, runner=None, policy="strict_test_first", declared=True):
        self.root, self.scratch, self.checks = Path(root), Path(scratch), checks
        self.repo = self.scratch / "repo"
        self.state = self.repo / ".singular-state"
        self.orch = self.repo / "docs/orchestration"
        self.task = self.orch / "tasks" / (TASK + ".md")
        self.lease = self.state / "leases" / (TASK + ".json")
        self.events_path = self.state / "events.ndjson"
        self.counters = self.scratch / "counters"
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("SINGULAR_", "GIT_", "PYTHON"))}
        assert "RAILS_NONCE" not in self.env and "RAILS_VERDICT_FILE" not in self.env, "fixture: verdict variables leaked to a child"
        settings = dict(
            ROOT=self.repo, STATE_DIR=self.state, ORCH_DIR=self.orch,
            TASKS_DIR=self.task.parent, RUNS_DIR=self.state / "runs",
            LEASES_DIR=self.lease.parent, INBOX_DIR=self.state / "inbox",
            EVENTS_FILE=self.events_path, WORKTREES_DIR=self.repo / ".worktrees",
            STOP_FILE=self.state / "STOP", ENGINE_HOME=self.root,
            HOME=self.scratch / "machine", TARGET_BRANCH="target", PUSH=0,
            RUNNER=runner or self.root / "tests/fixtures/red-proof-paths/runner.py",
            GENERATE=0, AUTO_INTEGRATE=0, DETACHED_DISPATCH=0, SLEEP=0,
            TEST_PROCESS_CONTROL=1, TEST_PROCESS_CONTROL_STATE="ok",
            LIMIT_SLEEPTHROUGH=0, RESOURCE_CPU_COUNT=4,
            RESOURCE_AVAILABLE_MEMORY_BYTES=17179869184, RESOURCE_LOAD_1M=0,
            RED_PROOF="off", AUDIT_INFRA_MAX=1, WORKER_INFRA_MAX=0, VERIFY_INFRA_MAX=0,
        )
        self.env.update({"SINGULAR_" + k: str(v) for k, v in settings.items()})
        self.env.update(HOME=str(self.scratch / "machine"), PACKET_COUNTERS=str(self.counters), PYTHONDONTWRITEBYTECODE="1",
                        GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null",
                        GIT_AUTHOR_NAME="fixture", GIT_COMMITTER_NAME="fixture",
                        GIT_AUTHOR_EMAIL="fixture", GIT_COMMITTER_EMAIL="fixture",
                        TMPDIR=str(self.scratch / "tmp"))
        Path(self.env["TMPDIR"]).mkdir(parents=True)
        self.task.parent.mkdir(parents=True)
        (self.orch / "prompts").mkdir()
        self.state.mkdir()
        for name in ("l2-test-first-developer", "auditor", "decider"):
            shutil.copyfile(self.root / "templates/prompts" / (name + ".md"),
                            self.orch / "prompts" / (name + ".md"))
        (self.repo / ".gitignore").write_text(
            ".singular-state/\n.worktrees/\n.singular-evidence/\n.singular-cache/\n")
        write(self.repo / "singular.config.json", {
            "schemaVersion": "v2", "targetBranch": "target", "gateCommand": "true"})
        (self.repo / "proof.sh").write_text("#!/usr/bin/env bash\ntest -f widget.txt\n")
        self.task.write_text("""# TASK-0001: Synthetic widget

Status: ready
Area: widget
Target branch: `target`
Worker branch: `agent/widget/TASK-0001-fixture`
Test policy: `strict_test_first`
Gate command: `true`
Proof command: `bash proof.sh`
Proof tests: ["proof.sh"]
Dispatch mode: canonical
Depends on: []

## Objective

Write a synthetic widget.

## Scope

Owned files:

- `widget.txt`
- `proof.sh`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- The widget exists.
""")
        task_text = self.task.read_text().replace("strict_test_first", policy)
        if not declared:
            task_text = task_text.replace("Proof command: `bash proof.sh`\n", "").replace('Proof tests: ["proof.sh"]\n', "")
        self.task.write_text(task_text)
        self.git("init", "-q")
        self.git("symbolic-ref", "HEAD", "refs/heads/target")
        self.git("add", ".")
        self.git("-c", "commit.gpgsign=false", "commit", "-qm", "initial")
        self.original_head = self.git("rev-parse", "target").stdout.strip()
        self.sequence = 0

    def run(self, argv, timeout=180):
        proc = subprocess.Popen([str(x) for x in argv], env=self.env, cwd=self.repo,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, start_new_session=True)
        try:
            output, _ = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.communicate()
            raise AssertionError("fixture command exceeded its 180-second deadline")
        return subprocess.CompletedProcess(argv, proc.returncode, output)

    def git(self, *args):
        result = self.run(["git", "-C", self.repo, *args])
        if result.returncode:
            raise AssertionError("fixture: fixture git command failed: " + result.stdout)
        return result

    def command(self, *args):
        result = self.run([self.env.get("TEST_BASH", "bash"), self.root / "cli/singular", *args])
        self.sequence += 1
        (self.scratch / ("command-%03d.log" % self.sequence)).write_text(result.stdout)
        return result

    def checked(self, argv):
        result = self.run(argv)
        if result.returncode:
            message = result.stdout.replace(str(self.scratch), "<fixture>").replace(str(self.root), "<engine>")
            raise AssertionError("fixture command failed: " + message[-2000:])
        return result

    def python(self, script, *args):
        return self.checked([sys.executable, self.root / "engine" / script, *args])

    def seed(self):
        # Synthetic certificate; the real host binding, review ledger and
        # manifest writers establish G/A/D/E, independently of the new V rule.
        self.run_id = "RUN-PROOF"
        self.run_dir = self.state / "runs" / self.run_id
        self.run_dir.mkdir(parents=True)
        self.worktree = self.repo / ".worktrees" / TASK
        self.git("worktree", "add", "-qb", BRANCH, self.worktree, "target")
        (self.worktree / "widget.txt").write_text("synthetic candidate\n")
        self.git("-C", self.worktree, "add", "widget.txt")
        self.git("-C", self.worktree, "commit", "-qm", "candidate")
        self.head = self.git("rev-parse", BRANCH).stdout.strip()
        self.tree = self.git("rev-parse", self.head + "^{tree}").stdout.strip()
        self.packet = self.run_dir / "packet.json"
        self.audit = self.run_dir / "audit.json"
        self.report = self.run_dir / "audit-verification.json"
        self.manifest = self.run_dir / "evidence-manifest.json"
        self.ledger = self.state / "review-policy/ledger.json"
        self.task.write_text(self.task.read_text().replace("Status: ready", "Status: accepted"))
        contract = self.run_dir / "verification-task-contract-1.md"
        contract.write_bytes(self.task.read_bytes())
        policy = self.run_dir / "verification-policy-1.json"
        write(policy, {"campaign": "legacy", "policy": "legacy"})
        request = self.run_dir / "verification-request-1.json"
        self.python("gate-report.py", "create-verification-request", "--output", request,
                    "--task-id", TASK, "--run-id", self.run_id, "--attempt", "1",
                    "--head-sha", self.head, "--tree-sha", self.tree, "--campaign", "legacy",
                    "--task-contract", contract, "--policy-contract", policy,
                    "--suite-id", "task-contract-gate")
        log = self.run_dir / "gate.log"
        log.write_text("host fixture gate exited 0\n")
        self.python("gate-report.py", "create", "--output", self.report,
                    "--task-id", TASK, "--run-id", self.run_id, "--head-sha", self.head,
                    "--command", "true", "--exit-code", "0", "--log", log,
                    "--integrity-status", "verified")
        self.python("gate-report.py", "bind-verification-result", "--request", request,
                    "--report", self.report, "--task-contract", contract, "--policy-contract", policy)
        write(self.audit, {
            "schema": "singular.orchestration.audit-verdict.v1", "taskId": TASK,
            "runId": self.run_id, "branch": BRANCH, "verdict": "accepted",
            "evidenceReviewed": ["audit-verification.json", "reviewed-head-sha:" + self.head],
            "verificationResults": [{"status": "passed", "command": "true", "exitCode": 0,
                "evidenceRefs": ["audit-verification.json"], "rationale": "synthetic gate"}],
            "commandsRun": [], "findings": [], "requiredFixes": [], "rationale": "synthetic audit"})
        self.python("review_policy.py", "record", "--logical-change", TASK, "--task", TASK,
                    "--run", self.run_id, "--attempt", "1", "--verdict", self.audit,
                    "--head", self.head, "--campaign", "legacy", "--apply")
        evidence = self.worktree / ".singular-evidence"
        evidence.mkdir()
        for phase in ("red", "green", "regression"):
            (evidence / (phase + ".log")).write_text("fixture\n")
        packet = dict(schema="singular.orchestration.state-packet.v0", packetId=self.run_id,
            runId=self.run_id, taskId=TASK, area="widget", role="l2-developer", status="accepted",
            baseRef=self.original_head, branch=BRANCH, headSha=self.head, workspace=str(self.worktree),
            ownedFiles=["widget.txt", "proof.sh"], changedFiles=["widget.txt"],
            commands=[dict(cmd="test -f widget.txt", exitCode=0, logRef=".singular-evidence/green.log")],
            tests=[dict(name=phase, phase=phase,
                status="failed-as-expected" if phase == "red" else "passed",
                logRef=".singular-evidence/" + phase + ".log") for phase in ("red", "green", "regression")],
            evidence=[dict(kind="audit-verification", ref="runs/" + self.run_id + "/audit-verification.json")],
            blockers=[], nextAction="integrate", createdAt="2026-01-01T00:00:00Z")
        write(self.packet, packet)
        write(self.run_dir / "last-message.json", packet)
        for check, name in (("secret", "secret-scan"), ("scope", "scope-check")):
            log = self.run_dir / (name + ".log")
            log.write_text("synthetic passing check\n")
            write(self.run_dir / (name + "-result.json"), dict(
                schema="singular.orchestration.check-result.v0", check=check, status="passed",
                exitCode=0, logRef=log.name, logSha256=digest(log), recordedAt="2026-01-01T00:00:00Z"))
        self.checked([self.env.get("TEST_BASH", "bash"), self.root / "engine/evidence-manifest.sh",
            "--run-dir", self.run_dir, "--task-id", TASK, "--worktree", self.worktree,
            "--base-ref", self.original_head, "--head-sha", self.head])
        self.lease.parent.mkdir(parents=True, exist_ok=True)
        write(self.lease, dict(taskId=TASK, branch=BRANCH, area="widget", owner="l2-developer",
            fileScope="widget.txt proof.sh", ownedFiles=["widget.txt", "proof.sh"], forbiddenFiles=[],
            baseSha=self.original_head, batchId="", runId=self.run_id, worktree=str(self.worktree),
            status="accepted", retryCount=0, maxRetries=1, productPassStarted=True, campaignBinding="legacy"))
        (self.state / "inbox").mkdir(exist_ok=True)
        self.checks.require("fixture", "G/A/D/E certificate is valid", self.validate().returncode == 0)
        assert not self.git("remote").stdout.strip()

    def validator_args(self):
        return [f"--task={TASK}", f"--run={self.run_id}", f"--branch={BRANCH}",
                f"--head={self.head}", "--campaign=legacy", f"--run-dir={self.run_dir}",
                f"--repo-root={self.repo}", f"--state-dir={self.state}",
                f"--logical-change={TASK}", f"--task-contract={self.task}",
                f"--config={self.repo / 'singular.config.json'}", "--require-audit=1",
                "--legacy-schema-mode=warn", "--trusted-shell=",
                "--policy-env-json=" + json.dumps({k: v for k, v in self.env.items()
                                                 if k.startswith("SINGULAR_REVIEW_")})]

    def validate(self):
        return self.run([sys.executable, self.root / "engine/acceptance_validator.py",
                         *self.validator_args()])

    def events(self):
        if not self.events_path.exists():
            return []
        return [json.loads(line) for line in self.events_path.read_text().splitlines() if line.strip()]
