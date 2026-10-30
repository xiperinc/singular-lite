#!/usr/bin/env bash
# Regression contracts for ctx-critic-recheck-context.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"
CTX="$ENGINE_HOME/engine/ctx-critic-recheck-context.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Isolated state: never touch the real repo or its events log -------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state"

export SINGULAR_ROOT="$tmp"
export SINGULAR_STATE_DIR="$tmp/state"
export SINGULAR_EVENTS_FILE="$tmp/events.ndjson"
: > "$SINGULAR_EVENTS_FILE"

# shellcheck disable=SC1090
source "$LIB" || fail "sourcing lib.sh failed"

# (a) The engine file must exist and be auto-sourced by lib.sh's ctx-loader; it
#     defines the two NEW functions (RED before impl).
[[ -f "$CTX" ]] || fail "engine not present yet: $CTX"
[[ "$(type -t singular_ctx_critic_recheck_accepted_diff)" == "function" ]] \
  || fail "singular_ctx_critic_recheck_accepted_diff not defined (auto-source failed?)"
[[ "$(type -t singular_ctx_critic_recheck_context)" == "function" ]] \
  || fail "singular_ctx_critic_recheck_context not defined (auto-source failed?)"

# A sentinel runner: if any function ever spawns a runner, this file appears.
SENTINEL="$tmp/runner-invoked"
STUB="$tmp/stub-runner.sh"
cat > "$STUB" <<STUBEOF
#!/usr/bin/env bash
touch "$SENTINEL"
exit 0
STUBEOF
chmod +x "$STUB"
export SINGULAR_RUNNER="$STUB"

# ---------------------------------------------------------------------------
# (b) accepted-diff resolution over a small git fixture.
# ---------------------------------------------------------------------------
repo="$tmp/repo"
mkdir -p "$repo"
(
  cd "$repo"
  git init -q
  git config user.email "t@t.local"
  git config user.name "t"
  printf 'line-one\n' > file.txt
  git add file.txt
  git commit -qm "base"
) || fail "git fixture setup failed"
BASE="$(git -C "$repo" rev-parse HEAD)"
(
  cd "$repo"
  printf 'line-one\nADDED-BY-ACCEPTED-DIFF\n' > file.txt
  git add file.txt
  git commit -qm "head"
) || fail "git fixture head commit failed"
HEAD_REF="$(git -C "$repo" rev-parse HEAD)"

# Purity of the diff reader: capture worktree + state fingerprint before/after.
worktree_fp() { git -C "$repo" status --porcelain=v1; git -C "$repo" rev-parse HEAD; }
before_wt="$(worktree_fp)"

diff_out="$(singular_ctx_critic_recheck_accepted_diff "$BASE" "$HEAD_REF" "$repo")" \
  || fail "accepted-diff reader must exit 0"
printf '%s\n' "$diff_out" | grep -q 'ADDED-BY-ACCEPTED-DIFF' \
  || fail "accepted-diff must contain the accepted change (got: $diff_out)"

after_wt="$(worktree_fp)"
[[ "$before_wt" == "$after_wt" ]] || fail "accepted-diff reader mutated the worktree"
[[ ! -e "$SENTINEL" ]] || fail "accepted-diff reader spawned a runner"
[[ ! -s "$SINGULAR_EVENTS_FILE" ]] || fail "accepted-diff reader appended events (must be read-only)"

# Indeterminate / empty ref -> empty output, no crash.
empty_base="$(singular_ctx_critic_recheck_accepted_diff "" "$HEAD_REF" "$repo")" \
  || fail "empty base ref must not crash"
[[ -z "$empty_base" ]] || fail "empty base ref must yield empty output (got: $empty_base)"

empty_head="$(singular_ctx_critic_recheck_accepted_diff "$BASE" "" "$repo")" \
  || fail "empty head ref must not crash"
[[ -z "$empty_head" ]] || fail "empty head ref must yield empty output (got: $empty_head)"

bogus="$(singular_ctx_critic_recheck_accepted_diff "deadbeefdeadbeef" "$HEAD_REF" "$repo")" \
  || fail "indeterminate ref must not crash"
[[ -z "$bogus" ]] || fail "indeterminate ref must yield empty output (got: $bogus)"

# Non-repo worktree -> empty output, no crash.
nonrepo="$tmp/not-a-repo"
mkdir -p "$nonrepo"
nr="$(singular_ctx_critic_recheck_accepted_diff "$BASE" "$HEAD_REF" "$nonrepo")" \
  || fail "non-repo worktree must not crash"
[[ -z "$nr" ]] || fail "non-repo worktree must yield empty output (got: $nr)"

# ---------------------------------------------------------------------------
# (c) context assembler: header + id-sorted checklist + accepted diff.
# ---------------------------------------------------------------------------
# A valid plan-critique.v0 record with THREE prior findings (out of id order).
rec="$tmp/critique.json"
cat > "$rec" <<'JSON'
{
  "schema": "singular.orchestration.plan-critique.v0",
  "node": "critic-carryover",
  "runId": "RUN-CRIT",
  "batchTaskIds": ["TASK-0007"],
  "verdict": "revise",
  "findings": [
    { "id": "f-0000000000b2", "severity": "should-fix", "claim": "CLAIM-BRAVO", "evidence": "EVID-BRAVO" },
    { "id": "f-0000000000a1", "severity": "blocking",    "claim": "CLAIM-ALPHA", "evidence": "EVID-ALPHA" },
    { "id": "f-0000000000c3", "severity": "nit",         "claim": "CLAIM-CHARLIE", "evidence": "EVID-CHARLIE" }
  ],
  "assumptionsChallenged": [],
  "rationale": "test critique"
}
JSON

# Materialize the accepted diff to a file (as the follow-up runner would).
diff_file="$tmp/accepted.diff"
printf '%s\n' "$diff_out" > "$diff_file"

out="$tmp/recheck-context.md"
singular_ctx_critic_recheck_context "critic-carryover" "TASK-0030" "$rec" "$diff_file" "$out" \
  || fail "context assembler crashed"
[[ -f "$out" ]] || fail "context assembler did not write the composed output file"

# Header frames the skeptic recheck question.
grep -qi 'addressed' "$out" || fail "context missing the recheck question (addressed)"
grep -qi 'survives'  "$out" || fail "context missing the recheck question (survives)"
grep -qi 'obsolete'  "$out" || fail "context missing the recheck question (obsolete)"

# Per-finding checklist: id, severity, claim, evidence for every prior finding.
for tok in f-0000000000a1 f-0000000000b2 f-0000000000c3 \
           CLAIM-ALPHA CLAIM-BRAVO CLAIM-CHARLIE \
           EVID-ALPHA EVID-BRAVO EVID-CHARLIE \
           blocking should-fix nit; do
  grep -q "$tok" "$out" || fail "context checklist missing token: $tok"
done

# Accepted diff embedded in the composed context.
grep -q 'ADDED-BY-ACCEPTED-DIFF' "$out" || fail "context missing the accepted-diff content"

# id-sorted ordering: a1 before b2 before c3.
a_line="$(grep -n 'f-0000000000a1' "$out" | head -1 | cut -d: -f1)"
b_line="$(grep -n 'f-0000000000b2' "$out" | head -1 | cut -d: -f1)"
c_line="$(grep -n 'f-0000000000c3' "$out" | head -1 | cut -d: -f1)"
[[ -n "$a_line" && -n "$b_line" && -n "$c_line" \
   && "$a_line" -lt "$b_line" && "$b_line" -lt "$c_line" ]] \
  || fail "findings not emitted in id-sorted order (a1 < b2 < c3)"

# ---------------------------------------------------------------------------
# (d) determinism: byte-stable across repeated runs for a fixed input set.
# ---------------------------------------------------------------------------
out2="$tmp/recheck-context-2.md"
singular_ctx_critic_recheck_context "critic-carryover" "TASK-0030" "$rec" "$diff_file" "$out2" \
  || fail "context assembler crashed on second run"
cmp -s "$out" "$out2" || fail "composed context is not byte-stable across runs"

# ---------------------------------------------------------------------------
# (f) purity: writes ONLY <out_file>, appends NO events, mutates nothing else.
# ---------------------------------------------------------------------------
singular_ensure_state_dirs
: > "$SINGULAR_EVENTS_FILE"
before_state="$(ls -1a "$tmp/state" | sort | shasum | awk '{print $1}')"
before_rec="$(cat "$rec" | cksum)"
before_diff="$(cat "$diff_file" | cksum)"
out3="$tmp/recheck-context-3.md"
singular_ctx_critic_recheck_context "critic-carryover" "TASK-0030" "$rec" "$diff_file" "$out3" \
  || fail "context assembler crashed on purity run"
[[ ! -e "$SENTINEL" ]] || fail "context assembler spawned a runner"
after_state="$(ls -1a "$tmp/state" | sort | shasum | awk '{print $1}')"
[[ "$before_state" == "$after_state" ]] || fail "context assembler mutated the state dir"
[[ "$before_rec" == "$(cat "$rec" | cksum)" ]] || fail "context assembler mutated the prior record"
[[ "$before_diff" == "$(cat "$diff_file" | cksum)" ]] || fail "context assembler mutated the diff file"
[[ ! -s "$SINGULAR_EVENTS_FILE" ]] || fail "context assembler appended events (must be read-only)"

# ---------------------------------------------------------------------------
# (e) graceful degradation: missing/unparseable record and/or missing/empty diff.
# ---------------------------------------------------------------------------
# Missing prior record -> empty checklist, still well-formed, no fabricated ids.
out_norec="$tmp/ctx-norec.md"
singular_ctx_critic_recheck_context "critic-carryover" "TASK-0030" "$tmp/nope.json" "$diff_file" "$out_norec" \
  || fail "missing prior record must not crash"
[[ -f "$out_norec" ]] || fail "missing prior record must still write a well-formed context"
grep -qi 'addressed' "$out_norec" || fail "missing-record context must still frame the recheck question"
grep -q 'f-0000000000a1' "$out_norec" && fail "missing prior record must not fabricate findings"
grep -q 'ADDED-BY-ACCEPTED-DIFF' "$out_norec" || fail "missing-record context must still embed the diff"

# Unparseable prior record -> empty checklist, no crash, no fabrication.
badrec="$tmp/bad-rec.json"
printf 'not { valid json\n' > "$badrec"
out_badrec="$tmp/ctx-badrec.md"
singular_ctx_critic_recheck_context "critic-carryover" "TASK-0030" "$badrec" "$diff_file" "$out_badrec" \
  || fail "unparseable prior record must not crash"
[[ -f "$out_badrec" ]] || fail "unparseable prior record must still write a context"
grep -q 'f-0000000000a1' "$out_badrec" && fail "unparseable prior record must not fabricate findings"

# Missing accepted-diff file -> empty diff section, still well-formed.
out_nodiff="$tmp/ctx-nodiff.md"
singular_ctx_critic_recheck_context "critic-carryover" "TASK-0030" "$rec" "$tmp/no-diff.diff" "$out_nodiff" \
  || fail "missing accepted-diff file must not crash"
[[ -f "$out_nodiff" ]] || fail "missing accepted-diff must still write a well-formed context"
grep -q 'f-0000000000a1' "$out_nodiff" || fail "missing-diff context must still carry the checklist"
grep -q 'ADDED-BY-ACCEPTED-DIFF' "$out_nodiff" && fail "missing-diff context must not fabricate diff content"

# Empty accepted-diff file -> empty diff section, no crash.
empty_diff="$tmp/empty.diff"
: > "$empty_diff"
out_emptydiff="$tmp/ctx-emptydiff.md"
singular_ctx_critic_recheck_context "critic-carryover" "TASK-0030" "$rec" "$empty_diff" "$out_emptydiff" \
  || fail "empty accepted-diff file must not crash"
[[ -f "$out_emptydiff" ]] || fail "empty accepted-diff must still write a context"

# ---------------------------------------------------------------------------
# (a) present-but-uncalled: no existing engine path invokes the new functions.
# ---------------------------------------------------------------------------
for fn in singular_ctx_critic_recheck_accepted_diff singular_ctx_critic_recheck_context; do
  callers="$(grep -rl "$fn" "$ENGINE_HOME/engine" 2>/dev/null \
    | grep -v '/ctx-critic-recheck-context.sh$' || true)"
  [[ -z "$callers" ]] || fail "$fn must be present-but-uncalled; referenced by: $callers"
done

echo "ctx-critic-recheck-context tests passed"
