#!/usr/bin/env python3
"""The one acceptance predicate every accepted-packet publication rechecks.

Protocol 1.1 (consultation #2, loop economics):

    PublishAccepted(K)  <=>  G(K) and A(K) and D(K) and E(K) and V(K)

for the exact candidate K (task, run, branch, head, tree, campaign):

  G  the trusted host verification report passed for this exact head and tree,
     and its request/result binding validates (gate-report.py, --require-pass);
  A  the audit verdict is host-bound to K, its effective verdict is accepted,
     and no blocking finding is unresolved or unclassified;
  D  the review-policy ledger durably holds the completed round for this
     run/attempt/head with effectiveVerdict accepted;
  E  the evidence manifest is bound to K and to the exact verdict and host
     report being published.

  V  when enforce/every-path is selected and proof is declared, its record
     matches the current candidate, attempt, declaration, files and logs.

Budget availability is deliberately absent: budgets authorize work, never
acceptance. Waivers and --no-audit cannot satisfy A.

The CLI takes candidate identity, record directories, schemas, and policy
inputs explicitly. It does not consult ambient SINGULAR_* variables or discover
configuration from the current directory. Record names within --run-dir and
--state-dir follow the classic engine's layout. --audit can select a sidecar.
Schema validation preserves the classic checker's supported keyword subset.
Review classification is also exposed here for review_policy's record writer.

`describe-refusal [--subject] <conjunct>:<reason>` names a refusal's subject in
plain words for the records people read (G host gate verification, A audit,
D review round, E evidence manifest, V red proof).

Exit 0: all applicable conjuncts hold. Exit 1: refused (stdout names the failing
conjunct and reason). Exit 2: usage error.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
import re
from datetime import datetime
import subprocess
import sys
import traceback
from pathlib import Path
from typing import Any

ENGINE_DIR = Path(__file__).resolve().parent
# The engine tree may be read-only or byte-pinned (frozen campaigns); never
# write bytecode next to it when importing sibling modules.
sys.dont_write_bytecode = True
sys.path.insert(0, str(ENGINE_DIR))



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
# Plain-word subjects of the conjuncts above, for refusal records that people
# read. "validator" is the callers' own code for a validator that did not run.
CONJUNCT_SUBJECTS = {
    "G": "host gate verification",
    "A": "audit",
    "D": "review round",
    "E": "evidence manifest",
    "V": "red proof",
    "validator": "acceptance validator",
}
PASSING_HOST = {"passed", "not-rerun-evidence-verified"}
# Protocol 5.1(5): configuration may make the blocking set stricter, never
# remove this floor.
DEFAULT_BLOCKING = ["P0", "P1"]
SEVERITIES = ("P0", "P1", "P2", "P3")
UNCLASSIFIABLE_SCHEMAS = (
    "singular.orchestration.audit-verdict.v0",
    "pmgo.orchestration.audit-verdict.v0",
)
CLASSIFIED_TEXT_FIELDS = ("trigger", "impact", "requirement", "location")
SUPPORT_FIELDS = ("trigger", "impact", "requirement")


def _nonblank(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _classification_text(value: Any) -> str:
    return "" if value is None else str(value)


def _classified_entry(entry: Any) -> dict[str, Any] | None:
    """Normalize one classifiedFindings entry, or None when it is malformed."""
    if not isinstance(entry, dict):
        return None
    ident = entry.get("id")
    severity = entry.get("severity")
    summary = entry.get("summary")
    if not _nonblank(ident) or not isinstance(severity, str) or severity not in SEVERITIES:
        return None
    if not _nonblank(summary):
        return None
    item = {"id": ident.strip(), "severity": severity, "summary": summary}
    for key in CLASSIFIED_TEXT_FIELDS:
        if key not in entry or entry[key] is None:
            continue
        if not isinstance(entry[key], str):
            return None
        item[key] = entry[key]
    return item


def _parse_classified(verdict: dict[str, Any]) -> tuple[bool, list[dict[str, Any]], list[dict[str, Any]]]:
    """Return (present, valid items, unresolved items) for classifiedFindings.

    ``present`` is false when the member is absent, null, or an empty list.
    Malformed entries and ids repeated with differing content are unresolved.
    """
    raw = verdict.get("classifiedFindings")
    if raw is None or raw == []:
        return False, [], []
    if not isinstance(raw, list):
        return True, [], [{
            "id": "malformed-classification",
            "severity": "unresolved",
            "summary": "classifiedFindings is not a list",
            "reason": "malformed-classification",
        }]
    unresolved: list[dict[str, Any]] = []
    by_id: dict[str, list[dict[str, Any]]] = {}
    order: list[str] = []
    for index, entry in enumerate(raw, start=1):
        item = _classified_entry(entry)
        if item is None:
            unresolved.append({
                "id": f"malformed-{index}",
                "severity": "unresolved",
                "summary": json.dumps(entry, ensure_ascii=False, sort_keys=True)[:500],
                "reason": "malformed-classification",
            })
            continue
        if item["id"] not in by_id:
            by_id[item["id"]] = []
            order.append(item["id"])
        by_id[item["id"]].append(item)
    items: list[dict[str, Any]] = []
    for ident in order:
        group = by_id[ident]
        if any(other != group[0] for other in group[1:]):
            unresolved.append({
                "id": ident,
                "severity": "unresolved",
                "summary": f"classified id {ident!r} is repeated with conflicting content",
                "reason": "conflicting-duplicate-id",
            })
            continue
        items.append(group[0])
    return True, items, unresolved


def _finding_strings(verdict: dict[str, Any]) -> list[str]:
    out: list[str] = []
    seen: set[str] = set()
    for key in ("findings", "requiredFixes"):
        raw = verdict.get(key)
        if not isinstance(raw, list):
            continue
        for item in raw:
            text = _classification_text(item).strip()
            if not text or text in seen:
                continue
            seen.add(text)
            out.append(text)
    return out


# A reference tag between the id and the separator, as in `F1 (P3) [A3]: ...`.
# The assumption-audit section lists assumptions as `[A1] ...` and asks the
# auditor to cite them, so auditors write the citation there. It names no
# classified item and carries no severity, so it does not change which item
# the string binds to.
_REFERENCE_TAGS = r"(?:\s*\[[^\]\n]{1,40}\])*"


def covering_item(
    text: str, items: list[dict[str, Any]]
) -> tuple[dict[str, Any] | None, str | None]:
    """(item, conflicting-id) for one finding string under the exact rule.

    ``item`` is the classified item that covers the string, or None. When the
    string names an item but its `(Pn)` tag disagrees with that item's
    severity, ``item`` is that item and ``conflicting-id`` is its id.
    """
    for item in items:
        if item["summary"] is not None and text == item["summary"].strip():
            return item, None
    # Longest id first so `F1-a: ...` binds to F1-a, never to F1.
    for item in sorted(items, key=lambda entry: len(entry["id"]), reverse=True):
        pattern = (
            re.escape(item["id"])
            + _REFERENCE_TAGS
            + r"(?:\s*\((P[0-3])\))?"
            + _REFERENCE_TAGS
            + r"(?:\s*:|\s+[-–—](?=\s|$)|\s*$)"
        )
        match = re.match(pattern, text)
        if not match:
            continue
        if match.group(1) and item["severity"] and match.group(1) != item["severity"]:
            return item, item["id"]
        return item, None
    return None, None


def _coverage(text: str, items: list[dict[str, Any]]) -> tuple[bool, str | None]:
    """(covered, conflicting-id) for one finding string under the exact rule."""
    item, conflict = covering_item(text, items)
    return item is not None, conflict


def _reason(reasons: list[str], reason: str) -> None:
    if reason not in reasons:
        reasons.append(reason)


def classify(verdict: dict[str, Any], policy: dict[str, Any]) -> dict[str, Any]:
    """Apply the fail-closed classification rules. Never mutates the input verdict."""
    original = _classification_text(verdict.get("verdict"))
    # P0/P1 are a floor even for a caller-built policy dict.
    blocking_severities = set(policy.get("blockingSeverities") or DEFAULT_BLOCKING)
    blocking_severities.update(DEFAULT_BLOCKING)
    require_classification = bool(policy.get("requireClassification", True))

    result: dict[str, Any] = {
        "originalVerdict": original,
        "effectiveVerdict": original,
        "applied": False,
        "blocking": [],
        "backlog": [],
        "downgraded": [],
        "unsupported": [],
        "unresolved": [],
        "unclassifiedCount": 0,
        "reason": None,
        "reasons": [],
        "items": [],
    }

    present, items, unresolved = _parse_classified(verdict)
    strings = _finding_strings(verdict)
    reasons: list[str] = result["reasons"]

    if not present:
        legacy = _classification_text(verdict.get("schema")) in UNCLASSIFIABLE_SCHEMAS
        must_classify = require_classification and (
            original == "needs-fix" or (original == "accepted" and strings and not legacy)
        )
        if not must_classify:
            # The auditor's own label stands; a needs-fix is never upgraded.
            return result
        unclassified = [
            {"id": f"unclassified-{index}", "severity": "unclassified", "summary": text}
            for index, text in enumerate(strings, start=1)
        ]
        if not unclassified:
            unclassified.append(
                {"id": "unclassified-1", "severity": "unclassified", "summary": "unclassified finding"}
            )
        result["items"] = unclassified
        result["blocking"] = [item["id"] for item in unclassified]
        result["unclassifiedCount"] = len(unclassified)
        _reason(reasons, "classification-missing")
        result["reason"] = reasons[0]
        result["effectiveVerdict"] = "needs-fix" if original in ("accepted", "needs-fix") else original
        result["applied"] = result["effectiveVerdict"] != original
        return result

    blocking: list[str] = []
    backlog: list[str] = []
    processed: list[dict[str, Any]] = []
    if unresolved:
        _reason(
            reasons,
            "classification-malformed"
            if any(entry["reason"] == "malformed-classification" for entry in unresolved)
            else "classification-conflict",
        )
    for item in items:
        copy = dict(item)
        if copy["severity"] in DEFAULT_BLOCKING:
            missing = [key for key in SUPPORT_FIELDS if not _nonblank(copy.get(key, ""))]
            if missing:
                # Severity is immutable: missing support never demotes a blocker.
                copy["supportMissing"] = missing
                copy["supportReason"] = "unsupported-blocking-claim"
                result["unsupported"].append(copy["id"])
                _reason(reasons, "unsupported-blocking-claim")
        if copy["severity"] in blocking_severities:
            blocking.append(copy["id"])
        else:
            backlog.append(copy["id"])
        processed.append(copy)
    for entry in unresolved:
        blocking.append(entry["id"])
        processed.append(dict(entry))
        result["unresolved"].append(entry["id"])

    # A finding that names a conflicting id is represented (and already
    # blocking through that id); it is not additionally uncovered.
    coverage_items = items + [
        {"id": entry["id"], "severity": None, "summary": None}
        for entry in unresolved if entry["reason"] == "conflicting-duplicate-id"
    ]
    uncovered = 0
    for text in strings:
        covered, conflict = _coverage(text, coverage_items)
        if conflict:
            ident = f"severity-tag-conflict-{conflict}"
            if ident not in result["unresolved"]:
                processed.append({
                    "id": ident,
                    "severity": "unresolved",
                    "summary": text,
                    "reason": "severity-tag-conflict",
                })
                blocking.append(ident)
                result["unresolved"].append(ident)
            _reason(reasons, "classification-conflict")
            continue
        if covered:
            continue
        uncovered += 1
        ident = f"unclassified-{uncovered}"
        processed.append({"id": ident, "severity": "unclassified", "summary": text})
        _reason(reasons, "classification-incomplete")
        # requireClassification=false lets an accepted label keep uncovered
        # informational text; it never lets a needs-fix through incomplete.
        if require_classification or original != "accepted":
            blocking.append(ident)

    result["items"] = processed
    result["blocking"] = blocking
    result["backlog"] = backlog
    result["unclassifiedCount"] = uncovered
    if blocking:
        if original == "accepted" and any(
            item["id"] in blocking for item in items
        ):
            _reason(reasons, "blocking-finding")
        result["effectiveVerdict"] = "needs-fix" if original in ("accepted", "needs-fix") else original
    elif original == "needs-fix":
        # Completely classified, nothing blocking or unresolved: accepted with backlog.
        result["effectiveVerdict"] = "accepted"
    else:
        result["effectiveVerdict"] = original
    result["applied"] = result["effectiveVerdict"] != original
    result["reason"] = reasons[0] if reasons else None
    return result


def audit_attempt_result(require_audit: str, verdict: str, verification: str) -> tuple[str, str]:
    """Classify the completed audit before the driver chooses its next action."""
    if verification == "failed-product":
        return "product-failure", "audit-needs-fix"
    if verification == "inconclusive-infrastructure":
        return "infrastructure", "audit-infra"
    if require_audit == "1" and verdict != "accepted":
        return "verdict", "audit-" + verdict
    return "continue", ""


def classify_review(
    verdict: dict[str, Any], policy: dict[str, Any], host_verification: str = "",
) -> dict[str, Any]:
    classification = classify(verdict, policy)
    if host_verification == "failed-product" and classification["effectiveVerdict"] == "accepted":
        # The host gate failed the product on this head: the review cannot close it.
        classification["effectiveVerdict"] = "needs-fix"
        classification["applied"] = classification["originalVerdict"] != "needs-fix"
        classification["blocking"].append("host-verification-failed-product")
        classification["reasons"].append("host-verification-failed-product")
        classification["reason"] = classification["reasons"][0]
    return classification


BLOCKING_FLOOR = set(DEFAULT_BLOCKING)


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
        "--require-pass", "--trusted-shell", args.trusted_shell,
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
    import review_policy

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
    import review_policy

    try:
        policy = review_policy.load_policy(args.policy_env, args.config or None)
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
        if not ident or not summary or severity not in SEVERITIES:
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
    if args.acceptance_mode == "every-path":
        check_manifest_whole(run_dir, artifacts)


# The driver rewrites the run's packet.json (status -> accepted, nextAction)
# after the final manifest refresh and after this predicate has run, by design:
# the accepted projection is written only once acceptance holds. Its listed
# hash is the worker's pre-acceptance packet, so it is excluded by name. The
# packet that is published is bound separately (identity, head, campaign).
WHOLE_MANIFEST_EXCLUDED = frozenset({"packet.json"})


def check_manifest_whole(run_dir: Path, artifacts: list[Any]) -> None:
    """every-path: every listed artifact must still be the bytes the manifest bound."""
    root = run_dir.resolve()
    for index, item in enumerate(artifacts):
        ref = item.get("ref") if isinstance(item, dict) else None
        if not isinstance(ref, str) or not ref:
            raise Refusal("E", "evidence-manifest-incomplete", f"artifacts[{index}] has no ref")
        if Path(ref).is_absolute():
            raise Refusal("E", "evidence-manifest-incomplete", f"{ref} is an absolute path")
        path = run_dir / ref
        try:
            path.resolve().relative_to(root)
        except ValueError:
            raise Refusal("E", "evidence-manifest-incomplete", f"{ref} is outside the run") from None
        if ref in WHOLE_MANIFEST_EXCLUDED:
            continue
        if not path.is_file():
            raise Refusal("E", "evidence-manifest-incomplete", f"{ref} is missing")
        if item.get("sha256") != sha_file(path):
            raise Refusal("E", "evidence-manifest-stale", f"{ref} changed after the manifest")


# ---- V: proof bound to the candidate at this acceptance boundary ------------
# Only the host's own record counts. The host writes it directly in the run
# folder as red-proof-<attempt>.json (red_proof.py); the red-proof-attempt-<n>
# spelling is accepted for records written by earlier acceptance fixtures. A
# file with the red-proof schema anywhere else, such as the worker's copied
# evidence under worker-evidence/, is not a record: it neither proves nor
# refuses.
PROOF_RECORD_NAME = re.compile(r"red-proof-(?:attempt-)?[0-9]+\.json")


def proof_records(run_dir: Path) -> list[tuple[Path, dict[str, Any]]]:
    """Records the host writes: red-proof-<n>.json directly in the run folder."""
    records = []
    if not run_dir.is_dir():
        return records
    for path in sorted(run_dir.iterdir()):
        if not PROOF_RECORD_NAME.fullmatch(path.name):
            continue
        if path.is_symlink() or not path.is_file():
            raise Refusal("V", "proof-record-unreadable")
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            raise Refusal("V", "proof-record-unreadable") from None
        if isinstance(value, dict) and value.get("schema") == "singular.orchestration.red-proof.v0":
            records.append((path, value))
    return records


def check_proof(args: argparse.Namespace, run_dir: Path, attempt: int) -> None:
    # Compatibility is explicit, including for callers whose shell config is
    # not exported. No ambient environment or journal is acceptance authority.
    if args.red_proof != "enforce" or args.acceptance_mode != "every-path":
        return
    from task_parser import parse_task, proof_preflight_reasons
    from red_proof import digest, git, proof_files

    try:
        task = parse_task(args.task_contract)
        if not (task.get("proofCommand") or task.get("proofTests")):
            return
        if task.get("taskId") != args.task or proof_preflight_reasons(task):
            raise Refusal("V", "proof-declaration-invalid")
        policy = task["testPolicy"]
        if policy not in ("strict_test_first", "characterization_first",
                          "test_after_waiver", "not_applicable"):
            raise Refusal("V", "proof-policy-invalid")
        lease_path = Path(args.lease) if args.lease else Path(args.state_dir) / "leases" / (args.task + ".json")
        lease = read_regular(lease_path, "V", "proof-lease-missing", "proof-lease-invalid")
        if lease.get("taskId") != args.task:
            raise Refusal("V", "proof-lease-mismatch")
        base = git(args.repo_root, "rev-parse", "--verify", "--end-of-options",
                   lease["baseSha"] + "^{commit}").decode().strip()
        head = git(args.repo_root, "rev-parse", "--verify", "--end-of-options",
                   args.head + "^{commit}").decode().strip()
        tree = git(args.repo_root, "rev-parse", head + "^{tree}").decode().strip()
        records = [(path, record) for path, record in proof_records(run_dir)
                   if type(record.get("attempt")) is int and record["attempt"] == attempt]
        if len(records) != 1:
            raise Refusal("V", "proof-record-missing" if not records else "proof-record-ambiguous")
        record_path, record = records[0]
        command = task["proofCommand"]
        expected = {"taskId": args.task, "runId": args.run, "baseSha": base,
                    "headSha": head, "treeSha": tree, "attempt": attempt,
                    "command": command, "commandSha256": digest(command.encode("utf-8")),
                    "proofFiles": proof_files(args.repo_root, head, task["proofTests"])}
        for field, value in expected.items():
            if record.get(field) != value:
                raise Refusal("V", "proof-binding-mismatch", field)
        if "testPolicy" in record and record["testPolicy"] != policy:
            raise Refusal("V", "proof-binding-mismatch", "testPolicy")
        if policy in ("test_after_waiver", "not_applicable"):
            if record.get("outcome") != "waived":
                raise Refusal("V", "proof-waiver-missing")
            return
        if record.get("outcome") != "proved":
            raise Refusal("V", "proof-not-proved")
        for side in ("base", "candidate"):
            observation = record.get(side)
            if not isinstance(observation, dict):
                raise Refusal("V", "proof-observation-missing", side)
            code = observation.get("rawExitCode")
            expected_outcome = "red" if side == "base" and policy == "strict_test_first" else "green"
            if (type(code) is not int or code in (126, 127)
                    or observation.get("timedOut") is not False
                    or observation.get("setupError")
                    or ("sourceIntegrity" in observation and (
                        not isinstance(observation["sourceIntegrity"], dict)
                        or observation["sourceIntegrity"].get("status") != "verified"
                        or observation["sourceIntegrity"].get("changedPaths")))
                    or observation.get("outcome") != expected_outcome
                    or (code != 0 if expected_outcome == "green" else code == 0)):
                raise Refusal("V", "proof-observation-invalid", side)
            ref = observation.get("logRef")
            if not isinstance(ref, str) or not ref:
                raise Refusal("V", "proof-log-missing", side)
            log = Path(ref)
            if not log.is_absolute():
                log = record_path.parent / log
            if (log.is_symlink() or not log.is_file()
                    or not log.resolve().is_relative_to(run_dir.resolve())):
                raise Refusal("V", "proof-log-missing", side)
            if sha_file(log) != observation.get("logSha256"):
                raise Refusal("V", "proof-log-changed", side)
    except Refusal:
        raise
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        # Candidate-controlled content must fail closed with a V diagnostic,
        # including unreadable files and Git objects missing at acceptance.
        raise Refusal("V", "proof-input-invalid") from None


def schema_error(message: str) -> None:
    raise ValueError(message)


def check_schema(val, spec, where):
    kind = spec.get("type")
    if kind == "string" and not isinstance(val, str):
        schema_error(f"{where} must be a string")
    if kind == "boolean" and not isinstance(val, bool):
        schema_error(f"{where} must be a boolean")
    if kind == "array" and not isinstance(val, list):
        schema_error(f"{where} must be an array")
    if kind == "object" and not isinstance(val, dict):
        schema_error(f"{where} must be an object")
    if kind == "integer" and (not isinstance(val, int) or isinstance(val, bool)):
        schema_error(f"{where} must be an integer")
    if "const" in spec and val != spec["const"]:
        schema_error(f"{where} must equal {spec['const']!r}")
    if "enum" in spec and val not in spec["enum"]:
        schema_error(f"{where} must be one of {spec['enum']}")
    if kind == "string":
        min_len = spec.get("minLength")
        if min_len is not None and len(val) < min_len:
            schema_error(f"{where} must be at least {min_len} character(s)")
        if spec.get("format") == "date-time":
            try:
                datetime.fromisoformat(str(val).replace("Z", "+00:00"))
            except ValueError:
                schema_error(f"{where} must be an ISO-8601 date-time")
        pattern = spec.get("pattern")
        # JSON Schema `pattern` uses regular-expression search semantics, not
        # an implicit whole-string match.  Schemas that require a full match
        # carry their own ^...$ anchors.
        if pattern and not re.search(pattern, val):
            schema_error(f"{where} must match pattern {pattern}")
    if kind == "array":
        min_items = spec.get("minItems")
        if min_items is not None and len(val) < min_items:
            schema_error(f"{where} must have at least {min_items} item(s)")
        item_spec = spec.get("items", {})
        for idx, item in enumerate(val):
            check_schema(item, item_spec, f"{where}[{idx}]")
    if kind == "object":
        props = spec.get("properties", {})
        if spec.get("additionalProperties") is False:
            unknown = sorted(set(val) - set(props))
            if unknown:
                schema_error(f"{where} has unknown field(s): {', '.join(unknown)}")
        for key in spec.get("required", []):
            if key not in val:
                schema_error(f"{where} missing required field: {key}")
        for key, child in props.items():
            if key in val:
                check_schema(val[key], child, f"{where}.{key}" if where else key)



def check_structure(args: argparse.Namespace, audit_path: Path, manifest_path: Path) -> None:
    """The driver's original prechecks, in their original refusal order."""
    if args.require_audit != "1":
        raise Refusal("A", "audit-disabled")
    if not audit_path.is_file():
        raise Refusal("A", "audit-missing")
    try:
        audit = json.loads(audit_path.read_text(encoding="utf-8"))
        schema_id = audit.get("schema")
        if schema_id == "pmgo.orchestration.audit-verdict.v0":
            if args.legacy_schema_mode == "reject":
                raise ValueError("legacy audit schema rejected")
            args.legacy_audit = True
            audit["schema"] = "singular.orchestration.audit-verdict.v0"
            schema_id = audit["schema"]
        version = {
            "singular.orchestration.audit-verdict.v0": "v0",
            "singular.orchestration.audit-verdict.v1": "v1",
        }[schema_id]
        schema = json.loads((Path(args.schema_dir) / f"audit-verdict.{version}.schema.json").read_text())
        check_schema(audit, schema, "audit verdict")
        if args.task and audit.get("taskId") and audit["taskId"] != args.task:
            raise ValueError("audit taskId mismatch")
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        raise Refusal("A", "audit-schema-invalid") from None
    if not manifest_path.is_file():
        raise Refusal("E", "evidence-manifest-missing")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        schema = json.loads((Path(args.schema_dir) / "evidence-manifest.v0.schema.json").read_text())
        check_schema(manifest, schema, "evidence manifest")
    except (OSError, ValueError, TypeError, AttributeError):
        raise Refusal("E", "evidence-manifest-schema-invalid") from None


def validate(args: argparse.Namespace) -> dict[str, Any]:
    run_dir = Path(args.run_dir)
    audit_path = Path(args.audit) if args.audit else run_dir / "audit.json"
    check_structure(args, audit_path, run_dir / "evidence-manifest.json")
    args.record_check = True
    report_path, attempt = check_gate(args, run_dir)
    audit = check_audit_identity(args, audit_path, report_path)
    rounds = ledger_rounds(args)
    row = check_ledger(args, rounds, attempt)
    check_classification(args, audit, row, rounds)
    check_evidence(args, run_dir, audit_path, report_path)
    check_proof(args, run_dir, attempt)
    return {"attempt": attempt, "round": row.get("round")}


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    for flag in ("task", "run", "branch", "head", "campaign", "run-dir",
                 "repo-root", "state-dir", "logical-change"):
        parser.add_argument("--" + flag, required=True)
    parser.add_argument("--audit", default="")
    parser.add_argument("--task-contract", default="")
    parser.add_argument("--config", required=True)
    parser.add_argument("--attempt", type=int)
    parser.add_argument("--red-proof", choices=("off", "observe", "enforce"), default="off")
    parser.add_argument("--acceptance-mode", choices=("driver-only", "every-path"), default="driver-only")
    parser.add_argument("--lease", default="")
    parser.add_argument("--schema-dir", default=str(ENGINE_DIR.parent / "schemas"))
    parser.add_argument("--require-audit", required=True)
    parser.add_argument("--legacy-schema-mode", required=True)
    parser.add_argument("--trusted-shell", required=True)
    parser.add_argument("--policy-env-json", required=True,
                        help="Explicit review policy environment overrides; ambient variables are ignored")
    parser.add_argument("--driver-records", action="store_true",
                        help="Write the classic driver's acceptance-check files after structural checks")
    args = parser.parse_args(argv)
    try:
        args.policy_env = json.loads(args.policy_env_json)
        if not isinstance(args.policy_env, dict) or not all(
            isinstance(key, str) and isinstance(value, str) for key, value in args.policy_env.items()
        ):
            raise ValueError("expected a string-to-string object")
    except (ValueError, TypeError) as exc:
        parser.error(f"--policy-env-json: {exc}")
    args.record_check = False
    args.legacy_audit = False
    return args


def describe_refusal(code: str) -> str:
    """Name a "<conjunct>:<reason>" refusal's subject: "audit (A): blocking-finding-open".

    A code without a known conjunct is returned unchanged.
    """
    conjunct, sep, reason = code.partition(":")
    subject = CONJUNCT_SUBJECTS.get(conjunct)
    if not sep or subject is None:
        return code
    return f"{subject} ({conjunct}): {reason}"


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv[:1] == ["describe-refusal"]:
        # describe-refusal CODE prints "audit (A): blocking-finding-open";
        # describe-refusal --subject CODE prints only "audit" (empty if unknown).
        if len(argv) == 3 and argv[1] == "--subject":
            print(CONJUNCT_SUBJECTS.get(argv[2].partition(":")[0], "") if ":" in argv[2] else "")
            return 0
        if len(argv) != 2:
            sys.stderr.write("usage: acceptance_validator.py describe-refusal [--subject] <conjunct>:<reason>\n")
            return 2
        print(describe_refusal(argv[1]))
        return 0
    if argv[:1] == ["attempt-result"]:
        parser = argparse.ArgumentParser(description=audit_attempt_result.__doc__)
        for flag in ("require-audit", "verdict", "verification"):
            parser.add_argument("--" + flag, required=True)
        attempt = parser.parse_args(argv[1:])
        branch, failure = audit_attempt_result(attempt.require_audit, attempt.verdict, attempt.verification)
        print(branch + "\t" + failure)
        return 0
    diagnostics = io.StringIO()
    try:
        with contextlib.redirect_stderr(diagnostics):
            args = parse_args(argv)
    except SystemExit as exc:
        # Parsing precedes validation, but the classic shell still left its
        # redirected diagnostic pair on usage errors. Standalone stays read-only.
        if exc.code == 2 and "--driver-records" in argv:
            records = argparse.ArgumentParser(add_help=False, allow_abbrev=False)
            records.add_argument("--run-dir", required=True)
            record_args, _ = records.parse_known_args(argv)
            run_dir = Path(record_args.run_dir)
            (run_dir / "acceptance-check.json").write_text("\n", encoding="utf-8")
            (run_dir / "acceptance-check.err").write_text(diagnostics.getvalue(), encoding="utf-8")
        else:
            sys.stderr.write(diagnostics.getvalue())
        return int(exc.code)
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
    except Exception:
        if not args.driver_records or not args.record_check:
            raise
        (Path(args.run_dir) / "acceptance-check.err").write_text(traceback.format_exc(), encoding="utf-8")
        (Path(args.run_dir) / "acceptance-check.json").write_text("\n", encoding="utf-8")
        if args.legacy_audit:
            print(json.dumps({"legacyAudit": True}))
        return 1
    else:
        result["accepted"] = True
    # The old shell wrapper wrote these only after its structural prechecks.
    # Standalone callers are read-only; the driver explicitly requests records.
    if args.driver_records and args.record_check:
        (Path(args.run_dir) / "acceptance-check.err").write_text("", encoding="utf-8")
        (Path(args.run_dir) / "acceptance-check.json").write_text(
            json.dumps(result, sort_keys=True) + "\n", encoding="utf-8",
        )
    if args.legacy_audit:
        result["legacyAudit"] = True
    print(json.dumps(result, sort_keys=True))
    return 0 if result["accepted"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
