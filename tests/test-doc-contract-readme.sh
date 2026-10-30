#!/usr/bin/env bash
# Document contract for the README row of public documentation.
#
# It judges documents as data. It reads README.md, docs/providers.md,
# docs/review-policy.md, and compares what they say with
# what the code does. Every number and value it compares against is read from
# the code when the test runs: engine/lib.sh, engine/l1-drive.sh,
# engine/autonomate.sh, engine/integrate.sh, engine/reconcile.sh,
# engine/claude-run.sh, engine/codex-run.sh, engine/ops.sh,
# engine/review_policy.py, cli/singular, VERSION and the templates. Three pure
# pieces of the engine are queried as child processes, on fixtures in the
# test's own folder: the driver's risk-tier retry policy, its
# bounded_infra_budget, and the lease step of `unpark`. Nothing of the engine
# is loaded into this process, and nothing is written outside one temporary
# folder. The one typed fact is the clone address, which no code holds.
#
# Public contracts:
#   readme  the README's settings: configured defaults and effective limits,
#           apart, and both as the code has them; the clone address
#   documentation  docs/providers.md, docs/review-policy.md,
#           and the README's further mismatches that a machine can check
#   push-defaults  the README names the loop, push variable and launchd launcher,
#           and gives the launcher defaults as values
#
# Not judged here: a reader checks
#   push-defaults  who pushes by default, the opt-out and direct-command behaviour;
#           the relationship between those claims, across clauses or sentences
#   documentation  whether `unpark` restores repairs but not review rounds
#   documentation  whether provider sandbox claims are true under their conditions;
#           only the exact obsolete sandbox sentence is rejected here
#
# Every failure line names its criterion. The exit status is 1 when a document
# fails an assertion and 3 when the test itself could not do its work.
# The verdict-file rule of the build's tool: read both, unset both, before
# anything else runs. The nonce is written as the very last act, and only when
# every assertion passed.
rails_nonce="${RAILS_NONCE:-}"
rails_verdict_file="${RAILS_VERDICT_FILE:-}"
unset RAILS_NONCE RAILS_VERDICT_FILE
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/doc-contract-readme.XXXXXX")" || exit 3
# An interrupted run removes its folder too, then dies by the same signal, so
# that it is never read as a verdict. A finished run removes the folder below,
# before the verdict is written: the write stays the last act.
for signal in INT TERM HUP; do
  # shellcheck disable=SC2064
  trap "rm -rf \"\$tmp\"; trap - $signal; kill -$signal \$\$" "$signal"
done

python3 - "$ROOT" "$tmp" "${BASH:-bash}" <<'PY'
import json
import os
import re
import subprocess
import sys
import traceback

ROOT, TMP, BASH = sys.argv[1:4]

# The public clone address is checked independently of a local remote. A
# README that omits a clone address also passes.
ORIGIN_ADDRESS = "github.com/xiperinc/singular-lite"


results = []  # (passed, criterion, message)


def ok(criterion, message):
    results.append((True, criterion, message))
    print("ok    %s: %s" % (criterion, message))


def bad(criterion, message):
    results.append((False, criterion, message))
    print("FAIL  %s: %s" % (criterion, message))


def check(condition, criterion, passed_message, failed_message):
    if condition:
        ok(criterion, passed_message)
    else:
        bad(criterion, failed_message)
    return bool(condition)


class CodeFact(Exception):
    """The test could not read a fact from the code."""


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8", errors="replace") as handle:
        return handle.read()


def exists(rel):
    return os.path.exists(os.path.join(ROOT, rel))


# --------------------------------------------------------------------------
# Reading text: numbers, tokens, blocks
# --------------------------------------------------------------------------

NUMBER_WORDS = {
    0: ["zero"], 1: ["one", "once", "single"], 2: ["two", "twice"],
    3: ["three"], 4: ["four"], 5: ["five"], 6: ["six"], 7: ["seven"],
    8: ["eight"], 9: ["nine"], 10: ["ten"], 11: ["eleven"], 12: ["twelve"],
    20: ["twenty"],
}
WORD_NUMBERS = {word: number for number, words in NUMBER_WORDS.items() for word in words}


def says(text, value, units=()):
    """True when the text states the value: a number as digits or as a word,
    anything else as a whole token. `L2`, `0.23.6` and `TASK-0002` do not state
    the number 2. A unit named in `units` may follow the digits (`20h`)."""
    value = str(value)
    if re.fullmatch(r"\d+", value):
        unit = r"(?:\s?(?:%s))?" % "|".join(units) if units else ""
        if re.search(r"(?<![\w.])(?<![A-Za-z]-)" + value + unit + r"(?![\w]|[.,]\d)", text):
            return True
        return any(re.search(r"\b%s\b" % word, text, re.I)
                   for word in NUMBER_WORDS.get(int(value), []))
    return re.search(r"(?<![\w-])" + re.escape(value) + r"(?![\w-])", text) is not None


def names(text, identifier):
    return re.search(r"(?<![A-Za-z0-9_])" + re.escape(identifier) + r"(?![A-Za-z0-9_])",
                     text) is not None


def split_cells(line):
    line = line.strip()
    if line.startswith("|"):
        line = line[1:]
    if line.endswith("|") and not line.endswith("\\|"):
        line = line[:-1]
    return [cell.strip() for cell in re.split(r"(?<!\\)\|", line)]


def parse_blocks(text):
    """A Markdown file as a list of blocks: a paragraph, a list item, a table
    row or a fenced block. Each block carries its context: the nearest heading
    above it, its table's header row, and for a fenced block the paragraph just
    above it. A statement may then be made in a table whose header names the
    subject, or in a listing under a sentence that names it."""
    blocks = []
    heading = ""
    paragraph = []
    paragraph_line = 0
    last_text = ""
    table_header = None
    fence = None
    fence_lines = []
    fence_line = 0

    def flush():
        nonlocal paragraph, last_text
        if paragraph:
            joined = " ".join(part.strip() for part in paragraph)
            blocks.append({"kind": "text", "text": joined, "context": heading,
                           "heading": heading, "line": paragraph_line})
            last_text = joined
            paragraph = []

    for number, raw in enumerate(text.splitlines(), 1):
        stripped = raw.strip()
        if fence is not None:
            if stripped.startswith(fence):
                body = "\n".join(fence_lines)
                blocks.append({"kind": "fence", "text": body, "heading": heading,
                               "context": heading + " " + last_text, "line": fence_line})
                fence = None
                fence_lines = []
            else:
                fence_lines.append(raw)
            continue
        opening = re.match(r"(```+|~~~+)", stripped)
        if opening:
            flush()
            table_header = None
            fence = opening.group(1)
            fence_line = number
            continue
        if not stripped:
            flush()
            table_header = None
            continue
        if re.match(r"#{1,6}\s", stripped):
            flush()
            table_header = None
            heading = stripped.lstrip("#").strip()
            last_text = ""
            continue
        if stripped.startswith("|"):
            flush()
            cells = split_cells(stripped)
            if table_header is None:
                table_header = cells
                continue
            if all(re.fullmatch(r":?-+:?", cell) for cell in cells if cell) and any(cells):
                continue
            blocks.append({"kind": "row", "text": stripped, "cells": cells,
                           "header": table_header, "heading": heading,
                           "context": heading + " " + " | ".join(table_header),
                           "line": number})
            continue
        table_header = None
        if re.match(r"([-*+]|\d+[.)])\s", stripped):
            flush()
        if not paragraph:
            paragraph_line = number
        paragraph.append(raw)
    flush()
    return blocks


def sentences(text):
    return [part for part in re.split(r"(?<=[.!?])\s+(?=[A-Z`*_\[(\"'])", text) if part.strip()]


def blocks_naming(blocks, identifier):
    return [block for block in blocks if names(block["text"], identifier)]


def blocks_about(blocks, knob):
    """The blocks that name a setting, without the table rows that are about
    another one: a row whose first cell names a different SINGULAR_ variable
    says what it says of that variable, also when it mentions this one."""
    about = []
    for block in blocks_naming(blocks, knob):
        if block["kind"] == "row" and block["cells"]:
            first = block["cells"][0]
            if re.search(r"SINGULAR_[A-Z0-9_]+", first) and not names(first, knob):
                continue
        about.append(block)
    return about


def settings_rows(blocks, knob):
    return [block for block in blocks
            if block["kind"] == "row" and block["cells"] and names(block["cells"][0], knob)]


def default_column(row):
    """Which column of a row's table carries the configured default: the one
    whose title says "configured", else the first that says "default". A column
    the title gives to the launcher or to an effective limit is not it, and in
    a table under a heading about the launcher a bare "Default" is the
    launcher's, so only a title that says configured, engine or direct counts
    there. None when the table has no such column."""
    under_launcher = re.search(r"launch", row["heading"], re.I) is not None
    found = []
    for index, title in enumerate(row["header"]):
        if index >= len(row["cells"]) or not re.search(r"configured|default", title, re.I):
            continue
        if re.search(r"launch", title, re.I):
            continue
        if re.search(r"effective|in effect", title, re.I) and not re.search(r"configured", title, re.I):
            continue
        if under_launcher and not re.search(r"configured|engine|direct", title, re.I):
            continue
        found.append(index)
    for index in found:
        if re.search(r"configured", row["header"][index], re.I):
            return index
    return found[0] if found else None


def configured_default_stated(blocks, knob, value, units=()):
    """The configured default is judged where the README states configured
    defaults: in every table row whose first cell names the setting and whose
    table has a column for the configured default. Every such row must give
    the value in that column. A row about the launcher does not stand in for
    the settings table."""
    judged = [(row, default_column(row)) for row in settings_rows(blocks, knob)]
    judged = [(row, index) for row, index in judged if index is not None]
    if not judged:
        return False, ("no table row whose first cell names %s in a table with a column for the "
                       "configured default" % knob)
    wrong = ["line %d reads %r" % (row["line"], row["cells"][index][:60])
             for row, index in judged if not says(row["cells"][index], value, units)]
    return not wrong, "; ".join(wrong)


def statement(block):
    """A block's text without the cell that carries a configured default: the
    default's own cell states the default and nothing else."""
    if block["kind"] != "row":
        return block["text"]
    index = default_column(block)
    return " | ".join(cell for position, cell in enumerate(block["cells"]) if position != index)


# --------------------------------------------------------------------------
# Facts, read from the code
# --------------------------------------------------------------------------

def shell_default(text, variable):
    """The default in `VAR="${VAR:-default}"`, with or without `export`."""
    match = re.search(r'^(?:export\s+)?%s="\$\{%s:-([^}"]*)\}"' % (variable, variable),
                      text, re.M)
    return match.group(1) if match else None


def inline_defaults(text, variable):
    return set(re.findall(r"\$\{%s:-([^}]*)\}" % variable, text))


def need(value, what):
    if value is None or value == "" or value == set():
        raise CodeFact(what)
    return value


def child(argv, what):
    try:
        done = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=60, cwd=TMP,
                              env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                                   "HOME": TMP, "TMPDIR": TMP})
    except (OSError, subprocess.SubprocessError) as error:
        raise CodeFact("%s: %s" % (what, error))
    if done.returncode != 0:
        raise CodeFact("%s: exit %d: %s" % (what, done.returncode,
                                            done.stderr.decode("utf-8", "replace")[-300:]))
    return done.stdout.decode("utf-8", "replace")


def retry_policy(drive, configured_cap):
    """The driver's own risk-tier policy, queried as a child process: the
    snippet it runs to compute a task's product-repair ceiling, given a task
    file and the configured SINGULAR_MAX_RETRIES. Returns what it prints for a
    task that declares no risk tier and for one that declares `high`."""
    match = re.search(r'retry_policy_json="\$\(python3 - [^\n]*(?:\\\n[^\n]*)*<<\'PY\'\n(.*?)\nPY\n',
                      drive, re.S)
    if not match:
        raise CodeFact("engine/l1-drive.sh: the risk-tier retry policy snippet was not found")
    script = os.path.join(TMP, "retry-policy.py")
    with open(script, "w", encoding="utf-8") as handle:
        handle.write(match.group(1) + "\n")
    answers = {}
    for label, tier_line in (("undeclared", ""), ("high", "Risk tier: high\n")):
        task = os.path.join(TMP, "task-%s.md" % label)
        with open(task, "w", encoding="utf-8") as handle:
            handle.write("# TASK-0001: fixture\n\nStatus: ready\n%s\n## Objective\n\nNone.\n" % tier_line)
        out = child([sys.executable, "-I", script, task, os.path.join(TMP, "no-config.json"),
                     "", "", str(configured_cap)],
                    "engine/l1-drive.sh: the risk-tier retry policy snippet")
        try:
            answer = json.loads(out)
            answers[label] = {"tier": str(answer["riskTier"]),
                              "ceiling": int(answer["riskCeiling"]),
                              "effective": int(answer["productRepairMax"])}
        except (ValueError, KeyError, TypeError) as error:
            raise CodeFact("engine/l1-drive.sh: the retry policy printed something else: %s" % error)
    return answers


def infra_clamp(drive, requested):
    """bounded_infra_budget, queried as a child process: what the driver makes
    of a configured infrastructure-retry budget."""
    match = re.search(r"^bounded_infra_budget\(\) \{\n.*?^\}\n", drive, re.S | re.M)
    if not match:
        raise CodeFact("engine/l1-drive.sh: bounded_infra_budget was not found")
    script = os.path.join(TMP, "bounded-infra-budget.sh")
    with open(script, "w", encoding="utf-8") as handle:
        handle.write(match.group(0))
    out = child([BASH, "-c", 'source "$1"; bounded_infra_budget "$2"', "_", script, str(requested)],
                "engine/l1-drive.sh: bounded_infra_budget").strip()
    if not re.fullmatch(r"\d+", out):
        raise CodeFact("engine/l1-drive.sh: bounded_infra_budget printed %r" % out)
    return out


def function_body(text, name):
    match = re.search(r"^%s\(\) \{\n(.*?)(?=^[A-Za-z_][A-Za-z0-9_]*\(\) \{|\Z)" % re.escape(name),
                      text, re.S | re.M)
    return match.group(1) if match else None


def version_tuple(text):
    return tuple(int(part) for part in text.split("."))


# --------------------------------------------------------------------------
# readme: the README's settings
# --------------------------------------------------------------------------

# The shape of a remote address: a scheme, the `user@host:path` form, or a
# host name with a path. A branch name, a tag, a depth and a local folder do
# not have it.
REMOTE_ADDRESS = r"(?:[a-z][a-z0-9+.-]*://|[\w.-]+@[\w.-]+:|[\w-]+(?:\.[\w-]+)*\.[a-z]{2,}[:/])\S"
# Options of `git clone` whose value is an address or a path that is not the
# repository being cloned.
CLONE_OPTIONS_WITH_A_PLACE = ("--reference", "--reference-if-able", "--bundle-uri", "--template",
                              "--separate-git-dir", "--upload-pack", "-u", "--config", "-c")


def readme_settings(readme, blocks):
    lib = read("engine/lib.sh")
    drive = read("engine/l1-drive.sh")
    C = "readme"

    # The hours default.
    hours = need(shell_default(lib, "SINGULAR_MAX_HOURS"), "engine/lib.sh: no default for SINGULAR_MAX_HOURS")
    stated, seen = configured_default_stated(blocks, "SINGULAR_MAX_HOURS", hours,
                                             units=("h", "hr", "hrs", "hours?"))
    check(stated, C,
          "README gives SINGULAR_MAX_HOURS its configured default, %s" % hours,
          "README must give SINGULAR_MAX_HOURS its configured default, %s (engine/lib.sh), in the "
          "default column of every settings row for it: %s" % (hours, seen))

    # The template's concurrency.
    try:
        template = json.loads(read("templates/singular.config.json"))
        concurrency = str(template["resources"]["maxConcurrent"])
    except (ValueError, KeyError, TypeError) as error:
        raise CodeFact("templates/singular.config.json: resources.maxConcurrent: %s" % error)
    check(any(says(block["text"], concurrency) for block in blocks_naming(blocks, "maxConcurrent")),
          C,
          "README states the template's resources.maxConcurrent, %s" % concurrency,
          "README must state the template's resources.maxConcurrent, %s "
          "(templates/singular.config.json), where it names maxConcurrent" % concurrency)
    count = (r"(\d+|" + "|".join(sorted(WORD_NUMBERS, key=len, reverse=True)) + r")"
             r"\s+(?:(?:L2|concurrent|parallel|simultaneous)\s+)*workers?\b")
    wrong = []
    for block in blocks:
        if block["kind"] == "fence":
            continue
        for sentence in sentences(block["text"]):
            if not re.search(r"\b(starter|template|scaffold\w*)\b", sentence, re.I):
                continue
            for match in re.finditer(count, sentence, re.I):
                raw = match.group(1).lower()
                number = raw if raw.isdigit() else str(WORD_NUMBERS[raw])
                if number != concurrency and not says(sentence, concurrency):
                    wrong.append("paragraph at line %d: %r" % (block["line"], match.group(0)))
    check(not wrong, C,
          "no README sentence gives the starter configuration a worker count the template does not set",
          "README gives the starter configuration a worker count the template does not set "
          "(templates/singular.config.json sets resources.maxConcurrent to %s): %s"
          % (concurrency, "; ".join(wrong)))

    # Product repairs: the configured default, and the ceilings by risk tier.
    retries = need(shell_default(lib, "SINGULAR_MAX_RETRIES"), "engine/lib.sh: no default for SINGULAR_MAX_RETRIES")
    stated, seen = configured_default_stated(blocks, "SINGULAR_MAX_RETRIES", retries)
    check(stated, C,
          "README gives SINGULAR_MAX_RETRIES its configured default, %s" % retries,
          "README must give SINGULAR_MAX_RETRIES its configured default, %s (engine/lib.sh), in the "
          "default column of every settings row for it: %s" % (retries, seen))
    # The effective limits are looked for outside the default's own cell, so
    # the default cannot stand in for them. The words of the risk tier may sit
    # in the table's header or the heading above.
    policy = retry_policy(drive, retries)
    low, high = policy["undeclared"], policy["high"]
    named = blocks_about(blocks, "SINGULAR_MAX_RETRIES")
    about = " ".join(statement(block) for block in named)
    around = about + " " + " ".join(block["context"] for block in named)
    missing = [str(tier["effective"]) for tier in (low, high) if not says(about, tier["effective"])]
    by_tier = re.search(r"\brisk\b|\btiers?\b", around, re.I) is not None
    check(not missing and by_tier, C,
          "README states the effective product-repair ceilings by risk tier (%s: %d, %s: %d)"
          % (low["tier"], low["effective"], high["tier"], high["effective"]),
          "README must state, where it names SINGULAR_MAX_RETRIES and outside the cell of the "
          "configured default (%s), the effective product-repair limit by risk tier: %d for a %s "
          "task and %d for a %s one (engine/l1-drive.sh). Missing: %s"
          % (retries, low["effective"], low["tier"], high["effective"], high["tier"],
             ", ".join(missing + ([] if by_tier else ["any word of the risk tier"]))))

    # Infrastructure retries: the configured defaults, and the driver's clamp.
    for knob in ("SINGULAR_AUDIT_INFRA_MAX", "SINGULAR_WORKER_INFRA_MAX"):
        configured = need(shell_default(lib, knob), "engine/lib.sh: no default for %s" % knob)
        stated, seen = configured_default_stated(blocks, knob, configured)
        check(stated, C,
              "README gives %s its configured default, %s" % (knob, configured),
              "README must give %s its configured default, %s (engine/lib.sh), in the default "
              "column of every settings row for it: %s" % (knob, configured, seen))
        effective = infra_clamp(drive, configured)
        about = " ".join(statement(block) for block in blocks_about(blocks, knob))
        check(says(about, effective), C,
              "README states the effective limit of %s, %s" % (knob, effective),
              "README must state, where it names %s (not in a row about another setting) and outside "
              "the cell of any configured default, the effective limit %s: the driver clamps the "
              "configured %s (bounded_infra_budget, engine/l1-drive.sh)" % (knob, effective, configured))

    # The clone address. Every token of a `git clone` command that has the
    # shape of a remote address is read, wherever its options put it.
    lines = readme.splitlines()
    found = []
    for number, line in enumerate(lines, 1):
        for match in re.finditer(r"\bgit\s+clone\b(.*)", line):
            command = match.group(1)
            following = number
            while command.rstrip().endswith("\\") and following < len(lines):
                command = command.rstrip()[:-1] + " " + lines[following]
                following += 1
            command = re.split(r"\s(?:&&|\|\||[;|#])(?:\s|$)", command)[0]
            previous = ""
            for raw in command.split():
                token = raw.strip("`\"'<>()[]{}").rstrip(".,;:!?`\"')]}")
                if previous not in CLONE_OPTIONS_WITH_A_PLACE and not raw.startswith("-") \
                        and re.match(REMOTE_ADDRESS, token, re.I):
                    found.append((number, token))
                    break
                if "`" in raw:
                    break  # the inline command ends here; what follows is prose
                previous = raw

    def normal(address):
        address = re.sub(r"^[a-z][a-z0-9+.-]*://", "", address.strip(), flags=re.I)
        address = re.sub(r"^[^@/:]+@", "", address)
        address = re.sub(r"^([\w.-]+):(?:\d+/)?", r"\1/", address)
        return re.sub(r"(?:\.git)?/*$", "", address).lower()

    off = sorted(set(number for number, address in found if normal(address) != ORIGIN_ADDRESS))
    check(not off, C,
          "README's clone address is origin's, or is cut (%d given)" % len(found),
          "README's clone address must be origin's, %s, or be cut; the "
          "`git clone` command on line %s gives another"
          % (ORIGIN_ADDRESS, ", ".join(str(number) for number in off)))


# --------------------------------------------------------------------------
# push-defaults: command and variable names; the launchd launcher's defaults
# --------------------------------------------------------------------------

# The launchd launcher, by the word launchd or by its file. "Launcher" alone is
# also what the README calls the `singular` command, so it does not count.
LAUNCHER = r"launchd|run-orchestrator"


def readme_push_and_launcher(readme, blocks):
    C = "push-defaults"
    launcher = read("templates/launchd/run-orchestrator.sh")
    lib = read("engine/lib.sh")

    # What the code does. The criterion's sentence is true of this code only:
    # the loop and the launcher push by default, a direct command does not.
    dispatched = re.search(r"^\s*auto\)\s+run_engine\s+autonomate\.sh\b", read("cli/singular"), re.M)
    auto = shell_default(read("engine/autonomate.sh"), "SINGULAR_PUSH")
    launched = shell_default(launcher, "SINGULAR_PUSH")
    direct = inline_defaults(read("engine/integrate.sh"), "SINGULAR_PUSH") \
        | inline_defaults(read("engine/reconcile.sh"), "SINGULAR_PUSH")
    premise = bool(dispatched) and auto is not None and auto == launched \
        and len(direct) == 1 and auto not in direct
    if not check(premise, C,
                 "the code: `singular auto` and the launchd launcher default SINGULAR_PUSH to %s, a "
                 "direct command to %s" % (auto, "/".join(sorted(direct))),
                 "the code no longer does what this criterion's sentence says (singular auto runs "
                 "autonomate.sh: %s; SINGULAR_PUSH defaults: auto %r, launcher %r, direct %r). The "
                 "sentence the README must carry has to be ruled again"
                 % (bool(dispatched), auto, launched, sorted(direct))):
        return
    # Literal names only. Their relationship and meaning belong to the reader.
    check(names(readme, "singular auto"), C,
          "README names `singular auto`",
          "README must name `singular auto`")
    check(re.search(LAUNCHER, readme, re.I) is not None, C,
          "README names the launchd launcher",
          "README must name the launchd launcher (launchd or run-orchestrator)")
    check(names(readme, "SINGULAR_PUSH"), C,
          "README names `SINGULAR_PUSH`",
          "README must name `SINGULAR_PUSH`")

    # Check the worker sandbox, target branch, and every
    # setting the launcher defaults to a value other than the engine's own
    # default in engine/lib.sh. Each value is read from the launcher. A
    # default's own cell in a settings table is not a statement about the
    # launcher.
    defaults = dict(re.findall(r'^export (SINGULAR_[A-Z0-9_]+)="\$\{[A-Z0-9_]+:-([^}"$]*)\}"', launcher, re.M))

    def launcher_says(value, variable=None):
        return any(says(statement(block), value)
                   and (variable is None or names(block["text"], variable))
                   and re.search(LAUNCHER, block["text"] + " " + block["context"], re.I)
                   for block in blocks)

    where = ("in a paragraph, row or listing that names the launchd launcher (the word launchd, or "
             "run-orchestrator.sh, in it, in its table's header or in the heading above)")
    sandbox = need(defaults.get("SINGULAR_L2_SANDBOX"),
                   "templates/launchd/run-orchestrator.sh: no default for SINGULAR_L2_SANDBOX")
    runner = inline_defaults(read("engine/codex-run.sh"), "SINGULAR_L2_SANDBOX")
    if runner == {sandbox}:
        ok(C, "the launcher's worker sandbox default is the runner's own (%s): nothing of the "
              "launcher's to state" % sandbox)
    else:
        check(launcher_says(sandbox), C,
              "README states the launcher's worker sandbox default, %s" % sandbox,
              "README must state that the launchd launcher defaults workers to the sandbox %s "
              "(SINGULAR_L2_SANDBOX in templates/launchd/run-orchestrator.sh; a direct command gets "
              "%s), %s" % (sandbox, "/".join(sorted(runner)) or "the runner's own default", where))
    branch = need(defaults.get("SINGULAR_TARGET_BRANCH"),
                  "templates/launchd/run-orchestrator.sh: no default for SINGULAR_TARGET_BRANCH")
    if shell_default(lib, "SINGULAR_TARGET_BRANCH") == branch:
        ok(C, "the launcher's target branch default is the engine's own (%s): nothing of the "
              "launcher's to state" % branch)
    else:
        check(launcher_says(branch), C,
              "README states the launcher's target branch default, %s" % branch,
              "README must state that the launchd launcher defaults the target branch to %s "
              "(SINGULAR_TARGET_BRANCH in templates/launchd/run-orchestrator.sh; the engine has no "
              "default of its own and requires one), %s" % (branch, where))
    for variable in sorted(defaults):
        value = defaults[variable]
        engine = shell_default(lib, variable)
        if variable in ("SINGULAR_PUSH", "SINGULAR_L2_SANDBOX", "SINGULAR_TARGET_BRANCH") \
                or engine is None or engine == value:
            continue
        check(launcher_says(value, variable), C,
              "README states the launcher's default for %s, %s" % (variable, value),
              "README must state that the launchd launcher defaults %s to %s "
              "(templates/launchd/run-orchestrator.sh; engine/lib.sh defaults it to %s), %s, and "
              "that names the variable" % (variable, value, engine, where))


# --------------------------------------------------------------------------
# documentation: the provider and review-policy documents
# --------------------------------------------------------------------------

def providers_document():
    C = "documentation"
    runner = read("engine/claude-run.sh")
    guard = re.search(r"^if \[\[ ([^\n]*) \]\]; then\n[ \t]*claude_os_sandbox=", runner, re.M)
    if not guard:
        raise CodeFact("engine/claude-run.sh: the condition around the OS sandbox was not found")
    wrapped = sorted(set(re.findall(r'"\$level" == "(\w+)"', guard.group(1))))
    if not wrapped:
        ok(C, "engine/claude-run.sh wraps no writable level: docs/providers.md may say so")
        return
    # Exact text in docs/providers.md at 6827d08, not a grammar for deciding
    # whether other sentences describe sandbox behaviour correctly.
    obsolete = "Non-readonly levels (`l0` / `l1` / `l2`) do not wrap the argv."
    check(obsolete not in read("docs/providers.md"), C,
          "docs/providers.md no longer contains the obsolete sentence from 6827d08",
          "docs/providers.md must remove or correct the exact obsolete sentence from 6827d08: "
          + obsolete)


def unpark_in_the_code():
    """What `unpark` does, from the code and not from its comments or its help
    text. (1) The lease step of singular_lease_unpark is run as a child process
    on a fixture lease that has spent two repairs, beside a fixture review
    ledger: afterwards the lease's retryCount is 0 and nothing but the lease
    has changed. (2) No line of code in ops_unpark or singular_lease_unpark
    runs the review-policy program, the one writer of the ledger, or names the
    ledger's file. Returns (resets repairs, writes the ledger)."""
    lease = function_body(read("engine/lib.sh"), "singular_lease_unpark")
    verb = function_body(read("engine/ops.sh"), "ops_unpark")
    if lease is None or verb is None:
        raise CodeFact("engine/lib.sh singular_lease_unpark or engine/ops.sh ops_unpark was not found")
    policy = read("engine/review_policy.py")
    where = re.search(r"def _ledger_path\([^)]*\)[^:]*:\n\s+return state_dir((?:\s*/\s*\"[^\"]+\")+)", policy)
    ledger_parts = re.findall(r'"([^"]+)"', where.group(1)) if where else []

    step = re.search(r"python3 - \"\$lease\" <<'PY'\n(.*?)\nPY\n", lease, re.S)
    if step:
        state = os.path.join(TMP, "unpark-state")
        os.makedirs(os.path.join(state, "leases"), exist_ok=True)
        script = os.path.join(TMP, "lease-unpark.py")
        with open(script, "w", encoding="utf-8") as handle:
            handle.write(step.group(1) + "\n")
        lease_file = os.path.join(state, "leases", "TASK-0001.json")
        with open(lease_file, "w", encoding="utf-8") as handle:
            json.dump({"taskId": "TASK-0001", "status": "parked", "retryCount": 2,
                       "productPassStarted": True}, handle)
        ledger_file = os.path.join(state, *(ledger_parts or ["review-ledger.json"]))
        os.makedirs(os.path.dirname(ledger_file), exist_ok=True)
        with open(ledger_file, "w", encoding="utf-8") as handle:
            json.dump({"logicalChanges": {"TASK-0001": {"rounds": [{"series": 1}, {"series": 1}]}}}, handle)

        def others():
            seen = {}
            for folder, _, files in os.walk(state):
                for name in files:
                    path = os.path.join(folder, name)
                    if path != lease_file:
                        with open(path, "rb") as handle:
                            seen[path] = handle.read()
            return seen

        before = others()
        child([sys.executable, "-I", script, lease_file], "engine/lib.sh: the lease step of singular_lease_unpark")
        try:
            with open(lease_file, encoding="utf-8") as handle:
                after = json.load(handle)
        except (OSError, ValueError) as error:
            raise CodeFact("engine/lib.sh: the lease step of singular_lease_unpark left no lease: %s" % error)
        resets = after.get("retryCount") == 0
        writes = others() != before
    else:
        resets = re.search(r"""["']retryCount["']\]\s*=\s*0\b""", lease) is not None
        writes = False

    def code(body):
        """Lines that do something: no comment, no line that only prints."""
        lines = []
        for line in body.splitlines():
            line = re.sub(r"(?:^|\s)#.*$", "", line).strip()
            if line and not re.match(r"(?:echo|printf|cat)\b", line):
                lines.append(line)
        return lines

    program = r"review_policy\.py"
    if ledger_parts:
        program += "|" + re.escape("/".join(ledger_parts))
    writes = writes or any(re.search(program, line) for line in code(lease) + code(verb))
    return resets, writes


def review_policy_document():
    C = "documentation"
    resets, writes = unpark_in_the_code()
    if not check(resets and not writes, C,
                 "the code: `unpark` resets the lease's retryCount and does not touch the review ledger",
                 "the code no longer does what this criterion's sentence says (unpark resets the "
                 "repair count: %s; the unpark path writes the review ledger: %s). The sentence "
                 "docs/review-policy.md must carry has to be ruled again" % (resets, writes)):
        return
    blocks = [block for block in parse_blocks(read("docs/review-policy.md"))
              if re.search(r"\bunpark\b", block["text"])]
    if not check(bool(blocks), C,
                 "docs/review-policy.md names `unpark`",
                 "docs/review-policy.md must say what `unpark` restores; it never names `unpark`"):
        return


# --------------------------------------------------------------------------
# documentation: the README's further mismatches that a machine can check
# --------------------------------------------------------------------------

def readme_further_mismatches(readme, blocks):
    C = "documentation"
    # The modules the README lists, against the modules that ship.
    shipped = sorted(name for name in os.listdir(os.path.join(ROOT, "singular-ext")) if name.endswith(".sh"))
    listings = [block for block in blocks
                if block["kind"] == "fence" and re.search(r"^\s*singular-ext/\s*$", block["text"], re.M)]
    listed = sorted(set(name for block in listings
                        for name in re.findall(r"^\s+([A-Za-z0-9_.-]+\.sh)\b", block["text"], re.M)))
    check(not listings or listed == shipped, C,
          "README's listing of singular-ext/ names the modules that ship, or is cut",
          "README's listing of singular-ext/ names %s; the folder ships %s. Match it, or cut the listing"
          % (", ".join(listed) or "nothing", ", ".join(shipped)))

    # The promotion canary, tied to releases that are long out.
    version = read("VERSION").strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise CodeFact("VERSION does not hold a release number")
    stale = []
    for number, line in enumerate(readme.splitlines(), 1):
        if "field-report-canary" not in line or not re.search(r"promot|releas|requir|before|must|ship", line, re.I):
            continue
        old = [found for found in re.findall(r"(?<![\w.])\d+\.\d+\.\d+(?![\w.]*\d)", line)
               if version_tuple(found) < version_tuple(version)]
        if old:
            stale.append("line %d: %s" % (number, ", ".join(old)))
    check(not stale, C,
          "README ties the field-report canary to no release older than VERSION (%s)" % version,
          "README says the field-report canary is required before releases that are older than "
          "VERSION (%s): %s. Match it to the code, or cut it" % (version, "; ".join(stale)))


# --------------------------------------------------------------------------

def main():
    try:
        readme = read("README.md")
        blocks = parse_blocks(readme)
    except FileNotFoundError:
        readme = blocks = None
    for section, criterion, arguments in (
            (readme_settings, "readme", (readme, blocks)),
            (readme_push_and_launcher, "push-defaults", (readme, blocks)),
            (providers_document, "documentation", ()),
            (review_policy_document, "documentation", ()),
            (readme_further_mismatches, "documentation", (readme, blocks))):
        if arguments and blocks is None:
            bad(criterion, "README.md is missing: nothing of this criterion can be judged in it")
            continue
        try:
            section(*arguments)
        except CodeFact as error:
            print("ERROR %s: the test could not read a fact it needs: %s" % (section.__name__, error))
            return 3
        except FileNotFoundError as error:
            bad(criterion, "a file this test reads is missing: %s"
                % os.path.relpath(error.filename or "?", ROOT))
    failed = [result for result in results if not result[0]]
    print("")
    print("test-doc-contract-readme: %d assertions, %d passed, %d failed"
          % (len(results), len(results) - len(failed), len(failed)))
    return 1 if failed else 0


try:
    sys.exit(main())
except SystemExit:
    raise
except Exception:
    traceback.print_exc()
    print("ERROR the test itself failed; this is not a verdict on the documents")
    sys.exit(3)
PY
rc=$?

rm -rf "$tmp"
if [[ "$rc" -ne 0 ]]; then
  exit "$rc"
fi

echo "test-doc-contract-readme: ok"
if [[ -n "$rails_nonce" && -n "$rails_verdict_file" ]]; then
  printf '%s\n' "$rails_nonce" >"$rails_verdict_file"
fi
