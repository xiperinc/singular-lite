# Baseline test failures

Tests that do **not** pass cleanly on this tree, recorded so the release gate is
enforceable rather than advisory.

**Gate definition.** "Tests pass" means:

1. No test outside this file fails, and
2. No test inside this file fails *differently* than recorded here.

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
