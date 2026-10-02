#!/usr/bin/env bash
set -euo pipefail

# Packet-format domain (loop-economics protocol 6, action-plan item 11):
#   1. the frozen-candidate fingerprint sees content, modes, symlink targets,
#      the index, the committed head and the worker's evidence directory;
#   2. the allowance is ONE per frozen candidate, shared across error names,
#      durable on the lease, and survives a native lease rewrite and unpark;
#   3. end to end (shared frozen-campaign fixture): one read-only re-emission
#      with no product or review charge, alternating error names, mutation and
#      fabricated evidence failing closed, durability across process + unpark.

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2', got '$1'"; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/singular-packet-format.XXXXXX")"
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT

# Load the driver's packet-format helpers without running the driver.
helpers="$tmp/helpers.sh"
for helper in l1_packet_format_fingerprint l1_packet_format_candidate_key \
    l1_packet_format_allowance_claim l1_candidate_signature; do
  sed -n "/^${helper}() {\$/,/^}\$/p" "$ENGINE_HOME/engine/l1-drive.sh" >>"$helpers"
  grep -q "^${helper}() {\$" "$helpers" || fail "$helper not found in l1-drive.sh"
done

export SINGULAR_ROOT="$tmp/root" SINGULAR_STATE_DIR="$tmp/root/.singular-state"
mkdir -p "$SINGULAR_ROOT"
in_lib() {
  bash -c 'source "$1" >/dev/null; source "$2"; shift 2; "$@"' \
    fixture "$ENGINE_HOME/engine/lib.sh" "$helpers" "$@"
}

# ---- 1. Fingerprint ---------------------------------------------------------
wt="$tmp/wt"
mkdir -p "$wt/src"
git -C "$wt" init -q
printf '.singular-evidence/\n' >"$wt/.gitignore"
printf 'one\n' >"$wt/src/a.txt"
git -C "$wt" add . && git -C "$wt" -c user.name=t -c user.email=t@e commit -qm init
printf 'uncommitted\n' >"$wt/src/a.txt"
mkdir -p "$wt/.singular-evidence"
printf 'red\n' >"$wt/.singular-evidence/red.log"
ln -s src/a.txt "$wt/link"
fp() { in_lib l1_packet_format_fingerprint "$wt"; }
base="$(fp)"
[[ "$base" =~ ^[0-9a-f]{64}$ ]] || fail "fingerprint is not a sha256: $base"
assert_eq "$(fp)" "$base" "fingerprint is stable for an unchanged candidate"
expect_changed() {
  local label="$1" now
  now="$(fp)"
  [[ "$now" != "$base" ]] || fail "fingerprint missed: $label"
  base="$now"
}
printf 'edited\n' >"$wt/src/a.txt"; expect_changed "tracked content"
chmod +x "$wt/src/a.txt"; expect_changed "mode change"
ln -sfn .gitignore "$wt/link"; expect_changed "untracked symlink target"
printf 'green\n' >"$wt/.singular-evidence/green.log"; expect_changed "new evidence file"
printf 'RED\n' >"$wt/.singular-evidence/red.log"; expect_changed "edited evidence"
git -C "$wt" add src/a.txt; expect_changed "index entry"
git -C "$wt" -c user.name=t -c user.email=t@e commit -qm two; expect_changed "committed head"
in_lib l1_packet_format_fingerprint "$tmp/not-a-repo" >/dev/null 2>&1 \
  && fail "fingerprint of a missing worktree must fail closed"
echo "ok: frozen-candidate fingerprint covers content, modes, links, index, head and evidence"

# The allowance key is the worker's product (owned paths + evidence), not its
# place in history: merging unrelated control-state commits keeps it.
key() { in_lib l1_packet_format_candidate_key "$wt" src; }
k0="$(key)"
[[ "$k0" =~ ^[0-9a-f]{64}$ ]] || fail "candidate key is not a sha256: $k0"
printf 'control\n' >"$wt/control.md"
git -C "$wt" add control.md && git -C "$wt" -c user.name=t -c user.email=t@e commit -qm control
assert_eq "$(key)" "$k0" "candidate key ignores a control-state commit outside owned paths"
printf 'owned edit\n' >"$wt/src/a.txt"
[[ "$(key)" != "$k0" ]] || fail "candidate key missed an owned-file edit"
k0="$(key)"
printf 'more\n' >"$wt/.singular-evidence/extra.log"
[[ "$(key)" != "$k0" ]] || fail "candidate key missed an evidence change"
k0="$(key)"
rm "$wt/src/a.txt"
[[ "$(key)" != "$k0" ]] || fail "candidate key missed an owned-file deletion"
in_lib l1_packet_format_candidate_key "$wt" ../escape >/dev/null 2>&1 \
  && fail "candidate key must refuse an owned path outside the worktree"
in_lib l1_packet_format_candidate_key "$wt" >/dev/null 2>&1 \
  && fail "candidate key without owned paths must fail closed"
echo "ok: allowance key binds owned content and evidence, not history"

# ---- 2. Durable shared allowance --------------------------------------------
claim_for() {
  bash -c 'source "$1" >/dev/null; source "$2"; task_id="$3"; run_id="$4"
    l1_packet_format_allowance_claim "$5" "$6" "$7"' \
    fixture "$ENGINE_HOME/engine/lib.sh" "$helpers" "$@"
}
claim() { claim_for TASK-0001 "$@"; }
in_lib singular_lease_write TASK-0001 agent/x widget l1 "src/a.txt" running RUN-A \
  || fail "lease write"
fingerprint_a="$(printf 'a%.0s' {1..64})"
fingerprint_b="$(printf 'b%.0s' {1..64})"
rc=0; claim RUN-A "$fingerprint_a" worker-no-packet 1 || rc=$?
assert_eq "$rc" "0" "first claim for a frozen candidate"
rc=0; claim RUN-A "$fingerprint_a" packet-invalid 1 || rc=$?
assert_eq "$rc" "4" "a different error name for the same candidate shares the allowance"
rc=0; claim RUN-A "$fingerprint_b" packet-invalid 2 || rc=$?
assert_eq "$rc" "0" "a changed candidate is a new packet-format operation"
# A native lease rewrite (new process, new run) and an operator unpark keep it.
in_lib singular_lease_write TASK-0001 agent/x widget l1 "src/a.txt" running RUN-B \
  || fail "lease rewrite"
in_lib singular_lease_set_status TASK-0001 blocked >/dev/null 2>&1 || true
in_lib singular_lease_unpark TASK-0001 || fail "unpark"
rc=0; claim RUN-C "$fingerprint_a" worker-no-packet 1 || rc=$?
assert_eq "$rc" "4" "allowance survives lease rewrite and unpark"
python3 - "$SINGULAR_STATE_DIR/leases/TASK-0001.json" <<'PY' || fail "durable allowance record"
import json, sys
lease = json.load(open(sys.argv[1], encoding="utf-8"))
allowance = lease["packetFormatAllowance"]
assert allowance["budgetDomain"] == "packet-format" and allowance["maxPerCandidate"] == 1, allowance
assert [op["failureClass"] for op in allowance["operations"]] == ["worker-no-packet", "packet-invalid"], allowance
assert lease["retryCount"] == 0, lease
PY
printf 'not json\n' >"$SINGULAR_STATE_DIR/leases/TASK-0002.json"
rc=0
claim_for TASK-0002 R "$fingerprint_a" worker-no-packet 1 >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 && "$rc" -ne 4 ]] \
  || fail "an unreadable lease must fail closed, not report claimed/spent (rc=$rc)"
echo "ok: one durable allowance per frozen candidate, shared across error names"

# ---- 3. End to end on the frozen-campaign lifecycle fixture -----------------
# The unit sections above exported a private root; the fixture builds its own.
unset SINGULAR_ROOT SINGULAR_STATE_DIR
FIRST_AUDIT_CASE=packet-format-budget bash "$ENGINE_HOME/tests/test-first-audit-correction.sh"
echo "PASS: test-packet-format-budget"
