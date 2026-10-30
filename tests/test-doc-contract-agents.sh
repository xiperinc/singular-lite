#!/usr/bin/env bash
# Document contract, AGENTS.md.
# Reads code and documents as data; never executes the engine.
# agents: language names, test command, tracked local links, absence of the
# literals "Go orchestration" and "probation", engine-dir and state names.
# push-defaults: auto command, launchd launcher, push variable and code-derived off
# value. The four code premises still check that their source facts hold.
#
# Not judged here: a reader checks
# - agents: a fix lands with a test seen to fail on the unfixed code.
# - agents: nothing restores or checks out files in place in a mutation script.
# - agents: SINGULAR_ENGINE_DIR is not the install path; fixtures ignore the
#   state folder. Only the two names' presence is judged here.
# - agents: expired probation and dated governance are gone beyond the banned
#   literal; language and test-command mentions describe the engine correctly.
# - push-defaults: auto and the launcher push unless the variable turns pushing off;
#   a command run on its own does not push. No sentence polarity is judged.
#
# Every assertion runs; exit 1 means assertions failed, exit 2 a missing root
# or tracked-file inventory. Each failure names its criterion. Facts are read
# at runtime; no default value is copied from the code into this test.
# The verdict-file rule of the build's tool: read the nonce and the path into
# this script's own variables and drop them from the environment before
# anything else runs. The nonce is written back only as the very last act, after
# every assertion passed. When the tool is not the caller both are empty and
# the step is skipped.
verdict_nonce="${RAILS_NONCE:-}"
verdict_file="${RAILS_VERDICT_FILE:-}"
unset RAILS_NONCE RAILS_VERDICT_FILE

set -euo pipefail

# Derive only the expected parent of tests/, never search ancestor folders.
# Shell parameter expansion avoids an external dirname dependency.
script_path="${BASH_SOURCE[0]}"
case "$script_path" in
  */*) script_dir="${script_path%/*}" ;;
  *) script_dir="." ;;
esac
if ! ROOT="$(cd -- "$script_dir/.." 2>/dev/null && pwd -P)" ||
   [[ ! -f "$ROOT/tests/test-doc-contract-agents.sh" ]] ||
   [[ ! -e "$ROOT/.git" ]]; then
  echo "FAIL  agents: repository root unavailable (expected this test and .git)" >&2
  exit 2
fi

status=0
# -I keeps the working directory and the user's site folder off the import
# path, so nothing in the tree under judgment is loaded into the judge.
python3 -I -B - "$ROOT" <<'PY' || status=$?
import fnmatch
import os
import posixpath
import re
import subprocess
import sys
import urllib.parse

ROOT = sys.argv[1]
AGENTS = "AGENTS.md"

results = []


def check(criterion, what, ok, why=""):
    results.append((bool(ok), criterion, what, why))


def read(rel):
    try:
        with open(os.path.join(ROOT, rel), encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return None


# --------------------------------------------------------------------------
# Local links resolve only through tracked files that exist in this checkout.
# Missing git or a bad index is an error, never grounds to walk the disk.
# --------------------------------------------------------------------------
def repository_files():
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env["GIT_CEILING_DIRECTORIES"] = os.path.dirname(ROOT)
    try:
        done = subprocess.run(
            ["git", "-C", ROOT, "ls-files", "-z", "--cached"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, timeout=120,
        )
        if done.returncode == 0:
            names = [name for name in done.stdout.decode("utf-8", "replace").split("\0") if name]
            return {name for name in names if os.path.isfile(os.path.join(ROOT, name))}
    except (OSError, subprocess.SubprocessError):
        pass
    print("FAIL  agents: cannot read the repository's tracked-file inventory", file=sys.stderr)
    sys.exit(2)


FILES = repository_files()
FOLDERS = set()
for _name in FILES:
    _parts = _name.split("/")
    for _depth in range(1, len(_parts)):
        FOLDERS.add("/".join(_parts[:_depth]))
TOP = {name.split("/")[0] for name in FILES}


def resolves(rel):
    rel = posixpath.normpath(rel)
    if rel in ("", "."):
        return True
    if rel == ".." or rel.startswith("../"):
        return False
    return rel in FILES or rel in FOLDERS


# --------------------------------------------------------------------------
# A small reading of Markdown: fenced code and inline code spans.
# --------------------------------------------------------------------------
FENCE = re.compile(r"^\s{0,3}(`{3,}|~{3,})")
CODE_SPAN = re.compile(r"(?<!`)(`+)(?!`)(.+?)(?<!`)\1(?!`)")


class Doc:
    def __init__(self, name, text):
        self.name = name
        self.text = text
        self.lines = text.splitlines()
        self.fenced = []
        fence = None
        for line in self.lines:
            mark = FENCE.match(line)
            if fence is None:
                if mark:
                    fence = mark.group(1)[0]
                self.fenced.append(fence is not None)
            else:
                self.fenced.append(True)
                if mark and mark.group(1)[0] == fence and line.strip().strip("`~") == "":
                    fence = None

    def prose(self):
        """The text a reader takes as statements: no fenced code, no code
        spans. A command such as `bash tests/run.sh` names no language."""
        kept = []
        for index, line in enumerate(self.lines):
            if not self.fenced[index]:
                kept.append(CODE_SPAN.sub(" ", line))
        return "\n".join(kept)


def load(name):
    text = read(name)
    return None if text is None else Doc(name, text)


def standalone(value):
    """The value as a token of its own: `0` in `SINGULAR_PUSH=0` or "default to
    0.", never the 0 of 0.23 or of 10."""
    return re.compile(r"(?<![0-9A-Za-z_.])" + re.escape(value) + r"(?![0-9A-Za-z_]|\.[0-9])")


# --------------------------------------------------------------------------
# Facts, read from the code.
# --------------------------------------------------------------------------
LANGUAGE_BY_SUFFIX = {
    ".sh": "Bash", ".bash": "Bash", ".py": "Python", ".go": "Go",
    ".ts": "TypeScript", ".js": "JavaScript", ".mjs": "JavaScript",
    ".rb": "Ruby", ".rs": "Rust", ".pl": "Perl",
}
LANGUAGE_NAMED = {
    "Bash": re.compile(r"\bbash\b", re.I),
    "Python": re.compile(r"\bpython\b", re.I),
    "Go": re.compile(r"\bGo(?:lang)?\b"),
    "TypeScript": re.compile(r"\btypescript\b", re.I),
    "JavaScript": re.compile(r"\bjavascript\b|\bnode(?:\.js)?\b", re.I),
    "Ruby": re.compile(r"\bruby\b", re.I),
    "Rust": re.compile(r"\brust\b", re.I),
    "Perl": re.compile(r"\bperl\b", re.I),
}


def engine_languages():
    """Language -> number of source files under engine/ and cli/."""
    count = {}
    for name in sorted(FILES):
        if not name.startswith(("engine/", "cli/")):
            continue
        suffix = posixpath.splitext(name)[1].lower()
        language = LANGUAGE_BY_SUFFIX.get(suffix)
        if language is None and suffix == "":
            first = (read(name) or "").split("\n", 1)[0]
            if first.startswith("#!"):
                if re.search(r"\bbash\b", first):
                    language = "Bash"
                elif re.search(r"\bpython", first):
                    language = "Python"
        if language:
            count[language] = count.get(language, 0) + 1
    return count


def cli_facts():
    """The runner behind the test command and the commands the CLI dispatches
    to an engine script."""
    cli = read("cli/singular") or ""
    runner = None
    mark = re.search(r'^\s*(?:local\s+)?suite="\$home/([^"$]+)"', cli, re.M)
    if mark:
        runner = mark.group(1)
    has_test = re.search(r"^\s*test\)\s+\S", cli, re.M) is not None
    dispatch = {}
    for mark in re.finditer(r"^\s*([a-z][a-z0-9-]*)\)\s+run_engine\s+([A-Za-z0-9_.-]+\.sh)\b", cli, re.M):
        dispatch[mark.group(1)] = mark.group(2)
    return runner, has_test, dispatch


PUSH_EXPORT = re.compile(r'^\s*export\s+SINGULAR_PUSH="?\$\{SINGULAR_PUSH:[-=]([A-Za-z0-9]*)\}"?', re.M)
PUSH_DEFAULT = re.compile(r"\$\{SINGULAR_PUSH:[-=]([A-Za-z0-9]*)\}")
PUSH_ASSIGN = re.compile(r"^\s*(?:export\s+)?SINGULAR_PUSH=")


def push_facts(dispatch):
    """What the code does about pushing when SINGULAR_PUSH is unset: under
    `singular auto`, under the launchd launcher, and in a command run on its
    own. Returns the facts and the reason they cannot be used, if any."""
    facts = {"auto": None, "launchers": {}, "direct": {}, "on": set(), "off": None}
    script = dispatch.get("auto")
    if not script:
        return facts, "cli/singular no longer dispatches `auto` to an engine script"
    text = read("engine/" + script)
    if text is None:
        return facts, "engine/%s, which `singular auto` runs, is missing" % script
    mark = PUSH_EXPORT.search(text)
    facts["auto"] = (script, mark.group(1) if mark else None)

    for name in sorted(FILES):
        if name.startswith("templates/launchd/"):
            mark = PUSH_EXPORT.search(read(name) or "")
            if mark:
                facts["launchers"][name] = mark.group(1)

    # A command run on its own: every engine script the CLI dispatches, other
    # than the loop's, that reads the variable with a default of its own.
    for command, other in sorted(dispatch.items()):
        if other == script:
            continue
        body = read("engine/" + other) or ""
        for line in body.splitlines():
            if not PUSH_DEFAULT.search(line) or PUSH_ASSIGN.match(line):
                continue
            for mark in PUSH_DEFAULT.finditer(line):
                facts["direct"].setdefault(other, set()).add(mark.group(1))
            # The value that means "push": what the variable is compared with.
            for mark in re.finditer(r'\$\{SINGULAR_PUSH:[-=][A-Za-z0-9]*\}"?\s*==\s*"?([A-Za-z0-9]+)', line):
                facts["on"].add(mark.group(1))
            holder = re.match(r'^\s*(?:local\s+)?([A-Za-z_][A-Za-z0-9_]*)="?\$\{SINGULAR_PUSH:[-=]', line)
            if holder:
                compared = re.compile(r'"?\$\{?' + re.escape(holder.group(1)) + r'\}?"?\s*==\s*"?([A-Za-z0-9]+)')
                for mark in compared.finditer(body):
                    facts["on"].add(mark.group(1))

    if facts["auto"][1] is None:
        return facts, "engine/%s no longer exports a default for SINGULAR_PUSH" % script
    if not facts["launchers"]:
        return facts, "no launcher under templates/launchd/ exports a default for SINGULAR_PUSH"
    if not facts["direct"]:
        return facts, "no directly dispatched engine script reads SINGULAR_PUSH with a default"
    if len(facts["on"]) != 1:
        return facts, "the value that turns pushing on could not be read (found: %s)" % sorted(facts["on"])
    on = next(iter(facts["on"]))
    direct_values = set()
    for values in facts["direct"].values():
        direct_values |= values
    loop_values = {facts["auto"][1]} | set(facts["launchers"].values())
    if loop_values != {on}:
        return facts, ("the loop no longer pushes by default: `singular auto` defaults SINGULAR_PUSH to %r, "
                       "the launcher to %s, and pushing is on at %r"
                       % (facts["auto"][1], sorted(set(facts["launchers"].values())), on))
    if on in direct_values or len(direct_values) != 1:
        return facts, ("a command run on its own no longer leaves pushing off: defaults %s, on at %r"
                       % (sorted(direct_values), on))
    facts["off"] = next(iter(direct_values))
    return facts, ""


def lib_facts():
    """Whether SINGULAR_ENGINE_DIR is still a setting a caller can override,
    and the name of the state folder."""
    lib = read("engine/lib.sh") or ""
    overridable = re.search(r'^\s*SINGULAR_ENGINE_DIR="?\$\{SINGULAR_ENGINE_DIR:-', lib, re.M) is not None
    mark = re.search(r'^\s*SINGULAR_STATE_DIR="?\$\{SINGULAR_STATE_DIR:-\$\{?SINGULAR_ROOT\}?/([^}"/]+)/?\}', lib, re.M)
    return overridable, (mark.group(1) if mark else None)


# --------------------------------------------------------------------------
# agents: links. A local link is a Markdown link whose target is not a URL, or
# a code span that names a path of this repository (its first part is one of
# the repository's top-level names). A document outside the repository, named
# by a home or absolute path, cannot resolve for a reader of the repository.
# --------------------------------------------------------------------------
DOCUMENT_SUFFIXES = (".md", ".markdown", ".pdf", ".html", ".htm", ".rst")
MD_LINK = re.compile(r"!?\[(?:[^\]\\]|\\.)*\]\(\s*(<[^>]*>|[^)\s]+)(?:\s+(?:\"[^\"]*\"|'[^']*'))?\s*\)")
MD_REFERENCE = re.compile(r"^\s{0,3}\[[^\]]+\]:\s*(<[^>]*>|\S+)")
PLACEHOLDER = re.compile("[<>{}]|\\.\\.\\.|\u2026")


def repository_path_problem(path):
    """None when a path of this repository resolves, else the path."""
    path = re.split(r"[#:]", path, maxsplit=1)[0]
    if not path:
        return None
    parts = path.split("/")
    if PLACEHOLDER.search(path):
        literal = []
        for part in parts:
            if PLACEHOLDER.search(part) or re.search(r"[*?\[]", part):
                break
            literal.append(part)
        prefix = "/".join(literal)
        return None if resolves(prefix) else path
    if re.search(r"[*?\[]", path):
        pattern = posixpath.normpath(path)
        hit = any(fnmatch.fnmatchcase(name, pattern) for name in FILES) or \
            any(fnmatch.fnmatchcase(name, pattern) for name in FOLDERS)
        return None if hit else path
    return None if resolves(path) else path


def unresolved_links(doc):
    """(line number, what) for every local link that does not resolve."""
    problems = []
    doc_dir = posixpath.dirname(doc.name)
    for index, line in enumerate(doc.lines):
        if doc.fenced[index]:
            continue
        number = index + 1
        spans = [mark.group(2) for mark in CODE_SPAN.finditer(line)]
        bare = CODE_SPAN.sub(lambda mark: " " * len(mark.group(0)), line)

        targets = [mark.group(1) for mark in MD_LINK.finditer(bare)]
        reference = MD_REFERENCE.match(bare)
        if reference:
            targets.append(reference.group(1))
        for target in targets:
            target = target.strip().strip("<>")
            if not target or target.startswith("#") or target.startswith("//"):
                continue
            if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:", target):
                continue
            target = urllib.parse.unquote(re.split(r"[#?]", target, maxsplit=1)[0])
            if not target:
                continue
            if target.startswith("~"):
                problems.append((number, "a link to a path outside the repository"))
            elif target.startswith("/"):
                inside = target.lstrip("/")
                if inside.split("/")[0] not in TOP:
                    problems.append((number, "a link to a path outside the repository"))
                elif not resolves(inside):
                    problems.append((number, inside))
            else:
                inside = posixpath.normpath(posixpath.join(doc_dir, target))
                if not resolves(inside):
                    problems.append((number, inside))

        for span in spans:
            span = span.strip()
            if span.startswith(("~/", "/")):
                inside = span.lstrip("/")
                if span.startswith("/") and inside.split("/")[0] in TOP:
                    bad = repository_path_problem(inside)
                    if bad:
                        problems.append((number, bad))
                elif span.lower().rstrip("/").endswith(DOCUMENT_SUFFIXES):
                    problems.append((number, "a document outside the repository"))
                continue
            for token in span.split():
                token = token.strip("\"'()[],;").rstrip(".,:;")
                if not token or "=" in token or "$" in token or "://" in token or token.startswith("-"):
                    continue
                while token.startswith("./"):
                    token = token[2:]
                if "/" not in token or token.split("/")[0] not in TOP:
                    continue
                bad = repository_path_problem(token)
                if bad:
                    problems.append((number, bad))
    return problems


# ==========================================================================
# The assertions.
# ==========================================================================
agents = load(AGENTS)
missing = "AGENTS.md is missing"

# ---- facts from the code (these pass today and must keep passing) ---------
languages = engine_languages()
check("agents", "code: the engine's languages can be read from engine/ and cli/ (%s)"
      % ", ".join("%s: %d files" % item for item in sorted(languages.items())),
      bool(languages), "no source file with a known language under engine/ or cli/")

runner, has_test_command, dispatch = cli_facts()
check("agents", "code: cli/singular names the suite's runner and the runner exists (%s)" % runner,
      runner is not None and resolves(runner),
      "the runner behind `singular test` could not be read from cli/singular, or it is not in the repository")

engine_dir_overridable, state_folder = lib_facts()
check("agents", "code: engine/lib.sh lets a caller override SINGULAR_ENGINE_DIR and names the state folder (%s)" % state_folder,
      engine_dir_overridable and state_folder,
      "engine/lib.sh no longer shows SINGULAR_ENGINE_DIR as an overridable setting, or the state folder's name could not be read")

push, push_problem = push_facts(dispatch)
check("push-defaults", "code: `singular auto` and the launchd launcher turn pushing on when SINGULAR_PUSH is unset, "
      "and a command run on its own leaves it off",
      not push_problem,
      "%s. The criterion's sentence no longer matches the code: it and this test must be judged again" % push_problem)

# ---- agents: the language ---------------------------------------------------
if agents is None:
    check("agents", "AGENTS.md names the engine's languages", False, missing)
else:
    prose = agents.prose()
    unnamed = [language for language in sorted(languages) if not LANGUAGE_NAMED[language].search(prose)]
    check("agents", "AGENTS.md names the engine's languages (%s)" % ", ".join(sorted(languages)),
          languages and not unnamed,
          "AGENTS.md does not name, outside code, the engine's language: %s"
          % ", ".join(unnamed or ["(no language could be read)"]))

# ---- agents: no Go claim, no probation --------------------------------------
if agents is None:
    check("agents", 'AGENTS.md does not say "Go orchestration"', False, missing)
    check("agents", 'AGENTS.md does not contain "probation"', False, missing)
else:
    go_claim = "Go" not in languages and "Go orchestration" in " ".join(agents.text.split())
    check("agents", 'AGENTS.md does not say "Go orchestration"', not go_claim,
          'the engine holds no Go source, and AGENTS.md contains "Go orchestration"')
    probation = [str(index + 1) for index, line in enumerate(agents.lines) if re.search(r"probation", line, re.I)]
    check("agents", 'AGENTS.md does not contain "probation"', not probation,
          'AGENTS.md says "probation" at line %s' % ", ".join(probation))

# ---- agents: the test command -----------------------------------------------
if agents is None:
    check("agents", "AGENTS.md gives the test command", False, missing)
else:
    given = False
    if runner:
        given = re.search(r"(?<![\w/.-])(?:\./)?" + re.escape(runner) + r"(?![\w-])", agents.text) is not None
    if not given and has_test_command:
        given = re.search(r"\bsingular\s+test\b", agents.text) is not None
    check("agents", "AGENTS.md gives the test command", given,
          "AGENTS.md names neither the suite's runner (`bash %s`) nor `singular test`" % (runner or "tests/run.sh"))

# ---- agents: every local link resolves --------------------------------------
if agents is None:
    check("agents", "every local link in AGENTS.md resolves", False, missing)
else:
    broken = unresolved_links(agents)
    shown = "; ".join("line %d: %s" % item for item in broken[:12])
    if len(broken) > 12:
        shown += "; and %d more" % (len(broken) - 12)
    check("agents", "every local link in AGENTS.md resolves", not broken,
          "%d local link(s) in AGENTS.md do not resolve: %s" % (len(broken), shown))

# ---- agents: standing-rule names, not their meaning -------------------------
text = agents.text if agents is not None else ""
check("agents", "AGENTS.md names SINGULAR_ENGINE_DIR",
      engine_dir_overridable and re.search(r"\bSINGULAR_ENGINE_DIR\b", text),
      missing if agents is None else "AGENTS.md must name the code's SINGULAR_ENGINE_DIR setting")
check("agents", "AGENTS.md names the state folder (%s)" % state_folder,
      state_folder and re.search(r"(?<![\w/-])" + re.escape(state_folder) + r"(?![\w-])", text),
      missing if agents is None else "AGENTS.md must name the code's state folder (%s)" % state_folder)

# ---- push-defaults: literal names and value, anywhere in the document --------------
push_claims = [
    "AGENTS.md names `singular auto`",
    "AGENTS.md names the launchd launcher",
    "AGENTS.md names SINGULAR_PUSH and its off value",
]
if agents is None or push_problem:
    for claim in push_claims:
        check("push-defaults", claim, False, missing if agents is None else "not judged: the code facts could not be used")
else:
    auto_named = re.compile(r"\bsingular\s+auto\b|`auto(?:\s[^`]*)?`")
    check("push-defaults", push_claims[0], auto_named.search(text),
          "AGENTS.md does not name `singular auto`")
    launcher_names = [re.escape(posixpath.basename(name)) for name in push["launchers"]]
    launcher_named = re.compile(r"launchd|" + "|".join(launcher_names), re.I)
    check("push-defaults", push_claims[1], launcher_named.search(text),
          "AGENTS.md does not name the launchd launcher")
    check("push-defaults", push_claims[2],
          re.search(r"\bSINGULAR_PUSH\b", text) and standalone(push["off"]).search(text),
          "AGENTS.md must name SINGULAR_PUSH and the code's off value (%s)" % push["off"])

# ==========================================================================
# The report.
# ==========================================================================
failed = [row for row in results if not row[0]]
for ok, criterion, what, why in results:
    if ok:
        print("ok    %s: %s" % (criterion, what))
    else:
        print("FAIL  %s: %s" % (criterion, why or what))
by_criterion = {}
for _ok, criterion, _what, _why in failed:
    by_criterion[criterion] = by_criterion.get(criterion, 0) + 1
print("")
if failed:
    print("failing criteria: %s" % ", ".join("%s (%d)" % item for item in sorted(by_criterion.items())))
print("test-doc-contract-agents: %d passed, %d failed" % (len(results) - len(failed), len(failed)))
sys.exit(1 if failed else 0)
PY

if [[ "$status" -ne 0 ]]; then
  echo "test-doc-contract-agents: failed (criteria listed above)" >&2
  exit "$status"
fi

echo "PASS: test-doc-contract-agents"
# Last act: the verdict, only now that every assertion passed.
if [[ -n "$verdict_nonce" && -n "$verdict_file" ]]; then
  printf '%s\n' "$verdict_nonce" >"$verdict_file"
fi
