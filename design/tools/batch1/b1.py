import os as _os
TOOLS = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))
BOARDS = _os.environ.get("BOARDS_DIR", _os.path.join(TOOLS, "..", "boards"))  # committed boards, read only
OUT_DIR = _os.environ.get("OUT_DIR", _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "out"))
_os.makedirs(OUT_DIR, exist_ok=True)
import sys, os, html as H
S = TOOLS
sys.path.insert(0,S+"/v4gen"); sys.path.insert(0,S+"/tuigen")
import base41 as B
import grid as G
OUT=os.environ.get("OUT_DIR",S+"/batch1/out"); os.makedirs(OUT,exist_ok=True)
P,A,GR,R,DN=B.P,B.A,B.G,B.R,B.D
kw,mod,s_,cm=B.kw,B.mod,B.s_,B.cm

def kept():
    return '<svg width="10" height="18" viewBox="0 0 10 18" aria-hidden="true" style="display:block"><path d="M5 0 L5 18" stroke="rgba(164,99,230,0.4)" stroke-width="1.5"/></svg>'
MARK={"":"","head":B.tw_head(),"body":B.tw_body(),"last":B.tw_last(),"you":B.you(),"kept":kept()}
CODE=[(229,f'{kw("defp")} chrome_state(ws) {kw("do")}',""),
 (230,'  %{status: workspace_agent_status(ws), limit: usage_limit(ws)}',""),
 (231,kw("end"),""),(232,"",""),
 (233,cm("# Status comes from one owner: the session's presence."),""),
 (234,f'{kw("@spec")} workspace_agent_status({mod("Workspace")}.t()) :: {mod("AgentPresence")}.state()',"M"),
 (235,f'{kw("defp")} workspace_agent_status(ws) {kw("do")}',"M"),
 (236,f'  ws |&gt; payload() |&gt; {mod("AgentPresence")}.of()',"M"),
 (237,kw("end"),"M"),(238,"",""),
 (239,f'{kw("defp")} usage_limit(ws) {kw("do")}',""),
 (240,'  ws |&gt; payload() |&gt; limit_label()',""),
 (241,kw("end"),""),(242,"",""),
 (243,f'{kw("def")} agent_label(%{{state: :working, action: a}}), {kw("do")}: a',""),
 (244,f'{kw("def")} agent_label(%{{state: :needs_you}}), {kw("do")}: {s_(chr(34)+"Needs you"+chr(34))}',""),
 (245,f'{kw("def")} agent_label(%{{state: :done}}), {kw("do")}: {s_(chr(34)+"Done"+chr(34))}',""),
]
def code(n=12, minga="none", dim=False, start=0):
    rows=CODE[start:start+n]; out=[]
    msegs=[i for i,r in enumerate(rows) if r[2]=="M"]
    for i,(num,t,m) in enumerate(rows):
        mk=""
        if m=="M" and minga!="none":
            if minga=="kept": mk="kept"
            else: mk="head" if i==msegs[0] else ("last" if i==msegs[-1] else "body")
        op="opacity:0.45;" if dim else ""
        out.append(f'<div class="ln" style="{op}"><span class="num" style="color:#7a7c85">{num}</span><span class="sign"></span><span class="bar">{MARK[mk]}</span><span class="code">{t}</span></div>')
    return "\n".join(out)

def seg(h,extra=""): return f'<span style="display:flex;align-items:center;gap:6px;padding:0 10px;height:100%;{extra}">{h}</span>'
def mode_pill(mode="NORMAL"):
    col={"NORMAL":("#6cb8f5","rgba(26,149,242,0.22)"),"INSERT":("#7fbf7a","rgba(127,191,122,0.2)")}[mode]
    return f'<span style="display:flex;align-items:center;padding:0 10px;margin:0 4px 0 6px;height:18px;border-radius:9px;background:{col[1]};color:{col[0]};font-weight:700;font-size:10.5px;letter-spacing:0.04em">{mode}</span>'
def modeline(mode="NORMAL", file="chrome_state.ex", minga=None, right="Elixir", pos="240:31"):
    branch='<span style="color:#8f8d88">main</span><span style="color:#8f8d88">+11</span>'
    m=seg(minga) if minga else ""
    return f'''<div style="height:26px;flex:none;display:flex;align-items:center;background:#25262c;border-top:1px solid rgba(255,255,255,0.07);font-size:12px;color:#a5a39e">
{mode_pill(mode)}{seg(f'<span style="color:#ecebe8;font-weight:600">{file}</span>')}{seg(branch)}{m}<span style="flex:1"></span>{seg(right) if right else ""}{seg(f'<span style="font-family:ui-monospace,monospace;font-size:11.5px">{pos}</span>',"padding-right:14px")}</div>'''
def k(key,label,col="#b98cf0"): return f'<span style="display:inline-flex;align-items:baseline;gap:6px;margin-right:18px"><span style="font-family:ui-monospace,\'SF Mono\',Menlo,monospace;font-weight:700;color:{col}">{key}</span><span style="color:#c9c7c2">{label}</span></span>'
def hint(key,label): return f'<span style="font-family:ui-monospace,monospace;color:#c9c7c2">{key}</span> <span style="color:#7a7c85">{label}</span>'
def drawer(title, counts, hints, body, h=210, focus=True):
    bc="#5b9bd5" if focus else "rgba(255,255,255,0.12)"
    return f'''<div style="flex:none;height:{h}px;background:#23242a;border-top:1px solid {bc};display:flex;flex-direction:column">
<div style="height:30px;flex:none;display:flex;align-items:center;gap:14px;padding:0 16px;font-size:12px;white-space:nowrap;overflow:hidden;border-bottom:1px solid rgba(255,255,255,0.05)">
<span style="color:#8f8d88;font-family:ui-monospace,monospace;font-size:11.5px">{title[0]}</span><span style="font-weight:700;color:#ecebe8">{title[1]}</span>{counts}<span style="flex:1"></span>{hints}</div>
<div style="flex:1;min-height:0;position:relative">{body}</div></div>'''
def macwin(inner, title="chrome_state.ex", path="lib/minga_editor/session", w=1392, h=400):
    return f'''<div style="width:{w}px;height:{h}px;flex:none;border-radius:10px;overflow:hidden;border:1px solid #2e3038;box-shadow:0 10px 30px rgba(0,0,0,0.45);display:flex;flex-direction:column;background:#1e1f24;color:#ecebe8;font-family:-apple-system,'SF Pro Text',system-ui,sans-serif;font-size:13px">
{B.titlebar(title,path)}{inner}</div>'''
def editor_area(codehtml): return f'<div style="flex:1;min-height:0;overflow:hidden;padding-top:6px;font-family:ui-monospace,\'SF Mono\',Menlo,monospace;font-size:13px;color:#c9c7c2">{codehtml}</div>'
def minibuf(content, h=28): return f'<div style="height:{h}px;flex:none;display:flex;align-items:center;gap:10px;padding:0 14px;background:#1b1c21;border-top:1px solid rgba(255,255,255,0.07);font-size:12.5px">{content}</div>'

CSSX=G.CSS+"""
.ln{display:flex;align-items:center;height:18px}.num{width:52px;text-align:right;padding-right:8px;flex:none}.sign{width:8px;flex:none}.bar{width:10px;height:18px;flex:none;margin:0 4px 0 2px}.code{padding-left:8px;white-space:pre}
.lab{font-size:12px;color:#a5a39e;margin:0 0 6px}.lab b{color:#e6e4df;font-weight:600}
.ex{font-family:-apple-system,system-ui,sans-serif;font-size:11.5px;line-height:17px;color:#a5a39e}.ex h4{margin:0 0 6px;font-size:12px;color:#e6e4df}.ex code{font-family:'SF Mono',Menlo,monospace;font-size:11px;color:#c9c7c2}.ex .t{color:#b98cf0;font-family:'SF Mono',Menlo,monospace;font-size:10.5px}
"""
def board(title, mac_label, mac_html, tui_label, tui_html, exits, note=""):
    ex="".join(f'<div><code>{H.escape(a)}</code> &nbsp;→&nbsp; <span class="t">{t}</span></div>' for a,t in exits)
    body=f'''<div style="width:1440px;height:900px;box-sizing:border-box;background:#141519;color:#e6e4df;font-family:-apple-system,system-ui,sans-serif;border-radius:12px;overflow:hidden;padding:18px 24px;display:flex;flex-direction:column;gap:12px">
<div><div class="lab"><b>{mac_label[0]}</b>  {mac_label[1]}</div>{mac_html}</div>
<div style="display:flex;gap:24px;align-items:flex-start">{tui_html}<div class="ex" style="flex:1;padding-top:22px"><h4>Exits</h4>{ex}<div style="margin-top:10px">{note}</div></div></div>
</div>'''
    return f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>{H.escape(title)}</title><script src="./support.js"></script></head><body><x-dc>
<helmet><link rel="preconnect" href="https://fonts.googleapis.com"><link href="https://fonts.googleapis.com/css2?family=Instrument+Serif:ital@0;1&display=swap" rel="stylesheet"><style>body{{margin:0}}{CSSX}</style></helmet>
{body}
</x-dc><script type="text/x-dc" data-dc-script data-props='{{"$preview":{{"width":1440,"height":900}}}}'>class Component extends DCLogic {{ renderVals() {{ return {{}}; }} }}</script></body></html>'''

# ---------- TUI helpers
TW,TH=128,20
TC=[(229,"defp chrome_state(ws) do"),(230,"  %{status: workspace_agent_status(ws), limit: usage_limit(ws)}"),(231,"end"),(232,""),(233,"# Status comes from one owner."),(234,"@spec workspace_agent_status(Workspace.t()) :: AgentPresence.state()"),(235,"defp workspace_agent_status(ws) do"),(236,"  ws |> payload() |> AgentPresence.of()"),(237,"end"),(238,""),(239,"defp usage_limit(ws) do"),(240,"  ws |> payload() |> limit_label()"),(241,"end"),(242,""),(243,"def agent_label(%{state: :working, action: a}), do: a")]
def tcode(g, rows, minga="none", dim=True, start=0, col=0, width=None):
    f=("#5f616a","#4a4c54") if dim else (G.CODE,G.DIM)
    for i in range(rows):
        if start+i>=len(TC): break
        n,t=TC[start+i]; r=i
        g.put(r,col,f"{n:>5} ",f[1])
        if 234<=n<=237 and minga!="none":
            if minga=="kept": g.put(r,col+7,"│","#5a4a70")
            else: g.put(r,col+7,"╳" if n==234 else "┃",G.PURPLED if not dim else "#6a4f8f")
        g.put(r,col+9,t[: (width-9) if width else None],f[0])
def tmode(g,r,mode="NORMAL",parts=(),right=" 240:31 "):
    g.fill(r,0,g.w,"#25262c")
    pill={"NORMAL":("#12304a",G.BLUE),"INSERT":("#12301a",G.GREEN)}[mode]
    x=g.segs(r,0,[(f" {mode} ",pill[0],pill[1],"b"),(" ",None,"#25262c")])
    for p in parts: x=g.segs(r,x,[p,(" ",None,"#25262c")])
    g.segs(r,g.w-len(right),[(right,G.TXT,"#30313a")])
def tterm(g,label,sub): return G.term(g.html(),label,sub)

def write(name,html):
    open(os.path.join(OUT,name),"w").write(html); print(name)

# ---- Empty-state anatomy (shared with batch 4): title, one muted description, a gap, an action list.
def es_row(key,label,state=None):
    if state=="sel": bg="background:#2c3e57;box-shadow:inset 2px 0 0 #6cb8f5;"; kc="#6cb8f5"; lc="#ecebe8"
    elif state=="hover": bg="background:rgba(255,255,255,0.07);"; kc="#b98cf0"; lc="#dcdce2"
    else: bg=""; kc="#b98cf0"; lc="#dcdce2"
    return f'<div style="height:26px;display:flex;align-items:center;border-radius:5px;padding:0 10px;{bg}"><span style="width:84px;flex:none;font-family:ui-monospace,\'SF Mono\',Menlo,monospace;font-size:12px;font-weight:700;color:{kc}">{key}</span><span style="font-size:12.5px;color:{lc}">{label}</span></div>'
def es_body(title, desc=None, actions=(), hover=None):
    rows="".join(es_row(k_,l_,"sel" if i==0 else ("hover" if hover==i else None)) for i,(k_,l_) in enumerate(actions))
    d=f'<div style="margin-top:4px;font-size:12px;color:#8f8d88">{desc}</div>' if desc else ''
    return f'<div style="position:absolute;inset:0;padding:18px 22px;overflow:hidden"><div style="font-size:14px;font-weight:600;color:#dcdce2">{title}</div>{d}<div style="margin-top:16px;width:300px;display:flex;flex-direction:column;gap:2px">{rows}</div></div>'
def tes_box(d, title, desc, actions, r=2):
    d.put(r,3,title,G.TXT,None,"b")
    if desc: d.put(r+1,3,desc,G.DIM)
    ar=r+3 if desc else r+2
    kw=max(len(a[0]) for a in actions)+4
    for i,(k_,l_) in enumerate(actions):
        rr=ar+i
        if i==0:
            d.bgrow(rr,1,d.w-2,"#2c3e57"); d.put(rr,3,f" {k_} ","#14151a",G.BLUE,"b"); d.put(rr,3+kw,l_,G.TXT,"#2c3e57")
        else:
            d.put(rr,4,k_,G.PURPLE,None,"b"); d.put(rr,3+kw,l_,G.CODE)

# ===== 1. minga.tasks.empty
body=es_body("No one's at the table yet.","Give Minga a task. Each one gets its own conversation, review and place in the modeline.",[("c","New task"),("SPC a S h","Resume an earlier session")])
mac=macwin(editor_area(code(8,dim=True))+drawer(("*minga-tasks*","Minga Tasks"),'',hint("q","close"),body,h=200)+modeline(file="*minga-tasks*",right=None,pos="1:1"))
g=G.Grid(TW,TH); tcode(g,8,dim=True)
d=G.Grid(TW-6,10,bg=G.SURF)
d.box(0,0,10,TW-6,G.FOCUS,G.SURF,title=[("*minga-tasks*",G.SUB),("  Minga Tasks",G.TXT,"b")],bottom=[("q",G.TXT),(" close",G.DIM)],bottom_right=[("SPC a a",G.FAINT)])
tes_box(d,"No one's at the table yet.","Give Minga a task. Each one gets its own conversation, review and place in the modeline.",[("c","New task"),("SPC a S h","Resume an earlier session")])
for y in range(10):
    for x in range(TW-6): g.c[8+y][3+x]=list(d.c[y][x])
tmode(g,18,parts=[(" *minga-tasks* ",G.TXT,"#30313a","b"),("  main +11 ",G.SUB,"#25262c")],right=" 1:1 ")
g.segs(19,0,[(" ",G.FAINT)])
write("Batch1_minga_tasks_empty.dc.html",board("Batch 1: tasks drawer, empty",("SPC a a with no tasks","macOS · the drawer keeps its header, so the keys are still taught"),mac,"",tterm(g,"TUI","same drawer, rounded border, help in the bottom border"),
 [("c (preselected)","minga.task.new"),("SPC a S h","minga.session_history"),("q","edit.plain (focus returns to the window you came from)"),("esc","edit.plain")],
 "The voice line appears only here. Description and actions are separated: the most likely action is preselected, so ↩ runs it."))

# ===== 2. minga.task.new (prompt)
rows=f'''<div style="padding:6px 0">
<div style="display:flex;align-items:center;gap:10px;height:26px;padding:0 16px;opacity:0.55">{B.st("Done",13)}<span style="font-weight:600">Update the agent docs for the Spine</span><span style="color:#8f8d88">Done · 2 files to review</span><span style="flex:1"></span><span style="color:#7a7c85">12m</span></div>
<div style="display:flex;align-items:center;gap:10px;height:26px;padding:0 16px;opacity:0.55">{B.st("Working",13)}<span style="font-weight:600">Show the plan limit instead of “rate limited”</span><span style="color:#b98cf0">Editing chrome_state.ex · step 2 of 3</span><span style="flex:1"></span><span style="color:#7a7c85">4m</span></div></div>'''
chip=lambda t: f'<span style="padding:1px 8px;border-radius:4px;background:rgba(108,184,245,0.14);color:#6cb8f5;font-family:ui-monospace,monospace;font-size:11.5px">{t}</span>'
mb=f'''<div style="flex:none;background:#1b1c21;border-top:1px solid #5b9bd5;padding:8px 14px;display:flex;flex-direction:column;gap:7px;font-size:13px">
<div style="display:flex;align-items:center;gap:8px"><span style="color:#b98cf0;font-weight:600">New task ›</span><span style="color:#ecebe8">Show the reset time next to the needs-you segment in the modeline</span><span style="display:inline-block;width:2px;height:16px;background:#6cb8f5"></span></div>
<div style="display:flex;align-items:center;gap:8px">{chip("@chrome_state.ex")}{chip("@selection 239–241")}<span style="flex:1"></span>{hint("@","add context")}<span style="width:8px"></span>{hint("↩","start")}<span style="width:8px"></span>{hint("esc","cancel")}</div></div>'''
mac=macwin(editor_area(code(6,minga="unreviewed",dim=True))+drawer(("*minga-tasks*","Minga Tasks"),f'<span style="display:flex;gap:10px;color:#8f8d88;font-size:11.5px"><span>{B.st("Working",11)} 1</span><span>{B.st("Done",11)} 1</span></span>',f'{hint("c","new")}<span style="width:10px"></span>{hint("q","close")}',rows,h=110,focus=False)+mb+modeline(mode="INSERT",file="New task",right=None,pos="1:63"))
g=G.Grid(TW,TH); tcode(g,6,minga="unreviewed",dim=True)
d=G.Grid(TW-6,6,bg=G.SURF)
d.box(0,0,6,TW-6,G.BORDER,G.SURF,title=[("*minga-tasks*",G.SUB),("  Minga Tasks",G.TXT,"b")])
d.segs(2,3,[("● ",G.GREEN),("Update the agent docs for the Spine",G.DIM),("   Done · 2 files to review",G.FAINT)])
d.segs(3,3,[("◐ ",G.PURPLED),("Show the plan limit instead of “rate limited”",G.DIM),("   Editing chrome_state.ex · step 2 of 3",G.FAINT)])
for y in range(6):
    for x in range(TW-6): g.c[7+y][3+x]=list(d.c[y][x])
mbx=G.Grid(TW,4,bg="#1b1c21")
mbx.box(0,0,4,TW,G.FOCUS,"#1b1c21",title=[("New task",G.PURPLE,"b")],bottom=[("@",G.TXT),(" add context  ",G.DIM),("↩",G.TXT),(" start  ",G.DIM),("esc",G.TXT),(" cancel",G.DIM)])
mbx.segs(1,2,[("› ",G.PURPLE),("Show the reset time next to the needs-you segment in the modeline",G.TXT),(" ",None,G.BLUE)])
mbx.segs(2,2,[(" @chrome_state.ex ",G.BLUE,"#203246"),(" ",None),(" @selection 239-241 ",G.BLUE,"#203246")])
for y in range(4):
    for x in range(TW): g.c[14+y][x]=list(mbx.c[y][x])
tmode(g,18,mode="INSERT",parts=[(" New task ",G.TXT,"#30313a","b"),("  main +11 ",G.SUB,"#25262c")],right=" 1:63 ")
write("Batch1_minga_task_new.dc.html",board("Batch 1: new task",("c in the tasks drawer","a minibuffer prompt; the goal becomes the task title; @ adds context"),mac,"",tterm(g,"TUI","the prompt is a bordered textinput at the bottom; keys in its border"),
 [("↩","minga.tasks.working (the new task, focused)"),("esc","minga.tasks.list (back to the drawer)"),("@","files.switcher (pick a buffer, file or selection as context)")],
 "Opened with the cursor's selection already attached when there is one. The prompt never steals focus from typing: it is where you type."))

# ===== 2b. started
rows=f'''<div style="padding:6px 0">
<div style="display:flex;align-items:center;gap:10px;height:28px;padding:0 16px;background:rgba(26,149,242,0.16);box-shadow:inset 3px 0 0 #a463e6">{B.st("Working",13)}<span style="font-weight:600">Show the reset time next to the needs-you segment</span><span style="color:#b98cf0">Starting · reading chrome_state.ex</span><span style="flex:1"></span>{hint("↩","open")}<span style="width:6px"></span>{hint("i","inspect")}<span style="width:12px"></span><span style="color:#7a7c85">now</span></div>
<div style="display:flex;align-items:center;gap:10px;height:26px;padding:0 16px">{B.st("Working",13)}<span style="font-weight:600">Show the plan limit instead of “rate limited”</span><span style="color:#b98cf0">Editing chrome_state.ex · step 2 of 3</span><span style="flex:1"></span><span style="color:#7a7c85">4m</span></div>
<div style="display:flex;align-items:center;gap:10px;height:26px;padding:0 16px">{B.st("Done",13)}<span style="font-weight:600">Update the agent docs for the Spine</span><span style="color:#8f8d88">Done · 2 files to review</span><span style="flex:1"></span>{hint("↩","review")}<span style="width:12px"></span><span style="color:#7a7c85">12m</span></div></div>'''
counts=f'<span style="display:flex;gap:10px;color:#8f8d88;font-size:11.5px"><span>{B.st("Working",11)} 2</span><span>{B.st("Done",11)} 1</span></span>'
mac=macwin(editor_area(code(8,minga="unreviewed",dim=True))+drawer(("*minga-tasks*","Minga Tasks"),counts,f'{hint("j/k","move")}<span style="width:8px"></span>{hint("/","filter")}<span style="width:8px"></span>{hint("q","close")}',rows,h=150)+minibuf('<span style="color:#8f8d88">Minga started “Show the reset time next to the needs-you segment”.</span>',h=24)+modeline(file="*minga-tasks*",minga=f'{B.st("Working",13)}<span style="color:#b98cf0">Minga</span><span style="color:#c9c7c2">working on 2 tasks</span>',right=None,pos="1:1"))
g=G.Grid(TW,TH); tcode(g,8,minga="unreviewed",dim=True)
d=G.Grid(TW-6,8,bg=G.SURF)
d.box(0,0,8,TW-6,G.FOCUS,G.SURF,title=[("*minga-tasks*",G.SUB),("  Minga Tasks",G.TXT,"b")],right=[("◐ 2",G.PURPLE),("  ",G.SUB),("● 1",G.GREEN)],bottom=[("j/k",G.TXT),(" move  ",G.DIM),("↩",G.TXT),(" open  ",G.DIM),("i",G.TXT),(" inspect  ",G.DIM),("/",G.TXT),(" filter  ",G.DIM),("q",G.TXT),(" close",G.DIM)])
SEL="#24303d"; d.bgrow(2,1,TW-8,SEL); d.put(2,1,"▌",G.PURPLED,SEL)
d.segs(2,3,[("◐ ",G.PURPLED),("Show the reset time next to the needs-you segment",G.TXT,None,"b"),("   Starting · reading chrome_state.ex",G.PURPLE)]); d.put(2,TW-10,"now",G.DIM)
d.segs(3,3,[("◐ ",G.PURPLED),("Show the plan limit instead of “rate limited”",G.TXT),("   Editing chrome_state.ex · step 2 of 3",G.PURPLE)]); d.put(3,TW-10,"4m",G.DIM)
d.segs(4,3,[("● ",G.GREEN),("Update the agent docs for the Spine",G.TXT),("   Done · 2 files to review",G.GREEN)]); d.put(4,TW-10,"12m",G.DIM)
for y in range(8):
    for x in range(TW-6): g.c[9+y][3+x]=list(d.c[y][x])
g.put(17,1,"Minga started “Show the reset time next to the needs-you segment”.",G.DIM)
tmode(g,18,parts=[(" *minga-tasks* ",G.TXT,"#30313a","b"),("  main +11 ",G.SUB,"#25262c"),(" ◐ Minga working on 2 tasks ",G.PURPLE,"#25262c")],right=" 1:1 ")
write("Batch1_minga_task_new_started.dc.html",board("Batch 1: new task started",("After ↩","the task joins the drawer at the top, focused, already working"),mac,"",tterm(g,"TUI","same drawer, the new row selected"),
 [("↩","minga.conversation (the new task's conversation)"),("i","minga.subagent.peek (inspect the live view)"),("q","edit.plain")],
 "The echo line confirms once and fades. The modeline carries the state from here on."))

# ===== 3. minga.conversation.stopped
conv=f'''<div style="flex:1;min-width:0;display:flex;flex-direction:column;border-left:1px solid rgba(255,255,255,0.08);background:#1e1f24">
<div style="height:30px;flex:none;display:flex;align-items:center;gap:8px;padding:0 16px;border-bottom:1px solid rgba(255,255,255,0.06);font-size:12px">{B.st("Waiting",12)}<span style="font-weight:600">Show the plan limit instead of “rate limited”</span><span style="color:#8f8d88">Stopped · 4 min · GPT-6.2 Sol</span></div>
<div style="flex:1;min-height:0;overflow:hidden;padding:12px 18px;display:flex;flex-direction:column;gap:7px;font-size:13px;line-height:19px">
<div style="color:#6cb8f5;font-size:11px;font-weight:600">You</div><div>Show the plan limit and when it resets instead of “rate limited”.</div>
<div style="display:flex;gap:8px;color:#a5a39e">{B.st("Done",13)}Read native.ex and found where 429s are classified</div>
<div style="display:flex;gap:8px;color:#a5a39e">{B.st("Done",13)}Edited retry.ex so a usage limit is not retried <span style="color:#7fbf7a">+12</span> <span style="color:#e5707a">−3</span></div>
<div style="display:flex;gap:8px;color:#c9c7c2">{B.st("Waiting",13)}Stopped while editing chrome_state.ex · 1 of 3 edits applied</div>
<div style="color:#b98cf0;font-size:11px;font-weight:600;margin-top:4px">Minga</div><div style="color:#dcdce2">Stopped. So far: retry.ex is ready to review, and chrome_state.ex has 1 of 3 edits. Nothing else was touched.</div>
<div style="color:#8f8d88;font-size:12px">2 changes to review · <span style="font-family:ui-monospace,monospace;color:#c9c7c2">SPC a r</span></div>
</div>
<div style="flex:none;margin:0 14px 8px;border:1px solid rgba(255,255,255,0.08);border-radius:8px;padding:6px 10px;font-size:12px"><span style="color:#8f8d88;font-family:ui-monospace,monospace">*minga-queue*</span> <span style="color:#a5a39e">2 queued, kept</span><div style="color:#c9c7c2;margin-top:2px">1 Then run the session tests and fix what fails.</div></div>
<div style="flex:none;margin:0 14px 10px;border:1px solid #5b9bd5;border-radius:8px;padding:8px 10px;font-size:13px"><div style="color:#7a7c85">Continue, or tell Minga what to do instead</div><div style="margin-top:6px;font-size:11.5px">{hint("↩","continue")}<span style="width:10px;display:inline-block"></span>{hint("⌥↩","queue")}<span style="width:10px;display:inline-block"></span>{hint("@","context")}</div></div></div>'''
left=f'<div style="width:620px;flex:none;overflow:hidden;padding-top:6px;font-family:ui-monospace,monospace;font-size:13px;color:#c9c7c2">{code(13,minga="unreviewed",start=0)}</div>'
mac=macwin(f'<div style="flex:1;min-height:0;display:flex">{left}{conv}</div>'+modeline(mode="NORMAL",file="*minga: Show the plan limit…*",minga=f'{B.st("Waiting",13)}<span style="color:#a5a39e">Minga stopped</span><span style="color:#8f8d88">· 2 to review</span>',right=None,pos="12:1"),title="Show the plan limit instead of “rate limited”",path="with chrome_state.ex")
g=G.Grid(TW,TH); tcode(g,17,minga="unreviewed",dim=False,width=58)
c=G.Grid(66,18,bg=G.BG)
c.box(0,0,18,66,G.FOCUS,G.BG,title=[("○ ",G.SUB),("Show the plan limit…",G.TXT,"b")],right=[("Stopped · 4 min",G.DIM)],bottom=[("↩",G.TXT),(" continue  ",G.DIM),("⌥↩",G.TXT),(" queue  ",G.DIM),("q",G.TXT),(" close",G.DIM)])
c.put(1,2,"You",G.BLUE,None,"b"); c.put(2,2,"Show the plan limit and when it resets, not “rate limited”.",G.TXT)
c.segs(3,2,[("● ",G.GREEN),("Read native.ex and found where 429s are classified",G.SUB)])
c.segs(4,2,[("● ",G.GREEN),("Edited retry.ex so a usage limit is not retried ",G.SUB),("+12 ",G.GREEN),("−3",G.RED)])
c.segs(5,2,[("○ ",G.SUB),("Stopped while editing chrome_state.ex · 1 of 3 edits",G.TXT)])
c.put(7,2,"Minga",G.PURPLE,None,"b"); c.put(8,2,"Stopped. retry.ex is ready to review; chrome_state.ex has",G.TXT); c.put(9,2,"1 of 3 edits. Nothing else was touched.",G.TXT)
c.segs(10,2,[("2 changes to review · ",G.DIM),("SPC a r",G.TXT)])
c.box(11,1,3,64,G.BORDER,G.BG,title=[("*minga-queue*",G.SUB),("  2 queued, kept",G.DIM)]); c.put(12,3,"1 Then run the session tests and fix what fails.",G.TXT)
c.box(14,1,3,64,G.FOCUS,G.BG,title=[("Composer",G.TXT,"b")]); c.put(15,3,"Continue, or tell Minga what to do instead",G.FAINT)
for y in range(18):
    for x in range(66): g.c[y][62+x]=list(c.c[y][x])
tmode(g,18,parts=[(" *minga: Show the plan limit…* ",G.TXT,"#30313a","b"),(" ○ Minga stopped · 2 to review ",G.SUB,"#25262c")],right=" 12:1 ")
write("Batch1_minga_conversation_stopped.dc.html",board("Batch 1: conversation after Stop",("After ⌘. or SPC a s","the run says what it finished and what it left; the queue is kept"),mac,"",tterm(g,"TUI","conversation split with the composer and the kept queue"),
 [("↩ (composer)","minga.conversation (continue the same task)"),("⌥↩","minga.queue"),("SPC a r","minga.review.buffer"),("q","edit.plain (closes the split; the task stays in the drawer)")],
 "Stopped uses the parked shape (hollow) with the word Stopped: it is neither failed nor waiting on you. Open question for the vocabulary: add Stopped as a sixth word on the Waiting shape, or keep it a Waiting variant."))

# ===== 4. minga.review.all_decided
rev=f'''<div style="width:520px;flex:none;border-right:1px solid rgba(255,255,255,0.08);display:flex;flex-direction:column;background:#23242a">
<div style="height:30px;flex:none;display:flex;align-items:center;gap:10px;padding:0 14px;border-bottom:1px solid rgba(255,255,255,0.05);font-size:12px"><span style="color:#8f8d88;font-family:ui-monospace,monospace">*minga-review*</span><span style="flex:1"></span>{hint("↩","reply to Minga")}<span style="width:8px"></span>{hint("q","close")}</div>
<div style="padding:16px 18px;display:flex;flex-direction:column;gap:9px;font-size:13px">
<div style="display:flex;align-items:center;gap:8px">{B.st("Done",14)}<span style="font-weight:600">Show the plan limit instead of “rate limited”</span></div>
<div style="font-size:22px;color:#7fbf7a;font-family:'Instrument Serif',serif;font-style:italic;margin:4px 0 0 22px">Passt.</div>
<div style="margin-left:22px;color:#a5a39e">Kept 3 · Rejected 1 · nothing left to decide</div>
<div style="margin:6px 0 0 22px;display:flex;flex-direction:column;gap:5px;font-family:ui-monospace,monospace;font-size:12.5px">
<div><span style="color:#7fbf7a">✓</span> lib/minga_agent/retry.ex <span style="color:#7a7c85">kept</span></div>
<div><span style="color:#7fbf7a">✓</span> lib/minga_editor/session/chrome_state.ex <span style="color:#7a7c85">2 kept</span></div>
<div style="color:#7a7c85"><span>–</span> lib/minga_agent/usage_limit.ex <span>rejected</span></div></div>
<div style="margin:10px 0 0 22px;font-size:12px;color:#8f8d88">Kept changes stay marked with a thin strand until your next commit.</div></div></div>'''
mac=macwin(f'<div style="flex:1;min-height:0;display:flex">{rev}<div style="flex:1;overflow:hidden;padding-top:6px;font-family:ui-monospace,monospace;font-size:13px;color:#c9c7c2">{code(12,minga="kept")}</div></div>'+modeline(file="*minga-review*",minga=f'{B.st("Done",13)}<span style="color:#7fbf7a">Minga done</span>',right=None,pos="3:1"),title="*minga-review*",path="Show the plan limit instead of “rate limited”")
g=G.Grid(TW,TH)
rv=G.Grid(60,18,bg=G.SURF)
rv.box(0,0,18,60,G.FOCUS,G.SURF,title=[("*minga-review*",G.SUB)],bottom=[("↩",G.TXT),(" reply to Minga  ",G.DIM),("q",G.TXT),(" close",G.DIM)])
rv.segs(2,2,[("● ",G.GREEN),("Show the plan limit instead of “rate limited”",G.TXT,None,"b")])
rv.put(4,4,"Passt.",G.GREEN,None,"b"); rv.put(5,4,"Kept 3 · Rejected 1 · nothing left to decide",G.SUB)
rv.segs(7,4,[("✓ ",G.GREEN),("lib/minga_agent/retry.ex",G.TXT),("  kept",G.DIM)])
rv.segs(8,4,[("✓ ",G.GREEN),("lib/minga_editor/session/chrome_state.ex",G.TXT),("  2 kept",G.DIM)])
rv.segs(9,4,[("– ",G.FAINT),("lib/minga_agent/usage_limit.ex",G.FAINT),("  rejected",G.FAINT)])
rv.put(11,4,"Kept lines keep a thin strand until you commit.",G.DIM)
for y in range(18):
    for x in range(60): g.c[y][x]=list(rv.c[y][x])
tc=G.Grid(66,18); tcode(tc,14,minga="kept",dim=False,width=64)
for y in range(18):
    for x in range(66): g.c[y][62+x]=list(tc.c[y][x])
tmode(g,18,parts=[(" *minga-review* ",G.TXT,"#30313a","b"),(" ● Minga done ",G.GREEN,"#25262c")],right=" 3:1 ")
write("Batch1_minga_review_all_decided.dc.html",board("Batch 1: review, all decided",("After the last y or n","the one-time Passt.; kept lines keep a thin strand"),mac,"",tterm(g,"TUI","review buffer with the summary; the file shows kept strands"),
 [("q","edit.plain"),("↩","minga.conversation (reply to Minga)")],
 "Passt. appears once here (and in the background notification), never again for this task."))

# ===== 5. confirms
def confirm_mac(q,sub,w=684):
    mb=f'''<div style="flex:none;background:#1b1c21;border-top:1px solid #5b9bd5;padding:8px 14px;font-size:13px;display:flex;flex-direction:column;gap:5px"><div><span style="color:#ecebe8">{q}</span></div><div style="display:flex;gap:4px;align-items:center;color:#8f8d88;font-size:12px">{sub}<span style="flex:1"></span>{hint("y","yes")}<span style="width:8px"></span>{hint("n","no")}<span style="width:8px"></span>{hint("esc","cancel")}</div></div>'''
    return mb
r1=f'<div style="flex:1;padding:10px 14px;font-size:12.5px;background:#23242a;color:#a5a39e"><span style="color:#8f8d88;font-family:ui-monospace,monospace">*minga-review*</span><div style="margin-top:10px;font-family:ui-monospace,monospace;color:#c9c7c2">▾ chrome_state.ex  2 changes<br>&nbsp;&nbsp;@@ 231 replaced 1 line with 3<br>▸ usage_limit.ex  new</div></div>'
mk=macwin(f'<div style="flex:1;min-height:0;display:flex;flex-direction:column">{r1}</div>'+confirm_mac("Keep all 3 changes in 2 files?","Kept changes stay marked until your next commit.")+modeline(file="*minga-review*",right=None,pos="2:1"),title="*minga-review*",path="",w=684,h=330)
mr=macwin(editor_area(code(7,minga="unreviewed"))+confirm_mac("Reject all 3 changes from “Show the plan limit…”?","Removes Minga's edits in 2 files. Your own edits are untouched.")+modeline(file="chrome_state.ex",right=None),w=684,h=330)
mac=f'<div style="display:flex;gap:24px">{mk}{mr}</div>'
g=G.Grid(TW,TH)
def tconfirm(g,col,w,q,sub):
    b=G.Grid(w,4,bg="#1b1c21"); b.box(0,0,4,w,G.FOCUS,"#1b1c21",bottom=[("y",G.TXT),(" yes  ",G.DIM),("n",G.TXT),(" no  ",G.DIM),("esc",G.TXT),(" cancel",G.DIM)])
    b.put(1,2,q,G.TXT); b.put(2,2,sub,G.DIM)
    for y in range(4):
        for x in range(w): g.c[14+y][col+x]=list(b.c[y][x])
lv=G.Grid(62,14,bg=G.SURF); lv.put(0,1,"*minga-review*",G.SUB); lv.segs(2,1,[("▾ ",G.SUB),("chrome_state.ex  2 changes",G.TXT)]); lv.put(3,5,"@@ 231 replaced 1 line with 3",G.DIM); lv.segs(4,1,[("▸ ",G.SUB),("usage_limit.ex  new",G.TXT)])
for y in range(14):
    for x in range(62): g.c[y][x]=list(lv.c[y][x])
tc=G.Grid(64,14); tcode(tc,12,minga="unreviewed",dim=False,width=62)
for y in range(14):
    for x in range(64): g.c[y][64+x]=list(tc.c[y][x])
tconfirm(g,0,62,"Keep all 3 changes in 2 files?","Kept changes stay marked until your next commit.")
tconfirm(g,64,64,"Reject all 3 changes from “Show the plan limit…”?","Removes Minga's edits in 2 files. Your edits stay.")
tmode(g,18,parts=[(" *minga-review* ",G.TXT,"#30313a","b")],right=" 2:1 ")
write("Batch1_minga_review_confirms.dc.html",board("Batch 1: keep all and reject all",("Y in *minga-review* (left) · SPC a u (right)","bulk actions always ask, with counts and what they touch"),mac,"",tterm(g,"TUI","both prompts as a bordered minibuffer with y n esc in the border"),
 [("Keep all: y","minga.review.all_decided"),("Keep all: n / esc","minga.review.buffer"),("Reject all: y","edit.plain (echo: Rejected 3 changes)"),("Reject all: n / esc","edit.plain")],
 "y and n mean yes and no here as everywhere Minga asks. The prompt names the task, the count and what is left untouched."))

# ===== 6. minga.review.empty
body=es_body("Nothing to review.","Minga's changes show up here when a task finishes or asks you to look.",[("SPC a a","Show tasks"),("SPC a n","New task")])
mac=macwin(editor_area(code(8,dim=True))+drawer(("*minga-review*","Review"),'',hint("q","close"),body,h=200)+modeline(file="*minga-review*",right=None,pos="1:1"))
g=G.Grid(TW,TH); tcode(g,8,dim=True)
d=G.Grid(TW-6,10,bg=G.SURF)
d.box(0,0,10,TW-6,G.FOCUS,G.SURF,title=[("*minga-review*",G.SUB),("  Review",G.TXT,"b")],bottom=[("q",G.TXT),(" close",G.DIM)],bottom_right=[("SPC a r",G.FAINT)])
tes_box(d,"Nothing to review.","Minga's changes show up here when a task finishes or asks you to look.",[("SPC a a","Show tasks"),("SPC a n","New task")])
for y in range(10):
    for x in range(TW-6): g.c[8+y][3+x]=list(d.c[y][x])
tmode(g,18,parts=[(" *minga-review* ",G.TXT,"#30313a","b"),("  main +11 ",G.SUB,"#25262c")],right=" 1:1 ")
write("Batch1_minga_review_empty.dc.html",board("Batch 1: nothing to review",("SPC a r with nothing waiting","an empty state that points to where work comes from"),mac,"",tterm(g,"TUI","same drawer, same words"),
 [("SPC a a (preselected)","minga.tasks.list (or minga.tasks.empty)"),("SPC a n","minga.task.new"),("q / esc","edit.plain")],
 "No voice line here: Passt. is reserved for the moment a task completes."))
