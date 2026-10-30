# Singular — agent front door

Read this before working in the repository, then read [CONTRIBUTING.md](CONTRIBUTING.md).

## What the code does

Singular's current engine, called the classic engine, is a Bash and Python
orchestration engine. The CLI dispatches commands to scripts that plan tasks,
run workers, check and audit their work, and integrate results. The autonomous
loop is one way to run it; individual commands are also available. Execution
requires Bash 4 or newer.

Start with [cli/singular](cli/singular) for command dispatch,
[engine/lib.sh](engine/lib.sh) for configuration and shared functions,
[engine/autonomate.sh](engine/autonomate.sh) for the loop, and
[engine/l1-drive.sh](engine/l1-drive.sh) for running a task.

## Testing and working rules

Run `bash tests/run.sh` for the full regression suite, or
`bash tests/run.sh <test file>` for one test. The runner accepts test basenames,
such as `test-readonly-guard.sh`, for focused runs.

- Every fix lands with a regression test seen to fail on the unfixed code.
  Record the failing and passing exit statuses; a passing test alone is not
  proof of a fix.
- Never use `git restore` or `git checkout` to reset files in place inside a
  script that mutates them. Use a disposable checkout for mutation checks and
  preserve existing work.
- `SINGULAR_ENGINE_DIR` is an overridable lookup directory, not the install
  path. Tests can point it at selected context scripts. Resolve bundled engine
  executables from `SINGULAR_LIB_DIR`, which is computed from the location of
  `engine/lib.sh`. The CLI's engine-home override is `SINGULAR_ENGINE_HOME`.
- Test fixture repositories must gitignore `.singular-state/`. It holds runtime
  state, including read-only guard bookkeeping; leaving it unignored makes
  the guard's own writes appear as project changes.
- Keep `engine/` generic, Python dependencies in the standard library, and
  `engine/lib.sh` parseable under Bash 3.2 even though execution uses Bash 4+.
  Preserve public command names, `SINGULAR_*` variables and the
  `singular.orchestration.*` schema namespace.

## When commands push

`singular auto` and the launchd launcher
[templates/launchd/run-orchestrator.sh](templates/launchd/run-orchestrator.sh)
default `SINGULAR_PUSH` to `1` when it is unset or empty. With an `origin`
remote, the loop can push integrated branches without another confirmation.
Set `SINGULAR_PUSH=0` to disable pushing, in the project's configuration if it
sets the variable, because configuration overrides the environment. Direct
commands such as `singular integrate` and `singular reconcile` default to `0`
and do not push unless `SINGULAR_PUSH=1` is supplied through their environment
or configuration.
These are the shipped defaults, not authorization to push during a task.
Run loop tests in a disposable project with no remote and `SINGULAR_PUSH=0`,
with no configuration overriding that value.

## Product direction

The product's direction is under review.
