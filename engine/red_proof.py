#!/usr/bin/env python3
"""Host observations of candidate proof files on the leased base and head.

The scratch runner owns checkout preparation, deadlines and source integrity.
This module owns classification and the single infrastructure retry. The driver
owns repair accounting and terminal disposition; log prose has no authority.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

from task_parser import proof_preflight_reasons


INFRA = "inconclusive-infrastructure"


def digest(content):
    return hashlib.sha256(content).hexdigest()


def git(root, *args):
    return subprocess.check_output(["git", "-C", root, *args], stderr=subprocess.DEVNULL)


def infrastructure(observation):
    return (observation.get("setupError") or observation.get("timedOut")
            or observation.get("rawExitCode") in (None, 126, 127)
            or observation.get("sourceIntegrity", {}).get("status") != "verified")


def classify(observation, side, policy):
    if infrastructure(observation):
        return INFRA
    if side == "candidate":
        return "green" if observation["rawExitCode"] == 0 else "green-failed"
    if observation["rawExitCode"] != 0:
        return "red"
    return "green" if policy == "characterization_first" else "not-demonstrated"


def outcome(base, candidate, policy):
    if base["outcome"] == INFRA or candidate["outcome"] == INFRA:
        if (base["rawExitCode"] in (126, 127)
                and not base.get("setupError") and not base["timedOut"]
                and base.get("sourceIntegrity", {}).get("status") == "verified"
                and candidate["outcome"] == "green"):
            return "base-cannot-run"
        return INFRA
    if candidate["outcome"] != "green":
        return "green-failed"
    expected = "green" if policy == "characterization_first" else "red"
    return "proved" if base["outcome"] == expected else "not-demonstrated"


def observe(args, side, commit, command, proofs, policy):
    observations = []
    for retry in range(2):
        log = Path(args.run_dir) / f"red-proof-{args.attempt}-{side}-{retry}.log"
        invocation = ["bash", str(Path(__file__).with_name("scratch-run.sh")),
                      "--commit", commit, "--command", command,
                      "--timeout", str(args.timeout), "--log", str(log),
                      "--scratch-parent", args.state, "--dependency-source", args.root,
                      "--source-worktree", args.worktree]
        if side == "base":
            invocation += ["--overlay-commit", args.head]
            for proof in proofs:
                invocation += ["--overlay-path", proof["path"]]
        env = dict(os.environ, SINGULAR_ROOT=args.root, SINGULAR_STATE_DIR=args.state)
        result = subprocess.run(invocation, env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, check=False)
        try:
            observation = json.loads(result.stdout)
            if (result.returncode not in (0, 20) or not isinstance(observation, dict)
                    or not {"rawExitCode", "timedOut", "sourceIntegrity", "setupError"} <= observation.keys()):
                raise ValueError("invalid scratch result")
        except (ValueError, TypeError):
            observation = {"rawExitCode": None, "timedOut": False,
                           "setupError": "scratch-runner-failed",
                           "sourceIntegrity": {"status": "not-checked", "changedPaths": []}}
        if not log.exists():
            log.write_text("Proof checkout could not be prepared.\n", encoding="utf-8")
        observation.update(outcome=classify(observation, side, policy),
                           logRef=log.name, logSha256=digest(log.read_bytes()))
        observations.append(observation)
        if observation["outcome"] != INFRA:
            break
    return observations


def proof_files(root, head, paths):
    """Expand declared folders using candidate Git objects, never working files."""
    files = {}
    for path in paths:
        entries = git(root, "--literal-pathspecs", "ls-tree", "-r", "-z", head, "--", path)
        if not entries:
            raise ValueError("candidate proof path is missing")
        for entry in entries.rstrip(b"\0").split(b"\0"):
            metadata, name = entry.split(b"\t", 1)
            mode, kind, oid = metadata.decode().split()
            if kind != "blob" or mode not in ("100644", "100755", "120000"):
                raise ValueError("proof tests must be tracked files")
            files[os.fsdecode(name)] = digest(git(root, "cat-file", "blob", oid))
    return [{"path": path, "sha256": sha} for path, sha in sorted(files.items())]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for flag in ("root", "state", "worktree", "run-dir", "head", "lease", "task-id", "run-id"):
        parser.add_argument("--" + flag, required=True)
    parser.add_argument("--attempt", type=int, required=True)
    parser.add_argument("--timeout", type=int, required=True)
    parser.add_argument("--mode", choices=("off", "observe", "enforce"), required=True)
    args = parser.parse_args()
    task = json.load(sys.stdin)
    if args.mode == "off" or not (task.get("proofCommand") or task.get("proofTests")):
        print("skipped")
        return
    if proof_preflight_reasons(task):
        raise ValueError("invalid proof declaration")
    if args.attempt < 1 or args.timeout < 1:
        raise ValueError("proof attempt and timeout must be positive")
    # Capture every binding before executing candidate code. The task JSON was
    # parsed by the driver before the worker, and the lease supplies the base.
    lease = json.loads(Path(args.lease).read_text(encoding="utf-8"))
    if lease.get("taskId") != args.task_id:
        raise ValueError("proof lease belongs to another task")
    base = git(args.root, "rev-parse", "--verify", "--end-of-options",
               lease["baseSha"] + "^{commit}").decode().strip()
    args.head = git(args.root, "rev-parse", "--verify", "--end-of-options",
                    args.head + "^{commit}").decode().strip()
    tree = git(args.root, "rev-parse", args.head + "^{tree}").decode().strip()
    command = task["proofCommand"]
    policy = task["testPolicy"]
    if policy not in ("strict_test_first", "characterization_first", "test_after_waiver", "not_applicable"):
        raise ValueError("unknown proof policy")
    proofs = proof_files(args.root, args.head, task["proofTests"])
    record = {"schema": "singular.orchestration.red-proof.v0", "mode": args.mode,
              "taskId": args.task_id, "runId": args.run_id, "testPolicy": policy,
              "baseSha": base, "headSha": args.head, "treeSha": tree,
              "attempt": args.attempt, "command": command,
              "commandSha256": digest(command.encode("utf-8")), "proofFiles": proofs,
              "isolation": "none"}
    if policy in ("test_after_waiver", "not_applicable"):
        record["outcome"] = "waived"
    else:
        # The command is one executable and its literal arguments. Quoting each
        # argument prevents shell expansion by the shared shell-command runner.
        executable = shlex.join(shlex.split(command))
        for side, commit in (("base", base), ("candidate", args.head)):
            observations = observe(args, side, commit, executable, proofs, policy)
            record[side + "Attempts"] = observations
            record[side] = observations[-1]
        record["outcome"] = outcome(record["base"], record["candidate"], policy)
    path = Path(args.run_dir) / f"red-proof-{args.attempt}.json"
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)
    print(record["outcome"])


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        # Do not echo candidate-controlled data or local paths into feedback.
        print("The host could not bind or record the proof observations.", file=sys.stderr)
        sys.exit(20)
