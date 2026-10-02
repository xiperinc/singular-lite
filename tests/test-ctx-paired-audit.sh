#!/usr/bin/env bash
# Covers the sampled post-acceptance paired-audit slice engine/ctx-paired-audit.sh:
# a default-OFF SINGULAR_PAIRED_AUDIT_PCT knob gates a deterministic content-hash
# sampling decision; when sampled, the recorder runs exactly ONE fresh, read-only
# auditor pass via a stubbable SINGULAR_RUNNER and records the paired verdict +
# findings as one ctx.paired_audit event (via singular_append_event) plus one
# paired-audit.json in the run dir — never changing any task outcome. Asserts:
#   (a) OFF (SINGULAR_PAIRED_AUDIT_PCT unset AND =0) -> no ctx.paired_audit event,
#       no paired-audit.json, and an otherwise untouched events log + run dir;
#   (b) PCT=100 + stub returning accepted/findings-empty -> exactly one
#       ctx.paired_audit event and one paired-audit.json flagged agreement, with
#       no write to any packet/lease/inbox/primary-audit path;
#   (c) PCT=100 + stub returning a disagreeing verdict (verdict != accepted OR
#       non-empty findings) -> disagreement flagged in BOTH event and record;
#   (d) sampling determinism -> same id reproducible across repeated calls and
#       separate bash processes; PCT=0 never samples a fixture set, PCT=100 always;
#   (e) freshness -> the stub records it was invoked FRESH (no resume/session
#       reuse) and read-only, using the base auditor prompt.
# The events log is pinned to an isolated SINGULAR_EVENTS_FILE and a temp run dir
# so the suite never mutates real run state.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
CTX_PA="$ENGINE_HOME/engine/ctx-paired-audit.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Isolated state: never touch the real repo or its events log -------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state" "$tmp/orch/prompts" "$tmp/run" "$tmp/worktree"
# Base auditor prompt the recorder must pass to the runner.
printf '# Auditor Prompt\n' > "$tmp/orch/prompts/auditor.md"

export SINGULAR_ROOT="$tmp"
export SINGULAR_STATE_DIR="$tmp/state"
export SINGULAR_ORCH_DIR="$tmp/orch"
# shellcheck disable=SC1090
source "$LIB" || fail "sourcing lib.sh failed"

# The engine file must exist and define the paired-audit functions (RED before
# it is written). lib.sh auto-sources it; source again defensively.
[[ -f "$CTX_PA" ]] || fail "engine not present yet: $CTX_PA"
# shellcheck disable=SC1090
source "$CTX_PA" || fail "sourcing $CTX_PA failed"
[[ "$(type -t singular_ctx_paired_audit_should_sample)" == "function" ]] \
  || fail "singular_ctx_paired_audit_should_sample not defined by $CTX_PA"
[[ "$(type -t singular_ctx_paired_audit_record)" == "function" ]] \
  || fail "singular_ctx_paired_audit_record not defined by $CTX_PA"

# Point the events log at an isolated temp file (lib.sh sets it at source time).
export SINGULAR_EVENTS_FILE="$tmp/events.ndjson"

# --- Stub runner: records its argv, writes the configured verdict JSON --------
STUB="$tmp/stub-runner.sh"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
# Fresh/read-only auditor stub. Records argv for freshness assertions and writes
# the configured verdict to the --output-last-message target.
set -uo pipefail
: > "$STUB_ARGV_FILE"
printf '%s\n' "$@" >> "$STUB_ARGV_FILE"
out=""
args=("$@")
i=0
while [[ $i -lt ${#args[@]} ]]; do
  if [[ "${args[$i]}" == "--output-last-message" ]]; then
    out="${args[$((i + 1))]}"
  fi
  i=$((i + 1))
done
prompt_file=""
i=0
while [[ $i -lt ${#args[@]} ]]; do
  [[ "${args[$i]}" == "--prompt-file" ]] && prompt_file="${args[$((i + 1))]}"
  i=$((i + 1))
done
if [[ -n "$prompt_file" ]]; then
  cat "$prompt_file" > "$STUB_PROMPT_FILE"
fi
if [[ -n "$out" ]]; then
  printf '{"verdict":"%s","findings":%s}\n' \
    "${STUB_VERDICT:-accepted}" "${STUB_FINDINGS:-[]}" > "$out"
fi
exit 0
STUBEOF
chmod +x "$STUB"
export SINGULAR_RUNNER="$STUB"
export STUB_ARGV_FILE="$tmp/stub-argv.txt"
export STUB_PROMPT_FILE="$tmp/stub-prompt.txt"

# The recorder launches the auditor through the host evidence broker
# (engine/evidence_delivery.py run --required packet.json --required
# audit-verification.json), which refuses unless the run dir holds an evidence
# manifest binding a host-verified packet and verification report for this
# task/run. Publish that accepted-run evidence, as l1-drive.sh does before
# acceptance; shapes mirror tests/test_evidence_delivery.py.
publish_accepted_evidence() {
  local run_dir="$1" run_id="$2" task_id="$3"
  python3 - "$run_dir" "$run_id" "$task_id" <<'PY'
import hashlib, json, sys
from pathlib import Path
run_dir, run_id, task_id = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
identity = {"taskId": task_id, "runId": run_id, "headSha": "a" * 40}
packet = dict(identity, schema="singular.orchestration.state-packet.v0")
report = dict(identity, schema="singular.orchestration.gate-report.v0",
              outcome="passed", command="true",
              commandSha256=hashlib.sha256(b"true").hexdigest(),
              sourceIntegrity={"status": "verified"})
artifacts = []
for name, value in (("packet.json", packet), ("audit-verification.json", report)):
    data = json.dumps(value).encode()
    (run_dir / name).write_bytes(data)
    artifacts.append({"ref": name, "bytes": len(data),
                      "sha256": hashlib.sha256(data).hexdigest()})
manifest = dict(identity, schema="singular.orchestration.evidence-manifest.v0",
                budget={"retrievalLimitBytes": 65536, "excerptLimitBytes": 2048,
                        "limitBytes": 262144},
                artifacts=artifacts)
(run_dir / "evidence-manifest.json").write_text(json.dumps(manifest))
PY
}

count_pa_events() {
  [[ -f "$SINGULAR_EVENTS_FILE" ]] || { echo 0; return 0; }
  local c
  c="$(grep -c '"type":"ctx.paired_audit"' "$SINGULAR_EVENTS_FILE" 2>/dev/null)" || true
  echo "${c:-0}"
}

RUN_DIR="$tmp/run/RUN-1"
mkdir -p "$RUN_DIR"

# ---------------------------------------------------------------------------
# (a) OFF -> no fresh audit, no event, no paired-audit.json, untouched log/dir.
# ---------------------------------------------------------------------------
unset SINGULAR_PAIRED_AUDIT_PCT
: > "$SINGULAR_EVENTS_FILE"
: > "$STUB_ARGV_FILE"
before_ev="$(shasum "$SINGULAR_EVENTS_FILE" | awk '{print $1}')"
before_dir="$(ls -1a "$RUN_DIR" | sort | shasum | awk '{print $1}')"
singular_ctx_paired_audit_record "RUN-1" "TASK-0005" "$RUN_DIR" "$tmp/worktree" \
  || fail "OFF (unset): recorder crashed"
[[ "$(count_pa_events)" -eq 0 ]] || fail "OFF (unset): ctx.paired_audit event emitted"
[[ ! -e "$RUN_DIR/paired-audit.json" ]] || fail "OFF (unset): paired-audit.json written"
[[ ! -s "$STUB_ARGV_FILE" ]] || fail "OFF (unset): runner was invoked"
after_ev="$(shasum "$SINGULAR_EVENTS_FILE" | awk '{print $1}')"
after_dir="$(ls -1a "$RUN_DIR" | sort | shasum | awk '{print $1}')"
[[ "$before_ev" == "$after_ev" ]] || fail "OFF (unset): events log mutated"
[[ "$before_dir" == "$after_dir" ]] || fail "OFF (unset): run dir mutated"

# Knob explicitly 0.
export SINGULAR_PAIRED_AUDIT_PCT=0
: > "$STUB_ARGV_FILE"
before_ev="$(shasum "$SINGULAR_EVENTS_FILE" | awk '{print $1}')"
singular_ctx_paired_audit_record "RUN-1" "TASK-0005" "$RUN_DIR" "$tmp/worktree" \
  || fail "OFF (=0): recorder crashed"
[[ "$(count_pa_events)" -eq 0 ]] || fail "OFF (=0): ctx.paired_audit event emitted"
[[ ! -e "$RUN_DIR/paired-audit.json" ]] || fail "OFF (=0): paired-audit.json written"
[[ ! -s "$STUB_ARGV_FILE" ]] || fail "OFF (=0): runner was invoked"
after_ev="$(shasum "$SINGULAR_EVENTS_FILE" | awk '{print $1}')"
[[ "$before_ev" == "$after_ev" ]] || fail "OFF (=0): events log mutated"

# ---------------------------------------------------------------------------
# (b) PCT=100 agreement: exactly one event + one paired-audit.json, agreement
#     flagged; no write to sibling packet/lease/inbox/primary-audit paths; and
#     (e) the auditor pass is FRESH + read-only with the base auditor prompt.
# ---------------------------------------------------------------------------
export SINGULAR_PAIRED_AUDIT_PCT=100
: > "$SINGULAR_EVENTS_FILE"
: > "$STUB_ARGV_FILE"
publish_accepted_evidence "$RUN_DIR" "RUN-1" "TASK-0005" \
  || fail "agreement: could not publish accepted-run evidence"
# Sentinel sibling artifacts the recorder must NOT create/move/mutate.
printf 'PACKET-ORIG' > "$RUN_DIR/state-packet.json"
printf 'AUDIT-ORIG'  > "$RUN_DIR/audit-record.json"
printf 'LEASE-ORIG'  > "$tmp/lease.json"
printf 'INBOX-ORIG'  > "$tmp/inbox.txt"
sib_before="$(cat "$RUN_DIR/state-packet.json" "$RUN_DIR/audit-record.json" \
  "$RUN_DIR/packet.json" "$RUN_DIR/audit-verification.json" \
  "$RUN_DIR/evidence-manifest.json" \
  "$tmp/lease.json" "$tmp/inbox.txt" | shasum | awk '{print $1}')"
export STUB_VERDICT="accepted"
export STUB_FINDINGS="[]"
singular_ctx_paired_audit_record "RUN-1" "TASK-0005" "$RUN_DIR" "$tmp/worktree" \
  || fail "agreement: recorder crashed"

[[ "$(count_pa_events)" -eq 1 ]] \
  || fail "agreement: expected exactly one ctx.paired_audit event, got $(count_pa_events)"
[[ -f "$RUN_DIR/paired-audit.json" ]] || fail "agreement: paired-audit.json not written"

# (e) freshness + read-only + base prompt, from the recorded stub argv.
grep -q -- '--level' "$STUB_ARGV_FILE" && grep -q -- 'readonly' "$STUB_ARGV_FILE" \
  || fail "freshness: auditor not invoked read-only (--level readonly missing)"
grep -q -- '--resume-session' "$STUB_ARGV_FILE" \
  && fail "freshness: auditor invoked with --resume-session (not fresh)"
grep -q -- '--resume' "$STUB_ARGV_FILE" \
  && fail "freshness: auditor invoked with a resume flag (not fresh)"
# The broker hands the runner an immutable snapshot (delivery-prompt-<sha>.md)
# composed from the base prompt plus the host-delivered evidence, so assert the
# delivered CONTENT starts with the base auditor prompt's exact bytes.
python3 - "$tmp/orch/prompts/auditor.md" "$STUB_PROMPT_FILE" <<'PY' \
  || fail "freshness: base auditor prompt not delivered to the runner"
import sys
base = open(sys.argv[1], "rb").read()
delivered = open(sys.argv[2], "rb").read()
assert base and delivered.startswith(base), delivered[:200]
assert b"Complete host-delivered review evidence" in delivered, delivered[:400]
PY

# Sibling artifacts untouched (no outcome change).
sib_after="$(cat "$RUN_DIR/state-packet.json" "$RUN_DIR/audit-record.json" \
  "$RUN_DIR/packet.json" "$RUN_DIR/audit-verification.json" \
  "$RUN_DIR/evidence-manifest.json" \
  "$tmp/lease.json" "$tmp/inbox.txt" | shasum | awk '{print $1}')"
[[ "$sib_before" == "$sib_after" ]] \
  || fail "agreement: recorder mutated a packet/lease/inbox/primary-audit path"

# Agreement flagged in both the record and the event.
python3 - "$RUN_DIR/paired-audit.json" "$SINGULAR_EVENTS_FILE" <<'PY' \
  || fail "agreement: record/event not flagged as agreement"
import json, sys
rec = json.load(open(sys.argv[1]))
assert rec.get("verdict") == "accepted", rec
assert rec.get("disagreement") is False, rec
assert rec.get("agreement") is True, rec
assert int(rec.get("findingsCount", -1)) == 0, rec
evs = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
pa = [e for e in evs if e.get("type") == "ctx.paired_audit"]
assert len(pa) == 1, pa
d = pa[0].get("data", {})
assert d.get("verdict") == "accepted", d
assert d.get("disagreement") is False, d
assert d.get("taskId") == "TASK-0005" and d.get("runId") == "RUN-1", d
print("agreement-ok")
PY

# ---------------------------------------------------------------------------
# (c) PCT=100 disagreement: verdict != accepted OR non-empty findings ->
#     disagreement flagged in BOTH event and record. Two sub-cases.
# ---------------------------------------------------------------------------
disagree_case() {
  local label="$1" verdict="$2" findings="$3"
  local run_dir="$tmp/run/$label"
  mkdir -p "$run_dir"
  publish_accepted_evidence "$run_dir" "RUN-$label" "TASK-$label" \
    || fail "disagreement[$label]: could not publish accepted-run evidence"
  : > "$SINGULAR_EVENTS_FILE"
  : > "$STUB_ARGV_FILE"
  export STUB_VERDICT="$verdict"
  export STUB_FINDINGS="$findings"
  singular_ctx_paired_audit_record "RUN-$label" "TASK-$label" "$run_dir" "$tmp/worktree" \
    || fail "disagreement[$label]: recorder crashed"
  # The disagreement must come from the auditor's answer, not from a refused
  # launch (which also records verdict "unknown" = disagreement).
  [[ -s "$STUB_ARGV_FILE" ]] || fail "disagreement[$label]: auditor was not invoked"
  [[ "$(count_pa_events)" -eq 1 ]] \
    || fail "disagreement[$label]: expected one event, got $(count_pa_events)"
  [[ -f "$run_dir/paired-audit.json" ]] || fail "disagreement[$label]: no record"
  python3 - "$run_dir/paired-audit.json" "$SINGULAR_EVENTS_FILE" <<'PY' \
    || fail "disagreement[$label]: not flagged as disagreement in both"
import json, os, sys
rec = json.load(open(sys.argv[1]))
assert rec.get("verdict") == os.environ["STUB_VERDICT"], rec
assert rec.get("disagreement") is True, rec
assert rec.get("agreement") is False, rec
evs = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
pa = [e for e in evs if e.get("type") == "ctx.paired_audit"]
assert len(pa) == 1, pa
assert pa[0].get("data", {}).get("disagreement") is True, pa[0]
print("disagreement-ok")
PY
}
# Verdict != accepted, findings empty.
disagree_case "REJECT" "needs-fix" "[]"
# Verdict accepted, but non-empty findings.
disagree_case "FINDINGS" "accepted" '["scope drift in engine/x"]'

# ---------------------------------------------------------------------------
# (d) Sampling determinism / knob honoring. PCT=0 never samples; PCT=100 always;
#     the decision is reproducible for the same id across repeated calls and
#     across separate bash processes.
# ---------------------------------------------------------------------------
fixture=(RUN-1:TASK-0001 RUN-1:TASK-0002 RUN-2:TASK-0003 RUN-3:TASK-0004 \
         RUN-4:TASK-0005 RUN-5:TASK-0006 RUN-6:TASK-0007 RUN-7:TASK-0008)

# PCT=0: never samples any id.
export SINGULAR_PAIRED_AUDIT_PCT=0
for id in "${fixture[@]}"; do
  if singular_ctx_paired_audit_should_sample "$id"; then
    fail "determinism: PCT=0 sampled id $id"
  fi
done

# PCT=100: always samples any id.
export SINGULAR_PAIRED_AUDIT_PCT=100
for id in "${fixture[@]}"; do
  singular_ctx_paired_audit_should_sample "$id" \
    || fail "determinism: PCT=100 did not sample id $id"
done

# Mid value: the per-id decision is reproducible across repeated calls and a
# separate bash process (machine-independent content-hash gate).
export SINGULAR_PAIRED_AUDIT_PCT=50
for id in "${fixture[@]}"; do
  d1=0; singular_ctx_paired_audit_should_sample "$id" && d1=1
  d2=0; singular_ctx_paired_audit_should_sample "$id" && d2=1
  [[ "$d1" == "$d2" ]] || fail "determinism: repeated calls differ for $id ($d1 vs $d2)"
  d3="$(SINGULAR_PAIRED_AUDIT_PCT=50 bash -c \
    'source "'"$CTX_PA"'"; if singular_ctx_paired_audit_should_sample "'"$id"'"; then echo 1; else echo 0; fi')" \
    || fail "determinism: subprocess invocation failed for $id"
  [[ "$d1" == "$d3" ]] || fail "determinism: cross-process decision differs for $id ($d1 vs $d3)"
done

echo "ctx-paired-audit tests passed"
