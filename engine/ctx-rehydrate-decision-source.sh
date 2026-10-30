#!/usr/bin/env bash
# ctx-rehydrate-decision-source.sh — pure, read-only decision-record extra-spec
# producer (stage S5-routing, node `rehydrate-path`, layer engine_runtime).
# Sourced exactly once by the context module loader block in lib.sh (it matches
# the ctx-*.sh glob). This file DEFINES a new function only; it is wired into the
# l1-drive.sh rehydrate call sites in this same slice, but is otherwise inert.
#
#   singular_ctx_rehydrate_decision_source [base_dir]
#
# The durable-artifact class `decision-record` — the stage file's enumerated
# "relevant decision records" — lives OUTSIDE run_dir, so the pure resolver
# singular_ctx_rehydrate_sources deliberately does NOT resolve it; instead it must
# be supplied by the caller as a class-tagged `extra-id=path` spec. This leaf is
# the single source of that spec: it prints exactly
#
#   decision-record=<base_dir>/docs/orchestration/decisions.md
#
# when that durable orchestration decision log EXISTS under base_dir (`-f`), and
# prints NOTHING otherwise. base_dir defaults to ${SINGULAR_ROOT:-.}. Its stdout is
# meant to be expanded as a trailing extra argument to singular_ctx_rehydrate_sources
# / singular_ctx_rehydrate_event_data at BOTH rehydrate sites, so the injected packet
# and the recorded manifest carry the SAME decision record (id + content hash).
#
# It performs NO quarantine filtering of its own: the assembler already composes
# singular_ctx_artifact_exclude over every spec, so a single quarantine authority is
# preserved and the leaf only names the candidate.
#
# Pure and READ-ONLY: it tests a path but never writes, renames, or deletes;
# appends no events; is deterministic across invocations; and never exits non-zero.
# It confers NO independence: the `rehydrate` strategy remains tainted per
# singular_ctx_route_strategy_tainted.

# singular_ctx_rehydrate_decision_source [base_dir]
singular_ctx_rehydrate_decision_source() {
  local base_dir="${1-}"
  [[ -n "$base_dir" ]] || base_dir="${SINGULAR_ROOT:-.}"

  local path="$base_dir/docs/orchestration/decisions.md"
  [[ -f "$path" ]] && printf 'decision-record=%s\n' "$path"
  return 0
}
