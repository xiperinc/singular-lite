#!/usr/bin/env python3
"""Observe Git mutations; optionally make only proof checkout creation fail."""
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
if any(word in args for word in ("checkout", "restore", "reset", "worktree")):
    with open(os.environ["RP_GIT_CALLS"], "a") as out:
        out.write(json.dumps({"cwd": os.getcwd(), "argv": args}) + "\n")
    if "worktree" in args and "add" in args:
        state = Path(os.environ["SINGULAR_STATE_DIR"]).resolve()
        destinations = [Path(arg).resolve() for arg in args if arg.startswith("/")]
        if os.environ.get("RP_SETUP_FAIL") == "1" and any(state in p.parents for p in destinations):
            print("fixture: proof checkout setup denied", file=sys.stderr)
            sys.exit(128)
os.execv(os.environ["RP_REAL_GIT"], [os.environ["RP_REAL_GIT"], *args])
