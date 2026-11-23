"""Render the storyboard inventory board: every scenario, grouped by journey.

Usage: OUT_DIR=path python3 design/tools/storyboard/inventory.py
Writes StoryboardInventory.dc.html.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from board import FAINT, JOURNEYS, STATUS, SUB, SURF, TXT, esc, load, page, write  # noqa: E402

WIDTH = 1440
COLS = 4
TILE_H = 92
GAP = 10


def tile(s):
    color, label = STATUS[s["status"]]
    removed = s["status"] == "removed"
    title_style = f"color:{FAINT};text-decoration:line-through" if removed else f"color:{TXT}"
    fronts = " · ".join("macOS" if f == "macos" else "TUI" for f in s.get("frontends", []))
    boards = s.get("boards") or {}
    board_txt = " · ".join(f"{'macOS' if k == 'macos' else 'TUI'}: {esc(v.replace('.dc.html', ''))}" for k, v in boards.items())
    link = f'<div style="color:#7fbf7a;font-size:11px;margin-top:4px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{board_txt}</div>' if board_txt else ""
    return f"""<div style="height:{TILE_H}px;box-sizing:border-box;background:{SURF};border-radius:8px;border-left:3px solid {color};padding:9px 12px;overflow:hidden">
<div style="display:flex;align-items:center;gap:8px"><span style="font-size:10.5px;font-weight:600;color:{color};text-transform:none">{label}</span><span style="flex:1"></span><span style="font-size:10.5px;color:{FAINT}">{fronts}</span></div>
<div style="{title_style};font-weight:600;font-size:12.5px;line-height:16px;margin-top:3px;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden">{esc(s['title'])}</div>
<div style="font-family:ui-monospace,'SF Mono',Menlo,monospace;font-size:10.5px;color:{FAINT};margin-top:2px">{esc(s['id'])}</div>
{link}
</div>"""


def main():
    scenarios = load()
    counts = {k: sum(1 for s in scenarios if s["status"] == k) for k in STATUS}
    legend = " ".join(
        f'<span style="display:inline-flex;align-items:center;gap:6px;margin-right:18px"><span style="width:10px;height:10px;border-radius:2px;background:{c}"></span>{lab} <span style="color:{SUB}">{counts[k]}</span></span>'
        for k, (c, lab) in STATUS.items()
    )
    parts = [
        f'<div style="font-size:22px;font-weight:700">Storyboard inventory</div>',
        f'<div style="color:{SUB};margin:6px 0 14px">Every screen and state on macOS and in the TUI, from docs/design/scenarios.toml. {len(scenarios)} scenarios.</div>',
        f'<div style="margin-bottom:18px">{legend}</div>',
    ]
    height = 150
    for key, label in JOURNEYS:
        group = [s for s in scenarios if s["journey"] == key]
        if not group:
            continue
        c = {k: sum(1 for s in group if s["status"] == k) for k in STATUS}
        summary = " · ".join(f"{c[k]} {STATUS[k][1].lower()}" for k in STATUS if c[k])
        parts.append(f'<div style="display:flex;align-items:baseline;gap:12px;margin:18px 0 8px"><span style="font-size:15px;font-weight:700">{label}</span><span style="color:{SUB};font-size:12px">{summary}</span></div>')
        parts.append(f'<div style="display:grid;grid-template-columns:repeat({COLS},1fr);gap:{GAP}px">' + "".join(tile(s) for s in group) + "</div>")
        rows = -(-len(group) // COLS)
        height += 44 + rows * (TILE_H + GAP)
    height += 40
    write("StoryboardInventory.dc.html", page("Storyboard inventory", "\n".join(parts), WIDTH, height))
    print(f"height {height}")


if __name__ == "__main__":
    main()
