/* plan/lens_timeline.js — the Timeline lens (flagship). Projects /api/timeline
   onto a compressed real-time axis: activity segments padded ±10min, gaps >45min
   collapsed to fixed break cells, hour gridlines + day rules with sticky date
   labels, and a NOW line. Lanes are area groups (collapsible) over node lanes
   whose bars are interval-packed on real ms. Bars carry the shared state
   vocabulary; retries chain with dotted connectors and a row-end ↻ chip; gate
   marks are coral diamonds; L0 cycles a strip up top. Hover dims unrelated lanes
   and traces the task's node dependencies (blue) / dependents (green).

   Labels are placed by a per-lane, per-row pass after bars are positioned:
   canvas measureText decides inline / right-outside / hidden so no two labels
   overlap and none bleed across a (clipped) lane. Built once per signature; live
   bars get a width-only patch each tick — never an innerHTML rebuild. */

import { S, esc, escAttr, icon, gateTone, select } from "../app.js";
import { bus } from "../core/bus.js";
import { isHistorical } from "../core/api.js";
import { loadingHtml } from "../core/health.js";
import { getDag, dagIndex, fetchTimeline, getTimeline } from "./data.js";

const BAR_H = 20, GAP = 5, LANE_PAD = 4;
const BREAK_W = 28, BREAK_BUDGET_SHARE = 0.25, AREA_HEAD_H = 24, AXIS_H = 46, CYCLE_H = 4;
const LABEL_TARGET_W = 56, MAX_PANE_WIDTHS = 8;
const UNATTRIBUTED = "(unattributed)";
const M = 60000;
const MON = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"];
// --tl-gutter is the single source of truth (CSS var + JS), read once at load.
const GUTTER = (() => {
  try { const v = parseInt(getComputedStyle(document.documentElement).getPropertyValue("--tl-gutter"), 10); return isFinite(v) && v > 0 ? v : 210; }
  catch (e) { return 210; }
})();

let pane = null, sigLast = null, selectedTask = null;
let openAreas = null;        // Set<area>
let openUnattributed = null; // Set<area>; absent by default means honestly collapsed
let axis = null, barIndex = {}, nodeHull = {}, laneY = {};
let hostEl = null, scrollEl = null, overlayEl = null, detailEl = null;
let resizeObserver = null, resizeTimer = null, lastPaneW = 0;

// ------------------------------------------------- label width measurement --
// One offscreen 2d context measures label widths exactly (proportional glyphs);
// results cached per string since task ids repeat across rebuilds.
let _ctx = null; const _lw = new Map();
function labelWidth(text) {
  if (_lw.has(text)) return _lw.get(text);
  let w;
  try {
    if (!_ctx) { _ctx = document.createElement("canvas").getContext("2d"); _ctx.font = "500 10px ui-monospace, SFMono-Regular, Menlo, monospace"; }
    w = _ctx.measureText(text).width;
  } catch (e) { w = String(text).length * 6.2; }
  _lw.set(text, w); return w;
}

function visibleTaskId(id) {
  const match = String(id || "").match(/^TASK-(\d+)$/);
  return match ? match[1] : String(id || "");
}

function median(values) {
  if (!values.length) return 0;
  const sorted = values.slice().sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

// ------------------------------------------------------------- axis --------
function buildAxis(data, paneW) {
  const spans = [];
  const taskMinutes = [];
  const nowMs = Date.parse(data.now);
  // `|| []` throughout: the axis is now built for payloads that carry cycles or
  // gates but no tasks at all, and a partial payload must not throw.
  for (const t of (data.tasks || [])) for (const iv of (t.intervals || [])) {
    const s = Date.parse(iv.startedAt); if (isNaN(s)) continue;
    let e = iv.endedAt ? Date.parse(iv.endedAt) : nowMs;
    if (isNaN(e) || e < s) e = s + M;
    spans.push([s, e]);
    taskMinutes.push(Math.max(1, (e - s) / M));
  }
  for (const c of (data.cycles || [])) { const s = Date.parse(c.startedAt); if (isNaN(s)) continue; const e = c.endedAt ? Date.parse(c.endedAt) : s; spans.push([s, isNaN(e) ? s : e]); }
  const times = [];
  for (const [s, e] of spans) times.push(s, e);
  for (const g of (data.gates || [])) { const t = Date.parse(g.recordedAt); if (!isNaN(t)) times.push(t); }
  if (!isNaN(nowMs)) times.push(nowMs);
  times.sort((a, b) => a - b);
  if (!times.length) return null;

  const GAP45 = 45 * M, PAD = 10 * M;
  const raw = []; let segS = times[0], prev = times[0];
  for (let i = 1; i < times.length; i++) { const t = times[i]; if (t - prev > GAP45) { raw.push([segS, prev]); segS = t; } prev = t; }
  raw.push([segS, prev]);
  const segs = raw.map(([s, e]) => ({ s: s - PAD, e: e + PAD, rawS: s, rawE: e }));
  const activeMin = segs.reduce((a, g) => a + (g.e - g.s) / M, 0);
  const breakCount = Math.max(0, segs.length - 1);
  const paneFloor = Math.max(320, paneW - GUTTER);
  // The cap applies to the full canvas, including its sticky gutter. When a
  // campaign has hundreds of fragmented activity islands, fixed 28px break
  // cells alone can exceed that cap; shrink them as a group while preserving
  // every gap and reserve the rest of the track for activity marks.
  // Keep the fill floor subordinate to the ceiling: even an artificially tiny
  // pane must not let the 320px preferred floor override the 8-pane budget.
  const maxTrack = Math.max(1, paneW * MAX_PANE_WIDTHS - GUTTER);
  const breakW = breakCount ? Math.min(BREAK_W, maxTrack * BREAK_BUDGET_SHARE / breakCount) : 0;
  const breakTotal = breakCount * breakW;
  const scaleDenom = Math.max(1, activeMin);
  const capScale = Math.max(0, (maxTrack - breakTotal) / scaleDenom);
  const fillScale = Math.min(capScale, Math.max(0.02, (paneFloor - breakTotal) / scaleDenom));
  const medianMinutes = median(taskMinutes);
  const legibleScale = medianMinutes ? LABEL_TARGET_W / medianMinutes : fillScale;
  // Legibility, not pane width, drives the normal scale: a median task interval
  // aims for a 56px bar. The pane-fill floor avoids a stranded short axis, while
  // the 8× cap bounds navigation. Trade-off: short runs grow clearer; long
  // campaigns may scroll farther than before and eventually yield to the cap.
  const SCALE = Math.min(capScale, Math.max(fillScale, legibleScale));
  let run = 0; const breaks = [];
  segs.forEach((g, i) => {
    g.x0 = run; g.w = (g.e - g.s) / M * SCALE; run += g.w;
    if (i < segs.length - 1) { breaks.push({ x: run, w: breakW, fromE: raw[i][1], toS: raw[i + 1][0] }); run += breakW; }
  });
  const xOf = (ms) => {
    if (ms <= segs[0].s) return segs[0].x0;
    for (let i = 0; i < segs.length; i++) {
      const g = segs[i];
      if (ms <= g.e) return g.x0 + Math.max(0, ms - g.s) / M * SCALE;
      if (i < segs.length - 1 && ms < segs[i + 1].s) return g.x0 + g.w + breakW / 2;
    }
    const last = segs[segs.length - 1]; return last.x0 + last.w;
  };
  return { segs, breaks, xOf, totalWidth: run, SCALE, nowMs };
}

const fmtDur = (mins) => { const h = Math.floor(mins / 60), m = Math.round(mins % 60); return h ? `${h}h ${m}m` : `${m}m`; };

// split an interval into per-segment pieces (so a bar crossing a break renders split)
function pieces(s, e) {
  const out = [];
  for (const g of axis.segs) { const a = Math.max(s, g.s), b = Math.min(e, g.e); if (b > a) out.push([a, b]); }
  return out.length ? out : [[s, Math.max(e, s + M)]];
}

// per-task busy intervals in real ms (for interval-based row packing)
function taskBusy(t) {
  return t.intervals.map((iv) => {
    const s = Date.parse(iv.startedAt); let e = iv.endedAt ? Date.parse(iv.endedAt) : axis.nowMs;
    if (isNaN(e) || e < s) e = s + M;
    return [s, e];
  });
}
function busyOverlaps(a, b) { for (const [as, ae] of a) for (const [bs, be] of b) if (as < be && bs < ae) return true; return false; }

// A collapsed row remains an honest trace: every recorded interval is projected
// onto the same axis instead of disappearing behind the disclosure control.
function heatFor(tasks) {
  let html = "";
  for (const t of tasks) for (const iv of (t.intervals || [])) {
    const s = Date.parse(iv.startedAt);
    if (!Number.isFinite(s)) continue;
    let e = iv.endedAt ? Date.parse(iv.endedAt) : axis.nowMs;
    if (!Number.isFinite(e) || e < s) e = s + M;
    for (const [ps, pe] of pieces(s, e)) {
      html += `<span class="tl-heat" style="left:${axis.xOf(ps)}px;width:${Math.max(2, axis.xOf(pe) - axis.xOf(ps))}px"></span>`;
    }
  }
  return html;
}

// ------------------------------------------------------------- build -------
function build() {
  const data = getTimeline();
  if (!pane) return;
  // Bail only when there is genuinely nothing to plot. This used to bail on
  // `!data.tasks.length`, which hid 147 L0 reconcile cycles, every gate, and a
  // whole run of planning during the window before the first task was imported
  // — the operator saw "no runtime activity recorded yet" while the loop was
  // demonstrably working. buildAxis already derives its axis from cycles and
  // gates as well as tasks, so it is the honest authority on "nothing to draw".
  if (!data) { pane.innerHTML = loadingHtml("timeline", "plan-lens-empty"); sigLast = sigOf(data); return; }

  const paneW = pane.clientWidth || 900;
  lastPaneW = paneW;
  axis = buildAxis(data, paneW);
  if (!axis) {
    pane.innerHTML = `<div class="plan-lens-empty">no runtime activity recorded yet — no cycles, gates, or tasks in the events window</div>`;
    sigLast = sigOf(data);
    return;
  }
  const idx = dagIndex();
  const stageOf = (nid) => (idx && idx.nodeById[nid] ? idx.nodeById[nid].stage : "");
  const gateByNode = {}; for (const g of (data.gates || [])) gateByNode[g.node] = g;
  const totalW = axis.totalWidth;

  // group tasks: area -> node(or an explicit unattributed sentinel) -> [tasks]
  const areas = {};
  for (const t of (data.tasks || [])) {
    const a = t.area || "(none)"; const nkey = t.node || UNATTRIBUTED;
    (areas[a] = areas[a] || {});
    (areas[a][nkey] = areas[a][nkey] || []).push(t);
  }
  const areaFirst = (a) => Math.min(...Object.values(areas[a]).flat().flatMap((t) => t.intervals.map((iv) => Date.parse(iv.startedAt) || Infinity)));
  const areaOrder = Object.keys(areas).sort((x, y) => areaFirst(x) - areaFirst(y));

  if (openAreas == null) {
    openAreas = new Set();
    const stored = localStorage.getItem("singular.plan.tl.open");
    if (stored != null) { try { openAreas = new Set(JSON.parse(stored)); } catch (e) {} }
    else for (const a of areaOrder) {
      const tasks = Object.values(areas[a]).flat();
      // The uncertainty lane itself starts collapsed, but its parent must be
      // open on first render so even an integrated unattributed task is named.
      if (tasks.some((t) => t.status !== "integrated") || (areas[a][UNATTRIBUTED] || []).length) openAreas.add(a);
    }
  }
  if (openUnattributed == null) {
    // Deliberately starts empty: uncertainty is summarized, not hidden, until an
    // operator expands the honest "no node recorded" lane.
    openUnattributed = new Set();
    const stored = localStorage.getItem("singular.plan.tl.unattributed.open");
    if (stored != null) { try { openUnattributed = new Set(JSON.parse(stored)); } catch (e) {} }
  }

  barIndex = {}; nodeHull = {}; laneY = {};
  let y = AXIS_H;
  let rowsHtml = `<div class="tl-row tl-axis-spacer" style="height:${AXIS_H}px"><div class="tl-gutter tl-corner"></div><div class="tl-track tl-axis-track">${buildAxisLabels(data, totalW)}</div></div>`;

  for (const a of areaOrder) {
    const nodesInArea = Object.keys(areas[a]).sort((x, y2) => (stageOf(x) || "").localeCompare(stageOf(y2) || "") || x.localeCompare(y2));
    const attributedNodes = nodesInArea.filter((n) => n !== UNATTRIBUTED);
    const unattributedCount = (areas[a][UNATTRIBUTED] || []).length;
    const allTasks = Object.values(areas[a]).flat();
    const gatesPassed = attributedNodes.filter((n) => (gateByNode[n] || {}).status === "passed").length;
    const open = openAreas.has(a);

    // Collapsed areas retain a heat strip inside the compact header band.
    const bandHeat = open ? "" : heatFor(allTasks);
    rowsHtml += `<div class="tl-row tl-arearow" style="height:${AREA_HEAD_H}px">
      <button class="tl-gutter tl-area-head" data-area="${escAttr(a)}" aria-expanded="${open}">
        <span class="tl-area-chev">${icon("i-chev")}</span><span class="tl-area-name">${esc(a)}</span>
        <span class="tl-area-meta mono">${attributedNodes.length}n · ${gatesPassed}/${attributedNodes.length} · ${allTasks.length} tasks${unattributedCount ? ` · ${unattributedCount} no node` : ""}</span></button>
      <div class="tl-track tl-area-band">${bandHeat}</div></div>`;
    y += AREA_HEAD_H;
    if (!open) continue;

    for (const nkey of nodesInArea) {
      const tasks = areas[a][nkey].slice().sort((t1, t2) => taskStart(t1) - taskStart(t2));
      const isUnattributed = nkey === UNATTRIBUTED;
      const uncertaintyLabel = `unattributed · ${tasks.length} — no node recorded`;

      if (isUnattributed && !openUnattributed.has(a)) {
        rowsHtml += `<div class="tl-row tl-unattributed-row" style="height:${AREA_HEAD_H}px">
          <button class="tl-gutter tl-node-gutter tl-unattributed-head" data-unattributed-area="${escAttr(a)}" aria-expanded="false" title="${escAttr(uncertaintyLabel)}">
            <span class="tl-unattributed-chev">${icon("i-chev")}</span><span class="tl-node-id">${esc(uncertaintyLabel)}</span></button>
          <div class="tl-track tl-lane tl-unattributed-band">${heatFor(tasks)}</div></div>`;
        y += AREA_HEAD_H;
        continue;
      }

      // interval-based row packing: a task fits a row iff its busy intervals don't
      // overlap any interval already placed there (keeps task-per-row + connectors).
      const rowIntervals = []; const place = {};
      for (const t of tasks) {
        const busy = taskBusy(t);
        let ri = rowIntervals.findIndex((r) => !busyOverlaps(r, busy));
        if (ri < 0) { ri = rowIntervals.length; rowIntervals.push([]); }
        rowIntervals[ri] = rowIntervals[ri].concat(busy);
        place[t.taskId] = ri;
      }
      const nRows = Math.max(1, rowIntervals.length);
      const laneH = nRows * (BAR_H + GAP) - GAP + LANE_PAD * 2;
      const laneTop = y;
      laneY[nkey] = laneTop + laneH / 2;

      // Phase A: place bars (merge <4px pieces), record rects; collect label cands.
      const laneTasks = []; const rowBars = {}; const labelCands = [];
      let nodeX0 = Infinity, nodeX1 = -Infinity;
      for (const t of tasks) {
        const row = place[t.taskId];
        const barTop = LANE_PAD + row * (BAR_H + GAP);
        const st2 = barState(t);
        const title = titleOf(t.taskId);
        const raw = [];
        t.intervals.forEach((iv, ii) => {
          let s = Date.parse(iv.startedAt); let e = iv.endedAt ? Date.parse(iv.endedAt) : axis.nowMs;
          const amber = e < s; if (amber) e = s + M;
          const live = !isHistorical() && t.liveNow && !iv.endedAt; if (live) e = axis.nowMs;
          pieces(s, e).forEach(([ps, pe]) => {
            const left = axis.xOf(ps); const width = Math.max(6, axis.xOf(pe) - left);
            raw.push({ left, width, amber, live });
          });
        });
        raw.sort((p, q) => p.left - q.left);
        const merged = [];
        for (const pc of raw) {
          const last = merged[merged.length - 1];
          if (last && pc.left - (last.left + last.width) < 4) {
            last.width = Math.max(last.width, pc.left + pc.width - last.left);
            last.live = last.live || pc.live; last.amber = last.amber || pc.amber;
          } else merged.push({ ...pc });
        }
        let taskX0 = Infinity, taskX1 = -Infinity;
        merged.forEach((pc) => {
          taskX0 = Math.min(taskX0, pc.left); taskX1 = Math.max(taskX1, pc.left + pc.width);
          (rowBars[row] = rowBars[row] || []).push({ left: pc.left, right: pc.left + pc.width });
        });
        const retries = t.retryCount != null ? t.retryCount : Math.max(0, t.intervals.length - 1);
        if (retries > 0 && isFinite(taskX1)) {
          const retryLeft = taskX1 + 6;
          (rowBars[row] = rowBars[row] || []).push({ left: retryLeft, right: retryLeft + labelWidth("↻" + retries) });
        }
        const text = t.taskId + (title ? " · " + title : "");   // full "id · title" for title attr + detail card only
        const visibleId = visibleTaskId(t.taskId);
        if (merged.length) {
          // Visible labels are the numeric suffix only (0041). Every interval
          // still exposes the unabridged id/title through title + aria-label.
          labelCands.push({ taskId: t.taskId, visibleId, row, anchors: merged.map((pc, index) => ({ left: pc.left, right: pc.left + pc.width, width: pc.width, index })), barTop, labelW: labelWidth(visibleId), mode: "hidden", anchorIndex: 0 });
        }
        laneTasks.push({ t, row, barTop, st2, merged, retries, taskX0, taskX1, text });
        nodeX0 = Math.min(nodeX0, taskX0); nodeX1 = Math.max(nodeX1, taskX1);
        barIndex[t.taskId] = { node: nkey, x0: isFinite(taskX0) ? taskX0 : 0, x1: isFinite(taskX1) ? taskX1 : 0, y: laneTop + barTop + BAR_H / 2 };
      }

      // Phase B: resolve label modes (inline / right-outside / hidden) per row.
      resolveLabels(labelCands, rowBars, totalW);
      const labelByTask = {}; for (const c of labelCands) labelByTask[c.taskId] = c;

      // Phase C: emit bars + labels + retry chips + connectors.
      let bars = "";
      for (const lt of laneTasks) {
        const cand = labelByTask[lt.t.taskId];
        lt.merged.forEach((pc, mi) => {
          const inner = (cand && cand.mode === "inline" && mi === cand.anchorIndex)
            ? `<span class="tl-bar-label">${esc(cand.visibleId)}</span>` : "";
          bars += `<div class="tl-bar tl-s-${lt.st2}${pc.amber ? " tl-amber" : ""}${pc.live ? " tl-live" : ""}" role="button" tabindex="${mi === 0 ? 0 : -1}" data-task="${escAttr(lt.t.taskId)}" data-node="${escAttr(nkey)}" data-live="${pc.live ? 1 : 0}" title="${escAttr(lt.text)}" aria-label="${escAttr(lt.text)}" style="left:${pc.left}px;top:${lt.barTop}px;width:${pc.width}px">${inner}</div>`;
          if (mi > 0) {
            const a2 = lt.merged[mi - 1], gapL = a2.left + a2.width, gapR = pc.left;
            if (gapR > gapL) bars += `<span class="tl-retry-link" style="left:${gapL}px;top:${lt.barTop + BAR_H / 2}px;width:${gapR - gapL}px"></span>`;
          }
        });
        if (cand && cand.mode === "out") {
          bars += `<span class="tl-bar-label tl-label-out" aria-hidden="true" style="left:${cand.outLeft}px;top:${lt.barTop}px;height:${BAR_H}px" title="${escAttr(lt.text)}">${esc(cand.visibleId)}</span>`;
        }
        if (lt.retries > 0 && isFinite(lt.taskX1)) {
          bars += `<span class="tl-retry" style="left:${lt.taskX1 + 6}px;top:${lt.barTop}px;height:${BAR_H}px" title="${lt.retries} retries">↻${lt.retries}</span>`;
        }
      }

      const g = gateByNode[nkey];
      let gate = "";
      if (g && g.recordedAt) {
        const gx = axis.xOf(Date.parse(g.recordedAt));
        const passed = g.status === "passed";
        gate = `<span class="tl-gate${passed ? " passed" : ""}" style="left:${gx}px;top:${laneH - 12}px" title="${escAttr((g.evidenceClass || "") + " · " + g.recordedAt)}">${passed ? icon("i-check") : ""}</span>`;
      }
      nodeHull[nkey] = { y: laneY[nkey], x0: isFinite(nodeX0) ? nodeX0 : 0, x1: isFinite(nodeX1) ? nodeX1 : 0 };
      const gtone = gateTone((gateByNode[nkey] || {}).status);
      const gutterAttrs = isUnattributed
        ? `data-unattributed-area="${escAttr(a)}" aria-expanded="true" title="${escAttr(uncertaintyLabel)}"`
        : `data-node="${escAttr(nkey)}"`;
      const gutterLabel = isUnattributed
        ? `<span class="tl-unattributed-chev">${icon("i-chev")}</span><span class="tl-node-id">${esc(uncertaintyLabel)}</span>`
        : `<span class="tone-dot" data-tone="${gtone}"></span><span class="mono tl-node-id">${esc(nkey)}</span>`;
      rowsHtml += `<div class="tl-row${isUnattributed ? " tl-unattributed-row" : ""}" style="height:${laneH}px">
        <button class="tl-gutter tl-node-gutter${isUnattributed ? " tl-unattributed-head" : ""}" ${gutterAttrs}>${gutterLabel}</button>
        <div class="tl-track tl-lane" data-nodelane="${escAttr(nkey)}">${bars}${gate}</div></div>`;
      y += laneH;
    }
  }

  // Nothing imported yet, but the axis exists — so cycles/gates ARE plotted
  // above. Say so explicitly instead of leaving a bare axis that reads as a
  // rendering failure.
  if (!areaOrder.length) {
    rowsHtml += `<div class="tl-row tl-emptyrow" style="height:34px">`
      + `<div class="tl-gutter"></div>`
      + `<div class="tl-track"><span class="tl-emptynote">no imported tasks yet — L0 cycles and gates shown above</span></div>`
      + `</div>`;
    y += 34;
  }

  const contentH = y + 20;

  // background: hour/day gridlines, break cells, NOW line, cycles strip (labels
  // live in the sticky axis strip, built above).
  // (the L0 cycle strip is emitted by buildAxisLabels — see the note there)
  let bg = "";
  for (const g of axis.segs) {
    let t = Math.ceil(g.rawS / 3600000) * 3600000;
    for (; t <= g.rawE; t += 3600000) {
      const x = axis.xOf(t);
      const d = new Date(t);
      if (d.getUTCHours() === 0) bg += `<div class="tl-dayrule" style="left:${x}px;height:${contentH}px"></div>`;
      else bg += `<div class="tl-hourline" style="left:${x}px;height:${contentH}px"></div>`;
    }
  }
  // Track BODY: a break is a quiet full-height band only (translucent fill +
  // dotted edges). The slash glyphs + elided-duration label live in the axis
  // header band alone (buildAxisLabels), so nothing floats mid-track.
  for (const b of axis.breaks) {
    bg += `<div class="tl-break" style="left:${b.x}px;width:${b.w}px;height:${contentH}px"></div>`;
  }
  const nowX = axis.xOf(axis.nowMs);
  bg += `<div class="tl-now" style="left:${nowX}px;height:${contentH}px"></div>`;

  pane.style.overflow = "hidden";
  pane.innerHTML =
    `<div class="plan-tl-scroll"><div class="plan-tl" style="width:${GUTTER + totalW}px;min-height:${contentH}px">
       <div class="tl-bg" style="left:${GUTTER}px;width:${totalW}px;height:${contentH}px">${bg}</div>
       <svg class="tl-overlay" style="left:${GUTTER}px;width:${totalW}px;height:${contentH}px"></svg>
       <div class="tl-flow">${rowsHtml}</div>
       <div class="plan-detail-card tl-detail" hidden></div>
     </div><div class="tl-fade" aria-hidden="true"></div></div>`;

  scrollEl = pane.querySelector(".plan-tl-scroll");
  overlayEl = pane.querySelector(".tl-overlay");
  detailEl = pane.querySelector(".tl-detail");
  wire();
  sigLast = sigOf(data);
}

// The sticky top axis strip: day labels + a NOW cap, positioned in the same x as
// the lanes (the strip itself is offset by the gutter via CSS).
function buildAxisLabels(data, totalW) {
  let out = "";
  for (const g of axis.segs) {
    let t = Math.ceil(g.rawS / 3600000) * 3600000;
    for (; t <= g.rawE; t += 3600000) {
      const d = new Date(t);
      if (d.getUTCHours() === 0) out += `<div class="tl-daylabel" style="left:${axis.xOf(t) + 4}px">${MON[d.getUTCMonth()]} ${d.getUTCDate()}</div>`;
    }
  }
  // break glyphs (⫽ + elided-duration label) live ONLY here, inside the AXIS_H
  // band; the track body renders each break as a quiet band with no glyphs/text.
  for (const b of axis.breaks) {
    const txt = fmtDur((b.toS - b.fromE) / M);
    const horiz = labelWidth(txt) <= b.w - 6;   // "2h" fits horizontally, "1h 20m" rotates
    out += `<div class="tl-break-axis" style="left:${b.x}px;width:${b.w}px" title="${escAttr(txt + " elided")}"><span class="tl-break-l1"></span><span class="tl-break-l2"></span><span class="tl-break-lbl${horiz ? " horiz" : ""}">${esc(txt)}</span></div>`;
  }
  out += `<div class="tl-now-cap" style="left:${axis.xOf(axis.nowMs) + 2}px">NOW</div>`;
  // L0 reconcile cycles ride along the bottom edge of the sticky axis band.
  // They used to be emitted into .tl-bg at top:0 — underneath this band, which
  // is z-index 7 with an opaque background — so 147 cycles rendered and none of
  // them were ever visible. Living here they are both visible and pinned while
  // the lanes scroll.
  let cyc = "";
  (data.cycles || []).forEach((c, i) => {
    const s = Date.parse(c.startedAt);
    const e = c.endedAt ? Date.parse(c.endedAt) : s;
    if (!Number.isFinite(s)) return;
    const x = axis.xOf(s);
    const w = Math.max(2, axis.xOf(Math.max(e, s + M)) - x);
    cyc += `<span class="tl-cycle" style="left:${x}px;width:${w}px;${i % 2 ? "opacity:0.5" : ""}"></span>`;
  });
  if (cyc) out += `<div class="tl-cycle-strip" style="width:${totalW}px">${cyc}</div>`;
  return out;
}

// Per-lane label placement: try every retry segment for an inline home, then
// extend a compact numeric label into a quiet right-hand gap. The 3px clearance
// keeps outside labels from touching the next bar/retry marker while reaching
// substantially more 20px-ish intervals than the old full-id calculation.
function resolveLabels(cands, rowBars, totalW) {
  const byRow = {};
  for (const c of cands) (byRow[c.row] = byRow[c.row] || []).push(c);
  for (const row in byRow) {
    const allBars = (rowBars[row] || []).slice().sort((a, b) => a.left - b.left);
    for (const c of byRow[row]) {
      const inline = c.anchors.find((anchor) => c.labelW + 10 <= anchor.width);
      if (inline) {
        c.mode = "inline";
        c.anchorIndex = inline.index;
        continue;
      }
      let best = null;
      for (const anchor of c.anchors) {
        let nextLeft = totalW;
        for (const bb of allBars) {
          if (bb.left > anchor.right + 0.5) { nextLeft = bb.left; break; }
        }
        const available = nextLeft - anchor.right;
        if (c.labelW + 7 <= available && (!best || available > best.available)) best = { anchor, available };
      }
      if (best) {
        c.mode = "out";
        c.anchorIndex = best.anchor.index;
        c.barRight = best.anchor.right;
        c.outLeft = best.anchor.right + 4;
      } else c.mode = "hidden";
    }
  }
}

function taskStart(t) { return Math.min(...t.intervals.map((iv) => Date.parse(iv.startedAt) || Infinity)); }
function taskEnd(t) { return Math.max(...t.intervals.map((iv) => (iv.endedAt ? Date.parse(iv.endedAt) : (axis ? axis.nowMs : Date.now())) || 0)); }
function titleOf(id) { const t = (S.snap && S.snap.l2Tasks || []).find((x) => x.id === id); return t ? t.title : ""; }
function barState(t) {
  if (!isHistorical() && t.liveNow) return "live";
  const s = t.status;
  if (s === "integrated") return "integrated";
  if (s === "failed" || s === "blocked") return "failed";
  if (s === "awaiting" || s === "accepted") return "awaiting";
  return "active";
}

// ------------------------------------------------------------- hover -------
function applyHover(taskId) {
  const bars = pane.querySelectorAll(".tl-bar");
  if (!taskId) { bars.forEach((b) => { b.style.opacity = ""; }); overlayEl.innerHTML = ""; if (detailEl) detailEl.hidden = true; return; }
  const idx = dagIndex();
  const info = barIndex[taskId]; if (!info) return;
  const node = info.node;
  const deps = idx && idx.nodeById[node] ? (idx.nodeById[node].dependsOn || []) : [];
  const dependents = idx ? (idx.dependents[node] || []) : [];
  const related = new Set([node, ...deps, ...dependents]);
  bars.forEach((b) => { b.style.opacity = related.has(b.dataset.node) ? "1" : "0.28"; });
  const from = info;
  let paths = "";
  const orth = (x1, y1, x2, y2, color) => { const mx = (x1 + x2) / 2; return `<path d="M${x1},${y1} L${mx},${y1} L${mx},${y2} L${x2},${y2}" fill="none" stroke="${color}" stroke-width="1.5" opacity="0.85"/>`; };
  for (const d of deps) { const h = nodeHull[d]; if (h) paths += orth(from.x0, from.y, h.x1, h.y, "var(--tone-blue-dot)"); }
  for (const d of dependents) { const h = nodeHull[d]; if (h) paths += orth(from.x1, from.y, h.x0, h.y, "var(--tone-green-dot)"); }
  overlayEl.innerHTML = paths;
  showDetail(taskId);
}

function showDetail(taskId) {
  if (!detailEl) return;
  const data = getTimeline(); const t = data.tasks.find((x) => x.taskId === taskId); if (!t) return;
  const idx = dagIndex();
  const deps = idx && idx.nodeById[t.node] ? (idx.nodeById[t.node].dependsOn || []).join(" · ") || "—" : "—";
  const dep2 = idx && t.node ? (idx.dependents[t.node] || []).join(" · ") || "—" : "—";
  const s = taskStart(t), e = taskEnd(t);
  const mins = Math.round((e - s) / M);
  const runId = (t.intervals[0] || {}).runId || "—";
  detailEl.innerHTML =
    `<div class="plan-detail-head"><span class="mono" style="font-size:11px;color:var(--text-secondary)">${esc(t.taskId)}</span>
       <span class="plan-chip">${esc(t.area || "—")}</span>
       <span style="margin-left:auto;font:600 9px var(--font-sans);letter-spacing:0.05em;text-transform:uppercase;color:var(--text-meta)">${esc(t.status)}</span></div>
     <div class="plan-detail-title">${esc(titleOf(t.taskId) || t.taskId)}</div>
     <div class="plan-detail-rule"></div>
     <div class="plan-detail-row"><span class="pdl">Window</span><span class="pdv mono">${fmtDur(mins)} · ${t.retryCount || 0} retries</span></div>
     <div class="plan-detail-row"><span class="pdl">Run</span><span class="pdv mono">${esc(String(runId).replace(/^RUN-/, "").slice(0, 16))}</span></div>
     <div class="plan-detail-row"><span class="pdl">Node deps</span><span class="pdv mono" style="color:var(--tone-blue-fg)">${esc(deps)}</span></div>
     <div class="plan-detail-row"><span class="pdl">Unblocks</span><span class="pdv mono" style="color:var(--tone-green-fg)">${esc(dep2)}</span></div>`;
  detailEl.hidden = false;
}

// live bars: width-only patch each tick (no rebuild)
function patchLive() {
  if (!pane || !axis) return;
  const nowX = axis.xOf(axis.nowMs);
  pane.querySelectorAll('.tl-bar[data-live="1"]').forEach((b) => {
    const left = parseFloat(b.style.left) || 0; b.style.width = Math.max(6, nowX - left) + "px";
  });
}

function rebuildPreservingScroll() {
  const left = scrollEl ? scrollEl.scrollLeft : 0;
  const top = scrollEl ? scrollEl.scrollTop : 0;
  build();
  if (scrollEl) { scrollEl.scrollLeft = left; scrollEl.scrollTop = top; }
}

function wire() {
  const flow = pane.querySelector(".tl-flow");
  flow.addEventListener("click", (e) => {
    const head = e.target.closest(".tl-area-head");
    if (head) { const a = head.dataset.area; if (openAreas.has(a)) openAreas.delete(a); else openAreas.add(a); localStorage.setItem("singular.plan.tl.open", JSON.stringify([...openAreas])); rebuildPreservingScroll(); return; }
    const uncertainty = e.target.closest("[data-unattributed-area]");
    if (uncertainty) {
      const a = uncertainty.dataset.unattributedArea;
      if (openUnattributed.has(a)) openUnattributed.delete(a); else openUnattributed.add(a);
      localStorage.setItem("singular.plan.tl.unattributed.open", JSON.stringify([...openUnattributed]));
      rebuildPreservingScroll();
      return;
    }
    const node = e.target.closest(".tl-node-gutter");
    if (node) { if (node.dataset.node && bus.onNodeSelect) bus.onNodeSelect(node.dataset.node); return; }
    const bar = e.target.closest(".tl-bar[data-task]");
    if (bar) { bar.focus({ preventScroll: true }); select("l2", bar.dataset.task); }
  });
  flow.addEventListener("keydown", (e) => {
    const bar = e.target.closest('.tl-bar[role="button"][data-task]');
    if (bar && (e.key === "Enter" || e.key === " ")) {
      e.preventDefault();
      select("l2", bar.dataset.task);
    }
  });
  flow.addEventListener("focusin", (e) => { const b = e.target.closest(".tl-bar[data-task]"); if (b) applyHover(b.dataset.task); });
  flow.addEventListener("focusout", (e) => { const b = e.target.closest(".tl-bar[data-task]"); if (b && !(e.relatedTarget && e.relatedTarget.closest && e.relatedTarget.closest(".tl-bar"))) applyHover(null); });
  flow.addEventListener("pointerover", (e) => { const b = e.target.closest(".tl-bar[data-task]"); if (b) applyHover(b.dataset.task); });
  flow.addEventListener("pointerout", (e) => { const b = e.target.closest(".tl-bar[data-task]"); if (b && !(e.relatedTarget && e.relatedTarget.closest && e.relatedTarget.closest(".tl-bar"))) applyHover(null); });
}

// ------------------------------------------------------------- iface -------
function sigOf(data) {
  if (!data) return "none";
  let maxEnd = 0; for (const t of data.tasks) for (const iv of t.intervals) { const e = iv.endedAt ? Date.parse(iv.endedAt) : 0; if (e > maxEnd) maxEnd = e; }
  return JSON.stringify([data.tasks.length, maxEnd, data.tasks.filter((t) => t.liveNow).map((t) => t.taskId), data.gates.length, data.cycles.length]);
}

async function refresh(initial) {
  await fetchTimeline();
  if (!pane) return;
  const data = getTimeline();
  const sig = sigOf(data);
  if (initial || sig !== sigLast) {
    const left = scrollEl ? scrollEl.scrollLeft : 0;
    const top = scrollEl ? scrollEl.scrollTop : 0;
    build();
    if (scrollEl) { scrollEl.scrollLeft = left; scrollEl.scrollTop = top; }
  }
  else if (!isHistorical()) patchLive();   // archived bars never extend (no liveNow)
}

export const lens = {
  mount(p) {
    pane = p; sigLast = null;
    if (getTimeline()) build(); else pane.innerHTML = loadingHtml("timeline", "plan-lens-empty");
    if (typeof ResizeObserver !== "undefined") {
      resizeObserver = new ResizeObserver((entries) => {
        const width = Math.round((entries[0] && entries[0].contentRect && entries[0].contentRect.width) || (pane && pane.clientWidth) || 0);
        if (!pane || width <= 0 || Math.abs(width - lastPaneW) < 2) return;
        clearTimeout(resizeTimer);
        resizeTimer = setTimeout(() => { if (pane && Math.abs((pane.clientWidth || width) - lastPaneW) >= 2) rebuildPreservingScroll(); }, 80);
      });
      resizeObserver.observe(p);
    }
    refresh(true);
  },
  update() { refresh(false); },
  applySelection(id) { /* node selection has no direct bar; hover drives relations */ },
  focusTask(id) {
    selectedTask = id;
    const b = pane && pane.querySelector(`.tl-bar[data-task="${window.CSS && CSS.escape ? CSS.escape(id) : id}"]`);
    if (b) b.scrollIntoView({ block: "center", inline: "center" });
  },
  unmount() {
    if (resizeObserver) resizeObserver.disconnect();
    resizeObserver = null;
    clearTimeout(resizeTimer); resizeTimer = null;
    if (pane) pane.style.overflow = "";
    pane = null; sigLast = null; barIndex = {}; lastPaneW = 0;
  },
};
