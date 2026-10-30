#!/usr/bin/env python3
"""Replay the synthetic graph through public orchestration contracts."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
from typing import Any


CAPTURE_SCHEMA = "singular.orchestration.field-report-capture.v0"
STATUS_SCHEMA = "singular.orchestration.run-status.v0"
GATE_SCHEMA = "singular.orchestration.gate-result.v1"
DIAGNOSTIC_CATEGORIES = {
    "product-failure",
    "orchestration-failure",
    "provider-failure",
    "optional-dependency-warning",
    "acknowledged-baseline",
    "infrastructure-inconclusive",
    "info",
}
PHASES = {
    "planning",
    "implementing",
    "gating",
    "auditing",
    "deciding",
    "integrating",
    "awaiting-human",
    "terminal",
}


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def safe_path(root: Path, ref: str) -> Path:
    candidate = Path(ref)
    if candidate.is_absolute() or ".." in candidate.parts:
        raise AssertionError(f"unsafe fixture reference: {ref}")
    resolved = (root / candidate).resolve()
    resolved.relative_to(root.resolve())
    return resolved


def run(
    command: list[str],
    *,
    env: dict[str, str],
    timeout: int = 10,
) -> str:
    result = subprocess.run(
        command,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )
    if result.returncode != 0:
        rendered = " ".join(command)
        raise AssertionError(
            f"command failed ({result.returncode}): {rendered}\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )
    return result.stdout.strip()


def load_capture(path: Path) -> dict[str, Any]:
    capture = json.loads(path.read_text(encoding="utf-8"))
    assert capture.get("schema") == CAPTURE_SCHEMA
    assert set(capture) == {
        "schema",
        "capturedAt",
        "source",
        "dag",
        "events",
        "artifacts",
        "runStatuses",
    }
    return capture


def validate_and_materialize(
    capture_path: Path,
    repo: Path,
) -> tuple[dict[str, Any], dict[str, Any], Path, Path]:
    capture = load_capture(capture_path)
    fixture_root = capture_path.parent
    dag_meta = capture["dag"]
    events_meta = capture["events"]
    dag_source = safe_path(fixture_root, dag_meta["ref"])
    events_source = safe_path(fixture_root, events_meta["ref"])
    assert sha256_file(dag_source) == dag_meta["sha256"]
    assert sha256_file(events_source) == events_meta["sha256"]

    dag = json.loads(dag_source.read_text(encoding="utf-8"))
    nodes = dag.get("nodes")
    assert isinstance(nodes, list)
    assert len(nodes) == dag_meta["nodeCount"] == 26
    node_ids = [node["id"] for node in nodes]
    assert len(node_ids) == len(set(node_ids)) == 26

    raw_events = events_source.read_bytes()
    events = [
        json.loads(line)
        for line in raw_events.decode("utf-8").splitlines()
        if line.strip()
    ]
    assert len(events) == events_meta["recordCount"]
    assert set(events_meta["diagnosticCounts"]) == DIAGNOSTIC_CATEGORIES

    orchestration = repo / "docs" / "orchestration"
    state = repo / ".singular-state"
    (orchestration / "gates").mkdir(parents=True, exist_ok=True)
    state.mkdir(parents=True, exist_ok=True)
    dag_target = orchestration / "dag.v0.json"
    events_target = state / "events.ndjson"
    shutil.copyfile(dag_source, dag_target)
    shutil.copyfile(events_source, events_target)
    assert dag_target.read_bytes() == dag_source.read_bytes()
    assert events_target.read_bytes() == raw_events

    artifact_by_node: dict[str, dict[str, Any]] = {}
    for artifact in capture["artifacts"]:
        assert set(artifact) == {"node", "ref", "sha256", "content"}
        node = artifact["node"]
        assert node in node_ids and node not in artifact_by_node
        payload = artifact["content"].encode("utf-8")
        assert sha256_bytes(payload) == artifact["sha256"]
        target = safe_path(repo, artifact["ref"])
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(payload)
        assert sha256_file(target) == artifact["sha256"]
        artifact_by_node[node] = artifact
    assert set(artifact_by_node) == set(node_ids)
    return capture, dag, dag_target, events_target


def engine_environment(root: Path, repo: Path, dag_path: Path) -> dict[str, str]:
    env = os.environ.copy()
    env.update(
        {
            "SINGULAR_ROOT": str(repo),
            "SINGULAR_PUSH": "0",
            "SINGULAR_ENGINE_HOME": str(root),
            "SINGULAR_ENGINE_DIR": str(root / "engine"),
            "SINGULAR_SCHEMA_DIR": str(root / "schemas"),
            "SINGULAR_STATE_DIR": str(repo / ".singular-state"),
            "SINGULAR_RUNS_DIR": str(repo / ".singular-state" / "runs"),
            "SINGULAR_ORCH_DIR": str(repo / "docs" / "orchestration"),
            "SINGULAR_DAG_FILE": str(dag_path),
            "SINGULAR_GATES_DIR": str(repo / "docs" / "orchestration" / "gates"),
            "SINGULAR_TASKS_DIR": str(repo / "docs" / "orchestration" / "tasks"),
            "SINGULAR_LEASES_DIR": str(repo / ".singular-state" / "leases"),
            "SINGULAR_WORKTREES_DIR": str(repo / ".worktrees"),
            "SINGULAR_TARGET_BRANCH": "main",
        }
    )
    return env


def replay_run_statuses(
    root: Path,
    repo: Path,
    capture: dict[str, Any],
    env: dict[str, str],
) -> None:
    statuses = capture["runStatuses"]
    assert {status["phase"] for status in statuses} == PHASES
    assert len(statuses) == len(PHASES)
    for expected in statuses:
        command = [
            str(root / "engine" / "run-status.sh"),
            "write",
            "--run-id",
            expected["runId"],
            "--task-id",
            expected["taskId"],
            "--node",
            expected["node"],
            "--phase",
            expected["phase"],
            "--state",
            expected["state"],
            "--activity",
            expected["activity"],
            "--safe-cancel",
            str(expected["safeCancel"]).lower(),
            "--next-action",
            expected["nextAction"],
        ]
        if expected.get("processType"):
            command.extend(
                [
                    "--process-type",
                    expected["processType"],
                    "--pid",
                    str(expected["pid"]),
                    "--pgid",
                    str(expected["pgid"]),
                ]
            )
        if expected.get("outcome"):
            command.extend(["--outcome", expected["outcome"]])
        write_env = dict(env)
        write_env["SINGULAR_NOW"] = expected["at"]
        run(command, env=write_env)
        status_path = (
            repo
            / ".singular-state"
            / "runs"
            / expected["runId"]
            / "run-status.json"
        )
        actual = json.loads(status_path.read_text(encoding="utf-8"))
        assert actual["schema"] == STATUS_SCHEMA
        assert actual["runId"] == expected["runId"]
        assert actual["taskId"] == expected["taskId"]
        assert actual["node"] == expected["node"]
        assert actual["phase"] == expected["phase"]
        assert actual["state"] == expected["state"]
        assert actual["lastProgressAt"] == expected["at"]
        assert actual["safeCancel"] is expected["safeCancel"]
        if expected.get("processType"):
            assert actual["process"]["type"] == expected["processType"]
            assert actual["process"]["pid"] == expected["pid"]
            assert actual["process"]["pgid"] == expected["pgid"]
        if expected["phase"] == "terminal":
            assert actual["phaseFinishedAt"] == expected["at"]
            assert actual["outcome"] == expected["outcome"]


def descendants(dag: dict[str, Any], node_id: str) -> list[str]:
    reverse: dict[str, set[str]] = {}
    for node in dag["nodes"]:
        for dependency in node.get("dependsOn", []):
            reverse.setdefault(dependency, set()).add(node["id"])
    result: set[str] = set()
    queue = list(reverse.get(node_id, set()))
    while queue:
        current = queue.pop()
        if current in result:
            continue
        result.add(current)
        queue.extend(reverse.get(current, set()))
    return sorted(result)


def write_normal_gate(
    repo: Path,
    node: dict[str, Any],
    artifact: dict[str, Any],
) -> None:
    path = (
        repo
        / "docs"
        / "orchestration"
        / "gates"
        / f"{node['id']}.gate-result.json"
    )
    record = {
        "schema": GATE_SCHEMA,
        "node": node["id"],
        "status": "passed",
        "authoritative": True,
        "evidenceClass": "captured-artifact",
        "verificationClassification": "not-rerun-evidence-verified",
        "evidence": [
            {
                "kind": "source-path",
                "ref": artifact["ref"],
                "sha256": artifact["sha256"],
                "description": "hash-verified field-report replay artifact",
            }
        ],
        "decidedBy": "field-report-canary",
        "rationale": "Equivalent 26-node replay accepted the synthetic artifact.",
        "recordedAt": "2000-01-01T02:00:00Z",
    }
    path.write_text(
        json.dumps(record, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def approve_human_gate(
    root: Path,
    repo: Path,
    dag: dict[str, Any],
    node: dict[str, Any],
    artifact: dict[str, Any],
    env: dict[str, str],
) -> None:
    human = node["humanGate"]
    owner = f"{node['id']}@field-report.invalid"
    gate_id = f"{node['id']}-approval"
    request = [
        str(root / "engine" / "human_gate.py"),
        "request",
        "--repo",
        str(repo),
        "--node",
        node["id"],
        "--gate-id",
        gate_id,
        "--approval-type",
        "exact-artifact",
        "--owner",
        owner,
        "--expires-at",
        "2099-07-25T00:00:00Z",
        "--request-ref",
        human["requestRef"],
        "--question",
        "accept=Approve these exact synthetic bytes?",
        "--artifact",
        artifact["ref"],
        "--now",
        "2000-01-01T01:45:00Z",
    ]
    for blocked in descendants(dag, node["id"]):
        request.extend(["--blocked-node", blocked])
    run(request, env=env)

    approval = [
        str(root / "engine" / "human_gate.py"),
        "approve",
        "--repo",
        str(repo),
        "--node",
        node["id"],
        "--request-ref",
        human["requestRef"],
        "--approval-ref",
        human["approvalRef"],
        "--gate-result-ref",
        f"docs/orchestration/gates/{node['id']}.gate-result.json",
        "--approver",
        owner,
        "--decision",
        "approved",
        "--answer",
        "accept=approved",
        "--evidence",
        artifact["ref"],
        "--rationale",
        "Exact captured synthetic artifact approved for the bounded canary.",
        "--now",
        "2000-01-01T01:50:00Z",
    ]
    result = json.loads(run(approval, env=env))
    assert result["state"] == "approved"


def replay_graph(
    root: Path,
    repo: Path,
    capture: dict[str, Any],
    dag: dict[str, Any],
    env: dict[str, str],
) -> None:
    artifact_by_node = {
        artifact["node"]: artifact for artifact in capture["artifacts"]
    }
    dag_command = [str(root / "engine" / "dag.sh")]
    assert run(dag_command + ["validate-dag"], env=env) == "ok"

    initial = json.loads(run(dag_command + ["next-areas"], env=env))
    assert [entry["node"] for entry in initial["frontier"]] == [
        "node-00"
    ]

    replayed: list[str] = []
    for node in dag["nodes"]:
        node_id = node["id"]
        frontier = json.loads(
            run(dag_command + ["next-areas", "--explain"], env=env)
        )
        eligible = {entry["node"] for entry in frontier["frontier"]}
        if node.get("humanGate"):
            excluded = {
                entry["node"]: entry for entry in frontier.get("excluded", [])
            }
            assert excluded[node_id]["reason"] == "human-gate-pending"
            approve_human_gate(
                root,
                repo,
                dag,
                node,
                artifact_by_node[node_id],
                env,
            )
        else:
            assert node_id in eligible, (
                f"{node_id} was not eligible during synthetic replay: {frontier}"
            )
            write_normal_gate(repo, node, artifact_by_node[node_id])
        assert run(dag_command + ["area-gate", node_id], env=env) == (
            f"gate-passed node={node_id}"
        )
        replayed.append(node_id)

    assert replayed == [node["id"] for node in dag["nodes"]]
    final = json.loads(run(dag_command + ["next-areas"], env=env))
    assert final["frontier"] == []
    assert final["allComplete"] is True


def assert_health(
    root: Path,
    capture: dict[str, Any],
    env: dict[str, str],
) -> None:
    health = json.loads(
        run([str(root / "engine" / "ops.sh"), "health", "--json"], env=env)
    )
    assert health["gates"] == {"passed": 26, "total": 26}
    assert health["frontier"]["ready"] == 0

    expected_counts = capture["events"]["diagnosticCounts"]
    diagnostics = health["diagnostics"]
    assert set(diagnostics["counts"]) == DIAGNOSTIC_CATEGORIES
    assert diagnostics["counts"] == expected_counts
    assert diagnostics["total"] == capture["events"]["recordCount"]
    assert diagnostics["groups"] == capture["events"]["diagnosticGroups"]
    duplicate = next(
        item
        for item in diagnostics["items"]
        if item["dedupeKey"] == "capture:optional-mcp"
    )
    assert duplicate["count"] == 2

    lifecycle = health["lifecycle"]
    expected_active_phases = PHASES - {"terminal"}
    assert lifecycle["activeCount"] == len(expected_active_phases)
    assert set(lifecycle["phaseCounts"]) == expected_active_phases
    assert all(
        lifecycle["phaseCounts"][phase] == 1 for phase in expected_active_phases
    )
    auditor = next(
        item
        for item in lifecycle["active"]
        if item["phase"] == "auditing"
    )
    assert auditor["process"]["type"] == "auditor"
    assert auditor["process"]["pid"] == 900004

    human = health["humanGates"]
    assert human["total"] == human["approved"] == 3
    assert human["blocking"] == 0
    assert human["blockedNodes"] == []


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--capture", type=Path, required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    root = args.root.resolve()
    repo = args.repo.resolve()
    capture_path = args.capture.resolve()
    capture, dag, dag_path, _ = validate_and_materialize(capture_path, repo)
    env = engine_environment(root, repo, dag_path)
    replay_run_statuses(root, repo, capture, env)
    replay_graph(root, repo, capture, dag, env)
    assert_health(root, capture, env)
    print(
        "captured event/artifact replay passed: "
        "26/26 nodes, 8 lifecycle phases, 7 diagnostic categories"
    )


if __name__ == "__main__":
    main()
