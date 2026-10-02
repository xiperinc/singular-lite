#!/usr/bin/env python3
"""Bind an audit-verdict.v1 verification aggregate to the host classification."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


AUDIT_V1 = "singular.orchestration.audit-verdict.v1"
AUDIT_V0 = {
    "singular.orchestration.audit-verdict.v0",
    "pmgo.orchestration.audit-verdict.v0",
}
CLASSIFICATIONS = {
    "passed",
    "failed-product",
    "inconclusive-infrastructure",
    "not-rerun-evidence-verified",
}
HOST_ALIASES = {
    "passed-with-acknowledged-baseline": "passed",
}


def read_object(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"invalid {label}: {exc}") from exc
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be a JSON object")
    return value


def host_classification(report: dict[str, Any]) -> str:
    raw = str(report.get("outcome") or "")
    classification = HOST_ALIASES.get(raw, raw)
    if classification not in CLASSIFICATIONS:
        raise ValueError(f"unsupported host verification classification: {raw!r}")
    return classification


def validate_identity(
    verdict: dict[str, Any], *, task: str, run: str, branch: str, head: str,
    require_accepted: bool = False,
) -> str:
    """Validate the audit identity imported and consumed at acceptance edges."""
    schema = verdict.get("schema")
    if schema != AUDIT_V1 and schema not in AUDIT_V0:
        raise ValueError(f"unsupported audit verdict schema: {schema!r}")
    if require_accepted and verdict.get("verdict") != "accepted":
        raise ValueError("audit verdict is not accepted")
    if not re.fullmatch(r"[0-9a-f]{40,64}", head):
        raise ValueError("expected reviewed head is not a full lowercase identity")
    for field, expected in (("taskId", task), ("runId", run), ("branch", branch)):
        if verdict.get(field) != expected:
            raise ValueError(
                f"audit {field} does not match packet: expected {expected!r}, "
                f"got {verdict.get(field)!r}"
            )
    evidence_reviewed = verdict.get("evidenceReviewed")
    if not isinstance(evidence_reviewed, list):
        raise ValueError("audit evidenceReviewed must be an array")
    reviewed_heads = [
        str(item)[len("reviewed-head-sha:"):]
        for item in evidence_reviewed
        if str(item).startswith("reviewed-head-sha:")
    ]
    if reviewed_heads != [head]:
        raise ValueError(
            "audit must contain exactly one reviewed-head-sha marker matching "
            f"the packet head ({head})"
        )
    return str(schema)


def model_aggregate(verdict: dict[str, Any]) -> tuple[str, list[str]]:
    if verdict.get("schema") != AUDIT_V1:
        raise ValueError("audit verdict is not audit-verdict.v1")
    results = verdict.get("verificationResults")
    if not isinstance(results, list) or not results:
        raise ValueError("audit-verdict.v1 verificationResults must be non-empty")
    statuses: list[str] = []
    for index, result in enumerate(results):
        if not isinstance(result, dict):
            raise ValueError(f"verificationResults[{index}] must be an object")
        status = result.get("status")
        if status not in CLASSIFICATIONS:
            raise ValueError(
                f"verificationResults[{index}] has unsupported status: {status!r}"
            )
        statuses.append(status)

    unique = set(statuses)
    if "failed-product" in unique:
        aggregate = "failed-product"
    elif "inconclusive-infrastructure" in unique:
        aggregate = "inconclusive-infrastructure"
    elif unique == {"passed"}:
        aggregate = "passed"
    elif unique == {"not-rerun-evidence-verified"}:
        aggregate = "not-rerun-evidence-verified"
    else:
        raise ValueError(
            "audit-verdict.v1 mixes passed and not-rerun-evidence-verified "
            "verification classifications"
        )
    return aggregate, statuses


def bind(host_report: Path, verdict_path: Path | None) -> str:
    host = host_classification(read_object(host_report, "host verification report"))
    if verdict_path is None:
        return host

    verdict = read_object(verdict_path, "audit verdict")
    aggregate, statuses = model_aggregate(verdict)
    if host == "not-rerun-evidence-verified" and "passed" in statuses:
        raise ValueError(
            "evidence-only host verification cannot be represented as passed"
        )
    if aggregate != host:
        raise ValueError(
            "audit-verdict.v1 verification aggregate does not match host "
            f"classification: model={aggregate} host={host}"
        )
    return aggregate


def echo_statuses(verdict: dict[str, Any]) -> list[str]:
    """Return the model's verification statuses when they form a clean echo.

    An echo is clean when every result is an object carrying one of the four
    host classifications. Anything else (missing, empty, non-object entries,
    unknown status words) is not an echo of the host observation at all, so
    the host may not paper over it by rewriting.
    """
    results = verdict.get("verificationResults")
    if not isinstance(results, list) or not results:
        raise ValueError("verificationResults is missing or empty; not an echo")
    statuses: list[str] = []
    for index, result in enumerate(results):
        status = result.get("status") if isinstance(result, dict) else None
        if status not in CLASSIFICATIONS:
            raise ValueError(
                f"verificationResults[{index}] is not a host classification echo: "
                f"{status!r}"
            )
        statuses.append(status)
    return statuses


def normalize(
    host_report: Path, verdict_path: Path, command: str, evidence_ref: str
) -> str:
    """Rewrite an echo mismatch in verificationResults to the host classification.

    The host owns the classification; the model was only asked to echo it. Only
    an unequivocal echo mismatch is rewritten: every result is a well-formed
    host classification and none of them reports `failed-product` while the
    host does not. A model-reported `failed-product` is independent product-
    failure evidence, not an echo, and is never overwritten with `passed`
    (0.23.4, protocol 4.3). Those verdicts, and malformed ones, are refused so
    the driver's bounded auditor repair retry handles them and nothing is
    accepted on a rewritten result. The model's verdict and findings are never
    touched; the original verdict is preserved beside the file. A verdict that
    already matches is left byte-identical.
    """
    host = host_classification(read_object(host_report, "host verification report"))
    verdict = read_object(verdict_path, "audit verdict")
    if verdict.get("schema") != AUDIT_V1:
        raise ValueError("audit verdict is not audit-verdict.v1")
    statuses = echo_statuses(verdict)
    if "failed-product" in statuses and host != "failed-product":
        raise ValueError(
            "model reported failed-product while the host classified "
            f"{host}; refusing to overwrite product-failure evidence"
        )
    reason = ""
    try:
        aggregate, statuses = model_aggregate(verdict)
        if host == "not-rerun-evidence-verified" and "passed" in statuses:
            reason = f"model reported passed for evidence-only host verification"
        elif aggregate != host:
            reason = f"model={aggregate} host={host}"
    except ValueError as exc:
        # Clean statuses that only mix passed and not-rerun-evidence-verified.
        reason = str(exc)
    if not reason:
        return host
    backup = verdict_path.with_name(verdict_path.name + ".pre-normalize.json")
    backup.write_text(json.dumps(verdict, indent=2) + "\n", encoding="utf-8")
    verdict["verificationResults"] = [
        {
            "status": host,
            "command": command or "(host verification)",
            "evidenceRefs": [evidence_ref or str(host_report)],
            "rationale": (
                "host-authoritative verification classification; the auditor's "
                f"own aggregate was replaced ({reason})"
            ),
        }
    ]
    temporary = verdict_path.with_name(verdict_path.name + ".normalize.tmp")
    temporary.write_text(json.dumps(verdict, indent=2) + "\n", encoding="utf-8")
    temporary.replace(verdict_path)
    print(f"audit-verdict-host-bind: normalized verificationResults ({reason})",
          file=sys.stderr)
    return host


# ---- Audit-format validation (findingsStatus + blocking support) -----------
# A pure check over the model's verdict and the host's record of the prior
# findings it supplied to that auditor (singular_render_reaudit_prompt writes
# it). A violation is an audit-format failure: the driver spends its one fresh
# auditor correction on it, never a product repair. Nothing here coerces or
# deletes model output; the verdict file is only read.

FINDINGS_STATUS_VALUES = ("resolved", "still-open")
BLOCKING_SEVERITIES = ("P0", "P1")
BLOCKING_SUPPORT = ("trigger", "impact", "requirement")


def finding_ledger_id(text: Any) -> str:
    """The findings-ledger identity (lib.sh singular_findings_ledger_update)."""
    import hashlib

    normalized = " ".join(str(text).replace("`", "").lower().split())
    return "f-" + hashlib.sha256(normalized.encode("utf-8")).hexdigest()[:12]


def read_prior_findings(path: Path) -> tuple[list[str], list[str]]:
    record = read_object(path, "host prior-finding record")
    supplied = record.get("suppliedIds")
    required = record.get("requiredIds")
    if not isinstance(supplied, list) or not isinstance(required, list):
        raise ValueError("host prior-finding record lacks suppliedIds/requiredIds arrays")
    if not all(isinstance(item, str) and item.strip() for item in supplied + required):
        raise ValueError("host prior-finding record contains a blank or non-string id")
    if not set(required) <= set(supplied):
        raise ValueError("host prior-finding record requires an id it did not supply")
    return list(supplied), list(required)


def validate_findings_status(
    verdict: dict[str, Any], supplied: list[str], required: list[str]
) -> None:
    present = "findingsStatus" in verdict
    status = verdict.get("findingsStatus")
    if not present:
        if required:
            raise ValueError(
                "findingsStatus is missing but the host supplied prior findings; "
                "report every required id: " + ", ".join(required)
            )
        return
    if not isinstance(status, dict):
        raise ValueError(
            "findingsStatus must be a JSON object mapping finding IDs to "
            f"\"resolved\" or \"still-open\", got {type(status).__name__}"
        )
    for key, value in status.items():
        if not isinstance(key, str) or not key.strip():
            raise ValueError("findingsStatus contains a blank finding id")
        if not isinstance(value, str) or value not in FINDINGS_STATUS_VALUES:
            raise ValueError(
                f"findingsStatus[{key!r}] must be exactly \"resolved\" or "
                f"\"still-open\", got {value!r}"
            )
    if not supplied:
        if status:
            raise ValueError(
                "findingsStatus must be omitted: the host supplied no prior findings, "
                "so these ids are invented: " + ", ".join(sorted(status))
            )
        return
    unknown = sorted(set(status) - set(supplied))
    if unknown:
        raise ValueError(
            "findingsStatus reports ids the host did not supply: " + ", ".join(unknown)
        )
    missing = [ident for ident in required if ident not in status]
    if missing:
        raise ValueError(
            "findingsStatus omits required prior finding ids: " + ", ".join(missing)
        )
    # "resolved" is an auditor assessment, not a host fact; it cannot erase a
    # blocking finding on its own. The converse is checkable here: an accepted
    # verdict may keep a prior finding still-open only by carrying it in its own
    # findings/requiredFixes, where the review policy must classify it (P2/P3
    # backlog, or blocking). Otherwise acceptance would silently close it.
    if verdict.get("verdict") == "accepted":
        carried = {
            finding_ledger_id(item)
            for key in ("findings", "requiredFixes")
            for item in (verdict.get(key) if isinstance(verdict.get(key), list) else [])
            if isinstance(item, str)
        }
        dropped = sorted(
            ident for ident, value in status.items()
            if value == "still-open" and ident not in carried
        )
        if dropped:
            raise ValueError(
                "an accepted verdict reports prior findings still-open without "
                "carrying them in findings/requiredFixes: " + ", ".join(dropped)
            )


def validate_blocking_support(verdict: dict[str, Any]) -> None:
    """Mirror of the schema's conditional P0/P1 requirement.

    singular_json_schema_check does not implement allOf/if/then, so the stdlib
    host check is what actually enforces it for new responses.
    """
    items = verdict.get("classifiedFindings")
    if items is None:
        return
    if not isinstance(items, list):
        raise ValueError("classifiedFindings must be an array")
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            raise ValueError(f"classifiedFindings[{index}] must be an object")
        if item.get("severity") not in BLOCKING_SEVERITIES:
            continue
        for field in BLOCKING_SUPPORT:
            value = item.get(field)
            if not isinstance(value, str) or not re.search(r"\S", value):
                raise ValueError(
                    f"classifiedFindings[{index}] ({item.get('severity')}) requires "
                    f"nonblank {field}; missing support never downgrades a finding"
                )


def validate_audit_format(verdict_path: Path, prior_findings: Path) -> str:
    verdict = read_object(verdict_path, "audit verdict")
    supplied, required = read_prior_findings(prior_findings)
    validate_findings_status(verdict, supplied, required)
    validate_blocking_support(verdict)
    return "ok"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host-report", type=Path)
    parser.add_argument("--verdict", type=Path)
    parser.add_argument("--normalize", action="store_true",
                        help="rewrite a mismatched verdict to the host classification")
    parser.add_argument("--command", default="")
    parser.add_argument("--evidence-ref", default="")
    identity_mode = parser.add_mutually_exclusive_group()
    identity_mode.add_argument("--validate-identity", action="store_true")
    identity_mode.add_argument("--validate-acceptance", action="store_true")
    parser.add_argument("--expected-task", default="")
    parser.add_argument("--expected-run", default="")
    parser.add_argument("--expected-branch", default="")
    parser.add_argument("--expected-head", default="")
    parser.add_argument("--validate-audit-format", action="store_true",
                        help="check findingsStatus and P0/P1 support against "
                             "the host's --prior-findings record")
    parser.add_argument("--prior-findings", type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    try:
        if args.validate_audit_format:
            if args.verdict is None or args.prior_findings is None:
                raise ValueError(
                    "--validate-audit-format requires --verdict and --prior-findings"
                )
            print(validate_audit_format(args.verdict, args.prior_findings))
        elif args.validate_identity or args.validate_acceptance:
            if args.verdict is None or not all((
                args.expected_task, args.expected_run,
                args.expected_branch, args.expected_head,
            )):
                raise ValueError(
                    "identity validation requires --verdict and all expected identities"
                )
            verdict = read_object(args.verdict, "audit verdict")
            print(validate_identity(
                verdict,
                task=args.expected_task,
                run=args.expected_run,
                branch=args.expected_branch,
                head=args.expected_head,
                require_accepted=args.validate_acceptance,
            ))
        elif args.normalize:
            if args.verdict is None:
                raise ValueError("--normalize requires --verdict")
            if args.host_report is None:
                raise ValueError("--normalize requires --host-report")
            print(normalize(args.host_report, args.verdict, args.command, args.evidence_ref))
        else:
            if args.host_report is None:
                raise ValueError("--host-report is required")
            print(bind(args.host_report, args.verdict))
    except ValueError as exc:
        raise SystemExit(f"audit-verdict-host-bind: {exc}") from exc


if __name__ == "__main__":
    main()
