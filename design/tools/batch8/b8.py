# Batch 8: the two designed scenarios whose boards covered one frontend only (#4036, AC 1).
#   code.diagnostics.hover: the TUI half (the macOS half is the hand-made V3Diagnostics board).
#   windows.focus_lost: the macOS half (the TUI half is V41TuiTerminalPowers, section 3).
# Both reuse the batch 7 building blocks, so they share its metrics and colours.
import os as _os
TOOLS = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))
import os
S = TOOLS
os.environ.setdefault("OUT_DIR", S + "/batch8/out")
_out = os.environ["OUT_DIR"]
os.environ["OUT_DIR"] = _out + "/_b7"  # batch 7 writes its own boards while it loads; keep them out of this batch
b7 = open(S + "/batch7/b7.py").read()
exec(b7[:b7.index("# ===== 2. hover on Minga lines and chrome")])
OUT = _out
os.makedirs(OUT, exist_ok=True)

# ===== 1. code.diagnostics.hover: the diagnostic hover with its actions, both frontends
m_diag = pop(psec(diag("Error", "elixir", f'{mono("Retry.after_ms/2")} is undefined. Did you mean {mono("after_ms/1")}?'), border=False)
             + psec(f'<div style="display:flex;gap:16px">{k("g.","Fix")}{k("SPC a ?","Ask Minga")}{k("y","Copy")}</div>')
             + pfoot(("g.", "actions · 1 fix")), 292, 66, 420)
m1 = macwin(area("".join(mrow(n, t, bg="rgba(255,255,255,0.03)" if n == 239 else "", numcol="#ecebe8" if n == 239 else "#7a7c85") for n, t in R_CODE), m_diag)
            + modeline(file="retry.ex", right="Elixir", pos="239:32"), title="retry.ex", path="lib/minga_agent", w=684, h=360)
mac = f'<div style="display:flex;gap:24px">{labeled("K or dwell on the error", "the diagnostic first, with its actions; V3Diagnostics shows the full macOS treatment", m1)}</div>'
g1 = tcodegrid(62, TH)
for x in range(9 + 29, 9 + 29 + 19):
    g1.c[2][x][3] = "u"
def fd(d):
    d.segs(1, 2, [("▌", G.RED), (" Error ", G.RED, None, "b"), ("· elixir", G.DIM)])
    d.segs(2, 3, [("Retry.after_ms/2 is undefined.", G.TXT)])
    d.segs(3, 3, [("Did you mean after_ms/1?", G.TXT)])
    d.put(4, 2, "─" * (d.w - 4), "#3a3c44")
    d.segs(5, 3, [("g.", G.PURPLE, None, "b"), (" Fix  ", G.CODE), ("SPC a ?", G.PURPLE, None, "b"), (" Ask Minga  ", G.CODE), ("y", G.PURPLE, None, "b"), (" Copy", G.CODE)])
tpop(g1, 3, 14, 8, 46, [("Retry.after_ms/2", G.TXT, "b")], [("g.", G.TXT), (" actions  ", G.DIM), ("esc", G.TXT), (" close", G.DIM)], fd)
tmode(g1, TH - 2, "NORMAL", [(" retry.ex ", G.TXT, "#30313a", "b"), (" E 1 ", G.RED, "#3a2328", "b")], " 239:32 ")
write("Batch8_code_diagnostics_hover.dc.html", board(
    "Batch 8: hover on a diagnostic", ("Hover on a diagnostic", "the problem, then Fix, Ask Minga and Copy, on both frontends"), mac, "",
    tterms((g1, "TUI", "K on the error: the diagnostic first, its actions one row below")),
    [("g.", "minga.act_menu (target: this diagnostic)"), ("SPC a ?", "minga.inline_ask (Ask Minga to fix it)"), ("y", "code.diagnostics.hover (copies the message)"), ("esc or click outside", "edit.plain")],
    "The same hover surface as code.hover, opened on a diagnostic: the problem leads, and its actions sit right under it instead of in a footer. The TUI draws them as keys in the accent colour with their words in the body colour."))

# ===== 2. windows.focus_lost: the macOS window when the app loses focus
def window(focused):
    rows = "".join(mrow(n, t, bg=("rgba(255,255,255,0.03)" if focused and n == 239 else ""), numcol=("#ecebe8" if focused and n == 239 else "#7a7c85")) for n, t in R_CODE)
    cursor = ('<div style="position:absolute;left:96px;top:42px;width:8px;height:16px;background:#8fc7ff"></div>' if focused
              else '<div style="position:absolute;left:96px;top:42px;width:8px;height:16px;box-sizing:border-box;border:1px solid #8fc7ff"></div>')
    body = f'<div style="position:relative;flex:1;min-height:0;{"" if focused else "opacity:0.78"}">{area(rows)}{cursor}</div>'
    return macwin(body + modeline(file="retry.ex", right="Elixir", pos="239:32"), title="retry.ex", path="lib/minga_agent", w=660, h=330)
mac2 = (f'<div style="display:flex;gap:24px">{labeled("Focused", "solid cursor, accent selection, live chrome", window(True))}'
        f'{labeled("Focus lost", "hollow cursor, chrome at rest; a needs-you notice becomes a desktop notification", window(False))}</div>')
write("Batch8_windows_focus_lost.dc.html", board(
    "Batch 8: the app lost focus", ("Focus lost on macOS", "a state, not a place: the window shows where you were and waits"), mac2, "",
    '<div class="ex" style="width:620px"><h4>TUI</h4>V41TuiTerminalPowers, section 3 (focus reporting): dim borders and a hollow cursor when the terminal loses focus.</div>',
    [("focus returns", "the scenario you were in, unchanged")],
    "Nothing moves and nothing closes when focus leaves. The cursor turns hollow so a glance tells you which window takes keys; macOS draws the traffic lights at rest itself."))
