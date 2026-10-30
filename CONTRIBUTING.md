# Contributing

Thanks for taking the time to improve singular.

Read [AGENTS.md](AGENTS.md) for the Bash and Python engine's entry points,
push defaults and working rules. The product's direction is under review.

Describe the problem, the resulting behavior and the focused verification in
your pull request. Keep changes scoped so a reviewer can assess them against
the code and tests.

## Before opening a PR

- Run `bash tests/run.sh` for the full regression suite, or
  `bash tests/run.sh <test file>` for one test (use its basename).
  Report commands and exit statuses.
- Every fix includes a test seen to fail on the unfixed code and pass with the
  fix. Use a disposable checkout to check mutations; never reset files in place
  with `git restore` or `git checkout` inside a script that changes them.
- Keep `engine/` generic. Project-specific rules belong in opt-in modules under
  `singular-ext/` or in a consumer repo's `singular.config.json` /
  `singular.config.sh`.
- Keep Python dependencies in the standard library and `engine/lib.sh`
  parseable under Bash 3.2; execution uses Bash 4 or newer.
- Treat `SINGULAR_ENGINE_DIR` as an overridable lookup directory, not the
  install path. Use `SINGULAR_LIB_DIR` for bundled engine executable locations.
- Gitignore `.singular-state/` in test fixture repositories. Run loop trials
  with `SINGULAR_PUSH=0` in disposable projects with no remote, ensuring project
  configuration does not override it: `singular auto` and the launchd launcher
  otherwise default pushing on. Direct commands
  default pushing off unless the environment or configuration enables it.
- Do not commit `.singular-state/`, `.worktrees/`, `.singular-evidence/`, local env
  files, generated logs, or other runtime artifacts.
- Preserve the public CLI names, `SINGULAR_*` env vars, and
  `singular.orchestration.*` schema namespace unless the change is an intentional
  versioned migration.
- Describe behavior the code implements. Documentation changes do not change
  runtime defaults.

For behavior changes, include focused regression coverage in `tests/` or
`singular-ext/tests/`.
