# Context graph: event mapping and evidence contract

This is the companion to `schemas/context-graph.v0.schema.json` and the
projector in `engine/ctx-graph.sh`, exposed through `singular graph` only when
`SINGULAR_CTX_GRAPH=1`. With the flag unset or disabled, the CLI does not expose
the command.
It maps durable records and events to node and edge types, and distinguishes
**`authoritative`** host evidence from model-authored **`claim`** records.

The graph is a pure projection: derived from the event log, decision records,
gate results, critiques, and ledgers; rebuildable from scratch; never authored
directly by a model. The system stays recoverable with the graph deleted.

## Evidence-class rule (fail-closed)

`evidenceClass` is exactly one of `authoritative | claim`.

- **`authoritative`** — HOST-verified records only: git `commit` refs, `gate-result`
  records, and the host `secret-scan` / `scope-check` scan outcomes. These are
  facts the host produced or checked mechanically, not statements a model made.
- **`claim`** — EVERY model-authored statement: plan batches, plan versions,
  critiques, findings, assumptions, audit verdicts (the auditor is itself a
  model — an `audit-verdict` node is a **claim**, never authoritative),
  routing/`decision` records, and capsules.

When in doubt a record is a `claim`. Only the three host-verified families above
may ever be minted `authoritative`.

Every node additionally carries `provenance` (`sourcePath` + `contentHash`), so
each projected line is traceable to the exact source record and a rebuild can
verify byte-identity. `contentHash` is a `sha256:` digest of the canonical
source content; stable ids (`n-…` / `e-…`) are hashes of source-record identity.

## Node taxonomy → source

| Node type | evidenceClass | Projected from (source record/event) |
|-----------|---------------|--------------------------------------------|
| `goal` | `claim` | The operator/planner objective record (`docs/orchestration/goal.md`, DAG root). |
| `plan-batch` | `claim` | A planner batch — planner `session-meta` + the staged candidate task set. |
| `plan-version` | `claim` | Each planner revision — `plan.revised` event, `revisesRunId` links versions. |
| `critique` | `claim` | A `plan-critique` record + `plan.critiqued` event. |
| `finding` | `claim` | A `findings[]` entry inside a `plan-critique` record, keyed by `singular_finding_id`. |
| `assumption` | `claim` | An assumption ledger entry / `context packet` `Assumptions` line. |
| `task` | `claim` | An imported task record (`docs/orchestration/tasks/TASK-*.md`). |
| `attempt` | `claim` | A worker attempt row in `attempts/index.json`. |
| `commit` | **`authoritative`** | A git `commit` produced by the L1 driver — host fact. |
| `gate-result` | **`authoritative`** | A `gate-result` record (host-decided gate). |
| `audit` | `claim` | An `audit-verdict` / paired-audit record (`ctx.paired_audit`). Auditor is a model → claim. |
| `decision` | `claim` | A routing `context.strategy_selected` decision or `ctx.critic_recheck` disposition. |
| `capsule` | `claim` | An implementer/reviewer `capsule` record. |

> `secret-scan` and `scope-check` outcomes are host-verified: when a scan gates a
> record they surface as an **`authoritative`** `gate-result` node; a
> `ctx.artifact_secret` quarantine event marks the affected source excluded from
> projection (a quarantined artifact is never projected as a live node).

## Edge taxonomy → source

| Edge type | Meaning | Projected from |
|-----------|---------|----------------|
| `depends_on` | task depends on prerequisite | DAG edges (`docs/orchestration/dag.v0.json`) / batch `depends_on`. |
| `derived_from` | node derived from an upstream node | `plan-batch` ← `goal`; `session-meta` lineage anchor. |
| `revises` | a plan version revises the prior | `plan.revised` event `revisesRunId`. |
| `critiques` | a critique targets a plan version | `plan.critiqued` event, critique → plan-version. |
| `accepts_observation` | a revision accepted a finding | `accepted-observation` disposition on `plan.revised`. |
| `rejects_observation` | a revision rejected a finding | `rejected-observation` disposition on `plan.revised`. |
| `implements` | an attempt implements a task | `attempts/index.json` attempt → task. |
| `verifies` | a gate/audit verifies an attempt | `gate-result` / paired `audit-verdict` → attempt. |
| `contradicts` | two records disagree | paired-audit disagreement (`ctx.paired_audit`) / critic recheck `survives`. |
| `invalidates` | a host result invalidates a prior claim | a failed `gate-result` invalidating an attempt/claim. |
| `supersedes` | a newer version supersedes an older | successive `plan.revised` versions; resolution of a contradiction. |

## Durable record/event coverage (every source is mapped)

Every durable record/event type below projects to at least one node/edge above.
The contract test (`tests/test-context-graph-schema.sh`) asserts each of these
strings is named in this document, so no durable source is left unprojected.

### baseline & instrumentation
- `ctx.arm_assigned` — A/B arm assignment at dispatch → recorded on the `attempt` node.
- `ctx.paired_audit` — paired-audit record (`paired-audit.json`) → `audit` node (`claim`) + `verifies`/`contradicts` edge.
- `attempts/index.json` — per-attempt rows → `attempt` nodes + `implements` edges.
- `gate-result` — host gate outcome → `gate-result` node (**`authoritative`**) + `verifies`/`invalidates` edge.
- `audit-verdict` — implementation-auditor verdict → `audit` node (`claim`).
- `commit` — git commit produced by the driver → `commit` node (**`authoritative`**).
- `secret-scan` — host secret scan → **`authoritative`** gate outcome; a hit yields `ctx.artifact_secret` quarantine.
- `scope-check` — host owned-file scope check → **`authoritative`** gate outcome.

### planner session persistence
- `session-meta` — planner `session-meta.v0` per node → `plan-batch` node (`claim`) + `derived_from` edge to `goal`.
- `context.strategy_selected` — planner routing decision → `decision` node (`claim`).

### first-class plan critique
- `plan-critique` — critic record (`plan-critique.v0`) → `critique` node + `finding` nodes + `critiques` edge.
- `plan.critiqued` — critique event (verdict + finding count) → `critiques` edge.
- `ctx.plan_critique_infra` — critic infra-failure telemetry (harness/model error, no verdict produced) → `telemetry — not projected`.
- `ctx.plan_critique_retry` — critic retry telemetry (transient re-attempt before a verdict) → `telemetry — not projected`.

### in-lineage plan revision
- `plan.revised` — revision event (`revisesRunId`) → `plan-version` node + `revises`/`supersedes` edges.
- `plan.revise_parked` — bounded-revise park outcome (revise budget exhausted, no accepted version) → `decision` node (`claim`); sibling of `plan.revised`, records the park disposition rather than a new plan version.
- `accepted-observation` — per-finding disposition → `accepts_observation` edge.
- `rejected-observation` — per-finding disposition → `rejects_observation` edge.
- `ctx.critic_recheck` — post-acceptance critic recheck → `decision` node; `survives` → `contradicts` edge.

### rich context packets
- `context packet` — task-markdown `## Context packet` block → `assumption` nodes (open/validated/violated) + decisions.
- `assumption ledger` — per-run ledger carried across attempts → `assumption` node status; a violation → `contradicts` edge.
- `capsule` — implementer/reviewer capsule per attempt → `capsule` node (`claim`).
- `ctx.artifact_secret` — secret-scan quarantine → source excluded from projection (never a live node).
- `ctx.packet_malformed` — context-packet parse-failure telemetry (a `## Context packet` block that failed to parse) → `telemetry — not projected`; no assumption/decision node is minted from an unparseable packet.

### explicit session routing & rehydration
- `context.strategy_selected` — routing strategy + reason (`continue|resume|fork|fresh|rehydrate`), taint flag → `decision` node (`claim`).
- `context.resume_failed` — routing resume-refused decision (resume declined → fell back to fork/fresh) → `decision` node (`claim`); sibling of `context.strategy_selected`, records the refused-resume disposition.
- `rehydrate` — rehydration packet manifest (which artifacts, which hashes) → `derived_from` edges from the rehydrated attempt to each source node.
- `decision record` — a durable routing/decision record → `decision` node (`claim`).
- `decision.recorded` — the canonical durable decision-record event (`engine/record-decision.sh`) → `decision` node (`claim`); the emitted event string behind every `decision record`.

## Invariant

Projection never changes what counts as evidence. An `authoritative` node exists
only where the host verified the fact (`commit`, `gate-result`, `secret-scan` /
`scope-check`); every model-authored record — including every `audit-verdict` —
is a `claim`. Deleting `.singular-state/graph/` and rebuilding from durable sources
must reproduce a byte-identical corpus.
