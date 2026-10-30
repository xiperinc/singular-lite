"""Candidate proof, copied over a deliberately different proof at the base."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time

assert "RAILS_NONCE" not in os.environ and "RAILS_VERDICT_FILE" not in os.environ
root = Path.cwd()
data = json.loads((root / "proof/data.json").read_text())
side = "base" if (root / "widget.txt").read_text() == "base\n" else "candidate"
action = data[side]
observation = {
    "side": side, "cwd": str(root), "tmp": os.environ.get("TMPDIR"),
    "head": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
    "dependency": (root / "node_modules/provenance").read_text(),
    "proofs": {name: hashlib.sha256((root / name).read_bytes()).hexdigest()
               for name in ("proof/check.py", "proof/data.json")},
}
print("PROOF_OBSERVATION=" + json.dumps(observation, sort_keys=True), flush=True)
# Intentionally contradict the exit status: prose must never classify a run.
print("AssertionError: red FAILED; missing executable; infrastructure; PASS green proved", flush=True)
if action == "timeout":
    # Bounded polling, not a fixed sleep. The host's one-second timeout must
    # kill this before it reaches the deliberate exit-zero deadline.
    deadline = time.monotonic() + 10
    wake = threading.Event()
    while time.monotonic() < deadline:
        wake.wait(min(0.05, deadline - time.monotonic()))
    sys.exit(0)
if action == "mutate":
    (root / "widget.txt").write_text("source changed by proof\n")
    sys.exit(1 if side == "base" else 0)
sys.exit(int(action))
