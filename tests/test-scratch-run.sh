#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

repo="$tmp/repo"
worker="$tmp/worker"
mkdir -p "$repo"
git -C "$repo" init -q
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture
printf '.singular-state/\nnode_modules/\n' >"$repo/.gitignore"
printf 'base\n' >"$repo/app.txt"
mkdir "$tmp/overlay-target"
ln -s "$tmp/overlay-target" "$repo/linked"
git -C "$repo" add .
git -C "$repo" commit -qm base
base="$(git -C "$repo" rev-parse HEAD)"
printf 'candidate\n' >"$repo/app.txt"
mkdir -p "$repo/proof tests"
printf 'test "$(cat app.txt)" = candidate\n' >"$repo/proof tests/check.sh"
rm "$repo/linked"
mkdir "$repo/linked"
cp "$repo/proof tests/check.sh" "$repo/linked/check.sh"
git -C "$repo" add .
git -C "$repo" commit -qm candidate
candidate="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" worktree add --detach -q "$worker" "$candidate"
printf 'worker changes\n' >"$worker/app.txt"
printf 'untracked\n' >"$worker/personal-work.txt"
mkdir -p "$repo/node_modules" "$worker/node_modules"
printf main >"$repo/node_modules/dependency"
printf worker >"$worker/node_modules/dependency"

export SINGULAR_ROOT="$repo" SINGULAR_STATE_DIR="$repo/.singular-state"
export SINGULAR_ENGINE_HOME="$ROOT" SINGULAR_ENGINE_DIR="$tmp/context-only"
export SINGULAR_LOCAL_CONFIG_FILE=/dev/null SINGULAR_BOOTSTRAP_JSON='{}'
export SINGULAR_PUSH=0
mkdir -p "$SINGULAR_ENGINE_DIR"

run_scratch() {
  local commit="$1" command="$2" expected="$3"
  shift 3
  local rc=0
  bash "$ROOT/engine/scratch-run.sh" --commit "$commit" --command "$command" \
    --log "$tmp/command.log" "$@" >"$tmp/result.json" 2>"$tmp/driver.err" || rc=$?
  [[ "$rc" == "$expected" ]] || {
    cat "$tmp/driver.err" >&2
    fail "scratch runner exit: expected $expected, got $rc"
  }
}

assert_result() {
  python3 - "$tmp/result.json" "$@" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
raw, timed, integrity, setup = sys.argv[2:6]
assert result["rawExitCode"] == (None if raw == "null" else int(raw)), result
assert result["timedOut"] == (timed == "true"), result
assert result["sourceIntegrity"]["status"] == integrity, result
assert result["setupError"] == (None if setup == "null" else setup), result
PY
}

# The new default is state-local, with copied main-checkout dependencies.
run_scratch "$base" 'set -e; test "$(cat app.txt)" = base; test "$(cat node_modules/dependency)" = main; printf "%s\n%s\n" "$PWD" "$TMPDIR"; printf changed >node_modules/dependency' 0
assert_result 0 false verified null
python3 - "$tmp/command.log" "$SINGULAR_STATE_DIR" <<'PY'
import pathlib, sys
paths = pathlib.Path(sys.argv[1]).read_text().splitlines()
assert len(paths) == 2, paths
for path in paths:
    assert pathlib.Path(sys.argv[2]) in pathlib.Path(path).parents, paths
    assert not pathlib.Path(path).exists(), paths
PY
[[ "$(cat "$repo/node_modules/dependency")" == main ]] || fail 'dependency copy mutated main'

run_scratch "$candidate" 'bash "proof tests/check.sh"' 0
assert_result 0 false verified null
run_scratch "$base" 'bash "proof tests/check.sh"' 0 \
  --overlay-commit "$candidate" --overlay-path 'proof tests/check.sh'
assert_result 1 false verified null
run_scratch "$base" 'test "$(cat app.txt)" = candidate' 0 \
  --overlay-commit "$candidate" --overlay-path app.txt
assert_result 0 false verified null

for code in 0 1 126 127; do
  run_scratch "$candidate" "printf 'AssertionError infrastructure failed'; exit $code" 0
  assert_result "$code" false verified null
done

run_scratch "$base" 'deadline=$((SECONDS + 5)); while ((SECONDS < deadline)); do :; done; exit 7' 0 --timeout 1
assert_result 124 true verified null

run_scratch invalid true 20
assert_result null false not-checked commit-unavailable
run_scratch "$base" true 20 --scratch-parent "$repo/app.txt"
assert_result null false not-checked scratch-create-failed
run_scratch "$base" "touch '$tmp/missing-parent-command-ran'" 20 \
  --scratch-parent "$tmp/missing-parent"
assert_result null false not-checked scratch-create-failed
[[ ! -e "$tmp/missing-parent" ]] || fail 'explicit missing scratch parent was created'
[[ ! -e "$tmp/missing-parent-command-ran" ]] || fail 'missing scratch parent ran the command'
run_scratch "$base" true 20 --overlay-commit "$candidate" --overlay-path ../escape
assert_result null false not-checked overlay-failed
run_scratch "$base" true 20 --overlay-commit "$candidate" --overlay-path missing
assert_result null false not-checked overlay-failed
run_scratch "$base" true 20 --overlay-commit "$candidate" --overlay-path linked/check.sh
assert_result null false not-checked overlay-failed
[[ ! -e "$tmp/overlay-target/check.sh" ]] || fail 'overlay wrote through a symlink outside scratch'
run_scratch "$base" true 20 --observation "$repo"
assert_result null false not-checked observation-prepare-failed

run_scratch "$base" 'printf mutated > app.txt' 0
assert_result 0 false violation null
python3 - "$tmp/result.json" <<'PY'
import json, sys
assert "app.txt" in json.load(open(sys.argv[1]))["sourceIntegrity"]["changedPaths"]
PY
run_scratch "$base" 'cp app.txt "$TMPDIR/original"; printf temporary >app.txt; cp "$TMPDIR/original" app.txt' 0
assert_result 0 false violation null

# Explicit audit-style overrides preserve its worker dependencies and location.
mkdir -p "$tmp/audit-scratch"
run_scratch "$base" 'set -e; test "$(cat node_modules/dependency)" = worker; pwd' 0 \
  --scratch-parent "$tmp/audit-scratch" --dependency-source "$worker" \
  --source-worktree "$worker" --timeout 0
assert_result 0 false verified null
[[ "$(cat "$tmp/command.log")" == "$tmp/audit-scratch/"* ]] || fail 'scratch parent override ignored'
[[ "$(git -C "$worker" rev-parse HEAD)" == "$candidate" ]] || fail 'worker HEAD changed'
[[ "$(cat "$worker/app.txt")" == 'worker changes' ]] || fail 'worker source changed'
[[ "$(cat "$worker/personal-work.txt")" == untracked ]] || fail 'worker untracked file changed'
[[ "$(cat "$worker/node_modules/dependency")" == worker ]] || fail 'worker dependency changed'
[[ "$(git -C "$repo" worktree list --porcelain | grep -c '^worktree ')" == 2 ]] || fail 'scratch worktree leaked'
echo 'PASS: scratch runner defaults, overlays, outcomes, integrity, cleanup, worker preservation'
