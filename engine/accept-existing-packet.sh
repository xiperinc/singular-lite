#!/usr/bin/env bash
set -euo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -n "${SINGULAR_BASH_BIN:-}" ]]; then
    [[ "$SINGULAR_BASH_BIN" == /* && -x "$SINGULAR_BASH_BIN" ]] || { echo "invalid SINGULAR_BASH_BIN: $SINGULAR_BASH_BIN" >&2; exit 2; }
    exec "$SINGULAR_BASH_BIN" "$0" "$@"
  fi
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "accept-existing-packet.sh requires bash >= 4 (mapfile); install via 'brew install bash'" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

singular_campaign_verify_or_refuse accept-existing-packet entry || exit 2
accept_campaign_binding="$(singular_campaign_binding)" || {
  echo "accept-existing-packet: inconsistent campaign identity" >&2
  exit 2
}

usage() {
  echo "usage: $0 path/to/state-packet.json" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
packet="$1"
[[ -f "$packet" ]] || { echo "packet not found: $packet" >&2; exit 2; }

verification_sandbox=""
verification_worktree=""
verification_worktree_added="no"
original_workspace_fingerprint=""
check_original_workspace_on_exit="no"
accept_campaign_lock_held="no"
accept_git_lock_held="no"
audit_candidate=""

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
    ["git", "-C", root, "status", "--porcelain=v1", "-z", "--untracked-files=all"],
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    check=False,
).stdout
print(hashlib.sha256(head + b"\0" + status).hexdigest())
PY
}

cleanup() {
  local rc=$?
  trap - EXIT
  if [[ "$accept_campaign_lock_held" == "yes" ]]; then
    singular_campaign_lock_release 2>/dev/null || true
    accept_campaign_lock_held="no"
  fi
  if [[ "$accept_git_lock_held" == "yes" ]]; then
    singular_git_lock_release 2>/dev/null || true
    accept_git_lock_held="no"
  fi
  [[ -z "$audit_candidate" ]] || rm -f "$audit_candidate" 2>/dev/null || true
  if [[ "$check_original_workspace_on_exit" == "yes" \
    && -n "$original_workspace_fingerprint" && -d "${workspace:-}" ]]; then
    local current_workspace_fingerprint=""
    current_workspace_fingerprint="$(workspace_fingerprint "$workspace" 2>/dev/null || true)"
    if [[ -z "$current_workspace_fingerprint" \
      || "$current_workspace_fingerprint" != "$original_workspace_fingerprint" ]]; then
      echo "original packet workspace changed during deterministic acceptance; refusing" >&2
      rc=2
    fi
  fi
  if [[ "$verification_worktree_added" == "yes" ]]; then
    if singular_git_lock_acquire 2>/dev/null; then
      git -C "$SINGULAR_ROOT" worktree remove --force "$verification_worktree" >/dev/null 2>&1 || true
      git -C "$SINGULAR_ROOT" worktree prune >/dev/null 2>&1 || true
      singular_git_lock_release
    fi
  fi
  if [[ -n "$verification_sandbox" \
    && "$(basename "$verification_sandbox")" == singular-accept-* ]]; then
    rm -rf -- "$verification_sandbox"
  fi
  exit "$rc"
}
trap cleanup EXIT

singular_ensure_state_dirs
singular_require_target_branch
if ! singular_validate_packet_basic "$packet" >/dev/null; then
  echo "packet command contract validation failed before deterministic execution" >&2
  exit 2
fi

task_id="$(singular_json_field "$packet" taskId)"
run_id="$(singular_json_field "$packet" runId)"
branch="$(singular_json_field "$packet" branch)"
head_sha="$(singular_json_field "$packet" headSha)"
base_ref="$(singular_json_field "$packet" baseRef)"
workspace="$(singular_json_field "$packet" workspace)"
run_dir="$SINGULAR_RUNS_DIR/$run_id"
audit_record="$(singular_audit_record_path "$run_id")"
audit_candidate="$run_dir/.audit.accept-existing.$$.tmp"
task_file="$SINGULAR_TASKS_DIR/$task_id.md"
packet_initial_sha="$(shasum -a 256 "$packet" | awk '{print $1}')"
lease_path="$(singular_lease_path "$task_id")"
lease_initial_sha="$(shasum -a 256 "$lease_path" 2>/dev/null | awk '{print $1}' || true)"
packet_campaign_binding="$(python3 - "$packet" <<'PY' 2>/dev/null || true
import json
import sys
packet = json.load(open(sys.argv[1], encoding="utf-8"))
for item in packet.get("evidence", []):
    if isinstance(item, dict) and item.get("kind") == "campaign-binding":
        print(item.get("ref", ""))
        break
PY
)"
lease_campaign_binding="$(singular_lease_field "$task_id" campaignBinding 2>/dev/null || true)"
if [[ "$accept_campaign_binding" == "legacy" ]]; then
  [[ -n "$packet_campaign_binding" ]] || packet_campaign_binding="legacy"
  [[ -n "$lease_campaign_binding" ]] || lease_campaign_binding="legacy"
fi
if [[ "$packet_campaign_binding" != "$accept_campaign_binding" \
    || "$lease_campaign_binding" != "$accept_campaign_binding" ]]; then
  echo "packet/lease campaign binding does not match the current campaign; re-audit required" >&2
  exit 2
fi
repo_schema_version="$(python3 - "$SINGULAR_ROOT/singular.config.json" <<'PY' 2>/dev/null || true
import json
import sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get("schemaVersion", "") or "")
except Exception:
    pass
PY
)"
audit_contract="v0"
audit_schema_path="$SINGULAR_SCHEMA_DIR/audit-verdict.v0.schema.json"
if [[ "$repo_schema_version" == "v2" ]]; then
  audit_contract="v1"
  audit_schema_path="$SINGULAR_SCHEMA_DIR/audit-verdict.v1.schema.json"
fi

[[ -f "$task_file" ]] || { echo "task file not found: $task_file" >&2; exit 2; }
[[ -d "$workspace" ]] || { echo "packet workspace not found: $workspace" >&2; exit 2; }
[[ -d "$run_dir" ]] || { echo "run dir not found: $run_dir" >&2; exit 2; }

if find "$SINGULAR_ORCH_DIR/packets/imported/$task_id" -maxdepth 1 -name '*.json' -not -name '*.audit.json' -type f 2>/dev/null | grep -q .; then
  echo "task already imported: $task_id" >&2
  exit 2
fi
if [[ -f "$SINGULAR_INBOX_DIR/$run_id.json" ]]; then
  echo "packet already queued in inbox: $SINGULAR_INBOX_DIR/$run_id.json" >&2
  exit 2
fi
if find "$SINGULAR_INBOX_DIR" -maxdepth 1 -name '*.json' -type f 2>/dev/null \
  | while IFS= read -r p; do [[ "$(singular_json_field "$p" taskId 2>/dev/null || true)" == "$task_id" ]] && echo "$p"; done \
  | grep -q .; then
  echo "task already queued in inbox: $task_id" >&2
  exit 2
fi

if ! git -C "$SINGULAR_ROOT" rev-parse --verify --quiet "$branch" >/dev/null; then
  echo "packet branch not found: $branch" >&2
  exit 2
fi
actual_head="$(git -C "$SINGULAR_ROOT" rev-parse "$branch")"
if [[ "$actual_head" != "$head_sha" ]]; then
  echo "packet headSha $head_sha does not match branch head $actual_head" >&2
  exit 2
fi
workspace_head="$(git -C "$workspace" rev-parse HEAD)"
if [[ "$workspace_head" != "$actual_head" ]]; then
  echo "packet workspace HEAD $workspace_head does not match branch head $actual_head" >&2
  exit 2
fi
if ! git -C "$workspace" rev-parse --verify --quiet "$base_ref^{commit}" >/dev/null; then
  echo "packet baseRef is not available in workspace: $base_ref" >&2
  exit 2
fi
non_generated_dirty="$(
  git -C "$workspace" status --porcelain --untracked-files=all \
    | sed 's/^...//' \
    | while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        p="${p##* -> }"
        case "$p" in
          .singular-cache|.singular-cache/*|.singular-state|.singular-state/*|.singular-evidence|.singular-evidence/*) ;;
          *) printf '%s\n' "$p" ;;
        esac
      done
)"
if [[ -n "$non_generated_dirty" ]]; then
  echo "workspace has uncommitted non-generated changes; refusing deterministic acceptance:" >&2
  printf '  %s\n' $non_generated_dirty >&2
  exit 2
fi
original_workspace_fingerprint="$(workspace_fingerprint "$workspace")"
check_original_workspace_on_exit="yes"

mapfile -t owned_files < <(python3 - "$packet" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
for path in data["ownedFiles"]:
    print(path)
PY
)
[[ "${#owned_files[@]}" -gt 0 ]] || { echo "packet declares no owned files" >&2; exit 2; }

task_json="$(singular_task_json "$task_file")"
mapfile -t forbidden_files < <(printf '%s' "$task_json" | python3 -c 'import json,sys
data=json.load(sys.stdin)
for path in data.get("forbiddenFiles", []):
    if "/" in path and " " not in path:
        print(path)
')

safe_run_id="${run_id//[^A-Za-z0-9_.-]/_}"
verification_sandbox="$(mktemp -d "${TMPDIR:-/tmp}/singular-accept-${safe_run_id}.XXXXXX")"
verification_worktree="$verification_sandbox/worktree"
verification_cache="$verification_sandbox/cache"
verification_setup_log="$run_dir/accept-existing-packet-setup.log"
if ! singular_git_lock_acquire; then
  echo "could not acquire git lock for deterministic acceptance worktree" >&2
  exit 2
fi
worktree_add_rc=0
git -C "$SINGULAR_ROOT" worktree add --detach -q "$verification_worktree" "$actual_head" \
  >"$verification_setup_log" 2>&1 || worktree_add_rc=$?
if [[ "$worktree_add_rc" -eq 0 ]]; then
  verification_worktree_added="yes"
fi
singular_git_lock_release
if [[ "$worktree_add_rc" -ne 0 ]]; then
  cat "$verification_setup_log" >&2
  echo "could not create disposable deterministic acceptance worktree" >&2
  exit 2
fi
verification_head="$(git -C "$verification_worktree" rev-parse HEAD 2>/dev/null || true)"
if [[ "$verification_head" != "$actual_head" ]]; then
  echo "disposable verification worktree head mismatch: expected $actual_head, got $verification_head" >&2
  exit 2
fi

mkdir -p "$verification_cache/tmp" "$verification_cache/xdg" \
  "$verification_cache/turbo" "$verification_cache/vite" \
  "$verification_cache/bun" "$verification_cache/npm" \
  "$verification_cache/yarn" "$verification_cache/corepack" \
  "$verification_cache/node" "$verification_cache/cargo" \
  "$verification_cache/go" "$verification_cache/home" \
  "$verification_cache/bun-install" "$verification_sandbox/state"
bootstrap_log="$run_dir/accept-existing-packet-bootstrap.log"
# Same shared preparer as l1-drive and audit-verify. This site previously got
# neither the dependency copies nor prewarm, so it was the least like the
# worktree whose work it is deciding to accept.
SINGULAR_WORKTREE_PREPARE_ENV=(
  SINGULAR_ROOT="$verification_worktree"
  SINGULAR_STATE_DIR="$verification_sandbox/state"
  TMPDIR="$verification_cache/tmp/"
  TMP="$verification_cache/tmp"
  TEMP="$verification_cache/tmp"
  XDG_CACHE_HOME="$verification_cache/xdg"
  TURBO_CACHE_DIR="$verification_cache/turbo"
  VITE_CACHE_DIR="$verification_cache/vite"
  BUN_INSTALL="$verification_cache/bun-install"
  BUN_INSTALL_CACHE_DIR="$verification_cache/bun"
  BUN_TMPDIR="$verification_cache/tmp"
  npm_config_cache="$verification_cache/npm"
  YARN_CACHE_FOLDER="$verification_cache/yarn"
  COREPACK_HOME="$verification_cache/corepack"
  NODE_COMPILE_CACHE="$verification_cache/node"
  CARGO_TARGET_DIR="$verification_cache/cargo"
  GOCACHE="$verification_cache/go"
)
if ! singular_worktree_prepare "$verification_worktree" "" "$SINGULAR_ROOT" "$bootstrap_log"; then
  cat "$bootstrap_log" >&2
  # Per-stage wording preserved verbatim: these strings are the infrastructure
  # rejection reasons callers and tests match on.
  case "$SINGULAR_WORKTREE_PREPARE_STAGE" in
    provision)
      echo "disposable deterministic acceptance worktree provisioning failed" >&2 ;;
    copy-paths)
      echo "deterministic acceptance dependency copy failed: ${SINGULAR_WORKTREE_PREPARE_DETAIL:-unknown}" >&2 ;;
    bootstrap)
      echo "required deterministic acceptance bootstrap failed" >&2 ;;
    *)
      echo "deterministic acceptance worktree preparation failed" >&2 ;;
  esac
  exit 2
fi
unset SINGULAR_WORKTREE_PREPARE_ENV
bootstrap_head="$(git -C "$verification_worktree" rev-parse HEAD 2>/dev/null || true)"
mapfile -t bootstrap_changed_paths < <(
  git -C "$verification_worktree" status --porcelain=v1 --untracked-files=all 2>/dev/null \
    | sed -E 's/^.. //' | sed '/^[[:space:]]*$/d'
)
if [[ "$bootstrap_head" != "$actual_head" || "${#bootstrap_changed_paths[@]}" -ne 0 ]]; then
  echo "deterministic acceptance bootstrap attempted source mutation; refusing" >&2
  if [[ "${#bootstrap_changed_paths[@]}" -gt 0 ]]; then
    printf '  %s\n' "${bootstrap_changed_paths[@]}" >&2
  fi
  exit 2
fi

scope_log="$run_dir/accept-existing-packet-scope.log"
scope_args=(--worktree "$verification_worktree" --base "$base_ref")
for f in "${owned_files[@]}"; do scope_args+=(--allow-prefix "$f"); done
for f in "${forbidden_files[@]}"; do scope_args+=(--forbid-prefix "$f"); done
if ! "$SCRIPT_DIR/scope-check.sh" "${scope_args[@]}" >"$scope_log" 2>&1; then
  cat "$scope_log" >&2
  exit 2
fi

secret_log="$run_dir/accept-existing-packet-secret-scan.log"
if ! "$SCRIPT_DIR/secret-scan.sh" --worktree "$verification_worktree" \
  --range "$base_ref..HEAD" >"$secret_log" 2>&1; then
  cat "$secret_log" >&2
  exit 2
fi
singular_check_result_write "$run_dir/scope-check-result.json" scope passed 0 "$scope_log"
singular_check_result_write "$run_dir/secret-scan-result.json" secret passed 0 "$secret_log"

cmd_list="$run_dir/accept-existing-packet-commands.jsonl"
python3 - "$packet" "$workspace" "$run_dir" "$cmd_list" <<'PY'
import hashlib
import json
import os
import pathlib
import shutil
import sys
import tempfile

packet_path, workspace, run_dir, cmd_list = sys.argv[1:5]
with open(packet_path, encoding="utf-8") as f:
    packet = json.load(f)
workspace = os.path.realpath(workspace)
run_dir = os.path.realpath(run_dir)

def candidates(ref):
    if not ref:
        return []
    if os.path.isabs(ref):
        return [ref]
    out = [
        os.path.join(workspace, ref),
        os.path.join(run_dir, ref),
    ]
    if ref.startswith(".singular-evidence/"):
        out.append(os.path.join(run_dir, "worker-evidence", os.path.basename(ref)))
    if ref.startswith("runs/"):
        out.append(os.path.join(os.path.dirname(os.path.dirname(run_dir)), ref))
    return out

def exists(ref):
    return any(os.path.isfile(path) for path in candidates(ref))

phases = {"red": False, "green": False, "regression": False}
missing = []
log_refs = []
for test in packet.get("tests", []):
    phase = str(test.get("phase", "")).lower()
    ref = test.get("logRef", "")
    if ref:
        log_refs.append(ref)
    for key in list(phases):
        if key in phase:
            phases[key] = True
            if not exists(ref):
                missing.append(f"{key} evidence missing: {ref}")

for key, seen in phases.items():
    if not seen:
        missing.append(f"{key} test evidence not declared")

rerun = []
for idx, command in enumerate(packet.get("commands", [])):
    ref = command.get("logRef", "")
    if ref:
        log_refs.append(ref)
    if ref and not exists(ref):
        missing.append(f"command evidence missing: {ref}")
    if int(command.get("exitCode", 999)) == 0:
        rerun.append({"idx": idx, "cmd": command.get("cmd", "")})

if not rerun:
    missing.append("no successful packet commands available to rerun")
if missing:
    print("\n".join(missing), file=sys.stderr)
    sys.exit(2)

def contained(root, path):
    try:
        return os.path.commonpath([root, os.path.realpath(path)]) == root
    except (OSError, ValueError):
        return False

def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

# Preserve the exact packet evidence bytes in the durable run directory before
# the acceptance verdict is written. The evidence manifest can then bind the
# re-check to immutable raw artifacts rather than mutable ignored worker files.
for ref in dict.fromkeys(log_refs):
    pure = pathlib.PurePosixPath(ref)
    if pure.is_absolute() or any(part in ("", ".", "..") for part in pure.parts):
        print(f"unsafe packet evidence ref: {ref}", file=sys.stderr)
        sys.exit(2)
    source = next((path for path in candidates(ref) if os.path.isfile(path)), None)
    if not source:
        continue
    source = os.path.realpath(source)
    if not (contained(workspace, source) or contained(run_dir, source)):
        print(f"packet evidence escapes allowed roots: {ref}", file=sys.stderr)
        sys.exit(2)
    destination = os.path.join(run_dir, *pure.parts)
    destination_parent = os.path.dirname(destination)
    os.makedirs(destination_parent, exist_ok=True)
    if not contained(run_dir, destination_parent):
        print(f"packet evidence destination escapes run directory: {ref}", file=sys.stderr)
        sys.exit(2)
    if os.path.islink(destination):
        print(f"packet evidence destination must not be a symlink: {ref}", file=sys.stderr)
        sys.exit(2)
    if os.path.realpath(destination) == source:
        continue
    if os.path.exists(destination):
        if not os.path.isfile(destination) or sha256(destination) != sha256(source):
            print(f"packet evidence conflicts with durable artifact: {ref}", file=sys.stderr)
            sys.exit(2)
        continue
    fd, temporary = tempfile.mkstemp(
        prefix=os.path.basename(destination) + ".",
        dir=destination_parent,
    )
    os.close(fd)
    try:
        shutil.copyfile(source, temporary)
        os.replace(temporary, destination)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass

with open(cmd_list, "w", encoding="utf-8") as f:
    for command in rerun:
        f.write(json.dumps(command, separators=(",", ":")) + "\n")
PY

storage_guard_log="$run_dir/accept-existing-packet-module-guard.log"
if ! singular_packet_module_guard "$packet" "$task_file" "$workspace" "$run_dir" >"$storage_guard_log" 2>&1; then
  cat "$storage_guard_log" >&2
  exit 2
fi

rerun_logs="$run_dir/accept-existing-packet-rerun-logs.txt"
rerun_results="$run_dir/accept-existing-packet-command-results.jsonl"
: >"$rerun_logs"
: >"$rerun_results"
failed_command=""
failed_command_log=""
failed_command_exit=0
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  idx="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["idx"])' "$line")"
  cmd="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["cmd"])' "$line")"
  log="$run_dir/accept-existing-packet-command-$idx.log"
  started_ms="$(python3 -c 'import time; print(time.time_ns() // 1000000)')"
  command_exit=0
  (
    singular_run_in_worktree_env "$verification_worktree" env \
      SINGULAR_ROOT="$verification_worktree" \
      SINGULAR_STATE_DIR="$verification_sandbox/state" \
      HOME="$verification_cache/home" \
      TMPDIR="$verification_cache/tmp/" \
      TMP="$verification_cache/tmp" \
      TEMP="$verification_cache/tmp" \
      XDG_CACHE_HOME="$verification_cache/xdg" \
      TURBO_CACHE_DIR="$verification_cache/turbo" \
      VITE_CACHE_DIR="$verification_cache/vite" \
      BUN_INSTALL="$verification_cache/bun-install" \
      BUN_INSTALL_CACHE_DIR="$verification_cache/bun" \
      BUN_TMPDIR="$verification_cache/tmp" \
      npm_config_cache="$verification_cache/npm" \
      YARN_CACHE_FOLDER="$verification_cache/yarn" \
      COREPACK_HOME="$verification_cache/corepack" \
      NODE_COMPILE_CACHE="$verification_cache/node" \
      CARGO_TARGET_DIR="$verification_cache/cargo" \
      GOCACHE="$verification_cache/go" \
      "$(singular_bash_bin)" -c "$cmd"
  ) >"$log" 2>&1 || command_exit=$?
  finished_ms="$(python3 -c 'import time; print(time.time_ns() // 1000000)')"
  duration_ms="$((finished_ms - started_ms))"
  python3 - "$rerun_results" "$idx" "$cmd" "$command_exit" "$duration_ms" "$log" <<'PY'
import json
import sys

path, index, command, exit_code, duration_ms, log = sys.argv[1:7]
with open(path, "a", encoding="utf-8") as handle:
    handle.write(json.dumps({
        "index": int(index),
        "command": command,
        "exitCode": int(exit_code),
        "durationMs": max(0, int(duration_ms)),
        "log": log,
    }, separators=(",", ":")) + "\n")
PY
  printf '%s\n' "$log" >>"$rerun_logs"
  if [[ "$command_exit" -ne 0 ]]; then
    failed_command="$cmd"
    failed_command_log="$log"
    failed_command_exit="$command_exit"
    break
  fi
done <"$cmd_list"

verification_head_after="$(git -C "$verification_worktree" rev-parse HEAD 2>/dev/null || true)"
mapfile -t verification_changed_paths < <(
  git -C "$verification_worktree" status --porcelain=v1 --untracked-files=all 2>/dev/null \
    | sed -E 's/^.. //' | sed '/^[[:space:]]*$/d'
)
if [[ "$verification_head_after" != "$actual_head" \
  || "${#verification_changed_paths[@]}" -ne 0 ]]; then
  echo "packet command attempted source mutation in disposable verification worktree; refusing" >&2
  if [[ "$verification_head_after" != "$actual_head" ]]; then
    echo "  HEAD changed: $actual_head -> $verification_head_after" >&2
  fi
  if [[ "${#verification_changed_paths[@]}" -gt 0 ]]; then
    printf '  %s\n' "${verification_changed_paths[@]}" >&2
  fi
  exit 2
fi

current_workspace_fingerprint="$(workspace_fingerprint "$workspace" 2>/dev/null || true)"
if [[ -z "$current_workspace_fingerprint" \
  || "$current_workspace_fingerprint" != "$original_workspace_fingerprint" ]]; then
  echo "original packet workspace changed during deterministic acceptance; refusing" >&2
  exit 2
fi
if [[ -n "$failed_command" ]]; then
  echo "packet command failed during deterministic acceptance with exit $failed_command_exit: $failed_command (log: $failed_command_log)" >&2
  cat "$failed_command_log" >&2
  exit 2
fi

packet_input="$run_dir/accept-existing-packet-input.json"
python3 - "$packet" "$packet_input" <<'PY'
import os
import pathlib
import sys
import tempfile

source, destination = map(pathlib.Path, sys.argv[1:3])
payload = source.read_bytes()
if destination.exists():
    if destination.read_bytes() != payload:
        raise SystemExit("existing deterministic acceptance packet snapshot has different bytes")
    raise SystemExit(0)
destination.parent.mkdir(parents=True, exist_ok=True)
fd, raw = tempfile.mkstemp(prefix=destination.name + ".", dir=str(destination.parent))
try:
    with os.fdopen(fd, "wb") as handle:
        handle.write(payload)
    os.replace(raw, destination)
finally:
    try:
        os.unlink(raw)
    except FileNotFoundError:
        pass
PY

manifest_log="$run_dir/accept-existing-packet-evidence-manifest.log"
if ! "$SCRIPT_DIR/evidence-manifest.sh" \
  --run-dir "$run_dir" --task-id "$task_id" \
  --worktree "$verification_worktree" --base-ref "$base_ref" --head-sha "$actual_head" \
  >"$manifest_log" 2>&1; then
  cat "$manifest_log" >&2
  echo "could not generate deterministic acceptance evidence manifest" >&2
  exit 2
fi
evidence_manifest="$run_dir/evidence-manifest.json"
python3 - "$evidence_manifest" "$run_dir" "$rerun_results" \
  "$scope_log" "$secret_log" "$bootstrap_log" "$storage_guard_log" "$packet_input" \
  "$verification_setup_log" "$cmd_list" "$rerun_logs" <<'PY'
import hashlib
import json
import os
import pathlib
import sys
import tempfile

(
    manifest_path_raw,
    run_dir_raw,
    rerun_results_raw,
    scope_log_raw,
    secret_log_raw,
    bootstrap_log_raw,
    module_guard_log_raw,
    packet_input_raw,
    setup_log_raw,
    command_list_raw,
    rerun_logs_raw,
) = sys.argv[1:12]
manifest_path = pathlib.Path(manifest_path_raw)
run_dir = pathlib.Path(run_dir_raw).resolve()
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
excerpt_limit = int(manifest["budget"]["excerptLimitBytes"])
limit_bytes = int(manifest["budget"]["limitBytes"])

def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def artifact_ref(path):
    return path.resolve().relative_to(run_dir).as_posix()

def excerpt(path):
    raw = path.read_bytes()[:excerpt_limit]
    text = raw.decode("utf-8", errors="replace")
    if path.stat().st_size > excerpt_limit:
        suffix = "\n[truncated at capture]"
        text = (text[:max(0, excerpt_limit - len(suffix))] + suffix)
    return text[:excerpt_limit]

reruns = []
with open(rerun_results_raw, encoding="utf-8") as handle:
    for line in handle:
        if line.strip():
            reruns.append(json.loads(line))
for result in reruns:
    log = pathlib.Path(result["log"]).resolve()
    if log.parent != run_dir or not log.is_file():
        raise SystemExit(f"acceptance rerun log escapes run directory: {log}")
    manifest["commands"].append({
        "name": f"acceptance-rerun-{result['index'] + 1}",
        "command": result["command"],
        "exitCode": result["exitCode"],
        "status": "passed" if result["exitCode"] == 0 else "failed-product",
        "durationMs": result["durationMs"],
        "logRef": artifact_ref(log),
        "logSha256": sha256(log),
        "excerpt": excerpt(log),
    })

artifact_paths = [
    pathlib.Path(scope_log_raw),
    pathlib.Path(secret_log_raw),
    pathlib.Path(bootstrap_log_raw),
    pathlib.Path(module_guard_log_raw),
    pathlib.Path(packet_input_raw),
    pathlib.Path(setup_log_raw),
    pathlib.Path(command_list_raw),
    pathlib.Path(rerun_logs_raw),
    pathlib.Path(rerun_results_raw),
    *[pathlib.Path(item["log"]) for item in reruns],
]
artifacts = {
    item.get("ref"): item
    for item in manifest.get("artifacts", [])
    if item.get("ref") not in {"packet.json", "audit.json"}
}
for path in artifact_paths:
    path = path.resolve()
    if path.parent != run_dir or not path.is_file():
        raise SystemExit(f"acceptance artifact escapes run directory: {path}")
    ref = artifact_ref(path)
    artifacts[ref] = {
        "ref": ref,
        "sha256": sha256(path),
        "bytes": path.stat().st_size,
    }
manifest["artifacts"] = sorted(artifacts.values(), key=lambda item: item["ref"])

scope = pathlib.Path(scope_log_raw).resolve()
secret = pathlib.Path(secret_log_raw).resolve()
results = pathlib.Path(rerun_results_raw).resolve()
manifest["checks"]["scope"] = {
    "status": "passed",
    "ref": artifact_ref(scope),
    "sha256": sha256(scope),
}
manifest["checks"]["secret"] = {
    "status": "passed",
    "ref": artifact_ref(secret),
    "sha256": sha256(secret),
}
manifest["checks"]["gate"] = {
    "status": "passed",
    "ref": artifact_ref(results),
    "sha256": sha256(results),
}

for _ in range(3):
    encoded = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")
    manifest["budget"]["composedBytes"] = len(encoded)
encoded = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")
if len(encoded) > limit_bytes:
    raise SystemExit(
        f"deterministic acceptance evidence exceeds {limit_bytes} bytes ({len(encoded)})"
    )
fd, temporary = tempfile.mkstemp(
    prefix=manifest_path.name + ".",
    dir=str(manifest_path.parent),
)
try:
    with os.fdopen(fd, "wb") as handle:
        handle.write(encoded)
    os.replace(temporary, manifest_path)
finally:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
PY

manifest_schema="$SINGULAR_SCHEMA_DIR/evidence-manifest.v0.schema.json"
manifest_json="$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])),separators=(",",":")))' "$evidence_manifest")"
singular_json_schema_check "$manifest_json" "$manifest_schema" "evidence manifest" \
  || { echo "evidence manifest schema validation failed for $evidence_manifest" >&2; exit 2; }

singular_campaign_binding_matches \
  "$accept_campaign_binding" accept-existing-packet pre-audit-publication-checkpoint \
  || exit 2
singular_git_lock_acquire || {
  echo "accept-existing-packet: git operation lock unavailable" >&2
  exit 75
}
accept_git_lock_held="yes"
singular_campaign_lock_acquire || {
  echo "accept-existing-packet: campaign publication lock unavailable" >&2
  exit 75
}
accept_campaign_lock_held="yes"
singular_campaign_publication_cas \
  "$accept_campaign_binding" accept-existing-packet pre-audit-publication || exit 2

# Re-read every mutable authority input under the same short git->campaign
# critical section as publication. Long verification remains parallel, but a
# packet, lease, branch, or workspace change during it cannot publish.
current_packet_sha="$(shasum -a 256 "$packet" 2>/dev/null | awk '{print $1}' || true)"
current_lease_sha="$(shasum -a 256 "$lease_path" 2>/dev/null | awk '{print $1}' || true)"
current_branch_head="$(git -C "$SINGULAR_ROOT" rev-parse "$branch" 2>/dev/null || true)"
current_workspace_head="$(git -C "$workspace" rev-parse HEAD 2>/dev/null || true)"
current_workspace_fingerprint="$(workspace_fingerprint "$workspace" 2>/dev/null || true)"
current_lease_campaign_binding="$(singular_lease_field "$task_id" campaignBinding 2>/dev/null || true)"
if [[ -z "$current_lease_campaign_binding" && "$accept_campaign_binding" == "legacy" ]]; then
  current_lease_campaign_binding="legacy"
fi
if [[ -z "$current_packet_sha" || "$current_packet_sha" != "$packet_initial_sha" \
    || -z "$lease_initial_sha" || "$current_lease_sha" != "$lease_initial_sha" \
    || "$current_branch_head" != "$head_sha" \
    || "$current_workspace_head" != "$head_sha" \
    || -z "$current_workspace_fingerprint" \
    || "$current_workspace_fingerprint" != "$original_workspace_fingerprint" \
    || "$current_lease_campaign_binding" != "$accept_campaign_binding" ]]; then
  echo "accept-existing-packet: packet, lease, branch, or workspace changed during verification; refusing publication" >&2
  exit 2
fi
check_original_workspace_on_exit="no"

python3 - "$packet" "$audit_candidate" "$scope_log" "$secret_log" "$cmd_list" \
  "$rerun_logs" "$audit_contract" "$evidence_manifest" \
  "$accept_campaign_binding" <<'PY'
import json
import os
import sys

(
    packet_path,
    audit_path,
    scope_log,
    secret_log,
    cmd_list,
  rerun_logs,
  contract,
  evidence_manifest,
  campaign_binding,
) = sys.argv[1:10]
with open(packet_path, encoding="utf-8") as f:
    packet = json.load(f)
with open(cmd_list, encoding="utf-8") as f:
    commands = [json.loads(line)["cmd"] for line in f if line.strip()]
with open(rerun_logs, encoding="utf-8") as f:
    logs = [line.strip() for line in f if line.strip()]

evidence = [
    evidence_manifest,
    packet_path,
    scope_log,
    secret_log,
    *logs,
    "campaign-binding:" + campaign_binding,
    "reviewed-head-sha:" + packet["headSha"],
]
for item in packet.get("evidence", []):
    ref = item.get("ref")
    if ref:
        evidence.append(ref)

audit = {
    "schema": f"singular.orchestration.audit-verdict.{contract}",
    "taskId": packet["taskId"],
    "runId": packet["runId"],
    "branch": packet["branch"],
    "verdict": "accepted",
    "evidenceReviewed": evidence,
    "commandsRun": [
        "scope-check.sh " + " ".join(packet.get("ownedFiles", [])),
        "secret-scan.sh --range " + packet["baseRef"] + "..HEAD",
        *commands,
    ],
    "findings": [
        "deterministic acceptance for an existing stranded packet",
        "packet branch head matched packet headSha",
        "scope check, secret scan, and current successful packet commands passed in a disposable exact-head worktree",
        "the original packet workspace remained immutable and disposable source integrity was verified",
    ],
    "requiredFixes": [],
    "rationale": "Existing worker output was accepted deterministically because the packet is valid, branch head matches, scope is clean, evidence is present, and successful packet commands pass when rerun.",
}
if contract == "v1":
    audit["verificationResults"] = [{
        "status": "passed",
        "command": "deterministic existing-packet scope, secret, and command verification",
        "exitCode": 0,
        "evidenceRefs": [evidence_manifest, scope_log, secret_log, *logs],
        "rationale": "All deterministic existing-packet checks passed in a disposable worktree at the exact packet head without source mutation.",
    }]

os.makedirs(os.path.dirname(audit_path), exist_ok=True)
with open(audit_path, "w", encoding="utf-8") as f:
    json.dump(audit, f, indent=2)
    f.write("\n")
PY

# Central validator (0.5.0): the same schema check every auditor verdict gets,
# replacing this script's hand-rolled required/extra/const/enum python.
SINGULAR_AUDIT_SCHEMA="$audit_schema_path" \
  singular_validate_audit_verdict "$audit_candidate" "$task_id" "$run_id" \
  || { echo "audit schema validation failed for $audit_candidate" >&2; exit 2; }

python3 - "$packet" "$run_id" "$accept_campaign_binding" <<'PY'
import json
import os
import sys

packet_path, run_id, campaign_binding = sys.argv[1:4]
with open(packet_path, encoding="utf-8") as f:
    packet = json.load(f)
packet["status"] = "accepted"
packet["nextAction"] = "import into control state and reconcile"
audit_ref = f"runs/{run_id}/audit.json"
if not any(item.get("kind") == "audit" and item.get("ref") == audit_ref for item in packet["evidence"]):
    packet["evidence"].append({"kind": "audit", "ref": audit_ref})
packet["evidence"] = [
    item for item in packet["evidence"] if item.get("kind") != "campaign-binding"
]
packet["evidence"].append({"kind": "campaign-binding", "ref": campaign_binding})
temporary = packet_path + ".accept-existing.tmp"
with open(temporary, "w", encoding="utf-8") as f:
    json.dump(packet, f, indent=2)
    f.write("\n")
os.replace(temporary, packet_path)
PY
singular_validate_packet_basic "$packet" >/dev/null
mv "$audit_candidate" "$audit_record"
audit_candidate=""

if ! singular_lease_set_status "$task_id" "accepted"; then
  echo "lease not found for task: $task_id" >&2
  exit 2
fi
singular_task_set_status "$task_file" "accepted"
"$SCRIPT_DIR/record-decision.sh" --task "$task_id" --decision "accept" \
  --rationale "deterministic acceptance of existing stranded packet; branch head matches packet; scope, secret scan, evidence, and rerun commands passed" \
  --run "$run_id" --branch "$branch" --authority origin >/dev/null
singular_append_event "packet.accepted_existing" "existing state packet accepted deterministically" \
  "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"branch\":\"$branch\",\"headSha\":\"$head_sha\",\"audit\":\"$audit_record\"}"

singular_campaign_lock_release
accept_campaign_lock_held="no"
singular_git_lock_release
accept_git_lock_held="no"

echo "accepted existing packet: $packet (audit: $audit_record)"
