#!/usr/bin/env bash
# Regression contracts for ctx-rehydrate-authored-packet.
set -uo pipefail

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ENGINE_HOME/engine/lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

run_dir="$tmp/run-state/RUN-AUTHORED"
mkdir -p "$run_dir"

# --- Path-backed artifact fixtures on disk ----------------------------------
# alpha.md   is an ordinary safe artifact (no quarantined sibling)   -> KEEP
# quar.md    has a `.quarantined` sibling on disk                    -> DROP
printf 'PATH FILE CONTENTS for alpha\n'  >"$run_dir/alpha.md"
printf 'SECRET quarantined body\n'        >"$run_dir/quar.md"
printf '{"leak":"x"}\n'                    >"$run_dir/quar.md.quarantined"

# --- Authored-knowledge manifest fixture ------------------------------------
# Entries deliberately in NON-sorted id order so the id-sorted emission order is
# exercised. Trigger context under test is `implement`.
#   zeta-body   body        load-when [implement]  current               -> KEEP
#   alpha-path  path alpha  load-when [implement]  current               -> KEEP
#   draft-note  body        load-when [implement]  current  UNVERIFIED    -> DROP (select)
#   stale-note  body        load-when [implement]  stale                  -> DROP (eligible)
#   quar-path   path quar   load-when [implement]  current  quarantined   -> DROP (select)
#   plan-only   body        load-when [planner]    current               -> DROP (trigger-mismatch)
manifest="$tmp/authored-manifest.json"
write_manifest() {
  local zeta_body="$1"
  cat >"$manifest" <<JSON
{
  "schema": "singular.orchestration.authored-knowledge-manifest.v0",
  "entries": [
    { "id": "zeta-body",  "body": "$zeta_body", "load-when": ["implement"], "freshness": "current" },
    { "id": "draft-note", "body": "scratch",    "load-when": ["implement"], "freshness": "current", "description_unverified": true },
    { "id": "stale-note", "body": "aged note",  "load-when": ["implement"], "freshness": "stale" },
    { "id": "quar-path",  "path": "$run_dir/quar.md",  "load-when": ["implement"], "freshness": "current" },
    { "id": "plan-only",  "body": "planner",    "load-when": ["planner"],   "freshness": "current" },
    { "id": "alpha-path", "path": "$run_dir/alpha.md", "load-when": ["implement"], "freshness": "current" }
  ]
}
JSON
}
write_manifest "AUTHORED BODY CONTENT zeta"

# Snapshot the on-disk tree so we can prove the composer is read-only.
tree_hash() {
  find "$run_dir" "$manifest" -type f -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}'
}
before_hash="$(tree_hash)"

render() {
  bash -c '
    source "'"$LIB"'"
    singular_ctx_rehydrate_authored_render "$@"
  ' _ "$@"
}
manifest_of() {
  bash -c '
    source "'"$LIB"'"
    singular_ctx_rehydrate_authored_manifest "$@"
  ' _ "$@"
}

# --- Case 1: render both eligible entries as authored sections --------------
out="$(render "$manifest" implement)" || fail "case1: render exited non-zero"

grep -q '=== authored:alpha-path ===' <<<"$out" \
  || fail "case1: path-backed authored:alpha-path section missing. got:[$out]"
grep -q '=== authored:zeta-body ===' <<<"$out" \
  || fail "case1: body-backed authored:zeta-body section missing. got:[$out]"
grep -q 'PATH FILE CONTENTS for alpha' <<<"$out" \
  || fail "case1: path-backed file contents not read into the section. got:[$out]"
grep -q 'AUTHORED BODY CONTENT zeta' <<<"$out" \
  || fail "case1: inline body not rendered into the section. got:[$out]"

# Each rendered section is headed by an authored-knowledge / not-authoritative
# marker (case-insensitive 'authored' + 'not authoritative').
n_marker="$(grep -ic 'authored-knowledge' <<<"$out")"
[[ "$n_marker" -ge 2 ]] \
  || fail "case1: expected an authored-knowledge marker per section, got $n_marker. out:[$out]"
grep -iq 'not authoritative' <<<"$out" \
  || fail "case1: sections missing 'not authoritative' marker. out:[$out]"

# id-sorted: alpha-path section precedes zeta-body section.
la="$(grep -n '=== authored:alpha-path ===' <<<"$out" | head -1 | cut -d: -f1)"
lz="$(grep -n '=== authored:zeta-body ===' <<<"$out" | head -1 | cut -d: -f1)"
[[ -n "$la" && -n "$lz" && "$la" -lt "$lz" ]] \
  || fail "case1: sections not in id-sorted order. out:[$out]"

# --- Case 2: exclusion inheritance ------------------------------------------
for bad in draft-note stale-note quar-path plan-only; do
  grep -q "authored:$bad" <<<"$out" \
    && fail "case2: excluded entry $bad appeared in rendered section. out:[$out]"
done
grep -q 'SECRET quarantined body' <<<"$out" \
  && fail "case2: quarantined path contents leaked into section. out:[$out]"

# --- Case 3: never authoritative --------------------------------------------
grep -Eiq '"?(host-verified|host_verified|tainted|authoritative)"?:? *true' <<<"$out" \
  && fail "case3: a rendered section was marked authoritative. out:[$out]"

# --- Case 4: caps -----------------------------------------------------------
big_body="$(python3 -c 'import sys; sys.stdout.write("X"*5000)')"
cap_manifest="$tmp/cap-manifest.json"
cat >"$cap_manifest" <<JSON
{ "entries": [ { "id": "big", "body": "$big_body", "load-when": [], "freshness": "current" } ] }
JSON

count_x() { grep -o 'X' <<<"$1" | wc -l | tr -d ' '; }

# Default cap (4000) honored when unset: 5000-char body is truncated.
out_def="$(unset SINGULAR_CONTEXT_SECTION_MAX_CHARS; render "$cap_manifest")" \
  || fail "case4: render exited non-zero (default cap)"
xd="$(count_x "$out_def")"
[[ "$xd" -le 4000 ]] || fail "case4: default cap not honored, $xd X's (>4000). "
[[ "$xd" -gt 0 ]]     || fail "case4: default-cap render produced no body."

# A lowered cap tightens the section.
out_lo="$(export SINGULAR_CONTEXT_SECTION_MAX_CHARS=200; render "$cap_manifest")" \
  || fail "case4: render exited non-zero (cap=200)"
xl="$(count_x "$out_lo")"
[[ "$xl" -le 200 ]] || fail "case4: lowered cap not honored, $xl X's (>200)."
[[ "$xl" -lt "$xd" ]] || fail "case4: lowered cap ($xl) not tighter than default ($xd)."

# A stable truncation marker is present when truncated.
[[ "${#out_lo}" -lt 5000 ]] || fail "case4: cap=200 output not truncated."
grep -iq 'truncat' <<<"$out_lo" || fail "case4: truncation marker missing. out:[$out_lo]"

# --- Case 5: manifest entries -----------------------------------------------
man="$(manifest_of "$manifest" implement)" || fail "case5: manifest exited non-zero"

python3 - "$man" <<'PY' || exit 1
import json, sys
obj = json.loads(sys.argv[1])
srcs = obj.get("sources")
assert isinstance(srcs, list), "sources not a list: %r" % obj
ids = [s["id"] for s in srcs]
assert ids == ["alpha-path", "zeta-body"], "unexpected/unsorted ids: %r" % ids
for s in srcs:
    assert s["class"] == "authored-knowledge", "bad class: %r" % s
    assert s["authoritative"] is False, "entry authoritative: %r" % s
    assert isinstance(s["sha256"], str) and len(s["sha256"]) == 64, "bad sha256: %r" % s
for bad in ("draft-note", "stale-note", "quar-path", "plan-only"):
    assert bad not in ids, "excluded id leaked into manifest: %s" % bad
print("manifest-ok")
PY

# Determinism: two runs over identical bytes are byte-identical.
man2="$(manifest_of "$manifest" implement)" || fail "case5: manifest rerun non-zero"
[[ "$man" == "$man2" ]] || fail "case5: manifest non-deterministic.\n1:[$man]\n2:[$man2]"
[[ "$out" == "$(render "$manifest" implement)" ]] \
  || fail "case5: render non-deterministic."

# Changing an entry's bytes changes only that entry's hash.
hash_of() { python3 -c 'import json,sys; print({s["id"]:s["sha256"] for s in json.loads(sys.argv[1])["sources"]}[sys.argv[2]])' "$1" "$2"; }
alpha_h1="$(hash_of "$man" alpha-path)"
zeta_h1="$(hash_of "$man" zeta-body)"
write_manifest "DIFFERENT BODY BYTES zeta"
man3="$(manifest_of "$manifest" implement)" || fail "case5: manifest non-zero after edit"
alpha_h2="$(hash_of "$man3" alpha-path)"
zeta_h2="$(hash_of "$man3" zeta-body)"
[[ "$alpha_h1" == "$alpha_h2" ]] || fail "case5: unchanged alpha-path hash changed."
[[ "$zeta_h1" != "$zeta_h2" ]]   || fail "case5: edited zeta-body hash did not change."
write_manifest "AUTHORED BODY CONTENT zeta"  # restore

# --- Case 6: purity / fail-soft ---------------------------------------------
# Absent manifest -> empty section + empty manifest sources, non-fatal.
out_absent="$(render "$tmp/nope.json" implement)" || fail "case6: render non-zero on absent manifest"
[[ -z "${out_absent//[$'\n']/}" ]] || fail "case6: absent manifest produced a section. got:[$out_absent]"
man_absent="$(manifest_of "$tmp/nope.json" implement)" || fail "case6: manifest non-zero on absent manifest"
python3 -c 'import json,sys; assert json.loads(sys.argv[1])["sources"]==[]' "$man_absent" \
  || fail "case6: absent manifest produced non-empty sources. got:[$man_absent]"

# Malformed manifest -> empty, non-fatal.
bad_manifest="$tmp/bad.json"
printf '{ not json ,,,' >"$bad_manifest"
out_bad="$(render "$bad_manifest" implement)" || fail "case6: render non-zero on malformed manifest"
[[ -z "${out_bad//[$'\n']/}" ]] || fail "case6: malformed manifest produced a section. got:[$out_bad]"
man_bad="$(manifest_of "$bad_manifest" implement)" || fail "case6: manifest non-zero on malformed manifest"
python3 -c 'import json,sys; assert json.loads(sys.argv[1])["sources"]==[]' "$man_bad" \
  || fail "case6: malformed manifest produced non-empty sources. got:[$man_bad]"

# Read-only: the composer wrote nothing to disk.
after_hash="$(tree_hash)"
[[ "$before_hash" == "$after_hash" ]] || fail "case6: composer mutated the on-disk tree."

echo "ctx-rehydrate-authored-packet tests passed"
