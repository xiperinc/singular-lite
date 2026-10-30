/* core/api.js — the single client-side API chokepoint for plan threads (0.8.0).

   The console can be pinned to an archived plan by a `?plan=<id>` query param.
   In that "historical" mode every /api/ read must carry the same param so the
   server resolves the archived mini-repo instead of the live tree. Rather than
   thread that through 21 scattered fetch sites, every fetch now routes through
   apiFetch/apiUrl here, which merge the plan id into the path's query string.

   The active plan is decided ONCE at module init (boot) — switching plans is a
   full page reload (switchPlan), never an in-place cache/signature dance, so
   historical vs live is a single immutable decision for the life of the page.

   Imports NOTHING (dependency-free) so any module — core, surface, or app.js —
   may import it without forming a cycle. Since 0.17.0 it also hosts the tiny
   execution-state store (setExecState/getExecState/onExecState), and since
   0.23.5 the data-health store (getHealth/onHealth/onRecover/retryNow, bottom of
   the file), for the same reason: every surface needs them and nothing may
   import a surface to get them. No DOM here — core/health.js paints it. */

// A plan id as minted by `singular plan archive` (plan-<UTCstamp>[-<slug>]). This
// is also the sole gate on a value that becomes a server-side filesystem root, so
// the charset is tight and mirrors the server's PLAN_ID_RE exactly.
const PLAN_ID_RE = /^plan-[A-Za-z0-9-]{1,64}$/;

function parseActivePlan() {
  try {
    const raw = new URLSearchParams(location.search).get("plan");
    return raw && PLAN_ID_RE.test(raw) ? raw : null;
  } catch (e) { return null; }
}

// Parsed once, at boot. Null unless a valid ?plan= is present.
export const activePlan = parseActivePlan();

export function isHistorical() { return !!activePlan; }

// Merge plan=<id> into an /api/ path's EXISTING query string (paths like
// /api/session/x?cursor=0&limit=200&file=y exist — never a naive append). Live
// mode returns the path unchanged; non-/api/ paths (favicon/assets) are left
// alone so only the API carries the param.
export function apiUrl(path) {
  if (!activePlan) return path;
  if (typeof path !== "string" || !path.startsWith("/api/")) return path;
  try {
    const u = new URL(path, location.origin);
    u.searchParams.set("plan", activePlan);
    return u.pathname + u.search;
  } catch (e) { return path; }
}

// Every read goes through here, so this is also where the page learns whether
// its data is arriving (see "data health" at the bottom of the file). Callers
// keep their own contract — a Response, or the fetch rejection — unchanged.
export async function apiFetch(path, init) {
  const watched = isWatched(path, init);
  let res;
  try {
    res = await fetch(apiUrl(path), init);
  } catch (err) {
    // An aborted request is the caller changing its mind, not the server failing.
    if (watched && !(err && err.name === "AbortError")) noteFailure(path, { kind: "network" });
    throw err;
  }
  if (watched) {
    if (res.ok) noteOk(path);
    // 409 (configuration unavailable) and 5xx mean the data could not be
    // produced. Other 4xx are an answer about one item (unknown task, bad id).
    else if (res.status === 409 || res.status >= 500) noteFailure(path, await httpFailure(res));
    else noteOk(path);
  }
  return res;
}

// Navigate to the same page with ?plan= set (archived) or removed (live), hash
// reset to #home. A full reload is deliberate: historical mode is decided once at
// boot, so there is no in-place cache/signature invalidation to get wrong.
export function switchPlan(idOrNull) {
  try {
    const u = new URL(location.href);
    if (idOrNull) u.searchParams.set("plan", idOrNull);
    else u.searchParams.delete("plan");
    u.hash = "#home";
    location.href = u.toString();
  } catch (e) {
    location.href = idOrNull ? ("?plan=" + encodeURIComponent(idOrNull) + "#home") : "?#home";
  }
}

// ------------------------------------------------------------ exec state -----
// The console had exactly one liveness vocabulary, so "Current plan ·
// live" (a DATA-SOURCE fact — we are attached to the live tree, not an archive)
// read as "the orchestration loop is running". They are different facts and now
// have different stores: connection/plan-source stays where it was, EXECUTION
// state lives here as { loopAlive, stopPresent, stopReason }.
//
// app.js is the SOLE writer (setExecState after each /api/state snapshot and
// each /api/overview land) and never writes in historical mode — an archived
// plan's payload describes a finished run and can never be evidence that a loop
// is alive. Subscribe-with-replay mirrors plan/data.js's onDag so a subscriber
// registered before the first poll paints as soon as the state exists.
let execState = null;
let execSig = "";
const execSubs = new Set();

export function getExecState() { return execState; }

// Deduped on the composed value: a quiet 10s poll notifies nobody.
export function setExecState(next) {
  const s = next && typeof next === "object" ? next : null;
  const sig = s ? JSON.stringify([s.loopAlive, s.stopPresent, s.stopReason]) : "";
  if (sig === execSig) return;
  execSig = sig;
  execState = s;
  execSubs.forEach((fn) => { try { fn(execState); } catch (e) {} });
}

// Returns an unsubscribe. Replays the current state immediately when one exists.
export function onExecState(fn) {
  execSubs.add(fn);
  if (execState) { try { fn(execState); } catch (e) {} }
  return () => execSubs.delete(fn);
}

// ----------------------------------------------------------- data health -----
// 0.23.5. A failed poll used to be swallowed by each caller ("keep last good"),
// so a server answering 409 on every data route, or no server at all, looked
// exactly like a slow first load: "loading…" forever, or old numbers with no
// hint they were old. This store is the one place that knows.
//
//   ok       every watched read last succeeded
//   error    the server answered, but could not produce the data (409 / 5xx);
//            `message` / `reason` are the server's own words
//   offline  the request never got an answer (connection refused, DNS, reset)
//
// A failure is remembered per route (query string ignored) until that route
// succeeds again. While anything is failing the store re-probes those routes
// itself with backoff (1s, 2s, 4s, 8s, then every 10s) — so recovery does not
// wait for a hidden surface's poll or a page reload — and onRecover subscribers
// refetch as soon as the last one clears.
export const HEALTH_BACKOFF_MS = [1000, 2000, 4000, 8000, 10000];
export function backoffDelay(attempt) {
  return HEALTH_BACKOFF_MS[Math.min(Math.max(0, attempt | 0), HEALTH_BACKOFF_MS.length - 1)];
}
// Last good data older than this is no longer "current", whatever the reason.
export const STALE_POLLS = 3;
export function isStale(lastOkAt, pollMs, now) {
  return !!lastOkAt && (now == null ? Date.now() : now) - lastOkAt > STALE_POLLS * pollMs;
}
export const OFFLINE_HINT = "console server is not running — run `singular console --ensure`";

const failing = new Map();      // route -> { path, kind, status, error, message, reason, since, at, count }
const healthSubs = new Set();
const recoverSubs = new Set();
let failingSince = 0;           // epoch ms the current failing streak began
let lastOkAt = 0;               // epoch ms of the last successful watched read
let retryAttempt = 0;
let retryTimer = null;
let nextRetryAt = 0;
let probing = null;             // in-flight probe promise (single-flight)

function isWatched(path, init) {
  if (typeof path !== "string" || !path.startsWith("/api/")) return false;
  const method = String((init && init.method) || "GET").toUpperCase();
  return method === "GET";
}
const routeOf = (path) => String(path).split("?")[0];

async function httpFailure(res) {
  let body = null;
  try { body = await res.clone().json(); } catch (e) { /* not JSON */ }
  const cfg = body && typeof body.configuration === "object" && body.configuration ? body.configuration : null;
  const error = body && typeof body.error === "string" ? body.error : null;
  const message = (cfg && cfg.message) || (body && typeof body.message === "string" && body.message) || null;
  return { kind: "http", status: res.status, error, message: message ? String(message) : null,
           reason: cfg && cfg.reason ? String(cfg.reason) : null };
}

function noteFailure(path, info) {
  const route = routeOf(path);
  const now = Date.now();
  const prev = failing.get(route);
  if (!failing.size) { failingSince = now; retryAttempt = 0; }
  failing.set(route, Object.assign({ status: null, error: null, message: null, reason: null }, info,
    { path, route, since: prev ? prev.since : now, at: now, count: prev ? prev.count + 1 : 1 }));
  emitHealth();
  scheduleRetry();
}

function noteOk(path) {
  lastOkAt = Date.now();
  if (!failing.size) return;
  if (!failing.delete(routeOf(path))) return;
  if (failing.size) { emitHealth(); return; }
  failingSince = 0; retryAttempt = 0; nextRetryAt = 0;
  if (retryTimer) { clearTimeout(retryTimer); retryTimer = null; }
  emitHealth();
  fireRecover();
}

function fireRecover() { recoverSubs.forEach((fn) => { try { fn(); } catch (e) {} }); }
function emitHealth() { const h = getHealth(); healthSubs.forEach((fn) => { try { fn(h); } catch (e) {} }); }

function scheduleRetry() {
  if (retryTimer || probing || !failing.size) return;
  const delay = backoffDelay(retryAttempt);
  nextRetryAt = Date.now() + delay;
  retryTimer = setTimeout(() => { retryTimer = null; probe(); }, delay);
}

// Re-request every failing route once. Each goes through apiFetch, so a success
// clears it and a failure refreshes its detail; nothing here reads the bodies.
function probe() {
  if (probing) return probing;
  const paths = Array.from(failing.values()).map((f) => f.path).slice(0, 6);
  nextRetryAt = 0;
  probing = Promise.all(paths.map((p) =>
    apiFetch(p, { cache: "no-store" }).then((r) => {
      try { if (r.body && r.body.cancel) r.body.cancel(); } catch (e) {}
    }, () => {})
  )).then(() => {
    probing = null;
    if (failing.size) { retryAttempt += 1; scheduleRetry(); emitHealth(); }
  });
  emitHealth();
  return probing;
}

// The most recent failure speaks for the page: if the last thing we heard was
// silence, the server is gone, whatever an earlier route answered.
export function getHealth() {
  const failures = Array.from(failing.values()).sort((a, b) => b.at - a.at);
  const primary = failures[0] || null;
  return {
    state: !primary ? "ok" : primary.kind === "network" ? "offline" : "error",
    since: failingSince || null,
    lastOkAt: lastOkAt || null,
    primary,
    failures,
    retrying: !!probing,
    nextRetryAt: nextRetryAt || null,
    attempt: retryAttempt,
  };
}

// One line a person can act on. The server's message wins over our guess.
export function describeFailure(f) {
  if (!f) return "";
  if (f.kind === "network") return OFFLINE_HINT;
  const head = f.error || ("HTTP " + f.status);
  let text = f.route + " — " + head;
  if (f.message && f.message !== head) text += ": " + f.message;
  if (f.reason) text += " [" + f.reason + "]";
  if (f.error) text += " (HTTP " + f.status + ")";
  return text;
}

// Subscribe-with-replay (same shape as onExecState). Returns an unsubscribe.
export function onHealth(fn) {
  healthSubs.add(fn);
  try { fn(getHealth()); } catch (e) {}
  return () => healthSubs.delete(fn);
}

// Called once each time the page goes from failing back to ok — refetch here.
export function onRecover(fn) { recoverSubs.add(fn); return () => recoverSubs.delete(fn); }

// The Retry button: probe now and restart the backoff. With nothing recorded as
// failing (a surface that simply has no data yet) just ask everyone to refetch.
export function retryNow() {
  if (!failing.size) { fireRecover(); return Promise.resolve(); }
  if (retryTimer) { clearTimeout(retryTimer); retryTimer = null; }
  retryAttempt = 0;
  return probe();
}
