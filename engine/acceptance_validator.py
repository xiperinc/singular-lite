#!/usr/bin/env python3
"""The one acceptance predicate every accepted-packet publication rechecks.

Protocol 1.1 (consultation #2, loop economics):

    PublishAccepted(K)  <=>  G(K) and A(K) and D(K) and E(K)

for the exact candidate K (task, run, branch, head, tree, campaign):

  G  the trusted host verification report passed for this exact head and tree,
     and its request/result binding validates (gate-report.py, --require-pass);
  A  the audit verdict is host-bound to K, its effective verdict is accepted,
     and no blocking finding is unresolved or unclassified;
  D  the review-policy ledger durably holds the completed round for this
     run/attempt/head with effectiveVerdict accepted;
  E  the evidence manifest is bound to K and to the exact verdict and host
     report being published.

Budget availability is deliberately absent: budgets authorize work, never
acceptance. Waivers and --no-audit cannot satisfy A; the driver refuses those
before or through this check.

Structural JSON-Schema validation of the audit verdict and the manifest uses
the shell checker in lib.sh, so the driver wrapper (l1_validate_acceptance in
l1-drive.sh) runs those first and then this module. This module owns the
predicate itself and is directly testable.

Exit 0: all four conjuncts hold. Exit 1: refused (stdout names the failing
conjunct and reason). Exit 2: usage error.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

ENGINE_DIR = Path(__file__).resolve().parent
# The engine tree may be read-only or byte-pinned (frozen campaigns); never
# write bytecode next to it when importing sibling modules.
sys.dont_write_bytecode = True
sys.path.insert(0, str(ENGINE_DIR))

import review_policy  # noqa: E402


def _load_host_bind() -> Any:
    spec = importlib.util.spec_from_file_location(
        "audit_verdict_host_bind", ENGINE_DIR / "audit-verdict-host-bind.py"
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


host_bind = _load_host_bind()

RESULT_SCHEMA = "singular.orchestration.acceptance-check.v0"
PASSING_HOST = {"passed", "not-rerun-evidence-verified"}
# Protocol 5.1(5): configuration may make the blocking set stricter, never
# remove this floor.
BLOCKING_FLOOR = {"P0", "P1"}


class Refusal(Exception):
    def __init__(self, conjunct: str, reason: str, detail: str = "") -> None:
        super().__init__(reason)
        self.conjunct = conjunct
        self.reason = reason
        self.detail = detail


def sha_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_regular(path: Path, conjunct: str, missing: str, invalid: str) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise Refusal(conjunct, missing, str(path))
    try:
        return host_bind.read_object(path, path.name)
    except ValueError as exc:
        raise Refusal(conjunct, invalid, str(exc)) from exc


def text(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


# ---- G: trusted host verification of the exact candidate --------------------
def check_gate(args: argparse.Namespace, run_dir: Path) -> tuple[Path, int]:
    report_path = run_dir / "audit-verification.json"
    report = read_regular(report_path, "G", "host-report-missing", "host-report-invalid")
    try:
        classification = host_bind.host_classification(report)
    except ValueError as exc:
        raise Refusal("G", "host-report-invalid", str(exc)) from exc
    if classification not in PASSING_HOST:
        raise Refusal("G", "host-verification-not-passed", classification)
    request = report.get("verificationRequest")
    if not isinstance(request, dict):
        raise Refusal("G", "host-report-unbound", "no verificationRequest binding")
    if request.get("runId") != args.run:
        raise Refusal("G", "host-report-run-mismatch", str(request.get("runId")))
    if request.get("headSha") != args.head:
        # A report for any other head is stale for this candidate.
        raise Refusal("G", "host-report-head-mismatch", str(request.get("headSha")))
    attempt = request.get("attempt")
    if not isinstance(attempt, int) or isinstance(attempt, bool) or attempt < 1:
        raise Refusal("G", "host-report-unbound", f"attempt {attempt!r}")
    if args.attempt is not None and attempt != args.attempt:
        raise Refusal("G", "host-report-attempt-mismatch", f"report={attempt} expected={args.attempt}")
    tree = subprocess.run(
        ["git", "-C", args.repo_root, "rev-parse", "--verify", "--quiet", args.head + "^{tree}"],
        capture_output=True, text=True, check=False,
    ).stdout.strip()
    if not tree:
        raise Refusal("G", "candidate-tree-unresolved", args.head)
    command = [
        sys.executable, str(ENGINE_DIR / "gate-report.py"), "verify-verification-result",
        "--request", str(run_dir / f"verification-request-{attempt}.json"),
        "--report", str(report_path),
        "--task-contract", str(run_dir / f"verification-task-contract-{attempt}.md"),
        "--policy-contract", str(run_dir / f"verification-policy-{attempt}.json"),
        "--expected-task", args.task, "--expected-run", args.run,
        "--expected-head", args.head, "--expected-tree", tree,
        "--expected-suite", "task-contract-gate",
        "--expected-campaign", args.campaign,
        "--expected-attempt", str(attempt),
        "--require-pass",
    ]
    if args.task_contract:
        command += ["--current-task-contract", args.task_contract]
    completed = subprocess.run(command, capture_output=True, text=True, check=False)
    if completed.returncode:
        detail = (completed.stderr or completed.stdout).strip().splitlines()
        raise Refusal("G", "verification-binding-invalid", detail[-1] if detail else "")
    return report_path, attempt


# ---- D: the durable review-ledger round for this run/attempt/head -----------
def ledger_rounds(args: argparse.Namespace) -> list[dict[str, Any]]:
    try:
        with review_policy.locked_ledger(Path(args.state_dir), write=False) as ledger:
            pass
    except review_policy.LedgerError as exc:
        raise Refusal("D", "review-ledger-invalid", str(exc)) from exc
    entry = (ledger.get("logicalChanges") or {}).get(args.logical_change)
    rounds = entry.get("rounds") if isinstance(entry, dict) else None
    if not isinstance(rounds, list):
        return []
    return [item for item in rounds if isinstance(item, dict)]


def check_ledger(
    args: argparse.Namespace, rounds: list[dict[str, Any]], attempt: int
) -> dict[str, Any]:
    mine = [item for item in rounds if item.get("runId") == args.run]
    if not mine:
        raise Refusal("D", "review-round-missing", f"no completed round for {args.run}")
    row = mine[-1]
    if row.get("attempt") != attempt:
        raise Refusal("D", "review-round-stale", f"latest round attempt {row.get('attempt')!r}, candidate attempt {attempt}")
    if row.get("head") != args.head:
        raise Refusal("D", "review-round-head-mismatch", str(row.get("head")))
    binding = text(row.get("campaignBinding"))
    if binding and binding != args.campaign:
        raise Refusal("D", "review-round-campaign-mismatch", binding)
    if row.get("effectiveVerdict") != "accepted":
        raise Refusal("D", "review-round-not-accepted", str(row.get("effectiveVerdict")))
    if row.get("blocking") or row.get("downgraded") or row.get("unclassifiedCount"):
        raise Refusal("D", "review-round-unresolved", json.dumps({
            key: row.get(key) for key in ("blocking", "downgraded", "unclassifiedCount")
        }, sort_keys=True))
    return row


# ---- A: a host-bound, completely classified, nonblocking audit --------------
def check_audit_identity(args: argparse.Namespace, audit_path: Path, report_path: Path) -> dict[str, Any]:
    audit = read_regular(audit_path, "A", "audit-missing", "audit-invalid")
    # The audit's own runId is a model-echoed label and not part of K: the
    # run is bound by the host verification request (G) and the ledger round
    # the driver recorded for this run (D), and the reviewed head by the
    # host-stamped reviewed-head-sha marker checked here. The driver has always
    # tolerated a mismatched echo (infra retries reuse runs); import-packet
    # keeps its stricter sidecar identity check.
    try:
        schema = host_bind.validate_identity(
            audit, task=args.task, run=str(audit.get("runId") or args.run),
            branch=args.branch, head=args.head,
        )
    except ValueError as exc:
        raise Refusal("A", "audit-identity-mismatch", str(exc)) from exc
    if audit.get("verdict") != "accepted":
        raise Refusal("A", "audit-not-accepted", str(audit.get("verdict")))
    bindings = [
        str(item)[len("campaign-binding:"):]
        for item in audit.get("evidenceReviewed", [])
        if str(item).startswith("campaign-binding:")
    ]
    if not bindings and args.campaign == "legacy":
        bindings = ["legacy"]
    if bindings != [args.campaign]:
        raise Refusal("A", "audit-campaign-mismatch", ",".join(bindings) or "missing")
    if schema == host_bind.AUDIT_V1:
        try:
            host_bind.bind(report_path, audit_path)
        except ValueError as exc:
            raise Refusal("A", "verification-echo-mismatch", str(exc)) from exc
        if not isinstance(audit.get("reviewPolicy"), dict):
            raise Refusal("A", "review-stamp-missing", "audit-verdict.v1 carries no reviewPolicy stamp")
    # Before 0.23.4 normalize() could overwrite a model-reported product
    # failure with the host's `passed`. A verdict whose preserved original
    # reported failed-product never participates in acceptance.
    original = audit_path.with_name(audit_path.name + ".pre-normalize.json")
    if original.is_file():
        try:
            raw = json.loads(original.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise Refusal("A", "pre-normalize-record-invalid", str(exc)) from exc
        results = raw.get("verificationResults") if isinstance(raw, dict) else None
        if isinstance(results, list) and any(
            isinstance(item, dict) and item.get("status") == "failed-product" for item in results
        ):
            raise Refusal("A", "model-reported-product-failure", str(original.name))
    return audit


def blocking_severities(args: argparse.Namespace) -> set[str]:
    config = args.config or os.environ.get("SINGULAR_JSON_CONFIG_FILE") or str(
        Path(args.repo_root) / "singular.config.json"
    )
    try:
        policy = review_policy.load_policy(os.environ, config)
    except review_policy.PolicyError as exc:
        raise Refusal("A", "review-policy-invalid", str(exc)) from exc
    return BLOCKING_FLOOR | set(policy.get("blockingSeverities") or [])


def check_classification(
    args: argparse.Namespace, audit: dict[str, Any], row: dict[str, Any],
    rounds: list[dict[str, Any]],
) -> None:
    blocking = blocking_severities(args)
    raw = audit.get("classifiedFindings", [])
    if not isinstance(raw, list):
        raise Refusal("A", "classification-malformed", "classifiedFindings is not an array")
    seen: dict[str, dict[str, Any]] = {}
    covered: set[str] = set()
    for index, item in enumerate(raw):
        ident = text(item.get("id")) if isinstance(item, dict) else ""
        severity = item.get("severity") if isinstance(item, dict) else None
        summary = text(item.get("summary")) if isinstance(item, dict) else ""
        if not ident or not summary or severity not in review_policy.SEVERITIES:
            raise Refusal("A", "classification-malformed", f"classifiedFindings[{index}]")
        if ident in seen and seen[ident] != item:
            raise Refusal("A", "classification-conflicting-ids", ident)
        seen[ident] = item
        if severity in blocking:
            raise Refusal("A", "blocking-finding-open", f"{ident} ({severity})")
        covered.update((ident, summary))
    # Every fix the auditor still requires must be explicitly classified as
    # nonblocking. When the review policy turned a needs-fix verdict into an
    # acceptance (the P2/P3 backlog route), every finding must be covered too:
    # an unmatched finding is unresolved and prevents acceptance (protocol 5.1).
    original = row.get("originalVerdict")
    stamp = audit.get("reviewPolicy")
    if isinstance(stamp, dict) and stamp.get("originalVerdict"):
        original = stamp.get("originalVerdict")
    required = [text(entry) for entry in audit.get("requiredFixes", [])]
    if original != "accepted":
        required += [text(entry) for entry in audit.get("findings", [])]
    uncovered = sorted({entry for entry in required if entry and entry not in covered})
    if uncovered:
        raise Refusal("A", "classification-incomplete", f"{len(uncovered)} unclassified finding(s)")
    # A prior round's blocking finding the auditor itself reports as still
    # open cannot be accepted around.
    status = audit.get("findingsStatus")
    if isinstance(status, dict):
        current = row.get("round")
        prior = {
            str(ident)
            for item in rounds
            if isinstance(item.get("round"), int) and isinstance(current, int)
            and item["round"] < current
            for ident in (item.get("blocking") or [])
        }
        still_open = sorted(
            ident for ident, value in status.items()
            if value == "still-open" and ident in prior
        )
        if still_open:
            raise Refusal("A", "prior-blocking-finding-still-open", ",".join(still_open))
    if isinstance(stamp, dict) and (
        stamp.get("round") != row.get("round")
        or stamp.get("effectiveVerdict") != "accepted"
        or stamp.get("logicalChange") != args.logical_change
    ):
        raise Refusal("D", "review-stamp-mismatch", "audit reviewPolicy stamp is not the ledger round")


# ---- E: evidence bound to the exact candidate and published verdict ---------
def check_evidence(args: argparse.Namespace, run_dir: Path, audit_path: Path, report_path: Path) -> None:
    manifest = read_regular(
        run_dir / "evidence-manifest.json", "E",
        "evidence-manifest-missing", "evidence-manifest-invalid",
    )
    if manifest.get("schema") != "singular.orchestration.evidence-manifest.v0":
        raise Refusal("E", "evidence-manifest-invalid", str(manifest.get("schema")))
    for field, expected in (("taskId", args.task), ("runId", args.run), ("headSha", args.head)):
        if manifest.get(field) != expected:
            raise Refusal("E", "evidence-manifest-identity-mismatch", f"{field}={manifest.get(field)!r}")
    if manifest.get("campaignBinding", "legacy") != args.campaign:
        raise Refusal("E", "evidence-manifest-campaign-mismatch", str(manifest.get("campaignBinding")))
    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, list):
        raise Refusal("E", "evidence-manifest-invalid", "artifacts is not an array")
    hashes = {
        item.get("ref"): item.get("sha256") for item in artifacts if isinstance(item, dict)
    }
    for path in (audit_path, report_path):
        try:
            ref = path.resolve().relative_to(run_dir.resolve()).as_posix()
        except ValueError:
            raise Refusal("E", "evidence-manifest-incomplete", f"{path} is outside the run")
        if ref not in hashes:
            raise Refusal("E", "evidence-manifest-incomplete", f"{ref} is not bound")
        if hashes[ref] != sha_file(path):
            raise Refusal("E", "evidence-manifest-stale", f"{ref} changed after the manifest")


def validate(args: argparse.Namespace) -> dict[str, Any]:
    run_dir = Path(args.run_dir)
    audit_path = Path(args.audit) if args.audit else run_dir / "audit.json"
    report_path, attempt = check_gate(args, run_dir)
    audit = check_audit_identity(args, audit_path, report_path)
    rounds = ledger_rounds(args)
    row = check_ledger(args, rounds, attempt)
    check_classification(args, audit, row, rounds)
    check_evidence(args, run_dir, audit_path, report_path)
    return {"attempt": attempt, "round": row.get("round")}


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    for flag in ("task", "run", "branch", "head", "campaign", "run-dir",
                 "repo-root", "state-dir", "logical-change"):
        parser.add_argument("--" + flag, required=True)
    parser.add_argument("--audit", default="")
    parser.add_argument("--task-contract", default="")
    parser.add_argument("--config", default="")
    parser.add_argument("--attempt", type=int)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    result: dict[str, Any] = {
        "schema": RESULT_SCHEMA, "taskId": args.task, "runId": args.run, "headSha": args.head,
    }
    try:
        result.update(validate(args))
    except Refusal as refusal:
        result.update({
            "accepted": False, "conjunct": refusal.conjunct,
            "reason": refusal.reason, "detail": refusal.detail,
        })
        print(json.dumps(result, sort_keys=True))
        return 1
    result["accepted"] = True
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
