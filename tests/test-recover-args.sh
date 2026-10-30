#!/usr/bin/env bash
recover_args_nonce="${RAILS_NONCE-}"
recover_args_verdict="${RAILS_VERDICT_FILE-}"
unset RAILS_NONCE RAILS_VERDICT_FILE
set -euo pipefail

# S0.4-7 / ruling I-11: validate the entire recover argument list before acting.
# Names this test fixes: none; all command, state and event names already exist.
#
# Mode inventory (checked against CLI/recover source below):
#   no arguments, --scan, or an empty first argument: mutating scan. Reclassifies
#     stale task/L1 leases, updates tasks, records events and orphan sightings.
#   --prune: mutating scan plus orphan worktree removal (branches survive).
#   candidate, orphan-reservation, continuation, continuation-preparation:
#     mutating ops.sh routes, assigned to the frozen sister test-ops-verbs.sh.
#   --help (and -h if supported): usage only, no mutation, exit 0 for --help.
# Neither local mode takes a value. Missing-value and present-value exceptions
# in I-11 therefore have no local instance; do not invent a required argument
# for --scan/--prune or treat an empty existing argument as missing.

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: S0.4-7: $*" >&2; exit 1; }
[[ "${BASH_VERSINFO[0]}" -ge 4 ]] || fail "run with Bash >= 4 (tests/run.sh selects it)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Use the public CLI in isolated repositories, like the recover/ops fixtures.
# Python keeps byte snapshots, bounds child lifetimes and collects every failed
# assertion, so a help failure cannot hide trailing-argument state corruption.
python3 - "$ENGINE_HOME" "$tmp" "$BASH" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys

engine, scratch = map(Path, sys.argv[1:3])
bash = sys.argv[3]
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)
        print(f"FAIL: S0.4-7: {message}", flush=True)
    return condition


# Discover conventional argument case labels and first-argument comparisons,
# plus advertised recover options. New modes require an explicit classification
# and positive fixture, rather than silently escaping the malformed-call matrix.
# This is inventory discovery only; every behavioural assertion uses the CLI.
source = (engine / "engine/recover.sh").read_text()
cli_source = (engine / "cli/singular").read_text()
discovered = set()
argument_case = False
for line in source.splitlines():
    if line.lstrip().startswith("#"):
        continue
    comparison = re.search(r'\$\{1(?::-[^}]*)?\}"?\s*==\s*"([\w-]+)"', line)
    if comparison:
        discovered.add(comparison[1])
    case = re.match(r'^\s*case\s+(.*?)\s+in\s*$', line)
    if case:
        argument_case = bool(re.search(r'\$(?:1|\{1(?::-[^}]*)?\})', case[1]))
    if re.match(r'^\s*esac\b', line):
        argument_case = False
    arm = re.match(r'^\s*([\w\-\'"|]+)\)', line)
    if arm:
        # Other case statements classify lease statuses and decider actions;
        # only flag arms and delegated command arms describe CLI modes.
        labels = {s.strip("\"'") for s in arm[1].split("|")}
        if argument_case or any(s.startswith("-") for s in labels):
            discovered.update(labels - {""})
    if "usage:" in line.lower():
        discovered.update(re.findall(r'--[a-z][a-z-]*', line))
for line in cli_source.splitlines():
    if re.match(r'^\s*recover\s+\[', line):
        discovered.update(re.findall(r'--[a-z][a-z-]*', line))

local_modes = {"--scan", "--prune"}
delegated = {"candidate", "orphan-reservation", "continuation", "continuation-preparation"}
classified = local_modes | delegated | {"--help", "-h"}
check(local_modes | delegated <= discovered,
      "mode discovery must find the current local and delegated modes")
check(not discovered - classified,
      "classify and add fixtures for new recover modes: " + ", ".join(sorted(discovered - classified)))
if failures:
    raise SystemExit(1)
print("PASS: S0.4-7: inventory: default/empty/--scan and --prune mutate; four ops routes delegated", flush=True)
print("N/A: S0.4-7: local recover modes take no values (I-11 missing/present-value cases)", flush=True)

# No inherited project settings, Git configuration, provider selection or
# credential environment reaches children. No installed engine is consulted.
env = {
    "PATH": os.environ["PATH"],
    "TMPDIR": str(scratch),
    "LC_ALL": "C",
    "PYTHONDONTWRITEBYTECODE": "1",
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_TERMINAL_PROMPT": "0",
    "GIT_AUTHOR_NAME": "fixture",
    "GIT_AUTHOR_EMAIL": "fixture",
    "GIT_COMMITTER_NAME": "fixture",
    "GIT_COMMITTER_EMAIL": "fixture",
    "SINGULAR_HOME": str(scratch / "machine-state"),
    "SINGULAR_ENGINE_HOME": str(engine),
    "SINGULAR_BASH_BIN": bash,
    "SINGULAR_PUSH": "0",
    "SINGULAR_AUTO_PRUNE": "0",
    "SINGULAR_STALE_MINUTES": "60",
    "SINGULAR_L1_STALE_MINUTES": "60",
    "SINGULAR_TARGET_BRANCH": "target",
}
stub = scratch / "decider.sh"
stub.write_text('''#!/usr/bin/env bash
set -eu
[[ ! ${RAILS_NONCE+x} && ! ${RAILS_VERDICT_FILE+x} ]] || exit 99
printf 'called\\n' >> "$SINGULAR_STATE_DIR/decider-calls"
echo action=revalidate-evidence
''')
stub.chmod(0o755)
env["SINGULAR_RECOVERY_DECIDER"] = str(stub)
# These fixtures need no worker; fail closed if a regression tries to run one.
env["SINGULAR_RUNNER"] = "/usr/bin/false"


def run(root, args):
    child_env = dict(env, SINGULAR_STATE_DIR=str(root / ".singular-state"))
    proc = subprocess.Popen(args, cwd=root, env=child_env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            start_new_session=True)
    try:
        output, _ = proc.communicate(timeout=45)
    except subprocess.TimeoutExpired:
        # Only the process group created by this test is ours to terminate.
        os.killpg(proc.pid, signal.SIGKILL)
        proc.communicate()
        raise RuntimeError("child exceeded the 45-second bound") from None
    return proc.returncode, output


def git(root, *args):
    rc, output = run(root, ["git", *args])
    if rc:
        raise RuntimeError("fixture Git command failed: " + " ".join(args[:2]))
    return output


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value) + "\n")


def fixture(name):
    root = scratch / name
    root.mkdir()
    state = root / ".singular-state"
    tasks = root / "docs/orchestration/tasks"
    tasks.mkdir(parents=True)
    (root / ".gitignore").write_text(".singular-state/\n.worktrees/\n")
    (tasks / "TASK-0001.md").write_text(
        "# TASK-0001: stale fixture\n\nStatus: planned\nArea: core\n")
    git(root, "init", "-q")
    git(root, "symbolic-ref", "HEAD", "refs/heads/target")
    git(root, "add", ".")
    git(root, "-c", "commit.gpgsign=false", "commit", "-qm", "fixture")
    orphan = root / ".worktrees/TASK-0042"
    git(root, "worktree", "add", "-q", "-b", "agent/core/TASK-0042", str(orphan))
    (orphan / "retained.txt").write_text("orphan bytes\n")
    write_json(state / "leases/TASK-0001.json", {
        "taskId": "TASK-0001", "status": "running", "retryCount": 1,
        "maxRetries": 2, "productPassStarted": True, "runId": "RUN-FIXTURE",
        "branch": "agent/core/TASK-0001", "updatedAt": "2000-01-01T00:00:00Z",
    })
    write_json(state / "leases/TASK-0042.json", {"taskId": "TASK-0042", "status": "failed"})
    write_json(state / "l1-leases/node-old.json", {
        "schema": "singular.orchestration.l1-lease.v0", "node": "node-old",
        "status": "active", "updatedAt": "2000-01-01T00:00:00Z",
        "area": "core", "runId": "RUN-PLAN", "stage": "S0", "layer": "x",
        "baseSha": git(root, "rev-parse", "HEAD").strip(), "targetBranch": "target",
        "allowedWriteScopes": ["internal/core/"], "startedAt": "2000-01-01T00:00:00Z",
    })
    (state / "STOP").write_text("fixture stop\n")
    write_json(state / "planner-backoff.json", {
        "schema": "singular.orchestration.planner-backoff.v0",
        "failureClass": "quota", "until": "2999-01-01T00:00:00Z",
    })
    write_json(state / "circuit.json", {"consecFails": 2, "updatedAt": "2000-01-01T00:00:00Z"})
    write_json(state / "events.ndjson", {"type": "fixture.sentinel", "data": {}})
    return root


def snapshot(root):
    # Includes STOP/backoff/breaker, all task and task/L1 lease bytes, action
    # events, orphan tracking, decisions and worktree contents. Ignore mtimes
    # and empty bookkeeping directories; compare Git refs/registry separately.
    result = {}
    for base in (root / ".singular-state", root / "docs", root / ".worktrees"):
        for path in base.rglob("*"):
            relative = str(path.relative_to(root))
            if path.is_symlink():
                result[relative] = ("link", os.readlink(path))
            elif path.is_file():
                result[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    result["git worktrees"] = git(root, "worktree", "list", "--porcelain")
    result["git refs"] = git(root, "show-ref")
    return result


def recover(root, args):
    return run(root, [bash, str(engine / "cli/singular"), "recover", *args])


def positive(name, args, prune=False):
    root = fixture("valid-" + name)
    before = snapshot(root)
    rc, _ = recover(root, args)
    prefix = "valid recover " + (repr(args) if args else "(default)")
    check(rc == 0, f"{prefix}: expected exit 0, got {rc}")
    state = root / ".singular-state"
    lease = json.loads((state / "leases/TASK-0001.json").read_text())
    check(lease.get("status") == "failed", f"{prefix}: stale lease becomes recoverable")
    check(lease.get("retryCount") == 1 and lease.get("productPassStarted") is True,
          f"{prefix}: durable product budget survives")
    check("Status: ready\n" in (root / "docs/orchestration/tasks/TASK-0001.md").read_text(),
          f"{prefix}: stale task is requeued")
    check(json.loads((state / "l1-leases/node-old.json").read_text()).get("status") == "failed",
          f"{prefix}: stale L1 lease is reclaimed")
    orphan = root / ".worktrees/TASK-0042"
    check(not orphan.exists() if prune else (orphan / "retained.txt").is_file(),
          f"{prefix}: orphan is {'removed' if prune else 'retained'}")
    after = snapshot(root)
    check(before["git refs"] == after["git refs"], f"{prefix}: branches are preserved")
    check((str(orphan) not in after["git worktrees"]) if prune else
          before["git worktrees"] == after["git worktrees"],
          f"{prefix}: worktree registration follows removal/retention")
    for filename in ("STOP", "planner-backoff.json", "circuit.json"):
        key = ".singular-state/" + filename
        check(before[key] == after.get(key), f"{prefix}: {filename} stays unchanged")
    events = [json.loads(line) for line in (state / "events.ndjson").read_text().splitlines()]
    check(any(e.get("type") == "recover.stale_retry_preserved" for e in events),
          f"{prefix}: stale recovery records an action event")
    if prune:
        check(any(e.get("type") == "recovery.action" for e in events),
              f"{prefix}: pruning records an action event")
    print(f"CHECK: S0.4-7: {prefix}: exit {rc}", flush=True)


try:
    # Prove the shared starting fixture really acts before testing refusals.
    positive("default", [])
    positive("empty", [""])
    for mode in sorted(local_modes):
        positive(mode[2:], [mode], prune=(mode == "--prune"))
    if failures:
        raise SystemExit(1)
    print("PASS: S0.4-7: all four correct calls retain today's behaviour", flush=True)

    for name, prefix in (("default", []), ("empty", [""]),
                         *((mode[2:], [mode]) for mode in sorted(local_modes))):
        for kind, tail in (("help", "--help"), ("unknown-option", "--not-a-recover-option"),
                           ("trailing-argument", "junk")):
            root = fixture(name + "-" + kind)
            before = snapshot(root)
            rc, output = recover(root, prefix + [tail])
            label = f"recover {name} / {kind}"
            check(rc == 0 if kind == "help" else rc > 0,
                  f"{label}: expected {'exit 0' if kind == 'help' else 'nonzero exit'}, got {rc}")
            if kind == "help":
                check(bool(re.search(r'usage|options', output, re.I)) and "recover" in output.lower(),
                      f"{label}: prints recover usage")
            after = snapshot(root)
            changed = sorted(k for k in before.keys() | after.keys() if before.get(k) != after.get(k))
            check(not changed, f"{label}: state/action events changed: {', '.join(changed)}")
            print(f"CHECK: S0.4-7: {label}: exit {rc}; changed surfaces {len(changed)}", flush=True)
except (OSError, RuntimeError, ValueError) as error:
    # Keep diagnostics synthetic: no command output, absolute fixture paths or
    # machine identity enters the frozen test's report.
    check(False, "fixture/command infrastructure failed (" + type(error).__name__ + ")")

if failures:
    print(f"FAIL: S0.4-7: {len(failures)} assertion(s) failed", flush=True)
    raise SystemExit(1)
print("PASS: S0.4-7: recover argument refusals preserve state and action events", flush=True)
PY

# Clean up before the verdict; writing the nonce must be the very last act.
rm -rf "$tmp"
trap - EXIT
if [[ -n "$recover_args_nonce" && -n "$recover_args_verdict" ]]; then
  printf '%s' "$recover_args_nonce" >"$recover_args_verdict"
fi
