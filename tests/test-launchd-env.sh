#!/usr/bin/env bash
set -euo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$msg: missing '$needle' in: $haystack"
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="$3"
  [[ "$haystack" != *"$needle"* ]] || fail "$msg: unexpectedly found '$needle' in: $haystack"
}

test_launchd_wrapper_sources_env_and_defaults_autonomy_flags() {
  local tmp consumer fake_codex codex_home env_file out
  tmp="$(mktemp -d)"
  consumer="$tmp/consumer"
  fake_codex="$tmp/codex"
  codex_home="$tmp/codex-home"
  env_file="$tmp/singular.env"
  mkdir -p "$consumer" "$codex_home"
  consumer="$(cd "$consumer" && pwd -P)"
  printf '{}\n' >"$codex_home/auth.json"
  cat >"$fake_codex" <<'EOF'
#!/usr/bin/env bash
echo "codex 0.0-test"
EOF
  chmod +x "$fake_codex"
  cat >"$env_file" <<'EOF'
SINGULAR_STORAGE_PROOF_DATABASE_URL=postgres://singular-secret.example/proof
SINGULAR_ROOT=/stale/consumer
SINGULAR_ENGINE_HOME=/stale/engine
EOF

  out="$(
    HOME="$tmp/home" \
    CODEX_HOME="$codex_home" \
    CODEX_BIN="$fake_codex" \
    SINGULAR_ROOT="$consumer" \
    SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
    SINGULAR_ENV_FILE="$env_file" \
    SINGULAR_LAUNCHD_MODE=--print-env \
    bash "$ENGINE_HOME/templates/launchd/run-orchestrator.sh"
  )"

  assert_contains "$out" "SINGULAR_ROOT=$consumer" "consumer repo is explicit"
  assert_contains "$out" "SINGULAR_ENGINE_HOME=$ENGINE_HOME" "engine home is explicit"
  assert_contains "$out" "SINGULAR_ENV_FILE=$env_file" "env file path is reported"
  assert_contains "$out" "SINGULAR_STORAGE_PROOF_DATABASE_URL=SET" "storage proof DSN is loaded without disclosure"
  assert_contains "$out" "SINGULAR_AUTO_PROMOTE_GATES=1" "auto gate promotion defaults on"
  assert_contains "$out" "SINGULAR_L2_SANDBOX=danger-full-access" "network-capable L2 sandbox defaults on"
  assert_contains "$out" "SINGULAR_ENABLE_L1_PARALLEL=1" "parallel L1 defaults on"
  assert_contains "$out" "SINGULAR_MAX_L1_CONCURRENT=auto" "parallel L1 cap defaults to auto (half the worker ceiling)"
  assert_contains "$out" "SINGULAR_L1_TASKS_PER_NODE=1" "per-node L1 task cap defaults to 1"
  assert_contains "$out" "SINGULAR_L2_SLICE_BUDGET=1" "per-task slice budget defaults to 1 (byte-identical)"
  assert_contains "$out" "SINGULAR_L2_SLICE_BUDGET_MAX=3" "slice budget cap defaults to 3"
  assert_contains "$out" "SINGULAR_MAX_CONCURRENT=auto" "worker concurrency cap defaults to the machine-sized ceiling"
  assert_contains "$out" "SINGULAR_MAX_DISPATCH=auto" "dispatch cap defaults to the effective ceiling"
  assert_contains "$out" "SINGULAR_MAX_HOURS=12" "watchdog time box defaults to 12 hours"
  assert_contains "$out" "SINGULAR_CODEX_BIN=$fake_codex" "legacy CODEX_BIN maps to canonical Codex pin"
  assert_not_contains "$out" "singular-secret.example" "database URL is not printed"

  local preferred_codex="$tmp/preferred codex"
  cp "$fake_codex" "$preferred_codex"
  chmod +x "$preferred_codex"
  out="$(
    HOME="$tmp/home" \
    CODEX_HOME="$codex_home" \
    CODEX_BIN="$fake_codex" \
    SINGULAR_CODEX_BIN="$preferred_codex" \
    SINGULAR_BASH_BIN="$BASH" \
    SINGULAR_ROOT="$consumer" \
    SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
    SINGULAR_ENV_FILE="$env_file" \
    SINGULAR_LAUNCHD_MODE=--print-env \
    bash "$ENGINE_HOME/templates/launchd/run-orchestrator.sh"
  )"
  assert_contains "$out" "SINGULAR_CODEX_BIN=$preferred_codex" "canonical Codex pin wins alias"
  assert_contains "$out" "SINGULAR_BASH_BIN=$BASH" "bootstrap Bash pin is preserved"
}

test_launchd_installer_renders_executable_placeholder_free_plist() {
  local tmp test_home consumer nested dest target_branch
  tmp="$(mktemp -d)"
  test_home="$tmp/home"
  consumer="$tmp/consumer repo & fixtures"
  nested="$consumer/nested"
  dest="$test_home/Library/LaunchAgents/com.singular.orchestrator.plist"
  target_branch="codex/test-launchd-target"

  mkdir -p "$nested"
  git -C "$consumer" init -q

  if HOME="$test_home" bash "$ENGINE_HOME/templates/launchd/install.sh" >/dev/null 2>&1; then
    fail "installer accepted a missing explicit consumer repo path"
  fi

  HOME="$test_home" SINGULAR_TARGET_BRANCH="$target_branch" \
    bash "$ENGINE_HOME/templates/launchd/install.sh" "$nested"

  [[ -f "$dest" ]] || fail "installer did not generate $dest"
  if grep -Eq '__SINGULAR_[A-Z0-9_]+__' "$dest"; then
    fail "generated plist retains a __SINGULAR_*__ placeholder"
  fi

  python3 - "$dest" "$consumer" "$ENGINE_HOME" "$target_branch" <<'PY'
import os
import plistlib
import sys

plist_path, consumer, engine_home, target_branch = sys.argv[1:]
consumer = os.path.realpath(consumer)
engine_home = os.path.realpath(engine_home)

with open(plist_path, "rb") as fh:
    plist = plistlib.load(fh)

args = plist.get("ProgramArguments", [])
if len(args) != 3 or args[0] != "/bin/bash" or args[2] != "--watchdog":
    raise SystemExit(f"unexpected ProgramArguments: {args!r}")

runner = args[1]
expected_runner = os.path.join(engine_home, "templates", "launchd", "run-orchestrator.sh")
if runner != expected_runner:
    raise SystemExit(f"runner mismatch: {runner!r} != {expected_runner!r}")
if not os.path.isfile(runner) or not os.access(runner, os.X_OK):
    raise SystemExit(f"ProgramArguments target is not executable: {runner!r}")

env = plist.get("EnvironmentVariables", {})
expected_env = {
    "SINGULAR_ROOT": consumer,
    "SINGULAR_ENGINE_HOME": engine_home,
    "SINGULAR_TARGET_BRANCH": target_branch,
}
for key, expected in expected_env.items():
    if env.get(key) != expected:
        raise SystemExit(f"{key} mismatch: {env.get(key)!r} != {expected!r}")

state_dir = os.path.join(consumer, ".singular-state")
if plist.get("StandardOutPath") != os.path.join(state_dir, "launchd.out.log"):
    raise SystemExit("StandardOutPath did not retain consumer state semantics")
if plist.get("StandardErrorPath") != os.path.join(state_dir, "launchd.err.log"):
    raise SystemExit("StandardErrorPath did not retain consumer state semantics")
PY
}

test_launchd_wrapper_sources_env_and_defaults_autonomy_flags
test_launchd_installer_renders_executable_placeholder_free_plist

echo "test-launchd-env: ok"
