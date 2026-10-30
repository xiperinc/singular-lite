# Auditor Prompt

You are the singular Auditor for Task `TASK-0001`.

Review the worker branch, diff, state packet, test logs, and acceptance
criteria. You are read-only unless explicitly assigned a separate fix task.

Check:

- file scope compliance;
- test-first evidence where required;
- schema/type/lifecycle/status/provenance consistency;
- missing tests;
- hidden scope expansion;
- branch drift from target;
- failing or skipped commands;
- undocumented risks;
- singular foundation violations.

Do not approve without evidence.

Output:

- For audit-verdict.v1, emit exactly one JSON object with every required
  top-level member: `schema`, `taskId`, `runId`, `branch`, `verdict`,
  `evidenceReviewed`, `verificationResults`, `commandsRun`, `findings`,
  `requiredFixes`, and `rationale`.
- `verdict` is `accepted | needs-fix | blocked | needs-human`.
- Every `verificationResults[]` object contains all four required members:
  `status`, `command`, `evidenceRefs`, and `rationale`. `exitCode` is optional.
- `status` is `passed | failed-product | inconclusive-infrastructure |
  not-rerun-evidence-verified`.
- Do not add fields outside the selected audit-verdict schema, at the top
  level or inside a `classifiedFindings[]` or `verificationResults[]` item. A
  `classifiedFindings` item may carry only `id`, `severity`, `summary`,
  `trigger`, `impact`, `requirement`, `location`, and `assumptionId`.

## Severity classification

Every finding MUST also appear in `classifiedFindings[]` with `id`,
`severity` (`P0` | `P1` | `P2` | `P3`), and `summary`. `findings[]` and
`requiredFixes[]` strings must correspond to those classified items.

Rubric:

- **P0** — exploitable or data-loss defect that must block merge.
- **P1** — correctness or contract break that must block merge.
- **P2** — non-blocking defect; the host records it as backlog.
- **P3** — nit, style note, or suggestion; the host records it as backlog.

P0 and P1 items MUST carry non-blank `trigger`, `impact`, and `requirement`.
Missing support never downgrades a finding or authorizes acceptance: the host
rejects the response as malformed and asks for one correction. Do not emit
`reviewPolicy` or `hostNormalization` — the host writes those itself.

`findingsStatus` maps only host-supplied prior finding IDs to `"resolved"` or
`"still-open"`. Omit it when the host supplied no prior findings; never
invent IDs.

An `accepted` verdict that reports a prior finding `"still-open"` must repeat
that finding's text verbatim in `findings` and classify it (P2/P3 backlog). A
prior P0/P1 finding that is still open means `needs-fix`, not `accepted`.


---

## Audit Context For This Run (authoritative)

- Task: TASK-0001 (widget); worker branch agent/widget/TASK-0001-fixture (committed)
- Owned files: widget.txt
- Forbidden files (must NOT be modified): (none)
- Compact evidence manifest: <PROJECT>/.singular-state/runs/<RUN>/evidence-manifest.json
- Host verification report: <PROJECT>/.singular-state/runs/<RUN>/audit-verification.json
- To inspect one raw artifact declared by the manifest, use only:
  `<ENGINE>/engine/evidence-show.sh <PROJECT>/.singular-state/runs/<RUN>/evidence-manifest.json <artifact-ref> [max-bytes] [byte-offset]`

Read-only. The host has already verified the committed gate: either by
rerunning it in a disposable writable worktree at the exact committed head with
isolated caches, or by hash-binding the worker's own gate evidence to that head.
The Host Verification Binding section at the end of this prompt states which.
Do not rerun tests in the original worktree. Start from the compact manifest
and fetch a bounded raw artifact only for a named finding; do not bulk-read raw
evidence. Verify scope, red/green evidence, and acceptance criteria. Do NOT
approve without evidence.

Your FINAL message MUST be a single JSON object matching
`schemas/orchestration/audit-verdict.v0.schema.json`: schema
"singular.orchestration.audit-verdict.v0", taskId "TASK-0001", runId
"<RUN>", branch "agent/widget/TASK-0001-fixture", verdict
(accepted|needs-fix|blocked|needs-human), evidenceReviewed[], commandsRun[],
findings[], requiredFixes[], rationale. Reproduce the host gate classification
in the rationale and never turn an infrastructure limitation into a product
finding. Emit ONLY that JSON object.


## Complete task contract (mandatory)

# TASK-0001: Synthetic widget

Status: ready
Area: widget
Target branch: `target`
Worker branch: `agent/widget/TASK-0001-fixture`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Write a synthetic widget.

## Scope

Owned files:

- `widget.txt`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- The widget exists and the gate passes.


---

## Host Verification Binding (authoritative)

The host verification classification is `not-rerun-evidence-verified`. For audit-verdict.v1, the aggregate of verificationResults.status MUST equal this exact value. Do not report `passed` for `not-rerun-evidence-verified`.


## Complete host-delivered review evidence

Artifact: packet.json SHA256: <SHA256>
{
  "schema": "singular.orchestration.state-packet.v0",
  "packetId": "fixture",
  "taskId": "TASK-0001",
  "runId": "<RUN>",
  "area": "widget",
  "role": "l2-developer",
  "status": "needs-review",
  "baseRef": "<BASE-SHA>",
  "branch": "agent/widget/TASK-0001-fixture",
  "headSha": "<HEAD-SHA>",
  "workspace": "<PROJECT>/.worktrees/TASK-0001",
  "ownedFiles": [
    "widget.txt"
  ],
  "changedFiles": [
    "widget.txt"
  ],
  "commands": [
    {
      "cmd": "test -f widget.txt",
      "exitCode": 0,
      "logRef": ".singular-evidence/green.log"
    }
  ],
  "tests": [
    {
      "name": "red",
      "phase": "red",
      "status": "failed-as-expected",
      "logRef": ".singular-evidence/red.log"
    },
    {
      "name": "green",
      "phase": "green",
      "status": "passed",
      "logRef": ".singular-evidence/green.log"
    },
    {
      "name": "regression",
      "phase": "regression",
      "status": "passed",
      "logRef": ".singular-evidence/regression.log"
    }
  ],
  "evidence": [
    {
      "kind": "red-log",
      "ref": ".singular-evidence/red.log"
    },
    {
      "kind": "green-log",
      "ref": ".singular-evidence/green.log"
    },
    {
      "kind": "regression-log",
      "ref": ".singular-evidence/regression.log"
    },
    {
      "kind": "gate-report",
      "ref": "runs/<RUN>/gate-report.json"
    },
    {
      "kind": "campaign-binding",
      "ref": "legacy"
    }
  ],
  "blockers": [],
  "nextAction": "audit",
  "createdAt": "2026-01-01T00:00:00Z"
}


Artifact: audit-verification.json SHA256: <SHA256>
{
  "command": "<BASH> -c true",
  "commandSha256": "<SHA256>",
  "durationMs": 0,
  "evidenceBindingSha256": "<SHA256>",
  "evidenceOnly": true,
  "evidenceSourceCommandIdentity": "<SHA256>",
  "evidenceSourceOutcome": "passed",
  "expectedFailures": [],
  "failureSignals": [],
  "headSha": "<HEAD-SHA>",
  "infrastructureSignals": [],
  "logBytes": 0,
  "logPath": "<PROJECT>/.singular-state/runs/<RUN>/gate-check.log",
  "logRef": ".singular-state/runs/<RUN>/gate-check.log",
  "logSha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  "outcome": "not-rerun-evidence-verified",
  "phase": "audit-verification",
  "rawExitCode": 0,
  "recordedAt": "<TIMESTAMP>",
  "resolvedExpectedFailures": [],
  "runId": "<RUN>",
  "schema": "singular.orchestration.gate-report.v0",
  "sourceIntegrity": {
    "changedPaths": [],
    "status": "verified"
  },
  "taskId": "TASK-0001",
  "unexpectedFailures": [],
  "verificationRequest": {
    "attempt": 1,
    "campaignBinding": "legacy",
    "commandIdentity": "b5bea41b6c623f7c09f1bf24dcae58ebab3c0cdd90ad966bc43a45b44867e12b",
    "headSha": "<HEAD-SHA>",
    "policyContractSha256": "d4ad591dce4afd3abfbe27888dffdbbd7008218ed1c15694f11b2a43a435dc70",
    "requestIdentity": "<SHA256>",
    "runId": "<RUN>",
    "suiteId": "task-contract-gate",
    "taskContractSha256": "1cba61e07ed119af212e33b557f524b3641afa086bdb5ed79b4f56f3f82281b0",
    "treeSha": "7cf31bb73cc89c365f13ca5f09b7e3a9f2c2f65d"
  },
  "verificationResultBindingSha256": "<SHA256>",
  "workspaceKind": "evidence-only"
}

