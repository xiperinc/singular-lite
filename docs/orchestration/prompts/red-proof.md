## Host red proof

For a task that must demonstrate a failure on the base and a pass on the
candidate, declare both task headers:

- `Proof command:` one executable and its arguments, without pipes, redirects,
  semicolons, `&&`, `||`, backticks or command substitution. Put a sequence of
  steps in a script and invoke that script.
- `Proof tests:` a JSON array of repository-relative test file paths inside the
  task's owned files, for example `["tests/proof.py"]`. These are the candidate
  tests the host overlays on the base.

The planner must choose a command and tests that exercise the acceptance
criteria. The critic must check that both fields are present together, the paths
are owned, and the proposed test can distinguish the missing behavior from the
implemented behavior. Omit both headers when no proof is declared, or use an
empty command with `Proof tests: []`. Do not invent a proof or a waiver for an
unrelated task.

The worker must implement the declared tests within the owned scope and run the
declared command. Worker logs do not establish host proof. The host runs the
candidate tests on the base and candidate in disposable checkouts; never reset
or check out files in the worker's worktree to simulate the base.

A base failure followed by a candidate pass is `proved`. A base pass is
`not-demonstrated`; a candidate failure is `green-failed`. A timeout or a command
that cannot start is infrastructure trouble, not proof of missing behavior.
Red proof demonstrates sensitivity to the change, not that the tests are right.
