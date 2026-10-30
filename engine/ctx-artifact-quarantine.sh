#!/usr/bin/env bash
# ctx-artifact-quarantine.sh — quarantine-on-hit containment for durable context
# artifacts (stage artifact-secret-scan, layer engine_runtime). Sourced exactly
# once by the context module loader block in lib.sh (it matches the ctx-*.sh
# glob). This file defines a PURE, present-but-uncalled helper: no existing
# engine/CLI/driver path invokes it, so with it sourced the engine stays
# byte-identical to prior behavior. The finalize-site hook that fires quarantine
# is a separate later slice and is OUT OF SCOPE here.
#
# singular_ctx_artifact_quarantine <run_dir>
#
# Enumerates the durable context artifacts by REUSING the integrated enumerator
# (singular_ctx_artifact_scan_paths) and the shared secret patterns
# (singular_secret_scan_patterns). For every artifact whose content matches a
# secret pattern it:
#   1. renames the artifact to `<path>.quarantined` — the content is PRESERVED
#      under the new name (never deleted), so forensic evidence is retained;
#   2. appends exactly one `ctx.artifact_secret` event recording the artifact
#      path and the matched pattern label; and
#   3. leaves the task outcome alone.
# It is NON-BLOCKING: it returns success (exit 0) even when it quarantines hits,
# unlike detection-mode scan which fails closed. Clean artifacts are left
# byte-for-byte untouched (not renamed, no event). Already-quarantined paths
# (suffix `.quarantined`) are skipped. Exit 2 only on genuine misuse (the
# artifacts path is not a directory, or a required helper is unavailable).
singular_ctx_artifact_quarantine() {
  local run_dir="$1"
  [[ -n "$run_dir" && -d "$run_dir" ]] || {
    echo "artifact-quarantine: artifacts path is not a directory: $run_dir" >&2
    return 2
  }
  if [[ "$(type -t singular_ctx_artifact_scan_paths)" != "function" ]]; then
    echo "artifact-quarantine: internal error: artifact enumerator unavailable" >&2
    return 2
  fi
  if [[ "$(type -t singular_secret_scan_patterns)" != "function" ]]; then
    echo "artifact-quarantine: internal error: secret patterns unavailable" >&2
    return 2
  fi

  local file label regex
  while IFS= read -r file; do
    [[ -n "$file" && -f "$file" ]] || continue
    # Never re-process an already-quarantined artifact.
    case "$file" in *.quarantined) continue ;; esac
    while IFS="$(printf '\t')" read -r label regex; do
      [[ -n "$label" && -n "$regex" ]] || continue
      # -a: treat as text; -e: patterns beginning with '-' are not parsed as flags.
      if LC_ALL=C grep -qaE -e "$regex" "$file" 2>/dev/null; then
        # Rename (content preserved under `.quarantined`; never deleted), then
        # record one event. First matching pattern wins per artifact.
        mv -f -- "$file" "$file.quarantined"
        singular_append_event "ctx.artifact_secret" \
          "quarantined durable context artifact matching secret pattern" \
          "{\"artifact\":\"$file\",\"pattern\":\"$label\"}"
        break
      fi
    done < <(singular_secret_scan_patterns)
  done < <(singular_ctx_artifact_scan_paths "$run_dir" | sort -u)

  return 0
}
