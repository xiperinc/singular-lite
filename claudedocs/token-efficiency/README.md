# Token-efficiency analysis

Scripts behind `../report-token-efficiency.html`. All are read-only on their inputs.

```
python3 ledger.py <repo-root> <integration-branch> ledger.json
python3 figures.py ledger.json figures.json
python3 supervision.py <repo>/.singular-state <claude-project-dir> <close-iso> supervision.json
python3 phases.py ledger.json supervision.json <repo>/.singular-state/events.ndjson \
        <fix-live-iso> <start-iso> <close-iso> TASK-1115@<merge-iso> phases.json <claude-session.jsonl>...
python3 build_report.py ledger.json figures.json supervision.json phases.json report.html
```

For the September campaign: fixes live `2026-09-14T16:34:19+00:00` (A15 campaign
start), start `2026-09-07T15:44:59+00:00`, close `2026-09-16T10:11:14+00:00`
(0.23.2 release), supervisor merge `TASK-1115@2026-09-16T10:10:09+00:00`.

`supervision.py` carries the Codex interactive supervisor totals as constants; they
come from a per-event counter analysis of the Codex session store (resets and
forked subagents handled) that a last-value read cannot reproduce. The August
AXON counts in `build_report.py` come from the 0.21.0 release notes.
