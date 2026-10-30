"""Frozen S0.4-3/4 tests; all enforcement goes through the public CLI."""
import json
from pathlib import Path
import re
import sys
from fixture import BRANCH, TASK, Checks, Fixture, digest, read, write


def task_events(events):
    return [event for event in events if event.get("data", {}).get("taskId") == TASK]


def refusal_events(events):
    return [event for event in task_events(events)
            if "acceptance" in event.get("type", "") and "refus" in event.get("type", "")]


def park_events(events):
    return [event for event in task_events(events) if re.search(
        r"park|awaiting-audit", event.get("type", "") + " " + event.get("message", "")
        + " " + str(event.get("data", {}).get("action", "")), re.I)]


def breaker(f):
    path = f.state / "circuit.json"
    return read(path).get("consecFails", 0) if path.is_file() else 0


def cycle(f):
    # Real reconcile, no synthetic counters and no planner/provider calls.
    result = f.command("auto", "--once")
    f.checks.check("S0.4-4", "bounded real loop cycle completes", result.returncode == 0)
    return result


def refusal_exit(f, result, before, initial_status, packet_before, label):
    c = f.checks
    new = f.events()[before:]
    c.check("S0.4-3", label + " exits nonzero", result.returncode != 0)
    c.check("S0.4-3", label + " publishes no inbox packet",
            not list((f.state / "inbox").glob("*.json")))
    c.check("S0.4-3", label + " leaves target unchanged",
            f.git("rev-parse", "target").stdout.strip() == f.case_target)
    # A pending direct packet must never acquire accepted. Recovery begins
    # accepted; it may retain history or demote it, but may not enqueue it.
    if packet_before["status"] != "accepted":
        c.check("S0.4-3", label + " does not stamp accepted", read(f.packet)["status"] != "accepted")
    c.check("S0.4-4", label + " emits a task-specific refusal event", bool(refusal_events(new)))
    parks = park_events(new)
    c.check("S0.4-4", label + " changes task status on first refusal",
            f.status() != initial_status and f.status() in {"blocked", "parked", "awaiting-audit"})
    c.check("S0.4-4", label + " emits a park record naming the task", bool(parks))
    records = refusal_events(new) + parks
    # Match a refusal's own durable record; generic task prose cannot satisfy it.
    c.check("S0.4-4", label + " reason names resolver and earning command", any(
        re.search(r"\b(operator|human|maintainer|reviewer|auditor)\b", json.dumps(e), re.I)
        and "singular drive TASK-0001 --audit-only" in json.dumps(e)
        for e in records))
    after_refusal = len(f.events())
    cycle(f)
    c.check("S0.4-4", label + " refusal counts toward real breaker", breaker(f) > 0)
    c.check("S0.4-4", label + " next cycle repeats neither refusal nor parking",
            not refusal_events(f.events()[after_refusal:]) and not park_events(f.events()[after_refusal:]))
    c.check("S0.4-4", label + " next cycle leaves task parked",
            f.status() in {"blocked", "parked", "awaiting-audit"})
    c.check("S0.4-3", label + " calls no worker or auditor", f.counts() == f.original_counters)


def recovered_certificate(f, label):
    c = f.checks
    c.check("S0.4-3", label + " preserves independent audit bytes", f.audit.read_bytes() == f.original_audit)
    c.check("S0.4-3", label + " preserves completed review rounds", f.rounds() == f.original_rounds)
    manifest = read(f.manifest)
    artifacts = {a["ref"]: a["sha256"] for a in manifest["artifacts"]}
    c.check("S0.4-3", label + " binds kept audit and exact host report",
            all(artifacts.get(p.name) == digest(p) for p in (f.audit, f.report)))
    c.check("S0.4-3", label + " published certificate validates", f.validate().returncode == 0)
    c.check("S0.4-3", label + " stores deterministic reruns as separate evidence",
            any(x.get("command") == "test -f widget.txt" and x.get("exitCode") == 0
                and x.get("logRef") not in {old.get("logRef") for old in f.original_commands}
                and (f.run_dir / x.get("logRef", "missing")).is_file()
                for x in manifest.get("commands", [])))
    c.check("S0.4-3", label + " launches no replacement audit", f.counts() == f.original_counters)


def missing_diagnostic(output, subject):
    for line in output.splitlines():
        if (re.search(r"\b(?:" + subject + r")\b", line, re.I)
                and re.search(r"missing|requir|absen|lack|incomplete|not[- ](?:found|present|complete|accepted)", line, re.I)):
            return True
    return False


def main(root, scratch):
    c = Checks()
    f = Fixture(root, scratch, c)
    f.env["SINGULAR_RESUME_ACCEPTED_EVIDENCE"] = "0"
    f.seed()

    # Same validated certificate in both compatibility settings and both paths.
    for mode in ("unset", "driver-only"):
        for route in ("direct", "stranded"):
            f.restore(mode)
            before = len(f.events())
            result = f.command("accept-packet", f.packet) if route == "direct" else f.command("drive", TASK)
            label = mode + " " + route
            c.check("S0.4-3", label + " retains successful legacy acceptance", result.returncode == 0)
            c.check("S0.4-3", label + " packet is accepted", read(f.packet)["status"] == "accepted")
            c.check("S0.4-3", label + " retains host-authored legacy audit", f.audit.read_bytes() != f.original_audit)
            c.check("S0.4-3", label + " retains legacy manifest excluding audit.json",
                    "audit.json" not in {a["ref"] for a in read(f.manifest)["artifacts"]})
            c.check("S0.4-4", label + " adds no strict refusal or park",
                    not refusal_events(f.events()[before:]) and not park_events(f.events()[before:]))
            if route == "stranded":
                c.check("S0.4-3", label + " uses stranded recovery and queues packet",
                        any(e["type"] == "l1.auto_accepted_existing" for e in f.events()[before:])
                        and (f.state / "inbox" / (f.run_id + ".json")).is_file())
            cycle(f)
            c.check("S0.4-4", label + " loop adds no strict parking or breaker charge",
                    not park_events(f.events()[before:]) and breaker(f) == 0)

        # The pre-existing stranded missing-round refusal stays as it is:
        # status remains accepted, no park and no new breaker charge.
        f.restore(mode)
        f.mutate("round-missing")
        before = len(f.events())
        result = f.command("drive", TASK)
        c.check("S0.4-3", mode + " keeps existing stranded missing-round refusal",
                result.returncode != 0 and not list((f.state / "inbox").glob("*.json")))
        c.check("S0.4-4", mode + " legacy refusal does not newly park task", f.status() == "accepted")
        cycle(f)
        c.check("S0.4-4", mode + " legacy refusal loop has no new park or breaker charge",
                not park_events(f.events()[before:]) and breaker(f) == 0)

    # A valid strict direct control proves the command is not simply disabled.
    f.restore(pending=True)
    result = f.command("accept-packet", f.packet)
    c.check("S0.4-3", "strict direct valid certificate succeeds", result.returncode == 0)
    c.check("S0.4-3", "strict direct valid certificate becomes accepted",
            read(f.packet)["status"] == "accepted")
    recovered_certificate(f, "strict direct")

    # Independent single-defect guards. A mutation's manifest is rebound when
    # needed so an audit defect cannot accidentally be an E defect as well.
    for route in ("direct", "stranded"):
        for defect, conjunct, source in (("audit-verdict", "A", "env"),
                                         ("round-missing", "D", "shell"),
                                         ("manifest-audit-hash", "E", "env")):
            f.restore(source=source, pending=route == "direct")
            f.mutate(defect)
            f.isolated_defect(conjunct)
            before = len(f.events())
            initial = f.status()
            packet_before = read(f.packet)
            result = f.command("accept-packet", f.packet) if route == "direct" else f.command("drive", TASK)
            refusal_exit(f, result, before, initial, packet_before, route + " " + defect)

    # This combined omission is the explicit diagnostic scenario in S0.4-3,
    # not evidence for any individual guard. The cases above isolate guards.
    f.restore(source="shell", pending=True)
    f.audit.unlink()
    f.mutate("round-missing")
    # Start task ready so the one-time parked transition is observable.
    f.task.write_text(f.task.read_text().replace("Status: blocked", "Status: ready"))
    before = len(f.events())
    packet_before = read(f.packet)
    result = f.command("accept-packet", f.packet)
    c.check("S0.4-3", "omitted independent audit is named", missing_diagnostic(result.stdout, r"audit"))
    c.check("S0.4-3", "omitted completed round is named",
            missing_diagnostic(result.stdout, r"review|round|ledger"))
    c.check("S0.4-3", "missing-rule diagnostic prints earning command",
            "singular drive TASK-0001 --audit-only" in result.stdout)
    refusal_exit(f, result, before, "ready", packet_before, "missing audit and round")

    # Repair is fixture-owned snapshot restoration, never another row's verb.
    # Positive recovery must preserve and validate the exact final certificate
    # before the real every-path import and integration commands are attempted.
    f.restore(source="shell")
    c.require("S0.4-3", "restored retained certificate is valid", f.validate().returncode == 0)
    result = f.command("drive", TASK)
    c.check("S0.4-3", "strict stranded recovery succeeds", result.returncode == 0)
    c.check("S0.4-3", "strict stranded recovery enqueues candidate",
            (f.state / "inbox" / (f.run_id + ".json")).is_file())
    recovered_certificate(f, "strict recovery")
    result = f.run([f.env["TEST_BASH"], f.root / "engine/import-packet.sh", f.packet])
    c.check("S0.4-3", "recovered candidate passes real every-path import", result.returncode == 0)
    imported = f.orch / "packets/imported" / TASK / (f.run_id + ".json")
    c.check("S0.4-3", "import publishes recovered head", imported.is_file() and read(imported)["headSha"] == f.head)
    result = f.command("integrate", "--task", TASK)
    c.check("S0.4-3", "recovered candidate passes real every-path integration", result.returncode == 0)
    c.check("S0.4-3", "target actually contains candidate commit",
            f.run(["git", "merge-base", "--is-ancestor", f.head, "target"]).returncode == 0)
    print("TOTAL assertion failures: " + str(c.failures), flush=True)
    return bool(c.failures)


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
