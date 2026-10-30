# Security Policy

singular runs repo-configured shell commands and launches local coding agents in
git worktrees. Treat a repo's `singular.config.json`, `singular.config.sh`, task
files, and opt-in modules as executable trust boundaries.

## Reporting a vulnerability

This policy does not yet provide a working private reporting channel. GitHub's
private vulnerability reporting is disabled for this repository; public issues
are not a supported fallback.

The proposed channel is GitHub private vulnerability reporting. It awaits the
repository owners' decision and activation, or their choice of another monitored
private channel. The owners must publish the confirmed reporting instructions
here once the channel works. Until then, do not post exploit details,
credentials, or proof-of-concept payloads publicly.

## Handling credentials

Do not commit credentials, `.env` files, `.singular-state/`, `.worktrees/`,
`.singular-evidence/`, or generated run artifacts. Runtime operator overrides and
secrets belong in `.singular-state/config.local.sh`, which is gitignored by the
scaffold.
