/* plan/lens_dag.js — the DAG lens as a card-based pipeline. White rounded pill
   cards on a dotted-grid canvas, each with a leading status glyph, the node id
   in confident mono, an optional ×N task-count badge, and an attribution line
   (owner-area dot + name, then the stage) underneath.

   Columns are DEPENDENCY WAVES: every node of equal longest-path rank over the
   whole dependsOn graph, computed by the pure dag_layout.js module. Stages no
   longer place anything — they used to own the columns, with depth computed
   from same-stage edges only, which drew a plan that names one stage per node
   as a single sequential rail and could even put a node left of its own
   prerequisite. Stages now survive as text on the card and in the
   detail card, nothing more.

   Soft edge-to-edge bezier edges carry no arrowheads at rest and grow
   directional markers only under hover tracing (blue upstream · green
   downstream). A sticky progress footer separates campaign gates from
   historical ones, a glyph legend spells out the status vocabulary, and a
   floating fit button scales the whole pipeline to the pane width. Layout is
   rebuilt only when the DAG changes (signature-gated); hover, selection and fit
   are attribute/style passes over the prebuilt DOM. */

import { esc, escAttr, icon, select } from "../app.js";
import { bus } from "../core/bus.js";
import { getDag } from "./data.js";
import { computeGrid } from "./dag_layout.js";

// card geometry — fixed-width cards, ellipsized ids
const NODE_W = 190;      // card width
const NODE_H = 40;       // card height (pill)
const ATTR_H = 18;       // attribution line under the card
const ROW_H = 84;        // vertical stride between rows in a wave
const COLUMN_W = 260;    // horizontal stride between rank columns
const MARGIN_X = 40;     // left/right canvas pad
const CARD_TOP = 56;     // first card top (below the wave ruler)
const RULER_TOP = 12;    // wave-ruler row
const FIT_KEY = "singular.plan.dag.fit";

let pane = null;
let sigLast = null;
let selectedId = null;
let fitOn = (() => { try { return localStorage.getItem(FIT_KEY) === "1"; } catch (e) { return false; } })();

// build artifacts
let nodesById = {}, positions = {}, ancestors = {}, descendants = {};
let waves = [];          // col -> [node ids], already in row order
let nodeEls = {}, attrEls = {}, edgeEls = [], detailEl = null;
let scrollEl = null, stageEl = null, wrapEl = null, fitBtn = null;
let stageNatW = 0, stageNatH = 0, ro = null;

// --------------------------------------------------------------- layout ----
function computeAncestry(dag) {
  const byId = {}; for (const n of dag.nodes) byId[n.id] = n;
  const children = {};
  for (const n of dag.nodes) for (const d of n.dependsOn || []) (children[d] = children[d] || []).push(n.id);
  const walk = (start, next) => {
    const out = new Set(); const stack = [...next(start)];
    while (stack.length) { const id = stack.pop(); if (id && !out.has(id)) { out.add(id); stack.push(...next(id)); } }
    return out;
  };
  ancestors = {}; descendants = {};
  // byId[id] is guarded: dependsOn may name an id outside the node set, and an
  // unguarded lookup threw here — blanking the whole lens over one stale edge.
  for (const n of dag.nodes) {
    ancestors[n.id] = walk(n.id, (id) => (byId[id] || {}).dependsOn || []);
    descendants[n.id] = walk(n.id, (id) => children[id] || []);
  }
  nodesById = byId;
}

function computeLayout(dag) {
  const nodes = dag.nodes || [];
  // The server may precompute a topological `rank` per node; older servers emit
  // none, so this is a guarded opt-in. Only a complete map is passed on —
  // dag_layout re-checks and falls back rather than mixing two rank spaces.
  const serverRanked = nodes.length > 0 && nodes.every((n) => Number.isFinite(n.rank));
  let override;
  if (serverRanked) { override = {}; for (const n of nodes) override[n.id] = n.rank; }
  const grid = computeGrid(nodes, override);

  waves = [];
  for (const n of nodes) {
    const cell = grid.cells[n.id];
    if (!cell) continue;
    (waves[cell.col] = waves[cell.col] || [])[cell.row] = n.id;
  }
  // A server override can leave a column empty; normalise the holes away so the
  // ruler, tints and footer can all just iterate.
  for (let i = 0; i < waves.length; i++) waves[i] = (waves[i] || []).filter((id) => id != null);

  // Recentre every wave against the tallest one, so the pipeline reads as a band
  // with a stable spine rather than a ragged top edge.
  const rows = Math.max(1, grid.maxRows);
  const CY0 = CARD_TOP + NODE_H / 2 + ((rows - 1) * ROW_H) / 2;
  positions = {};
  waves.forEach((ids, col) => {
    const k = ids.length;
    ids.forEach((nid, i) => {
      positions[nid] = { x: MARGIN_X + col * COLUMN_W, cy: CY0 - ((k - 1) * ROW_H) / 2 + i * ROW_H };
    });
  });

  const maxLeft = Math.max(MARGIN_X, ...Object.values(positions).map((p) => p.x));
  stageNatW = maxLeft + NODE_W + MARGIN_X;
  stageNatH = CARD_TOP + (rows - 1) * ROW_H + NODE_H + ATTR_H + 28;
  return grid;
}

// Ordered predicates over the node's resting status. The distinction the audit
// asked for is *why* a node is not moving: ready now, blocked by a dependency,
// blocked by a human gate, running, or complete in an earlier campaign.
//
//   done       gate passed (or passed-with-acknowledged-baseline) in the current
//              cohort — or with no cohort information at all, the pre-cohort
//              server's shape.
//   done-hist  the same, but grandfathered / cohort "historical". Historical
//              completion must never read as campaign progress, so
//              it wins over `done` when both descriptions fit.
//   failed     a hard gate verdict.
//   active     live work: an in-flight task OR an active L1 lease. The lease arm
//              is the fix for a node that is being planned right now rendering
//              as a quiet queued ring.
//   gated      on the frontier but held behind an unapproved human gate — either
//              the gate this node carries (humanGate) or one naming it in its
//              blocked set (humanGateBlockedBy, which the server only populates
//              while the gate is unapproved).
//   ready      on the frontier, nothing holding it. (The old code tested
//              `!status && frontier`, which never fired: the server always emits
//              a status string — "absent" — so the frontier glyph was dead.)
//   eval       an evaluation node not otherwise classified.
//   blocked    the default: waiting on a prerequisite.
//
// Every field beyond gate/tasks/frontier is optional — the server grows them in
// a parallel change and this must render identically without them.
function statusOf(n) {
  const g = n.gate || {};
  const c = (n.tasks && n.tasks.counts) || {};
  const status = g.status;
  const ok = status === "passed" || status === "passed-with-acknowledged-baseline";
  const historical = g.cohort === "historical" || g.evidenceClass === "grandfathered";
  const hg = n.humanGate || null;
  const heldByGate = (hg && hg.state !== "approved") || !!(n.humanGateBlockedBy || "").length;
  if (ok && !historical) return "done";
  if (ok) return "done-hist";
  if (status === "failed" || status === "blocked" || status === "invalid") return "failed";
  if ((c.active || 0) > 0 || (n.l1Lease && n.l1Lease.active)) return "active";
  if (n.frontier && heldByGate) return "gated";
  if (n.frontier) return "ready";
  if (n.kind === "evaluation") return "eval";
  return "blocked";
}

// Shape carries the status, not colour alone: filled check, outline check,
// pulse, diamond outline, filled diamond, pause bars, cross, hollow ring.
function glyphHtml(kind) {
  if (kind === "done") return `<span class="pdc-glyph g-done">${icon("i-check")}</span>`;
  if (kind === "done-hist") return `<span class="pdc-glyph g-done-hist">${icon("i-check")}</span>`;
  if (kind === "active") return `<span class="pdc-glyph g-active"><i class="pdc-pulse"></i></span>`;
  if (kind === "gated") return `<span class="pdc-glyph g-gated"><i></i><i></i></span>`;
  if (kind === "ready") return `<span class="pdc-glyph g-frontier"><i></i></span>`;
  if (kind === "eval") return `<span class="pdc-glyph g-eval"><i></i></span>`;
  if (kind === "failed") return `<span class="pdc-glyph g-failed">&times;</span>`;
  return `<span class="pdc-glyph g-blocked"><i></i></span>`;
}

function effRect(id) {
  const p = positions[id];
  return { left: p.x, right: p.x + NODE_W, cy: p.cy };
}

// card-edge to card-edge cubic bezier (right of source → left of target)
function curve(fromId, toId) {
  const a = effRect(fromId), b = effRect(toId);
  const fx = a.right, fy = a.cy, tx = b.left, ty = b.cy;
  const k = Math.max(40, (tx - fx) * 0.4);
  return `M${fx},${fy} C${fx + k},${fy} ${tx - k},${ty} ${tx},${ty}`;
}

// --------------------------------------------------------------- build -----
function build() {
  const dag = getDag();
  if (!pane) return;
  if (!dag || !(dag.nodes || []).length) { pane.innerHTML = `<div class="plan-lens-empty">no DAG nodes to graph</div>`; sigLast = "empty"; return; }
  if (ro) { try { ro.disconnect(); } catch (e) {} ro = null; }
  computeAncestry(dag);
  computeLayout(dag);

  // Dedup edges, and drop any whose endpoint this DAG does not place: the server
  // emits one edge per dependsOn entry including ids outside the node set, and
  // an unplaced endpoint would otherwise throw mid-build and blank the lens.
  const seen = new Set(); const edges = [];
  for (const e of dag.edges || []) {
    if (e.from === e.to || !positions[e.from] || !positions[e.to]) continue;
    const key = e.from + "->" + e.to;
    if (!seen.has(key)) { seen.add(key); edges.push({ from: e.from, to: e.to }); }
  }

  // Wave ruler — one calm header cell per rank column (this replaces the stage
  // ribbons; a wave is a set of nodes that may all start together) plus the
  // alternating full-height tints, now keyed by wave parity.
  let ruler = "", tints = "";
  waves.forEach((ids, col) => {
    if (!ids.length) return;
    const left = MARGIN_X + col * COLUMN_W - 8, width = NODE_W + 16;
    ruler += `<div class="plan-dag-wave" style="left:${left}px;top:${RULER_TOP}px;width:${width}px">
      <span class="pdw-id mono">wave ${col}</span>
      <span class="pdw-count mono">${ids.length} node${ids.length === 1 ? "" : "s"}</span></div>`;
    if (col % 2 === 0) tints += `<div class="plan-dag-tint" style="left:${left}px;width:${width}px;top:${RULER_TOP + 30}px;bottom:12px"></div>`;
  });

  // svg edges — no markers at rest; hover tracing swaps them in. (The old
  // coincident-rect suppression is gone with stage collapse: two distinct nodes
  // can no longer share one rectangle.)
  const edgePaths = edges.map((e, i) =>
    `<path data-edge="${i}" data-from="${escAttr(e.from)}" data-to="${escAttr(e.to)}" d="${curve(e.from, e.to)}" fill="none" stroke="var(--n-300)" stroke-width="1.5" opacity="0.7"/>`
  ).join("");
  const svg = `<svg width="${stageNatW}" height="${stageNatH}" class="plan-dag-edges">
    <defs>
      <marker id="dag-up" markerWidth="9" markerHeight="9" refX="6" refY="4" orient="auto" markerUnits="userSpaceOnUse"><path d="M1,1.5 L6,4 L1,6.5" fill="none" stroke="var(--tone-blue-dot)" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></marker>
      <marker id="dag-dn" markerWidth="9" markerHeight="9" refX="6" refY="4" orient="auto" markerUnits="userSpaceOnUse"><path d="M1,1.5 L6,4 L1,6.5" fill="none" stroke="var(--tone-green-dot)" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></marker>
    </defs>${edgePaths}</svg>`;

  // cards — glyph + id + ×N badge, attribution (area · stage) line under. A node
  // the scheduler cannot start yet for a *policy* reason (same-area lease, write
  // scopes overlapping an active lease) carries data-runnable="false"
  // and wears a dashed ring: safe serialization has to look deliberate, not
  // broken. The attribute is only emitted when the server says so.
  let cards = "";
  for (const n of dag.nodes) {
    const p = positions[n.id];
    if (!p) continue;
    const top = p.cy - NODE_H / 2;
    const kind = statusOf(n);
    const c = (n.tasks && n.tasks.counts) || {};
    const badge = (c.total || 0) > 1 ? `<span class="pdc-badge mono">&times;${c.total}</span>` : "";
    const dotTone = n.kind === "evaluation" ? "coral" : "neutral";
    const stageShort = n.stage ? String(n.stage).split("-")[0] : "";
    const runAttr = n.runnable === false ? ` data-runnable="false"` : "";
    const tip = [n.id, n.stage, n.area].filter(Boolean).join(" · ");
    cards += `<div class="plan-dag-cardwrap" style="left:${p.x}px;top:${top}px">
      <button class="plan-dag-card" data-node="${escAttr(n.id)}" data-selected="false" data-status="${kind}"${runAttr} title="${escAttr(tip)}">
        ${glyphHtml(kind)}<span class="pdc-name mono">${esc(n.id)}</span>${badge}</button>
      <div class="plan-dag-attr" data-attr="${escAttr(n.id)}"><span class="pdc-avatar" data-tone="${dotTone}"></span><span class="pdc-owner">${esc(n.area)}</span>${stageShort ? `<span class="pdc-stage mono">${esc(stageShort)}</span>` : ""}</div>
    </div>`;
  }

  // Progress footer dots, in wave order. Historical completion is counted and
  // drawn apart from campaign completion — a plan carried over from an earlier
  // run must not read as progress on this one.
  let dots = "", pTotal = 0, pPassed = 0, curTotal = 0, curPassed = 0, histPassed = 0;
  let cohortSeen = false, serializedSeen = false;
  const present = new Set();
  for (const ids of waves) {
    for (const nid of ids) {
      const n = nodesById[nid]; const g = n.gate || {};
      const kind = statusOf(n);
      present.add(kind);
      if (n.runnable === false) serializedSeen = true;
      if (g.cohort != null) cohortSeen = true;
      pTotal++;
      let cls = "hollow";
      if (kind === "done") { cls = "pass"; pPassed++; curTotal++; curPassed++; }
      else if (kind === "done-hist") { cls = "hist"; pPassed++; histPassed++; cohortSeen = true; }
      else { curTotal++; if (kind === "active") cls = "active"; }
      dots += `<i class="pdf-dot ${cls}"></i>`;
    }
  }
  const countLine = cohortSeen
    ? `${curPassed}/${curTotal} campaign · ${histPassed} historical`
    : `${pPassed}/${pTotal} gates`;

  // One-line glyph legend, restricted to the statuses this plan actually uses so
  // it stays a single quiet line.
  const LEGEND = [["done", "done"], ["done-hist", "historical"], ["active", "running"],
                  ["ready", "ready"], ["gated", "human gate"], ["blocked", "blocked"],
                  ["failed", "failed"], ["eval", "eval"]];
  let legend = LEGEND.filter(([k]) => present.has(k))
    .map(([k, label]) => `<span class="lg-item">${glyphHtml(k)}<span class="lg-text">${label}</span></span>`)
    .join("");
  if (serializedSeen) legend += `<span class="lg-item"><span class="lg-dash"></span><span class="lg-text">serialized</span></span>`;

  pane.style.overflow = "hidden";
  pane.innerHTML =
    `<div class="plan-scroll-host">
       <div class="plan-dag-scroll">
         <div class="plan-dag-stagewrap">
           <div class="plan-dag-stage" style="width:${stageNatW}px;height:${stageNatH}px">
             ${tints}${ruler}${svg}${cards}
           </div>
         </div>
       </div>
       <div class="plan-detail-card plan-dag-detail" hidden></div>
       <div class="plan-fade left"></div>
       <div class="plan-fade right"></div>
       <button class="plan-dag-fit" aria-pressed="${fitOn}" title="Fit to width">${icon("i-expand")}</button>
       ${legend ? `<div class="plan-dag-legend mono">${legend}</div>` : ""}
       <button class="plan-dag-progress" title="Plan overview">${dots}<span class="pdf-count mono">${countLine}</span></button>
     </div>`;

  // cache refs
  nodeEls = {}; attrEls = {}; edgeEls = [];
  pane.querySelectorAll(".plan-dag-card").forEach((el) => { nodeEls[el.dataset.node] = el; });
  pane.querySelectorAll(".plan-dag-attr").forEach((el) => { attrEls[el.dataset.attr] = el; });
  pane.querySelectorAll(".plan-dag-edges path[data-edge]").forEach((el) => edgeEls.push({ el, from: el.dataset.from, to: el.dataset.to }));
  detailEl = pane.querySelector(".plan-dag-detail");
  scrollEl = pane.querySelector(".plan-dag-scroll");
  stageEl = pane.querySelector(".plan-dag-stage");
  wrapEl = pane.querySelector(".plan-dag-stagewrap");
  fitBtn = pane.querySelector(".plan-dag-fit");

  wire();
  applyFit();
  repaint(null);
  if (window.ResizeObserver) { ro = new ResizeObserver(() => { if (fitOn) applyFit(); else centerStage(); measureFades(); }); ro.observe(pane); }
}

// Centre the (scaled) stage in the scroller on each axis when it fits, but fall
// back to flex-start on any axis where content overflows — centering an
// overflowing axis would push its top/left origin out of reach of the scrollbar.
function centerStage() {
  if (!scrollEl || !wrapEl) return;
  const paneW = scrollEl.clientWidth, paneH = scrollEl.clientHeight;
  const contentW = wrapEl.offsetWidth, contentH = wrapEl.offsetHeight;
  scrollEl.style.justifyContent = contentW <= paneW ? "center" : "flex-start";
  scrollEl.style.alignItems = contentH <= paneH ? "center" : "flex-start";
}

// --------------------------------------------------------------- fit -------
function applyFit() {
  if (!stageEl || !wrapEl || !scrollEl) return;
  let k = 1;
  if (fitOn) {
    const paneW = scrollEl.clientWidth || stageNatW;
    // Lower legibility floor is 0.25 (not 0.45). One column per dependency wave
    // is far narrower than the old one-column-per-stage layout, but a deep plan
    // still runs long (18 waves ≈ 4700px at 260px stride), and a 0.45 floor
    // could not remove horizontal scroll on a ~1360px pane. 0.25 lets the whole
    // graph fit while still guarding against microscopic scaling on
    // pathologically deep DAGs.
    k = Math.max(0.25, Math.min(paneW / stageNatW, 1));
  }
  stageEl.style.transformOrigin = "top left";
  stageEl.style.transform = k === 1 ? "none" : `scale(${k})`;
  wrapEl.style.width = stageNatW * k + "px";
  wrapEl.style.height = stageNatH * k + "px";
  if (fitBtn) fitBtn.setAttribute("aria-pressed", String(fitOn));
  centerStage();
  measureFades();
}

// --------------------------------------------------------------- paint -----
function repaint(focusId) {
  const dag = getDag(); if (!dag) return;
  let up = null, down = null, all = null;
  if (focusId && nodeEls[focusId]) { up = ancestors[focusId]; down = descendants[focusId]; all = new Set([focusId, ...up, ...down]); }

  for (const [id, el] of Object.entries(nodeEls)) {
    let op = 1, ring = "hover", z = "3";
    if (all) {
      if (id === focusId) { ring = "focus"; z = "8"; }
      else if (up.has(id)) { ring = "up"; z = "6"; }
      else if (down.has(id)) { ring = "down"; z = "6"; }
      else { op = 0.28; ring = "none"; }
    } else if (id === selectedId) { ring = "sel"; z = "7"; }
    el.style.opacity = op;
    el.dataset.trace = ring;
    el.dataset.selected = String(id === selectedId);
    el.parentElement.style.zIndex = z;
  }
  for (const [id, el] of Object.entries(attrEls)) el.style.opacity = all && !all.has(id) ? "0.22" : "1";
  for (const e of edgeEls) {
    let stroke = "var(--n-300)", w = "1.5", op = "0.7", mk = "";
    if (all) {
      const upEdge = (e.to === focusId || up.has(e.to)) && (e.from === focusId || up.has(e.from));
      const dnEdge = (e.from === focusId || down.has(e.from)) && (e.to === focusId || down.has(e.to));
      if (upEdge) { stroke = "var(--tone-blue-dot)"; w = "1.8"; op = "0.95"; mk = "url(#dag-up)"; }
      else if (dnEdge) { stroke = "var(--tone-green-dot)"; w = "1.8"; op = "0.95"; mk = "url(#dag-dn)"; }
      else { op = "0.08"; }
    }
    e.el.setAttribute("stroke", stroke); e.el.setAttribute("stroke-width", w);
    e.el.setAttribute("opacity", op);
    if (mk) e.el.setAttribute("marker-end", mk); else e.el.removeAttribute("marker-end");
  }
  if (focusId && detailEl) showDetail(focusId); else if (detailEl) detailEl.hidden = true;
}

function showDetail(id) {
  const n = nodesById[id]; if (!n || !detailEl) return;
  const p = positions[id], el = nodeEls[id];
  if (!p || !el) { detailEl.hidden = true; return; }
  const g = n.gate || {}; const c = (n.tasks && n.tasks.counts) || {};
  const deps = (n.dependsOn || []).join(" · ") || "—";
  detailEl.innerHTML =
    `<div class="plan-detail-head"><span class="mono" style="font-size:11px;color:var(--text-secondary)">${esc(n.id)}</span>
       <span class="plan-chip">${esc(n.area)}</span>
       <span style="margin-left:auto;font:600 9px var(--font-sans);letter-spacing:0.05em;text-transform:uppercase;color:var(--text-meta)">${esc(g.status || "absent")}</span></div>
     <div class="plan-detail-title">${esc(n.stage)}${n.kind ? " · " + esc(n.kind) : ""}</div>
     <div class="plan-detail-rule"></div>
     <div class="plan-detail-row"><span class="pdl">Depends on</span><span class="pdv mono" style="color:var(--tone-blue-fg)">${esc(deps)}</span></div>
     <div class="plan-detail-row"><span class="pdl">Unblocks</span><span class="pdv" style="color:var(--tone-green-fg)">${(descendants[id] || new Set()).size} downstream</span></div>
     <div class="plan-detail-row"><span class="pdl">Tasks</span><span class="pdv mono">${c.integrated || 0}/${c.total || 0}</span></div>`;
  // The card now lives in the (unscaled) scroll-host, not inside the scaled
  // stage, so we place it against real post-transform screen rects. Prefer
  // below the node (8px gap), flip above only when below overflows the pane,
  // then clamp both axes fully inside the scroller's visible rect (8px pad).
  detailEl.hidden = false;                        // reveal so it can be measured
  const host = detailEl.offsetParent || scrollEl;
  const hostRect = host.getBoundingClientRect();
  const paneRect = scrollEl.getBoundingClientRect();
  const nodeRect = el.getBoundingClientRect();
  const cw = detailEl.offsetWidth, ch = detailEl.offsetHeight;
  const pad = 8, gap = 8;
  let top = nodeRect.bottom + gap;                 // prefer below
  if (top + ch > paneRect.bottom - pad) {          // ...unless it clips the bottom
    const above = nodeRect.top - gap - ch;
    if (above >= paneRect.top + pad) top = above;  // flip above only if it fits
  }
  let left = nodeRect.left;                         // left-align to the node card
  left = Math.min(Math.max(left, paneRect.left + pad), paneRect.right - pad - cw);
  top = Math.min(Math.max(top, paneRect.top + pad), paneRect.bottom - pad - ch);
  detailEl.style.left = (left - hostRect.left) + "px";
  detailEl.style.top = (top - hostRect.top) + "px";
}

// --------------------------------------------------------------- wire ------
function wire() {
  stageEl.addEventListener("click", (e) => {
    const node = e.target.closest("[data-node]");
    if (node && bus.onNodeSelect) bus.onNodeSelect(node.dataset.node);
  });
  stageEl.addEventListener("pointerover", (e) => { const node = e.target.closest("[data-node]"); if (node) repaint(node.dataset.node); });
  stageEl.addEventListener("pointerout", (e) => {
    const node = e.target.closest("[data-node]");
    if (node && !stageEl.contains(e.relatedTarget && e.relatedTarget.closest && e.relatedTarget.closest("[data-node]"))) repaint(null);
  });
  scrollEl.addEventListener("scroll", measureFades);
  if (fitBtn) fitBtn.addEventListener("click", () => {
    fitOn = !fitOn;
    try { localStorage.setItem(FIT_KEY, fitOn ? "1" : "0"); } catch (e) {}
    applyFit();
  });
  const prog = pane.querySelector(".plan-dag-progress");
  if (prog) prog.addEventListener("click", () => select("overview", "plan"));
}

function measureFades() {
  if (!scrollEl || !pane) return;
  const max = scrollEl.scrollWidth - scrollEl.clientWidth;
  const l = pane.querySelector(".plan-fade.left"), r = pane.querySelector(".plan-fade.right");
  if (l) l.dataset.show = String(scrollEl.scrollLeft > 1);
  if (r) r.dataset.show = String(max > 1 && scrollEl.scrollLeft < max - 1);
}

// --------------------------------------------------------------- iface -----
// Everything a rebuild would change: status inputs (gate status AND cohort, task
// counts, lease liveness, human-gate state, runnability), the rank the layout is
// keyed on, and the edge SET — an edge-count signature missed a rewired
// dependency that kept the same number of edges, which is precisely the change
// that moves cards.
function currentSig() {
  const dag = getDag();
  if (!dag) return "nodag";
  return JSON.stringify({
    nodes: dag.nodes.map((n) => {
      const g = n.gate || {}, c = (n.tasks && n.tasks.counts) || {};
      return [n.id, g.status, g.cohort == null ? null : g.cohort, g.evidenceClass == null ? null : g.evidenceClass,
              c.active || 0, c.total || 0, n.kind, !!n.frontier,
              !!(n.l1Lease && n.l1Lease.active), (n.humanGate || {}).state || null,
              String(n.humanGateBlockedBy || ""), n.runnable === false,
              Number.isFinite(n.rank) ? n.rank : null];
    }),
    edges: (dag.edges || []).map((e) => e.from + ">" + e.to).join(","),
  });
}

export const lens = {
  mount(p) { pane = p; sigLast = null; build(); },
  update() {
    if (!pane) return;
    const sig = currentSig();
    if (sig !== sigLast) { const prev = scrollEl ? scrollEl.scrollLeft : 0; build(); if (scrollEl) scrollEl.scrollLeft = prev; sigLast = sig; }
  },
  applySelection(id) {
    selectedId = id;
    repaint(null);
    const el = nodeEls[id];
    if (el) el.scrollIntoView({ block: "center", inline: "center" });
  },
  unmount() {
    if (ro) { try { ro.disconnect(); } catch (e) {} ro = null; }
    if (pane) pane.style.overflow = "";
    pane = null; sigLast = null; nodeEls = {}; attrEls = {}; edgeEls = [];
    scrollEl = stageEl = wrapEl = fitBtn = detailEl = null;
  },
};
