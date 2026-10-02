#!/usr/bin/env bash
# Guard the clean Singular namespace: retired identity text and paths must not
# re-enter tracked or pending source files.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "$(git rev-parse --is-inside-work-tree 2>/dev/null || true)" != "true" ]]; then
  echo "Singular namespace guard requires a Git worktree" >&2
  exit 2
fi

legacy_left="glue"
legacy_right="run"
legacy_pattern="${legacy_left}.?${legacy_right}"
failures=""

while IFS= read -r -d '' path; do
  [[ -e "$path" || -L "$path" ]] || continue
  if printf '%s\n' "$path" | LC_ALL=C grep -Eqi "$legacy_pattern"; then
    failures+="retired identity in path: $path"$'\n'
  fi
  if [[ -L "$path" ]]; then
    link_target="$(readlink "$path" 2>/dev/null || true)"
    if printf '%s\n' "$link_target" | LC_ALL=C grep -Eqi "$legacy_pattern"; then
      failures+="retired identity in symlink target: $path -> $link_target"$'\n'
    fi
    continue
  fi
  [[ -f "$path" ]] || continue
  if LC_ALL=C grep -Iq . "$path" \
    && LC_ALL=C grep -Eqi "$legacy_pattern" "$path"; then
    failures+="retired identity in text: $path"$'\n'
  fi
done < <(git ls-files -co --exclude-standard -z)

[[ -x cli/singular ]] || failures+="missing executable cli/singular"$'\n'
[[ -f singular.config.json ]] || failures+="missing singular.config.json"$'\n'
[[ -f templates/singular.config.json ]] || failures+="missing template config"$'\n'
[[ -f .singular-version ]] || failures+="missing .singular-version"$'\n'
[[ -f plugin/scripts/singular_graph_server.py ]] || failures+="missing Singular console server"$'\n'

# Pin the Providers client to the exact raw-config singleton the server exposes.
# These checks inspect executable behavior/AST, not source-text counts: moving an
# expected literal into a comment must never make a broken route look covered.
if ! node --input-type=module <<'JS'
import fs from "node:fs";
import vm from "node:vm";

let source = fs.readFileSync("plugin/assets/providers/surface.js", "utf8");
source = source.replace(/^import .*;\s*$/gm, "");
source = source.replace(/export function /g, "function ");
source += "\nglobalThis.__activateProviders = setProvidersActive;";

const calls = [];
const context = vm.createContext({
  apiFetch: async (path) => {
    calls.push(path);
    return {
      ok: true,
      status: 200,
      json: async () => path === "/api/providers"
        ? { checkedAt: "2026-08-11T00:00:00Z", providers: [] }
        : { content: "{}" },
    };
  },
  isHistorical: () => false,
  document: { getElementById: () => null },
  window: {},
  MODEL_VOCABULARY: {},
  modelOptions: () => [],
  esc: String,
  escAttr: String,
  icon: () => "",
  relTime: () => "",
  toast: () => {},
  requestAnimationFrame: (fn) => fn(),
  setInterval: () => 0,
  clearInterval: () => {},
  fetch: async () => ({ ok: true, status: 200, json: async () => ({}) }),
  console,
});
new vm.Script(source, { filename: "providers/surface.js" }).runInContext(context);
context.__activateProviders(true);
const expected = "/api/raw/config/singular.config.json";
if (calls.filter((path) => path === expected).length !== 1) {
  throw new Error(`Providers did not execute exactly one ${expected} request: ${JSON.stringify(calls)}`);
}
JS
then
  failures+="Providers executable raw-config request drifted"$'\n'
fi

if ! python3 - <<'PY'
import ast
from pathlib import Path

tree = ast.parse(Path("plugin/scripts/singular_graph_server.py").read_text())
raw_assignment = next(
    node for node in tree.body
    if isinstance(node, (ast.Assign, ast.AnnAssign))
    and (
        isinstance(getattr(node, "target", None), ast.Name)
        and node.target.id == "RAW_ROOTS"
        or any(isinstance(t, ast.Name) and t.id == "RAW_ROOTS"
               for t in getattr(node, "targets", []))
    )
)
roots = ast.literal_eval(raw_assignment.value)
assert roots.get("config") == {"singleton": "singular.config.json"}

handler = next(node for node in tree.body
               if isinstance(node, ast.ClassDef) and node.name == "Handler")
methods = {node.name: node for node in handler.body
           if isinstance(node, ast.FunctionDef)}
# do_GET pins one configuration generation and delegates routing to _do_GET.
assert any(
    isinstance(node, ast.Call)
    and isinstance(node.func, ast.Attribute)
    and node.func.attr == "_do_GET"
    and isinstance(node.func.value, ast.Name)
    and node.func.value.id == "self"
    for node in ast.walk(methods["do_GET"])
)
do_get = methods["_do_GET"]
assert any(
    isinstance(node, ast.Call)
    and isinstance(node.func, ast.Attribute)
    and node.func.attr == "startswith"
    and isinstance(node.func.value, ast.Name)
    and node.func.value.id == "route"
    and len(node.args) == 1
    and isinstance(node.args[0], ast.Constant)
    and node.args[0].value == "/api/raw/"
    for node in ast.walk(do_get)
)
assert any(
    isinstance(node, ast.Subscript)
    and isinstance(node.value, ast.Name)
    and node.value.id == "route"
    and isinstance(node.slice, ast.Slice)
    and isinstance(node.slice.lower, ast.Call)
    and isinstance(node.slice.lower.func, ast.Name)
    and node.slice.lower.func.id == "len"
    and len(node.slice.lower.args) == 1
    and isinstance(node.slice.lower.args[0], ast.Constant)
    and node.slice.lower.args[0].value == "/api/raw/"
    for node in ast.walk(do_get)
)
PY
then
  failures+="console executable raw-config route/singleton drifted"$'\n'
fi

if [[ -n "$failures" ]]; then
  printf '%s' "$failures" >&2
  exit 1
fi

echo "PASS: Singular namespace is exclusive"
