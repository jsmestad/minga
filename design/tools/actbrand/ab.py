import os as _os
TOOLS = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))
BOARDS = _os.environ.get("BOARDS_DIR", _os.path.join(TOOLS, "..", "boards"))  # committed boards, read only
OUT_DIR = _os.environ.get("OUT_DIR", _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "out"))
_os.makedirs(OUT_DIR, exist_ok=True)
import os, subprocess
S = TOOLS
os.environ["OUT_DIR"]=OUT_DIR
b7=open(S+"/batch7/b7.py").read()
exec(b7[:b7.index("# ===== 1. hover on code")])
OUT=os.environ["OUT_DIR"]; os.makedirs(OUT,exist_ok=True)

# ---------------- shared vocabulary
ACC="#b98cf0"            # key letters (minga accent)
EDGE={"minga":"#a463e6","failure":"#e5707a","neutral":"rgba(255,255,255,0.22)"}
TINT={"minga":"rgba(164,99,230,0.14)","failure":"rgba(229,112,122,0.12)","neutral":"rgba(108,184,245,0.14)"}
RING={"minga":"rgba(164,99,230,0.55)","failure":"rgba(229,112,122,0.5)","neutral":"rgba(108,184,245,0.55)"}
SF="-apple-system,'SF Pro Text',system-ui,sans-serif"

def head(glyph,title,meta,role,compact=False):
    pad="8px 14px 7px" if not compact else "7px 12px 6px"
    return (f'<div style="padding:{pad}">'
      f'<div style="display:flex;align-items:center;gap:7px;white-space:nowrap"><span style="display:inline-flex">{glyph}</span>'
      f'<span style="font-size:12.5px;font-weight:600;color:#ecebe8">{title}</span><span style="font-size:12px;color:#8f8d88">{meta}</span></div>'
      +("" if compact else f'<div style="margin-top:6px;display:flex;align-items:center;gap:5px;font-family:{MONO};font-size:12px"><span style="color:{EDGE[role] if role!="neutral" else "#a5a39e"};font-weight:700">›</span>{CUR}<span style="color:#6e7079;margin-left:5px;font-family:{SF};font-size:12px">type to filter</span></div>')+'</div>')

def glabel(t): return f'<div style="padding:5px 14px 2px;font-size:11px;font-weight:600;color:#7a7c85;letter-spacing:0.01em">{t}</div>'
def row(key,label,note="",direct="",sel=False,role="minga"):
    bg=f"background:{TINT[role]};box-shadow:inset 0 0 0 1px {RING[role]};" if sel else ""
    n=f'<span style="color:#8f8d88;font-size:11.5px;margin-left:8px;white-space:nowrap">{note}</span>' if note else ""
    d=f'<span style="font-family:{MONO};font-size:11px;color:#6e7079;white-space:nowrap">{direct}</span>' if direct else ""
    return (f'<div style="height:24px;display:flex;align-items:center;margin:0 6px;padding:0 8px;border-radius:6px;{bg}">'
      f'<span style="width:22px;flex:none;font-family:{MONO};font-size:12.5px;font-weight:700;color:{ACC}">{key}</span>'
      f'<span style="font-size:12.5px;color:{"#f2f1ee" if sel else "#dcdce2"};white-space:nowrap">{label}</span>{n}<span style="flex:1"></span>{d}</div>')
def foot(compact=False):
    if compact: return ""
    return (f'<div style="margin-top:4px;padding:5px 14px;border-top:1px solid rgba(255,255,255,0.06);display:flex;gap:14px;font-size:11px;color:#7a7c85">'
      f'<span><span style="font-family:{MONO};color:#c9c7c2">↩</span> run</span><span><span style="font-family:{MONO};color:#c9c7c2">j k</span> move</span><span><span style="font-family:{MONO};color:#c9c7c2">esc</span> close</span>'
      f'<span style="flex:1"></span><span style="font-family:{MONO}">g.  ⌃.  right-click</span></div>')

def half(key,label,cons,direct,sel,role):
    if sel: st=f"background:{TINT[role]};box-shadow:inset 0 0 0 1px {RING[role]};"
    else:   st="background:rgba(255,255,255,0.035);box-shadow:inset 0 0 0 1px rgba(255,255,255,0.08);"
    return (f'<div style="flex:1;min-width:0;border-radius:8px;padding:7px 10px 7px 10px;{st}">'
      f'<div style="display:flex;align-items:baseline;gap:8px"><span style="font-family:{MONO};font-size:14px;font-weight:700;color:{ACC}">{key}</span>'
      f'<span style="font-size:13.5px;font-weight:600;color:#f2f1ee">{label}</span><span style="flex:1"></span><span style="font-family:{MONO};font-size:10.5px;color:#6e7079">{direct}</span></div>'
      +(f'<div style="margin-top:2px;padding-left:20px;font-size:11.5px;color:#a5a39e;white-space:nowrap">{cons}</div>' if cons else "")+'</div>')
def decision(pair,role):
    return f'<div style="display:flex;gap:6px;padding:2px 10px 6px">{"".join(half(*p,role) for p in pair)}</div>'
def primary(key,label,cons,direct,role):
    return f'<div style="padding:2px 10px 6px">{half(key,label,cons,direct,True,role)}</div>'

def shell(inner,role,w,left,top,extra=""):
    return (f'<div style="position:absolute;left:{left}px;top:{top}px;width:{w}px;background:#26272e;border:1px solid rgba(255,255,255,0.10);border-left:3px solid {EDGE[role]};'
      f'border-radius:9px;box-shadow:0 16px 38px rgba(0,0,0,0.55),0 1px 0 rgba(255,255,255,0.04) inset;font-family:{SF};color:#dcdce2;overflow:hidden;{extra}">{inner}</div>')

def strand_shell(inner,w,left,top):
    # B: the gutter strand runs on as the menu's left edge (two strands at the gutter columns)
    strip=(f'<svg width="10" height="100%" style="position:absolute;left:0;top:0;height:100%" preserveAspectRatio="none" viewBox="0 0 10 100">'
           f'<path d="M3 0 L3 100" stroke="#6b3fa3" stroke-width="2.6"/><path d="M7 0 L7 100" stroke="#a463e6" stroke-width="2.6"/></svg>')
    return (f'<div style="position:absolute;left:{left}px;top:{top}px;width:{w}px;font-family:{SF};color:#dcdce2">'
      f'<div style="position:absolute;left:0;top:0;bottom:0;width:10px">{strip}</div>'
      f'<div style="margin-left:14px;background:#25262c;border:1px solid rgba(255,255,255,0.09);border-radius:0 9px 9px 9px;box-shadow:0 14px 34px rgba(0,0,0,0.5);overflow:hidden">{inner}</div></div>')
def connector(top,h):
    return (f'<svg width="10" height="{h}" viewBox="0 0 10 {h}" style="position:absolute;left:62px;top:{top}px">'
            f'<path d="M3 0 L3 {h}" stroke="#6b3fa3" stroke-width="2.6"/><path d="M7 0 L7 {h}" stroke="#a463e6" stroke-width="2.6"/></svg>')

GL_UNREV=B.st("Waiting",13); GL_ERR=B.st("Failed",13)
# code: Minga's change on the first four lines
CODEA=[(232,f'{kw("@spec")} workspace_agent_status({mod("Workspace")}.t()) :: {mod("AgentPresence")}.state()',"head"),
 (233,f'{kw("defp")} workspace_agent_status(ws) {kw("do")}',"body"),(234,f'  ws |&gt; payload() |&gt; {mod("AgentPresence")}.of()',"body"),(235,kw("end"),"last"),(236,"",""),
 (237,f'{kw("defp")} usage_limit(ws) {kw("do")}',""),(238,f'  ws |&gt; payload() |&gt; limit_label()',""),(239,kw("end"),""),(240,"",""),
 (241,f'{kw("def")} agent_label(%{{state: :working, action: a}}), {kw("do")}: a',""),(242,f'{kw("def")} agent_label(_), {kw("do")}: {s_(chr(34)+chr(34))}',""),
 (243,"",""),(244,f'{kw("defp")} payload(%{mod("Workspace")}{{payload: p}}), {kw("do")}: p',""),(245,"",""),(246,"",""),(247,"",""),(248,"",""),(249,"",""),(250,"",""),(251,"",""),(252,"","")]
def coderows(cont=False,n=None):
    out=[]
    for num,t,m in CODEA[:n]:
        mk="body" if (cont and m=="last") else m
        out.append(mrow(num,t,mk,bg="rgba(164,99,230,0.06)" if m else ""))
    return "".join(out)

T_HEAD="Minga's change 1 of 2"; T_META=f'· 4 lines · <span style="display:inline-flex;vertical-align:-2px">{B.st("Waiting",11)}</span> unreviewed'
def meta_html(): return f'<span style="display:inline-flex;align-items:center;gap:5px">· 4 lines ·{B.st("Waiting",11)}unreviewed</span>'

def menu_A(w=470,left=70,top=84):
    body=(head(GL_UNREV,T_HEAD,meta_html(),"minga")
      +decision([("y","Keep","accept 4 lines","SPC a y",True),("n","Reject","removes 4 lines, restores 1","SPC a d",False)],"minga")
      +glabel("This change")+row("=","Show diff")+row("o","Open conversation","","SPC a v")
      +glabel("This file")+row("l","Copy file:line link")+row("b","Blame this line","","SPC g B")
      +glabel("Anywhere")+row("?","Ask Minga about this","","SPC a ?")+foot())
    return shell(body,"minga",w,left,top)
def menu_B(w=420,left=62,top=78):
    body=(head(GL_UNREV,T_HEAD,meta_html(),"minga")
      +glabel("This change")+row("y","Keep","accept 4 lines","SPC a y",sel=True)+row("=","Show diff")+row("o","Open conversation","","SPC a v")
      +row("n","Reject","removes 4 lines, restores 1","SPC a d")
      +glabel("This file")+row("l","Copy file:line link")+row("b","Blame this line","","SPC g B")
      +glabel("Anywhere")+row("?","Ask Minga about this","","SPC a ?")+foot())
    return strand_shell(body,w,left,top)

def mainwin(menu,cont,w=900,h=466,pos="232:1"):
    return macwin(area(coderows(cont)+menu)+modeline(file="chrome_state.ex",right="Elixir",pos=pos),title="chrome_state.ex",path="lib/minga_editor/session",w=w,h=h)

# ---- insets (diagnostic and file row)
D_CODE=[(238,f'  {kw("case")} status {kw("do")}',""),(239,f'    429 -&gt; {{:rate_limited, {mod("Retry")}.{u_err("after_ms(headers, :ms)")}}}',""),(240,"","")]
def inset_box(code_html,menu,label,sub,w=468,h=222):
    return (f'<div style="width:{w}px"><div class="lab"><b>{label}</b>  {sub}</div>'
      f'<div style="position:relative;width:{w}px;height:{h}px;border-radius:9px;overflow:hidden;border:1px solid #2e3038;background:#1e1f24">'
      f'<div style="position:absolute;inset:0;padding-top:6px;font-family:{MONO};font-size:13px;color:#c9c7c2">{code_html}</div>{menu}</div></div>')
def diag_menu(style,left=70,top=64,w=360):
    hd=head(GL_ERR,"Error","· Retry.after_ms/2 is undefined · elixir","failure",compact=True)
    if style=="A":
        body=hd+primary("f","Fix: call after_ms/1","edits 1 line","","failure")+glabel("This diagnostic")+row("?","Ask Minga to fix","","SPC a ?")+row("d","Open docs","","K K")
        return shell(body,"failure",w,left,top)
    body=hd+glabel("This diagnostic")+row("f","Fix: call after_ms/1","edits 1 line","",sel=True,role="failure")+row("?","Ask Minga to fix","","SPC a ?")+row("d","Open docs","","K K")
    return shell(body,"failure",w,left,top)
TREE=[("▾ lib/","#8f8d88"),("  ▾ minga_agent/","#8f8d88"),("      retry.ex","#ecebe8"),("      session.ex","#c9c7c2")]
def tree_html(sel=2):
    out=""
    for i,(t,c) in enumerate(TREE):
        bg="background:rgba(255,255,255,0.06);" if i==sel else ""
        out+=f'<div style="height:18px;display:flex;align-items:center;padding-left:14px;{bg};white-space:pre;color:{c};font-size:12.5px">{t}</div>'
    return out
def file_menu(style,left=150,top=58,w=300):
    hd=head(B.st("Done",0).replace('width="0"','width="0"') if False else "", "retry.ex","· lib/minga_agent · 142 lines","neutral",compact=True)
    hd=hd.replace('<span style="display:inline-flex"></span>','')
    if style=="A":
        body=hd+primary("↩","Open","","","neutral")+glabel("This file")+row("v","Open in split")+row("r","Rename…")+row("D","Delete…","moves to Trash")
    else:
        body=hd+glabel("This file")+row("↩","Open","","",sel=True,role="neutral")+row("v","Open in split")+row("r","Rename…")+row("D","Delete…","moves to Trash")
    return shell(body,"neutral",w,left,top)
def insets(style):
    a=inset_box("".join(mrow(n,t,"") for n,t,_ in D_CODE),diag_menu(style),"A diagnostic","the edge takes the failure role")
    b=inset_box(f'<div style="font-family:{SF}">{tree_html()}</div>',file_menu(style),"A file row in the tree","neutral edge, nothing Minga about it")
    return f'<div style="display:flex;flex-direction:column;gap:10px">{a}{b}</div>'

# ---------------- TUI
TCODE=[(232,"@spec workspace_agent_status(Workspace.t())","head"),(233,"defp workspace_agent_status(ws) do","body"),(234,"  ws |> payload() |> AgentPresence.of()","body"),(235,"end","body"),
 (236,"",""),(237,"defp usage_limit(ws) do",""),(238,"  ws |> payload() |> limit_label()",""),(239,"end",""),(240,"",""),(241,"def agent_label(%{state: :working, action: a}), do: a",""),
 (242,'def agent_label(_), do: ""',""),(243,"",""),(244,"defp payload(%Workspace{payload: p}), do: p",""),(245,"",""),(246,"",""),(247,"",""),(248,"","")]
TWD=76
def tgrid(style):
    g=G.Grid(TWD,TH)
    for i,(n,t,m) in enumerate(TCODE[:TH-2]):
        trow(g,i,n,t,m,bg=None)
    MP=G.PURPLED
    def fill(d):
        d.segs(1,2,[("›",MP,None,"b"),(" ",None),("▏",G.BLUE),("type to filter",G.DIM)])
        r=2
        if style=="A":
            L=" y Keep · 4 lines "; Rr=" n Reject · removes 4, restores 1 "
            d.put(r,2,L,"#1e1f24",MP,"b"); d.put(r,2+len(L)+1,Rr,G.TXT,"#3a3c44")
            r=3
            rows=[("lab","This change"),("=","Show diff",""),("o","Open conversation","SPC a v"),("lab","This file"),("l","Copy file:line link",""),("b","Blame this line","SPC g B"),("lab","Anywhere"),("?","Ask Minga about this","SPC a ?")]
        else:
            rows=[("lab","This change"),("y","Keep · accept 4 lines","SPC a y","sel"),("=","Show diff",""),("o","Open conversation","SPC a v"),("n","Reject · removes 4, restores 1","SPC a d"),("lab","This file"),("l","Copy file:line link",""),("b","Blame this line","SPC g B"),("lab","Anywhere"),("?","Ask Minga about this","SPC a ?")]
        for it in rows:
            if it[0]=="lab":
                d.put(r,3,it[1],G.DIM,None,"b"); r+=1; continue
            sel=len(it)>3
            bg="#3b2f4f" if sel else None
            if sel: d.bgrow(r,1,d.w-2,bg); d.put(r,1,"▌",MP,bg)
            d.segs(r,3,[(it[0],G.PURPLE,bg,"b"),("  "+it[1],G.TXT,bg,"b" if sel else None)])
            if it[2]: d.put(r,d.w-2-len(it[2]),it[2],(G.SUB if sel else G.DIM),bg)
            r+=1
    h=14 if style=="A" else 14
    top=4
    left=6
    w=58
    d=G.Grid(w,h,bg=SURF)
    d.box(0,0,h,w,MP,SURF,title=[("○ ",G.SUB),("Minga's change 1 of 2",G.TXT,"b"),(" · 4 lines",G.DIM)],bottom=[("↩",G.TXT),(" run  ",G.DIM),("j k",G.TXT),(" move  ",G.DIM),("esc",G.TXT),(" close",G.DIM)])
    fill(d); blit(g,d,top,left)
    for y in range(top+1,min(top+h+1,g.h)):
        if left+w<g.w: g.c[y][left+w][2]="#141519"
    if top+h<g.h:
        for x in range(left+1,min(left+w+1,g.w)): g.c[top+h][x][2]="#141519"
    tmode(g,TH-2,"NORMAL",[(" chrome_state.ex ",G.TXT,"#30313a","b"),(" change 1/2 ",G.PURPLE,"#2e2840")]," 232:1 ")
    return g


# ---------------- Direction A (owner choice) drawn by the shared helpers in dira.py
DEC_CHANGE=("decision",[("y","Keep","accept 4 lines","SPC a y",True),("n","Reject","removes 4 lines, restores 1","SPC a d",False)])
GR_CHANGE=[("This change",[("=","Show diff"),("o","Open conversation","","SPC a v")]),("This file",[("l","Copy file:line link"),("b","Blame this line","","SPC g B")]),("Anywhere",[("?","Ask Minga about this","","SPC a ?")])]
def menu_A(w=470,left=70,top=84):
    return menuA(GL_UNREV,T_HEAD,meta_html(),"minga",DEC_CHANGE,GR_CHANGE,w=w,left=left,top_px=top)
_diag_B=diag_menu; _file_B=file_menu
def diag_menu(style,left=70,top=64,w=360):
    if style!="A": return _diag_B(style,left,top,w)
    return menuA(GL_ERR,"Error","· Retry.after_ms/2 is undefined","failure",("primary",("f","Fix: call after_ms/1","edits 1 line","")),
                 [("This diagnostic",[("?","Ask Minga to fix","","SPC a ?"),("d","Open docs","","K K")])],w=w,left=left,top_px=top,compact=True,foot=False)
def file_menu(style,left=150,top=58,w=300):
    if style!="A": return _file_B(style,left,top,w)
    return menuA("","retry.ex","· lib/minga_agent · 142 lines","neutral",("primary",("↩","Open","","")),
                 [("This file",[("v","Open in split","","⌃V"),("r","Rename…"),("D","Delete…","moves to Trash")])],w=w,left=left,top_px=top,compact=True,foot=False)
_tgrid_B=tgrid
def tgrid(style):
    if style!="A": return _tgrid_B(style)
    g=G.Grid(TWD,TH)
    for i,(n,t,m) in enumerate(TCODE[:TH-2]): trow(g,i,n,t,m,bg=None)
    tmenuA(g,4,6,58,"minga",[("○ ",G.SUB),("Minga's change 1 of 2",G.TXT,"b"),(" · 4 lines",G.DIM)],DEC_CHANGE,GR_CHANGE)
    tmode(g,TH-2,"NORMAL",[(" chrome_state.ex ",G.TXT,"#30313a","b"),(" change 1/2 ",G.PURPLE,"#2e2840")]," 232:1 ")
    return g

EXITS=[("y / ↩ (Keep preselected)","minga.review.in_file (kept; cursor to the next change)"),("n Reject","minga.review.in_file (rejected; never preselected)"),("=","minga.review.diff_inline"),("o","minga.conversation"),("l","edit.plain (link copied)"),("b","git.blame"),("?","minga.inline_ask"),("typing","minga.act_menu.filtered"),("esc","edit.plain")]

def board_dir(style,name,title,sub,note,menu,cont):
    mac=f'<div style="display:flex;gap:24px">{labeled("g. on a Minga change", sub, mainwin(menu,cont))}{insets(style)}</div>'
    write(name,board(title,("",""),mac,"",tterm(tgrid(style),"TUI","Lip Gloss rounded panel, border in the target's role colour"),EXITS,note).replace('<div class="lab"><b></b>  </div>',''))

board_dir("A","ActMenu_DirectionA.dc.html","Act menu, direction A: decision first",
  "the yes or no sits on top as two halves with their consequences; everything else is a quieter list",
  "The yes/no grammar leads: Keep and Reject are two halves of one decision, each with its consequence, Keep preselected, Reject never. Below, verbs are grouped by what they act on. The left edge carries the target's role colour: minga for Minga's change, failure for a diagnostic, neutral for a file. The TUI draws the decision as two reverse-video halves.",
  menu_A(),False)
board_dir("B","ActMenu_DirectionB.dc.html","Act menu, direction B: strand anchored",
  "the change's strand runs down out of the gutter and becomes the menu's edge; the first row is the decision",
  "Lighter: one list, the decision is simply the first row (Keep, preselected) and Reject is last in its group. Identity comes from the connection: the two strands of the gutter twist continue into the menu's left edge, so the menu reads as part of the change. Diagnostics and files keep a plain role-coloured edge because they have no strand.",
  menu_B()+connector(78,4),True)

# ---------------- compare
def cwin(menu,cont):
    return macwin(area(coderows(cont)+menu)+modeline(file="chrome_state.ex",right="Elixir",pos="232:1"),title="chrome_state.ex",path="lib/minga_editor/session",w=684,h=466)
ca=cwin(menu_A(w=420,left=70,top=84),False)
cb=cwin(menu_B(w=420,left=62,top=78)+connector(78,4),True)
mac=f'<div style="display:flex;gap:24px">{labeled("A · Decision first","strongest identity: the yes/no grammar is the first thing you see; takes more space",ca)}{labeled("B · Strand anchored","lighter: identity comes from the strand connecting the menu to the change",cb)}</div>'
tui=f'<div style="display:flex;gap:12px">{G.term(tgrid("A").html(),"TUI · A","")}{G.term(tgrid("B").html(),"TUI · B","")}</div>'
html=board("Act menu: A and B compared",("",""),mac,"",tui,[],"Same target, same code, same actions. A spends about 60 px on the decision and makes Minga's yes/no grammar the brand moment. B costs nothing extra and makes the strand the brand moment, but only Minga's changes have a strand, so other targets fall back to a plain coloured edge.").replace('<div class="lab"><b></b>  </div>','')
html=html.replace('<h4>Exits</h4>','<h4>Trade-off</h4>')
write("ActMenu_Compare.dc.html",html)

