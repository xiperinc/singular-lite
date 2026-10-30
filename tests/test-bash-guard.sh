#!/usr/bin/env bash
set -euo pipefail

# engine/bash-guard.sh is the ONE Bash >= 4 gate, and cli/singular
# embeds a verbatim copy of it (the CLI cannot source a file it needs Bash >= 4
# to locate). This covers the guard's whole contract:
#
#   a  no-op under Bash >= 4 with no pin: no re-exec, no leftover definitions,
#      positional parameters untouched
#   b  SINGULAR_BASH_BIN that is not an absolute executable -> block, exit 2
#   c  SINGULAR_BASH_BIN that fails the >= 4 probe -> block, exit 2, NO exec
#   d  loop guard: already bootstrapped and still < 4 -> block, exit 2
#   e  the real re-exec actually lands on Bash >= 4
#   f  the CLI's embedded copy behaves the same under a bare /bin/bash
#   g  every adopting file still PARSES under Bash 3.2 — the interpreter the
#      guard exists to rescue must be able to read the file that rescues it
#
# d/e/f need a real Bash 3.2 at /bin/bash (macOS). They skip elsewhere.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-bash-guard.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ENGINE_HOME/engine/bash-guard.sh"
CLI="$ENGINE_HOME/cli/singular"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing [$2] in [$1]"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected [$2] in [$1]"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

[[ -f "$GUARD" ]] || fail "engine/bash-guard.sh is missing"

# Is /bin/bash the ancient one? d/e/f only mean something if it is.
legacy_bash="yes"
if /bin/bash -c '[[ "${BASH_VERSINFO[0]}" -ge 4 ]]' 2>/dev/null; then legacy_bash="no"; fi

# A script that SOURCES the guard, the way every adopting entrypoint does.
wrapper="$tmp/wrapper.sh"
cat >"$wrapper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
. "$SINGULAR_TEST_GUARD"
echo "major=${BASH_VERSINFO[0]}"
echo "args=$*"
echo "argc=$#"
echo "bootstrapped=${SINGULAR_BASH_BOOTSTRAPPED:-<unset>}"
echo "guardfns=$(declare -F | sed -n 's/^declare -f //p' | grep -c singular_bash_guard || true)"
EOF
chmod +x "$wrapper"

# --- a) Bash >= 4, no pin: a true no-op ------------------------------------
out="$(SINGULAR_TEST_GUARD="$GUARD" env -u SINGULAR_BASH_BIN -u SINGULAR_BASH_BOOTSTRAPPED \
  "$BASH" "$wrapper" one "two three" 2>&1)" || fail "a: sourcing the guard under bash >= 4 must succeed: $out"
assert_contains "$out" "args=one two three" "a: positional parameters preserved"
assert_contains "$out" "argc=2" "a: argument count preserved"
assert_contains "$out" "bootstrapped=<unset>" "a: no re-exec happened"
assert_contains "$out" "guardfns=0" "a: guard left no function definitions behind"

# --- b) pin that is not an absolute executable ------------------------------
rc=0
out="$(SINGULAR_TEST_GUARD="$GUARD" SINGULAR_BASH_BIN=/nonexistent/bash \
  env -u SINGULAR_BASH_BOOTSTRAPPED "$BASH" "$wrapper" 2>&1)" || rc=$?
[[ "$rc" -eq 2 ]] || fail "b: expected exit 2 for a nonexistent pin, got $rc ($out)"
assert_contains "$out" "SINGULAR_BASH_UNSUPPORTED" "b: block header"
assert_contains "$out" "Required: Bash >= 4" "b: block requirement line"
assert_contains "$out" "Recovery: brew install bash" "b: block recovery line"
assert_contains "$out" "must be an absolute executable path" "b: detail names the pin"
assert_not_contains "$out" "major=" "b: the guarded script must not run"

# --- c) pin that exists but fails the probe: diagnosed, never exec'd --------
stub="$tmp/fake-bash"
cat >"$stub" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$SINGULAR_TEST_STUB_LOG"
exit 1
EOF
chmod +x "$stub"
stub_log="$tmp/stub.log"
: >"$stub_log"
rc=0
out="$(SINGULAR_TEST_GUARD="$GUARD" SINGULAR_TEST_STUB_LOG="$stub_log" SINGULAR_BASH_BIN="$stub" \
  env -u SINGULAR_BASH_BOOTSTRAPPED "$BASH" "$wrapper" 2>&1)" || rc=$?
[[ "$rc" -eq 2 ]] || fail "c: expected exit 2 for a probe-failing pin, got $rc ($out)"
assert_contains "$out" "SINGULAR_BASH_UNSUPPORTED" "c: block header"
assert_contains "$out" "must provide Bash >= 4" "c: detail names the failed probe"
calls="$(wc -l <"$stub_log" | tr -d ' ')"
[[ "$calls" -eq 1 ]] || fail "c: pin must be probed exactly once and never exec'd (calls=$calls)"
assert_contains "$(cat "$stub_log")" "-c " "c: the single call was the version probe"

# --- d) loop guard: re-exec target lied ------------------------------------
if [[ "$legacy_bash" == "yes" ]]; then
  rc=0
  out="$(SINGULAR_TEST_GUARD="$GUARD" SINGULAR_BASH_BOOTSTRAPPED=1 \
    env -u SINGULAR_BASH_BIN /bin/bash "$wrapper" 2>&1)" || rc=$?
  [[ "$rc" -eq 2 ]] || fail "d: expected exit 2 from the loop guard, got $rc ($out)"
  assert_contains "$out" "SINGULAR_BASH_UNSUPPORTED" "d: block header"
  assert_contains "$out" "Found: /bin/bash 3." "d: block reports the running interpreter"
  assert_contains "$out" "Required: Bash >= 4" "d: block requirement line"
  assert_contains "$out" "Recovery: brew install bash && SINGULAR_BASH_BIN=/opt/homebrew/bin/bash singular setup" \
    "d: block recovery line"
  assert_contains "$out" "re-exec target did not provide Bash >= 4" "d: detail names the cause"
  assert_not_contains "$out" "major=" "d: the guarded script must not run"
else
  echo "SKIP  d: /bin/bash is already >= 4 on this machine"
fi

# --- e) the re-exec actually lands on Bash >= 4 ----------------------------
if [[ "$legacy_bash" == "yes" ]]; then
  out="$(SINGULAR_TEST_GUARD="$GUARD" SINGULAR_BASH_BIN="$BASH" \
    env -u SINGULAR_BASH_BOOTSTRAPPED /bin/bash "$wrapper" alpha 2>&1)" \
    || fail "e: guarded re-exec failed: $out"
  major="$(printf '%s\n' "$out" | sed -n 's/^major=//p')"
  [[ -n "$major" && "$major" -ge 4 ]] || fail "e: re-exec did not land on bash >= 4 (major=${major:-<none>}): $out"
  assert_contains "$out" "args=alpha" "e: arguments survive the re-exec"
  assert_contains "$out" "bootstrapped=1" "e: loop guard marker is exported"
else
  echo "SKIP  e: /bin/bash is already >= 4 on this machine"
fi

# --- e2) the bare-3.2-no-env case: fallback probes must find a Bash >= 4 ----
# The old CLI guard only re-executed when
# SINGULAR_BASH_BIN was set, so `/bin/bash <script>` ran unguarded under 3.2.
if [[ "$legacy_bash" == "yes" ]]; then
  if [[ -x /opt/homebrew/bin/bash || -x /usr/local/bin/bash ]]; then
    out="$(SINGULAR_TEST_GUARD="$GUARD" env -u SINGULAR_BASH_BIN -u SINGULAR_BASH_BOOTSTRAPPED \
      /bin/bash "$wrapper" beta 2>&1)" || fail "e2: unpinned fallback re-exec failed: $out"
    major="$(printf '%s\n' "$out" | sed -n 's/^major=//p')"
    [[ -n "$major" && "$major" -ge 4 ]] || fail "e2: no fallback re-exec happened (major=${major:-<none>}): $out"
    assert_contains "$out" "args=beta" "e2: arguments survive the fallback re-exec"
    assert_contains "$out" "bootstrapped=1" "e2: loop guard marker is exported"
  else
    echo "SKIP  e2: no Homebrew bash installed to fall back to"
  fi
else
  echo "SKIP  e2: /bin/bash is already >= 4 on this machine"
fi

# --- f) the CLI's embedded copy behaves identically -------------------------
# A bare `/bin/bash singular` with NO SINGULAR_* env must also bootstrap:
# it used to fall straight through the old pin-only guard.
if [[ "$legacy_bash" == "yes" ]]; then
  rc=0
  out="$(cd "$ENGINE_HOME" && env -i HOME="$HOME" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" \
    /bin/bash "$CLI" version 2>&1)" || rc=$?
  assert_not_contains "$out" "syntax error" "f: the CLI must never fail to parse under bash 3.2"
  assert_not_contains "$out" "unexpected token" "f: the CLI must never fail to parse under bash 3.2"
  if [[ "$rc" -eq 0 ]]; then
    assert_contains "$out" "singular CLI" "f: fallback re-exec reached the CLI body"
  else
    [[ "$rc" -eq 2 ]] || fail "f: expected exit 0 (re-exec) or 2 (diagnosis), got $rc ($out)"
    assert_contains "$out" "SINGULAR_BASH_UNSUPPORTED" "f: diagnosis block header"
    assert_contains "$out" "Required: Bash >= 4" "f: diagnosis requirement line"
  fi
else
  echo "SKIP  f: /bin/bash is already >= 4 on this machine"
fi

# --- h) the harness hands every test a Bash >= 4 interpreter ---------------
# tests/run.sh used to launch each test with a bare `bash`. With a 3.2 first on
# PATH that turned one environmental fact into one failure per test file — the
# cascade of interpreter failures. Prove it launches "$BASH" (already vetted >= 4)
# even when PATH-bash is ancient.
if [[ "$legacy_bash" == "yes" ]]; then
  fx="$tmp/harness"
  mkdir -p "$fx/engine" "$fx/tests" "$tmp/shim"
  cp "$ENGINE_HOME/tests/run.sh" "$fx/tests/run.sh"
  cp "$GUARD" "$fx/engine/bash-guard.sh"
  cp "$ENGINE_HOME/engine/git-preflight.sh" "$fx/engine/git-preflight.sh"
  cat >"$fx/tests/test-needs-bash4.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
[[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]] || { echo "harness handed me bash ${BASH_VERSION}"; exit 1; }
echo "ok"
EOF
  git -C "$fx" init -q -b main 2>/dev/null || git -C "$fx" init -q
  git -C "$fx" add -A
  git -C "$fx" -c user.email=singular@singular.local -c user.name=singular commit -q -m fixture
  ln -s /bin/bash "$tmp/shim/bash"
  rc=0
  out="$(PATH="$tmp/shim:$PATH" "$BASH" "$fx/tests/run.sh" </dev/null 2>&1)" || rc=$?
  [[ "$rc" -eq 0 ]] || fail "h: harness must launch tests under bash >= 4 even when PATH bash is 3.2 (exit $rc): $out"
  assert_contains "$out" "PASS  test-needs-bash4.sh" "h: the bash-4-requiring test ran under a >= 4 interpreter"
else
  echo "SKIP  h: /bin/bash is already >= 4 on this machine"
fi

# --- g) every adopting file parses under Bash 3.2 ---------------------------
for rel in engine/bash-guard.sh engine/git-preflight.sh cli/singular install.sh \
           migrations/v0-to-v1.sh migrations/v1-to-v2.sh tests/run.sh; do
  [[ -f "$ENGINE_HOME/$rel" ]] || fail "g: $rel is missing"
  perr="$(/bin/bash -n "$ENGINE_HOME/$rel" 2>&1)" \
    || fail "g: $rel does not parse under /bin/bash ($(/bin/bash -c 'echo $BASH_VERSION')): $perr"
done

# The two copies of the guard must not drift: the CLI's embedded block has to
# contain the shim's body verbatim, or a fix lands in only one of them.
body_start="$(grep -nxF 'if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 || -n "${SINGULAR_BASH_BIN:-}" ]]; then' "$GUARD" | head -n1 | cut -d: -f1)"
[[ -n "$body_start" ]] || fail "sync: could not locate the guard body in engine/bash-guard.sh"
sed -n "${body_start},\$p" "$GUARD" >"$tmp/guard-body"
python3 - "$tmp/guard-body" "$CLI" <<'PY' || fail "sync: cli/singular no longer embeds engine/bash-guard.sh verbatim"
import sys
body = open(sys.argv[1], encoding="utf-8").read()
cli = open(sys.argv[2], encoding="utf-8").read()
sys.exit(0 if body.strip() and body in cli else 1)
PY
grep -q 'keep in sync with engine/bash-guard.sh' "$CLI" || fail "sync: cli/singular lost its sync marker"
grep -q 'keep in sync with cli/singular' "$GUARD" || fail "sync: engine/bash-guard.sh lost its sync marker"

echo "PASS: test-bash-guard"
