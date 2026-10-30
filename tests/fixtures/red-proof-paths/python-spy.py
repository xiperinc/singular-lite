#!/usr/bin/env python3
"""Delete V at audit-only's final acceptance seam, then execute real Python.

No acceptance answer, driver function or other conjunct is stubbed. The spy
also injects a valid fixture record for the positive seam control, making this
acceptance test independent of whether the earlier proof phase is implemented.
"""
import json
import os
from pathlib import Path
import sys
from proof import install, remove, SCHEMA

assert "RAILS_NONCE" not in os.environ and "RAILS_VERDICT_FILE" not in os.environ
args = sys.argv[1:]
if args and Path(args[0]).name == "acceptance_validator.py" and any(x.startswith("--run-dir") for x in args):
    def option(name):
        for i, arg in enumerate(args):
            if arg.startswith(name + "="):
                return arg.split("=", 1)[1]
            if arg == name:
                return args[i + 1]
        raise AssertionError("missing validator input " + name)
    run = Path(option("--run-dir"))
    repo = Path(option("--repo-root"))
    head = option("--head")
    lease = json.loads((Path(os.environ["SINGULAR_LEASES_DIR"]) / "TASK-0001.json").read_text())
    request = json.loads((run / "audit-verification.json").read_text())["verificationRequest"]
    existing = []
    for path in run.rglob("*.json"):
        try:
            value = json.loads(path.read_text())
        except (ValueError, OSError):
            continue
        if (isinstance(value, dict) and value.get("schema") == SCHEMA
                and value.get("headSha") == head and value.get("attempt") == request["attempt"]):
            existing.append(path)
    # Preserve a real producer record (and any manifest binding it carries).
    # Before the producer exists, use the same synthetic positive fixture.
    if not existing:
        install(repo, run, head, lease["baseSha"], request["attempt"])
    if os.environ["PROOF_SPY_ACTION"] == "remove":
        remove(run)
    with open(os.environ["PROOF_SPY_CALLS"], "a") as output:
        output.write(json.dumps(dict(run=str(run), head=head, action=os.environ["PROOF_SPY_ACTION"])) + "\n")
os.execv(os.environ["PROOF_REAL_PYTHON"], [os.environ["PROOF_REAL_PYTHON"], *args])
