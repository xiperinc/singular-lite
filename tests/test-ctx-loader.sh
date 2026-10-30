#!/usr/bin/env bash
# Covers the context module loader block in lib.sh: the single structural hook
# that sources every engine/ctx-*.sh file exactly once, in sorted order, and
# fails LOUD (never silently skips) when a ctx file fails to source. The generic
# engine ships zero ctx-*.sh files, so with none present the hook must be a no-op
# (byte-identical to prior runtime behavior).
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_LIB="$ENGINE_HOME/engine/lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing [$2] in [$1]"; }

# Build an isolated engine dir holding only a copy of lib.sh, so ctx-*.sh
# fixtures never pollute the real engine tree. SINGULAR_ENGINE_DIR resolves to the
# copy's directory, which is where the loader globs for ctx-*.sh.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/engine"
cp "$REAL_LIB" "$tmp/engine/lib.sh"
LIB="$tmp/engine/lib.sh"

# Root is set explicitly so sourcing never touches the real repo (no git needed).
run_source() {
  SINGULAR_ROOT="$tmp" bash -c 'source "'"$LIB"'"; '"$1"''
}

# --- Case 1: no ctx files present -> hook is a no-op, engine functions load ---
out="$(run_source 'echo LOADED=ok; type -t singular_timestamp')" \
  || fail "no-files case: sourcing lib.sh failed with zero ctx-*.sh files"
assert_contains "$out" "LOADED=ok" "no-files case: lib.sh sources cleanly"
assert_contains "$out" "function" "no-files case: engine functions still defined"
[[ -z $(find "$tmp/engine" -maxdepth 1 -name 'ctx-*.sh' 2>/dev/null) ]] \
  || fail "no-files case: fixture leaked into engine dir"

# --- Case 2: a ctx-*.sh defining a new function is loaded ---------------------
cat > "$tmp/engine/ctx-010-demo.sh" <<'EOF'
singular_ctx_demo_fn() { echo demo-ok; }
EOF
out="$(run_source 'singular_ctx_demo_fn')" \
  || fail "loads case: sourcing lib.sh with a ctx fixture failed"
assert_contains "$out" "demo-ok" "loads case: ctx-defined function is available"
rm -f "$tmp/engine/ctx-010-demo.sh"

# --- Case 3: ctx files load exactly once, in sorted order --------------------
# Created out of sort order on purpose; the loader must apply lexical order.
order_file="$tmp/order.txt"
cat > "$tmp/engine/ctx-020-second.sh" <<EOF
printf '%s\n' 020 >> "$order_file"
EOF
cat > "$tmp/engine/ctx-010-first.sh" <<EOF
printf '%s\n' 010 >> "$order_file"
EOF
: > "$order_file"
run_source 'true' || fail "sorted case: sourcing lib.sh with two ctx fixtures failed"
got="$(tr '\n' ' ' < "$order_file")"
[[ "$got" == "010 020 " ]] || fail "sorted case: expected '010 020 ' got '$got' (order/dedup wrong)"
rm -f "$tmp/engine/ctx-020-second.sh" "$tmp/engine/ctx-010-first.sh"

# --- Case 4: a broken ctx file fails LOUD (fail closed), never skipped -------
# A good ctx file sits alongside the broken one; the load MUST abort non-zero and
# print a diagnostic naming the offending file, not silently skip past it.
cat > "$tmp/engine/ctx-010-ok.sh" <<'EOF'
singular_ctx_ok_fn() { echo ok; }
EOF
cat > "$tmp/engine/ctx-050-broken.sh" <<'EOF'
this is not valid bash syntax ((( <<<
EOF
set +e
err="$(run_source 'echo SHOULD_NOT_PRINT' 2>&1)"
ec=$?
set -e 2>/dev/null || true
[[ "$ec" -ne 0 ]] || fail "fails-loud case: broken ctx file did not fail the load (silent skip)"
assert_contains "$err" "ctx-050-broken.sh" "fails-loud case: diagnostic names the offending file"
[[ "$err" != *SHOULD_NOT_PRINT* ]] || fail "fails-loud case: load continued past the broken ctx file"
rm -f "$tmp/engine/ctx-010-ok.sh" "$tmp/engine/ctx-050-broken.sh"

echo "ctx-loader tests passed"
