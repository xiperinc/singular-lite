# Token-efficiency analysis

Scripts behind `../report-token-efficiency.html`. All are read-only on their inputs.

```
python3 ledger.py <repo-root> <integration-branch> brain-ledger.json
python3 figures.py brain-ledger.json brain-figures.json
python3 supervision.py <repo>/.singular-state <claude-project-dir> 2026-09-16T10:11:14+00:00 supervision.json
python3 build_report.py brain-ledger.json brain-figures.json supervision.json report.html
```

`supervision.py` carries the Codex interactive supervisor totals as constants; they
come from a per-event counter analysis of the Codex session store (resets and
forked subagents handled) that a last-value read cannot reproduce.
