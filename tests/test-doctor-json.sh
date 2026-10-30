#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
doctor_home="$tmp/home"
doctor_bin="$tmp/bin"
mkdir -p "$repo/docs/orchestration/prompts" "$repo/schemas/orchestration" \
  "$doctor_home/.codex" "$doctor_bin"
for schema in "$ROOT"/schemas/*.schema.json; do
  cp "$schema" "$repo/schemas/orchestration/"
done
git -C "$tmp" init -q repo
git -C "$repo" config user.email doctor@example.com
git -C "$repo" config user.name doctor
printf 'lock\n' >"$repo/lockfile"
git -C "$repo" add lockfile
git -C "$repo" commit -qm init

cat >"$doctor_bin/codex" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "--version ") echo "codex-cli 1.0.0" ;;
  "login status") echo "Logged in"; exit 0 ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$doctor_bin/codex"

write_config() {
  local required_missing="${1:-no}"
  python3 - "$repo/singular.config.json" "$required_missing" <<'PY'
import json, sys
path, required_missing = sys.argv[1:]
required = ["filesystem", "git", "schemas", "runner-contract", "provider-executable"]
if required_missing == "yes":
    required.append("executable:definitely-not-installed")
data = {
    "schemaVersion": "v2",
    "targetBranch": "main",
    "gateCommand": "true",
    "runner": "codex-run.sh",
    "capabilityProfiles": {
        "audit-core": {
            "startup": "lazy",
            "required": required,
            "optional": ["mcp:missing-optional"],
        }
    },
    "roleProfiles": {
        "auditor": "audit-core",
        "decider": "audit-core",
    },
    "bootstrap": {
        "required": True,
        "lockfiles": ["lockfile"],
        "sharedStoreRoots": [],
        "sharedLinks": [],
    },
    "resources": {
        "diskReserveBytes": 0,
        "estimatedWorktreeBytes": 1024,
        "maxConcurrent": 2,
    },
    "deploymentCredentials": [
        {"id": "release-token", "env": "DOCTOR_RELEASE_TOKEN", "requiredFor": ["deploy"]}
    ],
    "env": {"SINGULAR_CODEX_MODEL": "gpt-doctor"},
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY
}

write_cache() {
  cat >"$doctor_home/.codex/models_cache.json" <<'EOF'
{
  "fetched_at": "2026-07-24T00:00:00Z",
  "client_version": "9.0.0",
  "models": [
    {"slug": "gpt-doctor", "supports_reasoning_summaries": true}
  ]
}
EOF
}

doctor_json() {
  (
    cd "$repo"
    env HOME="$doctor_home" PATH="$doctor_bin:$PATH" \
      SINGULAR_ENGINE_HOME="$ROOT" \
      bash "$ROOT/cli/singular" doctor --json "$@"
  )
}

write_config no
write_cache
report="$(doctor_json)"
python3 - "$report" "$doctor_bin/codex" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
assert data["schema"] == "singular.doctor-report.v1"
assert data["ok"] is True
checks = data["checks"]
for check in checks:
    assert {"id", "status", "severity", "requiredFor", "message", "remediation", "dedupeKey"} <= set(check)
by_id = {item["id"]: item for item in checks}
required = {
    "runtime.bash",
    "provider.executable",
    "provider.authentication",
    "model.availability",
    "schema.fixture.runner-result",
    "git.disposable-worktree",
    "runner.contract-v1",
    "capability.profiles",
    "bootstrap.dry-run",
    "resources.adaptive-disk",
    "governance.unbound-waivers",
    "deployment.credentials",
    "dag.evaluation",
    "graph.promotability",
    "model-cache.compatibility",
    "runtime.process-group-kill",
    "runtime.process-enumeration",
}
assert required <= set(by_id), sorted(required - set(by_id))
assert by_id["provider.executable"]["details"]["path"] == sys.argv[2]
assert "--stage-dir" not in by_id["runner.contract-v1"]["details"]["arguments"]
assert by_id["bootstrap.dry-run"]["status"] == "pass"
assert by_id["resources.adaptive-disk"]["details"]["configuredSlots"] == 2
assert by_id["governance.unbound-waivers"]["status"] == "pass"
# The real probe, on a process-capable host: singular's timeout cleanup depends
# on session creation + group termination, and the machine-readable preflight is
# where an unattended launcher looks before it starts.
group_kill = by_id["runtime.process-group-kill"]
assert group_kill["status"] == "pass", group_kill
assert "unattended-runs" in group_kill["requiredFor"], group_kill["requiredFor"]
assert group_kill["details"]["pgid"] == group_kill["details"]["childPid"]
# Enumeration is the fallback, so its status depends on the host; what must
# always be readable is the evidence behind whichever verdict it reached.
enumeration = by_id["runtime.process-enumeration"]
assert enumeration["status"] in {"pass", "warn"}, enumeration
assert {"returncode", "selfVisible"} <= set(enumeration["details"]), enumeration
assert by_id["deployment.credentials"]["status"] == "skip"
assert by_id["model-cache.compatibility"]["status"] == "warn"
optional = [
    item for item in checks
    if item["dedupeKey"] == "capability-activation:mcp:missing-optional"
]
assert len(optional) == 1
assert optional[0]["status"] == "warn"
assert optional[0]["requiredFor"] == ["auditor", "decider"]
assert "capabilityArgs.mcp:missing-optional" in optional[0]["message"]
PY
[[ -f "$doctor_home/.codex/models_cache.json" ]] \
  || { echo "ordinary doctor must never mutate model cache" >&2; exit 1; }

# Machine capacity. The fixture pins `maxConcurrent: 2`. Doctor reports what
# the machine supports next to that number and warns only when the two are far
# apart — both directions were seen in the field (a fixed 3 idling a 12-core
# host, a fixed 5 saturating it). Machine facts are injected, so this does not
# depend on the host running the suite.
GIB=1073741824
machine_check() { # <cores> <available bytes> <load> -> the check as JSON
  local report
  report="$(SINGULAR_RESOURCE_CPU_COUNT="$1" SINGULAR_RESOURCE_AVAILABLE_MEMORY_BYTES="$2" \
    SINGULAR_RESOURCE_LOAD_1M="$3" doctor_json)"
  python3 -c '
import json, sys
by_id = {item["id"]: item for item in json.loads(sys.argv[1])["checks"]}
print(json.dumps(by_id["resources.machine-capacity"]))' "$report"
}
python3 - "$(machine_check 5 $((8 * GIB)) 0)" "$(machine_check 12 $((24 * GIB)) 0)" \
  "$(machine_check 2 $((8 * GIB)) 0)" "$(machine_check 5 $((8 * GIB)) 9)" \
  "$(machine_check banana $((8 * GIB)) 0)" <<'PY'
import json, sys
matched, big, small, loaded, broken = (json.loads(arg) for arg in sys.argv[1:6])
# 5 cores -> 3 cpu slots: an explicit 2 is in range.
assert matched["status"] == "pass", matched
assert matched["details"]["mode"] == "explicit", matched
assert matched["details"]["cpuSlots"] == 3, matched
assert matched["details"]["memorySlots"] == 6, matched
assert matched["details"]["cpuCount"] == 5, matched
assert "explicit worker ceiling 2" in matched["message"], matched
# 12 cores -> 8: an explicit 2 leaves the machine idle.
assert big["status"] == "warn", big
assert "far below" in big["message"], big
assert '"auto"' in big["remediation"], big
# 2 cores -> 1: an explicit 2 is twice what the machine supports.
assert small["status"] == "warn", small
assert "far above" in small["message"], small
# A saturated machine is reported as throttled, and that is not a failure.
# Nothing is running in this fixture, so the hold is the one-unit floor.
assert loaded["status"] == "warn", loaded
assert loaded["details"]["admission"] == "floor", loaded
assert loaded["details"]["progressFloor"] is True, loaded
assert "load-high" in loaded["message"], loaded
assert "minimum-progress floor" in loaded["message"], loaded
# A broken probe is a warning with the probe named, never a failed doctor.
assert broken["status"] == "warn", broken
assert broken["details"]["probeFailures"] == ["cpu"], broken
PY

# Check the JSON process-control verdict. An environment that cannot terminate a
# process group cannot clean up a timed-out agent, so this is a blocking check,
# not a note: whatever launches unattended runs reads this report to decide.
rc=0
report="$(SINGULAR_TEST_PROCESS_CONTROL=1 SINGULAR_TEST_PROCESS_CONTROL_STATE=no-group-kill \
  doctor_json)" || rc=$?
[[ "$rc" -ne 0 ]] \
  || { echo "an environment without group termination must fail doctor" >&2; exit 1; }
python3 - "$report" <<'PY'
import json, sys
by_id = {item["id"]: item for item in json.loads(sys.argv[1])["checks"]}
check = by_id["runtime.process-group-kill"]
assert check["status"] == "fail", check
assert "unattended-runs" in check["requiredFor"], check["requiredFor"]
assert "Do not run unattended actuation here." in check["remediation"], check
PY

# The PID probe verdict is a JSON field, so a supervisor
# reading this report can tell "the process is gone" from "I was not allowed to
# look" — which is the distinction that made doctor call a live server stale.
mkdir -p "$repo/.singular-state"
printf '4242\n' >"$repo/.singular-state/console.pid"
report="$(SINGULAR_TEST_PID_PROBE=1 SINGULAR_TEST_PID_PROBE_STATE=unknown doctor_json)"
python3 - "$report" <<'PY'
import json, sys
check = next(
    item for item in json.loads(sys.argv[1])["checks"]
    if item["id"] == "state.pidfile.console.pid"
)
assert check["status"] == "warn", check
assert check["details"]["verdict"] == "unknown-permission", check["details"]
assert check["details"]["pid"] == 4242, check["details"]
assert "Do not delete the pidfile automatically." in check["message"], check["message"]
PY
rm -f "$repo/.singular-state/console.pid"

# Consumer-only repository schema extensions survive migrations and are valid
# inputs to doctor. They do not weaken authoritative copy checks below.
cat >"$repo/schemas/orchestration/acme-extension.v0.schema.json" <<'JSON'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://example.test/schemas/acme-extension.v0.schema.json",
  "type": "object",
  "additionalProperties": false
}
JSON
report="$(doctor_json)"
python3 - "$report" <<'PY'
import json, sys
bundle = next(
    item for item in json.loads(sys.argv[1])["checks"]
    if item["id"] == "schema.bundle"
)
assert bundle["status"] == "pass"
assert bundle["details"]["consumerExtensions"]["repo-consumer"] == [
    "acme-extension.v0.schema.json"
]
assert bundle["details"]["consumerExtensions"]["engine-consumer"] == []
PY

# Allowing extensions must not allow an authoritative copy to disappear.
mv "$repo/schemas/orchestration/human-gate.v0.schema.json" \
  "$tmp/human-gate.v0.schema.json"
rc=0
report="$(doctor_json)" || rc=$?
[[ "$rc" -ne 0 ]] || { echo "missing schema mirror must fail doctor" >&2; exit 1; }
python3 - "$report" <<'PY'
import json, sys
bundle = next(
    item for item in json.loads(sys.argv[1])["checks"]
    if item["id"] == "schema.bundle"
)
assert bundle["status"] == "fail"
assert any(
    "repo-consumer: missing schema copies: human-gate.v0.schema.json" in error
    for error in bundle["details"]["errors"]
)
PY
mv "$tmp/human-gate.v0.schema.json" \
  "$repo/schemas/orchestration/human-gate.v0.schema.json"

# Doctor compares every consumer schema, not only the runner/provider pair.
printf '{"drifted":true}\n' >"$repo/schemas/orchestration/human-gate.v0.schema.json"
rc=0
report="$(doctor_json)" || rc=$?
[[ "$rc" -ne 0 ]] || { echo "schema mirror drift must fail doctor" >&2; exit 1; }
python3 - "$report" <<'PY'
import json, sys
bundle = next(
    item for item in json.loads(sys.argv[1])["checks"]
    if item["id"] == "schema.bundle"
)
assert bundle["status"] == "fail"
assert any(
    "repo-consumer/human-gate.v0.schema.json" in error
    for error in bundle["details"]["errors"]
)
PY
cp "$ROOT/schemas/human-gate.v0.schema.json" \
  "$repo/schemas/orchestration/human-gate.v0.schema.json"

# A consumer formatter (biome/prettier `--write .`, a pre-commit hook) rewrites
# the mirrors without changing their JSON. Doctor still fails on the byte
# difference, but names the real cause and the command that repairs it instead
# of the generic "differs", which reads as a stale engine bundle.
python3 - "$ROOT/schemas/human-gate.v0.schema.json" \
  "$repo/schemas/orchestration/human-gate.v0.schema.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
open(sys.argv[2], "w", encoding="utf-8").write(json.dumps(value, indent=4) + "\n")
PY
! cmp -s "$ROOT/schemas/human-gate.v0.schema.json" \
    "$repo/schemas/orchestration/human-gate.v0.schema.json" \
  || { echo "fixture did not reformat the schema mirror" >&2; exit 1; }
rc=0
report="$(doctor_json)" || rc=$?
[[ "$rc" -ne 0 ]] || { echo "reformatted schema mirror must fail doctor" >&2; exit 1; }
python3 - "$report" <<'PY'
import json, sys
bundle = next(
    item for item in json.loads(sys.argv[1])["checks"]
    if item["id"] == "schema.bundle"
)
assert bundle["status"] == "fail", bundle
assert bundle["details"]["reformatted"] == [
    "repo-consumer/human-gate.v0.schema.json"
], bundle["details"]
assert any(
    "repo-consumer/human-gate.v0.schema.json: consumer copy was reformatted" in error
    for error in bundle["details"]["errors"]
), bundle["details"]["errors"]
assert "singular init" in bundle["remediation"], bundle["remediation"]
assert "exclude schemas/orchestration/" in bundle["remediation"], bundle["remediation"]
PY
cp "$ROOT/schemas/human-gate.v0.schema.json" \
  "$repo/schemas/orchestration/human-gate.v0.schema.json"

write_config yes
rc=0
report="$(doctor_json)" || rc=$?
[[ "$rc" -ne 0 ]] || { echo "missing required capability must fail doctor" >&2; exit 1; }
python3 - "$report" <<'PY'
import json, sys
checks = json.loads(sys.argv[1])["checks"]
missing = [item for item in checks if item["id"] == "capability.executable-definitely-not-installed"]
assert len(missing) == 1
assert missing[0]["status"] == "fail"
assert missing[0]["requiredFor"] == ["auditor", "decider"]
PY

# Doctor validates providerArgs as literal bounded argv arrays before runtime.
write_config no
python3 - "$repo/singular.config.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["capabilityProfiles"]["audit-core"]["providerArgs"] = ["--safe", " bad"]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY
rc=0
report="$(doctor_json)" || rc=$?
[[ "$rc" -ne 0 ]] || { echo "invalid provider argv must fail doctor" >&2; exit 1; }
python3 - "$report" <<'PY'
import json, sys
by_id = {item["id"]: item for item in json.loads(sys.argv[1])["checks"]}
profile = by_id["capability.profiles"]
assert profile["status"] == "fail"
assert "providerArgs" in profile["message"]
PY

# An unrelated provider argv cannot activate a strict external capability.
# Activation argv must be bound to that exact capability ID, matching runtime.
write_config no
python3 - "$repo/singular.config.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
profile = data["capabilityProfiles"]["audit-core"]
profile["required"].append("skills")
profile["providerArgs"] = {"codex": ["--ephemeral"]}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY
rc=0
report="$(doctor_json)" || rc=$?
[[ "$rc" -ne 0 ]] \
  || { echo "unbound providerArgs must not activate strict skills" >&2; exit 1; }
python3 - "$report" <<'PY'
import json, sys
profile = next(
    item for item in json.loads(sys.argv[1])["checks"]
    if item["id"] == "capability.profiles"
)
assert profile["status"] == "fail"
assert "capabilityArgs.skills" in profile["message"], profile["message"]
PY

write_config no
python3 - "$repo/singular.config.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
profile = data["capabilityProfiles"]["audit-core"]
profile["required"].append("skills")
profile["capabilityArgs"] = {"skills": {"codex": ["--ephemeral"]}}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY
report="$(doctor_json)"
python3 - "$report" <<'PY'
import json, sys
profile = next(
    item for item in json.loads(sys.argv[1])["checks"]
    if item["id"] == "capability.profiles"
)
assert profile["status"] == "pass"
assert profile["details"]["activatedCapabilities"] == ["skills"]
PY

# Strict providerArgs cannot replace the native sandbox/capability boundary.
write_config no
python3 - "$repo/singular.config.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["capabilityProfiles"]["audit-core"]["providerArgs"] = {
    "codex": ["--sandbox=danger-full-access"],
    "claude": ["--mcp-config=/tmp/unsafe.json"],
    "gemini": ["--approval-mode=yolo"],
    "opencode": ["--pure=false"],
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY
rc=0
report="$(doctor_json)" || rc=$?
[[ "$rc" -ne 0 ]] \
  || { echo "strict provider boundary override must fail doctor" >&2; exit 1; }
python3 - "$report" <<'PY'
import json, sys
by_id = {item["id"]: item for item in json.loads(sys.argv[1])["checks"]}
profile = by_id["capability.profiles"]
assert profile["status"] == "fail"
for provider in ("codex", "claude", "gemini", "opencode"):
    assert f"strict {provider}" in profile["message"], profile["message"]
assert "host-owned sandbox/capability boundary" in profile["message"]
PY

write_config no
report="$(doctor_json --repair-model-cache)"
python3 - "$report" <<'PY'
import json, sys
by_id = {item["id"]: item for item in json.loads(sys.argv[1])["checks"]}
assert by_id["model-cache.repair"]["status"] == "pass"
assert by_id["model-cache.repair"]["details"]["sha256"]
PY
[[ ! -e "$doctor_home/.codex/models_cache.json" ]] \
  || { echo "explicit cache repair must retire the active cache" >&2; exit 1; }
compgen -G "$doctor_home/.codex/models_cache.json.bak-*" >/dev/null \
  || { echo "explicit cache repair must preserve a backup" >&2; exit 1; }

cat >"$repo/docs/orchestration/dag.v0.json" <<'EOF'
{
  "schema": "singular.orchestration.dag.v0",
  "nodes": [
    {
      "id": "deploy",
      "stage": "deploy",
      "area": "release",
      "layer": "release",
      "kind": "deploy",
      "dependsOn": [],
      "requiredCompletion": "production deployment"
    }
  ]
}
EOF
rc=0
report="$(doctor_json)" || rc=$?
[[ "$rc" -ne 0 ]] || { echo "ready deploy node with missing credentials must fail" >&2; exit 1; }
python3 - "$report" <<'PY'
import json, sys
item = next(item for item in json.loads(sys.argv[1])["checks"] if item["id"] == "deployment.credentials")
assert item["status"] == "fail"
assert item["details"]["missing"] == ["release-token"]
PY

report="$(DOCTOR_RELEASE_TOKEN=test-token doctor_json)"
python3 - "$report" <<'PY'
import json, sys
item = next(item for item in json.loads(sys.argv[1])["checks"] if item["id"] == "deployment.credentials")
assert item["status"] == "pass"
assert item["details"]["credentialIds"] == ["release-token"]
PY

human_help="$(
  cd "$repo"
  env HOME="$doctor_home" PATH="$doctor_bin:$PATH" SINGULAR_ENGINE_HOME="$ROOT" \
    bash "$ROOT/cli/singular" human-gate status --help
)"
[[ "$human_help" == *"--require-approved"* ]] \
  || { echo "singular human-gate status was not passed through" >&2; exit 1; }

echo "PASS: test-doctor-json"
