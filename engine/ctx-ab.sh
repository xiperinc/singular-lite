#!/usr/bin/env bash
# ctx-ab.sh — deterministic per-task A/B arm assignment behind SINGULAR_CTX_AB.
#
# Auto-sourced by the ctx-loader block in lib.sh (engine/ctx-*.sh). Defines new
# functions only; NO existing engine path invokes them, so with this file
# present-but-uncalled the engine is byte-identical to prior behavior. Later
# context module stages key their own knobs off the assigned arm; this slice
# only assigns and (when enabled) records it.
#
# Knob: SINGULAR_CTX_AB (default OFF). Unset or "0" -> assignment still maps a
# task id to an arm but emits NO event and touches nothing else. "1" -> the
# assignment is recorded as exactly one ctx.arm_assigned event per call.
#
# Public entry points:
#   singular_ctx_ab_arm_for <task_id>
#     Pure: print the arm ("A" or "B") for a task id. Deterministic and
#     machine-independent — derived from a stable content hash (SHA-256, or
#     cksum where no SHA tool exists) reduced modulo 2. Never uses $RANDOM or any
#     process/host-specific source, so the same id yields the same arm across
#     repeated calls, separate processes, and different machines. No side effects.
#   singular_ctx_ab_assign <task_id>
#     Assign + record. Prints the arm to stdout. When SINGULAR_CTX_AB=1, appends
#     one ctx.arm_assigned event via singular_append_event whose data carries the
#     task id and the assigned arm. When the knob is unset or 0, emits nothing.

# Map a task id to an arm in {A,B} via a stable content hash of the id.
singular_ctx_ab_arm_for() {
  local task_id="$1" hash last
  if command -v sha256sum >/dev/null 2>&1; then
    hash="$(printf '%s' "$task_id" | sha256sum | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    hash="$(printf '%s' "$task_id" | shasum -a 256 | awk '{print $1}')"
  else
    # POSIX fallback: cksum's CRC is deterministic and machine-independent.
    hash="$(printf '%s' "$task_id" | cksum | awk '{print $1}')"
  fi
  # Reduce the hash mod 2 via the parity of its last (hex or decimal) digit.
  last="${hash: -1}"
  if (( 16#$last % 2 == 0 )); then
    printf 'A'
  else
    printf 'B'
  fi
}

# Assign an arm and, when SINGULAR_CTX_AB=1, record it as one ctx.arm_assigned
# event. Prints the arm to stdout regardless of the knob.
singular_ctx_ab_assign() {
  local task_id="$1" arm
  arm="$(singular_ctx_ab_arm_for "$task_id")"
  if [[ "${SINGULAR_CTX_AB:-0}" == "1" ]]; then
    singular_append_event "ctx.arm_assigned" "ab arm assigned" \
      "{\"taskId\":\"$task_id\",\"arm\":\"$arm\"}"
  fi
  printf '%s' "$arm"
}
