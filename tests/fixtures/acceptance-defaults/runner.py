#!/usr/bin/env python3
"""Synthetic runner: one worker change and a valid or malformed legacy audit."""
import datetime
import json
import os
from pathlib import Path
import sys

assert "RAILS_NONCE" not in os.environ and "RAILS_VERDICT_FILE" not in os.environ
if sys.argv[1:] == ["--describe-contract"]:
    print(json.dumps({
        "schema": "singular.runner-contract.v1", "version": 1,
        "provider": "codex", "arguments": [
            "--worktree", "--prompt-file", "--level", "--run-id",
            "--output-last-message", "--role", "--capability-profile",
            "--result-file", "--describe-contract"],
        "structuredResult": "singular.orchestration.runner-result.v0",
        "structuredProviderError": "singular.orchestration.provider-error.v0",
    }))
    sys.exit(0)

args = sys.argv[1:]
def arg(*names):
    for name in names:
        if name in args:
            return args[args.index(name) + 1]
    return ""

out = Path(arg("--output-last-message"))
worktree = Path(arg("--worktree", "-C"))
run = arg("--run-id")
role = arg("--role") or os.environ.get("SINGULAR_RUNNER_ROLE", "")
counter = Path(os.environ["DEFAULTS_COUNTERS"])
counter.mkdir(exist_ok=True)
worker = arg("--level") == "l2"
kind = "worker" if worker else "audit"
count = counter / kind
count.write_text(str(int(count.read_text()) + 1 if count.exists() else 1))
if "decider" in arg("--prompt-file"):
    raise SystemExit("unexpected decider invocation")

if worker:
    (worktree / "widget.txt").write_text("synthetic candidate\n")
    evidence = worktree / ".singular-evidence"
    evidence.mkdir(exist_ok=True)
    for phase in ("red", "green", "regression"):
        (evidence / (phase + ".log")).write_text(phase + " fixture\n")
    record = {
        "schema": "singular.orchestration.state-packet.v0", "packetId": "fixture",
        "taskId": "TASK-0001", "runId": run, "area": "widget",
        "role": "l2-developer", "status": "needs-review", "baseRef": "target",
        "branch": "agent/widget/TASK-0001-fixture", "headSha": "uncommitted",
        "workspace": str(worktree), "ownedFiles": ["widget.txt"],
        "changedFiles": ["widget.txt"],
        "commands": [{"cmd": "test -f widget.txt", "exitCode": 0,
                      "logRef": ".singular-evidence/green.log"}],
        "tests": [{"name": phase, "phase": phase,
                   "status": "failed-as-expected" if phase == "red" else "passed",
                   "logRef": ".singular-evidence/" + phase + ".log"}
                  for phase in ("red", "green", "regression")],
        "evidence": [{"kind": phase + "-log", "ref": ".singular-evidence/" + phase + ".log"}
                     for phase in ("red", "green", "regression")],
        "blockers": [], "nextAction": "audit", "createdAt": "2026-01-01T00:00:00Z",
    }
else:
    record = {
        "schema": "singular.orchestration.audit-verdict.v0",
        "taskId": "TASK-0001", "runId": run,
        "branch": "agent/widget/TASK-0001-fixture", "verdict": "accepted",
        "evidenceReviewed": [], "commandsRun": [], "findings": [],
        "requiredFixes": [], "rationale": "synthetic clean audit",
    }
    if os.environ.get("DEFAULTS_MALFORMED") == "1":
        # Exactly one defect, with legal authority/identity fields. JSON parses,
        # but the v0 schema forbids this field. Every repair returns it again.
        record["unexpectedFixtureField"] = True

out.write_text(json.dumps(record) + "\n")
result = arg("--result-file")
if result:
    Path(result).write_text(json.dumps({
        "schema": "singular.orchestration.runner-result.v0", "contractVersion": 1,
        "provider": "codex", "runId": run, "role": role,
        "capabilityProfile": arg("--capability-profile"), "exitCode": 0,
        "outcome": "succeeded", "failureClass": "none", "providerErrorRef": None,
        "outputRef": str(out), "recordedAt": datetime.datetime.now(
            datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
    }))
