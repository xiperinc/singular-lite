/* providers/surface.js — the Providers surface (0.9.0 phase F).

   The 5th surface: a runtime status board over GET /api/providers
   (singular.providers.v0). One card per agent-CLI provider (claude · codex ·
   gemini · opencode · cursor · grok) showing installed/auth status, the login
   affordance when signed out, its env-key presence, the singular integration
   (runner script + default badge + roles + last-use + session count), an
   editable per-provider model knob (POST /api/settings → SINGULAR_<P>_MODEL) and
   a "Use as default runner" action (POST SINGULAR_RUNNER).

   Data: /api/providers (60s cache; ?refresh=1 forces a re-probe) drives the
   cards; the current model values come from the raw singular.config.json env{}
   (via /api/raw/config — the authoritative layer the settings POST writes to).
   Live-only, exactly like Agents: the router redirects #providers → #home in
   historical mode and plans.js disables the nav button. The render is
   signature-gated and frozen while a model input is dirty or a default-runner
   confirm is open, so a 60s poll never wipes an in-progress edit.

   Follows agents/surface.js structure: a state object, signature(), a single
   innerHTML render into #pv-body, delegated click/input handling, mount()
   wiring, a visibility-gated poll timer, and a 404 feature-probe degradation. */

import { esc, escAttr, icon, relTime, toast } from "../app.js";
import { apiFetch, isHistorical, onRecover } from "../core/api.js";
import { loadingHtml } from "../core/health.js";
import { MODEL_VOCABULARY, modelOptions } from "../core/models.js";

const POLL_MS = 60000;   // cache-aligned with the server's 60s providers TTL

// The flat model env key each provider's knob binds to (mirrors the server's
// _CONFIG_MODEL_FALLBACK). claude/codex own per-role keys on the Agents surface;
// this knob is the provider-wide default model.
const MODEL_KEY = {
  claude: "SINGULAR_CLAUDE_MODEL",
  codex: "SINGULAR_CODEX_MODEL",
  gemini: "SINGULAR_GEMINI_MODEL",
  opencode: "SINGULAR_OPENCODE_MODEL",
  cursor: "SINGULAR_CURSOR_MODEL",
  grok: "SINGULAR_GROK_MODEL",
};

// status → pm-go status tone. missing renders a dashed, de-emphasised card.
const STATUS_TONE = { ready: "success", warning: "warn", error: "error", missing: "idle" };

const PV = {
  started: false,
  visible: false,
  data: null,            // last /api/providers payload
  inflight: false,
  unavailable: false,    // 404 → server too old for /api/providers
  probed: false,
  timer: null,
  configEnv: null,       // parsed singular.config.json env{} (current model values)
  configInflight: false,
  selected: null,        // deep-link #providers/<id> highlight
  pendingScroll: false,  // scroll the selected card into view after the next render
  editing: false,        // a model input is dirty → freeze poll re-renders
  confirmDefault: null,  // provider id with an open "use as default" inline confirm
  sig: null,
};

const providerById = (id) => (PV.data && (PV.data.providers || []).find((p) => p.id === id)) || null;
const cssEsc = (s) => (window.CSS && CSS.escape ? CSS.escape(s) : String(s).replace(/["\\]/g, "\\$&"));
const cardEl = (id) => document.querySelector(`.pv-card[data-provider="${cssEsc(id)}"]`);
const shortKey = (k) => String(k || "").replace(/^SINGULAR_/, "").toLowerCase().replace(/_/g, " ");

// ------------------------------------------------------------- data fetch -----
async function fetchProviders(refresh) {
  if (PV.inflight || isHistorical()) return;
  PV.inflight = true;
  try {
    const res = await apiFetch("/api/providers" + (refresh ? "?refresh=1" : ""), { cache: "no-store" });
    if (res.status === 404 || res.status === 501) { PV.unavailable = true; }
    else if (res.ok) { PV.data = await res.json(); PV.unavailable = false; }
  } catch (e) { /* keep last good; a transient miss must not blank the board */ }
  finally { PV.probed = true; PV.inflight = false; render(); }
}

// The current per-provider model values live in singular.config.json env{} — the
// authoritative layer POST /api/settings writes to. /api/config only resolves the
// active provider's roles, so we read the raw config env directly (the same
// record the Agents "{}" config button opens).
async function fetchConfigEnv() {
  if (PV.configInflight || isHistorical()) return;
  PV.configInflight = true;
  try {
    const res = await apiFetch("/api/raw/config/singular.config.json", { cache: "no-store" });
    if (res.ok) {
      const raw = await res.json();
      const obj = JSON.parse(raw.content || "{}");
      PV.configEnv = (obj && typeof obj.env === "object" && obj.env) || {};
    }
  } catch (e) { /* leave last good; the knob just shows a placeholder */ }
  finally { PV.configInflight = false; if (!PV.editing) { PV.sig = null; render(); } }
}

// POST changes to /api/settings (live-only — plain fetch, never apiFetch, so the
// ?plan= param is never attached). Mirrors the Agents write path's toasts.
async function postSettings(changes, done) {
  try {
    const res = await fetch("/api/settings", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ changes }) });
    if (res.status === 404 || res.status === 405 || res.status === 501) { toast("settings are read-only on this server"); done && done(false); return; }
    const data = await res.json().catch(() => ({}));
    if (!res.ok) { toast(data.error ? String(data.error) : "save failed · " + res.status); done && done(false); return; }
    const at = data.appliesAt || {};
    const note = Object.keys(changes).map((k) => `${shortKey(k)} → ${at[k] || "applied"}`).join(" · ");
    toast(note || "settings saved");
    done && done(true, data);
  } catch (e) { toast("save failed"); done && done(false); }
}

// ------------------------------------------------------------- card html ------
function authLineHtml(p) {
  if (p.authStatus === "authenticated") {
    let txt;
    if (p.email && p.plan) txt = `${p.email} · ${p.plan}`;
    else if (p.email) txt = p.email;
    else if (p.plan) txt = p.plan;
    else txt = p.authMethod || "authenticated";
    return `<div class="pv-auth" data-ok="true"><span class="pv-auth-glyph">${icon("i-check")}</span><span class="pv-auth-text">${esc(txt)}</span></div>`;
  }
  // unauthenticated / unknown → the human message + a copy chip for the login command
  const login = p.loginCommand
    ? `<button class="copy-btn pv-login-copy" data-copy="${escAttr(p.loginCommand)}" title="copy login command"><code class="mono">${esc(p.loginCommand)}</code>${icon("i-copy")}</button>`
    : "";
  return `<div class="pv-auth" data-ok="false"><span class="pv-auth-text">${esc(p.message || "not authenticated")}</span>${login}</div>`;
}

function envRowHtml(p) {
  const keys = p.envKeys || [];
  if (!keys.length) return "";
  const chips = keys.map((k) => {
    const present = !!(p.envKeyPresent && p.envKeyPresent[k]);
    return `<span class="pv-env" data-present="${present}" title="${escAttr(k + (present ? " is set" : " not set"))}"><span class="pv-env-dot"></span><code class="mono">${esc(k)}</code></span>`;
  }).join("");
  return `<div class="pv-env-row">${chips}</div>`;
}

function integrationHtml(p) {
  const runner = p.runnerScript || "—";
  const runnerBlock = p.runnerPresent
    ? `<code class="mono pv-runner">${esc(runner)}</code>${p.isDefaultRunner ? `<span class="pv-default-badge">default runner</span>` : ""}`
    : `<code class="mono pv-runner pv-runner-off">${esc(runner)}</code><span class="pv-runner-note">no runner script</span>`;
  const roles = (p.roles || []).length
    ? (p.roles || []).map((r) => `<span class="pv-role mono">${esc(r)}</span>`).join("")
    : `<span class="pv-role-none">no roles bound</span>`;
  const exit = p.lastExitCode == null ? ""
    : (p.lastExitCode === 0
        ? `<span class="pv-exit" data-ok="true" title="last exit 0">${icon("i-check")}</span>`
        : `<span class="pv-exit" data-ok="false" title="last exit ${escAttr(p.lastExitCode)}">✕</span>`);
  const lastUsed = p.lastUsedAt ? relTime(p.lastUsedAt, (PV.data && PV.data.checkedAt) || null) + " ago" : "never";
  const sessions = `${p.recentSessions != null ? p.recentSessions : 0}`;
  return `<div class="pv-int">
    <div class="pv-int-row"><span class="pv-int-label">runner</span><span class="pv-int-val">${runnerBlock}</span></div>
    <div class="pv-int-row"><span class="pv-int-label">roles</span><span class="pv-int-val pv-roles">${roles}</span></div>
    <div class="pv-int-row"><span class="pv-int-label">activity</span><span class="pv-int-val pv-activity">
      <span class="pv-lastused mono">${esc(lastUsed)}</span>${exit}
      <span class="pv-sessions mono" title="${escAttr(sessions + " recent sessions")}">${esc(sessions)} sessions</span>
    </span></div>
  </div>`;
}

// The subscription-quota block (0.10.0). Codex exposes real headless usage → a
// gauge (usedPercent bar, tone warn ≥75 / error ≥90, window label + reset
// countdown + planType chip + a stale hint when the rollout is >2h old). Authed
// CLIs without a headless usage endpoint (cursor/claude → tier-only/not-exposed)
// get a one-line "tier · quota not exposed by CLI". Everything else renders
// nothing (cli-missing, no rollout data, parse error). Between integration + knob.
function quotaBlockHtml(p) {
  const q = p.quota;
  if (!q) return "";
  if (q.available) {
    const pct = Math.max(0, Math.round(q.usedPercent || 0));
    const tone = pct >= 90 ? "error" : pct >= 75 ? "warn" : "";
    const meta = [windowLabel(q.windowMinutes), resetsIn(q.resetsAt), q.planType]
      .filter(Boolean).map((m) => `<span>${esc(m)}</span>`).join(`<span class="pvq-dot">·</span>`);
    const stale = (q.staleSeconds || 0) > 7200 ? `stale ${Math.round(q.staleSeconds / 3600)}h` : "";
    const sec = (q.secondary && q.secondary.usedPercent != null)
      ? `<span class="pvq-track pvq-track-sec" title="secondary window ${escAttr(Math.round(q.secondary.usedPercent) + "%")}"><span class="pvq-fill" style="width:${Math.max(0, Math.round(q.secondary.usedPercent))}%"></span></span>` : "";
    return `<div class="pv-quota" data-tone="${tone}">
      <div class="pvq-head"><span class="pvq-label">subscription usage</span><span class="pvq-pct mono">${pct}%</span></div>
      <div class="pvq-tracks"><span class="pvq-track"><span class="pvq-fill" style="width:${pct}%"></span></span>${sec}</div>
      <div class="pvq-meta">${meta}${stale ? `<span class="pvq-dot">·</span><span class="pvq-stale">${esc(stale)}</span>` : ""}</div>
    </div>`;
  }
  if (q.reason === "tier-only" || q.reason === "not-exposed") {
    if (p.authStatus !== "authenticated") return "";
    const tier = p.plan ? `<span class="pvq-tierval">${esc(p.plan)}</span><span class="pvq-dot">·</span>` : "";
    return `<div class="pv-quota pv-quota-tier">${tier}<span class="pvq-tiernote">quota not exposed by CLI</span></div>`;
  }
  return "";   // cli-missing / no-rollout-data / rollout-parse-error → nothing
}

// window-minutes → a human label (10080 = the 7-day plan window).
function windowLabel(m) {
  if (m == null) return "";
  if (m === 10080) return "7-day";
  if (m % 1440 === 0) return (m / 1440) + "-day";
  if (m % 60 === 0) return (m / 60) + "h";
  return m + "m";
}

// Client-computed "resets in …" from epoch-seconds resetsAt (past → "resetting…").
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

function modelKnobHtml(p) {
  const key = MODEL_KEY[p.id];
  if (!key) return "";
  const cur = (PV.configEnv && PV.configEnv[key]) || "";
  const hasVocab = (MODEL_VOCABULARY[p.id] || []).length > 0;
  const vocab = modelOptions(p.id, cur).filter(Boolean);
  const listId = "pv-models-" + p.id;
  const placeholder = (p.id === "claude" || p.id === "codex") ? "model" : "CLI default";
  return `<div class="pv-model">
    <span class="pv-model-label">model</span>
    <input class="pv-model-input" type="text" ${hasVocab ? `list="${listId}"` : ""} data-pv-model="${escAttr(p.id)}" data-key="${escAttr(key)}" data-baseline="${escAttr(cur)}" value="${escAttr(cur)}" placeholder="${escAttr(placeholder)}" autocomplete="off" spellcheck="false">
    ${hasVocab ? `<datalist id="${listId}">${vocab.map((m) => `<option value="${escAttr(m)}"></option>`).join("")}</datalist>` : ""}
    <button class="primary-button compact pv-model-save" data-pv-model-save="${escAttr(p.id)}" disabled>Save</button>
    <code class="pv-model-key mono">${esc(key)}</code>
  </div>`;
}

// The default-runner action slot: current-default note, or the button (disabled
// with a reason when the runner script is absent or the CLI isn't installed).
function actionButtonHtml(p) {
  if (p.isDefaultRunner) return `<span class="pv-default-cur"><span class="tone-dot" data-tone="success"></span>current default runner</span>`;
  const ok = p.installed && p.runnerPresent;
  const why = !p.installed ? "not installed" : !p.runnerPresent ? "no runner script" : "";
  return `<button class="secondary-button pv-default-btn" data-pv-default="${escAttr(p.id)}"${ok ? "" : " disabled"}${why ? ` title="${escAttr(why)}"` : ""}>Use as default runner</button>`;
}
function confirmHtml(p) {
  return `<span class="pv-confirm">
    <span class="pv-confirm-text">Make ${esc(p.name)} the default runner?</span>
    <button class="primary-button compact pv-confirm-yes" data-pv-default-confirm="${escAttr(p.id)}">Confirm</button>
    <button class="secondary-button compact pv-confirm-no" data-pv-default-cancel="1">Cancel</button>
  </span>`;
}

function cardHtml(p) {
  const tone = STATUS_TONE[p.status] || "idle";
  const missing = p.status === "missing" || !p.installed;
  const selected = PV.selected === p.id;
  const version = p.version ? p.version : (missing ? "not installed" : "—");
  return `<article class="pv-card" data-provider="${escAttr(p.id)}" data-status="${escAttr(p.status || "")}" data-missing="${missing}" data-selected="${selected}" id="pv-card-${escAttr(p.id)}">
    <header class="pv-card-head">
      <span class="tone-dot pv-status-dot" data-tone="${tone}"></span>
      ${p.status && !missing ? `<span class="pv-status-word">${esc(p.status)}</span>` : ""}
      <span class="pv-name">${esc(p.name || p.id)}</span>
      <span class="pv-binary mono">${esc(p.binary || p.id)}</span>
      <span class="pv-version mono" data-missing="${missing}">${esc(version)}</span>
    </header>
    ${authLineHtml(p)}
    ${envRowHtml(p)}
    ${integrationHtml(p)}
    ${quotaBlockHtml(p)}
    ${modelKnobHtml(p)}
    <div class="pv-action">${actionButtonHtml(p)}</div>
  </article>`;
}

// ------------------------------------------------------------- header ---------
function summaryHtml(sum) {
  if (!sum) return "";
  const chip = (n, label, tone) => n ? `<span class="pv-sum-chip" data-tone="${tone}"><span class="tone-dot" data-tone="${tone}"></span>${n} ${label}</span>` : "";
  return `<span class="pv-summary">
    ${chip(sum.ready, "ready", "success")}
    ${chip(sum.warning, "warning", "warn")}
    ${chip(sum.error, "error", "error")}
    ${chip(sum.missing, "missing", "idle")}
  </span>`;
}

function headHtml(d) {
  const checked = d && d.checkedAt ? "checked " + relTime(d.checkedAt) + " ago" : "";
  return `<div class="pv-head">
    <div class="pv-head-main">
      <span class="co-eyebrow">providers</span>
      <div class="pv-head-title-row"><h1 class="pv-title">Providers</h1>${summaryHtml(d && d.summary)}</div>
    </div>
    <div class="pv-head-actions">
      ${checked ? `<span class="pv-checked mono">${esc(checked)}</span>` : ""}
      <button class="secondary-button compact pv-recheck" data-pv-recheck="1" title="re-probe every provider">${icon("i-refresh")}Recheck all</button>
    </div>
  </div>`;
}

// ------------------------------------------------------------- render ---------
function signature() {
  if (PV.unavailable) return "unavailable";
  const d = PV.data;
  if (!d) return "loading";
  const provSig = (d.providers || []).map((p) => {
    const q = p.quota || {};
    return [
      p.id, p.status, p.authStatus, p.email, p.plan, p.version, p.installed,
      p.isDefaultRunner, p.runnerPresent, (p.roles || []).join(","), p.lastUsedAt,
      p.lastExitCode, p.recentSessions, Object.values(p.envKeyPresent || {}).join(""),
      // quota fields (additive) — rounded % + fixed resetsAt + reason + a coarse
      // stale-threshold bit so the card repaints only on a real quota change.
      q.available, q.usedPercent != null ? Math.round(q.usedPercent) : "", q.resetsAt,
      q.reason, (q.staleSeconds || 0) > 7200,
    ].join("~");
  }).join("|");
  const envSig = PV.configEnv
    ? Object.keys(MODEL_KEY).map((id) => MODEL_KEY[id] + "=" + (PV.configEnv[MODEL_KEY[id]] || "")).join(",")
    : "noenv";
  return [d.checkedAt, provSig, envSig, PV.selected].join("::");
}

function render() {
  if (!PV.visible) return;
  if (PV.editing || PV.confirmDefault) return;   // never wipe an in-progress edit/confirm
  const host = document.getElementById("pv-body");
  if (!host) return;
  const sig = signature();
  if (sig === PV.sig) return;
  PV.sig = sig;
  if (PV.unavailable) {
    host.innerHTML = `<div class="pv-degraded">${headStub()}<div class="section-empty">server too old for /api/providers — update the console server to see provider status.</div></div>`;
    return;
  }
  const d = PV.data;
  if (!d) { host.innerHTML = loadingHtml("providers", "pv-loading"); return; }
  host.innerHTML = headHtml(d) + `<div class="pv-grid">${(d.providers || []).map(cardHtml).join("")}</div>`;
  if (PV.pendingScroll) scrollToSelected();
}
function headStub() { return `<div class="pv-head"><div class="pv-head-main"><span class="co-eyebrow">providers</span><div class="pv-head-title-row"><h1 class="pv-title">Providers</h1></div></div></div>`; }

function scrollToSelected() {
  const id = PV.selected;
  if (!id) { PV.pendingScroll = false; return; }
  requestAnimationFrame(() => {
    const el = cardEl(id);
    if (el) { el.scrollIntoView({ behavior: "smooth", block: "center" }); PV.pendingScroll = false; }
  });
}

// ------------------------------------------------------------- interactions ---
function anyModelDirty() {
  return [...document.querySelectorAll(".pv-model-input")].some((i) => i.value !== (i.dataset.baseline || ""));
}

function recheckAll() {
  // A pending confirm/edit is abandoned by an explicit recheck.
  PV.confirmDefault = null; PV.editing = false; PV.sig = null;
  const btn = document.querySelector("[data-pv-recheck]");
  if (btn) { btn.disabled = true; btn.classList.add("is-busy"); }
  Promise.all([fetchProviders(true), fetchConfigEnv()]).finally(() => {
    const b = document.querySelector("[data-pv-recheck]");
    if (b) { b.disabled = false; b.classList.remove("is-busy"); }
  });
}

function saveModel(id) {
  const card = cardEl(id);
  const inp = card && card.querySelector("[data-pv-model]");
  if (!inp) return;
  const key = inp.dataset.key;
  const val = inp.value.trim();
  const save = card.querySelector("[data-pv-model-save]");
  if (save) { save.disabled = true; save.textContent = "Saving…"; }
  postSettings({ [key]: val }, (ok) => {
    if (ok) {
      if (!PV.configEnv) PV.configEnv = {};
      if (val === "") delete PV.configEnv[key]; else PV.configEnv[key] = val;
      PV.editing = false; PV.sig = null; render();
    } else if (save) { save.disabled = false; save.textContent = "Save"; }
  });
}

function openConfirm(id) {
  const p = providerById(id);
  if (!p) return;
  PV.confirmDefault = id;
  const slot = cardEl(id) && cardEl(id).querySelector(".pv-action");
  if (slot) slot.innerHTML = confirmHtml(p);
}
function cancelConfirm() {
  const id = PV.confirmDefault;
  PV.confirmDefault = null;
  const p = id && providerById(id);
  const slot = id && cardEl(id) && cardEl(id).querySelector(".pv-action");
  if (slot && p) slot.innerHTML = actionButtonHtml(p);
}
function commitDefault(id) {
  const p = providerById(id);
  if (!p) { PV.confirmDefault = null; return; }
  postSettings({ SINGULAR_RUNNER: p.runnerScript }, (ok) => {
    PV.confirmDefault = null; PV.sig = null;
    if (ok && PV.data) {
      // Optimistic: the default runner is known the instant the write lands — move
      // the badge now instead of waiting on a full re-probe (a providers GET
      // re-runs every CLI auth probe, ~seconds). The background fetch below then
      // reconciles the roles[]/status the switch may also have shifted.
      for (const pr of (PV.data.providers || [])) pr.isDefaultRunner = (pr.id === id);
    }
    render();
    if (ok) fetchProviders();
  });
}

function onClick(e) {
  if (e.target.closest("[data-pv-recheck]")) { recheckAll(); return; }
  const save = e.target.closest("[data-pv-model-save]");
  if (save) { if (!save.disabled) saveModel(save.dataset.pvModelSave); return; }
  const yes = e.target.closest("[data-pv-default-confirm]");
  if (yes) { commitDefault(yes.dataset.pvDefaultConfirm); return; }
  if (e.target.closest("[data-pv-default-cancel]")) { cancelConfirm(); return; }
  const def = e.target.closest("[data-pv-default]");
  if (def) { if (!def.disabled) openConfirm(def.dataset.pvDefault); return; }
}
function onInput(e) {
  const inp = e.target.closest("[data-pv-model]");
  if (!inp) return;
  const dirty = inp.value !== (inp.dataset.baseline || "");
  const save = inp.closest(".pv-card").querySelector("[data-pv-model-save]");
  if (save) save.disabled = !dirty;
  PV.editing = anyModelDirty();
}
function onKeydown(e) {
  if (e.key !== "Enter") return;
  const inp = e.target.closest && e.target.closest("[data-pv-model]");
  if (inp) { e.preventDefault(); const save = inp.closest(".pv-card").querySelector("[data-pv-model-save]"); if (save && !save.disabled) saveModel(inp.dataset.pvModel); }
}

// ------------------------------------------------------------- mount ----------
function mount() {
  const surf = document.getElementById("surface-providers");
  if (!surf) return;
  surf.classList.add("pv-surface");
  surf.innerHTML = `<div class="pv-body" id="pv-body"></div>`;
  surf.addEventListener("click", onClick);
  surf.addEventListener("input", onInput);
  surf.addEventListener("change", onInput);
  surf.addEventListener("keydown", onKeydown);
}

// ------------------------------------------------------------- exports --------
export function initProviders() {
  if (PV.started) return; PV.started = true;
  mount();
  // Independent 60s poll — only while Providers is visible and the tab is shown.
  PV.timer = setInterval(() => { if (PV.visible && !document.hidden) fetchProviders(false); }, POLL_MS);
  // A 60s poll is a long wait after an outage: refetch as soon as reads recover.
  onRecover(() => { if (PV.visible) { fetchProviders(false); fetchConfigEnv(); } });
}

export function setProvidersActive(on) {
  PV.visible = on;
  if (on) {
    PV.sig = null;
    if (isHistorical()) { render(); return; }   // router redirects, but stay defensive
    if (!PV.data && !PV.inflight) fetchProviders(false);
    if (!PV.configEnv && !PV.configInflight) fetchConfigEnv();
    render();
  }
}

// Router hook — #providers[/<id>] (id selects + scrolls to a card).
export function providersRoute(route) {
  const id = route && route.id;
  PV.selected = id || null;
  PV.pendingScroll = !!id;
  PV.sig = null;
  render();
  if (id) scrollToSelected();
}

// Shared 10s snapshot dispatcher hook (main.js) — signature-gated, no-op while
// hidden. Providers data comes from its own poll, so this only repaints when the
// config env / selection changed; it never issues a network request.
export function providersTick() { if (PV.visible) render(); }
