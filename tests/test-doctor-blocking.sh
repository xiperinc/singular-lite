#!/usr/bin/env bash
# an engine-pin/schema mismatch used to cascade.
#
# A repo on schema v0 examined by a v2 engine produced a dozen derivative
# failures — an unreadable DAG, absent capability profiles, a drifted schema
# bundle — each a true statement about artifacts this engine was never able to
# interpret, and none of them the thing the operator had to fix. Doctor now
# states the incompatibility once and records why everything downstream did not
# run, while the checks that describe the HOST (bash, python, git, worktrees)
# keep answering, because their answers do not depend on any schema.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing [$2] in [$1]"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fakehome="$tmp/home"
mkdir -p "$fakehome"

# repo fixture: git repo with one commit, a mirrored schema bundle (so the
# bundle check has something valid to compare and cannot be the reason a case
# fails), and the given schemaVersion.
make_repo() { # dir schemaVersion [enginePin]
  local dir="$1" sv="$2" pin="${3:-}"
  mkdir -p "$dir/schemas/orchestration" "$dir/docs/orchestration/prompts"
  local schema
  for schema in "$ROOT"/schemas/*.schema.json; do
    cp "$schema" "$dir/schemas/orchestration/"
  done
  git -C "$(dirname "$dir")" init -q "$(basename "$dir")"
  git -C "$dir" config user.email blocking@example.com
  git -C "$dir" config user.name blocking
  git -C "$dir" commit -q --allow-empty -m init
  python3 - "$dir/singular.config.json" "$sv" <<'PY'
import json, sys
path, sv = sys.argv[1:]
data = {
    "schemaVersion": sv,
    "targetBranch": "main",
    "gateCommand": "true",
    "capabilityProfiles": {
        "audit-core": {"startup": "lazy", "required": ["filesystem", "git"]}
    },
    "roleProfiles": {"auditor": "audit-core"},
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY
  cat >"$dir/docs/orchestration/dag.v0.json" <<'EOF'
{
  "schema": "singular.orchestration.dag.v0",
  "nodes": [
    {
      "id": "M0.scaffold",
      "stage": "M0",
      "area": "core",
      "layer": "scaffold",
      "kind": "build",
      "dependsOn": [],
      "requiredCompletion": "scaffold complete"
    }
  ]
}
EOF
  [[ -z "$pin" ]] || printf '%s\n' "$pin" >"$dir/.singular-version"
}

doctor() { # repo [args...]
  local dir="$1"; shift
  (
    cd "$dir" \
      && env HOME="$fakehome" SINGULAR_ENGINE_HOME="$ROOT" \
        bash "$ROOT/cli/singular" doctor "$@" 2>/dev/null
  )
}

esv="$(tr -d '[:space:]' <"$ROOT/SCHEMA_VERSION")"
[[ "$esv" != "v0" ]] || fail "fixture assumes the engine is past schema v0"

# --- (a) mismatch: one primary diagnosis, everything derivative marked skip ---
make_repo "$tmp/repo-mismatch" v0
rc=0
report="$(doctor "$tmp/repo-mismatch" --json)" || rc=$?
[[ "$rc" -eq 1 ]] || fail "a schema mismatch must exit 1 (got $rc)"
python3 - "$report" "$esv" <<'PY' || exit 1
import json, sys
data = json.loads(sys.argv[1])
engine_schema = sys.argv[2]
assert data["schema"] == "singular.doctor-report.v1", data["schema"]
assert data["blocking"] == {
    "checkId": "schema.version",
    "code": "SINGULAR_SCHEMA_MISMATCH",
}, data["blocking"]
by_id = {item["id"]: item for item in data["checks"]}

primary = by_id["schema.version"]
assert primary["status"] == "fail", primary
assert primary["details"]["code"] == "SINGULAR_SCHEMA_MISMATCH", primary["details"]
assert primary["message"].startswith(
    f"schemaVersion mismatch: repo v0 vs engine {engine_schema}"
), primary["message"]
assert primary["remediation"] == "Run: singular setup", primary["remediation"]
assert primary["details"]["alternateRemediation"] == "Run: singular migrate", primary["details"]

for check_id in ("dag.evaluation", "capability.profiles", "config.source-conflict"):
    item = by_id[check_id]
    assert item["status"] == "skip", item
    assert item["details"]["blockedBy"] == "schema.version", item
    assert "SINGULAR_SCHEMA_MISMATCH" in item["message"], item["message"]

# Host truth is not a derivative of the repo's schema and must still be answered.
for check_id in ("runtime.bash", "runtime.python", "git.disposable-worktree"):
    item = by_id[check_id]
    assert item["status"] != "skip", item
    assert "blockedBy" not in item.get("details", {}), item

# Exactly one failure: the incompatibility itself.
failures = [item["id"] for item in data["checks"] if item["status"] == "fail"]
assert failures == ["schema.version"], failures
PY

# --- (b) matched versions: nothing is blocked --------------------------------
make_repo "$tmp/repo-matched" "$esv"
report="$(doctor "$tmp/repo-matched" --json)" || true
python3 - "$report" <<'PY' || exit 1
import json, sys
data = json.loads(sys.argv[1])
assert data["blocking"] is None, data["blocking"]
blocked = [
    item["id"] for item in data["checks"]
    if item.get("details", {}).get("blockedBy")
]
assert blocked == [], blocked
assert next(
    item for item in data["checks"] if item["id"] == "schema.version"
)["status"] == "pass"
PY

# --- (c) the historical large graph state: repo pinned 0.3.0, operator on 0.16.0 -----
# SINGULAR_ENGINE_HOME outranks the pin, which is exactly how an operator ends up
# probing a repo with an engine the repo never asked for. Doctor has to say that
# out loud: until now it never read .singular-version at all.
make_repo "$tmp/repo-pinned" v0 0.3.0
report="$(doctor "$tmp/repo-pinned" --json)" || true
python3 - "$report" "$(tr -d '[:space:]' <"$ROOT/VERSION")" <<'PY' || exit 1
import json, sys
data = json.loads(sys.argv[1])
engine_version = sys.argv[2]
by_id = {item["id"]: item for item in data["checks"]}
pin = by_id["pin.engine-version"]
assert pin["status"] == "warn", pin
assert pin["details"]["repoPin"] == "0.3.0", pin["details"]
assert pin["details"]["engineVersion"] == engine_version, pin["details"]
assert "0.3.0" in pin["message"] and engine_version in pin["message"], pin["message"]
assert by_id["pin.sources"]["details"]["resolved"] == "0.3.0", by_id["pin.sources"]

primary = by_id["schema.version"]
assert "Repository: engine 0.3.0" in primary["message"], primary["message"]
assert f"Selected engine: {engine_version}" in primary["message"], primary["message"]
assert "No planning or actuation was attempted." in primary["message"], primary["message"]
PY

# --- (d) human output: the diagnosis leads, the skips follow -----------------
out="$(doctor "$tmp/repo-mismatch")" || true
primary_line="$(printf '%s\n' "$out" | grep -n "schemaVersion mismatch" | head -n1 | cut -d: -f1)"
[[ -n "$primary_line" ]] || fail "human output does not report the mismatch: $out"
first_skip="$(printf '%s\n' "$out" | grep -n "blocked by schema.version" | head -n1 | cut -d: -f1)"
[[ -n "$first_skip" ]] || fail "human output does not report the blocked checks: $out"
[[ "$primary_line" -lt "$first_skip" ]] \
  || fail "the primary diagnosis must precede the checks it blocked ($primary_line >= $first_skip)"
first_info="$(printf '%s\n' "$out" | grep -n "^  info " | head -n1 | cut -d: -f1)"
[[ -z "$first_info" || "$primary_line" -lt "$first_info" ]] \
  || fail "no skipped check may be printed before the diagnosis that blocked it"
[[ "$out" == *"remediation: Run: singular setup"* ]] \
  || fail "human remediation must point at singular setup: $out"

# --- (e) the cascade guard must not SWALLOW environmental checks --------------
#
# blocked() promises two things: a check that did not run records why, and
# checks that describe the HOST keep answering. The guard used to sit at the top
# of one method that mixed both, so under a mismatch the host checks inside it
# vanished outright — no fail, no warn, not even a skip with a blockedBy. A
# broken ~/.codex/hooks.json breaks every Codex run on this machine whatever
# schema the repo is on, and a pidfile names a process that is either there or
# not; neither answer is a function of schemaVersion.
#
# Paired fixture: the SAME broken host file, examined once through a matched
# repo and once through a mismatched one. The verdict must be identical.
brokenhome="$tmp/home-broken"
mkdir -p "$brokenhome/.codex"
printf 'not json at all {{{\n' >"$brokenhome/.codex/hooks.json"

# HOME *and* CODEX_HOME are scoped to the fixture: doctor reads CODEX_HOME first
# and only falls back to $HOME/.codex, so pinning one alone would leave the real
# ~/.codex reachable from a developer machine that sets the other.
doctor_broken() { # repo [args...]
  local dir="$1"; shift
  (
    cd "$dir" \
      && env HOME="$brokenhome" CODEX_HOME="$brokenhome/.codex" \
        SINGULAR_ENGINE_HOME="$ROOT" \
        bash "$ROOT/cli/singular" doctor "$@" 2>/dev/null
  )
}

# A stale pidfile in each fixture: the four-verdict loop lives in the
# same method and must survive the same way.
for variant in matched mismatched; do
  case "$variant" in
    matched)    dir="$tmp/repo-env-matched";    sv="$esv" ;;
    mismatched) dir="$tmp/repo-env-mismatched"; sv="v0" ;;
  esac
  make_repo "$dir" "$sv"
  mkdir -p "$dir/.singular-state"
  printf '99999999\n' >"$dir/.singular-state/autonomate.pid"
  report="$(doctor_broken "$dir" --json)" || true
  python3 - "$report" "$variant" <<'PY' || exit 1
import json, sys
data = json.loads(sys.argv[1])
variant = sys.argv[2]
by_id = {item["id"]: item for item in data["checks"]}

# The fixture is only meaningful if the mismatch actually blocked something.
if variant == "mismatched":
    assert data["blocking"] == {
        "checkId": "schema.version",
        "code": "SINGULAR_SCHEMA_MISMATCH",
    }, data["blocking"]
    assert by_id["schema.legacy-ids"]["status"] == "skip", by_id["schema.legacy-ids"]
    assert by_id["schema.legacy-ids"]["details"]["blockedBy"] == "schema.version", \
        by_id["schema.legacy-ids"]
else:
    assert data["blocking"] is None, data["blocking"]

hooks = by_id.get("codex.hooks")
assert hooks is not None, "codex.hooks is ABSENT in the %s report" % variant
assert hooks["status"] == "fail", (variant, hooks)
assert "not valid JSON" in hooks["message"], (variant, hooks["message"])
assert "blockedBy" not in hooks.get("details", {}), (variant, hooks)

pidfile = by_id.get("state.pidfile.autonomate.pid")
assert pidfile is not None, "state.pidfile.* is ABSENT in the %s report" % variant
assert pidfile["status"] == "warn", (variant, pidfile)
assert pidfile["details"]["verdict"] == "stale", (variant, pidfile["details"])
assert "blockedBy" not in pidfile.get("details", {}), (variant, pidfile)
PY
done

# Same host file, same verdict, either side of the guard — stated as one claim
# so a future change cannot quietly re-couple them.
matched_hooks="$(doctor_broken "$tmp/repo-env-matched" --json \
  | python3 -c 'import json,sys; print(next(i["status"] for i in json.load(sys.stdin)["checks"] if i["id"]=="codex.hooks"))')"
mismatched_hooks="$(doctor_broken "$tmp/repo-env-mismatched" --json \
  | python3 -c 'import json,sys; print(next((i["status"] for i in json.load(sys.stdin)["checks"] if i["id"]=="codex.hooks"), "<absent>"))')"
[[ "$matched_hooks" == "$mismatched_hooks" ]] \
  || fail "a schema mismatch changed a HOST verdict: codex.hooks matched=$matched_hooks mismatched=$mismatched_hooks"

# Human output too: an operator on a mismatched repo must still be told.
out="$(doctor_broken "$tmp/repo-env-mismatched")" || true
assert_contains "$out" "hooks.json is not valid JSON" "human output drops codex.hooks under a mismatch"
assert_contains "$out" "stale pidfile" "human output drops the pidfile verdict under a mismatch"

echo "PASS: test-doctor-blocking"
