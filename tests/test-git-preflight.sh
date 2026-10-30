#!/usr/bin/env bash
set -euo pipefail

# The regression suite needs a real Git working tree — history and
# disposable worktrees. Run it from a `git archive` extraction and every
# dependent test used to fail on its own; the operator got a wall of noise
# instead of one diagnosis. engine/git-preflight.sh rejects that source once,
# before a single test is discovered.
#
#   a  a real repo with a commit -> accepted, silently
#   b  a git-archive extraction of the same layout -> exactly ONE
#      SINGULAR_TEST_SOURCE_UNSUPPORTED block, nonzero exit, ZERO per-test lines
#   c  a repo with no commits -> rejected, detail names HEAD
#   d  the same fixture as a real clone -> the suite runs and exits 0
#
# b/d drive the REAL tests/run.sh over a miniature fixture repo, so the wiring
# (not just the function) is what is under test.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-git-preflight.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFLIGHT="$ENGINE_HOME/engine/git-preflight.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing [$2] in [$1]"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

[[ -f "$PREFLIGHT" ]] || fail "engine/git-preflight.sh is missing"

# The archive fixture only proves anything if the temp dir is OUTSIDE any Git
# working tree — otherwise git walks up and finds a real repo.
if git -C "$tmp" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  fail "temp dir $tmp is inside a Git work tree; this test needs an unowned TMPDIR"
fi

git_commit() { # dir message
  git -C "$1" -c user.email=singular@singular.local -c user.name=singular \
    commit -q -m "$2"
}

# A miniature engine layout: the real run.sh + the two shims + one dummy test.
fixture="$tmp/fixture"
mkdir -p "$fixture/engine" "$fixture/tests"
cp "$ENGINE_HOME/tests/run.sh" "$fixture/tests/run.sh"
cp "$ENGINE_HOME/engine/bash-guard.sh" "$fixture/engine/bash-guard.sh"
cp "$PREFLIGHT" "$fixture/engine/git-preflight.sh"
cat >"$fixture/tests/test-dummy.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "PASS: test-dummy"
EOF
chmod +x "$fixture/tests/run.sh" "$fixture/tests/test-dummy.sh"
git -C "$fixture" init -q -b main 2>/dev/null || git -C "$fixture" init -q
git -C "$fixture" add -A
git_commit "$fixture" "fixture"

# --- a) a real repo with history is accepted, silently ----------------------
out="$(
  set -euo pipefail
  . "$PREFLIGHT"
  singular_git_source_preflight "$fixture" 2>&1
)" || fail "a: preflight rejected a real repo: $out"
[[ -z "$out" ]] || fail "a: preflight must be silent on success, got: $out"

# --- b) a git-archive extraction is rejected exactly once -------------------
archive="$tmp/archive"
mkdir -p "$archive"
git -C "$fixture" archive HEAD | tar -x -C "$archive"
[[ -f "$archive/tests/run.sh" ]] || fail "b: archive extraction did not produce tests/run.sh"
[[ ! -d "$archive/.git" ]] || fail "b: archive extraction unexpectedly carries a .git dir"

rc=0
out="$("$BASH" "$archive/tests/run.sh" </dev/null 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "b: the suite must refuse to run from an archive (exit $rc): $out"
blocks="$(printf '%s\n' "$out" | grep -c '^SINGULAR_TEST_SOURCE_UNSUPPORTED$' || true)"
[[ "$blocks" -eq 1 ]] || fail "b: expected exactly 1 rejection block, got $blocks: $out"
assert_contains "$out" "The full regression suite cannot run from a Git archive because it requires" "b: block line 2"
assert_contains "$out" "history and disposable worktrees." "b: block line 3"
assert_contains "$out" "Recovery: run from a clean Git clone." "b: block recovery line"
assert_contains "$out" "  detail: " "b: block carries a detail line"
per_test="$(printf '%s\n' "$out" | grep -cE '^(PASS|FAIL)  ' || true)"
[[ "$per_test" -eq 0 ]] || fail "b: no test may run from an archive, saw $per_test per-test lines: $out"
assert_contains "$out" "not a Git working tree" "b: detail names the failed property"

# --- c) a repo with no commits is rejected, naming HEAD ---------------------
empty="$tmp/empty"
mkdir -p "$empty"
git -C "$empty" init -q -b main 2>/dev/null || git -C "$empty" init -q
rc=0
out="$(
  . "$PREFLIGHT"
  singular_git_source_preflight "$empty" 2>&1
)" || rc=$?
[[ "$rc" -eq 1 ]] || fail "c: expected return 1 for a repo with no commits, got $rc: $out"
assert_contains "$out" "SINGULAR_TEST_SOURCE_UNSUPPORTED" "c: block header"
assert_contains "$out" "detail: HEAD does not resolve to a commit" "c: detail names HEAD"

# --- d) the same fixture as a real clone runs the suite normally ------------
rc=0
out="$("$BASH" "$fixture/tests/run.sh" </dev/null 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "d: the suite must run from a real repo, exit $rc: $out"
assert_contains "$out" "PASS  test-dummy.sh" "d: the dummy test ran"
assert_contains "$out" "SUMMARY: 1 passed, 0 failed" "d: harness summary is intact"
[[ "$out" != *"SINGULAR_TEST_SOURCE_UNSUPPORTED"* ]] || fail "d: a real repo must not be rejected: $out"

# The probe must not leak worktree metadata into the repo it probed.
leaked="$(git -C "$fixture" worktree list | wc -l | tr -d ' ')"
[[ "$leaked" -eq 1 ]] || fail "d: preflight leaked a worktree registration ($leaked entries)"

echo "PASS: test-git-preflight"
