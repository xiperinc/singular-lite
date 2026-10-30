#!/usr/bin/env python3
"""The worker succeeds; the auditor cannot start its infrastructure."""
import os
from pathlib import Path
import runpy
os.environ["PACKET_AUDIT_INFRA"] = "1"
runpy.run_path(str(Path(__file__).resolve().parents[1] /
                   "acceptance-boundary-accept-packet/runner.py"), run_name="__main__")
