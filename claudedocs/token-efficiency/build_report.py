#!/usr/bin/env python3
"""Build the token-efficiency report: diagnosis, fixes and progress.

usage: build_report.py <ledger.json> <figures.json> <supervision.json> <phases.json> <out.html>
"""
import collections, json, sys
from pathlib import Path
from charts import (F, OUTCOMES, COLOR, LABEL, legend_html, timeline_chart,
                    role_mix_chart, before_after_chart)

LEDGER, FIG, SUP, PHASES, OUT = sys.argv[1:6]
calls = json.load(open(LEDGER))["calls"]
FG = json.load(open(FIG))
SU = json.load(open(SUP))
PH = json.load(open(PHASES))["phases"]
BEF, AFT = PH["before"], PH["after"]

def M(n, d=2):
    if n >= 1e9: return f"{n/1e9:.2f}B"
    if n >= 1e6: return f"{n/1e6:.{d}f}M"
    if n >= 1e3: return f"{n/1e3:.0f}k"
    return f"{n:,}"

def ssum(pred, k):
    return sum((c.get(k) or 0) for c in calls if pred(c))

E = {k: ssum(lambda c: True, k2) for k, k2 in (("fresh", "freshInput"), ("cached", "cachedInput"), ("output", "output"))}
S = SU["total"]
ALL_OUT = E["output"] + S["output"]
landed = ssum(lambda c: str(c["yield"]).startswith("landed"), "output")
by_out = {r["key"]: r for r in FG["byOutcome"]}
by_cat = {r["key"]: r for r in FG["byCategory"]}
lin = {r["key"]: r for r in FG["byLineage"]}
n_calls = len(calls)
n_integ = FG["engineIntegrations"]
AXON_CALLS, AXON_PC, AXON_INTEG = 855, 430, 6          # 0.21.0 release notes; AXON event log confirms 6 integrations
land_share_b = 100 * BEF["landedOutput"] / BEF["engineOutput"]
land_share_a = 100 * AFT["landedOutput"] / AFT["engineOutput"]
sup_drop = BEF["supervisionOutputPerIntegration"] / AFT["supervisionOutputPerIntegration"]

# ---------------------------------------------------------------- charts
timeline = timeline_chart([
    ("27–28 Aug", "AXON · engine 0.20", "diagnosis", "DIAGNOSIS 1",
     [f"{AXON_CALLS} calls for {AXON_INTEG}", "integrations; half", "were planners and", "critics"]),
    ("5 Sep", "release 0.21.0", "fix", "FIX",
     ["critic calibrated;", "checks reused,", "not rerun"]),
    ("7–14 Sep", "brain campaign", "proof", "PROOF · DIAGNOSIS 2",
     [f"planning {100*8/n_calls:.0f}% of calls;", "supervisors wrote", f"{BEF['supervisionToEngineOutput']:.1f}× engine output"]),
    ("14 Sep", "A15 → 0.22.0", "fix", "FIX",
     ["four lifecycle", "deadlocks removed"]),
    ("14–16 Sep", "A15–A16 → 0.23.2", "signal", "EARLY SIGNAL",
     [f"supervision {AFT['supervisionToEngineOutput']:.2f}×", "engine output;", "integrations/day", f"{BEF['integrationsPerDay']:.1f} → {AFT['integrationsPerDay']:.1f}"]),
    ("next campaign", "after the open fixes", "next", "TO PROVE",
     ["supervision below", "engine, sustained;", "3 unattended", "integrations in a row"]),
])

cat_calls = {k: by_cat[k]["calls"] for k in by_cat}
critic_calls = sum(1 for c in calls if c["role"] == "critic")
role_mix = role_mix_chart(
    ("August · AXON · 0.20", f"{AXON_CALLS} calls · {AXON_INTEG} integrations",
     [(AXON_PC, "#c98a45", f"planners + critics {100*AXON_PC/AXON_CALLS:.0f}%"),
      (AXON_CALLS - AXON_PC, "#aebdc6", f"all other roles {100*(AXON_CALLS-AXON_PC)/AXON_CALLS:.0f}%")]),
    ("September · brain · 0.21–0.23", f"{n_calls} calls · {n_integ} integrations",
     [(cat_calls["planning"], "#c98a45", None),
      (cat_calls["control"] + cat_calls["probe"], "#46687a", None),
      (cat_calls["build"], "#0b8688", f"implement {100*cat_calls['build']/n_calls:.0f}%"),
      (cat_calls["audit"], "#7cc3bf", f"audit {100*cat_calls['audit']/n_calls:.0f}%"),
      (cat_calls["recovery"], "#8a74c4", f"engine repair {100*cat_calls['recovery']/n_calls:.0f}%")]),
    [("August", AXON_CALLS / AXON_INTEG, "#c98a45"), ("September", n_calls / n_integ, "#0b8688")],
)
role_legend = ('<div class="legend wrap">'
               '<span><i class="dot" style="background:#c98a45"></i>Planning: planners and critics</span>'
               '<span><i class="dot" style="background:#46687a"></i>Deciding and probes</span>'
               '<span><i class="dot" style="background:#0b8688"></i>Implementation</span>'
               '<span><i class="dot" style="background:#7cc3bf"></i>Audit</span>'
               '<span><i class="dot" style="background:#8a74c4"></i>Engine repair procedures</span>'
               '<span><i class="dot" style="background:#aebdc6"></i>All other roles (August)</span></div>')

SUPCOL = ["#4b3d7a", "#7a65b8", "#a18fd6", "#c3b6ec", "#d8cff5", "#ebe6fb"]
SUPNAME = {
    "Codex interactive supervisor (7–14 Sep)": "Codex interactive supervisor",
    "Supervisor-launched recovery runs (codex exec, 12–13 Sep)": "Supervisor-launched recovery runs",
    "Claude interactive supervisor (13–16 Sep, to close)": "Claude interactive supervisor",
    "Supervisor claude -p reviews": "Supervisor review calls",
    "Grok worker experiments (13 Sep)": "Grok worker experiments",
    "Supervisor probe sessions": "Probe and continuation sessions",
}

def overview_chart():
    W, x0, bw, bh = 650, 150, 392, 28
    rows = [
        ("All model output", M(ALL_OUT), [(landed, "#0b8688", "white"), (E["output"] - landed, "#aebdc6", "#173746"),
                                         (S["output"], "#6a57a8", "white")]),
        ("Engine calls", M(E["output"]), [(by_out[k]["output"], COLOR[k], "white" if k in ("landed-code", "in-loop-management", "engine-self-repair", "environment-loss", "protocol-loss") else "#173746")
                                         for k, _, _ in OUTCOMES if k in by_out]),
        ("Supervision", M(S["output"]), [(v["output"], SUPCOL[i], "white" if i < 2 else "#173746") for i, v in enumerate(SU["layers"].values())]),
    ]
    notes = [("■ landed code", "■ other engine work", "■ supervision"), ("by what the", "tokens produced"), ("by session type,", "to campaign close")]
    H = 12 + len(rows) * (bh + 24)
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" role="img">']
    y = 8
    for (label, tot_s, segs), note in zip(rows, notes):
        tot = sum(s[0] for s in segs)
        out.append(f'<text x="0" y="{y+12}" {F} font-size="10.6" font-weight="650" fill="#173746">{label}</text>')
        out.append(f'<text x="0" y="{y+25}" {F} font-size="9" fill="#5c7380">{tot_s} output tokens</text>')
        x = x0
        for val, col, tc in segs:
            w = bw * val / tot if tot else 0
            if w <= 0:
                continue
            out.append(f'<rect x="{x:.1f}" y="{y}" width="{w:.1f}" height="{bh}" fill="{col}"/>')
            if w >= 34:
                out.append(f'<text x="{x+w/2:.1f}" y="{y+18}" text-anchor="middle" {F} font-size="9" font-weight="700" fill="{tc}">{100*val/tot:.0f}%</text>')
            x += w
        if len(note) == 3:
            cols = ("#0b6f72", "#6b8290", "#5b4a8b")
            for j, t in enumerate(note):
                out.append(f'<text x="{x0+bw+10}" y="{y+6+j*11}" {F} font-size="8.3" font-weight="650" fill="{cols[j]}">{t}</text>')
        else:
            for j, t in enumerate(note):
                out.append(f'<text x="{x0+bw+10}" y="{y+11+j*12}" {F} font-size="8.6" fill="#4d6b7c">{t}</text>')
        y += bh + 24
    out.append("</svg>")
    return "".join(out)

before_after = before_after_chart([
    ("Supervisor output per integration", "tokens · lower is better", BEF["supervisionOutputPerIntegration"], AFT["supervisionOutputPerIntegration"], lambda v: M(v)),
    ("Supervision ÷ engine output", "lower is better; below 1 is the goal", BEF["supervisionToEngineOutput"], AFT["supervisionToEngineOutput"], lambda v: f"{v:.2f}×"),
    ("Integrations per day", "higher is better", BEF["integrationsPerDay"], AFT["integrationsPerDay"], lambda v: f"{v:.1f}"),
    ("Engine output that landed", "higher is better", land_share_b, land_share_a, lambda v: f"{v:.0f}%"),
], f"before · {BEF['hours']/24:.0f} days · {BEF['integrations']} integrations", f"after · {AFT['hours']:.0f} hours · {AFT['integrations']} integrations")

# ---------------------------------------------------------------- tables
env, prot, selfrep = by_out["environment-loss"], by_out["protocol-loss"], by_cat["recovery"]
orig = lin["Original plan, 7-8 Sep (abandoned at pivot)"]
orig_share = FG["landedShareOfBuildByLineage"]["Original plan, 7-8 Sep (abandoned at pivot)"]
audit_usd = by_cat["audit"]["usd"]

def pill(kind, text):
    return f'<span class="st st-{kind}">{text}</span>'

status_rows = [
    ("Planner and critic ceremony", "0.21.0", pill("proven", "Fixed · proven")),
    ("Four lifecycle deadlocks: unpark, lease deletion, base drift, format park", "0.22.0", pill("signal", "Fixed · early signal")),
    ("Complete work parked for one missing packet field", "0.23.0", pill("shipped", "Fixed · not yet exercised")),
    ("Integrator refusing work over a per-run setting", "0.23.2", pill("shipped", "Fixed · not yet exercised")),
    ("Two remaining lifecycle deadlocks", "finalize on frozen exit; accept own reservation", pill("open", "Open")),
    ("Auditor’s first try fails on one field", "prompt change", pill("open", "Open")),
    ("Driver retries straight into a provider session limit", "scheduler backs off; driver does not", pill("open", "Open")),
    ("Worker clock not sized from the task", "contract-sized clock", pill("open", "Open")),
    ("Supervision invisible to engine metrics", "build this measurement into the engine", pill("open", "Open")),
]
status_html = "".join(f"<tr><td>{a}</td><td class='muted2'>{b}</td><td>{c}</td></tr>" for a, b, c in status_rows)

CSS = (Path(__file__).parent / "report.css").read_text()
DATE = "16 SEP 2026"
TOP = f'<div class="topline">Singular / token efficiency review <span>0.23.2 · {DATE}</span></div>'
FOOT = 'Campaigns AXON L0-TASK-0263 (27–28 Aug) and BRAIN-RESCUE-20260910 (7–16 Sep) · internal measurements'

html = f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Singular Token Efficiency</title><style>{CSS}</style></head><body>
<nav><a href="#p1">Summary</a><a href="#p2">Diagnosis 1</a><a href="#p3">Diagnosis 2</a><a href="#p4">Progress</a></nav>

<article class="page" id="p1">{TOP}
<div class="kicker">01 / Summary</div>
<h1>Measure. Fix.<br>Measure again.</h1>
<p class="lead">We measured two field campaigns, three weeks apart, one model call at a time. The first showed the engine arguing with itself, and that fix is proven. The second showed the cost had moved to supervising the engine from outside. Those fixes shipped in 0.22 and 0.23, and the first signal is strong. One clean run still has to prove it.</p>

<div class="diagram">{timeline}</div>

<div class="three mb mt">
<div class="metric"><span class="big">142 → {n_calls/n_integ:.0f}</span><p>engine calls per integration, August to September.</p></div>
<div class="metric"><span class="big">{M(BEF["supervisionOutputPerIntegration"])} → {M(AFT["supervisionOutputPerIntegration"])}</span><p>supervisor output tokens per integration, before and after the lifecycle fixes went live.</p></div>
<div class="metric"><span class="big">{land_share_b:.0f}% → {land_share_a:.0f}%</span><p>share of engine output that became code on the integration branch, over the same split.</p></div>
</div>

<div class="three">
<div class="card status proven"><p class="tiny">FIXED · PROVEN</p><p class="small"><b>In-loop ceremony.</b> Planners and critics went from half of all calls in August to {cat_calls["planning"]} of {n_calls} in September.</p></div>
<div class="card status signal"><p class="tiny">FIXED · EARLY SIGNAL</p><p class="small"><b>Lifecycle deadlocks.</b> Four removed in 0.22.0, plus two supporting fixes in 0.23. Supervision per integration fell {sup_drop:.0f}×. The result is not yet controlled.</p></div>
<div class="card status open"><p class="tiny">OPEN · FIX PROPOSED</p><p class="small"><b>Five items.</b> Two lifecycle deadlocks, the auditor’s first-try defect, retries into provider limits, worker clock sizing, and a supervision metric inside the engine.</p></div>
</div>

<div class="two mt">
<div class="card"><p class="tiny">HOW TO READ THIS</p><p class="small">Both campaigns are field runs, not controlled experiments. The September campaign restarted 19 times on successive frozen runtimes and switched supervisor tools on 13–14 September. Codex ran on quota, so only Claude calls carry dollar amounts.</p></div>
<div class="card"><p class="tiny">HOW TO CHECK IT</p><p class="small">Scripts committed next to this report compute every figure from the engine’s event log, git history and provider session logs. Supervisor figures come from local session stores. The August counts are in the published 0.21.0 release notes.</p></div>
</div>
<footer class="foot"><span>{FOOT}</span><span class="num">01 / 04</span></footer></article>

<article class="page" id="p2">{TOP}
<div class="kicker">02 / Diagnosis one · August</div>
<h2>The loop argued with itself.<br>0.21 made it stop.</h2>
<p class="lead">In August the engine spent most of its calls deciding what to build. After 0.21.0, planning fell from half of all calls to one in twenty. Each integration took {n_calls/n_integ:.0f} calls instead of 142.</p>

<div class="steps">
<div class="step diag"><p class="tiny">DIAGNOSIS · 27–28 AUG · AXON ON 0.20</p><p class="small">{AXON_CALLS} provider calls produced {AXON_INTEG} integrations, and planners and critics made {AXON_PC} of them. The critic returned “revise” on 113 of 140 critiques. Every planned node parked when its revision budget ran out.</p></div>
<div class="arrow">→</div>
<div class="step fix"><p class="tiny">FIX · 5 SEP · RELEASE 0.21.0</p><p class="small">Critic severities now have binding meanings, and the host downgrades a “revise” that names no blocking defect. Verification reruns only for risky work. Integration reuses proofs instead of rerunning the suite.</p></div>
<div class="arrow">→</div>
<div class="step proof"><p class="tiny">PROOF · 7–16 SEP · BRAIN CAMPAIGN</p><p class="small">{n_calls} calls produced {n_integ} integrations. Planning made {cat_calls["planning"]} of them and deciding made {cat_calls["control"]}. 20 of 24 failure decisions took the deterministic fast path, with no model call.</p></div>
</div>

<div class="diagram">{role_mix}</div>
{role_legend}
<div class="three mb">
<div class="metric"><span class="big">50% → {100*cat_calls["planning"]/n_calls:.0f}%</span><p>planning’s share of engine calls, August to September.</p></div>
<div class="metric"><span class="big">140 → {critic_calls}</span><p>plan critiques. The August critic returned “revise” on 113 of its 140.</p></div>
<div class="metric"><span class="big">{100*ssum(lambda c: c["category"] in ("planning","control","probe"), "output")/E["output"]:.1f}%</span><p>of September engine output tokens went to planning, deciding and probes.</p></div>
</div>

<div class="two">
<div class="card"><p class="tiny">WHAT THE COMPARISON SHOWS</p><p class="small">A different project, task set and campaign length, so this shows a changed role mix, not a controlled result. The three measures above are exactly the behaviours 0.21 set out to remove.</p></div>
<div class="card"><p class="tiny">ONE LABEL TO READ CAREFULLY</p><p class="small">By role label, September planners and critics made 41 calls. 33 of those were engine-repair procedures a supervisor launched under the planner role. They are counted separately here, and they are the first sign of diagnosis two.</p></div>
</div>
<p class="refs mt"><b>Sources.</b> August counts come from the 0.21.0 release notes; the AXON event log independently records 6 integrations and 120 planner failures. September counts come from the campaign event log, with every <code>runner.completed</code> event counted.</p>
<footer class="foot"><span>{FOOT}</span><span class="num">02 / 04</span></footer></article>

<article class="page" id="p3">{TOP}
<div class="kicker">03 / Diagnosis two · September</div>
<h2>Then the overhead moved<br>outside the loop.</h2>
<p class="lead">With planning fixed, the September measurement found a new cost centre. Supervisors wrote {S["output"]/E["output"]:.1f} times the engine’s output to keep it moving. Across the campaign, only {100*landed/ALL_OUT:.0f}% of all output became code on the integration branch.</p>

<div class="diagram">{overview_chart()}</div>
{legend_html()}
<div class="legend wrap sup">{"".join(f'<span><i class="dot" style="background:{SUPCOL[i]}"></i>{SUPNAME[k]}</span>' for i, k in enumerate(SU["layers"]))}</div>

<table class="num">
<tr><th style="width:26%">Root cause</th><th style="width:46%">What it did</th><th style="width:28%">Measured cost</th></tr>
<tr><td>Six lifecycle deadlocks</td><td>The engine refused its own legitimate state. Each stall cost 1–9 hours and needed a supervisor decision.</td><td class="cost">most of the stalled time before the fixes; supervisor tokens cannot be split by cause</td></tr>
<tr><td>Engine repair run through the task loop</td><td>{selfrep["calls"]} procedures on 7–10 September built recovery tooling for the engine itself.</td><td class="cost">{M(selfrep["output"])} output · {100*selfrep["output"]/E["output"]:.0f}% of engine</td></tr>
<tr><td>Provider limits and short clocks</td><td>Session limits, one-hour timeouts and kills stopped workers mid-run with nothing landed.</td><td class="cost">{M(env["output"])} output · ${env["usd"]:.2f}</td></tr>
<tr><td>Work abandoned at the plan pivot</td><td>The original 7–8 September plan was replaced by the rescue plan.</td><td class="cost">{M(orig["output"])} output · {orig_share}% of its code landed</td></tr>
<tr><td>One malformed auditor field</td><td>Every Claude audit since 15 September failed its first try on <code>findingsStatus</code>.</td><td class="cost">{M(prot["output"])} output · ${prot["usd"]:.2f}, {100*prot["usd"]/audit_usd:.0f}% of Claude audit spend</td></tr>
</table>

<div class="two">
<div class="card"><p class="tiny">WHAT COUNTS AS LANDED</p><p class="small">Output counts as landed when a commit from its attempt is an ancestor of the integration branch, whatever the runner reported. Adopted and successor work counts. Accepted work that was never merged does not.</p></div>
<div class="card"><p class="tiny">THREE KINDS OF TOKEN</p><p class="small"><b>Output</b> is what models wrote, and this report leads with it. <b>Fresh input</b> is new prompt material. <b>Cached input</b> is context re-read at a discount, {100*E["cached"]/(E["cached"]+E["fresh"]):.0f}% of engine input. It is never counted as work or money.</p></div>
</div>
<footer class="foot"><span>{FOOT}</span><span class="num">03 / 04</span></footer></article>

<article class="page" id="p4">{TOP}
<div class="kicker">04 / Fixes and progress</div>
<h2>After the lifecycle fixes, supervision<br>fell {sup_drop:.0f}×. One clean run must prove why.</h2>
<p class="lead">The four lifecycle fixes went live at 16:34Z on 14 September. In the {AFT["hours"]:.0f} hours that followed, integrations per day more than doubled. Supervisor output per integration fell from {M(BEF["supervisionOutputPerIntegration"])} to {M(AFT["supervisionOutputPerIntegration"])} tokens.</p>

<div class="diagram">{before_after}</div>

<div class="callout warn"><p class="small"><b>Why this is a signal, not yet proof.</b> The supervisor tool changed on 13–14 September, from Codex with 23 subagents to a single Claude session. The earlier week includes one-off rescue and planning work that the later window did not repeat. The later window covers {AFT["hours"]:.0f} hours and {AFT["integrations"]} integrations, and it still needed hands: the supervisor finalized one dispatch record, adopted the TASK-1114 candidate and merged TASK-1115.</p></div>

<table class="num status-table">
<tr><th style="width:44%">Finding</th><th style="width:28%">Fix: shipped or proposed</th><th>Status</th></tr>
{status_html}
</table>

<div class="callout dark"><p class="small"><b style="color:white">What will count as proof.</b> One campaign on a release that carries the open fixes, reported per integration. It must meet three bars. Supervisor output stays below engine output across the run. Three consecutive representative integrations need no supervisor action: the repository’s own qualification bar, currently 0 of 3. And at least {land_share_a:.0f}% of engine output lands, the level seen after the fixes.</p></div>
<footer class="foot"><span>{FOOT}</span><span class="num">04 / 04</span></footer></article>
</body></html>
'''
Path(OUT).write_text(html, encoding="utf-8")
print("wrote", OUT, len(html), "bytes")
