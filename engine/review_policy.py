#!/usr/bin/env python3
"""Programmable review policy: classify, bound, record, and grant exceptions.

Stdlib only. Importable as a module and runnable as
`python3 engine/review_policy.py <verb> ...`.

Classification is fail-closed (loop-economics protocol 5.1):

* Severity is immutable. A P0/P1 item missing ``trigger``/``impact``/
  ``requirement`` keeps its severity and stays blocking (reason
  ``unsupported-blocking-claim``); it is never demoted to backlog.
* Findings are inspected for every verdict label. An ``accepted`` label with a
  blocking, unresolved, or uncovered finding becomes ``needs-fix``. A label of
  ``blocked``/``needs-human``/anything else is never turned into ``accepted``.
* Coverage is exact, never fuzzy. Every non-blank ``findings[]`` and
  ``requiredFixes[]`` string must be represented by a classified item, either
  (a) the stripped string equals an item's stripped ``summary``, or (b) the
  stripped string starts with an item's ``id`` as a whole token, optionally
  followed by a ``(Pn)`` tag, and then ``:``, a spaced dash, or the end of the
  string (``F1: ...``, ``F1 (P2): ...``, ``AF-1 - ...``). A ``(Pn)`` tag that
  disagrees with the item's severity is a conflict. Anything else is uncovered.
* Malformed classified entries and duplicate ids with differing content are
  unresolved and block. Identical duplicates collapse to one item.
* P0 and P1 are a floor for ``blockingSeverities``; configuration may add P2/P3
  but never remove P0/P1 (``load_policy`` refuses).
* A completely classified ``needs-fix`` whose items are all non-blocking (and
  nothing is unresolved or uncovered) is accepted with backlog.
* ``requireClassification=false`` only lets a verdict that carries no
  classification keep its own label; it never upgrades ``needs-fix``.
* Legacy ``audit-verdict.v0`` documents cannot carry ``classifiedFindings``
  (their schema forbids it). When such a verdict has none, the host does not
  reinterpret it: the auditor's own label stands and is never upgraded.

Review accounting is authoritative (protocol 5.4):

* ``reserve`` atomically admits one review operation under the write lock and
  binds it to logicalChange/task/run/attempt/head. Reserved operations hold a
  slot, so two concurrent reservations cannot both take the last one. A new
  reservation by the same task supersedes that task's earlier pending one (one
  driver holds a task lease at a time); ``release`` frees an operation that
  ended without a verdict. Auditor transport retries stay inside one operation.
* ``record`` completes an operation idempotently: the same operation with the
  same verdict hash (raw or as applied) is a no-op returning the stored result;
  different content is a conflict (exit 5). ``record`` without ``--operation``
  reserves and completes in one locked step, and refuses (exit 4, nothing
  written) when the ceiling is reached or the change is closed. The ledger is
  committed before ``--apply`` rewrites the verdict file.
* Rounds belong to a numbered series (``entry.series``, default 1). An accepted
  round closes its series: a closed change is never given a fresh budget
  silently. Starting a new series needs ``reopen --authority --reason
  --evidence`` (mirrors ``grant``).
* Grants are bound to the series in which they were granted and the rounds
  used inside a series never decrease, so a consumed grant cannot be consumed
  again.

Migration of ledgers written before series/operations existed: rows without a
``series`` member are legacy rows and keep their old semantics. A legacy
accepted row is still a series boundary (the following rounds start a fresh
budget, as before), so an existing ledger does not become exhausted or closed.
Legacy non-accepted rows after the last legacy accepted row count toward
series 1. A legacy grant (no ``series`` member) applies to series 1 only when
it was granted after the last legacy accepted row; otherwise the segment it
extended has ended and the grant is spent. Historical ``backfill`` rows are
legacy rows. Malformed ledger structure is an error (exit 3), never a reset.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import sys
import tempfile
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterator

LEDGER_SCHEMA = "singular.review-policy.ledger.v1"
POLICY_VERSION = 1
# Two total rounds: the initial review plus at most one follow-up. The L1
# driver bounds product repairs to maxReviewRounds - 1, so high-risk tasks are
# also capped here unless a project raises maxReviewRounds explicitly.
DEFAULT_MAX_REVIEW_ROUNDS = 2
DEFAULT_BLOCKING = ["P0", "P1"]
SEVERITIES = ("P0", "P1", "P2", "P3")
VERDICTS = ("accepted", "needs-fix", "blocked", "needs-human")
LANES = ("native", "maintenance", "consultant")
ROUND_KINDS = ("initial", "followup")
# Schemas whose documents cannot carry classifiedFindings.
UNCLASSIFIABLE_SCHEMAS = (
    "singular.orchestration.audit-verdict.v0",
    "pmgo.orchestration.audit-verdict.v0",
)
CLASSIFIED_TEXT_FIELDS = ("trigger", "impact", "requirement", "location")
SUPPORT_FIELDS = ("trigger", "impact", "requirement")
OP_RESERVED = "reserved"
OP_COMPLETED = "completed"
OP_RELEASE_STATUSES = ("infrastructure-exhausted", "abandoned")

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_LEDGER = 3
EXIT_EXHAUSTED = 4
EXIT_CONFLICT = 5


class PolicyError(Exception):
    """Invalid configuration, usage, or arguments (exit 2)."""


class LedgerError(Exception):
    """Ledger or filesystem I/O failure (exit 3)."""


class ExhaustedError(Exception):
    """Admission refused: rounds exhausted or change closed (exit 4)."""

    def __init__(self, payload: dict[str, Any]):
        super().__init__(payload.get("reason") or "review admission refused")
        self.payload = payload


class ConflictError(Exception):
    """Operation replay with different content, or a binding mismatch (exit 5)."""


def _utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace(
        "+00:00", "Z"
    )


def _nonblank(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _as_str(value: Any) -> str:
    if value is None:
        return ""
    return str(value)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _dump(obj: Any) -> str:
    return json.dumps(obj, indent=2, ensure_ascii=False) + "\n"


def _print_json(obj: Any) -> None:
    sys.stdout.write(_dump(obj))


def logical_change_id(task_id: str | None, dag_node: str | None) -> str:
    """dagNode if non-empty, else taskId. Maintenance ids are supplied explicitly."""
    node = (dag_node or "").strip()
    if node:
        return node
    return (task_id or "").strip()


def _parse_bool_env(raw: str, name: str) -> bool:
    if raw == "1":
        return True
    if raw == "0":
        return False
    raise PolicyError(f"{name} must be 0 or 1, got {raw!r}")


def _parse_int_ge(raw: str, name: str, minimum: int) -> int:
    if not re.fullmatch(r"[+-]?[0-9]+", raw.strip()):
        raise PolicyError(f"{name} must be an integer >= {minimum}, got {raw!r}")
    value = int(raw)
    if value < minimum:
        raise PolicyError(f"{name} must be an integer >= {minimum}, got {raw!r}")
    return value


def _parse_blocking(raw: Any, name: str) -> list[str]:
    out = _parse_severities(raw, name)
    missing = [sev for sev in DEFAULT_BLOCKING if sev not in out]
    if missing:
        raise PolicyError(
            f"{name} must include {', '.join(DEFAULT_BLOCKING)} (missing {', '.join(missing)}); "
            "configuration may add P2/P3 but never remove the P0/P1 floor"
        )
    return out


def _parse_severities(raw: Any, name: str) -> list[str]:
    if isinstance(raw, str):
        parts = [part.strip() for part in raw.split(",")]
        parts = [part for part in parts if part]
        if not parts:
            raise PolicyError(f"{name} must be a comma list from {', '.join(SEVERITIES)}")
    elif isinstance(raw, list):
        parts = []
        for item in raw:
            if not isinstance(item, str):
                raise PolicyError(f"{name} items must be strings")
            token = item.strip()
            if token:
                parts.append(token)
    else:
        raise PolicyError(f"{name} must be a list of severities")
    seen: set[str] = set()
    out: list[str] = []
    for part in parts:
        if part not in SEVERITIES:
            raise PolicyError(
                f"{name} contains invalid severity {part!r}; "
                f"allowed: {', '.join(SEVERITIES)}"
            )
        if part not in seen:
            seen.add(part)
            out.append(part)
    return out


def _apply_json_policy(policy: dict[str, Any], sources: dict[str, str], blob: Any, source: str) -> None:
    if not isinstance(blob, dict):
        raise PolicyError("reviewPolicy must be a JSON object")
    if "version" in blob:
        version = blob["version"]
        if not isinstance(version, int) or isinstance(version, bool) or version != POLICY_VERSION:
            raise PolicyError(f"reviewPolicy.version must be {POLICY_VERSION}, got {version!r}")
        policy["version"] = version
        sources["version"] = source
    if "maxReviewRounds" in blob:
        value = blob["maxReviewRounds"]
        if not isinstance(value, int) or isinstance(value, bool) or value < 1:
            raise PolicyError(
                f"reviewPolicy.maxReviewRounds must be an integer >= 1, got {value!r}"
            )
        policy["maxReviewRounds"] = value
        sources["maxReviewRounds"] = source
    if "blockingSeverities" in blob:
        policy["blockingSeverities"] = _parse_blocking(
            blob["blockingSeverities"], "reviewPolicy.blockingSeverities"
        )
        sources["blockingSeverities"] = source
    if "requireClassification" in blob:
        flag = blob["requireClassification"]
        if not isinstance(flag, bool):
            raise PolicyError(
                "reviewPolicy.requireClassification must be a boolean, "
                f"got {flag!r}"
            )
        policy["requireClassification"] = flag
        sources["requireClassification"] = source


def load_policy(env: dict[str, str] | None = None, config_path: str | None = None) -> dict[str, Any]:
    """Resolve review policy. Env field overrides win over JSON; defaults last.

    Invalid values are a hard error, never silently defaulted.
    """
    env = dict(os.environ if env is None else env)
    policy: dict[str, Any] = {
        "version": POLICY_VERSION,
        "maxReviewRounds": DEFAULT_MAX_REVIEW_ROUNDS,
        "blockingSeverities": list(DEFAULT_BLOCKING),
        "requireClassification": True,
    }
    sources = {
        "version": "default",
        "maxReviewRounds": "default",
        "blockingSeverities": "default",
        "requireClassification": "default",
    }

    json_blob = None
    json_source = "config"
    raw_json = env.get("SINGULAR_REVIEW_POLICY_JSON")
    if raw_json is not None and raw_json != "":
        try:
            json_blob = json.loads(raw_json)
        except json.JSONDecodeError as exc:
            raise PolicyError(f"invalid SINGULAR_REVIEW_POLICY_JSON: {exc}") from exc
        json_source = "config"
    elif config_path:
        path = Path(config_path)
        if path.is_file():
            try:
                cfg = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                raise PolicyError(f"invalid review policy config {config_path}: {exc}") from exc
            if isinstance(cfg, dict) and "reviewPolicy" in cfg:
                json_blob = cfg.get("reviewPolicy")
                json_source = "config"

    if json_blob is not None:
        _apply_json_policy(policy, sources, json_blob, json_source)

    if "SINGULAR_REVIEW_MAX_ROUNDS" in env and env["SINGULAR_REVIEW_MAX_ROUNDS"] != "":
        policy["maxReviewRounds"] = _parse_int_ge(
            env["SINGULAR_REVIEW_MAX_ROUNDS"], "SINGULAR_REVIEW_MAX_ROUNDS", 1
        )
        sources["maxReviewRounds"] = "env"
    if "SINGULAR_REVIEW_BLOCKING_SEVERITIES" in env and env["SINGULAR_REVIEW_BLOCKING_SEVERITIES"] != "":
        policy["blockingSeverities"] = _parse_blocking(
            env["SINGULAR_REVIEW_BLOCKING_SEVERITIES"],
            "SINGULAR_REVIEW_BLOCKING_SEVERITIES",
        )
        sources["blockingSeverities"] = "env"
    if "SINGULAR_REVIEW_REQUIRE_CLASSIFICATION" in env and env["SINGULAR_REVIEW_REQUIRE_CLASSIFICATION"] != "":
        policy["requireClassification"] = _parse_bool_env(
            env["SINGULAR_REVIEW_REQUIRE_CLASSIFICATION"],
            "SINGULAR_REVIEW_REQUIRE_CLASSIFICATION",
        )
        sources["requireClassification"] = "env"

    # Empty-but-present env vars are invalid, never a silent default.
    for name in (
        "SINGULAR_REVIEW_MAX_ROUNDS",
        "SINGULAR_REVIEW_BLOCKING_SEVERITIES",
        "SINGULAR_REVIEW_REQUIRE_CLASSIFICATION",
    ):
        if name in env and env[name] == "":
            raise PolicyError(f"{name} is empty; omit it to use JSON/defaults")

    out = dict(policy)
    out["sources"] = sources
    return out


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
            text = _as_str(item).strip()
            if not text or text in seen:
                continue
            seen.add(text)
            out.append(text)
    return out


def _coverage(text: str, items: list[dict[str, Any]]) -> tuple[bool, str | None]:
    """(covered, conflicting-id) for one finding string under the exact rule."""
    for item in items:
        if item["summary"] is not None and text == item["summary"].strip():
            return True, None
    # Longest id first so `F1-a: ...` binds to F1-a, never to F1.
    for item in sorted(items, key=lambda entry: len(entry["id"]), reverse=True):
        pattern = (
            re.escape(item["id"])
            + r"(?:\s*\((P[0-3])\))?(?:\s*:|\s+[-–—](?=\s|$)|\s*$)"
        )
        match = re.match(pattern, text)
        if not match:
            continue
        if match.group(1) and item["severity"] and match.group(1) != item["severity"]:
            return True, item["id"]
        return True, None
    return False, None


def _reason(reasons: list[str], reason: str) -> None:
    if reason not in reasons:
        reasons.append(reason)


def classify(verdict: dict[str, Any], policy: dict[str, Any]) -> dict[str, Any]:
    """Apply the fail-closed classification rules. Never mutates the input verdict."""
    original = _as_str(verdict.get("verdict"))
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
        legacy = _as_str(verdict.get("schema")) in UNCLASSIFIABLE_SCHEMAS
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


def empty_ledger() -> dict[str, Any]:
    return {
        "schema": LEDGER_SCHEMA,
        "updatedAt": _utc_now(),
        "logicalChanges": {},
    }


def _validate_entry(entry: Any, logical_change: str) -> dict[str, Any]:
    """Refuse malformed ledger structure; a corrupt entry is never a fresh budget."""
    where = f"review-policy ledger entry {logical_change!r}"
    if not isinstance(entry, dict):
        raise LedgerError(f"{where} is not an object")
    for key, kind in (
        ("rounds", list), ("exceptions", list), ("reopenings", list), ("operations", dict),
    ):
        if key in entry and not isinstance(entry[key], kind):
            raise LedgerError(f"{where} {key} is not a {kind.__name__}")
    series = entry.get("series", 1)
    if not isinstance(series, int) or isinstance(series, bool) or series < 1:
        raise LedgerError(f"{where} series is invalid: {series!r}")
    for key in ("rounds", "exceptions", "reopenings"):
        for row in entry.get(key) or []:
            if not isinstance(row, dict):
                raise LedgerError(f"{where} {key} contains a non-object row")
            if "series" in row:
                value = row["series"]
                if not isinstance(value, int) or isinstance(value, bool) or value < 1:
                    raise LedgerError(f"{where} {key} row series is invalid: {value!r}")
    for ident, op in (entry.get("operations") or {}).items():
        if not isinstance(op, dict) or op.get("operationId") != ident:
            raise LedgerError(f"{where} operation {ident!r} is malformed")
    return entry


def _load_ledger_unlocked(path: Path, *, validate: bool = True) -> dict[str, Any]:
    if not path.is_file():
        return empty_ledger()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise LedgerError(f"invalid review-policy ledger {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise LedgerError(f"review-policy ledger {path} is not an object")
    data.setdefault("schema", LEDGER_SCHEMA)
    data.setdefault("logicalChanges", {})
    if not isinstance(data["logicalChanges"], dict):
        raise LedgerError(f"review-policy ledger {path} logicalChanges is not an object")
    if validate:
        for ident, entry in data["logicalChanges"].items():
            _validate_entry(entry, ident)
    return data


def _ledger_path(state_dir: Path) -> Path:
    return state_dir / "review-policy" / "ledger.json"


def commit_ledger(state_dir: Path, ledger: dict[str, Any]) -> None:
    """Durably write the ledger. Callers hold the write lock."""
    ledger["updatedAt"] = _utc_now()
    ledger["schema"] = LEDGER_SCHEMA
    try:
        _atomic_write(_ledger_path(state_dir), ledger)
    except OSError as exc:
        raise LedgerError(f"cannot write review-policy ledger: {exc}") from exc


def _atomic_write(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


@contextmanager
def locked_ledger(
    state_dir: Path, *, write: bool = True, validate: bool = True
) -> Iterator[dict[str, Any]]:
    """Yield the ledger under the fcntl lock.

    ``write=True`` (record/grant/backfill) creates the state dir and rewrites the
    ledger on exit. ``write=False`` (check/show) takes a shared lock, never
    creates state, and never rewrites, so read verbs leave no trace and
    ``updatedAt`` keeps meaning "last recorded change". A refused or failed
    write verb raises inside the block, so nothing is written.
    """
    policy_dir = state_dir / "review-policy"
    ledger_path = policy_dir / "ledger.json"
    lock_path = policy_dir / "ledger.lock"
    if not write:
        if not lock_path.is_file():
            yield _load_ledger_unlocked(ledger_path, validate=validate)
            return
        try:
            lock = lock_path.open("r", encoding="utf-8")
        except OSError as exc:
            raise LedgerError(f"cannot open review-policy ledger lock: {exc}") from exc
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_SH)
            yield _load_ledger_unlocked(ledger_path, validate=validate)
        finally:
            try:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
            except OSError:
                pass
            lock.close()
        return
    try:
        policy_dir.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise LedgerError(f"cannot create review-policy state dir: {exc}") from exc
    try:
        lock = lock_path.open("a+", encoding="utf-8")
    except OSError as exc:
        raise LedgerError(f"cannot open review-policy ledger lock: {exc}") from exc
    try:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        ledger = _load_ledger_unlocked(ledger_path, validate=validate)
        yield ledger
        commit_ledger(state_dir, ledger)
    finally:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
        except OSError:
            pass
        lock.close()


def _change_entry(ledger: dict[str, Any], logical_change: str) -> dict[str, Any]:
    changes = ledger.setdefault("logicalChanges", {})
    entry = changes.get(logical_change)
    if entry is None:
        entry = {"status": "open", "rounds": [], "exceptions": []}
        changes[logical_change] = entry
    _validate_entry(entry, logical_change)
    entry.setdefault("status", "open")
    entry.setdefault("rounds", [])
    entry.setdefault("exceptions", [])
    return entry


def _verdict_sha256(verdict: dict[str, Any]) -> str:
    canonical = json.dumps(verdict, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def operation_id(logical_change: str, task_id: str, run_id: str, attempt: int, head: str) -> str:
    """Deterministic review-operation id for one bound review."""
    binding = json.dumps(
        [logical_change, task_id, run_id, int(attempt), head], separators=(",", ":")
    )
    return "rop-" + hashlib.sha256(binding.encode("utf-8")).hexdigest()[:20]


def _series(entry: dict[str, Any]) -> int:
    return int(entry.get("series", 1))


def _is_legacy(row: dict[str, Any]) -> bool:
    return "series" not in row


def _legacy_open_count(entry: dict[str, Any]) -> int:
    """Legacy rows after the last legacy accepted row (the old reset rule)."""
    used = 0
    for row in entry.get("rounds") or []:
        if not _is_legacy(row):
            continue
        if row.get("effectiveVerdict") == "accepted":
            used = 0
        else:
            used += 1
    return used


def _legacy_last_accept(entry: dict[str, Any]) -> str:
    stamp = ""
    for row in entry.get("rounds") or []:
        if _is_legacy(row) and row.get("effectiveVerdict") == "accepted":
            stamp = max(stamp, _as_str(row.get("recordedAt")))
    return stamp


def _series_rows(entry: dict[str, Any]) -> list[dict[str, Any]]:
    series = _series(entry)
    return [
        row for row in entry.get("rounds") or []
        if not _is_legacy(row) and row.get("series") == series
    ]


def _closing_row(entry: dict[str, Any]) -> dict[str, Any] | None:
    """The accepted round that closed the current series, if any."""
    for row in reversed(_series_rows(entry)):
        if row.get("effectiveVerdict") == "accepted":
            return row
    return None


def _used_rounds(entry: dict[str, Any]) -> int:
    used = len(_series_rows(entry))
    if _series(entry) == 1:
        used += _legacy_open_count(entry)
    return used


def _pending_ops(entry: dict[str, Any], exclude_task: str | None = None) -> list[dict[str, Any]]:
    series = _series(entry)
    return [
        op for op in (entry.get("operations") or {}).values()
        if op.get("status") == OP_RESERVED and op.get("series") == series
        and (exclude_task is None or op.get("taskId") != exclude_task)
    ]


def _exception_matches_task(exc: dict[str, Any], task_id: str | None) -> bool:
    bound = exc.get("taskId", None)
    if bound is None or bound == "":
        return True
    return _as_str(bound) == _as_str(task_id)


def _grant_extra(exc: dict[str, Any]) -> int:
    extra = exc.get("additionalRounds")
    if not isinstance(extra, int) or isinstance(extra, bool) or extra < 1:
        return 0
    return extra


def _grant_applies(exc: dict[str, Any], entry: dict[str, Any], task_id: str | None) -> bool:
    """A grant extends only the series it was granted in, for its task."""
    if not _grant_extra(exc) or not _exception_matches_task(exc, task_id):
        return False
    if "series" in exc:
        return exc["series"] == _series(entry)
    # Legacy grant: it extended the legacy segment open when it was granted.
    if _series(entry) != 1:
        return False
    last_accept = _legacy_last_accept(entry)
    return not last_accept or _as_str(exc.get("grantedAt")) > last_accept


def allowed_rounds(entry: dict[str, Any], task_id: str | None, policy: dict[str, Any]) -> tuple[int, int]:
    """(completed rounds in the current series, rounds allowed in it)."""
    used = _used_rounds(entry)
    allowed = int(policy["maxReviewRounds"])
    for exc in entry.get("exceptions") or []:
        if _grant_applies(exc, entry, task_id):
            allowed += _grant_extra(exc)
    return used, allowed


def _grant_for_slot(entry: dict[str, Any], task_id: str | None, policy: dict[str, Any], slot: int) -> str:
    """Id of the grant that supplies 0-based slot ``slot``, or '' for a base slot."""
    bound = int(policy["maxReviewRounds"])
    if slot < bound:
        return ""
    for exc in entry.get("exceptions") or []:
        if not _grant_applies(exc, entry, task_id):
            continue
        bound += _grant_extra(exc)
        if slot < bound:
            return _as_str(exc.get("id"))
    return ""


def _admission(
    entry: dict[str, Any], logical_change: str, task_id: str, policy: dict[str, Any]
) -> dict[str, Any]:
    used, allowed = allowed_rounds(entry, task_id, policy)
    pending = len(_pending_ops(entry, exclude_task=task_id))
    closing = _closing_row(entry)
    out = {
        "allowed": True,
        "used": used,
        "pending": pending,
        "allowedRounds": allowed,
        "reason": "ok",
        "logicalChange": logical_change,
        "series": _series(entry),
        "closed": closing is not None,
        "status": entry.get("status") or "open",
    }
    if closing is not None:
        out["allowed"] = False
        out["status"] = entry.get("status") or "accepted"
        out["closedBy"] = {
            "round": closing.get("round"),
            "runId": closing.get("runId"),
            "operationId": closing.get("operationId"),
        }
        out["reason"] = (
            f"logical change {logical_change} is closed by accepted round "
            f"{closing.get('round')} (run {closing.get('runId')}); a new review "
            "series requires an explicit `reopen` with authority"
        )
    elif used + pending >= allowed:
        out["allowed"] = False
        out["status"] = entry.get("status") or "exhausted"
        out["reason"] = f"review rounds exhausted for {logical_change} ({used}/{allowed})"
        if pending:
            out["reason"] += f"; {pending} reserved by another task"
    return out


def check(
    ledger: dict[str, Any],
    logical_change: str,
    task_id: str,
    policy: dict[str, Any],
) -> dict[str, Any]:
    """Whether another review round is admissible. Never mutates the ledger."""
    changes = ledger.get("logicalChanges") if isinstance(ledger, dict) else {}
    if not isinstance(changes, dict):
        changes = {}
    entry = changes.get(logical_change)
    if entry is None:
        entry = {"status": "open", "rounds": [], "exceptions": []}
    _validate_entry(entry, logical_change)
    return _admission(entry, logical_change, task_id, policy)


def _admit_operation(
    entry: dict[str, Any],
    op_id: str,
    logical_change: str,
    task_id: str,
    run_id: str,
    attempt: int,
    head: str,
    campaign_binding: str,
    lane: str,
    policy: dict[str, Any],
    stamp: str,
) -> dict[str, Any]:
    """Admit one reserved operation or raise ExhaustedError. Caller holds the lock."""
    payload = _admission(entry, logical_change, task_id, policy)
    if not payload["allowed"]:
        raise ExhaustedError(payload)
    ops = entry.setdefault("operations", {})
    # One driver holds a task lease at a time, so a new reservation by the same
    # task proves its earlier pending reservation can no longer complete.
    for other in ops.values():
        if (
            other.get("status") == OP_RESERVED
            and other.get("taskId") == task_id
            and other.get("operationId") != op_id
        ):
            other["status"] = "abandoned"
            other["closedAt"] = stamp
            other["closedReason"] = f"superseded by {op_id}"
    slot = payload["used"] + payload["pending"]
    op = {
        "operationId": op_id,
        "status": OP_RESERVED,
        "logicalChange": logical_change,
        "taskId": task_id,
        "runId": run_id,
        "attempt": int(attempt),
        "head": head,
        "campaignBinding": campaign_binding,
        "lane": lane,
        "series": _series(entry),
        "slot": slot + 1,
        "reservedAt": stamp,
    }
    grant_id = _grant_for_slot(entry, task_id, policy, slot)
    if grant_id:
        op["grantId"] = grant_id
    previous = ops.get(op_id)
    if isinstance(previous, dict):
        op["previousStatus"] = previous.get("status")
    ops[op_id] = op
    return op


def reserve(
    ledger: dict[str, Any],
    logical_change: str,
    task_id: str,
    run_id: str,
    attempt: int,
    policy: dict[str, Any],
    *,
    head: str = "",
    campaign_binding: str = "",
    lane: str = "native",
) -> dict[str, Any]:
    """Atomically admit one review operation. Caller holds the write lock."""
    if lane not in LANES:
        raise PolicyError(f"lane must be one of {', '.join(LANES)}, got {lane!r}")
    entry = _change_entry(ledger, logical_change)
    op_id = operation_id(logical_change, task_id, run_id, attempt, head)
    existing = (entry.get("operations") or {}).get(op_id)
    idempotent = False
    if isinstance(existing, dict) and existing.get("status") == OP_COMPLETED:
        raise ConflictError(
            f"review operation {op_id} is already completed; a new review needs a new attempt"
        )
    if (
        isinstance(existing, dict)
        and existing.get("status") == OP_RESERVED
        and existing.get("series") == _series(entry)
    ):
        op = existing
        idempotent = True
    else:
        op = _admit_operation(
            entry, op_id, logical_change, task_id, run_id, attempt, head,
            campaign_binding, lane, policy, _utc_now(),
        )
    _refresh_status(entry, policy, task_id)
    out = _admission(entry, logical_change, task_id, policy)
    out.update({
        "allowed": True,
        "reason": "ok",
        "reserved": True,
        "idempotent": idempotent,
        "operationId": op_id,
        "operation": dict(op),
    })
    return out


def release(
    ledger: dict[str, Any],
    logical_change: str,
    op_id: str,
    reason: str,
    *,
    status: str = "infrastructure-exhausted",
) -> dict[str, Any]:
    """End a reserved operation that produced no verdict; frees its slot."""
    if status not in OP_RELEASE_STATUSES:
        raise PolicyError(f"release status must be one of {', '.join(OP_RELEASE_STATUSES)}")
    if not _nonblank(reason):
        raise PolicyError("release requires a non-blank reason")
    entry = _change_entry(ledger, logical_change)
    op = (entry.get("operations") or {}).get(op_id)
    if not isinstance(op, dict):
        raise PolicyError(f"unknown review operation {op_id} for {logical_change}")
    if op.get("status") == OP_COMPLETED:
        raise ConflictError(f"review operation {op_id} is completed and cannot be released")
    if op.get("status") != OP_RESERVED:
        return {"operationId": op_id, "status": op.get("status"), "released": False, "idempotent": True}
    op["status"] = status
    op["closedAt"] = _utc_now()
    op["closedReason"] = reason
    return {"operationId": op_id, "status": status, "released": True, "idempotent": False}


def _item_by_id(classification: dict[str, Any], ident: str) -> dict[str, Any] | None:
    for item in classification.get("items") or []:
        if isinstance(item, dict) and item.get("id") == ident:
            return item
    return None


def _append_backlog(
    state_dir: Path,
    logical_change: str,
    task_id: str,
    run_id: str,
    round_no: int,
    classification: dict[str, Any],
    recorded_at: str,
) -> None:
    ids = classification.get("backlog") or []
    if not ids:
        return
    path = state_dir / "review-policy" / "backlog.ndjson"
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        with path.open("a", encoding="utf-8") as handle:
            for ident in ids:
                item = _item_by_id(classification, ident) or {"id": ident}
                line = {
                    "logicalChange": logical_change,
                    "taskId": task_id,
                    "runId": run_id,
                    "round": round_no,
                    "id": item.get("id", ident),
                    "severity": item.get("severity", ""),
                    "summary": item.get("summary", ""),
                    "recordedAt": recorded_at,
                }
                for key in ("trigger", "impact", "requirement", "location"):
                    if item.get(key):
                        line[key] = item[key]
                handle.write(json.dumps(line, ensure_ascii=False) + "\n")
    except OSError as exc:
        raise LedgerError(f"cannot append review-policy backlog: {exc}") from exc


def _refresh_status(entry: dict[str, Any], policy: dict[str, Any], task_id: str | None) -> None:
    if _closing_row(entry) is not None:
        entry["status"] = "accepted"
        return
    if _series(entry) == 1 and not _series_rows(entry):
        legacy = [row for row in entry.get("rounds") or [] if _is_legacy(row)]
        if legacy and _as_str(legacy[-1].get("effectiveVerdict")) == "accepted":
            # Legacy boundary: reported as accepted, but not closed.
            entry["status"] = "accepted"
            return
    used, allowed = allowed_rounds(entry, task_id, policy)
    entry["status"] = "exhausted" if used >= allowed else "open"


def record(
    ledger: dict[str, Any],
    logical_change: str,
    task_id: str,
    run_id: str,
    attempt: int,
    verdict: dict[str, Any],
    policy: dict[str, Any],
    *,
    head: str = "",
    campaign_binding: str = "",
    lane: str = "native",
    reviewer: dict[str, str] | None = None,
    historical: bool = False,
    recorded_at: str | None = None,
    state_dir: Path | None = None,
    operation: str | None = None,
    host_verification: str = "",
) -> dict[str, Any]:
    """Complete one review operation with a schema-valid verdict.

    With ``operation`` the reserved operation is completed. Without it the
    round is admitted and completed under the caller's lock, or refused with
    ExhaustedError. Completing a completed operation again is a no-op when the
    verdict hash matches (raw or as applied) and a ConflictError otherwise.
    Transport failures never call this.
    """
    if lane not in LANES:
        raise PolicyError(f"lane must be one of {', '.join(LANES)}, got {lane!r}")
    entry = _change_entry(ledger, logical_change)
    ops = entry.setdefault("operations", {})
    verdict_hash = _verdict_sha256(verdict)
    op_id = operation or operation_id(logical_change, task_id, run_id, attempt, head)
    op = ops.get(op_id)
    if isinstance(op, dict) and op.get("status") == OP_COMPLETED:
        if verdict_hash in (op.get("rawVerdictSha256"), op.get("appliedVerdictSha256")):
            out = dict(op.get("result") or {})
            out["idempotent"] = True
            out["operationId"] = op_id
            return out
        raise ConflictError(
            f"review operation {op_id} was already completed with different verdict content"
        )
    stamp = recorded_at or _utc_now()
    if operation:
        if not isinstance(op, dict):
            raise ConflictError(f"unknown review operation {op_id} for {logical_change}")
        if op.get("status") != OP_RESERVED:
            raise ConflictError(
                f"review operation {op_id} is {op.get('status')}; it cannot be completed"
            )
        for key, value in (
            ("logicalChange", logical_change), ("taskId", task_id), ("runId", run_id),
            ("attempt", int(attempt)), ("head", head),
        ):
            if op.get(key) != value:
                raise ConflictError(
                    f"review operation {op_id} is bound to {key}={op.get(key)!r}, got {value!r}"
                )
        if op.get("series") != _series(entry):
            raise ConflictError(
                f"review operation {op_id} belongs to series {op.get('series')}, "
                f"but {logical_change} is in series {_series(entry)}"
            )
    elif not (
        isinstance(op, dict)
        and op.get("status") == OP_RESERVED
        and op.get("series") == _series(entry)
    ):
        op = _admit_operation(
            entry, op_id, logical_change, task_id, run_id, attempt, head,
            campaign_binding, lane, policy, stamp,
        )
        op["implicit"] = True

    classification = classify(verdict, policy)
    if host_verification == "failed-product" and classification["effectiveVerdict"] == "accepted":
        # The host gate failed the product on this head: the review cannot close it.
        classification["effectiveVerdict"] = "needs-fix"
        classification["applied"] = classification["originalVerdict"] != "needs-fix"
        classification["blocking"].append("host-verification-failed-product")
        classification["reasons"].append("host-verification-failed-product")
        classification["reason"] = classification["reasons"][0]
    round_no = len(entry["rounds"]) + 1
    kind = "initial" if round_no == 1 else "followup"
    series_round = len(_series_rows(entry)) + 1
    reviewer = reviewer or {}
    round_row = {
        "round": round_no,
        "kind": kind,
        "taskId": task_id,
        "runId": run_id,
        "attempt": int(attempt),
        "head": head,
        "campaignBinding": campaign_binding,
        "lane": lane,
        "reviewer": {
            "runner": _as_str(reviewer.get("runner")),
            "model": _as_str(reviewer.get("model")),
            "effort": _as_str(reviewer.get("effort")),
        },
        "originalVerdict": classification["originalVerdict"],
        "effectiveVerdict": classification["effectiveVerdict"],
        "blocking": list(classification["blocking"]),
        "backlog": list(classification["backlog"]),
        "downgraded": list(classification["downgraded"]),
        "unsupported": list(classification["unsupported"]),
        "unresolved": list(classification["unresolved"]),
        "unclassifiedCount": int(classification["unclassifiedCount"]),
        "recordedAt": stamp,
        "historical": bool(historical),
        "series": _series(entry),
        "seriesRound": series_round,
        "operationId": op_id,
        "verdictSha256": verdict_hash,
    }
    if classification.get("reason"):
        round_row["reason"] = classification["reason"]
    if op.get("grantId"):
        round_row["grantId"] = op["grantId"]
    if host_verification:
        round_row["hostVerification"] = host_verification
    entry["rounds"].append(round_row)
    _refresh_status(entry, policy, task_id)
    if state_dir is not None:
        _append_backlog(
            state_dir, logical_change, task_id, run_id, round_no, classification, stamp
        )
    used, allowed = allowed_rounds(entry, task_id, policy)
    out = dict(classification)
    out.update(
        {
            "logicalChange": logical_change,
            "round": round_no,
            "kind": kind,
            "series": _series(entry),
            "seriesRound": series_round,
            "maxRounds": int(policy["maxReviewRounds"]),
            "allowedRounds": allowed,
            "used": used,
            "status": entry["status"],
            "recordedAt": stamp,
            "historical": bool(historical),
            "operationId": op_id,
            "idempotent": False,
        }
    )
    op["status"] = OP_COMPLETED
    op["completedAt"] = stamp
    op["round"] = round_no
    op["rawVerdictSha256"] = verdict_hash
    op["result"] = {key: value for key, value in out.items() if key != "idempotent"}
    return out


def apply_to_verdict(
    verdict_path: str | Path,
    classification: dict[str, Any],
    round_info: dict[str, Any],
) -> dict[str, Any]:
    """Rewrite the verdict's effective field and stamp a top-level reviewPolicy object."""
    path = Path(verdict_path)
    try:
        original = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise LedgerError(f"cannot read verdict {path}: {exc}") from exc
    if not isinstance(original, dict):
        raise LedgerError(f"verdict {path} is not a JSON object")

    effective = classification.get("effectiveVerdict") or original.get("verdict")
    policy_obj = {
        "version": int(round_info.get("version") or POLICY_VERSION),
        "logicalChange": _as_str(round_info.get("logicalChange")),
        "round": int(round_info.get("round") or 0),
        "maxRounds": int(round_info.get("maxRounds") or 0),
        "originalVerdict": classification.get("originalVerdict") or original.get("verdict"),
        "effectiveVerdict": effective,
        "blocking": list(classification.get("blocking") or []),
        "backlog": list(classification.get("backlog") or []),
        "downgraded": list(classification.get("downgraded") or []),
        "unclassifiedCount": int(classification.get("unclassifiedCount") or 0),
        "appliedAt": _utc_now(),
    }
    # The host stamp is a member of audit-verdict.v1 only. Legacy v0 schemas
    # forbid unknown members, so a v0 verdict receives the effective verdict
    # and the pre-policy copy, while the round record carries the details.
    stamp = _as_str(original.get("schema")) == "singular.orchestration.audit-verdict.v1"
    changed = original.get("verdict") != effective or (
        stamp and original.get("reviewPolicy") != policy_obj
    )
    if changed:
        pre = Path(str(path) + ".pre-policy.json")
        try:
            _atomic_write(pre, original)
        except OSError as exc:
            raise LedgerError(f"cannot write {pre}: {exc}") from exc
    rewritten = dict(original)
    rewritten["verdict"] = effective
    if stamp:
        rewritten["reviewPolicy"] = policy_obj
    elif not changed:
        return original
    try:
        _atomic_write(path, rewritten)
    except OSError as exc:
        raise LedgerError(f"cannot write verdict {path}: {exc}") from exc
    return rewritten


def _hash_evidence(evidence: list[str]) -> list[dict[str, str]]:
    hashed = []
    for raw in evidence:
        path = Path(raw)
        if not path.is_file():
            raise PolicyError(f"evidence path is missing or not a file: {raw}")
        try:
            digest = sha256_file(path)
        except OSError as exc:
            raise LedgerError(f"cannot hash evidence {raw}: {exc}") from exc
        hashed.append({"path": str(path), "sha256": digest})
    return hashed


def grant(
    ledger: dict[str, Any],
    logical_change: str,
    additional_rounds: int,
    reason: str,
    evidence: list[str],
    policy: dict[str, Any],
    *,
    task_id: str | None = None,
    authority: str = "",
) -> dict[str, Any]:
    if not isinstance(additional_rounds, int) or isinstance(additional_rounds, bool) or additional_rounds < 1:
        raise PolicyError("additional rounds must be an integer >= 1")
    max_rounds = int(policy["maxReviewRounds"])
    if additional_rounds > max_rounds:
        raise PolicyError(
            f"additionalRounds {additional_rounds} exceeds maxReviewRounds {max_rounds}"
        )
    if not _nonblank(reason):
        raise PolicyError("grant requires a non-blank reason")
    if not _nonblank(authority):
        raise PolicyError("grant requires --authority")
    if not evidence:
        raise PolicyError("grant requires at least one --evidence path")

    entry = _change_entry(ledger, logical_change)
    if _closing_row(entry) is not None:
        raise PolicyError(
            f"{logical_change} is closed by an accepted round; a grant cannot extend a "
            "closed series (use reopen)"
        )
    used = _used_rounds(entry)
    bound = max_rounds
    for exc in entry["exceptions"]:
        if not _grant_applies(exc, entry, task_id):
            continue
        bound += _grant_extra(exc)
        if used < bound:
            raise PolicyError(
                f"an active (unconsumed) exception already exists for {logical_change}: "
                f"{exc.get('id')}"
            )

    hashed = _hash_evidence(evidence)
    stamp = _utc_now()
    ident = "exc-" + hashlib.sha256(
        f"{logical_change}|{stamp}|{reason}|{authority}".encode()
    ).hexdigest()[:12]
    row = {
        "id": ident,
        "grantedAt": stamp,
        "additionalRounds": additional_rounds,
        "reason": reason,
        "evidence": hashed,
        "taskId": task_id if task_id else None,
        "authority": authority,
        # Bound to this series: rounds used in a series never decrease, so the
        # grant cannot be consumed again after a reopen.
        "series": _series(entry),
    }
    entry["exceptions"].append(row)
    _refresh_status(entry, policy, task_id)
    used, allowed = allowed_rounds(entry, task_id, policy)
    return {
        "exception": row,
        "logicalChange": logical_change,
        "used": used,
        "allowedRounds": allowed,
        "status": entry["status"],
    }


def reopen(
    ledger: dict[str, Any],
    logical_change: str,
    reason: str,
    evidence: list[str],
    policy: dict[str, Any],
    *,
    task_id: str | None = None,
    authority: str = "",
    if_closed: bool = False,
) -> dict[str, Any]:
    """Start a new review series for a logical change closed by acceptance.

    Authority-bearing like ``grant``. Replaying the same authority, reason and
    evidence is refused, so one authorization opens at most one series.
    """
    if not _nonblank(reason):
        raise PolicyError("reopen requires a non-blank reason")
    if not _nonblank(authority):
        raise PolicyError("reopen requires --authority")
    if not evidence:
        raise PolicyError("reopen requires at least one --evidence path")
    entry = _change_entry(ledger, logical_change)
    closing = _closing_row(entry)
    if closing is None:
        if if_closed:
            return {
                "logicalChange": logical_change,
                "reopened": False,
                "series": _series(entry),
                "status": entry.get("status") or "open",
            }
        raise PolicyError(
            f"{logical_change} is not closed by an accepted round; use grant to extend an open series"
        )
    hashed = _hash_evidence(evidence)
    fingerprint = hashlib.sha256(
        json.dumps([authority, reason, hashed], sort_keys=True).encode("utf-8")
    ).hexdigest()
    for prior in entry.get("reopenings") or []:
        if prior.get("fingerprint") == fingerprint:
            raise PolicyError(
                f"this authority already reopened {logical_change} ({prior.get('id')}); "
                "it cannot open another series"
            )
    stamp = _utc_now()
    previous = _series(entry)
    row = {
        "id": "reopen-" + fingerprint[:12],
        "reopenedAt": stamp,
        "fromSeries": previous,
        "series": previous + 1,
        "closedByRound": closing.get("round"),
        "closedByRun": closing.get("runId"),
        "closedByOperation": closing.get("operationId"),
        "reason": reason,
        "evidence": hashed,
        "taskId": task_id if task_id else None,
        "authority": authority,
        "fingerprint": fingerprint,
    }
    entry.setdefault("reopenings", []).append(row)
    entry["series"] = previous + 1
    _refresh_status(entry, policy, task_id)
    used, allowed = allowed_rounds(entry, task_id, policy)
    return {
        "logicalChange": logical_change,
        "reopened": True,
        "reopening": row,
        "series": entry["series"],
        "used": used,
        "allowedRounds": allowed,
        "status": entry["status"],
    }


def _coerce_round(raw: dict[str, Any], index: int) -> dict[str, Any]:
    round_no = raw.get("round", index)
    try:
        round_no = int(round_no)
    except (TypeError, ValueError) as exc:
        raise PolicyError(f"backfill round number is invalid: {raw.get('round')!r}") from exc
    kind = raw.get("kind") or ("initial" if round_no == 1 else "followup")
    if kind not in ROUND_KINDS:
        raise PolicyError(f"backfill round kind must be initial or followup, got {kind!r}")
    reviewer = raw.get("reviewer") if isinstance(raw.get("reviewer"), dict) else {}
    return {
        "round": round_no,
        "kind": kind,
        "taskId": _as_str(raw.get("taskId")),
        "runId": _as_str(raw.get("runId")),
        "attempt": int(raw.get("attempt") or round_no),
        "head": _as_str(raw.get("head")),
        "campaignBinding": _as_str(raw.get("campaignBinding")),
        "lane": raw.get("lane") if raw.get("lane") in LANES else "native",
        "reviewer": {
            "runner": _as_str(reviewer.get("runner")),
            "model": _as_str(reviewer.get("model")),
            "effort": _as_str(reviewer.get("effort")),
        },
        "originalVerdict": _as_str(raw.get("originalVerdict") or raw.get("verdict") or "needs-fix"),
        "effectiveVerdict": _as_str(raw.get("effectiveVerdict") or raw.get("verdict") or "needs-fix"),
        "blocking": [str(x) for x in (raw.get("blocking") or [])],
        "backlog": [str(x) for x in (raw.get("backlog") or [])],
        "downgraded": [str(x) for x in (raw.get("downgraded") or [])],
        "unclassifiedCount": int(raw.get("unclassifiedCount") or 0),
        "recordedAt": _as_str(raw.get("recordedAt") or _utc_now()),
        "historical": True,
    }


def backfill(ledger: dict[str, Any], entries: list[dict[str, Any]], policy: dict[str, Any]) -> dict[str, Any]:
    """Add historical rounds/exceptions. Historical rounds count toward used."""
    added_rounds = 0
    added_exceptions = 0
    for item in entries:
        if not isinstance(item, dict):
            raise PolicyError("backfill entries must be objects")
        logical_change = _as_str(item.get("logicalChange")).strip()
        if not logical_change:
            raise PolicyError("backfill entry requires logicalChange")
        entry = _change_entry(ledger, logical_change)
        for raw_round in item.get("rounds") or []:
            if not isinstance(raw_round, dict):
                raise PolicyError("backfill rounds must be objects")
            entry["rounds"].append(_coerce_round(raw_round, len(entry["rounds"]) + 1))
            added_rounds += 1
        for raw_exc in item.get("exceptions") or []:
            if not isinstance(raw_exc, dict):
                raise PolicyError("backfill exceptions must be objects")
            extra = raw_exc.get("additionalRounds")
            if not isinstance(extra, int) or isinstance(extra, bool) or extra < 1:
                raise PolicyError("backfill exception additionalRounds must be an integer >= 1")
            evidence = raw_exc.get("evidence") or []
            if not isinstance(evidence, list):
                evidence = []
            entry["exceptions"].append(
                {
                    "id": _as_str(raw_exc.get("id")) or f"exc-historical-{len(entry['exceptions']) + 1}",
                    "grantedAt": _as_str(raw_exc.get("grantedAt") or _utc_now()),
                    "additionalRounds": extra,
                    "reason": _as_str(raw_exc.get("reason")),
                    "evidence": evidence,
                    "taskId": raw_exc.get("taskId", None),
                    "authority": _as_str(raw_exc.get("authority")),
                    "historical": True,
                }
            )
            added_exceptions += 1
        task_hint = None
        rounds = [row for row in entry["rounds"] if isinstance(row, dict)]
        if rounds:
            task_hint = rounds[-1].get("taskId")
        _refresh_status(entry, policy, task_hint)
    return {
        "addedRounds": added_rounds,
        "addedExceptions": added_exceptions,
        "updatedAt": _utc_now(),
    }


def _read_backlog(state_dir: Path, logical_change: str | None) -> list[dict[str, Any]]:
    path = state_dir / "review-policy" / "backlog.ndjson"
    if not path.is_file():
        return []
    rows = []
    try:
        with path.open(encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(row, dict):
                    continue
                if logical_change and row.get("logicalChange") != logical_change:
                    continue
                rows.append(row)
    except OSError as exc:
        raise LedgerError(f"cannot read review-policy backlog: {exc}") from exc
    return rows


def _resolve_root(ns: argparse.Namespace) -> Path:
    root = os.environ.get("SINGULAR_ROOT") or os.getcwd()
    return Path(root)


def _resolve_config(ns: argparse.Namespace) -> str | None:
    if getattr(ns, "config", None):
        return ns.config
    env = os.environ.get("SINGULAR_JSON_CONFIG_FILE")
    if env:
        return env
    candidate = _resolve_root(ns) / "singular.config.json"
    return str(candidate)


def _resolve_state_dir(ns: argparse.Namespace) -> Path:
    if getattr(ns, "state_dir", None):
        return Path(ns.state_dir)
    env = os.environ.get("SINGULAR_STATE_DIR")
    if env:
        return Path(env)
    return _resolve_root(ns) / ".singular-state"


def _load_verdict(path: str) -> dict[str, Any]:
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise LedgerError(f"cannot read verdict {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise LedgerError(f"verdict {path} is not a JSON object")
    return data


def _cmd_effective(ns: argparse.Namespace) -> int:
    policy = load_policy(os.environ, _resolve_config(ns))
    _print_json(policy)
    return EXIT_OK


def _cmd_show(ns: argparse.Namespace) -> int:
    state_dir = _resolve_state_dir(ns)
    # show is a diagnosis verb: it prints even a ledger that fails validation.
    with locked_ledger(state_dir, write=False, validate=False) as ledger:
        pass
    if ns.logical_change:
        entry = (ledger.get("logicalChanges") or {}).get(ns.logical_change)
        _print_json(
            {
                "logicalChange": ns.logical_change,
                "entry": entry if isinstance(entry, dict) else None,
            }
        )
        return EXIT_OK
    _print_json(ledger)
    return EXIT_OK


def _cmd_check(ns: argparse.Namespace) -> int:
    policy = load_policy(os.environ, _resolve_config(ns))
    state_dir = _resolve_state_dir(ns)
    path = state_dir / "review-policy" / "ledger.json"
    # Shared lock: a concurrent record cannot interleave the read, and a
    # read verb never creates or rewrites durable state.
    with locked_ledger(state_dir, write=False) as ledger:
        result = check(ledger, ns.logical_change, ns.task, policy)
    _print_json(result)
    return EXIT_OK if result["allowed"] else EXIT_EXHAUSTED


def _cmd_reserve(ns: argparse.Namespace) -> int:
    policy = load_policy(os.environ, _resolve_config(ns))
    state_dir = _resolve_state_dir(ns)
    with locked_ledger(state_dir) as ledger:
        result = reserve(
            ledger,
            ns.logical_change,
            ns.task,
            ns.run,
            ns.attempt,
            policy,
            head=ns.head,
            campaign_binding=ns.campaign or "",
            lane=ns.lane,
        )
    _print_json(result)
    return EXIT_OK


def _cmd_record(ns: argparse.Namespace) -> int:
    policy = load_policy(os.environ, _resolve_config(ns))
    state_dir = _resolve_state_dir(ns)
    verdict = _load_verdict(ns.verdict)
    reviewer = {
        "runner": ns.reviewer_runner or "",
        "model": ns.reviewer_model or "",
        "effort": ns.reviewer_effort or "",
    }
    with locked_ledger(state_dir) as ledger:
        result = record(
            ledger,
            ns.logical_change,
            ns.task,
            ns.run,
            ns.attempt,
            verdict,
            policy,
            head=ns.head or "",
            campaign_binding=ns.campaign or "",
            lane=ns.lane,
            reviewer=reviewer,
            operation=ns.operation or None,
            host_verification=ns.host_verification or "",
        )
        op = ledger["logicalChanges"][ns.logical_change]["operations"][result["operationId"]]
        if result.get("idempotent"):
            # Replay of a completed operation: nothing new is recorded. A verdict
            # file still holding the raw content is re-derived on --apply.
            applied = _verdict_sha256(verdict) == op.get("appliedVerdictSha256")
            if ns.apply and not applied:
                rewritten = apply_to_verdict(ns.verdict, result, {
                    "version": policy["version"],
                    "logicalChange": ns.logical_change,
                    "round": result["round"],
                    "maxRounds": policy["maxReviewRounds"],
                })
                op["appliedVerdictSha256"] = _verdict_sha256(rewritten)
                applied = True
            result["appliedToVerdict"] = applied
        else:
            # The authoritative ledger is durable before any derived verdict
            # (and its effective label) is written.
            commit_ledger(state_dir, ledger)
            _append_backlog(
                state_dir, ns.logical_change, ns.task, ns.run, result["round"],
                result, result["recordedAt"],
            )
            if ns.apply:
                rewritten = apply_to_verdict(
                    ns.verdict,
                    result,
                    {
                        "version": policy["version"],
                        "logicalChange": ns.logical_change,
                        "round": result["round"],
                        "maxRounds": policy["maxReviewRounds"],
                    },
                )
                op["appliedVerdictSha256"] = _verdict_sha256(rewritten)
                result["appliedToVerdict"] = True
            else:
                result["appliedToVerdict"] = False
    _print_json(result)
    return EXIT_OK


def _cmd_release(ns: argparse.Namespace) -> int:
    state_dir = _resolve_state_dir(ns)
    with locked_ledger(state_dir) as ledger:
        result = release(
            ledger, ns.logical_change, ns.operation, ns.reason, status=ns.status
        )
    _print_json(result)
    return EXIT_OK


def _cmd_reopen(ns: argparse.Namespace) -> int:
    policy = load_policy(os.environ, _resolve_config(ns))
    state_dir = _resolve_state_dir(ns)
    with locked_ledger(state_dir) as ledger:
        result = reopen(
            ledger,
            ns.logical_change,
            ns.reason,
            list(ns.evidence or []),
            policy,
            task_id=ns.task,
            authority=ns.authority,
            if_closed=ns.if_closed,
        )
    _print_json(result)
    return EXIT_OK


def _cmd_grant(ns: argparse.Namespace) -> int:
    policy = load_policy(os.environ, _resolve_config(ns))
    state_dir = _resolve_state_dir(ns)
    with locked_ledger(state_dir) as ledger:
        result = grant(
            ledger,
            ns.logical_change,
            ns.rounds,
            ns.reason,
            list(ns.evidence or []),
            policy,
            task_id=ns.task,
            authority=ns.authority,
        )
    _print_json(result)
    return EXIT_OK


def _normalize_backfill_payload(payload: Any) -> list[dict[str, Any]]:
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        if "entries" in payload and isinstance(payload["entries"], list):
            return payload["entries"]
        if "logicalChange" in payload:
            return [payload]
        if "logicalChanges" in payload and isinstance(payload["logicalChanges"], dict):
            entries = []
            for ident, body in payload["logicalChanges"].items():
                if not isinstance(body, dict):
                    continue
                item = dict(body)
                item["logicalChange"] = ident
                entries.append(item)
            return entries
    raise PolicyError("backfill file must be an object or array of logical-change entries")


def _cmd_backfill(ns: argparse.Namespace) -> int:
    policy = load_policy(os.environ, _resolve_config(ns))
    try:
        payload = json.loads(Path(ns.file).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise LedgerError(f"cannot read backfill file {ns.file}: {exc}") from exc
    entries = _normalize_backfill_payload(payload)
    state_dir = _resolve_state_dir(ns)
    with locked_ledger(state_dir) as ledger:
        result = backfill(ledger, entries, policy)
    _print_json(result)
    return EXIT_OK


def _cmd_backlog(ns: argparse.Namespace) -> int:
    rows = _read_backlog(_resolve_state_dir(ns), ns.logical_change)
    _print_json({"backlog": rows, "count": len(rows)})
    return EXIT_OK


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="singular review-policy",
        description="Programmable review policy: classify findings, bound rounds, grant exceptions.",
    )
    parser.add_argument("--config", help="singular.config.json path")
    parser.add_argument("--state-dir", help="state directory (default: $SINGULAR_STATE_DIR)")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("effective", help="print effective policy with sources")

    show = sub.add_parser("show", help="print the ledger or one logical change")
    show.add_argument("--logical-change")

    chk = sub.add_parser("check", help="whether another review round is allowed (read-only)")
    chk.add_argument("--logical-change", required=True)
    chk.add_argument("--task", required=True)

    res = sub.add_parser("reserve", help="atomically admit one review operation")
    res.add_argument("--logical-change", required=True)
    res.add_argument("--task", required=True)
    res.add_argument("--run", required=True)
    res.add_argument("--attempt", required=True, type=int)
    res.add_argument("--head", required=True)
    res.add_argument("--campaign", default="")
    res.add_argument("--lane", default="native", choices=LANES)

    rec = sub.add_parser("record", help="record a completed schema-valid verdict")
    rec.add_argument("--logical-change", required=True)
    rec.add_argument("--task", required=True)
    rec.add_argument("--run", required=True)
    rec.add_argument("--attempt", required=True, type=int)
    rec.add_argument("--verdict", required=True)
    rec.add_argument("--head", required=True)
    rec.add_argument("--campaign", default="")
    rec.add_argument("--lane", default="native", choices=LANES)
    rec.add_argument("--reviewer-runner", default="")
    rec.add_argument("--reviewer-model", default="")
    rec.add_argument("--reviewer-effort", default="")
    rec.add_argument("--operation", default="", help="reserved review operation to complete")
    rec.add_argument(
        "--host-verification", default="",
        help="host verification classification of the reviewed head",
    )
    rec.add_argument("--apply", action="store_true", help="rewrite the verdict file")

    rel = sub.add_parser("release", help="end a reserved operation that produced no verdict")
    rel.add_argument("--logical-change", required=True)
    rel.add_argument("--operation", required=True)
    rel.add_argument("--reason", required=True)
    rel.add_argument("--status", default="infrastructure-exhausted", choices=OP_RELEASE_STATUSES)

    rop = sub.add_parser("reopen", help="start a new review series for a closed logical change")
    rop.add_argument("--logical-change", required=True)
    rop.add_argument("--reason", required=True)
    rop.add_argument("--evidence", nargs="+", required=True)
    rop.add_argument("--task")
    rop.add_argument("--authority", required=True)
    rop.add_argument("--if-closed", action="store_true", help="no-op (exit 0) when the change is not closed")

    gnt = sub.add_parser("grant", help="grant additional review rounds")
    gnt.add_argument("--logical-change", required=True)
    gnt.add_argument("--rounds", required=True, type=int)
    gnt.add_argument("--reason", required=True)
    gnt.add_argument("--evidence", nargs="+", required=True)
    gnt.add_argument("--task")
    gnt.add_argument("--authority", required=True)

    bf = sub.add_parser("backfill", help="add historical rounds/exceptions")
    bf.add_argument("--file", required=True)

    bl = sub.add_parser("backlog", help="print non-blocking backlog items")
    bl.add_argument("--logical-change")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    try:
        ns = parser.parse_args(argv)
    except SystemExit as exc:
        code = exc.code if isinstance(exc.code, int) else EXIT_USAGE
        return EXIT_USAGE if code else EXIT_OK

    handlers: dict[str, Callable[[argparse.Namespace], int]] = {
        "effective": _cmd_effective,
        "show": _cmd_show,
        "check": _cmd_check,
        "reserve": _cmd_reserve,
        "record": _cmd_record,
        "release": _cmd_release,
        "reopen": _cmd_reopen,
        "grant": _cmd_grant,
        "backfill": _cmd_backfill,
        "backlog": _cmd_backlog,
    }
    try:
        return handlers[ns.command](ns)
    except ExhaustedError as exc:
        _print_json(exc.payload)
        print(f"review-policy: {exc}", file=sys.stderr)
        return EXIT_EXHAUSTED
    except ConflictError as exc:
        print(f"review-policy: {exc}", file=sys.stderr)
        return EXIT_CONFLICT
    except PolicyError as exc:
        print(f"review-policy: {exc}", file=sys.stderr)
        return EXIT_USAGE
    except LedgerError as exc:
        print(f"review-policy: {exc}", file=sys.stderr)
        return EXIT_LEDGER
    except OSError as exc:
        print(f"review-policy: {exc}", file=sys.stderr)
        return EXIT_LEDGER


if __name__ == "__main__":
    sys.exit(main())
