"""Public-command fixture, adapted from acceptance-invariant/defaults tests."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

TASK = "TASK-0001"
BRANCH = "agent/widget/TASK-0001-fixture"


def read(path):
    return json.loads(Path(path).read_text())


def write(path, value):
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
    def __init__(self, root, scratch, checks, runner=None):
        self.root, self.scratch, self.checks = Path(root), Path(scratch), checks
        self.repo = self.scratch / "repo"
        self.state = self.repo / ".singular-state"
        self.orch = self.repo / "docs/orchestration"
        self.task = self.orch / "tasks" / (TASK + ".md")
        self.lease = self.state / "leases" / (TASK + ".json")
        self.events_path = self.state / "events.ndjson"
        self.counters = self.scratch / "counters"
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("SINGULAR_")}
        assert "RAILS_NONCE" not in self.env and "RAILS_VERDICT_FILE" not in self.env, "S0.4-3: verdict variables leaked to a child"
        settings = dict(
            ROOT=self.repo, STATE_DIR=self.state, ORCH_DIR=self.orch,
            TASKS_DIR=self.task.parent, RUNS_DIR=self.state / "runs",
            LEASES_DIR=self.lease.parent, INBOX_DIR=self.state / "inbox",
            EVENTS_FILE=self.events_path, WORKTREES_DIR=self.repo / ".worktrees",
            STOP_FILE=self.state / "STOP", ENGINE_HOME=self.root,
            HOME=self.scratch / "machine", TARGET_BRANCH="target", PUSH=0,
            RUNNER=runner or self.root / "tests/fixtures/acceptance-boundary-accept-packet/runner.py",
            GENERATE=0, AUTO_INTEGRATE=0, DETACHED_DISPATCH=0, SLEEP=0,
            TEST_PROCESS_CONTROL=1, TEST_PROCESS_CONTROL_STATE="ok",
            LIMIT_SLEEPTHROUGH=0, RESOURCE_CPU_COUNT=4,
            RESOURCE_AVAILABLE_MEMORY_BYTES=17179869184, RESOURCE_LOAD_1M=0,
            AUDIT_INFRA_MAX=1, WORKER_INFRA_MAX=0, VERIFY_INFRA_MAX=0,
        )
        self.env.update({"SINGULAR_" + k: str(v) for k, v in settings.items()})
        self.env.update(PACKET_COUNTERS=str(self.counters), PYTHONDONTWRITEBYTECODE="1",
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
        self.task.write_text("""# TASK-0001: Synthetic widget

Status: ready
Area: widget
Target branch: `target`
Worker branch: `agent/widget/TASK-0001-fixture`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Write a synthetic widget.

## Scope

Owned files:

- `widget.txt`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- The widget exists.
""")
        self.git("init", "-q")
        self.git("symbolic-ref", "HEAD", "refs/heads/target")
        self.git("add", ".")
        self.git("-c", "commit.gpgsign=false", "commit", "-qm", "initial")
        self.original_head = self.git("rev-parse", "target").stdout.strip()
        self.sequence = 0

    def run(self, argv, timeout=180):
        return subprocess.run([str(x) for x in argv], env=self.env, cwd=self.repo,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              text=True, timeout=timeout)

    def git(self, *args):
        result = self.run(["git", "-C", self.repo, *args])
        if result.returncode:
            raise AssertionError("S0.4-3: fixture git command failed: " + result.stdout)
        return result

    def command(self, *args):
        result = self.run([self.env.get("TEST_BASH", "bash"), self.root / "cli/singular", *args])
        self.sequence += 1
        (self.scratch / ("command-%03d.log" % self.sequence)).write_text(result.stdout)
        return result

    def seed(self):
        result = self.command("drive", TASK)
        self.checks.require("S0.4-3", "valid control drive exits zero", result.returncode == 0)
        self.run_id = read(self.lease)["runId"]
        self.run_dir = self.state / "runs" / self.run_id
        self.packet = self.run_dir / "packet.json"
        self.audit = self.run_dir / "audit.json"
        self.report = self.run_dir / "audit-verification.json"
        self.manifest = self.run_dir / "evidence-manifest.json"
        self.ledger = self.state / "review-policy/ledger.json"
        self.head = read(self.packet)["headSha"]
        self.checks.require("S0.4-3", "valid control certificate satisfies the existing validator",
                            self.validate().returncode == 0)
        self.checks.require("S0.4-3", "valid control publishes an inbox packet",
                            (self.state / "inbox" / (self.run_id + ".json")).is_file())
        self.snapshot = self.scratch / "snapshot"
        self.snapshot.mkdir()
        shutil.copytree(self.state, self.snapshot / "state")
        shutil.copytree(self.orch, self.snapshot / "orch")
        self.original_commands = read(self.manifest)["commands"]
        self.original_audit = self.audit.read_bytes()
        self.original_rounds = self.rounds()
        self.original_counters = self.counts()

    def restore(self, mode="every-path", source="env", pending=False):
        # Restore only synthetic runtime data and task records from our own
        # snapshot. No Git restore/reset/checkout and no worker mutation.
        shutil.rmtree(self.state)
        shutil.copytree(self.snapshot / "state", self.state)
        shutil.rmtree(self.orch)
        shutil.copytree(self.snapshot / "orch", self.orch)
        for p in (self.state / "inbox").glob("*.json"):
            p.unlink()
        self.case_target = self.git("rev-parse", "target").stdout.strip()
        self.env.pop("SINGULAR_ACCEPTANCE", None)
        local_config = self.state / "config.local.sh"
        if mode != "unset":
            if source == "shell":
                local_config.write_text("SINGULAR_ACCEPTANCE=" + mode + "\n")
            else:
                self.env["SINGULAR_ACCEPTANCE"] = mode
        if pending:
            packet = read(self.packet)
            packet["status"] = "needs-review"
            write(self.packet, packet)
            lease = read(self.lease)
            lease["status"] = "blocked"
            write(self.lease, lease)
            self.task.write_text(self.task.read_text().replace("Status: accepted", "Status: ready"))

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

    def rounds(self):
        return read(self.ledger)["logicalChanges"][TASK]["rounds"]

    def counts(self):
        return {p.name: p.read_text() for p in self.counters.glob("*")}

    def events(self):
        return [json.loads(line) for line in self.events_path.read_text().splitlines() if line.strip()]

    def status(self):
        return re.search(r"^Status:\s*(\S+)", self.task.read_text(), re.M).group(1)

    def bind_artifacts(self):
        manifest = read(self.manifest)
        for artifact in manifest["artifacts"]:
            p = self.run_dir / artifact["ref"]
            if p.is_file():
                artifact.update(sha256=digest(p), bytes=p.stat().st_size)
        write(self.manifest, manifest)

    def mutate(self, defect):
        if defect == "audit-verdict":
            value = read(self.audit)
            value["verdict"] = "needs-fix"
            write(self.audit, value)
            self.bind_artifacts()
        elif defect == "round-missing":
            value = read(self.ledger)
            value["logicalChanges"][TASK]["rounds"] = []
            write(self.ledger, value)
        elif defect == "audit-head":
            value = read(self.audit)
            value["evidenceReviewed"] = [
                "reviewed-head-sha:" + "0" * 40 if x.startswith("reviewed-head-sha:") else x
                for x in value["evidenceReviewed"]]
            write(self.audit, value)
            self.bind_artifacts()
        elif defect == "round-head":
            value = read(self.ledger)
            value["logicalChanges"][TASK]["rounds"][-1]["head"] = "0" * 40
            write(self.ledger, value)
        elif defect == "manifest-audit-hash":
            value = read(self.manifest)
            for artifact in value["artifacts"]:
                if artifact["ref"] == "audit.json":
                    artifact["sha256"] = "0" * 64
            write(self.manifest, value)
        else:
            raise ValueError(defect)

    def isolated_defect(self, expected):
        # Query the program through its CLI. Then repair only the mutated
        # component in fixture custody and query again: no second failure may
        # be hidden behind the first one. Restore the exact mutation afterward.
        result = self.validate()
        self.checks.require("S0.4-3", "mutation is refused as " + expected,
                            result.returncode == 1 and json.loads(result.stdout).get("conjunct") == expected)
        paths = {"A": [self.audit, self.manifest], "D": [self.ledger], "E": [self.manifest]}[expected]
        saved = {p: p.read_bytes() for p in paths}
        if expected in {"A", "D"}:
            hashes = {a["ref"]: a["sha256"] for a in read(self.manifest)["artifacts"]}
            self.checks.require("S0.4-3", "semantic mutation leaves exact evidence binding valid",
                                all(hashes.get(p.name) == digest(p) for p in (self.audit, self.report)))
        try:
            component = {"A": self.audit, "D": self.ledger, "E": self.manifest}[expected]
            relative = component.relative_to(self.state)
            component.write_bytes((self.snapshot / "state" / relative).read_bytes())
            if expected == "A":
                # Updating the digest is mechanical: the assertion above
                # established that E bound the mutated audit correctly too.
                self.bind_artifacts()
            repaired = self.validate()
            self.checks.require("S0.4-3", "repairing only " + expected + " restores a valid certificate",
                                repaired.returncode == 0)
        finally:
            for path, content in saved.items():
                path.write_bytes(content)
