"""Compare a completed drive against frozen candidate observations."""
import difflib
import hashlib
import json
import re
import shlex
from pathlib import Path
import sys

engine, scratch, expected = map(Path, sys.argv[1:])
project = scratch / "synthetic-widget"
state = project / ".singular-state"
runs = list((state / "runs").glob("RUN-*"))
assert len(runs) == 1, "expected exactly one ordinary run"
run = runs[0]
for path in (run / "packet.json", state / "inbox" / (run.name + ".json"),
             state / "leases/TASK-0001.json"):
    assert json.loads(path.read_bytes())["status"] == "accepted", "not accepted: " + path.name
assert "Status: accepted" in (project / "docs/orchestration/tasks/TASK-0001.md").read_text()
events = [json.loads(line)["type"] for line in (state / "events.ndjson").read_bytes().splitlines()]
assert events.count("l1.task_accepted") == 1, "expected one acceptance event"
captures = scratch / "captures"
for role in ("worker", "audit"):
    assert (captures / role).read_text() == "1", "expected exactly one " + role

observed = scratch / "observed"
observed.mkdir(exist_ok=True)
names = []
for path in sorted(run.rglob("*")):
    if not (path.is_file() or path.is_symlink()):
        continue
    name = str(path.relative_to(run))
    match = re.fullmatch(r"delivery-prompt-([0-9a-f]{64})\.md", name)
    if match:
        assert hashlib.sha256(path.read_bytes()).hexdigest() == match[1], "delivery prompt digest mismatch"
        name = "delivery-prompt-<SHA256>.md"
    names.append(name)
(observed / "run-files.txt").write_text("".join(name + "\n" for name in sorted(names)))
(observed / "event-kinds.txt").write_text("".join(kind + "\n" for kind in events))
lease = json.loads((state / "leases/TASK-0001.json").read_bytes())
packet = json.loads((run / "packet.json").read_bytes())
verification = json.loads((run / "audit-verification.json").read_bytes())
shell = shlex.split(verification["command"])[0]
assert Path(shell).name == "bash" and Path(shell).is_absolute(), "expected resolved Bash executable"
for role in ("worker", "audit"):
    data = (captures / (role + "-prompt.md")).read_bytes()
    for value, token in ((str(project), "<PROJECT>"), (str(scratch), "<SCRATCH>"),
                         (str(engine), "<ENGINE>"), (run.name, "<RUN>"),
                         (lease["baseSha"], "<BASE-SHA>"), (packet["headSha"], "<HEAD-SHA>"),
                         (shell, "<BASH>")):
        data = data.replace(value.encode(), token.encode())
    # Only named volatile JSON fields, preserving whitespace and all other bytes.
    data = re.sub(rb'("recordedAt": ")\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z(")', rb'\1<TIMESTAMP>\2', data)
    for field in (b"evidenceBindingSha256", b"requestIdentity", b"verificationResultBindingSha256",
                  b"commandSha256", b"evidenceSourceCommandIdentity"):
        data = re.sub(rb'("' + field + rb'": ")[0-9a-f]{64}(")', rb'\1<SHA256>\2', data)
    data = re.sub(rb'(Artifact: (?:packet|audit-verification)\.json SHA256: )[0-9a-f]{64}',
                  rb'\1<SHA256>', data)
    (observed / (role + "-prompt.md")).write_bytes(data)

for name in ("run-files.txt", "event-kinds.txt", "worker-prompt.md", "audit-prompt.md"):
    actual = (observed / name).read_bytes()
    assert (expected / name).is_file(), "missing baseline: " + name
    baseline = (expected / name).read_bytes()
    if actual != baseline:
        print("".join(difflib.unified_diff(
            baseline.decode().splitlines(keepends=True), actual.decode().splitlines(keepends=True),
            fromfile="expected/" + name, tofile="observed/" + name)), file=sys.stderr)
        raise SystemExit("parity mismatch: " + name)
