#!/usr/bin/env python3
"""Parity fixture's runner protocol, extended to supply repairable proof tests."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

assert "RAILS_NONCE" not in os.environ and "RAILS_VERDICT_FILE" not in os.environ
if sys.argv[1:] == ["--describe-contract"]:
    print(json.dumps({
        "schema": "singular.runner-contract.v1", "version": 1, "provider": "codex",
        "arguments": ["--worktree", "--prompt-file", "--level", "--run-id",
                      "--output-last-message", "--role", "--capability-profile",
                      "--result-file", "--describe-contract"],
        "structuredResult": "singular.orchestration.runner-result.v0",
        "structuredProviderError": "singular.orchestration.provider-error.v0",
    }))
    sys.exit(0)

args = sys.argv[1:]
def arg(*names):
    return next((args[args.index(name) + 1] for name in names if name in args), "")

worktree = Path(arg("--worktree", "-C"))
output = Path(arg("--output-last-message"))
run = arg("--run-id")
role = arg("--role") or os.environ.get("SINGULAR_RUNNER_ROLE", "")
worker = arg("--level") == "l2"
captures = Path(os.environ["RP_CAPTURES"])
captures.mkdir(exist_ok=True)
kind = "worker" if worker else "audit"
if "decider" in arg("--prompt-file"):
    kind = "decider"
count_path = captures / kind
count = int(count_path.read_text()) + 1 if count_path.exists() else 1
count_path.write_text(str(count))
prompt = Path(arg("--prompt-file")).read_text()
(captures / f"{kind}-{count}-prompt.md").write_text(prompt)
case = json.loads(Path(os.environ["RP_CASE"]).read_text())

if kind == "worker":
    assert count <= 3, "unbounded worker repair"
    data = {"base": case["base"], "candidate": case["candidate"]}
    if case.get("repair_chain"):
        data = [{"base": 0, "candidate": 0}, {"base": 1, "candidate": 1},
                {"base": 1, "candidate": 0}][count - 1]
    (worktree / "widget.txt").write_text(f"candidate {count}\n")
    (worktree / "proof").mkdir(exist_ok=True)
    shutil.copyfile(Path(__file__).with_name("proof.py"), worktree / "proof/check.py")
    (worktree / "proof/data.json").write_text(json.dumps(data) + "\n")
    # Distinguish the main dependency source from the worker's dependency copy.
    (worktree / "node_modules").mkdir(exist_ok=True)
    (worktree / "node_modules/provenance").write_text("worker\n")
    (worktree / "worker-sentinel").write_text("preserve ignored worker data\n")
    evidence = worktree / ".singular-evidence"
    evidence.mkdir(exist_ok=True)
    for phase in ("red", "green", "regression"):
        (evidence / (phase + ".log")).write_text(phase + " worker claim, not host proof\n")
    owned = ["widget.txt", "proof/check.py", "proof/data.json"]
    subprocess.run(["git", "-C", str(worktree), "add", "--", *owned], check=True)
    subprocess.run(["git", "-C", str(worktree), "-c", "commit.gpgsign=false",
                    "commit", "-qm", "fixture candidate"], check=True)
    head = subprocess.check_output(["git", "-C", str(worktree), "rev-parse", "HEAD"], text=True).strip()
    (captures / f"worker-{count}-snapshot.json").write_text(json.dumps({
        "head": head, "worktree": str(worktree),
        "files": {p: hashlib.sha256((worktree / p).read_bytes()).hexdigest()
                  for p in [*owned, "node_modules/provenance", "worker-sentinel"]},
    }))
    record = {
        "schema": "singular.orchestration.state-packet.v0", "packetId": "fixture",
        "taskId": "TASK-0001", "runId": run, "area": "widget", "role": "l2-developer",
        "status": "needs-review", "baseRef": "target",
        "branch": "agent/widget/TASK-0001-fixture", "headSha": head,
        "workspace": str(worktree), "ownedFiles": owned, "changedFiles": owned,
        "commands": [{"cmd": "test -f widget.txt", "exitCode": 0,
                      "logRef": ".singular-evidence/green.log"}],
        "tests": [{"name": p, "phase": p, "status": "failed-as-expected" if p == "red" else "passed",
                   "logRef": f".singular-evidence/{p}.log"} for p in ("red", "green", "regression")],
        "evidence": [{"kind": p + "-log", "ref": f".singular-evidence/{p}.log"}
                     for p in ("red", "green", "regression")],
        "blockers": [], "nextAction": "audit", "createdAt": "2026-01-01T00:00:00Z",
    }
elif kind == "decider":
    # Product failures may consult a decider. Infrastructure must never need
    # another worker: the driver, not this stub, must enforce that distinction.
    match = re.search(r"Decision class:\s*`?([^`\s]+)", prompt, re.I)
    record = {"schema": "singular.orchestration.decider-verdict.v0",
              "failureClass": match.group(1) if match else "red-proof",
              "action": "retry", "rationale": "repair the product", "nextOwner": "l1"}
else:
    record = {
        "schema": "singular.orchestration.audit-verdict.v0", "taskId": "TASK-0001", "runId": run,
        "branch": "agent/widget/TASK-0001-fixture", "verdict": "accepted",
        "evidenceReviewed": [], "commandsRun": [], "findings": [], "requiredFixes": [],
        "rationale": "synthetic clean audit",
    }
output.write_text(json.dumps(record) + "\n")
if arg("--result-file"):
    Path(arg("--result-file")).write_text(json.dumps({
        "schema": "singular.orchestration.runner-result.v0", "contractVersion": 1,
        "provider": "codex", "runId": run, "role": role,
        "capabilityProfile": arg("--capability-profile"), "exitCode": 0,
        "outcome": "succeeded", "failureClass": "none", "providerErrorRef": None,
        "outputRef": str(output), "recordedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }) + "\n")
