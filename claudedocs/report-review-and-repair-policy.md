# Review and repair policy — architectural report

**Audited 2026-09-16 against the live tree** (`codex/brain-integration`, engine 0.23.2):
`engine/review_policy.py` (1,191 lines), `engine/l1-drive.sh`, `engine/task_lifecycle.py`,
`.singular-state/campaign-policy/rescue-20260910/config-A16.json`, and the durable
ledger `.singular-state/review-policy/ledger.json` (9 logical changes, 19 recorded
rounds, 4 exceptions) plus `backlog.ndjson` (33 non-blocking items). Behavioural
claims below were reproduced by calling the policy module directly, not inferred
from reading.

---

## 1. Two budgets, one clamp

The engine runs **two independent budgets** on every dispatch, and they are not the
same mechanism at different scales.

| | Review policy | Worker repair policy |
|---|---|---|
| Owner | `engine/review_policy.py` | `engine/l1-drive.sh` |
| Counts | completed, schema-valid auditor verdicts | implement→gate→audit passes |
| Key | **logical change** (`dagNode`, else `taskId`) | **lease** (`taskId`) |
| Durable in | `.singular-state/review-policy/ledger.json` | the lease `retryCount` |
| Default | `maxReviewRounds: 2`, blocking `P0,P1` | `productRepairMax` 1 (normal) / 2 (high) |
| Survives the task | yes — spans successors on the same node | no — per lease |

They meet at exactly one line in the driver. After the risk tier is resolved, the
repair budget is clamped to `maxReviewRounds - 1` and the clamp is recorded as
`l1.review_policy_bound`:

```
review_bound=$((review_max_rounds - 1))
[[ "$max_retries" -gt "$review_bound" ]] && max_retries="$review_bound"
```

The rationale is sound — a repair you may never have reviewed is not a repair — but
the arithmetic has a consequence nobody configured on purpose. With the shipped
`maxReviewRounds: 2`, the clamp is 1, so a **`Risk tier: high` task gets the same one
repair as a normal task**. Its risk-derived ceiling of 2 is unreachable. All 18
`l1.review_policy_bound` events in this campaign show the same pair: `maxReviewRounds 2,
productRepairMax 1`, for normal and high tiers alike.

**Interaction on failure.** A `gate-red` or `audit-needs-fix` outcome consumes repair
budget; an `audit-infra`, `worker-infra` or provider timeout does not — those draw on
separate single-retry infrastructure domains. The review round is consumed later and
by a different gate: the driver calls `review_policy.py check` *before* launching the
auditor (exit 4 → `review-rounds-exhausted`, no paid call) and `record` only *after* a
parsed, host-validated verdict. **A failed audit transport therefore costs nothing in
either ledger.** That separation held through six session-limit and timeout events in
this campaign with no phantom rounds recorded.

---

## 2. What is programmable, and in what order

Precedence is strict and each layer is validated, never silently defaulted — an
invalid value is a hard exit 2, and the driver refuses to spend money on a run whose
policy will not load.

```
code defaults          maxReviewRounds 2, blocking [P0,P1], requireClassification true
   ↓  overridden by
campaign config        config-A16.json .reviewPolicy
                       → projected by lib.sh into SINGULAR_REVIEW_POLICY_JSON
                       → pinned in the campaign manifest
   ↓  overridden by
repo config file       $SINGULAR_JSON_CONFIG_FILE or $SINGULAR_ROOT/singular.config.json
                       (read ONLY when the env JSON above is absent)
   ↓  overridden by
per-field env          SINGULAR_REVIEW_MAX_ROUNDS
                       SINGULAR_REVIEW_BLOCKING_SEVERITIES
                       SINGULAR_REVIEW_REQUIRE_CLASSIFICATION
   ↓  extended by
CLI exception grants   review_policy.py grant --rounds --reason --evidence --authority [--task]
```

`effective` prints the resolved policy with a `sources` map naming the winning layer
per field, which is what makes this auditable at dispatch time.

The repair side has its own, **different** chain, resolved inline in the driver:

```
operator env SINGULAR_TASK_RISK_TIER
  → task contract "Risk tier:" header
    → SINGULAR_DEFAULT_RISK_TIER
      → singular.config.json .retryPolicy.defaultRiskTier
        → "normal"
```
with an unknown value failing **safe to high** (stricter), and `SINGULAR_MAX_RETRIES`
able only to lower, never raise, the risk-derived ceiling.

**The asymmetry that matters:** the task contract is a first-class input to the repair
budget and has **no input at all** to the review budget. A task author can change the
repair tier by editing one markdown line; raising review rounds requires a CLI grant
carrying `--authority` and at least one hashed evidence file. That is the right
direction of privilege, and it is worth stating explicitly because the two headers sit
three lines apart in the same contract file.

---

## 3. The ledger holds the line across successors

The ledger keys on the **logical change**, not the task, which is what let review
history survive three task supersessions in this campaign. `memory-lifecycle` carries
rounds from TASK-1105 (×2, backfilled as historical) and TASK-1117 (×1), and both the
consumed and the never-used exception remain recorded:

```
memory-lifecycle   status=accepted  rounds=3  exceptions=2
  1  TASK-1105  needs-fix  (historical)
  2  TASK-1105  needs-fix  (historical)
  3  TASK-1117  accepted
  exc-cc6aba1a1be9  +2  bound TASK-1116   (authorized, never used)
  exc-68487d55c6f8  +2  bound TASK-1117   (the migration)
```

Writes are `fcntl`-locked and atomic; read verbs take a shared lock, create nothing,
and leave `updatedAt` meaning "last recorded change". Exceptions are task-bound by
default, so the TASK-1116 and TASK-1117 grants above could never combine — the
migration ceremony the supervisor performed was enforced, not merely observed.

**Can a task reset its budget by renaming or by an unlinked branch?**

- **Branch: no.** The branch name appears in no key. Renaming or recreating a worker
  branch has zero effect on the ledger.
- **Task id: no, if the contract declares a DAG node.** The successor inherits the
  node's full history. Verified live: `invocation-envelope` holds both TASK-1115 rounds.
- **DAG node: yes.** `logical_change_id()` falls back to `taskId` when `dagNode` is
  blank. Deleting or retyping the `DAG node:` line in a task contract mints a fresh
  budget under a new key, silently, with no grant and no authority. This is the one
  real reset vector, and it lives in the least-privileged file in the system.
- **`unpark`: partially, by design.** It resets `retryCount` to 0 and clears
  `productPassStarted`, restoring the repair budget, and does **not** touch the review
  ledger. Operator re-entry buys worker passes, never review rounds. That asymmetry is
  correct but undocumented in the contract; it is why the TASK-1115 round-2 correction
  still had to fit inside the original allowance.

One further behaviour is deliberate and should be understood before the next campaign:
`_open_round_count()` **resets the count to zero at every accepted verdict**. An
accepted candidate closes; a later dispatch of the same node starts fresh at 2. Live
example, `maintenance:a12-engine-boundary`, needs-fix → accepted → needs-fix, currently
reads `used 1, allowed 2, status open`. This is the intended "acceptance closes the
candidate" rule, but it means the ceiling is per-candidate, not per-node, and a node
that alternates accept/needs-fix has no cumulative bound at all.

---

## 4. Where it is correct, and the three traps

**Working exactly as intended.** Round accounting is honest and cheap: five
`review.policy_applied` events for five real verdicts, zero rounds burned by the six
infra failures. Fail-closed classification works — a `needs-fix` verdict with prose
findings and no `classifiedFindings` synthesises `unclassified-N` items that are
**blocking**, so an auditor cannot escape a fix by skipping the taxonomy. P2/P3 are
diverted to `backlog.ndjson` (33 items, including the four TASK-1115 and TASK-1114
residuals) rather than blocking a merge, and the reviewer's runner, model and effort
are stamped into every round, which is what made the campaign's provenance claims
checkable afterwards. The pre-audit `check` gate is the single best design decision
here: exhaustion is discovered before the money is spent.

**Trap 1 — a genuine P0 can be auto-downgraded into an acceptance.** `classify()`
requires `trigger`, `impact` **and** `requirement` to be non-blank on any P0/P1, and
demotes to P2 otherwise. The audit-verdict v1 schema requires only `id`, `severity`,
`summary`; the three supporting fields are optional. So a **schema-valid** verdict is
reachable in which the auditor reports a real P0 and the host converts the run to
`accepted`. Reproduced against the live module:

```
input : verdict=needs-fix, F1 severity=P0, summary + trigger + impact, no requirement
output: effectiveVerdict = accepted   downgraded = [F1]   applied = true
```

Nothing blocks; the round is recorded as accepted; integration proceeds. The rule is
defensible as an anti-inflation measure, but "the claim is unsupported" and "the
verdict is now accepted" should not be the same branch. No downgrade fired in this
campaign (`downgraded: []` on all five rounds), so this is latent, not historical.

**Trap 2 — legacy verdicts validate in warn mode.** `SINGULAR_AUDIT_VERDICT_VALIDATE`
defaults to `warn`. A v1 verdict is always fail-closed, but a v0 or legacy-schema
verdict that fails host schema validation emits `l1.audit_verdict_warned` and
**proceeds to be recorded and to influence acceptance**. Campaign A16 is `schemaVersion
v2` → v1 contract, so it was not exposed; a consumer repo still on v0 is.

**Trap 3 — schema failures never reach the review budget at all.** A packet or verdict
that cannot be parsed is an infra class, so it consumes worker-repair budget while the
review ledger stays untouched. This is the TASK-1114 failure in one sentence: a
complete, later-clean candidate spent its entire product budget on two missing
`createdAt` fields and parked, having never been reviewed once. The 0.23.0 `createdAt`
default and the structural repair pass address the two known shapes; the structural
gap — a format slip billed to the product budget — is still open. Related: worker
timeout and review timeout are different clocks with no shared ceiling, which is how
TASK-1114 consumed two hours against a one-hour clock before any policy noticed.

---

## 5. Three minimal changes to make this turnkey

1. **Never let a downgrade manufacture an acceptance.** In `classify()`, when
   `downgraded` is non-empty and no blocking item remains, set `effectiveVerdict` to
   `needs-human` (already a valid verdict) instead of `accepted`. Roughly four lines,
   no schema change, no new state. Alternatively — or additionally — make `trigger`,
   `impact` and `requirement` `required` in the v1 schema for items whose severity is
   P0 or P1, which moves the failure to the auditor's own retry loop where it belongs.

2. **Make the logical-change key non-forgeable.** Require `DAG node:` in any contract
   that declares a `Target branch:`, and refuse dispatch when it is absent rather than
   falling back to `taskId`. Where a successor legitimately needs a new node, that is
   already what `grant --authority` is for. This closes the only budget-reset vector a
   task author can reach unaided.

3. **Give a format slip its own budget.** Classify `packet-invalid` and
   `worker-no-packet` on an *unchanged* candidate as an infrastructure domain with its
   own single retry, rather than charging the product-repair budget. The park rule
   added in 0.22.0 already grants one re-emit; this makes the accounting match the
   intent, and it is the change that would have saved TASK-1114 outright.

A fourth, optional: flip `SINGULAR_AUDIT_VERDICT_VALIDATE` to `strict` by default and
keep `warn` as the explicit opt-out for v0 consumers. And note the coupling in §1 —
if high-risk tasks are meant to get two repairs, `maxReviewRounds` must be raised to 3,
because today the clamp silently erases the distinction.

---

### Verification note

Every behavioural claim in §3 and §4 was reproduced by importing
`engine/review_policy.py` and calling `classify()` / `allowed_rounds()` /
`logical_change_id()` against the live module on 2026-09-16. Counts come from
`ledger.json`, `backlog.ndjson` and `.singular-state/events.ndjson`. The A16 runtime is
frozen and carries the pre-0.23.2 campaign-drift check; any campaign adopting the
recommendations above must be built from a runtime at 0.23.2 or later.
