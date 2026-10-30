#!/usr/bin/env bash
proof_fields_verdict_nonce="${RAILS_NONCE:-}"
proof_fields_verdict_file="${RAILS_VERDICT_FILE:-}"
unset RAILS_NONCE RAILS_VERDICT_FILE
set -euo pipefail

# S1.1-8; spec 03, "The verification contract"; rp-fields.t fast-push brief.
# Task headers chosen here for subsequent rows:
#   Proof command: python3 tests/proof/check.py --label "two words"
#   Proof tests: ["tests/proof/check.py", "tests/single.py"]
# Proof tests is an explicit JSON array, preserving spaces and order. Parsed
# keys are proofCommand (string) and proofTests (array of repository paths).
# Commands may use the existing header convention of outer Markdown backticks.
# These tests exercise the real parser and preflight, never a proof runner.
# Missing partners must parse and then fail at preflight. Invalid commands or
# paths may fail at either boundary, but must explain the refusal.
# Legacy JSON is pinned at 9149359. Only absent/empty optional proof keys may
# be added to that snapshot; every pre-existing value, including taskDocument,
# remains exact. No timestamps, paths, or other values are normalised.
# No providers, loops, git mutations, or operating-system sandbox are needed.

engine_home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$engine_home" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ENGINE = Path(sys.argv.pop())
FIXTURES = ENGINE / "tests/fixtures/red-proof-fields"
LEGACY = (FIXTURES / "legacy.md").read_text(encoding="utf-8")
EXPECTED = json.loads((FIXTURES / "legacy.json").read_text(encoding="utf-8"))
COMMAND = 'python3 tests/proof/check.py --label "two words" --count 2'
PROOFS = ["tests/proof/check.py", "tests/single.py"]


class ProofFields(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="red-proof-fields-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        (self.root / ".gitignore").write_text(".singular-state/\n", encoding="utf-8")
        self.task = self.root / "TASK-4242.md"
        # Also isolate direct invocation from an operator's inherited settings.
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith("SINGULAR_")}
        self.env.update({
            "SINGULAR_ROOT": str(self.root),
            "SINGULAR_ENGINE_HOME": str(ENGINE),
            "SINGULAR_ENGINE_DIR": str(ENGINE / "engine"),
            "SINGULAR_STATE_DIR": str(self.root / ".singular-state"),
            "SINGULAR_TASKS_DIR": str(self.root),
            "SINGULAR_LOCAL_CONFIG_FILE": "/dev/null",
            "SINGULAR_PUSH": "0",
            "SINGULAR_PREFLIGHT_REQUIRE_ACCEPTANCE": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
        })

    def lib(self, operation, *args):
        # Task data is passed as argv, never interpolated into Bash source.
        scripts = {
            "parse": 'source "$1/engine/lib.sh"; singular_task_json "$2"',
            "preflight": 'source "$1/engine/lib.sh"; singular_task_preflight "$2" "${3-}" "${4-}" "${5:-1}"',
        }
        result = subprocess.run(
            ["bash", "-c", scripts[operation], "proof-fields", str(ENGINE), *args],
            cwd=self.root, env=self.env, text=True, capture_output=True, timeout=20,
        )
        # Keep failure logs portable, without leaking the checkout or temp path.
        result.stdout = result.stdout.replace(str(self.root), "<fixture>").replace(str(ENGINE), "<engine>")
        result.stderr = result.stderr.replace(str(self.root), "<fixture>").replace(str(ENGINE), "<engine>")
        return result

    def document(self, command=None, proofs=None, wrapped=False):
        headers = []
        if command is not None:
            value = f"`{command}`" if wrapped else command
            headers.append(f"Proof command: {value}")
        if proofs is not None:
            headers.append("Proof tests: " + json.dumps(proofs))
        return LEGACY.replace("\n## Objective", "\n" + "\n".join(headers) + "\n## Objective") if headers else LEGACY

    def parse_result(self, document):
        self.task.write_text(document, encoding="utf-8")
        return self.lib("parse", str(self.task))

    def parse(self, document):
        result = self.parse_result(document)
        self.assertEqual(result.returncode, 0, "task must parse: " + result.stderr)
        return json.loads(result.stdout)

    def preflight(self, parsed, *args):
        return self.lib("preflight", json.dumps(parsed), *args)

    def assert_dispatchable(self, parsed, *args):
        result = self.preflight(parsed, *args)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout + result.stderr, "", "valid preflight must be silent")

    def assert_refused(self, result, reason_pattern):
        self.assertGreater(result.returncode, 0, "invalid proof declaration was accepted")
        diagnostic = result.stdout + result.stderr
        self.assertTrue(diagnostic.strip(), "refusal must have a reason")
        self.assertNotIn("Traceback", diagnostic, "a crash is not a refusal")
        self.assertRegex(diagnostic.lower(), reason_pattern)

    def assert_invalid_document(self, document, reason_pattern):
        result = self.parse_result(document)
        if result.returncode == 0:
            result = self.preflight(json.loads(result.stdout))
        self.assert_refused(result, reason_pattern)

    def test_legacy_exact_parse_and_preflight(self):
        parsed = self.parse(LEGACY)
        legacy_values = dict(parsed)
        for key, empty in (("proofCommand", ""), ("proofTests", [])):
            if key in legacy_values:
                self.assertEqual(legacy_values.pop(key), empty, "undeclared proof must be empty")
        self.assertEqual(legacy_values, EXPECTED)
        self.assert_dispatchable(parsed)
        # Existing preflight success/failure and fallback rules stay exact.
        no_gate = dict(parsed, gateCommand="")
        failure = self.preflight(no_gate)
        self.assertEqual(failure.returncode, 1)
        self.assertEqual(failure.stdout, "no gate command (set 'Gate command:' in the task or gateCommand in singular.config.json)\n")
        self.assertEqual(failure.stderr, "")
        self.assert_dispatchable(no_gate, "true")
        self.assert_dispatchable(no_gate, "", "", "0")
        no_acceptance = self.preflight(dict(parsed, acceptanceCriteria=[]))
        self.assertEqual(no_acceptance.returncode, 1)
        self.assertEqual(no_acceptance.stdout, "task declares no acceptance criteria\n")
        self.assertEqual(no_acceptance.stderr, "")

    def test_both_fields_parse_exactly(self):
        for wrapped in (False, True):
            with self.subTest(markdown_wrapped=wrapped):
                document = self.document(COMMAND, PROOFS, wrapped)
                parsed = self.parse(document)
                self.assertEqual(parsed.get("proofCommand"), COMMAND,
                                 "Proof command must survive parsing exactly")
                self.assertEqual(parsed.get("proofTests"), PROOFS,
                                 "Proof tests must preserve every path in order")
                self.assertEqual(parsed["taskDocument"], document)
                self.assertEqual(parsed["ownedFiles"], EXPECTED["ownedFiles"])
                self.assert_dispatchable(parsed)

    def test_valid_pair_dispatches_with_default_and_off(self):
        for mode in (None, "off"):
            with self.subTest(red_proof=mode):
                if mode is not None:
                    self.env["SINGULAR_RED_PROOF"] = mode
                self.assert_dispatchable(self.parse(self.document(COMMAND, PROOFS)))
                self.assertFalse((self.root / "tests").exists(),
                                 "declared proof files need not exist before implementation")

    def test_each_missing_partner_is_refused_at_preflight(self):
        for mode in (None, "off"):
            for command, proofs, missing in (
                (COMMAND, None, r"proof\s*tests"),
                (None, PROOFS, r"proof\s*command"),
                (COMMAND, [], r"proof\s*tests"),
                ("", PROOFS, r"proof\s*command"),
            ):
                with self.subTest(red_proof=mode, command=command, proofs=proofs):
                    if mode is not None:
                        self.env["SINGULAR_RED_PROOF"] = mode
                    parsed = self.parse(self.document(command, proofs))
                    self.assert_refused(self.preflight(parsed), missing)

    def test_shell_operators_are_refused_with_a_reason(self):
        commands = {
            "pipe": "python3 tests/proof/check.py | cat",
            "output redirect": "python3 tests/proof/check.py > proof.log",
            "append redirect": "python3 tests/proof/check.py >> proof.log",
            "input redirect": "python3 tests/proof/check.py < input.txt",
            "semicolon": "python3 tests/proof/check.py; true",
            "and": "python3 tests/proof/check.py && true",
            "or": "python3 tests/proof/check.py || true",
            "backticks": "python3 tests/proof/check.py `touch proof-command-ran`",
            "substitution": "python3 tests/proof/check.py $(touch proof-command-ran)",
        }
        for name, command in commands.items():
            with self.subTest(operator=name):
                self.assert_invalid_document(
                    self.document(command, PROOFS),
                    r"proof\s*command|shell|operator|pipe|redirect|substitution|backtick|semicolon|one program|single command",
                )
                self.assertFalse((self.root / "proof-command-ran").exists(),
                                 "proof validation must not execute the command")

    def test_proof_paths_inside_owned_files_are_preserved(self):
        # Covers a folder descendant, an exactly owned file, and a space in a
        # path. A JSON list must not split that last path into two proof files.
        proofs = ["tests/proof/nested/check.py", "tests/single.py", "tests/proof/with spaces.py"]
        parsed = self.parse(self.document(COMMAND, proofs))
        self.assertEqual(parsed.get("proofTests"), proofs)
        self.assert_dispatchable(parsed)

    def test_proof_paths_cannot_escape_owned_scope(self):
        for path in (
            "tests/unowned.py",          # unrelated path
            "tests/proof-other/check.py", # sibling sharing the owned prefix
            "tests/single.py.extra",     # prefix of an exactly owned file
            "private/check.py",          # forbidden and unowned
            "tests/",                    # ancestor of owned paths
            "../outside.py",             # parent traversal
            "tests/proof/../../outside.py",
            "/outside/check.py",         # absolute path
        ):
            with self.subTest(path=path):
                self.assert_invalid_document(
                    self.document(COMMAND, [PROOFS[0], path]),
                    r"proof\s*tests|owned|scope|relative|repository|traversal|path",
                )


unittest.main(verbosity=2)
PY
if [[ -n "$proof_fields_verdict_nonce" && -n "$proof_fields_verdict_file" ]]; then
  printf '%s' "$proof_fields_verdict_nonce" >"$proof_fields_verdict_file"
fi
