#!/usr/bin/env bash
# Checks release fields, the latest three headings and schema v2; allows a leading
# Unreleased section. Changelog wording and manifest prose require reader review.
release_nonce="${RAILS_NONCE:-}"
release_verdict_file="${RAILS_VERDICT_FILE:-}"
unset RAILS_NONCE RAILS_VERDICT_FILE
set -euo pipefail
export SINGULAR_PUSH=0

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Read the release identity from this checkout, never from an installed engine.
# No release number is pinned here: a future release must keep the same contract.
if ! python3 - "$ROOT" >"$tmp/result" 2>&1 <<'PY'
import datetime
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
version = (root / "VERSION").read_text(encoding="utf-8").strip()
errors = []

def check(condition, message):
    if not condition:
        errors.append(message)

check(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version),
      "VERSION must contain a semantic release version")
check((root / ".singular-version").read_text(encoding="utf-8").strip() == version,
      ".singular-version must equal VERSION")
for name, field in (
    ("singular.config.json", "engineVersion"),
    ("templates/singular.config.json", "engineVersion"),
    ("plugin/.codex-plugin/plugin.json", "version"),
):
    data = json.loads((root / name).read_text(encoding="utf-8"))
    check(data.get(field) == version, f"{name}: {field} must equal VERSION")

check((root / "SCHEMA_VERSION").read_text(encoding="utf-8").strip() == "v2",
      "SCHEMA_VERSION must remain v2")
headings = [line for line in (root / "CHANGELOG.md").read_text(encoding="utf-8").splitlines()
            if line.startswith("## ")]
if headings and headings[0].rstrip() == "## Unreleased":
    headings = headings[1:]
check(len(headings) >= 3, "CHANGELOG.md must retain the latest three release headings")
release_versions = []
for index, heading in enumerate(headings[:3]):
    match = re.fullmatch(r"## \[([0-9]+\.[0-9]+\.[0-9]+)\] — ([0-9]{4}-[0-9]{2}-[0-9]{2}) — (\S.*)", heading)
    check(match is not None, f"CHANGELOG.md: malformed release heading: {heading}")
    if match:
        release_versions.append(tuple(map(int, match[1].split("."))))
        if index == 0:
            check(match[1] == version, "CHANGELOG.md: first release heading must equal VERSION")
        try:
            datetime.date.fromisoformat(match[2])
        except ValueError:
            errors.append(f"CHANGELOG.md: invalid release date: {match[2]}")
check(all(newer > older for newer, older in zip(release_versions, release_versions[1:])),
      "CHANGELOG.md: latest three release versions must be distinct and descending")

if errors:
    print("\n".join(f"FAIL: {message}" for message in errors), file=sys.stderr)
    sys.exit(1)
print("release identity tests passed")
PY
then
  cat "$tmp/result" >&2
  exit 1
fi
cat "$tmp/result"
rm -rf "$tmp"
trap - EXIT

# The verdict is emitted only after every assertion and cleanup succeeded.
if [[ -n "$release_verdict_file" ]]; then
  printf '%s\n' "$release_nonce" >"$release_verdict_file"
fi
