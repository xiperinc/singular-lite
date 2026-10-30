/* tests/console/api_health.test.mjs — the console's data-health store (0.23.5).

   The defect it covers: every data route answered 409 (or the server was gone)
   and the page kept showing "loading digest…" or old numbers, because each
   caller swallowed its own failed poll. core/api.js now records, per route,
   whether a read succeeded, failed with an HTTP answer, or got no answer at
   all, re-probes with backoff, and announces recovery.

   core/api.js is import-free and DOM-free, so this runs under bare
   `node --test` with a stubbed global fetch. The store is a module singleton:
   every test leaves it in the "ok" state for the next one. */

import test, { mock } from "node:test";
import assert from "node:assert/strict";
import {
  apiFetch, getHealth, onHealth, onRecover, retryNow, describeFailure,
  backoffDelay, isStale, HEALTH_BACKOFF_MS, OFFLINE_HINT, STALE_POLLS,
} from "../../plugin/assets/core/api.js";

// ---- a scriptable server --------------------------------------------------
const server = { mode: {}, calls: [] };   // mode[route] = "ok" | "409" | "500" | "404" | "down"
const CONFIG_409 = {
  error: "configuration unavailable",
  configuration: { status: "error", reason: "configuration-load-failed",
                   message: "effective configuration projection failed for /r/singular.config.json (exit 2)" },
  generation: { id: "abc", status: "unavailable" },
};
globalThis.fetch = async (url, init) => {
  const route = String(url).split("?")[0];
  server.calls.push(route);
  if (init && init.signal && init.signal.aborted) {
    const e = new Error("aborted"); e.name = "AbortError"; throw e;
  }
  const mode = server.mode[route] || server.mode["*"] || "ok";
  if (mode === "down") throw new TypeError("fetch failed");
  if (mode === "409") return new Response(JSON.stringify(CONFIG_409), { status: 409 });
  if (mode === "500") return new Response("boom", { status: 500 });
  if (mode === "404") return new Response(JSON.stringify({ error: "task not found" }), { status: 404 });
  return new Response(JSON.stringify({ ok: true }), { status: 200 });
};
const settle = () => new Promise((r) => setImmediate(r));
const get = (path, init) => apiFetch(path, init).then((r) => r, (e) => e);
function reset() { server.mode = {}; server.calls = []; }
async function heal() { reset(); await retryNow(); await settle(); assert.equal(getHealth().state, "ok"); }

test("a successful read is ok and stamps lastOkAt", async () => {
  reset();
  const res = await apiFetch("/api/home", { cache: "no-store" });
  assert.equal(res.status, 200);
  const h = getHealth();
  assert.equal(h.state, "ok");
  assert.equal(h.primary, null);
  assert.ok(h.lastOkAt > 0);
});

test("409 is an error that carries the server's message and reason", async () => {
  reset(); server.mode["/api/home"] = "409";
  const seen = [];
  const off = onHealth((h) => seen.push(h.state));
  const res = await apiFetch("/api/home", { cache: "no-store" });
  assert.equal(res.status, 409, "callers still receive the response");
  assert.deepEqual(await res.json(), CONFIG_409, "and can still read its body");
  const h = getHealth();
  assert.equal(h.state, "error");
  assert.equal(h.primary.route, "/api/home");
  assert.equal(h.primary.status, 409);
  assert.equal(h.primary.reason, "configuration-load-failed");
  assert.match(h.primary.message, /projection failed/);
  assert.ok(h.since > 0);
  const text = describeFailure(h.primary);
  assert.match(text, /^\/api\/home — configuration unavailable: effective configuration projection failed/);
  assert.match(text, /\[configuration-load-failed\]/);
  assert.match(text, /HTTP 409/);
  assert.deepEqual(seen.slice(0, 2), ["ok", "error"], "subscribers are replayed, then told");
  // A second failed poll of the same route keeps the original "since".
  const since = h.since, firstSince = h.primary.since;
  await get("/api/home?x=1");
  assert.equal(getHealth().since, since);
  assert.equal(getHealth().primary.since, firstSince);
  assert.equal(getHealth().primary.count, 2);
  assert.equal(getHealth().failures.length, 1, "the query string does not make a new route");
  off();
  await heal();
});

test("5xx is an error without a server message", async () => {
  reset(); server.mode["/api/state"] = "500";
  await get("/api/state");
  const h = getHealth();
  assert.equal(h.state, "error");
  assert.equal(describeFailure(h.primary), "/api/state — HTTP 500");
  await heal();
});

test("no answer at all is offline and names the command to run", async () => {
  reset(); server.mode["*"] = "down";
  const err = await get("/api/state");
  assert.ok(err instanceof TypeError, "the rejection still reaches the caller");
  const h = getHealth();
  assert.equal(h.state, "offline");
  assert.equal(describeFailure(h.primary), OFFLINE_HINT);
  assert.match(OFFLINE_HINT, /not running/);
  assert.match(OFFLINE_HINT, /`singular console --ensure`/);
  await heal();
});

test("the latest failure decides between error and offline", async () => {
  reset(); server.mode["/api/home"] = "409";
  await get("/api/home");
  assert.equal(getHealth().state, "error");
  server.mode["*"] = "down"; server.mode["/api/home"] = "down";
  await new Promise((r) => setTimeout(r, 3));
  await get("/api/state");
  assert.equal(getHealth().state, "offline");
  assert.equal(getHealth().failures.length, 2);
  await heal();
});

test("item-level 4xx, writes and aborted requests are not data failures", async () => {
  reset(); server.mode["/api/task/TASK-1"] = "404"; server.mode["/api/settings"] = "500";
  assert.equal((await get("/api/task/TASK-1")).status, 404);
  assert.equal(getHealth().state, "ok");
  assert.equal((await get("/api/settings", { method: "POST", body: "{}" })).status, 500);
  assert.equal(getHealth().state, "ok");
  const ac = new AbortController(); ac.abort();
  const err = await get("/api/home", { signal: ac.signal });
  assert.equal(err.name, "AbortError");
  assert.equal(getHealth().state, "ok");
  await get("/favicon.ico");
  assert.equal(getHealth().state, "ok");
});

test("recovery is announced once, when the last failing route clears", async () => {
  reset(); server.mode["/api/home"] = "409"; server.mode["/api/dag"] = "409";
  let recovered = 0;
  const off = onRecover(() => { recovered += 1; });
  await get("/api/home"); await get("/api/dag");
  assert.equal(getHealth().failures.length, 2);
  server.mode["/api/home"] = "ok";
  await get("/api/home");
  assert.equal(getHealth().state, "error", "one route is still failing");
  assert.equal(recovered, 0);
  server.mode["/api/dag"] = "ok";
  await get("/api/dag");
  assert.equal(getHealth().state, "ok");
  assert.equal(getHealth().since, null);
  assert.equal(recovered, 1);
  await get("/api/dag");
  assert.equal(recovered, 1, "a quiet poll announces nothing");
  off();
});

test("backoff is 1s, 2s, 4s, 8s, then capped at 10s", () => {
  assert.deepEqual(HEALTH_BACKOFF_MS, [1000, 2000, 4000, 8000, 10000]);
  assert.deepEqual([0, 1, 2, 3, 4, 5, 50].map(backoffDelay), [1000, 2000, 4000, 8000, 10000, 10000, 10000]);
  assert.equal(backoffDelay(-1), 1000);
});

test("it keeps retrying by itself and recovers without anyone polling", async () => {
  reset();
  mock.timers.enable({ apis: ["setTimeout"] });
  try {
    server.mode["*"] = "down";
    let recovered = 0;
    const off = onRecover(() => { recovered += 1; });
    await get("/api/state");
    assert.equal(getHealth().state, "offline");
    assert.equal(server.calls.length, 1);
    // Nothing else calls apiFetch from here on: every further request is the
    // store's own probe, spaced by the backoff schedule.
    const waits = [1000, 2000, 4000, 8000, 10000, 10000];
    for (let i = 0; i < waits.length; i += 1) {
      mock.timers.tick(waits[i] - 1);
      await settle();
      assert.equal(server.calls.length, 1 + i, `no probe before ${waits[i]}ms (attempt ${i})`);
      mock.timers.tick(1);
      await settle();
      assert.equal(server.calls.length, 2 + i, `probe after ${waits[i]}ms (attempt ${i})`);
      assert.equal(getHealth().state, "offline");
      assert.equal(recovered, 0);
    }
    assert.ok(getHealth().nextRetryAt > 0, "the next retry time is published for the banner");
    server.mode = {};                    // the server comes back
    mock.timers.tick(10000);
    await settle();
    assert.equal(getHealth().state, "ok");
    assert.equal(recovered, 1);
    const calls = server.calls.length;
    mock.timers.tick(60000);
    await settle();
    assert.equal(server.calls.length, calls, "no probing once healthy");
    off();
  } finally { mock.timers.reset(); }
});

test("Retry probes immediately and restarts the backoff", async () => {
  reset(); server.mode["/api/home"] = "409";
  await get("/api/home");
  const before = server.calls.length;
  await retryNow();
  assert.equal(server.calls.length, before + 1);
  assert.equal(getHealth().state, "error");
  let recovered = 0;
  const off = onRecover(() => { recovered += 1; });
  server.mode = {};
  await retryNow();
  assert.equal(getHealth().state, "ok");
  assert.equal(recovered, 1);
  // With nothing failing, Retry still asks every surface to refetch.
  await retryNow();
  assert.equal(recovered, 2);
  off();
});

test("data older than three polls is stale", () => {
  assert.equal(STALE_POLLS, 3);
  const poll = 10000, t0 = 1_000_000;
  assert.equal(isStale(t0, poll, t0 + 30000), false);
  assert.equal(isStale(t0, poll, t0 + 30001), true);
  assert.equal(isStale(0, poll, t0), false, "never loaded is not 'stale', it is 'no data'");
});
