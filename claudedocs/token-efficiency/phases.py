#!/usr/bin/env python3
"""Split engine and supervision tokens at the moment a fix went live. READ-ONLY.

usage: phases.py <ledger.json> <supervision.json> <events.ndjson> <boundary-iso>
                 <start-iso> <close-iso> <manual-merges> <out.json> <claude-session.jsonl>...

<manual-merges> is a comma list of TASK@ISO integrations the engine did not record
(e.g. a supervisor merge). Claude sessions are de-duplicated by message id, and a
later session never re-counts an id owned by an earlier one. Every supervision
layer other than the Claude interactive sessions ended before the boundary in this
campaign (Codex quota was exhausted at 16:32Z, reviews and exec runs predate it),
so those layers are attributed wholly to the "before" phase.
"""
import json, sys
from datetime import datetime

ledger, supervision, events, b_iso, s_iso, c_iso, manual, out = sys.argv[1:9]
sessions = sys.argv[9:]
ts = lambda x: datetime.fromisoformat(str(x).replace("Z", "+00:00"))
B, START, CLOSE = ts(b_iso), ts(s_iso), ts(c_iso)

calls = json.load(open(ledger))["calls"]
sup = json.load(open(supervision))["layers"]

integrations = []
for line in open(events, encoding="utf-8", errors="replace"):
    if '"integration.integrated"' in line:
        e = json.loads(line)
        integrations.append({"taskId": e["data"].get("taskId"), "ts": e["ts"], "by": "engine"})
for item in filter(None, manual.split(",")):
    tid, when = item.split("@")
    integrations.append({"taskId": tid, "ts": when, "by": "supervisor"})

def phase(t):
    return "before" if t < B else "after"

P = {p: {"calls": 0, "engineOutput": 0, "landedOutput": 0, "supervisionOutput": 0,
         "supervisionTokens": 0, "integrations": 0, "supervisorMerges": 0} for p in ("before", "after")}
P["before"]["hours"] = round((B - START).total_seconds() / 3600, 1)
P["after"]["hours"] = round((CLOSE - B).total_seconds() / 3600, 1)

for c in calls:
    p = P[phase(ts(c["ts"]))]
    p["calls"] += 1
    p["engineOutput"] += c.get("output") or 0
    if str(c["yield"]).startswith("landed"):
        p["landedOutput"] += c.get("output") or 0

for i in integrations:
    t = ts(i["ts"])
    if START <= t <= CLOSE:
        P[phase(t)]["integrations"] += 1
        if i["by"] == "supervisor":
            P[phase(t)]["supervisorMerges"] += 1

for name, v in sup.items():
    if name.startswith("Claude interactive"):
        continue
    P["before"]["supervisionOutput"] += v["output"]
    P["before"]["supervisionTokens"] += v["output"] + v["fresh"] + v["cached"]

owned = set()
for path in sessions:
    best = {}
    for ln in open(path, encoding="utf-8", errors="replace"):
        try:
            o = json.loads(ln)
        except Exception:
            continue
        if o.get("type") != "assistant" or not o.get("timestamp"):
            continue
        m = o.get("message") or {}
        mid = m.get("id")
        if not mid or mid in owned:
            continue
        u = m.get("usage") or {}
        prev = best.get(mid)
        if prev is None or (u.get("output_tokens") or 0) >= (prev[1].get("output_tokens") or 0):
            best[mid] = (ts(o["timestamp"]), u)
    owned |= set(best)
    for t, u in best.values():
        if t > CLOSE:
            continue
        p = P[phase(t)]
        o_ = u.get("output_tokens") or 0
        p["supervisionOutput"] += o_
        p["supervisionTokens"] += (o_ + (u.get("input_tokens") or 0) + (u.get("cache_creation_input_tokens") or 0)
                                   + (u.get("cache_read_input_tokens") or 0))

for p in P.values():
    n = p["integrations"] or 1
    p["integrationsPerDay"] = round(p["integrations"] / (p["hours"] / 24), 2)
    p["supervisionOutputPerIntegration"] = round(p["supervisionOutput"] / n)
    p["engineCallsPerIntegration"] = round(p["calls"] / n, 1)
    p["supervisionToEngineOutput"] = round(p["supervisionOutput"] / p["engineOutput"], 2) if p["engineOutput"] else None
    p["landedOutputPerHour"] = round(p["landedOutput"] / p["hours"])

json.dump({"boundary": b_iso, "start": s_iso, "close": c_iso, "phases": P, "integrations": integrations},
          open(out, "w"), indent=1)
for k, p in P.items():
    print(k, json.dumps(p))
