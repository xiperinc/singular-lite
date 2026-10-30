---
name: singular-orchestration
description: Operate Singular (repo "singular-lite"; CLI command `singular`) through individual task commands or its optional autonomous loop. Use for Singular setup, DAG and task authoring, execution, recovery, and its orchestration console.
---

# Singular orchestration (`singular`)

This skill describes engine 0.24.0's Bash and Python implementation. Singular
runs coding agents in isolated worktrees, with DAG planning, durable leases,
audits and integration gates. Operate it within the user's chosen scope:
individual commands and the autonomous loop are both available. Product
direction and the future of the loop remain open decisions; this skill does
not choose a default operating mode. Each consumer repo pins its engine in
`.singular-version`.

| Tier | Role |
| --- | --- |
| **L0 origin** | The single scheduler. Each reconcile cycle: import staged L1 proposals → recover stale leases → integrate finished branches → dispatch frontier tasks → snapshot. |
| **L1 orchestration** | Shell orchestration invokes planners for ready DAG nodes and drives individual tasks through worker, gate and audit phases. Planners stage task proposals for L0 to import. |
| **L2 workers** | Each executes one task in an isolated git worktree on a per-task branch, then writes a state packet. An auditor reviews it; a decider routes retry/escalate/park. |

Operating choices:

- **Choose the execution scope.** Use `singular drive` for one task,
  `singular reconcile --actuate` for one scheduler cycle, or `singular auto`
  for an unattended loop when the user wants one.
- **Size concurrency to the work.** Worker concurrency defaults to `auto`;
  parallel L1 planning is opt-in (`SINGULAR_ENABLE_L1_PARALLEL=0` in the
  engine). Enable it only when independent scopes and available capacity
  justify it. Detached worker dispatch defaults to `1`.
- **Use the CLI's version resolution.** For consumer operation, invoke
  `singular` so the repo pin selects the engine. Checkout-based engine
  development and tests use the checkout's CLI and an explicit engine home.
- **Gates are the only completion authority.** A DAG node is done when
  `docs/orchestration/gates/<node>.gate-result.json` says so — never because
  a dashboard, task file, or planner claims it.

The [command reference](references/operations.md#current-command-reference)
lists every current top-level command, including optional context and review tools.

## 1. Orient, install, set up

First figure out where you are:

```bash
singular version && singular doctor        # engine installed + repo healthy?
singular status                            # existing orchestration state
ls docs/orchestration/dag.v0.json         # is there a plan?
```

If `singular` is missing, install the engine:

```bash
git clone https://github.com/xiperinc/singular-lite /path/to/singular-lite
cd /path/to/singular-lite && bash install.sh
export PATH="$HOME/.singular/bin:$PATH"
```

In a repo whose state you do not already know — never orchestrated, or on an
older pin or schema — run the one command that composes the whole lifecycle:

```bash
singular setup                 # -> a verified, STOPPED repo; ends with one Next: line
singular setup --no-test       # stop at `validated`, without the regression run
singular setup --test-async    # start the regression run detached, attach later
singular setup --json          # one singular.setup-report.v0 object on stdout
```

`singular setup` is idempotent and never actuates. It checks interpreter, repo
root, and git work tree; resolves the engine pin (naming the winner when
`.singular-version` and `singular.config.json` `engineVersion` disagree);
installs the pinned engine if absent — **only from a matching engine checkout
already on this machine, there is no download path**; writes
`.singular-state/STOP` as its first repo write; pins and scaffolds
(`singular init`) when needed; hashes every existing gate result; prints the
migration chain and then runs it (`singular migrate`); verifies those historical
verdicts survived; runs `singular doctor`; and records a supervised regression
run (`singular test`). Prerequisites fail *before* anything is mutated, each
with a stable code and one recovery instruction
(`singular.operator-failure.v0`); evidence lands in `.singular-state/setup/`.

It reports a state ladder — `installed → migrated → validated → stopped-ready`
— claiming only what it reached, then exactly one next action:

```text
State: stopped-ready (STOP active; no workers dispatched)
Next: singular resume
```

Treat that line as the next available action within the requested scope.
Setup never removes STOP: lifting it
is the separate, explicit actuation step, and when a human gate is pending the
one next action is that gate instead. Full step order, failure codes, and the
`singular test` contract: [references/operations.md](references/operations.md).

`singular init` on its own still scaffolds `singular.config.json`,
`docs/orchestration/`, and `.singular-version` when scaffolding is all you want.

Either way, edit `singular.config.json` before anything will run:

- `targetBranch` — the integration branch workers merge into (use a working
  branch like `agent/integration`, not `main`; promote to `main` manually at
  milestones).
- `gateCommand` — the command that proves the repo healthy (e.g.
  `bash tests/run.sh`, `npm test`). The scaffold ships `false` on purpose so
  an unconfigured repo fails closed — replace it.
- `runner` — which agent CLI drives the roles: `claude-run.sh`,
  `codex-run.sh`, `gemini-run.sh`, `opencode-run.sh`, `cursor-run.sh`,
  `openrouter-run.sh`, or `grok-run.sh` (switchable later, e.g. on provider quota walls —
  from the console's Providers tab, or by writing `SINGULAR_RUNNER` to config
  `env{}`, which overrides the top-level key). Check install/auth status per
  provider with `singular doctor` or `singular console --providers`.
  `engine/providers.json` records provider identities, model defaults and
  executable requirements; OpenRouter uses the OpenCode executable.
- `areas{}` — named file-scope groups: each key maps to an array of path
  prefixes, e.g. `"areas": {"api": ["src/api/", "tests/api/"], "core":
  ["src/core/", "tests/core/"]}`. DAG nodes reference an area by key and
  worker owned-file scopes are checked against its prefixes.
- `env{}` — record deliberate setting overrides here. See the default and
  effect tables in [references/operations.md](references/operations.md).
  JSON config overrides incoming shell values; shell config and then local
  config can override JSON. Check these layers when setting `SINGULAR_PUSH=0`.

Also rewrite the scaffolded role prompts in `docs/orchestration/prompts/`
for the repo's stack, and customize `docs/orchestration/planner-contract.md`
(section 2). Re-run `singular doctor` until clean.

The engine's own regression suite — the last thing `singular setup` does, and
the way to re-verify an engine after an environment change — is a supervised
job rather than a foreground command:

```bash
singular test                    # start a run, or attach to the live one
singular test --status [--json]  # what the current run is doing
singular test --wait             # attach to the live (or last recorded) run
singular test --rerun-failures   # re-run only the last completed run's failures
```

One live run at a time: a second `singular test` attaches instead of starting a
duplicate (`--new-run` is the explicit override). Liveness is proved by a lock
the kernel releases on any death, never guessed from a pid, so a supervisor
killed mid-run reconciles to `interrupted` with the counts it reached rather
than looking finished. Evidence survives the session that started it, under
`.singular-state/test-runs/<runId>/`.

The suite runs only from an engine **checkout**: most tests build disposable Git
worktrees of `HEAD`, and an installed engine (`~/.singular/versions/<ver>/`) is a
plain copy with no history — it ships no `tests/`. On one, `singular test` refuses
before creating anything (`SINGULAR_TEST_SUITE_UNAVAILABLE`, or
`SINGULAR_TEST_SOURCE_UNSUPPORTED` for a suite in a non-checkout tree), and
`singular setup` reports the same code as a warning and finishes at `validated`
instead of failing a repository that is otherwise correctly prepared. Record the
run from the consumer repo against a checkout — the evidence still lands in the
repo you are in:

```bash
SINGULAR_ENGINE_HOME=/path/to/engine-checkout singular test
```

## 2. Author the plan (DAG)

The plan is `docs/orchestration/dag.v0.json` (schema
`singular.orchestration.dag.v0`). `singular init` scaffolds it with a single
starter node — replace that with your real graph. Each node needs `id`,
`stage`, `area`, `layer`, `kind`, `dependsOn`, `requiredCompletion`
(+ optional `description`):

```json
{
  "id": "api-contract",
  "stage": "S1",
  "area": "api",
  "layer": "contract",
  "kind": "contract",
  "dependsOn": ["scaffold"],
  "requiredCompletion": "OpenAPI schema validates fixtures; contract tests green",
  "description": "Owns schemas/api/*; later api nodes build on this."
}
```

Represent real dependencies in the graph. The dispatch frontier contains
ready nodes; parallel planners, when enabled, are bounded by planner and
resource limits:

- **Minimal, honest `dependsOn`.** Every edge you add narrows the frontier.
  Depend on a node only when its output is genuinely consumed.
- **Non-overlapping areas.** Nodes running in parallel should own disjoint
  file scopes so their L2 workers integrate without conflicts. Give each node
  a clear file-ownership boundary in its description.
- **Small nodes, behavior-level `requiredCompletion`.** State it as a
  checkable outcome ("test X green", "command Y emits Z") — it becomes the
  gate promotion criterion.
- **Stages are waves, not locks.** `stage` groups nodes for humans; only
  `dependsOn` constrains scheduling.

Validate and inspect the frontier:

```bash
singular validate-dag
singular next-areas       # every currently-ready node
```

Tasks can be hand-authored or generated by L1 planners. A planner for a
frontier node decomposes it into tasks under
`docs/orchestration/tasks/TASK-XXXX.md` and stages them for L0 import. Your
lever over task quality is `docs/orchestration/planner-contract.md` — binding
rules the planners must follow (file conventions, scope discipline,
test-first policy, bundling of small dependent slices). To hand-author a task,
copy `docs/orchestration/tasks/TEMPLATE.md`.

For the full DAG field semantics, task-file format, planner-contract
patterns, and a checklist before first actuate, read
[references/plan-authoring.md](references/plan-authoring.md).

## 3. Choose how to run

Direct commands let the operator select one task or one cycle:

```bash
singular reconcile --actuate    # one cycle: import → recover → integrate → dispatch
singular reconcile --drain      # wait for detached workers to exit
singular drive TASK-0042        # one task through worker, gate and audit
```

The optional `singular auto` loop repeats reconcile cycles until DAG
exhaustion, the wall-clock budget, STOP or the no-progress breaker.
`singular auto` and the launchd launcher default `SINGULAR_PUSH` to `1`:
integration pushes the target and worker branches to `origin`, and reconcile
also pushes the target branch after a control-state commit. Set
`SINGULAR_PUSH=0` in the effective configuration to disable those pushes.
Direct commands such as `singular reconcile --actuate` and `singular integrate`
default to no push (`0`); they can push if explicitly configured with `1`.
Automatic integration defaults to `1` on all these entry points.

For a requested unattended run with pushing disabled (ensure config does
not override the shell value):

```bash
SINGULAR_PUSH=0 singular auto --detach
```

This supported detached launch writes `.singular-state/autonomate.log` and
tracks loop liveness with a pidfile. Use section 4 to monitor it.

### launchd defaults (macOS)

`templates/launchd/run-orchestrator.sh` defaults to `--watchdog`, which
runs the auto loop; the plist invokes it every 1800 seconds. It requires
Git, Go, Bash >=4, a runnable Codex executable and a readable Codex auth file,
even if the repo selects another runner. Its fallback target branch is
`codex/singular-bootstrap-target`. Configure the consumer root and engine
home when installing the LaunchAgent. The wrapper reads local settings from
`SINGULAR_ENV_FILE`, defaulting to `.singular-state/.env` in that consumer.

The launchd launcher supplies these defaults before the engine loads repo
configuration; existing values or later config layers can override them:

| Setting | Launcher default |
| --- | --- |
| `SINGULAR_PUSH` | `1` (set `0` to disable pushing) |
| `SINGULAR_AUTO_INTEGRATE`, `SINGULAR_GENERATE`, `SINGULAR_AUTO_PROMOTE_GATES` | `1` each |
| `SINGULAR_L2_SANDBOX` | `danger-full-access` (Codex worker sandbox) |
| `SINGULAR_ENABLE_L1_PARALLEL`, `SINGULAR_DETACHED_DISPATCH` | `1` each |
| `SINGULAR_MAX_CONCURRENT`, `SINGULAR_MAX_DISPATCH`, `SINGULAR_MAX_L1_CONCURRENT` | `auto` each |
| `SINGULAR_L1_TASKS_PER_NODE`, `SINGULAR_L2_SLICE_BUDGET` | `1` each |
| `SINGULAR_L2_SLICE_BUDGET_MAX` | `3` |
| `SINGULAR_MAX_HOURS` | `12` (launchd launcher) |

Control and safety:

- **Stop:** `singular stop --wait` writes STOP and waits up to 300 seconds
  for the auto loop to exit (`--wait=SECONDS` sets the bound). STOP suppresses
  new dispatch; it does not kill running workers.
  `singular resume` removes STOP but does not restart an exited loop.
  Never remove a STOP file you did not create without asking the user.
  This also applies to `singular resume` and `singular wake`; use
  `singular wake --keep-stop` to preserve STOP when ending a nap.
- **Budget:** `SINGULAR_MAX_HOURS` caps the auto loop's wall-clock (default
  20h in the engine; launchd supplies 12h). The breaker trips after
  `SINGULAR_MAX_CONSEC_FAILS` (default 5)
  consecutive no-progress cycles.
- **Throughput check:** effective batch width is
  `SINGULAR_MAX_CONCURRENT − active leases`. If parallelism looks pinned at 1,
  sweep `.singular-state/leases/*.json` for stale non-terminal leases and run
  `singular recover --scan`.

## 4. Monitor

**Heartbeat loop (use this for periodic supervision — do NOT re-read this
skill or run a full command battery per poll):**

```bash
singular console --ensure   # once: prints the dashboard URL (idempotent)
prev=""
while sleep 60; do
  d="$(singular health --json)"          # <2s digest: gates, frontier, leases,
  cur="$(jq -r .digest <<<"$d")"        # backoff, breaker, STOP, disk, attention[]
  [[ "$cur" == "$prev" ]] && continue   # digest unchanged -> nothing to do
  prev="$cur"
  jq '{ok, gates, attention}' <<<"$d"
  # attention[] non-empty or ok:false -> read the Recovery recipes in
  # references/operations.md and act; otherwise keep looping.
done
```

The `digest` field hashes everything except the timestamp — comparing it is
the whole cheap-poll contract. `attention[]` names exactly what needs an
operator (STOP present, backoff active, breaker open, stale L1 leases, disk
below floor, autonomate dead).

Deeper inspection when something changed:

```bash
singular status                  # orchestration status (incl. console URL when live)
singular gates                   # per-node gate table
singular next-areas --explain    # frontier + per-node exclusion reasons
singular metrics                 # read-only per-task/aggregate context metrics
singular console --snapshot      # one-shot JSON health snapshot, no browser
singular console --task TASK-0042   # one-shot task detail JSON
```

The console is a web UI over orchestration state — an app shell whose left
sidebar lists plan threads (live + archived) plus an app-level Providers nav,
with Home/Plan/Consoles/Agents as thread-scoped tabs; Home also carries the
supervisor briefing/chat and provider quota gauges. Orchestration state stays
read-only for tasks, leases and gates. Settings POSTs change whitelisted
config knobs; ask/report POSTs launch supervisor runs and write their artifacts.
Start/reuse it with `singular console --ensure` (URL persists in
`.singular-state/console.url`; `--status`/`--stop` manage it). Ground rules:
durable state is authoritative, "active" is derived from live facts (pids,
active leases, worktrees) — never from markdown claims or bare lease-file
existence. Full console usage, all API endpoints, and derived-state rules:
[references/console.md](references/console.md). Canonical artifact file map +
jq cookbook (exact field names per artifact):
[references/artifacts.md](references/artifacts.md).

While a run is live, watch for: worker liveness vs lease count, planner
failures (only fatal when a cycle produced nothing), and **free disk** — a
full volume shows up as confusing all-red gate runs, not as a disk error.

### Supervisor briefing & ask (0.10.0)

A read-only overseer can narrate the run and answer questions. It is
propose-only: it may suggest settings but never writes them — a human applies
them (the console's Apply chips write through the settings whitelist).

```bash
singular report                       # request a one-shot briefing (stage, risks, next steps)
singular ask "where are we?" --wait   # ask the supervisor; --wait tails to the answer
```

Both spawn a readonly one-shot agent over a state digest (STATUS, health,
frontier, gates, recent events, config). Auto-briefings are off by default; set
a cadence with `SINGULAR_SUPERVISOR_INTERVAL_MIN` (minutes, `0` = off — the L0
loop then briefs at most once per interval), and bound the runners with
`SINGULAR_SUPERVISOR_TIMEOUT_SEC` (900) / `SINGULAR_ASK_TIMEOUT_SEC` (600).
Briefings land in `.singular-state/supervisor/latest.json`; the console Home
shows the latest one plus a propose-only chat, and ask/report runs appear in
Consoles. See [references/console.md](references/console.md).

## 5. Completion, gates, recovery

When all of a node's tasks are integrated and its `requiredCompletion` is
demonstrably met, promote its gate:

```bash
singular area-gate <node-id>      # check gate status
singular promote-gate <node-id>   # write the gate result
```

`promote-gate` runs the repo's promoter script (`SINGULAR_PROMOTER`, default
`<engine>/singular-ext/promote-gate.sh`), which validates the evidence it is
configured to demand and writes `gates/<node>.gate-result.json`. You are
responsible for verifying the evidence is real before invoking it.

Since 0.5.0, gates auto-promote at integrate time (`SINGULAR_AUTO_PROMOTE_GATES=1`
default) — manual promotion is the exception, not the routine.

Promotion discipline (these have each caused real incidents):

- Promote only when the packet inbox is empty and every one of the node's
  task files is integrated or satisfied (superseded/blocked predecessors with
  an integrated successor count as satisfied since 0.5.0). Concrete check:
  `singular status` reports the inbox packet count; it must read 0.
- Never run `promote-gate` concurrently with a live reconcile cycle: the
  cycle's git operations clobber uncommitted gate files. Promote in a
  wait/drain window (`singular stop --wait` … `singular resume`).
- Evaluation nodes (`kind: evaluation`) are authority decisions. Under schema
  v2, record a first-class `human-gate` request and exact-artifact approval.
  The older `singular promote-gate <node> --operator --evidence <ref>` route is
  rejected unless `legacyCompatibility.unboundWaivers` is explicitly enabled.
  A node declaring `authority: agent-review-allowed` in the DAG may also
  promote on a valid PASSING review file at
  `gates/evidence/<node>.review.json` (gate-review.v0: independent reviewer
  identity, evidence refs, and headSha ancestor check). A failed review never
  writes a failed gate.
- A planner's "this node is already complete" refusal may be premature;
  re-read the claim after the last integration before promoting on it.

**Escalation contract:** when the frontier consists only of evaluation/
operator nodes, report ONCE to the operator with the exact required action
(the promote-gate command line or the review-file path), then idle — do not
re-notify every poll, do not silence the condition, and never weaken the gate
to make progress.

Recovery is CLI verbs since 0.5.0 — never hand-edit state files:

```bash
singular unpark TASK-XXXX                     # parked task -> frontier (status, lease, retry budget)
singular supersede TASK-XXXX --by TASK-YYYY   # all four surfaces atomically
singular clear-backoff                        # false/stale planner backoff
singular breaker reset                        # after fixing the failing class
singular wake                                 # backoff+breaker+STOP+nap, one shot
singular recover --scan                       # stale L2 + L1 leases, orphans
singular accept-packet <packet.json>          # stranded accepted work (usually automatic)
singular gc --dry-run                         # runs-history/worktrees/events hygiene
```

Numbered recipes per incident class (symptom → verify → command → expected
event) are in [references/operations.md](references/operations.md) — read it
before debugging a stuck or misbehaving run.

### Plan threads — finish one plan, start the next (0.8.0)

A repo holds one *active* plan; finished plans become read-only archived
threads (chat-style):

```bash
singular plan archive --name "Console redesign"   # snapshot + reset to starter DAG
singular plan list [--json]                       # registry of archived threads
```

`plan archive` refuses unless the run is truly finished: autonomate loop
stopped, origin lock free, no live dispatch trees, DAG frontier
`allComplete`, and `.worktrees/` empty (`singular gc` first). Each guard is
override-able with `--force`, but worktrees are never moved. It snapshots
the plan into `.singular-state/plans/<plan-id>/` (a mini-repo the console
can serve read-only: DAG, tasks, gates, areas, packets, events, runs,
leases, dispatch records + a `manifest.json`), keeps `prompts/`,
`planner-contract.md` and `decisions.md` live (copied into the archive),
then resets to the init starter DAG with a fresh event journal seeded by a
`plan.archived` event and commits the `docs/orchestration` reset
(`--no-commit` to skip). Task numbering restarts at TASK-0001. Author the
next plan exactly as in §2. Archived threads are browsable in the console
via the sidebar threads list / Home "Previous plans" card, or
`singular console --plans` (see [references/console.md](references/console.md)).

## Invariants — do not weaken

- `gateCommand` and gate results are the floor of truth; never bypass or
  soften them to make progress.
- The advocate/skeptic line: planner/implementer sessions never satisfy
  critic/auditor steps, and resumed sessions never satisfy an
  independence-required step.
- `.singular-state/`, `.worktrees/`, and `.singular-evidence/` are runtime
  state — never commit them, never hand-edit them. Every sanctioned mutation
  has a verb: `singular stop/resume`, `clear-backoff`, `breaker reset`,
  `supersede`, `unpark`, `wake`, `gc`.
- Singular executes repo-configured shell commands and launches coding
  agents; review `singular.config.json` and task files before running it in a
  repo you don't trust.
