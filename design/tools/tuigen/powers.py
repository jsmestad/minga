import sys; sys.path.insert(0,'.')
from grid import *
W=78
def frame(label,sub,inner,tabs=None,notif=None,width=None):
    tabhtml=""
    if tabs:
        tabhtml='<div style="display:flex;gap:2px;background:#202127;padding:4px 8px 0">'+"".join(tabs)+'</div>'
    return f"""<div style="position:relative">
<div style="font-size:12px;color:#a5a39e;margin:0 0 5px"><span style="color:#e6e4df;font-weight:600">{label}</span>  {sub}</div>
<div style="border-radius:9px;overflow:hidden;border:1px solid #2e3038;box-shadow:0 8px 24px rgba(0,0,0,0.4);background:{BG}">
<div style="height:20px;background:#2a2b31;display:flex;align-items:center;gap:6px;padding:0 9px"><span style="width:9px;height:9px;border-radius:5px;background:#ff5f57"></span><span style="width:9px;height:9px;border-radius:5px;background:#febc2e"></span><span style="width:9px;height:9px;border-radius:5px;background:#28c840"></span></div>
{tabhtml}<div style="padding:2px 0">{inner}</div></div>{notif or ""}</div>"""
def tab(title,active=False,progress=None,dot=None):
    bar=""
    if progress is not None:
        bar=f'<div style="position:absolute;left:0;bottom:0;height:2px;width:{progress}%;background:#a463e6;border-radius:1px"></div>'
    d=f'<span style="color:{dot}">● </span>' if dot else ""
    return f'<div style="position:relative;padding:4px 12px 6px;font-size:11px;border-radius:6px 6px 0 0;background:{"#1e1f24" if active else "transparent"};color:{"#e6e4df" if active else "#7a7c85"}">{d}{title}{bar}</div>'
def ml(g,r,w,parts,right=None,bgc="#25262c"):
    g.fill(r,0,w,bgc); g.segs(r,0,parts)
    if right: g.segs(r,w-sum(len(p[0]) for p in right)-1,right)

# (1) notifications, tab title, tab progress
g1=Grid(W,7)
for i,(n,t) in enumerate([(231,"# Status comes from one owner."),(232,"@spec workspace_agent_status(...)"),(233,"defp workspace_agent_status(ws) do"),(234,"  ws |> payload() |> AgentPresence.of()"),(235,"end")]):
    g1.put(i,0,f"{n:>5} ",FAINT); g1.put(i,9,t,CODE)
g1.put(1,7,"╳",PURPLED); g1.put(2,7,"┃",PURPLED); g1.put(3,7,"┃",PURPLED)
ml(g1,6,W,[(" NORMAL ","#12304a",BLUE,"b"),(" ",None),(" ◉ Needs you ",AMBER,"#3a3120","b"),(" ",None),(" ◐ Minga 2/3 ",PURPLE,"#25262c")],[(" 234:7 ",TXT,"#30313a")])
notif='''<div style="position:absolute;right:10px;top:64px;width:290px;background:rgba(48,49,56,0.97);border:1px solid rgba(255,255,255,0.12);border-radius:12px;padding:10px 12px;box-shadow:0 12px 30px rgba(0,0,0,0.55);font-size:11.5px;line-height:15px;color:#e6e4df;display:flex;gap:10px">
<div style="width:30px;height:30px;border-radius:7px;background:#14151a;display:flex;align-items:center;justify-content:center;font:11px Menlo;color:#a5a39e;flex:none">&gt;_</div>
<div><div style="font-weight:600">Minga needs you</div><div style="color:#c9c7c2">Add tests for the usage-limit classifier wants to create usage_limit_test.exs</div><div style="color:#7a7c85;font-size:10.5px;margin-top:3px">from the terminal · OSC 777 notify (OSC 9 fallback)</div></div></div>'''
f1=frame("1  Needs you, from inside the terminal","tab title, tab progress, desktop notification",g1.html("tg small"),
         tabs=[tab("Minga needs you · minga",True,progress=66,dot=AMBER),tab("zsh"),tab("logs")],notif=notif)

# (2) kitty keyboard protocol
g2=Grid(W,10)
g2.put(0,1,"Key events with the Kitty keyboard protocol",SUB,None,"b")
rows=[("⌘.","Stop Minga","super passes through"),("⌘1","Jump to pinned file 1","super passes through"),("Tab","Indent / complete","distinct from ⌃I"),("⌃I","Jump forward in jump list","distinct from Tab"),("Esc","Leave insert at once","no 25 ms wait for a sequence")]
g2.put(1,1,"┌"+"─"*8+"┬"+"─"*30+"┬"+"─"*34+"┐","#5a5d66")
for i,(k,a,n) in enumerate(rows):
    r=2+i
    g2.segs(r,1,[("│ ","#5a5d66"),(f"{k:<7}",PURPLE,None,"b"),("│ ","#5a5d66"),(f"{a:<29}",TXT),("│ ","#5a5d66"),(f"{n:<33}",DIM),("│","#5a5d66")])
g2.put(7,1,"└"+"─"*8+"┴"+"─"*30+"┴"+"─"*34+"┘","#5a5d66")
g2.put(8,1,"   works in Kitty, Ghostty and WezTerm; elsewhere ⌘ keys fall back to SPC",FAINT,None,"i")
f2=frame("2  Every key arrives as you pressed it","Bubble Tea v2 keyboard enhancements",g2.html("tg small"))

# (3) focus reporting
def mini(focused):
    m=Grid(37,7)
    for i,(n,t) in enumerate([(240,"  ws |> payload()"),(241,"end"),(242,""),(243,"def agent_label(_)")]):
        m.put(i,0,f"{n:>4} ",FAINT if focused else GHOST); m.put(i,6,t,CODE if focused else DIM)
    if focused: m.put(0,23," ",BG,BLUE)
    else: m.put(0,23," ",BLUE,None,"hc")
    bc=FOCUS if focused else "#5a5d66"
    m.box(4,0,3,37,bc,SURF,title=[("Minga Tasks",TXT if focused else DIM,"b")])
    m.put(5,2,"◉ Needs you · 1 task",AMBER if focused else "#8a7344")
    return m.html("tg small")
f3=frame("3  The terminal knows when you look away","tea.FocusMsg / tea.BlurMsg",
   '<div style="display:flex;gap:0"><div style="border-right:1px solid #2e3038">'+mini(True)+'</div><div>'+mini(False)+'</div></div>'+
   '<div style="display:flex;font-size:10.5px;color:#7a7c85;padding:3px 8px 4px"><span style="flex:1">focused: accent borders, solid cursor</span><span style="flex:1;padding-left:16px">unfocused: dim borders, hollow cursor, needs-you escalates to a notification</span></div>')

# (4) light and dark
def themed(dark):
    pal=dict(bg=BG,surf=SURF,txt=CODE,num=FAINT,kw=KW,fn=FN,str=STR,purple=PURPLED,amber=AMBER,blue=BLUE,ml="#25262c",mlt=TXT,modebg=BLUE,modefg="#12304a",chip="#3a3120",shade="#4a2c75") if dark else \
        dict(bg="#fbfaf7",surf="#f1efe9",txt="#2b2b30",num="#a3a19b",kw="#c2306b",fn="#2a6fb5",str="#4f7a2a",purple="#7b3fc9",amber="#9a6400",blue="#1f6fbf",ml="#ebe8e1",mlt="#2b2b30",modebg="#1f6fbf",modefg="#ffffff",chip="#f5e6c4",shade="#d9c6f2")
    m=Grid(37,6,bg=pal["bg"],fg=pal["txt"])
    L=[(232,[("@spec ",pal["kw"]),("status",pal["fn"]),("(ws)",pal["txt"])],True),(233,[("defp ",pal["kw"]),("status",pal["fn"]),("(ws) ",pal["txt"]),("do",pal["kw"])],False),(234,[("  ",pal["txt"]),('"Needs you"',pal["str"])],False),(235,[("end",pal["kw"])],None)]
    for i,(n,parts,head) in enumerate(L):
        m.put(i,0,f"{n:>4} ",pal["num"])
        if head is not None:
            m.put(i,5,"▚" if head else "▐",pal["purple"],pal["shade"])
        x=7
        for p in parts: x=m.put(i,x,p[0],p[1])
    m.fill(5,0,37,pal["ml"])
    m.segs(5,0,[(" NORMAL ",pal["modefg"],pal["modebg"],"b"),(" ",None,pal["ml"]),(" ◉ Needs you ",pal["amber"],pal["chip"],"b"),(" ",None,pal["ml"]),("◐ Minga",pal["purple"],pal["ml"])])
    return m
f4=frame("4  Light and dark terminals","lipgloss.LightDark pairs, chosen from tea.BackgroundColorMsg",
   '<div style="display:flex"><div>'+themed(True).html("tg small")+'</div><div style="border-left:1px solid #2e3038">'+themed(False).html("tg small")+'</div></div>')

# (5) capability report
g5=Grid(W*2+3,15,bg=SURF)
g5.box(0,0,15,W*2+3,FOCUS,SURF,title=[("*minga-health*",SUB),("  Terminal",TXT,"b")],right=[("this terminal · 220 × 60",DIM)],
       bottom=[(":checkhealth terminal",TXT),("   re-run after changing terminals",DIM)])
feat=[("24-bit colour","truecolor",True,"256 then 16 colours via colorprofile"),
      ("Curly and dotted underlines","SGR 4:3, 4:4",True,"plain underline"),
      ("Underline colour","SGR 58",True,"underline in text colour"),
      ("Hyperlinks","OSC 8",True,"plain text paths, gf still opens them"),
      ("Kitty keyboard protocol","CSI u",True,"⌘ keys map to SPC equivalents"),
      ("Desktop notifications","OSC 9 / OSC 777",True,"bell and tab title only"),
      ("Tab progress","OSC 9;4",True,"progress in the modeline only"),
      ("Exact twist in the gutter","Kitty graphics",False,"two-tone ▚ ▐ cells (in use)"),
      ("Synchronized output","mode 2026",True,"frames may tear on fast scroll"),
      ("Focus reporting","mode 1004",True,"no unfocused dimming"),
      ("Clipboard","OSC 52",True,"system clipboard via pbcopy")]
g5.segs(1,3,[("Feature".ljust(33),DIM,None,"b"),("Protocol".ljust(18),DIM,None,"b"),("Status".ljust(10),DIM,None,"b"),("If missing, Minga uses",DIM,None,"b")])
for i,(f,proto,ok,fb) in enumerate(feat):
    r=2+i
    g5.segs(r,3,[(("● " if ok else "○ "),GREEN if ok else SAND),(f.ljust(31),TXT),(proto.ljust(18),SUB),(("yes" if ok else "fallback").ljust(10),GREEN if ok else SAND),(fb,DIM if ok else SAND)])
f5=frame("5  :checkhealth terminal","what this terminal can do, and what Minga falls back to",g5.html("tg small"))

body=f'''<div style="display:flex;flex-direction:column;gap:16px;width:1130px">
<div style="display:flex;gap:18px;align-items:flex-start"><div style="width:556px">{f1}</div><div style="width:556px">{f2}</div></div>
<div style="display:flex;gap:18px;align-items:flex-start"><div style="width:556px">{f3}</div><div style="width:556px">{f4}</div></div>
<div>{f5}</div></div>'''
annot="""<h4>Terminal powers</h4>
<div class="it">Bubble Tea v2 and Lip Gloss v2 can do more than draw cells. Each power is detected at startup, listed in <code>:checkhealth terminal</code>, and degrades quietly.</div>
<div class="it"><span class="k">1</span> the window title (OSC 2, set from the Bubble Tea view) reads "● Minga needs you"; OSC 9;4 draws progress in the tab while Minga works; OSC 777 (or OSC 9) raises a desktop notification only for needs-you.</div>
<div class="it"><span class="k">2</span> Bubble Tea v2 keyboard enhancements enable the Kitty protocol: ⌘ passes through, Tab and ⌃I differ, Esc is instant.</div>
<div class="it"><span class="k">3</span> <code>tea.FocusMsg</code> and <code>tea.BlurMsg</code>: dim borders and a hollow cursor when the terminal loses focus.</div>
<div class="it"><span class="k">4</span> every colour role is a <code>lipgloss.LightDark</code> pair; <code>tea.BackgroundColorMsg</code> picks the side.</div>
<div class="it"><span class="k">5</span> a normal buffer built with <code>lipgloss/table</code>. A missing feature is a fallback, never an error.</div>"""
open(os.path.join(OUT_DIR,"V41TuiTerminalPowers.dc.html"),"w").write(page("TUI: terminal powers",body,annot))
