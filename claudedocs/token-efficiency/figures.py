#!/usr/bin/env python3
"""Turn the call ledger into the report's figures. Read-only on inputs."""
import collections, json, sys

ledger = json.load(open(sys.argv[1]))
calls = ledger["calls"]
OUT = sys.argv[2]

# ---- run-level landing: a run landed if any build call in it landed ----
run_landed = collections.defaultdict(lambda: False)
for c in calls:
    if c["category"] == "build" and str(c["yield"]).startswith("landed"):
        run_landed[c["runId"]] = True

LOST_PREFIX = "lost:"

def outcome(c):
    cat, y = c["category"], str(c["yield"])
    if cat == "recovery":
        return "engine-self-repair"
    if cat in ("planning", "control", "probe"):
        return "in-loop-management"
    if y in ("lost:invalid-or-infra-verdict", "lost:format"):
        return "protocol-loss"
    if y.startswith(LOST_PREFIX):
        return "environment-loss"
    if cat == "build":
        if y.startswith("landed"):
            return "landed-code"
        return "work-never-landed"
    if cat == "audit":
        return "assurance-on-landed-work" if run_landed[c["runId"]] else "assurance-on-unlanded-work"
    return "other"

def blank():
    return collections.Counter()

def add(s, c):
    s["calls"] += 1
    if c.get("hasUsage"):
        s["fresh"] += c.get("freshInput") or 0
        s["cached"] += c.get("cachedInput") or 0
        s["output"] += c.get("output") or 0
    else:
        s["noUsage"] += 1
    if c.get("costUsd") is not None:
        s["usdMilli"] += round(c["costUsd"] * 1000)

def table(keyf):
    t = collections.defaultdict(blank)
    for c in calls:
        add(t[keyf(c)], c)
    return t

tot = blank()
for c in calls:
    add(tot, c)

def shares(t):
    rows = []
    for k, s in sorted(t.items(), key=lambda kv: -kv[1]["output"]):
        rows.append({
            "key": k if isinstance(k, str) else " / ".join(map(str, k)),
            "calls": s["calls"], "noUsage": s["noUsage"],
            "fresh": s["fresh"], "cached": s["cached"], "output": s["output"],
            "usd": round(s["usdMilli"] / 1000, 2),
            "pctOutput": round(100 * s["output"] / tot["output"], 1) if tot["output"] else None,
            "pctFresh": round(100 * s["fresh"] / tot["fresh"], 1) if tot["fresh"] else None,
            "pctUsd": round(100 * s["usdMilli"] / tot["usdMilli"], 1) if tot["usdMilli"] else None,
        })
    return rows

# ---- audit usefulness ----
verdicts = collections.Counter()
for c in calls:
    if c["category"] == "audit":
        verdicts[str(c["yield"])] += 1

# ---- per day ----
day = collections.defaultdict(lambda: collections.defaultdict(int))
for c in calls:
    day[c["day"]][outcome(c)] += c.get("output") or 0

# ---- per lineage (logical change) ----
LINEAGE = {
    "TASK-1101": "B1 package + ingest",
    "TASK-1102": "B2 context service", "TASK-1103": "B2 context service",
    "TASK-1104": "B3 invocation coverage", "TASK-1113": "B3 invocation coverage",
    "TASK-1105": "B4 reviewed memory", "TASK-1116": "B4 reviewed memory", "TASK-1117": "B4 reviewed memory",
    "TASK-1106": "B5 evaluation harness",
    "TASK-1114": "Reconciliation discovery (0.23.0)",
    "TASK-1115": "Invocation admission (0.23.1)",
}
for t in ("TASK-1107", "TASK-1108", "TASK-1109", "TASK-1111", "TASK-1112"):
    LINEAGE[t] = "Brain-package maintenance"
for t in ("TASK-0001", "TASK-1001", "TASK-1003", "TASK-1004", "TASK-1009", "TASK-1010",
          "TASK-1011", "TASK-1013", "TASK-1017", "TASK-1019", "TASK-1022"):
    LINEAGE[t] = "Original plan, 7-8 Sep (abandoned at pivot)"
lin = collections.defaultdict(blank)
lin_build = collections.defaultdict(lambda: [0, 0])     # key -> [build output, landed build output]
for c in calls:
    tid = c.get("taskId")
    if c["category"] in ("planning", "control", "probe"):
        key = "Planning, deciding, probes"
    elif c["stream"] == "operator":
        key = "Engine self-repair procedures"
    elif tid in LINEAGE:
        key = LINEAGE[tid]
    else:
        key = "Unattributed"
    add(lin[key], c)
    if c["category"] == "build":
        lin_build[key][0] += c.get("output") or 0
        if str(c["yield"]).startswith("landed"):
            lin_build[key][1] += c.get("output") or 0
landed_share_by_lineage = {k: (round(100 * v[1] / v[0]) if v[0] else None) for k, v in lin_build.items()}

# ---- phases ----
phase = table(lambda c: "codex (7–13 Sep)" if c["provider"] == "codex" else "claude (14–16 Sep)")

# ---- cache ratio for build calls ----
build = [c for c in calls if c["category"] == "build" and c.get("hasUsage")]
per_call_cached = sorted(c["cachedInput"] for c in build)

landed_tasks = sorted({c.get("taskId") for c in calls
                       if c["category"] == "build" and str(c["yield"]).startswith("landed") and c.get("taskId")})

fig = {
    "window": [min(c["ts"] for c in calls), max(c["ts"] for c in calls)],
    "totals": {"calls": tot["calls"], "noUsage": tot["noUsage"], "fresh": tot["fresh"],
               "cached": tot["cached"], "output": tot["output"], "usd": round(tot["usdMilli"] / 1000, 2)},
    "engineIntegrations": len(ledger["integrations"]),
    "tasksWithLandedCode": landed_tasks,
    "byCategory": shares(table(lambda c: c["category"])),
    "byOutcome": shares(table(outcome)),
    "byCategoryYield": shares(table(lambda c: (c["category"], c["yield"]))),
    "byLineage": shares(lin),
    "landedShareOfBuildByLineage": landed_share_by_lineage,
    "byPhase": shares(phase),
    "auditVerdicts": dict(verdicts),
    "perDayOutputByOutcome": {k: dict(v) for k, v in sorted(day.items())},
    "claudeCallsWithoutCost": sum(1 for c in calls if c["provider"] == "claude" and c.get("hasUsage") and c.get("costUsd") is None and (c.get("output") or 0) > 0),
    "recoveredCalls": sum(1 for c in calls if c.get("recovered")),
    "buildCachedPerCall": {"median": per_call_cached[len(per_call_cached) // 2] if per_call_cached else None,
                           "max": per_call_cached[-1] if per_call_cached else None,
                           "n": len(per_call_cached)},
}
json.dump(fig, open(OUT, "w"), indent=1)

def pr(title, rows):
    print(f"\n== {title} ==")
    for r in rows:
        print(f"  {r['key']:44s} calls={r['calls']:3d} out={r['output']:9,d} ({r['pctOutput']:5}%)  fresh={r['fresh']:10,d} ({r['pctFresh']:5}%)  ${r['usd']:6.2f} ({r['pctUsd']}%)  noUsage={r['noUsage']}")
print("window:", fig["window"], "totals:", fig["totals"], "integrations:", fig["engineIntegrations"])
pr("by outcome", fig["byOutcome"])
pr("by category", fig["byCategory"])
pr("by lineage", fig["byLineage"])
print("landed share of build output by lineage:", fig["landedShareOfBuildByLineage"])
pr("by phase", fig["byPhase"])
print("\naudit verdicts:", fig["auditVerdicts"])
print("tasks with landed code:", landed_tasks)
print("build cached/call:", fig["buildCachedPerCall"], "| recovered:", fig["recoveredCalls"], "| claude calls w/o cost:", fig["claudeCallsWithoutCost"])
print("\nper-day output by outcome:")
for d, v in fig["perDayOutputByOutcome"].items():
    print("  ", d, {k: f"{x:,}" for k, x in sorted(v.items())})
