"""Public-boundary tests. Only the provider is stubbed; all judges are real."""
import difflib
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

sys.dont_write_bytecode = True
TASK = "TASK-0001"
BRANCH = "agent/widget/TASK-0001"


def read(path):
    return json.loads(path.read_text())


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n")


def edit(path, change):
    value = read(path)
    change(value)
    write(path, value)


class Failure(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Failure(message)


def scratch_parent():
    # Reserve space for the generated run id and broker socket on macOS.
    parent = tempfile.gettempdir()
    return parent if len(os.fsencode(parent)) <= 24 else "/tmp"


def resolution_text(value):
    """Read diagnostic values, never identity keys or ordinary worker owners."""
    parts = []
    if isinstance(value, dict):
        for key, item in value.items():
            if key in ("nextOwner", "resolver", "resolutionOwner"):
                if isinstance(item, str) and item.strip():
                    parts.append(json.dumps({key: item}))
            elif re.search(r"reason|advice|resolv|remed|recover|message|detail|error", key, re.I):
                parts.append(json.dumps(item))
            elif isinstance(item, (dict, list)):
                parts.append(resolution_text(item))
    elif isinstance(value, list):
        parts.extend(resolution_text(item) for item in value)
    return "\n".join(parts)


class Fixture:
    def __init__(self, engine, bash, temporary):
        self.engine = Path(engine)
        self.bash = bash
        self.tmp = Path(temporary)
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        self.orch = self.repo / "docs/orchestration"
        self.state = self.repo / ".singular-state"
        self.task = self.orch / "tasks" / (TASK + ".md")
        self.task.parent.mkdir(parents=True)
        self.state.mkdir()
        (self.tmp / "tmp").mkdir()
        (self.tmp / "home").mkdir()
        # Whitelist the environment; no user config, real provider or inherited
        # engine selection can escape this disposable project.
        self.env = {
            "PATH": os.environ["PATH"], "LC_ALL": "C", "PYTHONDONTWRITEBYTECODE": "1",
            "HOME": str(self.tmp / "home"), "TMPDIR": str(self.tmp / "tmp"), "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0",
            "GIT_AUTHOR_NAME": "fixture", "GIT_AUTHOR_EMAIL": "fixture",
            "GIT_COMMITTER_NAME": "fixture", "GIT_COMMITTER_EMAIL": "fixture",
            "SINGULAR_ROOT": str(self.repo), "SINGULAR_ENGINE_HOME": str(self.engine),
            "SINGULAR_ENGINE_DIR": str(self.engine / "engine"),
            "SINGULAR_BASH_BIN": bash, "SINGULAR_STATE_DIR": str(self.state),
            "SINGULAR_ORCH_DIR": str(self.orch),
            "SINGULAR_TASKS_DIR": str(self.task.parent),
            "SINGULAR_RUNS_DIR": str(self.state / "runs"),
            "SINGULAR_INBOX_DIR": str(self.state / "inbox"),
            "SINGULAR_LEASES_DIR": str(self.state / "leases"),
            "SINGULAR_EVENTS_FILE": str(self.state / "events.ndjson"),
            "SINGULAR_WORKTREES_DIR": str(self.repo / ".worktrees"),
            "SINGULAR_TARGET_BRANCH": "target", "SINGULAR_PUSH": "0",
            "SINGULAR_GIT_L0_NAME": "fixture", "SINGULAR_GIT_L0_EMAIL": "fixture",
            "SINGULAR_GIT_L1_NAME": "fixture", "SINGULAR_GIT_L1_EMAIL": "fixture",
            "SINGULAR_AUDIT_VERIFY": "1", "SINGULAR_GENERATE": "0",
            "SINGULAR_AUTO_INTEGRATE": "0", "SINGULAR_SLEEP": "0",
            "SINGULAR_LIMIT_SLEEPTHROUGH": "0", "SINGULAR_RESOURCE_THROTTLE": "0",
            "SINGULAR_MAX_CONSEC_FAILS": "5", "SINGULAR_DETACHED_DISPATCH": "0",
        }
        runner = self.tmp / "runner"
        shutil.copyfile(Path(__file__).with_name("runner.py"), runner)
        runner.chmod(0o755)
        for key in ("SINGULAR_RUNNER", "SINGULAR_CODEX_RUNNER", "SINGULAR_CLAUDE_RUNNER",
                    "SINGULAR_ROLE_RUNNER_AUDITOR", "SINGULAR_ROLE_RUNNER_IMPLEMENTER"):
            self.env[key] = str(runner)
        self.git("init", "-q")
        self.git("switch", "-q", "-c", "target")
        self.git("config", "user.name", "fixture")
        self.git("config", "user.email", "fixture")
        (self.repo / ".gitignore").write_text(
            ".singular-state/\n.worktrees/\n.singular-evidence/\n")
        self.task.write_text("""# TASK-0001: Synthetic widget

Status: ready
Area: widget
Target branch: `target`
Worker branch: `agent/widget/TASK-0001`
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
        prompts = self.orch / "prompts"
        prompts.mkdir()
        for name in ("l2-test-first-developer.md", "auditor.md", "decider.md"):
            shutil.copyfile(self.engine / "templates/prompts" / name, prompts / name)
        self.git("add", ".")
        self.git("commit", "-qm", "synthetic base")
        require(not self.git("remote").strip(), "fixture must have no remote")
        result = self.command("l1-drive.sh", TASK, timeout=180)
        if result.returncode:
            for log in (self.state / "runs").glob("*/*"):
                if log.is_file() and log.suffix in (".log", ".err"):
                    content = log.read_text(errors="replace")
                    if "audit" in log.name or "Traceback" in content or "Error" in content:
                        result.stdout += "\n" + log.name + ":\n" + content
        require(result.returncode == 0, "valid drive failed: " + self.safe(result.stdout))
        packets = list((self.state / "inbox").glob("*.json"))
        require(len(packets) == 1, "valid drive did not queue exactly one packet")
        self.packet = packets[0]
        self.run = read(self.packet)["runId"]
        self.run_dir = self.state / "runs" / self.run
        self.audit = self.run_dir / "audit.json"
        self.host = self.run_dir / "audit-verification.json"
        self.manifest = self.run_dir / "evidence-manifest.json"
        self.ledger = self.state / "review-policy/ledger.json"
        self.lease = self.state / "leases" / (TASK + ".json")
        self.dest = self.orch / "packets/imported" / TASK / (self.run + ".json")
        self.sidecar = self.dest.with_name(self.run + ".audit.json")
        self.head = read(self.packet)["headSha"]
        require(read(self.packet)["status"] == "accepted", "baseline packet not accepted")
        self.saved = self.tmp / "accepted-baseline"
        shutil.copytree(self.repo, self.saved, symlinks=True)
        self.base_env = dict(self.env)

    def safe(self, text):
        return text.replace(str(self.tmp), "<scratch>").replace(str(self.engine), "<engine>")[-20000:]

    def run_command(self, argv, timeout=90):
        # Kill only the process group this test started, including its children.
        process = subprocess.Popen([str(x) for x in argv], cwd=self.repo, env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, start_new_session=True)
        try:
            output, _ = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            raise Failure("bounded command timed out: " + Path(str(argv[0])).name)
        return subprocess.CompletedProcess(argv, process.returncode, output)

    def command(self, script, *args, timeout=90):
        return self.run_command([self.bash, self.engine / "engine" / script, *args], timeout)

    def git(self, *args):
        result = self.run_command(["git", *args])
        require(result.returncode == 0, "fixture git failed: " + self.safe(result.stdout))
        return result.stdout

    def reset(self, mode="every-path"):
        # Restore only our disposable fixture, never the source worktree.
        shutil.rmtree(self.repo)
        shutil.copytree(self.saved, self.repo, symlinks=True)
        self.env = dict(self.base_env)
        if mode is not None:
            self.env["SINGULAR_ACCEPTANCE"] = mode

    def events(self):
        path = self.state / "events.ndjson"
        return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]

    def task_status(self):
        match = re.search(r"^Status:\s*(\S+)\s*$", self.task.read_text(), re.M | re.I)
        require(match, "task has no status line")
        return match[1].lower()

    def import_packet(self):
        return self.command("import-packet.sh", self.packet)

    def accepted(self, result, packet=None):
        require(result.returncode == 0, "eligible import refused: " + self.safe(result.stdout))
        require(self.dest.is_file(), "successful import did not publish a packet")
        expected = read(self.packet) if packet is None else packet
        require(read(self.dest) == expected, "published packet differs from candidate")
        require(self.sidecar.is_file() and self.sidecar.read_bytes() == self.audit.read_bytes(),
                "published audit differs from independent audit")
        require(self.git("rev-parse", BRANCH).strip() == self.head,
                "import changed the candidate branch")

    def refused(self, result, reason, authority_before=None):
        # A current admission refusal may encounter authority published earlier.
        require(result.returncode != 0, "invalid candidate imported (guard absent)")
        require(re.search(reason, result.stdout, re.I),
                "refusal does not explain the broken part: " + self.safe(result.stdout))
        if authority_before is None:
            require(not self.dest.exists(), "refusal published an authoritative packet")
            require(not any(e["type"] == "packet.imported" for e in self.events()),
                    "refusal emitted a successful publication event")
        else:
            require(self.dest.read_bytes() == authority_before,
                    "refusal replaced pre-existing authority")
        require(self.git("rev-parse", BRANCH).strip() == self.head,
                "refusal destroyed or changed retained candidate")

    def rebind_manifest(self):
        # Keep E true when deliberately breaking A. This updates hashes only;
        # the production schema/binding checks and acceptance rule still run.
        def change(doc):
            for item in doc["artifacts"]:
                path = self.run_dir / item["ref"]
                if path.is_file():
                    item["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
                    if "sizeBytes" in item:
                        item["sizeBytes"] = path.stat().st_size
        edit(self.manifest, change)

    def rounds(self, change):
        def mutate(doc):
            entries = [entry for entry in doc["logicalChanges"].values()
                       if any(row.get("runId") == self.run for row in entry.get("rounds", []))]
            require(len(entries) == 1, "fixture review unit is ambiguous")
            change(entries[0]["rounds"])
        edit(self.ledger, mutate)

    def waiver(self):
        edit(self.audit, lambda d: d.update(verdict="needs-fix", findings=["synthetic concern"],
                                           requiredFixes=["synthetic concern"]))
        edit(self.packet, lambda d: d["evidence"].append(
            {"kind": "waiver", "ref": "decider:accept-waiver"}))
        write(self.run_dir / "decision-audit-needs-fix.json", {
            "schema": "singular.orchestration.decider-verdict.v0", "taskId": TASK,
            "failureClass": "audit-needs-fix", "action": "accept-waiver",
            "rationale": "synthetic legacy permission", "nextOwner": "l1",
        })
        self.rebind_manifest()

    def breaker(self):
        result = self.command("ops.sh", "breaker", "show")
        match = re.search(r"breaker: (\d+)/", result.stdout)
        # Today's show verb returns 1 when its optional counter file is absent,
        # after printing a valid zero count. Judge the observable count.
        require(result.returncode in (0, 1) and match,
                "public breaker status unavailable: " + self.safe(result.stdout))
        return int(match[1])

    def cycle_command(self, real=False):
        if real:
            self.env.pop("SINGULAR_RECONCILE_SCRIPT", None)
            return [self.bash, self.engine / "engine/autonomate.sh", "--once"]
        # The real reconciler imports and reports its real counters. Apply mode
        # excludes unrelated scheduling/integration; nothing fabricates counts.
        adapter = self.tmp / "reconcile-import-only"
        adapter.write_text('#!/usr/bin/env bash\nexec "$SINGULAR_BASH_BIN" '
                           '"$SINGULAR_ENGINE_HOME/engine/reconcile.sh" --apply\n')
        adapter.chmod(0o755)
        self.env["SINGULAR_RECONCILE_SCRIPT"] = str(adapter)
        return [self.bash, self.engine / "engine/autonomate.sh", "--once"]

    def cycle(self, real=False):
        return self.run_command(self.cycle_command(real), timeout=120)

    def refusal_exit(self, mutate, reason, racing=False, real=False):
        self.reset()
        if not racing:
            mutate(self)
        before = len(self.events())
        status_before = self.task_status()
        task_before = self.task.read_text()
        lease_before = read(self.lease)
        result = self.race(mutate, self.cycle_command(real)) if racing else self.cycle(real)
        require(result.returncode == 0, "loop did not finish one cycle: " + self.safe(result.stdout))
        require(not self.dest.exists(), "loop imported the refused candidate")
        events = self.events()[before:]
        refusals = [e for e in events if re.search(r"reject|refus|fail", e["type"])
                    and (TASK in json.dumps(e) or self.run in json.dumps(e))]
        require(refusals, "import refusal left no event")
        require(self.breaker() == 1, "import refusal did not count once toward breaker")
        parked_status = self.task_status()
        require(parked_status in ("parked", "blocked", "failed"),
                "refused task was not parked on first cycle")
        require(parked_status != status_before, "task park did not change its status")
        parked = [e for e in events if "park" in e["type"] and TASK in json.dumps(e)]
        require(parked, "task park has no durable event naming the task")
        # Only newly written diagnostics count. Original task prose, metadata
        # (runId/headSha) and a lease/event's worker owner cannot supply advice.
        lease = read(self.lease)
        resolution = {key: value for key, value in lease.items()
                      if lease_before.get(key) != value}
        added = "\n".join(line[2:] for line in difflib.ndiff(
            task_before.splitlines(), self.task.read_text().splitlines())
            if line.startswith("+ "))
        advice = resolution_text(refusals + parked) + added + resolution_text(resolution)
        require(re.search(reason, advice, re.I), "parked reason lost the broken part")
        require(re.search(r'\b(operator|human|person|maintainer|user)\b|'
                          r'"(?:nextOwner|resolver|resolutionOwner)"\s*:\s*"\s*[^"\s][^"]*"',
                          advice, re.I),
                "parked reason does not name who resolves it")
        require(re.search(r"singular\s+(drive|unpark|recover)\b", advice),
                "parked reason does not name a public recovery command")
        require(self.git("rev-parse", BRANCH).strip() == self.head,
                "parking lost the candidate")
        cut = len(self.events())
        second = self.cycle(real)
        require(second.returncode == 0, "next cycle failed")
        repeated = [e for e in self.events()[cut:]
                    if re.search(r"reject|refus|fail|park", e["type"])
                    and (TASK in json.dumps(e) or self.run in json.dumps(e))]
        require(not repeated, "next cycle repeated the same refusal or parking")
        require(self.task_status() == parked_status, "next cycle undid task park")
        require(self.breaker() == 1, "next cycle charged the refusal again")
        require(not self.dest.exists(), "next cycle published refused authority")

    def race(self, mutate, command=None):
        # Existing lock protocol: import takes git then campaign at publication.
        # Hold campaign; observing git acquisition is a bounded rendezvous after
        # initial validation. Neither validation nor publication is stubbed.
        ready, release = self.tmp / "holder-ready", self.tmp / "holder-release"
        for path in (ready, release):
            path.unlink(missing_ok=True)
        holder_script = self.tmp / "hold-campaign.sh"
        holder_script.write_text('''source "$SINGULAR_ENGINE_HOME/engine/lib.sh"
singular_campaign_lock_acquire
trap 'singular_campaign_lock_release' EXIT
: >"$1"
for ((n=0; n<1500; n++)); do
  [[ ! -e "$2" ]] || exit 0
  sleep 0.02
done
exit 1
''')
        log = self.tmp / "race.log"
        holder_log = self.tmp / "holder.log"
        with holder_log.open("w") as hlog, log.open("w") as ilog:
            holder = subprocess.Popen([self.bash, str(holder_script), str(ready), str(release)],
                                      cwd=self.repo, env=self.env, stdout=hlog,
                                      stderr=subprocess.STDOUT, start_new_session=True)
            importer = None
            try:
                self.poll(lambda: ready.exists(), holder, "campaign lock holder")
                command = command or [self.bash, self.engine / "engine/import-packet.sh", self.packet]
                importer = subprocess.Popen([str(x) for x in command],
                    cwd=self.repo, env=self.env, stdout=ilog, stderr=subprocess.STDOUT,
                    start_new_session=True)
                self.poll(lambda: (self.state / "locks/git-op.lock").is_dir(),
                          importer, "import publication rendezvous")
                mutate(self)
                release.touch()
                holder.wait(timeout=15)
                code = importer.wait(timeout=30)
                require(holder.returncode == 0, "lock holder failed")
            except subprocess.TimeoutExpired as exc:
                raise Failure("publication lock process timed out") from exc
            finally:
                release.touch()
                for process in (importer, holder):
                    if process is not None and process.poll() is None:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
        return subprocess.CompletedProcess([], code, log.read_text())

    @staticmethod
    def poll(predicate, process, label):
        deadline = time.monotonic() + 20
        while not predicate():
            require(process.poll() is None, label + " exited before rendezvous")
            require(time.monotonic() < deadline, label + " timed out")
            time.sleep(0.02)


def missing_host(f):
    f.host.unlink()


def wrong_host_tree(f):
    # Only G breaks: the host report remains passing, A echoes it, and E
    # binds its new bytes. Its tree no longer matches the verification request.
    edit(f.host, lambda d: d["verificationRequest"].update(treeSha="0" * 40))
    f.rebind_manifest()


def blocking_audit(f):
    edit(f.audit, lambda d: d.update(findings=["synthetic data loss"], classifiedFindings=[{
        "id": "F1", "severity": "P0", "summary": "synthetic data loss",
        "trigger": "write", "impact": "lost widget", "requirement": "preserve widget",
    }]))
    f.rebind_manifest()


def missing_round(f):
    f.rounds(lambda rows: rows.clear())


def stale_manifest(f):
    edit(f.manifest, lambda d: d.update(headSha="0" * 40))


def changed_manifest(f):
    # Still schema-valid, but it no longer binds the audited bytes.
    def change(doc):
        for item in doc["artifacts"]:
            if item["ref"] == "audit.json":
                item["sha256"] = "0" * 64
    edit(f.manifest, change)


def stale_audit_head(f):
    def change(doc):
        doc["evidenceReviewed"] = [
            "reviewed-head-sha:" + "0" * 40 if str(item).startswith("reviewed-head-sha:") else item
            for item in doc["evidenceReviewed"]
        ]
    edit(f.audit, change)
    f.rebind_manifest()


PRIMARY = [
    ("host report binds another tree", wrong_host_tree, r"host|verification"),
    ("missing host report", missing_host, r"host|verification"),
    ("open P0 in accepted audit", blocking_audit, r"audit|blocking|P0"),
    ("missing completed review round", missing_round, r"review|round"),
    ("manifest bound to another head", stale_manifest, r"evidence|manifest"),
]


def main(engine, bash):
    failures = []
    passed = 0
    # Keep AF_UNIX evidence-broker paths below the macOS socket path limit.
    with tempfile.TemporaryDirectory(prefix="abi-", dir=scratch_parent()) as temporary:
        try:
            f = Fixture(engine, bash, temporary)
        except (Failure, OSError, ValueError, KeyError, IndexError) as exc:
            print("CRITERION S0.4-1\nFAIL S0.4-1: valid baseline: " + str(exc))
            return 1

        def case(criterion, label, check):
            nonlocal passed
            try:
                check()
                passed += 1
                print("ok " + criterion + ": " + label, flush=True)
            except (Failure, OSError, ValueError, KeyError, IndexError) as exc:
                failures.append(label)
                print("CRITERION " + criterion, flush=True)
                print("FAIL " + criterion + ": " + label + ": " + f.safe(str(exc)), flush=True)

        def positive(mode):
            f.reset(mode)
            f.accepted(f.import_packet())
            packet, audit = f.dest.read_bytes(), f.sidecar.read_bytes()
            count = len([e for e in f.events() if e["type"] == "packet.imported"])
            f.accepted(f.import_packet())
            require((f.dest.read_bytes(), f.sidecar.read_bytes()) == (packet, audit),
                    "repeated import changed published bytes")
            require(len([e for e in f.events() if e["type"] == "packet.imported"]) == count,
                    "repeated import published a duplicate event")

        for mode in (None, "driver-only", "every-path"):
            case("S0.4-1", "valid and repeated import: " + str(mode), lambda m=mode: positive(m))

        def recovery():
            f.reset()
            f.sidecar.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(f.audit, f.sidecar)
            original = f.audit.read_bytes()
            f.accepted(f.import_packet())
            require(f.audit.read_bytes() == original, "recovery replaced independent audit")
        case("S0.4-1", "recover audit sidecar published before packet", recovery)

        def default_refusal(mode):
            f.reset(mode)
            f.audit.unlink()
            before = len(f.events())
            status, count = f.task_status(), f.breaker()
            result = f.cycle(real=True)
            require(result.returncode == 0, "default loop cycle failed")
            require(not f.dest.exists(), "default loop imported a missing audit")
            require(f.breaker() == count, "default refusal changed breaker")
            require(f.task_status() == status, "default refusal changed task status")
            events = f.events()[before:]
            require(any(e["type"] == "packet.import_rejected" for e in events),
                    "default cycle never attempted the refused import")
            require(not any("park" in e["type"] for e in events),
                    "default refusal parked on its first cycle")
            related = [e["type"] for e in events
                       if TASK in json.dumps(e) or f.run in json.dumps(e)]
            require(all(kind in ("packet.import_rejected", "packet.import_failed")
                        for kind in related), "default refusal added a lifecycle event")
        for mode in (None, "driver-only"):
            case("S0.4-4", "existing refusal keeps default lifecycle: " + str(mode),
                 lambda m=mode: default_refusal(m))

        def valid_cycle():
            f.reset()
            # Successful reconciliation consumes the inbox entry.
            packet = read(f.packet)
            result = f.cycle(real=True)
            f.accepted(result, packet)
            require(f.breaker() == 0, "successful loop import charged breaker")
            require(not re.search(r"^Status:\s*(parked|blocked|failed)\s*$",
                                  f.task.read_text(), re.M | re.I),
                    "successful loop import parked task")
            require(not any("park" in e["type"] and TASK in json.dumps(e)
                            for e in f.events()), "successful loop import emitted task park")
        case("S0.4-1", "valid every-path import through ordinary loop", valid_cycle)
        case("S0.4-4", "host-only refusal exits once through ordinary loop",
             lambda: f.refusal_exit(wrong_host_tree, r"host|verification", real=True))

        # Today import strictly rejects bad audits even when validation is warn.
        for policy in (None, "warn", "strict"):
            for mutation, label, reason in (
                (lambda f: f.audit.unlink(), "missing audit", r"audit|verdict"),
                (lambda f: edit(f.audit, lambda d: d.update(verdict="needs-fix")),
                 "nonaccepted audit", r"audit|verdict"),
                (lambda f: edit(f.audit, lambda d: d.pop("rationale")),
                 "schema-invalid audit", r"audit|schema|rationale"),
                (lambda f: edit(f.audit, lambda d: d.update(runId="RUN-unrelated")),
                 "cross-run audit", r"audit|identity"),
                (stale_audit_head, "audit for another head", r"audit|identity"),
            ):
                def today(m=mutation, p=policy, r=reason):
                    f.reset(None)
                    if p is not None:
                        f.env["SINGULAR_AUDIT_VERDICT_VALIDATE"] = p
                    m(f)
                    if f.audit.exists():
                        f.rebind_manifest()
                    f.refused(f.import_packet(), r)
                case("S0.4-1", "existing refusal: " + label + " / " + str(policy), today)
                if policy is None:
                    case("S0.4-4", label + " exits once",
                         lambda m=mutation, r=reason: f.refusal_exit(m, r))

        for label, mutate, reason in PRIMARY:
            # Each absent new guard is witnessed both as today's compatible
            # success and as tomorrow's explicit every-path refusal.
            for mode in (None, "driver-only"):
                def compatible(m=mutate, setting=mode):
                    f.reset(setting)
                    m(f)
                    f.accepted(f.import_packet())
                case("S0.4-1", label + " remains eligible: " + str(mode), compatible)
            def negative(m=mutate, r=reason):
                f.reset()
                m(f)
                f.refused(f.import_packet(), r)
            case("S0.4-1", label + " refused with every-path", negative)
            case("S0.4-4", label + " exits once", lambda m=mutate, r=reason: f.refusal_exit(m, r))

        for mode in (None, "driver-only"):
            def compatible_race(setting=mode):
                f.reset(setting)
                f.accepted(f.race(changed_manifest))
            case("S0.4-1", "publication race remains eligible: " + str(mode), compatible_race)

        def race():
            f.reset()
            f.refused(f.race(changed_manifest), r"evidence|manifest|chang")
        case("S0.4-1", "evidence changes after validation before publication", race)
        case("S0.4-4", "evidence changed during publication exits once",
             lambda: f.refusal_exit(changed_manifest, r"evidence|manifest|chang", racing=True))

        def legacy(allow):
            f.reset(None)
            f.waiver()
            if allow is not None:
                write(f.repo / "singular.config.json", {
                    "schemaVersion": "v2", "legacyCompatibility": {"unboundWaivers": allow},
                })
            result = f.import_packet()
            if allow is False:
                f.refused(result, r"waiver|audit|legacy")
            else:
                f.accepted(result)
        for allow in (None, True, False):
            case("S0.4-11", "legacy waiver admission: " + str(allow), lambda a=allow: legacy(a))

        def strict_waiver(f):
            f.waiver()
            write(f.repo / "singular.config.json", {
                "schemaVersion": "v2", "legacyCompatibility": {"unboundWaivers": True},
            })

        def strict_waiver_refused():
            f.reset()
            strict_waiver(f)
            f.refused(f.import_packet(), r"waiver|audit")
        case("S0.4-1", "legacy permission cannot replace A under every-path", strict_waiver_refused)
        case("S0.4-4", "strict waiver refusal exits once",
             lambda: f.refusal_exit(strict_waiver, r"waiver|audit"))

        def denied_waiver(f):
            f.waiver()
            write(f.repo / "singular.config.json", {
                "schemaVersion": "v2", "legacyCompatibility": {"unboundWaivers": False},
            })
        case("S0.4-4", "disabled waiver exits once",
             lambda: f.refusal_exit(denied_waiver, r"waiver|audit|legacy"))
    print(f"acceptance import: {passed} passing cases, {len(failures)} failing cases", flush=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
