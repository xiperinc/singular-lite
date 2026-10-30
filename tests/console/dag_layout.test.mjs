/* tests/console/dag_layout.test.mjs — regression coverage for the DAG
   lens rendering a four-wide graph as one sequential rail.

   The fixture is the audit's contract: every node has its own stage, the stage
   identifiers sort in the OPPOSITE order to the dependencies, and two siblings
   share a prerequisite. If placement ever consults `stage` again these tests
   fail, because stage order here is a lie.

   Loaded straight from plugin/assets/plan/dag_layout.js by relative URL — that
   module is import-free precisely so this can run under bare `node --test`. */

import test from "node:test";
import assert from "node:assert/strict";
import { computeRanks, computeGrid } from "../../plugin/assets/plan/dag_layout.js";

//        A            rank 0
//       / \
//      B   C          rank 1   (parallel siblings — the whole point)
//      |    \
//      D     \        rank 2
//       \     \
//        `--- E       rank 3   (depends on C and D; D is the deeper one)
//
// Stages are unique per node and deliberately inverted: A, the root, sits in
// "S9-last"; B, its dependent, in "S1-first". Any stage-ordered layout draws A
// to the right of B — i.e. a node before its own prerequisite.
const FIXTURE = [
  { id: "A", stage: "S9-last", area: "core", dependsOn: [] },
  { id: "B", stage: "S1-first", area: "z-mcp", dependsOn: ["A"] },
  { id: "C", stage: "S3-third", area: "a-cli", dependsOn: ["A"] },
  { id: "D", stage: "S2-second", area: "z-mcp", dependsOn: ["B"] },
  { id: "E", stage: "S0-zero", area: "core", dependsOn: ["C", "D"] },
];

const EDGES = [["A", "B"], ["A", "C"], ["B", "D"], ["C", "E"], ["D", "E"]];

const shuffled = (order) => order.map((id) => FIXTURE.find((n) => n.id === id));

test("computeRanks: longest path over all dependsOn edges", () => {
  const { rankById, acyclic } = computeRanks(FIXTURE);
  assert.equal(acyclic, true);
  assert.deepEqual(rankById, { A: 0, B: 1, C: 1, D: 2, E: 3 });
});

test("computeRanks: edges to unknown ids are ignored, not ranked", () => {
  const { rankById, acyclic } = computeRanks([
    { id: "A", dependsOn: ["GHOST"] },
    { id: "B", dependsOn: ["A", "ALSO-GONE"] },
  ]);
  assert.equal(acyclic, true);
  assert.deepEqual(rankById, { A: 0, B: 1 });
});

test("computeRanks: self-edges and duplicate edges never add depth", () => {
  const { rankById, acyclic } = computeRanks([
    { id: "A", dependsOn: ["A"] },
    { id: "B", dependsOn: ["A", "A", "A"] },
  ]);
  assert.equal(acyclic, true);
  assert.deepEqual(rankById, { A: 0, B: 1 });
});

test("computeGrid: no node is placed before a prerequisite", () => {
  const { cells } = computeGrid(FIXTURE);
  for (const [from, to] of EDGES) {
    assert.ok(cells[to].col > cells[from].col,
      `edge ${from}->${to}: expected col(${to})=${cells[to].col} > col(${from})=${cells[from].col}`);
  }
});

test("computeGrid: parallel siblings share a wave", () => {
  const { cells } = computeGrid(FIXTURE);
  assert.equal(cells.B.col, cells.C.col);
  assert.notEqual(cells.B.row, cells.C.row);
});

test("computeGrid: wave count and frontier width match the graph", () => {
  const grid = computeGrid(FIXTURE);
  // waves: [A] [B C] [D] [E]
  assert.equal(grid.waveCount, 4);
  assert.equal(grid.maxRows, 2);
  assert.equal(grid.acyclic, true);
  assert.deepEqual(grid.rankById, { A: 0, B: 1, C: 1, D: 2, E: 3 });
  assert.deepEqual(grid.cells, {
    A: { col: 0, row: 0 },
    C: { col: 1, row: 0 },   // area "a-cli" sorts ahead of B's "z-mcp"
    B: { col: 1, row: 1 },
    D: { col: 2, row: 0 },
    E: { col: 3, row: 0 },
  });
});

test("computeGrid: lanes are deterministic across input orderings", () => {
  const one = computeGrid(shuffled(["E", "D", "C", "B", "A"]));
  const two = computeGrid(shuffled(["C", "A", "E", "B", "D"]));
  assert.deepEqual(one.cells, two.cells);
  assert.deepEqual(one.cells, computeGrid(FIXTURE).cells);
  assert.equal(one.waveCount, 4);
  assert.equal(one.maxRows, 2);
});

test("computeGrid: a full server rank map wins over the derived one", () => {
  // The server may serialize the plan differently (here: one node per wave).
  const grid = computeGrid(FIXTURE, { A: 0, B: 1, C: 2, D: 3, E: 4 });
  assert.equal(grid.cells.A.col, 0);
  assert.equal(grid.cells.B.col, 1);
  assert.equal(grid.cells.C.col, 2);
  assert.equal(grid.cells.D.col, 3);
  assert.equal(grid.cells.E.col, 4);
  assert.equal(grid.waveCount, 5);
  assert.equal(grid.maxRows, 1);
});

test("computeGrid: a 1-based server rank map is shifted, not left with a hole", () => {
  const grid = computeGrid(FIXTURE, { A: 1, B: 2, C: 2, D: 3, E: 4 });
  assert.equal(grid.cells.A.col, 0);
  assert.equal(grid.cells.B.col, 1);
  assert.equal(grid.cells.C.col, 1);
  assert.equal(grid.waveCount, 4);
});

test("computeGrid: a partial server rank map is ignored wholesale", () => {
  const grid = computeGrid(FIXTURE, { A: 0, B: 9 });
  assert.deepEqual(grid.cells, computeGrid(FIXTURE).cells);
  assert.equal(grid.cells.B.col, 1);
  assert.equal(grid.cells.C.col, 1);
  assert.equal(grid.waveCount, 4);
});

test("computeGrid: a missing rank field degrades to the derived ranks", () => {
  // Older servers emit no `rank` at all; the lens passes undefined.
  assert.deepEqual(computeGrid(FIXTURE, undefined).cells, computeGrid(FIXTURE).cells);
  assert.deepEqual(computeGrid(FIXTURE, {}).cells, computeGrid(FIXTURE).cells);
});

test("computeGrid: a cycle still places every node", () => {
  const cyclic = [
    { id: "A", area: "core", dependsOn: [] },
    { id: "X", area: "core", dependsOn: ["A", "Z"] },
    { id: "Y", area: "core", dependsOn: ["X"] },
    { id: "Z", area: "core", dependsOn: ["Y"] },
  ];
  const grid = computeGrid(cyclic);
  assert.equal(grid.acyclic, false);
  for (const n of cyclic) {
    assert.ok(grid.cells[n.id], `no cell for ${n.id}`);
    assert.ok(Number.isInteger(grid.cells[n.id].col) && grid.cells[n.id].col >= 0);
    assert.ok(Number.isInteger(grid.cells[n.id].row) && grid.cells[n.id].row >= 0);
  }
  assert.equal(computeGrid(cyclic).cells.A.col, 0);
});

test("computeGrid: empty and junk inputs do not throw", () => {
  const empty = computeGrid([]);
  assert.deepEqual(empty.cells, {});
  assert.equal(empty.waveCount, 0);
  assert.equal(empty.maxRows, 0);
  assert.equal(empty.acyclic, true);
  assert.deepEqual(computeGrid(null).cells, {});
  assert.deepEqual(computeGrid(undefined, { A: 1 }).cells, {});
  assert.deepEqual(computeGrid([null, { id: "A" }]).cells, { A: { col: 0, row: 0 } });
  assert.deepEqual(computeGrid([{ id: "A" }]).cells, { A: { col: 0, row: 0 } });
});
