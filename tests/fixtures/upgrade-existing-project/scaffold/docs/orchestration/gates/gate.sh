#!/usr/bin/env bash
# singular gate adapter — scaffold. Copy to docs/orchestration/gates/gate.sh,
# point gateCommand at it, and replace the RUN block with your real gate.
#
# WHY THIS EXISTS
#
# The gate's exit code answers one question: did the command succeed? The engine
# needs two more that an exit code cannot express.
#
#   1. WHICH failures happened, as stable signatures. That is what lets a repo
#      register a baseline of known-failing tests (`singular gate baseline`) and
#      have the engine tell an acknowledged failure apart from a new one. With
#      no signatures the engine can only see "non-zero" and must treat every
#      run against a baseline as unclassifiable.
#
#   2. Whether the gate COULD RUN AT ALL. A missing dependency, a full disk or
#      an unreachable network is not a defect in the code under test, and the
#      engine must not spend a task's retry budget asking a model to fix code
#      that was never broken. Setting infrastructureFailure says so directly,
#      instead of leaving the engine to guess from log text.
#
# Neither is required. A gate that just exits 0 or 1 works: the engine reads the
# exit code, applies a deliberately conservative set of log signatures for the
# unmistakable environment failures, and otherwise calls a non-zero exit a
# product failure. This file is how you do better than that guess.
#
# CONTRACT
#
# The engine sets SINGULAR_GATE_REPORT_FILE to a path. Write a
# singular.orchestration.gate-observation.v0 document there, or don't — an absent
# file is a valid outcome and means "no structured information". It is never
# required just because the repo is on schemaVersion v2.
#
#   {
#     "schema": "singular.orchestration.gate-observation.v0",
#     "failures": [ {"signature": "suite/case-name", "title": "human summary"} ],
#     "infrastructureFailure": false,
#     "infrastructureReason": ""
#   }
#
# Signatures must be STABLE across runs — a file and test name, not a line
# number, a duration or a temp path — because a baseline matches on them.
# Report failures even when the command exits 0 if you know about them.
set -uo pipefail

report="${SINGULAR_GATE_REPORT_FILE:-}"
log="$(mktemp "${TMPDIR:-/tmp}/singular-gate.XXXXXX")"
trap 'rm -f "$log"' EXIT

# --- RUN: replace with your real gate ----------------------------------------
# Keep the output in "$log" so the classifier below can read it.
npm test >"$log" 2>&1
rc=$?
cat "$log"
# -----------------------------------------------------------------------------

[[ -n "$report" ]] || exit "$rc"

python3 - "$log" "$rc" "$report" <<'PY'
import json
import re
import sys

log_path, rc, report_path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
text = open(log_path, encoding="utf-8", errors="replace").read()

# --- infrastructure: did the gate fail to RUN? -------------------------------
# Prefer conditions you can check directly (a missing binary, an unset
# credential, a dependency directory that is not there) over log matching. Be
# strict: an infrastructure verdict is inconclusive, and the engine parks the
# task rather than retrying it. A product failure misreported here is a task
# that dies instead of getting fixed.
infrastructure = ""
for pattern, reason in (
    (r"\bENOSPC\b|\bno space left on device\b", "disk full"),
    (r"\bcannot find module\b|\bERR_MODULE_NOT_FOUND\b", "dependencies are not installed"),
    (r"\bTS2688\b|\bCannot find type definition file\b", "type packages are not installed"),
):
    if re.search(pattern, text, re.I):
        infrastructure = reason
        break

# --- failures: which tests failed, as stable signatures ----------------------
# Replace this with your runner's machine-readable output — `vitest --reporter
# json`, `jest --json`, `pytest --junitxml`, `go test -json`. Scraping human
# output is a stopgap; a signature that shifts between runs is worse than none,
# because a baseline silently stops matching.
failures = []
for match in re.finditer(r"^\s*(?:✕|×|FAIL)\s+(.+?)\s*$", text, re.M):
    signature = match.group(1).strip()
    if signature and not any(f["signature"] == signature for f in failures):
        failures.append({"signature": signature, "title": signature})

if rc != 0 and not failures and not infrastructure:
    # The command failed and nothing above explained why. Say that plainly
    # rather than inventing a signature a baseline might match by accident.
    failures.append({"signature": "gate-failed-without-parsed-failures"})

document = {
    "schema": "singular.orchestration.gate-observation.v0",
    "failures": failures,
}
if infrastructure:
    document["infrastructureFailure"] = True
    document["infrastructureReason"] = infrastructure

with open(report_path, "w", encoding="utf-8") as stream:
    json.dump(document, stream, indent=2)
    stream.write("\n")
PY

exit "$rc"
