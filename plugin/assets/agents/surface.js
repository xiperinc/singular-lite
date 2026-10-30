/* agents/surface.js — the Agents surface (0.6.0 console redesign).

   Ported from PMGO's AgentRoleGrid.tsx into pm-go tokens. Two live levels:
     L1  a responsive grid of role cards (avatar + corner status glyph, name,
         active/idle pill, current-work rows, model chip, last-activity age),
         with a dimmed "declared roles" strip below for catalog-only roles.
     L2  a role detail (breadcrumb back, identity + contract, Processes list, and
         READ-ONLY settings with env-key provenance). Level 3 is a JUMP to the
         Consoles surface (#consoles/<sessionId>) — no embedded terminal here.

   Data join (client-side): the declared role catalog (/api/roles), the resolved
   per-role config (/api/config), the 10s state snapshot (S.snap.agents), and the
   2s shared sessions feed (core/sessions-feed.js). The grid re-render is
   signature-gated and does zero work while the surface is hidden. */

import { S, esc, escAttr, icon, relTime, toast, viewRaw, viewPrompt, viewSessionPrompt } from "../app.js";
import { subscribe as subscribeSessions, feedState } from "../core/sessions-feed.js";
import { writeRoute } from "../core/router.js";
import { apiFetch } from "../core/api.js";
import { loadingHtml } from "../core/health.js";
import { modelOptions } from "../core/models.js";

const shortRun = (r) => String(r || "").replace(/^ORIGIN-|^RUN-/, "").slice(0, 16);

const REASONING_ALL = ["minimal", "low", "medium", "high", "xhigh"];
// enum option domains keyed by env key (the settings API doesn't ship choices)
const ENUM_OPTIONS = { SINGULAR_CODEX_SERVICE_TIER: ["default", "flex", "priority"] };
const effortOptions = (model) => /codex|gpt/i.test(model || "") ? ["minimal", "low", "medium", "high"]
  : /claude/i.test(model || "") ? ["low", "medium", "high", "xhigh"] : REASONING_ALL;
const shortEnv = (k) => String(k || "").replace(/^SINGULAR_/, "").toLowerCase();
const modelProvider = (row) => {
  if (row.provider) return String(row.provider).toLowerCase();
  const match = /^SINGULAR_([^_]+)_/.exec(String(row.envKey || ""));
  return match ? match[1].toLowerCase() : String((AG.config && AG.config.provider) || "").toLowerCase();
};
// card → prompt-library role (the template a role runs); resolved to a file name
// via /api/prompts' role field.
const PROMPT_ROLE = { origin: "origin", planner: "planner", developer: "developer", auditor: "auditor", reviewer: "reviewer", decider: "decider", "recovery-worker": "developer" };
const promptFileForCard = (card) => {
  const role = PROMPT_ROLE[card.id]; if (!role || !AG.prompts) return null;
  const p = (AG.prompts.prompts || []).find((x) => x.role === role); return p ? p.name : null;
};
// the rendered prompt this run actually used (session.logFiles kind:"prompt")
const runPromptFile = (s) => { const lf = ((s && s.logFiles) || []).find((f) => f.kind === "prompt"); return lf ? lf.name : null; };

// The eight cards with runtime evidence, in grid order. eyebrow layer follows the
// operating model (planner/integration/auditor are L1; the rest L2). configRole maps
// a card to its /api/config role for the model chip + settings provenance.
const CARDS = [
  { id: "origin", name: "origin", initials: "OR", tone: "ink", eyebrow: "L0 · SUPERVISOR", configRole: null },
  { id: "planner", name: "planner", initials: "PL", tone: "blue", eyebrow: "L1 · ORCHESTRATION", configRole: "planner", limits: true },
  { id: "developer", name: "developer", initials: "DV", tone: "soft", eyebrow: "L2 · WORKER", configRole: "implementer", limits: true },
  { id: "auditor", name: "auditor", initials: "AU", tone: "blue", eyebrow: "L1 · AUDIT", configRole: "auditor" },
  { id: "reviewer", name: "reviewer", initials: "RV", tone: "soft", eyebrow: "L2 · REVIEW", configRole: "auditor" },
  { id: "integration-worker", name: "integration", initials: "IG", tone: "blue", eyebrow: "L1 · INTEGRATION", configRole: null },
  { id: "recovery-worker", name: "recovery", initials: "RC", tone: "soft", eyebrow: "L2 · WORKER", configRole: "implementer" },
  { id: "decider", name: "decider", initials: "DC", tone: "soft", eyebrow: "L2 · WORKER", configRole: "decider" },
];
const CARD_BY_ID = Object.fromEntries(CARDS.map((c) => [c.id, c]));
// catalog roles with no runtime evidence → dimmed, non-drillable declared strip
const DECLARED_ONLY = ["test-engineer", "documentation-worker"];

const AG = {
  started: false,
  visible: false,
  config: null, configInflight: false,
  settings: null, settingsInflight: false, settingsUnavailable: false, settingsProbed: false,
  prompts: null, promptsInflight: false,
  roles: null, rolesInflight: false,
  sessions: [], byId: new Map(), generatedAt: null,
  level: 1,               // 1 = grid, 2 = detail
  roleId: null,           // detail role
  highlightSession: null, // deep-link process highlight
  editing: false,         // a settings editor has unsaved edits → freeze re-renders
  sysOpen: false,         // System settings panel open
  sig: null,
};

// ------------------------------------------------------------- data fetch -----
async function fetchConfig(force) {
  if (AG.configInflight || (AG.config && !force)) return;
  AG.configInflight = true;
  try { const r = await apiFetch("/api/config", { cache: "no-store" }); if (r.ok) AG.config = await r.json(); }
  catch (e) { /* leave last good */ } finally { AG.configInflight = false; render(); }
}
// Feature-probe + fetch the typed settings envelope (23 knobs, 4 groups). A 404
// flips settingsUnavailable so both editors fall back to read-only.
async function fetchSettings(force) {
  if (AG.settingsInflight || (AG.settings && !force) || AG.settingsUnavailable) return;
  AG.settingsInflight = true;
  try {
    const r = await apiFetch("/api/settings", { cache: "no-store" });
    if (r.status === 404 || r.status === 501) { AG.settingsUnavailable = true; }
    else if (r.ok) { AG.settings = await r.json(); }
  } catch (e) { /* leave last good */ }
  finally { AG.settingsProbed = true; AG.settingsInflight = false; if (AG.sysOpen) renderSysPanel(); }
}

// POST changes to /api/settings; refresh config+settings, toast appliesAt notes.
async function postSettings(changes, done) {
  try {
    const res = await fetch("/api/settings", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ changes }) });
    if (res.status === 404 || res.status === 405 || res.status === 501) { AG.settingsUnavailable = true; toast("settings are read-only on this server"); done && done(false); return; }
    const data = await res.json().catch(() => ({}));
    if (!res.ok) { toast(data.error ? String(data.error) : "save failed · " + res.status); done && done(false); return; }
    if (data.config) AG.config = data.config;
    if (data.settings) AG.settings = data.settings;
    const at = data.appliesAt || {};
    const note = Object.keys(changes).map((k) => `${shortEnv(k)} → ${at[k] || "applied"}`).join(" · ");
    toast(note || "settings saved");
    AG.editing = false; AG.sig = null;
    done && done(true);
  } catch (e) { toast("save failed"); done && done(false); }
}

// The prompt library (/api/prompts) — role→template names for the role prompt section.
async function fetchPrompts() {
  if (AG.prompts || AG.promptsInflight) return;
  AG.promptsInflight = true;
  try { const r = await apiFetch("/api/prompts", { cache: "no-store" }); if (r.ok) AG.prompts = await r.json(); }
  catch (e) { /* prompt section just hides without the library */ }
  finally { AG.promptsInflight = false; if (AG.visible) { AG.sig = null; render(); } }
}

function ensureRoles() {
  if (AG.roles) return;
  if (S.roleCatalog) { AG.roles = S.roleCatalog; return; }
  if (AG.rolesInflight) return;
  AG.rolesInflight = true;
  apiFetch("/api/roles", { cache: "no-store" }).then((r) => r.ok ? r.json() : null).then((j) => { if (j) { AG.roles = j; S.roleCatalog = S.roleCatalog || j; } })
    .catch(() => {}).finally(() => { AG.rolesInflight = false; render(); });
}
function workerCatalog(id) { return ((AG.roles && AG.roles.workers) || []).find((w) => w.id === id) || null; }

// ------------------------------------------------- session → card mapping -----
function cardIdsForSession(s) {
  const out = [];
  if (s.kind === "origin" || s.id === "origin") { out.push("origin"); return out; }
  const role = String(s.role || "");
  if (s.kind === "planner" || role === "planner") out.push("planner");
  else if (s.kind === "integration" || role === "integration-worker") out.push("integration-worker");
  else if (s.kind === "audit") { if (role === "session-decider" || role === "decider") out.push("decider"); else out.push("auditor"); }
  else if (role === "recovery-worker") out.push("recovery-worker");
  else if (role === "session-decider" || role === "decider") out.push("decider");
  else if (s.kind === "worker" || role === "l2-developer") out.push("developer");
  // a run with a paired reviewer also counts toward the reviewer card
  if (s.sessionMeta && s.sessionMeta.reviewer) out.push("reviewer");
  return out;
}
function sessionsForCard(id) {
  return AG.sessions.filter((s) => cardIdsForSession(s).includes(id))
    .sort((a, b) => String(b.updatedAt || "").localeCompare(String(a.updatedAt || "")));
}
function liveCountForCard(id) { return sessionsForCard(id).filter((s) => s.live).length; }

// snapshot-derived binding: is this role currently bound/active (not just live)?
function cardBound(id) {
  const ag = (S.snap && S.snap.agents) || {};
  if (id === "origin") { const l0 = ag.l0; return !!l0 && l0.state === "active" && !l0.stop; }
  if (id === "planner" || id === "integration-worker") return (ag.l1 || []).some((a) => a.l1Active || a.l1Lease);
  if (id === "developer" || id === "recovery-worker") return (ag.l2 || []).some((t) => t.state === "active" || (t.leaseStatus && t.leaseStatus !== "none"));
  return liveCountForCard(id) > 0;
}
function cardActive(id) { return liveCountForCard(id) > 0 || cardBound(id); }

// current-work rows for a card (≤3)
function cardWork(id) {
  const ag = (S.snap && S.snap.agents) || {};
  const rows = [];
  if (id === "planner" || id === "integration-worker") {
    for (const a of (ag.l1 || [])) if (a.l1Active) rows.push({ label: a.area, state: "active" });
  } else if (id === "developer" || id === "recovery-worker") {
    for (const t of (ag.l2 || [])) if (t.state === "active" || t.state === "blocked" || t.state === "failed") rows.push({ label: t.title || t.id || t.area, state: t.state });
  }
  // fall back to (or augment with) live sessions' idents
  for (const s of sessionsForCard(id)) {
    if (!s.live) continue;
    const label = s.taskId || s.node || s.area || shortRun(s.runId);
    if (label && !rows.some((r) => r.label === label)) rows.push({ label, state: s.state });
  }
  return rows.slice(0, 3);
}

// model chip text for a card (from /api/config)
function cardConfigRole(card) { return card.configRole; }
function cardModel(card) {
  const role = cardConfigRole(card);
  if (!role || !AG.config || !AG.config.roles) return null;
  const r = AG.config.roles[role];
  if (!r || !r.model) return null;
  return r.effort ? r.model + " · " + r.effort : r.model;
}
function lastActivity(id) {
  const list = sessionsForCard(id);
  return list.length ? relTime(list[0].updatedAt, AG.generatedAt) : "—";
}

// --------------------------------------------------------------- glyph --------
function statusGlyph(id) {
  if (liveCountForCard(id) > 0) return `<span class="ag-glyph ag-glyph-run" title="running">◔</span>`;
  if (cardBound(id)) return `<span class="ag-glyph ag-glyph-on" title="active"><span class="tone-dot" data-tone="success"></span></span>`;
  return `<span class="ag-glyph ag-glyph-idle" title="idle"></span>`;
}

// ------------------------------------------------------------ level 1 grid ----
function cardHtml(card) {
  const active = cardActive(card.id);
  const running = liveCountForCard(card.id);
  const work = cardWork(card.id);
  const model = cardModel(card);
  const workRows = work.map((w) =>
    `<div class="ag-work-row"><span class="tone-dot" data-tone="${esc(toneForState(w.state))}"></span><span class="mono ag-work-id">${esc(w.label)}</span></div>`).join("");
  return `<button class="ag-card" data-role="${escAttr(card.id)}" data-active="${active}" aria-label="${escAttr(card.name)} role — ${active ? "active" : "idle"}">
    <div class="ag-avatar-wrap">
      <span class="ag-avatar" data-tone="${card.tone}">${esc(card.initials)}</span>
      <span class="ag-avatar-glyph">${statusGlyph(card.id)}</span>
    </div>
    <span class="co-eyebrow ag-eyebrow">${esc(card.eyebrow)}</span>
    <span class="ag-name">${esc(card.name)}</span>
    <span class="ag-pill" data-active="${active}">${active ? "active" : "idle"}${running ? ` · ${running} running` : ""}</span>
    ${workRows ? `<div class="ag-work">${workRows}</div>` : ""}
    ${model ? `<span class="ag-model mono">${esc(model)}</span>` : ""}
    <span class="ag-lastact mono">${esc(lastActivity(card.id))} ago</span>
  </button>`;
}

function toneForState(state) {
  const st = String(state || "");
  // `rejected` is a planner-batch disposition — red, not green (see STATE_TONE).
  if (st === "failed" || st === "blocked" || st === "rejected") return "error";
  if (st === "awaiting" || st === "stale") return "warn";
  if (st === "active") return "active";
  if (st === "integrated" || st === "accepted") return "success";
  return "idle";
}

function declaredHtml(id) {
  const w = workerCatalog(id);
  const name = w ? (w.label || w.id) : id;
  return `<div class="ag-declared-tile" title="declared role — no runtime evidence"><span class="ag-declared-initials">${esc((name || "").slice(0, 2).toUpperCase())}</span><span class="ag-declared-name">${esc(name)}</span></div>`;
}

function renderGrid() {
  const host = document.getElementById("ag-body");
  if (!host) return;
  host.innerHTML =
    `<div class="ag-surface-head">
       <span class="co-eyebrow">agent roles</span>
       <span class="ag-head-actions">
         <button class="insp-raw-btn" data-ag-rawconfig="1" title="view source · singular.config.json">{ }<span class="irb-label">config</span></button>
         <button class="secondary-button compact ag-sys-btn" id="ag-sys-btn" title="Edit all orchestration settings">${icon("i-cpu")}System settings</button>
       </span>
     </div>
     <div class="ag-grid" id="ag-grid">${CARDS.map(cardHtml).join("")}</div>
     <div class="ag-declared">
       <div class="co-eyebrow">declared roles</div>
       <div class="ag-declared-row">${DECLARED_ONLY.map(declaredHtml).join("")}</div>
     </div>`;
}

// ------------------------------------------------------------ level 2 detail --
function detailHtml(card) {
  const w = workerCatalog(card.id);
  const layer = (AG.roles && AG.roles.layers || []).find((l) => card.eyebrow.startsWith(l.id));
  const contract = (w && (w.summary || (w.disciplines || []).join(" · "))) || (layer && layer.summary) || "";
  const active = cardActive(card.id);
  const running = liveCountForCard(card.id);
  const tools = (w && w.typicalTools) || [];
  const writes = w && w.writes;

  // processes: live first, then recent, ≤6
  const procs = sessionsForCard(card.id).sort((a, b) => (b.live - a.live) || String(b.updatedAt || "").localeCompare(String(a.updatedAt || ""))).slice(0, 6);
  const procRows = procs.map((s) => {
    const glyph = s.live ? `<span class="ag-glyph ag-glyph-run">◔</span>` : `<span class="tone-dot" data-tone="${esc(toneForState(s.state))}"></span>`;
    const model = s.model ? `<span class="ag-proc-model mono">${esc(s.model)}${s.effort ? " · " + esc(s.effort) : ""}</span>` : "";
    const tail = s.exitCode != null ? `exit ${esc(s.exitCode)}` : relTime(s.updatedAt, AG.generatedAt) + " ago";
    const hi = AG.highlightSession && AG.highlightSession === s.id ? " ag-proc-hi" : "";
    const rpf = runPromptFile(s);
    const promptChip = rpf ? `<span class="ag-proc-prompt" data-ag-run-prompt="${escAttr(s.id)}" data-ag-run-promptfile="${escAttr(rpf)}" role="button" tabindex="0" title="view the rendered prompt for this run">${icon("i-file")}prompt</span>` : "";
    return `<div class="ag-proc-row${hi}" data-ag-proc="${escAttr(s.id)}" role="button" tabindex="0" aria-label="open console for ${escAttr(s.taskId || shortRun(s.runId) || s.id)}">
      ${glyph}
      <span class="mono ag-proc-id">${esc(s.taskId || s.node || s.area || shortRun(s.runId) || s.id)}</span>
      ${s.phase ? `<span class="ag-proc-phase">${esc(s.phase)}</span>` : ""}
      ${model}
      ${promptChip}
      <span class="ag-proc-tail mono">${esc(tail)}</span>
      ${icon("i-chev", "ag-proc-chev")}
    </div>`;
  }).join("") || `<div class="section-empty">no processes recorded</div>`;

  // settings editor (or read-only fallback)
  const settings = settingsHtml(card);

  // role prompt template (from the prompt library)
  const pf = promptFileForCard(card);
  const promptSection = pf
    ? `<section class="ag-section"><div class="co-eyebrow">prompt</div>
        <button class="secondary-button ag-prompt-btn" data-ag-role-prompt="${escAttr(pf)}">${icon("i-file")}view role prompt<span class="ag-prompt-name mono">${esc(pf)}</span></button></section>`
    : "";

  return `
    <nav class="ag-breadcrumb"><button class="ag-crumb" data-ag-back="1">Agents</button><span class="ag-crumb-sep">/</span><span class="ag-crumb-cur">${esc(card.name)}</span></nav>
    <div class="ag-detail-head">
      <span class="ag-avatar ag-avatar-lg" data-tone="${card.tone}">${esc(card.initials)}</span>
      <div class="ag-detail-idn">
        <span class="co-eyebrow">${esc(card.eyebrow)}</span>
        <div class="ag-detail-title"><span class="ag-detail-name">${esc(card.name)}</span><span class="ag-pill" data-active="${active}">${active ? "active" : "idle"}${running ? ` · ${running} running` : ""}</span></div>
        ${contract ? `<p class="ag-contract">${esc(contract)}</p>` : ""}
        <div class="ag-idn-meta">
          ${tools.length ? `<span class="ag-tools">${tools.map((t) => `<span class="ag-tool mono">${esc(t)}</span>`).join("")}</span>` : ""}
          ${writes != null ? `<span class="ag-writes" data-writes="${!!writes}">${writes ? "writes" : "read-only"}</span>` : ""}
        </div>
      </div>
    </div>
    <section class="ag-section"><div class="co-eyebrow">processes · ${procs.length}</div><div class="ag-procs">${procRows}</div></section>
    ${promptSection}
    <section class="ag-section"><div class="co-eyebrow">settings</div>${settings}</section>`;
}

// The role's editable knobs: model + effort (from /api/config source env keys),
// plus its limits for cards that own them. maxDispatch is derived (read-only).
function roleSettingRows(card) {
  const rows = [];
  const role = cardConfigRole(card);
  if (role && AG.config && AG.config.roles && AG.config.roles[role]) {
    const r = AG.config.roles[role]; const src = r.source || {};
    if (src.model) rows.push({ envKey: src.model, label: "model", value: r.model || "", kind: "model", provider: AG.config.provider });
    if (src.effort) rows.push({ envKey: src.effort, label: "effort", value: r.effort || "", kind: "reasoning", options: effortOptions(r.model) });
  }
  if (card.limits && AG.config && AG.config.limits) {
    const L = AG.config.limits;
    if (L.maxConcurrent != null) rows.push({ envKey: "SINGULAR_MAX_CONCURRENT", label: "max concurrent", value: String(L.maxConcurrent), kind: "count" });
    if (L.l1Parallel != null) rows.push({ envKey: "SINGULAR_MAX_L1_CONCURRENT", label: "l1 parallel", value: String(L.l1Parallel), kind: "count" });
    if (L.maxDispatch != null) rows.push({ envKey: "SINGULAR_MAX_DISPATCH", label: "dispatch / cycle", value: String(L.maxDispatch), kind: "derived", meaning: "follows max concurrent" });
  }
  return rows.filter((r) => r.envKey);
}

// The role-detail Settings section: editable editor, or a read-only fallback +
// copy-command affordance when the server has no writable settings API.
function settingsHtml(card) {
  const rows = roleSettingRows(card);
  if (!rows.length) return `<div class="section-empty">no model settings for this role</div>`;
  if (AG.settingsUnavailable) return settingsReadOnlyHtml(rows);
  return renderSettingEditor(rows, { editorId: "role-" + card.id });
}

// Read-only fallback (old servers): value + env key + copy-the-line button.
function settingsReadOnlyHtml(rows) {
  const body = rows.map((r) =>
    `<div class="ag-set-row"><span class="ag-set-key">${esc(r.label)}</span><span class="ag-set-val mono">${esc(r.value)}</span>
      <button class="ag-set-copy" data-ag-copy="${escAttr(r.envKey + "=" + r.value)}" title="copy ${escAttr(r.envKey)}"><code class="ag-set-src mono">${esc(r.envKey)}</code>${icon("i-copy")}</button></div>`).join("");
  return `<div class="ag-settings">${body}</div><div class="ag-set-foot">read-only · export the env line or edit singular.config.json</div>`;
}

// ---- shared typed settings editor (role detail + System panel) ----------------
function settingFieldHtml(row) {
  const dv = row.value == null ? "" : String(row.value);
  const common = `data-envkey="${escAttr(row.envKey)}" data-kind="${escAttr(row.kind)}" data-baseline="${escAttr(dv)}"`;
  if (row.kind === "derived") return `<input class="ag-set-input" disabled value="${escAttr(dv)}" ${common}>`;
  if (row.kind === "bool") { const on = dv === "1" || dv === "on" || dv === "true"; return `<button type="button" class="ag-set-toggle" role="switch" aria-checked="${on}" data-value="${on ? "1" : "0"}" ${common}><span class="ag-toggle-knob"></span></button>`; }
  if (row.kind === "reasoning" || row.kind === "enum") {
    let opts = row.options || (row.kind === "reasoning" ? REASONING_ALL : (ENUM_OPTIONS[row.envKey] || []));
    if (dv && !opts.includes(dv)) opts = [dv, ...opts];
    return `<span class="select-wrap"><select class="ag-set-input filter" ${common}>${opts.map((o) => `<option value="${escAttr(o)}"${o === dv ? " selected" : ""}>${esc(o)}</option>`).join("")}</select><span class="chev">${icon("i-chev")}</span></span>`;
  }
  if (row.kind === "model") {
    const opts = modelOptions(modelProvider(row), dv);
    return `<span class="select-wrap"><select class="ag-set-input filter mono" aria-label="${escAttr(row.label || "model")}" ${common}>${opts.map((o) => `<option value="${escAttr(o)}"${o === dv ? " selected" : ""}>${esc(o || "CLI default")}</option>`).join("")}</select><span class="chev">${icon("i-chev")}</span></span>`;
  }
  if (row.kind === "count" || row.kind === "duration" || row.kind === "bytes")
    return `<span class="ag-set-num"><input class="ag-set-input" type="number" min="0" step="1" value="${escAttr(dv)}" ${common}>${row.unit ? `<span class="ag-set-unit">${esc(row.unit)}</span>` : ""}</span>`;
  return `<input class="ag-set-input" value="${escAttr(dv)}" ${common}>`;   // identifier / other
}

function settingRowHtml(row, keyBody, className) {
  const meaning = row.meaning ? `<span class="ag-set-meaning">${esc(row.meaning)}</span>` : "";
  const derived = row.kind === "derived" ? ' data-derived="1"' : "";
  const classes = `ag-set-erow${className ? " " + className : ""}`;
  const key = keyBody || `<span class="ag-set-elabel">${esc(row.label)}</span>${meaning}<code class="ag-set-env mono">${esc(row.envKey)}</code>`;
  return `<div class="${classes}"${derived}>
    <div class="ag-set-erow-key">${key}</div>
    <div class="ag-set-erow-val">${settingFieldHtml(row)}<span class="ag-set-dirty" title="unsaved" hidden></span></div>
  </div>`;
}

function settingEditorHtml(body, opts, className) {
  const id = (opts && opts.editorId) || "ed";
  return `<div class="ag-set-editor${className ? " " + className : ""}" data-editor="${escAttr(id)}">
    ${body}
    <div class="ag-set-editor-foot"><span class="ag-set-hint" hidden>unsaved changes</span><button class="primary-button compact ag-set-save" type="button" data-ag-save="${escAttr(id)}" disabled>Save</button></div>
  </div>`;
}

function renderSettingEditor(rows, opts) {
  if (!rows.length) return `<div class="section-empty">no editable settings</div>`;
  return settingEditorHtml(rows.map((row) => settingRowHtml(row)).join(""), opts);
}

// The models group is one shared model/tier followed by per-role reasoning.
// Keep it one editor so the existing dirty, validation and POST paths remain the
// single write path; lookups by env key make the layout robust to spec ordering.
function renderRoleMatrix(rows, opts) {
  const byKey = new Map(rows.map((row) => [row.envKey, row]));
  const used = new Set();
  const take = (key) => { const row = byKey.get(key); if (row) used.add(key); return row; };
  const shared = [take("SINGULAR_CODEX_MODEL"), take("SINGULAR_CODEX_SERVICE_TIER")].filter(Boolean);
  const roles = [
    ["planner", "L1", take("SINGULAR_CODEX_PLANNER_REASONING_EFFORT")],
    ["worker", "L2", take("SINGULAR_CODEX_L2_REASONING_EFFORT")],
    ["auditor", "gate", take("SINGULAR_CODEX_AUDITOR_REASONING_EFFORT")],
  ].filter((entry) => entry[2]);
  const sharedBody = shared.map((row) => settingRowHtml(row)).join("");
  const roleBody = roles.map(([name, cap, row]) => {
    const meaning = row.meaning ? `<span class="ag-set-meaning">${esc(row.meaning)}</span>` : "";
    const key = `<span class="ag-role-matrix-role"><span>${esc(name)}</span><span class="ag-role-matrix-cap">${esc(cap)}</span></span>${meaning}<code class="ag-set-env mono">${esc(row.envKey)}</code>`;
    return settingRowHtml(row, key, "ag-role-matrix-row");
  }).join("");
  const extras = rows.filter((row) => !used.has(row.envKey));
  const body = `${sharedBody ? `<div class="ag-role-matrix-shared"><div class="ag-role-matrix-shared-head"><span>all roles</span><span>shared</span></div>${sharedBody}</div>` : ""}
    ${roleBody ? `<div class="ag-role-matrix-columns" aria-hidden="true"><span>role</span><span>reasoning</span></div>${roleBody}` : ""}
    ${extras.length ? `<div class="ag-role-matrix-extra">additional</div>${extras.map((row) => settingRowHtml(row)).join("")}` : ""}`;
  return body ? settingEditorHtml(body, opts, "ag-role-matrix") : `<div class="section-empty">no editable settings</div>`;
}

// value read helper (input/select vs toggle button)
function fieldValue(el) { return el.classList.contains("ag-set-toggle") ? el.dataset.value : el.value; }

// Recompute dirty state for one editor: toggle per-row dots, the Save button, the
// unsaved hint, and the global AG.editing freeze.
function refreshEditor(editorEl) {
  if (!editorEl) return;
  let dirty = 0;
  editorEl.querySelectorAll(".ag-set-input, .ag-set-toggle").forEach((el) => {
    if (el.disabled) return;
    const changed = fieldValue(el) !== (el.dataset.baseline || "");
    const dot = el.closest(".ag-set-erow-val") && el.closest(".ag-set-erow-val").querySelector(".ag-set-dirty");
    if (dot) dot.hidden = !changed;
    const invalid = changed && !validField(el);
    el.classList.toggle("is-invalid", invalid);
    if (changed && !invalid) dirty++;
  });
  const save = editorEl.querySelector(".ag-set-save"); if (save) save.disabled = dirty === 0;
  const hint = editorEl.querySelector(".ag-set-hint"); if (hint) hint.hidden = dirty === 0;
  // Any editor with a change freezes the signature-gated re-render (protects input).
  AG.editing = anyEditorDirty();
}

function anyEditorDirty() {
  for (const el of document.querySelectorAll(".ag-set-input, .ag-set-toggle")) {
    if (!el.disabled && fieldValue(el) !== (el.dataset.baseline || "")) return true;
  }
  return false;
}

function validField(el) {
  const kind = el.dataset.kind, v = fieldValue(el);
  if (kind === "count") return /^\d+$/.test(v) && Number(v) >= 0;
  if (kind === "duration" || kind === "bytes") return v === "" || (/^\d+$/.test(v) && Number(v) >= 0);
  if (kind === "model") return v.trim().length > 0;
  return true;   // enum/reasoning/bool/identifier
}

function saveEditor(editorEl) {
  if (!editorEl) return;
  const changes = {};
  let bad = false;
  editorEl.querySelectorAll(".ag-set-input, .ag-set-toggle").forEach((el) => {
    if (el.disabled) return;
    const v = fieldValue(el);
    if (v === (el.dataset.baseline || "")) return;
    if (!validField(el)) { bad = true; el.classList.add("is-invalid"); return; }
    changes[el.dataset.envkey] = v;
  });
  if (bad) { toast("fix invalid fields before saving"); return; }
  if (!Object.keys(changes).length) return;
  const save = editorEl.querySelector(".ag-set-save"); if (save) { save.disabled = true; save.textContent = "Saving…"; }
  postSettings(changes, (ok) => {
    if (ok) { if (AG.sysOpen) renderSysPanel(); render(); }
    else if (save) { save.disabled = false; save.textContent = "Save"; }
  });
}

// ---- System settings panel (all 23 knobs, 4 groups) -------------------------
function renderSysPanel() {
  const body = document.getElementById("ag-sys-body");
  if (!body) return;
  if (AG.settingsUnavailable) { body.innerHTML = `<div class="section-empty">the settings API is unavailable on this server — settings are read-only.</div>`; return; }
  const s = AG.settings;
  if (!s) { body.innerHTML = loadingHtml("settings", "section-empty"); fetchSettings(); return; }
  body.innerHTML = (s.groups || []).map((g) => {
    const rows = (g.items || []).map((it) => ({
      envKey: it.envKey || it.key, label: it.label, value: it.value, kind: it.kind, unit: it.unit, meaning: it.meaning,
      options: it.kind === "reasoning" ? REASONING_ALL : (ENUM_OPTIONS[it.envKey || it.key] || null),
    }));
    const opts = { editorId: "sys-" + String(g.title || "g").replace(/\W+/g, "") };
    const editor = g.layout === "matrix" ? renderRoleMatrix(rows, opts) : renderSettingEditor(rows, opts);
    return `<section class="ag-sys-group"><div class="co-eyebrow">${esc(g.title || g.category)}</div>${editor}</section>`;
  }).join("") || `<div class="section-empty">no settings</div>`;
}

function openSysPanel() { AG.sysOpen = true; const p = document.getElementById("ag-sys-panel"); if (p) p.hidden = false; fetchSettings(); renderSysPanel(); }
function closeSysPanel() { AG.sysOpen = false; AG.editing = false; const p = document.getElementById("ag-sys-panel"); if (p) p.hidden = true; }

// ------------------------------------------------------------- render ---------
function signature() {
  const sessSig = AG.sessions.map((s) => [s.id, s.state, s.live, s.updatedAt, s.model]).join("|");
  const snapSig = JSON.stringify((S.snap && S.snap.agents) ? { l0: (S.snap.agents.l0 || {}).state, l1: (S.snap.agents.l1 || []).map((a) => [a.area, a.l1Active]), l2: (S.snap.agents.l2 || []).length } : null);
  const cfgSig = AG.config ? AG.config.generatedAt : "nc";
  return [AG.level, AG.roleId, AG.highlightSession, sessSig, snapSig, cfgSig, AG.roles ? 1 : 0, AG.prompts ? 1 : 0].join("::");
}

function render() {
  if (!AG.visible) return;
  if (AG.editing) return;   // never wipe an in-progress settings edit under a poll
  const sig = signature();
  if (sig === AG.sig) return;
  AG.sig = sig;
  const host = document.getElementById("ag-body");
  if (!host) return;
  if (AG.level === 2 && AG.roleId && CARD_BY_ID[AG.roleId]) {
    host.innerHTML = detailHtml(CARD_BY_ID[AG.roleId]);
  } else {
    renderGrid();
  }
}

// ------------------------------------------------------------- nav ------------
function openRole(id, opts) {
  if (!CARD_BY_ID[id]) return;
  AG.level = 2; AG.roleId = id;
  AG.highlightSession = (opts && opts.session) || null;
  AG.sig = null;
  if (!opts || opts.route !== false) writeRoute("agents", id, AG.highlightSession || null, null);
  render();
}
function backToGrid() {
  AG.level = 1; AG.roleId = null; AG.highlightSession = null; AG.sig = null;
  writeRoute("agents", null, null, null);
  render();
}
function jumpToConsole(sessionId) {
  // Level 3 is a JUMP: push a Consoles deep link (new history entry so browser-back
  // returns to this #agents/<role> detail). The router opens it pinned + soloed.
  location.hash = "#consoles/" + sessionId;
}

// ------------------------------------------------------------- feed -----------
function onFeed(state) {
  AG.sessions = state.sessions || [];
  AG.byId = state.byId || new Map(AG.sessions.map((s) => [s.id, s]));
  AG.generatedAt = state.generatedAt || null;
  render();
}

// ------------------------------------------------------------- mount ----------
function mount() {
  const surf = document.getElementById("surface-agents");
  if (!surf) return;
  surf.innerHTML = "";
  surf.classList.add("ag-surface");
  surf.innerHTML = `<div class="ag-body" id="ag-body"></div>
    <div class="ag-sys-panel" id="ag-sys-panel" hidden>
      <div class="ag-sys-scrim" data-ag-sys-close="1"></div>
      <div class="ag-sys-sheet" role="dialog" aria-label="System settings">
        <div class="ag-sys-head"><span class="ag-sys-title">System settings</span><span class="ag-sys-sub">all orchestration knobs · POST /api/settings</span>
          <button class="ag-sys-x" data-ag-sys-close="1" title="Close">${icon("i-stop")}</button></div>
        <div class="ag-sys-body" id="ag-sys-body"></div>
      </div>
    </div>`;
  surf.addEventListener("click", (e) => {
    const back = e.target.closest("[data-ag-back]");
    if (back) { backToGrid(); return; }
    if (e.target.closest("[data-ag-sys-close]")) { closeSysPanel(); return; }
    if (e.target.closest("#ag-sys-btn")) { openSysPanel(); return; }
    if (e.target.closest("[data-ag-rawconfig]")) { viewRaw("config", "singular.config.json", "singular.config.json"); return; }
    const copyBtn = e.target.closest("[data-ag-copy]");
    if (copyBtn) { try { navigator.clipboard.writeText(copyBtn.dataset.agCopy); toast("copied " + copyBtn.dataset.agCopy); } catch (x) { toast("copy unavailable"); } return; }
    const save = e.target.closest("[data-ag-save]");
    if (save) { saveEditor(save.closest(".ag-set-editor")); return; }
    const tgl = e.target.closest(".ag-set-toggle");
    if (tgl) { const on = tgl.dataset.value === "1"; tgl.dataset.value = on ? "0" : "1"; tgl.setAttribute("aria-checked", String(!on)); refreshEditor(tgl.closest(".ag-set-editor")); return; }
    const rolePrompt = e.target.closest("[data-ag-role-prompt]");
    if (rolePrompt) { viewPrompt(rolePrompt.dataset.agRolePrompt); return; }
    const runPrompt = e.target.closest("[data-ag-run-prompt]");
    if (runPrompt) { e.stopPropagation(); viewSessionPrompt(runPrompt.dataset.agRunPrompt, runPrompt.dataset.agRunPromptfile, runPrompt.dataset.agRunPrompt); return; }
    const proc = e.target.closest("[data-ag-proc]");
    if (proc) { jumpToConsole(proc.dataset.agProc); return; }
    const card = e.target.closest(".ag-card");
    if (card && card.dataset.active !== undefined) { openRole(card.dataset.role); return; }
  });
  // typed inputs (text/number/select) → recompute dirty on every edit
  surf.addEventListener("input", (e) => { const ed = e.target.closest && e.target.closest(".ag-set-editor"); if (ed) refreshEditor(ed); });
  surf.addEventListener("change", (e) => { const ed = e.target.closest && e.target.closest(".ag-set-editor"); if (ed) refreshEditor(ed); });
  // keyboard activation for role="button" rows/chips (a11y)
  surf.addEventListener("keydown", (e) => {
    if (e.key !== "Enter" && e.key !== " ") return;
    const t = e.target.closest && e.target.closest("[data-ag-run-prompt], [data-ag-proc]");
    if (t) { e.preventDefault(); t.click(); }
  });
}

// ------------------------------------------------------------- exports --------
export function initAgents() {
  if (AG.started) return; AG.started = true;
  mount();
  subscribeSessions(onFeed, () => AG.visible);
}

export function setAgentsActive(on) {
  AG.visible = on;
  if (on) {
    ensureRoles();
    fetchConfig(false);
    fetchPrompts();
    if (!AG.settingsProbed) fetchSettings(false);   // feature-probe once
    AG.sig = null;
    onFeed(feedState());
    render();
  }
}

// Router hook — #agents[/<roleId>[/<sessionId>]]
export function agentsRoute(route) {
  const role = route && route.role;
  const session = route && route.session;
  if (role && CARD_BY_ID[role]) openRole(role, { session, route: false });
  else backToGridSilent();
}
function backToGridSilent() { AG.level = 1; AG.roleId = null; AG.highlightSession = null; AG.sig = null; render(); }

// Called from the 10s snapshot dispatcher (via main.js) — signature-gated, and a
// no-op while hidden. On Refresh the config is re-pulled.
export function agentsTick() {
  if (!AG.visible) return;
  fetchConfig(false);   // module-cached; loaded once
  render();
}
