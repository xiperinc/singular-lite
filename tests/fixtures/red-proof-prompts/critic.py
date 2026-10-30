#!/usr/bin/env python3
"""Local read-only critic, adapted from test-ctx-plan-critic.sh's stub."""
import json
import os
from pathlib import Path
import sys

assert "RAILS_NONCE" not in os.environ
assert "RAILS_VERDICT_FILE" not in os.environ
args = sys.argv[1:]
if args == ["--describe-contract"]:
    # Legacy runner interface, supported by the real critic runtime.
    raise SystemExit(2)

def arg(name):
    return args[args.index(name) + 1]

assert arg("--level") == "readonly"
capture = Path(os.environ["PROMPTS_CRITIC_CAPTURE"])
assert not capture.exists(), "critic unexpectedly retried"
capture.write_bytes(Path(arg("--prompt-file")).read_bytes())
Path(arg("--output-last-message")).write_text(json.dumps({
    "schema": "singular.orchestration.plan-critique.v0",
    "node": "widget", "runId": arg("--run-id"),
    "batchTaskIds": ["TASK-0001"], "verdict": "approve",
    "findings": [], "assumptionsChallenged": [],
    "rationale": "Synthetic prompt capture.",
}) + "\n")
