#!/usr/bin/env python3
"""Generate the V4.1 built-in terminal boards."""
import os

OUT = os.environ.get("OUT_DIR", "./out")
os.makedirs(OUT, exist_ok=True)

BG = "#1e1f24"
DRAWER_BG = "#1a1b20"
P, PS, A, G, R, D, BLUE, YOU = "#a463e6", "#6b3fa3", "#f2b544", "#a5a39e", "#e5707a", "#7fbf7a", "#6cb8f5", "#4f9fe0"
MONO = "ui-monospace,'SF Mono',Menlo,monospace"

def orbit(state, size=13):
    body = {
        "Working": f'<circle cx="8" cy="8" r="5.5" fill="none" stroke="{P}" stroke-opacity="0.28" stroke-width="1.5"/><path d="M8 2.5 A5.5 5.5 0 0 1 13.5 8" fill="none" stroke="{P}" stroke-width="1.5" stroke-linecap="round"/><circle cx="13.5" cy="8" r="2.1" fill="{P}"/>',
        "Needs you": f'<circle cx="8" cy="8" r="6" fill="{A}" fill-opacity="0.25"/><circle cx="8" cy="8" r="3.4" fill="{A}"/>',
        "Waiting": f'<circle cx="8" cy="8" r="3" fill="none" stroke="{G}" stroke-width="1.6"/>',
        "Failed": f'<rect x="4.6" y="4.6" width="6.8" height="6.8" rx="1.2" fill="{R}" transform="rotate(45 8 8)"/>',
        "Done": f'<circle cx="8" cy="8" r="3.4" fill="{D}"/>',
    }[state]
    return f'<svg width="{size}" height="{size}" viewBox="0 0 16 16" aria-label="{state}" style="flex:none;display:block">{body}</svg>'

H = 22  # terminal line height

def strand(kind, part, bg=DRAWER_BG):
    """kind: you | minga ; part: head | body | last | single"""
    if kind == "you":
        y0 = 4 if part in ("head", "single") else 0
        y1 = H - 4 if part in ("last", "single") else H
        cap = ' stroke-linecap="round"'
        return f'<svg width="10" height="{H}" viewBox="0 0 10 {H}" aria-hidden="true" style="display:block"><path d="M5 {y0} L5 {y1}" stroke="{YOU}" stroke-width="1.5"{cap}/></svg>'
    if part in ("head", "single"):
        end = H - 5 if part == "single" else H
        return (f'<svg width="10" height="{H}" viewBox="0 0 10 {H}" aria-label="Minga ran this" style="display:block;overflow:visible">'
                f'<path d="M7 4 C7 9, 3 9, 3 14 L3 {end}" fill="none" stroke="{PS}" stroke-width="2.6" stroke-linecap="round"/>'
                f'<path d="M3 4 C3 9, 7 9, 7 14 L7 {end}" fill="none" stroke="{bg}" stroke-width="5" stroke-linecap="round"/>'
                f'<path d="M3 4 C3 9, 7 9, 7 14 L7 {end}" fill="none" stroke="{P}" stroke-width="2.6" stroke-linecap="round"/></svg>')
    end = H - 5 if part == "last" else H
    cap = ' stroke-linecap="round"' if part == "last" else ""
    return (f'<svg width="10" height="{H}" viewBox="0 0 10 {H}" aria-hidden="true" style="display:block">'
            f'<path d="M3 0 L3 {end}" stroke="{PS}" stroke-width="2.6"{cap}/><path d="M7 0 L7 {end}" stroke="{P}" stroke-width="2.6"{cap}/></svg>')

def tline(text, glyph="", who=None, part=None, right="", bg="", text_color="#c9c7c2", bgcol=DRAWER_BG):
    g = f'<span style="width:16px;flex:none;display:flex;justify-content:center">{glyph}</span>'
    s = f'<span style="width:10px;flex:none;margin:0 8px 0 2px">{strand(who, part, bgcol) if who else ""}</span>'
    r = f'<span style="margin-left:auto;padding-right:16px;color:#8f8d88;font-size:11.5px;font-family:-apple-system,sans-serif">{right}</span>' if right else ""
    style = f"background:{bg};" if bg else ""
    return f'<div style="display:flex;align-items:center;height:{H}px;{style}">{g}{s}<span style="white-space:pre;color:{text_color}">{text}</span>{r}</div>'

def rule():
    return '<div style="height:1px;background:rgba(255,255,255,0.06);margin:3px 16px 3px 36px"></div>'

def prompt(cmd, cwd="~/code/minga"):
    return f'<span style="color:{BLUE}">{cwd}</span> <span style="color:#8f8d88">main</span> <span style="color:{D}">❯</span> <span style="color:#ecebe8">{cmd}</span>'

def mprompt(cmd):
    return f'<span style="color:#b98cf0">minga</span> <span style="color:#8f8d88">~/code/minga</span> <span style="color:#b98cf0">❯</span> <span style="color:#ecebe8">{cmd}</span>'

def pill(text, kind):
    col = {"TERM": ("rgba(127,191,122,0.22)", D), "NORMAL": ("rgba(26,149,242,0.22)", BLUE), "INSERT": ("rgba(127,191,122,0.22)", D)}[kind]
    return f'<span style="margin-left:8px;display:flex;align-items:center;padding:1px 9px;border-radius:9px;background:{col[0]};color:{col[1]};font-weight:700;font-size:10.5px;letter-spacing:0.04em">{text}</span>'

SEP = '<span style="width:1px;height:14px;background:rgba(255,255,255,0.09)"></span>'

def seg(inner, extra=""):
    return f'<span style="display:flex;align-items:center;gap:6px;padding:0 10px;height:100%;{extra}">{inner}</span>'

def modeline(parts, focused=True):
    bg = "#25262c" if focused else "#212227"
    return (f'<div style="height:26px;flex:none;display:flex;align-items:center;background:{bg};border-top:1px solid rgba(255,255,255,0.07);font-size:12px;color:#a5a39e;overflow:hidden;white-space:nowrap">'
            + "".join(parts) + '</div>')

def needs_seg():
    return seg(f'<span style="display:flex;align-items:center;gap:6px;color:{A}">{orbit("Needs you")}<span>Needs you</span></span>')

def titlebar(title, sub):
    return f'''<div style="height:30px;flex:none;display:flex;align-items:center;gap:12px;padding:0 14px;background:#222329;border-bottom:1px solid rgba(255,255,255,0.06);position:relative">
  <div style="display:flex;gap:8px"><span style="width:12px;height:12px;border-radius:6px;background:#ff5f57"></span><span style="width:12px;height:12px;border-radius:6px;background:#febc2e"></span><span style="width:12px;height:12px;border-radius:6px;background:#28c840"></span></div>
  <span style="font-family:'Instrument Serif',serif;font-style:italic;font-size:15px;color:#8f8d88">minga</span>
  <div style="position:absolute;left:0;right:0;text-align:center;pointer-events:none;font-size:12.5px"><span style="font-weight:600">{title}</span>  <span style="color:#8f8d88">{sub}</span></div>
</div>'''

def code_line(n, text, cur=False):
    bg = "background:rgba(255,255,255,0.035);" if cur else ""
    return f'<div style="display:flex;align-items:center;height:24px;{bg}"><span style="width:56px;text-align:right;padding-right:22px;color:{"#c9c7c2" if cur else "#7a7c85"};flex:none">{n}</span><span style="white-space:pre">{text}</span></div>'

K = lambda s: f'<span style="color:#ff7ab2">{s}</span>'
T = lambda s: f'<span style="color:#dabaff">{s}</span>'
S = lambda s: f'<span style="color:#a6d189">{s}</span>'
C = lambda s: f'<span style="color:#7f8c98">{s}</span>'

def page(title, body):
    return f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{title}</title>
<script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Instrument+Serif:ital@0;1&display=swap" rel="stylesheet">
<style>
body{{margin:0}}
a{{color:#ecebe8;text-decoration:none}}a:hover{{color:#ffffff}}
.mono{{font-family:{MONO}}}
</style>
</helmet>
{body}
</x-dc>
<script type="text/x-dc" data-dc-script data-props='{{"$preview":{{"width":1440,"height":900}}}}'>
class Component extends DCLogic {{
  renderVals() {{
    return {{}};
  }}
}}
</script>
</body>
</html>
'''

WIN = f"width:1440px;height:900px;box-sizing:border-box;background:{BG};color:#ecebe8;font-family:-apple-system,'SF Pro Text',system-ui,sans-serif;display:flex;flex-direction:column;font-size:13px;border-radius:12px;overflow:hidden;position:relative"

# ---------------------------------------------------------------- Drawer board
def drawer_board():
    code = [
        code_line(18, f'  {K("describe")} {S(chr(34)+"usage limit"+chr(34))} {K("do")}'),
        code_line(19, f'    {K("test")} {S(chr(34)+"a 429 with usage_limit_reached is not retried"+chr(34))} {K("do")}'),
        code_line(20, f'      error = {T("Fixtures")}.provider_error(:usage_limit)'),
        code_line(21, f'      refute {T("Retry")}.retryable?(error)'),
        code_line(22, f'    {K("end")}'),
        code_line(23, ''),
        code_line(24, f'    {K("test")} {S(chr(34)+"the message names the plan and the reset time"+chr(34))} {K("do")}'),
        code_line(25, f'      assert {T("UsageLimit")}.message(error()) =~ {S(chr(34)+"resets at"+chr(34))}', cur=False),
        code_line(26, f'    {K("end")}'),
        code_line(27, f'  {K("end")}'),
    ]
    editor_ml = modeline([pill("NORMAL", "NORMAL"),
        seg('<span style="color:#ecebe8;font-weight:600">usage_limit_test.exs</span>'), SEP,
        seg('<span>main</span><span style="color:#8f8d88">+11</span>'),
        f'<span style="margin-left:auto"></span>', seg("Elixir"), SEP, seg(f'<span class="mono" style="font-size:11.5px">25:7</span>', "padding-right:14px")], focused=False)

    blocks = []
    blocks.append(tline(prompt("mix test test/minga_agent/retry_test.exs"), orbit("Done"), "you", "single", "● exit 0 · 1.8 s"))
    blocks.append(tline('<span style="color:#8f8d88">Finished in 0.4 seconds (0.4s async, 0.0s sync)</span>'))
    blocks.append(tline(f'<span style="color:{D}">12 tests, 0 failures</span>'))
    blocks.append(rule())
    blocks.append(tline(prompt("mix test test/minga_agent/usage_limit_test.exs"), orbit("Failed"), "you", "single", f'<span style="color:{R}">◆ exit 2</span> · 2.3 s', bg="rgba(229,112,122,0.06)"))
    out = [
        f'<span style="color:{R}">  1) test usage limit the message names the plan and the reset time</span>',
        '<span style="color:#8f8d88">     (MingaAgent.UsageLimitTest)</span>',
        f'<span style="color:#c9c7c2">     <span style="text-decoration:underline;text-decoration-color:rgba(108,184,245,0.6)">test/minga_agent/usage_limit_test.exs:25</span></span>',
        f'<span style="color:#c9c7c2">     Assertion with =~ failed</span>',
        f'<span style="color:#c9c7c2">     left:  <span style="color:#a6d189">"You have reached your plan limit."</span></span>',
        f'<span style="color:#c9c7c2">     right: <span style="color:#a6d189">"resets at"</span></span>',
        f'<span style="color:{R}">9 tests, 1 failure</span>',
    ]
    for i, o in enumerate(out):
        blocks.append(tline(o, bg="rgba(229,112,122,0.06)" if i < 1 else ""))
    blocks.append(rule())
    blocks.append(tline(prompt('<span style="display:inline-block;width:8px;height:15px;background:#c9c7c2;vertical-align:-3px"></span>'), "", None, None))

    drawer_ml = modeline([pill("TERM", "TERM"),
        seg('<span style="color:#ecebe8;font-weight:600">*terminal 1*</span>'), SEP,
        seg('<span>~/code/minga</span>'), SEP,
        seg(f'{orbit("Failed", 12)}<span style="color:{R}">exit 2</span><span style="color:#8f8d88">mix test</span>'),
        f'<span style="margin-left:auto"></span>', seg('<span style="color:#8f8d88">zsh 4182</span>', "padding-right:14px")])

    body = f'''<div style="{WIN}">
{titlebar("usage_limit_test.exs", "test/minga_agent")}
<div style="flex:1;display:flex;flex-direction:column;min-height:0">
  <div style="flex:1;padding-top:14px;font-family:{MONO};font-size:13.5px;color:#c9c7c2;min-height:0;overflow:hidden">{"".join(code)}</div>
  {editor_ml}
  <div style="height:5px;flex:none;background:{BG};border-top:1px solid rgba(255,255,255,0.10)"></div>
  <div style="height:410px;flex:none;background:{DRAWER_BG};display:flex;flex-direction:column">
    <div style="height:28px;flex:none;display:flex;align-items:center;gap:14px;padding:0 16px;font-size:12px;color:#8f8d88;border-bottom:1px solid rgba(255,255,255,0.05)">
      <span style="color:#ecebe8;font-weight:600">Terminal 1</span><span>~/code/minga</span>
      <span style="margin-left:auto" class="mono"><span style="color:{BLUE}">⌃\\ ⌃N</span> normal  <span style="color:{BLUE}">]]</span> next command  <span style="color:{BLUE}">SPC o t</span> hide</span>
    </div>
    <div style="flex:1;padding-top:6px;font-family:{MONO};font-size:13px;overflow:hidden">{"".join(blocks)}</div>
    {drawer_ml}
  </div>
</div>
</div>'''
    return page("V4.1: SPC o t, the terminal drawer", body)

# ---------------------------------------------------------------- Minga shell board
def minga_board():
    code = [
        code_line(41, f'  {K("def")} retryable?(%{{status: 429}} = error),'),
        code_line(42, f'    {K("do")}: not usage_limit?(error)'),
        code_line(43, ''),
        code_line(44, f'  {K("def")} retryable?(%{{status: s}}) {K("when")} s >= 500, {K("do")}: true'),
        code_line(45, f'  {K("def")} retryable?(_), {K("do")}: false'),
        code_line(46, ''),
        code_line(47, f'  {K("defp")} usage_limit?(%{{body: %{{"error" => %{{"type" => t}}}}}}),', cur=True),
        code_line(48, f'    {K("do")}: t == {S(chr(34)+"usage_limit_reached"+chr(34))}'),
        code_line(49, ''),
        code_line(50, f'  {K("defp")} usage_limit?(_), {K("do")}: false'),
    ]
    left_ml = modeline([pill("NORMAL", "NORMAL"), needs_seg(),
        seg('<span style="color:#ecebe8;font-weight:600">retry.ex</span>'), SEP,
        seg(f'{orbit("Working", 12)}<span style="color:#b98cf0">Minga</span><span>running tests</span>'),
        f'<span style="margin-left:auto"></span>', seg(f'<span class="mono" style="font-size:11.5px">47:5</span>', "padding-right:14px")], focused=False)

    sb = BG
    L = []
    L.append(tline(prompt("git stash list", "~/code/minga"), orbit("Done"), "you", "single", "● exit 0 · 0.1 s", bgcol=sb))
    L.append(tline('<span style="color:#8f8d88">(empty)</span>', bgcol=sb))
    L.append(rule())
    L.append(tline(mprompt("mix compile --warnings-as-errors"), orbit("Done"), "minga", "head", "● exit 0 · 3.1 s", bgcol=sb))
    L.append(tline('<span style="color:#8f8d88">Compiling 2 files (.ex)</span>', who="minga", part="last", bgcol=sb))
    L.append(rule())
    L.append(tline(mprompt("mix test test/minga_agent/retry_test.exs"), orbit("Failed"), "minga", "head", f'<span style="color:{R}">◆ exit 2</span> · 2.0 s', bg="rgba(229,112,122,0.06)", bgcol=sb))
    L.append(tline(f'<span style="color:{R}">  1) test 5xx errors are retried (MingaAgent.RetryTest)</span>', who="minga", part="body", bgcol=sb))
    L.append(tline('<span style="color:#c9c7c2">     test/minga_agent/retry_test.exs:31</span>', who="minga", part="body", bgcol=sb))
    L.append(tline(f'<span style="color:{R}">12 tests, 1 failure</span>', who="minga", part="last", bgcol=sb))
    L.append(rule())
    L.append(tline(mprompt("mix test test/minga_agent/retry_test.exs:31"), orbit("Working"), "minga", "head", '<span style="color:#b98cf0">running · 4 s</span>', bgcol=sb))
    L.append(tline('<span style="color:#8f8d88">Running ExUnit with seed: 718854, max_cases: 16</span>', who="minga", part="last", bgcol=sb))
    L.append(rule())
    L.append(tline(mprompt("mix ecto.reset"), orbit("Needs you"), "minga", "single", f'<span style="color:{A}">waiting for you</span>', bg="rgba(242,181,68,0.07)", bgcol=sb))
    L.append(tline(f'<span style="color:#c9c7c2;font-family:-apple-system,sans-serif;font-size:12.5px">Minga wants to reset the dev database.  <span style="color:{BLUE}" class="mono">↩</span> to answer</span>', bg="rgba(242,181,68,0.07)", bgcol=sb))

    menu = f'''<div style="position:absolute;left:480px;top:196px;width:230px;background:#2b2c33;border:1px solid rgba(255,255,255,0.12);border-radius:8px;box-shadow:0 12px 32px rgba(0,0,0,0.5);padding:5px;font-size:13px">
  <div style="display:flex;padding:5px 10px;border-radius:5px"><span>Ask Minga to Fix</span><span class="mono" style="margin-left:auto;color:#8f8d88">f</span></div>
  <div style="display:flex;padding:5px 10px;border-radius:5px"><span>Copy Output</span><span class="mono" style="margin-left:auto;color:#8f8d88">yic</span></div>
  <div style="display:flex;padding:5px 10px;border-radius:5px"><span>Rerun</span><span class="mono" style="margin-left:auto;color:#8f8d88">r</span></div>
  <div style="height:1px;background:rgba(255,255,255,0.08);margin:4px 6px"></div>
  <div style="display:flex;padding:5px 10px;border-radius:5px"><span>Send to Quickfix</span><span class="mono" style="margin-left:auto;color:#8f8d88">q</span></div>
</div>'''

    right_ml = modeline([pill("NORMAL", "NORMAL"),
        seg('<span style="color:#ecebe8;font-weight:600">*minga-shell*</span>'), SEP,
        seg(f'{orbit("Working", 12)}<span style="color:#b98cf0">mix test</span><span style="color:#8f8d88">4 s</span>'),
        f'<span style="margin-left:auto"></span>', seg('<span style="color:#8f8d88">read only</span>', "padding-right:14px")])

    minibuf = f'''<div style="height:28px;flex:none;display:flex;align-items:center;gap:8px;padding:0 14px;background:{BG};border-top:1px solid rgba(255,255,255,0.07);font-size:12.5px">
  <span style="color:{A}">Run</span><span class="mono" style="color:#ecebe8">mix ecto.reset</span><span style="color:{A}">?</span>
  <span class="mono" style="margin-left:10px"><span style="color:{BLUE};font-weight:700">y</span> <span style="color:#c9c7c2">once</span>   <span style="color:{BLUE};font-weight:700">a</span> <span style="color:#c9c7c2">always</span>   <span style="color:{BLUE};font-weight:700">t</span> <span style="color:#c9c7c2">this turn</span>   <span style="color:{BLUE};font-weight:700">n</span> <span style="color:#c9c7c2">deny</span></span>
  <span style="margin-left:auto;color:#8f8d88;font-size:11.5px">Board note: shown after ↩ on the pending block. In the scrollback, y stays yank.</span>
</div>'''

    body = f'''<div style="{WIN}">
{titlebar("retry.ex", "lib/minga_agent")}
<div style="flex:1;display:flex;min-height:0">
  <div style="width:640px;flex:none;display:flex;flex-direction:column;border-right:1px solid rgba(255,255,255,0.08)">
    <div style="flex:1;padding-top:14px;font-family:{MONO};font-size:13.5px;color:#c9c7c2;overflow:hidden">{"".join(code)}</div>
    {left_ml}
  </div>
  <div style="flex:1;display:flex;flex-direction:column;position:relative;min-width:0">
    <div style="height:28px;flex:none;display:flex;align-items:center;gap:14px;padding:0 16px;font-size:12px;color:#8f8d88;border-bottom:1px solid rgba(255,255,255,0.05)">
      <span style="color:#ecebe8;font-weight:600">Minga's shell</span><span>commands Minga runs, read only</span>
      <span style="margin-left:auto" class="mono"><span style="color:{BLUE}">]]</span> next  <span style="color:{BLUE}">↩</span> act on block  <span style="color:{BLUE}">⌃C</span> interrupt</span>
    </div>
    <div style="flex:1;padding-top:6px;font-family:{MONO};font-size:13px;overflow:hidden">{"".join(L)}</div>
    {menu}
    {right_ml}
  </div>
</div>
{minibuf}
</div>'''
    return page("V4.1: *minga-shell*, Minga's commands in view", body)

# ---------------------------------------------------------------- TUI board
def tui_board():
    # Character-cell frames drawn in a Lip Gloss style.
    CELL = "font-family:Menlo,monospace;font-size:12.5px;line-height:16px;white-space:pre"
    TWL, TWS = "#a463e6", "#4a2c75"
    TWH = (f'<span style="display:inline-block;width:1ch;height:16px;vertical-align:top;'
           f'background-image:linear-gradient(to right,{TWL} 50%,{TWS} 50%),linear-gradient(to right,{TWS} 50%,{TWL} 50%);'
           f'background-size:100% 50%,100% 50%;background-position:top,bottom;background-repeat:no-repeat"> </span>')
    TWB = (f'<span style="display:inline-block;width:1ch;height:16px;vertical-align:top;'
           f'background-image:linear-gradient(to right,{TWS} 50%,{TWL} 50%)"> </span>')
    LK = lambda col, s_: f'<span style="color:{col};text-decoration:underline;text-decoration-color:color-mix(in srgb,{col} 45%,transparent);text-underline-offset:3px">{s_}</span>'

    def frame(title, inner, width):
        return f'''<div style="width:{width}px;background:#101115;border-radius:10px;padding:10px 12px;box-shadow:0 0 0 1px rgba(255,255,255,0.08)">
  <div style="font-size:11px;color:#8f8d88;margin-bottom:6px;font-family:-apple-system,sans-serif">{title}</div>
  <div style="{CELL};color:#c9c7c2">{inner}</div></div>'''

    c = lambda col, s: f'<span style="color:{col}">{s}</span>'
    bgspan = lambda bg, s: f'<span style="background:{bg}">{s}</span>'
    dim = "#55575f"
    border = "#5b5d66"

    def boxtop(w, title):
        return c(border, "╭─ ") + c("#ecebe8", title) + c(border, " " + "─" * (w - len(title) - 5) + "╮")

    def boxbot(w, help_):
        n = vis(help_["html"])
        return c(border, "╰─ ") + help_["html"] + c(border, " " + "─" * (w - n - 5) + "╯")

    import re as _re, html as _h
    def vis(html):
        return len(_h.unescape(_re.sub(r"<[^>]+>", "", html)))
    def row(w, html, plain, bg=None):
        pad = " " * max(0, w - 4 - vis(html))
        inner = html + pad
        if bg:
            inner = bgspan(bg, inner)
        return c(border, "│ ") + inner + c(border, " │")

    def mline(parts):
        return "".join(parts)

    W = 84
    # Frame 1: drawer in the user's terminal
    help1 = {"plain": "⌃\\ ⌃N normal · ]] next · SPC o t hide",
             "html": c(BLUE, "⌃\\ ⌃N") + c("#8f8d88", " normal · ") + c(BLUE, "]]") + c("#8f8d88", " next · ") + c(BLUE, "SPC o t") + c("#8f8d88", " hide")}
    rows = []
    def r(html, plain, bg=None):
        rows.append(row(W, html, plain, bg))
    def blank():
        r("", "")
    def sep():
        r(c(dim, "─" * (W - 4)), "─" * (W - 4))
    pr = lambda cmd: (c(BLUE, "~/code/minga") + " " + c("#8f8d88", "main") + " " + c(D, "❯") + " " + c("#ecebe8", cmd),
                      "~/code/minga main ❯ " + cmd)
    h, p = pr("mix test test/minga_agent/retry_test.exs")
    tail = "● 0 1.8s"
    r(c(D, "●") + " " + c(YOU, "│") + " " + h + " " * (W - 4 - 4 - len(p) - len(tail)) + c("#8f8d88", tail), "x" * (W - 4))
    r("  " + c(YOU, " ") + " " + c("#8f8d88", "12 tests, 0 failures"), "     12 tests, 0 failures")
    sep()
    h, p = pr("mix test test/minga_agent/usage_limit_test.exs")
    tail = "◆ 2 2.3s"
    r(c(R, "◆") + " " + c(YOU, "│") + " " + h + " " * (W - 4 - 4 - len(p) - len(tail)) + c(R, tail), "x" * (W - 4), bg="#2a1d22")
    r("    " + c(R, "1) test the message names the plan and the reset time"), "    1) test the message names the plan and the reset time")
    r("       " + LK("#c9c7c2", "test/minga_agent/usage_limit_test.exs:25"), "       test/minga_agent/usage_limit_test.exs:25")
    r("       " + c("#c9c7c2", "Assertion with =~ failed"), "       Assertion with =~ failed")
    r("    " + c(R, "9 tests, 1 failure"), "    9 tests, 1 failure")
    sep()
    h, p = pr("█")
    r("    " + h, "    " + p)
    f1 = [boxtop(W, "terminal 1 · ~/code/minga")] + rows + [boxbot(W, help1)]
    ml1 = (bgspan("#7fbf7a", c("#101115", " TERM ")) + " " + c("#ecebe8", "*terminal 1*") + c(dim, " │ ") + "~/code/minga" + c(dim, " │ ") +
           c(R, "◆ exit 2") + " " + c("#8f8d88", "mix test") + " " * 22 + c("#8f8d88", "zsh 4182"))
    editor1 = c(dim, "  24 ") + c("#ff7ab2", "test") + c("#a6d189", ' "the message names the plan and the reset time"') + c("#ff7ab2", " do") + "\n" + \
              c(dim, "  25 ") + "    assert UsageLimit.message(error()) =~ " + c("#a6d189", '"resets at"') + "\n" + \
              bgspan("#212227", c(BLUE, " NORMAL ") + " usage_limit_test.exs" + c(dim, " │ ") + "main +11" + " " * 40 + "25:7 ") + "\n"
    f1html = editor1 + "\n".join(f1) + "\n" + bgspan("#25262c", ml1 + " ")

    # Frame 2: *minga-shell*
    W2 = 84
    rows = []
    def r2(html, plain, bg=None):
        rows.append(row(W2, html, plain, bg))
    def sep2():
        r2(c(dim, "─" * (W2 - 4)), "─" * (W2 - 4))
    mp = lambda cmd: (c("#b98cf0", "minga") + " " + c("#b98cf0", "❯") + " " + c("#ecebe8", cmd), "minga ❯ " + cmd)
    up = lambda cmd: (c(BLUE, "you") + " " + c(D, "❯") + " " + c("#ecebe8", cmd), "you ❯ " + cmd)
    def blockline(glyph, gcol, strand_html, head, plain, tail, tcol, bg=None):
        gap = W2 - 4 - 4 - len(plain) - len(tail)
        r2(c(gcol, glyph) + " " + strand_html + " " + head + " " * gap + c(tcol, tail), "x" * (W2 - 4), bg)
    h, p = up("git stash list")
    blockline("●", D, c(YOU, "│"), h, p, "● 0 0.1s", "#8f8d88")
    sep2()
    h, p = mp("mix compile --warnings-as-errors")
    blockline("●", D, TWH, h, p, "● 0 3.1s", "#8f8d88")
    sep2()
    h, p = mp("mix test test/minga_agent/retry_test.exs")
    blockline("◆", R, TWH, h, p, "◆ 2 2.0s", R, bg="#2a1d22")
    r2("  " + TWB + "  " + c(R, "1) test 5xx errors are retried") + "   " + LK("#c9c7c2", "retry_test.exs:31"), "  ┃  1) test 5xx errors are retried   retry_test.exs:31")
    sep2()
    h, p = mp("mix test test/minga_agent/retry_test.exs:31")
    blockline("◐", P, TWH, h, p, "running 4s", "#b98cf0")
    sep2()
    h, p = mp("mix ecto.reset")
    blockline("◉", A, TWH, h, p, "waiting for you", A, bg="#2b2617")
    r2("  " + TWB + "  " + c("#c9c7c2", "Minga wants to reset the dev database.  ") + c(BLUE, "↩") + c("#c9c7c2", " to answer"),
       "  ┃  Minga wants to reset the dev database.  ↩ to answer", bg="#2b2617")
    help2 = {"plain": "]] next · ↩ act on block · ⌃C interrupt",
             "html": c(BLUE, "]]") + c("#8f8d88", " next · ") + c(BLUE, "↩") + c("#8f8d88", " act on block · ") + c(BLUE, "⌃C") + c("#8f8d88", " interrupt")}
    f2 = [boxtop(W2, "minga-shell · read only")] + rows + [boxbot(W2, help2)]
    ml2 = (bgspan("#6cb8f5", c("#101115", " NORMAL ")) + " " + bgspan("#3a3020", c(A, " ◉ Needs you ")) + " " + c("#ecebe8", "*minga-shell*") + c(dim, " │ ") +
           c(P, "◐") + " " + c("#b98cf0", "mix test 4s") + " " * 30 + c("#8f8d88", "read only"))
    mini = c(A, "Run ") + c("#ecebe8", "mix ecto.reset") + c(A, "?  ") + c(BLUE, "y") + " once  " + c(BLUE, "a") + " always  " + c(BLUE, "t") + " this turn  " + c(BLUE, "n") + " deny"
    menu = ("\n" + " " * 8 + c(border, "╭──────────────────────────╮") + "\n" +
            " " * 8 + c(border, "│ ") + bgspan("#2e3f55", c("#ecebe8", "Ask Minga to fix       f ")) + c(border, "│") + "\n" +
            " " * 8 + c(border, "│ ") + c("#c9c7c2", "Copy output          yic ") + c(border, "│") + "\n" +
            " " * 8 + c(border, "│ ") + c("#c9c7c2", "Rerun                  r ") + c(border, "│") + "\n" +
            " " * 8 + c(border, "│ ") + c("#c9c7c2", "Send to quickfix       q ") + c(border, "│") + "\n" +
            " " * 8 + c(border, "╰──────────────────────────╯"))
    f2html = "\n".join(f2) + "\n" + bgspan("#25262c", ml2 + " ") + "\n" + mini

    notes = '''<div style="width:330px;font-size:12px;color:#a5a39e;line-height:18px;font-family:-apple-system,sans-serif">
  <div style="color:#8f8d88;font-size:11px;margin-bottom:6px">Board note: how Lip Gloss draws it</div>
  <div style="margin-bottom:8px"><span style="color:#ecebe8">Drawer</span>: <span class="mono">lipgloss.RoundedBorder()</span> with the title set into the top border and the key help in the bottom border, so no extra hint line sits above the modeline.</div>
  <div style="margin-bottom:8px"><span style="color:#ecebe8">Surfaces</span>: drawer background one step darker than the editor; a failed block gets a faint red row tint, a pending one a faint amber tint.</div>
  <div style="margin-bottom:8px"><span style="color:#ecebe8">Blocks</span>: separated by a dim rule, not blank lines. Gutter: state glyph (◐ ● ◆ ◉), then authorship: <span style="color:#4f9fe0">│</span> yours, and for Minga's a two-tone cell: <span style="color:#a463e6">▐</span> light over shade on each line, <span style="color:#a463e6">▚</span> on the first line so the strands cross.</div>
  <div style="margin-bottom:8px"><span style="color:#ecebe8">Links</span>: <span class="mono">file:line</span> in test and shell output is an OSC 8 hyperlink (Lip Gloss v2 <span class="mono">Hyperlink</span>); click opens the file at the line.</div>
  <div style="margin-bottom:8px"><span style="color:#ecebe8">Running</span>: the ◐ is a <span class="mono">bubbles/spinner</span> with frames ◐ ◓ ◑ ◒.</div>
  <div style="margin-bottom:8px"><span style="color:#ecebe8">Modeline</span>: segments are background blocks, not text separated by pipes; the mode pill is the only saturated block.</div>
  <div><span style="color:#ecebe8">Menu</span>: a bordered overlay with a full-width selection bar, the same component as completion.</div>
</div>'''

    body = f'''<div style="width:1440px;height:900px;box-sizing:border-box;background:#17181c;color:#ecebe8;font-family:-apple-system,'SF Pro Text',system-ui,sans-serif;border-radius:12px;overflow:hidden;padding:22px 26px">
  <div style="display:flex;align-items:baseline;gap:14px;margin-bottom:14px"><span style="font-size:17px;font-weight:700">The terminal in the terminal</span><span style="color:#8f8d88;font-size:12.5px">Go TUI · Bubble Tea and Lip Gloss · same blocks, glyphs and strands as macOS</span></div>
  <div style="display:flex;gap:20px;align-items:flex-start">
    {frame("SPC o t · your terminal drawer, a failed run", f1html, 700)}
    {frame("SPC a w · *minga-shell*, a pending approval, menu open on the failed block", f2html, 700)}
  </div>
  <div style="display:flex;gap:20px;margin-top:16px">
    <div style="width:700px;font-size:12px;color:#a5a39e;line-height:18px">
      <div style="color:#8f8d88;font-size:11px;margin-bottom:6px">Board note: keys</div>
      <span class="mono" style="color:{BLUE}">⌃\\ ⌃N</span> leaves TERM for NORMAL; <span class="mono" style="color:{BLUE}">i</span> goes back. Esc and ⌃C always reach the shell in TERM.
      In NORMAL: <span class="mono" style="color:{BLUE}">]] [[</span> commands, <span class="mono" style="color:{BLUE}">yic</span> copy output, <span class="mono" style="color:{BLUE}">yac</span> copy block, <span class="mono" style="color:{BLUE}">↩</span> on a failed block opens its menu.
      *minga-shell* has no TERM mode: you watch, scroll and interrupt, you never type into Minga's shell.
    </div>
    {notes}
  </div>
</div>'''
    return page("V4.1: the built-in terminal in the TUI", body)

for name, fn in [("V41ShellDrawer", drawer_board), ("V41ShellMinga", minga_board), ("V41ShellTui", tui_board)]:
    with open(os.path.join(OUT, name + ".dc.html"), "w") as f:
        f.write(fn())
print("ok")
