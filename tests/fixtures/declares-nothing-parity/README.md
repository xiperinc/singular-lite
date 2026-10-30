# Declares-nothing parity fixture

S1.1-6 characterizes one ordinary accepted drive of **synthetic-widget**. The
project declares no proof fields and no verification contract. The existing
`strict_test_first` task policy and `true` gate are deliberately retained;
acceptance, red-proof, review, context, and verification settings are unset.
There is no project configuration, provider call, network access, or remote.

The fixture setup and runner are adapted from `test-acceptance-defaults.sh` and
`fixtures/acceptance-defaults/runner.py`. The local runner copy allows the same
test to be overlaid onto the older candidate, where that fixture is absent.
The only runner additions capture the actual `--prompt-file` bytes outside the
run folder and reject extra invocations. Malformed-audit support is removed.
The driver, gate, audit validation, review ledger, and publication remain real.
The stub's synthetic test logs are fixture inputs, not product test evidence.

The four files in `expected/` were captured from local tag **v0.23.7**, commit
**2a13ebbd2efba3171d0be4123516a59bb5349834**, in a detached disposable worktree.
They were first checked there, then at the task's `next` base
**35d5ba76b8be1e6a44d99cf71c37a50bc2f1f062**. Both returned exit 0.

- `run-files.txt`: every file recursively under the completed run folder,
  sorted by relative name (98 files).
- `event-kinds.txt`: every event's `type`, in emission order, with duplicates
  retained (20 events).
- `worker-prompt.md`: bytes delivered to the sole worker invocation.
- `audit-prompt.md`: bytes delivered to the sole auditor invocation, including
  the host verification binding and delivered packet/report evidence.

All normalizations are enumerated in the test header and implemented in
`compare.py`. Only volatile identities and their derived hashes are replaced.
Static digests (including task/policy contracts, tree, and empty gate log),
JSON formatting, whitespace, and trailing newlines remain pinned. The audit
prompt's final blank line is original output and is intentionally preserved. The
content-addressed delivery prompt's filename digest is checked against its
contents before normalization. No command rewrites the expected files.

Run `bash tests/run.sh test-declares-nothing-parity.sh`. To check another engine
revision, make a detached disposable worktree and copy this fixture directory
and the test into it; run that worktree's test runner. No remote is needed.

Sensitivity checks use separate disposable worktrees, never a reset of the
working source. Each must return exit 1 after an otherwise accepted drive:

- Change `singular` to `Singular` in the worker template's first sentence:
  `parity mismatch: worker-prompt.md`.
- Rename the emitted `l1.dispatch_started` event to `l1.dispatch_startEd`:
  `parity mismatch: event-kinds.txt`.
- Change `singular` to `Singular` in the auditor template's first sentence:
  `parity mismatch: audit-prompt.md`.
- Create `unexpected-parity-file` immediately after the driver creates the run
  directory: `parity mismatch: run-files.txt`.

This is a characterization test, not a behavior fix: the unchanged candidate
is expected green. A missing-baseline setup failure is not red proof. The
mutations above demonstrate sensitivity; these developer checks are not
independent acceptance evidence.
