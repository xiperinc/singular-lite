#!/usr/bin/env bash
set -uo pipefail

# O2 (0.5.0): console CLI lifecycle — one-shot JSON purity (banner must not
# leak into stdout), idempotent detached start via --ensure (url/pid files,
# health poll, pid reuse), --status exit codes (+ --json), --stop idempotence
# with file cleanup, stale-file recovery, the `singular status` console line, and
# the stable address (0.23.5): console.port survives --stop, a restart comes back
# on the same port, a port taken by another process falls back and updates the
# files, and SINGULAR_CONSOLE_PORT pins it.
# Hermetic: runs against a mktemp fixture repo with SINGULAR_ENGINE_HOME set to
# this checkout; every server started here is killed in the trap.

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SINGULAR="$ENGINE_HOME/cli/singular"
export SINGULAR_ENGINE_HOME="$ENGINE_HOME"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2' in: $1"; }

[[ -f "$SINGULAR" ]] || fail "cli/singular not present: $SINGULAR"
[[ -f "$ENGINE_HOME/plugin/scripts/singular_graph_server.py" ]] \
  || fail "console server not present in this checkout"

tmp="$(mktemp -d)"
root="$tmp/repo"

cleanup() {
  # Kill any console the test started (current pid file, then every pid this
  # test ever recorded) so no detached server outlives the suite.
  local p
  for p in "$root/.singular-state/console.pid" "$tmp"/pids/*; do
    [[ -f "$p" ]] || continue
    kill "$(tr -d '[:space:]' < "$p" 2>/dev/null)" 2>/dev/null || true
  done
  [[ -n "${squatter_pid:-}" ]] && kill "$squatter_pid" 2>/dev/null || true
  rm -rf "$tmp"
}
squatter_pid=""
trap cleanup EXIT
mkdir -p "$tmp/pids"
record_pid() { # remember a started server pid for the trap
  [[ -f "$root/.singular-state/console.pid" ]] \
    && cp "$root/.singular-state/console.pid" "$tmp/pids/$(date +%s%N 2>/dev/null || date +%s).$RANDOM"
}

# --- Fixture repo --------------------------------------------------------------
mkdir -p "$root/.singular-state" "$root/docs/orchestration/tasks" "$root/docs/orchestration/gates"
git -C "$root" init -q
git -C "$root" checkout -q -b main
git -C "$root" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
cat >"$root/singular.config.json" <<'EOF'
{"schemaVersion": "v0", "targetBranch": "main"}
EOF
cat >"$root/docs/orchestration/dag.v0.json" <<'EOF'
{"schema": "singular.orchestration.dag.v0",
 "nodes": [{"id": "M0.core", "stage": "M0", "area": "core", "layer": "scaffold",
            "kind": "build", "dependsOn": [], "requiredCompletion": "done"}]}
EOF
cd "$root"

# --- 1. one-shot purity: stdout is pure JSON (no banner, no port pick) ----------
snap="$("$SINGULAR" console --snapshot 2>/dev/null)" || fail "console --snapshot exited non-zero"
printf '%s' "$snap" | python3 -m json.tool >/dev/null \
  || fail "console --snapshot stdout is not valid JSON (banner leaked?)"
over="$("$SINGULAR" console --overview 2>/dev/null)" || fail "console --overview exited non-zero"
printf '%s' "$over" | python3 -m json.tool >/dev/null \
  || fail "console --overview stdout is not valid JSON"
[[ ! -f "$root/.singular-state/console.url" ]] \
  || fail "one-shot --snapshot must not write console.url"

# --- 2. --status before any server: not running, exit 1 -------------------------
if "$SINGULAR" console --status >"$tmp/status0.out" 2>&1; then
  fail "console --status should exit 1 when no console is running"
fi
assert_contains "$(cat "$tmp/status0.out")" "not running" "status-before-start"

# --- 3. --ensure cold start ------------------------------------------------------
url="$("$SINGULAR" console --ensure)" \
  || fail "console --ensure failed; log tail: $(tail -5 "$root/.singular-state/console.log" 2>/dev/null)"
record_pid
[[ "$url" == http://127.0.0.1:* ]] || fail "--ensure printed unexpected url: $url"
[[ -f "$root/.singular-state/console.url" ]] || fail "console.url not written"
[[ "$(head -1 "$root/.singular-state/console.url")" == "$url" ]] \
  || fail "console.url content does not match printed url"
[[ -f "$root/.singular-state/console.pid" ]] || fail "console.pid not written"
pid="$(tr -d '[:space:]' < "$root/.singular-state/console.pid")"
kill -0 "$pid" 2>/dev/null || fail "console.pid ($pid) is not alive"
port_file="$root/.singular-state/console.port"
[[ -f "$port_file" ]] || fail "console.port not written"
port="$(tr -d '[:space:]' < "$port_file")"
[[ "$url" == "http://127.0.0.1:$port" ]] || fail "console.port ($port) does not match url $url"
python3 -c 'import sys, urllib.request
urllib.request.urlopen(sys.argv[1].rstrip("/") + "/api/health", timeout=3)' "$url" \
  || fail "/api/health not answering at $url"

# --- 4. second --ensure is idempotent (same url, same pid) ----------------------
url2="$("$SINGULAR" console --ensure)" || fail "second --ensure failed"
[[ "$url2" == "$url" ]] || fail "second --ensure changed the url ($url -> $url2)"
pid2="$(tr -d '[:space:]' < "$root/.singular-state/console.pid")"
[[ "$pid2" == "$pid" ]] || fail "second --ensure restarted the server (pid $pid -> $pid2)"

# --- 5. --status while running: exit 0 + url; --json shape ----------------------
out="$("$SINGULAR" console --status)" || fail "console --status should exit 0 while running"
assert_contains "$out" "$url" "status-running"
outj="$("$SINGULAR" console --status --json)" || fail "console --status --json should exit 0"
printf '%s' "$outj" | python3 -c 'import json, sys
d = json.load(sys.stdin)
assert d["running"] is True, d
assert d["url"].startswith("http://127.0.0.1:"), d
assert isinstance(d["pid"], int), d' || fail "--status --json shape wrong: $outj"

# --- 6. singular status prints the console line while running --------------------
stat="$("$SINGULAR" status 2>/dev/null)" || fail "singular status failed"
assert_contains "$stat" "console: $url" "singular-status-console-line"

# --- 7. --stop: server gone, files removed, idempotent --------------------------
"$SINGULAR" console --stop 2>/dev/null || fail "console --stop exited non-zero"
[[ ! -f "$root/.singular-state/console.url" ]] || fail "console.url not removed by --stop"
[[ ! -f "$root/.singular-state/console.pid" ]] || fail "console.pid not removed by --stop"
[[ "$(tr -d '[:space:]' < "$port_file" 2>/dev/null)" == "$port" ]] \
  || fail "console.port must survive --stop (it is the address the next start reuses)"
sleep 0.5
kill -0 "$pid" 2>/dev/null && fail "server pid $pid still alive after --stop"
"$SINGULAR" console --stop 2>/dev/null || fail "second --stop (idempotent) exited non-zero"
if "$SINGULAR" console --status >/dev/null 2>&1; then
  fail "--status should exit 1 after --stop"
fi

# --- 8. stale-file recovery -------------------------------------------------------
# `singular status` flags a dead console; --ensure cleans the leftovers and starts fresh.
echo "http://127.0.0.1:1" > "$root/.singular-state/console.url"   # nothing listens on :1
echo "999999" > "$root/.singular-state/console.pid"               # never a live pid
stat2="$("$SINGULAR" status 2>/dev/null)" || fail "singular status failed on stale files"
assert_contains "$stat2" "console: stale (not running)" "singular-status-stale-line"
url3="$("$SINGULAR" console --ensure)" || fail "--ensure did not recover from stale files"
record_pid
[[ "$url3" != "http://127.0.0.1:1" ]] || fail "--ensure reused the stale url"
pid3="$(tr -d '[:space:]' < "$root/.singular-state/console.pid")"
kill -0 "$pid3" 2>/dev/null || fail "recovered console pid ($pid3) not alive"

# --- 9. stable address: a restart comes back on the same port ---------------------
[[ "$url3" == "$url" ]] || fail "restart moved the console ($url -> $url3); console.port was $port"
# Leave a connection in TIME_WAIT behind, then stop and start again immediately:
# the port probe must still call it free.
python3 -c 'import sys, urllib.request
urllib.request.urlopen(sys.argv[1] + "/api/health", timeout=3).read()' "$url3" \
  || fail "/api/health not answering at $url3"
"$SINGULAR" console --stop 2>/dev/null || fail "--stop before restart exited non-zero"
url4="$("$SINGULAR" console --ensure)" || fail "--ensure after --stop failed"
record_pid
[[ "$url4" == "$url" ]] || fail "stop-then-ensure moved the console ($url -> $url4)"
"$SINGULAR" console --stop 2>/dev/null || fail "--stop exited non-zero"

# --- 10. saved port taken by another process: fall back, update the files ---------
python3 -c 'import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(1)
print("ready", flush=True); time.sleep(60)' "$port" >"$tmp/squatter.out" 2>&1 &
squatter_pid=$!
for _ in $(seq 1 40); do grep -q ready "$tmp/squatter.out" 2>/dev/null && break; sleep 0.1; done
grep -q ready "$tmp/squatter.out" || fail "could not occupy port $port for the fallback case"
url5="$("$SINGULAR" console --ensure 2>"$tmp/ensure5.err")" \
  || fail "--ensure failed while the saved port was taken: $(cat "$tmp/ensure5.err")"
record_pid
[[ "$url5" != "$url" ]] || fail "--ensure claimed a port another process holds"
assert_contains "$(cat "$tmp/ensure5.err")" "in use" "taken-port-notice"
port5="$(tr -d '[:space:]' < "$port_file")"
[[ "$url5" == "http://127.0.0.1:$port5" ]] || fail "console.port ($port5) not updated to $url5"
[[ "$(head -1 "$root/.singular-state/console.url")" == "$url5" ]] || fail "console.url not updated to $url5"
python3 -c 'import sys, urllib.request
urllib.request.urlopen(sys.argv[1] + "/api/health", timeout=3)' "$url5" \
  || fail "/api/health not answering at fallback $url5"
"$SINGULAR" console --stop 2>/dev/null || fail "--stop exited non-zero"
kill "$squatter_pid" 2>/dev/null || true; wait "$squatter_pid" 2>/dev/null || true; squatter_pid=""

# --- 11. SINGULAR_CONSOLE_PORT pins the port; garbage is refused -------------------
pin="$(python3 -c 'import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
url6="$(SINGULAR_CONSOLE_PORT="$pin" "$SINGULAR" console --ensure)" || fail "--ensure with SINGULAR_CONSOLE_PORT failed"
record_pid
[[ "$url6" == "http://127.0.0.1:$pin" ]] || fail "SINGULAR_CONSOLE_PORT=$pin ignored (got $url6)"
"$SINGULAR" console --stop 2>/dev/null || fail "final --stop exited non-zero"
if SINGULAR_CONSOLE_PORT="not-a-port" "$SINGULAR" console --ensure >/dev/null 2>"$tmp/ensure7.err"; then
  "$SINGULAR" console --stop 2>/dev/null || true
  fail "--ensure accepted SINGULAR_CONSOLE_PORT=not-a-port"
fi
assert_contains "$(cat "$tmp/ensure7.err")" "is not a port" "bad-port-message"

echo "PASS: test-console-cli.sh"
