#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
destination="${1:?usage: record.sh NEW_ABSOLUTE_DIRECTORY}"
[[ "$destination" == /* && ! -e "$destination" ]]
scratch="$(mktemp -d "${TMPDIR:-/tmp}/singular-upgrade-record.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/engine" "$scratch/project" "$scratch/isolated-home"
git -C "$repo" archive a3c1c77a41722100e3639e5f545f4304c459587f |
  tar -x -C "$scratch/engine"
git -C "$scratch/project" init -q
(
  cd "$scratch/project"
  env -i PATH="$PATH" HOME="$scratch/isolated-home" \
    SINGULAR_HOME="$scratch/isolated-home/engine-home" \
    SINGULAR_ENGINE_HOME="$scratch/engine" \
    SINGULAR_STATE_DIR="$scratch/project/.singular-state" SINGULAR_PUSH=0 \
    bash "$scratch/engine/cli/singular" init
)
python3 - "$scratch/project" "$destination" <<'PY'
import hashlib
import json
from pathlib import Path
import shutil
import sys

source, destination = map(Path, sys.argv[1:])
destination.mkdir()
scaffold = destination / "scaffold"
shutil.copytree(source, scaffold, ignore=shutil.ignore_patterns(".git", ".singular-state"))
path = scaffold / "singular.config.json"
config = json.loads(path.read_text())
for role in config["identity"].values():
    role["email"] = "fixture"
path.write_text(json.dumps(config, indent=2) + "\n")
manifest = {str(p.relative_to(scaffold)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(scaffold.rglob("*")) if p.is_file()}
(destination / "sha256.json").write_text(json.dumps(manifest, indent=2) + "\n")
PY
