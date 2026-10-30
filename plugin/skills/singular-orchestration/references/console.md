# Orchestration console — monitoring UI, JSON API, snapshot modes

A local web console over Singular's durable state. Since 0.10.0 it is a
full-bleed **app shell**: a left sidebar lists plan threads (the live plan plus
archived read-only threads) and holds an app-level Providers nav, and a slim
44px header carries four thread-scoped tabs (Home, Plan, Consoles, Agents):

- **Home** (default) — system at a glance: health verdict + attention feed
  (STOP, breaker, planner backoff, stale L1 leases, disk, stale loop
  pidfile), per-stage gate progress, live event feed, 14-day activity
  sparkline, throughput tiles, a **supervisor card** (periodic read-only
  briefing + propose-only chat) and **provider quota gauges** (0.10.0),
  quick links.
- **Plan** — a workbench over the orchestration DAG with four lenses:
  Timeline (real execution Gantt: per-task attempt bars on compressed real
  time, gate diamonds, L0 cycle strip, retry chains; labels are
  collision-placed and never overlap), Matrix (N×N dependency matrix with
  sticky headers/row labels, readable two-line labels, height-aware fit and
  follow-diagonal scrolling (0.10.0), gate-status diagonal, acyclicity
  proof), DAG (layered stage graph with collapse + hover tracing), and
  Tasks (the sortable task table + the status quick-filters). A right-hand
  aside drills into the selected DAG node; the bottom-sheet inspector owns
  full task detail.
- **Consoles** — a live operations room: the L0 supervisor as a persistent
  left pane (semantic events + raw supervisor log), and a dynamic region
  where labeled agent consoles (role · task/area · phase · model) pop in as
  the system spawns planners/workers/auditors and linger→collapse into a
  recent rail when they finish. Finished sessions reopen with full parsed
  scrollback; a prompt chip opens the exact rendered prompt of the run.
- **Agents** — a role card grid (avatar, live glyph, current work, model ·
  effort) with per-role detail: processes (jump to their console), the
  role's prompt template, and **editable settings** (see below).
- **Providers** (0.9.0; moved into the sidebar app-nav in 0.10.0) —
  runtime/provider status cards for every supported
  provider (Claude Code, Codex, Gemini, OpenCode, Cursor, OpenRouter, Grok): installed
  + version, auth status probed via each CLI's own status command or
  credential-file/env inference (email · plan shown when the CLI prints
  them; never any secret values), env-key presence, the provider's runner
  script + roles using it + last-used evidence from session metadata, an
  editable `SINGULAR_<PROVIDER>_MODEL` knob, a copyable login command when
  unauthenticated, and a **"Use as default runner"** switch (writes
  `SINGULAR_RUNNER` via the settings path; applies next cycle). Probes are
  cached 60s; "Recheck" forces a re-probe. Each card also carries a
  **subscription-quota gauge** (0.10.0: Codex real used-percent/window/reset
  from its own local session data; tier-only or not-exposed for the rest).
  Live-only (disabled when viewing an archived plan).

**Write scope:** `POST /api/settings` edits whitelisted `SINGULAR_*` knobs
in `singular.config.json` `env{}` (atomic; secrets and unknown keys untouched).
`POST /api/ask` and `POST /api/report` start supervisor runs and write their
questions, answers and briefing artifacts. Those runners are read-only with
respect to the project and propose settings for an operator to apply.
Most changes apply on the next loop cycle; `SINGULAR_SLEEP`/`SINGULAR_MAX_HOURS`
need a loop restart (the UI labels each). Orchestration state — tasks,
leases, gates, STOP, worktrees — remains read-only from the console.
Developer primitives: `{}` view-source buttons open the raw durable file
behind any entity in the inspector.

**Configuration reload (0.23.5):** the console binds a *generation* to the
inputs its configuration was resolved from (`singular.config.json`, the shell
and local layers, the selected context policy, the runner, the engine files).
When one of them changes on disk — the plan was regenerated, a knob was edited
by hand — the next data request re-resolves once in process, drops every
derived cache and serves the new generation (`generation.id` changes,
`generation.reloadCount` / `generation.lastReload.changedInputs` say why; the
console log prints one `configuration reloaded (…)` line). No restart, same URL.
If the new configuration cannot be loaded (for example invalid JSON), data
routes answer `409 {"error":"configuration unavailable","configuration":{"reason":…,"message":…}}`
and the page shows that message; fixing the file is itself a detected change
and recovers the same way. `/api/health`, the page shell and static assets never
run a reload and never wait behind one. A request already in flight finishes on
the generation it started with. `POST /api/settings` reads the file as it is on
disk under the same lock, so it never overwrites an external edit with stale
values, and it is refused (409) while the file is not valid JSON.
The reload runs the same `lib.sh` resolution as startup (it sources
`singular.config.sh`), once per detected change and never on a steady-state
read. To keep the strict earlier contract — reads never resolve configuration,
a change answers 409 `configuration-changed` until restart or a settings write —
start the console with `SINGULAR_CONSOLE_CONFIG_RELOAD=0`.

## Start it

Preferred — idempotent (0.5.0): reuse a live console or start one detached,
then print the URL:

```bash
singular console --ensure     # prints http://127.0.0.1:<port>; safe to re-run
singular console --status     # running/not-running (exit 0/1); --json available
singular console --stop       # terminate and clean up
```

While serving, the URL and pid persist at `.singular-state/console.url` /
`console.pid` (removed on exit), and `singular status` prints the live URL.

**Stable address (0.23.5):** the port the console binds is also written to
`.singular-state/console.port`, and that file is *not* removed on exit. The
next start (`--stop` then `--ensure`, a crash, a reboot) binds the same port
again, so an open tab or a bookmark keeps working. Candidates, first free one
wins: `SINGULAR_CONSOLE_PORT` (operator pin, 1-65535) → the saved
`console.port` → **8765** → an ephemeral free port. If a candidate is held by
another process the CLI says so on stderr, takes the next one, and
`console.port` / `console.url` are updated to the new address. Delete
`console.port` to let the console choose again.

Foreground mode is still `singular console` — its
banner goes to **stderr**, so one-shot JSON modes are pipe-pure. Use the CLI
to resolve the consumer's selected engine version.

**When data stops arriving (0.23.5):** the page says so instead of sitting on
"loading…" or on old numbers. Every read goes through `core/api.js`, which
records per route whether it succeeded, got an HTTP error (409 / 5xx) or got
no answer at all:

- a persistent strip under the top bar — "Refresh failed since HH:MM:SS UTC",
  the failing route and the server's own `message` / `reason`, the time of the
  data still on screen, a retry countdown and a **Retry now** button. It stays
  until the next success;
- when the server does not answer: "Console server is not running — run
  `singular console --ensure`". The page keeps retrying (1s, 2s, 4s, 8s, then
  every 10s) and resumes by itself when the console is back on the same
  address — no reload;
- a surface with no data yet shows the error and a **Retry** button in place of
  its "loading …" line, and the header chips read `unavailable` / `offline` and
  `stop unknown` instead of `loading` / `stop —`;
- the last good data stays on screen, desaturated, and the dock's "updated"
  cell turns into a warning ("42s ago — stale") once the last successful
  refresh is older than three poll intervals (30s), whatever the cause.

The page auto-refreshes every 10 seconds without losing selection, pin,
filters, or lane expansion. Deep links (0.6.0 grammar
`#<surface>/<lens>/<selection>[:tab]`): `#plan/timeline`, `#plan/matrix`,
`#plan/dag/NODE:<node-id>`, `#plan/tasks/TASK-0309:work`,
`#consoles/<session-id>` (pins + solos that console), `#agents/<role-id>`.
Legacy hashes (`#TASK-0309[:tab]`, `#NODE:<id>`, `#L1:<area>`, `#PLAN`,
`?list=1`) are migrated automatically.

## One-shot modes (no browser)

`singular console` forwards extra flags to the server, and every one-shot
flag prints JSON and exits without binding a port:

```bash
singular console --snapshot            # full health snapshot (same shape as /api/state)
singular console --task TASK-0309      # one task's detail
singular console --overview            # plan overview (DAG stages/nodes + gate status)
singular console --node <node-id>      # one DAG node's provenance
singular console --area <area>         # all DAG nodes for one area
singular console --sessions            # live session inventory
singular console --session <run-id>    # one session's terminal lines
singular console --events              # live event overlay
singular console --dag                 # full DAG view: nodes+gates+task rollups+edges (0.6.0)
singular console --timeline            # execution timeline: task intervals+gates+cycles (0.6.0)
singular console --config              # resolved per-role model/effort + limits (0.6.0)
singular console --home                # at-a-glance digest: health+attention+activity (0.7.0)
singular console --prompts             # role prompt library listing (0.7.0)
singular console --prompt <name>.md    # one prompt template's content (0.7.0)
singular console --raw <root>/<name>   # raw durable file behind an entity (0.7.0)
singular console --plans               # archived plan-thread registry (0.8.0)
singular console --providers           # runtime/provider status probes (0.9.0)
```

Use these to summarize orchestration health or inspect one task from a
terminal-only context.

## Read-only rules

The console reads task, lease and gate state. Its three POST routes change
settings or request supervisor work as described above. When monitoring:

- Treat Singular durable state as authoritative.
- Do not mutate the repo, `.singular-state`, worktrees, leases, tasks,
  packets, gates, or branches from the console context.
- Do not remove `.singular-state/STOP` or resume L0 as a side effect of
  "refreshing" — stopping/resuming is an operator action (see SKILL.md §3).
- "Deployed/active" is derived from durable facts only: live pid/process,
  active origin lock, non-terminal lease, existing worktree, recent dispatch
  events, run metadata. Accepted markdown alone never reads as active.
  Lease-file existence is not activity. `origin-state.extraWorktrees` is
  surfaced as a divergence note when it disagrees with disk, never rendered
  as agents.
- Completion authority is `docs/orchestration/gates/*.gate-result.json`,
  not markdown area dashboards.
- Storage-proof validity stays delegated to `dag.sh`/gate-result validation;
  the console exposes command-log evidence refs and exit codes (including
  `*-skip-guard-red` logs) but never independently rules a proof valid.

## What it reads

- `docs/orchestration/tasks/*.md`, `docs/orchestration/areas/*/state.md`,
  `docs/orchestration/gates/*.gate-result.json`
- `.singular-state/origin-state.json`, `.singular-state/events.ndjson`,
  `.singular-state/leases/*.json`,
  `.singular-state/l1-leases/*.json`, `.singular-state/inbox/*.json`
  (state packets), `.singular-state/runs/*` (run/audit artifacts)
- The newer existing loop log: `.singular-state/autonomate.log` (supported
  detached launch) or `.singular-state/autonomate.out.log` (legacy/adapter).
- `.worktrees/`

## L1 parallelism surfacing

When the L1 fanout runs (`SINGULAR_ENABLE_L1_PARALLEL=1`), the console shows
it from durable facts only: the plural DAG frontier marks every ready node
with the coral ◆ (not just the first); the top-bar frontier pill reads
`N ready · M` (M = live planners); an area with an *active*
`.singular-state/l1-leases/<node>.json` (status `proposed|planning|active`)
gets a blue **L1** badge and an **L1-lease** inspector tab
(node/status/runId/baseSha/scopes). A `released`/`failed` lease is history —
never a live agent, never "complete"; gate-result.v0 remains the sole
completion authority.

Skills/roles are surfaced two ways (Singular stores no literal skill
registry): the L0 inspector `roles` tab shows the declared role catalog, and
each task's `work` tab shows the roles that touched it and the
commands/tools they actually ran.

## JSON API (GET reads and three POST routes)

Routes below use GET unless POST is named. Settings supports both methods;
ask/report POSTs start work and create artifacts. The route inventory is
implemented in `plugin/scripts/singular_graph_server.py`.

```text
/                       → console UI
/assets/**              → client modules (extension-allowlisted: .css/.js/.mjs/.svg)
/api/state              → full orchestration snapshot (?fresh=1 forces a blocking
                          recompute; otherwise a stale snapshot is served instantly
                          with stale/computing/snapshotAgeSeconds set while a
                          background refresh runs — 0.5.0)
/api/task/TASK-0309     → full task detail (objective, scope, acceptance, required
                          evidence, lease, run id, worktree path + existence, packets,
                          integration audit, gate refs, task-scoped events, gate
                          command-log evidence summaries, agentsInvolved, toolsUsed)
/api/roles              → declared role/skill catalog (static, cached)
/api/health             → liveness
/api/lifecycle          → repository lifecycle state
/api/overview           → plan overview (DAG stages/nodes with gate status)
/api/node/<node-id>     → single DAG node detail (requiredCompletion, gate result,
                          tasks attributed to the node)
/api/area/<area>/nodes  → all DAG nodes for one area
/api/events?cursor=N    → paged reader over .singular-state/events.ndjson
                          (returns a next cursor; poll-friendly)
/api/sessions?limit=N   → runtime session inventory (planner/worker/auditor rows
                          incl. durable model/effort/exitCode session-meta;
                          supervisor briefing + ask runs appear as assistant-kind
                          rows (0.10.0); default 16, max 40; origin always included)
/api/session/<id>       → paged session transcript reader
                          (?cursor=N&limit=N&file=<name>&raw=1)
/api/dag                → full DAG view (0.6.0): nodes merged with gate results,
                          per-node task rollups, L1 leases, frontier flags,
                          edges[], stage/area swimlane metadata
/api/timeline?since=T   → execution history (0.6.0): per-task attempt intervals
                          (reconstructed from events; liveNow for running bars),
                          gate marks, L0 reconcile cycle spans
/api/config             → resolved per-role model/effort with env-key provenance
                          + limits/flags (0.6.0; .env > config env{} > defaults)
/api/home               → at-a-glance digest (0.7.0): health, attention[],
                          gates, frontier, taskCounts, dispatch/autonomate
                          liveness, breaker/backoff, 14-day activityByDay;
                          + loop (STATUS iteration/note), briefing (latest
                          supervisor report), supervisor {intervalMin,enabled} (0.10.0)
/api/settings           → GET: all knob rows (config env{} overlaid) + appliesAt;
                          POST {"changes":{KEY:value}} writes whitelisted keys
                          into singular.config.json env{} (""-value deletes a key)
/api/prompts            → role prompt library listing (0.7.0)
/api/prompt/<name>      → one prompt template's content
/api/raw/<root>/<name>  → raw durable file (roots: task, gate, gate-review,
                          lease, l1-lease, dispatch, inbox, state, config, dag)
/api/plans              → archived plan-thread registry (0.8.0,
                          singular.plans.v0): id, name, archivedAt, gates,
                          taskCount, eventCount, headSha, branch — from
                          .singular-state/plans/index.json (+ manifest self-heal)
/api/providers          → runtime/provider status (0.9.0, singular.providers.v0):
                          per agent CLI installed/version/path, authStatus +
                          email/plan (CLI status probes, 3s timeouts, 60s cache;
                          ?refresh=1 re-probes), env-key presence, runner script,
                          isDefaultRunner, roles, last-used session evidence, and
                          a per-provider quota field (0.10.0: Codex real usage
                          from local rollout JSONL; tier-only/not-exposed else).
                          Live-only (?plan= ignored); never contains secrets
/api/report             → POST: request a one-shot supervisor briefing (0.10.0);
                          spawns the readonly runner (429 while busy or inside the
                          60s throttle); ?plan= / archived plans rejected
/api/ask                → POST {"question": "…"}: ask the supervisor (0.10.0);
                          mints ASK-<id>, writes the question to a file (never on
                          argv), spawns the readonly runner; 202 {runId}; 429 busy
/api/ask/<id>           → one ask's state + answer (0.10.0; pure-FS; answer capped;
                          proposedSettings filtered to the settings whitelist)
/api/asks               → newest-20 ask runs (0.10.0)
```

**Plan threads (0.8.0).** After `singular plan archive` (see SKILL.md), each
archived plan lives at `.singular-state/plans/<plan-id>/` as a mini-repo
snapshot. Appending `?plan=<plan-id>` to the read endpoints (`/api/dag`,
`/api/timeline`, `/api/overview`, `/api/task`, `/api/node`, `/api/area`,
`/api/events`, `/api/sessions`, `/api/session`, `/api/prompts`,
`/api/prompt`, `/api/raw`) serves that archived snapshot; ids are validated
against the registry (unknown → 404). `/api/state`, `/api/home`,
`/api/config` and `/api/settings` are live-only and ignore the param; any
POST carrying `?plan=` is rejected 400 — archived plans are strictly
read-only. In the UI, the sidebar threads list (and the Home "Previous
plans" card) opens a thread in historical mode: a read-only banner, Plan
lenses + Consoles transcripts rendered from the archive, Agents disabled,
polling frozen. The supervisor briefing/chat and provider quota gauges are
live-only — historical `?plan=` mode shows none of them. Deep link:
`http://…/?plan=<plan-id>#plan/timeline`.

Snapshot extras: `orchestration.gates` `{passed,total,byNode}` (replaces the
legacy `gateD0`/`gateD1` probes; the built-in status/frontier/validate probes
are native file reads since 0.5.0 — no `make orch-*` subprocesses unless a
console adapter explicitly configures commands), `orchestration.nextAreas`
(plural frontier
`{frontier:[{node,area,...}],allComplete?}`), top-level `l1Leases[]` (each
with an `active` flag), `agents` block (`l0`, `l1[]` with
`l1Active`+`l1Lease`, notable non-terminal `l2[]`), a derived `state` on
every task/area, and `summary` with `stateCounts`, `l1PlannersActive`,
`frontierCount`.

For scripted monitoring, `/api/events?cursor=N` + `/api/state` is the stable
poll pair; the `--snapshot` mode emits the same snapshot JSON without a
server.
