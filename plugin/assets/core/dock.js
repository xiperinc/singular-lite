/* core/dock.js — the persistent bottom status dock (0.11.0 "Quiet Instrument").

   The ambient system-state layer. It renders honest cells from the app.js store
   ONLY — S.snap (/api/state, the same snapshot renderTop consumes) plus the
   already-polled S.overview (/api/overview, fetched every load() by app.js). It
   adds NO polling of its own: dockTick() is wired into the shared snapshot
   dispatcher in main.js (alongside homeTick/providersTick), so the dock repaints
   on each 10s snapshot. The relocated conn dot (#conn-dot) and updated-age
   (#refresh-age) keep their ids, so app.js's setConn/tickAge keep writing them
   wherever they render — the dock just hosts them now.

   Dependency-light, low in the graph: imports the app.js store (like the surface
   modules) + core/api.js + core/plans.js (for the archived-plan name). No import
   cycle (app.js never imports the dock).

   Cells (left→right): loop · tasks · frontier(only when the server reports
   l1Selection) · gates · attention(needs-you) · breaker(only when tripped) ·
   spacer · repo·branch · conn+age. Every value is snapshot-derived; nothing is
   fabricated — a cell whose payload is absent is hidden rather than zero-filled.
   A codex-quota cell is intentionally OMITTED in Phase 1 (the /api/providers
   quota payload isn't cached off the Home surface yet). */

import { S } from "../app.js";
import { isHistorical, activePlan, switchPlan } from "./api.js";
import { activePlanEntry } from "./plans.js";

const el = (id) => document.getElementById(id);
const setText = (id, t) => { const n = el(id); if (n) n.textContent = t; };
const toggleClass = (id, cls, on) => { const n = el(id); if (n) n.classList.toggle(cls, !!on); };
const basename = (p) => String(p || "").replace(/\/+$/, "").split("/").pop() || "";

// Codex subscription-quota cell (0.11.0). The dock fetches /api/providers on init
// and every 150 snapshot ticks (~5min; the server caches the quota probe for 60s),
// reading ONLY codex's headless-usage percent — the one provider that exposes it.
// Plain GET, never in historical mode. When codex has no usable percent the cell
// is omitted entirely rather than fabricate a value. See renderCells() for paint.
let provTick = 0;
let codexPct = null;   // rounded used-percent, or null when unavailable
async function fetchDockQuota() {
  if (isHistorical()) { codexPct = null; renderCells(); return; }
  try {
    const res = await fetch("/api/providers", { cache: "no-store" });
    if (!res.ok) return;   // keep last-known on a transient miss
    const d = await res.json();
    const codex = (d.providers || []).find((p) => p.id === "codex");
    const q = codex && codex.quota;
    codexPct = (q && q.available && q.usedPercent != null) ? Math.max(0, Math.round(q.usedPercent)) : null;
    renderCells();
  } catch (e) { /* quota is a quiet cell; a miss just keeps the last value */ }
}

// Ready-task count: the /api/state origin-state projection when present (it may be
// a list of ids OR a count, depending on the origin-state version), else the
// /api/overview loop status. Both are already in the store — no new fetch.
function readyCount(snap, ov) {
  const os = (snap.orchestration && snap.orchestration.originState) || {};
  const r = os.readyTasks;
  if (Array.isArray(r)) return r.length;
  if (typeof r === "number") return r;
  if (ov && ov.loop && typeof ov.loop.readyTasks === "number") return ov.loop.readyTasks;
  return null;
}

// Repo basename → the rail brand caption (the dock owns the single
// snapshot→chrome-text write so app.js/renderTop stays untouched). Only writes when
// the live snapshot actually carries a repo path (the historical synthetic snapshot
// does not), so a live→historical switch keeps the last-known repo rather than "—".
function paintRepoChrome(snap) {
  const repo = snap && snap.repo ? basename(snap.repo) : "";
  if (!repo) return;
  setText("brand-repo", repo);
}

function renderCells() {
  const snap = S.snap;
  const ov = S.overview;
  const hist = isHistorical();

  const liveEl = el("dock-live"), histEl = el("dock-hist");
  if (liveEl) liveEl.hidden = hist;
  if (histEl) histEl.hidden = !hist;

  // Right cluster: repo · branch (the sidebar brand repo rides along).
  paintRepoChrome(snap);
  const entry = activePlanEntry();
  const repoBase = snap && snap.repo ? basename(snap.repo) : "";
  const branch = (snap && snap.targetBranch) || (entry && entry.branch) || "";
  setText("dock-repo-text", [repoBase, branch].filter(Boolean).join(" · ") || "—");

  // Historical mode: one muted "viewing archived plan <name>" cell + back-to-live;
  // the right cluster (repo·branch, conn, age) stays as painted above.
  if (hist) {
    const name = (entry && entry.name) || activePlan || "archived plan";
    setText("dock-hist-text", "viewing archived plan " + name);
    return;
  }

  // codex quota — omitted entirely when unavailable; ochre attention ≥75%.
  const qEl = el("dock-quota");
  if (qEl) {
    if (codexPct == null) { qEl.hidden = true; }
    else {
      qEl.hidden = false;
      setText("dock-quota-text", "codex " + codexPct + "%");
      const qd = el("dock-quota-dot");
      if (qd) qd.className = "state-dot" + (codexPct >= 75 ? " needs-you" : "");
      qEl.classList.toggle("attention-cell", codexPct >= 75);
    }
  }

  if (!snap) return;

  const sc = (snap.summary && snap.summary.stateCounts) || {};
  const active = sc.active || 0;
  const blockedFailed = (sc.blocked || 0) + (sc.failed || 0);

  // loop — the daemon pidfile is the honest authority (snap.loop, additive
  // 0.11.0 server field). agents.l0.state counts engine *processes*, which
  // test suites and manual ops inflate — that reads as "engine busy", and only
  // a live autonomate pid earns the blue pulse + "running".
  const l0 = (snap.agents && snap.agents.l0) || {};
  const alive = !!(snap.loop && snap.loop.alive);
  const busy = !alive && l0.state === "active";
  const iter = (ov && ov.pulse && ov.pulse.iteration != null) ? ov.pulse.iteration
    : (ov && ov.loop ? ov.loop.iteration : null);
  const loopDot = el("dock-loop-dot");
  if (loopDot) loopDot.className = alive ? "pulse-dot" : "state-dot";
  setText("dock-loop-text", alive
    ? ("running" + (iter != null ? " · iter " + iter : ""))
    : busy ? "engine busy"
      : (l0.state === "stopped" ? "loop stopped" : "loop idle"));

  // tasks — BOTH numbers from one payload block. They used to come from two
  // sources with two definitions and two vintages, which is how a single task
  // rendered as "1 active · 1 ready". summary.taskCounts is the projection; the
  // old readyCount() fallback chain stays only for a pre-0.14.0 server.
  const tc = (snap.summary && snap.summary.taskCounts) || null;
  const tasksActive = tc ? (tc.active || 0) : active;
  const ready = tc ? tc.ready : readyCount(snap, ov);
  setText("dock-tasks-text", tasksActive + " active · " + (ready != null ? ready : "—") + " ready");

  // gates — the CURRENT campaign's passed/total when the server splits the
  // cohorts; historical accepted-as-done evidence and the combined
  // figure ride in the tooltip instead of being blended into one number. Older
  // server (no cohorts) → the combined "gates P/T" exactly as before. Ochre when
  // blocked/failed tasks stall gate progress.
  const g = (snap.orchestration && snap.orchestration.gates) || {};
  const gCur = g.cohorts && g.cohorts.current;
  const gHist = (g.cohorts && g.cohorts.historical) || {};
  const gCombined = (g.passed != null ? g.passed : "?") + "/" + (g.total != null ? g.total : "?");
  const gatesEl = el("dock-gates");
  if (gCur) {
    setText("dock-gates-text", "campaign " + (gCur.passed != null ? gCur.passed : "?")
      + "/" + (gCur.total != null ? gCur.total : "?"));
    if (gatesEl) {
      gatesEl.title = "Gate progress — current campaign · historical accepted "
        + (gHist.passed || 0) + "/" + (gHist.total || 0) + " · combined " + gCombined;
    }
  } else {
    setText("dock-gates-text", "gates " + gCombined);
    if (gatesEl) gatesEl.title = "Gate progress";
  }
  toggleClass("dock-gates", "attention-cell", blockedFailed > 0);

  // frontier — ready-by-dependency vs runnable-now and the concurrency
  // cap, with the named per-node reason for the gap in the tooltip. Same-area
  // serialization and scope-overlap holds are a SAFETY policy, and without this
  // cell a deliberately narrowed wave looks like a broken parallel engine. The
  // whole cell is hidden when /api/overview carries no l1Selection (older
  // server): an omitted cell is honest, a fabricated "ready 0 · runnable 0" is not.
  const sel = ov && ov.l1Selection;
  const frEl = el("dock-frontier");
  if (frEl) {
    if (!sel) {
      frEl.hidden = true;
    } else {
      frEl.hidden = false;
      const num = (v) => (v != null ? v : "—");
      setText("dock-frontier-text", "ready " + num(sel.readyByDependency)
        + " · runnable " + num(sel.runnableNow) + " · cap " + num(sel.cap));
      const held = (sel.serialized || []).map((s) =>
        (s.node || "?") + " — " + (s.detail || s.rule || "held back"));
      frEl.title = held.length
        ? "held back this cycle:\n" + held.join("\n")
        : "every dependency-ready node is runnable now";
    }
  }

  // attention — the operator's action queue: blocked + failed tasks (the loop
  // cannot self-heal past retries). Ochre + amber dot when > 0, quiet at 0.
  const needs = blockedFailed;
  const attDot = el("dock-attention-dot");
  if (attDot) attDot.className = needs > 0 ? "state-dot needs-you" : "state-dot";
  toggleClass("dock-attention", "attention-cell", needs > 0);
  setText("dock-attention-text", needs > 0 ? (needs + " needs you") : "all clear");

  // breaker — shown ONLY when the loop reports consecutive failures (rose text).
  const cf = ov && ov.loop ? ov.loop.consecFails : null;
  const brEl = el("dock-breaker");
  if (brEl) {
    const tripped = typeof cf === "number" && cf > 0;
    brEl.hidden = !tripped;
    if (tripped) setText("dock-breaker-text", "breaker " + cf);
  }
}

export function initDock() {
  const dock = el("status-dock");
  if (!dock) return;
  dock.addEventListener("click", (e) => {
    if (e.target.closest("#dock-hist-back")) { switchPlan(null); return; }
    const cell = e.target.closest("[data-dock-nav]");
    if (cell) { location.hash = cell.dataset.dockNav; }
  });
  renderCells();   // paint immediately (pre-snapshot → placeholders; fills on first tick)
  fetchDockQuota();   // one codex-quota probe on init; refreshed every 150 ticks
}

// Called from the shared snapshot dispatcher (main.js). The only fetch is the
// codex-quota probe every 150 ticks (~5min); every other cell is snapshot-derived.
export function dockTick() {
  renderCells();
  if ((++provTick) % 150 === 0) fetchDockQuota();
}
