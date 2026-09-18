# Baseline test failures

Tests on `codex/brain-integration` that do **not** pass cleanly, recorded so the
0.23.3 release gate is enforceable rather than advisory.

**Gate definition for 0.23.3.** "Tests pass" means:

1. No test outside this file fails, and
2. No test inside this file fails *differently* than recorded here — a changed
   error line, a new `FAIL:` assertion, or a changed exit code is a regression
   even though the test was already failing.

Entry 5 is a special case: its assertions pass and it self-reports `PASS:`. The
gate reads that line, not its exit code.

Each entry was reproduced against baseline commit **`d5d5b37`** in a detached
`git worktree`, so no working-tree change is in scope.

---

## 1. `test-detached-dispatch`

- **Baseline verified against:** `d5d5b37`
- **Exit code:** 2
- **First error line:**
  ```
  singular: selected JSON configuration is missing: <TMPDIR>/repo/singular.config.json
  ```
- **Classification:** environment / fixture. Not an assertion failure — the run
  produces no `FAIL:` line and no `ok:` line; it exits on the first engine call.
- **Mechanism:** the JSON-config selector guard at `engine/lib.sh:210` refuses
  when `SINGULAR_JSON_CONFIG_SOURCE` is `selector` and the selected file does not
  exist. The test never creates `singular.config.json` (no reference to it
  anywhere in the file).

## 2. `test-orphan-continuation`

- **Baseline verified against:** `d5d5b37`
- **Exit code:** 1
- **First error line:**
  ```
  FAIL: native continuation did not invoke exactly one worker
  ```
- **Classification:** **assertion failure.** The only genuine product-behaviour
  failure in this file. No configuration error precedes it.

## 3. `test-candidate-recovery`

- **Baseline verified against:** `d5d5b37`
- **Exit code:** 1
- **First error line:**
  ```
  singular: selected JSON configuration is missing: /dev/null
  ```
  followed immediately by:
  ```
  FAIL: host recovery entrypoint refused valid repair authority
  ```
- **Classification:** environment / fixture, with a **downstream assertion
  failure**. Distinct trigger from entries 1 and 4: this test deliberately sets
  `SINGULAR_JSON_CONFIG_FILE=/dev/null` (`tests/test-candidate-recovery.sh:167`,
  and again at `:509`). `/dev/null` is not a regular file, so it fails the
  `[[ -f ]]` test in the same `engine/lib.sh:210` guard and the entrypoint exits
  2 — which the test then reports as a refused repair authority.
- **Not verified:** whether the assertion would pass if the configuration
  resolved. Treat the `FAIL:` line as unexplained until that is established.

## 4. `test-continuity-core`

- **Baseline verified against:** `d5d5b37`
- **Exit code:** 2
- **First error line:** (preceded by one passing step, `ok: preflight`)
  ```
  singular: selected JSON configuration is missing: <TMPDIR>/repo/singular.config.json
  ```
- **Classification:** environment / fixture. Same shape as entry 1; the test
  contains no reference to `singular.config.json`.

## 5. `test-frozen-campaign-terminal`

- **Verified against:** `d5d5b37` + the Item ① change (the lease-writer fix).
  Not re-run on bare `d5d5b37`: this test takes ~30 minutes, and its failure is
  `rm` against vendored `.mjs` files, which cannot interact with lease writing.
- **Exit code:** 1
- **Assertions:** **all pass** — 15 `ok:` lines, zero `FAIL:` lines, and the
  test prints its own success line:
  ```
  PASS: frozen campaign terminal lifecycle
  ```
- **First error line:** (teardown only, after the `PASS:` line)
  ```
  rm: <TMPDIR>/singular-frozen-terminal.<X>/.../vendor/singular-brain/engine/cli.mjs: Permission denied
  ```
- **Classification:** **teardown only.** The EXIT trap runs
  `rm -rf "$scratch" || cleanup_failed=1`
  (`tests/test-frozen-campaign-terminal.sh:107`) and the script exits non-zero on
  that flag. The scratch tree contains a frozen campaign runtime, which is
  written read-only by design: directories are `dr-xr-xr-x` and files
  `-r--r--r--` (observed under `.singular-state/runtime/*/`), so entries cannot
  be unlinked. Known A14/A15 behaviour.
- **Gate rule:** read the `PASS:` line, not the exit code. A missing `PASS:`
  line, any `FAIL:` line, or fewer than 15 `ok:` lines is a regression.
- **Cleanup note:** a failed teardown leaves a read-only scratch tree under
  `$TMPDIR/singular-frozen-terminal.*`. Remove it with `chmod -R u+w` first, and
  only when no run is in flight — the glob will match a live run's directory.

---

## Notes

- Entries 1, 3 and 4 share the `engine/lib.sh:210` selector guard but **do not
  share one root cause**: entry 3 is an explicit `/dev/null` idiom in the test,
  entries 1 and 4 are a fixture that never creates the file. They are recorded
  separately and are not assumed to be one fix.
- Entry 2 is the only genuine product-behaviour failure recorded here.
- **Coverage gap.** Entries 1 and 2 are the two tests most likely to catch a
  regression in the reaper and retained-worktree work (plan items 2 and 3).
  Changes in that area cannot rely on them and must carry their own pinned
  tests, with the uncovered regressions stated explicitly in the change report.
