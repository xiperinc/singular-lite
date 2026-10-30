/* core/plans.js — the plan-thread registry client (0.8.0; sidebar threads 0.10.0;
   static header surface tabs 0.18.0).
   Fetches /api/plans once at boot (and lazily as the pointer enters the threads
   column), owns the sidebar threads list (#side-threads-list — the live plan plus
   every archived plan), the historical-mode banner, the stop reason, and — in
   historical mode — the archived plan's gates in the Plan workbench readout.

   Import direction: plans.js → core/api.js only (never a surface, never app.js,
   never the router — surface state remains the router's responsibility), so it
   sits low in the graph and any surface + main.js may import it. That still
   holds with the execution-state subscription (0.17.0): the store lives in
   core/api.js, so plans.js reads app.js's execution facts without importing
   app.js. The tiny esc/fmtDate helpers are local (kept dependency-free on
   purpose).

   Vocabulary rule: this module describes DATA SOURCES, never execution.
   A plan row's meta says "connected" (we are attached to the live tree) or a
   date; the words running / stopped / waiting / blocked belong to execution and
   appear here only in #stop-reason, which is fed from the exec store. */

import { activePlan, isHistorical, apiFetch, switchPlan, onExecState, onRecover } from "./api.js";

const MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

const esc = (v) => String(v == null ? "" : v).replace(/[&<>"']/g, (c) =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

function fmtDate(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  if (isNaN(d)) return String(iso).slice(0, 10);
  return `${MON[d.getUTCMonth()]} ${d.getUTCDate()}`;
}

// null = not fetched yet OR the endpoint is unavailable (older server); an array
// (possibly empty) means the endpoint answered. Callers use null to hide the
// feature quietly.
let plansData = null;
let fetched = false;
let inflight = null;

export function plansList() { return plansData; }

export function activePlanEntry() {
  if (!activePlan || !plansData) return null;
  return plansData.find((p) => p.id === activePlan) || null;
}

export async function fetchPlans(force) {
  if (inflight) return inflight;
  if (fetched && !force) return plansData;
  inflight = (async () => {
    try {
      const res = await apiFetch("/api/plans", { cache: "no-store" });
      if (res.ok) {
        const data = await res.json();
        plansData = Array.isArray(data.plans) ? data.plans : [];
      }
      // A non-OK response leaves plansData as-is (null on first miss) so the
      // switcher/card stay hidden on servers without the endpoint.
    } catch (e) { /* leave last good; null signals unavailable */ }
    finally { fetched = true; inflight = null; }
    return plansData;
  })();
  return inflight;
}

// archived-thread meta line: MMM D · gates P/T (mirrors home/surface.js:106-109)
function archivedMeta(p) {
  const g = p.gates || {};
  const gp = g.passed != null ? g.passed : "?";
  const gt = g.total != null ? g.total : "?";
  return `${fmtDate(p.archivedAt)} · gates ${gp}/${gt}`;
}

// one 32px thread row: a leading tone dot, then a name over a mono meta line.
function threadRow(id, tone, active, name, meta) {
  return `<button class="side-thread" data-plan-switch="${esc(id)}" data-active="${active ? "true" : "false"}" title="${esc(name)}">
    <span class="tone-dot" data-tone="${esc(tone)}"></span>
    <span class="st-main"><span class="st-name">${esc(name)}</span><span class="st-meta mono">${esc(meta)}</span></span>
  </button>`;
}

// ------------------------------------------------------------- threads --------
// Paint the sidebar threads list: the live plan first (acts as back-to-live while
// historical), then every archived plan newest-first. plansData==null (older
// server) or an empty registry → just the live row (feature quietly minimal).
function renderThreads() {
  const host = document.getElementById("side-threads-list");
  if (!host) return;
  const list = plansData || [];
  const live = !isHistorical();
  // Live row: green (success) dot = we are CONNECTED to the live tree (a data
  // source), active (page bg) only when live. The meta used to read "live",
  // which operators read as "the orchestration loop is running" — the dot stays,
  // the word does not. Execution state is the top stop chip's job.
  let html = threadRow("", "success", live, "Current plan", "connected");
  for (const p of list) {
    const on = p.id === activePlan;
    // The pinned archived plan gets the coral accent dot; the rest stay quiet.
    html += threadRow(p.id, on ? "integration" : "idle", on, p.name || p.id, archivedMeta(p));
  }
  // Self-heal edge: historical on an id the registry didn't return — still list it.
  if (isHistorical() && !list.some((p) => p.id === activePlan)) {
    html += threadRow(activePlan, "integration", true, activePlan, "archived");
  }
  host.innerHTML = html;
}

// ------------------------------------------------------------- exec chip ------
// #stop-reason is the reason half of the top-bar stop chip. app.js exclusively
// owns #stop-text ("stopped" / "stop clear"); this module appends the actionable
// reason without either writer replacing the other's text. Fed by core/api.js's
// exec store, which app.js writes only in live mode.
function paintExecCrumb(state) {
  const reason = document.getElementById("stop-reason");
  if (!reason) return;
  const chip = document.getElementById("stop-chip");
  if (isHistorical() || !state || !state.stopPresent || !state.stopReason) {
    reason.textContent = "";
    reason.hidden = true;
    if (chip) chip.removeAttribute("title");
    return;
  }
  reason.textContent = " — " + state.stopReason;
  reason.hidden = false;
  if (chip) chip.title = state.stopReason;
}

// ------------------------------------------------------------- banner ---------
function paintBanner() {
  const banner = document.getElementById("plan-banner");
  if (!banner) return;
  if (!isHistorical()) { banner.hidden = true; return; }
  const entry = activePlanEntry();
  const name = (entry && entry.name) || activePlan;
  const when = entry && entry.archivedAt ? fmtDate(entry.archivedAt) : "";
  const txt = banner.querySelector(".pb-text");
  if (txt) txt.textContent = `Viewing archived plan ${name}${when ? " (" + when + ")" : ""} — read-only`;
  banner.hidden = false;
}

// The Plan workbench gates readout, in historical mode, reflects the archived
// plan's registry entry (app.js suppresses its own gates write when historical).
function paintArchivedGates() {
  if (!isHistorical()) return;
  const entry = activePlanEntry();
  const val = document.getElementById("plan-gates-val");
  if (!val || !entry || !entry.gates) return;
  const g = entry.gates;
  val.textContent = `${g.passed != null ? g.passed : "?"}/${g.total != null ? g.total : "?"}`;
}

// ------------------------------------------------------------- init -----------
export function initPlans() {
  if (isHistorical()) document.body.classList.add("historical");

  const backBtn = document.getElementById("pb-back");
  if (backBtn) backBtn.addEventListener("click", () => switchPlan(null));

  // Sidebar threads list: click a row to switch plan (empty id = the live row =
  // back-to-live while historical); refresh the registry lazily as the pointer
  // enters the column so the list is fresh without a poll.
  const threads = document.getElementById("side-threads");
  if (threads) {
    threads.addEventListener("click", (e) => {
      const b = e.target.closest("[data-plan-switch]");
      if (!b) return;
      const id = b.dataset.planSwitch;
      if (id) switchPlan(id);
      else if (isHistorical()) switchPlan(null);   // "Current plan" while historical → back to live
    });
    threads.addEventListener("pointerenter", () => { fetchPlans(true).then(() => renderThreads()); });
  }

  if (isHistorical()) {
    // Agents + Providers are live-only surfaces. Both controls are static, so a
    // single boot-time disable matches the router's historical redirect.
    for (const nav of document.querySelectorAll('#surface-tabs [data-surface="agents"], #side-nav [data-surface="providers"]')) {
      nav.disabled = true;
      nav.title = "live only";
    }
  }

  // Execution chip: subscribe-with-replay, so it paints on the first snapshot
  // app.js publishes (initPlans runs before start()) and on every change after.
  onExecState(paintExecCrumb);

  renderThreads();   // paints the live row (+ self-heal id) immediately
  paintBanner();     // shows the id fallback immediately; refreshed once plans resolve
  fetchPlans().then(() => { renderThreads(); paintBanner(); paintArchivedGates(); });
  // The registry is fetched once; if that one read failed, take it again when
  // reads recover instead of leaving the threads list empty until a reload.
  onRecover(() => { fetchPlans(true).then(() => { renderThreads(); paintBanner(); paintArchivedGates(); }); });
}

export { fmtDate };
