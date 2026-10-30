#!/usr/bin/env bash
# Deterministically sample accepted changes for critic rechecks using the configured percentage.

singular_ctx_critic_recheck_bucket() {
  local id="$1" hash
  if command -v sha256sum >/dev/null 2>&1; then
    hash="$(printf '%s' "$id" | sha256sum | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    hash="$(printf '%s' "$id" | shasum -a 256 | awk '{print $1}')"
  else
    hash="$(printf '%s' "$id" | cksum | awk '{print $1}')"
  fi
  # Reduce to 0..99. Interpret the low 6 hex digits as a number, then mod 100.
  # A decimal cksum digit string is a valid hex string too, so this is stable
  # across all hash sources.
  local low="${hash: -6}"
  if [[ "$low" =~ ^[0-9a-fA-F]+$ ]]; then
    printf '%s' $(( 16#$low % 100 ))
  else
    printf '0'
  fi
}

# Exit 0 iff the id is sampled under SINGULAR_CRITIC_RECHECK_PCT, else 1. Pure /
# no side effects. Default 0 (OFF) never samples; 100 always; a mid value P
# samples the reproducible subset whose bucket < P; a non-numeric/garbage value
# is treated as 0 (fail-safe OFF).
singular_ctx_critic_recheck_should_sample() {
  local id="$1" pct="${SINGULAR_CRITIC_RECHECK_PCT:-0}" bucket
  [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
  (( pct <= 0 )) && return 1
  (( pct >= 100 )) && return 0
  bucket="$(singular_ctx_critic_recheck_bucket "$id")"
  (( bucket < pct )) && return 0
  return 1
}
