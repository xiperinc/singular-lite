#!/usr/bin/env bash
set -euo pipefail

# Run a command at a commit in a disposable worktree. JSON is written to stdout;
# command output goes to --log. Exit 0 means the command was observed (including
# nonzero rawExitCode, timeout, or source mutation); exit 20 means setup failed
# and rawExitCode is null. Exit 2 is invalid usage. Callers classify observations.
#
# Required: --commit REV --command SHELL_COMMAND --log FILE
# Optional: --timeout SECONDS (1200; 0 disables), --scratch-parent DIR
# (SINGULAR_STATE_DIR), --dependency-source DIR (SINGULAR_ROOT),
# --source-worktree DIR (dependency source, monitored for changes),
# --overlay-commit REV --overlay-path FILE (repeatable, literal tracked files).
# Overlay files are the integrity baseline, not mutations made by the command.
# Audit compatibility: --scratch-prefix NAME, --observation FILE,
# --log-label TEXT, --force-setup-failure.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
head_sha=""
gate_command=""
log=""
gate_timeout=1200
scratch_parent="$SINGULAR_STATE_DIR"
scratch_parent_explicit=no
scratch_prefix=singular-scratch
dependency_source="$SINGULAR_ROOT"
source_worktree=""
overlay_commit=""
overlay_paths=()
observation=""
log_label="scratch run"
force_setup_failure=no
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force-setup-failure) force_setup_failure=yes; shift; continue ;;
  esac
  [[ $# -ge 2 && -n "$2" ]] || { echo "scratch-run: option requires a value" >&2; exit 2; }
  case "$1" in
    --commit) head_sha="$2" ;;
    --command) gate_command="$2" ;;
    --log) log="$2" ;;
    --timeout) gate_timeout="$2" ;;
    --scratch-parent) scratch_parent="$2"; scratch_parent_explicit=yes ;;
    --scratch-prefix) scratch_prefix="$2" ;;
    --dependency-source) dependency_source="$2" ;;
    --source-worktree) source_worktree="$2" ;;
    --overlay-commit) overlay_commit="$2" ;;
    --overlay-path) overlay_paths+=("$2") ;;
    --observation) observation="$2" ;;
    --log-label) log_label="$2" ;;
    *) echo "scratch-run: unknown option: $1" >&2; exit 2 ;;
  esac
  shift 2
done
[[ -n "$head_sha" && -n "$gate_command" && -n "$log" \
   && "$gate_timeout" =~ ^[0-9]+$ && "$scratch_prefix" =~ ^[A-Za-z0-9_.-]+$ ]] || {
  echo "scratch-run: commit, command, log, and valid timeout/prefix required" >&2
  exit 2
}
[[ ${#overlay_paths[@]} -eq 0 || -n "$overlay_commit" ]] || {
  echo "scratch-run: overlay paths require an overlay commit" >&2
  exit 2
}
[[ -n "$source_worktree" ]] || source_worktree="$dependency_source"

sandbox_base=""
verify_worktree=""
worktree_added=no
gate_exit=""
gate_timed_out=no
integrity_status=not-checked
changed_paths=()
duration_ms=0
setup_error=""

emit_result() {
  python3 - "$gate_exit" "$gate_timed_out" "$integrity_status" \
    "$duration_ms" "$setup_error" "${changed_paths[@]}" <<'PYRESULT'
import json
import sys
raw, timed, integrity, duration, setup, *paths = sys.argv[1:]
print(json.dumps({
    "rawExitCode": int(raw) if raw else None,
    "timedOut": timed == "yes",
    "durationMs": int(duration),
    "sourceIntegrity": {"status": integrity, "changedPaths": paths},
    "setupError": setup or None,
}, separators=(",", ":")))
PYRESULT
}

emit_setup_failure() {
  setup_error="$1"
  gate_exit=""
  printf '%s setup failed: %s\n' "$log_label" "$setup_error" >"$log" || true
  emit_result
  return 20
}

cleanup() {
  if [[ "$worktree_added" == "yes" ]]; then
    if singular_git_lock_acquire 2>/dev/null; then
      git -C "$SINGULAR_ROOT" worktree remove --force "$verify_worktree" >/dev/null 2>&1 || true
      git -C "$SINGULAR_ROOT" worktree prune >/dev/null 2>&1 || true
      singular_git_lock_release
    fi
  fi
  [[ -z "$sandbox_base" ]] || rm -rf "$sandbox_base"
}
trap cleanup EXIT

# Only literal regular files and symlinks from Git objects are laid over the
# disposable checkout. Never follow a checkout symlink while writing an overlay.
apply_overlay() {
  python3 - "$verify_worktree" "$overlay_commit" "${overlay_paths[@]}" <<'PYOVERLAY'
import os
from pathlib import Path
import subprocess
import sys

root, revision, *paths = sys.argv[1:]
def git(*args):
    return subprocess.check_output(["git", "-C", root, *args])
revision = git("rev-parse", "--verify", "--end-of-options", revision + "^{commit}").decode().strip()
for relative in paths:
    parts = relative.split("/")
    if any(p in ("", ".", "..", ".git") for p in parts):
        raise ValueError("overlay requires a clean relative file path")
    record = git("--literal-pathspecs", "ls-tree", "-z", revision, "--", relative)
    entry, name = record.rstrip(b"\0").split(b"\t", 1)
    mode, kind, oid = entry.decode().split()
    if os.fsdecode(name) != relative or kind != "blob" or mode not in ("100644", "100755", "120000"):
        raise ValueError("overlay requires a tracked file")
    target = Path(root)
    for part in parts[:-1]:
        target /= part
        if target.is_symlink():
            raise ValueError("overlay parent is a symlink")
        target.mkdir(exist_ok=True)
    target /= parts[-1]
    if target.is_symlink() or target.is_file():
        target.unlink()
    content = git("cat-file", "blob", oid)
    if mode == "120000":
        target.symlink_to(os.fsdecode(content))
    else:
        target.write_bytes(content)
        target.chmod(0o755 if mode == "100755" else 0o644)
    git("--literal-pathspecs", "add", "-f", "--", relative)
PYOVERLAY
}

workspace_fingerprint() {
  python3 - "$1" <<'PY'
import hashlib
import subprocess
import sys

root = sys.argv[1]
head = subprocess.run(
    ["git", "-C", root, "rev-parse", "HEAD"],
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    check=False,
).stdout
status = subprocess.run(
    ["git", "-C", root, "status", "--porcelain=v1", "--untracked-files=all"],
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    check=False,
).stdout
print(hashlib.sha256(head + b"\0" + status).hexdigest())
PY
}

tracked_source_snapshot() {
  python3 - "$1" "$2" <<'PY'
import json
import os
import stat
import subprocess
import sys

root, output = sys.argv[1:3]
result = subprocess.run(
    ["git", "-C", root, "ls-files", "-z"],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    check=False,
)
if result.returncode:
    sys.stderr.buffer.write(result.stderr)
    raise SystemExit(result.returncode)

snapshot = {}
for raw in result.stdout.split(b"\0"):
    if not raw:
        continue
    relative = os.fsdecode(raw)
    path = os.path.join(root, relative)
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        snapshot[relative] = {"missing": True}
        continue
    snapshot[relative] = {
        "device": info.st_dev,
        "inode": info.st_ino,
        "kind": stat.S_IFMT(info.st_mode),
        "mode": stat.S_IMODE(info.st_mode),
        "size": info.st_size,
        # Reads may update atime. Writes, replacements, and chmod operations
        # necessarily change at least ctime on supported audit hosts, even if a
        # command restores the original bytes and mtime before it exits.
        "mtimeNs": info.st_mtime_ns,
        "ctimeNs": info.st_ctime_ns,
    }

temporary = output + ".tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(snapshot, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
os.replace(temporary, output)
PY
}

tracked_source_changes() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

before_path, after_path = sys.argv[1:3]
with open(before_path, encoding="utf-8") as handle:
    before = json.load(handle)
with open(after_path, encoding="utf-8") as handle:
    after = json.load(handle)
for path in sorted(set(before) | set(after)):
    if before.get(path) != after.get(path):
        print(path)
PY
}

if ! : >"$log"; then
  emit_setup_failure "log-create-failed"
  exit $?
fi
resolved_commit="$(git -C "$SINGULAR_ROOT" rev-parse --verify --end-of-options "$head_sha^{commit}" 2>/dev/null)" || {
  emit_setup_failure "commit-unavailable"
  exit $?
}
head_sha="$resolved_commit"
if [[ ! -d "$dependency_source" || ! -d "$source_worktree" ]]; then
  emit_setup_failure "source-worktree-unavailable"
  exit $?
fi
# Only the runner's default state directory may be created on demand.
if [[ "$scratch_parent_explicit" == no ]] && ! mkdir -p "$scratch_parent" 2>/dev/null; then
  emit_setup_failure "scratch-create-failed"
  exit $?
fi
if ! scratch_parent="$(cd "$scratch_parent" && pwd)" \
    || ! sandbox_base="$(mktemp -d "$scratch_parent/$scratch_prefix.XXXXXX" 2>/dev/null)"; then
  emit_setup_failure "scratch-create-failed"
  exit $?
fi
verify_worktree="$sandbox_base/worktree"
cache_root="$sandbox_base/cache"

original_before="$(workspace_fingerprint "$source_worktree")"

if [[ "$force_setup_failure" == "yes" ]]; then
  emit_setup_failure "forced-setup-failure"
  exit $?
fi

if ! singular_git_lock_acquire; then
  emit_setup_failure "git-lock-timeout"
  exit $?
fi
add_rc=0
git -C "$SINGULAR_ROOT" worktree add --detach -q "$verify_worktree" "$head_sha" >"$log" 2>&1 || add_rc=$?
if [[ "$add_rc" -eq 0 ]]; then worktree_added="yes"; fi
singular_git_lock_release
if [[ "$add_rc" -ne 0 ]]; then
  emit_setup_failure "worktree-create-failed"
  exit $?
fi

resolved_head="$(git -C "$verify_worktree" rev-parse HEAD 2>/dev/null || true)"
if [[ "$resolved_head" != "$head_sha" ]]; then
  emit_setup_failure "worktree-head-mismatch"
  exit $?
fi

baseline_tree="$head_sha"
if [[ ${#overlay_paths[@]} -gt 0 ]]; then
  if ! apply_overlay >>"$log" 2>&1; then
    emit_setup_failure "overlay-failed"
    exit $?
  fi
  baseline_tree="$(git -C "$verify_worktree" write-tree)" || {
    emit_setup_failure "overlay-failed"
    exit $?
  }
fi

# One shared preparer for provision -> dependency copies -> bootstrap -> prewarm,
# so this disposable worktree is environment-equivalent to the worker's by
# construction rather than by two code paths happening to agree. They did not:
# this one never ran `prewarm`, and it is the worktree where the auditor re-runs
# the gate whose result decides whether the work is accepted. A green worker gate
# that fails here is indistinguishable, from the outside, from broken work.
if ! singular_worktree_prepare "$verify_worktree" "" "$dependency_source" "$log"; then
  case "$SINGULAR_WORKTREE_PREPARE_STAGE" in
    provision) emit_setup_failure "worktree-provision-failed" ;;
    copy-paths) emit_setup_failure "${SINGULAR_WORKTREE_PREPARE_DETAIL:-dependency-copy-failed}" ;;
    bootstrap) emit_setup_failure "worktree-bootstrap-failed" ;;
    *) emit_setup_failure "worktree-prepare-failed" ;;
  esac
  exit $?
fi

if ! mkdir -p "$cache_root/tmp" "$cache_root/xdg" "$cache_root/turbo" \
  "$cache_root/vite" "$cache_root/bun" "$cache_root/npm" "$cache_root/yarn" \
  "$cache_root/corepack" "$cache_root/node" "$cache_root/cargo" "$cache_root/go"; then
  emit_setup_failure "cache-create-failed"
  exit $?
fi

source_snapshot_before="$sandbox_base/tracked-source-before.json"
source_snapshot_after="$sandbox_base/tracked-source-after.json"
if ! tracked_source_snapshot "$verify_worktree" "$source_snapshot_before" >>"$log" 2>&1; then
  emit_setup_failure "source-integrity-snapshot-failed"
  exit $?
fi

[[ -n "$observation" ]] || observation="$sandbox_base/observation.json"
if ! rm -f "$observation"; then
  emit_setup_failure "observation-prepare-failed"
  exit $?
fi

# Cache + report variables supplied only to the disposable command; they stay
# outside the source checkout. Declared ONCE and shared by both spawn paths
# below so the guarded and unguarded gates cannot drift apart.
gate_env=(
  SINGULAR_GATE_REPORT_FILE="$observation"
  TMPDIR="$cache_root/tmp/"
  TMP="$cache_root/tmp"
  TEMP="$cache_root/tmp"
  XDG_CACHE_HOME="$cache_root/xdg"
  TURBO_CACHE_DIR="$cache_root/turbo"
  VITE_CACHE_DIR="$cache_root/vite"
  BUN_INSTALL_CACHE_DIR="$cache_root/bun"
  BUN_TMPDIR="$cache_root/tmp"
  npm_config_cache="$cache_root/npm"
  YARN_CACHE_FOLDER="$cache_root/yarn"
  COREPACK_HOME="$cache_root/corepack"
  NODE_COMPILE_CACHE="$cache_root/node"
  CARGO_TARGET_DIR="$cache_root/cargo"
  GOCACHE="$cache_root/go"
)

run_gate_command() {
  # Reuse the worker gate's allowlisted environment boundary so a denied host
  # variable cannot leak into verification.
  singular_run_in_worktree_env "$verify_worktree" env "${gate_env[@]}" \
    "$(singular_bash_bin)" -c "$gate_command"
}

# The same gate, spawned as a SESSION LEADER. An audited gate is an arbitrary,
# uncooperative tree, so containment cannot depend on `ps`: where enumeration is
# denied the old walk found no children and killed only the top shell, leaving
# the gate running in a disposable worktree nobody would ever look at again.
# singular_setsid_exec is the LAST command here, so $! at the call
# site is the leader itself (pid == pgid) and one negative pid reaches the tree.
#
# ONLY valid as a background job — it replaces the calling process.
#
# singular_run_in_worktree_env is a shell function that runs its command in a
# SUBSHELL, so it cannot be exec'd; the new session therefore re-enters it after
# sourcing lib.sh, exactly the way every other engine child process obtains it.
# Inlining the boundary here instead would fork it into two copies that drift.
run_gate_command_session() {
  export SINGULAR_ROOT SINGULAR_STATE_DIR SINGULAR_ENGINE_HOME
  export SINGULAR_AUDIT_GATE_LIB="$SCRIPT_DIR/lib.sh"
  export SINGULAR_AUDIT_GATE_WORKTREE="$verify_worktree"
  export SINGULAR_AUDIT_GATE_COMMAND="$gate_command"
  singular_setsid_exec "$(singular_bash_bin)" -c '
set -euo pipefail
gate_env=("$@")
set --
source "$SINGULAR_AUDIT_GATE_LIB"
singular_run_in_worktree_env "$SINGULAR_AUDIT_GATE_WORKTREE" env "${gate_env[@]}" \
  "$(singular_bash_bin)" -c "$SINGULAR_AUDIT_GATE_COMMAND"
' singular-audit-gate "${gate_env[@]}"
}

started_ms="$(python3 -c 'import time; print(time.monotonic_ns() // 1000000)')"
gate_exit=0
gate_timed_out="no"
if [[ "$gate_timeout" -gt 0 ]]; then
  run_gate_command_session >"$log" 2>&1 &
  gate_pid=$!
  # SECONDS truncates to whole seconds: a one-second deadline could otherwise
  # expire almost immediately when setup ends near its next tick. Measure the
  # full allowance with a monotonic clock, independent of wall-clock changes.
  gate_deadline_ms=$((started_ms + gate_timeout * 1000))
  while kill -0 "$gate_pid" 2>/dev/null; do
    gate_now_ms="$(python3 -c 'import time; print(time.monotonic_ns() // 1000000)')"
    if [[ "$gate_now_ms" -ge "$gate_deadline_ms" ]]; then
      gate_timed_out="yes"
      # `session`: the spawner's assertion that $gate_pid came from
      # singular_setsid_exec above and has not been waited on yet.
      singular_kill_tree "$gate_pid" 0 session
      kill -KILL "$gate_pid" 2>/dev/null || true
      wait "$gate_pid" 2>/dev/null || true
      gate_exit=124
      break
    fi
    sleep 0.1
  done
  if [[ "$gate_timed_out" != "yes" ]]; then
    if wait "$gate_pid"; then
      gate_exit=0
    else
      gate_exit=$?
    fi
  else
    printf '%s gate timed out after %ss\n' "$log_label" "$gate_timeout" >>"$log"
  fi
else
  run_gate_command >"$log" 2>&1 || gate_exit=$?
fi
finished_ms="$(python3 -c 'import time; print(time.monotonic_ns() // 1000000)')"

if ! tracked_source_snapshot "$verify_worktree" "$source_snapshot_after" >>"$log" 2>&1; then
  emit_setup_failure "source-integrity-snapshot-failed"
  exit $?
fi

mapfile -t changed_paths < <(
  if [[ ${#overlay_paths[@]} -eq 0 ]]; then
    git -C "$verify_worktree" status --porcelain=v1 --untracked-files=all 2>/dev/null \
      | sed -E 's/^.. //' | sed '/^[[:space:]]*$/d'
  else
    git -C "$verify_worktree" diff --name-only "$baseline_tree" --
    git -C "$verify_worktree" ls-files --others --exclude-standard
  fi
)
mapfile -t metadata_changed_paths < <(
  tracked_source_changes "$source_snapshot_before" "$source_snapshot_after"
)
changed_paths+=("${metadata_changed_paths[@]}")
integrity_status="verified"
[[ ${#changed_paths[@]} -eq 0 ]] || integrity_status="violation"
original_after="$(workspace_fingerprint "$source_worktree")"
if [[ "$original_before" != "$original_after" ]]; then
  integrity_status="violation"
  changed_paths+=("original-worktree-changed-during-verification")
fi

duration_ms="$((finished_ms - started_ms))"
emit_result
