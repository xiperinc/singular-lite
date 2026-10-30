#!/usr/bin/env bash
set -euo pipefail

# P8 (0.5.0): doctor preflights — legacy pmgo ids (FAIL), broken
# ~/.codex/hooks.json (FAIL), model-prefix warnings, stale pidfiles (warn),
# disk floor. Each of these bit the field run undetected.

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
root="$tmp/repo"
fakehome="$tmp/home"
fakebin="$tmp/bin"
mkdir -p "$root/docs/orchestration/prompts" "$root/schemas/orchestration" \
  "$root/.singular-state" "$fakehome/.codex" "$fakebin"
for schema in "$ENGINE_HOME"/schemas/*.schema.json; do
  cp "$schema" "$root/schemas/orchestration/"
done
git -C "$root" init -q
git -C "$root" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
cat >"$fakebin/codex" <<'EOF'
#!/usr/bin/env bash
if [[ "${DOCTOR_CODEX_SLEEP:-0}" == "1" ]]; then sleep 30; fi
case "${1:-} ${2:-}" in
  "--version ") echo "codex-cli test-1.0" ;;
  "login status")
    [[ "${DOCTOR_CODEX_AUTH_FAIL:-0}" == "1" ]] && { echo "Not logged in"; exit 1; }
    echo "Logged in using test credentials"
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$fakebin/codex"
cat >"$root/singular.config.json" <<'EOF'
{
  "schemaVersion": "v2",
  "targetBranch": "main",
  "gateCommand": "true",
  "env": { "SINGULAR_CODEX_MODEL": "gpt-5.6-sol", "SINGULAR_CLAUDE_MODEL": "bogus-model" }
}
EOF

doctor() {
  (
    cd "$root"
    extra_env=()
    [[ -n "${DOCTOR_CODEX_BIN:-}" ]] && extra_env+=("SINGULAR_CODEX_BIN=$DOCTOR_CODEX_BIN")
    env HOME="$fakehome" SINGULAR_ENGINE_HOME="$ENGINE_HOME" SINGULAR_MIN_DISK_GB=0 \
      PATH="${DOCTOR_PATH:-$fakebin:$PATH}" "${extra_env[@]}" \
      bash "$ENGINE_HOME/cli/singular" doctor "$@" 2>&1
  )
}

# 1. Clean baseline: hooks absent, no pmgo, models checked.
out="$(doctor)" || true
assert_contains "$out" "ok    codex model: gpt-5.6-sol" "known codex prefix ok"
assert_contains "$out" "warn  SINGULAR_CLAUDE_MODEL 'bogus-model'" "unknown claude prefix warns"
assert_contains "$out" "selected Codex executable: $fakebin/codex" "selected codex path reported"
assert_contains "$out" "ok    selected Codex spawn: codex-cli test-1.0" "selected codex is spawned"
assert_contains "$out" "ok    selected Codex authentication" "selected codex auth is checked"
assert_contains "$out" "ok    no legacy pmgo.* schema ids" "pmgo clean"

# 2. Broken hooks.json -> FAIL (nonzero exit).
printf '' >"$fakehome/.codex/hooks.json"
rc=0; out="$(doctor)" || rc=$?
assert_contains "$out" "hooks.json is not valid JSON" "hooks parse failure surfaced"
[[ "$rc" -ne 0 ]] || fail "broken hooks.json must fail doctor"
printf '{}\n' >"$fakehome/.codex/hooks.json"
out="$(doctor)" || true
assert_contains "$out" "ok    ~/.codex/hooks.json parses" "fixed hooks ok"

# 3. Legacy pmgo id in a consumer prompt -> FAIL with migrate pointer.
printf 'emit "schema": "pmgo.orchestration.decider-verdict.v0"\n' \
  >"$root/docs/orchestration/prompts/decider.md"
rc=0; out="$(doctor)" || rc=$?
assert_contains "$out" "legacy pmgo.* schema ids found" "pmgo detected"
assert_contains "$out" "migrations/v0-to-v1.sh" "migrate pointer"
[[ "$rc" -ne 0 ]] || fail "pmgo ids must fail doctor"
rm -f "$root/docs/orchestration/prompts/decider.md"

# 4. Stale pidfile -> warn.
printf '99999999\n' >"$root/.singular-state/autonomate.pid"
out="$(doctor)" || true
assert_contains "$out" "stale pidfile" "stale pidfile warned"

# 5. A broken first PATH candidate is not hidden by a later healthy Codex.
brokenbin="$tmp/broken-bin"
mkdir -p "$brokenbin"
cat >"$brokenbin/codex" <<'EOF'
#!/usr/bin/env bash
echo "Error: packaged native executable ENOENT" >&2
exit 1
EOF
chmod +x "$brokenbin/codex"
rc=0
out="$(DOCTOR_PATH="$brokenbin:$fakebin:$PATH" doctor)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "broken selected Codex must fail doctor"
assert_contains "$out" "selected Codex executable: $brokenbin/codex" "doctor reports broken selected path"
assert_contains "$out" "selected Codex spawn probe failed" "broken native spawn is surfaced"
assert_contains "$out" "ENOENT" "spawn failure preserves useful diagnostic"

# 6. SINGULAR_CODEX_BIN pins the healthy executable independently from PATH.
out="$(DOCTOR_PATH="$brokenbin:$fakebin:$PATH" DOCTOR_CODEX_BIN="$fakebin/codex" doctor)"
assert_contains "$out" "selected Codex executable: $fakebin/codex" "explicit Codex pin wins"
assert_contains "$out" "ok    selected Codex authentication" "pinned Codex auth passes"

# 7. Spawn success is insufficient when the selected CLI reports logged out.
rc=0
out="$(DOCTOR_CODEX_AUTH_FAIL=1 doctor)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "unauthenticated selected Codex must fail doctor"
assert_contains "$out" "selected Codex authentication probe failed" "auth failure surfaced"

# 8. Provider probes are bounded and kill a hung wrapper/native process group.
rc=0
out="$(DOCTOR_CODEX_SLEEP=1 doctor)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "hung selected Codex must fail doctor"
assert_contains "$out" "probe timed out after 10s" "spawn timeout surfaced"

# 9. `bootstrap.required: true` with no commands guarantees nothing, and doctor
# used to report it as passing. templates/singular.config.json shipped exactly
# that block, so every `singular init` inherited the empty promise.
cp "$root/singular.config.json" "$tmp/config.backup"
python3 - "$root/singular.config.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["bootstrap"] = {"required": True, "commands": []}
json.dump(data, open(path, "w"), indent=2)
PY
out="$(doctor)" || true
assert_contains "$out" "required: true but defines no commands" \
  "empty required bootstrap must warn"

# The same block WITH a command is a real guarantee and must not warn.
python3 - "$root/singular.config.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["bootstrap"] = {"required": True, "commands": [{"command": "true"}]}
json.dump(data, open(path, "w"), indent=2)
PY
out="$(doctor)" || true
[[ "$out" != *"required: true but defines no commands"* ]] \
  || fail "a bootstrap with commands must not warn"

# The shipped template must not carry the empty promise it used to: every
# `singular init` copies this file, so a vacuous required:true there put the
# warning above into every new repo.
python3 - "$ENGINE_HOME/templates/singular.config.json" <<'PY' \
  || fail "templates/singular.config.json ships bootstrap.required: true with no commands"
import json, sys
data = json.load(open(sys.argv[1]))
bootstrap = data.get("bootstrap") or {}
commands = bootstrap.get("commands") or []
raise SystemExit(
    1 if bootstrap.get("required") and not (bootstrap.get("command") or commands) else 0
)
PY
cp "$tmp/config.backup" "$root/singular.config.json"

# 10. A read-only guard journal whose owner is gone means some worktree still
# holds changes a read-only run made. Only `singular reconcile` applies those, so
# doctor has to say so rather than let the repo sit in that state silently.
mkdir -p "$root/.singular-state/readonly-guard/orphan-run"
cat >"$root/.singular-state/readonly-guard/orphan-run/journal.json" <<'EOF'
{"schema":"singular.orchestration.readonly-guard.v0","ownerPid":999999,
 "worktree":"/nonexistent","entries":{},"trackedBefore":[],"excludes":[]}
EOF
out="$(doctor)" || true
# Asserted on the distinguishing clause, not on "read-only guard journal" — the
# PASS message ("no read-only guard journals are pending") contains that too, so
# the looser substring made this case pass with the warn removed entirely.
assert_contains "$out" "were never applied" "orphaned guard journal must warn"
rm -rf "$root/.singular-state/readonly-guard"
out="$(doctor)" || true
[[ "$out" != *"were never applied"* ]] || fail "no journals must not warn"

# 11. Pidfile verdicts. A PID probe has four outcomes and doctor used
# to print one of them. The field cost was a live console server reported as a
# leftover in a sandbox that denies process inspection, which is an invitation
# to delete the pidfile of a running process.
#
# (a) alive: previously emitted NOTHING at all, so a healthy pidfile and a
# pidfile doctor had not looked at were indistinguishable.
printf '%s\n' "$$" >"$root/.singular-state/autonomate.pid"
rc=0; out="$(doctor)" || rc=$?
assert_contains "$out" "names live PID $$" "a live pidfile is reported as live"
[[ "$rc" -eq 0 ]] || fail "a live pidfile must not fail doctor"
[[ "$out" != *"stale pidfile"* ]] || fail "a live pid must never be called stale"

# (b) malformed: not a pid at all. Distinct from staleness — there is no process
# to restart, and "remove this stale pidfile" is the wrong instruction.
printf 'not-a-pid\n' >"$root/.singular-state/autonomate.pid"
out="$(doctor)" || true
assert_contains "$out" "malformed pidfile" "unparseable contents are reported as malformed"
[[ "$out" != *"stale pidfile"* ]] || fail "malformed contents are not staleness"

# A negative number parses as an int but is a process-GROUP selector to kill(2),
# not a pid: probing it asks about every process this user may signal, which
# answers "alive" for a garbage file.
printf -- '-1\n' >"$root/.singular-state/autonomate.pid"
out="$(doctor)" || true
assert_contains "$out" "malformed pidfile" "a group selector is not a live pid"
[[ "$out" != *"names live PID"* ]] || fail "a negative pid must never read as alive"

# (c) unknown-permission: exercise the verdict with a REAL EPERM.
# PID 1 is root-owned, and POSIX applies the permission check to signal 0 too,
# so an unprivileged `kill -0 1` is the same inconclusive answer a restricted
# sandbox gives for every pid. Skipped under root, where the probe legitimately
# succeeds; the seam below covers that case.
if [[ "$(id -u)" -ne 0 ]]; then
  printf '1\n' >"$root/.singular-state/autonomate.pid"
  out="$(doctor)" || true
  assert_contains "$out" "Do not delete the pidfile automatically." \
    "a real EPERM warns without inviting deletion"
  [[ "$out" != *"stale pidfile"* ]] || fail "EPERM must never be reported as stale"
fi

# The same verdict through the seam, which is how a CI job on a permissive host
# exercises the branch at all.
printf '99999999\n' >"$root/.singular-state/autonomate.pid"
out="$(SINGULAR_TEST_PID_PROBE=1 SINGULAR_TEST_PID_PROBE_STATE=unknown doctor)" || true
assert_contains "$out" "Do not delete the pidfile automatically." \
  "the seam reports an uninspectable pid the same way"
[[ "$out" != *"stale pidfile"* ]] || fail "the seam must not report EPERM as stale"

# (d) A lone seam variable is not a seam: an inherited SINGULAR_TEST_PID_PROBE_STATE
# must not be able to rewrite a real operator's diagnosis.
out="$(SINGULAR_TEST_PID_PROBE_STATE=unknown doctor)" || true
assert_contains "$out" "stale pidfile" "a lone seam variable falls through to the real probe"

# (e) Doctor is read-only about pidfiles in every verdict, including under the
# one flag that does mutate state. An inconclusive probe must not lose the file.
out="$(SINGULAR_TEST_PID_PROBE=1 SINGULAR_TEST_PID_PROBE_STATE=unknown doctor --repair-model-cache)" || true
[[ -f "$root/.singular-state/autonomate.pid" ]] \
  || fail "doctor must never delete a pidfile, least of all an uninspectable one"
printf '99999999\n' >"$root/.singular-state/autonomate.pid"

# 12. Process-control capability. Timeout cleanup depends on session
# creation + group termination; `ps` is now only the fallback.
rc=0
out="$(SINGULAR_TEST_PROCESS_CONTROL=1 SINGULAR_TEST_PROCESS_CONTROL_STATE=no-ps doctor)" || rc=$?
assert_contains "$out" "descendant-tree fallback cleanup is degraded" \
  "missing ps is surfaced as a degraded fallback"
[[ "$rc" -eq 0 ]] || fail "missing ps must warn, not block (rc=$rc)"

rc=0
out="$(SINGULAR_TEST_PROCESS_CONTROL=1 SINGULAR_TEST_PROCESS_CONTROL_STATE=no-group-kill doctor)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "an environment that cannot kill a process group must fail doctor"
assert_contains "$out" "Do not run unattended actuation here." \
  "the group-kill failure tells the operator not to actuate unattended"

# Unseamed, on a process-capable host, the real probe passes.
out="$(doctor)" || true
assert_contains "$out" "ok    process-group termination works" "the real group-kill probe passes here"

echo "PASS: test-doctor"
