#!/usr/bin/env bash
# Covers the SIXTH and final strict-test-first slice of the OPTIONAL
# authored-knowledge manifest ingestion for DAG node `rehydrate-path` (stage
# S5-routing, layer engine_runtime): the strategy-event payload builder
# `engine/ctx-rehydrate-event.sh` records, ALONGSIDE the durable-artifact
# manifest, the config-gated authored-knowledge manifest entries — the recorded
# counterpart of the section the driver injects into the rehydration prompt.
#
#   singular_ctx_rehydrate_event_data \
#     <role> <task-id> <run-id> <attempt> <reason> <run_dir> [extra-id=path ...]
#
# The builder merges `singular_ctx_rehydrate_authored_config_manifest implement`
# (the SAME `implement` trigger the driver injects with) into the event's nested
# `manifest` under a distinguishable `authored` key, so the recorded authored
# entries match the injected authored section (consistency invariant). Each
# authored entry carries id + sha256 + class=authored-knowledge +
# authoritative=false and is NEVER recorded as authoritative / host-verified. The
# config gate internally checks SINGULAR_CTX_MANIFEST (default 0) and
# the OPTIONAL singular.config.json `contextManifest` field, so with either OFF it
# returns empty and nothing is merged (OFF-parity: byte-identical to the
# durable-only payload). This OPTIONAL feature is NOT part of the node's
# requiredCompletion and does NOT gate the node.
#
#   - ON (armed+configured): the event `manifest` carries an `authored` object
#     equal to the config-gated authored manifest for the same `implement`
#     trigger; every authored entry is {id, sha256, class:"authored-knowledge",
#     authoritative:false}.
#   - Durable sources unaffected: manifest.sources stay recorded
#     unchanged; authored entries are additive under their own key.
#   - Never authoritative: no authored entry is host-verified / authoritative.
#   - OFF-parity: with SINGULAR_CTX_MANIFEST unset, no authored entries merge and
#     the event data is byte-identical to the durable-only payload.
#   - Valid JSON: the merged event data parses as a single JSON object.
#   - Minimal delegation: the merge delegates into
#     singular_ctx_rehydrate_authored_config_manifest; no config/selection/render
#     logic is inlined into engine/ctx-rehydrate-event.sh.
#   - Pure / read-only: the builder mutates nothing on disk and appends no events.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export SINGULAR_ROOT="$tmp"

run_dir="$tmp/run-state/RUN-REHYDRATE-AUTHORED-EVENT"
mkdir -p "$run_dir"

# --- Durable artifact fixtures (subset of the resolver's classes) -----------
printf '{"task":"T"}\n'    >"$run_dir/packet.json"
printf '{"impl":"cap"}\n'  >"$run_dir/implementer-capsule.json"
printf '{"findings":[]}\n' >"$run_dir/findings-status.json"

# --- Authored-knowledge manifest fixture ------------------------------------
# Two implement-eligible body entries (KEEP) + one planner-only entry (DROP under
# the `implement` trigger the builder passes at merge time).
authored_manifest="$tmp/authored-manifest.json"
cat >"$authored_manifest" <<'JSON'
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
config="$tmp/singular.config.json"
cat >"$config" <<JSON
{ "contextManifest": "$authored_manifest" }
JSON

# Event builder invoked with an explicit gate flag + config file.
#   $1 = SINGULAR_CTX_MANIFEST value (empty string => unset)
#   $2 = SINGULAR_JSON_CONFIG_FILE
#   $3.. = event_data args
event_data() {
  local flag="$1" cfg="$2"; shift 2
  if [[ -n "$flag" ]]; then
    SINGULAR_CTX_MANIFEST="$flag" SINGULAR_JSON_CONFIG_FILE="$cfg" \
      bash -c 'source "'"$LIB"'"; singular_ctx_rehydrate_event_data "$@"' _ "$@"
  else
    SINGULAR_JSON_CONFIG_FILE="$cfg" \
      bash -c 'unset SINGULAR_CTX_MANIFEST; source "'"$LIB"'"; singular_ctx_rehydrate_event_data "$@"' _ "$@"
  fi
}

# The delegation target the merged `authored` block must equal (same trigger).
config_manifest() {
  local flag="$1" cfg="$2"; shift 2
  SINGULAR_CTX_MANIFEST="$flag" SINGULAR_JSON_CONFIG_FILE="$cfg" \
    bash -c 'source "'"$LIB"'"; singular_ctx_rehydrate_authored_config_manifest "$@"' _ "$@"
}

before_hash="$(find "$run_dir" -type f -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}')"

# --- Case 1: ON — authored entries recorded in the event manifest -----------
on="$(event_data 1 "$config" implementer T-1 R-1 2 window-pressure "$run_dir")" \
  || fail "case1: builder(ON) exited non-zero"

# Parses as a single JSON object (so append_event's json.loads keeps it
# structured, not a {"raw":…} fallback).
printf '%s' "$on" | python3 -c 'import json,sys; json.load(sys.stdin)' \
  || fail "case1: ON output is not a single valid JSON object"

# The event manifest carries a distinguishable `authored` block.
printf '%s' "$on" | python3 -c '
import json, sys
o = json.load(sys.stdin)
m = o["manifest"]
assert isinstance(m, dict), "manifest not a dict"
assert "authored" in m, "manifest.authored missing when armed+configured"
a = m["authored"]
srcs = a["sources"] if isinstance(a, dict) else a
ids = sorted(s["id"] for s in srcs)
assert ids == ["alpha-body", "zeta-body"], ids
for s in srcs:
    assert s["class"] == "authored-knowledge", s
    assert s["authoritative"] is False, s
    assert isinstance(s.get("sha256"), str) and s["sha256"], s
' || fail "case1: authored entries not recorded with id+sha256+class+authoritative"

# --- Case 2: consistency with injection (same `implement` trigger) ----------
# The recorded authored block equals singular_ctx_rehydrate_authored_config_manifest.
want_authored="$(config_manifest 1 "$config" implement)" \
  || fail "case2: config manifest delegate non-zero"
[[ -n "${want_authored//[$'\n' ]/}" ]] || fail "case2: fixture sanity — delegate produced nothing"

python3 -c '
import json, sys
on, want = sys.argv[1], sys.argv[2]
rec = json.loads(on)["manifest"]["authored"]
w = json.loads(want)
assert json.dumps(rec, sort_keys=True) == json.dumps(w, sort_keys=True), \
    "recorded authored != config_manifest implement\nrec:  %r\nwant: %r" % (rec, w)
' "$on" "$want_authored" \
  || fail "case2: recorded authored entries != injected authored manifest"

# --- Case 3: durable sources unaffected -------------------------------------
# manifest.sources are recorded unchanged vs the durable-only (OFF) payload.
off="$(event_data "" "$config" implementer T-1 R-1 2 window-pressure "$run_dir")" \
  || fail "case3: builder(OFF) exited non-zero"
on_sources="$(printf '%s' "$on"  | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["manifest"]["sources"], sort_keys=True))')"
off_sources="$(printf '%s' "$off" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["manifest"]["sources"], sort_keys=True))')"
[[ "$on_sources" == "$off_sources" ]] \
  || fail "case3: durable manifest.sources changed by the authored merge.
on:  $on_sources
off: $off_sources"

# --- Case 4: never authoritative --------------------------------------------
# No authored entry — and nothing under manifest.authored — is authoritative.
[[ "$on" != *'"authoritative":true'* ]] \
  || fail "case4: an authored entry was recorded as authoritative"

# --- Case 5: OFF-parity — byte-identical to the durable-only payload ---------
# With the gate unset, no authored entries merge and there is no `authored` key.
printf '%s' "$off" | python3 -c '
import json, sys
m = json.load(sys.stdin)["manifest"]
assert "authored" not in m, "authored merged even though gate is OFF"
assert sorted(m.keys()) == ["schema", "sources"], sorted(m.keys())
' || fail "case5: OFF payload is not the durable-only manifest"

# Gate=0 is also OFF and byte-identical to the unset run.
off0="$(event_data 0 "$config" implementer T-1 R-1 2 window-pressure "$run_dir")" \
  || fail "case5: builder(gate=0) exited non-zero"
[[ "$off0" == "$off" ]] || fail "case5: gate=0 payload != unset payload"

# --- Case 6: determinism -----------------------------------------------------
on2="$(event_data 1 "$config" implementer T-1 R-1 2 window-pressure "$run_dir")" \
  || fail "case6: builder(ON,2) exited non-zero"
[[ "$on" == "$on2" ]] || fail "case6: ON event data not byte-identical across runs"

# --- Case 7: armed but unconfigured -> OFF-parity (fail-soft) ---------------
# SINGULAR_CTX_MANIFEST=1 but the config declares no contextManifest field.
config_absent="$tmp/cfg-absent.json"
cat >"$config_absent" <<'JSON'
{ "targetBranch": "main" }
JSON
armed_absent="$(event_data 1 "$config_absent" implementer T-1 R-1 2 window-pressure "$run_dir")" \
  || fail "case7: builder(armed,absent) exited non-zero"
printf '%s' "$armed_absent" | python3 -c '
import json, sys
assert "authored" not in json.load(sys.stdin)["manifest"], "authored merged with no contextManifest field"
' || fail "case7: armed-but-unconfigured merged authored entries"

# --- Case 8: purity / read-only, no events appended -------------------------
after_hash="$(find "$run_dir" -type f -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}')"
[[ "$before_hash" == "$after_hash" ]] || fail "case8: builder mutated the source tree (not read-only)"
[[ ! -e "$tmp/.singular-state/events.ndjson" ]] \
  || fail "case8: builder appended events (should PRODUCE data only)"

echo "ctx-rehydrate-authored-event tests passed"
