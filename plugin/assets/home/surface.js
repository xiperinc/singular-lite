/* home/surface.js — the Home surface (0.7.0 workspace polish).

   The default landing surface: a 16:9 glance canvas over GET /api/home
   (singular.codex.home.v0, 10s aggregate). Top→bottom: a hero health + attention
   row, a gates block with per-stage bars (from the shared plan/data.js dag), the
   relocated live event feed side-by-side with a dependency-free 14-day activity
   sparkline, a throughput/limits tile row, and quick links into Plan/Consoles.

   Home owns an independent 10s /api/home poll (paused while hidden) and also
   re-renders on the shared snapshot tick for immediacy. Render is signature-gated
   so a quiet poll produces zero rebuilds. The live feed itself is painted by the
   relocated overlay poll in app.js (renderActivityFeed) into #home-activity-feed,
   so it stays out of the Home signature and updates on its own 2s cadence. */

import { S, esc, escAttr, icon, toneOf, relTime, toast, select, navigateToTask, renderActivityFeed } from "../app.js";
import { getDag, fetchDag, onDag } from "../plan/data.js";
import { feedState, subscribe as subscribeSessions } from "../core/sessions-feed.js";
import { apiFetch, isHistorical, switchPlan, onRecover } from "../core/api.js";
import { loadingHtml } from "../core/health.js";
import { fetchPlans, plansList, activePlanEntry, fmtDate } from "../core/plans.js";

const POLL_MS = 10000;
const MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

const HOME = {
  started: false,
  visible: false,
  data: null,          // last /api/home payload
  inflight: false,
  timer: null,
  sig: null,
  entering: false,     // true for exactly one route-entry render → cards `arrive` once
  dagUnsub: null,
  prov: null,          // last /api/providers payload (quota fields only)
  provInflight: false,
  pollTick: 0,         // 10s tick counter; providers re-fetch every 6th (~60s)
};

// Supervisor chat — a feed-precedent controller that lives OUTSIDE signature().
// Its state drives renderChat() into the stable #home-sup-chat host + the input
// row; a full home rebuild recreates the host and repaints from here, and the
// 3s poll repaints the host directly without a home-canvas rebuild.
const CHAT = {
  items: [],           // [{runId, question, state, answer, proposedSettings, applied}]
  seeded: false,       // seeded once from /api/asks on first activation
  polling: false,      // a send is in flight and being polled
  timer: null,         // 3s poll interval handle
  pollStart: 0,        // epoch ms of the current poll (12-min cap)
  draft: "",           // in-progress input text, preserved across repaints
};
const CHAT_POLL_MS = 3000;
const CHAT_POLL_CAP_MS = 12 * 60 * 1000;
const shortKey = (k) => String(k || "").replace(/^SINGULAR_/, "").toLowerCase().replace(/_/g, " ");

const HEALTH_TONE = { ok: "success", healthy: "success", watch: "warn", blocker: "error" };
const HEALTH_LABEL = { ok: "all clear", healthy: "all clear", watch: "watch", blocker: "blocker" };

// ------------------------------------------------------------- data fetch -----
async function fetchHome() {
  // Historical Home renders from the /api/plans registry entry + the archived dag
  // (never /api/home, which is a live-only digest). Handled in setHomeActive/render.
  if (isHistorical() || HOME.inflight) return;
  HOME.inflight = true;
  try {
    const res = await apiFetch("/api/home", { cache: "no-store" });
    if (res.ok) { HOME.data = await res.json(); }
    await fetchPlans();   // feeds the "Previous plans" card (folded into signature())
    render();
  } catch (e) { /* keep last good; a transient miss must not blank Home */ }
  finally { HOME.inflight = false; }
}

// Provider subscription quota (the same /api/providers payload the Providers
// surface polls; Home reads only the additive per-provider quota field). Plain
// GET — never ?refresh=1 (rides the server's 60s cache), never in historical.
async function fetchProviders() {
  if (HOME.provInflight || isHistorical()) return;
  HOME.provInflight = true;
  try {
    const res = await apiFetch("/api/providers", { cache: "no-store" });
    if (res.status === 404 || res.status === 501) { HOME.prov = null; }
    else if (res.ok) { HOME.prov = await res.json(); render(); }
  } catch (e) { /* keep last good; quota is a quiet section */ }
  finally { HOME.provInflight = false; }
}

// ------------------------------------------------------------- signature ------
function signature() {
  const d = HOME.data;
  if (!d) return "nohome";
  const abd = (d.activityByDay || []).map((x) => [x.dispatches, x.integrations, x.failures]).join(",");
  // Gates: the combined figure PLUS the cohort split, so a campaign gate landing
  // (which moves cohorts.current without changing the combined total) repaints.
  // Appended, not substituted, so a server without cohorts produces the exact
  // signature it did before and no spurious rebuild happens mid-deploy.
  const gc = (d.gates && d.gates.cohorts) || null;
  const gcCur = (gc && gc.current) || {};
  const gcHist = (gc && gc.historical) || {};
  const gates = d.gates
    ? `${d.gates.passed}/${d.gates.total}` +
      (gc ? `~${gcCur.passed}/${gcCur.total}~${gcHist.passed}/${gcHist.total}` : "")
    : "-";
  const dag = getDag();
  const stages = dag ? (dag.stages || []).map((s) => `${s.id}:${s.passed}/${s.total}`).join("|") : "-";
  const disk = S.snap && S.snap.disk;
  const snapExtra = S.snap ? [
    (S.snap.git && S.snap.git.drift && (S.snap.git.drift.left + "/" + S.snap.git.drift.right)) || "-",
    // disk: 5% buckets + the watch bit — a ±1–2% df flap must not rebuild Home
    // (the tile may read up to 4% stale until any other component changes).
    disk && disk.capacityPercent != null ? Math.round(disk.capacityPercent / 5) * 5 + (disk.watch ? "w" : "") : "-",
  ].join(",") : "-";
  // Live-session chips (linksHtml) — exactly the fields the card consumes, so a
  // quiet 2s sessions poll no-ops here instead of forcing a canvas rebuild.
  const sess = (feedState().sessions || []).filter((s) => s.live && s.id !== "origin").slice(0, 6)
    .map((s) => s.id + ":" + (s.taskId || s.node || "")).join("|");
  const pl = plansList();
  const plansSig = pl == null ? "np" : pl.map((p) => p.id + ":" + ((p.gates && p.gates.passed) != null ? p.gates.passed : "?")).join(",");
  // Supervisor + quota fold into the signature (the chat controller does NOT —
  // it repaints its own host). loop.iteration/note + briefing.generatedAt +
  // supervisor.enabled drive the supervisor card; quotaSig() drives the gauge.
  const loop = d.loop || {};
  const supSig = [loop.iteration, loop.note, d.briefing && d.briefing.generatedAt,
    d.supervisor && d.supervisor.enabled, (d.frontier && d.frontier.nodes && d.frontier.nodes[0]) || "-"].join(",");
  return [d.health, (d.attention || []).length, gates, JSON.stringify(d.taskCounts || {}),
    JSON.stringify(d.dispatch || {}), d.stop, d.breaker && d.breaker.consecFails,
    d.backoff && d.backoff.active, d.lastActivityAt, abd, stages, snapExtra,
    (d.frontier && d.frontier.count) || 0, plansSig, supSig, quotaSig(), sess].join("::");
}

// Per-provider quota signature — id/available/rounded %/resetsAt/plan/reason +
// a coarse stale-threshold bit (so the section repaints only on a real change).
function quotaSig() {
  const provs = (HOME.prov && HOME.prov.providers) || [];
  return provs.map((p) => {
    const q = p.quota || {};
    const pct = q.usedPercent != null ? Math.round(q.usedPercent) : "-";
    return [p.id, q.available, pct, q.resetsAt, p.plan, p.authStatus, q.reason,
      (q.staleSeconds || 0) > 7200].join(":");
  }).join("|");
}

// ------------------------------------------------------------- render ---------
function render() {
  if (!HOME.visible) return;
  const host = document.getElementById("home-body");
  if (!host) return;
  if (isHistorical()) { renderHistorical(host); return; }
  const sig = signature();
  if (sig === HOME.sig) return;
  HOME.sig = sig;
  const d = HOME.data;
  // No digest yet: a loading line, or — while reads are failing — the error
  // with a Retry button. core/health.js keeps the placeholder current.
  if (!d) { host.innerHTML = loadingHtml("digest", "home-loading"); return; }
  // Preserve chat focus across the rebuild (the draft itself rides CHAT.draft).
  const chatFocused = document.activeElement && document.activeElement.id === "home-sup-input";
  host.innerHTML =
    `<div class="home-canvas${HOME.entering ? " is-entering" : ""}">
       ${heroHtml(d)}
       ${supervisorHtml(d)}
       ${gatesHtml(d)}
       ${activityHtml(d)}
       ${tilesHtml(d)}
       ${quotaHtml()}
       ${linksHtml(d)}
       ${prevPlansHtml()}
     </div>`;
  consumeEntrance(host);
  // Repaint the relocated event feed + the supervisor chat into their freshly
  // rebuilt hosts (both live outside the signature, like renderActivityFeed).
  renderActivityFeed();
  renderChat();
  if (chatFocused) {
    const inp = document.getElementById("home-sup-input");
    if (inp) { inp.focus(); const n = inp.value.length; try { inp.setSelectionRange(n, n); } catch (e) {} }
  }
}

// Route-entry entrance: exactly one canvas paint per activation carries
// .is-entering (home.css scopes the card `arrive` animation under it), so data
// rebuilds never replay the entrance. The class is dropped on animationend
// (bubbles up from the cards) to keep the steady-state DOM unmarked.
function consumeEntrance(host) {
  if (!HOME.entering) return;
  HOME.entering = false;
  const canvas = host.firstElementChild;
  if (!canvas) return;
  canvas.addEventListener("animationend", () => canvas.classList.remove("is-entering"), { once: true });
}

// U4 — "Previous plans" card (live mode). Hidden when the endpoint is unavailable
// (older server → plansList() null); an empty registry shows a run-hint.
function prevPlansHtml() {
  const list = plansList();
  if (list == null) return "";   // endpoint absent → feature quietly hidden
  const body = list.length
    ? list.map((p) => {
        const g = p.gates || {};
        const gp = g.passed != null ? g.passed : "?";
        const gt = g.total != null ? g.total : "?";
        return `<button class="home-plan-chip" data-plan-switch="${escAttr(p.id)}" title="switch to ${escAttr(p.name || p.id)}">
          <span class="hpc-name">${esc(p.name || p.id)}</span>
          <span class="hpc-meta mono">${esc(fmtDate(p.archivedAt))} · gates ${esc(gp + "/" + gt)} · ${esc((p.taskCount != null ? p.taskCount : 0) + " tasks")}</span>
        </button>`;
      }).join("")
    : `<div class="home-empty">No archived plans yet — run <code>singular plan archive</code> when a DAG completes.</div>`;
  return `<section class="home-block home-prevplans">
    <div class="home-block-head"><span class="home-eyebrow">previous plans</span></div>
    <div class="hb-body"><div class="home-plan-list">${body}</div></div>
  </section>`;
}

// Archived Home variant: a hero card for the archived plan (from the /api/plans
// registry entry), per-stage gate bars (from the archived dag), and quick links
// into the Plan lenses + Consoles. No /api/home, no live tiles/attention/activity.
function renderHistorical(host) {
  const e = activePlanEntry();
  const dag = getDag();
  const stagesSig = dag ? (dag.stages || []).map((s) => `${s.id}:${s.passed}/${s.total}`).join("|") : "-";
  const sig = "hist::" + (e ? e.id + ":" + JSON.stringify(e.gates || {}) : "-") + "::" + stagesSig;
  if (sig === HOME.sig) return;
  HOME.sig = sig;
  host.innerHTML = `<div class="home-canvas${HOME.entering ? " is-entering" : ""}">
    ${histHeroHtml(e)}
    ${histGatesHtml(e)}
    ${histLinksHtml()}
  </div>`;
  consumeEntrance(host);
}

function histHeroHtml(e) {
  if (!e) return `<section class="home-hero"><div class="home-hero-head"><span class="home-headline">loading archived plan…</span></div></section>`;
  const g = e.gates || {};
  const gp = g.passed != null ? g.passed : "?";
  const gt = g.total != null ? g.total : "?";
  const meta = (label, value) => `<div class="home-hist-meta"><span class="hhm-k">${esc(label)}</span><span class="hhm-v mono">${esc(value)}</span></div>`;
  return `<section class="home-hero home-hist-hero">
    <div class="home-hero-head">
      <span class="home-health status-chip" data-tone="idle"><span class="tone-dot" data-tone="idle"></span><span>archived</span></span>
      <span class="home-headline">${esc(e.name || e.id)}</span>
      <span class="home-hero-age mono">${esc(fmtDate(e.archivedAt))}</span>
    </div>
    <div class="home-hist-metarow">
      ${meta("gates", gp + "/" + gt)}
      ${meta("tasks", e.taskCount != null ? e.taskCount : 0)}
      ${meta("head", e.headSha ? String(e.headSha).slice(0, 12) : "—")}
      ${meta("branch", e.branch || "—")}
    </div>
  </section>`;
}

function histGatesHtml(e) {
  const g = (e && e.gates) || {};
  const dag = getDag();
  const stages = dag ? (dag.stages || []) : [];
  const bars = stages.map((s) => {
    const pct = s.total ? Math.round(100 * s.passed / s.total) : 0;
    const done = s.total && s.passed === s.total;
    const shortStage = String(s.id || "").split("-")[0];
    return `<button class="home-stage-bar" data-stage="${escAttr(s.id)}" title="${escAttr(s.id + " · " + s.passed + "/" + s.total)}">
      <span class="hsb-label mono">${esc(shortStage)}</span>
      <span class="hsb-track"><span class="hsb-fill${done ? " is-done" : ""}" style="width:${pct}%"></span></span>
      <span class="hsb-count mono">${s.passed}/${s.total}</span>
    </button>`;
  }).join("") || `<div class="home-empty">gate detail is loading…</div>`;
  return `<section class="home-block home-gates">
    <div class="home-block-head"><span class="home-eyebrow">gates</span>
      <span class="home-gates-val mono">${g.passed != null ? g.passed : "?"}/${g.total != null ? g.total : "?"}</span></div>
    <div class="hb-body"><div class="home-stage-bars">${bars}</div></div>
  </section>`;
}

function histLinksHtml() {
  const link = (hash, label) => `<button class="home-link-chip" data-hist-link="${escAttr(hash)}"><span class="tone-dot" data-tone="idle"></span>${esc(label)}</button>`;
  return `<section class="home-block home-links home-hist-links">
    <div class="hb-body home-links-body">
      <div class="home-links-col">
        <div class="home-eyebrow">browse this plan</div>
        <div class="home-link-row">
          ${link("#plan/timeline", "Timeline")}
          ${link("#plan/dag", "DAG")}
          ${link("#plan/matrix", "Matrix")}
          ${link("#plan/tasks", "Tasks")}
          ${link("#consoles", "Consoles")}
        </div>
      </div>
    </div>
  </section>`;
}

// 1. Hero — health chip + headline count summary + attention list.
function heroHtml(d) {
  const tone = HEALTH_TONE[d.health] || "warn";
  const label = HEALTH_LABEL[d.health] || d.health || "—";
  const tc = d.taskCounts || {};
  const headline = `${tc.integrated || 0} integrated · ${tc.active || 0} active · ${tc.ready || 0} ready`;
  const att = (d.attention || []);
  const attList = att.length
    ? att.map((a) => {
        const sev = a.severity === "blocker" ? "error" : "warn";
        const raw = a.link ? rawBtnFromLink(a.link) : "";
        return `<div class="home-att-row" data-sev="${esc(a.severity)}">
          <span class="tone-dot" data-tone="${sev}"></span>
          <span class="home-att-text">${esc(a.text)}</span>${raw}</div>`;
      }).join("")
    // The walk-away moment: nothing is in the operator's action queue.
    : `<div class="home-clear">
         <span class="home-clear-tile">${icon("i-check")}</span>
         <span class="home-clear-title">All clear</span>
         <p class="home-clear-sub">Nothing needs you — no blocked or failed work in the queue.</p>
       </div>`;
  return `<section class="home-hero">
    <div class="home-hero-head">
      <span class="home-health status-chip" data-tone="${tone}"><span class="tone-dot" data-tone="${tone}"></span><span>${esc(label)}</span></span>
      <span class="home-headline">${esc(headline)}</span>
      <span class="home-hero-age mono">${d.lastActivityAt ? relTime(d.lastActivityAt) + " ago" : "—"}</span>
    </div>
    <div class="home-attention">${attList}</div>
  </section>`;
}

// A quiet {} raw-view button wired to an /api/raw/<root>/<name> link (E-style).
function rawBtnFromLink(link) {
  const m = /\/api\/raw\/([^/]+)\/(.+)$/.exec(link || "");
  if (!m) return "";
  return `<button class="home-raw-btn" data-raw-root="${escAttr(m[1])}" data-raw-name="${escAttr(m[2])}" title="view source">{ }</button>`;
}

// 1b. Supervisor — a deterministic stage line + the latest LLM briefing (when
// one exists) + the interactive propose-only chat. The card itself is inside the
// signature (briefing.generatedAt / loop / supervisor.enabled drive it); the chat
// thread + input are painted by renderChat() into the stable hosts below.
function supervisorHtml(d) {
  if (d.supervisor == null) return "";   // pre-0.10 server → feature absent
  const sup = d.supervisor || {};
  const brief = d.briefing || null;
  const loop = d.loop || {};

  // Stage: the briefing's own line, else a deterministic fallback from home data.
  let stage;
  if (brief && brief.stage) stage = brief.stage;
  else {
    const fr = (d.frontier && d.frontier.nodes) || [];
    const it = loop.iteration;
    stage = fr.length ? `working ${fr[0]}${it != null ? " · iteration " + it : ""}`
      : (it != null ? "iteration " + it : "idle");
  }
  const loopNote = loop.note
    ? `<div class="home-sup-note">${esc(loop.note)}${loop.updatedAt ? ` <span class="mono home-sup-ago">· ${esc(relTime(loop.updatedAt))} ago</span>` : ""}</div>`
    : "";

  let body;
  if (brief) {
    const narr = esc(brief.narrative || "").trim().replace(/\n/g, "<br>");
    const risks = (brief.risks || []).slice(0, 8).map((r) => `<span class="home-sup-chip">${esc(r)}</span>`).join("");
    const steps = (brief.nextSteps || []).slice(0, 8).map((s) => `<li>${esc(s)}</li>`).join("");
    body = `<div class="home-sup-brief">
      ${narr ? `<p class="home-sup-narr">${narr}</p>` : ""}
      ${risks ? `<div class="home-sup-sub"><span class="home-sup-k">risks</span><div class="home-sup-chips">${risks}</div></div>` : ""}
      ${steps ? `<div class="home-sup-sub"><span class="home-sup-k">next</span><ul class="home-sup-steps">${steps}</ul></div>` : ""}
      <div class="home-sup-briefed mono">briefed ${esc(relTime(brief.generatedAt))} ago</div>
    </div>`;
  } else if (!sup.enabled) {
    body = `<div class="home-sup-off">
      <span class="home-sup-offtext">periodic briefings are off</span>
      <button class="secondary-button compact home-sup-enable" data-sup-enable title="set SINGULAR_SUPERVISOR_INTERVAL_MIN=15">enable auto-briefing</button>
    </div>`;
  } else {
    body = `<div class="home-sup-off"><span class="home-sup-offtext">no briefing yet — refresh to generate one</span></div>`;
  }

  return `<section class="home-block home-sup">
    <div class="home-block-head">
      <span class="home-eyebrow">supervisor</span>
      <span class="home-sup-stage">${esc(stage)}</span>
      <button class="secondary-button compact home-sup-refresh" data-sup-refresh title="request a fresh briefing">${icon("i-refresh")}refresh briefing</button>
    </div>
    <div class="hb-body">
      ${loopNote}
      ${body}
      <div class="home-sup-chatwrap">
        <div class="hchat-thread" id="home-sup-chat" role="log" aria-live="polite" aria-label="Supervisor chat"></div>
        <div class="hchat-composer">
          <textarea id="home-sup-input" class="hchat-input" rows="1" placeholder="ask the supervisor…" autocomplete="off" spellcheck="false">${esc(CHAT.draft)}</textarea>
          <div class="hchat-composer-rail">
            <button class="hchat-send" data-sup-send aria-label="Send">${icon("i-arrowdown")}</button>
          </div>
        </div>
      </div>
    </div>
  </section>`;
}

// 1c. Provider subscription quotas — an honest mix: a real Codex usage gauge
// (only Codex exposes headless usage), tier chips for authed CLIs that don't.
// Between tiles and links; quiet-hides when nothing qualifies or providers 404.
function quotaHtml() {
  const prov = HOME.prov;
  if (!prov || !prov.providers) return "";
  const rows = [];
  for (const p of prov.providers) {
    const q = p.quota;
    if (!q) continue;
    if (q.available) { rows.push(quotaGaugeRow(p, q)); continue; }
    if ((q.reason === "tier-only" || q.reason === "not-exposed") && p.authStatus === "authenticated") {
      rows.push(quotaTierRow(p));
    }
  }
  if (!rows.length) return "";
  return `<section class="home-block home-quota">
    <div class="home-block-head"><span class="home-eyebrow">provider quotas</span></div>
    <div class="hb-body"><div class="hq-list">${rows.join("")}</div></div>
  </section>`;
}

function quotaGaugeRow(p, q) {
  const pct = Math.max(0, Math.round(q.usedPercent || 0));
  const tone = pct >= 90 ? "error" : pct >= 75 ? "warn" : "";
  const meta = [windowLabel(q.windowMinutes), resetsIn(q.resetsAt), q.planType]
    .filter(Boolean).map((m) => `<span>${esc(m)}</span>`).join(`<span class="hq-dot">·</span>`);
  const stale = (q.staleSeconds || 0) > 7200 ? `stale ${Math.round(q.staleSeconds / 3600)}h` : "";
  const sec = (q.secondary && q.secondary.usedPercent != null)
    ? `<span class="hq-track hq-track-sec" title="secondary window ${escAttr(Math.round(q.secondary.usedPercent) + "%")}"><span class="hq-fill" style="width:${Math.max(0, Math.round(q.secondary.usedPercent))}%"></span></span>` : "";
  return `<div class="hq-item" data-tone="${tone}">
    <span class="hq-name">${esc(p.name || p.id)}</span>
    <span class="hq-tracks"><span class="hq-track"><span class="hq-fill" style="width:${pct}%"></span></span>${sec}</span>
    <span class="hq-pct mono">${pct}%</span>
    <span class="hq-meta">${meta}${stale ? `<span class="hq-dot">·</span><span class="hq-stale">${esc(stale)}</span>` : ""}</span>
  </div>`;
}

function quotaTierRow(p) {
  const tier = p.plan ? `<span class="hq-tierval">${esc(p.plan)}</span><span class="hq-dot">·</span>` : "";
  return `<div class="hq-item hq-tier">
    <span class="hq-name">${esc(p.name || p.id)}</span>
    ${tier}<span class="hq-tiernote">quota not exposed by CLI</span>
  </div>`;
}

// window-minutes → a human label (10080 = the 7-day plan window).
function windowLabel(m) {
  if (m == null) return "";
  if (m === 10080) return "7-day";
  if (m % 1440 === 0) return (m / 1440) + "-day";
  if (m % 60 === 0) return (m / 60) + "h";
  return m + "m";
}

// A client-computed "resets in …" from the epoch-seconds resetsAt (clamps a past
// time to "resetting…"). Coarse (days/hours/minutes) — refreshed on each poll.
function resetsIn(epochSec) {
  if (!epochSec) return "";
  const ms = epochSec * 1000 - Date.now();
  if (ms <= 0) return "resetting…";
  const totalMin = Math.round(ms / 60000);
  const days = Math.floor(totalMin / 1440);
  const hrs = Math.floor((totalMin % 1440) / 60);
  const mins = totalMin % 60;
  if (days > 0) return `resets in ${days}d ${hrs}h`;
  if (hrs > 0) return `resets in ${hrs}h ${mins}m`;
  return `resets in ${mins}m`;
}

// 2. Gates block — gates X/Y headline + per-stage bars (from the shared dag).
// When the server splits the cohorts the headline is the CURRENT
// campaign and the historical accepted-as-done set drops to a subline, so the
// landing page can never present grandfathered evidence as this run's delivery.
// Older server (no cohorts) → the combined headline, unchanged.
function gatesHtml(d) {
  const g = d.gates || {};
  const cur = g.cohorts && g.cohorts.current;
  const hist = (g.cohorts && g.cohorts.historical) || {};
  const dag = getDag();
  const stages = dag ? (dag.stages || []) : [];
  const bars = stages.map((s) => {
    const pct = s.total ? Math.round(100 * s.passed / s.total) : 0;
    const done = s.total && s.passed === s.total;
    const shortStage = String(s.id || "").split("-")[0];
    return `<button class="home-stage-bar" data-stage="${escAttr(s.id)}" title="${escAttr(s.id + " · " + s.passed + "/" + s.total)}">
      <span class="hsb-label mono">${esc(shortStage)}</span>
      <span class="hsb-track"><span class="hsb-fill${done ? " is-done" : ""}" style="width:${pct}%"></span></span>
      <span class="hsb-count mono">${s.passed}/${s.total}</span>
    </button>`;
  }).join("") || `<div class="home-empty">no stages</div>`;
  const combined = `${g.passed != null ? g.passed : "?"}/${g.total != null ? g.total : "?"}`;
  const headline = cur
    ? `${cur.passed != null ? cur.passed : "?"}/${cur.total != null ? cur.total : "?"}`
    : combined;
  const nums = cur
    ? `<span class="home-gates-nums"><span class="home-gates-val mono">${headline}</span>
        <span class="home-gates-sub mono">historical ${hist.passed || 0}/${hist.total || 0} · all-time ${combined}</span></span>`
    : `<span class="home-gates-val mono">${headline}</span>`;
  return `<section class="home-block home-gates">
    <div class="home-block-head"><span class="home-eyebrow">gates${cur ? " · current campaign" : ""}</span>
      ${nums}</div>
    <div class="hb-body"><div class="home-stage-bars">${bars}</div></div>
  </section>`;
}

// 3. Activity — relocated live feed (left) + 14-day sparkline (right), one card.
function activityHtml(d) {
  return `<section class="home-block home-activity">
    <div class="home-block-head">
      <span class="home-eyebrow">activity</span>
      <span class="home-activity-pulse" id="home-activity-pulse" data-state="idle"><span class="tone-dot" data-tone="idle"></span><span id="home-activity-pulse-text">—</span></span>
      <span class="home-activity-rate mono" id="home-activity-rate"></span>
    </div>
    <div class="hb-body home-activity-body">
      <div class="home-activity-events">
        <div class="home-feed ov-feed" id="home-activity-feed" role="log" aria-live="polite" aria-label="Live orchestration events"></div>
      </div>
      <div class="home-activity-chart">
        <div class="home-eyebrow">last 14 days</div>
        ${sparklineHtml(d.activityByDay || [])}
      </div>
    </div>
  </section>`;
}

// 4. Dependency-free stacked-bar sparkline over activityByDay (A4).
function sparklineHtml(days) {
  const max = Math.max(1, ...days.map((x) => (x.dispatches || 0) + (x.integrations || 0) + (x.failures || 0)));
  const cols = days.map((x) => {
    const di = x.dispatches || 0, ig = x.integrations || 0, fa = x.failures || 0;
    const total = di + ig + fa;
    const dt = new Date((x.date || "") + "T00:00:00Z");
    const lbl = isNaN(dt) ? (x.date || "") : `${MON[dt.getUTCMonth()]} ${dt.getUTCDate()}`;
    const seg = (n, cls) => n > 0 ? `<span class="hspark-seg ${cls}" style="height:${(n / max * 100).toFixed(1)}%"></span>` : "";
    return `<span class="hspark-col" title="${escAttr(lbl + " · " + di + " dispatch · " + ig + " integ · " + fa + " fail")}">
      <span class="hspark-stack">${total ? seg(fa, "s-fail") + seg(ig, "s-integ") + seg(di, "s-disp") : `<span class="hspark-seg s-zero"></span>`}</span>
    </span>`;
  }).join("");
  return `<div class="home-spark">${cols}</div>
    <div class="home-spark-caption"><span>14d ago</span><span>today</span></div>
    <div class="home-spark-legend">
      <span><span class="hspark-key s-disp"></span>dispatch</span>
      <span><span class="hspark-key s-integ"></span>integrated</span>
      <span><span class="hspark-key s-fail"></span>failure</span>
    </div>`;
}

// 5. Throughput / limits tiles. Task counts deep-link into Plan filters; drift +
// disk come from the shared state snapshot (not in the home payload).
function tilesHtml(d) {
  const tc = d.taskCounts || {};
  const dp = d.dispatch || {};
  const drift = (S.snap && S.snap.git && S.snap.git.drift) || null;
  const disk = (S.snap && S.snap.disk) || null;
  const tile = (label, value, opts) => {
    const o = opts || {};
    const attr = o.filter ? ` data-plan-filter="${escAttr(o.filter)}" role="button" tabindex="0"` : "";
    const tone = o.tone ? ` data-tone="${o.tone}"` : "";
    return `<div class="home-tile${o.filter ? " is-link" : ""}"${attr}${tone}>
      <span class="home-tile-num mono">${esc(value)}</span>
      <span class="home-tile-label">${esc(label)}</span></div>`;
  };
  return `<section class="home-block home-tiles">
    <div class="home-block-head"><span class="home-eyebrow">throughput &amp; limits</span></div>
    <div class="hb-body"><div class="home-tile-row">
      ${tile("dispatched", `${dp.launched != null ? dp.launched : 0}`)}
      ${tile("pid alive", `${dp.pidAlive != null ? dp.pidAlive : 0}`)}
      ${tile("active", `${tc.active || 0}`, { filter: "active", tone: (tc.active || 0) > 0 ? "active" : "" })}
      ${tile("ready", `${tc.ready || 0}`)}
      ${tile("blocked", `${tc.blocked || 0}`, { filter: "blocked", tone: (tc.blocked || 0) > 0 ? "error" : "" })}
      ${tile("failed", `${tc.failed || 0}`, { filter: "failed", tone: (tc.failed || 0) > 0 ? "error" : "" })}
      ${tile("drift", drift ? `${drift.left} · ${drift.right}` : "—")}
      ${tile("disk", disk && disk.capacityPercent != null ? disk.capacityPercent + "%" : "—", { tone: disk && disk.watch ? "warn" : "" })}
    </div></div>
  </section>`;
}

// 6. Quick links — frontier nodes → Plan/dag; live sessions → Consoles.
function linksHtml(d) {
  const fr = (d.frontier && d.frontier.nodes) || [];
  const sessions = (feedState().sessions || []).filter((s) => s.live && s.id !== "origin").slice(0, 6);
  const frChips = fr.slice(0, 8).map((n) =>
    `<button class="home-link-chip" data-node-link="${escAttr(n)}"><span class="tone-dot" data-tone="integration"></span>${esc(n)}</button>`).join("")
    || `<span class="home-empty">no frontier nodes — plan gated complete</span>`;
  // Drive the dot from the session's own state rather than hard-coding green:
  // the list is filtered to live sessions, so this is usually the same colour,
  // but expressing the invariant means it stays honest if the filter changes.
  const sessChips = sessions.map((s) =>
    `<button class="home-link-chip" data-session-link="${escAttr(s.id)}"><span class="tone-dot" data-tone="${escAttr(toneOf(s.state))}"></span>${esc(s.taskId || s.node || s.id)}</button>`).join("")
    || `<span class="home-empty">no live sessions</span>`;
  return `<section class="home-block home-links">
    <div class="hb-body home-links-body">
      <div class="home-links-col">
        <div class="home-eyebrow">frontier nodes</div>
        <div class="home-link-row">${frChips}</div>
      </div>
      <div class="home-links-col">
        <div class="home-eyebrow">live sessions</div>
        <div class="home-link-row">${sessChips}</div>
      </div>
    </div>
  </section>`;
}

// ------------------------------------------------------------- supervisor chat
// Seed the thread from /api/asks (newest-20, oldest-first) once per session. The
// list entries already carry an answer head, so no per-item lazy fetch is needed
// for display; a still-running newest ask resumes polling.
async function seedChat() {
  if (CHAT.seeded || isHistorical()) return;
  CHAT.seeded = true;
  try {
    const res = await apiFetch("/api/asks", { cache: "no-store" });
    if (!res.ok) return;
    const data = await res.json();
    CHAT.items = (data.asks || []).slice().reverse().map((a) => ({
      runId: a.runId, question: a.question, state: a.state,
      answer: a.answer, proposedSettings: a.proposedSettings || {}, applied: {},
      createdAt: a.createdAt, answeredAt: a.answeredAt,
      painted: true,   // history, not a new send — never entrance-animate it
    }));
    renderChat();
    const last = CHAT.items[CHAT.items.length - 1];
    if (last && (last.state === "pending" || last.state === "running")) startPoll(last.runId);
  } catch (e) { /* chat is best-effort; a miss just leaves an empty thread */ }
}

// Repaint the thread into the stable #home-sup-chat host (no home-canvas rebuild).
// Called from render() after a rebuild, and directly by the poll/send/seed paths.
function renderChat() {
  const host = document.getElementById("home-sup-chat");
  if (!host) return;
  if (!CHAT.items.length) {
    host.innerHTML = `<div class="hchat-empty">Ask about the run — the supervisor reads the live status and can propose settings you apply with one click.</div>`;
    return;
  }
  const atBottom = host.scrollHeight - host.scrollTop - host.clientHeight < 48;
  host.innerHTML = CHAT.items.map(chatBubble).join("");
  // Only an item's FIRST paint carries the arrive class (chatBubble) — repaints
  // (pending→done flips, canvas rebuilds) must not re-animate the thread.
  for (const it of CHAT.items) it.painted = true;
  if (atBottom) host.scrollTop = host.scrollHeight;
}

// The engine leaves the machine-readable proposedSettings fence in answer.md; we
// surface those as Apply chips, so strip a trailing ```json {…proposedSettings…}```
// block from the prose bubble (leaves any other prose/code the answer contains).
function cleanAnswer(ans) {
  const s = String(ans || "");
  const m = s.match(/```(?:json)?\s*[\s\S]*?```\s*$/i);
  if (m && /proposedSettings/.test(m[0])) return s.slice(0, m.index).trim();
  return s.trim();
}

// AI-thread archetype: the user instruction is a compact dark block, the
// supervisor's answer is open prose beside a small product glyph, with a quiet
// provenance row (when answered · run id) — never enclosed in a chat bubble.
function chatBubble(it) {
  const q = `<div class="hchat-user${it.painted ? "" : " is-new"}">${esc(it.question || "")}</div>`;
  let main;
  if (it.state === "pending" || it.state === "running") {
    main = `<div class="hchat-thinking"><span class="pulse-dot"></span>Thinking…</div>`;
  } else if (it.state === "error" || it.state === "timeout") {
    const msg = it.state === "timeout" ? "the supervisor ran out of time" : "the supervisor could not answer";
    main = `<p class="hchat-prose hchat-err">${esc(msg)}</p>`;
  } else {
    const ans = cleanAnswer(it.answer);
    const body = ans ? esc(ans).replace(/\n/g, "<br>") : "(no answer)";
    const keys = Object.keys(it.proposedSettings || {});
    const chips = keys.map((k) => {
      const v = it.proposedSettings[k];
      const done = it.applied && it.applied[k];
      return `<button class="hchat-apply" data-apply-key="${escAttr(k)}" data-apply-value="${escAttr(v)}" data-apply-run="${escAttr(it.runId)}"${done ? " disabled data-applied=\"true\"" : ""}>${done ? "applied" : "apply"} <code>${esc(shortKey(k))} → ${esc(v)}</code></button>`;
    }).join("");
    main = `<p class="hchat-prose">${body}</p>${chips ? `<div class="hchat-applies">${chips}</div>` : ""}${chatMetaHtml(it)}`;
  }
  return `<div class="hchat-turn">${q}
    <div class="hchat-agent">
      <span class="hchat-glyph">${icon("i-grid")}</span>
      <div class="hchat-agent-main">${main}</div>
    </div></div>`;
}

// The quiet provenance row under a supervisor answer: honest fields only —
// when it was answered, and the ask run id (no fabricated model / links).
function chatMetaHtml(it) {
  const bits = [];
  const when = it.answeredAt || it.createdAt;
  if (when) bits.push(`briefed ${esc(relTime(when))} ago`);
  if (it.runId && !/^pending-/.test(it.runId)) bits.push(`<span class="hchat-run">${esc(it.runId)}</span>`);
  if (!bits.length) return "";
  return `<div class="hchat-meta">${bits.join('<span aria-hidden="true">·</span>')}</div>`;
}

// Send the current draft: optimistic pending bubble → POST /api/ask → poll to a
// terminal state. A 429 (an ask already running) restores the draft to retry.
function sendAsk() {
  const inp = document.getElementById("home-sup-input");
  const q = (inp ? inp.value : CHAT.draft).trim();
  if (!q) return;
  if (CHAT.polling) { toast("wait for the current answer"); return; }
  const temp = { runId: "pending-" + Date.now(), question: q, state: "pending", answer: null, proposedSettings: {}, applied: {} };
  CHAT.items.push(temp);
  CHAT.draft = ""; if (inp) inp.value = "";
  renderChat();
  fetch("/api/ask", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ question: q }) })
    .then(async (res) => {
      const data = await res.json().catch(() => ({}));
      if (res.status === 429) {
        toast((data.error ? String(data.error) : "an ask is already running") + " — try again in a moment");
        CHAT.items = CHAT.items.filter((x) => x !== temp);
        CHAT.draft = q; if (inp) inp.value = q;
        renderChat();
        return;
      }
      if (!res.ok || !data.runId) { toast(data.error ? String(data.error) : "could not send"); temp.state = "error"; renderChat(); return; }
      temp.runId = data.runId; temp.state = "running";
      renderChat();
      startPoll(data.runId);
    })
    .catch(() => { toast("could not send"); temp.state = "error"; renderChat(); });
}

function startPoll(runId) {
  stopPoll();
  CHAT.polling = true;
  CHAT.pollStart = Date.now();
  CHAT.timer = setInterval(() => pollAsk(runId), CHAT_POLL_MS);
}
function stopPoll() {
  if (CHAT.timer) { clearInterval(CHAT.timer); CHAT.timer = null; }
  CHAT.polling = false;
}
async function pollAsk(runId) {
  if (Date.now() - CHAT.pollStart > CHAT_POLL_CAP_MS) {
    stopPoll();
    const it = CHAT.items.find((x) => x.runId === runId);
    if (it && (it.state === "pending" || it.state === "running")) { it.state = "timeout"; renderChat(); }
    return;
  }
  try {
    const res = await apiFetch("/api/ask/" + encodeURIComponent(runId), { cache: "no-store" });
    if (!res.ok) return;   // a 404 right after mint is transient — keep polling
    const d = await res.json();
    const it = CHAT.items.find((x) => x.runId === runId);
    if (!it) { stopPoll(); return; }
    it.state = d.state; it.answer = d.answer; it.proposedSettings = d.proposedSettings || {};
    it.answeredAt = d.answeredAt || it.answeredAt; it.createdAt = it.createdAt || d.createdAt;
    renderChat();
    if (d.state === "done" || d.state === "error" || d.state === "timeout") stopPoll();
  } catch (e) { /* transient — keep polling until the cap */ }
}

// Apply one proposed settings change — the human click is the only write path
// (the model never applies anything). Success flips the chip to "applied".
function applySetting(btn) {
  const key = btn.dataset.applyKey;
  const val = btn.dataset.applyValue;
  const runId = btn.dataset.applyRun;
  if (btn.dataset.applied === "true") return;
  btn.disabled = true;
  fetch("/api/settings", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ changes: { [key]: val } }) })
    .then(async (res) => {
      const data = await res.json().catch(() => ({}));
      if (res.status === 404 || res.status === 405 || res.status === 501) { toast("settings are read-only on this server"); btn.disabled = false; return; }
      if (!res.ok) { toast(data.error ? String(data.error) : "apply failed · " + res.status); btn.disabled = false; return; }
      const at = (data.appliesAt || {})[key] || "applied";
      toast(`${shortKey(key)} → ${at}`);
      const it = CHAT.items.find((x) => x.runId === runId);
      if (it) { it.applied = it.applied || {}; it.applied[key] = true; }
      renderChat();
    })
    .catch(() => { toast("apply failed"); btn.disabled = false; });
}

// Request a one-shot briefing (POST /api/report; throttled server-side to 60s).
function requestBriefing(btn) {
  if (btn) btn.disabled = true;
  fetch("/api/report", { method: "POST" })
    .then(async (res) => {
      const data = await res.json().catch(() => ({}));
      if (res.status === 429) toast(data.error ? String(data.error) : "a briefing just ran — try again soon");
      else if (!res.ok) toast(data.error ? String(data.error) : "could not request briefing");
      else toast("briefing requested — lands within a minute");
    })
    .catch(() => toast("could not request briefing"))
    .finally(() => { if (btn) setTimeout(() => { btn.disabled = false; }, 1500); });
}

// Turn on periodic auto-briefings (writes SINGULAR_SUPERVISOR_INTERVAL_MIN=15).
// Follows the same shape as postSettings in agents/providers: adopt whatever the
// server echoes back, and build the toast from appliesAt instead of asserting an
// effect. That last part matters here — autonomate.sh sources lib.sh once at
// startup and reads this knob from its own env inside the loop, so the change
// lands on loop restart, not next cycle.
const BRIEFING_INTERVAL_MIN = 15;

function enableBriefings(btn) {
  if (btn) btn.disabled = true;
  const reenable = () => { if (btn) btn.disabled = false; };
  fetch("/api/settings", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ changes: { SINGULAR_SUPERVISOR_INTERVAL_MIN: String(BRIEFING_INTERVAL_MIN) } }),
  })
    .then(async (res) => {
      const data = await res.json().catch(() => ({}));
      if (res.status === 404 || res.status === 405 || res.status === 501) {
        toast("settings are read-only on this server"); reenable(); return;
      }
      if (!res.ok) { toast(data.error ? String(data.error) : "could not enable"); reenable(); return; }
      const at = (data.appliesAt || {}).SINGULAR_SUPERVISOR_INTERVAL_MIN || "applied";
      toast(`auto-briefing every ${BRIEFING_INTERVAL_MIN} min → ${at}`);
      if (data.settings) HOME.settings = data.settings;
      if (data.config) HOME.config = data.config;
      // supervisor.enabled folds into supSig, so the mutation repaints through
      // the signature gate — no reset needed.
      if (HOME.data && HOME.data.supervisor) {
        HOME.data.supervisor.enabled = true;
        HOME.data.supervisor.intervalMin = BRIEFING_INTERVAL_MIN;
        render();
      }
      // Re-enable on success too: the button used to stay dead forever, so a
      // later change of mind needed a page reload.
      reenable();
    })
    .catch(() => { toast("could not enable"); reenable(); });
}

// ------------------------------------------------------------- nav ------------
// Deep-link a Home task-count tile into the Plan tasks lens with a status filter
// pre-applied (the Plan filter select owns the actual filtering).
function navToPlanFilter(status) {
  location.hash = "#plan/tasks";
  setTimeout(() => {
    const sel = document.getElementById("filter-status");
    if (sel) { sel.value = status; sel.dispatchEvent(new Event("change", { bubbles: true })); }
  }, 60);
}

function mount() {
  const surf = document.getElementById("surface-home");
  if (!surf) return;
  surf.addEventListener("click", (e) => {
    // Attention {} raw buttons carry [data-raw-root]; the app.js document handler
    // (viewRaw) opens them in the inspector file-view — no local wiring needed.
    const stage = e.target.closest("[data-stage]");
    if (stage) { location.hash = "#plan/matrix"; return; }
    const tile = e.target.closest("[data-plan-filter]");
    if (tile) { navToPlanFilter(tile.dataset.planFilter); return; }
    const node = e.target.closest("[data-node-link]");
    if (node) { location.hash = "#plan/dag/NODE:" + node.dataset.nodeLink; return; }
    const sess = e.target.closest("[data-session-link]");
    if (sess) { location.hash = "#consoles/" + sess.dataset.sessionLink; return; }
    const histLink = e.target.closest("[data-hist-link]");
    if (histLink) { location.hash = histLink.dataset.histLink; return; }
    const planSwitch = e.target.closest("[data-plan-switch]");
    if (planSwitch) { switchPlan(planSwitch.dataset.planSwitch); return; }
    // Supervisor card + chat actions (all propose-only; the human click writes).
    if (e.target.closest("[data-sup-send]")) { sendAsk(); return; }
    const refresh = e.target.closest("[data-sup-refresh]");
    if (refresh) { requestBriefing(refresh); return; }
    const enable = e.target.closest("[data-sup-enable]");
    if (enable) { enableBriefings(enable); return; }
    const apply = e.target.closest("[data-apply-key]");
    if (apply) { applySetting(apply); return; }
  });
  // Keep the chat draft current so a signature rebuild can restore it verbatim.
  surf.addEventListener("input", (e) => {
    if (e.target && e.target.id === "home-sup-input") CHAT.draft = e.target.value;
  });
  surf.addEventListener("keydown", (e) => {
    // Enter (without Shift) sends the chat; Shift+Enter keeps a newline.
    const chatInput = e.target.closest && e.target.closest("#home-sup-input");
    if (chatInput && e.key === "Enter" && !e.shiftKey) { e.preventDefault(); sendAsk(); return; }
    if ((e.key === "Enter" || e.key === " ")) {
      const tile = e.target.closest && e.target.closest("[data-plan-filter]");
      if (tile) { e.preventDefault(); navToPlanFilter(tile.dataset.planFilter); }
    }
  });
}

// ------------------------------------------------------------- exports --------
export function initHome() {
  if (HOME.started) return; HOME.started = true;
  mount();
  // Dag stages and live-session chips are FOLDED INTO signature(), so these
  // events just request a render — the sig gate no-ops a quiet poll instead of
  // rebuilding an identical canvas (and replaying the entrance animation).
  HOME.dagUnsub = onDag(() => render());
  subscribeSessions(() => { if (HOME.visible) render(); }, () => HOME.visible);
  // Independent 10s poll — only ticks while Home is visible + the tab is shown.
  // Providers ride every 6th tick (~60s, aligned with the server's quota cache).
  onRecover(() => { if (HOME.visible && !isHistorical()) { fetchHome(); fetchProviders(); } });
  HOME.timer = setInterval(() => {
    if (!HOME.visible || document.hidden) return;
    fetchHome();
    HOME.pollTick = (HOME.pollTick + 1) % 6;
    if (HOME.pollTick === 0) fetchProviders();
  }, POLL_MS);
}

export function setHomeActive(on) {
  HOME.visible = on;
  if (on) {
    // Route entry: the one legitimate signature reset (a fresh paint is due) and
    // the only point that arms the entrance animation.
    HOME.sig = null;
    HOME.entering = true;
    if (!getDag()) fetchDag();
    if (isHistorical()) {
      // Archived Home: registry entry (name/gates/tasks) + archived dag gate bars.
      // The registry entry folds into the historical sig, so resolution repaints
      // through the gate — no signature reset needed.
      fetchPlans().then(() => render());
      render();
    } else {
      fetchHome();
      fetchProviders();   // provider quota (own cadence; folds into signature())
      seedChat();         // seed the supervisor thread once from /api/asks
      render();
    }
  }
}

// Router hook — #home has no sub-route in v2.
export function homeRoute() { setHomeActive(true); }

// Called from the shared 10s snapshot dispatcher (main.js) — signature-gated,
// no-op while hidden. Reflects drift/disk/dag deltas immediately.
export function homeTick() { if (HOME.visible) render(); }
