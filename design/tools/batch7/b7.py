import os as _os
TOOLS = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))
BOARDS = _os.environ.get("BOARDS_DIR", _os.path.join(TOOLS, "..", "boards"))  # committed boards, read only
OUT_DIR = _os.environ.get("OUT_DIR", _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "out"))
_os.makedirs(OUT_DIR, exist_ok=True)
import os
S = TOOLS
os.environ.setdefault("OUT_DIR",S+"/batch7/out")
b4=open(S+"/batch4/b4.py").read()
exec(b4[:b4.index("# ===== 1. windows.narrow")])
OUT=os.environ["OUT_DIR"]; os.makedirs(OUT,exist_ok=True)

MONO="ui-monospace,'SF Mono',Menlo,monospace"
# ---------- macOS building blocks
def mrow(num,html,mark="",bg="",numcol="#7a7c85"):
    return f'<div class="ln" style="background:{bg}"><span class="num" style="color:{numcol}">{num}</span><span class="sign"></span><span class="bar">{MARK[mark] if mark else ""}</span><span class="code">{html}</span></div>'
def area(rows,overlays="",h=None):
    hh=f"height:{h}px;flex:none;" if h else "flex:1;min-height:0;"
    return f'<div style="{hh}position:relative;overflow:hidden;padding-top:6px;font-family:{MONO};font-size:13px;color:#c9c7c2">{rows}{overlays}</div>'
def pop(inner,left,top,w,focus=False,extra="",cls=""):
    bc="#5b9bd5" if focus else "rgba(255,255,255,0.12)"
    return f'<div style="position:absolute;left:{left}px;top:{top}px;width:{w}px;background:#2a2b32;border:1px solid {bc};border-radius:8px;box-shadow:0 14px 34px rgba(0,0,0,0.55);font-family:-apple-system,system-ui,sans-serif;font-size:12.5px;color:#dcdce2;overflow:hidden;{extra}">{inner}</div>'
def psec(inner,border=True): return f'<div style="padding:8px 12px;{"border-top:1px solid rgba(255,255,255,0.07);" if border else ""}">{inner}</div>'
def pfoot(*hs): return f'<div style="padding:5px 12px;border-top:1px solid rgba(255,255,255,0.07);background:#25262c;font-size:11.5px;display:flex;gap:14px">{"".join(hint(a,b) for a,b in hs)}</div>'
def mono(t,col="#c9c7c2",size=12): return f'<span style="font-family:{MONO};font-size:{size}px;color:{col}">{t}</span>'
def diag(sev,src,msg):
    col={"Error":"#e5707a","Warning":"#d8c08a"}[sev]
    return f'<div style="display:flex;gap:8px;align-items:flex-start"><span style="width:3px;align-self:stretch;border-radius:2px;background:{col};flex:none"></span><div><div style="font-size:11px;color:{col};font-weight:700">{sev} · <span style="font-weight:400;color:#8f8d88">{src}</span></div><div style="margin-top:2px">{msg}</div></div></div>'
CUR='<span style="display:inline-block;width:8px;height:16px;vertical-align:-3px;background:#6cb8f5;opacity:0.85"></span>'
def u_err(t): return f'<span style="text-decoration:underline wavy #e5707a;text-underline-offset:3px">{t}</span>'

# act menu (macOS)
def item(acc,label,direct="",note="",sel=False,dim=False):
    bg="background:rgba(26,149,242,0.85);color:#fff;" if sel else ""
    ac="#fff" if sel else "#b98cf0"
    nc="rgba(255,255,255,0.8)" if sel else "#8f8d88"
    dc="rgba(255,255,255,0.85)" if sel else "#7a7c85"
    op="opacity:0.45;" if dim else ""
    n=f'<span style="color:{nc};font-size:11.5px;margin-left:8px">{note}</span>' if note else ""
    return f'<div style="height:24px;display:flex;align-items:center;gap:10px;padding:0 10px;margin:0 4px;border-radius:5px;{bg}{op}"><span style="width:14px;font-family:{MONO};font-weight:700;color:{ac}">{acc}</span><span>{label}</span>{n}<span style="flex:1"></span><span style="font-family:{MONO};font-size:11px;color:{dc}">{direct}</span></div>'
def sep(lab=""): return f'<div style="margin:4px 14px 2px;padding-top:4px;border-top:1px solid rgba(255,255,255,0.07);font-size:10.5px;color:#7a7c85;letter-spacing:0.03em">{lab}</div>' if lab else '<div style="margin:4px 14px;border-top:1px solid rgba(255,255,255,0.07)"></div>'
def actmenu(target,items,filt="",w=360,left=0,top=0,foot=True):
    f=f'<span style="color:#ecebe8">{filt}</span>{CUR}' if filt else f'{CUR}<span style="color:#7a7c85;margin-left:6px">type to filter</span>'
    head=f'<div style="padding:7px 12px 6px;border-bottom:1px solid rgba(255,255,255,0.07)"><div style="font-size:11.5px;color:#a5a39e">{target}</div><div style="margin-top:5px;font-family:{MONO};font-size:12px;display:flex;align-items:center;gap:4px"><span style="color:#b98cf0">›</span>{f}</div></div>'
    ft=pfoot(("↩","run"),("j k","move"),("esc","close")) if foot else ""
    return pop(head+f'<div style="padding:4px 0">{"".join(items)}</div>'+ft,left,top,w,focus=True)

# ---------- TUI building blocks
def tpop(g,r,c,h,w,title,bottom,fill):
    d=G.Grid(w,h,bg=SURF); d.box(0,0,h,w,G.FOCUS,SURF,title=title,bottom=bottom)
    fill(d); blit(g,d,r,c)
    for y in range(r+1,min(r+h+1,g.h)):
        if c+w<g.w: g.c[y][c+w][2]="#141519"
    if r+h<g.h:
        for x in range(c+1,min(c+w+1,g.w)): g.c[r+h][x][2]="#141519"
def titem(d,r,acc,label,direct="",note="",sel=False):
    bg="#3b3f4a" if sel else None
    if sel: d.bgrow(r,1,d.w-2,bg); d.put(r,1,"▌",G.BLUE,bg)
    x=d.segs(r,2,[(acc,G.BLUE if sel else G.PURPLE,bg,"b"),("  "+label,G.TXT,bg,"b" if sel else None)])
    if note: d.put(r,x+2,note,G.SUB if sel else G.DIM,bg)
    if direct: d.put(r,d.w-2-len(direct),direct,G.SUB if sel else G.DIM,bg)
def tsep(d,r,lab=""):
    d.put(r,2,"─"*(d.w-4),"#3a3c44")
    if lab: d.put(r,3," "+lab+" ",G.DIM)
def trow(g,r,num,text,mark="",col=G.CODE,bg=None,numcol=None):
    if bg: g.bgrow(r,0,g.w,bg)
    g.put(r,0,f"{num:>5} ",numcol or G.DIM,bg)
    if mark=="head": g.put(r,7,"╳",G.PURPLED,bg)
    elif mark=="body": g.put(r,7,"┃",G.PURPLED,bg)
    elif mark=="you": g.put(r,7,"│",G.BLUE,bg)
    g.put(r,9,text,col,bg)

R_CODE=[(237,f'{kw("def")} classify(status, headers) {kw("do")}'),
 (238,f'  {kw("case")} status {kw("do")}'),
 (239,f'    429 -&gt; {{:rate_limited, {mod("Retry")}.{u_err("after_ms(headers, :ms)")}}}'),
 (240,f'    529 -&gt; {{:overloaded, backoff_ms(2)}}'),
 (241,f'    _ -&gt; {{:fatal, status}}'),
 (242,f'  {kw("end")}'),(243,kw("end")),(244,""),
 (245,f'{kw("defp")} backoff_ms(n), {kw("do")}: n * 1_000')]
T_CODE=[(237,"def classify(status, headers) do"),(238,"  case status do"),(239,"    429 -> {:rate_limited, Retry.after_ms(headers, :ms)}"),(240,"    529 -> {:overloaded, backoff_ms(2)}"),(241,"    _ -> {:fatal, status}"),(242,"  end"),(243,"end"),(244,""),(245,"defp backoff_ms(n), do: n * 1_000")]

exec(open(TOOLS+"/actbrand/dira.py").read())  # Direction A act menu (owner choice)
# ===== 1. hover on code
rows="".join(mrow(n,t,bg="rgba(255,255,255,0.03)" if n==239 else "",numcol="#ecebe8" if n==239 else "#7a7c85") for n,t in R_CODE)
compact=pop(psec(diag("Error","elixir",f'{mono("Retry.after_ms/2")} is undefined. Did you mean {mono("after_ms/1")}?'),border=False)
 +psec(mono('@spec after_ms([{String.t(), String.t()}]) :: non_neg_integer()','#8fc7ff',11.5))
 +psec('<span style="color:#c9c7c2">Reads the Retry-After header as milliseconds. Falls back to the provider\'s window when the header is missing.</span>')
 +pfoot(("K","more"),("g.","actions · 1 fix")),292,66,420)
m1=macwin(area(rows,compact)+modeline(file="retry.ex",right="Elixir",pos="239:32"),title="retry.ex",path="lib/minga_agent",w=684,h=360)
mid=(psec(f'{mono("Retry.after_ms(headers)","#ecebe8")}<div style="margin-top:3px">{mono("@spec after_ms([{String.t(), String.t()}]) :: non_neg_integer()","#8fc7ff",11.5)}</div>')
 +psec('<div style="color:#c9c7c2">Reads the Retry-After header as milliseconds. Falls back to the provider\'s window when the header is missing.</div><div style="margin-top:8px;font-weight:700;color:#ecebe8;font-size:12px">Examples</div><div style="margin-top:4px;padding:6px 8px;background:#1e1f24;border-radius:5px">'+mono('iex&gt; Retry.after_ms([{"retry-after", "40"}])<br>40_000')+'</div><div style="margin-top:8px;font-size:12px"><span style="color:#8fc7ff;text-decoration:underline;text-underline-offset:3px">lib/minga_agent/retry.ex:88</span>  <span style="color:#7a7c85">·</span>  <span style="color:#8fc7ff;text-decoration:underline;text-underline-offset:3px">hexdocs: Retry.after_ms/1</span></div>'))
full=pop(psec(diag("Error","elixir",f'{mono("Retry.after_ms/2")} is undefined. Did you mean {mono("after_ms/1")}?')+'<div style="margin:6px 0 0 11px">'+k("g.","fix: call after_ms/1")+'</div>',border=False)
 +f'<div style="flex:1;min-height:0;overflow:hidden;position:relative">{mid}<div style="position:absolute;right:3px;top:6px;width:3px;height:46px;border-radius:2px;background:rgba(255,255,255,0.28)"></div></div>'
 +pfoot(("j k","scroll"),("↩","follow link"),("y","copy"),("q","close")),232,30,440,focus=True,extra="height:286px;display:flex;flex-direction:column")
sb='<div style="position:absolute;left:666px;top:54px;width:3px;height:70px;border-radius:2px;background:rgba(255,255,255,0.25)"></div>'
m2=macwin(area("".join(mrow(n,t,numcol="#7a7c85") for n,t in R_CODE),full)+modeline(file="*hover*  Retry.after_ms/1",right=None,pos="3/9"),title="retry.ex",path="lib/minga_agent",w=684,h=360)
mac=f'<div style="display:flex;gap:24px">{labeled("K on the error","compact: the problem first, then the signature and one paragraph",m1)}{labeled("K again","focused: full docs scroll in place; q or esc returns to the code",m2)}</div>'
def tcodegrid(w,h,cur=239,dim=False):
    g=G.Grid(w,h)
    for i,(n,t) in enumerate(T_CODE):
        if i>=h-2: break
        trow(g,i,n,t,col=("#5f616a" if dim else G.CODE),bg=("#25262d" if n==cur and not dim else None),numcol=(G.TXT if n==cur else None))
    return g
g1=tcodegrid(62,TH)
for x in range(9+29,9+29+19): g1.c[2][x][3]="u"
def f1(d):
    d.segs(1,2,[("▌",G.RED),(" Error ",G.RED,None,"b"),("· elixir",G.DIM)])
    d.segs(2,3,[("Retry.after_ms/2 is undefined.",G.TXT)]); d.segs(3,3,[("Did you mean after_ms/1?",G.TXT)])
    d.put(4,2,"─"*(d.w-4),"#3a3c44")
    d.put(5,2,"@spec after_ms([{String.t(), String.t()}])",G.FN); d.put(6,4,":: non_neg_integer()",G.FN)
    d.put(7,2,"─"*(d.w-4),"#3a3c44")
    d.put(8,2,"Reads the Retry-After header as ms.",G.CODE)
tpop(g1,3,14,11,46,[("Retry.after_ms/2",G.TXT,"b")],[("K",G.TXT),(" more  ",G.DIM),("g.",G.TXT),(" actions",G.DIM)],f1)
tmode(g1,TH-2,"NORMAL",[(" retry.ex ",G.TXT,"#30313a","b"),(" E 1 ",G.RED,"#3a2328","b")]," 239:32 ")
g2=tcodegrid(62,TH,dim=True)
def f2(d):
    d.segs(1,2,[("▌",G.RED),(" Error ",G.RED,None,"b"),("· elixir   ",G.DIM),("g.",G.PURPLE,None,"b"),(" fix",G.CODE)])
    d.put(2,3,"Retry.after_ms/2 is undefined.",G.TXT)
    d.put(3,2,"─"*(d.w-4),"#3a3c44")
    d.put(4,2,"Reads the Retry-After header as ms.",G.CODE); d.put(5,2,"Falls back to the provider's window.",G.CODE)
    d.put(6,2,"Accepts delta-seconds and HTTP dates.",G.CODE)
    d.put(7,2,"Examples",G.TXT,None,"b")
    d.bgrow(8,2,d.w-4,"#1e1f24"); d.put(8,3,'iex> Retry.after_ms([{"retry-after","40"}])',G.CODE,"#1e1f24")
    d.bgrow(9,2,d.w-4,"#1e1f24"); d.put(9,3,"40_000",G.CODE,"#1e1f24")
    d.put(11,2,"lib/minga_agent/retry.ex:88",G.FN,None,"bu")
    d.put(4,d.w-2,"┃",G.SUB)
tpop(g2,1,6,14,54,[("*hover*",G.SUB),("  Retry.after_ms/1",G.TXT,"b")],[("j k",G.TXT),(" scroll  ",G.DIM),("↩",G.TXT),(" link  ",G.DIM),("y",G.TXT),(" copy  ",G.DIM),("q",G.TXT),(" close",G.DIM)],f2)
tmode(g2,TH-2,"NORMAL",[(" *hover* ",G.TXT,"#30313a","b"),(" Retry.after_ms/1 ",G.SUB,"#25262c")]," 3/9 ")
write("Batch7_hover_code.dc.html",board("Batch 7: K on code",("Hover on code","one surface for every hover: the problem first, then what the thing is, then how to act"),mac,"",tterms((g1,"TUI","K: compact Lip Gloss layer"),(g2,"","K again: focused, scrolls")),
 [("compact: K","code.hover.focused"),("compact: g.","minga.act_menu (target: this diagnostic and symbol)"),("compact: any motion or esc","edit.plain (the popover closes; nothing moved)"),("focused: j k, ⌃D ⌃U","code.hover.focused (scrolls)"),("focused: ↩ on a link","edit.plain (jumps to retry.ex:88)"),("focused: y","code.hover.focused (copies the docs)"),("focused: q or esc","edit.plain (cursor where it was)")],
 "Order never changes: diagnostics, then signature, then docs, then where it is defined. The compact view holds at most one doc paragraph; K again focuses the same popover in place instead of opening a buffer, like Neovim's LSP hover. The mouse opens the compact view after a short dwell and never focuses it. Text arrives as BEAM-styled spans; neither frontend parses markdown."))

# ===== 2. hover on Minga lines and chrome
M_CODE=[(232,f'{kw("@spec")} workspace_agent_status({mod("Workspace")}.t()) :: {mod("AgentPresence")}.state()',"head"),
 (233,f'{kw("defp")} workspace_agent_status(ws) {kw("do")}',"body"),(234,f'  ws |&gt; payload() |&gt; {mod("AgentPresence")}.of()',"body"),(235,kw("end"),"last"),(236,"",""),
 (237,f'{kw("defp")} usage_limit(ws) {kw("do")}',""),(238,f'  ws |&gt; payload() |&gt; limit_label()',""),(239,kw("end"),"")]
rows="".join(mrow(n,t,m) for n,t,m in M_CODE)
arrow='<svg width="14" height="20" viewBox="0 0 14 20" style="position:absolute;left:216px;top:43px"><path d="M1 1 L1 15 L5 11 L8 18 L10 17 L7 10 L12 10 Z" fill="#fff" stroke="#000" stroke-width="1"/></svg>'
attrib=pop(psec(f'<div style="display:flex;align-items:center;gap:8px">{B.st("Working",13)}<span style="color:#b98cf0;font-weight:700">Minga</span><span style="color:#8f8d88">wrote these 4 lines · 4 min ago</span></div><div style="margin-top:5px;color:#c9c7c2">Task: Show the plan limit instead of “rate limited”</div><div style="margin-top:2px;color:#8f8d88">Change 1 of 2 · unreviewed</div>',border=False)
 +pfoot(("g.","keep, reject, diff"),("↩","conversation")),236,53,400)
ma=macwin(area(rows,attrib+arrow)+modeline(file="chrome_state.ex",right="Elixir",pos="233:4"),title="chrome_state.ex",path="lib/minga_editor/session",w=684,h=330)
def tip(text,left): return f'<div style="position:absolute;left:{left}px;bottom:30px;padding:5px 9px;background:#2a2b32;border:1px solid rgba(255,255,255,0.12);border-radius:6px;box-shadow:0 8px 20px rgba(0,0,0,0.5);font-size:12px;color:#dcdce2;white-space:nowrap">{text}</div>'
def strip(tipx,tiptext,hl):
    segs=[("needs",f'<span style="display:flex;align-items:center;gap:6px;color:#f2b544">{B.st("Needs you",12)}1 needs you</span>'),("file",'<span style="color:#ecebe8;font-weight:600">chrome_state.ex</span>'),("change",'<span style="color:#b98cf0">change 1/2</span>'),("minga",f'<span style="display:flex;align-items:center;gap:6px;color:#a5a39e">{B.st("Waiting",12)}Minga waiting</span>')]
    inner="".join(seg(h,"background:rgba(255,255,255,0.08);border-radius:5px;" if n==hl else "") for n,h in segs)
    return f'<div style="position:relative;width:684px;height:96px;border-radius:8px;overflow:visible;background:#1e1f24;border:1px solid #2e3038"><div style="position:absolute;left:0;right:0;bottom:0;height:26px;display:flex;align-items:center;background:#25262c;font-size:12px;color:#a5a39e;border-radius:0 0 8px 8px">{mode_pill()}{inner}</div>{tip(tiptext,tipx)}</div>'
s1=strip(70,f'1 task needs you · {mono("SPC a a","#c9c7c2")}',"needs")
s2=strip(250,f'change 1 of 2 from “Show the plan limit…” · {mono("]h","#c9c7c2")} next',"change")
s3=strip(330,f'{B.st("Waiting",12)} Waiting · rate limited, retry in 40 s',"minga").replace(B.st("Waiting",12)+" Waiting",'<span style="display:inline-flex;align-items:center;gap:6px">'+B.st("Waiting",12)+' Waiting</span>',1)
right=f'<div style="display:flex;flex-direction:column;gap:8px">{s1}{s2}{s3}</div>'
mac=f'<div style="display:flex;gap:24px">{labeled("Hover a Minga line","who wrote it, for which task, and whether it is settled",ma)}{labeled("Hover the modeline","each segment says what it means and the key that acts on it",right)}</div>'
g1=G.Grid(62,TH)
TM=[(232,"@spec workspace_agent_status(Workspace.t())","head"),(233,"defp workspace_agent_status(ws) do","body"),(234,"  ws |> payload() |> AgentPresence.of()","body"),(235,"end","body"),(236,"",""),(237,"defp usage_limit(ws) do",""),(238,"  ws |> payload() |> limit_label()",""),(239,"end","")]
for i,(n,t,m) in enumerate(TM): trow(g1,i,n,t,m,bg=("#25262d" if n==233 else None))
def f3(d):
    d.segs(1,2,[("◐ ",G.PURPLED),("Minga",G.PURPLE,None,"b"),(" wrote these 4 lines · 4m",G.DIM)])
    d.put(2,2,"Task: Show the plan limit instead of …",G.CODE)
    d.put(3,2,"Change 1 of 2 · unreviewed",G.DIM)
tpop(g1,2,12,5,46,[("K",G.SUB),("  Minga",G.PURPLE,"b")],[("g.",G.TXT),(" act  ",G.DIM),("↩",G.TXT),(" conversation",G.DIM)],f3)
g1.fill(TH-3,0,62,"#1b1c21"); g1.segs(TH-3,1,[("1 task needs you · ",G.TXT,"#1b1c21"),("SPC a a",G.PURPLE,"#1b1c21","b"),("   (mouse over the segment)",G.DIM,"#1b1c21")])
tmode(g1,TH-2,"NORMAL",[(" ◉ 1 ",G.AMBER,"#3a3120","b"),(" chrome_state.ex ",G.TXT,"#30313a","b"),(" change 1/2 ",G.PURPLE,"#2e2840"),(" ○ ",G.SUB,"#25262c")]," 233:4 ")
g1.c[TH-2][1][2]=g1.c[TH-2][1][2]
write("Batch7_hover_minga_and_chrome.dc.html",board("Batch 7: hover on Minga's lines and the modeline",("Hover beyond code","the same surface explains Minga's work and every piece of chrome"),mac,"",tterm(g1,"TUI","K on a Minga line; modeline hover writes to the echo row"),
 [("Minga line: K or dwell","minga.hover.attribution"),("attribution: g.","minga.act_menu (target: this change)"),("attribution: ↩","minga.conversation"),("modeline Needs you: click","minga.tasks.needs_you"),("modeline change 1/2: click","minga.review.in_file (jumps to the change)"),("modeline Minga: click","minga.conversation"),("any: move away or esc","edit.plain")],
 "Tooltips on chrome are one line: what it means, then the key. In the TUI there is no floating tooltip for chrome: when the terminal reports mouse motion, the text appears in the echo row, so nothing ever covers the code. State glyph tooltips always include the reason and time, never just the state word."))

# ===== 3. act menu on a Minga change
rows="".join(mrow(n,t,m,bg="rgba(164,99,230,0.06)" if m else "") for n,t,m in M_CODE)
items=[sep("This change"),item("y","Keep","SPC a y","accept 4 lines",sel=True),item("=","Show diff","SPC g d"),item("o","Open conversation","SPC a v"),item("n","Reject","SPC a d","removes 4 lines, restores 1"),
       sep("Anywhere"),item("l","Copy file:line link"),item("a","Ask Minga about this","SPC a ?")]
GLW=B.st("Waiting",13); META_CH=f'<span style="display:inline-flex;align-items:center;gap:5px">· 4 lines ·{B.st("Waiting",11)}unreviewed</span>'
DEC_CH=("decision",[("y","Keep","accept 4 lines","SPC a y",True),("n","Reject","removes 4 lines, restores 1","SPC a d",False)])
GR_CH=[("This change",[("=","Show diff"),("o","Open conversation","","SPC a v")]),("Anywhere",[("l","Copy file:line link"),("?","Ask Minga about this","","SPC a ?")])]
menu=menuA(GLW,"Minga's change 1 of 2",META_CH,"minga",DEC_CH,GR_CH,w=470,left=150,top_px=92)
m1=macwin(area(rows.replace('<span class="code">','<span class="code">',1),menu,h=366)+modeline(file="chrome_state.ex",right="Elixir",pos="232:1"),title="chrome_state.ex",path="lib/minga_editor/session",w=684,h=430)
items2=[item("o","Open conversation","SPC a v",sel=True),item("l","Copy file:line link")]
menu2=menuA(GLW,"Minga's change 1 of 2",META_CH,"minga",None,[("",[("o","Open conversation","","SPC a v",True),("l","Copy file:line link")])],w=470,left=150,top_px=92,filt="op")
m2=macwin(area(rows,menu2)+modeline(file="chrome_state.ex",right="Elixir",pos="232:1"),title="chrome_state.ex",path="lib/minga_editor/session",w=684,h=380)
mac=f'<div style="display:flex;gap:24px">{labeled("g. on a Minga change","the likely action is preselected; letters run an action; destructive last",m1)}{labeled("Typing filters","“op” leaves two actions; ↩ runs the highlighted one",m2)}</div>'
g1=G.Grid(62,TH)
for i,(n,t,m) in enumerate(TM): trow(g1,i,n,t,m)
tmenuA(g1,5,6,52,"minga",[("○ ",G.SUB),("Minga's change 1 of 2",G.TXT,"b"),(" · 4 lines",G.DIM)],DEC_CH,GR_CH)
tmode(g1,TH-2,"NORMAL",[(" chrome_state.ex ",G.TXT,"#30313a","b"),(" change 1/2 ",G.PURPLE,"#2e2840")]," 232:1 ")
write("Batch7_act_change.dc.html",board("Batch 7: the act menu on a Minga change",("g. (or ⌃. or right-click)","one menu for whatever is under the cursor; the BEAM decides what it offers"),mac,"",tterm(g1,"TUI","the same menu as a Lip Gloss layer at the cursor"),
 [("y / ↩ on Keep","minga.review.in_file (change kept; cursor to the next change)"),("=","minga.review.diff_inline"),("o","minga.conversation"),("n","minga.review.in_file (change rejected)"),("l","edit.plain (link copied, echo confirms)"),("?","minga.inline_ask"),("typing","minga.act_menu (filtered)"),("esc","edit.plain")],
 "Each row shows the letter that runs it inside the menu and, on the right, the key that runs it without the menu, so the menu teaches the direct keys. Consequences are written next to the action (“removes 4 lines, restores 1”). Destructive actions sit last in their group and are never preselected. The header always names the target, so you know what you are acting on."))

# ===== 4. act menu on other targets + right-click
def miniA(title,html,w=262,h=286):
    return f'<div style="width:{w}px"><div class="lab"><b>{title}</b></div><div style="position:relative;height:{h}px">{html}</div></div>'
FILE_A=lambda left=0,top=0,w=262: menuA("","retry.ex","· lib/minga_agent","neutral",("primary",("↩","Open","","")),[("This file",[("v","Open in split","","⌃V"),("r","Rename…"),("p","Copy path"),("a","Ask Minga about it","","SPC a ?"),("D","Delete…","to Trash")])],w=w,left=left,top_px=top,compact=True,foot=False)
c1=miniA("A diagnostic",menuA(B.st("Failed",13),"Error","· after_ms/2 undefined","failure",("primary",("f","Fix: call after_ms/1","edits 1 line","")),[("This diagnostic",[("m","Ask Minga to fix","","SPC a ?"),("c","Copy message"),("d","Open docs","","K K")]),("Anywhere",[("l","Copy file:line link")])],w=262,compact=True,foot=False))
c2=miniA("A file row in the tree",FILE_A())
c3=miniA("A task row in the drawer",menuA(B.st("Working",13),"Show the plan limit…","· working","minga",("primary",("↩","Open conversation","","")),[("This task",[("i","Inspect","","SPC a i"),("o","Show output"),("r","Retry"),("x","Stop","after this step","⌘.")])],w=262,compact=True,foot=False))
c4=miniA("A terminal command block",menuA(B.st("Failed",13),"mix test","· exit 2 · 2.3 s","failure",("primary",("f","Ask Minga to fix","output attached","")),[("This command",[("y","Copy output","","yic"),("r","Rerun"),("Q","Send to quickfix"),("c","Copy command")])],w=262,compact=True,foot=False))
PTR='<svg width="14" height="20" viewBox="0 0 14 20" style="position:absolute;left:46px;top:-2px"><path d="M1 1 L1 16 L5 12 L8 19 L10.5 18 L7.5 11 L13 11 Z" fill="#fff" stroke="#000" stroke-width="1"/></svg>'
ns=f'<div style="width:262px"><div class="lab"><b>Right-click</b> opens the same menu</div><div style="position:relative;height:286px">{PTR}{FILE_A(left=46,top=16,w=216)}</div><div style="margin-top:-60px;font-size:11.5px;color:#a5a39e;line-height:16px">Not a stock context menu: right-click opens this branded menu at the pointer, on macOS and in the TUI. Same actions, same order, from the same BEAM list.</div></div>'

mac=f'<div style="display:flex;gap:16px">{c1}{c2}{c3}{c4}{ns}</div>'
gt=G.Grid(62,TH)
tree=[("▾ lib/",G.SUB),("  ▾ minga_agent/",G.SUB),("      providers/",G.SUB),("      retry.ex",G.TXT),("      session.ex",G.CODE),("      usage_limit.ex",G.CODE),("  ▸ minga_editor/",G.SUB),("▸ test/",G.SUB)]
for i,(t,c) in enumerate(tree): gt.put(i,1,t,c)
gt.bgrow(3,0,30,"#3b3f4a"); gt.put(3,1,"      retry.ex",G.TXT,"#3b3f4a")
gt.put(3,17,"▲",G.TXT)
tmenuA(gt,4,16,36,"neutral",[("retry.ex",G.TXT,"b")],("primary",("↩","Open","","")),[("This file",[("v","Open in split","","⌃V"),("r","Rename…"),("p","Copy path"),("a","Ask Minga about it"),("D","Delete…","to Trash")])],cover_gutter=False)
gt.fill(TH-3,0,62,"#1b1c21"); gt.put(TH-3,1,"right mouse button at the row opens the same menu",G.DIM,"#1b1c21")
tmode(gt,TH-2,"NORMAL",[(" *tree* ",G.TXT,"#30313a","b")]," 4:1 ")
gb=G.Grid(62,TH)
blk=[("◆ │ ~/code/minga main › mix test",G.RED),("    1) test usage limit names the plan",G.RED),("       test/minga_agent/usage_limit_test.exs:25",G.FN),("    9 tests, 1 failure",G.RED),("",G.CODE),("● │ ~/code/minga main › mix compile",G.GREEN)]
for i,(t,c) in enumerate(blk): gb.put(i,1,t,c,"#2a1f24" if i<4 else None);
for i in range(4): gb.bgrow(i,0,62,"#2a1f24")
for i,(t,c) in enumerate(blk[:4]): gb.put(i,1,t,c,"#2a1f24")
tmenuA(gb,4,14,40,"failure",[("◆ ",G.RED),("mix test",G.TXT,"b"),(" · exit 2",G.DIM)],("primary",("f","Ask Minga to fix","output attached","")),[("This command",[("y","Copy output","","yic"),("r","Rerun"),("Q","Send to quickfix"),("c","Copy command")])],cover_gutter=False)
tmline(gb,TH-2,"NORMAL",[(" *terminal 1* ",G.TXT,"#30313a","b"),(" ◆ exit 2 ",G.RED,"#3a2328")]," zsh ")
write("Batch7_act_targets.dc.html",board("Batch 7: the act menu on other targets",("One menu, many targets","the same shape on a diagnostic, a file, a task and a command; right-click opens it too"),mac,"",tterms((gt,"TUI","right-click on a tree row"),(gb,"","g. on a command block")),
 [("diagnostic: f","edit.plain (fix applied)"),("diagnostic: m","minga.task.new (with the diagnostic attached)"),("file row: ↩","edit.plain"),("file row: v","windows.split"),("file row: r","edit.prompt (rename)"),("file row: D","edit.prompt (confirm delete)"),("task row: ↩","minga.conversation"),("task row: o","minga.task.output"),("task row: x","edit.prompt (confirm stop)"),("command block: f","minga.task.new"),("command block: Q","search.quickfix"),("any: esc","the surface it came from")],
 "The specific actions come first and the likely one is preselected: Fix on a diagnostic with one fix, Open on a file, Open conversation on a task, Ask Minga to fix on a failed command. Destructive actions (Delete, Stop, Reject) are last and ask to confirm."))

# ===== 5. act menu on a selection
S_CODE=[(229,f'{kw("defp")} chrome_state(ws) {kw("do")}',"you"),(230,'  %{status: workspace_agent_status(ws), limit: usage_limit(ws)}',"you"),(231,kw("end"),""),(232,"",""),
 (233,f'{kw("@spec")} workspace_agent_status({mod("Workspace")}.t()) :: {mod("AgentPresence")}.state()',"head"),(234,f'{kw("defp")} workspace_agent_status(ws) {kw("do")}',"last"),(235,"",""),
 (236,f'{kw("defp")} usage_limit(ws) {kw("do")}',"head"),(237,f'  ws |&gt; payload() |&gt; {mod("UsageLimit")}.of()',"last"),(238,kw("end"),"")]
SEL="rgba(26,149,242,0.20)"
rows="".join(mrow(n,t,m,bg=SEL if 229<=n<=237 else "") for n,t,m in S_CODE)
items=[sep("9 lines · 2 Minga changes · 2 of your lines"),item("y","Keep 2 changes","SPC a y","4 lines",sel=True),item("a","Ask Minga about the selection","SPC a ?"),item("e","Rewrite selection","SPC a e"),item("c","Comment","gc"),item("f","Format selection","="),item("l","Copy as file:line link"),item("n","Reject 2 changes","SPC a d","removes 4 lines")]
DEC_SEL=("decision",[("y","Keep 2 changes","4 lines","SPC a y",True),("n","Reject 2 changes","removes 4 lines","SPC a d",False)])
GR_SEL=[("This selection",[("a","Ask Minga about it","","SPC a ?"),("e","Rewrite selection","","SPC a e"),("c","Comment","","gc"),("f","Format selection","","SPC c f"),("l","Copy as file:line link")])]
menu=menuA("","Selection","· 229-237 · 2 Minga changes · 2 of your lines","minga",DEC_SEL,GR_SEL,w=440,left=300,top_px=84)
m1=macwin(area(rows,menu)+modeline(mode="NORMAL",file="chrome_state.ex",right="Elixir",pos="9 lines"),title="chrome_state.ex",path="lib/minga_editor/session",w=1392,h=480)
mac=labeled("g. with a Visual selection","actions apply to everything selected, and say how much",m1)
g1=G.Grid(70,TH)
TS=[(229,"defp chrome_state(ws) do","you"),(230,"  %{status: ..., limit: usage_limit(ws)}","you"),(231,"end",""),(232,"",""),(233,"@spec workspace_agent_status(...)","head"),(234,"defp workspace_agent_status(ws) do","body"),(235,"",""),(236,"defp usage_limit(ws) do","head"),(237,"  ws |> payload() |> UsageLimit.of()","body"),(238,"end","")]
for i,(n,t,m) in enumerate(TS): trow(g1,i,n,t,m,bg=("#363a44" if 229<=n<=237 else None))
tmenuA(g1,4,22,46,"minga",[("Selection",G.TXT,"b"),(" · 2 changes",G.DIM)],DEC_SEL,GR_SEL,cover_gutter=False)
tmode(g1,TH-2,"NORMAL",[(" chrome_state.ex ",G.TXT,"#30313a","b")]," 9 lines ")
write("Batch7_act_selection.dc.html",board("Batch 7: the act menu on a selection",("Act on all","Embark's act-all: one menu, every target in the selection, with counts"),mac,"",tterm(g1,"TUI","the same menu on a Visual selection"),
 [("y","minga.review.in_file (both changes kept)"),("a","minga.inline_ask (selection attached)"),("e","minga.inline_edit"),("c / f","edit.plain"),("l","edit.plain (link copied)"),("n","edit.prompt (confirm reject 2 changes)"),("esc","edit.visual (selection kept)")],
 "The header counts what the selection contains, so “Keep 2 changes” is never a surprise. Actions that only apply to Minga's lines say so in the count; your own lines are untouched by Keep and Reject. Esc keeps the selection so you can adjust it and act again."))

# ===== 6. picker: act on a match, act on all, export
PK=["lib/minga_agent/retry.ex","lib/minga_agent/retry_policy.ex","lib/minga_agent/providers/retry_after.ex","test/minga_agent/retry_test.exs","test/minga_agent/retry_policy_test.exs","lib/minga_editor/retry_notice.ex","docs/design/retry.md","lib/minga/lsp/retry.ex","test/minga/lsp/retry_test.exs","lib/minga_agent/tools/retry_tool.ex","bench/retry_bench.exs","test/support/retry_case.ex"]
def hl(p): return p.replace("retry",'<span style="color:#ecebe8;font-weight:700;text-decoration:underline;text-underline-offset:3px">retry</span>')
prow="".join(f'<div style="height:22px;display:flex;align-items:center;padding:0 14px;font-family:{MONO};font-size:12px;{"background:rgba(26,149,242,0.85);color:#fff;" if i==0 else "color:#a5a39e;"}">{hl(p) if i else p}</div>' for i,p in enumerate(PK[:6]))
pbody=f'<div style="height:28px;display:flex;align-items:center;gap:8px;padding:0 14px;border-bottom:1px solid rgba(255,255,255,0.06);font-family:{MONO};font-size:12.5px"><span style="color:#6cb8f5">Find file ›</span><span style="color:#ecebe8">retry</span>{CUR}<span style="flex:1"></span><span style="color:#7a7c85;font-family:-apple-system,system-ui;font-size:11.5px">12 of 1,204</span></div>{prow}'
pitems=[sep("retry.ex"),item("↩","Open","",sel=True),item("v","Open in split","⌃V"),item("p","Copy path"),sep("All 12 matches"),item("A","Open all 12 matches"),item("E","Export 12 to a buffer","","then select and act"),sep("Anywhere"),item("a","Ask Minga about these files")]
pmenu=menuA("","retry.ex","· match 1 of 12","neutral",("primary",("↩","Open","","")),[("This file",[("v","Open in split","","⌃V"),("p","Copy path")]),("All 12 matches",[("A","Open all 12"),("E","Export 12 to a buffer","then select and act")]),("Anywhere",[("a","Ask Minga about these files")])],w=360,left=300,top_px=-236,entry="⌃.  right-click")
pdr=drawer(("*find-file*","Find File"),'',f'{hint("⌃.","act")}{sp()}{hint("⌃V","split")}{sp()}{hint("esc","close")}',f'<div style="position:absolute;inset:0">{pbody}</div><div style="position:absolute;left:0;top:0">{pmenu}</div>',h=200)
m1=macwin(area(code(8,dim=True))+pdr+modeline(mode="INSERT",file="*find-file*",right=None,pos="12"),title="chrome_state.ex",path="lib/minga_editor/session",w=684,h=480)
m1=m1.replace('top:-232px','top:-232px')
FL=PK
frows="".join(f'<div class="ln" style="height:22px;background:{SEL if 2<=i<=4 else ""}"><span class="num" style="color:#7a7c85">{i+1}</span><span class="code" style="padding-left:14px">{p}</span></div>' for i,p in enumerate(FL[:10]))
fitems=[sep("3 files selected"),item("↩","Open 3 files","",sel=True),item("v","Open 3 in splits"),item("a","Ask Minga about 3 files","SPC a ?"),item("q","Send 3 to quickfix"),item("p","Copy 3 paths"),item("D","Delete 3 files…","","moves to Trash")]
fmenu=menuA("","Selection","· 3 of 12 in *file-list*","neutral",("primary",("↩","Open 3 files","","")),[("This selection",[("v","Open 3 in splits"),("a","Ask Minga about 3 files","","SPC a ?"),("Q","Send 3 to quickfix"),("p","Copy 3 paths"),("D","Delete 3 files…","to Trash")])],w=360,left=280,top_px=45)
m2=macwin(area(frows,fmenu)+modeline(file="*file-list*  retry · 12",right=None,pos="3 lines"),title="*file-list*",path="from Find File: retry",w=684,h=480)
mac=f'<div style="display:flex;gap:24px">{labeled("⌃. in the picker","Tab only completes; the act menu offers the row, all matches, or export",m1)}{labeled("Export 12, then V and g.","pick the subset with Vim, then act on it",m2)}</div>'
g1=G.Grid(62,TH)
tcode(g1,4,dim=True)
def fp(d):
    d.segs(1,2,[("Find file › ",G.BLUE),("retry",G.TXT),("▏",G.BLUE)]); d.put(1,d.w-15,"12 of 1,204",G.DIM)
    for i,p in enumerate(PK[:7]):
        if i==0: d.bgrow(2+i,1,d.w-2,"#3b3f4a"); d.put(2+i,1,"▌",G.BLUE,"#3b3f4a"); d.put(2+i,3,p,G.TXT,"#3b3f4a")
        else: d.put(2+i,3,p,G.CODE)
tpop(g1,4,0,11,62,[("*find-file*",G.SUB),("  Find File",G.TXT,"b")],[("⌃.",G.TXT),(" act  ",G.DIM),("⌃V",G.TXT),(" split  ",G.DIM),("esc",G.TXT),(" close",G.DIM)],fp)
tmenuA(g1,1,26,34,"neutral",[("retry.ex",G.TXT,"b")],("primary",("↩","Open","","")),[("",[("v","Open in split","","⌃V")]),("All 12",[("A","Open all 12"),("E","Export 12")])],cover_gutter=False)
tmode(g1,TH-2,"INSERT",[(" *find-file* ",G.TXT,"#30313a","b")]," 12 ")
g2=G.Grid(62,TH)
for i,p in enumerate(PK[:11]):
    bg="#363a44" if 2<=i<=4 else None
    if bg: g2.bgrow(i,0,62,bg)
    g2.put(i,0,f"{i+1:>4}  ",G.DIM,bg); g2.put(i,6,p,G.CODE,bg)
tmenuA(g2,6,22,38,"neutral",[("Selection",G.TXT,"b"),(" · 3 of 12",G.DIM)],("primary",("↩","Open 3 files","","")),[("This selection",[("a","Ask Minga about 3"),("Q","Send 3 to quickfix"),("p","Copy 3 paths"),("D","Delete 3 files…")])],cover_gutter=False)
tmode(g2,TH-2,"NORMAL",[(" *file-list* ",G.TXT,"#30313a","b"),(" retry · 12 ",G.SUB,"#25262c")]," 3 lines ")
write("Batch7_act_picker.dc.html",board("Batch 7: acting from the picker",("Pickers act, then export","no marking: act on one row, on all matches, or export and use Vim to choose"),mac,"",tterms((g1,"TUI","⌃. on the highlighted row"),(g2,"","*file-list* with V on 3 rows, then g.")),
 [("picker: ⌃. or right-click","minga.act_menu (target: highlighted row)"),("menu: ↩ Open","edit.plain"),("menu: A","edit.plain (12 files opened, the last one shown)"),("menu: E","files.file_list"),("menu: esc","files.switcher (query kept)"),("*file-list*: V then g.","minga.act_menu (target: 3 rows)"),("*file-list*: ↩ on a row","edit.plain"),("*file-list*: q","edit.plain"),("selection menu: Q","search.quickfix")],
 "Tab never marks: it completes. ⌃. opens the act menu because typing owns SPC in the picker. Bulk work has two doors: “Open all 12 matches” for when the filter already says everything, and “Export” for when you want to choose with Vim selection in a real buffer. The exported *file-list* is a special buffer like quickfix: it can be saved, split and searched."))
