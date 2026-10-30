"""Re-import of a refused packet, refusal subjects and the whole-manifest check
under SINGULAR_ACCEPTANCE=every-path, and today's behaviour under driver-only.
Reuses the acceptance-boundary-import harness: only the provider is stubbed,
every judge is the real engine."""
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location(
    "acceptance_boundary_import", HERE.parent / "acceptance-boundary-import" / "check.py")
base = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(base)
Failure, require, read, write, edit = base.Failure, base.require, base.read, base.write, base.edit
TASK = base.TASK
SUBJECTS = {"G": "host gate verification", "A": "audit", "D": "review round",
            "E": "evidence manifest", "V": "red proof"}


class Fixture(base.Fixture):
    """The import fixture, with its one baseline drive optionally under every-path."""

    def __init__(self, engine, bash, temporary, drive_mode=None):
        self._drive_mode = drive_mode
        super().__init__(engine, bash, temporary)
        self.base_env.pop("SINGULAR_ACCEPTANCE", None)
        self.env.pop("SINGULAR_ACCEPTANCE", None)

    def command(self, script, *args, timeout=90):
        if script == "l1-drive.sh" and self._drive_mode:
            self.env["SINGULAR_ACCEPTANCE"] = self._drive_mode
        return super().command(script, *args, timeout=timeout)

    @property
    def retained_dir(self):
        return self.state / "import-refusals" / self.run

    def retained(self):
        if not self.retained_dir.is_dir():
            return []
        return sorted(p for p in self.retained_dir.iterdir() if p.name.startswith("packet."))

    def operator_restores(self):
        """Repair the evidence and restore the task, as an operator would."""
        saved_run = self.saved / ".singular-state/runs" / self.run
        for name in ("audit.json", "evidence-manifest.json", "audit-verification.json"):
            shutil.copyfile(saved_run / name, self.run_dir / name)
        shutil.copyfile(self.saved / ".singular-state/leases" / (TASK + ".json"), self.lease)
        shutil.copyfile(self.saved / "docs/orchestration/tasks" / (TASK + ".md"), self.task)

    def listed(self):
        """One manifest artifact other than the two check_evidence already pins."""
        for item in read(self.manifest)["artifacts"]:
            if item["ref"] not in ("audit.json", "audit-verification.json", "packet.json") \
                    and (self.run_dir / item["ref"]).is_file():
                return item["ref"]
        raise Failure("manifest lists no other artifact to break")

    def integrate(self):
        return self.command("integrate.sh", "--task", TASK, timeout=180)


def describe(f, code, subject_only=False):
    argv = ["python3", f.engine / "engine/acceptance_validator.py", "describe-refusal"]
    argv += ["--subject"] if subject_only else []
    result = f.run_command(argv + [code])
    require(result.returncode == 0, "describe-refusal failed: " + result.stdout)
    return result.stdout.strip()


def main(engine, bash):
    # Keep AF_UNIX evidence-broker paths below the macOS socket path limit.
    with tempfile.TemporaryDirectory(prefix="epg-", dir=base.scratch_parent()) as temporary:
        return run_cases(engine, bash, Path(temporary))


def run_cases(engine, bash, temporary):
    failures, passed = [], 0
    try:
        (temporary / "a").mkdir()
        f = Fixture(engine, bash, temporary / "a")
    except (Failure, OSError, ValueError, KeyError, IndexError) as exc:
        print("CRITERION S0.4-1\nFAIL S0.4-1: valid baseline: " + str(exc))
        return 1

    only = os.environ.get("EVERY_PATH_GAPS_ONLY", "")  # a label substring, or "route"

    def case(criterion, label, check):
        nonlocal passed
        if only and only not in label:
            return
        try:
            check()
            passed += 1
            print("ok " + criterion + ": " + label, flush=True)
        except (Failure, OSError, ValueError, KeyError, IndexError) as exc:
            failures.append(label)
            print("CRITERION " + criterion, flush=True)
            print("FAIL " + criterion + ": " + label + ": " + f.safe(str(exc)), flush=True)

    # ---- explicit re-import restores the retained refused packet -----------
    def refuse_and_park():
        base.blocking_audit(f)
        result = f.import_packet()
        f.refused(result, r"audit|blocking")
        require(not f.packet.exists(), "refused inbox packet was not moved aside")
        require(len(f.retained()) == 1, "refused packet was not retained once")
        return result

    def recovery():
        f.reset()
        result = refuse_and_park()
        require("or import the packet again" in result.stdout,
                "park advice does not name the re-import: " + f.safe(result.stdout))
        parked = [e for e in f.events() if e["type"] == "task.import_parked"]
        require(parked and "or import the packet again" in parked[-1]["data"]["reason"],
                "park event advice does not name the re-import")
        f.operator_restores()
        packet = read(f.retained()[0])
        result = f.import_packet()
        f.accepted(result, packet)
        require(f.packet.is_file(), "re-import did not restore the inbox packet")
        require(not f.retained(), "restored packet is still retained")
        # The loop clears an imported inbox entry; nothing is judged again.
        cut = len(f.events())
        require(f.cycle(real=True).returncode == 0, "next cycle failed")
        require(not f.packet.exists(), "loop left the imported inbox entry")
        judged = [e["type"] + ":" + json.dumps(e.get("data")) for e in f.events()[cut:]
                  if re.search(r"reject|refus|fail|park", e["type"])
                  and (TASK in json.dumps(e) or f.run in json.dumps(e))]
        require(not judged, "next cycle refused the recovered packet: " + "; ".join(judged))
    case("S0.4-1", "every-path: re-import after repair restores and imports", recovery)

    def reimport_still_broken():
        f.reset()
        refuse_and_park()
        shutil.copyfile(f.saved / ".singular-state/leases" / (TASK + ".json"), f.lease)
        shutil.copyfile(f.saved / "docs/orchestration/tasks" / (TASK + ".md"), f.task)
        parks = len([e for e in f.events() if e["type"] == "task.import_parked"])
        result = f.import_packet()
        f.refused(result, r"audit|blocking")
        require(len([e for e in f.events() if e["type"] == "task.import_parked"]) == parks + 1,
                "still-broken re-import was not parked again, visibly")
        require(f.task_status() == "blocked", "still-broken re-import left the task restored")
        require(not f.packet.exists(), "still-broken re-import left the packet in the inbox")
        require(len(f.retained()) == 1, "still-broken re-import lost or duplicated the retained packet")
    case("S0.4-1", "every-path: still-broken re-import parks again", reimport_still_broken)

    def reimport_task_not_restored():
        f.reset()
        refuse_and_park()
        kept = f.retained()[0]
        result = f.import_packet()  # the lease is still blocked
        require(result.returncode != 0, "import of a parked task succeeded")
        require(not f.packet.exists(), "failed re-import left the packet for the loop")
        require(f.retained() == [kept], "failed re-import did not put the packet back aside")
        cut = len(f.events())
        require(f.cycle(real=True).returncode == 0, "next cycle failed")
        require(not [e for e in f.events()[cut:] if re.search(r"reject|refus|fail|park", e["type"])
                     and TASK in json.dumps(e)], "next cycle judged the retained packet")
    case("S0.4-4", "every-path: failed re-import puts the packet back aside", reimport_task_not_restored)

    def symlink_not_restored():
        f.reset()
        refuse_and_park()
        f.operator_restores()
        kept = f.retained()[0]
        target = f.tmp / "elsewhere.json"
        kept.rename(target)
        kept.symlink_to(target)
        result = f.import_packet()
        require(result.returncode != 0 and "packet not found" in result.stdout,
                "a symlinked retained packet was restored")
        require(not f.packet.exists(), "symlink restored into the inbox")
    case("S0.4-1", "every-path: a symlinked retained copy is not restored", symlink_not_restored)

    def outside_inbox_unchanged():
        f.reset()
        refuse_and_park()
        f.operator_restores()
        other = f.tmp / "elsewhere" / f.packet.name
        other.parent.mkdir(exist_ok=True)
        result = f.command("import-packet.sh", other)
        require(result.returncode != 0 and "packet not found" in result.stdout,
                "a path outside the inbox was restored")
        require(len(f.retained()) == 1 and not other.exists(), "retained packet moved")
    case("S0.4-1", "every-path: paths outside the inbox are not restored", outside_inbox_unchanged)

    def driver_only_not_found():
        f.reset("driver-only")
        f.retained_dir.mkdir(parents=True)
        kept = f.retained_dir / "packet.ABC123"
        f.packet.rename(kept)
        result = f.import_packet()
        require(result.returncode != 0 and "packet not found" in result.stdout,
                "driver-only re-import changed: " + f.safe(result.stdout))
        require(kept.is_file() and not f.packet.exists(), "driver-only restored a packet")
    case("S0.4-1", "driver-only: re-import of a missing inbox packet still not found",
         driver_only_not_found)

    # ---- refusals name their subject ---------------------------------------
    def subjects():
        for letter, words in SUBJECTS.items():
            require(describe(f, letter + ":x-y") == words + " (" + letter + "): x-y",
                    "describe-refusal mislabels " + letter)
            require(describe(f, letter + ":x-y", True) == words, "subject mislabels " + letter)
        require(describe(f, "review-unit-invalid") == "review-unit-invalid",
                "describe-refusal changed a code without a conjunct")
        require(describe(f, "review-unit-invalid", True) == "", "subject invented for plain code")
    case("S0.4-2", "conjunct letters map to their plain-word subjects", subjects)

    def integrate_names(mutate, code, words):
        def check():
            f.reset()
            f.accepted(f.import_packet())
            mutate(f)
            result = f.integrate()
            require(result.returncode != 0, "every-path integration of a refused candidate passed")
            require(f"refuse {TASK}: {words}: " in result.stdout,
                    "printed refusal does not name the subject: " + f.safe(result.stdout))
            parked = [e for e in f.events() if e["type"] == "integration.acceptance_parked"]
            require(len(parked) == 1, "refusal was not recorded once")
            require(words in parked[0]["message"], "event text does not name the subject")
            require(parked[0]["data"].get("detail", "").startswith(words),
                    "event payload does not name the subject")
            require(parked[0]["data"].get("reason") == code, "event reason code changed")
        return check
    case("S0.4-2", "every-path integrate: audit refusal names audit (A)",
         integrate_names(base.blocking_audit, "A:blocking-finding-open", "audit (A)"))
    case("S0.4-2", "every-path integrate: manifest refusal names evidence manifest (E)",
         integrate_names(base.stale_manifest, "E:evidence-manifest-identity-mismatch",
                         "evidence manifest (E)"))

    def integrate_default():
        f.reset("driver-only")
        f.accepted(f.import_packet())
        base.blocking_audit(f)
        result = f.integrate()
        require(result.returncode == 0, "driver-only integration changed: " + f.safe(result.stdout))
        require(not any(e["type"] == "integration.acceptance_parked" for e in f.events()),
                "driver-only integration parked")
        require("audit (A)" not in result.stdout, "driver-only output changed")
    case("S0.4-2", "driver-only integrate: unchanged, no acceptance refusal", integrate_default)

    def import_names():
        f.reset()
        base.blocking_audit(f)
        result = f.import_packet()
        f.refused(result, r"audit")
        require("import refused: A:blocking-finding-open (audit)" in result.stdout,
                "import refusal does not name its subject: " + f.safe(result.stdout))
        refused = [e for e in f.events() if e["type"] == "packet.import_refused"]
        require(refused and refused[-1]["data"]["reason"].startswith("A:blocking-finding-open (audit);"),
                "import refusal record does not name its subject")
    case("S0.4-2", "every-path import: refusal keeps its code and names the subject", import_names)

    # ---- every listed artifact is checked -----------------------------------
    def change_listed(f):
        path = f.run_dir / f.listed()
        path.write_bytes(path.read_bytes() + b"tampered\n")

    def remove_listed(f):
        (f.run_dir / f.listed()).unlink()

    def list_outside(f):
        edit(f.manifest, lambda d: d["artifacts"].append(
            {"ref": "../outside.json", "sha256": "0" * 64, "bytes": 0}))

    def list_absolute(f):
        edit(f.manifest, lambda d: d["artifacts"].append(
            {"ref": str(f.tmp / "absolute.json"), "sha256": "0" * 64, "bytes": 0}))

    whole = [
        ("listed artifact changed", change_listed, "evidence-manifest-stale"),
        ("listed artifact missing", remove_listed, "evidence-manifest-incomplete"),
        ("listed ref outside the run", list_outside, "evidence-manifest-incomplete"),
        ("listed ref is absolute", list_absolute, "evidence-manifest-incomplete"),
    ]
    for label, mutate, reason in whole:
        def refused(m=mutate, r=reason):
            f.reset()
            ref = f.listed()
            m(f)
            f.refused(f.import_packet(), r)
            # The refusal's detail names the ref (the validator's own record).
            detail = whole_check_detail(f)
            if m in (change_listed, remove_listed):
                require(detail.startswith(ref + " "), "refusal does not name the ref: " + detail)
            if m is list_outside:
                require(detail.endswith("is outside the run"), "outside ref not named: " + detail)
            if m is list_absolute:
                require(detail.endswith("is an absolute path"), "absolute ref not named: " + detail)
        case("S0.4-1", "every-path: " + label, refused)

        def compatible(m=mutate):
            f.reset("driver-only")
            m(f)
            f.accepted(f.import_packet())
        case("S0.4-1", "driver-only: " + label + " still imports", compatible)

    def validator_modes():
        # The importer runs the predicate only under every-path, so pin the
        # driver-only predicate (driver, ops, accept-existing-packet) directly.
        f.reset("driver-only")
        change_listed(f)
        require(evidence_refusal(f, "driver-only") is None,
                "driver-only predicate now checks the whole manifest")
        refusal = evidence_refusal(f, "every-path")
        require(refusal == "evidence-manifest-stale", "every-path predicate missed the change")
    case("S0.4-1", "predicate: whole check only under every-path", validator_modes)

    print(f"every-path gaps: {passed} passing cases, {len(failures)} failing cases", flush=True)
    passed_main = not failures
    if only and only != "route":
        return 0 if passed_main else 1

    # The engine's own manifest validates on its normal every-path route: the
    # driver's predicate before publication, then import and integrate.
    try:
        (temporary / "b").mkdir()
        g = Fixture(engine, bash, temporary / "b", drive_mode="every-path")
        g.reset()
        g.accepted(g.import_packet())
        result = g.integrate()
        require(result.returncode == 0, "every-path integration of the valid run failed: "
                + g.safe(result.stdout))
        require(not any(e["type"] == "integration.acceptance_parked" for e in g.events()),
                "valid run parked at integration")
        print("ok S0.4-1: engine-written manifest passes the whole check on the every-path route",
              flush=True)
    except (Failure, OSError, ValueError, KeyError, IndexError) as exc:
        print("CRITERION S0.4-1\nFAIL S0.4-1: every-path route: " + str(exc), flush=True)
        passed_main = False
    return 0 if passed_main else 1


def load_validator(f):
    spec = importlib.util.spec_from_file_location(
        "acceptance_validator_under_test", f.engine / "engine/acceptance_validator.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def evidence_refusal(f, mode):
    """check_evidence's refusal reason for this run under a mode, or None."""
    module = load_validator(f)
    manifest = read(f.manifest)
    args = module.argparse.Namespace(
        task=TASK, run=f.run, head=f.head, campaign=manifest.get("campaignBinding", "legacy"),
        acceptance_mode=mode)
    try:
        module.check_evidence(args, f.run_dir, f.audit, f.host)
    except module.Refusal as refusal:
        return refusal.reason
    return None


def whole_check_detail(f):
    """The detail the real predicate gives for this run's manifest."""
    module = load_validator(f)
    try:
        module.check_manifest_whole(f.run_dir, read(f.manifest)["artifacts"])
    except module.Refusal as refusal:
        return refusal.detail
    return ""


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
