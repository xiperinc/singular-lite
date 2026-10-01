#!/usr/bin/env bash
# Covers the FOURTH slice of the OPTIONAL authored-knowledge manifest ingestion
# leaf (stage S5-routing, node `rehydrate-path`, layer engine_runtime).
# `engine/ctx-rehydrate-authored-config.sh` ships a PURE, read-only,
# present-but-uncalled config-gated entry point over the integrated render /
# manifest composers (TASK-0060):
#
#   singular_ctx_rehydrate_authored_config_render   [trigger ...]
#   singular_ctx_rehydrate_authored_config_manifest [trigger ...]
#
# Each emits the authored packet section / manifest entries ONLY when
# SINGULAR_CTX_MANIFEST=1 AND singular.config.json declares a readable
# `contextManifest` path — resolving that path and delegating to
# `singular_ctx_rehydrate_authored_render <resolved> [trigger ...]` /
# `singular_ctx_rehydrate_authored_manifest <resolved> [trigger ...]`. Any unmet
# precondition (flag off, field absent, path missing/unreadable) yields empty
# output. Pure / read-only / deterministic / fail-soft: mutates nothing on disk
# and never exits non-zero on well-formed input.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- Authored-knowledge manifest fixture ------------------------------------
# Entries in NON-sorted id order; trigger context under test is `implement`.
#   zeta-body   body   load-when [implement]  current   -> KEEP
#   alpha-body  body   load-when [implement]  current   -> KEEP
#   plan-only   body   load-when [planner]    current   -> DROP (trigger-mismatch)
manifest="$tmp/authored-manifest.json"
cat >"$manifest" <<'JSON'
{
  "schema": "singular.orchestration.authored-knowledge-manifest.v0",
  "entries": [
    { "id": "zeta-body",  "body": "AUTHORED BODY zeta",  "load-when": ["implement"], "freshness": "current" },
    { "id": "plan-only",  "body": "planner body",        "load-when": ["planner"],   "freshness": "current" },
    { "id": "alpha-body", "body": "AUTHORED BODY alpha", "load-when": ["implement"], "freshness": "current" }
  ]
}
JSON

# --- Fixture config declaring an ABSOLUTE contextManifest path ---------------
config_abs="$tmp/singular.config.json"
cat >"$config_abs" <<JSON
{ "contextManifest": "$manifest" }
JSON

# --- Fixture config declaring a RELATIVE contextManifest path ---------------
# Resolved against the config file's own directory (== \$tmp here).
config_rel="$tmp/cfg-rel/singular.config.json"
mkdir -p "$tmp/cfg-rel"
cp "$manifest" "$tmp/cfg-rel/authored-manifest.json"
cat >"$config_rel" <<'JSON'
{ "contextManifest": "authored-manifest.json" }
JSON

# --- Fixture config with NO contextManifest field ---------------------------
config_absent="$tmp/cfg-absent.json"
cat >"$config_absent" <<'JSON'
{ "targetBranch": "main" }
JSON

# --- Fixture config pointing at a MISSING manifest --------------------------
config_missing="$tmp/cfg-missing.json"
cat >"$config_missing" <<JSON
{ "contextManifest": "$tmp/does-not-exist.json" }
JSON

# Snapshot the on-disk tree so we can prove the entry point is read-only.
tree_hash() {
  find "$tmp" -type f -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}'
}
before_hash="$(tree_hash)"

# Invoke the config-gated entry point with an explicit flag + config file.
#   $1 = SINGULAR_CTX_MANIFEST value (empty string => unset)
#   $2 = fn suffix: render|manifest
#   $3 = SINGULAR_JSON_CONFIG_FILE
#   $4.. = triggers
cfg_call() {
  local flag="$1" suffix="$2" cfgfile="$3"; shift 3
  if [[ -n "$flag" ]]; then
    SINGULAR_CTX_MANIFEST="$flag" SINGULAR_JSON_CONFIG_FILE="$cfgfile" \
      bash -c 'source "'"$LIB"'"; singular_ctx_rehydrate_authored_config_'"$suffix"' "$@"' _ "$@"
  else
    SINGULAR_JSON_CONFIG_FILE="$cfgfile" \
      bash -c 'unset SINGULAR_CTX_MANIFEST; source "'"$LIB"'"; singular_ctx_rehydrate_authored_config_'"$suffix"' "$@"' _ "$@"
  fi
}

# Direct delegation target (the thing config_* must equal when armed+configured).
direct_call() {
  local suffix="$1" mpath="$2"; shift 2
  bash -c 'source "'"$LIB"'"; singular_ctx_rehydrate_authored_'"$suffix"' "$@"' _ "$mpath" "$@"
}

nonblank() { [[ -n "${1//[$'\n' ]/}" ]]; }

# --- Case 1: gate OFF (unset / != 1) emits nothing even with valid config ---
for suffix in render manifest; do
  out="$(cfg_call "" "$suffix" "$config_abs" implement)" \
    || fail "case1: $suffix exited non-zero with flag unset"
  nonblank "$out" && fail "case1: $suffix emitted output with SINGULAR_CTX_MANIFEST unset. got:[$out]"

  out="$(cfg_call 0 "$suffix" "$config_abs" implement)" \
    || fail "case1: $suffix exited non-zero with flag=0"
  nonblank "$out" && fail "case1: $suffix emitted output with SINGULAR_CTX_MANIFEST=0. got:[$out]"

  out="$(cfg_call 2 "$suffix" "$config_abs" implement)" \
    || fail "case1: $suffix exited non-zero with flag=2"
  nonblank "$out" && fail "case1: $suffix emitted output with SINGULAR_CTX_MANIFEST=2. got:[$out]"
done

# --- Case 2: armed but contextManifest absent / path missing -> nothing -----
for cfg in "$config_absent" "$config_missing"; do
  for suffix in render manifest; do
    out="$(cfg_call 1 "$suffix" "$cfg" implement)" \
      || fail "case2: $suffix exited non-zero (cfg=$cfg)"
    nonblank "$out" \
      && fail "case2: $suffix emitted output for cfg=$cfg. got:[$out]"
  done
done

# --- Case 3: armed + configured -> delegation fidelity ----------------------
# render
got="$(cfg_call 1 render "$config_abs" implement)" || fail "case3: config render non-zero"
want="$(direct_call render "$manifest" implement)"  || fail "case3: direct render non-zero"
[[ "$got" == "$want" ]] \
  || fail "case3: config render != direct render.\ngot:[$got]\nwant:[$want]"
nonblank "$got" || fail "case3: armed render produced no output (fixture sanity)."
grep -q '=== authored:alpha-body ===' <<<"$got" \
  || fail "case3: expected authored:alpha-body section. got:[$got]"

# manifest
got="$(cfg_call 1 manifest "$config_abs" implement)" || fail "case3: config manifest non-zero"
want="$(direct_call manifest "$manifest" implement)"  || fail "case3: direct manifest non-zero"
[[ "$got" == "$want" ]] \
  || fail "case3: config manifest != direct manifest.\ngot:[$got]\nwant:[$want]"
python3 -c 'import json,sys; ids=[s["id"] for s in json.loads(sys.argv[1])["sources"]]; assert ids==["alpha-body","zeta-body"], ids' "$got" \
  || fail "case3: unexpected manifest ids. got:[$got]"

# --- Case 4: relative contextManifest resolves against config dir -----------
resolved_rel="$tmp/cfg-rel/authored-manifest.json"
got="$(cfg_call 1 render "$config_rel" implement)" || fail "case4: config render (rel) non-zero"
want="$(direct_call render "$resolved_rel" implement)" || fail "case4: direct render (rel) non-zero"
[[ "$got" == "$want" ]] \
  || fail "case4: relative-path render != direct render on resolved path.\ngot:[$got]\nwant:[$want]"
got="$(cfg_call 1 manifest "$config_rel" implement)" || fail "case4: config manifest (rel) non-zero"
want="$(direct_call manifest "$resolved_rel" implement)" || fail "case4: direct manifest (rel) non-zero"
[[ "$got" == "$want" ]] \
  || fail "case4: relative-path manifest != direct manifest on resolved path."

# --- Case 5: trigger passthrough (planner trigger changes selection) --------
# With the `planner` trigger, plan-only becomes eligible and the implement-only
# entries drop — config_* must reflect the delegated trigger, not a fixed one.
got="$(cfg_call 1 manifest "$config_abs" planner)" || fail "case5: config manifest (planner) non-zero"
want="$(direct_call manifest "$manifest" planner)"  || fail "case5: direct manifest (planner) non-zero"
[[ "$got" == "$want" ]] || fail "case5: trigger not passed through to delegate."
python3 -c 'import json,sys; ids=[s["id"] for s in json.loads(sys.argv[1])["sources"]]; assert ids==["plan-only"], ids' "$got" \
  || fail "case5: planner trigger selection wrong. got:[$got]"

# --- Case 6: determinism -----------------------------------------------------
a="$(cfg_call 1 render "$config_abs" implement)"
b="$(cfg_call 1 render "$config_abs" implement)"
[[ "$a" == "$b" ]] || fail "case6: config render non-deterministic."
a="$(cfg_call 1 manifest "$config_abs" implement)"
b="$(cfg_call 1 manifest "$config_abs" implement)"
[[ "$a" == "$b" ]] || fail "case6: config manifest non-deterministic."

# --- Case 7: missing / unreadable config file -> fail-soft, nothing ---------
# lib.sh refuses a missing *selected* JSON config at source time (pinned by
# test-config-loader), so the vanished file is pointed at after sourcing: this
# case is the entry point's own fail-soft, e.g. a config removed mid-run.
cfg_call_vanished() {
  local suffix="$1" cfgfile="$2"; shift 2
  SINGULAR_CTX_MANIFEST=1 CFG="$cfgfile" \
    bash -c 'source "'"$LIB"'"; SINGULAR_JSON_CONFIG_FILE="$CFG"; singular_ctx_rehydrate_authored_config_'"$suffix"' "$@"' _ "$@"
}
for suffix in render manifest; do
  out="$(cfg_call_vanished "$suffix" "$tmp/no-such-config.json" implement)" \
    || fail "case7: $suffix exited non-zero on missing config file"
  nonblank "$out" && fail "case7: $suffix emitted output on missing config. got:[$out]"
done

# --- Case 8: purity / read-only ---------------------------------------------
after_hash="$(tree_hash)"
[[ "$before_hash" == "$after_hash" ]] || fail "case8: entry point mutated the on-disk tree."

echo "ctx-rehydrate-authored-config tests passed"
