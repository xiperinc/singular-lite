/* core/health.js — paints the data-health store (core/api.js) onto the page.

   Three things, all driven by one onHealth subscription:

   1. #conn-banner — a persistent strip under the top bar while any read is
      failing: what failed, since when (UTC), that it is retrying and when, and
      a Retry-now button. It stays until the next success; it is not a toast.
   2. Loading placeholders. A surface with no data yet renders loadingHtml(what)
      instead of a bare "loading …" string. While reads are failing the
      placeholder shows the error and a Retry button; it flips back by itself
      when the failure clears. Surfaces do not have to subscribe to anything.
   3. The two header chips, which otherwise read "loading" / "stop —" for as
      long as the first snapshot never arrives.

   Imports core/api.js only (which imports nothing), so any surface may import
   loadingHtml from here without forming a cycle. */

import { onHealth, getHealth, retryNow, describeFailure, OFFLINE_HINT } from "./api.js";

const esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, (c) => (
  { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

// `singular console --ensure` → <code>…</code>; everything else escaped.
const withCode = (s) => esc(s).replace(/`([^`]+)`/g, "<code>$1</code>");

export function utcClock(ms) {
  if (!ms) return "—";
  return new Date(ms).toISOString().slice(11, 19) + " UTC";
}

function retryText(h) {
  if (h.retrying) return "retrying now…";
  if (!h.nextRetryAt) return "retrying";
  const s = Math.max(0, Math.ceil((h.nextRetryAt - Date.now()) / 1000));
  return s <= 0 ? "retrying now…" : "retrying in " + s + "s";
}

// ------------------------------------------------------- placeholders -------
function placeholderInner(what, h) {
  if (h.state === "ok") return "loading " + esc(what) + "…";
  const why = h.state === "offline" ? OFFLINE_HINT : describeFailure(h.primary);
  return `<span class="load-error" role="alert">
      <span class="load-error-title">could not load ${esc(what)}</span>
      <span class="load-error-why">${withCode(why)}</span>
      <span class="load-error-foot"><button type="button" class="secondary-button compact" data-api-retry>Retry</button><span class="load-error-auto">${esc(retryText(h))}</span></span>
    </span>`;
}

// The markup a surface renders while it has no data. `cls` is the surface's own
// placeholder class, kept so its spacing and typography do not change.
export function loadingHtml(what, cls) {
  return `<div class="${esc(cls || "section-empty")}" data-load-what="${esc(what)}">${placeholderInner(what, getHealth())}</div>`;
}

function refreshPlaceholders(h) {
  document.querySelectorAll("[data-load-what]").forEach((el) => {
    const state = h.state === "ok" ? "ok" : h.state + ":" + (h.primary ? h.primary.at : "");
    // Only the retry countdown changes between failures of the same kind.
    if (el.dataset.loadState === state) {
      const auto = el.querySelector(".load-error-auto");
      if (auto) auto.textContent = retryText(h);
      return;
    }
    el.dataset.loadState = state;
    el.innerHTML = placeholderInner(el.dataset.loadWhat, h);
  });
}

// ------------------------------------------------------------- banner -------
function paintBanner(h) {
  const el = document.getElementById("conn-banner");
  if (!el) return;
  const root = document.documentElement;
  if (h.state === "ok") {
    el.hidden = true;
    document.body.dataset.health = "ok";
    root.style.setProperty("--conn-banner-h", "0px");
    return;
  }
  const title = el.querySelector(".cb-title");
  const detail = el.querySelector(".cb-detail");
  const retry = el.querySelector(".cb-retry");
  const since = utcClock(h.since);
  if (h.state === "offline") {
    title.textContent = "Console server is not running";
    detail.innerHTML = "run <code>singular console --ensure</code> · no answer since " + esc(since) +
      (h.lastOkAt ? " · showing data from " + esc(utcClock(h.lastOkAt)) : "");
  } else {
    const more = h.failures.length > 1 ? " (+" + (h.failures.length - 1) + " more)" : "";
    title.textContent = "Refresh failed since " + since;
    detail.innerHTML = withCode(describeFailure(h.primary)) + esc(more) +
      (h.lastOkAt ? " · showing data from " + esc(utcClock(h.lastOkAt)) : "");
  }
  detail.title = detail.textContent;
  retry.textContent = retryText(h);
  el.dataset.state = h.state;
  el.hidden = false;
  document.body.dataset.health = h.state;
  // The banner takes a row of its own (styles.css reads this variable), so it
  // never covers the content it is warning about.
  root.style.setProperty("--conn-banner-h", el.offsetHeight + "px");
}

// ------------------------------------------------------- header chips -------
// Only ever replaces the boot placeholders; once a snapshot has painted real
// values app.js owns these nodes again.
const HEALTH_PLACEHOLDERS = ["loading", "offline", "unavailable"];
const STOP_PLACEHOLDERS = ["stop —", "stop unknown"];
function paintChips(h) {
  const ht = document.getElementById("health-text");
  const st = document.getElementById("stop-text");
  const hf = document.getElementById("health-flag");
  const failing = h.state !== "ok";
  if (ht && HEALTH_PLACEHOLDERS.includes(ht.textContent)) {
    ht.textContent = !failing ? "loading" : h.state === "offline" ? "offline" : "unavailable";
    if (hf) hf.dataset.tone = failing ? "error" : "idle";
  }
  if (st && STOP_PLACEHOLDERS.includes(st.textContent)) {
    st.textContent = failing ? "stop unknown" : "stop —";
  }
}

// --------------------------------------------------------------- init -------
let started = false;
export function initHealth() {
  if (started) return; started = true;
  const paint = (h) => { paintBanner(h); refreshPlaceholders(h); paintChips(h); };
  onHealth(paint);
  // The countdown is the only thing that changes between store events.
  setInterval(() => { const h = getHealth(); if (h.state !== "ok") paint(h); }, 1000);
  window.addEventListener("resize", () => { const h = getHealth(); if (h.state !== "ok") paintBanner(h); });
  // One delegated handler for the banner button and every placeholder's Retry.
  document.addEventListener("click", (e) => {
    const b = e.target && e.target.closest && e.target.closest("[data-api-retry]");
    if (!b) return;
    e.preventDefault();
    retryNow();
  });
  // Coming back to a backgrounded tab: do not wait out the backoff.
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden && getHealth().state !== "ok") retryNow();
  });
}
