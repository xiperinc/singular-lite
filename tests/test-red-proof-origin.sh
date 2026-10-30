#!/usr/bin/env bash
proof_origin_nonce="${RAILS_NONCE:-}"
proof_origin_verdict="${RAILS_VERDICT_FILE:-}"
unset RAILS_NONCE RAILS_VERDICT_FILE
set -euo pipefail
# singular-test: serial
# Only the host's own red-proof record counts at acceptance (V). The host writes
# it directly in the run folder as red-proof-<attempt>.json. A proved record
# with the red-proof schema anywhere else (the worker's evidence copied to
# worker-evidence/, any deeper folder, or a worker-authored file in the run
# folder itself) neither proves nor refuses. Each refusal case has a positive
# twin: the same record at the host's path is accepted.
# Reuses the red-proof-paths fixtures; no provider, network or remote. Runs
# serially, one fixture at a time.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/po.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
export PYTHONDONTWRITEBYTECODE=1
python3 - "$ROOT" "$scratch" "$BASH" <<'PY'
import json
from pathlib import Path
import shutil
import sys

root, scratch, bash = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
sys.path.insert(0, str(root / "tests/fixtures/red-proof-paths"))
from fixture import TASK, Checks, Fixture, read, write
from proof import install

failures = 0
HOST_NAME = "red-proof-1.json"


def names_missing_v(text):
    # import says "V:proof-record-missing (red proof)"; integrate says
    # "red proof (V): proof-record-missing". Both name the subject and reason.
    return ("V:proof-record-missing" in text
            or "red proof (V): proof-record-missing" in text)


def strict(f):
    # Unexported shell settings, as in the red-proof-paths suite: every caller
    # must pass the resolved values to the validator itself.
    f.env.pop("SINGULAR_RED_PROOF", None)
    f.env.pop("SINGULAR_ACCEPTANCE", None)
    (f.state / "config.local.sh").write_text(
        "SINGULAR_ACCEPTANCE=every-path\nSINGULAR_RED_PROOF=enforce\n")


def fixture(name):
    folder = scratch / name
    folder.mkdir()
    c = Checks()
    f = Fixture(root, folder, c)
    f.env["TEST_BASH"] = bash
    f.seed()
    return c, f


def place(f, folder, name):
    """Put one proved record and its two logs at run_dir/folder/name."""
    record = install(f.repo, f.run_dir, f.head, f.original_head)
    destination = f.run_dir / folder
    destination.mkdir(parents=True, exist_ok=True)
    data = read(record)
    for side in ("base", "candidate"):
        log = f.run_dir / data[side]["logRef"]
        if destination != f.run_dir:
            shutil.move(str(log), str(destination / log.name))
    target = destination / name
    record.rename(target)
    return target


def strip(f, path):
    """Remove a placed record and its logs."""
    data = read(path)
    for side in ("base", "candidate"):
        (path.parent / data[side]["logRef"]).unlink()
    path.unlink()


def validate(f):
    result = f.run([sys.executable, root / "engine/acceptance_validator.py",
                    *f.validator_args(), "--red-proof=enforce",
                    "--acceptance-mode=every-path"])
    return result


def answer(result):
    try:
        return json.loads(result.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return {}


def refused_v(result, reason="proof-record-missing"):
    value = answer(result)
    return (result.returncode != 0 and value.get("conjunct") == "V"
            and value.get("reason") == reason)


def log(name, result):
    if result.returncode:
        print(result.stdout[-1200:].replace(str(scratch), "<scratch>").replace(str(root), "<engine>"))


# ---- the validator: location and name ---------------------------------------
c, f = fixture("v")
strict(f)
for folder, name in (("worker-evidence", HOST_NAME),
                     ("worker-evidence", "red-proof-attempt-1.json"),
                     ("worker-evidence/nested", HOST_NAME),
                     ("logs", HOST_NAME),
                     (".", "last-message.attempt-1.invalid.json"),
                     (".", "proof.json")):
    path = place(f, folder, name)
    where = (folder + "/" if folder != "." else "") + name
    result = validate(f)
    c.check("origin", "a proved record only at " + where + " is refused with V", refused_v(result))
    strip(f, path)
host = place(f, ".", HOST_NAME)
result = validate(f)
log("host", result)
c.check("origin", "the same record at the host's path is accepted", result.returncode == 0)
# A copy elsewhere neither proves nor refuses: a second proved copy is not
# ambiguity, and an unreadable copy under worker-evidence is not a refusal.
extra = f.run_dir / "worker-evidence"
extra.mkdir(exist_ok=True)
shutil.copyfile(host, extra / HOST_NAME)
for side in ("base", "candidate"):
    name = read(host)[side]["logRef"]
    shutil.copyfile(f.run_dir / name, extra / name)
(extra / "red-proof-2.json").write_text("not json")
(extra / "linked.json").symlink_to(host)
result = validate(f)
log("copies", result)
c.check("origin", "copies under worker-evidence neither prove nor refuse", result.returncode == 0)
# Anything at the host's own name is still judged.
host.write_text("not json")
result = validate(f)
c.check("origin", "an unreadable record at the host's path refuses with V",
        refused_v(result, "proof-record-unreadable"))
failures += c.failures


# ---- public entrypoints: import and integrate -------------------------------
def imported(f):
    return (f.orch / "packets/imported" / TASK / (f.run_id + ".json")).is_file()


for label, folder in (("refused", "worker-evidence"), ("accepted", ".")):
    c, f = fixture("i-" + label)
    place(f, folder, HOST_NAME)
    strict(f)
    result = f.run([bash, root / "engine/import-packet.sh", f.packet])
    (f.scratch / "result.log").write_text(result.stdout)
    if label == "refused":
        c.check("origin", "import: record only under worker-evidence/ is refused with V",
                result.returncode != 0 and names_missing_v(result.stdout))
        c.check("origin", "import: refused candidate publishes no certificate", not imported(f))
    else:
        log("import", result)
        c.check("origin", "import: record at the host's path imports",
                result.returncode == 0 and imported(f))
    failures += c.failures

for label, folder in (("refused", "worker-evidence"), ("accepted", ".")):
    c, f = fixture("g-" + label)
    target = f.run_dir / "packet.json"
    copy = f.orch / "packets/imported" / TASK / (f.run_id + ".json")
    write(copy, read(target))
    write(copy.with_suffix(".audit.json"), read(f.audit))
    f.git("add", "docs/orchestration")
    f.git("commit", "-qm", "fixture imported certificate")
    place(f, folder, HOST_NAME)
    strict(f)
    before = f.git("rev-parse", "target").stdout.strip()
    result = f.command("integrate", "--task", TASK)
    contains = f.run(["git", "-C", f.repo, "merge-base", "--is-ancestor", f.head, "target"]).returncode == 0
    if label == "refused":
        c.check("origin", "integrate --task: record only under worker-evidence/ is refused with V",
                result.returncode != 0 and names_missing_v(result.stdout))
        c.check("origin", "integrate --task: target is unchanged",
                f.git("rev-parse", "target").stdout.strip() == before and not contains)
    else:
        log("integrate", result)
        c.check("origin", "integrate --task: record at the host's path merges",
                result.returncode == 0 and contains)
    failures += c.failures

print("red-proof-origin: %d assertion failures" % failures, flush=True)
sys.exit(1 if failures else 0)
PY
# Clean up before the verdict, so writing it is the final successful action.
rm -rf "$scratch"
trap - EXIT
if [[ -n "$proof_origin_nonce" && -n "$proof_origin_verdict" ]]; then
  printf '%s\n' "$proof_origin_nonce" >"$proof_origin_verdict"
fi
