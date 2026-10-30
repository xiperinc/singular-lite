# Review policy

Programmable bound on how many times a logical change is reviewed, which
finding severities block acceptance, and how extra rounds are granted.

The engine module is `engine/review_policy.py`. Drive it with
`singular review-policy <verb>` (sources `lib.sh` so repo config is applied)
or `python3 engine/review_policy.py <verb>`.

## Settings

`reviewPolicy` in `singular.config.json`:

```json
{
  "version": 1,
  "maxReviewRounds": 2,
  "blockingSeverities": ["P0", "P1"],
  "requireClassification": true,
  "supersessionExtraRounds": 1,
  "maxSupersessionExtensions": 2
}
```

| Field | Default | Meaning |
| --- | --- | --- |
| `version` | `1` | Policy schema version. |
| `maxReviewRounds` | `2` | Base allowance of completed schema-valid verdicts per logical change and series: the initial review plus one follow-up, before extensions or exceptions. Product repairs have a separate risk-tier ceiling; a high-risk task can spend two repairs under this default if earlier passes failed the gate without recording reviews. |
| `blockingSeverities` | `["P0","P1"]` | Severities that block acceptance. P0 and P1 are a floor: a value may add `P2`/`P3` but a set without P0 or P1 is refused (exit 2). |
| `supersessionExtraRounds` | `1` | Rounds added to a review unit's budget each time the engine registers a successor task (`Supersedes:`) in it. `0` disables the extension. |
| `maxSupersessionExtensions` | `2` | How many supersessions per series may extend the budget. Later successors share what is left. `0` restores the strict cap. |
| `requireClassification` | `true` | Missing `classifiedFindings` fail-safe: findings stay blocking. `false` only lets a verdict with no classification keep its own label; it never upgrades `needs-fix`. |

### Precedence

Environment overrides win over JSON; defaults last. Invalid values are a hard
error (exit 2) and are never silently defaulted.

| Env | JSON | Notes |
| --- | --- | --- |
| `SINGULAR_REVIEW_MAX_ROUNDS` | `maxReviewRounds` | Integer `>= 1`. |
| `SINGULAR_REVIEW_BLOCKING_SEVERITIES` | `blockingSeverities` | Comma list from `P0,P1,P2,P3`; must include `P0,P1`. |
| `SINGULAR_REVIEW_REQUIRE_CLASSIFICATION` | `requireClassification` | `0` or `1`. |
| `SINGULAR_REVIEW_SUPERSESSION_EXTRA_ROUNDS` | `supersessionExtraRounds` | Integer `>= 0`. |
| `SINGULAR_REVIEW_MAX_SUPERSESSION_EXTENSIONS` | `maxSupersessionExtensions` | Integer `>= 0`. |

`lib.sh` also projects the JSON object to `SINGULAR_REVIEW_POLICY_JSON` so a
frozen campaign pins it. A broken policy refuses the drive before paid work.

Inspect the resolved policy with `singular review-policy effective`.

## Logical change and lanes

The logical change (the **review unit**) of a native task is its
**supersession chain**, keyed by the chain's root task id. `resolve` computes
it and the L1 driver calls it once before any paid work:

- A task with no predecessor is its own unit. Two tasks a planner issues for
  one DAG node in the same batch each get their own series: the acceptance of
  one neither closes nor charges the other.
- A task whose `Supersedes:` header names a published task record joins that
  task's unit. The chain shares **one** budget. Each supersession the engine
  registers extends it by `supersessionExtraRounds`, for at most
  `maxSupersessionExtensions` supersessions per series, so a replacement the
  planner issued for an exhausted task can be reviewed, and a chain of
  replacements can never mint an unlimited budget. With the defaults a chain
  gets 2, then 3, then 4 rounds, and stays at 4. A header naming a task that
  has no record is ignored. Registration is idempotent.
- The duplicate guard, not the review ledger, is what stops a second
  non-superseding task for the same node and files from being published.

Until 0.23.6 the id was `dagNode` when non-empty. Those node-keyed entries stay
valid: a chain that already has rounds or operations in its node's entry keeps
using it (used rounds are not reset by the upgrade, and a successor registered
there gets the same bounded extension), unless a task outside the chain closed
that entry, in which case the chain starts its own unit. A task with nothing
in the node's entry gets its own unit.

Maintenance lanes pass an explicit id such as `maintenance:<slug>`.

Native L1 drives record `--lane native`. Maintenance and consultant lanes use
the same ledger; they are bounded by the same `maxReviewRounds` plus any
exception whose `taskId` is null or equals the current task.

## Rounds and budget

A **round** is one completed schema-valid verdict for a candidate of the
logical change. The first is `initial`; later ones are `followup`.

Each review is one **operation**. The L1 driver calls `reserve` before the
auditor launches: under the ledger write lock it admits the review (or refuses,
exit 4) and records a reserved operation bound to
logicalChange/task/run/attempt/head. A reserved operation holds its slot, so two
concurrent reservations can never both take the last one. Auditor transport
retries stay inside that one operation; `record --operation` completes it
exactly once. A replay with the same verdict content (raw or as applied) is a
no-op returning the stored result; different content is a conflict (exit 5).
An operation that ends without a verdict is `release`d; a new reservation by
the same task also supersedes that task's unfinished one. `record` without
`--operation` admits and completes in one locked step and refuses (exit 4,
nothing written, verdict file untouched) at the ceiling. The ledger is
committed before `--apply` rewrites the verdict.

Rounds belong to a numbered **series** (default 1). An `accepted` round
**closes** the logical change: `check`/`reserve`/`record` then refuse (exit 4,
`closed: true`) instead of minting a fresh budget for a successor task, new
run, or renamed node. Re-recording the same accepted operation stays
idempotent. A genuinely new review series needs
`reopen --authority --reason --evidence` (evidence hashed; one authority opens
at most one series). The driver uses this for an authorized repair recovery of
an accepted candidate (`recoveryAuthorization`, which requires a fresh audit),
with the recovery authority as evidence. Accepted-evidence recovery publishes
without a new audit and never needs it.

**Infrastructure outcomes are not rounds.** An audit that ends without a
schema-valid verdict never records one (`release`). A round that was recorded
and then could not be used for a reason that is not the product's (the
verdict could not be applied, the evidence writer failed after a non-accepted
verdict, host verification was inconclusive) is voided by the driver with
`void`: the row stays in the ledger with a `voided` member, does not count
toward the budget and cannot close the unit (`review.round_voided`).

Allowed rounds = `maxReviewRounds` + the supersession extension + the sum of
`additionalRounds` on exceptions granted in the current series whose `taskId` is null or equals the
current task. Rounds used in a series never decrease, so a consumed exception
cannot be consumed again. `check` (read-only) refuses when
`used + pending >= allowed` (exit 4), where pending counts other tasks'
reserved operations.

**Migration.** Rows written before series existed have no `series` member and
keep the old rule: a legacy `accepted` row is a series boundary (later rounds
start a fresh budget, as before), so existing ledgers neither become exhausted
nor closed. Legacy non-accepted rows after the last legacy acceptance count
toward series 1; a legacy exception applies only if granted after that
acceptance. `backfill` rows are legacy rows. A malformed ledger is an error
(exit 3), never a reset.

The L1 driver does not clamp product repairs to `maxReviewRounds - 1`; the
repair ceiling is `min(risk-tier repairs, SINGULAR_MAX_RETRIES)`. Instead it
runs a read-only `check` before every product pass (the initial pass and each
repair, before the repair is charged or a decider is consulted), so no worker
is started for a candidate that could never be reviewed. Exhaustion is terminal:
`escalate-parked` with `terminal_authority=policy`, failure class
`review-rounds-exhausted`. It does not consume product repair budget and does
not call the decider.

### Unparking and the two budgets

`singular unpark TASK-1234` restores the task's product-repair budget: the lease's
`retryCount` becomes `0` and `productPassStarted` becomes `false`. It does not
restore review rounds or modify the review ledger. An exhausted review unit
therefore stays exhausted, and an accepted unit stays closed; unparking alone
cannot admit another product pass in either case. Additional review capacity
requires a policy action such as `grant` for an exhausted open unit or `reopen`
for a closed one, with the authority, reason and evidence described below.

## Severities

`classifiedFindings[]` items: required `id`, `severity` (`P0`..`P3`),
`summary`; optional `trigger`, `impact`, `requirement`, `location`,
`assumptionId` (the assumption-ledger id the finding reports as violated).
Any other property inside an item is dropped by the host before validation and
recorded in `hostNormalization.droppedFields`; it never fails the verdict.

Classification is fail-closed and applies to **every** verdict label:

- Severity is immutable. A P0/P1 missing non-blank `trigger`, `impact` or
  `requirement` stays P0/P1 and blocking (`unsupported`, reason
  `unsupported-blocking-claim`); `downgraded` is always empty.
- Coverage is exact. Every non-blank `findings[]`/`requiredFixes[]` string must
  equal a classified item's `summary`, or start with its `id` as a whole token,
  optionally followed by `(Pn)`, then `:`, a spaced dash, or the end
  (`F1: ...`, `F1 (P2): ...`). Bracketed reference tags next to the id are
  skipped (`F1 (P3) [A3]: ...`); they name no item and carry no severity. Uncovered strings become blocking
  `unclassified-N` items (`classification-incomplete`). A `(Pn)` tag that
  disagrees with the item's severity is a conflict.
- Malformed entries (`classification-malformed`) and ids repeated with
  differing content (`classification-conflict`) are unresolved and block.

| Original verdict | Effective verdict |
| --- | --- |
| `needs-fix`, completely classified, only non-blocking items | `accepted`; items go to the backlog |
| `needs-fix`, anything blocking, unresolved, or uncovered | `needs-fix` |
| `accepted`, anything blocking, unresolved, or uncovered | `needs-fix` (`.pre-policy.json` keeps the label) |
| `accepted`, no findings, or every finding covered by non-blocking items | `accepted` |
| `needs-fix`/`accepted` (v1) with findings but no `classifiedFindings` | `needs-fix`, reason `classification-missing` |
| `blocked`, `needs-human`, other | unchanged; never `accepted` |
| legacy `audit-verdict.v0` without `classifiedFindings` (its schema cannot carry one) | the auditor's label; never upgraded |

`record --host-verification failed-product` keeps an `accepted` label from
closing the change (effective `needs-fix`).

### Prior findings on an accepted verdict

A follow-up review reports each host-supplied prior finding as `resolved` or
`still-open` in `findingsStatus`. An `accepted` verdict may leave one
`still-open` only if the finding is classified in that verdict. When the
auditor did not repeat the finding's text, the host completes the verdict
before validation instead of asking for another auditor pass. It looks the
finding up in the run's findings ledger (`findings-status.json`) and in the
review round that last reported it (`review-policy-attempt-<n>.json`):

| Recorded severity of the still-open prior | Host action | Outcome |
| --- | --- | --- |
| non-blocking under the effective policy (default P2/P3) | text appended to `findings`, classified at the recorded severity | `accepted`; the item goes to the backlog |
| blocking (P0/P1, or a severity added to `blockingSeverities`) | text appended to `requiredFixes` with a classified item at the recorded severity and its recorded support | `needs-fix`, reason `blocking-finding` |
| not established (no ledger entry, no round record, unclassified or tag-conflicting in that round) | nothing is carried | refused as an auditor-format failure naming the id |

Each carried finding is listed in `hostNormalization.carriedPriorFindings`
(`id`, `severity`, `disposition`, `classifiedAs`, `source`, `reason`).

## Exceptions

`singular review-policy grant --logical-change ID --rounds N --reason TEXT --evidence PATH... --authority NAME [--task TASK]`

Grant refuses when:

- an active (unconsumed) exception already exists for that logical change
- `additionalRounds > maxReviewRounds`
- reason or evidence is missing
- the logical change is closed (use `reopen`)

Evidence paths are hashed at grant time. A second grant before the extra
rounds are spent is refused. Historical rounds added with `backfill` count
toward `used`.

## Ledger and backlog

- Ledger: `$SINGULAR_STATE_DIR/review-policy/ledger.json`, schema
  `singular.review-policy.ledger.v1`, atomic write under `fcntl` lock file
  `ledger.lock`.
- A unit entry may carry `unit: "task"`, `dagNode`, `chain` (member task ids)
  and `supersessions` (`from`, `to`, `series`, `registeredAt`). All are
  optional; an entry without them reads as before.
- Backlog: `$SINGULAR_STATE_DIR/review-policy/backlog.ndjson` (one JSON line
  per non-blocking item).

Statuses: `open`, `accepted` (closed, or a legacy boundary), `exhausted`.
Operation statuses: `reserved`, `completed`, `infrastructure-exhausted`,
`abandoned`.

## CLI

```text
singular review-policy effective
singular review-policy show [--logical-change ID]
singular review-policy check --logical-change ID --task TASK
singular review-policy reserve --logical-change ID --task TASK --run RUN \
  --attempt N --head SHA [--campaign BINDING] [--lane native]
singular review-policy record --logical-change ID --task TASK --run RUN \
  --attempt N --verdict PATH --head SHA [--campaign BINDING] [--lane native] \
  [--reviewer-runner NAME] [--reviewer-model M] [--reviewer-effort E] \
  [--operation OP] [--host-verification STATUS] [--apply]
singular review-policy release --logical-change ID --operation OP --reason TEXT \
  [--status infrastructure-exhausted|abandoned]
singular review-policy void --logical-change ID --operation OP --reason TEXT
singular review-policy resolve --task TASK [--dag-node NODE] [--tasks-dir DIR] [--dry-run]
singular review-policy reopen --logical-change ID --reason TEXT \
  --evidence PATH... --authority NAME [--task TASK] [--if-closed]
singular review-policy grant --logical-change ID --rounds N --reason TEXT \
  --evidence PATH... [--task TASK] --authority NAME
singular review-policy backfill --file PATH
singular review-policy backlog [--logical-change ID]
```

Exit codes: `0` ok, `2` usage/invalid config, `3` ledger/IO error or
malformed ledger, `4` admission refused (exhausted or closed; `check`,
`reserve`, `record`; the refusal JSON is on stdout), `5` operation conflict.
JSON on stdout. Never prints secrets.

`--apply` writes `<verdict>.pre-policy.json` if anything changes and sets
`verdict` to the effective verdict. The top-level `reviewPolicy` stamp is
added only to `audit-verdict.v1` documents; legacy v0 verdicts are left
without it (their schema forbids unknown members) and the round record
`review-policy-attempt-<n>.json` carries the classification instead.

## Compatibility

Old `audit-verdict.v1` documents without `classifiedFindings` or
`reviewPolicy` keep validating (`additionalProperties` remains false; the new
members are optional). Host identity binding still requires
`verdict == accepted` at acceptance edges; the host applies policy before
that read, so a P2-only `needs-fix` can become `accepted` without a second
auditor launch.

The completed round is conjunct `D` of the acceptance rule, and the classified
verdict is conjunct `A`. With `SINGULAR_ACCEPTANCE=every-path` both are checked
again at import, integration and recovery; see
[acceptance.md](acceptance.md).
