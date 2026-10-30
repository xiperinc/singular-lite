#!/usr/bin/env bash
set -euo pipefail

# launchd entry point for the singular bootstrap orchestrator.
#
# launchd jobs run with a minimal environment: no user PATH, possibly no HOME.
# This wrapper reconstructs enough environment for git, go, and the Codex CLI to
# run, confirms the Codex (ChatGPT) credential is readable, then invokes the
# reconciler. The mode is the first argument (default: --actuate).
#
# install.sh pins both the consumer repository and engine home in the plist.
# Requiring the consumer root prevents a versioned engine install from
# accidentally orchestrating its own checkout.

mode="${1:-${SINGULAR_LAUNCHD_MODE:---watchdog}}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
engine_home="${SINGULAR_ENGINE_HOME:-$(cd "$script_dir/../.." && pwd -P)}"
repo_root="${SINGULAR_ROOT:-}"

if [[ -z "$repo_root" || ! -d "$repo_root" ]]; then
  echo "ERROR: SINGULAR_ROOT must name an existing consumer repository" >&2
  exit 1
fi
repo_root="$(cd "$repo_root" && pwd -P)"
if [[ ! -d "$engine_home/engine" ]]; then
  echo "ERROR: SINGULAR_ENGINE_HOME does not contain the engine: $engine_home" >&2
  exit 1
fi
engine_home="$(cd "$engine_home" && pwd -P)"
export SINGULAR_ROOT="$repo_root"
export SINGULAR_ENGINE_HOME="$engine_home"

# HOME is required for git config and for Codex to find ~/.codex/auth.json.
export HOME="${HOME:-$(/usr/bin/id -P "$(/usr/bin/id -un)" 2>/dev/null | cut -d: -f9)}"
export HOME="${HOME:-/Users/$(/usr/bin/id -un)}"
export CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"

# Load local operational configuration, including proof database credentials.
# Keep it local to .singular-state; it is intentionally not committed control state.
export SINGULAR_ENV_FILE="${SINGULAR_ENV_FILE:-$repo_root/.singular-state/.env}"
if [[ -f "$SINGULAR_ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$SINGULAR_ENV_FILE"
  set +a
fi
# The plist's repository and engine pins are identity, not tunable operational
# settings. Do not let a stale local env file redirect the LaunchAgent.
export SINGULAR_ROOT="$repo_root"
export SINGULAR_ENGINE_HOME="$engine_home"

# Resolve a working codex binary. SINGULAR_CODEX_BIN is canonical; CODEX_BIN is
# retained as a deprecated launchd-only fallback. The selected path is exported
# so doctor and codex-run execute exactly what this preflight checks.
codex_bin="${SINGULAR_CODEX_BIN:-${CODEX_BIN:-}}"
if [[ -z "$codex_bin" ]]; then
  for cand in \
    "/Applications/Codex.app/Contents/Resources/codex" \
    "$HOME/.local/bin/codex"; do
    if [[ -x "$cand" ]]; then codex_bin="$cand"; break; fi
  done
fi

# Standard tool locations; executable pinning deliberately does not prepend a
# provider or shell directory to PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
if [[ -z "$codex_bin" ]]; then
  codex_bin="$(command -v codex 2>/dev/null || true)"
fi
if [[ -n "$codex_bin" ]]; then
  export SINGULAR_CODEX_BIN="$codex_bin"
fi

export SINGULAR_TARGET_BRANCH="${SINGULAR_TARGET_BRANCH:-codex/singular-bootstrap-target}"
# Full autonomy for unattended runs.
export SINGULAR_AUTO_INTEGRATE="${SINGULAR_AUTO_INTEGRATE:-1}"
export SINGULAR_PUSH="${SINGULAR_PUSH:-1}"
export SINGULAR_GENERATE="${SINGULAR_GENERATE:-1}"
export SINGULAR_AUTO_PROMOTE_GATES="${SINGULAR_AUTO_PROMOTE_GATES:-1}"
export SINGULAR_L2_SANDBOX="${SINGULAR_L2_SANDBOX:-danger-full-access}"
export SINGULAR_ENABLE_L1_PARALLEL="${SINGULAR_ENABLE_L1_PARALLEL:-1}"
export SINGULAR_MAX_L1_CONCURRENT="${SINGULAR_MAX_L1_CONCURRENT:-auto}"
export SINGULAR_L1_TASKS_PER_NODE="${SINGULAR_L1_TASKS_PER_NODE:-1}"
export SINGULAR_L2_SLICE_BUDGET="${SINGULAR_L2_SLICE_BUDGET:-1}"
export SINGULAR_L2_SLICE_BUDGET_MAX="${SINGULAR_L2_SLICE_BUDGET_MAX:-3}"
# auto = sized from this machine every cycle (cores, available memory, disk),
# and held while it is saturated. An integer pins a fixed ceiling instead.
export SINGULAR_MAX_CONCURRENT="${SINGULAR_MAX_CONCURRENT:-auto}"
export SINGULAR_MAX_DISPATCH="${SINGULAR_MAX_DISPATCH:-auto}"
export SINGULAR_MAX_HOURS="${SINGULAR_MAX_HOURS:-12}"
# Default 1 = fire-and-forget dispatch (reconcile returns in seconds; the
# reaper attributes worker outcomes on later cycles). Set 0 for legacy batch wait.
export SINGULAR_DETACHED_DISPATCH="${SINGULAR_DETACHED_DISPATCH:-1}"

if [[ "$mode" == "--print-env" ]]; then
  echo "SINGULAR_ROOT=$SINGULAR_ROOT"
  echo "SINGULAR_ENGINE_HOME=$SINGULAR_ENGINE_HOME"
  echo "SINGULAR_ENV_FILE=$SINGULAR_ENV_FILE"
  echo "SINGULAR_STORAGE_PROOF_DATABASE_URL=${SINGULAR_STORAGE_PROOF_DATABASE_URL:+SET}"
  echo "SINGULAR_AUTO_PROMOTE_GATES=$SINGULAR_AUTO_PROMOTE_GATES"
  echo "SINGULAR_L2_SANDBOX=$SINGULAR_L2_SANDBOX"
  echo "SINGULAR_ENABLE_L1_PARALLEL=$SINGULAR_ENABLE_L1_PARALLEL"
  echo "SINGULAR_MAX_L1_CONCURRENT=$SINGULAR_MAX_L1_CONCURRENT"
  echo "SINGULAR_L1_TASKS_PER_NODE=$SINGULAR_L1_TASKS_PER_NODE"
  echo "SINGULAR_L2_SLICE_BUDGET=$SINGULAR_L2_SLICE_BUDGET"
  echo "SINGULAR_L2_SLICE_BUDGET_MAX=$SINGULAR_L2_SLICE_BUDGET_MAX"
  echo "SINGULAR_MAX_CONCURRENT=$SINGULAR_MAX_CONCURRENT"
  echo "SINGULAR_MAX_DISPATCH=$SINGULAR_MAX_DISPATCH"
  echo "SINGULAR_MAX_HOURS=$SINGULAR_MAX_HOURS"
  echo "SINGULAR_DETACHED_DISPATCH=$SINGULAR_DETACHED_DISPATCH"
  echo "SINGULAR_CODEX_BIN=${SINGULAR_CODEX_BIN:-}"
  echo "SINGULAR_BASH_BIN=${SINGULAR_BASH_BIN:-}"
  exit 0
fi

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

fail=0
if ! command -v git >/dev/null 2>&1; then log "ERROR: git not found on PATH ($PATH)"; fail=1; fi
if ! command -v go  >/dev/null 2>&1; then log "ERROR: go not found on PATH ($PATH)"; fail=1; fi

# The reconciler uses mapfile (bash >= 4). Prefer the bootstrap-only explicit
# path; otherwise retain the existing PATH/Homebrew fallback.
bash_bin="${SINGULAR_BASH_BIN:-}"
if [[ -n "$bash_bin" && ( "$bash_bin" != /* || ! -x "$bash_bin" ) ]]; then
  log "ERROR: SINGULAR_BASH_BIN must be an absolute executable path ($bash_bin)"
  fail=1
elif [[ -z "$bash_bin" ]]; then
  bash_bin="$(command -v bash 2>/dev/null || true)"
  if [[ -z "$bash_bin" ]] || ! "$bash_bin" -c '[[ "${BASH_VERSINFO[0]}" -ge 4 ]]' 2>/dev/null; then
    [[ -x /opt/homebrew/bin/bash ]] && bash_bin=/opt/homebrew/bin/bash
  fi
fi
if [[ -z "$bash_bin" ]] || ! "$bash_bin" -c '[[ "${BASH_VERSINFO[0]}" -ge 4 ]]' 2>/dev/null; then
  log "ERROR: bash >= 4 not found (set SINGULAR_BASH_BIN or run 'brew install bash')"
  fail=1
else
  export SINGULAR_BASH_BIN="$bash_bin"
fi

# Resolve and FUNCTIONALLY test codex (an executable bit is not enough; the
# Homebrew codex shim is broken on some setups).
codex_check="${SINGULAR_CODEX_BIN:-}"
if [[ -z "$codex_check" || "$codex_check" != /* || ! -x "$codex_check" ]]; then
  log "ERROR: SINGULAR_CODEX_BIN must resolve to an absolute executable path ($codex_check)"
  fail=1
elif "$codex_check" --version >/dev/null 2>&1; then
  log "codex: $codex_check ($("$codex_check" --version 2>/dev/null | head -1))"
else
  log "ERROR: codex not runnable ($codex_check); set SINGULAR_CODEX_BIN to a working binary"; fail=1
fi

if [[ ! -r "$CODEX_HOME/auth.json" ]]; then
  log "ERROR: Codex credential not readable at $CODEX_HOME/auth.json"; fail=1
fi
if [[ "$fail" -ne 0 ]]; then
  log "environment check failed; aborting orchestrator run"
  exit 1
fi

log "repo_root=$repo_root mode=$mode target=$SINGULAR_TARGET_BRANCH"
cd "$repo_root"
# Watchdog: (re)launch the self-driving loop; autonomate's pidfile guard makes
# this a no-op if it is already running. Any other mode runs a single reconcile.
case "$mode" in
  --watchdog) exec "$bash_bin" "$engine_home/engine/autonomate.sh" ;;
  *)          exec "$bash_bin" "$engine_home/engine/reconcile.sh" "$mode" ;;
esac
