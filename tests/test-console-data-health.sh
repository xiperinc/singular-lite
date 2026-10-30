#!/usr/bin/env bash
set -euo pipefail

# 0.23.5: the console page must never sit on "loading…" or on old numbers
# without saying so. The logic that decides ok / HTTP error / server gone /
# stale, retries with backoff and announces recovery lives in
# plugin/assets/core/api.js, which is import-free and DOM-free so it can be
# asserted under bare `node --test` (tests/console/api_health.test.mjs). This
# wrapper runs that suite and guards the wiring a unit test cannot see: the
# banner element exists, the painter is booted before the first fetch, and no
# surface went back to a bare "loading …" string for its first paint.
# Without node the suite skips — the engine stays testable with no JS toolchain.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-console-data-health.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS="$ENGINE_HOME/plugin/assets"
SUITE="$ENGINE_HOME/tests/console/api_health.test.mjs"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$ASSETS/core/api.js" && -f "$ASSETS/core/health.js" ]] || fail "core/api.js or core/health.js missing"

# --- static wiring ------------------------------------------------------------
if grep -Eq '^import[[:space:]]' "$ASSETS/core/api.js"; then
  fail "core/api.js must stay import-free (every module imports it; it must load under bare node)"
fi
grep -q 'id="conn-banner"' "$ASSETS/index.html" || fail "index.html has no #conn-banner"
grep -q 'data-api-retry' "$ASSETS/index.html" || fail "#conn-banner has no Retry button"
grep -q 'initHealth()' "$ASSETS/main.js" || fail "main.js does not boot core/health.js"
init_line="$(grep -n 'initHealth()' "$ASSETS/main.js" | head -1 | cut -d: -f1)"
start_line="$(grep -n '^start()' "$ASSETS/main.js" | head -1 | cut -d: -f1)"
[[ -n "$start_line" && "$init_line" -lt "$start_line" ]] \
  || fail "initHealth() must run before start() so the first failed fetch is already painted"
for f in home/surface.js providers/surface.js plan/lens_timeline.js; do
  grep -q 'loadingHtml(' "$ASSETS/$f" || fail "$f does not use loadingHtml() for its first paint"
done
if grep -n 'loading digest…' "$ASSETS/home/surface.js"; then
  fail "home/surface.js renders a bare 'loading digest…' again (it would show forever when reads fail)"
fi
# Every polled read must go through apiFetch, or its failures are invisible to
# the store. Deliberate exceptions: the settings/ask/report POSTs (writes are never
# "refresh failed") and the dock's quiet 5-minute codex-quota cell.
stray="$(grep -rnE '(^|[^A-Za-z.])fetch\(' "$ASSETS" --include='*.js' \
  | grep -v '/core/api.js:' | grep -v '/core/dock.js:' \
  | grep -vE 'fetch\("/api/(settings|ask|report)"' || true)"
[[ -z "$stray" ]] || fail "a read bypasses apiFetch (its failures would not reach the banner): $stray"

# --- behaviour ----------------------------------------------------------------
command -v node >/dev/null 2>&1 || { echo "SKIP: node not found (static wiring checks passed)"; exit 0; }
[[ -f "$SUITE" ]] || fail "suite not present: $SUITE"
if ! out="$(node --test "$SUITE" 2>&1)"; then
  printf '%s\n' "$out" >&2
  fail "node --test api_health.test.mjs"
fi
grep -Eq '(^|[[:space:]])fail 0[[:space:]]*$' <<<"$out" || fail "unexpected node --test summary: $out"
grep -q "recovers without anyone polling" <<<"$out" || fail "the self-retry test did not run: $out"

printf '%s\n' "$out" | tail -8
echo "PASS: test-console-data-health.sh"
