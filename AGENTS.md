# Singular — agent front door

Read this before anything else in this repository.

## What this repo is now

Singular is a Go orchestration engine (0.23.x, branch `codex/brain-integration`).
Since decision **D-03 (18 Sep 2026)** it is **not** the product trunk and **not**
a runtime dependency of the Xiper beta. The trunk is **PMGO**.

Singular is an **internal tool on probation** (directive 3, Open):

- Stopped until the PMGO gate on 25 Sep passes: feature work, resuming the brain
  campaign, any PMGO-to-Singular seam, `runner-executor-v1`.
- If the gate passes: 0.23.3 is cut 26 Sep, dogfood sprint 26–28 Sep.
- Keep-or-shelve is decided 28 Sep from the dogfood ledger.

Its brain, review/repair policy, recovery machinery and catalogue of failure
modes remain design input for PMGO. Rights questions under A are open: shared
script lineage with PMGO, and `vendor/singular-brain` has no licence.

## Where the truth lives

- Decision and context: `claudedocs/d-03-trunk-decision-pointer.md` (this repo),
  then the full record in the PMGO repo:
  `~/Desktop/999. PROJECTS/PMGO-launch/docs/core/launch/d-03-trunk-decision-2026-09-18.md`,
  `d-03-audit-2026-09-19.md`, `directives-2026-09-19.md`.
- Mission, repo map and direction across both projects:
  `~/Desktop/999. PROJECTS/PMGO-launch/docs/PROJECT.md`.
- Sprint plan here: `claudedocs/dogfood-sprint-0.23.3-proposal.md`, kickoff
  briefs `claudedocs/kickoff-b-*.md`, `kickoff-c-*.md`, `kickoff-d-*.md`.
- Designed reports on Singular (architecture, brain, token efficiency, research,
  review/repair): `~/Desktop/999. PROJECTS/pmgo-orchestration-engine/docs/pdf-singular/`.

## Other checkouts

`~/Desktop/999. PROJECTS/pmgo-orchestration-engine` is an older clone of this
same repository, stopped 16 Sep. Reference only; do not develop there.

## Keeping this current

When the 28 Sep keep-or-shelve decision lands, update the first section here and
`claudedocs/d-03-trunk-decision-pointer.md` in the same commit.
