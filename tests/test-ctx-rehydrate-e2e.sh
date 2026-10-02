#!/usr/bin/env bash
set -euo pipefail

# test-ctx-rehydrate-e2e.sh — the COMPOSED end-to-end guard for the executable DAG
# node `rehydrate-path` (stage S5-routing, layer engine_runtime), pinning its CORE
# requiredCompletion as a SINGLE deterministic walk over the fully-integrated stack
# (TASK-0051..0068). Every behavioral predicate of the node already has a per-slice
# test; what NO existing test does is assert them TOGETHER on one refused-resume
# run, so a future engine change could silently regress the COMPOSED node (drop a
# durable source class from the packet while every per-slice test still passes) with
# no guard catching it. This file closes exactly that gap. It owns only itself and
# modifies NO engine file: it drives the real l1-drive.sh (following the established
# tests/test-ctx-rehydrate-inject-drive.sh / tests/test-ctx-rehydrate-event-drive.sh
# pattern) and composes the same pure engine bricks the driver delegates into.
#
# The composed contract asserted in one walk:
#   (A) All-classes packet, through the real driver. On a refused-resume lineage
#       step with SINGULAR_CTX_ROUTING=1 + SINGULAR_REHYDRATE=1 and a fixture run_dir
#       populated with EVERY durable source class (task packet, implementer/reviewer
#       capsules, findings + assumption ledgers, critique record) plus a fixture
#       repo decision log, the routing spine yields `rehydrate` and the injected
#       $active_prompt durable-context section contains every present durable class
#       in the assembler's fixed rank order (ranks 0..6), each body capped to at most
#       SINGULAR_CONTEXT_SECTION_MAX_CHARS.
#   (B) Manifest completeness + injected<->recorded consistency. The recorded
#       context.strategy_selected event's manifest.sources lists EXACTLY the same
#       class ids injected into $active_prompt, each with a sha256.
#   (C) Quarantine exclusion, through the single singular_ctx_artifact_exclude
#       authority: a class with a `.quarantined` sibling is absent from BOTH the
#       injected packet and the recorded manifest.
#   (D) Determinism: two assemblies over identical fixture bytes yield byte-identical
#       injected packet and byte-identical event data.
#   (E) OFF-parity: with SINGULAR_REHYDRATE unset, no `rehydrate` strategy, no durable
#       section injected, recorded strategy is `fresh` and carries no manifest.
#   (F) Taint independence: singular_ctx_route_independence_admit rehydrate at the
#       independence-pinned steps (final-audit, paired-audit) returns `refuse tainted`
#       under ANY knob values, so a rehydrated (tainted) session is provably never
#       eligible for an independence-required step.
#
# GENUINE-GUARD (non-tautology): assertion (A)/(B) pin the injected/recorded id set
# to the FIXED full 7-class set, not to whatever the resolver happens to return.
# Running with SINGULAR_E2E_DROP_CLASS=critique-record drops that durable class from
# the fixture so the set assertion FAILS (red) — proving the guard bites when a
# source class is dropped from the packet or manifest. Unset (the normal run) it
# passes green against the integrated stack.
#
#   $ SINGULAR_E2E_DROP_CLASS=critique-record bash tests/test-ctx-rehydrate-e2e.sh
#   FAIL: A: injected classes in fixed rank order (full set): ...  # exit 1 (red)
#
# critique-record (plan-critique.json) is the canonical drop target because it is
# the one durable class the driver's implement/audit path does NOT itself persist —
# it is purely mock-seeded here, so removing it from the fixture genuinely removes
# it from the composed packet and manifest. The other run_dir-resolved classes
# (implementer/reviewer capsules, findings/assumptions ledgers, packet.json) are
# (re)written by l1-drive.sh during the same run, so dropping them from the mock
# seed is a no-op — do not use them to demonstrate the red. decision-record and
# task-packet also genuinely drop, but critique-record is the documented default.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
  echo "test-ctx-rehydrate-e2e.sh requires bash >= 4" >&2; exit 1
fi

ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ENGINE_HOME/engine"

# Capture the harness-only knobs BEFORE the hermetic scrub wipes every SINGULAR_*.
# SINGULAR_E2E_DROP_CLASS is the optional non-tautology mutation: drop one durable
# class (canonically critique-record — see the GENUINE-GUARD note above) from the
# fixture so the full-set assertions in walks (A)/(B) MUST fail — this is how red.log
# is produced without touching any engine file. SINGULAR_E2E_KEEP keeps the sandbox
# for debugging.
DROP_CLASS="${SINGULAR_E2E_DROP_CLASS:-}"
KEEP="${SINGULAR_E2E_KEEP:-}"

# Hermetic guard: scrub inherited SINGULAR_* so a leaked knob can't poison the sandbox.
while IFS= read -r _v; do unset "$_v"; done < <(compgen -v | grep '^SINGULAR_' || true)
unset _v

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: want '$2' got '$1'"; }

workroot="$(mktemp -d "${TMPDIR:-/tmp}/singular-rehydrate-e2e.XXXXXX")"
trap '[[ -n "$KEEP" ]] || rm -rf "$workroot"' EXIT
[[ -n "$KEEP" ]] && echo "workroot=$workroot" >&2

# Source lib.sh (auto-sources the ctx-*.sh bricks) so the harness composes the SAME
# pure helpers the driver delegates into.
export SINGULAR_ROOT="$workroot/libroot"
export SINGULAR_STATE_DIR="$SINGULAR_ROOT/.singular-state"
export SINGULAR_TARGET_BRANCH="target"
mkdir -p "$SINGULAR_STATE_DIR"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"
for fn in singular_ctx_rehydrate_sources singular_ctx_rehydrate_packet \
          singular_ctx_rehydrate_manifest singular_ctx_rehydrate_event_data \
          singular_ctx_rehydrate_decision_source singular_ctx_artifact_exclude \
          singular_ctx_route_independence_admit; do
  [[ "$(type -t "$fn")" == "function" ]] || fail "integrated brick missing: $fn"
done

# The node's fixed durable source-class order (assembler RANK 0..6). The composed
# guard pins the injected + recorded id set to EXACTLY this list.
FULL_CLASSES=(task-packet implementer-capsule reviewer-capsule findings-ledger \
              assumptions-ledger critique-record decision-record)
# id -> run_dir file for the six run_dir-resolved classes (decision-record lives in
# the repo, supplied as an extra spec). Kept in RANK order.
CLASS_FILE_task_packet="packet.json"
CLASS_FILE_implementer_capsule="implementer-capsule.json"
CLASS_FILE_reviewer_capsule="reviewer-capsule.json"
CLASS_FILE_findings_ledger="findings-status.json"
CLASS_FILE_assumptions_ledger="assumptions-ledger.json"
CLASS_FILE_critique_record="plan-critique.json"

# Ordered `=== <id> ===` header ids of a packet file, one per line.
packet_section_ids() {
  python3 - "$1" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
for m in re.finditer(r'^=== (\S+) ===$', text, re.M):
    print(m.group(1))
PY
}
# manifest.sources ids of a compact event-data JSON string, one per line.
manifest_source_ids() {
  python3 - "$1" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
for s in d.get("manifest", {}).get("sources", []):
    print(s.get("id"))
PY
}

# ===========================================================================
# Fixture repo + mock runner (shared by walks A/B and E), modeled on the sibling
# inject-drive / event-drive drivers.
# ===========================================================================
drv_root="$workroot/drv"
mkdir -p "$drv_root/docs/orchestration/prompts" "$drv_root/docs/orchestration/tasks" \
  "$drv_root/.singular-state" "$drv_root/internal/widget"
git -C "$drv_root" init -q
git -C "$drv_root" config user.email t@t; git -C "$drv_root" config user.name t
git -C "$drv_root" checkout -q -b target
cp "$ENGINE_HOME/templates/prompts/l2-test-first-developer.md" "$drv_root/docs/orchestration/prompts/l2-test-first-developer.md"
cp "$ENGINE_HOME/templates/prompts/auditor.md" "$drv_root/docs/orchestration/prompts/auditor.md"
printf '# Decider Prompt\n[TASK-ID] [FAILURE CLASS]\n' > "$drv_root/docs/orchestration/prompts/decider.md"

cat >"$drv_root/docs/orchestration/tasks/TASK-0001.md" <<'EOF'
# TASK-0001: Generic widget parser

Status: ready
Area: widget
Target branch: `target`
Worker branch: `agent/widget/TASK-0001-generic`
Test policy: `strict_test_first`
Gate command: `true`
Dispatch mode: canonical
Depends on: []

## Objective

Implement the widget parser.

## Scope

Owned files:

- `internal/widget/parser.go`

Forbidden files:

- Any file outside the owned scope.

## Acceptance Criteria

- Parser handles empty input.
EOF
git -C "$drv_root" add .
git -C "$drv_root" commit -qm init

TASK_MD="$drv_root/docs/orchestration/tasks/TASK-0001.md"
EVENTS="$drv_root/.singular-state/events.ndjson"
# The repo decision log — the rank-6 `decision-record` durable class, supplied to
# both rehydrate sites via singular_ctx_rehydrate_decision_source at drive start.
DECISIONS_MD="$drv_root/docs/orchestration/decisions.md"

# Mock runner. L2 (implementer): on attempt 1 it seeds EVERY run_dir-resolved durable
# class (ranks 1..5; the rank-0 packet.json is persisted by the driver from the
# last-message below) into run_dir=dirname(--output-last-message) with fixed bytes,
# UNLESS that class id equals E2E_DROP_CLASS (the non-tautology mutation). On the
# attempt named by WORKER_FAIL_ON it emits an EMPTY last-message (worker-no-packet ->
# the attempt fails before any durable artifact under run_dir is rewritten, freezing
# run_dir at its attempt-1 state). Read-only (auditor): first call needs-fix, then
# accepted, driving exactly one retry.
mock_runner="$workroot/mock-runner.sh"
cat >"$mock_runner" <<MOCK
#!/usr/bin/env bash
set -uo pipefail
source "$SCRIPT_DIR/lib.sh"
level=""; worktree=""; out=""; meta=""
args=("\$@")
i=0
while [[ \$i -lt \${#args[@]} ]]; do
  case "\${args[\$i]}" in
    --level) level="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    -C|--worktree) worktree="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    --output-last-message) out="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    --session-meta) meta="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    *) i=\$((i+1)) ;;
  esac
done
if [[ "\$level" == "l2" ]]; then
  echo "mock l2 worker ran"
  c=0; [[ -f "\${L2_COUNT_FILE:-/dev/null}" ]] && c="\$(cat "\$L2_COUNT_FILE" 2>/dev/null || echo 0)"
  c=\$((c+1)); [[ -n "\${L2_COUNT_FILE:-}" ]] && echo "\$c" > "\$L2_COUNT_FILE"
  if [[ "\$c" == "1" ]]; then
    run_dir="\$(dirname "\$out")"
    seed_class() {
      [[ "\${E2E_DROP_CLASS:-}" == "\$1" ]] && return 0
      printf '%s' "\$3" > "\$run_dir/\$2"
    }
    seed_class implementer-capsule implementer-capsule.json '{"role":"implementer","note":"fixture implementer capsule"}'
    seed_class reviewer-capsule    reviewer-capsule.json    '{"role":"reviewer","note":"fixture reviewer capsule"}'
    seed_class findings-ledger     findings-status.json     '{"findings":[{"id":"F1","status":"open"}]}'
    seed_class assumptions-ledger  assumptions-ledger.json  '{"assumptions":[{"id":"A1","text":"fixture assumption"}]}'
    seed_class critique-record     plan-critique.json       '{"critique":[{"id":"C1","severity":"low"}]}'
  fi
  if [[ -n "\${WORKER_FAIL_ON:-}" && "\$c" == "\${WORKER_FAIL_ON}" ]]; then
    [[ -n "\$out" ]] && : > "\$out"
    exit 0
  fi
  mkdir -p "\$worktree/internal/widget"
  printf 'package widget\n// attempt %s\n' "\$c" > "\$worktree/internal/widget/parser.go"
  [[ -n "\$out" ]] && cat > "\$out" <<'PKT'
{"schema":"singular.orchestration.state-packet.v0","packetId":"p","runId":"r","taskId":"TASK-0001","area":"widget","role":"l2-developer","status":"needs-review","baseRef":"target","branch":"agent/widget/TASK-0001-generic","headSha":"0","workspace":"w","ownedFiles":["internal/widget/parser.go"],"changedFiles":[],"commands":[],"tests":[],"evidence":[],"blockers":[],"nextAction":"await auditor verdict","createdAt":"2026-01-01T00:00:00Z"}
PKT
  [[ -n "\$meta" ]] && singular_codex_session_meta_write "\$meta" "WORKER-SID" "gpt-5.5" "medium" "\$worktree" 0
  exit 0
fi
# read-only: the auditor.
ac=0; [[ -f "\${AUDIT_COUNT_FILE:-/dev/null}" ]] && ac="\$(cat "\$AUDIT_COUNT_FILE" 2>/dev/null || echo 0)"
ac=\$((ac+1)); [[ -n "\${AUDIT_COUNT_FILE:-}" ]] && echo "\$ac" > "\$AUDIT_COUNT_FILE"
[[ -n "\$meta" ]] && singular_codex_session_meta_write "\$meta" "REVIEWER-SID" "gpt-5.5" "high" "\$worktree" 0
if [[ "\${SCENARIO:-accept}" == "needs-fix-first" && "\$ac" -eq 1 ]]; then
  [[ -n "\$out" ]] && printf '{"verdict":"needs-fix","findings":[{"summary":"fix it"}]}\n' > "\$out"
  exit 0
fi
[[ -n "\$out" ]] && python3 -c 'import json,os,sys; o,v=sys.argv[1:3]; d=os.path.dirname(o); f=os.path.join(d,"packet.json"); p=json.load(open(f)) if os.path.isfile(f) else {}; json.dump({"schema":"singular.orchestration.audit-verdict.v0","taskId":p.get("taskId","TASK-0001"),"runId":p.get("runId") or os.path.basename(d),"branch":p.get("branch","unknown"),"verdict":v,"evidenceReviewed":[],"commandsRun":[],"findings":[],"requiredFixes":[],"rationale":"fixture verdict"},open(o,"w"))' "\$out" "accepted"
exit 0
MOCK
chmod +x "$mock_runner"

reset_state() {
  git -C "$drv_root" checkout -q target 2>/dev/null || true
  rm -rf "$drv_root/.singular-state/runs" "$drv_root/.singular-state/leases" \
    "$drv_root/.singular-state/inbox" "$drv_root/.worktrees" 2>/dev/null || true
  : > "$EVENTS"
  rm -f "$workroot/l2-count" "$workroot/audit-count" 2>/dev/null || true
  # Re-plant the repo decision log (rank-6 decision-record) each run.
  printf '# Decisions\n\n- D1: use the widget parser (fixture decision record).\n' > "$DECISIONS_MD"
  python3 - "$TASK_MD" <<'PY'
import re, sys
p = sys.argv[1]; t = open(p).read()
t = re.sub(r"Status: \w+", "Status: ready", t, count=1)
open(p, "w").write(t)
PY
  git -C "$drv_root" worktree prune 2>/dev/null || true
  git -C "$drv_root" branch -D agent/widget/TASK-0001-generic 2>/dev/null || true
}

run_drive() {
  ( cd "$drv_root" && env SINGULAR_ROOT="$drv_root" SINGULAR_STATE_DIR="$drv_root/.singular-state" \
      SINGULAR_ORCH_DIR="$drv_root/docs/orchestration" SINGULAR_TASKS_DIR="$drv_root/docs/orchestration/tasks" \
      SINGULAR_TARGET_BRANCH=target SINGULAR_RUNNER="$mock_runner" SINGULAR_ENGINE_HOME="$ENGINE_HOME" \
      L2_COUNT_FILE="$workroot/l2-count" AUDIT_COUNT_FILE="$workroot/audit-count" \
      E2E_DROP_CLASS="$DROP_CLASS" \
      SINGULAR_MAX_RETRIES=1 \
      "$@" "$SCRIPT_DIR/l1-drive.sh" TASK-0001 ) || true
}

run_dir_of() { ls -d "$drv_root"/.singular-state/runs/RUN-* 2>/dev/null | head -1; }

# The LAST implementer context.strategy_selected event's `data` object (compact JSON).
last_impl_strategy_data() {
  python3 - "$1" <<'PY'
import json, sys
last = None
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except json.JSONDecodeError:
        continue
    if ev.get("type") != "context.strategy_selected":
        continue
    d = ev.get("data", {})
    if isinstance(d, dict) and d.get("role") == "implementer":
        last = d
if last is None:
    sys.exit(3)
sys.stdout.write(json.dumps(last, sort_keys=True, separators=(",", ":")))
PY
}
jq_field() { python3 -c 'import json,sys
v = json.loads(sys.argv[1])
for k in sys.argv[2].split("."):
    v = v.get(k) if isinstance(v, dict) else None
print(v if v is not None else "")' "$1" "$2"; }

PROV_HEADER="## Injected durable context (rehydrated from a refused-resume lineage)"

# id -> frozen run_dir filename for the six run_dir-resolved durable classes.
runfile_of() {
  case "$1" in
    task-packet)         echo "packet.json" ;;
    implementer-capsule) echo "implementer-capsule.json" ;;
    reviewer-capsule)    echo "reviewer-capsule.json" ;;
    findings-ledger)     echo "findings-status.json" ;;
    assumptions-ledger)  echo "assumptions-ledger.json" ;;
    critique-record)     echo "plan-critique.json" ;;
    *)                   echo "" ;;
  esac
}

# The FULL fixed id set the packet/manifest MUST carry. This is pinned to the whole
# FULL_CLASSES set and is INDEPENDENT of SINGULAR_E2E_DROP_CLASS: the mutation removes
# a class only from the FIXTURE, never from the expectation, so a dropped class makes
# the actual set (short one) diverge from this — the guard bites (red).
expected_id_set() { printf '%s\n' "${FULL_CLASSES[@]}" | sort; }
expected_id_order() { printf '%s ' "${FULL_CLASSES[@]}"; }

# ===========================================================================
# WALK (A)+(B): all-classes packet + manifest completeness + injected<->recorded
# consistency, THROUGH THE REAL DRIVER, on one refused-resume run.
# ===========================================================================
reset_state
run_drive SINGULAR_CTX_ROUTING=1 SINGULAR_REHYDRATE=1 SINGULAR_SESSION_WINDOW_MAX_PCT=0 \
  SCENARIO=needs-fix-first WORKER_FAIL_ON=2 >/dev/null 2>&1
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "A: no run dir produced"
active_prompt="$run_dir/l2-active-prompt.md"
[[ -f "$active_prompt" ]] || fail "A: no active prompt produced"

# Spine yielded rehydrate: the provenance/taint header is present exactly once, and
# frames the section reference-only / NOT authoritative (taint).
prov_count="$(grep -cF "$PROV_HEADER" "$active_prompt" || true)"
assert_eq "$prov_count" "1" "A: routing spine yielded rehydrate (provenance header once)"
grep -qi "not authoritative" "$active_prompt" || fail "A: provenance taint framing (not authoritative) missing"

# The injected durable-context region begins at the provenance header. Its `=== id ===`
# section headers are EVERY present durable class in the assembler's fixed RANK order
# (ranks 0..6). This is the composed, non-tautology assertion: the id set is pinned to
# the full FULL_CLASSES set, so dropping any class from packet OR manifest fails here.
inj_region="$workroot/injected-region.txt"
awk -v h="$PROV_HEADER" 'index($0,h){p=1} p' "$active_prompt" > "$inj_region"
mapfile -t injected_ids < <(packet_section_ids "$inj_region")
assert_eq "${injected_ids[*]} " "$(expected_id_order)" "A: injected classes in fixed rank order (full set)"
assert_eq "$(printf '%s\n' "${injected_ids[@]}" | sort)" "$(expected_id_set)" "A: injected id set == full durable class set"
pass "(A) all durable classes injected into \$active_prompt in fixed rank order (through the real driver)"

# Each injected section body is capped to at most SINGULAR_CONTEXT_SECTION_MAX_CHARS.
python3 - "$inj_region" "${SINGULAR_CONTEXT_SECTION_MAX_CHARS:-4000}" <<'PY' || fail "A: a section body exceeds the per-section cap"
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
cap = int(sys.argv[2])
hdrs = list(re.finditer(r'^=== \S+ ===$', text, re.M))
assert hdrs, "no injected sections found"
for i, m in enumerate(hdrs):
    start = m.end() + 1
    end = hdrs[i + 1].start() if i + 1 < len(hdrs) else len(text)
    body = text[start:end]
    assert len(body) <= cap + 1, "section %s body %d exceeds cap %d" % (m.group(0), len(body), cap)
PY
pass "(A) each injected section body capped to SINGULAR_CONTEXT_SECTION_MAX_CHARS"

# Body fidelity: each FROZEN run_dir-resolved class's on-disk bytes reached the packet
# verbatim (the six run_dir files are frozen at attempt-1 state; the rank-6
# decision-record body is a live-appended repo log so only its header presence is
# asserted, above). This proves the packet carries the real durable artifacts, not
# just their labels.
for c in "${FULL_CLASSES[@]}"; do
  [[ "$c" == "$DROP_CLASS" ]] && continue
  rf="$(runfile_of "$c")"; [[ -n "$rf" ]] || continue
  [[ -f "$run_dir/$rf" ]] || fail "A: frozen run_dir missing $rf for class $c"
  python3 - "$inj_region" "$run_dir/$rf" <<'PY' || fail "A: durable class body not carried verbatim into packet ($c)"
import sys
region = open(sys.argv[1], encoding="utf-8").read()
body = open(sys.argv[2], encoding="utf-8").read()
assert body in region, "artifact bytes not found in injected packet"
PY
done
pass "(A) each frozen durable artifact's bytes carried verbatim into the injected packet"

# (B) The recorded event's manifest.sources lists EXACTLY the injected class ids,
# each with a sha256 — injected <-> recorded consistency.
data="$(last_impl_strategy_data "$EVENTS")" || fail "B: no implementer strategy_selected event"
assert_eq "$(jq_field "$data" strategy)" "rehydrate" "B: recorded strategy is rehydrate"
mapfile -t recorded_ids < <(manifest_source_ids "$data")
assert_eq "$(printf '%s\n' "${recorded_ids[@]}" | sort)" "$(expected_id_set)" "B: manifest.sources id set == full durable class set"
assert_eq "$(printf '%s\n' "${recorded_ids[@]}" | sort)" "$(printf '%s\n' "${injected_ids[@]}" | sort)" "B: recorded ids == injected ids (consistency)"
python3 - "$data" <<'PY' || fail "B: a manifest source lacks a valid sha256"
import json, re, sys
srcs = json.loads(sys.argv[1])["manifest"]["sources"]
assert srcs, "empty manifest.sources"
for s in srcs:
    assert re.fullmatch(r'[0-9a-f]{64}', s.get("sha256", "")), "bad sha256 for %s" % s.get("id")
PY
pass "(B) manifest.sources == injected classes, each with sha256 (injected<->recorded consistency)"

# ===========================================================================
# WALK (E): OFF-parity — SINGULAR_REHYDRATE unset -> no rehydrate strategy, no
# injected section, recorded strategy=fresh with no manifest.
# ===========================================================================
reset_state
run_drive SINGULAR_CTX_ROUTING=1 SINGULAR_SESSION_WINDOW_MAX_PCT=0 \
  SCENARIO=needs-fix-first WORKER_FAIL_ON=2 >/dev/null 2>&1
run_dir="$(run_dir_of)"; [[ -n "$run_dir" ]] || fail "E: no run dir produced"
active_prompt="$run_dir/l2-active-prompt.md"
[[ -f "$active_prompt" ]] || fail "E: no active prompt produced"
grep -qF "$PROV_HEADER" "$active_prompt" && fail "E: provenance header must be absent (hook must not fire)"
grep -q "^=== task-packet ===$" "$active_prompt" && fail "E: no injected durable section may appear"
data="$(last_impl_strategy_data "$EVENTS")" || fail "E: no implementer strategy_selected event"
assert_eq "$(jq_field "$data" strategy)" "fresh" "E: refused resume recorded as fresh (no rehydrate upgrade)"
[[ "$(jq_field "$data" manifest.schema)" == "" ]] || fail "E: fresh event must carry no manifest"
pass "(E) OFF-parity: no rehydrate strategy, no injected section, recorded strategy=fresh, no manifest"

# ===========================================================================
# WALK (C)+(D): quarantine exclusion + determinism, composing the SAME bricks the
# driver delegates into over a fully-controlled fixture run_dir (fixed bytes), so
# both the single quarantine authority and byte-determinism are exercised reliably.
# ===========================================================================
fx="$workroot/fixture"; fx_run_dir="$fx/run"; mkdir -p "$fx_run_dir"
printf '%s' '{"schema":"singular.orchestration.state-packet.v0","taskId":"TASK-0001"}' > "$fx_run_dir/packet.json"
printf '%s' '{"role":"implementer","note":"fx impl"}'   > "$fx_run_dir/implementer-capsule.json"
printf '%s' '{"role":"reviewer","note":"fx reviewer"}'  > "$fx_run_dir/reviewer-capsule.json"
printf '%s' '{"findings":[{"id":"F1"}]}'                > "$fx_run_dir/findings-status.json"
printf '%s' '{"assumptions":[{"id":"A1"}]}'             > "$fx_run_dir/assumptions-ledger.json"
printf '%s' '{"critique":[{"id":"C1"}]}'                > "$fx_run_dir/plan-critique.json"
fx_decisions="$fx/decisions.md"
printf '# Decisions\n- D1 fixture.\n' > "$fx_decisions"
fx_decision_extra="decision-record=$fx_decisions"

# Quarantine one durable class (reviewer-capsule) via a `.quarantined` sibling — the
# single singular_ctx_artifact_exclude authority the assembler composes.
printf 'quarantined\n' > "$fx_run_dir/reviewer-capsule.json.quarantined"

fx_specs=()
while IFS= read -r line; do
  [[ -n "$line" ]] && fx_specs+=("$line")
done < <(singular_ctx_rehydrate_sources "$fx_run_dir" "$fx_decision_extra")
singular_ctx_rehydrate_packet "${fx_specs[@]}" > "$fx/packet.txt"
fx_event="$(singular_ctx_rehydrate_event_data implementer TASK-0001 RUN-FIX 2 window-pressure "$fx_run_dir" "$fx_decision_extra")"

# reviewer-capsule is absent from BOTH the packet and the manifest; the other six
# survive.
packet_section_ids "$fx/packet.txt" | grep -qx "reviewer-capsule" \
  && fail "C: quarantined reviewer-capsule leaked into the injected packet"
manifest_source_ids "$fx_event" | grep -qx "reviewer-capsule" \
  && fail "C: quarantined reviewer-capsule leaked into the recorded manifest"
fx_want="$(printf '%s\n' task-packet implementer-capsule findings-ledger assumptions-ledger critique-record decision-record | sort)"
assert_eq "$(packet_section_ids "$fx/packet.txt" | sort)" "$fx_want" "C: injected set excludes only the quarantined class"
assert_eq "$(manifest_source_ids "$fx_event" | sort)" "$fx_want" "C: manifest set excludes only the quarantined class"
pass "(C) quarantine exclusion: quarantined class absent from BOTH packet and manifest (single authority)"

# (D) Determinism: reassembling over identical fixture bytes is byte-identical.
singular_ctx_rehydrate_packet "${fx_specs[@]}" > "$fx/packet2.txt"
fx_event2="$(singular_ctx_rehydrate_event_data implementer TASK-0001 RUN-FIX 2 window-pressure "$fx_run_dir" "$fx_decision_extra")"
assert_eq "$(cat "$fx/packet2.txt")" "$(cat "$fx/packet.txt")" "D: injected packet byte-identical across runs"
cmp -s "$fx/packet.txt" "$fx/packet2.txt" || fail "D: injected packet not byte-identical across runs"
assert_eq "$fx_event2" "$fx_event" "D: event data byte-identical across runs"
pass "(D) determinism: identical fixture bytes -> byte-identical packet and event data"

# ===========================================================================
# WALK (F): taint independence — rehydrate is refused at the independence-pinned
# steps under ANY knob values, so a tainted session is never eligible.
# ===========================================================================
# Positive control: `fresh` is admitted at an independence step (the refuse is not
# vacuous), and rehydrate is admitted at a NON-independence step.
assert_eq "$(singular_ctx_route_independence_admit fresh implementer final-audit)" "admit" \
  "F: control — fresh admitted at independence step"
assert_eq "$(singular_ctx_route_independence_admit rehydrate implementer implement)" "admit" \
  "F: control — rehydrate admitted at a non-independence step"
# The pin: rehydrate is refused as tainted at BOTH independence-required steps, under
# a spread of knob values (the pin is structural — no knob may reroute it).
for step in final-audit paired-audit; do
  for knobs in \
    "" \
    "SINGULAR_REHYDRATE=1" \
    "SINGULAR_REHYDRATE=1 SINGULAR_SESSION_WINDOW_MAX_PCT=99 SINGULAR_CTX_ROUTING=1" \
    "SINGULAR_REHYDRATE=0 SINGULAR_MAX_RETRIES=9"; do
    got="$(env $knobs bash -c 'source "$1"; singular_ctx_route_independence_admit rehydrate implementer "$2"' _ "$SCRIPT_DIR/lib.sh" "$step" 2>/dev/null)"
    assert_eq "$got" "refuse tainted" "F: rehydrate refused tainted at $step (knobs: ${knobs:-none})"
  done
done
pass "(F) taint independence: rehydrate refused tainted at final-audit + paired-audit under any knobs"

echo "ALL CTX-REHYDRATE-E2E TESTS PASSED"
