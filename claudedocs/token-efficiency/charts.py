"""SVG chart generators for the token-efficiency report (design system colours)."""
F = 'font-family="Inter,Arial,sans-serif"'

OUTCOMES = [  # key, label, colour
    ("landed-code", "Code that landed", "#0b8688"),
    ("assurance-on-landed-work", "Audits of landed work", "#7cc3bf"),
    ("in-loop-management", "Planning · deciding · probes", "#46687a"),
    ("engine-self-repair", "Engine self-repair procedures", "#8a74c4"),
    ("work-never-landed", "Code that never landed", "#aebdc6"),
    ("assurance-on-unlanded-work", "Audits of unlanded work", "#d3dde3"),
    ("environment-loss", "Lost: limits · timeouts · kills", "#c98a45"),
    ("protocol-loss", "Lost: invalid verdicts", "#b8573a"),
]
COLOR = {k: c for k, _, c in OUTCOMES}
LABEL = {k: l for k, l, _ in OUTCOMES}


def fmt_m(n):
    return f"{n/1e6:.2f}M" if n >= 1e6 else f"{n/1e3:.0f}k"


def three_lens_bars(by_outcome, totals):
    """Three 100%-stacked bars: output tokens, fresh input tokens, Claude dollars."""
    rows = {r["key"]: r for r in by_outcome}
    lenses = [
        ("Output tokens", "output", f"{fmt_m(totals['output'])} generated"),
        ("Fresh input tokens", "fresh", f"{fmt_m(totals['fresh'])} uncached"),
        ("Claude spend", "usd", f"${totals['usd']:.2f} billed"),
    ]
    W, x0, bw, bh, gap = 650, 128, 400, 30, 22
    h = 18 + len(lenses) * (bh + gap) + 8
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {h}" role="img">']
    y = 18
    for label, field, note in lenses:
        total = sum(rows[k][field] for k in COLOR if k in rows)
        out.append(f'<text x="0" y="{y+19}" {F} font-size="10.6" font-weight="650" fill="#173746">{label}</text>')
        x = x0
        for key, _, col in OUTCOMES:
            if key not in rows or not total:
                continue
            val = rows[key][field]
            w = bw * val / total
            if w <= 0:
                continue
            out.append(f'<rect x="{x:.1f}" y="{y}" width="{w:.1f}" height="{bh}" fill="{col}"/>')
            pct = 100 * val / total
            if w >= 30:
                tc = "white" if key in ("landed-code", "in-loop-management", "engine-self-repair", "environment-loss", "protocol-loss") else "#173746"
                out.append(f'<text x="{x + w/2:.1f}" y="{y+19}" text-anchor="middle" {F} font-size="9" font-weight="700" fill="{tc}">{pct:.0f}%</text>')
            x += w
        out.append(f'<text x="{x0+bw+12}" y="{y+19}" {F} font-size="9.6" fill="#4d6b7c">{note}</text>')
        y += bh + gap
    out.append("</svg>")
    return "".join(out)


def legend_html(keys=None):
    keys = keys or [k for k, _, _ in OUTCOMES]
    items = "".join(
        f'<span><i class="dot" style="background:{COLOR[k]}"></i>{LABEL[k]}</span>' for k in keys)
    return f'<div class="legend wrap">{items}</div>'


def daily_columns(per_day, annotations):
    """Stacked columns of output tokens per day, by outcome."""
    days = list(per_day.keys())
    W, H, left, bottom, top = 650, 196, 44, 162, 30
    maxv = max(sum(v.values()) for v in per_day.values())
    scale = (bottom - top) / (maxv * 1.05)
    colw = (W - left - 10) / len(days)
    bw = colw * 0.62
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" role="img">']
    for tick in (100_000, 200_000, 300_000, 400_000, 500_000, 600_000, 700_000):
        if tick > maxv * 1.05:
            break
        ty = bottom - tick * scale
        out.append(f'<line x1="{left}" y1="{ty:.1f}" x2="{W-6}" y2="{ty:.1f}" stroke="#e4ebef" stroke-width="1"/>')
        out.append(f'<text x="{left-6}" y="{ty+3:.1f}" text-anchor="end" {F} font-size="8.4" fill="#7a909b">{tick//1000}k</text>')
    out.append(f'<line x1="{left}" y1="{bottom}" x2="{W-6}" y2="{bottom}" stroke="#bacdd5" stroke-width="1.2"/>')
    for i, dname in enumerate(days):
        cx = left + colw * i + colw / 2
        yb = bottom
        for key, _, col in OUTCOMES:
            v = per_day[dname].get(key, 0)
            if v <= 0:
                continue
            hgt = v * scale
            out.append(f'<rect x="{cx-bw/2:.1f}" y="{yb-hgt:.1f}" width="{bw:.1f}" height="{hgt:.1f}" fill="{col}"/>')
            yb -= hgt
        out.append(f'<text x="{cx:.1f}" y="{bottom+14}" text-anchor="middle" {F} font-size="8.8" fill="#4d6b7c">{dname[8:10]} Sep</text>')
    for (i0, i1, text) in annotations:
        xa = left + colw * i0 + 4
        xb = left + colw * (i1 + 1) - 4
        out.append(f'<line x1="{xa:.1f}" y1="{top-12}" x2="{xb:.1f}" y2="{top-12}" stroke="#9fb3bd" stroke-width="1"/>')
        out.append(f'<text x="{(xa+xb)/2:.1f}" y="{top-17}" text-anchor="middle" {F} font-size="8.6" font-weight="650" fill="#46687a">{text}</text>')
    out.append(f'<text x="{left}" y="{H-4}" {F} font-size="8" fill="#7a909b">Output tokens per day, stacked by what they produced.</text>')
    out.append("</svg>")
    return "".join(out)


def audit_pair_chart(pairs):
    """Grouped bars sized for a half-width column: rejected first try vs repair try ($)."""
    W, left, top, rowh = 330, 116, 8, 30
    H = top + rowh * len(pairs) + 22
    maxv = max(max(a, b) for _, a, b in pairs) * 1.35
    span = W - left - 58
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" role="img">']
    for i, (label, a, b) in enumerate(pairs):
        y = top + i * rowh
        out.append(f'<text x="{left-8}" y="{y+16}" text-anchor="end" {F} font-size="9.4" font-weight="650" fill="#173746">{label}</text>')
        wa, wb = span * a / maxv, span * b / maxv
        out.append(f'<rect x="{left}" y="{y+3}" width="{wa:.1f}" height="11" rx="2" fill="#b8573a"/>')
        out.append(f'<text x="{left+wa+5:.1f}" y="{y+12}" {F} font-size="8.8" font-weight="650" fill="#8a3f2a">${a:.2f}</text>')
        out.append(f'<rect x="{left}" y="{y+16}" width="{wb:.1f}" height="11" rx="2" fill="#7cc3bf"/>')
        out.append(f'<text x="{left+wb+5:.1f}" y="{y+25}" {F} font-size="8.8" font-weight="650" fill="#0d5f62">${b:.2f}</text>')
    ly = H - 8
    out.append(f'<rect x="{left}" y="{ly-8}" width="9" height="9" rx="2" fill="#b8573a"/><text x="{left+13}" y="{ly}" {F} font-size="8.6" fill="#4d6b7c">rejected first try</text>')
    out.append(f'<rect x="{left+104}" y="{ly-8}" width="9" height="9" rx="2" fill="#7cc3bf"/><text x="{left+117}" y="{ly}" {F} font-size="8.6" fill="#4d6b7c">valid repair try</text>')
    out.append("</svg>")
    return "".join(out)
