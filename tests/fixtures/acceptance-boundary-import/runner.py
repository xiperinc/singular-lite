#!/usr/bin/env python3
"""Synthetic worker/auditor only; never delegates to a provider."""
import json
import os
from pathlib import Path
import sys

assert "RAILS_NONCE" not in os.environ and "RAILS_VERDICT_FILE" not in os.environ
if "--describe-contract" in sys.argv:
    print(json.dumps({
        "schema": "singular.runner-contract.v1", "version": 1, "provider": "codex",
        "arguments": ["--worktree", "--prompt-file", "--level", "--run-id",
                      "--output-last-message", "--role", "--capability-profile",
                      "--result-file", "--describe-contract"],
        "structuredResult": "singular.orchestration.runner-result.v0",
        "structuredProviderError": "singular.orchestration.provider-error.v0",
    }))
    sys.exit(0)
args = dict(zip(sys.argv[1::2], sys.argv[2::2]))
out = Path(args["--output-last-message"])
workspace = Path(args.get("--worktree") or args["-C"])
run = args["--run-id"]
branch = "agent/widget/TASK-0001"
stamp = "2026-01-01T00:00:00Z"
if args["--level"] == "l2":
    (workspace / "widget.txt").write_text("synthetic widget\n")
    evidence = workspace / ".singular-evidence"
    evidence.mkdir(exist_ok=True)
    for phase in ("red", "green", "regression"):
        (evidence / (phase + ".log")).write_text(phase + " fixture\n")
    record = {
        "schema": "singular.orchestration.state-packet.v0", "packetId": "fixture",
        "taskId": "TASK-0001", "runId": run, "area": "widget",
        "role": "l2-developer", "status": "needs-review", "baseRef": "target",
        "branch": branch, "headSha": "uncommitted", "workspace": str(workspace),
        "ownedFiles": ["widget.txt"], "changedFiles": ["widget.txt"],
        "commands": [{"cmd": "true", "exitCode": 0,
                      "logRef": ".singular-evidence/green.log"}],
        "tests": [{"name": phase, "phase": phase,
                   "status": "failed-as-expected" if phase == "red" else "passed",
                   "logRef": ".singular-evidence/" + phase + ".log"}
                  for phase in ("red", "green", "regression")],
        "evidence": [{"kind": phase + "-log",
                      "ref": ".singular-evidence/" + phase + ".log"}
                     for phase in ("red", "green", "regression")],
        "blockers": [], "nextAction": "audit", "createdAt": stamp,
    }
elif args.get("--role") == "auditor" or "audit" in args["--prompt-file"]:
    report = json.loads((out.parent / "audit-verification.json").read_text())
    status = report["outcome"]
    if status == "passed-with-acknowledged-baseline":
        status = "passed"
    record = {
        "schema": "singular.orchestration.audit-verdict.v1",
        "taskId": "TASK-0001", "runId": run, "branch": branch,
        "verdict": "accepted", "evidenceReviewed": ["audit-verification.json"],
        "verificationResults": [{"status": status, "command": "true", "exitCode": 0,
                                 "evidenceRefs": ["audit-verification.json"],
                                 "rationale": "synthetic independent audit"}],
        "commandsRun": [], "findings": [], "requiredFixes": [],
        "rationale": "synthetic candidate satisfies the task",
    }
else:
    raise SystemExit("unexpected runner role; refusing provider fallback")
out.write_text(json.dumps(record))
if args.get("--result-file"):
    Path(args["--result-file"]).write_text(json.dumps({
        "schema": "singular.orchestration.runner-result.v0", "contractVersion": 1,
        "provider": "codex", "runId": run, "role": args.get("--role", "implementer"),
        "capabilityProfile": args.get("--capability-profile", "fixture"),
        "exitCode": 0, "outcome": "succeeded", "failureClass": "none",
        "providerErrorRef": None, "outputRef": str(out), "recordedAt": stamp,
    }))
