# Design note: process-group fencing for dispatch cleanup (Q1)

Scope: the fence only. It does not redesign the reaper (plan item 2) or the
retained-worktree guard (item 3). Engine 0.23.2, verified against the working
tree at `d5d5b37` + Item ①.

**Provenance.** Claims marked **[V]** I verified myself this session by reading
the cited lines or by running the stated experiment. Claims marked **[S]** come
from subagent investigation and are **not** independently verified — do not act
on them without checking.

---

## 1. The ruling, restated

`singular_dispatch_tree_alive` does not establish absence, and the bind-failure
cleanup killing a bare `$dispatch_pid` is wrong given detached mode's `setsid`.
Both hold.

**[V]** `engine/reconcile.sh:613` writes the dispatch record; when that write
fails, `:618` runs `kill "$dispatch_pid" 2>/dev/null || true` — a single pid, no
group, no verification.

**[V]** `engine/reconcile.sh:604-605` execs a `python3` shim that calls
`os.setsid()` inside `try: … except OSError: pass`. So the signalled pid is the
session leader of a *different* session than reconcile's, and any provider
grandchildren survive a bare `kill`. The swallowed `OSError` also means a child
can silently fail to become a session leader while the code still treats the
dispatch as detached.

**[V]** `singular_dispatch_tree_alive` (`engine/lib.sh:6310`) shells out to
`subprocess.run(["ps", "-A", …], capture_output=True)` and **never checks the
return code**. Where process enumeration is denied or `ps` fails, stdout is
empty, no pid matches, and a live worker is reported dead. It is a liveness
heuristic, not an absence proof.

---

## 2. Constraint 1 — holds, and there are two helpers, not one

**[V]** Both exist already; the change is a call site, not a subsystem.

| Helper | Keyed on | Leader proof |
|---|---|---|
| `singular_kill_dispatch_pgroup` (`lib.sh:6410`) | **task id** → reads the dispatch record | `[[ "$pgid" == "$pid" ]]` at `:6419` — both fields read from the *same JSON record* |
| `singular_kill_tree` (`lib.sh:1698`) | **pid** (`pid`, `grace_sec`, optional literal `session`) | live `os.getpgid(root)`, requiring `found == root && found != own_pgid && found > 1` |

**RESOLVED — shipped in 0.23.3.** The fence calls `singular_kill_tree` with the
recorded leader **PID** and the `session` claim, never with the pgid: the helper
is pid-keyed and resolves the group itself through a live `os.getpgid(root)`.
An earlier draft of this note spoke of passing "the group" to the fence; that was
imprecise and is corrected here — passing a pgid would reintroduce exactly the
record-internal trust this section argues against.

**The bind-failure site must use `singular_kill_tree`.** The decisive reason is
that `singular_kill_dispatch_pgroup` opens with
`record="$(singular_dispatch_record_path "$task_id")"; [[ -f "$record" ]] || return 1`
(**[V]** `lib.sh:6413-6414`) — and at `reconcile.sh:618` **the dispatch-record
write is precisely what just failed**. The record-keyed helper is structurally
unable to act there: it either finds no record and returns 1, or finds a stale
one from a previous generation and acts on the wrong pgid. `singular_kill_tree`
needs only the pid reconcile already holds in `$dispatch_pid`, and reconcile is
the spawner, so it can legitimately pass the `session` claim.

Its secondary advantage: it reports an outcome. **[V]** it sets
`SINGULAR_KILL_TREE_RESULT` / `_REASON` / `_MODE`, with modes `group-proven`,
`group-asserted` and `tree` — which is exactly the signal the tri-state in §4
needs. The record-keyed helper returns only 0/1.

---

## 3. Constraint 2 — amended; the ruling was wrong here

> *"Validate against the recorded pid start time before signalling. If you cannot validate, do not signal."*

The intent is right; the mechanism cannot work in the case the fence exists for.

**[V]** `singular_dispatch_pid_start` (`lib.sh:6208`) is
`ps -p "$pid" -o lstart=`. Its own comment says "empty if the pid is gone."

**[V] Measured this session:**

```
while alive:     Fri Sep 18 08:34:21 2026
after exit:      []
```

So `pidStart` can validate a PGID **only while the group leader is still alive**.
The orphan case the fence exists for — leader dead, descendants alive — is
exactly where it returns nothing. Constraint 2 as written would forbid signalling
in every case where signalling is the point.

### Worse: the engine's stated reuse guard does not hold

**[V]** `lib.sh:1538-1541` documents the containment argument:

> *"The spawner keeps the child un-reaped, which is what makes the pid (and therefore the pgid) safe to signal later: neither can be recycled while the entry is still in the table."*

**[V] Measured this session** — a backgrounded child that exits is auto-reaped by
bash, leaves the process table, and `kill -0` fails:

```
NOT IN TABLE (invariant does NOT hold) — ps rc=1
kill -0 FAILS -> pid is free for reuse
```

The documented "costs one integer and no process enumeration" proof is therefore
unsound as stated, and `singular_kill_dispatch_pgroup`'s record-internal
`pgid == pid` guard rests on it. This is an argument for using the live-kernel
guard, not the record one — and for not extending the record-keyed helper.

### Substitute guard

Use `singular_kill_tree`'s live check as the fence's validation: resolve
`os.getpgid(root)` at signal time and require `found == root` (root is its own
group leader, i.e. setsid succeeded), `found != own_pgid` (never signal our own
group), and `found > 1`. Signal only on `group-proven`. Treat `group-asserted`
— the caller's `session` claim without kernel confirmation — as **not proven**
for fencing purposes, even though the existing runners accept it.

### Residual limits, stated plainly

1. `os.getpgid(root)` proves the group leader is alive *now*. It cannot prove
   the group's membership is the one recorded, only that the leader pid still
   leads its own group. A recycled pid that happens to be a session leader
   passes. The window is smaller than the record-internal check but not zero.
2. **[V]** `singular_pgroup_alive` (`lib.sh:1639-1652`) does `os.kill(-pgid, 0)`
   and maps `ProcessLookupError` → dead, but **`except Exception: sys.exit(0)`
   → alive**. Any `PermissionError` therefore reads as alive. **[S]** macOS is
   reported to raise EPERM for an unwaited zombie group; I verified the code
   path, not the platform behaviour. Consequence either way: EPERM cannot be
   distinguished from "alive", so it must map to `unknown`, never to `dead`.
3. Neither guard survives a sandbox that denies process enumeration. That is the
   `unknown` branch, not a failure to be engineered away.

---

## 4. Constraint 3 — holds

`alive` / `dead` / `unknown → quarantine + park`. Termination is not observation:
a successful `kill` licenses **no** transition to `dead`. The fence must
re-observe afterwards and, if it still cannot prove absence, return `unknown`.

Mapping from `singular_kill_tree`:

| Observation | Fence result |
|---|---|
| `group-proven`, group gone after signal + verify | `dead` |
| leader alive, `os.getpgid` answers | `alive` |
| `group-asserted` only, enumeration denied, EPERM, `ps` non-zero, or `setsid` unconfirmed | `unknown` |

---

## 5. Acceptance criterion — and the open item that fails it

> Every state the fence can produce, including quarantine and park, must have an engine-executable exit — scheduler, reaper, or public CLI verb.

| State | Engine-executable exit |
|---|---|
| `alive` | Normal completion, or the execution deadline. Exists. |
| `dead` | Dispatch closed by the reaper (`close-dispatch`, shipped in 0.23.3). |
| `unknown → quarantined` | `singular fence <task_id>`, re-runnable; parks on proven absence, otherwise exits 3 and retains the fence. Shipped in 0.23.3. |

### Q-OPEN-1 — RESOLVED in 0.23.3: `singular fence <task_id>`

Shipped together with the producer, because a fence that can create a state
nothing clears reintroduces the bug class this sequence removes, and an exit verb
for a state nothing produces is dead code.

`engine/fence.sh` terminates via `singular_kill_tree` (pid-keyed, `session`
claim), **re-observes** afterwards — a successful kill is delivery, not absence —
and transitions `quarantined → parked` only on `ProcessLookupError`. Everything
else stays quarantined with the resource fence retained, exit 3, and a
machine-readable reason: EPERM (a process exists that cannot be queried), any
other errno, and a `getpgid` that merely SUCCEEDS, since a recycled leader pid
makes an unrelated process answer. A kill whose mode is `group-asserted` or
`tree` rather than `group-proven` also degrades a dead leader back to `unknown`,
because the leader being gone is not the group being gone.

Pinned by `tests/test-process-fence.sh`. The unprovable cases are asserted at
source level on purpose: exercising them end to end would mean running the kill
path against a process the test does not own.

### Q-OPEN-1 — original statement (for the record)

The fence introduces a state no existing verb clears. This is not cosmetic: a
fence that produces a state only a human can clear **reintroduces exactly the bug
class this sequence exists to remove**, and would do it while holding a worktree.

`unpark` is not the answer as it stands. **[V]** `singular_lease_unpark`
(`lib.sh:6035`) flips `status` to `ready` and resets `retryCount` /
`productPassStarted`; it performs no liveness check. Unparking an
`owner-unfenced` task would hand a possibly-still-written worktree to a second
worker — an S1 violation, and a worse failure than the deadlock it replaces.

The exit verb must **re-run the fence** and clear the quarantine only on a
`dead` result, with the resource fence retained on `unknown`. Two candidate
shapes, both deferred to the item-2 design:

- extend the reaper to re-observe quarantined dispatches each cycle, so a group
  that dies later is closed automatically and no operator action is needed in
  the common case; **plus**
- a public `singular lifecycle release-quarantine TASK-XXXX` that re-observes
  once and refuses with a machine-readable reason when it still cannot prove
  absence.

The first alone leaves a permanently-unprovable group stuck; the second alone
requires an operator for every transient. Both are needed. **This must be
decided before the fence ships.** Until then the fence should be built but its
`unknown` branch left routed to the existing refusal path, so it cannot create a
state the engine cannot leave.

### Q-OPEN-2 — RESOLVED in 0.23.3: the setsid outcome is recorded at bind

`singular_lifecycle_dispatch_record_write` compares the observed pgid with the
pid and persists `sessionLeader` on the dispatch record. `pgid == pid` is the
session-leader proof, so a child that failed to become one is now diagnosable at
bind time instead of surfacing much later as a permanent `unknown` from the
fence. reconcile still swallows the `OSError`; this records the consequence
rather than changing the spawn.

### Q-OPEN-2 — original statement (for the record)

**[V]** `reconcile.sh:605` swallows `OSError` from `os.setsid()`. A child that
failed to become a session leader is recorded as if detached, and its recorded
pgid is reconcile's own — which the `found != own_pgid` guard then correctly
refuses, turning a containment failure into a permanent `unknown`. Worth
recording the setsid outcome at spawn so this is diagnosable rather than
inferred.

---

## 6. What this note does not establish

- **[S]** That `$!` in detached mode is in fact the setsid leader with
  `pgid == pid`. `lib.sh:1538-1540` asserts it and `reconcile.sh:604` does
  `setsid` + `exec`, but I did not measure the resulting pgid. The fence's live
  guard does not depend on the claim being true — it checks it — but the
  *frequency* of the `unknown` branch does.
- **[S]** macOS EPERM-on-zombie (see §3, limit 2).
- **[S]** Reported tri-state handling elsewhere (`ops.sh`, `recover.sh`). Not
  checked; item 2 should not assume it.
- Any claim about how often `unknown` occurs in practice. There is no telemetry
  for it, which is itself an argument for plan item 6.
