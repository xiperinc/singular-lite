/* plan/dag_layout.js — the DAG lens's placement maths, extracted as a pure
   module so it can be asserted without a browser. ZERO imports by design: it
   must load under a bare `node --test` (tests/console/dag_layout.test.mjs) with
   no DOM, no bundler and no console app around it. Nothing in here touches the
   document; callers turn cells into pixels.

   Columns are dependency WAVES, not stages. The old layout grouped
   nodes by stage, gave each stage a successive column, and computed depth from
   same-stage dependencies only — so a plan with a distinct stage per node
   rendered as one sequential rail even when its dependency graph allowed parallel
   work. The server's stage sort could also place a node left of its own
   prerequisite. Here rank comes from the WHOLE dependsOn graph via a Kahn sweep
   with longest-path relaxation, so `rank(n) = 1 + max(rank(deps))` and every
   equal-rank node is genuinely startable together. Stage identifiers take no
   part in placement at all. */

const idOf = (n) => (n && n.id != null ? String(n.id) : null);

// Lane order inside a wave: area first, then id — deterministic (a total order
// over unique ids, so input order cannot change the result) and area-adjacent,
// which keeps same-area work — the work the scheduler serializes — vertically
// clustered instead of scattered across the wave.
function laneOrder(a, b) {
  const aa = a.area == null ? "" : String(a.area);
  const bb = b.area == null ? "" : String(b.area);
  const byArea = aa.localeCompare(bb);
  return byArea !== 0 ? byArea : idOf(a).localeCompare(idOf(b));
}

/* Longest-path rank over every dependsOn edge.

   Kahn's algorithm, same shape as lens_matrix.js `isAcyclic`, with a relaxation
   step: a node dequeues only once all its prerequisites have, so its rank is
   final when it is popped. Edges to ids that are not in `nodes` are ignored —
   an out-of-manifest dependency must not silently push a node right (or, worse,
   strand it in the cycle branch). Self-edges and duplicate edges are dropped
   for the same reason.

   Returns { rankById, acyclic }. Every node is ranked even when acyclic is
   false: members of a cycle never dequeue, so they are ranked one past the
   deepest prerequisite that DID rank (0 when none did). That fallback reads the
   acyclic snapshot rather than the live map, so a cycle's ranks never depend on
   iteration order. */
export function computeRanks(nodes) {
  const list = Array.isArray(nodes) ? nodes.filter((n) => idOf(n) !== null) : [];
  const known = new Set(list.map(idOf));
  const depsOf = {};   // id -> [in-graph dep ids]
  const adj = {};      // dep id -> [dependent ids]
  const indeg = {};
  for (const n of list) { const id = idOf(n); depsOf[id] = []; adj[id] = []; indeg[id] = 0; }
  for (const n of list) {
    const id = idOf(n);
    const seen = new Set();
    for (const d of n.dependsOn || []) {
      const dep = d == null ? null : String(d);
      if (!dep || dep === id || !known.has(dep) || seen.has(dep)) continue;
      seen.add(dep);
      depsOf[id].push(dep);
      adj[dep].push(id);
      indeg[id]++;
    }
  }

  const rankById = {};
  const queue = [];
  for (const n of list) { const id = idOf(n); if (indeg[id] === 0) { rankById[id] = 0; queue.push(id); } }
  let head = 0, drained = 0;
  while (head < queue.length) {
    const id = queue[head++];
    drained++;
    for (const m of adj[id]) {
      const cand = rankById[id] + 1;
      if (rankById[m] == null || cand > rankById[m]) rankById[m] = cand;
      if (--indeg[m] === 0) queue.push(m);
    }
  }

  const acyclic = drained === list.length;
  if (!acyclic) {
    const settled = Object.assign({}, rankById);
    for (const n of list) {
      const id = idOf(n);
      if (settled[id] != null) continue;
      let best = -1;
      for (const dep of depsOf[id]) if (settled[dep] != null && settled[dep] > best) best = settled[dep];
      rankById[id] = 1 + (best < 0 ? 0 : best);
    }
  }
  return { rankById, acyclic };
}

/* Wave grid: { cells: { id: { col, row } }, waveCount, maxRows, rankById, acyclic }.

   `col` comes from `rankOverride` (the server's precomputed `n.rank`, which
   older servers do not emit — always guard) when EVERY node carries a finite
   override; a partial map is ignored wholesale and computeRanks decides, since
   mixing two rank spaces is exactly how a node ends up drawn before its own
   prerequisite. Columns are then shifted to a 0-based space — a no-op on
   well-formed 0-based ranks, and it keeps a 1-based server map (or an all-cycle
   graph, whose minimum rank is 1) from opening an empty first column.

   `waveCount` is the number of columns spanned (max col + 1). With derived
   ranks that is also the number of non-empty waves — every level 0..max is
   occupied by construction — but a sparse server override can leave a hole, so
   callers must treat a wave as possibly empty. */
export function computeGrid(nodes, rankOverride) {
  const list = Array.isArray(nodes) ? nodes.filter((n) => idOf(n) !== null) : [];
  const derived = computeRanks(list);
  const useOverride = !!rankOverride && list.length > 0 &&
    list.every((n) => Number.isFinite(rankOverride[idOf(n)]));

  let min = 0, first = true;
  const raw = {};
  for (const n of list) {
    const id = idOf(n);
    const r = useOverride ? Math.trunc(rankOverride[id]) : derived.rankById[id];
    raw[id] = r;
    if (first || r < min) { min = r; first = false; }
  }

  const rankById = {};
  const waves = [];
  for (const n of list) {
    const col = raw[idOf(n)] - min;
    rankById[idOf(n)] = col;
    (waves[col] = waves[col] || []).push(n);
  }

  const cells = {};
  let maxRows = 0;
  for (let col = 0; col < waves.length; col++) {
    const wave = waves[col];
    if (!wave) continue;
    wave.sort(laneOrder);
    if (wave.length > maxRows) maxRows = wave.length;
    wave.forEach((n, row) => { cells[idOf(n)] = { col, row }; });
  }

  return { cells, waveCount: waves.length, maxRows, rankById, acyclic: derived.acyclic };
}
