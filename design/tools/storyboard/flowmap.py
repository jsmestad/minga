"""Render the design-time flow map: designed scenarios and where their exits go.

Usage: OUT_DIR=path python3 design/tools/storyboard/flowmap.py
Writes StoryboardFlow.dc.html.

Nodes are the designed scenarios plus every scenario their exits reach. Columns
are the number of steps from plain editing. Edges carry the keys (and clicks)
that take you there. Marks come from check.py:
  red border     dead end (no esc or q path home within 3 steps)
  amber border   no mouse path from cold start
  faded          unreachable from cold start by keys
Undesigned targets are drawn hollow in their status colour.
"""
import sys
from collections import deque
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from board import FAINT, JOURNEYS, STATUS, SUB, SURF, TXT, esc, load, page, write  # noqa: E402
from check import check  # noqa: E402

WIDTH = 1440
INNER = WIDTH - 64
NODE_W, NODE_H = 210, 58
ROW = 74
TOP = 40
RED, AMBER = "#e5707a", "#f2b544"


def main():
    scenarios = load()
    by_id = {s["id"]: s for s in scenarios}
    problems = check(scenarios)
    dead = set(problems["dead_end"])
    no_click = set(problems["unreachable_by_click"])
    no_key = set(problems["unreachable_by_key"])

    designed = [s["id"] for s in scenarios if s["status"] == "designed"]
    homes = {s["id"] for s in scenarios if s.get("home")}

    def wanted(src, to):
        # Home scenarios fan out to every leader surface; the inventory shows those.
        # Here a home only links to designed scenarios.
        return to in by_id and (src not in homes or by_id[to]["status"] == "designed")

    nodes = list(designed)
    fanout = {}
    for sid in designed:
        for e in by_id[sid].get("exits", []):
            if not wanted(sid, e["to"]):
                if sid in homes and e["to"] in by_id:
                    fanout[sid] = fanout.get(sid, 0) + 1
                continue
            if e["to"] not in nodes:
                nodes.append(e["to"])

    edges, loops, back_home = {}, {}, {}
    for sid in designed:
        for e in by_id[sid].get("exits", []):
            to = e["to"]
            if not wanted(sid, to):
                continue
            label = e.get("key") or e.get("click") or "event"
            if to == sid:
                loops.setdefault(sid, []).append(label)
            elif to in homes and sid not in homes:
                back_home.setdefault(sid, []).append(label)
            else:
                edges.setdefault((sid, to), []).append(label)
    for sid in nodes:
        if sid in designed:
            continue
        for e in by_id[sid].get("exits", []):
            if e["to"] in homes:
                back_home.setdefault(sid, []).append(e.get("key") or e.get("click"))

    home = "edit.plain" if "edit.plain" in by_id else designed[0]
    depth = {home: 0}
    todo = deque([home])
    adj = {}
    for (a, b) in edges:
        adj.setdefault(a, []).append(b)
    while todo:
        cur = todo.popleft()
        for nxt in adj.get(cur, ()):
            if nxt not in depth:
                depth[nxt] = depth[cur] + 1
                todo.append(nxt)
    maxd = max(depth.values()) if depth else 0
    for n in nodes:
        depth.setdefault(n, maxd + 1)
    ncols = max(depth.values()) + 1
    col_x = [int(i * (INNER - NODE_W) / max(ncols - 1, 1)) for i in range(ncols)]

    jorder = [j for j, _ in JOURNEYS]
    columns = {}
    for n in nodes:
        columns.setdefault(depth[n], []).append(n)
    pos = {}
    for c, members in columns.items():
        members.sort(key=lambda n: (jorder.index(by_id[n]["journey"]), by_id[n]["status"] != "designed", n))
        for i, n in enumerate(members):
            pos[n] = (col_x[c], TOP + 30 + i * ROW)
    height_svg = TOP + 30 + max(len(m) for m in columns.values()) * ROW + 20

    svg = [f'<svg width="{INNER}" height="{height_svg}" viewBox="0 0 {INNER} {height_svg}" xmlns="http://www.w3.org/2000/svg" font-family="-apple-system, system-ui, sans-serif">']
    svg.append('<defs><marker id="ah" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto"><path d="M0 0 L8 4 L0 8 z" fill="#8f8d88"/></marker></defs>')
    for c in range(ncols):
        lab = "Plain editing" if c == 0 else f"{c} step{'s' if c > 1 else ''} away"
        if c == ncols - 1 and any(depth[n] == c and n not in adj for n in nodes) and c > maxd:
            lab = "Other resting views and events"
        svg.append(f'<text x="{col_x[c]}" y="{TOP}" fill="{SUB}" font-size="11.5" font-weight="600">{lab}</text>')

    labels = []
    for (a, b), keys in edges.items():
        x1, y1 = pos[a][0] + NODE_W, pos[a][1] + NODE_H / 2
        x2, y2 = pos[b][0], pos[b][1] + NODE_H / 2
        if x2 > x1:
            mx = (x1 + x2) / 2
            d = f"M{x1} {y1} C{mx} {y1}, {mx} {y2}, {x2} {y2}"
            lx, ly = mx, (y1 + y2) / 2
        else:
            # back edge: leave from the left of the source, enter the right of the target
            x1, x2 = pos[a][0], pos[b][0] + NODE_W
            bend = 34
            d = f"M{x1} {y1} C{x1 - bend} {y1}, {x2 + bend} {y2}, {x2} {y2}"
            lx, ly = (x1 + x2) / 2, (y1 + y2) / 2
        svg.append(f'<path d="{d}" fill="none" stroke="#8f8d88" stroke-opacity="0.32" stroke-width="1.2" marker-end="url(#ah)"/>')
        text = " · ".join(dict.fromkeys(keys))
        if len(text) > 22:
            text = text[:21] + "…"
        labels.append((lx, ly, text))
    for lx, ly, text in labels:
        w = 6.2 * len(text) + 8
        svg.append(f'<rect x="{lx - w / 2}" y="{ly - 8}" width="{w}" height="15" rx="3" fill="#1e1f24" fill-opacity="0.85"/>')
        svg.append(f'<text x="{lx}" y="{ly + 3.5}" fill="#c9c7c2" font-size="10" text-anchor="middle" font-family="ui-monospace, Menlo, monospace">{esc(text)}</text>')

    for n in nodes:
        s = by_id[n]
        x, y = pos[n]
        color = STATUS[s["status"]][0]
        is_designed = s["status"] == "designed"
        stroke, sw, dash = color, 1.2, "" if is_designed else ' stroke-dasharray="4 3"'
        if n in dead:
            stroke, sw, dash = RED, 2.4, ""
        elif n in no_click:
            stroke, sw, dash = AMBER, 2, ""
        opacity = ' opacity="0.45"' if n in no_key else ""
        fill = SURF if is_designed else "#1e1f24"
        svg.append(f'<g{opacity}><rect x="{x}" y="{y}" width="{NODE_W}" height="{NODE_H}" rx="7" fill="{fill}" stroke="{stroke}" stroke-width="{sw}"{dash}/>')
        title = s["title"] if len(s["title"]) <= 31 else s["title"][:30] + "…"
        svg.append(f'<text x="{x + 10}" y="{y + 18}" fill="{TXT if is_designed else SUB}" font-size="11.5" font-weight="600">{esc(title)}</text>')
        svg.append(f'<text x="{x + 10}" y="{y + 32}" fill="{FAINT}" font-size="10" font-family="ui-monospace, Menlo, monospace">{esc(n)}</text>')
        extra = []
        if n in back_home:
            extra.append("⤺ " + " · ".join(k for k in dict.fromkeys(back_home[n]) if k))
        if n in loops:
            extra.append("↻ " + " · ".join(dict.fromkeys(loops[n])))
        if n in fanout:
            extra.append(f"+{fanout[n]} leader keys to other surfaces")
        line = "   ".join(extra)
        if len(line) > 40:
            line = line[:39] + "…"
        tcolor = RED if n in dead else "#8fbf8a" if n in back_home else FAINT
        if line:
            svg.append(f'<text x="{x + 10}" y="{y + 47}" fill="{tcolor}" font-size="10" font-family="ui-monospace, Menlo, monospace">{esc(line)}</text>')
        elif n in dead:
            svg.append(f'<text x="{x + 10}" y="{y + 47}" fill="{RED}" font-size="10">no way home</text>')
        svg.append("</g>")
    svg.append("</svg>")

    def chip(color, text, style="solid"):
        border = f"2px {style} {color}"
        return f'<span style="display:inline-flex;align-items:center;gap:7px;margin-right:18px"><span style="width:16px;height:10px;border-radius:3px;border:{border}"></span>{text}</span>'

    legend = (
        chip(STATUS["designed"][0], "Designed")
        + chip(STATUS["missing"][0], "Missing target", "dashed")
        + chip(STATUS["existing-only"][0], "Existing-only target", "dashed")
        + chip(RED, "Dead end")
        + chip(AMBER, "No mouse path from cold start")
        + '<span style="opacity:0.45;margin-right:18px">Faded: no key path from cold start</span>'
        + '<span style="color:#8fbf8a;font-family:ui-monospace,Menlo,monospace;font-size:12px">⤺ keys that return to editing</span>'
    )
    counts = {k: len(v) for k, v in problems.items()}
    body = f"""<div style="font-size:22px;font-weight:700">Design-time flow map</div>
<div style="color:{SUB};margin:6px 0 12px">The designed scenarios and every scenario their exits reach, by key and by click. Returns to editing are listed on each node (⤺) instead of drawn; plain editing's links to undesigned surfaces are counted, and listed in the inventory. Generated from docs/design/scenarios.toml and checked by design/tools/storyboard/check.py: {counts['dead_end']} dead ends, {counts['unreachable_by_key']} with no key path, {counts['parity']} transient exits with a click but no key. Pending the mouse sweep: {counts['unreachable_by_click']} scenarios with no mouse path and {counts['no_click']} transient exits with no click.</div>
<div style="margin-bottom:14px">{legend}</div>
{''.join(svg)}"""
    height = height_svg + 150
    write("StoryboardFlow.dc.html", page("Storyboard flow map", body, WIDTH, height))
    print(f"height {height}")


if __name__ == "__main__":
    main()
