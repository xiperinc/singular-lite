"""Frozen S1.1-3 / S1.1-9 acceptance boundaries; no model or network."""
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import time
import tempfile
import threading

from fixture import BRANCH, TASK, Checks, Fixture, read, write
from proof import install, remove, SCHEMA

HERE = Path(__file__).resolve().parent


def driver_parts(root, scratch, bash):
    # Bash parses complete functions, including embedded Python heredocs.
    # This is the same test seam used by rp-step.t. Only the UI is stubbed.
    text = (root / "engine/l1-drive.sh").read_text()
    lines = text.splitlines(keepends=True)
    blocks = []
    index = 0
    while index < len(lines):
        if not re.match(r"^[A-Za-z_][A-Za-z_0-9]*\(\) \{\s*$", lines[index]):
            index += 1
            continue
        for end in range(index + 1, len(lines)):
            if lines[end].rstrip() != "}":
                continue
            candidate = "".join(lines[index:end + 1])
            parsed = subprocess.run([bash, "-n"], input=candidate, text=True,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
            if parsed.returncode == 0:
                blocks.append(candidate)
                index = end
                break
        else:
            raise AssertionError("could not extract complete driver function")
        index += 1
    definitions = scratch / "driver-functions.sh"
    definitions.write_text("\n".join(blocks))
    start = text.index('# ---- Acceptance predicate (0.23.4)')
    stop = text.index('# ---- Artifact secret-scan finalize hook', start)
    publication = scratch / "publication-body.sh"
    publication.write_text(text[start:stop])
    subprocess.run([bash, "-n", str(publication)], check=True, timeout=5)
    return definitions, publication


def boundary(f, parts, check=False):
    return f.run([f.env["TEST_BASH"], HERE / "publication.sh", f.root, *parts,
                  "check" if check else "publish"])


def set_mode(f, proof, acceptance):
    # Shell settings are deliberately unexported. Every Python caller must
    # receive resolved values, rather than relying on ambient os.environ.
    f.env.pop("SINGULAR_RED_PROOF", None)
    f.env.pop("SINGULAR_ACCEPTANCE", None)
    text = "SINGULAR_ACCEPTANCE=" + acceptance + "\n"
    if proof != "unset":
        text += "SINGULAR_RED_PROOF=" + proof + "\n"
    (f.state / "config.local.sh").write_text(text)


def pending(f):
    packet = read(f.packet)
    packet["status"] = "needs-review"
    write(f.packet, packet)
    lease = read(f.lease)
    lease["status"] = "blocked"
    write(f.lease, lease)
    f.task.write_text(f.task.read_text().replace("Status: accepted", "Status: ready"))


def prepare_imported(f):
    imported = f.orch / "packets/imported" / TASK / (f.run_id + ".json")
    write(imported, read(f.packet))
    write(imported.with_suffix(".audit.json"), read(f.audit))
    f.git("add", "docs/orchestration")
    f.git("commit", "-qm", "fixture imported certificate")
    return imported


def prepare_regate(f):
    f.python("task_lifecycle.py", "retain-candidate", "--lease", f.lease,
             "--packet", f.packet, "--audit", f.audit, "--task-file", f.task,
             "--task", TASK, "--run", f.run_id, "--branch", BRANCH,
             "--head", f.head, "--tree", f.tree, "--campaign", "legacy",
             "--acceptance-mode", "accepted")
    f.python("task_lifecycle.py", "candidate-failed", "--lease", f.lease,
             "--head", f.head, "--tree", f.tree, "--campaign", "legacy",
             "--failure-class", "gate-setup", "--target-head", f.original_head,
             "--invalidation-key", "fixture-inputs", "--next-action", "authorize regate",
             "--failure-id", "fixture-infrastructure", "--domain", "infrastructure")


def prepare_audit_only(f, action):
    # The existing public resume protocol, not a shortcut to the validator.
    pending(f)
    f.audit.rename(f.run_dir / "previous-audit.json")
    # An unreadable prior audit never completed a review round. Model that
    # predecessor state before the public command earns a fresh round.
    ledger = read(f.ledger)
    ledger["logicalChanges"].pop(TASK)
    write(f.ledger, ledger)
    lease = read(f.lease)
    lease["auditRecheck"] = dict(taskId=TASK, branch=BRANCH, runId=f.run_id,
                                headSha=f.head, baseSha=f.original_head)
    write(f.lease, lease)
    packet = read(f.packet)
    packet["status"] = "blocked"
    write(f.packet, packet)
    bindir = f.scratch / "bin"
    bindir.mkdir()
    shim = bindir / "python3"
    real_python = shlex.quote(sys.executable)
    spy = shlex.quote(str(HERE / "python-spy.py"))
    shim.write_text('#!/bin/sh\ncase "${1##*/}" in\n'
                    + 'acceptance_validator.py) exec ' + real_python + ' ' + spy + ' "$@" ;;\n'
                    + '*) exec ' + real_python + ' "$@" ;;\nesac\n')
    shim.chmod(0o755)
    f.env.update(PATH=str(bindir) + os.pathsep + f.env["PATH"], PROOF_SPY_ACTION=action,
                 PROOF_REAL_PYTHON=sys.executable, PROOF_SPY_CALLS=str(f.scratch / "spy.jsonl"))


def run_route(f, route, parts):
    if route == "ordinary":
        return boundary(f, parts)
    if route == "retained":
        return f.command("drive", TASK)
    if route == "stranded":
        f.env["SINGULAR_RESUME_ACCEPTED_EVIDENCE"] = "0"
        return f.command("drive", TASK)
    if route == "audit-only":
        return f.command("drive", TASK, "--audit-only")
    if route == "import":
        return f.run([f.env["TEST_BASH"], f.root / "engine/import-packet.sh", f.packet])
    if route == "integration":
        return f.command("integrate")
    if route == "retry":
        return f.command("integrate", "--task", TASK)
    if route == "regate":
        return f.command("recover", "candidate", TASK, "--action", "regate",
                         "--successor-run", "RUN-REGATE", "--successor-branch", BRANCH,
                         "--successor-worktree", f.worktree, "--failure-id", "fixture-infrastructure")
    if route == "accept-packet":
        return f.command("accept-packet", f.packet)
    raise AssertionError(route)


def diagnostic(f, result, start_events):
    # V must be named by the refusal, not merely appear in a prompt/task file.
    texts = [result.stdout]
    texts.extend(json.dumps(e) for e in f.events()[start_events:])
    for path in (f.state / "runs").rglob("acceptance-check.json"):
        texts.append(path.read_text())
    return any(re.search(r'"conjunct"\s*:\s*"V"|\bV:', value) for value in texts)


def path_case(root, scratch, parts, bash, route, mode, acceptance, valid=False, fixture=None):
    c = Checks()
    f = fixture or Fixture(root, scratch, c)
    f.checks = c
    f.env["TEST_BASH"] = bash
    if fixture is None:
        f.seed()
    record = install(f.repo, f.run_dir, f.head, f.original_head)
    # Verify fixture behavior independently of its serialization.
    base_test = f.run([bash, "proof.sh"])
    candidate_test = f.run([bash, "-c", 'cd "$1" && bash proof.sh', "fixture", f.worktree])
    c.require("fixture", "proof is red on base and green on candidate",
              base_test.returncode == 1 and candidate_test.returncode == 0)
    if route in {"integration", "retry"}:
        prepare_imported(f)
    if route == "retry":
        # An accepted and integrated run is explicitly retried by task id.
        # No default scan can hide behind the terminal-lease early skip.
        initial = f.command("integrate", "--task", TASK)
        c.require("fixture", "initial integration succeeds before retry", initial.returncode == 0)
        c.require("fixture", "initial integration contains candidate",
                  f.run(["git", "merge-base", "--is-ancestor", f.head, "target"]).returncode == 0)
    if route == "regate":
        prepare_regate(f)
    set_mode(f, mode, acceptance)
    # Establish that the exact synthetic record is accepted by the real caller.
    # This is a single-conjunct differential: removal changes no G/A/D/E input.
    positive = boundary(f, parts, check=True)
    c.require("fixture", route + " valid proof control accepts", positive.returncode == 0)
    (f.run_dir / "acceptance-check.json").unlink(missing_ok=True)
    if not valid:
        c.require("fixture", "record removed from previously accepted run", record in remove(f.run_dir))
    if route in {"ordinary", "accept-packet"}:
        pending(f)
    if route == "audit-only":
        prepare_audit_only(f, "valid" if valid else "remove")
    start_events = len(f.events())
    target_before = f.git("rev-parse", "target").stdout.strip()
    result = run_route(f, route, parts)
    (scratch / "result.log").write_text(result.stdout)
    strict = mode == "enforce" and acceptance == "every-path" and not valid
    criterion = "S1.1-9" if route in {"ordinary", "retry"} and strict else "S1.1-3"
    label = route + "/" + mode + "/" + acceptance + ("/proved" if valid else "/missing")
    if strict:
        c.check(criterion, label + " exits nonzero", result.returncode != 0)
        c.check(criterion, label + " names V", diagnostic(f, result, start_events))
        c.check(criterion, label + " queues no accepted packet", not list((f.state / "inbox").glob("*.json")))
        c.check(criterion, label + " does not advance target",
                f.git("rev-parse", "target").stdout.strip() == target_before)
        if route in {"ordinary", "accept-packet", "audit-only"}:
            packets = list((f.state / "runs").glob("*/packet.json"))
            c.check(criterion, label + " leaves packet unaccepted",
                    all(read(p).get("status") != "accepted" for p in packets))
        if route == "import":
            c.check(criterion, label + " publishes no imported certificate",
                    not list((f.orch / "packets/imported").glob("*/*.json")))
        if route == "regate":
            c.check(criterion, label + " grants no recovery authorization",
                    not read(f.lease).get("recoveryAuthorization"))
    else:
        c.check("compatibility", label + " succeeds", result.returncode == 0)
        if result.returncode:
            print(result.stdout[-1200:].replace(str(scratch), "<fixture>").replace(str(root), "<engine>"))
        if route in {"ordinary", "retained", "stranded", "audit-only"}:
            c.check("compatibility", label + " publishes acceptance",
                    bool(list((f.state / "inbox").glob("*.json"))))
        elif route == "accept-packet":
            c.check("compatibility", label + " stamps accepted", read(f.packet)["status"] == "accepted")
        elif route == "import":
            c.check("compatibility", label + " imports packet",
                    (f.orch / "packets/imported" / TASK / (f.run_id + ".json")).is_file())
        elif route in {"integration", "retry"}:
            c.check("compatibility", label + " contains candidate",
                    f.run(["git", "merge-base", "--is-ancestor", f.head, "target"]).returncode == 0)
        elif route == "regate":
            c.check("compatibility", label + " authorizes recovery", bool(read(f.lease).get("recoveryAuthorization")))
    if route == "audit-only":
        c.check("fixture", "audit-only reaches real acceptance program", (scratch / "spy.jsonl").is_file())
        c.check("fixture", "audit-only never invokes implementer", not (f.counters / "worker").exists())
    return c.failures


def record_matrix(root, scratch, parts, bash):
    c = Checks()
    f = Fixture(root, scratch, c)
    f.env["TEST_BASH"] = bash
    f.seed()
    set_mode(f, "enforce", "every-path")
    path = install(f.repo, f.run_dir, f.head, f.original_head)
    pristine = path.read_bytes()
    positive = boundary(f, parts, check=True)
    c.require("fixture", "intact strict record accepts", positive.returncode == 0)
    # Each case changes exactly one V input; the four old conjuncts remain valid.
    mutations = {
        "not-demonstrated": lambda d: d.update(outcome="not-demonstrated"),
        "green-failed": lambda d: d.update(outcome="green-failed"),
        "infrastructure": lambda d: d.update(outcome="inconclusive-infrastructure"),
        "base-cannot-run": lambda d: d.update(outcome="base-cannot-run"),
        "waived-strict": lambda d: d.update(outcome="waived"),
        "wrong-base": lambda d: d.update(baseSha=f.head),
        "wrong-head": lambda d: d.update(headSha=f.original_head),
        "wrong-tree": lambda d: d.update(treeSha=f.original_head),
        "wrong-attempt": lambda d: d.update(attempt=2),
        "wrong-command": lambda d: d.update(command="true"),
        "command-digest": lambda d: d.update(commandSha256="0" * 64),
        "proof-digest": lambda d: d["proofFiles"][0].update(sha256="0" * 64),
        "proof-omitted": lambda d: d.update(proofFiles=[]),
        "base-log-digest": lambda d: d["base"].update(logSha256="0" * 64),
        "candidate-log-digest": lambda d: d["candidate"].update(logSha256="0" * 64),
        "base-passed-strict": lambda d: d["base"].update(rawExitCode=0, outcome="green"),
        "candidate-failed": lambda d: d["candidate"].update(rawExitCode=1, outcome="green-failed"),
    }
    for name, mutate in mutations.items():
        data = json.loads(pristine)
        mutate(data)
        write(path, data)
        result = boundary(f, parts, check=True)
        c.check("S1.1-3", name + " refuses specifically V", result.returncode != 0 and "V:" in result.stdout)
        path.write_bytes(pristine)
    # Existing accept result is not a cache of V: remove the record after a
    # real accepted answer, then ask ordinary publication to evaluate again.
    c.require("fixture", "restored record accepts", boundary(f, parts, check=True).returncode == 0)
    path.unlink()
    result = boundary(f, parts, check=True)
    c.check("S1.1-9", "accepted result cannot replace deleted proof",
            result.returncode != 0 and "V:" in result.stdout)
    return c.failures


def policy_controls(root, scratch, parts, bash):
    failures = 0
    for policy, declared in (("characterization_first", True), ("test_after_waiver", True),
                              ("not_applicable", True), ("strict_test_first", False)):
        folder = scratch / policy
        folder.mkdir()
        c = Checks()
        f = Fixture(root, folder, c, policy=policy, declared=declared)
        f.env["TEST_BASH"] = bash
        f.seed()
        set_mode(f, "enforce", "every-path")
        if declared:
            path = install(f.repo, f.run_dir, f.head, f.original_head)
            record = read(path)
            if policy == "characterization_first":
                record["base"].update(rawExitCode=0, outcome="green")
            else:
                record["outcome"] = "waived"
                del record["base"], record["candidate"]
            write(path, record)
        result = boundary(f, parts, check=True)
        c.check("V-table", policy + ("" if declared else "/nothing-declared") + " accepts",
                result.returncode == 0)
        if declared:
            path.unlink()
            result = boundary(f, parts, check=True)
            c.check("V-table", policy + " requires its record under enforce",
                    result.returncode != 0 and "V:" in result.stdout)
        failures += c.failures
    return failures


def main():
    root, scratch = map(Path, sys.argv[1:3])
    bash = sys.argv[3]
    started = time.monotonic()
    parts = driver_parts(root, scratch, bash)
    routes = ("ordinary", "retained", "stranded", "audit-only", "import",
              "integration", "retry", "regate", "accept-packet")
    cases = []
    for route in routes:
        for mode, acceptance, valid in (("enforce", "every-path", False),
                                         ("enforce", "every-path", True),
                                         ("off", "every-path", False),
                                         ("observe", "every-path", False),
                                         ("unset", "driver-only", False)):
            name = "-".join((route, mode, acceptance, "proved" if valid else "missing"))
            cases.append((name, route, mode, acceptance, valid))
    local = threading.local()

    def reusable_fixture():
        if not hasattr(local, "fixture"):
            home = Path(tempfile.mkdtemp(prefix="shared-", dir=scratch))
            f = Fixture(root, home, Checks())
            f.env["TEST_BASH"] = bash
            f.seed()
            snapshot = home / "snapshot"
            shutil.copytree(f.state, snapshot / "state")
            shutil.copytree(f.orch, snapshot / "orch")
            local.fixture, local.env = f, dict(f.env)
        f = local.fixture
        # Only fixture-owned runtime data and task projections are restored.
        # Git objects, refs, worker HEAD/index/files are never reset in place.
        for source, destination in (("state", f.state), ("orch", f.orch)):
            shutil.rmtree(destination)
            shutil.copytree(f.scratch / "snapshot" / source, destination)
        f.env = dict(local.env)
        return f

    def execute(indexed_case):
        index, case = indexed_case
        name, *args = case
        # Keep the AF_UNIX evidence broker's path beneath its platform limit.
        folder = scratch / ("c%02d" % index)
        folder.mkdir()
        try:
            fixture = None if args[0] in {"audit-only", "integration", "retry"} else reusable_fixture()
            return path_case(root, folder, parts, bash, *args, fixture=fixture)
        except Exception as exc:
            detail = str(exc).replace(str(scratch), "<scratch>").replace(str(root), "<engine>")
            print("FAIL fixture " + name + ": " + detail, flush=True)
            return 1
    with ThreadPoolExecutor(max_workers=2) as pool:
        failures = sum(pool.map(execute, enumerate(cases)))
    folder = scratch / "record-matrix"
    folder.mkdir()
    try:
        failures += record_matrix(root, folder, parts, bash)
    except Exception as exc:
        print("FAIL fixture record-matrix: " + str(exc).replace(str(scratch), "<scratch>"), flush=True)
        failures += 1
    folder = scratch / "policy-controls"
    folder.mkdir()
    try:
        failures += policy_controls(root, folder, parts, bash)
    except Exception as exc:
        print("FAIL fixture policy-controls: " + str(exc).replace(str(scratch), "<scratch>"), flush=True)
        failures += 1
    print(f"red-proof-paths: {failures} assertion failures; {time.monotonic() - started:.1f}s", flush=True)
    return bool(failures)


if __name__ == "__main__":
    sys.exit(main())
