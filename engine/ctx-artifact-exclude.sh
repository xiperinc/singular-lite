#!/usr/bin/env bash
# ctx-artifact-exclude.sh — quarantine-aware exclusion filter for durable context
# artifacts (stage artifact-secret-scan, layer engine_runtime). Sourced exactly
# once by the context module loader block in lib.sh (it matches the ctx-*.sh
# glob). This file defines a PURE, read-only, present-but-uncalled helper: no
# existing engine/CLI/driver path invokes it, so with it sourced the engine
# stays byte-identical to prior behavior. The assembly wire-in that applies this
# filter is a separate later slice and is OUT OF SCOPE here.
#
# singular_ctx_artifact_exclude [path...]
#   (candidate paths may also be supplied one-per-line on stdin)
#
# Given a set of candidate artifact paths, drops every quarantined entry:
#   * any path ending in the fixed `.quarantined` suffix, and
#   * any original path whose `.quarantined` sibling exists on disk,
# and emits only the surviving safe paths on stdout, order-stable. This ensures
# a quarantined artifact can never reach a rendered prompt or rehydration packet.
# It is PURE and READ-ONLY: it inspects paths (and tests for `.quarantined`
# siblings) but never writes, renames, or deletes anything.
singular_ctx_artifact_exclude() {
  local path
  if [[ $# -gt 0 ]]; then
    for path in "$@"; do
      _singular_ctx_artifact_exclude_emit "$path"
    done
  else
    while IFS= read -r path; do
      _singular_ctx_artifact_exclude_emit "$path"
    done
  fi
}

# Internal: emit a single candidate iff it survives the quarantine filter.
_singular_ctx_artifact_exclude_emit() {
  local p="$1"
  [[ -n "$p" ]] || return 0
  # Drop the quarantined evidence file itself.
  case "$p" in *.quarantined) return 0 ;; esac
  # Drop an original whose `.quarantined` sibling exists.
  [[ -e "$p.quarantined" ]] && return 0
  printf '%s\n' "$p"
}
