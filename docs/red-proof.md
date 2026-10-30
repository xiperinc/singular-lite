# Red proof

Red proof is an opt-in check. The host itself runs a task's proof tests twice:
once on the base the task started from, and once on the candidate the worker
committed. A task that declares a proof is expected to fail on the base and pass
on the candidate. The worker's own logs count for nothing here. The host writes
its own record of both runs.

The check is off by default. A task that declares no proof is never checked,
whatever the mode.

## Settings

| Setting | Default | Values and meaning |
| --- | --- | --- |
| `SINGULAR_RED_PROOF` | `off` | `off`: no proof runs, prompts are unchanged, and nothing is recorded. `observe`: the host runs declared proofs and records the result, but no result changes what happens to the task. `enforce`: a declared proof must end `proved` (or `waived`) before the audit runs. |
| `SINGULAR_RED_PROOF_TIMEOUT_SEC` | `1200` | Time limit, in seconds, for each proof run. A run that is still going at the limit is killed. That counts as infrastructure trouble, not as a failing test. The value must be a positive integer. `0` does not turn the limit off: every proof then ends `inconclusive-infrastructure`. |

Set them like any other `SINGULAR_*` setting: in the `env` object of
`singular.config.json`, in `singular.config.sh`, or in
`.singular-state/config.local.sh`. A later layer wins. If `SINGULAR_RED_PROOF`
holds any other value, every engine command stops with exit 2.

In `observe` and `enforce` the planner, the plan critic and the worker get an
extra prompt section on how to declare and write a proof. The section comes
from `docs/orchestration/prompts/red-proof.md` in the project if that file
exists. Otherwise it comes from the copy bundled with the engine. When
`singular init` writes a new task template with either mode on, the template
includes empty proof headers.

## Declaring a proof

A task declares a proof with two header lines, next to `Test policy:` and
`Gate command:`:

```markdown
Test policy: `strict_test_first`
Gate command: `npm test`
Proof command: `python3 tests/test_widget_limit.py`
Proof tests: `["tests/test_widget_limit.py"]`
```

- `Proof command:` names one program and its arguments. It takes no pipes,
  redirects, `;`, `&`, `&&`, `||`, backticks or `$(`. These characters are
  refused even inside quotes. Arguments are passed as written, with no shell
  expansion. If you need several steps, put them in a script and list the script
  under `Proof tests:`.
- `Proof tests:` is a JSON array of paths, relative to the repository root. A
  path may be a file or a folder. Every path must sit inside the task's owned
  files. The files need not exist yet, because the worker writes them. They must
  be tracked files in the candidate commit.
- Declare both headers or neither. An empty command with `Proof tests: []`
  means the same as no proof.

The task's `Test policy:` decides what counts as proof:

| Test policy | Base run | Candidate run | Result when both hold |
| --- | --- | --- | --- |
| `strict_test_first` | must fail (nonzero exit) | must pass (exit 0) | `proved` |
| `characterization_first` | must pass | must pass | `proved` |
| `test_after_waiver` | not run | not run | `waived` |
| `not_applicable` | not run | not run | `waived` |

A waived policy runs nothing. The waiver comes from the task's own header,
written before the work started. A decider cannot grant it later.

### Preflight refusals

These checks run before the task is dispatched, in every mode, including
`off`. If one fails, the driver refuses to start the task. It sets the task to
`blocked` and records an `escalate-parked` decision and an `l1.preflight_failed`
event that lists the reasons. No run, lease or worktree is created. The task
author corrects the headers, and then an operator runs `singular unpark TASK-XXXX`.

| Reason | Cause |
| --- | --- |
| missing Proof tests | A command was declared without test paths. |
| missing Proof command | Test paths were declared without a command. |
| shell operators and substitutions are not allowed | The command contains one of the refused characters, or a control character. |
| one program with valid argument quoting | The command's quoting does not parse, or it names no program. |
| Proof tests must be a JSON array | The header is not a JSON array of strings. |
| path is outside owned files | A proof path is outside the owned scope, or is not a valid repository path. |

A second `Proof command:` or `Proof tests:` header in the same task is a parse
error, and so is a `Proof tests:` value that is not valid JSON.

## What the host runs

After the worker commits, and before the audit, the driver runs the proof
phase. It runs only when the mode is `observe` or `enforce` and the task
declares a proof. The task declaration the host uses was read before the worker
started. Edits the worker makes to the task file are ignored.

1. The host binds its inputs before it runs any candidate code: the base commit
   from the task's lease, the candidate head and its tree, the command, and the
   SHA-256 of every proof file in the candidate commit. Declared folders are
   expanded from the candidate's Git objects, never from files on disk.
2. **Base run.** The host makes a disposable checkout of the base commit, copies
   the candidate's proof files over it, and runs the proof command there.
3. **Candidate run.** The host makes a disposable checkout of the candidate head
   and runs the proof command there.

Both runs happen in fresh checkouts, prepared the same way as the gate's
disposable rerun. Dependency copies come from the project root. The worker's
worktree is never reset, checked out or changed. The run is also flagged if the
worker's worktree changes while the proof runs.

Each run is classified by its exit code alone. Text printed by the tests has no
weight. A run counts as infrastructure trouble, and not as a test result, when:

- the checkout could not be prepared,
- the run hit the time limit,
- the program could not start (exit 126 or 127),
- or the run changed tracked files, or left untracked files that are not
  ignored, in its checkout.

An infrastructure result on one side gets exactly one more try on that side.

## Outcomes

| Outcome | Meaning | Under `enforce` |
| --- | --- | --- |
| `proved` | Each run behaved as the test policy requires. | The attempt goes on to the audit. |
| `waived` | The policy is `test_after_waiver` or `not_applicable`. Nothing ran. | The attempt goes on to the audit. |
| `not-demonstrated` | The candidate passed, but the base did not do what the policy requires: it passed under `strict_test_first`, or it failed under `characterization_first`. | Product failure `red-proof-not-demonstrated`. The worker gets feedback and a product repair is charged. |
| `green-failed` | The candidate run failed. | Product failure `red-proof-green-failed`. The worker gets feedback and a product repair is charged. |
| `base-cannot-run` | The program could not start on the base (exit 126 or 127, twice), while the candidate passed. | Infrastructure. The task is parked. |
| `inconclusive-infrastructure` | A run was still infrastructure trouble after its retry, or the host could not bind or record the observations. | Infrastructure. The task is parked. |

The product failures follow the driver's ordinary repair rules. The decider
cannot waive them: the only next step is another product pass. As with any
product failure, the task is parked instead in these cases:

- the product-repair budget is spent (`SINGULAR_MAX_RETRIES` and the task's
  risk tier);
- no review round is left for another pass;
- the attempt left the candidate exactly as it was;
- the attempt reproduced the previous attempt exactly: same head, same
  changes, same failure;
- the normalized findings repeated those of the previous attempt;
- or a project module reports a blocker for the failure.

The infrastructure outcomes charge no product repair. They end the drive with
`escalate-infra`. The lease and the task become `blocked`, and the decision
says why. An operator fixes the proof environment, for example a missing tool
or a proof command that does not exist on the base, and then runs
`singular unpark TASK-XXXX`.

Under `observe`, every outcome is recorded and the attempt goes on to the audit
as if no proof had run.

The worker's feedback for an attempt is in
`.singular-state/runs/<run>/red-proof-<attempt>-feedback.txt`.

## The record

Every executed or waived proof writes
`.singular-state/runs/<run>/red-proof-<attempt>.json`. Its schema is
`schemas/red-proof.v0.schema.json` (`singular.orchestration.red-proof.v0`).
Each attempt gets its own record, so a task that took three attempts keeps
three records. The output of each run is in
`red-proof-<attempt>-<base|candidate>-<try>.log` in the same folder.

| Field | Content |
| --- | --- |
| `mode` | `observe` or `enforce`. |
| `taskId`, `runId`, `attempt` | Which task, run and attempt the record belongs to. |
| `testPolicy` | The task's test policy. |
| `baseSha`, `headSha`, `treeSha` | The base from the lease, the candidate head and the candidate tree. |
| `command`, `commandSha256` | The declared command, and the SHA-256 of its UTF-8 bytes. |
| `proofFiles` | `[{path, sha256}]` for every proof file in the candidate. |
| `outcome` | One of the outcomes above. |
| `isolation` | Always `none`. See below. |
| `base`, `candidate` | The last run on each side: `outcome`, `rawExitCode`, `timedOut`, `setupError`, `sourceIntegrity`, `durationMs`, `logRef`, `logSha256`. |
| `baseAttempts`, `candidateAttempts` | Every run on each side, one or two. |

A waived record has no observations.

## Events

| Event | When |
| --- | --- |
| `red_proof.observed` | Once for every proof phase that ran. It carries `taskId`, `runId`, `attempt`, `mode` and `outcome`. |
| `l1.preflight_failed` | A proof declaration failed preflight. |
| `l1.acceptance_refused` | The acceptance rule refused the candidate. A refusal for conjunct `V` names the proof. |

Product repairs, budget exhaustion and parking use the driver's ordinary
events, such as `l1.product_repair_budget_exhausted`,
`l1.unchanged_candidate_parked` and `l1.task_terminal`.

## Proof at acceptance (`V`)

The acceptance rule (see [acceptance.md](acceptance.md)) has a fifth conjunct,
`V`. It applies only when both `SINGULAR_RED_PROOF=enforce` and
`SINGULAR_ACCEPTANCE=every-path` are set, and only to a task that declares a
proof. With any other combination, `V` holds trivially. Under the default
`driver-only`, `enforce` works through the driver's proof phase described
above. Import and integration do not check the proof again.

When `V` applies, it rereads the task contract and the lease and recomputes
every binding from Git. Only the record the host writes counts: a regular
file directly in the run folder named `red-proof-<attempt>.json` (or
`red-proof-attempt-<attempt>.json`, a name the test fixtures use) with the
red-proof schema. A file with that schema anywhere else, such as the worker's
evidence copied to `worker-evidence/`, is not a record: it neither proves nor
refuses. It then requires:

- exactly one record for the candidate's attempt,
- a record that matches the current task, run, base, head, tree, attempt,
  command, command hash and proof file hashes, and also the test policy when
  the record states one,
- for a waived policy, the outcome `waived`,
- otherwise, the outcome `proved`. The last run on each side (`base` and
  `candidate`) must also be consistent with the policy: a real exit code, no
  timeout, no setup error, and the expected exit. If the run records source
  integrity, it must be verified with no changed paths,
- and the log of that last run on each side must still be in the run folder,
  with the hash the record names. Logs of earlier tries are not checked.

A refusal names `V` and a reason code: `proof-record-missing`,
`proof-record-ambiguous`, `proof-record-unreadable`, `proof-declaration-invalid`,
`proof-policy-invalid`, `proof-lease-missing`, `proof-lease-invalid`,
`proof-lease-mismatch`, `proof-binding-mismatch`, `proof-waiver-missing`,
`proof-not-proved`, `proof-observation-missing`, `proof-observation-invalid`,
`proof-log-missing`, `proof-log-changed`, or `proof-input-invalid`.

When the driver's ordinary accept path is refused on `V`, the task is parked and its packet is
marked `blocked` with the operator as the owner. To resolve it, an operator
repairs the proof evidence, reopens the closed review series with
`singular review-policy reopen`, and runs `singular drive TASK-XXXX --audit-only`.
How refusals on the other paths are resolved is described in
[acceptance.md](acceptance.md).

## What a proof does and does not establish

A `proved` record shows that the declared tests, run by the host, tell the
base and the candidate apart. Under `characterization_first` it shows only that
they pass on both.

It does not show:

- **That the tests are right.** A proof shows that the tests react to the
  change. It does not show that they check the acceptance criteria. The plan
  critic and the auditor still judge that.
- **That the code is safe to run.** `isolation` is `none`. The proof command
  runs candidate code with the host's own permissions, in a disposable
  checkout. It has no sandbox.
- **Anything about tasks without a proof.** `enforce` does not require any task
  to declare one. Only declared proofs are checked.
- **Anything under `observe`.** In that mode no outcome blocks a task.
- **Anything for waived policies.** Nothing runs.
- **A later check at import or integration under `driver-only`.** Only
  `every-path` repeats the check there.
