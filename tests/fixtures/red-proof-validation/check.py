"""Small independent V input checks; no provider, engine loop or remote."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(sys.argv[1]) / "engine"))
from acceptance_validator import Refusal, check_proof


def sha(data):
    return hashlib.sha256(data).hexdigest()


with tempfile.TemporaryDirectory(prefix="proof-inputs-") as directory:
    root = Path(directory)
    def git(*args):
        return subprocess.check_output(["git", "-C", str(root), *args], stderr=subprocess.DEVNULL).decode().strip()
    git("init", "-q")
    git("config", "user.name", "fixture")
    git("config", "user.email", "fixture")
    (root / ".gitignore").write_text(".singular-state/\n")
    (root / "proof.sh").write_text("test -f widget\n")
    git("add", ".")
    git("-c", "commit.gpgsign=false", "commit", "-qm", "base")
    base = git("rev-parse", "HEAD")
    (root / "widget").write_text("candidate\n")
    git("add", ".")
    git("-c", "commit.gpgsign=false", "commit", "-qm", "candidate")
    head = git("rev-parse", "HEAD")
    state = root / ".singular-state"
    run = state / "runs/RUN-PROOF"
    run.mkdir(parents=True)
    task = state / "task.md"
    task.write_text('''# TASK-0001: Fixture
Test policy: strict_test_first
Proof command: bash proof.sh
Proof tests: ["proof.sh"]

## Scope
Owned files:
- `proof.sh`
''')
    lease = state / "lease.json"
    lease.write_text(json.dumps(dict(taskId="TASK-0001", baseSha=base)))
    args = argparse.Namespace(red_proof="enforce", acceptance_mode="every-path",
        task_contract=str(task), task="TASK-0001", run=run.name, lease=str(lease),
        state_dir=str(state), repo_root=str(root), head=head)
    record = dict(schema="singular.orchestration.red-proof.v0", taskId=args.task,
        runId=args.run, baseSha=base, headSha=head, treeSha=git("rev-parse", "HEAD^{tree}"),
        attempt=1, command="bash proof.sh", commandSha256=sha(b"bash proof.sh"),
        proofFiles=[dict(path="proof.sh", sha256=sha((root / "proof.sh").read_bytes()))],
        outcome="proved", testPolicy="strict_test_first")
    for side, code, outcome in (("base", 1, "red"), ("candidate", 0, "green")):
        log = run / (side + ".log")
        log.write_text("observation\n")
        record[side] = dict(rawExitCode=code, outcome=outcome, timedOut=False,
            logRef=log.name, logSha256=sha(log.read_bytes()), setupError=None,
            sourceIntegrity=dict(status="verified", changedPaths=[]))
    path = run / "red-proof-1.json"
    def check(label, value=record, refused=True):
        if value is None:
            path.unlink(missing_ok=True)
        else:
            path.write_text(json.dumps(value))
        try:
            check_proof(args, run, 1)
        except Refusal as error:
            assert refused and error.conjunct == "V", (label, error)
        else:
            assert not refused, label + " unexpectedly accepted"
        print("ok: " + label)

    check("valid host record", refused=False)
    check("missing", None)
    for field, value in dict(taskId="TASK-0002", runId="RUN-OTHER", baseSha=head,
            headSha=base, treeSha=base, attempt=2, command="true", commandSha256="0" * 64,
            proofFiles=[], testPolicy="characterization_first", outcome="waived").items():
        mutated = copy.deepcopy(record)
        mutated[field] = value
        check(field, mutated)
    for side in ("base", "candidate"):
        for field, value in dict(rawExitCode=True, timedOut=True, setupError="failed",
                sourceIntegrity=dict(status="violation"), outcome="inconclusive-infrastructure",
                logRef="absent", logSha256="0" * 64).items():
            mutated = copy.deepcopy(record)
            mutated[side][field] = value
            check(side + "/" + field, mutated)
        mutated = copy.deepcopy(record)
        mutated[side]["sourceIntegrity"]["changedPaths"] = ["proof.sh"]
        check(side + "/source-changed", mutated)
        for code in (126, 127, None, "1", 0 if side == "base" else 1):
            mutated = copy.deepcopy(record)
            mutated[side]["rawExitCode"] = code
            check(side + "/exit-" + str(code), mutated)
        mutated = copy.deepcopy(record)
        del mutated[side]
        check(side + "/missing-observation", mutated)
    path.write_text(json.dumps(record))
    duplicate = run / "red-proof-attempt-1.json"
    duplicate.write_text(path.read_text())
    check("ambiguous current attempt")
    duplicate.unlink()
    # Old attempts remain available and do not stand in for the current one.
    old = copy.deepcopy(record)
    old["attempt"] = 2
    duplicate.write_text(json.dumps(old))
    check("other attempt ignored", refused=False)
    duplicate.unlink()
    path.unlink()
    path.symlink_to(run / "absent-record")
    try:
        check_proof(args, run, 1)
    except Refusal as error:
        assert error.conjunct == "V"
    else:
        raise AssertionError("dangling record accepted")
    path.unlink()
    path.write_text("unreadable json")
    try:
        check_proof(args, run, 1)
    except Refusal as error:
        assert error.conjunct == "V"
    else:
        raise AssertionError("unreadable record accepted")
    path.write_text(json.dumps(record))
    log = run / "base.log"
    log.unlink()
    check("missing base log")
    log.symlink_to(run / "candidate.log")
    check("symlink log")
    log.unlink()
    log.write_text("changed bytes\n")
    check("changed log bytes")
    log.write_text("observation\n")
    # V reads candidate blobs, not mutable working files.
    (root / "proof.sh").write_text("working file changed\n")
    check("candidate blob is authority", refused=False)
    for mode, acceptance in (("off", "every-path"), ("observe", "every-path"), ("enforce", "driver-only")):
        args.red_proof, args.acceptance_mode = mode, acceptance
        check(mode + "/" + acceptance, None, refused=False)
    args.red_proof, args.acceptance_mode = "enforce", "every-path"
    original_task = task.read_text()
    for policy in ("test_after_waiver", "not_applicable"):
        task.write_text(original_task.replace("strict_test_first", policy))
        waived = copy.deepcopy(record)
        waived.update(testPolicy=policy, outcome="waived")
        del waived["base"], waived["candidate"]
        check(policy, waived, refused=False)
        waived["outcome"] = "proved"
        check(policy + "/missing-waiver", waived)
    task.write_text("# TASK-0001: Fixture\nTest policy: strict_test_first\n")
    check("no declaration", None, refused=False)
