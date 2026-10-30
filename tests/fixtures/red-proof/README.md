# Red-proof frozen fixture

This is the test-only handoff for S1.1-1, 2, 4, 5 and 7, under the D4 default
assumption. It uses the existing parity fixture's runner protocol and real Git,
driver, parser, scratch runner, schema checker, event writer and task selector.
It uses no provider, network, autonomous loop, installed engine or remote.

## Fixture-selected interface

The specification does not name an internal phase or the JSON members. This
fixture makes those choices explicit for the following implementation row:

* `run_red_proof_phase <attempt>` is a top-level function in `l1-drive.sh`, like
  `run_worker_phase` and `run_audit_phase`. The ordinary driver must call it.
  Its input globals are the driver's `task_json`, `task_file`, `test_policy`,
  `task_id`, `run_id`, `run_dir`, `worktree`, `head_sha`, `packet_base_ref`,
  `branch_base`, `worker_branch`, and `lease_path`. `phase.sh` supplies these.
  The task is parsed by the real parser. The base also exists in the pre-worker
  lease. Helpers defined in the driver are loaded verbatim, as is `lib.sh`.
* The phase returns zero when it permits continuation. Otherwise it sets
  `attempt_failure` and `attempt_ctx` and returns nonzero, following the
  existing phases. It owns the one infrastructure retry, not product repair
  accounting. The driver owns product repair and terminal parking. Only the
  status UI function is replaced with a no-op in the focused harness.
* The command deadline is `SINGULAR_RED_PROOF_TIMEOUT_SEC` (one second here).
  `SINGULAR_RED_PROOF` is deliberately set by an **unexported** project shell
  setting, so reading it only from Python's environment fails these checks.
* The record that counts is the one the host writes directly in the run
  directory as `red-proof-<attempt>.json`; a file with the same schema in a
  subfolder (such as `worker-evidence/`) is not a record. Its `schema` is
  `singular.orchestration.red-proof.v0`, with a matching schema anywhere under
  `schemas/`. Extra members are permitted by the test. Required bindings are
  `baseSha`, `headSha`, `treeSha`, integer `attempt`, exact `command`,
  `commandSha256` (SHA256 of the command's UTF-8 bytes without a newline), and
  `proofFiles: [{"path": ..., "sha256": ...}]` for every candidate proof file.
* An executed record has `base` and `candidate` observations with `outcome`,
  `rawExitCode`, `timedOut`, `logRef` and `logSha256`. Log references may be
  absolute or relative to the record; both logs must remain in the run folder.
  `setupError` identifies an observation which could not execute. Base outcomes
  are `red`, `not-demonstrated`, `green` (characterization), or
  `inconclusive-infrastructure`; candidate product outcomes are `green` and
  `green-failed`. The overall `outcome` uses spec 03's six classes. A successful
  characterization is `proved` with base exit zero, not a red observation.
  Waivers are `waived`, never execute the command, and need no observation logs.
* Repair records must remain available by attempt; overwriting the only record
  and losing earlier bindings fails the three-attempt integration case.

These are test seam/serialization choices, not new public CLI verbs. The
implementation can factor its internals freely behind this phase. Nothing in
the fixture implements red proof or fabricates an accepted proof record.

## Coverage and controls

The matrix covers all four V rows at `off`, `observe`, and `enforce`, both
classic waiver policies, unset mode, base exits 0/1/7/126/127, candidate exits
0/1/7, timeout, failed checkout setup and tracked-source mutation. The
infrastructure cases check one retry. Every failure class also runs in
`observe`, where it must return success with no driver failure state.
`base-cannot-run` requires two base observations and a successful candidate;
the same base failure with a failing candidate stays infrastructure. Waiver
cells test the predeclared exception without executing the command.

Every executed proof prints contradictory pass/failure/infrastructure prose.
The assertions compare actual exits, not that prose. The base contains stale
proofs that exit 89. The candidate replaces two proof files, so a missing or
partial overlay cannot accidentally pass. Logs capture the actual commit,
checkout and temporary directory, both proof hashes and dependency provenance.
The main dependency says `main`, the worker's copy says `worker`. The phase
harness snapshots HEAD, staged diff, status, tracked bytes and ignored worker
data. A Git observer additionally catches temporary checkout/reset/restore
operations even if the final snapshot would match.

Three ordinary drives independently check wiring: two product failures then a
successful repair (including both feedback prompts, repair charges and all
three attempt bindings); infrastructure retry then one parked event, no product
charge and exclusion from the next real task selection; observe-mode failure
recording followed by normal audited acceptance. The original parity test
remains the independent control for unchanged default run files and prompts.

The shell entrypoint captures and unsets the Rails verdict variables before
loading any code. Only its last successful action writes the verdict nonce.
Runner and proof processes assert they received neither variable. The test is
marked serial in the outer harness and runs at most two fixture jobs inside.
Every subprocess has a deadline; timeout fixtures poll with a bound. Temporary
repositories ignore `.singular-state/` and all fixture-only runtime files.

## Removal checks for the implementation reviewer

* Remove exit-based classification: `base-zero`, `base-seven`,
  `candidate-one`, `candidate-seven`, `base-126-green`, `base-127-green`,
  `base-126-failed`, `base-127-failed`, `base-timeout` must fail.
* Remove mode/policy gating: the `V-*`, `unset` and `observe-*` cases fail.
* Remove checkout isolation, main dependency source, either overlay, or worker
  preservation: every executed phase checks these independently of outcome.
* Remove the bounded infrastructure retry or source-integrity/setup handling:
  the infrastructure matrix cases and `drive-infrastructure` fail.
* Remove product feedback/accounting or ignore the phase result in the driver:
  `drive-product-repairs` and `drive-infrastructure` fail.
* Remove record bindings: every record is checked against independently read
  Git objects, raw command/file/log bytes, and its shipped schema;
  `attempt-binding` uses attempt 7, and the repair drive checks three heads.

This test-only row cannot demonstrate guard-removal failures or a green
implementation before that implementation exists. Those checks remain due
from the implementation row; a green fixture self-check is not host evidence.
