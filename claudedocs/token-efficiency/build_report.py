#!/usr/bin/env python3
"""Build the token-efficiency report HTML from the computed ledgers."""
import collections, json, sys
from charts import F, OUTCOMES, COLOR, LABEL, three_lens_bars, legend_html, daily_columns, audit_pair_chart

LEDGER, FIG, SUP, OUT = sys.argv[1:5]
L = json.load(open(LEDGER)); calls = L["calls"]
FG = json.load(open(FIG))
SU = json.load(open(SUP))

def M(n, d=2):
    return f"{n/1e9:.2f}B" if n >= 1e9 else (f"{n/1e6:.{d}f}M" if n >= 1e6 else (f"{n/1e3:.0f}k" if n >= 1e3 else f"{n:,}"))

def ssum(pred, k):
    return sum((c.get(k) or 0) for c in calls if pred(c))

E = {k: ssum(lambda c: True, k2) for k, k2 in (("fresh", "freshInput"), ("cached", "cachedInput"), ("output", "output"))}
S = SU["total"]
ALL_OUT = E["output"] + S["output"]
landed = ssum(lambda c: str(c["yield"]).startswith("landed"), "output")
mgmt = ssum(lambda c: c["category"] in ("planning", "control", "probe"), "output")
ratio_out = S["output"] / E["output"]
ratio_tot = sum(S.values()) / sum(E.values())
usd_engine = sum(c.get("costUsd") or 0 for c in calls)
by_out = {r["key"]: r for r in FG["byOutcome"]}
by_cat = {r["key"]: r for r in FG["byCategory"]}
cached_share = 100 * E["cached"] / (E["cached"] + E["fresh"])

SUPNAME = {
    "Codex interactive supervisor (7–14 Sep)": ("Codex interactive supervisor", "7–14 Sep · 3 threads, 23 subagents"),
    "Supervisor-launched recovery runs (codex exec, 12–13 Sep)": ("Supervisor-launched recovery runs", "12–13 Sep · 87 codex exec calls"),
    "Claude interactive supervisor (13–16 Sep, to close)": ("Claude interactive supervisor", "13–16 Sep · 2 sessions, to close"),
    "Supervisor claude -p reviews": ("Supervisor review calls", "claude -p · 6 calls · $18.14"),
    "Grok worker experiments (13 Sep)": ("Grok worker experiments", "13 Sep · 2 workers, 1 unrecorded · input not split"),
    "Supervisor probe sessions": ("Probe and continuation sessions", "5 transcript-only sessions"),
}

# ---------------------------------------------------------------- charts
SUPCOL = ["#4b3d7a", "#7a65b8", "#a18fd6", "#c3b6ec", "#d8cff5", "#ebe6fb"]

def overview_chart():
    W, x0, bw, bh = 650, 150, 392, 30
    rows = []
    # row 1: all output
    engine_other = E["output"] - landed
    rows.append(("All model output", M(ALL_OUT), [
        (landed, "#0b8688", "landed code", "white"),
        (engine_other, "#aebdc6", "other engine work", "#173746"),
        (S["output"], "#6a57a8", "supervision outside the loop", "white"),
    ]))
    rows.append(("Engine calls", M(E["output"]), [
        (by_out[k]["output"], COLOR[k], None, "white" if k in ("landed-code", "in-loop-management", "engine-self-repair", "environment-loss", "protocol-loss") else "#173746")
        for k, _, _ in OUTCOMES if k in by_out]))
    layers = list(SU["layers"].items())
    rows.append(("Supervision", M(S["output"]), [
        (v["output"], SUPCOL[i], None, "white" if i < 2 else "#173746") for i, (k, v) in enumerate(layers)]))
    H = 16 + len(rows) * (bh + 30) + 4
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" role="img">']
    y = 16
    for label, total_s, segs in rows:
        tot = sum(s[0] for s in segs)
        out.append(f'<text x="0" y="{y+13}" {F} font-size="10.8" font-weight="650" fill="#173746">{label}</text>')
        out.append(f'<text x="0" y="{y+27}" {F} font-size="9.2" fill="#5c7380">{total_s} output tokens</text>')
        x = x0
        for val, col, name, tc in segs:
            w = bw * val / tot if tot else 0
            if w <= 0:
                continue
            out.append(f'<rect x="{x:.1f}" y="{y}" width="{w:.1f}" height="{bh}" fill="{col}"/>')
            pct = 100 * val / tot
            if w >= 34:
                out.append(f'<text x="{x+w/2:.1f}" y="{y+19}" text-anchor="middle" {F} font-size="9.2" font-weight="700" fill="{tc}">{pct:.0f}%</text>')
            x += w
        if label == "All model output":
            out.append(f'<text x="{x0+bw+10}" y="{y+6}" {F} font-size="8.4" fill="#0b6f72" font-weight="650">■ landed code</text>')
            out.append(f'<text x="{x0+bw+10}" y="{y+17}" {F} font-size="8.4" fill="#6b8290" font-weight="650">■ other engine work</text>')
            out.append(f'<text x="{x0+bw+10}" y="{y+28}" {F} font-size="8.4" fill="#5b4a8b" font-weight="650">■ supervision</text>')
        elif label == "Engine calls":
            out.append(f'<text x="{x0+bw+10}" y="{y+12}" {F} font-size="8.8" fill="#4d6b7c">by what the</text>')
            out.append(f'<text x="{x0+bw+10}" y="{y+25}" {F} font-size="8.8" fill="#4d6b7c">tokens produced</text>')
        else:
            out.append(f'<text x="{x0+bw+10}" y="{y+12}" {F} font-size="8.8" fill="#4d6b7c">by session type,</text>')
            out.append(f'<text x="{x0+bw+10}" y="{y+25}" {F} font-size="8.8" fill="#4d6b7c">to campaign close</text>')
        y += bh + 30
    out.append("</svg>")
    return "".join(out)

per_day = FG["perDayOutputByOutcome"]
day_chart = daily_columns(per_day, [(0, 0, "original plan"), (1, 3, "engine self-repair"), (4, 6, "Codex delivery"), (7, 9, "Claude delivery")])

pairs = collections.defaultdict(dict)
for c in calls:
    if c["provider"] == "claude" and c["category"] == "audit" and "attempt" in c:
        pairs[(c["runId"], c["attempt"])][c["try"]] = c
pair_rows = []
for (rid, n), v in sorted(pairs.items()):
    if 0 in v and 1 in v:
        tid = v[0].get("taskId")
        label = f"{tid} · {'round 2' if rid.endswith('27580') else 'round 1'}" if tid == "TASK-1115" else tid
        pair_rows.append((label, v[0]["costUsd"], v[1]["costUsd"]))
rej_usd = sum(a for _, a, _ in pair_rows)
ok_usd = sum(b for _, _, b in pair_rows)
audit_usd = by_cat["audit"]["usd"]

# ---------------------------------------------------------------- tables
CATNAME = {"build": "Implementation", "audit": "Audit", "recovery": "Engine self-repair procedures",
           "planning": "Planning (planner + critic)", "control": "Deciding", "probe": "Provider probes"}
cached_by = {k: ssum(lambda c, k=k: c["category"] == k, "cachedInput") for k in CATNAME}
cat_rows = ""
for k in ("build", "recovery", "audit", "planning", "control", "probe"):
    r = by_cat[k]
    cat_rows += (f'<tr><td>{CATNAME[k]}</td><td class="n">{r["calls"]}</td><td class="n">{M(r["output"])} <span class="muted">{r["pctOutput"]:.1f}%</span></td>'
                 f'<td class="n">{M(r["fresh"])}</td><td class="n">{M(cached_by[k],0)}</td><td class="n">{"$%.2f" % r["usd"] if r["usd"] else "—"}</td></tr>')

lin_rows = ""
share = FG["landedShareOfBuildByLineage"]
order = ["B1 package + ingest", "B2 context service", "B3 invocation coverage", "B4 reviewed memory",
         "B5 evaluation harness", "Reconciliation discovery (0.23.0)", "Invocation admission (0.23.1)",
         "Brain-package maintenance", "Original plan, 7-8 Sep (abandoned at pivot)"]
lin = {r["key"]: r for r in FG["byLineage"]}
for k in order:
    r = lin[k]
    sh = share.get(k)
    bar = f'<span class="minibar"><i style="width:{sh}%"></i></span> {sh}%' if sh is not None else "—"
    lin_rows += (f'<tr><td>{k.replace(", 7-8 Sep", ", 7–8 Sep")}</td><td class="n">{r["calls"]}</td><td class="n">{M(r["output"])}</td>'
                 f'<td>{bar}</td><td class="n">{"$%.2f" % r["usd"] if r["usd"] else "—"}</td></tr>')

sup_rows = ""
for i, (k, v) in enumerate(SU["layers"].items()):
    nm, sub = SUPNAME[k]
    sup_rows += (f'<tr><td><i class="dot" style="background:{SUPCOL[i]}"></i>{nm}<br><span class="muted small2">{sub}</span></td>'
                 f'<td class="n">{M(v["fresh"])}</td><td class="n">{M(v["cached"],0)}</td>'
                 f'<td class="n">{M(v["output"])} <span class="muted">{100*v["output"]/S["output"]:.0f}%</span></td></tr>')
sup_rows += (f'<tr class="total"><td>Supervision total</td><td class="n">{M(S["fresh"])}</td><td class="n">{M(S["cached"])}</td><td class="n">{M(S["output"])}</td></tr>'
             f'<tr class="total muted"><td>Engine total, for comparison</td><td class="n">{M(E["fresh"])}</td><td class="n">{M(E["cached"],0)}</td><td class="n">{M(E["output"])}</td></tr>')

verd = FG["auditVerdicts"]
nf, acc, blk = verd.get("verdict:needs-fix", 0), verd.get("verdict:accepted", 0), verd.get("verdict:blocked", 0)
valid = nf + acc + blk
env = by_out["environment-loss"]
selfrep = by_cat["recovery"]

REPORT_DATE = "16 SEP 2026"
FOOT = 'Campaign <b>BRAIN-RESCUE-20260910</b> · engine 0.23.2 · 7–16 Sep 2026'

CSS = open(__file__.replace("build_report.py", "report.css")).read()

html = f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Singular Token Efficiency</title><style>{CSS}</style></head><body>
<nav><a href="#p1">Where tokens went</a><a href="#p2">Inside the loop</a><a href="#p3">Assurance &amp; loss</a><a href="#p4">Outside the loop</a></nav>

<article class="page" id="p1"><div class="topline">Singular / token efficiency report <span>0.23.2 · {REPORT_DATE}</span></div>
<div class="kicker">01 / Where the tokens went</div>
<h2>Supervising the engine<br>cost more than running it.</h2>
<p class="lead">Between 7 and 16 September the brain campaign’s models wrote {M(ALL_OUT)} output tokens. The engine’s own provider calls account for {M(E["output"])} of them. Supervisors working outside the loop — diagnosing, repairing and relaunching the engine — wrote {M(S["output"])}.</p>

<div class="three mb">
<div class="metric"><span class="big">{100*landed/ALL_OUT:.0f}%</span><p>of all output tokens became code that reached the integration branch ({M(landed)}).</p></div>
<div class="metric"><span class="big">{ratio_out:.1f}×</span><p>supervision output relative to engine output; {ratio_tot:.1f}× counting every token.</p></div>
<div class="metric"><span class="big">{100*mgmt/E["output"]:.1f}%</span><p>of engine output went to in-loop planning, deciding and probes.</p></div>
</div>

<div class="diagram">{overview_chart()}</div>
{legend_html()}
<div class="legend wrap sup">{"".join(f'<span><i class="dot" style="background:{SUPCOL[i]}"></i>{SUPNAME[k][0]}</span>' for i, k in enumerate(SU["layers"]))}</div>

<div class="two">
<div class="card"><p class="tiny">WHAT COUNTS AS LANDED</p><p class="small">A call’s output counts as landed when a commit from its attempt is an ancestor of <code>codex/brain-integration</code>, whatever the runner reported. Adopted and successor candidates count. Work that was accepted but never merged does not.</p></div>
<div class="card"><p class="tiny">THREE KINDS OF TOKEN, NEVER SUMMED AS WORK</p><p class="small"><b>Output</b> is what models wrote. <b>Fresh input</b> is new prompt material. <b>Cached input</b> is context re-read at a discount — {cached_share:.0f}% of engine input — and is reported separately, never as work or money.</p></div>
</div>

<div class="callout dark"><p class="small"><b style="color:white">The problem moved.</b> In the 0.20 AXON campaign, planners and critics made half of all engine calls. Here, genuine planning made 8 of {len(calls)}, and planning, deciding and probes together wrote under 2% of engine output. The overhead now sits outside the loop, in supervisor sessions that no engine metric records.</p></div>

<p class="refs">Engine: {len(calls)} calls from <code>runner.completed</code> events; {FG["recoveredCalls"]} calls with no recorded usage were recovered from provider session logs; 2 remain unknown. Supervision: 87 supervisor-launched exec calls, review envelopes and supervisor transcripts, cut at the 0.23.2 release (16 Sep 10:11Z). Claude dollars come from provider envelopes; Codex ran on quota.</p>
<footer class="foot"><span>{FOOT}</span><span class="num">01 / 04</span></footer></article>

<article class="page" id="p2"><div class="topline">Singular / token efficiency report <span>0.23.2 · {REPORT_DATE}</span></div>
<div class="kicker">02 / Inside the loop</div>
<h2>The engine’s own bureaucracy is small.<br>Its failures are not.</h2>
<p class="lead">Two-thirds of engine output went to implementation, and deterministic policy made most control decisions without a model. The waste sits in three places: work the engine performed on itself, environment failures, and work that never landed.</p>

<div class="diagram">{three_lens_bars(FG["byOutcome"], {"output": E["output"], "fresh": E["fresh"], "usd": usd_engine})}</div>
<p class="caption">Engine calls only. The same outcomes, weighed three ways: what models wrote, what fresh context they read, and what Claude billed.</p>

<table class="num">
<tr><th style="width:34%">Engine call category</th><th class="n">Calls</th><th class="n">Output</th><th class="n">Fresh input</th><th class="n">Cached</th><th class="n">Claude $</th></tr>
{cat_rows}
</table>

<div class="three">
<div class="card"><p class="tiny">CONTROL IS NEARLY FREE</p><p class="small">20 of 24 failure decisions went through the deterministic fast path with no model call. 1,774 reconcile cycles ran entirely in code.</p></div>
<div class="card"><p class="tiny">SELF-REPAIR IS NOT</p><p class="small">On 7–10 September, 53 calls built recovery controllers, proof fixtures and audit bridges for the engine itself: {100*selfrep["output"]/E["output"]:.0f}% of output. They ran under the planner role, so role metrics count them as planning.</p></div>
<div class="card"><p class="tiny">BEFORE AND AFTER 0.21</p><p class="small">AXON (0.20): planners and critics made 430 of 855 calls. Here those roles made 41 of {len(calls)}, and 33 were the repair procedures. Planning proper: 8 calls. Different project, so this is not a controlled comparison.</p></div>
</div>
<p class="refs mt"><b>Method.</b> Engine usage comes from <code>runner.completed</code> events, never overwritten sidecars. Provider semantics are normalised: Codex input includes cached tokens; Claude cache writes count as fresh input. Landing is tested with <code>git merge-base --is-ancestor</code>, including successor and adopted commits named by run ID. The Codex supervisor total sums per-event counter increases, handling resets and forked subagents. Claude sessions are de-duplicated by message ID. Supervision stops at the 0.23.2 release, so this report’s own analysis is excluded.</p>
<footer class="foot"><span>{FOOT}</span><span class="num">02 / 04</span></footer></article>

<article class="page" id="p3"><div class="topline">Singular / token efficiency report <span>0.23.2 · {REPORT_DATE}</span></div>
<div class="kicker">03 / Assurance and loss</div>
<h2>Audits earn their keep. One malformed<br>field wastes most of their dollars.</h2>
<p class="lead">Auditing took {by_cat["audit"]["pctOutput"]:.0f}% of engine output and returned needs-fix on {nf} of {valid} valid verdicts. On Claude, a single prompt defect made every audit since 15 September run twice.</p>

<div class="diagram">{day_chart}</div>

<div class="two">
<div>
<h3>Since 15 September, every first audit try fails</h3>
<p class="small">All four rejections carry the same host error: <code>findingsStatus must be an object</code>. The prompt names the field as optional without giving its shape. The model guesses wrong, the host rejects the verdict, and a repair try with the error attached passes. Rejected tries cost ${rej_usd:.2f}, which is {100*rej_usd/audit_usd:.0f}% of Claude audit spend and {rej_usd/ok_usd:.1f}× the valid tries.</p>
</div>
<div><div class="diagram tight">{audit_pair_chart(pair_rows)}</div></div>
</div>

<h3 class="mt">Where build tokens were lost</h3>
<p class="small">Limits, timeouts and kills cost {env["calls"]} calls, {M(env["output"])} output and ${env["usd"]:.2f} of Claude spend with nothing landed. Two one-hour clocks timed out TASK-1114 with no source edits (${ssum(lambda c: c.get("taskId")=="TASK-1114" and c["yield"]=="lost:timeout","costUsd"):.2f}). A session limit killed a TASK-1106 worker (${ssum(lambda c: c.get("taskId")=="TASK-1106" and c["yield"]=="lost:quota","costUsd"):.2f}). A TASK-1115 worker killed the same way was salvaged, and its code landed. Codex timeouts recorded no usage; their session logs show {M(ssum(lambda c: c["provider"]=="codex" and c in [x for x in calls if x["category"] not in ("recovery","planning","control","probe") and x["yield"]=="lost:timeout"],"output"))} output tokens that never produced a commit.</p>

<table class="num">
<tr><th style="width:40%">Work stream</th><th class="n">Calls</th><th class="n">Output</th><th>Build output that landed</th><th class="n">Claude $</th></tr>
{lin_rows}
</table>
<footer class="foot"><span>{FOOT}</span><span class="num">03 / 04</span></footer></article>

<article class="page" id="p4"><div class="topline">Singular / token efficiency report <span>0.23.2 · {REPORT_DATE}</span></div>
<div class="kicker">04 / Outside the loop</div>
<h2>Supervision is the number<br>to drive down.</h2>
<p class="lead">Supervisors only spent these tokens because the engine could not finish unattended. They produced real fixes — six lifecycle deadlocks diagnosed, runtimes A12–A16 built, releases 0.22.0–0.23.2 shipped — but none of it is the product the campaign set out to build.</p>

<table class="num">
<tr><th style="width:44%">Supervision layer</th><th class="n">Fresh input</th><th class="n">Cached input</th><th class="n">Output</th></tr>
{sup_rows}
</table>

<h3 class="mt">What to change next</h3>
<ol class="reclist">
<li><b>Measure supervision, not only the engine.</b> Report supervisor tokens per integration beside engine tokens per integration. Today no engine metric sees {100*S["output"]/ALL_OUT:.0f}% of output.</li>
<li><b>Label engine self-repair as its own role.</b> Its 53 calls ran as “planner”. Also fix <code>singular metrics</code>, which sums raw input across providers so Claude calls barely register.</li>
<li><b>Stop retrying into provider limits.</b> Check session headroom before a long implementer call and back off after a 429. The engine retried immediately into the same limit.</li>
<li><b>Size worker clocks from the contract</b> and keep the partial transcript on timeout. Both TASK-1114 timeouts left nothing to resume.</li>
<li><b>Fix the auditor’s first try.</b> Give <code>findingsStatus</code> its exact shape in the prompt, or omit it from first-round audits: about ${rej_usd/len(pair_rows):.2f} and {M(ssum(lambda c: c['yield']=='lost:invalid-or-infra-verdict','output')/len(pair_rows))} output tokens saved per audited task.</li>
</ol>
<div class="two mt">
<div class="card"><p class="tiny">ESTABLISHED</p><p class="small">Where the recorded tokens went, which engine output reached the branch, and the ratio of supervision to engine tokens in this campaign.</p></div>
<div class="card"><p class="tiny">NOT ESTABLISHED</p><p class="small">Whether this much supervision was avoidable at this engine version. The dollar cost of Codex (quota) or of interactive Claude sessions (subscription). Anything beyond this one campaign.</p></div>
</div>


<footer class="foot"><span>{FOOT}</span><span class="num">04 / 04</span></footer></article>
</body></html>
'''
open(OUT, "w", encoding="utf-8").write(html)
print("wrote", OUT, len(html), "bytes")
