#!/usr/bin/env bash
# Document contract, the skill for public operator documentation.
#
# Judges plugin/skills/singular-orchestration/ (SKILL.md and its references)
# against the code. The documents are data: this test reads files and runs
# nothing of the engine.
#
#   documentation  Current command names, clone address, hours, test count, runners,
#           detached-launch marker, version, context defaults, API heading,
#           and the exact old validation phrase.
#   push-defaults  SKILL.md names singular auto, the launchd launcher and SINGULAR_PUSH;
#           the switch appears beside the loop/launcher; SKILL.md itself
#           contains the launcher's literal worker-sandbox value.
#
# Not judged here: a reader checks
#   documentation  Whether the loop is mandatory, optional, or the direction under
#           review (loop-not-mandatory removed), including operating defaults
#           and instructions to maximize parallelism.
#   push-defaults  Whether auto and launchd push by default, the override's effect,
#           and whether direct commands push (push-auto, push-launcher and
#           push-direct replaced by names only); contradictions and denials
#           about pushing or the sandbox, and other launcher defaults.
#   documentation  What validation/withdrawal prose means beyond the literal old
#           phrase (validation-claim narrowed); no negation is interpreted.
#   documentation  Meaning beyond the retained literal detectors: completeness of
#           prose, historical versus current claims, list scope, command
#           arguments, and alternative wording of defaults or API headings.
#
# Code facts are read at runtime: CLI dispatch, engine/lib.sh defaults,
# engine/providers.json names, launcher sandbox, console routes, VERSION,
# and test filenames. Origin's address has no code source and is retained
# as the public clone address. The old validation phrase is a literal
# marker from references/operations.md, not evidence about an experiment.
# Synthetic judge samples exercise parsers; they do not pin engine values.
# Run it alone to see every assertion: bash tests/test-doc-contract-skill.sh

# The verdict file of the build's tool: read, then unset, before anything else.
rails_nonce="${RAILS_NONCE:-}"
rails_verdict_file="${RAILS_VERDICT_FILE:-}"
unset RAILS_NONCE RAILS_VERDICT_FILE
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

rc=0
python3 - "$ROOT" <<'PY' || rc=$?
import json
import re
import sys
from pathlib import Path

ROOT = Path(sys.argv[1])
SKILL_DIR = ROOT / "plugin" / "skills" / "singular-orchestration"
SKILL_MD = "plugin/skills/singular-orchestration/SKILL.md"
FIXTURE = "tests/fixtures/doc-contract/commands.txt"
# The public clone address is independent of the checkout remote and has no
# runtime source in the engine.
ORIGIN = "github.com/xiperinc/singular-lite"

results = []  # (key, criterion, title, problems)


def record(key, criterion, title, problems):
    results.append((key, criterion, title, list(problems)))


def read(relpath):
    try:
        return (ROOT / relpath).read_text(encoding="utf-8")
    except OSError:
        return None


def code_fact(relpath, pattern, what):
    """One value read from the code, or (None, why)."""
    text = read(relpath)
    if text is None:
        return None, f"{relpath}: cannot be read, so {what} is unknown"
    match = re.search(pattern, text, re.M)
    if not match:
        return None, f"{relpath}: {what} was not found where this test reads it"
    return match.group(1), None


# ---------------------------------------------------------------- markdown

FENCE = re.compile(r"^\s*(```|~~~)")
HEADING = re.compile(r"^#{1,6}\s+\S")
ROW = re.compile(r"^\s*\|")
SEPARATOR = re.compile(r"^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$")
ITEM = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s+")


class Unit:
    """One unit of meaning: a heading, a paragraph, a list item, a table row
    or a fenced block. `context` is what a reader carries into it: the header
    of a row's table, the paragraph that introduces an item's list."""

    def __init__(self, kind, line, text, context=""):
        self.kind, self.line, self.text, self.context = kind, line, text, context


def units(text):
    out, lines = [], text.split("\n")
    lead = None      # the paragraph that introduces the list being read
    header = None    # the header row of the table being read
    current = None   # the paragraph or item still collecting lines
    i = 0
    while i < len(lines):
        line = lines[i]
        fence = FENCE.match(line)
        if fence:
            j = i + 1
            while j < len(lines) and not lines[j].lstrip().startswith(fence.group(1)):
                j += 1
            out.append(Unit("code", i + 1, "\n".join(lines[i + 1:j])))
            lead, header, current = None, None, None
            i = j + 1
            continue
        if not line.strip():
            header, current = None, None
        elif HEADING.match(line):
            out.append(Unit("heading", i + 1, line.strip()))
            lead, header, current = None, None, None
        elif ROW.match(line):
            current = None
            if SEPARATOR.match(line):
                pass
            elif header is None and i + 1 < len(lines) and SEPARATOR.match(lines[i + 1]):
                header = line.strip()
            else:
                out.append(Unit("row", i + 1, line.strip(), header or ""))
        elif ITEM.match(line):
            current = Unit("item", i + 1, line.strip(), lead)
            out.append(current)
        elif current is not None:
            current.text += " " + line.strip()
        else:
            current = Unit("para", i + 1, line.strip())
            out.append(current)
            if not line.startswith("  "):
                lead = current
        i += 1
    for unit in out:
        if isinstance(unit.context, Unit):
            unit.context = unit.context.text
        elif unit.context is None:
            unit.context = ""
    return out


def cells(row):
    out, cur, code = [], "", False
    for ch in row.strip():
        if ch == "`":
            code = not code
        if ch == "|" and not code:
            out.append(cur.strip())
            cur = ""
        else:
            cur += ch
    out.append(cur.strip())
    if out and out[0] == "":
        out = out[1:]
    if out and out[-1] == "":
        out = out[:-1]
    return out


def sections(us):
    """Units grouped under the heading above them."""
    group = []
    for unit in us:
        if unit.kind == "heading" and group:
            yield group
            group = []
        group.append(unit)
    if group:
        yield group


# ---------------------------------------------------------------- commands

COMMAND_WORD = r"[a-z][a-z0-9-]*"
SINGULAR_COMMAND = re.compile(
    r"(?<![A-Za-z0-9_./-])singular\s+(" + COMMAND_WORD + r"(?:[/|]" + COMMAND_WORD + r")*)(?![A-Za-z0-9_])"
)


def dispatched_commands(cli_text):
    """The first words main() in cli/singular accepts: the names on the arms
    of its outer `case "$cmd"`. Options and the default arm are left out."""
    lines = cli_text.split("\n")
    start = next((i for i, line in enumerate(lines) if re.match(r"^main\(\)\s*\{", line)), None)
    if start is None:
        return None
    i = start + 1
    while i < len(lines) and not re.match(r'^\s*case\s+"?\$\{?cmd\}?"?\s+in\s*$', lines[i]):
        if re.match(r"^\}", lines[i]):
            return None
        i += 1
    if i >= len(lines):
        return None
    names, depth = [], 1
    for line in lines[i + 1:]:
        if re.match(r"^\s*esac\b", line):
            depth -= 1
            if depth == 0:
                break
            continue
        if depth == 1:
            arm = re.match(r"^\s*([^\s()#][^()]*?)\)", line)
            if arm and re.fullmatch(r'[A-Za-z0-9_*"|\s-]+', arm.group(1)):
                for name in arm.group(1).split("|"):
                    if re.fullmatch(COMMAND_WORD, name.strip()):
                        names.append(name.strip())
        if re.match(r"^\s*case\b.*\bin\s*$", line):
            depth += 1
    return names


def commands_after_singular(text):
    """Every X written as `singular X` (also `singular X/Y`)."""
    found = set()
    for match in SINGULAR_COMMAND.finditer(text):
        found.update(re.split(r"[/|]", match.group(1)))
    return found


def commands_listed(us):
    """Usage-style listings. In a fenced block: a line, indented little, that
    begins with the command and goes on as a usage line does (nothing, an
    option, an argument, a column gap, alternatives). In a table or a list:
    a first cell or an item that begins with the command, in code."""
    found = set()
    alternatives = COMMAND_WORD + r"(?:\s*[/|]\s*" + COMMAND_WORD + r")*"
    usage = re.compile(
        r"^\s{0,6}(?:\$\s+)?(?:singular\s+)?(" + alternatives + r")(?:\s+" + COMMAND_WORD + r")?"
        r"(?=\s*$|\s{2,}|\s+[\[<\"A-Z-]|\s+\S*\|)"
    )
    for unit in us:
        firsts = []
        if unit.kind == "code":
            for line in unit.text.split("\n"):
                match = usage.match(line)
                if match:
                    firsts.append(match.group(1))
        elif unit.kind in ("row", "item"):
            first = (cells(unit.text) or [""])[0] if unit.kind == "row" else ITEM.sub("", unit.text, count=1)
            match = re.match(r"^[*_]*`(?:singular\s+)?(" + alternatives + r")(?=[\s`\[<])", first)
            if match:
                firsts.append(match.group(1))
        for first in firsts:
            found.update(re.split(r"\s*[/|]\s*", first))
    return found


def commands_in_code(us):
    """`singular X` inside a code span or a fenced block, comments left out:
    the places where the skill gives a command to run."""
    found = {}
    for unit in us:
        if unit.kind == "code":
            fragments = [re.sub(r"(^|\s)#.*$", "", line) for line in unit.text.split("\n")]
        else:
            fragments = re.findall(r"`([^`]*)`", unit.text)
        for fragment in fragments:
            for name in commands_after_singular(fragment):
                found.setdefault(name, unit.line)
    return found


# ------------------------------------------------------------ clone address

# An address of the engine's repository on any host: a host name, then a path
# that ends in singular-lite. A local path or a placeholder is not an address.
REPOSITORY = re.compile(
    r"(?:[a-z][a-z0-9+.-]*://)?(?:[\w.-]+@)?[\w-]+(?:\.[\w-]+)*\.[a-z]{2,}(?::\d+)?[:/][\w./~-]*?singular-lite(?:\.git)?(?![\w-])", re.I
)


def normalise_address(address):
    address = address.strip().rstrip("/.,;:")
    address = re.sub(r"^[a-z][a-z0-9+.-]*://", "", address, flags=re.I)
    address = re.sub(r"^[^@/]+@", "", address)
    address = re.sub(r"^([^/:]+):(?!\d)", r"\1/", address)
    return re.sub(r"\.git$", "", address).rstrip("/").lower()


def wrong_clone_lines(text, origin):
    """The lines that give an address for the engine's repository other than origin's."""
    return [
        number for number, line in enumerate(text.split("\n"), 1)
        if any(normalise_address(m.group(0)) != origin for m in REPOSITORY.finditer(line))
    ]


# ------------------------------------------------- further mismatches

NUMBER = r"(?<![\w.])(\d+(?:\.\d+)?)(?:h|hrs?|\s*hours?)?(?![\w.])"
LAUNCHER = re.compile(r"\blaunchd\b|\blauncher\b|run-orchestrator", re.I)
QUIET_GAP = r"(?:(?!SINGULAR_)(?!\.\s)[^;])"


def hours_claims(unit):
    """The numbers a unit gives as the default of SINGULAR_MAX_HOURS."""
    if "SINGULAR_MAX_HOURS" not in unit.text:
        return []
    if unit.kind == "row":
        row, head = cells(unit.text), cells(unit.context) if unit.context else []
        column = next((i for i, cell in enumerate(head) if re.search(r"default", cell, re.I)), None)
        named = re.findall(r"SINGULAR_[A-Z0-9_]+", row[0]) if row else []
        if column is not None and column < len(row) and named == ["SINGULAR_MAX_HOURS"]:
            return re.findall(NUMBER, row[column])
    claims = []
    after = r"SINGULAR_MAX_HOURS" + QUIET_GAP + r"{0,120}?\bdefaults?\b(?:(?!SINGULAR_)[^;0-9]){0,30}?" + NUMBER
    before = r"\bdefaults?\b(?:(?!SINGULAR_)[^;0-9]){0,30}?" + NUMBER + QUIET_GAP + r"{0,80}?SINGULAR_MAX_HOURS"
    for pattern in (after, before):
        claims += [m.group(1) for m in re.finditer(pattern, unit.text, re.I)]
    return claims


TEST_COUNT = re.compile(
    r"(?<![\w.\-/])(\d{3,5})\s*\+?\s+(?:[A-Za-z`*/._-]+\s+){0,2}?(?:test\s+files|tests\b|test\s+scripts|`?tests/test-\*\.sh)", re.I
)


def test_counts(unit):
    return [int(n) for n in TEST_COUNT.findall(unit.text.replace("\n", " "))]


def partial_runner_lists(unit, adapters):
    """A unit that lists three or more of the engine's runners and not all of
    them, unless it presents them as examples."""
    mentions = [m for m in re.finditer(r"[a-z0-9]+-run\.sh", unit.text) if m.group(0) in adapters]
    named = {m.group(0) for m in mentions}
    if len(named) < 3 or named == set(adapters):
        return []
    if re.search(r"(?:e\.g\.|for example|such as|including|like)\W*$", unit.text[:mentions[0].start()][-25:], re.I):
        return []
    return sorted(set(adapters) - named)


def partial_provider_lists(unit, providers):
    """Three or more literal provider ids in one unit must include them all.
    Word boundaries exclude adapter filenames and longer product names.
    No prose is interpreted as an exemption."""
    named = {name for name in providers if re.search(
        r"(?<![\w.-])" + re.escape(name) + r"(?![\w.-])", unit.text, re.I)}
    return sorted(set(providers) - named) if len(named) >= 3 else []


def nohup_launches(unit):
    """(line number, line) for each command in a fenced block that starts the loop under nohup."""
    if unit.kind != "code":
        return []
    return [
        (unit.line + 1 + offset, line.strip()) for offset, line in enumerate(unit.text.split("\n"))
        if re.search(r"\bnohup\b.*\bsingular\s+auto\b", re.sub(r"(^|\s)#.*$", "", line))
    ]


VERSION_CLAIM = re.compile(
    r"\b(?:reflects?|describes?|documents?|covers?|written\s+(?:for|against)|current\s+(?:as\s+of|for|to)|applies\s+to|valid\s+for"
    r"|up\s+to\s+date\s+(?:with|for|as\s+of)|(?:checked|audited|verified)\s+against)\s+(?:the\s+)?(?:singular\s+)?(?:engine\s+)?"
    r"(?:version\s+)?v?(\d+\.\d+)(?:\.(?:\d+|x))?(?![\w.])", re.I
)


def version_claims(unit):
    return [] if unit.kind == "code" else VERSION_CLAIM.findall(unit.text)


BLANKET_ZERO = re.compile(r"\bdefaults?\s+(?:(?:stay|stays|are|is|remain|remains|to|of|at|was|were|=)\s+)?`?0`?(?![\w.%])", re.I)
NOT_ALL = re.compile(r"\b(?:rest|others?|remaining|except|apart|all\s+but|unless|otherwise)\b", re.I)


def blanket_zero_offenders(section, defaults):
    """A sentence that says the defaults are 0, naming no setting, over a
    section whose tables and lists name settings the code defaults otherwise."""
    said = None
    for unit in section:
        if unit.kind != "para":
            continue
        for sentence in re.split(r"(?<=[.!?])\s+", unit.text):
            if BLANKET_ZERO.search(sentence) and "SINGULAR_" not in sentence and not NOT_ALL.search(sentence):
                said = said or unit.line
    if said is None:
        return None, []
    named = []
    for unit in section:
        if unit.kind in ("row", "item"):
            named += re.findall(r"SINGULAR_[A-Z0-9_]+", unit.text)
    offenders = sorted({name for name in named if defaults.get(name, "0") not in ("0", "")})
    return said, offenders


# Exact marker in references/operations.md at freeze time. Do not interpret
# negation, synonyms, or claims about what the experiment established.
VALIDATION_PHRASE = "validated by the 0.4.0 experiment"


def get_only_api_heading(unit):
    return (
        unit.kind == "heading"
        and re.search(r"\bAPI\b", unit.text)
        and re.search(r"\ball\s+GET\b|\bGET[- ]only\b|\bread[- ]only\b", unit.text, re.I)
        and not re.search(r"\bPOST\b|\bexcept\b|\bapart\s+from\b|\bbut\b", unit.text, re.I)
    )


# ------------------------------------------------------------------- push

AUTO = re.compile(r"singular\s+auto\b|\bautonomate(?:\.sh)?\b|\b(?:self-driving|autonomous|auto)\s+loop\b", re.I)


def push_names(text):
    """Presence only; no reading of defaults, negation, or push behaviour."""
    missing = []
    if "auto" not in commands_after_singular(text):
        missing.append("singular auto")
    if not re.search(r"\blaunchd\b|\brun-orchestrator\.sh\b", text):
        missing.append("launchd or run-orchestrator.sh")
    if not re.search(r"\bSINGULAR_PUSH\b", text):
        missing.append("SINGULAR_PUSH")
    return missing


def push_switch(us):
    """SINGULAR_PUSH named where the loop's or the launcher's push is stated."""
    for unit in us:
        if "SINGULAR_PUSH" in unit.text + " " + unit.context and (AUTO.search(unit.text) or LAUNCHER.search(unit.text)):
            return unit
    return None


def launcher_sandbox(us, value):
    for unit in us:
        if LAUNCHER.search(unit.text + " " + unit.context):
            if re.search(r"(?<![\w-])" + re.escape(value) + r"(?![\w-])", unit.text):
                return unit
    return None


# --------------------------------------------- the judge, checked on samples
# Small documents with a known answer, so that a reasonable phrasing is seen
# to pass and each fault of today is seen to fail before the skill is read.

def self_check():
    wrong = []

    def expect(criterion, name, got, want):
        if got != want:
            wrong.append(f"{criterion}: judge self-check, {name}: got {got!r}, wanted {want!r}")

    expect("push-defaults", "all push names",
           push_names("`singular auto`, launchd, `SINGULAR_PUSH`"), [])
    expect("push-defaults", "launcher filename",
           push_names("`singular auto`, run-orchestrator.sh, `SINGULAR_PUSH`"), [])
    for absent, text in (
        ("singular auto", "launchd SINGULAR_PUSH"),
        ("launchd or run-orchestrator.sh", "singular auto SINGULAR_PUSH"),
        ("SINGULAR_PUSH", "singular auto launchd"),
    ):
        expect("push-defaults", "missing " + absent, push_names(text), [absent])
    expect("push-defaults", "switch beside loop",
           bool(push_switch(units("`singular auto` uses `SINGULAR_PUSH`."))), True)
    expect("push-defaults", "switch under list lead-in",
           bool(push_switch(units("`SINGULAR_PUSH`:\n\n- launchd\n"))), True)
    expect("push-defaults", "switch without loop or launcher",
           bool(push_switch(units("`SINGULAR_PUSH`"))), False)
    expect("push-defaults", "literal sandbox beside launcher",
           bool(launcher_sandbox(units("launchd: `sample-sandbox`"), "sample-sandbox")), True)
    expect("push-defaults", "sandbox paraphrase",
           bool(launcher_sandbox(units("launchd: full access"), "sample-sandbox")), False)
    expect("push-defaults", "sandbox substring",
           bool(launcher_sandbox(units("launchd: `sample-sandbox-extra`"), "sample-sandbox")), False)
    expect("push-defaults", "sandbox without launcher",
           bool(launcher_sandbox(units("`sample-sandbox`"), "sample-sandbox")), False)

    expect("documentation", "origin's address, two spellings", wrong_clone_lines(
        "git clone https://github.com/xiperinc/singular-lite /path/to/engine\ngit clone git@github.com:xiperinc/singular-lite.git\n"
        "git clone <the engine repository> /path/to/engine\n", ORIGIN), [])
    expect("documentation", "another account's address, another host", wrong_clone_lines(
        "git clone https://github.com/someone-else/singular-lite /path/to/engine\ncd /path/to/singular-lite && bash install.sh\n"
        "git clone ssh://git@git.example.org:2222/mirror/singular-lite.git\n", ORIGIN), [1, 3])

    budget = units(
        "- **Budget:** `SINGULAR_MAX_HOURS` caps the auto loop's wall-clock (default\n  12h); the breaker trips after"
        " `SINGULAR_MAX_CONSEC_FAILS` (default 5) consecutive no-progress cycles.\n"
    )
    expect("documentation", "an hours default in prose", hours_claims(budget[0]), ["12"])
    knobs = units(
        "| Knob | Default | Effect |\n| --- | --- | --- |\n"
        "| `SINGULAR_MAX_HOURS` | `20` | Wall-clock budget for `singular auto`; the launchd launcher sets `12`. |\n"
    )
    expect("documentation", "an hours default in a table", hours_claims(knobs[0]), ["20"])
    passing = units("It runs until the wall-clock budget (`SINGULAR_MAX_HOURS`) and sets `SINGULAR_PUSH=1` by default.\n")
    expect("documentation", "no hours default given", hours_claims(passing[0]), [])

    expect("documentation", "a count of test files", test_counts(units("a long job (`tests/run.sh`, ~185 test\nfiles) that\n")[0]), [185])
    expect("documentation", "numbers that count other things",
           test_counts(units("75 treatment tasks, 0 escaped defects vs 1/30 control; bounded at (900) seconds\n")[0]), [])

    four = ["a-run.sh", "b-run.sh", "c-run.sh", "d-run.sh"]
    expect("documentation", "a runner list one short",
           partial_runner_lists(units("- `runner`: `a-run.sh`, `b-run.sh`, or `c-run.sh`.\n")[0], four), ["d-run.sh"])
    expect("documentation", "a whole runner list",
           partial_runner_lists(units("any of `a-run.sh`, `b-run.sh`, `c-run.sh`, `d-run.sh`\n")[0], four), [])
    expect("documentation", "runners given as examples",
           partial_runner_lists(units("a runner, e.g. `a-run.sh`, `b-run.sh` or `c-run.sh`\n")[0], four), [])

    products = ["alpha", "beta", "gamma", "delta"]
    expect("documentation", "a product list one short",
           partial_provider_lists(units("Alpha, BETA, Gamma")[0], products), ["delta"])
    expect("documentation", "a whole product list",
           partial_provider_lists(units("Alpha, Beta, Gamma, Delta")[0], products), [])
    expect("documentation", "product names are whole words",
           partial_provider_lists(units("alphabet, beta-run.sh, gammablob")[0], products), [])

    shell = units("```bash\nnohup singular auto >> out.log 2>&1 & disown\nsingular auto --detach   # never: nohup singular auto &\n```\n")
    expect("documentation", "a nohup launch", [number for number, _ in nohup_launches(shell[0])], [2])

    expect("documentation", "the version a file says it reflects",
           version_claims(units("Everything here reflects\nengine 0.5.x behavior and lessons from production runs.\n")[0]), ["0.5"])
    expect("documentation", "a version that dates a change", version_claims(units("Since 0.5.0 STOP takes effect mid-nap.\n")[0]), [])

    defaults = {"SINGULAR_A": "1", "SINGULAR_B": "0"}
    stale = units("## Knobs\n\nRaw engine defaults stay `0` for back-compat; the recommended set:\n\n| Knob | Recommended |\n| --- | --- |\n"
                  "| `SINGULAR_A` | `1` |\n| `SINGULAR_B` | `25` |\n")
    expect("documentation", "defaults said to stay 0", blanket_zero_offenders(stale, defaults)[1], ["SINGULAR_A"])
    fixed = units("## Knobs\n\n`SINGULAR_A` already defaults to `1`. The rest default to `0`.\n\n| Knob | Recommended |\n| --- | --- |\n"
                  "| `SINGULAR_A` | `1` |\n| `SINGULAR_B` | `25` |\n")
    expect("documentation", "defaults told apart", blanket_zero_offenders(fixed, defaults)[1], [])

    expect("documentation", "the old validation marker",
           VALIDATION_PHRASE in "set (" + VALIDATION_PHRASE + ": results)", True)
    expect("documentation", "other validation wording is for a reader",
           VALIDATION_PHRASE in "No controlled validation was performed.", False)

    heads = units("## JSON API (all GET, read-only)\n\n## JSON API (GET, and three POST routes)\n\n## Read-only rules\n")
    expect("documentation", "API headings", [bool(get_only_api_heading(u)) for u in heads], [True, False, False])

    cli = 'main() {\n  case "$cmd" in\n    a)  run a ;;\n    b-c)\n      case "${1:-}" in\n        x) run x ;;\n        *) die ;;\n' \
          '      esac ;;\n    v|--version|-v) ver ;;\n    help|--help|-h|"") usage ;;\n    *) die "unknown (try: help)" ;;\n  esac\n}\n'
    expect("documentation", "the dispatch of a small CLI", dispatched_commands(cli), ["a", "b-c", "v", "help"])
    listing = units(
        "Run `singular fence` or `singular stop/resume`.\n\n```text\n  lease list|show     raw lease operations\n"
        "  next-area | next-areas\n  gate validate FILE\n  /api/timeline  per-task intervals,\n"
        "                 memory marks, context spans\n  health marks, cycle spans\n```\n\n"
        "| Command | Does |\n| --- | --- |\n| `campaign start` | freezes |\n\n"
        "- `review-policy effective` — the policy in force\n- the `status` field of a lease\n- `gateCommand` — proves the repo healthy\n"
    )
    named = commands_after_singular("\n".join(u.text for u in listing)) | commands_listed(listing)
    expect("documentation", "the ways a command is named", sorted(named & {
        "fence", "stop", "resume", "lease", "next-area", "next-areas", "gate", "campaign", "review-policy", "status",
        "memory", "context", "health"}),
        ["campaign", "fence", "gate", "lease", "next-area", "next-areas", "resume", "review-policy", "stop"])
    expect("documentation", "a command given to run", sorted(commands_in_code(units("Run `singular frobnicate --now`, not Singular itself.\n"))), ["frobnicate"])
    return wrong


# ------------------------------------------------------------- the checks

judge = self_check()
record("judge", "documentation, push-defaults", "the judge gives the known answer on its own samples", judge)

skill_files = sorted(str(p.relative_to(ROOT)) for p in SKILL_DIR.rglob("*.md")) if SKILL_DIR.is_dir() else []
docs = {rel: read(rel) or "" for rel in skill_files}
parsed = {rel: units(text) for rel, text in docs.items()}
have_skill = SKILL_MD in docs
no_skill = [f"{SKILL_MD}: missing, so nothing of the skill can be judged"]

# documentation: the frozen list holds nothing stale. It equalled the dispatch when it
# was frozen; a command added to the CLI later is not this list's to carry, so
# the test never asks that the two stay equal.
cli_text, fixture_text = read("cli/singular"), read(FIXTURE)
dispatch = dispatched_commands(cli_text) if cli_text is not None else None
current = list(dict.fromkeys(dispatch or []))  # the current commands, from the code
no_dispatch = ["cli/singular: the dispatch in main() was not found where this test reads it"]
frozen, problems = [], []
if fixture_text is None:
    problems.append(f"{FIXTURE}: missing")
else:
    for number, line in enumerate(fixture_text.split("\n"), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if not re.fullmatch(COMMAND_WORD, line):
            problems.append(f"{FIXTURE}:{number}: not a command name")
        elif line in frozen:
            problems.append(f"{FIXTURE}:{number}: `{line}` is listed twice")
        else:
            frozen.append(line)
if not current:
    problems += no_dispatch
elif fixture_text is not None:
    if not frozen:
        problems.append(f"{FIXTURE}: lists no command")
    stale = [name for name in frozen if name not in current]
    if stale:
        problems.append(f"{FIXTURE} lists what cli/singular no longer dispatches: {', '.join(stale)}")
record("commands-list", "documentation", "every command on the frozen list is still dispatched by cli/singular", problems)

# documentation: the skill's commands are the current commands, both ways. Both read
# the dispatch, never the list: a command a later row adds to the CLI is one
# the skill must name and may give.
everything = "\n".join(docs.values())
named = commands_after_singular(everything)
for us in parsed.values():
    named |= commands_listed(us)
problems = list(no_dispatch) if not current else ([] if have_skill else list(no_skill))
unnamed = [name for name in current if name not in named]
if unnamed:
    problems.append(
        f"{len(unnamed)} of the {len(current)} commands cli/singular dispatches are named nowhere in the skill: {', '.join(unnamed)}"
        " (a command is named by `singular <command>`, or by a usage line, a table row or a list item that begins with it in code)"
    )
record("commands-named", "documentation", "every command cli/singular dispatches is named in the skill", problems)

problems = list(no_dispatch) if not current else ([] if have_skill else list(no_skill))
for rel, us in parsed.items():
    for name, line in sorted(commands_in_code(us).items()):
        if current and name not in current:
            problems.append(f"{rel}:{line}: `singular {name}` is not a command cli/singular dispatches")
record("commands-current", "documentation", "every command the skill gives is a current command", problems)

# documentation: compare the clone address without printing it.
problems = [] if have_skill else list(no_skill)
for rel, text in docs.items():
    for line in wrong_clone_lines(text, ORIGIN):
        problems.append(f"{rel}:{line}: a clone address that is not origin's ({ORIGIN}); give origin's, or cut it")
record("clone-address", "documentation", "the clone address is origin's, or is cut", problems)

# documentation, further mismatches: 12 hours against the code's default.
code_hours, why = code_fact("engine/lib.sh", r'^\s*SINGULAR_MAX_HOURS="\$\{SINGULAR_MAX_HOURS:-([0-9.]+)\}"', "the default of SINGULAR_MAX_HOURS")
launcher_hours, _ = code_fact("templates/launchd/run-orchestrator.sh", r'SINGULAR_MAX_HOURS="\$\{SINGULAR_MAX_HOURS:-([0-9.]+)\}"', "the launcher's hours")
problems = [why] if why else ([] if have_skill else list(no_skill))
if code_hours:
    for rel, us in parsed.items():
        for unit in us:
            allowed = {float(code_hours)}
            if launcher_hours and LAUNCHER.search(unit.text):
                allowed.add(float(launcher_hours))
            for claim in hours_claims(unit):
                if float(claim) not in allowed:
                    problems.append(
                        f"{rel}:{unit.line}: gives {claim} as the default of SINGULAR_MAX_HOURS; engine/lib.sh sets {code_hours}"
                        + (f" (the launchd launcher sets {launcher_hours}, where the launcher is named)" if launcher_hours else "")
                    )
record("hours-default", "documentation", "a default given for SINGULAR_MAX_HOURS is the code's", problems)

# documentation, further mismatches: "~185 test files".
suite = len(list((ROOT / "tests").glob("test-*.sh"))) + len(list((ROOT / "singular-ext" / "tests").glob("test-*.sh")))
problems = [] if have_skill else list(no_skill)
for rel, us in parsed.items():
    for unit in us:
        for count in test_counts(unit):
            if abs(count - suite) * 10 > suite:
                problems.append(f"{rel}:{unit.line}: counts {count} test files; tests/run.sh finds {suite} (within a tenth passes; or cut the number)")
record("test-count", "documentation", "a count of the suite's test files is near what tests/run.sh finds", problems)

# documentation, further mismatches: six providers in the skill, seven in the engine.
adapters, providers, problems = [], [], []
try:
    registry = json.loads(read("engine/providers.json") or "")
    providers = sorted(registry["providers"])
    adapters = sorted({spec["adapter"] for spec in registry["providers"].values() if spec.get("adapter")})
except (ValueError, KeyError, TypeError, AttributeError):
    pass
if not adapters:
    problems.append("engine/providers.json: the runners were not found where this test reads them")
elif not have_skill:
    problems += no_skill
for rel, us in parsed.items():
    for unit in us:
        missing = partial_runner_lists(unit, adapters) if adapters else []
        if missing:
            problems.append(f"{rel}:{unit.line}: lists some of the engine's {len(adapters)} runners and leaves out {', '.join(missing)}")
        missing = partial_provider_lists(unit, providers) if providers else []
        if missing:
            problems.append(f"{rel}:{unit.line}: lists some of the engine's {len(providers)} provider names and leaves out {', '.join(missing)}")
record("runner-list", "documentation", "a list of runners is the whole of engine/providers.json", problems)

# documentation, further mismatches: the loop launched with nohup where the reference says never.
autonomate = read("engine/autonomate.sh")
problems = [] if have_skill else list(no_skill)
if autonomate is None:
    problems.append("engine/autonomate.sh: cannot be read, so whether `singular auto --detach` exists is unknown")
elif re.search(r"^\s*--detach\)", autonomate, re.M):
    for rel, us in parsed.items():
        for unit in us:
            for number, line in nohup_launches(unit):
                problems.append(f"{rel}:{number}: launches the loop with nohup (\"{line}\"); engine/autonomate.sh has --detach for this")
else:
    for rel, text in docs.items():
        for number, line in enumerate(text.split("\n"), 1):
            if re.search(r"singular\s+auto\s+--detach", line):
                problems.append(f"{rel}:{number}: names `singular auto --detach`, which engine/autonomate.sh does not have")
record("detached-launch", "documentation", "the loop is not launched with nohup where the engine has --detach", problems)

# documentation, further mismatches: "reflects engine 0.5".
version = (read("VERSION") or "").strip()
problems = [] if have_skill else list(no_skill)
if not re.fullmatch(r"\d+\.\d+\.\d+", version):
    problems.append("VERSION: no engine version was found")
else:
    series = ".".join(version.split(".")[:2])
    for rel, us in parsed.items():
        for unit in us:
            for claim in version_claims(unit):
                if claim != series:
                    problems.append(f"{rel}:{unit.line}: says it reflects engine {claim}; VERSION is {version}")
record("engine-version", "documentation", "the engine version a file says it reflects is VERSION's series", problems)

# documentation, further mismatches: context settings said to stay 0.
lib = read("engine/lib.sh")
defaults = dict(re.findall(r'^\s*(SINGULAR_[A-Z0-9_]+)="\$\{\1:-([^}"]*)\}"', lib or "", re.M))
problems = [] if have_skill else list(no_skill)
if not defaults:
    problems.append("engine/lib.sh: no default was found where this test reads them")
for rel, us in parsed.items():
    for section in sections(us):
        line, offenders = blanket_zero_offenders(section, defaults)
        if offenders:
            detail = ", ".join(f"{name}={defaults[name]}" for name in offenders)
            problems.append(f"{rel}:{line}: says the defaults are 0 over settings that engine/lib.sh defaults otherwise: {detail}")
record("context-defaults", "documentation", "no setting is said to default to 0 that the code defaults otherwise", problems)

# documentation: absence of the exact old marker; its meaning is the reader's.
problems = [] if have_skill else list(no_skill)
for rel, text in docs.items():
    for number, line in enumerate(text.splitlines(), 1):
        if VALIDATION_PHRASE in line:
            problems.append(f'{rel}:{number}: contains the old literal "{VALIDATION_PHRASE}"; remove or rewrite it')
record("validation-claim", "documentation", "the old validation phrase is absent", problems)

# documentation, further mismatches: an API headed "all GET, read-only" above POST routes.
server = read("plugin/scripts/singular_graph_server.py")
problems = [] if have_skill else list(no_skill)
if server is None:
    problems.append("plugin/scripts/singular_graph_server.py: cannot be read, so the console's routes are unknown")
else:
    bodies = re.findall(r"^    def _?do_POST\(self\).*?(?=^    def |^[^\s#]|\Z)", server, re.M | re.S)
    posts = sorted(set(re.findall(r'"(/api/[A-Za-z0-9_/-]+)"', "\n".join(bodies))))
    if posts:
        for rel, us in parsed.items():
            for unit in us:
                if get_only_api_heading(unit):
                    problems.append(f"{rel}:{unit.line}: \"{unit.text}\"; the console server takes POST on {', '.join(posts)}")
record("api-heading", "documentation", "the console API is not headed all-GET while the server takes POST", problems)

# push-defaults: named entry points and variable only. Their behaviour is read by a person.
skill = parsed.get(SKILL_MD, [])
problems = [] if have_skill else list(no_skill)
if have_skill:
    for missing in push_names(docs[SKILL_MD]):
        problems.append(f"{SKILL_MD}: missing literal name `{missing}`")
record("push-names", "push-defaults", "SKILL.md names singular auto, the launchd launcher and SINGULAR_PUSH", problems)

problems = [] if have_skill else list(no_skill)
if have_skill and not push_switch(skill):
    problems.append(f"{SKILL_MD}: SINGULAR_PUSH is not named where the loop's or the launcher's push is stated")
record("push-switch", "push-defaults", "SKILL.md names SINGULAR_PUSH as the switch", problems)

# push-defaults: the launcher's documented worker sandbox.
sandbox, why = code_fact("templates/launchd/run-orchestrator.sh", r'SINGULAR_L2_SANDBOX="\$\{SINGULAR_L2_SANDBOX:-([^}"]*)\}"', "the launcher's default worker sandbox")
problems = [why] if why else ([] if have_skill else list(no_skill))
if sandbox and have_skill and not launcher_sandbox(skill, sandbox):
    problems.append(
        f"{SKILL_MD}: missing literal launcher sandbox `{sandbox}` (SINGULAR_L2_SANDBOX)."
        " The judge looks in SKILL.md itself for one unit that names the launcher and that literal value"
    )
record("launcher-sandbox", "push-defaults", "SKILL.md contains the launcher's literal default worker sandbox", problems)

# ------------------------------------------------------------------ report

failed = [r for r in results if r[3]]
for key, criterion, title, problems in results:
    print(f"{'FAIL' if problems else 'ok  '}  {criterion}: {title}  [{key}]")
    for problem in problems:
        print(f"        {criterion}: {problem}")
print()
print("passed: " + (" ".join(r[0] for r in results if not r[3]) or "none"))
print("failed: " + (" ".join(r[0] for r in failed) or "none"))
print(f"test-doc-contract-skill: {len(failed)} of {len(results)} assertions failed")
sys.exit(1 if failed else 0)
PY

if [[ "$rc" -ne 0 ]]; then
  exit 1
fi

echo "doc contract (skill) tests passed"
# The very last act, and only after every assertion passed.
if [[ -n "$rails_nonce" && -n "$rails_verdict_file" ]]; then
  printf '%s\n' "$rails_nonce" >"$rails_verdict_file"
fi
