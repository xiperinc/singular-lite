# Upgrading an existing 0.23.x project

This procedure qualifies a local candidate from its checkout. It does not install,
download, publish or push anything. `tests/test-upgrade-existing-project.sh`
executes the labelled Bash blocks below against a recorded 0.23.4 scaffold,
with a local prompt edit and an existing ready task. Its provider is a stub;
release qualification must separately exercise a real provider.

In 0.23.7, the Claude provider's runtime default changes from
`claude-opus-4-8` to `claude-sonnet-5-5`, including for existing projects.
Every Claude call inherits it when no model override applies; effort defaults
are unchanged. To keep every Claude call on the old model, set
`SINGULAR_CLAUDE_MODEL=claude-opus-4-8` in the project's configuration.
Nonempty role-specific settings (`SINGULAR_CLAUDE_L2_MODEL`,
`SINGULAR_CLAUDE_L1_MODEL`, `SINGULAR_CLAUDE_PLANNER_MODEL`,
`SINGULAR_CLAUDE_AUDITOR_MODEL`, `SINGULAR_CLAUDE_DECIDER_MODEL`) win over
`SINGULAR_CLAUDE_MODEL` for calls that read them; the general setting wins over
the provider default. The plan critic, the planner's repair round, the paired
audit, the supervisor briefing and `singular ask` read only `SINGULAR_CLAUDE_MODEL`,
then the provider default. A project that pins models by role only must also
set `SINGULAR_CLAUDE_MODEL` to keep those calls on the old model; any role-specific
pins for other models still win for calls that read them. For each setting,
configuration loads over the environment in this order: `singular.config.json`
(`env`), `singular.config.sh`, then `.singular-state/config.local.sh`, using the
default configuration paths; the later layer wins.

Use Bash 4 or later. Stop the project's loop and workers first. Work on an
independent copy with no remote, retaining the original project and the previous
engine. Include ignored state, local configuration, uncommitted work and Git
history in that copy. For projects with linked worktrees or state outside the
repository, retain those directories and their Git metadata too; copying only
the repository is not a complete backup.

Set `project` to that copy, `candidate` to the candidate checkout, and `backup`
to a new directory outside both. Use absolute paths. Set `task_id` to an existing
ready task whose gate you can run. These are shell variables, not engine settings.
The blocks run in the same shell. Preserve any pre-existing engine override so
you can restore it on rollback. This example uses state inside the project.

<!-- upgrade-step: backup -->
```bash
set -euo pipefail
test -d "$project/.git"
test -f "$candidate/engine/lib.sh"
test ! -e "$backup"
test -z "$(git -C "$project" remote)"
mkdir -p "$backup"
cp -a "$project" "$backup/project"
previous_version="$(cat "$project/.singular-version")"
candidate_version="$(cat "$candidate/VERSION")"
export SINGULAR_HOME="$backup/engine-home"
export SINGULAR_STATE_DIR="$project/.singular-state"
export SINGULAR_PUSH=0
cd "$project"
```

Select the candidate explicitly. `SINGULAR_ENGINE_HOME` selects the engine
checkout and takes precedence over the project pin; `SINGULAR_ENGINE_DIR` is
not an installation selector. `update` writes only `.singular-version` and
does not install an engine. In particular, the old `engineVersion` field in
`singular.config.json` remains unchanged. The explicit override is required
when the candidate is not installed.

<!-- upgrade-step: select -->
```bash
export SINGULAR_ENGINE_HOME="$candidate"
bash "$candidate/cli/singular" update "$candidate_version"
bash "$candidate/cli/singular" version
bash "$candidate/cli/singular" migrate --dry-run
```

Both the recorded scaffold and this candidate use schema `v2`; the dry run
reports no migration. If another candidate requires a migration, stop here
and review its migration and rollback contract before applying it. This test
does not qualify a schema downgrade.

| Source | What an existing project gets |
|---|---|
| `engine/`, including the driver, policy, runner adapters and schema validators | Inherited immediately from the selected engine checkout. Runtime validation uses the engine's `schemas/`. |
| `.singular-version` | Updated to the candidate's `VERSION`. |
| `singular.config.json`, optional `singular.config.sh`, ignored `.singular-state/config.local.sh` | Kept. JSON settings load first, then shell settings, then local settings. Unspecified settings take engine defaults. |
| `docs/orchestration/prompts/*.md` | Kept as project copies, including local edits and the old L0/L1 scaffolding prompts. The driver reads the project's worker and auditor prompts. Review and merge template improvements manually. |
| DAG, task template, planner contract, gate adapter and project/area state | Kept as project files. Merge relevant template changes manually; a resumed task and its decision/state records can change during execution. |
| `schemas/orchestration/*.schema.json` | Existing mirrors survive routine runs; missing mirrors may be added. Explicit `init` synchronizes mirrors when schema versions agree, so it is not a harmless prompt refresh. |

Review differences against `candidate/templates/prompts/` and
`candidate/templates/singular.config.json`; do not replace local files wholesale.
`init` skips existing prompts and configuration, so rerunning it does not merge
their improvements. To refresh a prompt, merge its relevant changes with your
local instructions, review the diff and rerun a representative task. Schema
mirrors need an explicit reviewed refresh if tooling in your project uses them.
For this candidate, the worker template clarifies that `blockers[]` entries are
objects, and the auditor template clarifies allowed fields, host-owned fields
and unresolved prior findings. Old project copies do not acquire those edits.

Inspect effective configuration before continuing work:

<!-- upgrade-step: inspect -->
```bash
bash "$candidate/cli/singular" health --json
```

For the recorded scaffold, `runner` is the selected engine's `claude-run.sh`,
target branch is `agent/integration`, area prefix is `src/`, concurrency remains
`3` from the old configuration (the candidate template uses `auto`), schema is `v2`, and the default gate remains the scaffold's deliberately
failing placeholder until the project configures it. Unset runtime knobs inherit
20 hours, configured worker retries 3 and configured auditor infrastructure
retries 2. The driver limits product repairs to 1 for a normal task (2 for a
high-risk task), and infrastructure retries to 1. Context packets and routing default to 1; artifact scanning and paired
auditing default to 0. Existing project
overrides can change these settings. The regression checks these loaded values
and the normal task's effective repair ceiling, not just the template text.

The regression adds a local concurrency override of 2, a worker-prompt edit and
a small task gate, then runs this exact continuation command with an isolated
stub runner supplied by local configuration. In a real rehearsal, use your
chosen provider and review its output and costs. Keep pushing disabled.

<!-- upgrade-step: continue -->
```bash
bash "$candidate/cli/singular" drive "$task_id"
```

Check the task status, packet, gate results and generated prompts under
`.singular-state/runs/`. The regression requires the pre-existing task to reach
`accepted`, with an accepted lease and inbox packet, a passing gate and the
local prompt instruction present in the worker input. Acceptance is not
integration; this rehearsal does not merge or push the task's branch.

## Roll back

Stop candidate workers before switching. To roll back engine selection while
keeping the task progress, restore the previous pin:

<!-- upgrade-step: rollback -->
```bash
bash "$candidate/cli/singular" update "$previous_version"
unset SINGULAR_ENGINE_HOME
```

Restore your previous `SINGULAR_HOME`, `SINGULAR_STATE_DIR` and any previous
engine override before the next normal invocation. The isolated engine home
above has no installed versions. For checkout-based use, explicitly select
the retained previous checkout with `SINGULAR_ENGINE_HOME`, and run its CLI's
`version` command to confirm selection before running work. Merely changing
the pin while retaining the candidate override would still run the candidate.

This rollback does not undo task commits, restore prompts you manually merged,
or reverse state changes or migrations. Keep the post-upgrade copy as well as
the backup. If the previous engine cannot consume the new state, use the
untouched original or recover the complete pre-upgrade snapshot (including its
associated state and worktrees) before resuming. Do not overwrite newer work
with the backup. The regression checks pin rollback and backup preservation;
it does not claim that an older engine can read candidate-written state.
