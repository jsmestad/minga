import os as _os
TOOLS = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))
BOARDS = _os.environ.get("BOARDS_DIR", _os.path.join(TOOLS, "..", "boards"))  # committed boards, read only
OUT_DIR = _os.environ.get("OUT_DIR", _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "out"))
_os.makedirs(OUT_DIR, exist_ok=True)
import os
S = TOOLS
os.environ.setdefault("OUT_DIR",S+"/mouse/out")
src=open(S+"/batch1/b1.py").read()
exec(src[:src.index("# ===== 1.")])
OUT=os.environ["OUT_DIR"]; os.makedirs(OUT,exist_ok=True)
SURF="#23242a"; HOV="rgba(108,184,245,0.16)"
def pill_hover():
    return '<span style="display:flex;align-items:center;padding:0 10px;margin:0 4px 0 6px;height:18px;border-radius:9px;background:rgba(26,149,242,0.42);color:#ecebe8;font-weight:700;font-size:10.5px;letter-spacing:0.04em;box-shadow:0 0 0 1px #6cb8f5">NORMAL</span>'
def ml(parts,pill=None,right='<span style="font-family:ui-monospace,monospace;font-size:11.5px">240:31</span>'):
    return f'<div style="height:26px;flex:none;display:flex;align-items:center;background:#25262c;border-top:1px solid rgba(255,255,255,0.07);font-size:12px;color:#a5a39e;position:relative">{pill or mode_pill()}{"".join(parts)}<span style="flex:1"></span>{seg(right,"padding-right:14px")}</div>'
def tip(text,left,bottom=34):
    return f'<div style="position:absolute;left:{left}px;bottom:{bottom}px;background:#3a3c45;color:#ecebe8;font-size:11.5px;padding:4px 8px;border-radius:5px;box-shadow:0 4px 12px rgba(0,0,0,0.4);white-space:nowrap;z-index:5">{text}</div>'
def chip(key,label,primary=False):
    bg="#1a95f2" if primary else "rgba(255,255,255,0.09)"; fg="#ffffff" if primary else "#dcdce2"
    return f'<span style="display:inline-flex;align-items:center;gap:6px;height:20px;padding:0 9px;border-radius:5px;background:{bg};color:{fg};font-size:12px;margin-left:6px"><span style="font-family:ui-monospace,monospace;opacity:0.8">{key}</span>{label}</span>'
GRP="#a9b1f0"  # which-key group role (astrodark source; re-themes to Frappé lavender)
def wk_panel(crumb,cols,hover=None,h=150):
    colhtml=""
    for head,rows in cols:
        rr=""
        for row in rows:
            key,lab,extra=row[:3]; grp=len(row)>3 and row[3]
            if grp: lab=f'<span style="color:{GRP}">{lab} ›</span>'
            bg=f"background:{HOV};border-radius:4px;" if hover==(head,key) else ""
            ex=f'<span style="color:{extra[1]};margin-left:6px">{extra[0]}</span>' if extra else ""
            rr+=f'<div style="height:21px;display:flex;align-items:center;gap:9px;padding:0 6px;{bg}"><span style="font-family:ui-monospace,monospace;font-weight:700;color:#b98cf0;width:22px">{key}</span><span style="color:#dcdce2">{lab}</span>{ex}</div>'
        colhtml+=f'<div style="min-width:210px"><div style="font-size:11px;color:#7a7c85;font-weight:600;margin:0 0 3px 6px">{head}</div>{rr}</div>'
    return f'''<div style="flex:none;height:{h}px;background:{SURF};border-top:1px solid rgba(255,255,255,0.12);box-shadow:0 -8px 20px rgba(0,0,0,0.35);display:flex;flex-direction:column">
<div style="height:28px;flex:none;display:flex;align-items:center;gap:8px;padding:0 14px;font-size:12px;border-bottom:1px solid rgba(255,255,255,0.05)">{crumb}<span style="flex:1"></span>{hint("⌫","back")}<span style="width:10px"></span>{hint("esc","close")}</div>
<div style="flex:1;display:flex;gap:28px;padding:8px 10px;font-size:12.5px">{colhtml}</div></div>'''
def crumb(*parts):
    out=[]
    for i,p in enumerate(parts):
        u="text-decoration:underline;text-underline-offset:3px;" if i<len(parts)-1 else "font-weight:700;"
        out.append(f'<span style="color:{"#a5a39e" if i<len(parts)-1 else "#ecebe8"};{u}">{p}</span>')
    return '<span style="color:#55575f"> › </span>'.join(out)
def tml(g,r,parts,pill_bg=None,right=" 240:31 "):
    g.fill(r,0,g.w,"#25262c")
    x=g.segs(r,0,[(" NORMAL ","#12304a",pill_bg or G.BLUE,"b"),(" ",None,"#25262c")])
    for p in parts: x=g.segs(r,x,[p,(" ",None,"#25262c")])
    g.segs(r,g.w-len(right),[(right,G.TXT,"#30313a")])
def note(lines): return '<div class="ex" style="width:330px;flex:none">'+"".join(f'<div style="margin-bottom:6px">{l}</div>' for l in lines)+'</div>'

# ===== 1. mode pill opens which-key
cols=[("Groups",[("a","Minga",("· 1 needs you","#f2b544"),True),("s","Search",None,True),("c","Code",("· 1 error","#e5707a"),True),("g","Git",("· 11 changed","#8f8d88"),True)]),
      ("",[("f","Files",None,True),("b","Buffers",None,True),("w","Windows",None,True),("o","Open",None,True)]),
      ("",[("h","Help",None,True),("t","Toggles",None,True),("q","Quit and session",None,True),(":","Commands",None)]),
      ("Often",[("SPC","Find file",None),(",","Switch buffer",None),("/","Search project",None)])]
wk=wk_panel(crumb("SPC"),cols,hover=("Groups","s"),h=150)
modl=ml([seg('<span style="color:#ecebe8;font-weight:600">chrome_state.ex</span>'),seg('<span style="color:#8f8d88">main +11</span>')],pill=pill_hover())
inner=f'<div style="flex:1;min-height:0;display:flex;flex-direction:column;position:relative">{editor_area(code(5,dim=True))}{wk}{modl}</div>'
mac=f'<div style="display:flex;gap:22px;align-items:flex-start">{macwin(inner,w=1010,h=320)}{note(["<b style=\'color:#e6e4df\'>One door for the mouse.</b> Clicking the mode pill is the same as pressing SPC and pausing. On hover the pill brightens and its tooltip reads Commands (SPC).","Group rows drill in (s Search shows the search group); command rows run; the breadcrumb goes back up; click outside or esc closes.","Every row still shows its key, so clicking teaches the keyboard."])}</div>'
g=G.Grid(TW,TH); tcode(g,11,dim=True)
wkg=G.Grid(TW,7,bg=SURF); wkg.box(0,0,7,TW,G.BORDER,SURF,title=[("SPC",G.TXT,"b")],bottom=[("⌫",G.TXT),(" back  ",G.DIM),("esc",G.TXT),(" close",G.DIM)])
items=[(1,3,"a","Minga ›","· 1 needs you",G.AMBER),(2,3,"s","Search ›","",None),(3,3,"c","Code ›","· 1 error",G.RED),(4,3,"g","Git ›","· 11 changed",G.DIM),
       (1,36,"f","Files ›","",None),(2,36,"b","Buffers ›","",None),(3,36,"w","Windows ›","",None),(4,36,"o","Open ›","",None),
       (1,66,"h","Help ›","",None),(2,66,"t","Toggles ›","",None),(3,66,"q","Quit and session ›","",None),(4,66,":","Commands","",None),
       (1,96,"SPC","Find file","",None),(2,96,",","Switch buffer","",None),(3,96,"/","Search project","",None)]
wkg.bgrow(2,2,30,"#2c3a4a")
for r,c,k_,lab,ex,col in items:
    bg="#2c3a4a" if (r,c)==(2,3) else None
    x=wkg.segs(r,c,[(k_,G.PURPLE,bg,"b"),("  "+lab,GRP if lab.endswith("›") else G.TXT,bg)])
    if ex: wkg.put(r,x+1,ex,col,bg)
for y in range(7):
    for x in range(TW): g.c[11+y][x]=list(wkg.c[y][x])
tml(g,18,[(" chrome_state.ex ",G.TXT,"#30313a","b"),(" main +11 ",G.DIM,"#25262c")],pill_bg="#4f9fe0")
g.fill(19,0,TW,"#1b1c21"); g.segs(19,1,[("Commands (SPC)",G.DIM,"#1b1c21"),("   hovering s Search · click to open the group",G.FAINT,"#1b1c21")])
write("Mouse_ModePill.dc.html",board("Mouse: the mode pill opens which-key",("Click the mode pill","the mouse's front door to every SPC group (hover shown on the pill and on s Search)"),mac,"",tterm(g,"TUI","same panel; hover highlights the row and names it in the echo area"),
 [("click mode pill","edit.whichkey.leader"),("click a group row","that group's which-key"),("click a command row","runs it, e.g. s › p → search.project"),("click the breadcrumb","back up one level"),("click outside / esc","edit.plain")],
 "Closes 41 of the 68 gaps: every surface that was only reachable through SPC. The TUI turns on motion tracking only while the panel is open, so hover costs nothing elsewhere."))

# ===== 2. macOS menu bar mirrors SPC
mb_items=["Minga","File","Edit","View","Search","Code","Git","Window","Help"]
bar=''.join(f'<span style="padding:0 9px;height:24px;display:flex;align-items:center;border-radius:4px;{"background:#3a6fd8;color:#fff;" if i==0 else ""}{"font-weight:700;" if i==0 else ""}">{n}</span>' for i,n in enumerate(mb_items))
def mi(label="",seq="",cmd="",sep=False,sel=False):
    if sep: return '<div style="height:1px;background:rgba(255,255,255,0.12);margin:4px 8px"></div>'
    bg="background:#3a6fd8;color:#fff;border-radius:4px;" if sel else ""
    return f'<div style="height:22px;display:flex;align-items:center;padding:0 10px;margin:0 4px;{bg}"><span>{label}</span><span style="color:{"#dbe6ff" if sel else "#7a7c85"};margin-left:8px;font-family:ui-monospace,monospace;font-size:11px">{seq}</span><span style="flex:1"></span><span style="color:{"#fff" if sel else "#a5a39e"};font-size:12px">{cmd}</span></div>'
menu=''.join([mi("Tasks","SPC a a"),mi("New Task…","SPC a n","⌘N"),mi("Conversation","SPC a v",sel=True),mi("Review Changes","SPC a r"),mi("Inspect Task","SPC a i"),mi("Watch Minga","SPC a w"),mi(sep=True),mi("Keep Change","SPC a y"),mi("Reject Change","SPC a d"),mi("Reject All…","SPC a u"),mi("Publish Edits…","SPC a p"),mi(sep=True),mi("Queue","SPC a q","›"),mi("Context","SPC a x","›"),mi("Session","SPC a S","›"),mi(sep=True),mi("Stop","SPC a s","⌘."),mi(sep=True),mi("Settings…","","⌘,"),mi("Quit Minga","SPC q q","⌘Q")])
screen=f'''<div style="width:1010px;height:430px;flex:none;border-radius:10px;overflow:hidden;border:1px solid #2e3038;background:#1a1b20;position:relative;font-family:-apple-system,system-ui,sans-serif;font-size:13px;color:#ecebe8">
<div style="height:26px;display:flex;align-items:center;gap:2px;padding:0 10px;background:rgba(40,41,48,0.96);border-bottom:1px solid rgba(255,255,255,0.08)"><span style="width:18px"></span>{bar}</div>
<div style="position:absolute;left:28px;top:30px;right:28px;bottom:10px;opacity:0.55">{macwin(editor_area(code(8,dim=True))+modeline(right=None),w=950,h=380)}</div>
<div style="position:absolute;left:26px;top:27px;width:300px;padding:4px 0;background:rgba(48,50,58,0.98);border:1px solid rgba(255,255,255,0.12);border-radius:7px;box-shadow:0 12px 30px rgba(0,0,0,0.5)">{menu}</div></div>'''
mac=f'<div style="display:flex;gap:22px;align-items:flex-start">{screen}{note(["<b style=\'color:#e6e4df\'>The menu bar mirrors SPC.</b> Minga, File, Edit, View, Search, Code, Git, Window and Help follow the leader groups.","Native menus cannot draw a key sequence in the shortcut column, so the leader sequence sits dimmed in the title; a ⌘ shortcut shows where one exists.","Free with it: Help-menu search, VoiceOver, and custom shortcuts in System Settings."])}</div>'
g=G.Grid(TW,TH); tcode(g,12,dim=True)
wkg=G.Grid(TW,6,bg=SURF); wkg.box(0,0,6,TW,G.BORDER,SURF,title=[("SPC",G.DIM),(" › ",G.FAINT),("a",G.PURPLE,"b"),("  Minga",G.TXT,"b")],bottom=[("⌫",G.TXT),(" back  ",G.DIM),("esc",G.TXT),(" close",G.DIM)])
it=[(1,3,"a","Tasks · 1 needs you"),(2,3,"n","New task…"),(3,3,"v","Conversation"),(4,3,"r","Review · 3"),(1,36,"i","Inspect a task"),(2,36,"w","Watch Minga"),(3,36,"s","Stop"),(4,36,"u","Reject all…"),(1,66,"y","Keep change"),(2,66,"d","Reject change"),(3,66,"p","Publish edits…"),(4,66,"?","Ask about this"),(1,96,"q","Queue ›"),(2,96,"x","Context ›"),(3,96,"S","Session ›")]
wkg.bgrow(3,2,30,"#2c3a4a")
for r,c,k_,lab in it:
    bg="#2c3a4a" if (r,c)==(3,3) else None
    wkg.segs(r,c,[(k_,G.PURPLE,bg,"b"),("  "+lab,GRP if lab.endswith("›") else G.TXT,bg)])
for y in range(6):
    for x in range(TW): g.c[12+y][x]=list(wkg.c[y][x])
tml(g,18,[(" chrome_state.ex ",G.TXT,"#30313a","b")]); g.fill(19,0,TW,"#1b1c21"); g.segs(19,1,[("No menu bar in a terminal: the mode pill and which-key are the mouse path.",G.DIM,"#1b1c21")])
write("Mouse_MenuBar.dc.html",board("Mouse: the menu bar mirrors SPC",("macOS menu bar","Minga menu open, mirroring SPC a"),mac,"",tterm(g,"TUI","no menu bar: mode pill › a Minga is the same list"),
 [("Minga › Conversation","minga.conversation"),("Minga › Review Changes","minga.review.buffer"),("Minga › Quit Minga (⌘Q)","start.quit.confirm when something is at stake"),("TUI: mode pill › a › v","minga.conversation")],
 "A second mouse path on macOS for the same 41 gaps, and the native home for ⌘ shortcuts. The menu items and which-key rows come from the same keymap scopes, so they cannot disagree."))

# ===== 3. right-click opens the act menu (Direction A, shared helpers in actbrand/dira.py)
MONO="ui-monospace,'SF Mono',Menlo,monospace"
CUR='<span style="display:inline-block;width:8px;height:16px;vertical-align:-3px;background:#6cb8f5;opacity:0.85"></span>'
def blit(g,d,r,c): g.blit(d,r,c)
exec(open(S+"/actbrand/dira.py").read())
META_CH=f'<span style="display:inline-flex;align-items:center;gap:5px">· 4 lines ·{B.st("Waiting",11)}unreviewed</span>'
DEC_CH=("decision",[("y","Keep","accept 4 lines","SPC a y",True),("n","Reject","removes 4 lines, restores 1","SPC a d",False)])
GR_CM=[("This change",[("=","Show diff"),("o","Open conversation","","SPC a v")]),
       ("The symbol",[("g","Go to definition","","SPC c d"),("r","Find references","","SPC c D"),("R","Rename symbol…","","SPC c r")]),
       ("Anywhere",[("l","Copy file:line link"),("?","Ask Minga about this","","SPC a ?")])]
menu=menuA(B.st("Waiting",13),"Minga's change 1 of 2",META_CH,"minga",DEC_CH,GR_CM,w=470,left=330,top_px=44)
cur='<svg width="14" height="20" viewBox="0 0 14 20" style="position:absolute;left:322px;top:30px;z-index:5"><path d="M1 1 L1 16 L5 12 L8 19 L10.5 18 L7.5 11 L13 11 Z" fill="#fff" stroke="#000" stroke-width="1"/></svg>'
inner=f'<div style="flex:1;min-height:0;display:flex;flex-direction:column;position:relative">{editor_area(code(14,minga="unreviewed"))}{menu}{cur}{modeline(minga=seg(B.st("Working",12)+chr(32)+"<span style=\'color:#b98cf0\'>Minga here 2/3</span>"),right=None)}</div>'
mac=f'<div style="display:flex;gap:22px;align-items:flex-start">{macwin(inner,w=1010,h=480)}{note(["<b style=\'color:#e6e4df\'>One act menu.</b> Right click opens the same menu as g. (Normal mode) and ⌃. (prompts and Insert): the decision first, then grouped actions.","<b style=\'color:#e6e4df\'>Not a stock context menu.</b> The BEAM builds the list for what is under the pointer: the change first, then the symbol, then anything.","<b style=\'color:#e6e4df\'>Keys teach themselves.</b> Each row shows its in-menu letter and, on the right, the key that skips the menu."])}</div>'
g=G.Grid(TW,TH); tcode(g,15,minga="unreviewed",dim=False)
tmenuA(g,2,36,54,"minga",[("○ ",G.SUB),("Minga's change 1 of 2",G.TXT,"b"),(" · 4 lines",G.DIM)],DEC_CH,GR_CM,cover_gutter=False)
tml(g,18,[(" chrome_state.ex ",G.TXT,"#30313a","b"),(" change 1/2 ",G.PURPLE,"#2e2840"),(" ◐ Minga here 2/3 ",G.PURPLE,"#25262c")])
g.fill(19,0,TW,"#1b1c21"); g.segs(19,1,[("Right click reaches Minga while mouse reporting is on; hold the terminal's bypass modifier for native selection.",G.DIM,"#1b1c21")])
write("Mouse_ActMenu.dc.html",board("Mouse: right click opens the act menu",("Right click = the act menu (also g. and ⌃.)","on a Minga change (lines 234 to 237)"),mac,"",tterm(g,"TUI","the same act menu as a Lip Gloss layer at the pointer or cursor; esc or click outside closes"),
 [("y Keep / n Reject","edit.working (change decided)"),("r Find references","code.references (or code.references.none)"),("R Rename symbol…","code.rename"),("g Go to definition","code.definition"),("selection › Rewrite with Minga","minga.inline_edit"),("click outside / esc","edit.working")],
 "Closes 10 gaps. Right click is not a separate context menu: it opens the act menu with the mouse. Precedent: Emacs 28 context-menu-mode, embark-act in Doom, native Mac context menus."))

# ===== 4. modeline segments, prompt chips, drawer buttons
parts=[seg(f'<span style="color:#f2b544">{B.st("Needs you",12)} 1</span>'),seg('<span style="color:#ecebe8;font-weight:600">chrome_state.ex</span>'),seg('<span style="color:#b98cf0">change 1/2</span>'),
       seg('<span style="color:#ecebe8">main +11</span>',f"background:{HOV};border-radius:4px;"),seg(B.st("Working",12)+'<span style="color:#b98cf0">Minga here 2/3</span>'),seg('<span style="color:#e5707a;font-weight:700">E 1</span>')]
m1=f'<div style="position:relative">{ml(parts)}{tip("Git status · SPC g g",470,30)}</div>'
pr=minibuf(f'<span style="color:#a5a39e">Rename</span><span style="font-family:ui-monospace,monospace;color:#ecebe8">limit_label</span><span style="color:#55575f">→</span><span style="font-family:ui-monospace,monospace;color:#ecebe8;border-bottom:1px solid #6cb8f5">plan_limit_label</span><span style="flex:1"></span>{chip("esc","Cancel")}{chip("↩","Rename",True)}')
sb=minibuf(f'<span style="color:#6cb8f5">/</span><span style="font-family:ui-monospace,monospace;color:#ecebe8">limit</span><span style="color:#8f8d88">3 of 9</span><span style="flex:1"></span>{chip("N","↑")}{chip("n","↓")}{chip("↩","Find",True)}')
qf_rows='<div style="padding:4px 0;font-size:12.5px;font-family:ui-monospace,monospace">'+"".join(f'<div style="height:22px;display:flex;align-items:center;gap:10px;padding:0 16px;{("background:rgba(108,184,245,0.18);" if i==1 else "")}"><span style="color:#8fc7ff;text-decoration:underline">{p}</span><span style="color:#a5a39e;font-family:-apple-system,sans-serif">{t}</span></div>' for i,(p,t) in enumerate([("lib/minga_editor/session/chrome_state.ex:234","replaced 1 line with 3"),("lib/minga_editor/session/chrome_state.ex:239","added 2 lines"),("lib/minga_agent/usage_limit.ex:1","new file")]))+'</div>'
btn=lambda t: f'<span style="padding:2px 8px;border-radius:5px;background:rgba(255,255,255,0.09);color:#dcdce2;font-size:12px">{t}</span>'
qf=drawer(("*quickfix*","Quickfix"),'<span style="color:#8f8d88">2 of 3</span>',f'{btn("‹")}<span style="width:4px"></span>{btn("›")}<span style="width:10px"></span>{hint("q","close")}',qf_rows,h=104)
inner=f'<div style="flex:1;min-height:0;display:flex;flex-direction:column;position:relative">{editor_area(code(3,dim=True))}{qf}{sb}{pr}{m1}</div>'
mac=f'<div style="display:flex;gap:22px;align-items:flex-start">{macwin(inner,w=1010,h=330)}{note(["<b style=\'color:#e6e4df\'>Modeline:</b> every segment clicks to the obvious place; git (hovered) opens git status. Tooltips name the action and key.","<b style=\'color:#e6e4df\'>Prompts:</b> a transient prompt shows its actions as chips: Rename, Cancel; buffer search adds ↑ ↓ for N and n.","<b style=\'color:#e6e4df\'>Drawers:</b> the hints in a header become buttons; lists get ‹ › for previous and next."])}</div>'
g=G.Grid(TW,TH); tcode(g,9,dim=True)
qg=G.Grid(TW,6,bg=SURF); qg.box(0,0,6,TW,G.FOCUS,SURF,title=[("*quickfix*",G.SUB),("  Quickfix  ",G.TXT,"b"),("2 of 3",G.DIM)],bottom=[("[‹]",G.TXT),(" ",G.DIM),("[›]",G.TXT),("  q",G.TXT),(" close",G.DIM)])
qg.segs(1,2,[("lib/minga_editor/session/chrome_state.ex:234",G.FN,None,"bu"),("  replaced 1 line with 3",G.DIM)]); qg.bgrow(2,1,TW-2,"#2c3a4a")
qg.segs(2,2,[("lib/minga_editor/session/chrome_state.ex:239",G.FN,"#2c3a4a","bu"),("  added 2 lines",G.SUB,"#2c3a4a")]); qg.segs(3,2,[("lib/minga_agent/usage_limit.ex:1",G.FN,None,"bu"),("  new file",G.DIM)])
for y in range(6):
    for x in range(TW): g.c[9+y][x]=list(qg.c[y][x])
g.fill(15,0,TW,"#1b1c21"); g.segs(15,1,[("Rename ",G.DIM,"#1b1c21"),("limit_label → plan_limit_label",G.TXT,"#1b1c21")]); g.segs(15,TW-28,[("[esc cancel]",G.TXT,"#30313a"),(" ",None,"#1b1c21"),("[↩ rename]",G.TXT,"#1f4f80","b")])
g.fill(16,0,TW,"#1b1c21"); g.segs(16,1,[("/limit",G.BLUE,"#1b1c21"),("  3 of 9",G.DIM,"#1b1c21")]); g.segs(16,TW-24,[("[N ↑]",G.TXT,"#30313a"),(" ",None,"#1b1c21"),("[n ↓]",G.TXT,"#30313a"),(" ",None,"#1b1c21"),("[↩ find]",G.TXT,"#1f4f80","b")])
g.fill(17,0,TW,"#25262c")
x=g.segs(17,0,[(" NORMAL ","#12304a",G.BLUE,"b"),(" ",None,"#25262c"),(" ◉ 1 ",G.AMBER,"#3a3120","b"),(" ",None,"#25262c"),(" chrome_state.ex ",G.TXT,"#30313a","b"),(" ",None,"#25262c"),(" change 1/2 ",G.PURPLE,"#2e2840"),(" ",None,"#25262c"),(" main +11 ",G.TXT,"#2c3a4a"),(" ",None,"#25262c"),(" ◐ Minga here 2/3 ",G.PURPLE,"#25262c"),(" E 1 ",G.RED,"#3a2328","b")])
g.segs(17,TW-8,[(" 240:31 ",G.TXT,"#30313a")])
g.fill(18,0,TW,"#1b1c21"); g.segs(18,1,[("Git status · SPC g g",G.DIM,"#1b1c21"),("   (hovering the git segment)",G.FAINT,"#1b1c21")])
g.fill(19,0,TW,BG if 'BG' in globals() else "#1e1f24")
write("Mouse_ModelineChips.dc.html",board("Mouse: modeline, prompt chips, drawer buttons",("Clickable modeline, prompt chips and drawer buttons","git segment hovered; a rename prompt and a buffer search with chips; quickfix with ‹ ›"),mac,"",tterm(g,"TUI","chips in brackets; hover names the segment in the echo area"),
 [("click git segment","git.status (git.status.clean when clean)"),("click change 1/2","next Minga change"),("chip ↩ Rename / esc Cancel","edit.plain"),("chips ↑ ↓ (N, n)","previous / next match"),("drawer ‹ ›","previous / next quickfix item"),("header To quickfix (project search)","search.quickfix")],
 "Closes 2 gaps (git status) and all 12 transient exits that lacked a click. Prompts and drawers are transient surfaces, so showing their keys keeps principle 10."))
