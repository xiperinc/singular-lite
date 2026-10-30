"""Frozen red-proof behavior checks. Only the engine supplies observations."""
from concurrent.futures import ThreadPoolExecutor
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
import time

ENGINE = Path(sys.argv[1]).resolve()
FIXTURE = Path(__file__).resolve().parent
COMMAND = "python3 proof/check.py"
PROOFS = ["proof/check.py", "proof/data.json"]
SCHEMA = "singular.orchestration.red-proof.v0"


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_json(path):
    return json.loads(path.read_bytes())


def execute(args, env, cwd, timeout=180):
    # A deadline bounds every child tree, including a broken host timeout.
    process = subprocess.Popen(args, env=env, cwd=cwd, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, start_new_session=True)
    try:
        output, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        raise AssertionError("fixture command exceeded its bounded deadline")
    return process.returncode, output.decode(errors="replace")


def driver_definitions():
    """Extract real top-level Bash functions; never substitute proof behavior.

    bash -n finds the closing brace correctly even with heredocs containing }.
    This is the same seam as tests extracting l1_validate_acceptance, but not
    tied to line numbers or to the location of the new phase in the driver.
    """
    lines = (ENGINE / "engine/l1-drive.sh").read_text().splitlines(keepends=True)
    blocks = []
    index = 0
    while index < len(lines):
        if not re.match(r"^[A-Za-z_][A-Za-z_0-9]*\(\) \{\s*$", lines[index]):
            index += 1
            continue
        for end in range(index + 1, len(lines)):
            if lines[end].strip() != "}" or not lines[end].startswith("}"):
                continue
            candidate = "".join(lines[index:end + 1])
            parsed = subprocess.run(["bash", "-n"], input=candidate, text=True,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if parsed.returncode == 0:
                blocks.append(candidate)
                index = end
                break
        else:
            raise AssertionError("cannot extract a complete driver function")
        index += 1
    return "\n".join(blocks)


class Project:
    def __init__(self, name, mode="enforce", policy="strict_test_first", base=1,
                 candidate=0, declared=True, repair_chain=False, setup=False):
        # The evidence broker creates an AF_UNIX socket below TMPDIR; keep
        # this prefix short enough for the platform's socket-path limit.
        self.temp = tempfile.TemporaryDirectory(prefix="rp-")
        self.path = Path(self.temp.name)
        self.root = self.path / "project"
        self.state = self.root / ".singular-state"
        self.worker = self.path / "worker"
        self.captures = self.path / "captures"
        self.task = self.root / "docs/orchestration/tasks/TASK-0001.md"
        self.run = self.state / "runs/RUN-PROOF"
        self.case = dict(base=base, candidate=candidate, repair_chain=repair_chain)
        self.mode, self.policy, self.declared, self.setup = mode, policy, declared, setup
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("SINGULAR_", "RP_", "RAILS_", "GIT_"))}
        self.env.update({
            "SINGULAR_ROOT": str(self.root), "SINGULAR_STATE_DIR": str(self.state),
            "SINGULAR_ENGINE_HOME": str(ENGINE), "SINGULAR_ENGINE_DIR": str(ENGINE / "engine"),
            "SINGULAR_HOME": str(self.path / "machine"), "SINGULAR_PUSH": "0",
            "SINGULAR_LOCAL_CONFIG_FILE": "/dev/null",
            "SINGULAR_ORCH_DIR": str(self.root / "docs/orchestration"),
            "SINGULAR_TASKS_DIR": str(self.task.parent), "SINGULAR_TARGET_BRANCH": "target",
            "SINGULAR_RUNNER": str(FIXTURE / "runner.py"),
            "SINGULAR_WORKTREE_COPY_PATHS_JSON": '["node_modules"]',
            "SINGULAR_MAX_RETRIES": "2", "SINGULAR_FIX_PROMPT_STRUCTURED": "0",
            "SINGULAR_RED_PROOF_TIMEOUT_SEC": "1", "SINGULAR_AUDIT_GATE_TIMEOUT_SEC": "1",
            "SINGULAR_GATE_TIMEOUT_SEC": "10", "SINGULAR_ACCEPTANCE": "every-path",
            "PYTHONDONTWRITEBYTECODE": "1", "TMPDIR": str(self.path / "tmp"),
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_AUTHOR_NAME": "fixture", "GIT_AUTHOR_EMAIL": "fixture",
            "GIT_COMMITTER_NAME": "fixture", "GIT_COMMITTER_EMAIL": "fixture",
            "RP_REAL_GIT": shutil.which("git"), "RP_GIT_CALLS": str(self.path / "git-calls.jsonl"),
            "RP_CAPTURES": str(self.captures), "RP_CASE": str(self.path / "case.json"),
        })
        for folder in (self.task.parent, self.path / "tmp", self.captures, self.path / "bin"):
            folder.mkdir(parents=True, exist_ok=True)
        (self.path / "bin/git").symlink_to(FIXTURE / "git-spy.py")
        self.env["PATH"] = str(self.path / "bin") + os.pathsep + self.env["PATH"]
        (self.path / "case.json").write_text(json.dumps(self.case))
        # Deliberately a non-exported setting: Python must receive it explicitly.
        (self.root / "singular.config.sh").write_text(
            "# Synthetic proof configuration.\n" +
            (f"SINGULAR_RED_PROOF={mode}\n" if mode is not None else ""))
        (self.root / ".gitignore").write_text(
            ".singular-state/\n.worktrees/\n.singular-evidence/\n.singular-cache/\n"
            "node_modules/\nworker-sentinel\n")
        (self.root / "widget.txt").write_text("base\n")
        (self.root / "proof").mkdir()
        (self.root / "proof/check.py").write_text("raise SystemExit(89) # stale base proof\n")
        (self.root / "proof/data.json").write_text('{"base": 89, "candidate": 89}\n')
        fields = f"Proof command: `{COMMAND}`\nProof tests: {json.dumps(PROOFS)}\n" if declared else ""
        self.task.write_text(
            "# TASK-0001: Synthetic widget\n\nStatus: ready\nArea: widget\n"
            "Target branch: `target`\nWorker branch: `agent/widget/TASK-0001-fixture`\n"
            f"Test policy: `{policy}`\nGate command: `true`\n" +
            ("Risk tier: high\n" if repair_chain else "") + fields +
            "Dispatch mode: canonical\nDepends on: []\n\n## Objective\n\nWrite a widget.\n\n"
            "## Scope\n\nOwned files:\n\n- `widget.txt`\n- `proof/check.py`\n- `proof/data.json`\n\n"
            "Forbidden files:\n\n- Any file outside the owned scope.\n\n"
            "## Acceptance Criteria\n\n- The widget satisfies the proof.\n")
        prompts = self.root / "docs/orchestration/prompts"
        prompts.mkdir()
        for filename in ("l2-test-first-developer.md", "auditor.md", "decider.md"):
            shutil.copyfile(ENGINE / "templates/prompts" / filename, prompts / filename)
        self.git("init", "-q")
        self.git("symbolic-ref", "HEAD", "refs/heads/target")
        self.git("add", ".")
        self.git("-c", "commit.gpgsign=false", "commit", "-qm", "initial")
        self.base = self.git("rev-parse", "HEAD").strip()
        require(not self.git("remote").strip(), "fixture unexpectedly has a remote")
        (self.root / "node_modules").mkdir()
        (self.root / "node_modules/provenance").write_text("main\n")
        if setup:
            self.env["RP_SETUP_FAIL"] = "1"

    def close(self):
        self.temp.cleanup()

    def git(self, *args, cwd=None):
        rc, output = execute(["git", "-C", str(cwd or self.root), *args], self.env, self.path, 20)
        require(rc == 0, "fixture git failed: " + output[-600:])
        return output

    def prepare_candidate(self):
        self.git("worktree", "add", "-q", "-b", "agent/widget/TASK-0001-fixture", str(self.worker), self.base)
        self.run.mkdir(parents=True)
        (self.state / "leases").mkdir()
        (self.state / "leases/TASK-0001.json").write_text(json.dumps({
            "taskId": "TASK-0001", "area": "widget", "owner": "l1",
            "runId": "RUN-PROOF", "baseSha": self.base, "branch": "agent/widget/TASK-0001-fixture",
            "worktree": str(self.worker), "retryCount": 0, "status": "running",
            "ownedFiles": ["widget.txt", *PROOFS], "forbiddenFiles": [], "maxRetries": 2,
            "productPassStarted": True,
        }))
        prompt = self.path / "prompt.md"
        prompt.write_text("fixture worker prompt\n")
        rc, output = execute([str(FIXTURE / "runner.py"), "--level", "l2", "--worktree", str(self.worker),
                              "--run-id", "RUN-PROOF", "--prompt-file", str(prompt),
                              "--output-last-message", str(self.run / "packet.json")], self.env, self.path)
        require(rc == 0, "fixture worker failed: " + output[-600:])
        self.head = self.git("rev-parse", "HEAD", cwd=self.worker).strip()
        # Uncommitted tracked, staged and ignored bytes catch a restore/reset
        # that recreates the original head but destroys unrelated worker work.
        (self.worker / "widget.txt").write_text("worker staged change\n")
        self.git("add", "widget.txt", cwd=self.worker)
        (self.worker / "widget.txt").write_text("worker unstaged change\n")
        self.before = self.snapshot()
        (self.path / "git-calls.jsonl").write_text("")

    def prepare_phase(self, definitions, attempt=1):
        self.prepare_candidate()
        defs = self.path / "functions.sh"
        defs.write_text(definitions)
        self.phase_rc, self.phase_output = execute(
            ["bash", str(FIXTURE / "phase.sh"), str(ENGINE), str(self.path), str(defs), str(attempt)],
            self.env, self.root, 35)
        require(self.phase_rc == 0, "phase harness failed: " + self.phase_output[-700:])
        return read_json(self.path / "phase-result.json")

    def snapshot(self):
        return {
            "head": self.git("rev-parse", "HEAD", cwd=self.worker),
            "index": self.git("diff", "--cached", "--binary", cwd=self.worker),
            "status": self.git("status", "--porcelain=v1", "--untracked-files=all", cwd=self.worker),
            "files": {p: (self.worker / p).read_bytes() for p in
                      ["widget.txt", *PROOFS, "node_modules/provenance", "worker-sentinel"]},
        }

    def git_calls(self):
        path = self.path / "git-calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def proof_adds(self, commit=None):
        calls = []
        for call in self.git_calls():
            args = call["argv"]
            if "worktree" in args and "add" in args and any(str(self.state) + "/" in arg for arg in args):
                if commit is None or commit in args:
                    calls.append(call)
        return calls

    def assert_worker_untouched(self):
        require(self.snapshot() == self.before, "S1.1-2: proof changed worker HEAD/index/files/status")
        for call in self.git_calls():
            args = call["argv"]
            cwd = Path(call["cwd"])
            if "-C" in args:
                cwd = Path(args[args.index("-C") + 1])
            require(not (cwd.resolve() == self.worker.resolve() and
                         any(verb in args for verb in ("checkout", "reset", "restore"))),
                    "S1.1-2: host checked out/reset/restored a file in the worker")
        require((self.root / "node_modules/provenance").read_text() == "main\n",
                "S1.1-2: proof modified main dependencies")

    def records(self):
        records = []
        for path in (self.state / "runs").rglob("*.json"):
            try:
                record = read_json(path)
            except (ValueError, OSError):
                continue
            if isinstance(record, dict) and record.get("schema") == SCHEMA:
                records.append((path, record))
        return records


def validate_record(project, path, record, outcome, attempt, head):
    require(record.get("outcome") == outcome, f"S1.1-1: wanted {outcome}, got {record.get('outcome')}")
    expected = {"baseSha": project.base, "headSha": head,
                "treeSha": project.git("rev-parse", head + "^{tree}").strip(),
                "attempt": attempt, "command": COMMAND, "commandSha256": digest(COMMAND.encode())}
    for key, value in expected.items():
        require(record.get(key) == value, "S1.1-7: incorrect " + key)
    files = record.get("proofFiles")
    require(isinstance(files, list) and len(files) == len(PROOFS), "S1.1-7: missing proof file digests")
    expected_files = {name: digest(subprocess.check_output(
        [project.env["RP_REAL_GIT"], "-C", str(project.root), "show", head + ":" + name], env=project.env))
        for name in PROOFS}
    require({item.get("path"): item.get("sha256") for item in files} == expected_files,
            "S1.1-7: proof file hashes do not bind candidate bytes")
    schemas = []
    for schema_path in (ENGINE / "schemas").rglob("*.schema.json"):
        schema = read_json(schema_path)
        if schema.get("properties", {}).get("schema", {}).get("const") == SCHEMA:
            schemas.append(schema_path)
    require(schemas, "S1.1-7: no shipped schema for the proof record")
    rc, output = execute(["bash", "-c", 'source "$1/engine/lib.sh"; singular_json_schema_check "$(cat "$2")" "$3"',
                          "schema-check", str(ENGINE), str(path), str(schemas[0])], project.env, project.root)
    require(rc == 0, "S1.1-7: record fails its schema: " + output[-300:])
    if outcome == "waived":
        require(not project.proof_adds(), "S1.1-1: waived proof was executed")
        return
    for side, commit in (("base", project.base), ("candidate", head)):
        observation = record.get(side)
        require(isinstance(observation, dict), "S1.1-7: missing " + side + " observation")
        reference = observation.get("logRef")
        require(isinstance(reference, str) and reference, "S1.1-7: missing " + side + " log reference")
        log = Path(reference)
        if not log.is_absolute():
            log = path.parent / log
        require(project.state / "runs" in log.resolve().parents, "S1.1-7: log is not retained in the run folder")
        require(log.is_file() and digest(log.read_bytes()) == observation.get("logSha256"),
                "S1.1-7: " + side + " log hash mismatch")
        observations = [json.loads(line.split("=", 1)[1]) for line in log.read_text().splitlines()
                        if line.startswith("PROOF_OBSERVATION=")]
        if project.setup:
            require(observation.get("setupError"), "S1.1-1: failed setup is not a test failure")
            continue
        require(not observation.get("setupError"), "fixture command unexpectedly failed setup")
        require(observations, "S1.1-2: proof command was not actually observed on " + side)
        seen = observations[-1]
        require(seen["side"] == side and seen["head"] == commit, "S1.1-2: wrong observed commit")
        for key in ("cwd", "tmp"):
            require(project.state in Path(seen[key]).resolve().parents,
                    "S1.1-2: proof " + key + " must be below state, not TMPDIR or worker")
        require(seen["dependency"] == "main\n", "S1.1-2: dependencies came from the worker")
        require(seen["proofs"] == expected_files, "S1.1-2: base did not use candidate proof files")


def phase_case(definitions, name, *, mode="enforce", policy="strict_test_first", base=1,
               candidate=0, declared=True, outcome="proved", infra=False, setup=False, attempt=1):
    project = Project(name, mode, policy, base, candidate, declared, setup=setup)
    try:
        result = project.prepare_phase(definitions, attempt)
        project.assert_worker_untouched()
        records = project.records()
        disabled = mode in (None, "off") or not declared
        if disabled:
            require(not records and not project.proof_adds(), "S1.1: off/undeclared task ran or recorded proof")
            require(result["exit"] == 0 and not result["failure"], "S1.1: disabled proof refused the phase")
            return
        require(records, "S1.1-1/7: host produced no red-proof record")
        # Archives may duplicate a record; the live record for this attempt is
        # allowed any filename within the run directory.
        matches = [(p, r) for p, r in records if r.get("attempt") == attempt]
        require(matches, "S1.1-7: no record for the current attempt")
        path, record = min(matches, key=lambda item: len(item[0].parts))
        validate_record(project, path, record, outcome, attempt, project.head)
        allowed = mode == "observe" or outcome in ("proved", "waived")
        require((result["exit"] == 0) == allowed, "S1.1-1/5: wrong phase acceptance decision")
        require((not result["failure"]) == allowed, "S1.1-5: observe leaked a product failure into the driver")
        require(result["repairs"] == 0, "S1.1-4: phase itself charged product repair")
        if outcome == "waived":
            return
        base_observation, green = record["base"], record["candidate"]
        if not setup:
            expected_exit = 124 if base == "timeout" else 1 if base == "mutate" else base
            require(base_observation.get("rawExitCode") == expected_exit,
                    "S1.1-1: base raw exit was lost or inferred from log prose")
            require(bool(base_observation.get("timedOut")) == (base == "timeout"),
                    "S1.1-1: timeout was not distinguished from product failure")
            expected_base = "inconclusive-infrastructure" if infra else (
                "green" if policy == "characterization_first" and base == 0 else
                "not-demonstrated" if base == 0 else "red")
            require(base_observation.get("outcome") == expected_base,
                    "S1.1-1: base observation was not classified by exit and infrastructure status")
            require(green.get("rawExitCode") == candidate, "S1.1-1: candidate exit was not preserved")
            require(green.get("outcome") == ("green" if candidate == 0 else "green-failed"),
                    "S1.1-1: candidate green classification is wrong")
        if infra:
            require(len(project.proof_adds(project.base)) == 2,
                    "S1.1-4: infrastructure needs exactly one retry of the base observation")
            require(len(project.proof_adds()) <= 4, "S1.1-4: infrastructure retry was unbounded")
        else:
            require(len(project.proof_adds(project.base)) == 1,
                    "S1.1-1: ordinary base observation did not run exactly once")
            require(len(project.proof_adds(project.head)) == 1,
                    "S1.1-1: ordinary candidate observation did not run exactly once")
    finally:
        project.close()


def integration_case(name, mode, base, candidate, repair=False, infra=False):
    project = Project(name, mode, base=base, candidate=candidate, repair_chain=repair)
    try:
        rc, output = execute(["bash", str(ENGINE / "engine/l1-drive.sh"), "TASK-0001"],
                             project.env, project.root, 210)
        (project.path / "drive.log").write_text(output)
        snapshots = sorted(project.captures.glob("worker-*-snapshot.json"))
        require(snapshots, "control failure: driver never ran fixture worker: " + output[-600:])
        runs = list((project.state / "runs").glob("RUN-*"))
        require(len(runs) == 1, "control failure: expected one ordinary drive")
        project.run = runs[0]
        lease = read_json(project.state / "leases/TASK-0001.json")
        records = project.records()
        if not records:
            # Prove this is a missing-feature failure rather than a broken
            # packet, audit, preflight, runner protocol, or fixture setup.
            audit_log = project.run / "auditor-codex.log"
            detail = audit_log.read_text()[-1600:] if audit_log.exists() else output[-1600:]
            require(rc == 0 and lease.get("status") == "accepted",
                    "control failure before proof: " + detail)
        require(records, "S1.1-1/7: ordinary drive produced no host proof record (drive exit " + str(rc) + ")")
        snapshot = read_json(snapshots[-1])
        worktree = Path(snapshot["worktree"])
        require(all((worktree / p).is_file() and digest((worktree / p).read_bytes()) == sha
                    for p, sha in snapshot["files"].items()), "S1.1-2: drive damaged worker snapshot")
        events = [json.loads(line) for line in (project.state / "events.ndjson").read_text().splitlines()]
        repairs = [e for e in events if e["type"] == "l1.product_repair_budget_consumed"]
        accepted = [e for e in events if e["type"] == "l1.task_accepted"]
        if repair:
            require(len(snapshots) == 3, "S1.1-4: both product proof failures must return to worker")
            for n, phrase in ((2, "not-demonstrated"), (3, "green-failed")):
                feedback = (project.captures / f"worker-{n}-prompt.md").read_text().lower()
                require(phrase in feedback, "S1.1-4: worker was not told " + phrase)
                require("base" in feedback if n == 2 else "candidate" in feedback,
                        "S1.1-4: feedback lacks a plain explanation of the failed observation")
            require(len(repairs) == 2 and lease.get("retryCount") == 2,
                    "S1.1-4: product failures were not charged exactly twice")
            wanted = {1: "not-demonstrated", 2: "green-failed", 3: "proved"}
            for n, expected in wanted.items():
                matching = [(p, r) for p, r in records if r.get("attempt") == n]
                require(matching, "S1.1-7: lost proof record for repair attempt " + str(n))
                head = read_json(project.captures / f"worker-{n}-snapshot.json")["head"]
                validate_record(project, *matching[0], expected, n, head)
        elif infra:
            require(rc != 0 and lease.get("status") != "accepted" and not accepted,
                    "S1.1-1/4: inconclusive proof was accepted")
            require(len(snapshots) == 1 and not repairs and lease.get("retryCount") == 0,
                    "S1.1-4: infrastructure charged product repair or reran the worker")
            require(len(project.proof_adds(project.base)) == 2, "S1.1-4: retry count is not one")
            require("Status: blocked" in project.task.read_text(), "S1.1-4: infrastructure task not parked")
            decisions = [e for e in events if e["type"] == "decision.recorded" and
                         e.get("data", {}).get("decision") in ("escalate-parked", "escalate-infra")]
            require(len(decisions) == 1, "S1.1-4: refusal must park once with an event")
            advice = (project.root / "docs/orchestration/decisions.md").read_text().lower()
            require("singular unpark task-0001" in advice and
                    any(word in advice for word in ("operator", "person", "environment")),
                    "S1.1-4: park reason must identify resolution owner and public command")
            require(not list((project.state / "inbox").glob("*.json")), "S1.1-4: refused packet published")
            validate_record(project, *records[0], "inconclusive-infrastructure", 1, snapshot["head"])
            # The next scheduler selection must not dispatch the parked task.
            # Exercise the real selector without starting the autonomous loop.
            before_events = (project.state / "events.ndjson").read_bytes()
            before_calls = project.git_calls()
            selector_rc, ready = execute(["bash", "-c",
                'source "$1/engine/lib.sh"; singular_list_ready_tasks', "next-selection", str(ENGINE)],
                project.env, project.root)
            require(selector_rc == 0 and "TASK-0001" not in ready,
                    "S1.1-4: parked task selected on the next cycle")
            require((project.state / "events.ndjson").read_bytes() == before_events and
                    project.git_calls() == before_calls, "S1.1-4: next selection repeated refusal/proof")
            return
        else:
            require(len(snapshots) == 1 and not repairs, "S1.1-5: observe caused a repair")
            validate_record(project, *records[0], "not-demonstrated", 1, snapshot["head"])
        require(rc == 0 and lease.get("status") == "accepted" and len(accepted) == 1,
                "S1.1-4/5: eligible candidate not accepted: " + output[-500:])
        packet = read_json(project.run / "packet.json")
        require(packet["status"] == "accepted" and packet["headSha"] == snapshot["head"],
                "S1.1-4/5: wrong candidate published")
        require((project.state / "inbox" / (project.run.name + ".json")).is_file(),
                "S1.1-4/5: eligible packet not published")
    finally:
        project.close()


def main():
    started = time.monotonic()
    definitions = driver_definitions()
    failures = []
    cases = []
    # The four V rows under every setting; both classic waiver policies.
    for mode in ("off", "observe", "enforce"):
        for policy in ("strict_test_first", "characterization_first", "test_after_waiver", "not_applicable"):
            cases.append((f"V-{mode}-{policy}", dict(mode=mode, policy=policy,
                         base=0 if policy == "characterization_first" else 1,
                         outcome="waived" if policy in ("test_after_waiver", "not_applicable") else "proved")))
        cases.append((f"V-{mode}-undeclared", dict(mode=mode, declared=False)))
    cases.extend([
        ("unset", dict(mode=None)),
        ("base-zero", dict(base=0, outcome="not-demonstrated")),
        ("base-seven", dict(base=7)),
        ("candidate-one", dict(candidate=1, outcome="green-failed")),
        ("candidate-seven", dict(candidate=7, outcome="green-failed")),
        ("characterization-red", dict(policy="characterization_first", outcome="not-demonstrated")),
        ("characterization-green-failed", dict(policy="characterization_first", base=0,
                                              candidate=1, outcome="green-failed")),
        ("base-126-green", dict(base=126, outcome="base-cannot-run", infra=True)),
        ("base-127-green", dict(base=127, outcome="base-cannot-run", infra=True)),
        ("base-126-failed", dict(base=126, candidate=1, outcome="inconclusive-infrastructure", infra=True)),
        ("base-127-failed", dict(base=127, candidate=1, outcome="inconclusive-infrastructure", infra=True)),
        ("base-timeout", dict(base="timeout", outcome="inconclusive-infrastructure", infra=True)),
        ("base-source-mutated", dict(base="mutate", outcome="inconclusive-infrastructure", infra=True)),
        ("setup-failed", dict(setup=True, outcome="inconclusive-infrastructure", infra=True)),
        ("attempt-binding", dict(attempt=7)),
    ])
    # Observe records each failure class but never routes it to product repair.
    for name, options in list(cases):
        if options.get("outcome") in ("not-demonstrated", "green-failed", "base-cannot-run", "inconclusive-infrastructure"):
            cases.append(("observe-" + name, dict(options, mode="observe")))

    def check(name, fn, *args, **kwargs):
        try:
            fn(*args, **kwargs)
            return name, None
        except Exception as error:
            return name, f"{type(error).__name__}: {error}"

    # Missing phase is one clear feature failure, not dozens of fixture errors.
    if "run_red_proof_phase() {" not in definitions:
        failures.append(("phase-matrix", "S1.1: host red-proof phase is absent (run_red_proof_phase); "
                         + str(len(cases)) + " specified cases cannot execute"))
    else:
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(check, name, phase_case, definitions, name, **options) for name, options in cases]
            for future in futures:
                name, error = future.result()
                if error:
                    failures.append((name, error))
                else:
                    print("PASS red-proof " + name, flush=True)
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(check, name, integration_case, name, **options) for name, options in [
            ("drive-product-repairs", dict(mode="enforce", base=0, candidate=0, repair=True)),
            ("drive-infrastructure", dict(mode="enforce", base=126, candidate=1, infra=True)),
            ("drive-observe", dict(mode="observe", base=0, candidate=0)),
        ]]
        for future in futures:
            name, error = future.result()
            if error:
                failures.append((name, error))
            else:
                print("PASS red-proof " + name, flush=True)
    for name, error in failures:
        print("FAIL red-proof " + name + ": " + error, flush=True)
    print(f"red-proof: {len(failures)} failed groups; {time.monotonic() - started:.1f}s", flush=True)
    return bool(failures)


if __name__ == "__main__":
    sys.exit(main())
