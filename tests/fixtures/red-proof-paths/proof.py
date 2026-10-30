"""Fixture records use the serialization frozen by rp-step.t (5214d2e)."""
import hashlib
import json
from pathlib import Path
import subprocess

SCHEMA = "singular.orchestration.red-proof.v0"
COMMAND = "bash proof.sh"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def install(repo, run, head, base, attempt=1):
    def git(*args):
        return subprocess.check_output(["git", "-C", str(repo), *args])
    record = dict(schema=SCHEMA, taskId="TASK-0001", runId=run.name,
                  baseSha=base, headSha=head, treeSha=git("rev-parse", head + "^{tree}").decode().strip(),
                  attempt=attempt, command=COMMAND, commandSha256=sha(COMMAND.encode()),
                  proofFiles=[dict(path="proof.sh", sha256=sha(git("show", head + ":proof.sh")))],
                  outcome="proved")
    for name, code, outcome in (("base", 1, "red"), ("candidate", 0, "green")):
        log = run / ("fixture-proof-" + name + ".log")
        log.write_text("synthetic observation: exit " + str(code) + "\n")
        record[name] = dict(outcome=outcome, rawExitCode=code, timedOut=False,
                            logRef=log.name, logSha256=sha(log.read_bytes()))
    path = run / ("red-proof-attempt-" + str(attempt) + ".json")
    path.write_text(json.dumps(record, indent=2) + "\n")
    return path


def remove(run):
    # Discover by the frozen schema, not a producer-specific filename.
    removed = []
    for path in run.rglob("*.json"):
        try:
            value = json.loads(path.read_text())
        except (ValueError, OSError):
            continue
        if isinstance(value, dict) and value.get("schema") == SCHEMA:
            removed.append(path)
            path.unlink()
    return removed
