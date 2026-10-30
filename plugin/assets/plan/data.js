/* plan/data.js — the Plan surface's data layer. Owns the /api/dag and
   /api/timeline fetches, module-level caches, and change subscriptions so the
   four lenses share one source of truth. The DAG refetches only when the live
   snapshot's gate map changes (subscribed via the 10s tick); the timeline
   refetches on each visible tick with a since-cursor. */

import { S } from "../app.js";
import { apiFetch, onRecover } from "../core/api.js";

// ---- DAG (singular.codex.dag.v0) ----
let dag = null;
let dagInflight = false;
let lastGatesSig = null;
const dagSubs = new Set();

export function getDag() { return dag; }

// Subscribe to DAG (re)loads. Returns an unsubscribe.
export function onDag(fn) { dagSubs.add(fn); if (dag) fn(dag); return () => dagSubs.delete(fn); }

export async function fetchDag() {
  if (dagInflight) return dag;
  dagInflight = true;
  try {
    const res = await apiFetch("/api/dag", { cache: "no-store" });
    if (res.ok) { dag = await res.json(); dagSubs.forEach((fn) => { try { fn(dag); } catch (e) {} }); }
  } catch (e) { /* keep last good dag; a transient miss must not blank the lens */ }
  finally { dagInflight = false; }
  return dag;
}

// Called from the 10s snapshot tick: refetch the DAG only when the gate map
// (orchestration.gates.byNode) actually changed — a quiet snapshot is a no-op.
export function dagMaybeRefetch() {
  const byNode = ((S.snap && S.snap.orchestration && S.snap.orchestration.gates) || {}).byNode;
  const sig = JSON.stringify(byNode || null);
  if (sig !== lastGatesSig) { lastGatesSig = sig; fetchDag(); }
}

// Reads were failing and came back: the gate-map signature may not have moved,
// but what we hold may be older than the outage (or nothing at all).
onRecover(() => { lastGatesSig = null; fetchDag(); });

// ---- Derived DAG indexes (recomputed lazily per dag identity) ----
let idxDag = null, idxCache = null;
export function dagIndex() {
  if (!dag) return null;
  if (idxDag === dag && idxCache) return idxCache;
  const nodeById = {};
  for (const n of dag.nodes) nodeById[n.id] = n;
  const dependents = {};              // id -> [dependent ids]
  const taskToNode = {};              // TASK-xxxx -> node id
  for (const e of dag.edges || []) { (dependents[e.from] = dependents[e.from] || []).push(e.to); }
  for (const n of dag.nodes) for (const t of (n.tasks && n.tasks.taskIds) || []) taskToNode[t] = n.id;
  idxDag = dag;
  idxCache = { nodeById, dependents, taskToNode };
  return idxCache;
}

// ---- Timeline (singular.codex.timeline.v0) ----
let timeline = null;
let tlInflight = false;

export function getTimeline() { return timeline; }

export async function fetchTimeline() {
  if (tlInflight) return timeline;
  tlInflight = true;
  try {
    const res = await apiFetch("/api/timeline", { cache: "no-store" });
    if (res.ok) timeline = await res.json();
  } catch (e) { /* keep last good timeline */ }
  finally { tlInflight = false; }
  return timeline;
}
