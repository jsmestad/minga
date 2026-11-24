import os as _os
TOOLS = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))
BOARDS = _os.environ.get("BOARDS_DIR", _os.path.join(TOOLS, "..", "boards"))  # committed boards, read only
OUT_DIR = _os.environ.get("OUT_DIR", _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "out"))
_os.makedirs(OUT_DIR, exist_ok=True)
"""Animated (CSS-only) walkthroughs of the seven mouse patterns. OUT_DIR env var sets the output folder."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from anim import *

OUT=os.environ.get("OUT_DIR","./out"); os.makedirs(OUT,exist_ok=True)
def write(name,s): open(os.path.join(OUT,name),"w").write(s)

# ---- Direction A act menu helpers (astrodark source, mapped to Frappé here)
import re as _re
SCR = TOOLS
_rt=open(SCR+"/retheme/retheme.py").read(); exec(_rt[:_rt.index('T={"frappe"')])
def frappe(h): return _re.sub(r"#([0-9a-fA-F]{6})\b",lambda m:"#"+mapc(m.group(1),FRAPPE),h)
MONO="ui-monospace,'SF Mono',Menlo,monospace"
CUR='<span style="display:inline-block;width:8px;height:16px;vertical-align:-3px;background:#6cb8f5;opacity:0.85"></span>'
exec(open(SCR+"/actbrand/dira.py").read())

W=1360; ML_Y=670  # modeline top inside the window
CODE=[(229,"defp chrome_state(ws) do",None,None),
      (230,"  %{status: workspace_agent_status(ws), limit: usage_limit(ws)}",None,None),
      (231,"end",None,None),(232,"",None,None),
      (233,"# Status comes from one owner: the session's presence.",None,None),
      (234,"@spec workspace_agent_status(Workspace.t()) :: AgentPresence.state()","head",None),
      (235,"defp workspace_agent_status(ws) do","body",None),
      (236,"  ws |> payload() |> AgentPresence.of()","body",None),
      (237,"end","last",None),(238,"",None,None),
      (239,"defp usage_limit(ws) do",None,None),
      (240,"  ws |> payload() |> limit_label()",None,"E"),
      (241,"end",None,None),(242,"",None,None),
      (243,"def agent_label(%{state: :working, action: a}), do: a",None,None),
      (244,"def agent_label(%{state: :needs_you}), do: \"Needs you\"",None,"W"),
      (245,"def agent_label(%{state: :done}), do: \"Done\"",None,None),
      (246,"def agent_label(_), do: \"\"",None,None)]
ERR=(240,21,34)

def title(file,d): return f'<b style="color:{TXT};font-weight:600">{esc(file)}</b> <span style="color:{OV1}">{esc(d)}</span>'

def chip(text,key,x,y,bg=S0,fg=TXT,kfg=None,w=None,h=22):
    kfg=kfg or MAUVE
    ws=f"width:{w}px;" if w else ""
    return (f'<div style="position:absolute;left:{x}px;top:{y}px;height:{h}px;{ws}padding:0 10px;border-radius:6px;background:{bg};display:flex;align-items:center;gap:7px;'
            f'font-size:12px;color:{fg};white-space:nowrap"><span style="font-family:\'SF Mono\',Menlo,monospace;color:{kfg};font-weight:600">{esc(key)}</span>{esc(text)}</div>')

def glyph(state,size=12):
    v='0 0 16 16'
    g={"working":f'<circle cx="8" cy="8" r="5.5" fill="none" stroke="{MAUVE}" stroke-opacity=".28" stroke-width="1.5"/><path d="M8 2.5 A5.5 5.5 0 0 1 13.5 8" fill="none" stroke="{MAUVE}" stroke-width="1.5" stroke-linecap="round"/><circle cx="13.5" cy="8" r="2.1" fill="{MAUVE}"/>',
       "needs":f'<circle cx="8" cy="8" r="6" fill="{PEACH}" fill-opacity=".25"/><circle cx="8" cy="8" r="3.4" fill="{PEACH}"/>',
       "waiting":f'<circle cx="8" cy="8" r="3" fill="none" stroke="{SUB0}" stroke-width="1.6"/>',
       "failed":f'<rect x="4.6" y="4.6" width="6.8" height="6.8" rx="1.2" fill="{RED}" transform="rotate(45 8 8)"/>',
       "done":f'<circle cx="8" cy="8" r="3.4" fill="{GREEN}"/>'}[state]
    return f'<svg width="{size}" height="{size}" viewBox="{v}" style="display:inline-block;vertical-align:-2px">{g}</svg>'

def modeline(tl,needs_segs=None,file="chrome_state.ex",change="change 1/2",extra_left="",hover=None,file_segs=None):
    """Returns modeline html. needs_segs: vis segments for the needs-you chip (None = always)."""
    out=[f'<div style="position:absolute;left:0;top:{ML_Y}px;width:{W}px;height:30px;background:{MANTLE};border-top:1px solid {S0};border-radius:0 0 10px 10px"></div>',
         f'<div style="position:absolute;left:10px;top:{ML_Y+6}px;width:72px;height:19px;border-radius:5px;background:{BLUE};color:{CRUST};font-size:11px;font-weight:700;display:flex;align-items:center;justify-content:center;letter-spacing:.5px">NORMAL</div>']
    nc=tl.vis(needs_segs) if needs_segs is not None else ""
    out.append(f'<div class="{nc}" style="position:absolute;left:92px;top:{ML_Y+7}px;font-size:12px;color:{PEACH};display:flex;gap:6px;align-items:center">{glyph("needs",11)} 1 needs you</div>')
    out.append(f'<div style="position:absolute;left:196px;top:{ML_Y+7}px;font-size:12px;font-weight:600;color:{TXT}">{esc(file)}</div>')
    if change: out.append(f'<div style="position:absolute;left:330px;top:{ML_Y+7}px;font-size:12px;color:{MAUVE}">{esc(change)}</div>')
    out.append(f'<div style="position:absolute;left:420px;top:{ML_Y+7}px;font-size:12px;color:{OV1}">main +11</div>')
    out.append(f'<div style="position:absolute;left:880px;top:{ML_Y+7}px;font-size:12px;color:{MAUVE};display:flex;gap:6px;align-items:center">{glyph("working",11)} Minga editing 2/3</div>')
    out.append(f'<div style="position:absolute;left:1048px;top:{ML_Y+6}px;height:18px;padding:0 6px;border-radius:4px;background:{RED}33;color:{RED};font-size:12px;font-weight:600;display:flex;align-items:center">E 1</div>')
    out.append(f'<div style="position:absolute;left:1094px;top:{ML_Y+6}px;height:18px;padding:0 6px;border-radius:4px;background:{YELLOW}2a;color:{YELLOW};font-size:12px;font-weight:600;display:flex;align-items:center">W 1</div>')
    out.append(f'<div style="position:absolute;left:1190px;top:{ML_Y+7}px;font-size:12px;color:{OV1}">Elixir</div>')
    out.append(f'<div style="position:absolute;left:1270px;top:{ML_Y+7}px;font-size:12px;color:{TXT}">240:31</div>')
    return "".join(out)

def tint(tl,segs,x,y,w,h,color=None,radius=5,border=None):
    c=tl.vis(segs,fade=0.1)
    bd=f"box-shadow:inset 0 0 0 1.5px {border};" if border else ""
    return f'<div class="{c}" style="position:absolute;left:{x}px;top:{y}px;width:{w}px;height:{h}px;border-radius:{radius}px;background:{color or "rgba(255,255,255,.10)"};{bd}pointer-events:none"></div>'

def tooltip(tl,segs,x,y,text,key=None):
    c=tl.vis(segs,fade=0.15)
    k=f' <span style="color:{OV1}">·</span> <span style="font-family:\'SF Mono\',Menlo,monospace;color:{SUB0}">{esc(key)}</span>' if key else ""
    return f'<div class="{c}" style="position:absolute;left:{x}px;top:{y}px;padding:4px 9px;border-radius:6px;background:#3b3f52;border:1px solid {S1};box-shadow:0 6px 18px rgba(0,0,0,.4);font-size:12px;color:{TXT};white-space:nowrap;z-index:50">{esc(text)}{k}</div>'

def layer(tl,segs,inner,z=20):
    c=tl.vis(segs,fade=0.14)
    return f'<div class="{c}" style="position:absolute;left:0;top:0;width:1360px;height:700px;z-index:{z};pointer-events:none">{inner}</div>'

def wk_panel(y,crumb_html,cols,colw=310):
    rows=[]
    for ci,items in enumerate(cols):
        for ri,(k,label,extra,ecol) in enumerate(items):
            x=24+ci*colw; yy=y+30+ri*24
            ex=f' <span style="color:{ecol}">· {esc(extra)}</span>' if extra else ""
            grp=label.endswith("›")
            rows.append(f'<div style="position:absolute;left:{x}px;top:{yy}px;font-size:13px;white-space:nowrap"><span style="display:inline-block;width:34px;font-family:\'SF Mono\',Menlo,monospace;color:{MAUVE};font-weight:600">{esc(k)}</span>{('<span style="color:#BABBF1">'+esc(label)+'</span>') if grp else esc(label)}{ex}</div>')
    h=ML_Y-y
    return (f'<div style="position:absolute;left:0;top:{y}px;width:{W}px;height:{h}px;background:{MANTLE};border-top:1px solid {S1};box-shadow:0 -10px 24px rgba(0,0,0,.35)"></div>'
            f'<div style="position:absolute;left:24px;top:{y+8}px;font-size:12px;color:{OV1}">{crumb_html}</div>'+"".join(rows))

# =====================================================================
# 1. Mode pill -> which-key -> Minga -> Tasks -> Approve -> Close
# =====================================================================
def board_modepill():
    D=28; tl=TL(D)
    code=code_block(CODE,err=ERR,cursor=236)
    WK_Y=540
    top=wk_panel(WK_Y,f'<span style="font-family:\'SF Mono\',Menlo,monospace;color:{TXT}">SPC</span> <span style="color:{OV0}">and a pause</span>',[
        [("f","Files ›",None,None),("b","Buffers ›",None,None),("p","Project ›",None,None),("o","Open ›",None,None)],
        [("a","Minga ›","1 needs you",PEACH),("c","Code ›","1 error",RED),("s","Search ›",None,None),("g","Git ›",None,None)],
        [("w","Windows ›",None,None),("t","Toggles ›",None,None),("h","Help ›",None,None),("q","Quit and session ›",None,None)],
        [(":","Commands",None,None),(",","Switch file",None,None),("SPC","Find file in project",None,None)]])
    ming=wk_panel(WK_Y,f'<span style="font-family:\'SF Mono\',Menlo,monospace;color:{OV1};text-decoration:underline">SPC</span> <span style="color:{OV0}">›</span> <span style="font-family:\'SF Mono\',Menlo,monospace;color:{MAUVE}">a</span> <b style="color:{TXT}">Minga</b> <span style="margin-left:14px;color:{MAUVE}">{glyph("working",11)} 2/3</span> <span style="margin-left:8px;color:{PEACH}">{glyph("needs",11)} 1 needs you</span>',[
        [("a","Tasks","1 needs you",PEACH),("n","New task…",None,None),("i","Inspect a task",None,None),("w","Watch Minga",None,None)],
        [("v","Conversation",None,None),("?","Ask about this",None,None),("e","Rewrite selection",None,None),("q","Queue ›","2",OV1)],
        [("r","Review","3",MAUVE),("y","Keep change",None,None),("d","Reject change",None,None),("u","Reject all…",None,None)],
        [("s","Stop  ⌘.",None,None),("p","Publish edits…",None,None),("x","Context ›",None,None),("S","Session ›",None,None)]])
    # tasks drawer
    DY=392
    def rowline(y,g,title,state,scol,act=""):
        return (f'<div style="position:absolute;left:24px;top:{y}px;font-size:13px;display:flex;gap:10px;align-items:center">{glyph(g)}<span>{esc(title)}</span></div>'
                f'<div style="position:absolute;left:560px;top:{y}px;font-size:12.5px;color:{scol}">{esc(state)}</div>'
                +(f'<div style="position:absolute;left:1180px;top:{y}px;font-size:12px;color:{OV1}"><span style="font-family:\'SF Mono\',Menlo,monospace;color:{MAUVE}">{esc(act[0])}</span> {esc(act[1])}</div>' if act else ""))
    drawer_frame=(f'<div style="position:absolute;left:0;top:{DY}px;width:{W}px;height:{ML_Y-DY}px;background:{MANTLE};border-top:1px solid {BLUE};box-shadow:0 -10px 24px rgba(0,0,0,.35)"></div>'
                  f'<div style="position:absolute;left:24px;top:{DY+9}px;font-size:12.5px;white-space:nowrap"><span style="color:{OV0};font-family:\'SF Mono\',Menlo,monospace">*minga-tasks*</span> &nbsp;<b>Minga Tasks</b>'
                  f' &nbsp; <span style="color:{PEACH}">{glyph("needs",11)} 1</span> &nbsp;<span style="color:{MAUVE}">{glyph("working",11)} 1</span> &nbsp;<span style="color:{SUB0}">{glyph("waiting",11)} 1</span> &nbsp;<span style="color:{RED}">{glyph("failed",11)} 1</span> &nbsp;<span style="color:{GREEN}">{glyph("done",11)} 1</span></div>'
                  +chip("Open","↩",1054,DY+6)+chip("Stop","x",1132,DY+6)+chip("Close","esc",1206,DY+6)
                  +f'<div style="position:absolute;left:0;top:{DY+36}px;width:{W}px;height:1px;background:{S0}"></div>')
    R0=DY+48
    before=(f'<div style="position:absolute;left:12px;top:{R0-6}px;width:{W-24}px;height:84px;border-radius:7px;background:{PEACH}14;box-shadow:inset 3px 0 0 {PEACH}"></div>'
            +rowline(R0,"needs","Add tests for the usage-limit classifier","Needs you · wants to create a file",PEACH)
            +f'<div style="position:absolute;left:46px;top:{R0+22}px;font-size:12.5px;color:{SUB0};font-family:\'SF Mono\',Menlo,monospace">Create test/minga_agent/usage_limit_test.exs <span style="color:{GREEN}">+86</span></div>'
            +chip("Approve once","y",44,R0+46,bg=BLUE,fg=CRUST,kfg=CRUST)+chip("Always for this session","a",176,R0+46)+chip("This turn","t",370,R0+46)+chip("Deny","n",478,R0+46)
            +rowline(R0+96,"working","Show the plan limit instead of “rate limited”","Editing chrome_state.ex · step 2 of 3",MAUVE,("i","Inspect"))
            +rowline(R0+124,"waiting","Refactor the picker sources","Waiting · rate limited, retry in 40 s",SUB0,("r","Retry now"))
            +rowline(R0+152,"failed","Run the session test suite","Failed · test run crashed",RED,("o","Output"))
            +rowline(R0+180,"done","Update the agent docs","Done · 2 files to review",GREEN,("↩","Review")))
    after=(rowline(R0,"working","Add tests for the usage-limit classifier","Working · creating usage_limit_test.exs",MAUVE,("i","Inspect"))
           +f'<div style="position:absolute;left:46px;top:{R0+22}px;font-size:12px;color:{OV1}">Approved once.</div>'
           +rowline(R0+52,"working","Show the plan limit instead of “rate limited”","Editing chrome_state.ex · step 2 of 3",MAUVE,("i","Inspect"))
           +rowline(R0+80,"waiting","Refactor the picker sources","Waiting · rate limited, retry in 40 s",SUB0,("r","Retry now"))
           +rowline(R0+108,"failed","Run the session test suite","Failed · test run crashed",RED,("o","Output"))
           +rowline(R0+136,"done","Update the agent docs","Done · 2 files to review",GREEN,("↩","Review")))
    T_PILL=2.0; T_A=4.8; T_TASKS=8.4; T_APPROVE=13.2; T_CLOSE=20.0
    PILL=(46,ML_Y+15); AROW=(360,WK_Y+30+9); TROW=(80,WK_Y+30+9); APP=(110,R0+57); CLOSE=(1236,DY+17)
    inner=code+modeline(tl,needs_segs=[(0,T_APPROVE+0.2)])
    inner+=tint(tl,[(1.5,T_PILL+0.15)],8,ML_Y+4,76,23,color="rgba(255,255,255,.22)")
    inner+=tooltip(tl,[(1.85,T_PILL+0.15)],10,ML_Y-34,"Commands","SPC")
    inner+=layer(tl,[(T_PILL+0.2,T_A+0.2)],top+tint(tl,[(3.5,T_A+0.2)],334-8,WK_Y+26,250,24,color=f"{BLUE}33"))
    inner+=layer(tl,[(T_A+0.2,T_TASKS+0.2)],ming+tint(tl,[(6.9,T_TASKS+0.2)],16,WK_Y+26,270,24,color=f"{BLUE}33"))
    inner+=layer(tl,[(T_TASKS+0.2,T_CLOSE+0.2)],drawer_frame)
    inner+=layer(tl,[(T_TASKS+0.2,T_APPROVE+0.2)],before+tint(tl,[(11.9,T_APPROVE+0.1)],42,R0+44,128,26,color="rgba(255,255,255,.18)"))
    inner+=layer(tl,[(T_APPROVE+0.2,T_CLOSE+0.2)],after)
    inner+=tint(tl,[(17.9,T_CLOSE+0.1)],1204,DY+4,76,26,color="rgba(255,255,255,.14)")
    inner+=tooltip(tl,[(18.6,T_CLOSE+0.1)],1140,DY-34,"Close the drawer","esc")
    pts=[(0,900,240),(1.0,900,240),(1.6,*PILL),(2.4,*PILL),(3.6,*AROW),(5.3,*AROW),(7.0,*TROW),(9.2,*TROW),(12.0,*APP),(14.4,*APP),(18.0,*CLOSE),(20.6,*CLOSE),(22.0,880,250),(D,880,250)]
    inner+=pointer(tl,pts)+ripples(tl,[(T_PILL,*PILL),(T_A,*AROW),(T_TASKS,*TROW),(T_APPROVE,*APP),(T_CLOSE,*CLOSE)])
    win=macwin(inner,title_html=title("chrome_state.ex","lib/minga_editor/session"))
    caps=[(0,1.5,"Plain editing. One front door for the mouse: the mode pill."),
          (1.5,4.6,"Click the mode pill. The top-level which-key opens, exactly as if you pressed SPC and paused."),
          (4.6,8.2,"Click Minga. You drill into SPC › a, with live counts; the breadcrumb takes you back up."),
          (8.2,11.8,"Click Tasks. The tasks drawer opens with the task that needs you first."),
          (11.8,17.6,"Click Approve once. The row turns to Working and the needs-you segment leaves the modeline."),
          (17.6,21.2,"Drawer header hints are buttons. Click Close (the same as esc)."),
          (21.2,D,"Back to editing. Every click showed its key, so the next time is SPC a a, y.")]
    cap=captions(tl,caps)
    write("Mouse_Video_ModePill.dc.html",board("Mouse video: the mode pill","Mouse video 1","the mode pill, which-key, the tasks drawer (patterns 1 and 6)",win,cap,[c[2] for c in caps],tl))
    return D,caps

# =====================================================================
# 2. Modeline segments + tooltips, diagnostics, macOS menu bar -> Review
# =====================================================================
def board_modeline_menubar():
    D=30; tl=TL(D)
    T_ERR=7.6; T_ROW=10.6; T_MENU=13.6; T_REVIEW=20.4
    code_a=code_block(CODE,err=ERR,cursor=236)
    code_b=code_block(CODE,err=ERR,cursor=240)
    inner=layer(tl,[(0,T_ROW+0.2)],code_a,z=1)+layer(tl,[(T_ROW+0.2,T_REVIEW+0.2)],code_b,z=1)
    # review buffer replaces the editor
    rv=(f'<div style="position:absolute;left:0;top:37px;width:560px;height:{ML_Y-37}px;background:{MANTLE};border-right:1px solid {S1}"></div>'
        f'<div style="position:absolute;left:20px;top:50px;font-size:12.5px"><span style="color:{OV0};font-family:\'SF Mono\',Menlo,monospace">*minga-review*</span></div>'
        f'<div style="position:absolute;left:20px;top:76px;font-size:14px;font-weight:600;display:flex;gap:8px;align-items:center">{glyph("working")} Show the plan limit instead of “rate limited”</div>'
        f'<div style="position:absolute;left:40px;top:98px;font-size:12px;color:{OV1}">3 files · <span style="color:{GREEN}">+40</span> <span style="color:{RED}">−12</span> · 1 of 3 kept</div>'
        f'<div style="position:absolute;left:20px;top:132px;font-size:12px;color:{SUB0};font-weight:600">Unreviewed <span style="color:{OV0};font-weight:400">2 changes in 2 files</span></div>'
        f'<div style="position:absolute;left:12px;top:152px;width:536px;height:22px;border-radius:5px;background:{S0}"></div>'
        f'<div style="position:absolute;left:28px;top:155px;font-size:12.5px;font-family:\'SF Mono\',Menlo,monospace">▾ session/chrome_state.ex</div>'
        f'<div style="position:absolute;left:50px;top:178px;font-size:12px;color:{OV1};font-family:\'SF Mono\',Menlo,monospace">├ @@ 234 replaced 1 line with 4</div>'
        f'<div style="position:absolute;left:28px;top:200px;font-size:12.5px;font-family:\'SF Mono\',Menlo,monospace">▸ minga_agent/usage_limit.ex <span style="color:{GREEN}">new</span></div>'
        f'<div style="position:absolute;left:20px;top:236px;font-size:12px;color:{SUB0};font-weight:600">Kept <span style="color:{OV0};font-weight:400">1 change</span></div>'
        f'<div style="position:absolute;left:28px;top:256px;font-size:12.5px;color:{OV1};font-family:\'SF Mono\',Menlo,monospace">▸ minga_agent/retry.ex</div>'
        +chip("Keep","y",20,ML_Y-34)+chip("Reject","n",100,ML_Y-34)+chip("Diff","=",186,ML_Y-34)+chip("Next","]h",262,ML_Y-34)+chip("Close","q",346,ML_Y-34)
        +f'<div style="position:absolute;left:560px;top:37px;width:800px;height:{ML_Y-37}px;overflow:hidden"><div style="position:absolute;left:0;top:0">{code_block(CODE[3:],y0=11,cursor=234,width=800)}</div></div>')
    inner+=layer(tl,[(T_REVIEW+0.2,D)],rv,z=2)
    inner+=modeline(tl)
    # review modeline file name overlay
    inner+=layer(tl,[(T_REVIEW+0.2,D)],f'<div style="position:absolute;left:190px;top:{ML_Y+4}px;width:130px;height:22px;background:{MANTLE}"></div><div style="position:absolute;left:196px;top:{ML_Y+7}px;font-size:12px;font-weight:600;color:{TXT}">*minga-review*</div>',z=3)
    # hover tints + tooltips on segments
    NEED=(138,ML_Y+15); CHG=(358,ML_Y+15); ERRS=(1064,ML_Y+15)
    inner+=tint(tl,[(1.4,3.5)],86,ML_Y+4,100,23); inner+=tooltip(tl,[(2.0,3.5)],86,ML_Y-34,"1 task needs you","SPC a a")
    inner+=tint(tl,[(3.6,5.7)],324,ML_Y+4,80,23); inner+=tooltip(tl,[(4.2,5.7)],300,ML_Y-34,"Next Minga change","]h")
    inner+=tint(tl,[(5.8,T_ERR+0.2)],1044,ML_Y+4,44,23,color="rgba(255,255,255,.16)"); inner+=tooltip(tl,[(6.4,T_ERR+0.2)],990,ML_Y-34,"1 error","SPC c x")
    # diagnostics drawer
    DY=470
    dg=(f'<div style="position:absolute;left:0;top:{DY}px;width:{W}px;height:{ML_Y-DY}px;background:{MANTLE};border-top:1px solid {BLUE};box-shadow:0 -10px 24px rgba(0,0,0,.35)"></div>'
        f'<div style="position:absolute;left:24px;top:{DY+9}px;font-size:12.5px"><span style="color:{OV0};font-family:\'SF Mono\',Menlo,monospace">*diagnostics*</span> &nbsp;<b>Diagnostics</b> &nbsp;<span style="color:{RED}">1 error</span> <span style="color:{OV0}">·</span> <span style="color:{YELLOW}">1 warning</span></div>'
        +chip("","‹",1150,DY+6)+chip("","›",1190,DY+6)+chip("Close","esc",1236,DY+6)
        +f'<div style="position:absolute;left:0;top:{DY+36}px;width:{W}px;height:1px;background:{S0}"></div>'
        f'<div style="position:absolute;z-index:2;left:24px;top:{DY+50}px;font-size:12.5px;font-family:\'SF Mono\',Menlo,monospace"><span style="color:{RED};font-weight:700">E</span> &nbsp;<span style="color:{BLUE};text-decoration:underline">chrome_state.ex:240</span> &nbsp;<span style="color:{TXT}">undefined function limit_label/1</span> <span style="color:{OV0}">elixir</span></div>'
        f'<div style="position:absolute;z-index:2;left:24px;top:{DY+76}px;font-size:12.5px;font-family:\'SF Mono\',Menlo,monospace"><span style="color:{YELLOW};font-weight:700">W</span> &nbsp;<span style="color:{BLUE};text-decoration:underline">chrome_state.ex:244</span> &nbsp;<span style="color:{TXT}">this clause cannot match</span> <span style="color:{OV0}">elixir</span></div>')
    ROW1=(200,DY+58)
    inner+=layer(tl,[(T_ERR+0.2,T_REVIEW+0.2)],dg+tint(tl,[(9.4,T_ROW+0.2)],12,DY+46,W-24,24,color="rgba(255,255,255,.10)")+tint(tl,[(T_ROW+0.2,T_REVIEW+0.2)],12,DY+46,W-24,24,color=f"{BLUE}40"),z=4)
    # macOS menu bar (screen level, above the window: window top is at board y=80, menu bar at board y=48)
    MB=-32
    items=["Minga","File","Edit","View","Search","Code","Git","Window","Help"]
    mbx=[]; x=34
    for i,it in enumerate(items):
        mbx.append(f'<span style="position:absolute;left:{x}px;top:{MB+4}px;font-size:13px;{"font-weight:700;" if i==0 else ""}color:#ECEFF4">{it}</span>'); x+=len(it)*8+22
    mbar=(f'<div style="position:absolute;left:-40px;top:{MB}px;width:1440px;height:24px;background:rgba(30,32,44,.92);border-bottom:1px solid rgba(255,255,255,.06)"></div>'
          f'<span style="position:absolute;left:8px;top:{MB+3}px;font-size:14px;color:#ECEFF4"></span>'+"".join(mbx)
          +f'<span style="position:absolute;left:1270px;top:{MB+4}px;font-size:13px;color:#ECEFF4">Mon 15:20</span>')
    inner+=mbar
    inner+=tint(tl,[(T_MENU-0.1,T_REVIEW+0.2)],26,MB+1,60,22,color="rgba(255,255,255,.18)",radius=4)
    MX=30; MY=MB+26
    mitems=[("About Minga",None,None),None,("Tasks","SPC a a",None),("Conversation","SPC a v",None),("New Task…","SPC a n",None),("Review Changes","SPC a r",None),("Inspect a Task","SPC a i",None),("Watch Minga","SPC a w",None),None,("Keep Change","SPC a y",None),("Reject Change","SPC a d",None),("Reject All…","SPC a u",None),("Publish Edits…","SPC a p",None),None,("Queue","SPC a q","›"),("Context","SPC a x","›"),("Session","SPC a S","›"),None,("Stop","SPC a s","⌘."),None,("Settings…",None,"⌘,"),None,("Quit Minga",None,"⌘Q")]
    rows=[]; y=MY+6; ypos={}
    for it in mitems:
        if it is None:
            rows.append(f'<div style="position:absolute;left:{MX+10}px;top:{y+4}px;width:260px;height:1px;background:rgba(255,255,255,.12)"></div>'); y+=9; continue
        name,seq,sc=it; ypos[name]=y
        s=f'<span style="margin-left:10px;color:rgba(236,239,244,.45);font-family:\'SF Mono\',Menlo,monospace;font-size:11px">{esc(seq)}</span>' if seq else ""
        k=f'<span style="position:absolute;right:14px;color:rgba(236,239,244,.55)">{esc(sc)}</span>' if sc else ""
        rows.append(f'<div style="position:absolute;left:{MX+5}px;top:{y}px;width:270px;height:22px;font-size:13px;color:#ECEFF4;display:flex;align-items:center;padding-left:12px;box-sizing:border-box">{esc(name)}{s}{k}</div>')
        y+=22
    menu=(f'<div style="position:absolute;left:{MX}px;top:{MY}px;width:280px;height:{y-MY+6}px;border-radius:8px;background:rgba(44,46,60,.97);border:1px solid rgba(255,255,255,.12);box-shadow:0 14px 34px rgba(0,0,0,.55)"></div>'
          +tint(tl,[(15.0,15.9)],MX+5,ypos["Tasks"],270,22,color=ACCENT,radius=4)
          +tint(tl,[(15.9,16.7)],MX+5,ypos["Conversation"],270,22,color=ACCENT,radius=4)
          +tint(tl,[(16.7,17.4)],MX+5,ypos["New Task…"],270,22,color=ACCENT,radius=4)
          +tint(tl,[(17.4,T_REVIEW+0.15)],MX+5,ypos["Review Changes"],270,22,color=ACCENT,radius=4)
          +"".join(rows))
    inner+=layer(tl,[(T_MENU+0.15,T_REVIEW+0.2)],menu,z=60)
    MENU_MINGA=(56,MB+12); REV=(MX+110,ypos["Review Changes"]+11)
    pts=[(0,800,240),(1.0,800,240),(1.4,*NEED),(3.6,*CHG),(5.8,*ERRS),(8.2,*ERRS),(9.4,*ROW1),(11.6,*ROW1),(13.0,*MENU_MINGA),(14.4,*MENU_MINGA),(15.0,MX+110,ypos["Tasks"]+11),(15.9,MX+110,ypos["Conversation"]+11),(16.7,MX+110,ypos["New Task…"]+11),(17.4,*REV),(21.0,*REV),(22.4,900,300),(D,900,300)]
    inner+=pointer(tl,pts)+ripples(tl,[(T_ERR,*ERRS),(T_ROW,*ROW1),(T_MENU,*MENU_MINGA),(T_REVIEW,*REV)])
    win=macwin(inner,title_html=title("chrome_state.ex","lib/minga_editor/session"))
    caps=[(0,1.3,"Every modeline segment is a button, and its tooltip teaches the key."),
          (1.3,3.6,"Hover the needs-you segment: “1 task needs you · SPC a a”. Clicking it would open the tasks drawer."),
          (3.6,5.8,"Hover change 1/2: “Next Minga change · ]h”."),
          (5.8,9.3,"Hover the error count, then click it. The diagnostics list opens as a drawer."),
          (9.3,12.8,"Click the error. The cursor jumps to line 240; the list stays one click away."),
          (12.8,17.4,"On macOS the menu bar mirrors SPC. The Minga menu is the SPC a group, with each key sequence dimmed in its title."),
          (17.4,21.6,"Choose Review Changes (SPC a r). The review buffer opens beside the file."),
          (21.6,D,"Mouse users see the keys every time; keyboard users never need the menus.")]
    cap=captions(tl,caps)
    write("Mouse_Video_Modeline_MenuBar.dc.html",board("Mouse video: modeline and menu bar","Mouse video 2","clickable modeline segments and the macOS menu bar (patterns 2 and 3)",win,cap,[c[2] for c in caps],tl))
    return D,caps

# =====================================================================
# 3. Right-click act menu -> Reject -> prompt chips -> close button -> quit prompt
# =====================================================================
def board_actmenu():
    D=30; tl=TL(D)
    T_RC=2.0; T_REJ=7.4; T_Y=12.2; T_CLOSEBTN=19.4; T_ESC=25.0
    after=[(n if n<234 else n-3,t,tw,s) for (n,t,tw,s) in CODE if n<234 or n>237]
    after.insert(5,(234,"defp workspace_agent_status(ws), do: ws.payload.agent_status |> status_label()",None,None))
    err_after=(237,21,34)
    code_a=code_block(CODE,err=ERR,cursor=236)
    code_b=code_block(after,err=err_after,cursor=234)
    inner=layer(tl,[(0,T_Y+0.2)],code_a,z=1)+layer(tl,[(T_Y+0.2,D)],code_b,z=1)
    inner+=layer(tl,[(0,T_Y+0.2)],modeline(tl),z=2)
    inner+=layer(tl,[(T_Y+0.2,D)],modeline(tl,change="1 change left"),z=2)
    # right-click target line tint (Minga change 234-237)
    RC=(420,48+7*LH+9)  # line 236
    inner+=tint(tl,[(T_RC,T_REJ+0.2)],0,48+5*LH,W,4*LH,color=f"{MAUVE}1c",radius=0)
    # Direction A act menu (shared helpers in actbrand/dira.py, colours mapped to Frappé)
    MX=RC[0]+4; MY=RC[1]+2; AW=490
    WAIT='<svg width="13" height="13" viewBox="0 0 16 16"><circle cx="8" cy="8" r="3" fill="none" stroke="#a5a39e" stroke-width="1.6"/></svg>'
    menu=frappe(menuA(WAIT,"Minga's change 1 of 2","· 4 lines · unreviewed","minga",
        ("decision",[("y","Keep","accept 4 lines","SPC a y",True),("n","Reject","removes 4 lines, restores 1","SPC a d",False)]),
        [("This change",[("=","Show diff"),("o","Open conversation","","SPC a v")]),
         ("The symbol",[("g","Go to definition","","SPC c d"),("r","Find references","","SPC c D")]),
         ("Anywhere",[("l","Copy file:line link"),("?","Ask Minga about this","","SPC a ?")])],
        w=AW,left=MX,top_px=MY))
    HY=MY+35; HH=46; HW=(AW-4-20-6)//2
    KX=MX+3+10; RX=KX+HW+6
    menu+=(tint(tl,[(3.4,5.4)],KX,HY,HW,HH,color="rgba(255,255,255,.10)",radius=8)
          +tint(tl,[(5.6,T_REJ+0.15)],RX,HY,HW,HH,color="rgba(255,255,255,.14)",radius=8))
    inner+=layer(tl,[(T_RC+0.15,T_REJ+0.2)],menu,z=60)
    KEEP=(KX+HW//2,HY+HH//2); REJ=(RX+HW//2,HY+HH//2)
    # minibuffer prompt with chips
    PY=ML_Y-30
    def prompt(text,chips_):
        out=f'<div style="position:absolute;left:0;top:{PY}px;width:{W}px;height:30px;background:{MANTLE};border-top:1px solid {S0}"></div><div style="position:absolute;left:16px;top:{PY+7}px;font-size:13px;color:{TXT}">{text}</div>'
        for (lab,key,x,primary) in chips_:
            out+=chip(lab,key,x,PY+4,bg=(BLUE if primary else S0),fg=(CRUST if primary else TXT),kfg=(CRUST if primary else MAUVE))
        return out
    p1=prompt(f'Reject Minga\'s change 1 of 2? <span style="color:{OV1}">Removes 4 lines, restores 1. Your own edits are untouched.</span>',[("Reject","y",1010,True),("Keep it","n",1104,False),("Cancel","esc",1196,False)])
    inner+=layer(tl,[(T_REJ+0.2,T_Y+0.2)],p1+tint(tl,[(10.3,T_Y+0.1)],1008,PY+2,92,26,color="rgba(255,255,255,.22)"),z=40)
    YCHIP=(1050,PY+15)
    echo=f'<div style="position:absolute;left:0;top:{PY}px;width:{W}px;height:30px;background:{BASE}"></div><div style="position:absolute;left:16px;top:{PY+7}px;font-size:13px;color:{SUB0}">Rejected change 1 of 2. <span style="color:{OV1}">1 change left · SPC a r to review it</span></div>'
    inner+=layer(tl,[(T_Y+0.2,17.6)],echo,z=40)
    # close button hover x
    inner+=layer(tl,[(18.4,T_CLOSEBTN+0.2)],f'<span style="position:absolute;left:14px;top:12px;width:12px;height:12px;border-radius:6px;background:#ff5f57;color:#6b0d0a;font-size:10px;line-height:12px;text-align:center;font-weight:700">×</span>',z=70)
    inner+=tooltip(tl,[(18.9,T_CLOSEBTN+0.15)],10,42,"Close window","⌘W")
    p2=prompt(f'Quit Minga? <span style="color:{OV1}">1 unsaved file · Minga is working on 1 task (it keeps your unreviewed changes)</span>',[("Save all and quit","s",880,False),("Discard and quit","d",1040,False),("Cancel","esc",1196,True)])
    inner+=layer(tl,[(T_CLOSEBTN+0.3,T_ESC+0.2)],p2+tint(tl,[(23.3,T_ESC+0.1)],1194,PY+2,86,26,color="rgba(255,255,255,.22)"),z=40)
    CLOSEB=(20,18); ESCC=(1232,PY+15)
    pts=[(0,800,220),(1.0,800,220),(1.7,*RC),(2.6,*RC),(3.4,*KEEP),(5.4,*KEEP),(5.6,*REJ),(8.2,*REJ),(10.3,*YCHIP),(12.8,*YCHIP),(15.5,780,260),(17.6,780,260),(18.4,*CLOSEB),(20.2,*CLOSEB),(23.3,*ESCC),(25.6,*ESCC),(27.0,820,300),(D,820,300)]
    inner+=pointer(tl,pts)+ripples(tl,[(T_RC,*RC)],color=MAUVE)+ripples(tl,[(T_REJ,*REJ),(T_Y,*YCHIP),(T_CLOSEBTN,*CLOSEB),(T_ESC,*ESCC)])
    win=macwin(inner,title_html=title("chrome_state.ex","lib/minga_editor/session"))
    caps=[(0,1.6,"One of Minga's changes, marked by the twist in the gutter."),
          (1.6,3.3,"Right-click it. The act menu opens, the same menu as g. and ⌃.: the decision on top, actions below."),
          (3.3,5.5,"Keep is preselected; each half says what it does. Keep is y, Reject is n."),
          (5.5,7.6,"Reject removes 4 lines and restores 1. Click the n half."),
          (7.6,12.4,"The confirmation is a prompt with clickable chips. Click Reject (or press y)."),
          (12.4,17.6,"The change is gone and the original line is back. Undo is yours; Reject is for Minga."),
          (17.6,20.2,"Window chrome quits too: click the close button."),
          (20.2,25.4,"Something is at stake, so the quit prompt says what. Click Cancel (or press esc)."),
          (25.4,D,"Right-click, chips and the close button: three patterns, all showing their keys.")]
    cap=captions(tl,caps)
    write("Mouse_Video_ActMenu_Chips.dc.html",board("Mouse video: act menu and chips","Mouse video 3","right-click act menu, prompt chips, quitting from window chrome (patterns 4, 5 and 7)",win,cap,[c[2] for c in caps],tl))
    return D,caps

# =====================================================================
# 4. TUI: the mode-pill flow on a cell grid
# =====================================================================
def board_tui():
    D=20; tl=TL(D)
    FS=13; RH=16; CW=7.83  # 13 px SF Mono, 1.25x rows
    COLS=112; ROWS=34
    def cx(c): return round(c*CW,1)
    def cy(r): return r*RH
    def T(r,c,text,fg=TXT,bg=None,bold=False,ul=False):
        b=f"background:{bg};" if bg else ""
        return f'<span style="position:absolute;left:{cx(c)}px;top:{cy(r)}px;height:{RH}px;line-height:{RH}px;{b}color:{fg};{"font-weight:700;" if bold else ""}{"text-decoration:underline;" if ul else ""}white-space:pre">{esc(text)}</span>'
    def box(r,c,h,w,border,title_parts,bottom_parts,bg=MANTLE):
        out=f'<div style="position:absolute;left:{cx(c)+CW/2}px;top:{cy(r)+RH/2}px;width:{cx(w-1)}px;height:{cy(h-1)}px;border:1px solid {border};border-radius:7px;background:{bg};box-sizing:border-box"></div>'
        x=c+2
        for t,fg,bold in title_parts:
            out+=T(r,x,t,fg,bg,bold); x+=len(t)
        x=c+2
        for t,fg,bold in bottom_parts:
            out+=T(r+h-1,x,t,fg,bg,bold); x+=len(t)
        return out
    code=[(229,"defp chrome_state(ws) do"),(230,"  %{status: workspace_agent_status(ws), limit: usage_limit(ws)}"),(231,"end"),(232,""),
          (233,"# Status comes from one owner: the session's presence."),(234,"@spec workspace_agent_status(Workspace.t()) :: AgentPresence.state()"),
          (235,"defp workspace_agent_status(ws) do"),(236,"  ws |> payload() |> AgentPresence.of()"),(237,"end"),(238,""),(239,"defp usage_limit(ws) do"),
          (240,"  ws |> payload() |> limit_label()"),(241,"end")]
    g=""
    for i,(n,t) in enumerate(code):
        g+=T(i,0,f"{n:>5}",OV0)
        if 234<=n<=237: g+=f'<span style="position:absolute;left:{cx(6)}px;top:{cy(i)}px;width:{CW}px;height:{RH}px;background:linear-gradient(to right,{SHADE} 50%,{MAUVE} 50%)"></span>'
        g+=f'<span style="position:absolute;left:{cx(8)}px;top:{cy(i)}px;height:{RH}px;line-height:{RH}px;white-space:pre;color:{TXT}">{hl(t)}</span>'
    MR=ROWS-2
    ml=(f'<div style="position:absolute;left:0;top:{cy(MR)}px;width:{cx(COLS)}px;height:{RH}px;background:{MANTLE}"></div>'
        +T(MR,0," NORMAL ",CRUST,BLUE,True))
    needs_c=tl.vis([(0,11.8)])
    ml+=f'<span class="{needs_c}" style="position:absolute;left:{cx(9)}px;top:{cy(MR)}px;line-height:{RH}px;color:{PEACH};white-space:pre"> ◉ 1 needs you </span>'
    ml+=T(MR,25," chrome_state.ex ",TXT,S0,True)+T(MR,43," change 1/2 ",MAUVE)+T(MR,56," main +11 ",OV1)+T(MR,70," ◐ Minga 2/3 ",MAUVE)+T(MR,86," E 1 ",RED)+T(MR,92," W 1 ",YELLOW)+T(MR,104," 240:31 ",TXT,S0)
    ER=ROWS-1
    echo_hover=tl.vis([(1.0,1.8)])
    ml+=f'<span class="{echo_hover}" style="position:absolute;left:{cx(1)}px;top:{cy(ER)}px;line-height:{RH}px;color:{SUB0};white-space:pre">Commands · SPC  (click to open)</span>'
    T_PILL=1.8; T_A=4.6; T_TASKS=7.6; T_APP=11.6; T_ESC=15.2
    WR=24  # which-key panel top row
    wk_top=box(WR,0,MR-WR,COLS,S2,[(" SPC ",TXT,True),(" and a pause ",OV1,False)],[(" ⌫ back · esc close ",OV1,False)])
    entries=[[("f","Files ›"),("b","Buffers ›"),("p","Project ›")],[("a","Minga › 1 needs you"),("c","Code › 1 error"),("s","Search ›")],[("w","Windows ›"),("h","Help ›"),("q","Quit and session ›")],[(":","Commands"),(",","Switch file"),("SPC","Find file")]]
    for ci,col in enumerate(entries):
        for ri,(k,lab) in enumerate(col):
            wk_top+=T(WR+2+ri,3+ci*27,k,MAUVE,MANTLE,True)+T(WR+2+ri,3+ci*27+4,lab,PEACH if "needs" in lab else (RED if "error" in lab else ("#BABBF1" if "›" in lab else TXT)),MANTLE)
    wk_a=box(WR,0,MR-WR,COLS,S2,[(" SPC ",OV1,False),("› ",OV0,False),("a",MAUVE,True),(" Minga ",TXT,True)],[(" ⌫ back · esc close ",OV1,False)])
    entries=[[("a","Tasks · 1 needs you"),("n","New task…"),("i","Inspect a task")],[("v","Conversation"),("?","Ask about this"),("q","Queue › · 2")],[("r","Review · 3"),("y","Keep change"),("d","Reject change")],[("s","Stop"),("p","Publish edits…"),("S","Session ›")]]
    for ci,col in enumerate(entries):
        for ri,(k,lab) in enumerate(col):
            wk_a+=T(WR+2+ri,3+ci*27,k,MAUVE,MANTLE,True)+T(WR+2+ri,3+ci*27+4,lab,PEACH if "needs" in lab else ("#BABBF1" if "›" in lab else TXT),MANTLE)
    DR=14
    drawer=box(DR,0,MR-DR,COLS,BLUE,[(" *minga-tasks* ",OV1,False),(" Minga Tasks ",TXT,True),(" ◉ 1  ◐ 1  ○ 1  ◆ 1  ● 1 ",SUB0,False)],[(" ↩ open · x stop · ",OV1,False),("[esc close]",TXT,True),(" ",OV1,False)])
    rb=(T(DR+2,2,"▌",PEACH,MANTLE)+T(DR+2,4,"◉ Add tests for the usage-limit classifier",PEACH,MANTLE)+T(DR+2,60,"Needs you · wants to create a file",PEACH,MANTLE)
        +T(DR+3,6,"Create test/minga_agent/usage_limit_test.exs +86",SUB0,MANTLE)
        +T(DR+4,6,"[y Approve once]",CRUST,BLUE,True)+T(DR+4,24,"[a Always]",TXT,S0)+T(DR+4,36,"[t This turn]",TXT,S0)+T(DR+4,51,"[n Deny]",TXT,S0)
        +T(DR+6,4,"◐ Show the plan limit instead of “rate limited”",MAUVE,MANTLE)+T(DR+6,60,"Editing chrome_state.ex · 2 of 3",MAUVE,MANTLE)
        +T(DR+7,4,"○ Refactor the picker sources",SUB0,MANTLE)+T(DR+7,60,"Waiting · retry in 40 s",SUB0,MANTLE)
        +T(DR+8,4,"◆ Run the session test suite",RED,MANTLE)+T(DR+8,60,"Failed · test run crashed",RED,MANTLE)
        +T(DR+9,4,"● Update the agent docs",GREEN,MANTLE)+T(DR+9,60,"Done · 2 files to review",GREEN,MANTLE))
    ra=(T(DR+2,4,"◐ Add tests for the usage-limit classifier",MAUVE,MANTLE)+T(DR+2,60,"Working · creating usage_limit_test.exs",MAUVE,MANTLE)
        +T(DR+3,6,"Approved once.",OV1,MANTLE)
        +T(DR+5,4,"◐ Show the plan limit instead of “rate limited”",MAUVE,MANTLE)+T(DR+5,60,"Editing chrome_state.ex · 2 of 3",MAUVE,MANTLE)
        +T(DR+6,4,"○ Refactor the picker sources",SUB0,MANTLE)+T(DR+6,60,"Waiting · retry in 40 s",SUB0,MANTLE)
        +T(DR+7,4,"◆ Run the session test suite",RED,MANTLE)+T(DR+7,60,"Failed · test run crashed",RED,MANTLE)
        +T(DR+8,4,"● Update the agent docs",GREEN,MANTLE)+T(DR+8,60,"Done · 2 files to review",GREEN,MANTLE))
    def flash(t,r,c,w):
        k=tl.vis([(t,t+0.25)],fade=0.02)
        return f'<div class="{k}" style="position:absolute;left:{cx(c)}px;top:{cy(r)}px;width:{cx(w)}px;height:{RH}px;background:{TXT};mix-blend-mode:difference;z-index:80"></div>'
    def bar(segs,r,c,w,color=f"{BLUE}44"):
        k=tl.vis(segs,fade=0.05)
        return f'<div class="{k}" style="position:absolute;left:{cx(c)}px;top:{cy(r)}px;width:{cx(w)}px;height:{RH}px;background:{color};z-index:30"></div>'
    stage=g+ml
    stage+=layer(tl,[(T_PILL+0.2,T_A+0.2)],wk_top+bar([(3.2,T_A+0.2)],WR+2,29,24),z=20)
    stage+=layer(tl,[(T_A+0.2,T_TASKS+0.2)],wk_a+bar([(6.2,T_TASKS+0.2)],WR+2,2,24),z=20)
    stage+=layer(tl,[(T_TASKS+0.2,T_ESC+0.2)],drawer,z=20)
    stage+=layer(tl,[(T_TASKS+0.2,T_APP+0.2)],rb,z=21)+layer(tl,[(T_APP+0.2,T_ESC+0.2)],ra,z=21)
    stage+=bar([(13.8,T_ESC+0.2)],MR-1,22,11,color="rgba(255,255,255,.18)")
    stage+=flash(T_PILL,MR,0,8)+flash(T_A,WR+2,29,24)+flash(T_TASKS,WR+2,2,24)+flash(T_APP,DR+4,6,16)+flash(T_ESC,MR-1,22,11)
    # pointer: a highlighted cell (terminals have no pointer sprite), cell-snapped
    def P(r,c): return (round(cx(c),1),cy(r))
    pts=[(0,*P(6,70)),(1.0,*P(6,70)),(1.2,*P(MR,3)),(2.6,*P(MR,3)),(3.2,*P(WR+2,32)),(5.0,*P(WR+2,32)),(6.2,*P(WR+2,5)),(8.0,*P(WR+2,5)),(10.2,*P(DR+4,9)),(12.0,*P(DR+4,9)),(13.8,*P(MR-1,25)),(15.6,*P(MR-1,25)),(16.4,*P(6,70)),(D,*P(6,70))]
    pc=tl.path(pts,step=True)
    stage+=f'<div class="{pc}" style="position:absolute;left:0;top:0;width:{CW}px;height:{RH}px;background:{PEACH};opacity:.85;mix-blend-mode:screen;z-index:99;box-shadow:0 0 0 1px {PEACH}"></div>'
    term_w=cx(COLS)+28; term_h=cy(ROWS)+46
    win=(f'<div style="position:absolute;left:40px;top:70px;width:{term_w}px;height:{term_h}px;border-radius:10px;background:{BASE};border:1px solid {S0};box-shadow:0 18px 50px rgba(0,0,0,.55);overflow:hidden">'
         f'<div style="height:26px;background:{MANTLE};border-bottom:1px solid {S0};position:relative"><span style="position:absolute;left:12px;top:8px;width:11px;height:11px;border-radius:6px;background:#ff5f57"></span><span style="position:absolute;left:30px;top:8px;width:11px;height:11px;border-radius:6px;background:#febc2e"></span><span style="position:absolute;left:48px;top:8px;width:11px;height:11px;border-radius:6px;background:#28c840"></span><span style="position:absolute;left:0;right:0;top:6px;text-align:center;font-size:12px;color:{OV1}">retry.ex · minga</span></div>'
         f'<div style="position:absolute;left:14px;top:36px;width:{cx(COLS)}px;height:{cy(ROWS)}px;font-family:\'SF Mono\',Menlo,ui-monospace,monospace;font-size:{FS}px">{stage}</div></div>')
    notes=(f'<div style="position:absolute;left:{40+term_w+28}px;top:84px;width:{1400-(40+term_w+28)}px;font-size:12.5px;line-height:19px;color:{SUB0}">'
           f'<div style="color:{TXT};font-weight:600;margin-bottom:6px">In a terminal</div>'
           f'<div>The pointer is shown as a highlighted cell: terminals report the cell under the mouse, they draw no arrow.</div>'
           f'<div style="margin-top:8px">A click flashes the target in reverse video for a moment.</div>'
           f'<div style="margin-top:8px">Hover text goes to the echo line, not a floating tooltip.</div>'
           f'<div style="margin-top:8px">Motion tracking is on only while which-key or a drawer is open, so plain editing costs nothing.</div>'
           f'<div style="margin-top:8px">Chips are bracketed: <span style="font-family:\'SF Mono\',Menlo,monospace;color:{TXT}">[y Approve once]</span>.</div></div>')
    caps=[(0,1.0,"Plain editing in the terminal."),
          (1.0,2.0,"Hover the mode pill: the echo line names it. Click it."),
          (2.0,4.8,"Which-key opens. Click Minga."),
          (4.8,7.8,"SPC › a. Click Tasks."),
          (7.8,11.8,"The tasks drawer. Click the [y Approve once] chip."),
          (11.8,15.4,"The row turns to Working. Click [esc close] in the border."),
          (15.4,D,"Same flow as macOS, cell by cell.")]
    cap=captions(tl,caps)
    write("Mouse_Video_TUI.dc.html",board("Mouse video: the terminal","Mouse video 4","the mode-pill flow in the Go TUI (patterns 1 and 6)",win,cap,[c[2] for c in caps],tl,right_html=notes))
    return D,caps

if __name__=="__main__":
    for f in (board_modepill,board_modeline_menubar,board_actmenu,board_tui):
        D,caps=f(); print(f.__name__,D,"s")
