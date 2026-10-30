# Red-proof prompt contract

`test-red-proof-prompts.sh` covers S1.1-10 and the planner/critic part of
S1.1-6. It runs ten isolated cases: each of `templates/prompts/` and
`docs/orchestration/prompts/`, with the setting unset, `off`, `observe`, and
`enforce`, plus an `off` case with proof fields declared. No provider, network,
autonomous loop, or remote is used.

The planner and worker run their real `--dry-run` entry points. The critic runs
`singular_ctx_plan_critic_run` with a local runner that captures the exact
`--prompt-file` bytes. The task template is produced by `engine/scaffold.sh` in
a fresh project for each case. This does not require overwriting a consumer's
existing template when a setting changes. Fixture repositories ignore runtime
state, and every engine subprocess has its own project, state and temp folders.

The disabled snapshots in `expected/` were captured from the unchanged engine
at **cfe5afb8b7f8d6cd9376647c6b6e9d3b62694458**. The worker's generated run ID
and base commit SHA and the critic's initial commit SHA are the only
normalizations. No paths, prose, whitespace, or trailing newlines are removed.
The suite has no snapshot-update mode. Unset and explicit `off` must each
match all four snapshots for their prompt folder. Explicit `off` also pins the
worker's existing behavior when the task declares proof fields: the fields
are echoed in the complete-task appendix, with no new proof instructions.
The existing independent
`test-declares-nothing-parity.sh` remains the accepted-drive worker/auditor,
event-order and run-file pin against v0.23.7; run it alongside this test.

Enabled cases require the exact task-key labels `Proof command:` and
`Proof tests:` in the planner, critic, worker and scaffolded task template.
The worker receives the concrete command `python3 tests/proof-widget.py` and
owned proof path `tests/proof-widget.py`; these must appear with the labels in
its instructions before the verbatim complete-task appendix. The appendix
alone already echoes these headers on the old engine and therefore cannot
demonstrate the new prompt contract. Planner and critic input tasks deliberately
have no proof fields, so those prompts cannot pass by echoing fixture input.
No exact new prose, placeholder syntax, or rendering helper is prescribed.

At the base, the docs folder has no `plan-critic.md`; the critic's supported
engine-template fallback supplies its disabled snapshot. Enabled cases require
the docs copy as well, so that both prompt folders actually participate.
This missing mirror is part of the absent feature, not a fixture setup error.

The shell wrapper captures and unsets the Rails variables before launching any
child. Its nonce is written only after all assertions and cleanup succeed.
The critic stub additionally asserts that neither variable reached it.

Sensitivity checks in separate disposable checkouts changed one byte in the
planner template and, separately, one byte in the critic template. Each disabled
render comparison returned exit 1 for its own byte mismatch. The unmodified
disabled captures matched. These local checks are not independent acceptance
evidence; the feature suite is intentionally red until the implementation row.
