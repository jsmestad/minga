import os as _os
TOOLS = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))
BOARDS = _os.environ.get("BOARDS_DIR", _os.path.join(TOOLS, "..", "boards"))  # committed boards, read only
OUT_DIR = _os.environ.get("OUT_DIR", _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "out"))
_os.makedirs(OUT_DIR, exist_ok=True)
import os
S = TOOLS
os.environ.setdefault("OUT_DIR",S+"/batch5/out")
b3=open(S+"/batch3/b3.py").read()
exec(b3[:b3.index("# ===== 1. errors.crash_reconnect")])
OUT=os.environ["OUT_DIR"]; os.makedirs(OUT,exist_ok=True)

# ---------- macOS: before (terminal drawer, TERM) and after (tasks drawer replaced it)
term_blk=(tline(PROMPT+'<span style="color:#ecebe8">mix phx.server</span>',glyph=B.st("Working",11),strand=YOU,right="running · 6 m")+
          tline("[info] Running MingaWeb.Endpoint at 127.0.0.1:4000",col="#a5a39e",strand=YOU)+
          tline("[info] GET /api/usage 200 in 4ms",col="#a5a39e",strand=YOU))
tdr=drawer(("*terminal 1*","Terminal"),'<span style="color:#8f8d88">~/code/minga</span>',f'{hint("⌃\\ ⌃N","normal")}{sp()}{hint("SPC o t","hide")}',
           f'<div style="position:absolute;inset:0;padding-top:4px;font-family:ui-monospace,monospace;font-size:12.5px">{term_blk}</div>',h=128)
before=macwin(editor_area(code(6,dim=True))+tdr+tmodeline("TERM","*terminal 1*","~/code/minga",seg_state("Working","mix phx.server","#b98cf0")),w=684,h=330)

rows=('<div style="padding:4px 0;font-size:12.5px">'
 f'<div style="height:24px;display:flex;align-items:center;gap:10px;padding:0 14px;background:rgba(242,181,68,0.10)">{B.st("Needs you",12)}<span style="color:#ecebe8;font-weight:600">Add tests for the usage-limit classifier</span><span style="flex:1"></span><span style="color:#f2b544">Needs you</span></div>'
 f'<div style="height:24px;display:flex;align-items:center;gap:10px;padding:0 14px">{B.st("Working",12)}<span style="color:#dcdce2">Show the plan limit instead of “rate limited”</span><span style="flex:1"></span><span style="color:#8f8d88">2/3 · 4m</span></div>'
 '</div>')
crumb='<span style="color:#8f8d88;font-size:11.5px">terminal 1 hidden · <span style="font-family:ui-monospace,monospace;color:#c9c7c2">q</span> returns</span>'
tsk=drawer(("*minga-tasks*","Minga Tasks"),crumb,f'{hint("↩","open")}{sp()}{hint("q","back to terminal 1")}',rows,h=128)
after=macwin(editor_area(code(6,dim=True))+tsk+modeline(file="*minga-tasks*",minga=seg_state("Working",'<span style="color:#c9c7c2">terminal 1: mix phx.server</span>',"#b98cf0"),right=None,pos="1:1"),w=684,h=330)
mac=(f'<div style="display:flex;gap:24px;align-items:flex-start">'
     f'<div><div class="lab"><b>Before</b>  the terminal drawer is open, the server is running</div>{before}</div>'
     f'<div><div class="lab"><b>SPC a a</b>  the tasks drawer replaces it; the terminal keeps running underneath</div>{after}</div></div>')

# ---------- TUI: before and after, 62 columns each
def tui(state):
    g=G.Grid(62,TH); tcode(g,9,dim=True,width=62)
    if state=="before":
        d=G.Grid(62,8,bg=SURF)
        d.box(0,0,8,62,G.FOCUS,SURF,title=[("*terminal 1*",G.SUB),("  Terminal",G.TXT,"b"),("  ~/code/minga",G.DIM)],bottom=[("⌃\\ ⌃N",G.TXT),(" normal  ",G.DIM),("SPC o t",G.TXT),(" hide",G.DIM)])
        d.put(1,2,"◐",G.PURPLED); d.put(1,4,"│","#4f9fe0"); d.put(1,6,"~/code/minga main ❯ mix phx.server",G.TXT); d.put(1,47,"running · 6 m",G.DIM)
        d.put(2,4,"│","#4f9fe0"); d.put(2,6,"[info] Running MingaWeb.Endpoint at :4000",G.SUB)
        d.put(3,4,"│","#4f9fe0"); d.put(3,6,"[info] GET /api/usage 200 in 4ms",G.SUB)
        blit(g,d,10)
        tmline(g,18,"TERM",[(" *terminal 1* ",G.TXT,"#30313a","b"),(" ◐ mix phx.server ",G.PURPLE,"#25262c")]," zsh 4182 ")
    else:
        d=G.Grid(62,8,bg=SURF)
        d.box(0,0,8,62,G.FOCUS,SURF,title=[("*minga-tasks*",G.SUB),("  Minga Tasks",G.TXT,"b")],bottom=[("↩",G.TXT),(" open  ",G.DIM),("q",G.TXT),(" back to terminal 1",G.DIM)])
        d.put(1,2,"terminal 1 hidden · q returns",G.DIM)
        d.bgrow(3,1,60,"#3a3120"); d.segs(3,2,[("◉ ",G.AMBER,"#3a3120"),("Add tests for the usage-limit…",G.TXT,"#3a3120","b")]); d.put(3,50,"Needs you",G.AMBER,"#3a3120")
        d.segs(4,2,[("◐ ",G.PURPLED),("Show the plan limit instead of…",G.CODE)]); d.put(4,52,"2/3 · 4m",G.DIM)
        blit(g,d,10)
        tmline(g,18,"NORMAL",[(" *minga-tasks* ",G.TXT,"#30313a","b"),(" ◐ terminal 1 running ",G.PURPLE,"#25262c")]," 1:1 ")
    return g
tuih=f'<div style="display:flex;gap:14px">{tterm(tui("before"),"TUI","before")}{tterm(tui("after"),"","after SPC a a")}</div>'

write("Batch5_windows_drawer_stack.dc.html",board("Batch 5: one drawer at a time",("Two drawers at once","opening a drawer replaces the open one; closing it brings the previous one back"),mac,"",tuih,
 [("q","terminal.drawer (the previous drawer comes back, shell still running)"),("esc","terminal.drawer (same as q)"),("SPC o t","terminal.drawer (toggles straight back to the terminal)")],
 "Only one drawer shows at a time (Doom popup behaviour). The replaced drawer is remembered, not closed: its process keeps running and the modeline keeps its state. To see two things at once, use a split."))
