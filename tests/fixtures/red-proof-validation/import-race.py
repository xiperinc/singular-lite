"""Deleting proof after import's first check must prevent publication."""
import json
import os
from pathlib import Path
import shlex
import sys
import tempfile

root = Path(sys.argv[1]).resolve()
bash = sys.argv[2]
sys.path.insert(0, str(root / "tests/fixtures/red-proof-paths"))
from fixture import Checks, Fixture
from proof import install
from suite import set_mode

with tempfile.TemporaryDirectory(prefix="vrace.") as directory:
    home = Path(directory)
    checks = Checks()
    f = Fixture(root, home, checks)
    f.env["TEST_BASH"] = bash
    f.seed()
    record = install(f.repo, f.run_dir, f.head, f.original_head)
    set_mode(f, "enforce", "every-path")
    spy = home / "spy.py"
    spy.write_text('''import os
from pathlib import Path
import subprocess
import sys
result = subprocess.run([sys.executable, *sys.argv[1:]], check=False)
if Path(sys.argv[1]).name == "acceptance_validator.py":
    marker = Path(os.environ["PROOF_RACE_MARKER"])
    with marker.open("a") as stream:
        stream.write(str(result.returncode) + "\\n")
    if result.returncode == 0:
        Path(os.environ["PROOF_RACE_RECORD"]).unlink(missing_ok=True)
sys.exit(result.returncode)
''')
    bin_dir = home / "bin"
    bin_dir.mkdir()
    shim = bin_dir / "python3"
    shim.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + " " + shlex.quote(str(spy)) + ' "$@"\n')
    shim.chmod(0o755)
    marker = home / "calls"
    f.env.update(PATH=str(bin_dir) + os.pathsep + f.env["PATH"],
                 PROOF_RACE_MARKER=str(marker), PROOF_RACE_RECORD=str(record))
    result = f.run([bash, root / "engine/import-packet.sh", f.packet])
    calls = marker.read_text().splitlines() if marker.exists() else []
    checks.check("import-race", "first acceptance check passed", bool(calls) and calls[0] == "0")
    checks.check("import-race", "proof removed before publication", not record.exists())
    checks.check("import-race", "final check refused V", result.returncode != 0 and "V:" in result.stdout)
    checks.check("import-race", "no imported certificate", not list((f.orch / "packets/imported").glob("*/*.json")))
    if checks.failures:
        print(result.stdout[-2000:])
    sys.exit(bool(checks.failures))
