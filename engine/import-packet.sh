#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
import_acceptance_mode="$(singular_acceptance_mode)" || exit 2
import_refusal_reason=""

# Park strict admission failures once, retaining the candidate and the refused
# queue entry. Removing that entry from the queue prevents reconcile's legacy
# retry policy from charging the same refusal again on the next cycle.
import_park_refusal() {
  [[ "$import_acceptance_mode" == "every-path" && -n "$import_refusal_reason" ]] || return 0
  if [[ "$import_git_lock_held" != "yes" ]]; then
    singular_git_lock_acquire || return $?
    import_git_lock_held="yes"
  fi
  if [[ "$import_campaign_lock_held" != "yes" ]]; then
    singular_campaign_lock_acquire || return $?
    import_campaign_lock_held="yes"
  fi
  singular_campaign_publication_cas "$import_campaign_binding" import-packet refusal || return $?
  # A stale import must not park newer producer state, even within the same
  # run. An integrated lease is terminal authority, not a candidate to park.
  [[ "$lease_status_before" == "accepted" && -f "$lease_path" && ! -L "$lease_path" \
      && "$(shasum -a 256 "$lease_path" | awk '{print $1}')" == "$lease_sha_before" \
      && -f "$packet_input" \
      && "$(shasum -a 256 "$packet_input" | awk '{print $1}')" == "$packet_sha_before" ]] || return 0
  singular_import_packet_parked "$packet_input" && return 0
  local advice payload retained
  advice="$import_refusal_reason; operator must repair the named acceptance evidence, then run singular drive $task_id to retry the retained candidate, or import the packet again"
  printf '%s\n' "$advice" >&2
  printf '%s\n' "$advice" >"$import_guard_log"
  SINGULAR_IMPORT_FAIL_PARK=1 singular_import_failure_note "$packet_input" "$import_guard_log" >/dev/null || return $?
  singular_lease_set_status "$task_id" blocked || return $?
  singular_task_set_status "$task_file" blocked || return $?
  singular_breaker_trip >/dev/null || return $?
  payload="$(python3 - "$task_id" "$run_id" "$advice" <<'PY'
import json, sys
print(json.dumps(dict(taskId=sys.argv[1], runId=sys.argv[2], reason=sys.argv[3],
                     resolutionOwner="operator"), separators=(",", ":")))
PY
)" || return $?
  singular_append_event "packet.import_refused" "import acceptance refused" "$payload" || return $?
  singular_append_event "task.import_parked" "task parked after import refusal" "$payload" || return $?
  # Only dequeue the exact inbox bytes we judged. Caller-owned packets outside
  # the inbox stay in place; their failure record suppresses duplicate parking.
  if [[ "$(cd "$(dirname "$packet_input")" && pwd -P)" == "$(cd "$SINGULAR_INBOX_DIR" && pwd -P)" \
      && "$(shasum -a 256 "$packet_input" | awk '{print $1}')" == "$packet_sha_before" ]]; then
    mkdir -p "$SINGULAR_STATE_DIR/import-refusals/$run_id"
    retained="$(mktemp "$SINGULAR_STATE_DIR/import-refusals/$run_id/packet.XXXXXX")" || return $?
    mv -- "$packet_input" "$retained" || return $?
  fi
}

# Pin the inputs read by the shared rule, including optional records whose
# appearance could change its answer. Include the host's referenced log and
# baseline, but not unrelated run output. Compare under the publication locks.
import_acceptance_inputs() {
  python3 - "$run_dir" "$audit_record" "$SINGULAR_STATE_DIR" \
    "$task_file" "$SINGULAR_JSON_CONFIG_FILE" <<'PY'
import hashlib, json, os, stat, sys
from pathlib import Path
run, audit, state, task, config = map(Path, sys.argv[1:])
paths = {audit, audit.with_name(audit.name + ".pre-normalize.json"),
         run / "audit-verification.json", run / "evidence-manifest.json",
         state / "review-policy/ledger.json", task, config}
try:
    report = json.loads((run / "audit-verification.json").read_text())
except (OSError, ValueError):
    report = {}
if isinstance(report, dict):
    for ref in (report.get("logPath") or report.get("logRef"), report.get("baselineRef")):
        if isinstance(ref, str) and ref:
            path = Path(ref)
            paths.add(path if path.is_absolute() else run / path)
for pattern in ("verification-request-*.json", "verification-task-contract-*.md",
                "verification-policy-*.json"):
    paths.update(run.glob(pattern))
values = []
for path in sorted(paths):
    try:
        mode = path.lstat().st_mode
        if stat.S_ISREG(mode):
            value = hashlib.sha256(path.read_bytes()).hexdigest()
        elif stat.S_ISLNK(mode):
            value = [os.readlink(path), hashlib.sha256(path.read_bytes()).hexdigest()]
        else:
            value = "not-a-file"
    except FileNotFoundError:
        value = None
    values.append([str(path), value])
print(hashlib.sha256(json.dumps(values, sort_keys=True).encode()).hexdigest())
PY
}

import_validate_acceptance() {
  local unit dag_node policy_env result rc=0
  import_refusal_reason="review-unit-invalid"
  dag_node="$(singular_task_field "$task_file" dagNode)" || return $?
  unit="$(python3 "$SINGULAR_LIB_DIR/review_policy.py" \
    --config "$SINGULAR_JSON_CONFIG_FILE" --state-dir "$SINGULAR_STATE_DIR" \
    resolve --task "$task_id" --dag-node "$dag_node" --tasks-dir "$SINGULAR_TASKS_DIR" --dry-run)" || return $?
  unit="$(printf '%s' "$unit" | python3 -c 'import json,sys; print(json.load(sys.stdin)["logicalChange"])')" || return $?
  policy_env="$(python3 -c 'import json,os
print(json.dumps({k:v for k,v in os.environ.items() if k.startswith("SINGULAR_REVIEW_")}))')" || return $?
  import_refusal_reason="acceptance-evidence-inputs-invalid"
  import_acceptance_before="$(import_acceptance_inputs)" || return $?
  result="$(python3 "$SINGULAR_LIB_DIR/acceptance_validator.py" \
      "--red-proof=${SINGULAR_RED_PROOF:-off}" \
      "--acceptance-mode=$import_acceptance_mode" "--lease=$lease_path" \
    "--task=$task_id" "--run=$run_id" "--branch=$branch" "--head=$head_sha" \
    "--campaign=$import_campaign_binding" "--run-dir=$run_dir" \
    "--repo-root=$SINGULAR_ROOT" "--state-dir=$SINGULAR_STATE_DIR" \
    "--logical-change=$unit" "--audit=$audit_record" "--task-contract=$task_file" \
    "--schema-dir=$SINGULAR_SCHEMA_DIR" "--config=$SINGULAR_JSON_CONFIG_FILE" \
    "--policy-env-json=$policy_env" "--legacy-schema-mode=${SINGULAR_LEGACY_SCHEMA_MODE:-warn}" \
    "--trusted-shell=${SINGULAR_BASH_BIN:-}" "--require-audit=$require_audit")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    import_refusal_reason="$(printf '%s' "$result" | python3 -c 'import json,sys
try:
    value = json.load(sys.stdin)
    print(value["conjunct"] + ":" + value["reason"])
except (ValueError, KeyError, TypeError):
    print("acceptance-validator-failed")')"
    # Keep the code and name the failed part of the rule in words beside it:
    # "A:blocking-finding-open (audit)".
    local subject=""
    subject="$(python3 "$SINGULAR_LIB_DIR/acceptance_validator.py" \
      describe-refusal --subject "$import_refusal_reason" 2>/dev/null)" || subject=""
    [[ -z "$subject" ]] || import_refusal_reason="$import_refusal_reason ($subject)"
    printf 'import refused: %s\n' "$import_refusal_reason" >&2
    return "$rc"
  fi
  import_refusal_reason="acceptance-evidence-changed-before-publication"
}

if [[ $# -ne 1 ]]; then
  echo "usage: $0 path/to/state-packet.json" >&2
  exit 2
fi

packet_input="$1"
import_restored_from=""
# every-path: a refused inbox packet was moved aside (import_park_refusal) so
# the loop does not judge it again. An operator's explicit re-import of that
# inbox path restores the newest retained copy for the run and imports it as
# usual. Reconcile only scans the inbox, so it never restores one by itself.
import_restore_retained() {
  [[ "$import_acceptance_mode" == "every-path" ]] || return 0
  [[ ! -e "$packet_input" && ! -L "$packet_input" ]] || return 0
  local inbox_real input_dir retained
  [[ -d "$SINGULAR_INBOX_DIR" ]] || return 0
  inbox_real="$(cd "$SINGULAR_INBOX_DIR" && pwd -P)" || return 0
  input_dir="$(dirname "$packet_input")"
  [[ -d "$input_dir" ]] || return 0
  [[ "$(cd "$input_dir" && pwd -P)" == "$inbox_real" ]] || return 0
  retained="$(python3 - "$SINGULAR_STATE_DIR/import-refusals" "$(basename "$packet_input")" <<'PY'
import os, re, stat, sys
root, name = sys.argv[1:3]
match = re.fullmatch(r"([A-Za-z0-9][A-Za-z0-9._-]*)\.json", name)
if not match or match[1] in {".", ".."}:
    raise SystemExit(0)
folder = os.path.join(root, match[1])
try:
    for path in (root, folder):
        if not stat.S_ISDIR(os.lstat(path).st_mode):
            raise SystemExit(0)
    entries = os.listdir(folder)
except OSError:
    raise SystemExit(0)
best = None
for entry in entries:
    if not re.fullmatch(r"packet\.[A-Za-z0-9]+", entry):
        continue
    path = os.path.join(folder, entry)
    value = os.lstat(path)
    if not stat.S_ISREG(value.st_mode):
        continue
    key = (value.st_mtime_ns, entry)
    if best is None or key > best[0]:
        best = (key, path)
if best:
    print(best[1])
PY
)" || return 0
  [[ -n "$retained" ]] || return 0
  mv -- "$retained" "$packet_input" || return 0
  # A fresh judgement: the failure record of the parked bytes no longer
  # matches, so a still-broken packet is refused and parked again, visibly.
  touch -- "$packet_input" || true
  import_restored_from="$retained"
  echo "import-packet: restored the retained refused packet to $packet_input" >&2
}
import_restore_retained
if [[ ! -f "$packet_input" ]]; then
  echo "packet not found: $packet_input" >&2
  exit 2
fi

# Import is the point where a run-local verdict becomes tracked authoritative
# control state. Capture the campaign before reading semantic evidence and
# compare-and-publish under the shared git->campaign locks below.
singular_campaign_verify_or_refuse import-packet entry || exit 2
import_campaign_binding="$(singular_campaign_binding)" || {
  echo "import-packet: inconsistent campaign identity at entry" >&2
  exit 2
}
import_campaign_lock_held="no"
import_git_lock_held="no"
import_packet_tmp=""
import_audit_tmp=""
import_packet_snapshot=""
import_audit_snapshot=""
import_lease_snapshot=""
import_decision_snapshot=""
import_guard_log=""
import_cleanup() {
  local import_exit=$?
  if [[ "$import_exit" -ne 0 ]]; then
    import_park_refusal || echo "import-packet: could not finish refusal parking" >&2
    # A restored packet that was not imported and not parked again goes back
    # aside, so the loop's inbox scan never judges it on the next cycle.
    if [[ -n "$import_restored_from" && -f "$packet_input" && ! -L "$packet_input" \
        && ! -e "$import_restored_from" ]]; then
      mv -- "$packet_input" "$import_restored_from" 2>/dev/null \
        || echo "import-packet: could not move the restored packet aside again" >&2
    fi
  fi
  rm -f "${import_packet_tmp:-}" "${import_audit_tmp:-}" \
    "${import_packet_snapshot:-}" "${import_audit_snapshot:-}" \
    "${import_lease_snapshot:-}" "${import_decision_snapshot:-}" \
    "${import_guard_log:-}" 2>/dev/null || true
  if [[ "$import_campaign_lock_held" == "yes" ]]; then
    singular_campaign_lock_release 2>/dev/null || true
    import_campaign_lock_held="no"
  fi
  if [[ "$import_git_lock_held" == "yes" ]]; then
    singular_git_lock_release 2>/dev/null || true
    import_git_lock_held="no"
  fi
}
trap import_cleanup EXIT

# Validate and publish one immutable snapshot.  Reading fields directly from a
# caller-owned file at different times permits a mixed-version packet when a
# producer is still replacing it.
singular_ensure_state_dirs
import_snapshot_dir="$SINGULAR_STATE_DIR/import-candidates"
mkdir -p "$import_snapshot_dir"
# Packets queued by an engine that did not normalise at worker exit can still
# carry bare-string blockers/evidence. Wrap them in the queued file itself,
# before the snapshot, so the snapshot and the change check below see the same
# bytes. Authority-carrying members are not touched.
singular_packet_normalize_and_record "$packet_input" import \
  "$(singular_json_field "$packet_input" taskId 2>/dev/null || true)" \
  "$(singular_json_field "$packet_input" runId 2>/dev/null || true)"
import_packet_snapshot="$(mktemp "$import_snapshot_dir/.packet.XXXXXX")"
cp -- "$packet_input" "$import_packet_snapshot"
packet="$import_packet_snapshot"
packet_json="$(python3 - "$packet" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.dumps(json.load(handle), separators=(",", ":")))
PY
)" || { echo "invalid packet JSON: $packet_input" >&2; exit 2; }
singular_json_schema_check "$packet_json" "$SINGULAR_PACKET_SCHEMA" "state packet" \
  || { echo "packet schema validation failed: $packet_input" >&2; exit 2; }
singular_validate_packet_basic "$packet" >/dev/null \
  || { echo "packet command contract validation failed: $packet_input" >&2; exit 2; }

task_id="$(singular_json_field "$packet" taskId)"
run_id="$(singular_json_field "$packet" runId)"
branch="$(singular_json_field "$packet" branch)"
head_sha="$(singular_json_field "$packet" headSha)"
workspace="$(singular_json_field "$packet" workspace)"
packet_status="$(singular_json_field "$packet" status)"
if [[ "$packet_status" != "accepted" ]]; then
  echo "packet status must be accepted before import (got: $packet_status)" >&2
  exit 2
fi
if ! python3 - "$run_id" "$SINGULAR_RUNS_DIR" <<'PY'
import os
import re
import sys

run_id, runs_dir = sys.argv[1:3]
if run_id in {".", ".."} or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", run_id):
    print("packet runId must be one safe path component", file=sys.stderr)
    raise SystemExit(2)
runs_root = os.path.abspath(runs_dir)
run_path = os.path.abspath(os.path.join(runs_root, run_id))
if os.path.commonpath([runs_root, run_path]) != runs_root or os.path.dirname(run_path) != runs_root:
    print("packet runId escapes the runs directory", file=sys.stderr)
    raise SystemExit(2)
PY
then
  exit 2
fi
task_file="$SINGULAR_TASKS_DIR/$task_id.md"
run_dir="$SINGULAR_RUNS_DIR/$run_id"

# The run is pre-existing producer state, not a directory the importer may
# create.  Require one real (non-symlink) directory immediately below the
# canonical runs root and retain its inode identity for the publication CAS.
import_run_identity="$(python3 - "$SINGULAR_RUNS_DIR" "$run_id" <<'PY'
import os
import stat
import sys

runs_dir, run_id = sys.argv[1:3]
runs_root = os.path.realpath(runs_dir)
try:
    root_stat = os.lstat(runs_dir)
    run_path = os.path.join(runs_dir, run_id)
    run_stat = os.lstat(run_path)
except OSError as exc:
    print(f"invalid packet run directory: {exc}", file=sys.stderr)
    raise SystemExit(2)
if stat.S_ISLNK(root_stat.st_mode) or not stat.S_ISDIR(root_stat.st_mode):
    print("runs root must be a real directory, not a symlink", file=sys.stderr)
    raise SystemExit(2)
if stat.S_ISLNK(run_stat.st_mode) or not stat.S_ISDIR(run_stat.st_mode):
    print("packet run directory must be a real directory, not a symlink", file=sys.stderr)
    raise SystemExit(2)
run_real = os.path.realpath(run_path)
if os.path.dirname(run_real) != runs_root:
    print("packet run directory is not a direct child of the runs root", file=sys.stderr)
    raise SystemExit(2)
print(f"{run_stat.st_dev}:{run_stat.st_ino}")
PY
)" || exit 2

if [[ ! -f "$task_file" ]]; then
  echo "task file not found: $task_file" >&2
  exit 2
fi

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
if [[ -z "$packet_campaign_binding" && "$import_campaign_binding" == "legacy" ]]; then
  packet_campaign_binding="legacy"
fi
lease_path="$(singular_lease_path "$task_id")"
if [[ ! -f "$lease_path" || -L "$lease_path" ]]; then
  echo "lease not found for packet task: $lease_path" >&2
  exit 2
fi
import_lease_snapshot="$(mktemp "$import_snapshot_dir/.lease.XXXXXX")"
cp -- "$lease_path" "$import_lease_snapshot"
lease_info="$(python3 - "$import_lease_snapshot" "$task_id" "$run_id" "$branch" \
  "$import_campaign_binding" <<'PY'
import json
import sys

path, task_id, run_id, branch, current_binding = sys.argv[1:6]
try:
    with open(path, encoding="utf-8") as handle:
        lease = json.load(handle)
except (OSError, ValueError) as exc:
    print(f"invalid lease JSON: {exc}", file=sys.stderr)
    raise SystemExit(2)
if not isinstance(lease, dict):
    print("lease must be a JSON object", file=sys.stderr)
    raise SystemExit(2)
expected = {"taskId": task_id, "runId": run_id, "branch": branch}
for field, value in expected.items():
    if lease.get(field) != value:
        print(
            f"lease {field} does not match packet: expected {value!r}, got {lease.get(field)!r}",
            file=sys.stderr,
        )
        raise SystemExit(2)
status = lease.get("status")
if status not in {"accepted", "integrated"}:
    print(f"lease status is not terminal-good: {status!r}", file=sys.stderr)
    raise SystemExit(2)
binding = str(lease.get("campaignBinding", ""))
if not binding and current_binding == "legacy":
    binding = "legacy"
print(binding)
print(status)
PY
)" || exit 2
lease_campaign_binding="$(printf '%s\n' "$lease_info" | sed -n '1p')"
lease_status_before="$(printf '%s\n' "$lease_info" | sed -n '2p')"
if [[ "$packet_campaign_binding" != "$import_campaign_binding" \
    || "$lease_campaign_binding" != "$import_campaign_binding" ]]; then
  echo "packet/lease campaign binding does not match current import campaign" >&2
  exit 2
fi
packet_sha_before="$(shasum -a 256 "$packet" | awk '{print $1}')"
lease_sha_before="$(shasum -a 256 "$import_lease_snapshot" | awk '{print $1}')"

import_guard_log="$(mktemp "$import_snapshot_dir/.guard.XXXXXX")"
import_refusal_reason="packet-module-or-branch-invalid"
if ! singular_packet_module_guard "$packet" "$task_file" "$workspace" "$run_dir" >"$import_guard_log" 2>&1; then
  cat "$import_guard_log" >&2
  singular_append_event "packet.import_rejected" "import rejected: module packet guard" \
    "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"reason\":\"module-packet-guard\"}"
  exit 2
fi

if ! git -C "$SINGULAR_ROOT" check-ref-format "refs/heads/$branch" >/dev/null 2>&1 \
    || ! git -C "$SINGULAR_ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
  echo "packet branch not found: $branch" >&2
  exit 2
fi

actual_head="$(git -C "$SINGULAR_ROOT" rev-parse --verify "refs/heads/$branch^{commit}")"
if [[ "$head_sha" != "$actual_head" ]]; then
  echo "packet headSha $head_sha does not match branch head $actual_head" >&2
  exit 2
fi

# Acceptance gate: no packet is imported without an accepted auditor verdict
# (operating model section 12). The verdict is the run's durable audit record.
# Set SINGULAR_REQUIRE_AUDIT=0 only for explicit, documented bootstrap exceptions.
require_audit="${SINGULAR_REQUIRE_AUDIT:-1}"
import_refusal_reason="audit-verdict-or-waiver-invalid"
case "$require_audit" in
  0|1) ;;
  *)
    echo "SINGULAR_REQUIRE_AUDIT must be exactly 0 or 1 (got: $require_audit)" >&2
    exit 2
    ;;
esac
audit_record="$(singular_audit_record_path "$run_id")"
audit_present_before="no"
verdict="n/a"
acceptance_mode="audit-disabled"
decision_record=""
decision_sha_before=""
if [[ -f "$audit_record" ]]; then
  if [[ -L "$audit_record" ]]; then
    echo "audit record must be a regular non-symlink file: $audit_record" >&2
    exit 2
  fi
  audit_present_before="yes"
  import_audit_snapshot="$(mktemp "$import_snapshot_dir/.audit.XXXXXX")"
  cp -- "$audit_record" "$import_audit_snapshot"
fi

audit_campaign_binding=""
audit_sha_before=""
if [[ "$audit_present_before" == "yes" ]]; then
  audit_schema="$(singular_json_field "$import_audit_snapshot" schema 2>/dev/null || true)"
  case "$audit_schema" in
    singular.orchestration.audit-verdict.v1)
      audit_schema_path="$SINGULAR_SCHEMA_DIR/audit-verdict.v1.schema.json"
      ;;
    singular.orchestration.audit-verdict.v0|pmgo.orchestration.audit-verdict.v0)
      audit_schema_path="$SINGULAR_SCHEMA_DIR/audit-verdict.v0.schema.json"
      ;;
    *)
      echo "unsupported audit verdict schema for import: ${audit_schema:-<missing>}" >&2
      exit 2
      ;;
  esac
  SINGULAR_AUDIT_SCHEMA="$audit_schema_path" \
    singular_validate_audit_verdict "$import_audit_snapshot" "$task_id" "$run_id" \
    || { echo "audit schema validation failed before import" >&2; exit 2; }
  python3 "$SCRIPT_DIR/audit-verdict-host-bind.py" \
    --validate-identity --verdict "$import_audit_snapshot" \
    --expected-task "$task_id" --expected-run "$run_id" \
    --expected-branch "$branch" --expected-head "$head_sha" \
    >/dev/null || exit 2
  audit_campaign_binding="$(python3 - "$import_audit_snapshot" <<'PY' 2>/dev/null || true
import json
import sys
audit = json.load(open(sys.argv[1], encoding="utf-8"))
for item in audit.get("evidenceReviewed", []):
    marker = str(item)
    if marker.startswith("campaign-binding:"):
        print(marker[len("campaign-binding:"):])
        break
PY
)"
  if [[ -z "$audit_campaign_binding" && "$import_campaign_binding" == "legacy" ]]; then
    audit_campaign_binding="legacy"
  fi
  if [[ "$audit_campaign_binding" != "$import_campaign_binding" ]]; then
    echo "audit campaign binding does not match current import campaign" >&2
    exit 2
  fi
  audit_sha_before="$(shasum -a 256 "$import_audit_snapshot" | awk '{print $1}')"
  verdict="$(singular_json_field "$import_audit_snapshot" verdict 2>/dev/null || echo unknown)"
fi

if [[ "$require_audit" == "1" ]]; then
  if [[ "$audit_present_before" != "yes" ]]; then
    echo "no auditor verdict for run $run_id (expected $audit_record); refusing import" >&2
    singular_append_event "packet.import_rejected" "import rejected: missing auditor verdict" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"reason\":\"missing-audit\"}"
    exit 2
  fi
  if [[ "$verdict" == "accepted" ]]; then
    acceptance_mode="accepted"
  elif singular_packet_has_accept_waiver "$packet"; then
    acceptance_mode="accepted-waiver"
    decision_record="$run_dir/decision-audit-needs-fix.json"
    if [[ ! -f "$decision_record" || -L "$decision_record" ]]; then
      echo "accept-waiver decision must be a regular non-symlink run-local record" >&2
      exit 2
    fi
    import_decision_snapshot="$(mktemp "$import_snapshot_dir/.decision.XXXXXX")"
    cp -- "$decision_record" "$import_decision_snapshot"
    decision_json="$(python3 - "$import_decision_snapshot" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.dumps(json.load(handle), separators=(",", ":")))
PY
)" || { echo "invalid accept-waiver decision JSON" >&2; exit 2; }
    singular_json_schema_check "$decision_json" "$SINGULAR_DECIDER_SCHEMA" \
      "accept-waiver decision" || exit 2
    python3 - "$import_decision_snapshot" "$task_id" "$run_id" \
      "$import_campaign_binding" <<'PY' || exit 2
import json
import sys

path, task_id, run_id, current_binding = sys.argv[1:5]
with open(path, encoding="utf-8") as handle:
    decision = json.load(handle)
decision_run = str(decision.get("runId", ""))
decision_binding = str(decision.get("campaignBinding", ""))
if current_binding == "legacy":
    decision_run = decision_run or run_id
    decision_binding = decision_binding or "legacy"
expected = {
    "taskId": task_id,
    "failureClass": "audit-needs-fix",
    "action": "accept-waiver",
}
for field, value in expected.items():
    if decision.get(field) != value:
        print(f"accept-waiver decision {field} does not match {value!r}", file=sys.stderr)
        raise SystemExit(2)
if decision_run != run_id or decision_binding != current_binding:
    print("accept-waiver decision run/campaign identity does not match packet", file=sys.stderr)
    raise SystemExit(2)
PY
    decision_sha_before="$(shasum -a 256 "$import_decision_snapshot" | awk '{print $1}')"
  else
    echo "auditor verdict for $run_id is '$verdict' (not accepted, no recorded accept-waiver); refusing import" >&2
    singular_append_event "packet.import_rejected" "import rejected: auditor not accepted" \
      "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"verdict\":\"$verdict\"}"
    exit 2
  fi
fi

dest_dir="$SINGULAR_ORCH_DIR/packets/imported/$task_id"
dest="$dest_dir/$run_id.json"
audit_dest="$dest_dir/$run_id.audit.json"
import_acceptance_before=""
if [[ "$import_acceptance_mode" == "every-path" && ! -e "$dest" ]]; then
  import_validate_acceptance || exit $?
fi

import_prepare_destination_dir() {
  python3 - "$SINGULAR_ORCH_DIR" "$task_id" <<'PY'
import os
import re
import stat
import sys

root, task_id = sys.argv[1:3]
if not re.fullmatch(r"TASK-[0-9]{4,}", task_id):
    print("unsafe task id for import destination", file=sys.stderr)
    raise SystemExit(2)
flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
try:
    root_stat = os.lstat(root)
    if stat.S_ISLNK(root_stat.st_mode) or not stat.S_ISDIR(root_stat.st_mode):
        raise OSError("orchestration root is not a real directory")
    fd = os.open(root, flags)
    try:
        for component in ("packets", "imported", task_id):
            try:
                value = os.stat(component, dir_fd=fd, follow_symlinks=False)
            except FileNotFoundError:
                os.mkdir(component, mode=0o700, dir_fd=fd)
                value = os.stat(component, dir_fd=fd, follow_symlinks=False)
            if stat.S_ISLNK(value.st_mode) or not stat.S_ISDIR(value.st_mode):
                raise OSError(f"unsafe import destination component: {component}")
            next_fd = os.open(component, flags, dir_fd=fd)
            os.close(fd)
            fd = next_fd
    finally:
        os.close(fd)
except OSError as exc:
    print(f"unsafe import destination: {exc}", file=sys.stderr)
    raise SystemExit(2)
PY
}

# Final authority publication is serialized with both integration and campaign
# transitions. Recheck every mutable identity after the locks are held; then
# publish the audit sidecar first and the packet (the authority marker) last.
singular_campaign_binding_matches \
  "$import_campaign_binding" import-packet pre-publication-checkpoint || exit 2
singular_git_lock_acquire || exit $?
import_git_lock_held="yes"
singular_campaign_lock_acquire || exit $?
import_campaign_lock_held="yes"
singular_campaign_publication_cas \
  "$import_campaign_binding" import-packet pre-publication || exit 2
[[ "$(python3 - "$run_dir" <<'PY' 2>/dev/null || true
import os
import stat
import sys
value = os.lstat(sys.argv[1])
if stat.S_ISLNK(value.st_mode) or not stat.S_ISDIR(value.st_mode):
    raise SystemExit(2)
print(f"{value.st_dev}:{value.st_ino}")
PY
)" == "$import_run_identity" ]] \
  || { echo "packet run directory changed while import was being validated" >&2; exit 2; }
[[ -f "$lease_path" \
    && ! -L "$lease_path" \
    && "$(shasum -a 256 "$lease_path" | awk '{print $1}')" == "$lease_sha_before" ]] \
  || { echo "lease changed while packet import was being validated" >&2; exit 2; }
[[ -f "$packet_input" \
    && "$(shasum -a 256 "$packet_input" | awk '{print $1}')" == "$packet_sha_before" ]] \
  || { echo "packet changed while import was being validated" >&2; exit 2; }
if [[ "$audit_present_before" == "yes" ]]; then
  [[ -f "$audit_record" \
      && ! -L "$audit_record" \
      && "$(shasum -a 256 "$audit_record" | awk '{print $1}')" == "$audit_sha_before" ]] \
    || { echo "audit changed while packet import was being validated" >&2; exit 2; }
else
  [[ ! -e "$audit_record" && ! -L "$audit_record" ]] \
    || { echo "audit appeared while packet import was being validated" >&2; exit 2; }
fi
if [[ -n "$decision_record" ]]; then
  [[ -f "$decision_record" \
      && ! -L "$decision_record" \
      && "$(shasum -a 256 "$decision_record" | awk '{print $1}')" == "$decision_sha_before" ]] \
    || { echo "accept-waiver decision changed while packet import was being validated" >&2; exit 2; }
fi
[[ "$(git -C "$SINGULAR_ROOT" rev-parse --verify \
      "refs/heads/$branch^{commit}" 2>/dev/null || true)" \
      == "$actual_head" ]] \
  || { echo "branch head changed while packet import was being validated" >&2; exit 2; }
import_prepare_destination_dir || exit 2
if [[ -L "$dest" || ( -e "$dest" && ! -f "$dest" ) ]]; then
  echo "import packet destination must be a regular non-symlink file: $dest" >&2
  exit 2
fi
if [[ -L "$audit_dest" || ( -e "$audit_dest" && ! -f "$audit_dest" ) ]]; then
  echo "import audit destination must be a regular non-symlink file: $audit_dest" >&2
  exit 2
fi

# Idempotent: re-importing the same packet (e.g. after a crash between copy and
# inbox cleanup) is a success, so the caller can clear it from the inbox queue.
if [[ -e "$dest" ]]; then
  idempotent_complete="no"
  if cmp -s "$packet" "$dest"; then
    if [[ "$audit_present_before" == "yes" ]]; then
      [[ -f "$audit_dest" ]] && cmp -s "$import_audit_snapshot" "$audit_dest" \
        && idempotent_complete="yes"
    elif [[ ! -e "$audit_dest" ]]; then
      idempotent_complete="yes"
    fi
  fi
  if [[ "$idempotent_complete" == "yes" ]]; then
    singular_campaign_lock_release || exit $?
    import_campaign_lock_held="no"
    singular_git_lock_release || exit $?
    import_git_lock_held="no"
    echo "already imported (idempotent): $dest"
    exit 0
  fi
  echo "import destination is incomplete or has different packet/audit content: $dest" >&2
  exit 2
fi
if [[ "$lease_status_before" != "accepted" ]]; then
  echo "new packet import requires an accepted lease (got: $lease_status_before)" >&2
  exit 2
fi
if [[ "$audit_present_before" != "yes" && -e "$audit_dest" ]]; then
  echo "unexpected imported audit sidecar without a validated source audit: $audit_dest" >&2
  exit 2
fi

if [[ "$import_acceptance_mode" == "every-path" ]]; then
  [[ -n "$import_acceptance_before" \
      && "$(import_acceptance_inputs)" == "$import_acceptance_before" ]] \
    || { echo "acceptance evidence changed while import was being validated" >&2; exit 2; }
  if [[ "${SINGULAR_RED_PROOF:-off}" == enforce ]]; then
    import_validate_acceptance || exit $?
  fi
fi

# Atomic authority publish: stage complete bytes, install the audit first, and
# rename the packet last. An audit sidecar without a packet has no authority;
# a packet can therefore never become visible without all required evidence.
import_packet_tmp="$(mktemp "$dest_dir/.$run_id.packet.XXXXXX")"
cp -- "$packet" "$import_packet_tmp"
audit_published="no"
if [[ "$audit_present_before" == "yes" ]]; then
  import_audit_tmp="$(mktemp "$dest_dir/.$run_id.audit.XXXXXX")"
  cp -- "$import_audit_snapshot" "$import_audit_tmp"
  if [[ -e "$audit_dest" ]]; then
    cmp -s "$import_audit_tmp" "$audit_dest" \
      || { echo "import audit destination exists with different content: $audit_dest" >&2; exit 2; }
    rm -f "$import_audit_tmp"
    import_audit_tmp=""
  else
    mv "$import_audit_tmp" "$audit_dest"
    import_audit_tmp=""
    audit_published="yes"
  fi
fi
if ! mv "$import_packet_tmp" "$dest"; then
  [[ "$audit_published" != "yes" ]] || rm -f "$audit_dest" 2>/dev/null || true
  exit 2
fi
import_packet_tmp=""
singular_append_event "packet.imported" "state packet imported" \
  "{\"taskId\":\"$task_id\",\"runId\":\"$run_id\",\"branch\":\"$branch\",\"verdict\":\"$verdict\",\"acceptanceMode\":\"$acceptance_mode\"}" \
  || true
singular_campaign_lock_release || exit $?
import_campaign_lock_held="no"
singular_git_lock_release || exit $?
import_git_lock_held="no"
echo "imported $packet_input -> $dest (auditor verdict: $verdict; acceptance: $acceptance_mode)"
