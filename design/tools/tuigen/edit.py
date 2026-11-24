import os as _os
TOOLS = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))
BOARDS = _os.environ.get("BOARDS_DIR", _os.path.join(TOOLS, "..", "boards"))  # committed boards, read only
OUT_DIR = _os.environ.get("OUT_DIR", _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "out"))
_os.makedirs(OUT_DIR, exist_ok=True)
import sys; sys.path.insert(0,'.')
from grid import *
W,H=150,38
g=Grid(W,H)
CUR="#25262d"
# editor
L=[
 (229,[("defp ",KW),("chrome_state",FN),("(ws) ",CODE),("do",KW)],None,("│",BLUEB)),
 (230,[("  %{status: ",CODE),("workspace_agent_status",FN),("(ws), limit: ",CODE),("usage_limit",FN),("(ws)}",CODE)],None,("│",BLUEB)),
 (231,[("end",KW)],None,None),
 (232,[],None,None),
 (233,[("# Status comes from one owner: the session's presence.",CMT,"i")],None,None),
 (234,[("@spec ",KW),("workspace_agent_status",FN),("(",CODE),("Workspace",MOD),(".t()) :: ",CODE),("AgentPresence",MOD),(".state()",CODE)],None,("╳",PURPLED)),
 (235,[("defp ",KW),("workspace_agent_status",FN),("(ws) ",CODE),("do",KW)],None,("┃",PURPLED)),
 (236,[("  ws |> ",CODE),("payload",FN),("() |> ",CODE),("AgentPresence",MOD),(".of()",CODE)],None,("┃",PURPLED)),
 (237,[("end",KW)],None,("┃",PURPLED)),
 (238,[],None,None),
 (239,[("defp ",KW),("usage_limit",FN),("(ws) ",CODE),("do",KW)],None,None),
 (240,[("  ws |> ",CODE),("payload",FN),("() |> ",CODE),("limit_label",FN,"u"),("()",CODE,"u")],("E",RED),None),
 (241,[("end",KW)],None,None),
 (242,[],None,None),
 (243,[("def ",KW),("agent_label",FN),("(%{state: ",CODE),(":working",MOD),(", action: a}), ",CODE),("do",KW),(": a",CODE)],None,("│",GHOST)),
 (244,[("def ",KW),("agent_label",FN),("(%{state: ",CODE),(":needs_you",MOD),("}), ",CODE),("do",KW),(": ",CODE),('"Needs you"',STR,"ud")],("W",SAND),("│",GHOST)),
 (245,[("def ",KW),("agent_label",FN),("(%{state: ",CODE),(":done",MOD),("}), ",CODE),("do",KW),(": ",CODE),('"Done"',STR)],None,None),
 (246,[("def ",KW),("agent_label",FN),("(_), ",CODE),("do",KW),(': ""',STR)],None,None),
 (247,[],None,None),
 (248,[("defp ",KW),("payload",FN),("(%",CODE),("Workspace",MOD),("{payload: p}), ",CODE),("do",KW),(": p",CODE)],None,None),
 (249,[],None,None),
 (250,[("defp ",KW),("limit_label",FN),("(%{plan: plan, resets_at: at}) ",CODE),("do",KW)],None,None),
 (251,[("  ",CODE),('"#{plan} limit reached, resets "',STR),(" <> ",CODE),("relative",FN),("(at)",CODE)],None,None),
 (252,[("end",KW)],None,None),
 (253,[],None,None),
 (254,[("defp ",KW),("limit_label",FN),("(_), ",CODE),("do",KW),(": ",CODE),("nil",MOD)],None,None),
 (255,[],None,None),
 (256,[("@spec ",KW),("relative",FN),("(",CODE),("DateTime",MOD),(".t()) :: ",CODE),("String",MOD),(".t()",CODE)],None,None),
 (257,[("defp ",KW),("relative",FN),("(at) ",CODE),("do",KW)],None,None),
 (258,[("  at |> ",CODE),("DateTime",MOD),(".diff(",CODE),("DateTime",MOD),(".utc_now(), ",CODE),(":minute",MOD),(") |> ",CODE),("minutes",FN),("()",CODE)],None,None),
 (259,[("end",KW)],None,None),
 (260,[],None,None),
 (261,[("defp ",KW),("minutes",FN),("(n) ",CODE),("when",KW),(" n < 60, ",CODE),("do",KW),(": ",CODE),('"in #{n} min"',STR)],None,None),
 (262,[("defp ",KW),("minutes",FN),("(n), ",CODE),("do",KW),(": ",CODE),('"in #{div(n, 60)} h"',STR)],None,None),
 (263,[],None,None),
]
for i,(n,parts,sign,auth) in enumerate(L):
    r=i+1
    cur=(n==240)
    x=code_line(g,r,n,parts,sign=sign,auth=auth,numcol=(TXT if cur else FAINT),bgline=(CUR if cur else None))
    if n==236:
        g.put(r,x,"▏",PURPLED); g.put(r,x+2," Minga ","#14151a",PURPLED,"b")
    if n==240:
        g.put(r,x," ",BG,BLUE)
        g.put(r,x+4,"elixir: undefined function limit_label/1",DIM,None,"i")
# which-key panel: compact, single-spaced, columns sized to content
GRP="#a9b1f0"  # which-key group role (astrodark source; re-themes to Frappé lavender)
cols=[("Tasks",[("a","Tasks",("· 1 needs you",AMBER)),("n","New task…",None),("i","Inspect a task",None),("w","Watch Minga",None),("s","Stop",None)]),
      ("Conversation",[("v","Conversation",None),("?","Ask about this",None),("e","Rewrite selection",None),("q","Queue ›",("2",DIM))]),
      ("Changes",[("r","Review",("· 3",PURPLE)),("y","Keep change",None),("d","Reject change",None),("u","Reject all…",None),("p","Publish edits…",None)]),
      ("More",[("x","Context ›",("4",DIM)),("S","Session ›",("7",DIM))])]
h=8; top=35-h; PX=8; PW=W-18
wk=Grid(PW,h,bg=SURF)
wk.box(0,0,h,PW,BORDER,SURF,title=[("SPC",DIM),(" › ",FAINT),("a",PURPLE,"b"),("  Minga",TXT,"b")],
      right=[("◐ ",PURPLED),("2/3",SUB),("   ",SUB),("◉ ",AMBER),("1 needs you",AMBER)],
      bottom=[("⌫",TXT),(" back   ",DIM),("esc",TXT),(" cancel",DIM)])
c=3
for head,items in cols:
    wcol=max(3+len(lab)+(1+len(ex[0]) if ex else 0) for _,lab,ex in items)
    wk.put(1,c,head,DIM,None,"b")
    for k,(key,lab,extra) in enumerate(items):
        r=2+k
        x=wk.put(r,c,key,PURPLE,None,"b")
        x=wk.put(r,x+2,lab,GRP if lab.endswith("›") else TXT)
        if extra: wk.put(r,x+1,extra[0],extra[1])
    c+=wcol+6
g.blit(wk,top,PX); g.shadow(top,PX,h,PW)
# modeline row 36, echo row 37
r=36; g.fill(r,0,W,"#25262c")
x=g.segs(r,0,[(" NORMAL ","#12304a",BLUE,"b"),(" ",None,"#25262c"),(" ◉ Needs you ",AMBER,"#3a3120","b"),(" ",None,"#25262c"),
  (" chrome_state.ex ",TXT,"#30313a","b"),("● ",BLUE,"#30313a"),(" ",None,"#25262c"),(" change 1/2 ",PURPLE,"#2e2840"),(" ",None,"#25262c"),
  ("  main +11 ",SUB,"#25262c"),(" ◐ ",PURPLED,"#25262c"),("Minga here 2/3 ",PURPLE,"#25262c"),(" E 1 ",RED,"#3a2328","b"),(" ",None,"#25262c"),(" W 1 ",SAND,"#36321f","b")])
rx=W-len(" Elixir  240:31 ")
g.segs(r,rx-1,[(" Elixir ",SUB,"#25262c"),(" 240:31 ",TXT,"#30313a")])
g.segs(37,0,[(" SPC a-",PURPLE),("   waiting for a key",FAINT)])
open("edit_grid.html","w").write(g.html())
# colour profiles strip
def modeline():
    m=Grid(112,1); m.fill(0,0,112,"#25262c")
    m.segs(0,0,[(" NORMAL ","#12304a",BLUE,"b"),(" ",None,"#25262c"),(" ◉ Needs you ",AMBER,"#3a3120","b"),(" ",None,"#25262c"),(" chrome_state.ex ",TXT,"#30313a","b"),(" ",None,"#25262c"),(" change 1/2 ",PURPLE,"#2e2840"),("  main +11 ",SUB,"#25262c"),(" ◐ Minga here 2/3 ",PURPLE,"#25262c"),(" E 1 ",RED,"#3a2328","b"),(" W 1 ",SAND,"#36321f","b"),(" 240:31 ",TXT,"#30313a")])
    return m
strips=[]
for lab,f in [("Truecolor",None),("256 colours",to256),("16 colours",to16)]:
    m=modeline()
    if f: m.map_colors(f)
    strips.append(f'<div style="display:flex;align-items:center;gap:10px;margin-top:5px"><span style="width:78px;font-size:11px;color:#a5a39e">{lab}</span><div style="border-radius:4px;overflow:hidden">{m.html("tg small")}</div></div>')
body=term(open("edit_grid.html").read(),"Editing, then SPC a and a pause","150 × 38 cells, truecolor")
body=body[:-6]+f'<div style="margin-top:12px;font-size:12px;color:#e6e4df;font-weight:600">Colour profiles <span style="font-weight:400;color:#a5a39e">same modeline, degraded by colorprofile</span></div>{"".join(strips)}</div>'
annot="""<h4>What renders what</h4>
<div class="it"><span class="k">Gutter</span> number, sign, authorship: three fixed columns in one <code>lipgloss.JoinHorizontal</code>. E and W signs bold. The twist is one cell with two strands as foreground and background colour (<code>▐</code>, light over shade); the first line swaps sides with a quadrant block (<code>▚</code>), so the strands cross. Blue thin strand for you, faint when kept. On Kitty, Ghostty, WezTerm and iTerm2 the gutter can draw the exact twist with the graphics protocol instead.</div>
<div class="it"><span class="k">Diagnostics</span> Lip Gloss v2 <code>UnderlineStyle(Curly)</code> + <code>UnderlineColor(Red)</code> for errors (SGR 4:3, 58:2); <code>UnderlineStyle(Dotted)</code> in sand for warnings (line 244). Plain underline where the terminal lacks styled underlines.</div>
<div class="it"><span class="k">Cursor line</span> <code>Surface</code> tint across the row; its diagnostic as faint italic text after the code. Other lines stay clean.</div>
<div class="it"><span class="k">Minga chip</span> reverse video: purple background, dark text, <code>Padding(0,1)</code>.</div>
<div class="it"><span class="k">Which-key</span> floats over the code as a layer (<code>lipgloss.NewLayer</code> on the <code>Canvas</code>, already used in go/tui) with a soft drop shadow: a dim <code>▌</code> edge on the right and <code>▀</code> edge below. One <code>lipgloss.RoundedBorder()</code> panel, <code>BorderForeground(PopupBorder)</code>, <code>Background(PopupSurface)</code>. Title and live counts in the top border, help in the bottom border. Rows single-spaced, columns sized to their longest entry with a 6-cell gap, group names dim above each column, no rules. The panel is only as tall as its longest group.</div>
<div class="it"><span class="k">Working spinner</span> the ◐ in the modeline and which-key header is a <code>bubbles/spinner</code> with <code>Frames: ◐ ◓ ◑ ◒</code> at 8 fps; static ◐ when motion is reduced.</div>
<div class="it"><span class="k">Modeline</span> segments are styled blocks joined with one-cell gaps: mode pill (<code>ModeNormal</code>), needs-you chip, file, change, git, Minga, E/W chips, filetype, position. No powerline arrows.</div>
<div class="it"><span class="k">Degradation</span> <code>colorprofile</code> maps tints to 256 and ANSI 16; shapes and words carry meaning when colour collapses.</div>"""
open(OUT_DIR+"/V41TuiEdit.dc.html","w").write(page("TUI: editing and which-key",body,annot))
