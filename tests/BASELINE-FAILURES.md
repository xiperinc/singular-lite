# Baseline test failures

Tests that do **not** pass cleanly on this tree, recorded so the release gate is
enforceable rather than advisory.

**Gate definition.** "Tests pass" means:

1. No test outside this file fails, and
2. No test inside this file fails *differently* than recorded here.

## 0.24.0: no known deterministic failure in the suite; one test not run; the field-report canary fails

**Qualified candidate:** `0b3acb27b46df7aed0f233c8de4a8a23c825c425`. This file is
the receipt for it: the published tree is that commit's tree with this one file
changed. The records behind these figures are kept by the build that prepared
the candidate, outside this repository.

- **The run.** One run on exactly that commit, `bash tests/run.sh` at three jobs
  with a log kept for each test: 297 of the 298 test files (294 in `tests/`, 4
  in `singular-ext/tests/`). All 297 passed. Darwin arm64, Bash 5.3.9, Python
  3.14, 52 minutes. The machine was loaded when the run started (load average
  15 to 18, swap nearly full).
- **Not run: `test-frozen-campaign-terminal.sh`.** It needs about 10 GiB of
  scratch, and the host had 7 GiB free, below the requirement written at the
  end of this file. It passed in the 0.23.7 qualification; since then engine
  code it drives through `engine/reconcile.sh`, such as `engine/l1-drive.sh`,
  has changed. Its result on this candidate is unknown.
- **An earlier run,** on `98f8c2f`, an ancestor of the candidate, is not the
  qualification. It ran 296 of that commit's 297 test files, the same test
  left out; `tests/test-red-proof-origin.sh` did not exist yet. In it four
  tests failed. `test-console-cli.sh` failed in the run, when the console port
  it had saved was taken by another process, and passed when the four were
  run again on their own, two at a time, on the same commit.
  `test-doc-contract-skill.sh` failed because the plugin skill still named the
  previous engine version. `test-publication-tree.sh` and
  `test-publication-scaffold.sh` failed every time: the public-tree check
  matched its task-record pattern from the end of the path, so a fixture
  project's task file under `tests/fixtures/` counted as a task record of this
  repository. The skill and the pattern are fixed in the candidate, and all
  four pass in the qualification run.
- **Also run on the candidate.** The plugin's Python tests: 310 pass. The secret
  scan over `v0.23.4..HEAD`: clean. `singular doctor --json`, with the engine
  called from its checkout, on this repository: `ok`, no failing check (39
  passed, 2 warnings, 6 skipped).
- **Two drives with a real provider,** on an earlier candidate of this release
  that differs from the qualified one in the red-proof record rule, the
  public-tree test, test comments and documentation. Throwaway projects, no
  remote and pushing off, every other setting as shipped except those named;
  the Claude CLI with the shipped
  default model. With `SINGULAR_RED_PROOF=enforce` and
  `SINGULAR_ACCEPTANCE=every-path`, two dependent `strict_test_first` tasks:
  each has one `proved` record, and each was accepted, imported and
  integrated. With `SINGULAR_RED_PROOF=observe` and acceptance as shipped, ten
  independent `strict_test_first` tasks: all ten first attempts were `proved`,
  none `not-demonstrated`; all ten were accepted and integrated, one after a
  second attempt that red proof did not cause. 26 provider calls, USD 1.70 as
  the provider reported it. The tasks were small; these drives give no
  evidence of how often `not-demonstrated` occurs on real work.
- **An independent audit** of the same earlier candidate checked each
  acceptance and red-proof requirement, most against a test, and broke nine
  guards (each turned at least one test red). In a 45-minute time box it then
  recorded 40 attempts, controls included, to publish a candidate that lacks
  one part of the acceptance rule, through the public verbs, the recovery
  paths and direct edits of the state folder. Two got through, both the same
  way: `V` counted a proof record found anywhere in the run folder, including
  the worker's copied evidence. That is fixed in the candidate: `V` now reads
  only records lying directly in the run folder, where the host writes its
  own, and not the worker's copied evidence
  (`tests/test-red-proof-origin.sh`). The audit also recorded smaller
  findings. It turned none of them into a published incomplete candidate, and
  of them the candidate fixes only wording in the changelog. Still
  open, among others: an edited audit file is not compared with the hash its
  review round records (this takes a writer to the state folder); after a
  refused import the advice still offers "import the packet again", which is
  refused (it fails closed, and `singular drive <task>` works); a tracked
  `singular.config.json` overrides a setting the operator exported; and under
  `enforce` the worker's proof tests run with the host's permissions, as
  `docs/red-proof.md` says.
- **The field-report canary does not pass.** `tests/field-report-canary.sh`
  stops at the case it labels `diagnostic-category-rendering`, as in 0.23.7:
  `test-ops-health.sh` reports "digest must be stable across idle calls" when
  the canary runs it directly. The same test passed in the suite. The cause is
  not diagnosed.
- **What this does not cover.** No other host. A skip is not a pass: test files
  that leave early with exit 0 when a host tool is missing still print PASS.

## 0.23.7: no known deterministic failure in the suite; the field-report canary fails

**Qualified candidate:** `b5853d196addaab87a683463e8e69d604a705b70`. This file is
the receipt for it: the release commit changes this one file on top of that
commit and nothing else. The records behind these figures are kept by the build
that prepared the candidate, outside this repository.

- **The run.** One full-suite run on exactly that commit, `bash tests/run.sh` at
  four jobs with a log kept for each test: 276 test files (272 in `tests/`, 4 in
  `singular-ext/tests/`). 275 passed in the run. One,
  `test-l1-plan-node-revise-hook.sh`, failed in the run and passed at the first
  try when run again alone on the same commit. Darwin arm64, Bash 5.3.9, 37
  minutes.
- **The retry rule, for this release.** The rule written below for
  `test-l1-parallel` was applied to that test: run again alone, up to three
  times, one pass counts. The gate definition above is read with it for 0.23.7
  only; whether it becomes a standing rule for every test is not decided here.
- **Two earlier full runs the same day,** on the first-parent commits `cf85d1f`
  and `6c5c3b1`, are not the qualification. In them `test-ctx-artifact-scan.sh`
  failed twice (once with exit 139, an interpreter crash) and
  `test-console-cli.sh` once. Both passed in the qualification run, and both
  passed when run alone on the candidate afterwards. The machine was busy with
  other work during all three runs (swap nearly full; the failing tests
  differed from run to run, one of them failing in two of the three); the
  records suggest load as the cause and do not prove it.
- **Also run on the candidate.** The plugin's Python tests: 310 pass. The secret
  scan over `v0.23.4..HEAD`: clean. `singular doctor --json`, with the engine
  called from its checkout, on this repository: exit 1 with one failing check,
  `dag.evaluation`, because this repository's own plan files still describe a
  finished campaign. On a fresh project made with the same engine, `doctor`
  reports no failing check.
- **The field-report canary does not pass.** `tests/field-report-canary.sh` had
  failed at its replay step since 2026-08-11, when a rename changed two fixture
  files and left their recorded checksums behind; that is corrected in this
  version and the replay passes. The canary now stops at the case it labels
  `diagnostic-category-rendering`: `test-ops-health.sh` reports "digest must be
  stable across idle calls" when it is run directly, as the canary runs it. The
  same test passed in the suite, and alone through `tests/run.sh` on the
  candidate. The cause is not diagnosed.
- **What this does not cover.** No other host. A skip is not a pass: eight test
  files can leave early with exit 0 when a host tool is missing, and would still
  print PASS there.

## 0.23.4: no known deterministic failures

The 0.23.3 file recorded six entries; the full suite on 0.23.3 actually had
fourteen tests that also failed on 0.23.2, plus three host-environmental
failures. All of them are fixed in 0.23.4. Each fix names its cause in its
commit message; in short:

| Test | Cause | Fix |
| --- | --- | --- |
| accept-existing-packet | engine never wrote `secret-scan-result.json` before `evidence-manifest.sh` (since ff29c88) | engine |
| detached-dispatch, continuity-core | stale exported JSON-config provenance across fixture rebuilds; old-engine copy lacked python helpers | test |
| candidate-recovery | `/dev/null` selected as JSON config | test |
| capability-runtime | explicit config selected for a repo that has none | test |
| ctx-rehydrate-authored-config | missing config selected before sourcing lib.sh | test |
| ctx-artifact-scan-hook | shim engine dir held only `ctx-*.sh` | test |
| orphan-continuation | out-of-scope untracked partial vs ff29c88 admission (guard kept) | test |
| dispatch-auto-accept | expected an un-audited stranded packet to auto-heal; now refused by the acceptance predicate | test |
| ctx-paired-audit | fixture predated the evidence broker | test |
| per-try-artifacts | extracted worker phase missing driver globals; error hidden by the exit trap | test |
| session-affinity | warmup and retry share a run id; preserved-candidate path collided | test |
| singular-brand | routing moved from `do_GET` to `_do_GET` | test |
| storage-proof-redlog | reference prompt named the branch, prompt now names the base SHA | test |
| frozen-campaign-terminal | teardown could not unlink earlier cases' read-only engine copies | test |
| exit-attribution | fixture run id `RUN-2` matched live `RUN-2026…` runs via `pgrep -f` | test |
| setup | host had too little free disk for installer variants | environment |

## Flaky: `test-l1-parallel`

- **Observed at `edb39bb`:** 2 failures in 4 runs, with two different messages
  (`fanout imports both planned nodes: want '2' got '1'`;
  `one free slot imports exactly one planned task: want '1' got '0'`). It
  passed in the 0.23.3 full-suite run.
- **Gate rule:** retry up to 3 times; one pass is a pass. Three consecutive
  failures is a regression and must be investigated.
- **Open:** the planner fanout slot-accounting race is not yet diagnosed.

## Host requirements for a full-suite run

- At least 15 GiB free. `test-frozen-campaign-terminal` alone peaks at about
  10 GiB of scratch and must not run concurrently with another copy of itself.
- macOS `mktemp -d` ignores `TMPDIR`; scratch lands in the per-user temp
  directory. Remove read-only leftovers with `chmod -R u+w` first, and only
  when no run is in flight.
- Run ids in fixtures must be host-unique when the reaper's process
  observation can be reached (`pgrep -f <runId>`).
