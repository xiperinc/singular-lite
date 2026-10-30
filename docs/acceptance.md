# Acceptance on every path

The engine publishes a candidate as accepted only when one rule holds for that
exact candidate: its task, run, branch, head, tree and campaign. The rule is
`engine/acceptance_validator.py`. By default only the driver applies it, at the
moment it publishes. `SINGULAR_ACCEPTANCE=every-path` makes the other places
that move an accepted candidate forward apply the same rule as well: packet
import, integration, `singular accept-packet`, and recovery.

## Setting

| Setting | Default | Values and meaning |
| --- | --- | --- |
| `SINGULAR_ACCEPTANCE` | `driver-only` | `driver-only`: the driver checks the rule before it publishes an accepted packet. Import, integration and `accept-packet` behave as they did before this setting existed. `every-path`: those paths check the rule too, and a refusal parks the task once. |

Set it like any other `SINGULAR_*` setting: in the `env` object of
`singular.config.json`, in `singular.config.sh`, or in
`.singular-state/config.local.sh`. If it holds any other value, every engine
command stops with exit 2.

## The rule

```text
PublishAccepted(K)  <=>  G(K) and A(K) and D(K) and E(K) and V(K)
```

| Conjunct | Holds when |
| --- | --- |
| `G`, host gate | The host's verification report for this run says `passed` (or `not-rerun-evidence-verified`). It must be bound to this run, head, tree, attempt and campaign, and its request/result binding must validate. |
| `A`, audit | The audit verdict is schema-valid, bound by the host to this task, branch, head and campaign, and says `accepted`. Every finding the auditor still requires must be classified, and none may be at a blocking severity (P0 and P1 always block). A blocking finding from an earlier round that the auditor reports `still-open` refuses. So does a verdict whose original, before host normalization, reported a product failure. |
| `D`, review round | The review-policy ledger holds a completed round for this run, attempt and head, with effective verdict `accepted` and nothing blocking, downgraded or unclassified. The verdict's `reviewPolicy` stamp, when present, must match that round. |
| `E`, evidence | The evidence manifest names this task, run, head and campaign, and binds the exact audit verdict and host report being published, by hash. |
| `V`, proof | Applies only when `SINGULAR_RED_PROOF=enforce` and `SINGULAR_ACCEPTANCE=every-path` are both set, and the task declares a proof. The host's red-proof record must match the current candidate, attempt, declaration, proof files and logs. See [red-proof.md](red-proof.md). |

Budgets are not inputs to the rule. They decide whether more work may be done,
never whether work is accepted. An accept-waiver cannot satisfy `A`, and
neither can a run with audits turned off (`--no-audit`, reason
`audit-disabled`). Under `every-path`, a packet that rests on a waiver is
refused at import and at integration.

The rule reads only the explicit inputs it is given. It never reads ambient
`SINGULAR_*` variables. Run on its own, it prints a
`singular.orchestration.acceptance-check.v0` JSON result and exits `0` when
every conjunct holds, `1` on a refusal, or `2` on a usage error. The driver
also writes that result to `.singular-state/runs/<run>/acceptance-check.json`,
but only once the structural checks have passed. A refusal for
`audit-disabled`, `audit-missing`, `audit-schema-invalid`,
`evidence-manifest-missing` or `evidence-manifest-schema-invalid` writes no new
file, so any file already there is from an earlier check.

### Reason codes

A refusal names the first conjunct that failed and a reason code. Wording may
change between releases; the conjunct and the code are what to match on.

| Conjunct | Reason codes |
| --- | --- |
| `G` | `host-report-missing`, `host-report-invalid`, `host-verification-not-passed`, `host-report-unbound`, `host-report-run-mismatch`, `host-report-head-mismatch`, `host-report-attempt-mismatch`, `candidate-tree-unresolved`, `verification-binding-invalid` |
| `A` | `audit-disabled`, `audit-missing`, `audit-schema-invalid`, `audit-invalid`, `audit-identity-mismatch`, `audit-not-accepted`, `audit-campaign-mismatch`, `verification-echo-mismatch`, `review-stamp-missing`, `review-policy-invalid`, `classification-malformed`, `classification-conflicting-ids`, `classification-incomplete`, `blocking-finding-open`, `prior-blocking-finding-still-open`, `pre-normalize-record-invalid`, `model-reported-product-failure` |
| `D` | `review-ledger-invalid`, `review-round-missing`, `review-round-stale`, `review-round-head-mismatch`, `review-round-campaign-mismatch`, `review-round-not-accepted`, `review-round-unresolved`, `review-stamp-mismatch` |
| `E` | `evidence-manifest-missing`, `evidence-manifest-schema-invalid`, `evidence-manifest-invalid`, `evidence-manifest-identity-mismatch`, `evidence-manifest-campaign-mismatch`, `evidence-manifest-incomplete`, `evidence-manifest-stale` |
| `V` | listed in [red-proof.md](red-proof.md#proof-at-acceptance-v) |

The paths below add a few codes of their own. They cover inputs that could not
be read before the rule ran, a review unit that could not be resolved, and
evidence that changed between the check and publication.

## What changes under `every-path`

Each path checks the rule just before it publishes. Import, integration and
`accept-packet` also take a hash of the certificate files the rule reads: the
audit verdict, the host report and its verification request files, the
evidence manifest and the review ledger. Before publishing, each checks under
the publication locks that those files have not changed. A change refuses
publication. This catches a replacement certificate too, even one that is
consistent in itself.

The hash does not cover every input. It leaves out the lease and the red-proof
records, and at integration also the task contract. Those inputs are covered by
running the rule a second time: integration does so after its gate,
`accept-packet` after its reruns, and import under the publication locks when
`SINGULAR_RED_PROOF=enforce` is set. Import also checks that the lease has not
changed. The driver takes no hash: it runs the rule once, just before it
publishes.

### The driver (`singular drive`, and every drive the loop starts)

The driver applies the rule in both modes, on three paths. A refusal is never
published, and the event `l1.acceptance_refused` names the conjunct and the
reason. What else happens depends on the path:

| Driver path | On refusal |
| --- | --- |
| Ordinary accept, after the audit | The task ends `escalate-parked`. Lease and task become `blocked`, and the decision rationale names the refusal and points to `runs/<run>/acceptance-check.json`. On a `V` refusal the packet is also marked `blocked`, and the rationale gives the route described in [red-proof.md](red-proof.md#proof-at-acceptance-v). |
| Resume of an accepted checkpoint that was waiting for evidence | The checkpoint is kept unpublished and the drive exits 3 (`AWAITING EVIDENCE`), with event `l1.accepted_evidence_resume_refused`. No decision is recorded and the task is not parked. The exception is a refusal on `V`: then the task is parked once, an `escalate-parked` decision is recorded, and the marker `runs/<run>/proof-publication-refusal.txt` is written. An operator repairs the proof evidence and runs `singular drive TASK-XXXX`. |
| Recovery of a stranded accepted packet, under `driver-only` | The packet is not re-accepted, and the drive exits nonzero without recording a decision. The refusal does not park the task by itself. Only the driver's ordinary count of repeated dispatch refusals (`SINGULAR_REFUSAL_PARK_THRESHOLD`, default 3) can park it. |

The driver's own check is the same in both modes, with three exceptions under
`every-path`:

- With `SINGULAR_RED_PROOF=enforce` also set, the check includes `V`.
- Recovery of a stranded packet is handed to `accept-packet`, which applies the
  stricter rules below and owns the refusal and the park. If it refuses, the
  drive exits 2.
- After an `accept-packet` refusal, `singular drive TASK-XXXX --audit-only`
  records the retained candidate as awaiting a new audit. The candidate then
  earns a new certificate through the ordinary gate and audit, even if the
  refused packet or audit still says `accepted`.

### Packet import (reconcile importing the inbox)

| | `driver-only` | `every-path` |
| --- | --- | --- |
| Check | Audit schema, identity and campaign; `accepted`, or a recorded accept-waiver. | All of that, then the full rule, before a new packet is published. With `SINGULAR_RED_PROOF=enforce`, the rule runs again under the publication locks. |
| On refusal | `packet.import_rejected` or `packet.import_failed`. The inbox packet stays, and it is parked after `SINGULAR_IMPORT_FAIL_PARK` identical failures. | The task is parked at once: lease and task `blocked`, breaker incremented, events `packet.import_refused` and `task.import_parked`. The packet leaves the inbox for `.singular-state/import-refusals/<run>/`, so the next cycle does not judge it again. |
| Resolve | Fix the packet or its evidence. | An operator repairs the named evidence and runs `singular drive TASK-XXXX` to retry the retained candidate. |

An import that is already published, with identical bytes, succeeds without
being judged again.

### Integration (`singular integrate`, and the loop's integration step)

| | `driver-only` | `every-path` |
| --- | --- | --- |
| Check | The imported audit sidecar says `accepted`, or a recorded accept-waiver exists. | The full rule, before the integration gate. It runs again after the gate, before the merge commit. The imported sidecar must be byte-identical to the run's `audit.json`. |
| On refusal | `skip TASK-XXXX: no accepted auditor verdict or recorded accept-waiver`. Nothing is parked. | Nothing is merged, and the target branch is unchanged. Lease and task become `blocked`, and the lease's `failureReason` is `acceptance:<conjunct>:<reason>`. Event `integration.acceptance_parked`. Run directly, the command exits nonzero and increments the breaker; in the loop, the refusal counts as a failed integration. A repeat of the same refusal does not park the task again. |
| Resolve | Not applicable. | An operator repairs the acceptance evidence, then runs `singular integrate --task TASK-XXXX`. When the rule then holds, that explicit retry lifts the park and integrates. |

### `singular accept-packet`

`accept-packet` re-accepts an existing stranded packet whose branch head still
matches. It reruns the scope check, the secret scan and the packet's commands
in a disposable exact-head checkout.

| | `driver-only` | `every-path` |
| --- | --- | --- |
| Certificate | The reruns write a new `accepted` audit verdict for the packet. | No verdict is written. The retained independent audit, the completed review round and the exact host report must already satisfy the rule. The rule runs before the reruns and again before publication. The reruns are recorded as separate evidence only. |
| On refusal | The command fails. | Exit 2. Lease and task become `blocked`, an `escalate-parked` decision is recorded, the breaker is incremented, events `packet.acceptance_refused` and `task.acceptance_parked` are written, and the marker `runs/<run>/accept-existing-packet-refusal.json` is written. A second refusal of the same packet does not park it again. |
| Resolve | Not applicable. | An operator repairs the named evidence, then runs `singular drive TASK-XXXX --audit-only`. |

### Recovery

Resuming an accepted checkpoint is a driver path, covered above. The other
recovery check is on regating:

- **`singular recover candidate TASK-XXXX --action regate --successor-run RUN --successor-branch BRANCH --successor-worktree PATH`.** When
  `SINGULAR_ACCEPTANCE=every-path` and `SINGULAR_RED_PROOF=enforce` are both
  set, and the task declares a proof, the retained candidate must satisfy the
  rule before a recovery authorization is written. A refusal parks the task
  once, with event `candidate.acceptance_refused` and the marker
  `runs/<run>/regate-acceptance-refused.json`. An operator repairs the evidence
  and retries the same `recover candidate` command, with the same successor
  arguments. When it then passes, the
  park is lifted. With any other combination, regating does not check the rule
  first.

## What `every-path` does not protect against

- **The rule checks records, not code.** It shows that a gate, an audit, a
  review round and a manifest agree about this exact candidate. It does not
  show that the gate tests the right thing or that the auditor was right.
- **It changes the driver's own check only as listed above.** The driver
  checks `G`, `A`, `D` and `E` in both modes. `every-path` mainly adds checks
  on the later paths.
- **`V` needs both settings, on every path.** Without
  `SINGULAR_RED_PROOF=enforce`, no path checks the proof at acceptance.
  Regating checks the rule only when both settings are on and the task
  declares a proof.
- **It does not run the gate again.** Integration still runs its own gate on
  the merged tree. The rule only checks the recorded host report.
- **It refuses waivers.** A project that relies on accept-waivers will see
  those packets refused at import and integration.
