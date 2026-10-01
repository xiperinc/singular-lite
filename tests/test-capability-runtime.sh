#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/singular-capability-runtime.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

repo="$tmp/repo"
legacy_repo="$tmp/legacy-repo"
fake_bin="$tmp/bin"
args_dir="$tmp/args"
mkdir -p "$repo" "$legacy_repo" "$fake_bin" "$args_dir"
git -C "$repo" init -q
git -C "$repo" -c user.name=test -c user.email=test@example.local \
  commit --allow-empty -q -m init
git -C "$legacy_repo" init -q
git -C "$legacy_repo" -c user.name=test -c user.email=test@example.local \
  commit --allow-empty -q -m init
branch="$(git -C "$repo" branch --show-current)"
legacy_branch="$(git -C "$legacy_repo" branch --show-current)"
prompt="$tmp/prompt.md"
printf 'Return a small successful response.\n' >"$prompt"
mkdir -p "$repo/.agents/skills/local-test"
printf '# Local test skill\n' >"$repo/.agents/skills/local-test/SKILL.md"
printf '{"mcpServers":{"configured-but-isolated":{"command":"true"}}}\n' \
  >"$repo/.mcp.json"

python3 - "$repo/singular.config.json" "$branch" "$tmp/provider-args-canary" <<'PY'
import json
import sys

path, branch, canary = sys.argv[1:]
local_required = [
    "filesystem",
    "git",
    "schemas",
    "runner-contract",
    "provider-executable",
]
data = {
    "schemaVersion": "v2",
    "targetBranch": branch,
    "capabilityProfiles": {
        "strict-local": {
            "startup": "lazy",
            "required": local_required,
            "optional": [
                "file:optional-capability-does-not-exist",
                "mcp:configured-but-isolated",
            ],
        },
        "required-block": {
            "startup": "lazy",
            "required": local_required + ["file:required-capability-does-not-exist"],
            "optional": [],
        },
        "validated-override": {
            "startup": "lazy",
            "required": local_required,
            "optional": [],
            "providerArgs": {
                "cursor": ["--isolated-config", f"literal value;touch {canary}"],
                "grok": ["--isolated-config", f"literal value;touch {canary}"],
            },
        },
        "strict-skill-required": {
            "startup": "lazy",
            "required": local_required + ["skills"],
            "optional": [],
        },
        "strict-skill-unrelated": {
            "startup": "lazy",
            "required": local_required + ["skills"],
            "optional": [],
            "providerArgs": {"codex": ["--ephemeral"]},
        },
        "strict-skill-activated": {
            "startup": "lazy",
            "required": local_required + ["skills"],
            "optional": [],
            "capabilityArgs": {
                "skills": {"codex": ["--ephemeral"]},
            },
        },
        "codex-boundary-denied": {
            "startup": "lazy",
            "required": local_required,
            "optional": [],
            "providerArgs": {"codex": ["--sandbox=danger-full-access"]},
        },
        "claude-boundary-denied": {
            "startup": "lazy",
            "required": local_required,
            "optional": [],
            "providerArgs": {
                "claude": ["--permission-mode=bypassPermissions"],
            },
        },
        "gemini-boundary-denied": {
            "startup": "lazy",
            "required": local_required,
            "optional": [],
            "providerArgs": {"gemini": ["--include-directories=/"]},
        },
        "opencode-boundary-denied": {
            "startup": "lazy",
            "required": local_required,
            "optional": [],
            "providerArgs": {"opencode": ["--pure=false"]},
        },
    },
    "roleProfiles": {
        "planner": "strict-local",
        "blocked": "required-block",
        "validated-override": "validated-override",
        "skill-required": "strict-skill-required",
        "skill-unrelated": "strict-skill-unrelated",
        "skill-activated": "strict-skill-activated",
        "codex-boundary-denied": "codex-boundary-denied",
        "claude-boundary-denied": "claude-boundary-denied",
        "gemini-boundary-denied": "gemini-boundary-denied",
        "opencode-boundary-denied": "opencode-boundary-denied",
    },
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY

# One provider-neutral fake records the literal argv it receives. Its basename
# determines the minimum successful terminal envelope to emit.
python3 - "$fake_bin/provider-fake" <<'PY'
import os
import stat
import sys

path = sys.argv[1]
script = r'''#!/usr/bin/env bash
set -euo pipefail
name="$(basename "$0")"
python3 - "$FAKE_ARGS_DIR/$FAKE_INVOCATION_ID.json" "$@" <<'ARGS'
import json
import sys
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(sys.argv[2:], handle)
    handle.write("\n")
ARGS
case "$name" in
  codex)
    printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":3,"output_tokens":1}}'
    ;;
  claude)
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
    ;;
  gemini)
    printf '%s\n' '{"response":"ok"}'
    ;;
  opencode)
    printf '%s\n' '{"type":"message.part.updated","part":{"id":"p1","type":"text","text":"ok"}}'
    ;;
  cursor-agent)
    printf '%s\n' '{"type":"result","is_error":false,"result":"ok"}'
    ;;
  grok)
    printf '%s\n' '{"type":"result","text":"ok"}'
    ;;
  *)
    exit 127
    ;;
esac
'''
with open(path, "w", encoding="utf-8") as handle:
    handle.write(script)
os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
PY
for name in codex claude gemini opencode cursor-agent grok; do
  ln -s provider-fake "$fake_bin/$name"
done

run_provider() {
  local provider="$1" role="$2" invocation="$3" stderr_file="$4"
  local root="${5:-$repo}" target="${6:-$branch}" fallback="${7:-callsite-fallback}"
  local runner_provider="$provider"
  [[ "$provider" == "cursor-agent" ]] && runner_provider="cursor"
  # An explicitly selected JSON config must exist (lib.sh refuses a missing
  # selection); the legacy repository declares no config at all.
  local -a config_selection=()
  [[ -f "$root/singular.config.json" ]] \
    && config_selection=(SINGULAR_JSON_CONFIG_FILE="$root/singular.config.json")
  env \
    -u SINGULAR_JSON_CONFIG_FILE \
    -u SINGULAR_CAPABILITY_PROFILES_JSON \
    -u SINGULAR_ROLE_PROFILES_JSON \
    -u SINGULAR_CAPABILITIES_JSON \
    -u SINGULAR_CONFIG_SCHEMA_VERSION \
    PATH="$fake_bin:$PATH" \
    FAKE_ARGS_DIR="$args_dir" \
    FAKE_INVOCATION_ID="$invocation" \
    SINGULAR_ROOT="$root" \
    SINGULAR_STATE_DIR="$root/.singular-state" \
    ${config_selection[@]+"${config_selection[@]}"} \
    SINGULAR_TARGET_BRANCH="$target" \
    SINGULAR_CODEX_BIN="$fake_bin/codex" \
    SINGULAR_CODEX_TIMEOUT_SEC=0 \
    SINGULAR_CLAUDE_TIMEOUT_SEC=0 \
    SINGULAR_GEMINI_TIMEOUT_SEC=0 \
    SINGULAR_OPENCODE_TIMEOUT_SEC=0 \
    SINGULAR_CURSOR_TIMEOUT_SEC=0 \
    SINGULAR_GROK_TIMEOUT_SEC=0 \
    bash "$ROOT/engine/$runner_provider-run.sh" \
      -C "$root" \
      --level l2 \
      --prompt-file "$prompt" \
      --no-output-capture \
      --run-id "RUN-$invocation" \
      --role "$role" \
      --capability-profile "$fallback" \
      --result-file "$tmp/$invocation-result.json" \
      >"$tmp/$invocation.stdout" 2>"$stderr_file"
}

assert_arg() {
  python3 - "$args_dir/$1.json" "$2" <<'PY' || fail "$1 omitted argv $2"
import json
import sys
argv = json.load(open(sys.argv[1], encoding="utf-8"))
assert sys.argv[2] in argv, argv
PY
}

assert_pair() {
  python3 - "$args_dir/$1.json" "$2" "$3" <<'PY' || fail "$1 argv pair $2 $3"
import json
import sys
argv = json.load(open(sys.argv[1], encoding="utf-8"))
index = argv.index(sys.argv[2])
assert argv[index + 1] == sys.argv[3], argv
PY
}

# Keep the policy table broad enough to cover every provider boundary Singular
# owns, while leaving Cursor/Grok's explicit isolation argv path available.
python3 - "$ROOT/engine" <<'PY' \
  || fail "strict provider argument denylist policy"
import sys
sys.path.insert(0, sys.argv[1])
from capability_policy import strict_provider_arg_violation

denied = {
    "codex": [
        "--dangerously-bypass-approvals-and-sandbox",
        "--sandbox=danger-full-access",
        "-C/tmp/outside",
        "-c",
        "--add-dir=/",
        "--",
    ],
    "claude": [
        "--dangerously-skip-permissions",
        "--permission-mode=bypassPermissions",
        "--add-dir=/",
        "--mcp-config=/tmp/unsafe.json",
        "--plugin-dir=/tmp/plugin",
        "--safe-mode=false",
    ],
    "gemini": [
        "--approval-mode=yolo",
        "--allowed-mcp-server-names=unsafe",
        "--extensions=all",
        "--include-directories=/",
        "--sandbox=false",
        "-y",
    ],
    "opencode": [
        "--pure=false",
        "--agent=unsafe",
        "--attach=http://localhost:4096",
        "--file=/etc/passwd",
        "--config=/tmp/unsafe.json",
    ],
}
for provider, arguments in denied.items():
    for argument in arguments:
        assert strict_provider_arg_violation(provider, [argument]), (
            provider,
            argument,
        )
assert strict_provider_arg_violation("codex", ["--color=never"]) is None
assert strict_provider_arg_violation("claude", ["--fallback-model=sonnet"]) is None
assert strict_provider_arg_violation("gemini", ["--debug"]) is None
assert strict_provider_arg_violation("opencode", ["--title=test"]) is None
assert strict_provider_arg_violation("cursor", ["--sandbox", "strict"]) is None
assert strict_provider_arg_violation("grok", ["--allow", "Read(**)"]) is None
PY
pass "strict built-in provider argument policy denies boundary overrides"

# roleProfiles has authority over a stale call-site fallback. The optional
# capability warning/event is emitted once despite repeated runs.
run_provider codex planner codex-first "$tmp/codex-first.err"
run_provider codex planner codex-second "$tmp/codex-second.err"
python3 - "$tmp/codex-first-result.json" <<'PY' \
  || fail "role profile did not override call-site fallback"
import json
import sys
result = json.load(open(sys.argv[1], encoding="utf-8"))
assert result["capabilityProfile"] == "strict-local", result
PY
warning_count="$(
  { grep -h -c 'optional capability unavailable' \
      "$tmp/codex-first.err" "$tmp/codex-second.err" || true; } \
    | awk '{ total += $1 } END { print total + 0 }'
)"
[[ "$warning_count" -eq 2 ]] || fail "optional warnings emitted $warning_count times"
event_count="$(
  grep -c '"type":"capability.optional_unavailable"' \
    "$repo/.singular-state/events.ndjson" || true
)"
[[ "$event_count" -eq 2 ]] || fail "optional events emitted $event_count times"
python3 - "$repo/.singular-state/events.ndjson" <<'PY' \
  || fail "optional capability warning/event deduplication is not per capability"
import json
import sys
counts = {}
for line in open(sys.argv[1], encoding="utf-8"):
    event = json.loads(line)
    if event.get("type") != "capability.optional_unavailable":
        continue
    capability = event["data"]["capability"]
    counts[capability] = counts.get(capability, 0) + 1
assert counts == {
    "file:optional-capability-does-not-exist": 1,
    "mcp:configured-but-isolated": 1,
}, counts
PY
pass "role resolution wins and optional capability warnings are deduplicated"

# A missing required capability blocks before the provider executable starts and
# still leaves the normalized runner result.
rm -f "$args_dir/codex-blocked.json"
blocked_rc=0
run_provider codex blocked codex-blocked "$tmp/codex-blocked.err" \
  || blocked_rc=$?
[[ "$blocked_rc" -eq 78 ]] || fail "required capability block returned $blocked_rc"
[[ ! -e "$args_dir/codex-blocked.json" ]] \
  || fail "provider started despite failed capability preflight"
python3 - "$tmp/codex-blocked-result.json" <<'PY' \
  || fail "required block result is not bound to its resolved profile"
import json
import sys
result = json.load(open(sys.argv[1], encoding="utf-8"))
assert result["exitCode"] == 78
assert result["capabilityProfile"] == "required-block"
PY
pass "required capability failure blocks before provider execution"

# Strict native modes disable inherited skills/MCP/plugins. A locally available
# skill therefore cannot satisfy a required profile unless validated activation
# argv is declared.
rm -f "$args_dir/codex-skill-blocked.json"
skill_rc=0
run_provider codex skill-required codex-skill-blocked \
  "$tmp/codex-skill-blocked.err" || skill_rc=$?
[[ "$skill_rc" -eq 78 ]] || fail "strict required skill returned $skill_rc"
[[ ! -e "$args_dir/codex-skill-blocked.json" ]] \
  || fail "provider started with a required but unactivated skill"
grep -q 'strict isolation requires capabilityArgs.skills' \
  "$tmp/codex-skill-blocked.err" \
  || fail "strict required skill omitted activation remediation"

rm -f "$args_dir/codex-skill-unrelated.json"
unrelated_rc=0
run_provider codex skill-unrelated codex-skill-unrelated \
  "$tmp/codex-skill-unrelated.err" || unrelated_rc=$?
[[ "$unrelated_rc" -eq 78 ]] \
  || fail "unrelated providerArgs incorrectly activated a required skill"
[[ ! -e "$args_dir/codex-skill-unrelated.json" ]] \
  || fail "provider started after an unbound capability claim"

run_provider codex skill-activated codex-skill-activated \
  "$tmp/codex-skill-activated.err"
assert_arg codex-skill-activated --ephemeral
pass "strict required skills need argv bound to the exact capability"

# Supported providers receive their native strict-isolation flags.
# Plant the exact artifacts a hard-killed strict run used to leave behind. The
# strict MCP config was created with a template ending in ".json", but BSD/macOS
# mktemp only substitutes TRAILING X's, so it produced a file named literally
# "singular-claude-empty-mcp.XXXXXX.json". That works once — the EXIT trap
# removes it — but a killed run (stopped suite, OOM, reboot) leaves the literal
# name behind and every later strict claude run dies with "mkstemp failed: File
# exists". A leaked temp file turned into a permanent provider outage that no
# test noticed, because nothing ever ran with one present.
claude_mcp_leaks=(
  "${TMPDIR:-/tmp}/singular-claude-empty-mcp.XXXXXX.json"
  "${TMPDIR:-/tmp}/singular-claude-mcp.XXXXXX"
)
: >"${claude_mcp_leaks[0]}"
: >"${claude_mcp_leaks[1]}"

run_provider claude planner claude-strict "$tmp/claude-strict.err"
rm -f "${claude_mcp_leaks[@]}"
run_provider gemini planner gemini-strict "$tmp/gemini-strict.err"
run_provider opencode planner opencode-strict "$tmp/opencode-strict.err"
assert_arg codex-first --ignore-user-config
assert_arg claude-strict --safe-mode
assert_arg claude-strict --strict-mcp-config
assert_arg claude-strict --mcp-config
assert_pair gemini-strict --allowed-mcp-server-names ""
assert_pair gemini-strict --extensions none
assert_arg opencode-strict --pure
pass "built-in strict profiles add provider-native isolation argv"

# Legacy free-form environment argv is shell-split and not capability-bound;
# strict profiles reject it before provider launch.
rm -f "$args_dir/claude-legacy-extra.json"
legacy_extra_rc=0
SINGULAR_CLAUDE_EXTRA_ARGS="--allowedTools Bash" \
  run_provider claude planner claude-legacy-extra \
    "$tmp/claude-legacy-extra.err" || legacy_extra_rc=$?
[[ "$legacy_extra_rc" -eq 78 ]] \
  || fail "strict legacy extra argv returned $legacy_extra_rc"
[[ ! -e "$args_dir/claude-legacy-extra.json" ]] \
  || fail "strict provider launched with legacy free-form extra argv"
grep -q 'SINGULAR_CLAUDE_EXTRA_ARGS is disabled' "$tmp/claude-legacy-extra.err" \
  || fail "strict legacy extra argv omitted stable remediation"
pass "strict profiles reject legacy free-form provider argv"

# Even literal argv is rejected before provider launch when it can override the
# host-supplied native strict boundary.
for provider in codex claude gemini opencode; do
  invocation="$provider-boundary-denied"
  rm -f "$args_dir/$invocation.json"
  denied_rc=0
  run_provider "$provider" "$provider-boundary-denied" "$invocation" \
    "$tmp/$invocation.err" || denied_rc=$?
  [[ "$denied_rc" -eq 78 ]] \
    || fail "$provider boundary override returned $denied_rc"
  [[ ! -e "$args_dir/$invocation.json" ]] \
    || fail "$provider launched with a forbidden strict boundary override"
  grep -q 'forbidden for strict' "$tmp/$invocation.err" \
    || fail "$provider boundary override omitted stable remediation"
done
pass "strict provider boundary overrides fail before provider execution"

# Cursor and Grok fail closed without a proven native mode. A declared,
# validated providerArgs override is passed literally as argv without eval.
for provider in cursor-agent grok; do
  invocation="${provider}-strict-block"
  rm -f "$args_dir/$invocation.json"
  strict_rc=0
  run_provider "$provider" planner "$invocation" "$tmp/$invocation.err" \
    || strict_rc=$?
  [[ "$strict_rc" -eq 78 ]] \
    || fail "$provider strict profile without override returned $strict_rc"
  [[ ! -e "$args_dir/$invocation.json" ]] \
    || fail "$provider started without a strict isolation override"

  override="${provider}-override"
  run_provider "$provider" validated-override "$override" "$tmp/$override.err"
  assert_pair "$override" --isolated-config \
    "literal value;touch $tmp/provider-args-canary"
done
[[ ! -e "$tmp/provider-args-canary" ]] \
  || fail "providerArgs were evaluated as shell text"
pass "unsupported strict providers fail closed and validated argv stays literal"

# Repositories with no capability profile declaration retain the v1 behavior:
# the call-site profile is recorded and no isolation/profile gate is introduced.
run_provider cursor-agent legacy legacy-cursor "$tmp/legacy-cursor.err" \
  "$legacy_repo" "$legacy_branch" legacy-fallback
python3 - "$tmp/legacy-cursor-result.json" <<'PY' \
  || fail "legacy profile compatibility changed"
import json
import sys
result = json.load(open(sys.argv[1], encoding="utf-8"))
assert result["exitCode"] == 0
assert result["capabilityProfile"] == "legacy-fallback"
PY
pass "undeclared legacy profiles remain compatible"

echo "capability runtime tests passed"
