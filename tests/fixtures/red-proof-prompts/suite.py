"""Exercise public render paths without a provider or an autonomous loop."""
import difflib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
FOLDERS = {"templates": "templates/prompts", "docs": "docs/orchestration/prompts"}
FIELDS = (b"Proof command:", b"Proof tests:")
COMMAND = b"python3 tests/proof-widget.py"
PROOF_TEST = b"tests/proof-widget.py"


def run_case(engine, scratch, folder, mode):
    case = scratch / (folder + "-" + mode)
    project = case / "project"
    orch = project / "docs/orchestration"
    prompts = orch / "prompts"
    prompts.mkdir(parents=True)
    temp = case / "tmp"
    temp.mkdir()
    env = {key: value for key, value in os.environ.items()
           if not key.startswith("SINGULAR_") and key not in
           ("RAILS_NONCE", "RAILS_VERDICT_FILE")}
    env.update({
        "SINGULAR_ENGINE_HOME": str(engine), "SINGULAR_ROOT": str(project),
        "SINGULAR_HOME": str(case / "machine"),
        "SINGULAR_STATE_DIR": str(project / ".singular-state"),
        "SINGULAR_ORCH_DIR": str(orch), "SINGULAR_TARGET_BRANCH": "target",
        "SINGULAR_PUSH": "0", "TMPDIR": str(temp),
        "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_AUTHOR_NAME": "fixture", "GIT_COMMITTER_NAME": "fixture",
        "GIT_AUTHOR_EMAIL": "fixture", "GIT_COMMITTER_EMAIL": "fixture",
        "PYTHONDONTWRITEBYTECODE": "1",
        "SINGULAR_RUNNER": str(HERE / "critic.py"),
        "PROMPTS_CRITIC_CAPTURE": str(case / "critic.md"),
    })
    if mode != "unset":
        env["SINGULAR_RED_PROOF"] = "off" if mode == "off-declared" else mode

    def run(*args):
        result = subprocess.run(args, cwd=project, env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=45)
        with (case / "commands.log").open("ab") as log:
            log.write(result.stdout)
        if result.returncode:
            raise AssertionError(f"{folder}/{mode}: {Path(args[0]).name} setup/render "
                                 f"exit {result.returncode}: " +
                                 result.stdout.decode(errors="replace")[-2000:])
        return result.stdout

    run("git", "init", "-q")
    run("git", "symbolic-ref", "HEAD", "refs/heads/target")
    (project / ".gitignore").write_text(
        ".singular-state/\n.worktrees/\n.singular-evidence/\n.singular-cache/\n")
    for name in ("l1-planner.md", "plan-critic.md", "l2-test-first-developer.md", "auditor.md"):
        source = engine / FOLDERS[folder] / name
        if source.exists():
            shutil.copyfile(source, prompts / name)
        elif name != "plan-critic.md":
            raise AssertionError(f"missing shipped prompt: {folder}/{name}")
        # The base has no docs critic copy; its real runtime falls back to the
        # engine template. Keep that baseline, but require both copies when on.
    run("bash", str(engine / "engine/scaffold.sh"))
    template = (orch / "tasks/TEMPLATE.md").read_bytes()
    (orch / "dag.v0.json").write_text(json.dumps({
        "schema": "singular.orchestration.dag.v0",
        "layers": ["runtime"], "kinds": ["runtime"],
        "nodes": [{"id": "widget", "stage": "S1", "area": "widget",
                   "layer": "runtime", "kind": "runtime", "dependsOn": [],
                   "requiredCompletion": "A synthetic widget exists."}],
    }) + "\n")
    run("git", "add", ".")
    run("git", "-c", "commit.gpgsign=false", "commit", "-qm", "fixture")
    assert not run("git", "remote").strip(), "fixture must have no remote"
    base_sha = run("git", "rev-parse", "HEAD").strip()
    # No existing task can accidentally supply the planner's proof instructions.
    run("bash", str(engine / "engine/generate-tasks.sh"), "--node", "widget", "--dry-run")
    runs = project / ".singular-state/runs"
    planner_paths = list(runs.glob("*/planner-prompt.md"))
    assert len(planner_paths) == 1, "planner did not render exactly one prompt"
    planner = planner_paths[0].read_bytes()

    stage = case / "stage"
    stage.mkdir()
    task = (HERE / "task.md").read_bytes()
    (stage / "TASK-0001.candidate.md").write_bytes(task)
    (stage / "existing-tasks.md").write_text("No existing tasks.\n")
    # Use the runtime entry point, not a reimplementation of its renderer.
    run("bash", "-c", 'source "$1/engine/lib.sh"; '
        'singular_ctx_plan_critic_run widget RUN-PROMPTS "$2" "$SINGULAR_ROOT"',
        "critic", str(engine), str(stage))
    critic = (case / "critic.md").read_bytes()
    record = json.loads((stage / "plan-critique.json").read_bytes())
    assert record["verdict"] == "approve", "critic fixture was not accepted"
    events = (project / ".singular-state/events.ndjson").read_text()
    assert '"ctx.plan_critique_infra"' not in events, "critic failed open"

    if mode in ("observe", "enforce", "off-declared"):
        task = task.replace(b"Dispatch mode:", b"Proof command: `" + COMMAND +
                            b'`\nProof tests: ["' + PROOF_TEST + b'"]\nDispatch mode:')
    (orch / "tasks/TASK-0001.md").write_bytes(task)
    run("git", "add", ".")
    run("git", "-c", "commit.gpgsign=false", "commit", "-qm", "task")
    worker_base = run("git", "rev-parse", "HEAD").strip()
    run("bash", str(engine / "engine/l1-drive.sh"), "TASK-0001", "--dry-run")
    worker_paths = list(runs.glob("*/l2-prompt.md"))
    assert len(worker_paths) == 1, "worker did not render exactly one prompt"
    worker_path = worker_paths[0]
    worker = worker_path.read_bytes().replace(worker_path.parent.name.encode(), b"<RUN>")
    worker = worker.replace(worker_base, b"<WORKER-BASE-SHA>")
    critic = critic.replace(base_sha, b"<BASE-SHA>")
    observed = {"planner": planner, "critic": critic, "worker": worker, "task-template": template}
    for role, data in observed.items():
        (case / (role + "-normalized.md")).write_bytes(data)
    return observed


def main(engine, scratch):
    failures = []
    checks = 0

    def check(ok, message):
        nonlocal checks
        checks += 1
        if not ok:
            failures.append(message)
            print("FAIL: " + message, flush=True)

    for folder in FOLDERS:
        for mode in ("unset", "off", "off-declared", "observe", "enforce"):
            observed = run_case(engine, scratch, folder, mode)
            label = folder + "/" + mode
            if mode in ("unset", "off", "off-declared"):
                for role, actual in observed.items():
                    name = "worker-declared" if role == "worker" and mode == "off-declared" else role
                    expected = HERE / "expected" / folder / (name + ".md")
                    baseline = expected.read_bytes()
                    check(actual == baseline, f"{label}/{role}: disabled bytes changed")
                    if actual != baseline:
                        print("".join(difflib.unified_diff(
                            baseline.decode().splitlines(True), actual.decode().splitlines(True),
                            fromfile="expected", tofile="observed"))[:4000])
            else:
                check((engine / FOLDERS[folder] / "plan-critic.md").is_file(),
                      f"{label}: critic source missing from prompt folder")
                for role, data in observed.items():
                    if role == "worker":
                        data = data.split(b"## Complete task contract (mandatory)", 1)[0]
                    for field in FIELDS:
                        check(field in data, f"{label}/{role}: missing {field.decode()}")
                    if role == "worker":
                        check(COMMAND in data, f"{label}/worker: missing declared proof command")
                        check(PROOF_TEST in data, f"{label}/worker: missing declared proof test")
            print(f"Checked {label}", flush=True)
    print(f"S1.1-6/10: {checks} assertions, {len(failures)} failures", flush=True)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main(*(Path(value).resolve() for value in sys.argv[1:])))
