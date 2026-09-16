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


# ---------------------------------------------------------------- redesign charts
KIND = {  # pill background, pill text, node fill, node stroke, dashed
    "diagnosis": ("#fff0dc", "#945514", "#c98a45", "#c98a45", False),
    "fix": ("#153242", "#ffffff", "#153242", "#153242", False),
    "proof": ("#e6f4f2", "#077477", "#0b8688", "#0b8688", False),
    "signal": ("#e3f1f0", "#0b6f72", "#7cc3bf", "#0b8688", False),
    "next": ("#ffffff", "#587180", "#ffffff", "#9fb3bd", True),
}


def timeline_chart(nodes):
    """nodes: [(date, sub, kind, pill_text, [lines...]), ...] evenly spaced."""
    W, H = 650, 144
    n = len(nodes)
    x0, x1 = 54, W - 54
    step = (x1 - x0) / (n - 1)
    ly = 46
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" role="img">']
    solid_end = x0 + step * (n - 2)
    out.append(f'<line x1="{x0}" y1="{ly}" x2="{solid_end:.1f}" y2="{ly}" stroke="#bacdd5" stroke-width="2"/>')
    out.append(f'<line x1="{solid_end:.1f}" y1="{ly}" x2="{x1}" y2="{ly}" stroke="#bacdd5" stroke-width="2" stroke-dasharray="4 4"/>')
    for i, (date, sub, kind, pill, lines) in enumerate(nodes):
        cx = x0 + step * i
        pb, pt, nf, ns, dashed = KIND[kind]
        out.append(f'<text x="{cx:.1f}" y="14" text-anchor="middle" {F} font-size="9.6" font-weight="700" fill="#173746">{date}</text>')
        out.append(f'<text x="{cx:.1f}" y="28" text-anchor="middle" {F} font-size="8.5" fill="#5c7380">{sub}</text>')
        dash = ' stroke-dasharray="3 2"' if dashed else ""
        out.append(f'<circle cx="{cx:.1f}" cy="{ly}" r="6.5" fill="{nf}" stroke="{ns}" stroke-width="2"{dash}/>')
        pw = max(52, 5.0 * len(pill) + 14)
        out.append(f'<rect x="{cx-pw/2:.1f}" y="{ly+14}" width="{pw:.1f}" height="16" rx="8" fill="{pb}" stroke="{ns if dashed else pb}"{dash}/>')
        out.append(f'<text x="{cx:.1f}" y="{ly+25.5}" text-anchor="middle" {F} font-size="7.4" font-weight="750" letter-spacing="0.5" fill="{pt}">{pill}</text>')
        for j, line in enumerate(lines):
            weight = ' font-weight="650"' if j == 0 else ""
            out.append(f'<text x="{cx:.1f}" y="{ly+48+j*12.5:.1f}" text-anchor="middle" {F} font-size="8.6"{weight} fill="#173746">{line}</text>')
    out.append("</svg>")
    return "".join(out)


def role_mix_chart(aug, sep, per_integration):
    """aug/sep: (title, subtitle, [(value, colour, inside_label), ...]); per_integration: [(label, value, colour)]."""
    W, x0, bw, bh = 650, 170, 400, 28
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} 138" role="img">']
    y = 6
    for title, subtitle, segs in (aug, sep):
        total = sum(v for v, _, _ in segs)
        out.append(f'<text x="0" y="{y+12}" {F} font-size="10.2" font-weight="650" fill="#173746">{title}</text>')
        out.append(f'<text x="0" y="{y+25}" {F} font-size="8.8" fill="#5c7380">{subtitle}</text>')
        x = x0
        for v, col, lab in segs:
            w = bw * v / total
            out.append(f'<rect x="{x:.1f}" y="{y}" width="{w:.1f}" height="{bh}" fill="{col}"/>')
            if lab and w >= 40:
                tc = "#173746" if col in ("#aebdc6", "#7cc3bf") else "white"
                out.append(f'<text x="{x+w/2:.1f}" y="{y+18}" text-anchor="middle" {F} font-size="8.8" font-weight="700" fill="{tc}">{lab}</text>')
            x += w
        y += bh + 20
    out.append(f'<text x="0" y="{y+12}" {F} font-size="10.2" font-weight="650" fill="#173746">Calls per integration</text>')
    out.append(f'<text x="0" y="{y+25}" {F} font-size="8.8" fill="#5c7380">same scale</text>')
    mx = max(v for _, v, _ in per_integration)
    for k, (lab, v, col) in enumerate(per_integration):
        yy = y + k * 17
        w = bw * v / mx
        out.append(f'<rect x="{x0}" y="{yy}" width="{w:.1f}" height="12" rx="2" fill="{col}"/>')
        out.append(f'<text x="{x0+w+6:.1f}" y="{yy+10}" {F} font-size="9" font-weight="700" fill="#173746">{v:.0f}</text>')
        out.append(f'<text x="{x0-8}" y="{yy+10}" text-anchor="end" {F} font-size="8.6" fill="#4d6b7c">{lab}</text>')
    out.append("</svg>")
    return "".join(out)


def before_after_chart(rows, before_label, after_label):
    """rows: [(metric, direction_note, before, after, fmt)] — each row on its own scale."""
    W, lx, x0, bw = 650, 0, 214, 330
    rowh = 40
    H = 22 + rowh * len(rows)
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" role="img">']
    out.append(f'<rect x="{x0}" y="4" width="10" height="10" rx="2" fill="#aebdc6"/><text x="{x0+15}" y="13" {F} font-size="8.8" fill="#4d6b7c">{before_label}</text>')
    out.append(f'<rect x="{x0+196}" y="4" width="10" height="10" rx="2" fill="#0b8688"/><text x="{x0+211}" y="13" {F} font-size="8.8" fill="#4d6b7c">{after_label}</text>')
    y = 24
    for metric, note, b, a, fmt in rows:
        mx = max(a, b) * 1.08
        out.append(f'<text x="{lx}" y="{y+14}" {F} font-size="9.8" font-weight="650" fill="#173746">{metric}</text>')
        out.append(f'<text x="{lx}" y="{y+27}" {F} font-size="8.4" fill="#7a909b">{note}</text>')
        wb, wa = bw * b / mx, bw * a / mx
        out.append(f'<rect x="{x0}" y="{y+2}" width="{wb:.1f}" height="14" rx="2" fill="#aebdc6"/>')
        out.append(f'<text x="{x0+wb+6:.1f}" y="{y+13}" {F} font-size="9.2" font-weight="650" fill="#46687a">{fmt(b)}</text>')
        out.append(f'<rect x="{x0}" y="{y+19}" width="{max(wa,2):.1f}" height="14" rx="2" fill="#0b8688"/>')
        out.append(f'<text x="{x0+max(wa,2)+6:.1f}" y="{y+30}" {F} font-size="9.2" font-weight="750" fill="#0b6f72">{fmt(a)}</text>')
        y += rowh
    out.append("</svg>")
    return "".join(out)
