https://github.com/user-attachments/assets/826bf112-645b-4293-8b63-cf1c8ad6038b

# singular

**Autonomous multi-agent orchestration for software repos. One engine, many consumers.**

singular is a bash + Python orchestration engine that drives autonomous AI coding agents
in parallel against a repository. It implements a three-tier scheduling model
(L0 scheduler → L1 drivers → L2 worker agents) with durable leases, state packets,
gate/audit pipelines, and git-worktree isolation. The engine is installed once per machine
and pinned per consumer repo — improvements propagate by bumping a version pin, not by
re-copying scripts.

## How it works

### Scheduling tiers

| Tier | Role |
| --- | --- |
| **L0 origin** | Bash control loop (`autonomate.sh` / `reconcile.sh`), not a model agent. Imports packets, recovers leases, integrates completed work, schedules planning and dispatch, and writes snapshots. |
| **L1 drivers** | Bash orchestration: `l1-plan-node.sh` invokes a model planner for a DAG node and stages its proposals; `l1-drive.sh` drives one task through worker, gate, audit and bounded recovery. L1 is not itself a persistent model agent. |
| **L2 workers** | Execute a single task in an isolated git worktree on a per-task branch. Produce a state packet (owned files, changes, evidence). An auditor reviews the packet; the decider routes the outcome. |

### Reconcile cycle

Each `singular reconcile --actuate` runs:

1. **Import** — validate and import completed state packets from the inbox.
2. **Recover** — reclaim stale leases whose workers have exited or timed out.
3. **Integrate** — merge completed worker branches into the target branch under the git-op lock.
4. **Plan and dispatch** — generate tasks when needed, import staged planner proposals, pre-lease frontier tasks and launch L1 task drivers, which invoke L2 workers.
5. **Snapshot** — write a human-readable project state snapshot.

### Leases and packets

Every in-flight task holds a **lease** (a JSON file in `.singular-state/leases/`) that records
ownership, retry count, and expiry. When a worker finishes it writes a **state packet**
(`state-packet.v0.schema.json`) enumerating owned files, changed files, commands, tests, and
evidence. The auditor validates the packet; the reaper attributes outcomes on later cycles.

### Gates and audits

After each L2 worker run the host executes the configured **gate command** (e.g. `npm test`).
A gate result (`gate-result.v0.schema.json`) feeds the **auditor** model, which returns an
audit verdict (`audit-verdict.v0.schema.json`). The **decider** maps the
`(failure-class, retries-left)` pair to a recovery action — retry, amend-scope, escalate, or
park — using a deterministic fast-path table before falling back to a model round-trip.

A bare command works: exit 0 passes, non-zero fails. The exit code cannot answer
two questions the engine would use if it could, so a gate may optionally write a
**gate observation** (`gate-observation.v0.schema.json`) to the path in
`SINGULAR_GATE_REPORT_FILE`:

- `failures[].signature` — stable per-failure identifiers. Required for
  `singular gate baseline` to tell an acknowledged failure from a new one.
- `infrastructureFailure` / `infrastructureReason` — the gate could not **run**
  (missing dependencies, full disk, unreachable network). The engine reports
  that as `inconclusive-infrastructure` instead of spending a task's retry
  budget asking a model to fix code that was never broken.

Review rounds are independently bounded. `reviewPolicy` in
`singular.config.json` (defaults: two rounds, P0/P1 blocking, classification
required) plus `SINGULAR_REVIEW_*` env overrides decide when a `needs-fix`
verdict is still blocking, when P2/P3 findings become backlog, and when the
drive must park instead of spending another product repair. See
[`docs/review-policy.md`](docs/review-policy.md) and
`singular review-policy --help`.

Two guards are off by default. `SINGULAR_RED_PROOF` makes the host run a task's
declared proof tests on the base and on the candidate before the audit
([`docs/red-proof.md`](docs/red-proof.md)). `SINGULAR_ACCEPTANCE=every-path`
applies the driver's acceptance rule again at packet import, integration,
`singular accept-packet` and recovery
([`docs/acceptance.md`](docs/acceptance.md)).

`singular init` scaffolds `docs/orchestration/gates/gate.sh` as a starting point.
The sidecar is never required — including on `schemaVersion: v2`. Without one
the engine falls back to the exit code plus a deliberately narrow set of log
signatures (`engine/infra-patterns.tsv`) covering only environment failures that
application code cannot plausibly produce.

**How many times a gate runs per task (0.21.0).** The host runs the consumer's
gate once in the worker's worktree after the worker commits (`gate-check.sh`;
the model never runs it), once more on a disposable checkout of the exact
staged merge tree at integration, and cites that integration proof at
promotion when the promoted tree is byte-identical
(`.singular-state/proofs/<tree>.json`, `gate_promotion.proof_reused`). The
disposable rerun before the auditor is risk-scoped: `SINGULAR_AUDIT_VERIFY=auto`
(default) reruns only for a high-risk task, a worker gate that is not a clean
`passed` at the exact committed head, a source-integrity anomaly, or a report
from another phase; `1` always reruns, `0` never. The verification
classification the auditor must echo is a host fact — a mismatching echo is
rewritten to the host value (`l1.audit_verification_normalized`) rather than
paid for with another auditor pass.

**What the host is strict about in a verdict, and what it repairs (0.23.6).**
The verdict value, the task/branch identity, the verification classification
and which findings block under the review policy carry authority and are never
adjusted. Format that carries none is normalised before validation instead of
being refused: properties the schema does not define inside a
`classifiedFindings[]` or `verificationResults[]` item are dropped, and an
`accepted` verdict that reports a prior finding `still-open` without repeating
its text is completed from the host's own record of that finding (P2/P3 goes to
`findings` as backlog; a blocking prior goes to `requiredFixes`, so the review
policy returns `needs-fix`; a prior whose severity the host cannot establish is
still refused). Every change is written to the verdict's `hostNormalization`
member and the `l1.audit_verdict_normalized` event, and the response as received
is kept as `audit.json.pre-format-normalize.json`. Unknown top-level members
stay fatal. `SINGULAR_AUDIT_FORMAT_NORMALIZE=0` restores the strict behaviour.

When the one format-repair retry is also refused but the response names the
right task and branch, carries a legal verdict value and echoes host
classifications, the drive ends as `awaiting-audit`, not `escalate-infra`: the
gated candidate is retained, nothing is accepted, no product repair or review
round is charged, and the refused response is moved off `audit.json`.
`singular health` lists the candidate with the command that re-runs only the
audit:

```bash
singular drive TASK-1234 --audit-only
```

That pass replays the retained worker packet instead of launching an
implementer, reruns the gate on the unchanged head, and audits it from nothing.
It refuses when the branch has moved. A task parked as `escalate-infra` by an
earlier engine with the refused response still in `audit.json` (later drives
answer `accepted-checkpoint-invalid-retained-state`) is adopted by the same
command.

Host verification is identity-bound. A worker-side request names the task,
attempt, exact commit/tree, campaign, policy contract and suite; it does not
contain an executable command. `gate-check.sh` and `audit-verify.sh` resolve the
command from the trusted task contract, reject packet-command fields, and bind
the result to the request plus the full log hash. Contract/policy drift,
malformed requests, changed candidates and missing/tampered logs fail closed.
When a focused test run has readable history but the checkout's shared Git
worktree registry (or the temporary probe workspace) is unavailable, the
harness prints `HOST_REQUIRED ... unrun` and still executes the focused body.
The unfiltered canonical suite remains host-required, and a genuine body
failure remains a failure.

Failed accepted candidates are retained. A host can authorize either a repair
in a distinct run/branch/worktree or one unchanged-code regate with:

```bash
singular recover candidate TASK-1234 --action repair \
  --successor-run RUN-NEW --successor-branch agent/core/TASK-1234-repair \
  --successor-worktree /absolute/path/to/new-worktree --failure-id FAILURE-ID
```

The generated authority binds the predecessor packet/audit/contract,
commit/tree, campaign/policy, eligible failure and successor action. It is
claim-once and crash-resumable only for the exact same successor identity while
execution is incomplete. A completed failed execution closes that claim and a
new host authorization must bind the resulting failure before another launch.
Recovery limits are checked both when authority is issued and when execution is
claimed, so a stale issued record cannot bypass a changed or exhausted ceiling.
Ordinary integration retries use the same limits: an unchanged recorded
failure is suppressed regardless of whether it came from product behavior,
host infrastructure, report validation, setup or finalization. A relevant
input change permits another ordinary attempt only while that failure domain
still has capacity.
Repair candidates always need a fresh accepted audit even when the
tree is unchanged; regate keeps the exact candidate and prints the bound
`singular integrate --run-id ...` next action. `singular health --json` exposes
retained candidates with dependencies, reason/domain, owner, budgets and the
permitted next action. Product, infrastructure and regate failures are counted
once by durable failure identity in separate counters. The identity includes an
active recovery action and successor attempt, and integration consumes the gate
report's product/infrastructure outcome instead of charging every red exit as a
product failure. Supported accepted audit schemas and waiver acceptance also
revalidate their exact host verification request, result and policy through the
canonical gate-report validator before retention or recovery. Accepted audit
authority is bound to exactly one reviewed-head marker for the candidate commit,
so a new commit cannot reuse an earlier audit even when its tree is unchanged.

## Dispatch model

**Detached dispatch is ON by default.** When `SINGULAR_DETACHED_DISPATCH=1` (the default),
`reconcile` pre-leases each frontier task and spawns the worker in its own session via
`dispatch-wrap.sh`, then returns within seconds. The origin lock is held only for the cycle's
control work. A **reaper** (`singular_reap_dispatches`) runs at the top of every
apply/actuate cycle and attributes completions, failures, and crashes by checking dispatch
records + worker exit files (pid liveness defeats pid reuse; crash detection drops from the
60-min stale-lease window to ~one cycle).

This is what keeps import, integrate, recover, STATUS, and STOP responsive while long
workers run in the background.

Set `SINGULAR_DETACHED_DISPATCH=0` to restore the legacy synchronous batch path, where
`reconcile` waits for every worker before returning.

## Install

Prerequisites:

- Bash >= 4, `python3`, and `git`.
- At least one supported runner CLI on `PATH` (`claude`, `codex`, or another
  configured runner). The shipped providers are `codex`, `claude`, `gemini`,
  `opencode`, `cursor`, `openrouter` and `grok`; each is one row in
  `engine/providers.json` and one `engine/<provider>-run.sh` adapter, and
  `singular doctor` verifies the selected one's executable, authentication and
  configured model before a run starts.
- **OpenRouter** needs no CLI of its own: set
  `SINGULAR_OPENROUTER_MODEL=openrouter/<vendor>/<model>` (any id from
  <https://openrouter.ai/api/v1/models>) plus `OPENROUTER_API_KEY`, and select
  `openrouter-run.sh` as the runner. It dispatches through the installed
  `opencode` CLI, and doctor checks the configured model against OpenRouter's
  own catalog rather than a naming convention.
- macOS users may need `brew install bash`. Set
  `SINGULAR_BASH_BIN=/opt/homebrew/bin/bash` in the shell/service environment to
  select it without reordering `PATH`.
- When multiple Codex installations exist, set
  `SINGULAR_CODEX_BIN=/absolute/path/to/codex`. Doctor and the runner use that
  exact executable and do not fall back when it is broken.

```bash
# Clone and install the engine to ~/.singular
git clone https://github.com/xiperinc/singular-lite /path/to/singular-lite
cd /path/to/singular-lite
bash install.sh
# -> ~/.singular/versions/<ver>/  ~/.singular/current  ~/.singular/bin/singular

export PATH="$HOME/.singular/bin:$PATH"
```

Singular uses `SINGULAR_*`, `singular.config.json`, `.singular-version`,
`.singular-state/`, and the `SINGULAR_HOME` install root (default `~/.singular`).
Use `singular setup` for a new consumer. For an existing consumer, setup
checks the schema, prints the migration plan, then runs the supported migration
chain automatically; the migrations
rewrite legacy schema identifiers while preserving historical gate verdicts.
Setup also mirrors STOP into an existing legacy state directory. It does not
copy that directory's contents into the current state root. See
[upgrading an existing project](docs/upgrade.md).

In each consumer repo:

```bash
singular setup     # one idempotent path from "a repo" to a verified, STOPPED repo
```

`singular setup` composes the individual lifecycle verbs and contributes the
order, the evidence, and the contract. It checks interpreter/repo/git work tree,
resolves the engine pin (naming the winner when `.singular-version` and
`singular.config.json` `engineVersion` disagree), installs the pinned engine when
it is absent — only from a matching engine checkout already on this machine,
since there is no download mechanism — writes `.singular-state/STOP` as its first
repo write, pins and scaffolds, hashes every gate result before printing and
running the migration chain, verifies those historical verdicts survived, runs
doctor, and records a supervised regression run. Prerequisites fail before
anything is mutated. It reports a state ladder
(`installed → migrated → validated → stopped-ready`), never actuates, and prints
exactly one `Next:` line. Failures carry a stable code and one recovery
instruction (`singular.operator-failure.v0`); evidence lands under
`.singular-state/setup/`.

```bash
singular setup --no-test      # stop at `validated`, without the regression run
singular setup --test-async   # start the suite detached; attach with singular test --wait
singular setup --json         # one singular.setup-report.v0 object on stdout
```

The composed steps are still available on their own:

```bash
singular init      # scaffold singular.config.json, docs/orchestration/, .singular-version
singular doctor    # check deps, engine resolution, repo config
singular migrate   # raise schemaVersion to the engine's (--dry-run prints the chain only)
```

`SINGULAR_BASH_BIN` is bootstrap-only and is ignored in `singular.config.json`;
set it before invoking `singular`. `SINGULAR_CODEX_BIN` may be supplied through
the normal engine environment/config layers. For the standard Codex runner,
`singular doctor` performs bounded `--version` and `login status` probes against
the exact selected executable.

Doctor is also the machine-readable preflight for unattended runs:

```bash
singular doctor --json | jq '.summary, .checks[] | select(.status != "pass")'
singular doctor --repair-model-cache  # explicit: backup first, then regenerate later
```

Every JSON check has a stable `id`, `severity`, `requiredFor`, `remediation`,
and `dedupeKey`. Required capability failures block doctor; a missing optional
capability produces one warning even when several roles share it. Doctor checks
deployment credentials only while a deployment-capable DAG node is actually in
the ready frontier. It never silently deletes or rewrites Codex model cache
data: the repair flag moves the original to a timestamped, SHA-tagged backup.

Role profiles are local-only by default. Repositories that need extra tools,
MCP servers, or plugins can declare lazy profiles explicitly:

```json
{
  "capabilityProfiles": {
    "audit-core": {
      "startup": "lazy",
      "required": ["filesystem", "git", "schemas", "runner-contract"],
      "optional": ["mcp:browser"]
    }
  },
  "roleProfiles": {
    "auditor": "audit-core",
    "decider": "audit-core"
  }
}
```

Capability IDs may use `mcp:NAME`, `plugin:NAME`, `executable:NAME`, or
`file:REPO_PATH`. More specialized capabilities can be declared in the
top-level `capabilities` registry with a `type` of `builtin`, `executable`,
`file`, `mcp`, `plugin`, or `environment`.
In strict profiles, external skills, MCP servers, and plugins are activated
only by `capabilityArgs.<exact-capability>`; unrelated `providerArgs` never
claim a capability. Legacy `SINGULAR_*_EXTRA_ARGS` variables are rejected for
strict runs because they are not capability-bound.

Each repo pins its engine version in `.singular-version` (overrides `singular.config.json`
`engineVersion`). The `singular` launcher resolves that version from `~/.singular/versions/<ver>`,
binds `SINGULAR_ROOT` to the current repo, loads its config, and execs the engine. Run
`singular update <ver>` to repin.

## Use

```bash
# Run one reconcile/actuate cycle (import → recover → integrate → dispatch → snapshot)
singular reconcile --actuate

# Drive a single task through L1 → L2 → audit
singular drive TASK-0001

# Self-driving autonomy loop (wall-clock budget: SINGULAR_MAX_HOURS)
singular auto

# Create, approve, or inspect an owner- and artifact-hash-bound human gate
singular human-gate request --help
singular human-gate approve --help
singular human-gate status --help

# Report every contract violation in a gate-result at once. The frontier read
# stops at the first breach (correctly — it must not act on an invalid gate),
# which means a promoter under development learns about one violation per run.
singular gate validate docs/orchestration/gates/<node>.gate-result.json

# The old promote-gate --operator route is schema-v2 legacy compatibility only

# Block until all detached workers finish (useful in CI or clean shutdown)
singular reconcile --drain

# Context graph (behind SINGULAR_CTX_GRAPH): project the event log into
# context-graph.v0 JSONL, sync incrementally, and query it
singular graph rebuild
singular graph sync
singular graph query neighbors <node-id>

# Experiment tooling (behind SINGULAR_CTX_EXPERIMENT): per-arm metrics,
# treatment-vs-control delta, and rendered report tables
singular experiment-report summary
singular experiment-report delta
singular experiment-report tables
```

## Configuration

All per-repo variation lives in the consumer repo, never in engine files:

- **`singular.config.json`** — declarative: `targetBranch`, `gateCommand`, `runner`,
  `areas{}`, `areaPrefix`, `prewarm`, `worktreeCopyPaths[]`, `modules[]`,
  `identity{}`, `env{}`, `provisionFiles[]`, `envAllowlist[]`,
  `capabilityProfiles{}`, `roleProfiles{}`, `roleRunners{}`, `evidence{}`, `bootstrap{}`,
  `resources{}`, `promoter`, `controlState{}`, and `legacyCompatibility{}`.

### Worker concurrency: the resource governor

`resources.maxConcurrent` (env `SINGULAR_MAX_CONCURRENT`) defaults to
**`"auto"`**: every reconcile cycle sizes the worker ceiling from the machine it
is running on and takes the smallest of three budgets.

| Budget | Slots | Tunables (`resources{}` key / env, default) |
| --- | --- | --- |
| CPU | `min(autoMaxConcurrent, floor((cores - cpuReserveCores) * workersPerCore))`, at least 1 | `autoMaxConcurrent` / `SINGULAR_AUTO_MAX_CONCURRENT` `8`; `cpuReserveCores` / `SINGULAR_CPU_RESERVE_CORES` `2`; `workersPerCore` / `SINGULAR_WORKERS_PER_CORE` `1` |
| Memory | `running workers + floor((available - memoryReserveBytes) / estimatedWorkerBytes)`, at least 1 | `estimatedWorkerBytes` / `SINGULAR_ESTIMATED_WORKER_BYTES` 1 GiB; `memoryReserveBytes` / `SINGULAR_MEMORY_RESERVE_BYTES` 2 GiB |
| Disk | `floor((free - diskReserveBytes) / estimatedWorktreeBytes)` (unchanged; may be 0, which is low-disk mode) | `diskReserveBytes`, `estimatedWorktreeBytes` |

A worker is an agent CLI that mostly waits on a remote model, so one per core is
affordable; two cores are kept for the loop itself and the operator, and the cap
of 8 is where serial integration and provider rate limits, not this machine,
become the bottleneck. Available memory is `MemAvailable` on Linux and free +
inactive + speculative + purgeable pages (`vm_stat`) on macOS. On a 12-core host
with 9 GiB available that is `min(8, 7, disk)` = 7 workers.

An **explicit integer** keeps the pre-governor rule exactly — `min(integer, disk
slots)`, same record, same reasons — and is a fixed upper bound. Use it to pin a
ceiling deliberately; `singular doctor` warns when it is at most half or at least
twice what the machine supports.

Separately from the ceiling, each cycle checks **live pressure** before admitting
anything new. The signal is **CPU utilisation**: the busy fraction of all cores
over a short window (`cpuSampleSeconds` / `SINGULAR_CPU_SAMPLE_SEC`, `1`),
read from `top -l 2 -n 0` on macOS and from two readings of `/proc/stat` on
Linux (iowait counts as idle). When it is above `cpuBusyHighWater`
(`SINGULAR_CPU_BUSY_HIGH_WATER`, `0.90`), or available memory is below
`memoryReserveBytes`, the cycle starts **no new worker and no new planner**;
running work is never stopped, and integration, promotion and imports continue.
Admission resumes once the CPU is below `cpuBusyLowWater`
(`SINGULAR_CPU_BUSY_LOW_WATER`, `0.75`) or memory is back above the reserve
plus one worker — the gap is deliberate, so the loop does not flap. This
applies to explicit ceilings too; `"throttle": false`
(`SINGULAR_RESOURCE_THROTTLE=0`) turns it off.

**Why not the load average.** Until 0.23.6 the signal was the 1-minute load
average per core. It counts threads blocked on I/O and lags by a minute: on a
12-core macOS host it read 15–30 while the CPU was 55% idle, so the governor
throttled an idle machine, and at another moment 30 with the CPU 0% idle, where
throttling was right. Load per core is now only the **fallback**, used when the
CPU cannot be sampled (the probe failed, or `SINGULAR_CPU_SAMPLE_SEC=0`), with
its own marks `loadHighWater` (`SINGULAR_LOAD_HIGH_WATER`, `1.5`) and
`loadLowWater` (`SINGULAR_LOAD_LOW_WATER`, `1.0`). `pressureSignal` in the plan
says which one decided (`cpu-busy`, `load-average` or `none`). A hold taken on
one signal is released by the other's low-water mark.

Tests and scripts inject the facts instead of measuring: `--cpu-busy` /
`SINGULAR_RESOURCE_CPU_BUSY` (a fraction in `[0,1]`), and a caller that injects
the load (`--load-1m` / `SINGULAR_RESOURCE_LOAD_1M`) is not sampled at all, so
it exercises the fallback deterministically. `singular health` and
`singular doctor` reuse the loop's last sample when it is under 30 s old.

**Minimum-progress floor.** A host saturated by *other* processes never falls
back under the low-water mark, so a strict hold would stop the loop for good.
When the hold would apply and the loop has nothing running at all — no active
worker and no active planner — the cycle admits exactly one unit of work: one
worker if a task is runnable, otherwise one planner (never both). The plan says
so: `reason` is `load-high-floor` or `memory-low-floor` and `progressFloor` is
`true` (`cpu-busy-floor` when the CPU signal took the hold). As soon as anything is running the hold is strict again, so the floor
is one unit at a time, not one extra per cycle. `"progressFloor": 0`
(`SINGULAR_PROGRESS_FLOOR=0`) restores the strict hold. A planner counts as
running while its L1 lease is live, so a crashed planner's lease holds the
floor shut until it is reclaimed (`SINGULAR_L1_STALE_MINUTES`).

`origin.resource_plan` records the decision each cycle: `configuredSlots`,
`effectiveSlots`, `availableSlots`, `cpuSlots`, `memorySlots`, `diskSlots`,
`cpuBusy`, `pressureSignal`, `loadPerCore`, `availableMemoryBytes`, `mode`,
`admission` (`open`, `throttled` or `floor`), `progressFloor`, and a `reason`
naming what is binding — `cpu-bound`, `memory-bound`, `disk-bound`, `cpu-busy`,
`load-high`, `memory-low`, `cpu-busy-floor`, `load-high-floor`,
`memory-low-floor`, or for an explicit integer `configured-capacity-available` /
`disk-limited-concurrency`. If the machine cannot be measured, `auto` falls back
to 3 workers and says `probe-unavailable`; a failed probe never stops a cycle.
`singular health` prints the same view, and `singular doctor` reports it as
`resources.machine-capacity`.

Planning follows the ceiling: with `SINGULAR_ENABLE_L1_PARALLEL=1`,
`SINGULAR_MAX_L1_CONCURRENT` defaults to `auto` = half the effective worker
ceiling (`plannerFraction` / `SINGULAR_L1_AUTO_FRACTION`, at least 1, at most
the frontier), and `SINGULAR_MAX_DISPATCH` defaults to the effective ceiling.
Parallel L1 planning itself stays opt-in: the serial planner asks one node for
up to the whole dispatch budget while the fanout asks each node for
`SINGULAR_L1_TASKS_PER_NODE` (default 1), so on a single-node frontier turning
it on by default would plan less per cycle, not more.

### Per-role runners and review isolation

`roleRunners` pins an adapter per role (`implementer`, `auditor`, `planner`,
`critic`, `decider`, `supervisor`, `integrator`). A bare name resolves inside
`engine/`; a relative path is consumer-root relative. Review-evidence delivery
admits an adapter only when `engine/providers.json` declares
`readOnlyEnforcement` for this host **and** the argv is the engine's own file —
copies and wrappers are refused. On macOS, `claude-run.sh` at `--level readonly`
wraps the CLI in `/usr/bin/sandbox-exec` (deny `file-write*` under the worktree,
repo root, and state dir). Codex uses its native OS sandbox on every platform.
Grok has no declared read-only enforcement and is an implementer (l2) runner
only. See `docs/providers.md`.

**`promoter` is the one most consumers need and miss.** It names the script that
decides when a DAG node's gate may be promoted — a bare name resolves to
`<engine>/singular-ext/<name>.sh`, a path is used as-is (repo-relative);
`SINGULAR_PROMOTER` overrides it. The shipped default promotes only nodes in its
own built-in registry, so a repo with its own DAG matches nothing and stalls
after layer 0, reporting only `promotion: no promotable frontier gates` — the
same line a merely not-yet-ready frontier prints. `singular doctor` now names this
directly (`graph.promotability`). Configure a project promoter that registers
your DAG nodes.
Note that evaluation nodes are governed separately, by `authority` on the node:
absent or `operator` means manual promotion, `agent-review-allowed` lets a valid
`gate-review.v0` record promote them.
- **`singular.config.sh`** — optional shell extras (computed values, functions).
- **`.singular-state/config.local.sh`** — gitignored operator overrides and secrets.

The starter config deliberately sets `gateCommand` to `false` so a newly
scaffolded repo fails closed until you replace it with the command that proves
the repo is healthy.

`worktreeCopyPaths[]` names dependency trees to copy into every fresh worktree —
the worker's, the auditor's disposable one, and the deterministic acceptance
one. All three are prepared by the same code path, so a gate that passes for the
worker is running in the same environment when the auditor re-runs it. Copies
are copy-on-write where the filesystem supports it (macOS clonefile, GNU
reflink), falling back to a plain recursive copy. `node_modules` is always
included; the listed paths are **added** to it, so a monorepo declares only its
nested trees:

```json
"worktreeCopyPaths": ["apps/web/node_modules", "packages/ui/node_modules"]
```

A declared path that does not exist in the source worktree is reported and
recorded as a `worktree.copy_path_absent` event rather than skipped silently.

The v2 starter profile is local-only and lazy: each runner role requires the
filesystem, Git, schema bundle, runner contract, and selected provider
executable, while external skills, MCP servers, and plugins must be opted into
explicitly. Evidence composition defaults to 256 KiB, excerpts to 2 KiB,
cumulative raw retrieval to 256 KiB, and the audit input canary to 100,000
tokens. Worktree scheduling reserves 2 GiB, estimates 256 MiB per worktree,
and sets `resources.maxConcurrent` to `"auto"`, using the resource governor's
computed worker ceiling. Semantic control snapshots default to a
300-second interval; set `controlState.commitIntervalSeconds` to `0` only for
legacy every-cycle snapshots.

`bootstrap.commands` is an ordered list of `{command, required, lockfiles}`
records. Every declared lockfile must exist and be tracked before any command
runs; an optional command may warn and continue, while a required failure
blocks the worktree. The singular `bootstrap.command` field remains a legacy
shorthand. Shared-store links must stay under declared roots and target
gitignored, untracked paths.

Schema v2 rejects the historical, artifact-unbound `accept-waiver` and
`promote-gate --operator --evidence` paths by default. Prefer a `human-gate`
request and exact-hash approval. An operator may temporarily restore the old
behavior only by explicitly setting
`legacyCompatibility.unboundWaivers` to `true`.

`provisionFiles` entries copy repo-local, gitignored files into each worker
worktree after `git worktree add`: `{ "source": ".env.local", "target":
".env.local", "required": true }`. The source and target must both be ignored
or provisioning fails closed. `envAllowlist` accepts exact env names or prefix
patterns ending in `*`; allowed values are written to
`worktree/.singular-state/worktree-env.sh` and sourced for prewarm/gate phases.

### Operator env knobs

| Env knob | Configured default | Effective limit / behavior |
| --- | --- | --- |
| `SINGULAR_MAX_CONCURRENT` | `auto` | Maximum L2 workers running concurrently. `auto` sizes it every cycle as the minimum of the CPU, memory and disk budgets (see "Worker concurrency: the resource governor"). An integer is a fixed upper bound that only disk may lower; zero effective slots enters low-disk mode. |
| `SINGULAR_MAX_DISPATCH` | `auto` | Maximum tasks dispatched per reconcile cycle. `auto` / unset follows the effective worker ceiling. |
| `SINGULAR_ENABLE_L1_PARALLEL` | `0` | `1` plans several independent DAG nodes concurrently. Opt-in (the launchd launcher turns it on). |
| `SINGULAR_MAX_L1_CONCURRENT` | `auto` | Parallel L1 planner cap when the fanout is on. `auto` is `SINGULAR_L1_AUTO_FRACTION` of the effective worker ceiling, at least 1; an integer is a fixed cap. |
| `SINGULAR_L1_AUTO_FRACTION` | `0.5` | Share of the worker ceiling given to planners when the planner cap is `auto`. |
| `SINGULAR_AUTO_MAX_CONCURRENT` | `8` | Hard cap on the `auto` worker ceiling. |
| `SINGULAR_CPU_RESERVE_CORES` | `2` | Logical cores left out of the `auto` CPU budget. |
| `SINGULAR_WORKERS_PER_CORE` | `1` | Workers allowed per remaining core. |
| `SINGULAR_ESTIMATED_WORKER_BYTES` | `1073741824` | Memory one worker is assumed to need (agent CLI plus a gate run). |
| `SINGULAR_MEMORY_RESERVE_BYTES` | `2147483648` | Available memory kept free; below it no new work is admitted. |
| `SINGULAR_CPU_BUSY_HIGH_WATER` | `0.90` | CPU busy fraction (all cores, sampled over `SINGULAR_CPU_SAMPLE_SEC`) above which a cycle admits no new worker or planner. The primary live-pressure signal. |
| `SINGULAR_CPU_BUSY_LOW_WATER` | `0.75` | CPU busy fraction below which admission resumes. |
| `SINGULAR_CPU_SAMPLE_SEC` | `1` | CPU sampling window in seconds. `0` never samples, which makes load per core the signal. |
| `SINGULAR_LOAD_HIGH_WATER` | `1.5` | Fallback signal, used only when CPU utilisation cannot be sampled: 1-minute load per core above which a cycle admits no new worker or planner. |
| `SINGULAR_LOAD_LOW_WATER` | `1.0` | Fallback signal: load per core below which admission resumes. |
| `SINGULAR_PROGRESS_FLOOR` | `1` | Under a live-pressure hold with no worker and no planner running, admit exactly one unit of work so a permanently saturated host cannot starve the loop. `0` = strict hold. |
| `SINGULAR_RESOURCE_THROTTLE` | `1` | `0` disables the live-pressure admission gate (the ceiling still applies). |
| `SINGULAR_L1_SKIP_NODES_WITH_OPEN_TASKS` | `0` | With parallel L1 planning, skip a frontier node that still has a task that is ready, in flight or accepted. For consumers whose planner batch covers a whole node: planning it again can only return "nothing to plan", which costs a planner slot per cycle and is recorded as a planner failure. Failed, blocked and parked tasks do not hold the node. |
| `SINGULAR_DETACHED_DISPATCH` | `1` | **Default ON.** Reconcile spawns workers in their own session and returns in seconds; the reaper attributes outcomes on later cycles. Set `0` for the legacy synchronous batch wait. |
| `SINGULAR_AUTO_INTEGRATE` | `1` | Automatically integrate (merge) completed worker branches in direct `reconcile --actuate`, `singular auto`, launchd, and console-driven cycles. |
| `SINGULAR_PUSH` | `0` direct / `1` auto | Push to `origin` after integration and control-state commits. Direct commands default to no push; `singular auto` and the launchd launcher enable it unless `SINGULAR_PUSH=0`. |
| `SINGULAR_MAX_HOURS` | `20` | Wall-clock budget in hours for `singular auto`; the launchd launcher supplies its own value (below). |
| `SINGULAR_MAX_RETRIES` | `3` | Effective product-repair ceiling: 1 for normal risk (including undeclared risk with no override), 2 for high risk. The driver takes the minimum of this setting and the risk-tier ceiling; lowering it can reduce repairs to 0. Review capacity is checked separately before each product pass. |
| `SINGULAR_STALE_MINUTES` | `60` | Lease age (minutes) before a task without a live dispatch pid is reclaimed by the reaper. |
| `SINGULAR_PLANNER_BACKOFF_SECONDS` | `900` | Wait after an ordinary planner failure before planning is attempted again. |
| `SINGULAR_PLANNER_QUOTA_BACKOFF_SECONDS` | `1800` | Wait after a usage limit (429) or entitlement denial (403) — a window the account has to sit out. The loop sleeps through it without incrementing the circuit breaker. |
| `SINGULAR_PLANNER_OVERLOAD_BACKOFF_SECONDS` | `180` | Wait after a provider 503/529. Overload is the provider shedding load, not a usage limit, and typically clears in seconds. It gets the same no-breaker sleep-through as quota but an order of magnitude shorter — before it had its own class one 529 bought the 1800s quota window, and because the nap skips the reconcile cycle entirely it idled the whole graph. |
| `SINGULAR_OVERLOAD_WAIT_BUDGET` | `3600` | Total overload sleep-through before the loop writes STOP. Deliberately separate from `SINGULAR_QUOTA_WAIT_BUDGET` so a burst of 529s cannot spend the usage-limit allowance and stop the loop for a reason that was never a usage limit. |
| `SINGULAR_TARGET_BRANCH` | _(required)_ | Integration target branch in the consumer repo. |
| `SINGULAR_SESSION_AFFINITY` | `1` | Reuse a role's prior runtime session when all staleness gates pass; `0` always runs fresh. |
| `SINGULAR_FIX_PROMPT_STRUCTURED` | `1` | Structured fix prompt on retries (authoritative findings); `0` = legacy `fix_hints` tail. |
| `SINGULAR_DECIDER_FAST` | `1` | Resolve clear-cut failure classes by host policy table; `0` routes every failure through the model decider. |
| `SINGULAR_WORKER_INFRA_MAX` | `1` | Effective limit: 1 extra worker run on infrastructure failure before `worker-infra`. The driver clamps any positive integer to 1; 0 disables retries. |
| `SINGULAR_AUDIT_INFRA_MAX` | `2` | Effective limit: 1 extra auditor run on infrastructure failure before `audit-infra`. The driver clamps any positive integer to 1; 0 disables retries. |
| `SINGULAR_AUDIT_FORMAT_NORMALIZE` | `1` | Normalise audit-verdict format before validation (drop unknown properties inside finding/verification items; carry still-open prior findings the host can classify). `0` refuses such verdicts as before. |
| `SINGULAR_IMPORT_FAIL_PARK` | `3` | Consecutive identical import failures of the same inbox packet before it is parked: one `packet.import_parked` event, an ATTENTION line in `singular health`, and no further validation until the file changes. |
| `SINGULAR_DISPATCH_REFUSAL_PARK_THRESHOLD` | `3` | Consecutive dispatches of one task that the driver refuses (exit 2) for the same reason before the task is parked: one `origin.dispatch_refusal_parked` event carrying the reason, an ATTENTION line in `singular health` with the reason and `singular unpark TASK`, and no further dispatch until it is unparked. A dispatch that gets past its preconditions, or a different reason, restarts the count. |
| `SINGULAR_PROMOTION_SWEEP_MAX` | `3` | Promoter runs per reconcile cycle in the promotion sweep, which re-attempts promotion for every node whose tasks are complete and whose gate is unpublished. A node is attempted again only when its task set, a task status or the target HEAD changed since its last attempt. `0` disables the sweep; `SINGULAR_AUTO_PROMOTE_GATES=0` disables all automatic promotion. |
| `SINGULAR_PLANNER_OUTPUT_REPAIR` | `1` | When a planner's task batch fails host validation (for example the task parser rejects a scope bullet), re-invoke the planner once with its own output, the exact diagnostic and the rule before counting a planner failure. `0` fails at once. Output still malformed afterwards is `failureClass: malformed-output`, distinct from provider and infrastructure failures. |
| `SINGULAR_LOCK_WAIT_SEC` | `120` | Seconds a lock-taking operator verb (`unpark`, `supersede`, `recover candidate`, `integrate --task`, …) waits for a running loop cycle to release the origin lock before failing with `origin lock busy`. `--wait=SECONDS` / `--no-wait` set it for one command; `0` fails fast. |
| `SINGULAR_LOCK_YIELD_SEC` | `20` | How long a reconcile cycle holds off at its start while an operator command is queued on the origin lock. `0` never yields. |
| `SINGULAR_GATE_TIMEOUT_SEC` | `3600` | Wall-clock bound on the consumer's gate command; the whole process tree is killed on expiry and the result is `inconclusive-infrastructure`, never a product failure. `0` disables. Before this existed a hung gate held a worker slot indefinitely and made cooperative STOP never fire. |
| `SINGULAR_KILL_GRACE_SEC` | `10` | Seconds a timed-out runner gets to run its EXIT trap — where the read-only restore guard lives — before the tree is SIGKILLed. |
| `SINGULAR_READONLY_GUARD_MODE` | `restore` | `restore` puts the working tree back after a read-only run; `report` logs what it would do and changes nothing; `off` disarms it. |
| `SINGULAR_READONLY_GUARD_KEEP_DAYS` | `30` | How long `singular gc` keeps guard journals, which hold quarantined content, before removing them. |
| `SINGULAR_CONTEXT_SECTION_MAX_CHARS` | `4000` | Per-section cap on continuity content appended to prompts. |
| `SINGULAR_PREFLIGHT_REQUIRE_ACCEPTANCE` | `1` | Preflight requires non-empty `acceptanceCriteria` on a task. |
| `SINGULAR_RED_PROOF` | `off` | `observe` runs and records a task's declared proof on the base and the candidate; `enforce` also requires the outcome `proved` (or `waived`) before the audit. See [`docs/red-proof.md`](docs/red-proof.md). |
| `SINGULAR_RED_PROOF_TIMEOUT_SEC` | `1200` | Time limit in seconds for each proof run; a run that reaches it is infrastructure trouble, never a product failure. |
| `SINGULAR_ACCEPTANCE` | `driver-only` | `every-path` applies the acceptance rule at import, integration, `singular accept-packet` and recovery too, and parks a refused task once. See [`docs/acceptance.md`](docs/acceptance.md). |

### Launchd launcher defaults

`templates/launchd/run-orchestrator.sh` defaults to watchdog mode, which starts
`singular auto`'s engine loop. Other execution modes invoke a single reconcile. It checks
for Git, Go, Bash >= 4, a working Codex executable and a readable Codex
credential file, even when the project's selected runner is another provider.

| Setting | Launchd default | Meaning |
| --- | --- | --- |
| `SINGULAR_PUSH` | `1` | Enables pushes; set `SINGULAR_PUSH=0` to opt out. Direct commands default to `0`. |
| `SINGULAR_L2_SANDBOX` | `danger-full-access` | Codex L2 sandbox selection; the Codex adapter otherwise defaults to `workspace-write`. |
| `SINGULAR_TARGET_BRANCH` | `codex/singular-bootstrap-target` | Fallback integration target; configure the consumer's actual branch. |
| `SINGULAR_ENABLE_L1_PARALLEL` | `1` | Enables parallel node planning; the engine otherwise defaults to `0`. |
| `SINGULAR_MAX_HOURS` | `12` | Loop wall-clock budget in hours; the engine otherwise defaults to `20`. |

These are launcher fallbacks, not changes to the engine or starter config.
Project configuration is still loaded by the engine. Keep `SINGULAR_PUSH=0`
in the effective configuration to disable pushes: a value in the config's
`env` object overrides the process environment, and local shell configuration
can override it again.

### Context knobs (0.20.0)

**The context subsystem ships ON.** Through 0.19.0 these defaulted to `0` and this
table's "Recommended" column was the only thing steering an operator to the
governed configuration — which meant a default install ran the *least*-governed
setup, and every description of how singular manages context described a
configuration nobody was running by default. As of 0.20.0 the shipped defaults
ARE the recommended values, so the two columns agree. Setting any of them to `0`
is a supported rollback.

Some governance is not on this table at all, because it has no knob:

- **The independence pin.** `final-audit`, `paired-audit`, `re-critique`, and
  `critic-recheck` always run fresh. It is evaluated above the routing flag, so it
  binds even with `SINGULAR_CTX_ROUTING=0`. There is no configuration in which an
  auditor grades work from inside a session that already formed an opinion on it.
- **Per-provider context windows.** The window-pressure gate resolves its budget
  from the runner’s provider via `engine/providers.json` (`contextWindowTokens`)
  rather than one global constant. Derived, not configured.

Run `singular doctor` to see the effective posture — it reports which gates are
live and warns when a dependent feature is enabled without its dependency.

| Env knob | Default | Effect |
| --- | --- | --- |
| `SINGULAR_CTX_ROUTING` | **`1`** | Explicit 5-strategy routing (`continue/resume/fork/fresh/rehydrate`) with reason codes, session-lease + window-pressure + diff-volume gates, and structural taint on resumed sessions. |
| `SINGULAR_PLANNER_SESSION` | **`1`** | Per-node planner session persistence + resume behind fail-closed lineage/template/lease/window gates. |
| `SINGULAR_CTX_PACKET` | **`1`** | Planner context packets (decisions/assumptions/rejected alternatives) flow into worker, fix, and audit prompts; per-run assumption ledger. |
| `SINGULAR_PLAN_CRITIQUE` | **`1`** | Read-only skeptic critic over staged planner batches before L0 import; a reject disposition parks the batch. |
| `SINGULAR_PLAN_REVISE_MAX` | `1` | Bounded revise→re-critique loop for `revise` verdicts. |
| `SINGULAR_CTX_ARTIFACT_SCAN` | `0` | Secret scan over durable artifacts; hits quarantine (`.quarantined`) and drop out of all prompt assembly. |
| `SINGULAR_PAIRED_AUDIT_PCT` | `0` | Sampled post-acceptance paired fresh audits (bias measurement + independence spine). |
| `SINGULAR_REHYDRATE` | `0` | Inject deterministic durable-artifact packets on refused-resume lineage steps. Opt-in until the per-section truncation issue below is fixed. |
| `SINGULAR_CTX_MANIFEST` | `0` | Authored-knowledge ingestion into rehydration packets (`contextManifest`: legacy string manifest or strict `singular-brain.manifest.v1` descriptor). |
| `SINGULAR_CTX_GRAPH` | `0` | Context-graph projector/sync/query + subgraph-selected rehydration. |
| `SINGULAR_CTX_EXPERIMENT` | `0` | Experiment aggregators, delta, renderers, and `singular experiment-report`. |
| `SINGULAR_CTX_ARMSTATE` | `0` | Per-run knob-state provenance recording for arm-integrity audits. |

`SINGULAR_REHYDRATE` and `SINGULAR_CTX_GRAPH` stay opt-in deliberately.
Rehydration orders node selection contradictions-first, but the per-section cap
(`SINGULAR_CONTEXT_SECTION_MAX_CHARS`, default 4000) truncates *within* a section
content-blind — the line that mattered can be cut from a section chosen precisely
because it mattered. That is fixed before rehydrate is promoted, not after.

### Singular-brain manifests

The optional producer is the complete singular-brain 0.2.0 engine pinned in
`vendor/singular-brain`. Configure its JSON path relative to the effective
Singular JSON configuration, then use:

```bash
singular manifest gen --scope knowledge
singular manifest check --scope knowledge
singular manifest lint --scope knowledge
singular manifest bless --scope knowledge path/to/reviewed.md
```

`--config PATH` overrides `brainConfig` and resolves from the invocation
directory. Otherwise `brainConfig` resolves relative to the selected Singular
JSON file, including a file selected with `SINGULAR_JSON_CONFIG_FILE`. Brain is
opt-in: when `brainConfig` is absent, doctor reports a skip and Node.js remains
optional. `check`, `lint`, and doctor are read-only. Regeneration preserves the
freshness sidecar's prior review hashes; body drift stays
`description_unverified` until an explicit `bless`.

For ingestion, `contextManifest` can be an explicit descriptor:

```json
{
  "contextManifest": {
    "format": "singular-brain.manifest.v1",
    "manifest": "generated/KNOWLEDGE.json",
    "sourceId": "project-knowledge",
    "expectedScope": "knowledge",
    "sourceRoot": "knowledge-corpus",
    "select": ["decisions/runtime.md", "skills/release/SKILL.md"]
  }
}
```

All six fields are required and unknown fields are rejected. `manifest` and
`sourceRoot` resolve relative to the effective Singular JSON file, never the
process cwd. Artifact and selection paths must be canonical POSIX-relative
paths. The consumer contains resolved sources beneath `sourceRoot`, rejects
escaping or colliding symlinks and duplicate identities, and excludes missing,
quarantined, stale, superseded, or otherwise unreviewed sources. Selection is
explicit: natural-language `loadWhen` prose is retained as metadata and is not
interpreted as role tokens.

Normalization keeps the manifest hash, live full-source hash, and last-reviewed
metadata/body hashes distinct. It is deterministic and read-only:

```bash
python3 engine/brain_documents.py normalize --config /absolute/path/to/singular.config.json
```

The output contract is `singular.context.brain-documents.v1`, described by
`schemas/brain-documents.v1.schema.json`. A string-valued `contextManifest`
remains the explicit legacy compatibility path with exact historical trigger
matching and fail-soft behavior; an object descriptor never falls back to it.
With `SINGULAR_CTX_MANIFEST` disabled or the field absent, no brain sources are
read.

### Bounded local context service

The opt-in context service reads the normalized brain manifest, explicitly
selected current-worktree code, and retained run records into one immutable
read snapshot. It uses no cache, lock, ledger, vector service, or third-party
Python dependency. Enable it in the effective `singular.config.json`:

```json
{
  "contextService": {
    "enabled": true,
    "projectId": "my-project",
    "budgetBytes": 65536,
    "codePaths": ["engine/example.py"],
    "runRecordPaths": [".singular-state/runs/RUN-ID/runner-result.json"],
    "rolePolicy": {
      "planner": ["brain", "code", "run"],
      "implementer": ["brain", "code", "run"],
      "review-target": ["brain", "code"]
    }
  }
}
```

Paths are canonical project-relative paths and are contained after symlink
resolution. Role policy is applied before source metadata is exposed. The
command role is an input from the host invocation boundary; the context CLI does not
authenticate a caller by itself. An absent or false `enabled` value returns a
versioned `disabled` result and performs no source discovery.

During a frozen campaign, the selected root JSON configuration remains the
authoritative context policy for planners, worker worktrees, and audits. A
worker worktree is passed separately as the invocation source workspace; its
copy of `singular.config.json` cannot change enablement, role selection, or
budgets. An explicit `SINGULAR_CONTEXT_CONFIG_FILE` remains supported and is
fingerprinted as an active policy artifact, including its selected path and
contents. A missing frozen policy file therefore fails closed instead of
silently disabling context. Without an active campaign, the legacy optional
configuration behavior is unchanged.

Campaign manifests use `singular.campaign.resolved-settings.v1` to classify
exact setting names as stable policy, invocation identity, or child transport.
Unknown `SINGULAR_*` names remain stable policy. Canonical task roots, model and
effort settings, capability definitions/mappings, and context budgets remain
frozen; task/run/role/profile selections and reservation authority remain
per-invocation identity.

When enabled, context is assembled at the actual provider boundary. Planners
and first implementers receive an initial bundle independently of session
rehydration routing. Product retries and resumed planners compare a freshly
validated snapshot with the prior bundle, carrying changed bytes plus immutable
references for unchanged sources. Missing, revoked, modified, or newly
ineligible configured sources stop the affected invocation before the provider
runs. Final and sampled paired audits always start fresh under the
`review-target` policy; audit roles cannot read `run` sources, so worker
conclusions are not imported as trusted review knowledge.

The host validates the actual adapter argv and frozen campaign before an audit
is admitted. It then snapshots the base prompt, task, selected context, and
required review evidence; composes them once; applies both the context byte
budget and evidence manifest's final-prompt cap; and publishes a
content-addressed prompt plus a unique immutable invocation bundle. The event,
admission receipt, and evidence-delivery ledger all bind that final prompt hash
and byte count. Required-evidence and paged-read debits remain a separate
cumulative retrieval budget and do not count unrelated prompt bytes.
Deterministic refusal writes a `singular.host-invocation.v1` receipt with
`status: denied`, a stable reason, and zero retrieval debit. A genuine frozen
campaign mismatch is routed to the durable campaign-mismatch disposition; it
is neither retried as provider infrastructure nor offered to a model decider.

```bash
singular context search --role implementer --query "serialized migration"
singular context get --role implementer --ref REF --version sha256:... \
  --section "Failure recovery" --max-bytes 4000
singular context get --role implementer --ref REF --version sha256:... \
  --cursor line:80 --line-count 40
singular context build --role implementer --phase implement --task TASK.md \
  --budget-bytes 12000 --output .singular-state/runs/RUN-ID/context-bundle.json
singular context explain --role implementer \
  --bundle .singular-state/runs/RUN-ID/context-bundle.json
singular context effective-config --role review-target --phase final-audit
```

Search is deterministic exact-reference and lexical-token matching
(`exact-lexical.v1`). It can miss synonyms and semantic paraphrases; no result
is reported as an explicit abstention, never as proof that knowledge is absent.
`get` requires the source SHA-256 returned by search and refuses missing,
modified, wrong-version, review-ineligible, or lifecycle-ineligible sources.
Heading and line/cursor pagination make late facts reachable beyond the
default 4,000-byte excerpt. A truncated response returns an opaque
`continuationCursor` such as `byte:4096`; replay that exact cursor to continue
inside a long line without losing bytes. Byte cursors always identify UTF-8
boundaries and are scoped to the requested section when `--section` is used.

Build admits the complete task contract and open/violated run obligations
before optional lexical matches. If mandatory bytes do not fit, it exits 3
with `mandatory-overflow`; optional overflow is recorded in `omissions`. Byte
accounting is exact UTF-8 at the host boundary. Provider system content, tool
schemas, session history, and output remain explicitly unknown to the context service rather
than being counted as zero. The output contract is
`singular.context.bundle.v1` in `schemas/context-bundle.v1.schema.json`.
Prompt bytes and their provenance are fields of the same hash-addressed JSON
object; `--output` publishes that object with a same-directory atomic replace.
Driver bundles are retained beside run evidence as `context-*.bundle.json` and
the matching `context.bundle_selected` event records the same bundle id, prompt
hash, delivery mode, byte budget, omissions, and source provenance. `singular
doctor --json` projects the effective service policy and recent bundle details.
Search, get, effective-config, and explain never write accounting or retrieval
state.

### Retrieval evaluation and campaign analysis

Two read-only evaluation surfaces sit on top of the same service. Neither needs
a provider, and neither writes into the state directories it measures.

```bash
singular context evaluate --corpus tests/fixtures/context-evaluation/corpus.json \
  --output /tmp/evaluation-report.json
singular context campaign-report \
  --events .singular-state/events.ndjson \
  --runs .singular-state/runs \
  --interventions .../operator-interventions.jsonl \
  --checkpoint .../checkpoint.json --observations .../observations.json
```

`evaluate` replays a declared labeled corpus
(`singular.context.evaluation-corpus.v1`) through the real service and reports
inclusion/recall within the byte budget, incorrect selections, budget omissions,
abstentions and refusals per case and in aggregate, then compares them with the
metrics the corpus itself declares. Labels cover exact, lexical and paraphrased
facts, long documents, contradictory sources, wrong versions, wrong roots,
wrong roles, revoked sources, missing knowledge, budget omission and mandatory
priority. The corpus fixture's manifest is produced by the vendored
singular-brain generator, so the evaluation runs against real manifest output
rather than invented JSON. Exit 0 means the measured metrics match the declared
ones; exit 4 means a measured deviation (the report is still published); exit 2
means the inputs are unusable.

`campaign-report` reads retained orchestration events, runner-result provider
sidecars, host gate reports and the operator intervention log. Run artifacts are
scanned recursively and deduplicated by content, so staged planner/critic
invocations and superseded earlier-attempt gate runs are included while the
byte-identical copies the engine retains under `attempts/<n>/` are collapsed;
both collapsed counts appear under `inputs.runs`. It reports
integrated and unfinished tasks, retries and refused work, ready-to-dispatch
wait, gate durations by workspace, control-plane work, bytes per accepted
review, and provider input/cached/output tokens by role and by provider.
Failed and setup work stays included. Every counter the evidence does not
contain is listed under `unknowns` with its kind and reference — an absent or
usage-free sidecar, an accepted review with no retained context bundle, a role
spanning providers whose cached-input semantics differ, and the standing
unknowns for monetary cost, provider-observed service tier and context
occupancy. Absent counters are never defaulted to zero, cumulative tokens are
never presented as context occupancy or money, and interventions are counted
separately from uninterrupted native delivery. Every input is recorded with its
path and SHA-256 so a report can be re-derived. Exit 2 if the event stream or
runs directory is absent; a declared-but-absent optional input becomes an
`absent-input` unknown instead.

Installation, activation, immutable runtime adoption, rollback and the memory
approval policy are in [the context adoption guide](docs/context-adoption.md).

### Reviewed persistent memory

Persistent memory is opt-in and project-local. Model-authored content always
enters as an untrusted `proposed` record with a retained source hash. It becomes
eligible for context retrieval only after a separately identified authority is
verified against a pinned authority document and, where configured, pinned code
identity. The authority's subject must differ from the proposer. A consumer
policy selects allowed scopes, approver roles, retrieval roles, and whether a
human (rather than an authorized internal reviewer role) is required:

```json
{
  "memoryService": {
    "enabled": true,
    "storePath": ".singular-memory",
    "maxContentBytes": 16384,
    "maxCheckpointBytes": 32768,
    "credentialKeyId": "host-memory-key-v1",
    "credentialKeySha256": "sha256:...",
    "authorities": {
      "independent-reviewer": {
        "source": "policy/memory-reviewer.json",
        "sha256": "sha256:...",
        "codeIdentity": [
          {"path": "policy/reviewer.py", "sha256": "sha256:..."}
        ]
      }
    },
    "consumerPolicies": {
      "task": {
        "scopes": ["project"],
        "approverRoles": ["memory-reviewer"],
        "humanReviewRequired": false,
        "contextRoles": ["planner", "implementer"]
      }
    }
  },
  "contextService": {
    "enabled": true,
    "rolePolicy": {"implementer": ["brain", "code", "run", "memory"]}
  }
}
```

Routine policy-authorized internal approval does not interrupt the user.
Set `humanReviewRequired` only for consumers that require it. The service
requires every proposal, lifecycle decision, and checkpoint write to carry an
operation-bound HMAC credential minted by the host. The credential binds the
authenticated subject, action, operation, target memory, and relevant reason or
replacement; `SINGULAR_MEMORY_CREDENTIAL_KEY` is host-held and must match the
configured key hash. Merely naming a configured authority or proposer is never
sufficient. Human-only consumers additionally require a credential whose
authenticated subject matches the configured human authority.

The service
revalidates retained sources, authored artifact bytes, authority documents, and
configured code identity before trusted retrieval. Missing or drifted identity
fails closed. Rejection, supersession, and tombstones are durable record states;
the trusted index is derived and can be rebuilt without restoring retired
content. Each lifecycle writer takes the existing store lock and drains
prepared work before reading lifecycle state. New journals bind the exact
request and first-captured input hashes, expected record revision/hash,
resulting revision/hash, operation, and response. Recovery applies a successor
only to its recorded predecessor, acknowledges an exact result or proven
descendant, and otherwise fails closed. Legacy prepared journals without that
ancestry are acknowledged only when their exact result is already present.
Replay therefore cannot reopen rejected, quarantined, superseded, or tombstoned
memory. Index refresh is derived repair after the authoritative journal/record
commit; deleting or failing it does not change lifecycle state.

Context readers never acquire or create the writer lock, store directories,
indexes, caches, or ledgers. They parse and hash the same captured record bytes,
require the selected revision's journal to be committed, bind record and
operation membership plus artifact, citations, current policy, authority, and
code identity, and retry snapshot acquisition only within a fixed bound. An
absent store is an empty snapshot. Prepared, malformed, conflicting, or
changing state yields a recovery-required or changed-snapshot refusal and is
repaired only by a later writer. `tests/test-memory-lifecycle-e2e.sh` proves
this from observed filesystem state (content, inode, timestamps and directory
membership) for absent, populated and pending-journal stores on every host, and
additionally re-runs the same proof under a macOS `sandbox-exec` deny-write
policy wherever a profile can actually be applied. Seatbelt refuses to nest, so
on an already-contained host the extra OS-enforced pass records a skip reason
instead of failing; the behavioural proof still runs.

Search, get, bundle build, CLI publication, and host admission revalidate the
frozen snapshot at their publication/admission boundary. The guarantee is the
exact immutable bytes selected at that validated point in time; it does not
claim synchronization with a retirement after validation through an arbitrary
consumer's read of the final stdout byte. Operation IDs remain
conflict-detecting and idempotent, and bounded checkpoints recover solely from
local retained files:

```bash
singular memory propose --operation-id capture-1 --task TASK-1234 \
  --actor implementer-1 --scope project --policy task \
  --content-file findings/retry.md --source events/task-complete.json \
  --credential .host-credentials/capture-1.json
singular memory review --memory-id mem-... --authority independent-reviewer
singular memory approve --operation-id approve-1 --memory-id mem-... \
  --authority independent-reviewer --credential .host-credentials/approve-1.json
singular memory reject --operation-id reject-1 --memory-id mem-... \
  --authority independent-reviewer --reason "not reusable" \
  --credential .host-credentials/reject-1.json
singular memory quarantine --operation-id quarantine-1 --memory-id mem-... \
  --authority independent-reviewer --reason "citation requires investigation" \
  --credential .host-credentials/quarantine-1.json
singular memory supersede --operation-id supersede-1 --memory-id mem-old \
  --by mem-new --authority independent-reviewer \
  --credential .host-credentials/supersede-1.json
singular memory tombstone --operation-id retire-1 --memory-id mem-... \
  --authority independent-reviewer --reason "policy retirement" \
  --credential .host-credentials/retire-1.json
singular memory checkpoint save --operation-id cp-1 --task TASK-1234 \
  --actor implementer-1 --payload-file checkpoints/task.json \
  --source events/task-progress.json \
  --credential .host-credentials/cp-1.json
singular memory checkpoint recover --task TASK-1234
singular memory rebuild
```

The record contract is `singular.orchestration.memory-record.v1`; schema copies
are published in `schemas/` and `schemas/orchestration/`.

**Note on overrides.** `singular.config.json`’s `env{}` block is applied over the
process environment, so in a repo that pins a knob there, `VAR=0 singular …` will
*not* override it — edit the config (or `.singular-state/config.local.sh`) instead.

`singular metrics` also reports what the model calls were spent on
(`aggregate.roles`: invocations, outcomes, failure classes and tokens per role,
from the runner-result sidecars) and a `ceremony` block: control-plane versus
implementer invocation and input-token fractions, invocations per accepted
task, input tokens per integration. A healthy campaign spends most of its
tokens on implementers; the number to watch is `controlPlaneInputTokenFraction`.

Key context event types (all in `.singular-state/events.ndjson`, countable via
`singular metrics`): `context.strategy_selected`, `context.resume_failed`,
`ctx.arm_assigned`, `ctx.paired_audit`, `ctx.critic_recheck`,
`ctx.artifact_secret`, `ctx.packet_malformed`, `plan.critiqued`,
`plan.revised`, `plan.revise_parked`, `planner.backoff_active`.

## Context continuity

Between retry attempts singular carries authoritative state forward rather than
re-deriving it from a log tail:

- **Context capsules** — hash-stamped `implementer-capsule.json` and
  `reviewer-capsule.json` per attempt.
- **Findings ledger** — `findings-status.json` upserted from each audit verdict, with
  stable finding ids tracked open/resolved across retries.
- **Structured fix prompts** — the worker receives authoritative open findings on retry
  (set `SINGULAR_FIX_PROMPT_STRUCTURED=0` to revert to the legacy byte-tail).
- **Re-audit delta prompts** — the auditor receives prior findings + fix diff +
  per-id verification targets.
- **Attempt archive** — each attempt's artifacts are copied (never moved) under
  `runs/<id>/attempts/<n>/` with an `attempts/index.json`.

### Session affinity and routing

Role-keyed runtime session resume (`codex exec resume`, `claude -r`) behind ordered
fail-closed staleness gates, for three roles:

- **Implementer/reviewer** (within one drive): defaulting ON
  (`SINGULAR_SESSION_AFFINITY=1`); any gate failure or runner refusal (exit 86)
  degrades silently to a fresh run within the same attempt. A resume that
  started and failed (exit 87) relaunches fresh as an infrastructure retry.
- **Planner** (across planning runs, per DAG node): behind
  `SINGULAR_PLANNER_SESSION` — persisted per-node session meta, node-lineage and
  template-sha gates, session leases against concurrent resume, rc-86 fresh
  fallback. A planner session can decompose a multi-slice node across
  consecutive resumes.
- **Plan critic** (re-critique of a revised batch): the skeptic may be offered
  its own prior session — never an advocate's.

Every routing decision is reason-coded as a `context.strategy_selected` event
(`strategy` + the exact gate reason) and countable via `singular metrics`.

> **Invariant (evidence invariance):** routing never changes what counts as
> evidence. Gates, red/green proofs, scope checks, and the fresh implementation
> auditor are identical under every strategy — `fresh` or `resume`. Outcomes MAY
> improve with continuity (that is the point), and the improvement is measured,
> not assumed: per-strategy outcomes flow into the attempts index and
> `singular metrics`.

> **Advocate/skeptic line:** a session never crosses between advocate roles
> (planner, implementer) and skeptic roles (plan critic, auditor), in either
> direction. Per-role session-meta files make violations structural, not merely
> checked. Resumed or rehydrated sessions never satisfy an independence-required
> step.

### Plan critique and revision

Behind `SINGULAR_PLAN_CRITIQUE` (default ON since 0.20.0): staged planner
batches are reviewed by a fresh, read-only plan critic
on the default runner before L0 import. Verdicts follow `plan-critique.v0`:
`approve` → import; `revise` → the node's planner session is resumed with the
critic's structured findings (bounded by `SINGULAR_PLAN_REVISE_MAX`), records
per-finding dispositions (accepted/rejected-observation; silent drops are
recorded as unaddressed), and re-enters the critic; `park` / budget exhaustion →
candidates never reach import (fail closed). Critic infrastructure failure fails
OPEN with an event — the critic is an added safety layer; the un-bypassable
implementation auditor remains the floor.

Severities are a contract, not a mood (0.21.0). `blocking` is reserved for
defects only the planner can fix — owned-file collisions, undeclared
dependencies on unintegrated work, unverifiable acceptance criteria,
duplicates, batch tasks that cannot land independently, contract violations.
The host enforces it: a `revise` verdict with no blocking finding is downgraded
to `approve` (`plan.critique_downgraded`; `SINGULAR_PLAN_CRITIQUE_REQUIRE_BLOCKING=0`
restores verdict-as-written), and an approved batch carries its should-fix and
note findings into every task as `## Plan critique (advisory)`, which the
implementer prompt renders as work to address-or-decline and the auditor prompt
as something to check (`SINGULAR_PLAN_CRITIQUE_ADVISORY=0` disables). A
repository with no `prompts/plan-critic.md` uses the engine template
(`ctx.plan_critic_prompt_fallback`) instead of running the critic blind.

In schema v2, a successful revision is published as an immutable generation
under the node staging directory. One atomically replaced
`.candidate-current.json` manifest selects the authoritative generation, and
all engine readers pin that generation before enumerating files. Direct
`TASK-*.candidate.md` files are a legacy pre-migration read fallback only; new
revision batches are never published through sequential direct-file moves.
L0 imports the pinned generation through byte-verified private writable copies.
It allocates the complete monotonic ID range once, applies one simultaneous
whole-token mapping to every private candidate, validates the transformed batch,
and publishes it all-or-nothing. The canonical generation, pointer, file modes,
and adjacent critique evidence remain read-only and unchanged on success or
rollback.

Task scope uses one parser across dispatch, preflight, node indexing, batch
validation, and duplicate detection. A list item may be a bare legacy path or
contain exactly one backtick-delimited path followed by prose; quoting is
required for paths containing spaces. Traversal, globs, malformed/multiple
backtick spans, and ambiguous unquoted annotations fail closed. Historical
sentences in a `Forbidden files` list remain non-executable policy prose and do
not become path authority. Acceptance-criteria continuations and nested content
are retained, and the complete original task document is appended unchanged to
worker and fresh-auditor prompts (with an explicit 256 KiB mandatory-content
limit).

## Modules

The generic `engine/` references **zero** project-specific symbols — enforced by
`tests/test-engine-clean.sh` (the abstraction gate test). All per-project logic lives in
opt-in modules:

```
singular-ext/
  storage-proof.sh    # example: durable-proof regime
  promote-gate.sh     # example: gate promoter
  grok-implementer.sh # example: route the implementer to Grok
```

Modules are listed in `singular.config.json` → `modules[]`. A repo that doesn't list them
never loads them. The `SINGULAR_MODULES` env var is the runtime list (set by the JSON
config loader).

## Versioning and schema

Two versions move independently:

- **Engine pin** — `.singular-version` is the canonical per-repo pin (overrides
  `singular.config.json` `engineVersion`; if they disagree `.singular-version` wins and
  `singular doctor` warns). `singular update <ver>` rewrites it.
- **Schema** — `SCHEMA_VERSION` (repo root) holds the data-contract version (`v2` today).
  A repo records the schema it was scaffolded against in `singular.config.json` →
  `schemaVersion`. `singular doctor` fails on a schema mismatch; `singular migrate` runs
  the shipped `migrations/<from>-to-<to>.sh` chain and rewrites `schemaVersion`.
  Runtime JSON schema identifiers follow the namespace
  `singular.orchestration.*.vN`. v2 keeps reading existing v0 records while
  writing the structured audit and gate v1 contracts.

## Development and tests

```bash
bash tests/run.sh    # full regression suite, serial
SINGULAR_TEST_JOBS=6 bash tests/run.sh   # the same suite, six files at a time
singular test         # the same suite as a supervised, attachable run
bash tests/field-report-canary.sh  # required before promoting a release
```

Every test file builds its own scratch repository, so files are independent by
construction and `SINGULAR_TEST_JOBS=N` runs them N at a time; results print in
discovery order, so the output, the summary and `progress.jsonl` are identical
to a serial run. A file that must not share the machine (it asserts wall-clock
bounds, binds a fixed port, or drives a headless browser) declares
`# singular-test: serial` in its first 40 lines and runs after the parallel
batch. Duration depends on the checkout, host and concurrency; this repository's
own `gateCommand` uses four jobs.

`singular test` runs the resolved engine's own `tests/run.sh` as a supervised job
and keeps the evidence in the current repo under
`.singular-state/test-runs/<runId>/` (`singular.test-run.v0` manifest, `suite.log`,
per-test logs, `progress.jsonl`), so a result outlives the session that started
it. A detached supervisor holds an exclusive `flock` for its whole life:
liveness is proved by the kernel rather than guessed from a pid, and `ps` is
never consulted. A second invocation attaches to the live run instead of
starting a duplicate — `--new-run` is the explicit override — and a supervisor
killed mid-run reconciles to `interrupted` with the counts it reached (and ends
the run's process group, so an orphaned suite cannot keep writing into it).

**The resolved engine must be a checkout.** Most tests build disposable Git
worktrees of `HEAD`, so `tests/run.sh` opens with a source preflight that needs
real history — and an installed version (`~/.singular/versions/<ver>/`) is a plain
copy that ships no `tests/` at all. `singular test` refuses up front there, with
`SINGULAR_TEST_SUITE_UNAVAILABLE` or `SINGULAR_TEST_SOURCE_UNSUPPORTED` and before
any run directory exists. To record a run for a consumer repo, point the CLI at a
checkout from inside that repo — evidence still lands in the repo you are in:

```bash
SINGULAR_ENGINE_HOME=/path/to/engine-checkout singular test
```

`--status` and `--wait` are exempt: reporting on a past run needs no suite.

```bash
singular test --status [--json]  # report on the current run
singular test --wait             # attach to the live (or last recorded) run
singular test --no-wait          # start detached; the run id goes to stdout
singular test --rerun-failures   # re-run only the last completed run's failures
```

The test suite uses no live state — all fixtures use a generic layer vocabulary. The
`tests/test-engine-clean.sh` gate enforces the abstraction contract on `engine/`.
The promotion canary is also non-destructive: it validates the captured 26-node
localization graph and composes the ten field-report regression scenarios from
their focused hermetic tests. It stays outside `tests/run.sh` to avoid running
those same scenarios twice in an ordinary development pass.

## Contributing

Run `bash tests/run.sh` before opening a PR. Keep `engine/` generic: project-specific
rules belong in opt-in modules under `singular-ext/` or in a consumer repo's config.
Do not commit `.singular-state/`, `.worktrees/`, `.singular-evidence/`, local env
files, or generated run artifacts.

## Security

singular executes repo-configured shell commands and launches local coding
agents in git worktrees. Review `singular.config.json`, `singular.config.sh`, and
task files before running it in an untrusted repo. See [SECURITY.md](SECURITY.md)
for the reporting-channel status. A working private reporting channel still
requires the repository owners' decision and activation.

## License

Licensed under GPL-3.0 — see [LICENSE](LICENSE).
