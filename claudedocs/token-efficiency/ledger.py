#!/usr/bin/env python3
"""Token ledger for a Singular state dir. READ-ONLY: reads events, sidecars,
provider envelopes and git ancestry; writes only to the output path given.

Rules (verified against engine/lib.sh:4038-4523 and retained data):
- The ledger is every `runner.completed` event; sidecars are overwritten, so
  they are used only to ENRICH a call when their usage matches exactly.
- codex: inputTokens INCLUDES cachedInputTokens -> fresh = input - cached.
- claude: inputTokens is uncached only; cache reads = cachedInputTokens;
  cache creation and total_cost_usd live only in the raw envelope.
- Missing usage is unknown, never zero.
"""
import collections, glob, json, os, re, subprocess, sys
from pathlib import Path

ROOT = Path(sys.argv[1])
TARGET = sys.argv[2]
OUT = Path(sys.argv[3])
STATE = ROOT / ".singular-state"
EVENTS = STATE / "events.ndjson"

def load_events():
    out = []
    files = [EVENTS] + sorted(Path(p) for p in glob.glob(str(STATE / "planning" / "*" / ".singular-state" / "events.ndjson")))
    for f in files:
        with open(f, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    e = json.loads(line)
                    e["_source"] = str(f)
                    out.append(e)
                except Exception:
                    pass
    out.sort(key=lambda e: e.get("ts") or "")
    return out

def envelope_objects(path):
    try:
        raw = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return []
    objs = []
    for ln in raw.splitlines():
        ln = ln.strip()
        if ln.startswith("{"):
            try:
                objs.append(json.loads(ln))
            except Exception:
                pass
    if not objs:
        try:
            objs = [json.loads(raw)]
        except Exception:
            pass
    return [o for o in objs if isinstance(o, dict)]

def claude_extras(env_paths, usage):
    """Find the envelope whose usage matches this call exactly."""
    for p in env_paths:
        for o in reversed(envelope_objects(p)):
            u = o.get("usage")
            if not isinstance(u, dict):
                continue
            if (u.get("input_tokens") == usage.get("inputTokens")
                    and u.get("cache_read_input_tokens") == usage.get("cachedInputTokens")
                    and u.get("output_tokens") == usage.get("outputTokens")):
                det = u.get("output_tokens_details") or {}
                return {
                    "cacheCreation": int(u.get("cache_creation_input_tokens") or 0),
                    "costUsd": o.get("total_cost_usd"),
                    "thinking": det.get("thinking_tokens"),
                    "durationMs": o.get("duration_ms"),
                    "model": ",".join(sorted((o.get("modelUsage") or {}).keys())) or None,
                }
    return None

def codex_extras(env_paths, usage):
    for p in env_paths:
        for o in reversed(envelope_objects(p)):
            u = o.get("usage") if isinstance(o.get("usage"), dict) else None
            if u is None and isinstance(o.get("info"), dict):
                u = o["info"].get("total_token_usage")
            if not isinstance(u, dict):
                continue
            if (u.get("input_tokens") == usage.get("inputTokens")
                    and u.get("output_tokens") == usage.get("outputTokens")):
                return {"reasoning": u.get("reasoning_output_tokens")}
    return None

def candidate_envelopes(ref):
    ref = Path(ref)
    stem = ref.name[:-len(".json")] if ref.name.endswith(".json") else ref.name
    paths = [ref.with_name(stem + ".provider-envelope.raw")]
    run_dir = None
    for parent in ref.parents:
        if parent.parent.name == "runs":
            run_dir = parent
            break
    if run_dir is not None:
        paths += sorted(glob.glob(str(run_dir / "attempts" / "*" / (stem + ".provider-envelope.raw"))))
        paths += sorted(glob.glob(str(run_dir / "attempts" / "*" / "*" / (stem + ".provider-envelope.raw"))))
    return [p for p in paths if os.path.exists(p)]

from datetime import datetime, timezone
HOME = Path.home()

def _ts(x):
    try:
        return datetime.fromisoformat(str(x).replace("Z", "+00:00"))
    except Exception:
        return None

def recover_codex(env_paths):
    tid = None
    for p in env_paths:
        for o in envelope_objects(p):
            if o.get("thread_id"):
                tid = o["thread_id"]
                break
        if tid:
            break
    if not tid:
        return None
    hits = glob.glob(str(HOME / ".codex" / "sessions" / "**" / f"rollout-*-{tid}.jsonl"), recursive=True)
    last = None
    for h in hits:
        for ln in open(h, encoding="utf-8", errors="replace"):
            try:
                o = json.loads(ln)
            except Exception:
                continue
            pl = o.get("payload") or {}
            if o.get("type") == "event_msg" and pl.get("type") == "token_count":
                info = pl.get("info") or {}
                if isinstance(info.get("total_token_usage"), dict):
                    last = info["total_token_usage"]
    if not last:
        return None
    inp, cached = int(last.get("input_tokens") or 0), int(last.get("cached_input_tokens") or 0)
    return {"freshInput": inp - cached, "cachedInput": cached, "output": int(last.get("output_tokens") or 0),
            "recovered": "codex-rollout:" + tid}

_claude_msgs = {}
def claude_messages(project_dir):
    """De-duplicated assistant messages (by message id, keep max output) with timestamps."""
    if project_dir in _claude_msgs:
        return _claude_msgs[project_dir]
    best = {}
    for f in glob.glob(str(project_dir / "*.jsonl")):
        for ln in open(f, encoding="utf-8", errors="replace"):
            try:
                o = json.loads(ln)
            except Exception:
                continue
            if o.get("type") != "assistant":
                continue
            m = o.get("message") or {}
            u = m.get("usage") or {}
            mid, ts = m.get("id"), _ts(o.get("timestamp"))
            if not mid or ts is None:
                continue
            prev = best.get(mid)
            if prev is None or (u.get("output_tokens") or 0) >= (prev[1].get("output_tokens") or 0):
                best[mid] = (ts, u)
    _claude_msgs[project_dir] = list(best.values())
    return _claude_msgs[project_dir]

def recover_claude(worktree, start, end):
    if not worktree or start is None or end is None:
        return None
    esc = re.sub(r"[^A-Za-z0-9]", "-", str(worktree))
    pdir = HOME / ".claude" / "projects" / esc
    if not pdir.is_dir():
        return None
    fresh = cached = out = 0
    n = 0
    for ts, u in claude_messages(pdir):
        if start < ts <= end:
            n += 1
            fresh += int(u.get("input_tokens") or 0) + int(u.get("cache_creation_input_tokens") or 0)
            cached += int(u.get("cache_read_input_tokens") or 0)
            out += int(u.get("output_tokens") or 0)
    if n == 0:
        return None
    return {"freshInput": fresh, "cachedInput": cached, "output": out, "recovered": f"claude-transcript:{n}msgs"}

NAME_RE = re.compile(r"^(?P<role>implementer|auditor)-attempt-(?P<n>\d+)-try-(?P<t>\d+)(?P<suffix>-[a-z-]+)?-runner-result\.json$")

def stream_of(run_id, ref):
    if "/campaign-evidence/" in ref:
        return "operator"
    for prefix, stream in (("RUN-", "task-run"), ("ORIGIN-", "scheduler"), ("SUP-", "supervisor"),
                           ("PROBE-", "operator"), ("AUTHOR-", "operator"), ("REPAIR-", "operator"),
                           ("AMEND-", "operator"), ("RECOVERY-", "operator"), ("OPERATOR-", "operator"),
                           ("MODEL-TRANSITION-", "operator")):
        if run_id.startswith(prefix):
            return stream
    return "other"

_anc_cache = {}
def landed(sha):
    if not sha or not re.fullmatch(r"[0-9a-f]{40}", sha):
        return None
    if sha in _anc_cache:
        return _anc_cache[sha]
    r = subprocess.run(["git", "-C", str(ROOT), "merge-base", "--is-ancestor", sha, TARGET],
                       capture_output=True)
    val = True if r.returncode == 0 else (False if r.returncode == 1 else None)
    _anc_cache[sha] = val
    return val

_grep_cache = {}
def run_landed(run_id):
    """True if any commit whose message names this run is on the target."""
    if run_id in _grep_cache:
        return _grep_cache[run_id]
    r = subprocess.run(["git", "-C", str(ROOT), "log", "--all", "--format=%H", "--grep=" + run_id],
                       capture_output=True, text=True)
    shas = [x for x in r.stdout.split() if x]
    val = None if not shas else any(landed(x) for x in shas)
    _grep_cache[run_id] = val
    return val

def main():
    events = load_events()
    run_task = {}
    policy_applied = collections.defaultdict(list)     # (run, attempt) -> verdicts
    audit_retry = set()                                  # (run, attempt, try) that was retried
    worker_retry = set()
    integrations = []
    audit_completed = collections.defaultdict(list)     # run -> [verdict,...] in order
    for e in events:
        t, d = e.get("type"), e.get("data") or {}
        rid, tid = d.get("runId"), d.get("taskId")
        if rid and tid and rid not in run_task:
            run_task[rid] = tid
        if t == "review.policy_applied":
            policy_applied[(rid, int(d.get("attempt") or 0))].append(d.get("effectiveVerdict"))
        elif t == "audit.infra_retry":
            audit_retry.add((rid, int(d.get("attempt") or 0), int(d.get("try") or 0) - 1))
        elif t == "worker.infra_retry":
            worker_retry.add((rid, int(d.get("attempt") or 0), int(d.get("try") or 0) - 1))
        elif t == "l1.audit_completed":
            audit_completed[rid].append(d.get("verdict"))
        elif t == "integration.integrated":
            integrations.append({"ts": e["ts"], "taskId": tid, "headSha": d.get("headSha"),
                                 "mergeCommit": d.get("mergeCommit")})

    attempts_idx = {}
    def attempt_entry(run_id, n):
        if run_id not in attempts_idx:
            p = STATE / "runs" / run_id / "attempts" / "index.json"
            try:
                doc = json.load(open(p))
                attempts_idx[run_id] = {int(a.get("n")): a for a in doc.get("attempts", []) if a.get("n") is not None}
                if doc.get("taskId") and run_id not in run_task:
                    run_task[run_id] = doc["taskId"]
            except Exception:
                attempts_idx[run_id] = {}
        return attempts_idx[run_id].get(n)

    run_ends = collections.defaultdict(list)
    for e in events:
        if e.get("type") == "runner.completed":
            run_ends[(e.get("data") or {}).get("runId")].append(_ts(e["ts"]))
    calls = []
    for e in events:
        if e.get("type") != "runner.completed":
            continue
        d = e["data"]
        ref = d.get("runnerResultRef") or ""
        name = os.path.basename(ref)
        run_id = d.get("runId") or ""
        provider, role = d.get("provider"), d.get("role")
        c = {"ts": e["ts"], "day": e["ts"][:10], "provider": provider, "role": role,
             "runId": run_id, "taskId": run_task.get(run_id), "ref": ref, "name": name,
             "outcome": d.get("outcome"), "failureClass": d.get("failureClass"),
             "exitCode": d.get("exitCode"), "stream": stream_of(run_id, ref)}
        m = NAME_RE.match(name)
        if m:
            c["attempt"], c["try"] = int(m.group("n")), int(m.group("t"))
            c["variant"] = (m.group("suffix") or "").lstrip("-") or None
        if "paired-audit" in name:
            c["variant"] = "paired-audit"
        elif "critic-recheck" in name:
            c["variant"] = "critic-recheck"
        elif name.startswith("plan-critic"):
            c["variant"] = "plan-critic"
        elif name.startswith("revised-planner"):
            c["variant"] = "plan-revise"
        elif name.startswith("plan-recritic"):
            c["variant"] = "plan-recritic"

        u = d.get("usage")
        c["hasUsage"] = isinstance(u, dict)
        if not c["hasUsage"]:
            rec = None
            if provider == "codex":
                rec = recover_codex(candidate_envelopes(ref))
            elif provider == "claude" and c["taskId"]:
                end = _ts(e["ts"])
                prior = [t for t in run_ends.get(run_id, []) if t and end and t < end]
                a = attempt_entry(run_id, int(NAME_RE.match(name).group("n"))) if NAME_RE.match(name) else None
                start = max(prior) if prior else _ts((a or {}).get("startedAt"))
                rec = recover_claude(ROOT / ".worktrees" / c["taskId"], start, end)
            if rec:
                c.update(rec)
                c["hasUsage"] = True
        if isinstance(u, dict):
            inp = int(u.get("inputTokens") or 0)
            cached = int(u.get("cachedInputTokens") or 0)
            out = int(u.get("outputTokens") or 0)
            env = candidate_envelopes(ref)
            if provider == "codex":
                c["freshInput"], c["cachedInput"], c["output"] = inp - cached, cached, out
                x = codex_extras(env, u)
                c["reasoning"] = (x or {}).get("reasoning")
                c["enriched"] = x is not None
            else:
                x = claude_extras(env, u)
                cc = (x or {}).get("cacheCreation")
                c["cacheCreation"] = cc
                c["freshInput"] = inp + (cc or 0)
                c["cachedInput"], c["output"] = cached, out
                c["costUsd"] = (x or {}).get("costUsd")
                c["thinking"] = (x or {}).get("thinking")
                c["durationMs"] = (x or {}).get("durationMs")
                c["model"] = (x or {}).get("model")
                c["enriched"] = x is not None

        # ---- category ----
        if c["stream"] == "operator":
            cat = "probe" if run_id.startswith(("PROBE-", "PROVIDER-AVAILABILITY")) else "recovery"
        elif role == "implementer":
            cat = "build"
        elif role == "auditor" or c.get("variant") in ("paired-audit", "critic-recheck"):
            cat = "audit"
        elif role in ("planner", "critic"):
            cat = "planning"
        elif role in ("decider", "supervisor", "assistant"):
            cat = "control"
        else:
            cat = "other"
        c["category"] = cat

        # ---- yield ----
        ok = c["outcome"] == "succeeded"
        y = None
        lost = None
        if not ok:
            fc0 = c["failureClass"] or "failed"
            if c["exitCode"] == 143:
                fc0 = "killed"
            lost = "lost:" + fc0
        if cat == "build" and "attempt" in c:
            a = attempt_entry(run_id, c["attempt"]) or {}
            fc = a.get("failureClass")
            lnd = landed(a.get("headSha"))
            via = "attempt-head"
            if lnd is not True:
                rl = run_landed(run_id)
                if rl is True:
                    lnd, via = True, "run-commit"
                elif lnd is None and rl is False:
                    lnd, via = False, "run-commit"
            c["landedVia"] = via if lnd is not None else None
            c["attemptFailureClass"] = fc
            c["headSha"] = a.get("headSha")
            if lnd is True and lost:
                y = "landed-after-runner-failure"
            elif lost:
                y = lost
            elif (run_id, c["attempt"], c["try"]) in worker_retry:
                y = "lost:worker-infra"
            elif fc in ("worker-no-packet", "packet-invalid"):
                y = "landed-after-format-slip" if lnd else "lost:format"
            elif lnd is True:
                y = "landed-first-pass" if c["attempt"] == 1 else "landed-correction"
            elif lnd is False or fc:
                y = "not-landed"
            else:
                y = "unknown"
        elif lost:
            y = lost
        elif cat == "audit" and "attempt" in c:
            if (run_id, c["attempt"], c["try"]) in audit_retry:
                y = "lost:invalid-or-infra-verdict"
            elif policy_applied.get((run_id, c["attempt"])):
                y = "verdict:" + (policy_applied[(run_id, c["attempt"])][-1] or "unknown")
            elif len(audit_completed.get(run_id, [])) >= c["attempt"]:
                y = "verdict:" + (audit_completed[run_id][c["attempt"] - 1] or "unknown")
            else:
                y = "verdict:unrecorded"
        else:
            y = "used"
        c["yield"] = y
        calls.append(c)

    json.dump({"root": str(ROOT), "target": TARGET, "calls": calls, "integrations": integrations},
              open(OUT, "w"), indent=1)
    print(f"calls={len(calls)} integrations={len(integrations)} -> {OUT}")

if __name__ == "__main__":
    main()
