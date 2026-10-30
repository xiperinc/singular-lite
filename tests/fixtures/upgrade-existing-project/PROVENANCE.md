# Recorded upgrade scaffold

Source: `v0.23.4`, commit `a3c1c77a41722100e3639e5f545f4304c459587f`.
Recorded with that revision's `cli/singular init`, not the candidate's init.
`scaffold/` contains all 59 files it created outside Git and runtime state.
The only normalization replaces both example Git identity email values in
`singular.config.json` with `fixture`; no address is needed for this test.
`sha256.json` records the normalized bytes. No credentials or machine paths
are recorded. The suite reads this fixture without needing tags or old engines.

To reproduce, from a checkout containing the source revision, run:

```bash
recording_parent="$(mktemp -d)"
bash tests/fixtures/upgrade-existing-project/record.sh "$recording_parent/upgrade-recording"
```

The destination must not exist. Compare its `scaffold/` and `sha256.json` with
this directory. The recorder exports the old source to its own temporary
directory, gives it an isolated engine home and state directory, invokes init
by path, and removes the export afterwards. It never installs or pushes.

The test adds consumer changes at runtime: concurrency 2 in JSON, a local
worker-prompt instruction, an existing ready task and its product files, and
an ignored local configuration selecting a stub runner. Those are not presented
as output of init. All 59 scaffold files are checked before those edits.
