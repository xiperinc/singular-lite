"""Synthetic integration certificates and public-boundary assertions (stdlib)."""
from functools import lru_cache
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile

TASK = "TASK-0412"
RUN = "RUN-candidate"
BRANCH = "agent/widget/TASK-0412"
COMMAND = "bash gate.sh"
HERE = Path(__file__).resolve().parent


@lru_cache(maxsize=1)
def supported_bash():
    for candidate in (os.environ.get("BOUNDARY_BASH"), shutil.which("bash"),
                      "/opt/homebrew/bin/bash"):
        if candidate and Path(candidate).is_file():
            try:
                version = subprocess.run([candidate, "--version"], capture_output=True,
                                         text=True, timeout=30)
            except (OSError, subprocess.TimeoutExpired):
                continue
            match = re.search(r"version (\d+)\.", version.stdout)
            if version.returncode == 0 and match and int(match[1]) >= 4:
                return candidate
    raise AssertionError("fixture requires Bash 4 or newer")


def read(path):
    return json.loads(path.read_text())


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n")


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class Fixture:
    def __init__(self, root, scratch, name, mode="every-path", waiver=None):
        self.root = root
        self.bash = supported_bash()
        self.home = scratch / name
        self.repo = self.home / "repo"
        self.state = self.repo / ".singular-state"
        self.run = self.state / "runs" / RUN
        self.orch = self.repo / "docs/orchestration"
        self.task = self.orch / "tasks" / (TASK + ".md")
        self.packet = self.orch / "packets/imported" / TASK / (RUN + ".json")
        self.sidecar = self.packet.with_suffix(".audit.json")
        self.report = self.run / "audit-verification.json"
        self.audit = self.run / "audit.json"
        self.manifest = self.run / "evidence-manifest.json"
        self.ledger = self.state / "review-policy/ledger.json"
        self.events_path = self.state / "events.ndjson"
        self.run.mkdir(parents=True)
        self.task.parent.mkdir(parents=True)
        (self.orch / "prompts").mkdir()
        (self.orch / "prompts/decider.md").write_text("Decide [FAILURE CLASS] for [TASK-ID].\n")
        (self.home / "tmp").mkdir()
        (self.home / "home").mkdir()
        # No inherited project, provider, git, or Python selection. All engine
        # defaults that could launch a provider point at a failing local stub.
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("SINGULAR_", "GIT_", "RAILS_", "PYTHON"))}
        self.env.update(HOME=str(self.home / "home"), TMPDIR=str(self.home / "tmp"),
                        PYTHONDONTWRITEBYTECODE="1", GIT_CONFIG_NOSYSTEM="1",
                        GIT_CONFIG_GLOBAL=os.devnull, GIT_TERMINAL_PROMPT="0",
                        GIT_AUTHOR_NAME="fixture", GIT_AUTHOR_EMAIL="fixture",
                        GIT_COMMITTER_NAME="fixture", GIT_COMMITTER_EMAIL="fixture")
        self.env["PATH"] = str(Path(self.bash).parent) + os.pathsep + self.env["PATH"]
        settings = dict(ROOT=self.repo, ENGINE_HOME=root, STATE_DIR=self.state,
                        ORCH_DIR=self.orch, TASKS_DIR=self.task.parent,
                        RUNS_DIR=self.state / "runs", INBOX_DIR=self.state / "inbox",
                        WORKTREES_DIR=self.repo / ".worktrees", EVENTS_FILE=self.events_path,
                        CONFIG_FILE=self.repo / "singular.config.sh",
                        JSON_CONFIG_FILE=self.repo / "singular.config.json",
                        LOCAL_CONFIG_FILE=self.state / "config.local.sh",
                        TARGET_BRANCH="target", BASH_BIN=self.bash, PUSH=0, GENERATE=0,
                        AUTO_PROMOTE_GATES=0, AUTO_INTEGRATE=1, RECONCILE_INDEX=0,
                        MAX_DISPATCH=0, SLEEP=0, LIMIT_SLEEPTHROUGH=0,
                        TEST_PROCESS_CONTROL=1, TEST_PROCESS_CONTROL_STATE="ok",
                        RESOURCE_CPU_COUNT=4, RESOURCE_AVAILABLE_MEMORY_BYTES=17179869184,
                        RESOURCE_LOAD_1M=0)
        stub = self.home / "no-provider.sh"
        stub.write_text('''#!/usr/bin/env bash
if [[ "${1:-}" == --describe-contract || "${SINGULAR_RUNNER_ROLE:-}" == decider ]]; then
  exit 97
fi
printf "unexpected worker\\n" >>"$BOUNDARY_RUNNER_CALLS"
exit 97
''')
        stub.chmod(0o755)
        self.env["BOUNDARY_RUNNER_CALLS"] = str(self.home / "runner-calls")
        for key in ("RUNNER", "CODEX_RUNNER", "CLAUDE_RUNNER", "PLANNER_RUNNER",
                    "AUDITOR_RUNNER", "DECIDER_RUNNER", "L1_DRIVER"):
            settings[key] = stub
        self.env.update({"SINGULAR_" + k: str(v) for k, v in settings.items()})
        if mode is not None:
            self.env["SINGULAR_ACCEPTANCE"] = mode
        self.git("init", "-q")
        self.git("checkout", "-qb", "target")
        config = {"schemaVersion": "v1", "targetBranch": "target",
                  "gateCommand": COMMAND, "bootstrap": {"required": False, "commands": []}}
        if waiver is not None:
            config["legacyCompatibility"] = {"unboundWaivers": waiver}
        write(self.repo / "singular.config.json", config)
        (self.repo / "singular.config.sh").write_text("")
        (self.state / "config.local.sh").write_text("")
        (self.repo / ".gitignore").write_text(
            ".singular-state/\n.worktrees/\n.singular-evidence/\n.singular-cache/\n")
        shutil.copyfile(HERE / "gate.sh", self.repo / "gate.sh")
        (self.repo / "value.txt").write_text("base\n")
        (self.repo / "target-owned.txt").write_text("clean\n")
        self.task.write_text(f"""# {TASK}: Synthetic widget

Status: accepted
Area: widget
Target branch: `target`
Worker branch: `{BRANCH}`
Test policy: `characterization_first`
Gate command: `{COMMAND}`
Dispatch mode: canonical
Depends on: []

## Objective

Change the synthetic value.

## Scope

Owned files:

- `value.txt`

## Acceptance Criteria

- The value reads candidate.
""")
        self.task_before = self.task.read_text()
        self.git("add", ".")
        self.git("commit", "-qm", "fixture base")
        self.base = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("checkout", "-qb", BRANCH)
        (self.repo / "value.txt").write_text("candidate\n")
        self.git("add", "value.txt")
        self.git("commit", "-qm", "synthetic candidate")
        self.head = self.git("rev-parse", "HEAD").stdout.strip()
        tree = self.git("rev-parse", "HEAD^{tree}").stdout.strip()
        contract = self.run / "verification-task-contract-1.md"
        policy = self.run / "verification-policy-1.json"
        request = self.run / "verification-request-1.json"
        shutil.copyfile(self.task, contract)
        write(policy, {"campaign": "legacy", "policy": "legacy"})
        self.python("gate-report.py", "create-verification-request", "--output", request,
                    "--task-id", TASK, "--run-id", RUN, "--attempt", "1",
                    "--head-sha", self.head, "--tree-sha", tree, "--campaign", "legacy",
                    "--task-contract", contract, "--policy-contract", policy,
                    "--suite-id", "task-contract-gate")
        self.engine("gate-check.sh", RUN, "--task-id", TASK,
                    "--verification-request", request, "--task-contract", contract,
                    "--policy-contract", policy, "--attempt", "1", check=True)
        shutil.copyfile(self.run / "gate-report.json", self.report)
        write(self.audit, {
            "schema": "singular.orchestration.audit-verdict.v1", "taskId": TASK,
            "runId": RUN, "branch": BRANCH, "verdict": "accepted",
            "evidenceReviewed": ["audit-verification.json", "reviewed-head-sha:" + self.head],
            "verificationResults": [{"status": "passed", "command": COMMAND,
                "exitCode": 0, "evidenceRefs": ["audit-verification.json"], "rationale": "synthetic gate"}],
            "commandsRun": [], "findings": [], "requiredFixes": [], "rationale": "synthetic review"})
        self.python("review_policy.py", "record", "--logical-change", TASK,
                    "--task", TASK, "--run", RUN, "--attempt", "1", "--verdict", self.audit,
                    "--head", self.head, "--campaign", "legacy", "--apply")
        packet = {
            "schema": "singular.orchestration.state-packet.v0", "packetId": RUN,
            "runId": RUN, "taskId": TASK, "area": "widget", "role": "l2-developer",
            "status": "accepted", "baseRef": self.base, "branch": BRANCH,
            "headSha": self.head, "workspace": str(self.repo), "ownedFiles": ["value.txt"],
            "changedFiles": ["value.txt"], "commands": [{"cmd": COMMAND, "exitCode": 0}],
            "tests": [{"name": "synthetic", "phase": "regression", "status": "passed"}],
            "evidence": [{"kind": "audit-verification", "ref": f"runs/{RUN}/audit-verification.json"}],
            "blockers": [], "nextAction": "integrate", "createdAt": "2026-01-01T00:00:00Z"}
        write(self.run / "packet.json", packet)
        for check, filename in (("secret", "secret-scan"), ("scope", "scope-check")):
            log = self.run / (filename + ".log")
            log.write_text("synthetic passing check\n")
            write(self.run / (filename + "-result.json"), {
                "schema": "singular.orchestration.check-result.v0", "check": check,
                "status": "passed", "exitCode": 0, "logRef": log.name, "logSha256": sha(log),
                "recordedAt": "2026-01-01T00:00:00Z"})
        self.engine("evidence-manifest.sh", "--run-dir", self.run, "--task-id", TASK,
                    "--worktree", self.repo, "--base-ref", self.base, "--head-sha", self.head,
                    check=True)
        self.git("checkout", "-q", "target")
        write(self.packet, packet)
        shutil.copyfile(self.audit, self.sidecar)
        self.git("add", "docs/orchestration/packets")
        self.git("commit", "-qm", "synthetic imported certificate")
        self.target = self.git("rev-parse", "target").stdout.strip()
        assert not self.git("remote").stdout.strip(), "fixture unexpectedly has a remote"
        # Establish that every rejection below starts with all four parts valid.
        self.python("acceptance_validator.py", f"--task={TASK}", f"--run={RUN}",
                    f"--branch={BRANCH}", f"--head={self.head}", "--campaign=legacy",
                    f"--run-dir={self.run}", f"--repo-root={self.repo}",
                    f"--state-dir={self.state}", f"--logical-change={TASK}",
                    f"--task-contract={self.task}",
                    f"--config={self.env['SINGULAR_JSON_CONFIG_FILE']}",
                    "--require-audit=1", "--legacy-schema-mode=warn",
                    f"--trusted-shell={self.bash}", "--policy-env-json={}")

    def command(self, argv, check=False, extra=None):
        env = dict(self.env, **(extra or {}))
        # Bound the entire process group we create, including grandchildren.
        proc = subprocess.Popen(list(map(str, argv)), cwd=self.repo, env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, start_new_session=True)
        try:
            output, error = proc.communicate(timeout=90)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.communicate()
            raise AssertionError("public command exceeded its 90-second bound")
        result = subprocess.CompletedProcess(argv, proc.returncode, output, error)
        if check and result.returncode:
            # Sanitize generated absolute paths before displaying diagnostics.
            diagnostic = (output + error).replace(str(self.home), "<fixture>").replace(str(self.root), "<engine>")
            raise AssertionError(f"fixture command {Path(str(argv[0])).name} failed "
                                 f"({result.returncode}): {diagnostic[-1800:]}")
        return result

    def git(self, *args):
        return self.command(["git", *args], check=True)

    def python(self, script, *args):
        return self.command([sys.executable, self.root / "engine" / script, *args], check=True)

    def engine(self, script, *args, check=False, extra=None):
        return self.command([self.bash, self.root / "engine" / script, *args], check, extra)

    def integrate(self, extra=None):
        return self.engine("integrate.sh", "--task", TASK, extra=extra)

    def events(self):
        return [json.loads(line) for line in self.events_path.read_text().splitlines()
                if line.strip()] if self.events_path.exists() else []

    def refresh_hashes(self):
        # Break A or G without also breaking E. Both audit locations represent
        # the same certificate; never leave an untouched sidecar as a fallback.
        shutil.copyfile(self.audit, self.sidecar)
        manifest = read(self.manifest)
        for item in manifest["artifacts"]:
            path = self.run / item["ref"]
            if path.is_file():
                item["sha256"] = sha(path)
                if "bytes" in item:
                    item["bytes"] = path.stat().st_size
        write(self.manifest, manifest)

    def break_part(self, part):
        if part == "host":
            value = read(self.report)
            value["verificationRequest"]["headSha"] = self.base
            write(self.report, value)
            self.refresh_hashes()
        elif part == "audit":
            value = read(self.audit)
            value["evidenceReviewed"] = ["reviewed-head-sha:" + self.base
                if ref.startswith("reviewed-head-sha:") else ref for ref in value["evidenceReviewed"]]
            write(self.audit, value)
            self.refresh_hashes()
        elif part == "review":
            value = read(self.ledger)
            value["logicalChanges"][TASK]["rounds"] = []
            write(self.ledger, value)
        elif part == "manifest":
            self.manifest.unlink()
        else:
            raise AssertionError("unknown fixture mutation")

    def make_waiver(self):
        packet = read(self.packet)
        packet["evidence"].append({"kind": "waiver", "ref": "decider:accept-waiver"})
        write(self.packet, packet)
        write(self.run / "packet.json", packet)
        # A alone fails: retain the host echo and E's bound audit bytes. A
        # missing audit would also break E and conceal a missing A guard.
        audit = read(self.audit)
        audit["verdict"] = "needs-fix"
        write(self.audit, audit)
        self.refresh_hashes()
        write(self.run / "decision-audit-needs-fix.json", {
            "taskId": TASK, "runId": RUN, "failureClass": "audit-needs-fix",
            "action": "accept-waiver"})
        self.commit_certificate()

    def commit_certificate(self):
        self.git("add", "docs/orchestration/packets")
        self.git("commit", "-qm", "fixture certificate mutation")
        self.target = self.git("rev-parse", "target").stdout.strip()

    def recovery_snapshot(self):
        lease = self.state / "leases" / (TASK + ".json")
        return self.task.read_bytes(), lease.read_bytes() if lease.exists() else None

    def restore_recovery_snapshot(self, snapshot):
        task, lease_bytes = snapshot
        self.task.write_bytes(task)
        lease = self.state / "leases" / (TASK + ".json")
        if lease_bytes is None:
            lease.unlink(missing_ok=True)
        else:
            lease.parent.mkdir(parents=True, exist_ok=True)
            lease.write_bytes(lease_bytes)


class Checks:
    def __init__(self):
        self.failures = []
        self.passes = 0

    def check(self, ok, criterion, label):
        if ok:
            self.passes += 1
            print(f"ok: {criterion}: {label}", flush=True)
        else:
            self.failures.append((criterion, label))
            print(f"CRITERION {criterion}\nFAIL: {criterion}: {label}", flush=True)

    def case(self, label, action, criterion="S0.4-2"):
        try:
            action()
        except (AssertionError, OSError, ValueError, KeyError, IndexError) as exc:
            self.check(False, criterion, f"{label}: {exc}")

    def finish(self):
        print(f"acceptance integration: {self.passes} assertions passed, "
              f"{len(self.failures)} failed", flush=True)
        return int(bool(self.failures))


def merged(f):
    return f.command(["git", "merge-base", "--is-ancestor", f.head, "target"]).returncode == 0


def assert_accepted(c, f, result, label, criterion="S0.4-2"):
    c.check(result.returncode == 0 and merged(f), criterion, label + " merges the candidate")
    c.check(f.git("show", "target:value.txt").stdout.strip() == "candidate",
            criterion, label + " publishes the candidate bytes")
    c.check(not (f.home / "runner-calls").exists(), criterion, label + " uses no provider")


def assert_refused(c, f, result, part, strict=True, criterion="S0.4-2", cycle=False):
    c.check(not merged(f), criterion, part + " refusal leaves candidate outside target")
    c.check(f.git("rev-parse", BRANCH).stdout.strip() == f.head,
            criterion, part + " refusal preserves the candidate branch")
    if not cycle:
        c.check(f.git("rev-parse", "target").stdout.strip() == f.target,
                criterion, part + " refusal leaves target HEAD unchanged")
    c.check(f.git("show", "target:value.txt").stdout.strip() == "base",
            criterion, part + " refusal keeps base bytes")
    c.check(not (f.repo / ".git/MERGE_HEAD").exists(), criterion, part + " leaves no pending merge")
    c.check(f.command(["git", "diff", "--cached", "--quiet"]).returncode == 0,
            criterion, part + " leaves no staged publication")
    # In a cycle the subject must be on the refusal's own record, not in task
    # prose, an event type, a JSON key, or an unrelated health message.
    reason = "\n".join(record_text(e) for e in refusal_events(f))
    if not cycle:
        reason += "\n" + result.stdout + result.stderr
    subjects = {"host": r"\bhost\b|verification", "audit": r"\baudit\b",
                "review": r"review[ -]+round|ledger|\bround\b",
                "manifest": r"manifest|evidence",
                "drift": r"manifest|evidence|stale|changed", "waiver": r"waiver|\baudit\b"}
    if not strict and part in ("host", "audit"):
        # Pin the historical skip itself: default behavior is not this row's
        # new refusal contract. In particular, "auditor" is not the word audit.
        identifies = f"skip {TASK}: no accepted auditor verdict or recorded accept-waiver" in reason.splitlines()
    else:
        # Recovery instructions cannot double as the fault's diagnosis. Each
        # diagnostic value gets its own line, so this preserves other fields.
        reason = re.sub(r"\bsingular\s+(?:drive|unpark|recover|review|integrate)\b[^\n]*",
                        "", reason, flags=re.I)
        identifies = bool(re.search(subjects[part], reason, re.I))
    c.check(identifies, criterion, part + " refusal identifies its subject")
    if strict and not cycle:
        c.check(result.returncode != 0, criterion, part + " refusal returns failure")


def refusal_events(f):
    return [event for event in f.events() if TASK in json.dumps(event)
            and not str(event.get("type", "")).lower().startswith("decider.")
            and re.search(r"refus|reject|park|blocked|integration\.failed", str(event.get("type", "")), re.I)]


def record_text(value):
    """Only diagnostic values; owner keys and task identity cannot be advice."""
    if not isinstance(value, dict):
        return ""
    pieces = []
    for key, item in value.items():
        if re.search(r"reason|message|detail|advice|next|resolv|remed|recover", key, re.I):
            if isinstance(item, str):
                pieces.append(item)
            elif isinstance(item, list):
                pieces.extend(s for s in item if isinstance(s, str))
        if isinstance(item, dict):
            pieces.append(record_text(item))
    return "\n".join(pieces)


def park_events(f):
    return [e for e in refusal_events(f)
            if re.search(r"park|blocked", str(e.get("type", "")), re.I)]


def assert_default_exit(c, f, snapshot):
    c.check(f.recovery_snapshot() == snapshot, "S0.4-4",
            "default refusal preserves task and lease")
    c.check(not refusal_events(f), "S0.4-4", "default refusal adds no refusal or park event")
    c.check(not park_events(f), "S0.4-4", "default refusal does not park the task")
    c.check(not any(e.get("type") == "autonomate.breaker_incremented" for e in f.events()),
            "S0.4-4", "default refusal adds no breaker event")
    health = f.engine("ops.sh", "health", "--json", check=True)
    c.check(json.loads(health.stdout)["breaker"]["consecFails"] == 0,
            "S0.4-4", "default refusal keeps the persisted breaker at zero")


def assert_exit(c, f, before):
    assert f.env.get("SINGULAR_ACCEPTANCE") == "every-path", "refusal exit requires every-path"
    events = refusal_events(f)
    c.check(bool(events), "S0.4-4", "refusal is a task-associated event")
    parks = park_events(f)
    c.check(bool(parks), "S0.4-4", "park event names the refused task")
    text = f.task.read_text()
    c.check(text != f.task_before and bool(re.search(r"^Status:\s*(blocked|parked|failed)\s*$", text, re.M)),
            "S0.4-4", "refused task changes from accepted to parked status")
    health = f.engine("ops.sh", "health", "--json", check=True).stdout
    lease = f.state / "leases" / (TASK + ".json")
    added_lines = "\n".join(line for line in text.splitlines()
                            if line not in f.task_before.splitlines())
    advice = " ".join(record_text(e) for e in events) + added_lines
    if lease.exists():
        advice += record_text(read(lease))
    c.check(bool(re.search(r"\b(human|operator|maintainer|person|user)\b", advice, re.I))
            and bool(re.search(r"singular\s+(drive|unpark|recover|review|integrate)\b", advice)),
            "S0.4-4", "durable refusal advice names resolver and public recovery verb")
    increments = [e for e in f.events() if e.get("type") == "autonomate.breaker_incremented"]
    c.check(len(increments) == before + 1, "S0.4-4", "refusal counts once toward the real breaker")
    breaker = json.loads(health)["breaker"]["consecFails"]
    c.check(breaker == before + 1, "S0.4-4", "public health confirms the persisted breaker charge")
    snapshot = [json.dumps(e, sort_keys=True) for e in events]
    f.engine("autonomate.sh", "--once")
    c.check(f.task.read_text() == text and park_events(f) == parks,
            "S0.4-4", "next cycle preserves parked task and adds no task park event")
    c.check(snapshot == [json.dumps(e, sort_keys=True) for e in refusal_events(f)],
            "S0.4-4", "next cycle emits no repeated refusal or parking transition")
    c.check(len([e for e in f.events() if e.get("type") == "autonomate.breaker_incremented"])
            == len(increments), "S0.4-4", "next cycle does not charge the same refusal again")
    next_health = f.engine("ops.sh", "health", "--json")
    c.check(json.loads(next_health.stdout)["breaker"]["consecFails"] == breaker,
            "S0.4-4", "next cycle preserves the durable breaker count")
    c.check(not merged(f), "S0.4-4", "next cycle still leaves refused candidate unmerged")
    c.check(not (f.home / "runner-calls").exists(), "S0.4-4", "parked work launches no provider")


def main(root):
    c = Checks()
    with tempfile.TemporaryDirectory(prefix="acceptance-integration-") as raw:
        scratch = Path(raw).resolve()
        # Exactly the same certificate, only the acceptance setting varies.
        for index, mode in enumerate((None, "driver-only", "", "every-path")):
            def positive(mode=mode, index=index):
                f = Fixture(root, scratch, "valid-" + str(index), mode)
                assert_accepted(c, f, f.integrate(), "valid " + repr(mode))
                target = f.git("rev-parse", "target").stdout
                count = sum(e.get("type") == "integration.integrated" for e in f.events())
                repeat = f.integrate()
                c.check(repeat.returncode == 0 and target == f.git("rev-parse", "target").stdout,
                        "S0.4-2", "repeated integration is a successful no-op")
                c.check(count == 1 == sum(e.get("type") == "integration.integrated" for e in f.events()),
                        "S0.4-2", "repeated integration emits no duplicate merge")
            c.case("valid candidate", positive)
        for index, mode in enumerate((None, "driver-only")):
            for part in ("review", "manifest"):
                def compatibility(mode=mode, index=index, part=part):
                    f = Fixture(root, scratch, f"compatibility-{index}-{part}", mode)
                    f.break_part(part)
                    assert_accepted(c, f, f.integrate(), "historically eligible missing " + part)
                c.case("legacy eligibility", compatibility)
        def positive_cycle():
            f = Fixture(root, scratch, "valid-cycle")
            assert_accepted(c, f, f.engine("autonomate.sh", "--once"), "valid every-path cycle")
            c.check(not park_events(f) and not re.search(r"^Status:\s*(blocked|parked|failed)\s*$",
                    f.task.read_text(), re.M), "S0.4-4", "valid cycle does not park the task")
            health = f.engine("ops.sh", "health", "--json", check=True)
            c.check(json.loads(health.stdout)["breaker"]["consecFails"] == 0,
                    "S0.4-4", "valid cycle leaves breaker at zero")
        c.case("valid loop control", positive_cycle, "S0.4-4")
        # Historical guards: assert their current skip/no-merge behavior too.
        for part in ("host", "audit"):
            for index, mode in enumerate((None, "driver-only")):
                def historical(part=part, mode=mode, index=index):
                    f = Fixture(root, scratch, f"historical-{part}-{index}", mode)
                    f.break_part(part)
                    result = f.integrate()
                    assert_refused(c, f, result, part, strict=False)
                    c.check(result.returncode == 0, "S0.4-2", "historical ineligible packet is skipped successfully")
                c.case("historical " + part, historical)
                def historical_cycle(part=part, mode=mode, index=index):
                    f = Fixture(root, scratch, f"default-cycle-{part}-{index}", mode)
                    f.break_part(part)
                    snapshot = f.recovery_snapshot()
                    result = f.engine("autonomate.sh", "--once")
                    c.check(result.returncode == 0 and not merged(f), "S0.4-2",
                            "default loop successfully skips ineligible " + part)
                    assert_default_exit(c, f, snapshot)
                c.case("historical loop " + part, historical_cycle, "S0.4-4")
        for part in ("host", "audit", "review", "manifest"):
            def refusal(part=part):
                f = Fixture(root, scratch, "strict-" + part)
                f.break_part(part)
                assert_refused(c, f, f.integrate(), part)
            c.case("strict " + part, refusal)
            def lifecycle(part=part):
                f = Fixture(root, scratch, "cycle-" + part)
                f.break_part(part)
                result = f.engine("autonomate.sh", "--once")
                assert_refused(c, f, result, part, cycle=True)
                assert_exit(c, f, 0)
            c.case("lifecycle " + part, lifecycle, "S0.4-4")
        for index, mode in enumerate((None, "driver-only", "every-path")):
            def drift(index=index, mode=mode):
                f = Fixture(root, scratch, "publication-drift-" + str(index), mode)
                marker = f.home / "drift-observed"
                result = f.integrate({"BOUNDARY_DRIFT_FILE": str(f.report),
                                      "BOUNDARY_DRIFT_MARKER": str(marker)})
                c.check(marker.exists(), "S0.4-2", "evidence changed inside the integration gate")
                if mode == "every-path":
                    assert_refused(c, f, result, "drift")
                else:
                    assert_accepted(c, f, result, "default publication drift remains eligible")
            c.case("publication drift", drift)
        def drift_cycle():
            f = Fixture(root, scratch, "cycle-drift")
            f.env.update(BOUNDARY_DRIFT_FILE=str(f.report),
                         BOUNDARY_DRIFT_MARKER=str(f.home / "drift-observed"))
            result = f.engine("autonomate.sh", "--once")
            c.check((f.home / "drift-observed").exists(), "S0.4-2", "cycle reaches drift interleaving")
            assert_refused(c, f, result, "drift", cycle=True)
            f.env.pop("BOUNDARY_DRIFT_FILE")
            assert_exit(c, f, 0)
        c.case("publication drift lifecycle", drift_cycle, "S0.4-4")
        # Recover a retained candidate after an unrelated target gate failure.
        # Only target-owned bytes change; G/A/D/E for the candidate stay valid.
        def recovery():
            f = Fixture(root, scratch, "recovery")
            task_before = f.task.read_bytes()
            before = [sha(p) for p in (f.audit, f.report, f.manifest, f.ledger)]
            (f.repo / "target-owned.txt").write_text("lint-error\n")
            f.git("add", "target-owned.txt")
            f.git("commit", "-qm", "target gate failure")
            failed = f.integrate()
            c.check(failed.returncode != 0 and not merged(f)
                    and any(e.get("type") == "integration.failed" for e in f.events()),
                    "S0.4-2", "unrelated target failure retains the unmerged candidate")
            (f.repo / "target-owned.txt").write_text("clean\n")
            f.git("add", "target-owned.txt")
            f.git("commit", "-qm", "repair target gate")
            # Restore only task control text. Keep the engine's retained
            # candidate lease and failure history for the actual retry.
            f.task.write_bytes(task_before)
            lease = f.state / "leases" / (TASK + ".json")
            c.check(lease.exists() and isinstance(read(lease).get("acceptedCandidate"), dict),
                    "S0.4-2", "target repair retains the engine's candidate lease")
            assert_accepted(c, f, f.integrate(), "retry after target repair")
            c.check(before == [sha(p) for p in (f.audit, f.report, f.manifest, f.ledger)],
                    "S0.4-2", "retry preserves independent audit, review and evidence")
        c.case("recovery", recovery)
        for index, (mode, switch) in enumerate(((None, None), ("driver-only", True),
                                                (None, False), ("driver-only", False),
                                                ("every-path", False), ("every-path", True))):
            def waiver(mode=mode, switch=switch, index=index):
                f = Fixture(root, scratch, "waiver-" + str(index), mode, switch)
                f.make_waiver()
                result = f.integrate()
                if mode == "every-path" or switch is False:
                    criterion = "S0.4-11" if switch is False else "S0.4-2"
                    assert_refused(c, f, result, "waiver", strict=mode == "every-path", criterion=criterion)
                    if mode != "every-path":
                        c.check(result.returncode == 0, "S0.4-11", "default denied waiver keeps successful skip")
                else:
                    assert_accepted(c, f, result, "eligible legacy waiver", "S0.4-11")
            c.case("waiver policy", waiver, "S0.4-11")
        for switch in (False, True):
            def waiver_cycle(switch=switch):
                f = Fixture(root, scratch, "cycle-waiver-" + str(switch), waiver=switch)
                f.make_waiver()
                result = f.engine("autonomate.sh", "--once")
                criterion = "S0.4-11" if switch is False else "S0.4-2"
                assert_refused(c, f, result, "waiver", criterion=criterion, cycle=True)
                assert_exit(c, f, 0)
            c.case("waiver lifecycle", waiver_cycle, "S0.4-4")
    return c.finish()


if __name__ == "__main__":
    sys.exit(main(Path(sys.argv[1]).resolve()))
