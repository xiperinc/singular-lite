#!/usr/bin/env python3
"""Supervision tokens outside the engine loop. READ-ONLY.

Computed here: supervisor-launched codex exec recovery runs, claude -p reviews,
and the Claude interactive sessions cut at campaign close. The Codex interactive
supervisor total is taken from the session-store analysis (incremental counter
method with reset and fork handling) because it cannot be re-derived from a
last-value read.
"""
import glob, json, sys
from datetime import datetime
from pathlib import Path

HOME = Path.home()
# usage: supervision.py <state-dir> <claude-project-dir> <cutoff-iso> <out.json>
S = Path(sys.argv[1])
CLAUDE_PROJECT = Path(sys.argv[2])
CUTOFF = datetime.fromisoformat(sys.argv[3])      # campaign close, e.g. the release commit time
OUT = sys.argv[4]

def ts(x):
    try:
        return datetime.fromisoformat(str(x).replace("Z", "+00:00"))
    except Exception:
        return None

def jl(path):
    for ln in open(path, encoding="utf-8", errors="replace"):
        ln = ln.strip()
        if ln.startswith("{"):
            try:
                yield json.loads(ln)
            except Exception:
                pass

# ---- 1. supervisor-launched codex exec (autonomous recovery) ----
# Each provider.jsonl is one `codex exec` call; resumed calls share a thread id
# but are separate billed calls, so sum per file. A thread's calls that lack
# usage are recovered as (rollout cumulative total - known calls on that thread).
exec_files = sorted(glob.glob(str(S / "rescue-20260910" / "autonomous-recovery-20260912" / "**" / "provider.jsonl"), recursive=True))
ex = {"files": len(exec_files), "withUsage": 0, "recoveredThreads": 0, "missing": 0, "fresh": 0, "cached": 0, "output": 0}
threads = {}
for f in exec_files:
    tid, usage = None, None
    for o in jl(f):
        tid = tid or o.get("thread_id")
        if o.get("type") in ("turn.completed", "response.completed") and isinstance(o.get("usage"), dict):
            usage = o["usage"]
    threads.setdefault(tid, []).append(usage)
def add_usage(u, sign=1):
    inp, cached = int(u.get("input_tokens") or 0), int(u.get("cached_input_tokens") or 0)
    return (inp - cached) * sign, cached * sign, int(u.get("output_tokens") or 0) * sign
for tid, usages in threads.items():
    known = [u for u in usages if u]
    missing = len(usages) - len(known)
    kf = kc = ko = 0
    for u in known:
        a1, b1, c1 = add_usage(u)
        kf += a1; kc += b1; ko += c1
    ex["withUsage"] += len(known)
    rf = rc = ro = 0
    if missing and tid:
        last = None
        for h in glob.glob(str(HOME / ".codex" / "sessions" / "**" / f"rollout-*-{tid}.jsonl"), recursive=True):
            for o in jl(h):
                pl = o.get("payload") or {}
                if o.get("type") == "event_msg" and pl.get("type") == "token_count":
                    info = pl.get("info") or {}
                    if isinstance(info.get("total_token_usage"), dict):
                        last = info["total_token_usage"]
        if last:
            tf, tc, to = add_usage(last)
            rf, rc, ro = max(0, tf - kf), max(0, tc - kc), max(0, to - ko)
            ex["recoveredThreads"] += 1
        else:
            ex["missing"] += missing
    ex["fresh"] += kf + rf
    ex["cached"] += kc + rc
    ex["output"] += ko + ro

# ---- 2. claude -p supervisor reviews ----
rev = {"envelopes": 0, "fresh": 0, "cached": 0, "output": 0, "usd": 0.0}
seen_sessions = set()
for f in sorted(glob.glob(str(S / "rescue-20260910" / "autonomous-recovery-20260912" / "claude-takeover-20260913" / "wu*" / "**" / "claude-envelope.json"), recursive=True)):
    try:
        o = json.load(open(f))
    except Exception:
        continue
    sid = o.get("session_id")
    if sid in seen_sessions:
        continue
    seen_sessions.add(sid)
    u = o.get("usage") or {}
    rev["envelopes"] += 1
    rev["fresh"] += int(u.get("input_tokens") or 0) + int(u.get("cache_creation_input_tokens") or 0)
    rev["cached"] += int(u.get("cache_read_input_tokens") or 0)
    rev["output"] += int(u.get("output_tokens") or 0)
    rev["usd"] += float(o.get("total_cost_usd") or 0)

# ---- 3. Claude interactive supervisors, cut at campaign close ----
proj = CLAUDE_PROJECT
def claude_session(path, owned_ids, before=None):
    best = {}
    for o in jl(path):
        if o.get("type") != "assistant":
            continue
        m = o.get("message") or {}
        mid, t = m.get("id"), ts(o.get("timestamp"))
        if not mid or t is None or mid in owned_ids:
            continue
        if before and t > before:
            continue
        u = m.get("usage") or {}
        prev = best.get(mid)
        if prev is None or (u.get("output_tokens") or 0) >= (prev.get("output_tokens") or 0):
            best[mid] = u
    tot = {"messages": len(best), "fresh": 0, "cached": 0, "output": 0}
    for u in best.values():
        tot["fresh"] += int(u.get("input_tokens") or 0) + int(u.get("cache_creation_input_tokens") or 0)
        tot["cached"] += int(u.get("cache_read_input_tokens") or 0)
        tot["output"] += int(u.get("output_tokens") or 0)
    return tot, set(best.keys())

a, a_ids = claude_session(proj / "91f03b29-cf3f-4044-929b-cec5bff5f4e2.jsonl", set())
b, _ = claude_session(proj / "5392a51e-1da5-4834-8e12-c6c4d2fb7756.jsonl", a_ids, before=CUTOFF)
claude_int = {"sessions": ["91f03b29 (13 Sep 21:40 → 15 Sep 20:09)", "5392a51e (to 16 Sep 10:11, campaign close)"],
              "fresh": a["fresh"] + b["fresh"], "cached": a["cached"] + b["cached"], "output": a["output"] + b["output"],
              "parts": {"91f03b29": a, "5392a51e_to_close": b}}

# ---- 4. Codex interactive supervisor (session-store analysis, incremental counters) ----
codex_int = {"threads": 3, "subagents": 23, "fresh": 28_308_656, "cached": 946_598_016, "output": 3_826_167,
             "source": "rollouts 01a07b1f, 01a08d32 (+23 subagents), 01a09792; per-event increments, resets and forks handled"}

# ---- 5. Grok experiments (worker envelope) and transcript-only supervisor probes ----
grok = {"fresh": 13_130_000, "cached": 0, "output": 66_200, "note": "worker B envelope; worker A envelope empty (usage unknown)"}
probes = {"fresh": 0, "cached": 4_840_000, "output": 42_200, "note": "3 outcome-unknown continuation sessions + 2 containment probes (transcripts only)"}

layers = {
    "Codex interactive supervisor (7–14 Sep)": codex_int,
    "Supervisor-launched recovery runs (codex exec, 12–13 Sep)": ex,
    "Claude interactive supervisor (13–16 Sep, to close)": claude_int,
    "Supervisor claude -p reviews": rev,
    "Grok worker experiments (13 Sep)": grok,
    "Supervisor probe sessions": probes,
}
total = {k: sum(v.get(k, 0) for v in layers.values()) for k in ("fresh", "cached", "output")}
json.dump({"cutoff": CUTOFF.isoformat(), "layers": layers, "total": total}, open(OUT, "w"), indent=1)
for k, v in layers.items():
    print(f"{k:58s} fresh={v['fresh']:13,d} cached={v['cached']:15,d} output={v['output']:11,d}")
print(f"{'TOTAL':58s} fresh={total['fresh']:13,d} cached={total['cached']:15,d} output={total['output']:11,d}")
print("exec detail:", {k: ex[k] for k in ('files','withUsage','recoveredThreads','missing')}, "| reviews:", rev["envelopes"], f"${rev['usd']:.2f}")
print("claude parts:", {k: (v['messages'], v['output']) for k, v in claude_int['parts'].items()})
