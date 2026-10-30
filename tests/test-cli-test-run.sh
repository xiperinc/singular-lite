#!/usr/bin/env bash
set -euo pipefail

# `singular test` is the supervised, attachable form of the engine's
# own regression suite. What that has to be true of:
#
#   a  --no-wait starts a detached run and returns: manifest published, current
#      run repointed, and the supervisor's flock HELD (the liveness proof)
#   b  plain `singular test` while one is live ATTACHES to it — no second run —
#      and exits with the suite's own exit code once it finishes
#   c  --status --json parses, and reports liveness after completion
#   d  --rerun-failures starts a new run filtered to the last completed run's
#      failures, and runs only those
#   e  --new-run overrides the single-instance attach and repoints current
#   f  a supervisor killed mid-run reconciles to "interrupted" on the next read
#      (the lock dies with the process; nothing polls a pid to find out)
#   g  an engine that ships no tests/ fails once, by name
#   g2 an engine home that is not a Git CHECKOUT refuses BEFORE anything is
#      created — no run dir, no manifest, no current.json, no supervisor — while
#      --status/--wait still report on a past run there
#   h  tests/run.sh's own hooks: run dir set -> per-test logs + progress.jsonl
#      and a working basename filter; run dir unset -> byte-identical output and
#      nothing written
#   i  --wait with nothing ever recorded is an error, not a hang
#
# Everything runs against FIXTURE suites (three dummy tests), never the real
# ~50-minute one.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-cli-test-run.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset SINGULAR_TEST_RUN_DIR SINGULAR_ENGINE_HOME 2>/dev/null || true

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected [$2], got [$1]"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing [$2] in [$1]"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected [$2] in [$1]"; }

tmp="$(mktemp -d)"
self_pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ' || echo 0)"

# Supervisors are detached (setsid) and their suites outlive a killed
# supervisor, so cleanup kills whole process GROUPS — every group id any
# fixture manifest ever recorded. setsid guarantees each is a fresh group, so
# this can never reach anything of ours.
reap() {
  local manifest pgid
  while IFS= read -r manifest; do
    pgid="$(python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get("pgid") or 0)
except Exception:
    print(0)' "$manifest" 2>/dev/null || echo 0)"
    [[ "$pgid" =~ ^[0-9]+$ ]] || continue
    [[ "$pgid" -gt 1 && "$pgid" != "$self_pgid" ]] || continue
    kill -9 -"$pgid" 2>/dev/null || true
  done < <(find "$tmp" -name manifest.json -type f 2>/dev/null || true)
}
trap 'reap; rm -rf "$tmp"' EXIT

# --- fixtures ---------------------------------------------------------------

# A fake engine home: the real CLI, the real guards, the real tests/run.sh, and
# a tests/ dir holding only dummies — so the supervised suite finishes in
# seconds instead of ~50 minutes. engine/lib.sh only has to EXIST
# (resolve_engine_home probes for it); nothing here ever sources it.
make_engine() {
  local d="$1"
  mkdir -p "$d/engine" "$d/cli" "$d/tests"
  cp "$ENGINE_HOME/cli/singular" "$d/cli/singular"
  cp "$ENGINE_HOME/engine/bash-guard.sh" "$d/engine/bash-guard.sh"
  cp "$ENGINE_HOME/engine/git-preflight.sh" "$d/engine/git-preflight.sh"
  : >"$d/engine/lib.sh"
  cp "$ENGINE_HOME/tests/run.sh" "$d/tests/run.sh"
  echo "9.9.9" >"$d/VERSION"
  printf '#!/usr/bin/env bash\necho quick ok\n' >"$d/tests/test-quick-pass.sh"
  printf '#!/usr/bin/env bash\necho slow start\nsleep 10\necho slow ok\n' >"$d/tests/test-slow-pass.sh"
  printf '#!/usr/bin/env bash\necho boom\nexit 1\n' >"$d/tests/test-always-fail.sh"
  chmod +x "$d/tests/"*.sh
  # run.sh's git preflight needs real history and disposable worktrees.
  git -C "$d" init -q -b main 2>/dev/null || git -C "$d" init -q
  git -C "$d" add -A
  git -C "$d" -c user.email=singular@singular.local -c user.name=singular commit -q -m fixture
}

# A consumer repo: this is where .singular-state/test-runs/ lives.
make_consumer() {
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q -b main 2>/dev/null || git -C "$d" init -q
  echo consumer >"$d/README"
  git -C "$d" add -A
  git -C "$d" -c user.email=singular@singular.local -c user.name=singular commit -q -m init
}

eng="$tmp/engine"
make_engine "$eng"

# singular <args> run from a consumer repo against the fixture engine.
G() {
  local consumer="$1"; shift
  ( cd "$consumer" && SINGULAR_ENGINE_HOME="$eng" "$BASH" "$eng/cli/singular" "$@" )
}

runs_of() { printf '%s' "$1/.singular-state/test-runs"; }
mget() {
  python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get(sys.argv[2])))' "$1" "$2"
}
# HELD = something holds the exclusive lock (a live supervisor); FREE = nobody.
lock_state() {
  python3 - "$1" <<'PY'
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
try:
    fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
    print("FREE")
except OSError:
    print("HELD")
PY
}

# --- a) --no-wait starts a supervised run and returns -----------------------

c1="$tmp/consumer1"; make_consumer "$c1"
rid="$(G "$c1" test --no-wait 2>"$tmp/a.err")" \
  || fail "a: --no-wait must succeed (stderr: $(cat "$tmp/a.err"))"
[[ "$rid" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{4}$ ]] || fail "a: bad runId format: [$rid]"
run1="$(runs_of "$c1")/$rid"
[[ -f "$run1/manifest.json" ]] || fail "a: no manifest at $run1"
assert_eq "$(mget "$run1/manifest.json" status)" '"running"' "a: manifest status"
assert_eq "$(mget "$(runs_of "$c1")/current.json" runId)" "\"$rid\"" "a: current.json points at the run"
assert_eq "$(lock_state "$run1/supervisor.lock")" "HELD" "a: supervisor.lock is held for the run's life"
assert_contains "$(cat "$tmp/a.err")" "started run $rid" "a: start is reported on stderr"

# --- b) plain `singular test` attaches to the live run -----------------------

# If this fixture ever gets slow enough that the run finished during a), say so
# instead of failing as "started a second run".
assert_eq "$(lock_state "$run1/supervisor.lock")" "HELD" "b: precondition — run must still be live"
rc=0
out="$(G "$c1" test 2>&1)" || rc=$?
assert_eq "$rc" "1" "b: attach must mirror the suite's exit code"
assert_contains "$out" "attaching to live run $rid" "b: attached rather than started"
assert_contains "$out" "SUMMARY: 2 passed, 1 failed" "b: the suite's own summary was streamed"
dirs="$(find "$(runs_of "$c1")" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
assert_eq "$dirs" "1" "b: no second run directory was created"
assert_eq "$(mget "$run1/manifest.json" status)" '"failed"' "b: final status"
assert_eq "$(mget "$run1/manifest.json" counts)" '{"pass": 2, "fail": 1}' "b: final counts"
assert_eq "$(mget "$run1/manifest.json" failed)" '["test-always-fail.sh"]' "b: failed list"
assert_eq "$(mget "$run1/manifest.json" exitCode)" "1" "b: exit code"
[[ "$(mget "$run1/manifest.json" endedAt)" != "null" ]] || fail "b: endedAt was not set"
logs="$(find "$run1/logs" -type f -name '*.log' | wc -l | tr -d ' ')"
assert_eq "$logs" "3" "b: one durable log per test"
lines="$(wc -l <"$run1/progress.jsonl" | tr -d ' ')"
assert_eq "$lines" "3" "b: one progress line per test"
assert_contains "$(cat "$run1/logs/test-always-fail.sh.log")" "boom" "b: per-test log holds the test's output"

# --- c) --status --json after completion ------------------------------------

status_json="$(G "$c1" test --status --json)" || fail "c: --status --json must succeed"
eval "$(printf '%s' "$status_json" | python3 -c 'import json,sys
d = json.load(sys.stdin)
print("st=%s" % json.dumps(d.get("status")))
print("lv=%s" % json.dumps(d.get("liveness")))
print("rid2=%s" % json.dumps(d.get("runId")))')" \
  || fail "c: --status --json did not parse: $status_json"
assert_eq "$st" "failed" "c: reported status"
assert_eq "$rid2" "$rid" "c: reported runId"
[[ "$lv" != "running" ]] || fail "c: liveness must not be 'running' after completion (got $lv)"

# --- d) --rerun-failures runs exactly the last completed run's failures -----

rc=0
out="$(G "$c1" test --rerun-failures 2>&1)" || rc=$?
assert_eq "$rc" "1" "d: the re-run still fails"
assert_contains "$out" "re-running 1 failed test(s): test-always-fail.sh" "d: names what it re-runs"
rid_d="$(mget "$(runs_of "$c1")/current.json" runId | tr -d '"')"
[[ "$rid_d" != "$rid" ]] || fail "d: --rerun-failures must start a NEW run"
run_d="$(runs_of "$c1")/$rid_d"
assert_eq "$(mget "$run_d/manifest.json" filter)" '["test-always-fail.sh"]' "d: manifest records the filter"
assert_eq "$(wc -l <"$run_d/progress.jsonl" | tr -d ' ')" "1" "d: only the filtered test ran"
assert_contains "$(cat "$run_d/progress.jsonl")" '"test":"test-always-fail.sh"' "d: and it was the right one"

# --- e) --new-run starts a concurrent run and repoints current --------------

c2="$tmp/consumer2"; make_consumer "$c2"
rid_a="$(G "$c2" test --no-wait 2>/dev/null)" || fail "e: first run must start"
rid_b="$(G "$c2" test --new-run --no-wait 2>/dev/null)" || fail "e: --new-run must start a second run"
[[ "$rid_a" != "$rid_b" ]] || fail "e: --new-run reused the live run ($rid_a)"
[[ -d "$(runs_of "$c2")/$rid_a" && -d "$(runs_of "$c2")/$rid_b" ]] || fail "e: both run dirs must exist"
assert_eq "$(mget "$(runs_of "$c2")/current.json" runId)" "\"$rid_b\"" "e: current.json repointed"
assert_eq "$(lock_state "$(runs_of "$c2")/$rid_a/supervisor.lock")" "HELD" "e: the first run is still live"
reap   # both fixtures die here; the trap would do it anyway

# --- f) a killed supervisor reconciles to "interrupted" AND ends the run -----

# A second fixture engine whose only test sleeps far longer than this case can
# possibly take. That is what makes the orphan claim below falsifiable: with a
# ten-second suite, "the process group is gone" is equally explained by the
# suite simply having finished, so a version that reaps nothing passes. Here the
# only way the group can be gone is that something killed it.
eng_slow="$tmp/engine-slow"
make_engine "$eng_slow"
rm -f "$eng_slow/tests/"test-*.sh
printf '#!/usr/bin/env bash\necho orphan start\nsleep 600\necho orphan end\n' \
  >"$eng_slow/tests/test-orphan.sh"
chmod +x "$eng_slow/tests/test-orphan.sh"

c3="$tmp/consumer3"; make_consumer "$c3"
Gs() { ( cd "$c3" && SINGULAR_ENGINE_HOME="$eng_slow" "$BASH" "$eng_slow/cli/singular" "$@" ); }
rid_f="$(Gs test --no-wait 2>/dev/null)" || fail "f: run must start"
run_f="$(runs_of "$c3")/$rid_f"
pid_f="$(mget "$run_f/manifest.json" pid)"
pgid_f="$(mget "$run_f/manifest.json" pgid)"
kill -9 "$pid_f" 2>/dev/null || fail "f: could not kill supervisor pid $pid_f"
for _ in $(seq 1 40); do kill -0 "$pid_f" 2>/dev/null || break; sleep 0.25; done
kill -0 "$pid_f" 2>/dev/null && fail "f: supervisor $pid_f survived kill -9"
# The suite itself is NOT dead: subprocess.call's child survives its parent, so
# tests/run.sh keeps running behind a manifest that is about to say
# "interrupted". If this precondition ever stops holding, the orphan assertion
# below proves nothing — so it is asserted rather than assumed.
kill -0 -"$pgid_f" 2>/dev/null || fail "f: precondition — the run's group must outlive its supervisor"
Gs test --status >"$tmp/f.out" 2>&1 || fail "f: --status must still report: $(cat "$tmp/f.out")"
assert_eq "$(mget "$run_f/manifest.json" status)" '"interrupted"' "f: manifest reconciled"
[[ "$(mget "$run_f/manifest.json" endedAt)" != "null" ]] || fail "f: interrupted run must record endedAt"
assert_contains "$(cat "$tmp/f.out")" "status interrupted" "f: --status says so out loud"
# Reconciling to "interrupted" ends the RUN, not merely the supervisor. Left
# alive, the orphaned suite keeps writing results into a run already declared
# dead, and the next `singular test` — seeing no live run — starts a genuinely
# duplicate ~50-minute one. The supervisor is setsid'd, so the recorded pgid
# names exactly this run and nothing else.
for _ in $(seq 1 20); do kill -0 -"$pgid_f" 2>/dev/null || break; sleep 0.25; done
kill -0 -"$pgid_f" 2>/dev/null \
  && fail "f: the orphaned suite (pgid $pgid_f) survived reconciliation to interrupted"
reap

# --- f2) a STALE running manifest must never reap the pgid it names ---------

# The counterweight to (f). A recorded pgid is a number, not an identity: once
# the group is gone the kernel reissues it, and after a reboot pids restart low
# and come back around within hours. A manifest left "running" by a crash or a
# power cut therefore names a group that may now belong to anyone — and the
# command that triggers reconciliation is `--status`, which reads as harmless.
# Recent output is what makes the pgid still mean what the manifest says, so a
# run whose files went quiet long ago must be reconciled WITHOUT signalling.
setsid_group() {
  # A bystander in its own session, so its pgid is its pid and killing that
  # group cannot be confused with killing anything of ours.
  "$BASH" -c 'exec python3 -c "
import os, sys, time
os.setsid()
sys.stdout.write(str(os.getpid()) + chr(10)); sys.stdout.flush()
time.sleep(600)
"' &
}
setsid_group >"$tmp/f2.pid" 2>/dev/null
for _ in $(seq 1 40); do [[ -s "$tmp/f2.pid" ]] && break; sleep 0.25; done
innocent="$(head -n1 "$tmp/f2.pid" | tr -d '[:space:]')"
[[ -n "$innocent" ]] || fail "f2: bystander group never reported its pid"
kill -0 -"$innocent" 2>/dev/null || fail "f2: precondition — bystander group must be alive"

cst="$tmp/consumer-stale"; make_consumer "$cst"
Gst() { ( cd "$cst" && SINGULAR_ENGINE_HOME="$eng" "$BASH" "$eng/cli/singular" "$@" ); }
rid_f2="$(Gst test --no-wait 2>/dev/null)" || fail "f2: run must start"
run_f2="$(runs_of "$cst")/$rid_f2"
for _ in $(seq 1 80); do
  [[ "$(mget "$run_f2/manifest.json" status)" == '"running"' ]] || break
  sleep 0.25
done
# Forge exactly the post-crash shape: status back to "running", pgid pointing at
# the bystander, and every run artefact backdated well past the staleness bound.
python3 - "$run_f2" "$innocent" <<'PY'
import json, os, sys
run, pgid = sys.argv[1], int(sys.argv[2])
p = os.path.join(run, "manifest.json")
m = json.load(open(p))
m["status"] = "running"; m["pgid"] = pgid; m["endedAt"] = None; m["exitCode"] = None
json.dump(m, open(p, "w"))
old = 1.0e9  # 2001, and unambiguously older than any staleness window
for root, _dirs, files in os.walk(run):
    for f in files:
        os.utime(os.path.join(root, f), (old, old))
PY
# This fixture's suite recorded a failing test, so --status reports a nonzero
# outcome for the run itself; that is the report working, not the probe failing.
Gst test --status >"$tmp/f2.out" 2>&1 || true
assert_contains "$(cat "$tmp/f2.out")" "status interrupted" "f2: --status reconciled and said so"
assert_eq "$(mget "$run_f2/manifest.json" status)" '"interrupted"' "f2: stale run still reconciles"
sleep 0.5
kill -0 -"$innocent" 2>/dev/null \
  || fail "f2: --status SIGKILLed an unrelated process group ($innocent) via a recycled pgid"
kill -9 -"$innocent" 2>/dev/null || true
reap

# --- g) an engine with no tests/ fails once, by name ------------------------

mkdir -p "$tmp/nosuite/engine"; : >"$tmp/nosuite/engine/lib.sh"
rc=0
out="$( cd "$c3" && SINGULAR_ENGINE_HOME="$tmp/nosuite" "$BASH" "$eng/cli/singular" test --no-wait 2>&1 )" || rc=$?
[[ "$rc" -ne 0 ]] || fail "g: a missing suite must not exit 0"
assert_contains "$out" "SINGULAR_TEST_SUITE_UNAVAILABLE" "g: diagnosis header"
assert_contains "$out" "run from an engine checkout" "g: recovery line"

# --- g2) an engine home that is not a Git checkout refuses BEFORE writing -----
#
# An INSTALLED engine is a plain `cp -Rp` tree with no .git, and tests/run.sh's
# own preflight rejects it — but by then a run dir, a manifest and a
# detached supervisor already exist, and the run has to be reconciled to explain
# a failure that was knowable up front. The refusal belongs before the first
# write. The fixture is the auditor's: a copy of a working engine home with its
# history removed, so the ONLY thing that changed is Git-ness.
nogit="$tmp/engine-nogit"
cp -Rp "$eng" "$nogit"
rm -rf "$nogit/.git"
[[ ! -e "$nogit/.git" ]] || fail "g2: fixture still has a .git"
[[ -f "$nogit/tests/run.sh" ]] || fail "g2: fixture must still ship the suite"

c5="$tmp/consumer5"; make_consumer "$c5"
rc=0
out="$( cd "$c5" && SINGULAR_ENGINE_HOME="$nogit" "$BASH" "$nogit/cli/singular" test 2>&1 )" || rc=$?
[[ "$rc" -ne 0 ]] || fail "g2: a non-checkout engine home must not exit 0"
assert_contains "$out" "SINGULAR_TEST_SOURCE_UNSUPPORTED" "g2: diagnosis header"
assert_contains "$out" "run from an engine checkout" "g2: recovery line"
# The old failure said this from INSIDE a supervised run; the new one never
# starts one, so run.sh's own wording must be absent.
assert_not_contains "$out" "started run " "g2: no run may be started"
# Nothing was written. This is the whole point of the case.
[[ ! -e "$(runs_of "$c5")" ]] || fail \
  "g2: a refused run created $(runs_of "$c5"): $(find "$(runs_of "$c5")" | tr '\n' ' ')"
[[ ! -e "$c5/.singular-state/test-runs/current.json" ]] || fail "g2: current.json was written"
[[ -z "$(find "$c5" -name 'manifest.json' 2>/dev/null)" ]] || fail "g2: a manifest was written"

# --no-wait takes the same refusal (it is the path `singular setup --test-async`
# uses, and the one that would otherwise leak a detached supervisor).
rc=0
out="$( cd "$c5" && SINGULAR_ENGINE_HOME="$nogit" "$BASH" "$nogit/cli/singular" test --no-wait 2>&1 )" || rc=$?
[[ "$rc" -ne 0 ]] || fail "g2: --no-wait must refuse too"
assert_contains "$out" "SINGULAR_TEST_SOURCE_UNSUPPORTED" "g2: --no-wait diagnosis"
[[ ! -e "$(runs_of "$c5")" ]] || fail "g2: --no-wait created run state"

# ...and the carve-out holds: reporting on a PAST run needs no runnable suite,
# so --status still answers from a repo that has one recorded (c3, from f).
rc=0
out="$( cd "$c3" && SINGULAR_ENGINE_HOME="$nogit" "$BASH" "$nogit/cli/singular" test --status 2>&1 )" || rc=$?
assert_eq "$rc" "0" "g2: --status must still report on a past run"
assert_contains "$out" "status interrupted" "g2: --status reads the recorded run"
assert_not_contains "$out" "SINGULAR_TEST_SOURCE_UNSUPPORTED" "g2: --status is not gated on the suite"

# --- h) tests/run.sh's own hooks, standalone --------------------------------

# With a run dir: durable per-test logs + progress lines, and the basename
# filter selects exactly what was named.
hd="$tmp/hookrun"
rc=0
out="$( cd "$tmp" && SINGULAR_TEST_RUN_DIR="$hd" "$BASH" "$eng/tests/run.sh" \
        test-quick-pass.sh test-always-fail.sh 2>&1 )" || rc=$?
assert_eq "$rc" "1" "h: the filtered run reports the failing test"
assert_contains "$out" "SUMMARY: 1 passed, 1 failed" "h: only the two named tests ran"
[[ -f "$hd/logs/test-quick-pass.sh.log" ]] || fail "h: missing per-test log for test-quick-pass.sh"
[[ -f "$hd/logs/test-always-fail.sh.log" ]] || fail "h: missing per-test log for test-always-fail.sh"
[[ ! -e "$hd/logs/test-slow-pass.sh.log" ]] || fail "h: an unselected test was run"
assert_eq "$(wc -l <"$hd/progress.jsonl" | tr -d ' ')" "2" "h: one progress line per selected test"
assert_contains "$(cat "$hd/progress.jsonl")" '"status":"pass"' "h: progress records a pass"
assert_contains "$(cat "$hd/progress.jsonl")" '"status":"fail"' "h: progress records a fail"

# Without a run dir: byte-identical output, and nothing written anywhere.
clean="$tmp/clean"; mkdir -p "$clean"
rc=0
out="$( cd "$clean" && "$BASH" "$eng/tests/run.sh" test-quick-pass.sh 2>&1 )" || rc=$?
assert_eq "$rc" "0" "h: an unfiltered-out passing test exits 0"
assert_eq "$out" "$(printf 'PASS  test-quick-pass.sh\n\nSUMMARY: 1 passed, 0 failed')" \
  "h: default output is unchanged"
[[ -z "$(ls -A "$clean")" ]] || fail "h: run.sh wrote artifacts with no run dir set: $(ls -A "$clean")"
[[ ! -e "$eng/tests/logs" && ! -e "$eng/tests/progress.jsonl" ]] || fail "h: artifacts leaked into the suite dir"

# A filter that matches nothing is an error, not an empty green run.
rc=0
out="$( cd "$clean" && "$BASH" "$eng/tests/run.sh" test-does-not-exist.sh 2>&1 )" || rc=$?
[[ "$rc" -ne 0 ]] || fail "h: a filter matching nothing must not exit 0"
assert_contains "$out" "no test file matched the filter" "h: and it says which"

# --- i) --wait with nothing recorded is an error ----------------------------

c4="$tmp/consumer4"; make_consumer "$c4"
rc=0
out="$(G "$c4" test --wait 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "i: --wait with no run must not exit 0"
assert_contains "$out" "no test run recorded" "i: says nothing was ever recorded"

echo "PASS: test-cli-test-run"
