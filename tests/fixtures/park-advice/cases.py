"""S0.4-8: a passing gate cannot be blamed for an auditor failure."""
from pathlib import Path
import re
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "acceptance-boundary-accept-packet"))
from fixture import TASK, Checks, Fixture, read


def main(root, scratch):
    c = Checks()
    for mode in ("unset", "every-path"):
        f = Fixture(root, Path(scratch) / mode, c,
                    Path(root) / "tests/fixtures/park-advice/runner.py")
        if mode != "unset":
            f.env["SINGULAR_ACCEPTANCE"] = mode
        result = f.command("drive", TASK)
        c.check("S0.4-8", mode + " infrastructure failure exits nonzero", result.returncode != 0)
        c.require("S0.4-8", mode + " worker ran once and auditor exhausted one retry",
                  f.counts() == {"worker": "1", "audit": "2"})
        events = f.events()
        c.require("S0.4-8", mode + " records audit infrastructure exhaustion",
                  any(e["type"] == "audit.infra_exhausted" for e in events))
        c.check("S0.4-8", mode + " exactly one auditor infrastructure retry",
                sum(e["type"] == "audit.infra_retry" for e in events) == 1)
        run_dir = f.state / "runs" / read(f.lease)["runId"]
        host = read(run_dir / "gate-report.json")
        c.require("S0.4-8", mode + " host gate passed before auditor failure", host["outcome"] == "passed")
        c.check("S0.4-8", mode + " task parked", f.status() == "blocked")
        c.check("S0.4-8", mode + " no accepted inbox publication",
                not list((f.state / "inbox").glob("*.json")))
        decisions = (f.orch / "decisions.md").read_text()
        entries = re.split(r"(?m)^### ", decisions)
        terminal = [entry for entry in entries if TASK in entry.splitlines()[0]
                    and entry.splitlines()[0].rstrip().endswith("— escalate-infra")]
        c.require("S0.4-8", mode + " terminal infrastructure decision exists", bool(terminal))
        rationale = re.search(r"(?m)^- Rationale:\s*(.+)$", terminal[-1])
        c.require("S0.4-8", mode + " parked reason exists", rationale is not None)
        reason = rationale.group(1)
        # Remove machine failure-class labels. 'audit-infra' alone existed
        # before this fix and cannot prove phase-specific user advice.
        advice = re.sub(r"\([^)]*\)", "", reason)
        c.check("S0.4-8", mode + " parked advice names auditor phase",
                bool(re.search(r"\b(audit|auditor|auditing)\b", advice, re.I)))
        c.check("S0.4-8", mode + " parked advice does not blame successful gate",
                not re.search(r"(?:could not|cannot|unable to|failed to)\s+(?:run|execute)\s+(?:the\s+)?gate", advice, re.I))
        c.check("S0.4-8", mode + " advice retains public recovery command",
                "singular unpark TASK-0001" in reason)
    print("TOTAL assertion failures: " + str(c.failures), flush=True)
    return bool(c.failures)


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
