"""V refusals park recovery once, and restored proof can be retried."""
from pathlib import Path
import sys
import tempfile

root = Path(sys.argv[1]).resolve()
bash = sys.argv[2]
sys.path.insert(0, str(root / "tests/fixtures/red-proof-paths"))
from fixture import Checks, Fixture, read
from proof import install
from suite import driver_parts, path_case, run_route

failures = 0
with tempfile.TemporaryDirectory(prefix="vr.") as temporary:
    home = Path(temporary)
    parts = driver_parts(root, home, bash)
    for route, event in (("retained", "l1.acceptance_refused"), ("regate", "candidate.acceptance_refused")):
        folder = home / route
        folder.mkdir()
        checks = Checks()
        fixture = Fixture(root, folder, checks)
        fixture.env["TEST_BASH"] = bash
        fixture.seed()
        failures += path_case(root, folder, parts, bash, route, "enforce", "every-path", fixture=fixture)
        checks.check("parking", route + " lease blocked", read(fixture.lease)["status"] == "blocked")
        checks.check("parking", route + " task blocked", "Status: blocked" in fixture.task.read_text())
        before = len([item for item in fixture.events() if item.get("type") == event])
        repeated = run_route(fixture, route, parts)
        after = len([item for item in fixture.events() if item.get("type") == event])
        checks.check("parking", route + " retry still refuses", repeated.returncode != 0)
        checks.check("parking", route + " emits refusal once", before == after == 1)
        install(fixture.repo, fixture.run_dir, fixture.head, fixture.original_head)
        repaired = run_route(fixture, route, parts)
        checks.check("parking", route + " repaired evidence can retry", repaired.returncode == 0)
        if repaired.returncode:
            print(repaired.stdout[-2000:])
        failures += checks.failures
    folder = home / "audit-only"
    folder.mkdir()
    checks = Checks()
    fixture = Fixture(root, folder, checks)
    fixture.env["TEST_BASH"] = bash
    fixture.seed()
    failures += path_case(root, folder, parts, bash, "audit-only", "enforce", "every-path", fixture=fixture)
    checks.check("parking", "audit-only lease blocked", read(fixture.lease)["status"] == "blocked")
    # An accepted audit closes its review series even when V later refuses.
    # Recovery must not silently grant a new review budget.
    closed = fixture.command("review-policy", "check", "--logical-change", "TASK-0001", "--task", "TASK-0001")
    checks.check("parking", "V refusal does not reopen review authority", closed.returncode == 4)
    current_run = read(fixture.lease)["runId"]
    refusal = fixture.state / "runs" / current_run / "accept-existing-packet-refusal.json"
    reopened = fixture.command("review-policy", "reopen", "--logical-change", "TASK-0001",
        "--task", "TASK-0001", "--authority", "fixture-operator", "--reason", "proof evidence repaired",
        "--evidence", refusal, "--if-closed")
    checks.require("parking", "operator explicitly reopens review", reopened.returncode == 0)
    fixture.env["PROOF_SPY_ACTION"] = "valid"
    repaired = run_route(fixture, "audit-only", parts)
    checks.check("parking", "audit-only can earn a fresh proof and certificate", repaired.returncode == 0)
    checks.check("parking", "audit-only retry never invokes implementer", not (fixture.counters / "worker").exists())
    if repaired.returncode:
        print(repaired.stdout[-2000:])
    failures += checks.failures
sys.exit(bool(failures))
