import os as _os
TOOLS = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))
BOARDS = _os.environ.get("BOARDS_DIR", _os.path.join(TOOLS, "..", "boards"))  # committed boards, read only
OUT_DIR = _os.environ.get("OUT_DIR", _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "out"))
_os.makedirs(OUT_DIR, exist_ok=True)
import os, subprocess
S = TOOLS
os.environ.setdefault("OUT_DIR",S+"/batch4/out")
b3=open(S+"/batch3/b3.py").read()
exec(b3[:b3.index("# ===== 1. errors.crash_reconnect")])
OUT=os.environ["OUT_DIR"]; os.makedirs(OUT,exist_ok=True)

def center(lines):
    inner="".join(lines)
    return f'<div style="position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:7px;text-align:center;padding:0 20px">{inner}</div>'
def big(t): return f'<div style="font-size:14px;color:#dcdce2">{t}</div>'
def small(t): return f'<div style="font-size:12px;color:#8f8d88">{t}</div>'
def acts(*pairs): return '<div style="margin-top:8px;font-size:12.5px">'+"".join(k(a,b) for a,b in pairs)+'</div>'
# ---- Empty-state anatomy: title, one muted description, a gap, then an action list.
# Keys sit in a fixed-width accent column; the most likely action is preselected (↩ runs it).
def es_title(text, glyph=None):
    g=f'{B.st(glyph,14)}' if glyph else ''
    return f'<div style="display:flex;align-items:center;gap:8px;font-size:14px;font-weight:600;color:#dcdce2">{g}<span>{text}</span></div>'
def es_row(key,label,state=None):
    if state=="sel":
        bg="background:#2c3e57;box-shadow:inset 2px 0 0 #6cb8f5;"; kc="#6cb8f5"; lc="#ecebe8"
    elif state=="hover":
        bg="background:rgba(255,255,255,0.07);"; kc="#b98cf0"; lc="#dcdce2"
    else:
        bg=""; kc="#b98cf0"; lc="#dcdce2"
    return f'<div style="height:26px;display:flex;align-items:center;border-radius:5px;padding:0 10px;{bg}"><span style="width:84px;flex:none;font-family:ui-monospace,\'SF Mono\',Menlo,monospace;font-size:12px;font-weight:700;color:{kc}">{key}</span><span style="font-size:12.5px;color:{lc}">{label}</span></div>'
def es(title, desc=None, actions=(), hover=None, glyph=None):
    rows="".join(es_row(k_,l_, "sel" if i==0 else ("hover" if hover==i else None)) for i,(k_,l_) in enumerate(actions))
    d=f'<div style="margin-top:4px;font-size:12px;color:#8f8d88">{desc}</div>' if desc else ''
    al=f'<div style="margin-top:16px;width:300px;display:flex;flex-direction:column;gap:2px">{rows}</div>' if actions else ''
    return f'<div style="position:absolute;inset:0;padding:18px 22px;overflow:hidden">{es_title(text=title,glyph=glyph)}{d}{al}</div>'
# TUI: left-aligned block inside the box; selected row = full-width bar with the key as a reverse chip.
def es_tree():
    rows=es_row("a","New file","sel")+es_row("A","New folder")
    return f'<div style="position:absolute;inset:0;padding:14px 12px"><div style="font-size:13px;font-weight:600;color:#dcdce2">new_project/ is empty.</div><div style="margin-top:14px;display:flex;flex-direction:column;gap:2px">{rows}</div></div>'
def tes(d, title, desc=None, actions=(), tcol=None, glyph=None, r=2):
    x=3
    if glyph: d.put(r,x,glyph[0],glyph[1]); x+=2
    d.put(r,x,title,tcol or G.TXT,None,"b")
    if desc: d.put(r+1,3,desc,G.DIM)
    ar=r+3 if desc else r+2
    kw=max([len(a[0]) for a in actions]+[1])+4
    for i,(k_,l_) in enumerate(actions):
        rr=ar+i
        if i==0:
            d.bgrow(rr,1,d.w-2,"#2c3e57")
            d.put(rr,3,f" {k_} ","#14151a",G.BLUE,"b"); d.put(rr,3+kw,l_,G.TXT,"#2c3e57")
        else:
            d.put(rr,4,k_,G.PURPLE,None,"b"); d.put(rr,3+kw,l_,G.CODE)
def minimac(inner,title,path,w=452,h=290): return macwin(inner,title=title,path=path,w=w,h=h)
def mini_ml(file,right=None,pos="1:1",minga=None): return modeline(file=file,minga=minga,right=right,pos=pos)
def tgrid(w,h): return G.Grid(w,h)
def tbox(g,r,h,w,title,bottom,c=0,focus=True):
    d=G.Grid(w,h,bg=SURF); d.box(0,0,h,w,G.FOCUS if focus else G.BORDER,SURF,title=title,bottom=bottom); return d
def tcenter(d,r,text,col):
    d.put(r,max(1,(d.w-len(text))//2),text,col)
def tml(g,r,mode,parts,right=""):
    g.fill(r,0,g.w,"#25262c")
    pill={"NORMAL":("#12304a",G.BLUE),"INSERT":("#12301a",G.GREEN)}[mode]
    x=g.segs(r,0,[(f" {mode} ",pill[0],pill[1],"b"),(" ",None,"#25262c")])
    for p in parts: x=g.segs(r,x,[p,(" ",None,"#25262c")])
    if right: g.segs(r,g.w-len(right),[(right,G.TXT,"#30313a")])
def row3(*items): return '<div style="display:flex;gap:18px">'+"".join(items)+'</div>'
def labeled(lab,sub,html): return f'<div><div class="lab"><b>{lab}</b>  {sub}</div>{html}</div>'
def tterms(*gs): return '<div style="display:flex;gap:12px">'+"".join(G.term(g.html(),l,s) for g,l,s in gs)+'</div>'


# Live prompts own every typed key, so next steps are result rows you move to (⌃J ⌃K or ↓ ↑, ↩, click),
# never chords that collide with text editing (⌃A, ⌃E, ⌃H, ⌃W, ⌃U, ⌃K as kill).
def prow(label,note,sel=False):
    bg="background:#2c3e57;box-shadow:inset 2px 0 0 #6cb8f5;" if sel else ""
    lc="#ecebe8" if sel else "#dcdce2"
    nc="#c9d6ea" if sel else "#8f8d88"
    return f'<div style="height:24px;display:flex;align-items:center;border-radius:5px;padding:0 10px;{bg}"><span style="font-size:12.5px;color:{lc}">{label}</span><span style="flex:1"></span><span style="font-family:ui-monospace,monospace;font-size:11.5px;color:{nc}">{note}</span></div>'
def pres(title, desc, rows):
    r="".join(prow(l_,n_,i==0) for i,(l_,n_) in enumerate(rows))
    d=f'<div style="margin-top:4px;font-size:12px;color:#8f8d88">{desc}</div>' if desc else ''
    return f'<div style="position:absolute;inset:0;padding:14px 22px;overflow:hidden"><div style="font-size:14px;font-weight:600;color:#dcdce2">{title}</div>{d}<div style="margin-top:12px;width:420px;display:flex;flex-direction:column;gap:2px">{r}</div></div>'
def tpres(d, title, desc, rows, r=1):
    d.put(r,3,title,G.TXT,None,"b")
    if desc: d.put(r+1,3,desc,G.DIM)
    ar=r+3 if desc else r+2
    for i,(l_,n_) in enumerate(rows):
        rr=ar+i
        if i==0:
            d.bgrow(rr,1,d.w-2,"#2c3e57"); d.put(rr,2,"▌",G.BLUE,"#2c3e57"); d.put(rr,4,l_,G.TXT,"#2c3e57"); d.put(rr,d.w-3-len(n_),n_,G.SUB,"#2c3e57")
        else:
            d.put(rr,4,l_,G.CODE); d.put(rr,d.w-3-len(n_),n_,G.DIM)
PHELP=lambda: f'{hint("⌃J ⌃K","move")}{sp()}{hint("↩","run")}{sp()}{hint("esc","close")}'
TPHELP=[("⌃J ⌃K",G.TXT),(" move  ",G.DIM),("↩",G.TXT),(" run  ",G.DIM),("esc",G.TXT),(" close",G.DIM)]

# ===== 1. windows.narrow
def narrow_ml(needs=True):
    pill=mode_pill("NORMAL")
    ny=f'<span style="display:flex;align-items:center;gap:6px;padding:0 10px;color:#f2b544">{B.st("Needs you",12)}1</span>' if needs else ""
    return f'''<div style="height:26px;flex:none;display:flex;align-items:center;background:#25262c;border-top:1px solid rgba(255,255,255,0.07);font-size:12px;color:#a5a39e;white-space:nowrap">
{pill}{ny}{seg('<span style="color:#ecebe8;font-weight:600">chrome_state.ex</span>')}{seg('<span style="color:#b98cf0">change 1/2</span>')}{seg(B.st("Working",12)+'<span style="color:#b98cf0">2/3</span>')}{seg('<span style="color:#e5707a;font-weight:700">E 1</span>')}<span style="flex:1"></span></div>'''
rows='''<div style="padding:4px 0;font-size:12.5px">
<div style="height:24px;display:flex;align-items:center;gap:10px;padding:0 14px;background:rgba(242,181,68,0.10)">%s<span style="color:#ecebe8;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">Add tests for the usage-limit…</span><span style="flex:1"></span><span style="color:#f2b544;white-space:nowrap">Needs you</span></div>
<div style="height:24px;display:flex;align-items:center;gap:10px;padding:0 14px">%s<span style="color:#dcdce2;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">Show the plan limit instead of…</span><span style="flex:1"></span><span style="color:#8f8d88;white-space:nowrap">2/3 · 4m</span></div>
<div style="height:24px;display:flex;align-items:center;gap:10px;padding:0 14px">%s<span style="color:#dcdce2">Update the agent docs</span><span style="flex:1"></span><span style="color:#8f8d88">Done</span></div></div>'''%(B.st("Needs you",12),B.st("Working",12),B.st("Done",12))
dr=drawer(("*minga-tasks*","Minga Tasks"),'',f'{hint("↩","open")}{sp()}{hint("q","close")}',rows,h=118)
macn=macwin(editor_area(code(6))+dr+narrow_ml(),title="chrome_state.ex",path="…/session",w=1060,h=380)
mac=f'<div style="display:flex;gap:22px;align-items:flex-start">{macn}<div class="ex" style="width:300px;padding-top:4px"><h4>Dropped, in order</h4><div>1. filetype (Elixir)</div><div>2. position (240:31)</div><div>3. git (main +11)</div><div>4. Minga\'s words: "Minga here 2/3" becomes the glyph and 2/3</div><h4 style="margin-top:10px">Never dropped</h4><div>mode, needs-you, the file name, errors</div><div style="margin-top:10px">The title path shortens from the left with an ellipsis; the file name never does. Drawer rows truncate the goal, never the state word.</div></div></div>'
g=tgrid(80,20); tcode(g,9,dim=False,width=80)
d=tbox(g,0,6,80,[("*minga-tasks*",G.SUB),("  Minga Tasks",G.TXT,"b")],[("↩",G.TXT),(" open  ",G.DIM),("q",G.TXT),(" close",G.DIM)])
d.bgrow(1,1,78,"#3a3120"); d.segs(1,2,[("◉ ",G.AMBER,"#3a3120"),("Add tests for the usage-limit…",G.TXT,"#3a3120","b")]); d.put(1,68,"Needs you",G.AMBER,"#3a3120")
d.segs(2,2,[("◐ ",G.PURPLED),("Show the plan limit instead of…",G.CODE)]); d.put(2,70,"2/3 · 4m",G.DIM)
d.segs(3,2,[("● ",G.GREEN),("Update the agent docs",G.CODE)]); d.put(3,74,"Done",G.DIM)
blit(g,d,11)
tml(g,18,"NORMAL",[(" ◉ 1 ",G.AMBER,"#3a3120","b"),(" chrome_state.ex ",G.TXT,"#30313a","b"),(" change 1/2 ",G.PURPLE,"#2e2840"),(" ◐ 2/3 ",G.PURPLE,"#25262c"),(" E 1 ",G.RED,"#3a2328","b")])
g.fill(19,0,80,"#1e1f24")
write("Batch4_windows_narrow.dc.html",board("Batch 4: a narrow window",("1280 pt window (drawn at 1060 px)","the modeline drops segments in the fixed order; the drawer truncates goals, not states"),mac,"",tterm(g,"TUI 80 × 24","same order at 80 columns"),
 [("(any key)","unchanged: narrowing changes presentation only"),("SPC a a, SPC ,, SPC o t","the same drawers, at full window width")],
 "Breakpoints follow width, not device: at 1440 pt everything shows; below about 1360 pt filetype and position go; below about 1180 pt git goes; below about 1000 pt Minga's words collapse to the glyph and 2/3. In the TUI the same ladder runs at 140, 120, 100 and 80 columns."))

# ===== 2. search empties
mb=minibuf(f'<span style="color:#6cb8f5">/</span><span style="color:#ecebe8;font-family:ui-monospace,monospace">limit_lable</span><span style="color:#e5707a">no matches in this buffer</span><span style="flex:1"></span>{hint("SPC s p","search the project")}{sp()}{hint("esc","cancel")}')
left=macwin(editor_area(code(8))+mb+modeline(right=None),w=684,h=300)
SROWS=[("Search ignored files too","-- -u"),("Search hidden files too","--hidden"),("Search all files","-- -uu")]
pbody=pres("No results for “limit_lable” in 1,204 files.","Ignored and hidden files were skipped. Keep typing to change the query.",SROWS)
pdr=drawer(("*search*","Search Project"),'<span style="color:#6cb8f5">limit_lable</span>',PHELP(),pbody,h=170)
right=macwin(editor_area(code(3,dim=True))+pdr+modeline(file="*search*",right=None,pos="1:1"),w=684,h=300)
mac=f'<div style="display:flex;gap:24px">{labeled("/ in a buffer","the minibuffer says it, and offers the wider search",left)}{labeled("SPC s p","an empty drawer that says what was skipped",right)}</div>'
g1=tgrid(62,TH); tcode(g1,15,dim=False,width=62)
g1.fill(16,0,62,"#1b1c21"); g1.segs(16,1,[("/",G.BLUE,"#1b1c21"),("limit_lable",G.TXT,"#1b1c21"),("  no matches in this buffer",G.RED,"#1b1c21")])
g1.fill(17,0,62,"#1b1c21"); g1.segs(17,3,[("SPC s p",G.TXT,"#1b1c21"),(" search the project   ",G.DIM,"#1b1c21"),("esc",G.TXT,"#1b1c21"),(" cancel",G.DIM,"#1b1c21")])
tml(g1,18,"NORMAL",[(" chrome_state.ex ",G.TXT,"#30313a","b")])
g2=tgrid(62,TH); tcode(g2,8,dim=True,width=62)
d=tbox(g2,0,9,62,[("*search*",G.SUB),("  Search Project  ",G.TXT,"b"),("limit_lable",G.BLUE)],TPHELP)
tpres(d,"No results for “limit_lable” in 1,204 files.","Ignored and hidden files were skipped.",SROWS,r=1)
blit(g2,d,9); tml(g2,18,"NORMAL",[(" *search* ",G.TXT,"#30313a","b")])
write("Batch4_search_empty.dc.html",board("Batch 4: search with nothing found",("Search empty states","say what was searched and what was skipped, then offer the next wider search"),mac,"",tterms((g1,"TUI","/ in a buffer"),(g2,"","SPC s p")),
 [("buffer: SPC s p","search.project (same query)"),("buffer: esc","edit.plain"),("project: ⌃J / ↓ then ↩ (or click)","search.project (rerun with the row's flag: ignored, hidden, or all files)"),("project: typing","search.project (keeps editing the query; flags after -- work as in Doom)"),("project: esc","edit.plain")],
 "The prompt owns every typed key, so the next steps are result rows you move to, never chords: ⌃A and ⌃H edit text in a prompt. Each row shows the ripgrep flag it adds, so the menu teaches the Doom syntax (limit_lable -- -uu)."))

# ===== 3. code empties
diag=es("No problems in this project.","elixir-ls and credo checked 1,204 files · 4 s ago",[("r","Check again"),("SPC c l i","Show what ran")],glyph="Done")
dwin=macwin(editor_area(code(4,dim=True))+drawer(("*diagnostics*","Diagnostics"),'',f'{hint("q","close")}',diag,h=150)+modeline(file="*diagnostics*",right=None,pos="1:1"),w=684,h=300)
e1=macwin(editor_area(code(3))+echo(f'<span style="color:#dcdce2">No code actions at 240:31.</span><span style="flex:1"></span>{hint("SPC a ?","ask Minga")}')+modeline(right=None),w=684,h=138)
e2=macwin(editor_area(code(3))+echo(f'<span style="color:#dcdce2">No references to <span style="font-family:ui-monospace,monospace;font-size:12px">limit_label/1</span>.</span><span style="flex:1"></span>{hint("SPC c d","go to definition")}')+modeline(right=None),w=684,h=138)
mac=f'<div style="display:flex;gap:24px">{labeled("SPC c x","nothing to report, and when it was last checked",dwin)}<div style="display:flex;flex-direction:column;gap:10px"><div class="lab"><b>SPC c a  ·  SPC c D</b>  a one-line answer in the echo area; nothing opens</div>{e1}{e2}</div></div>'
g1=tgrid(62,TH); tcode(g1,8,dim=True,width=62)
d=tbox(g1,0,9,62,[("*diagnostics*",G.SUB),("  Diagnostics",G.TXT,"b")],[("q",G.TXT),(" close",G.DIM)])
tes(d,"No problems in this project.","elixir-ls and credo checked 1,204 files · 4 s ago",[("r","Check again"),("SPC c l i","Show what ran")],glyph=("●",G.GREEN),r=1)
blit(g1,d,9); tml(g1,18,"NORMAL",[(" *diagnostics* ",G.TXT,"#30313a","b")])
g2=tgrid(62,TH); tcode(g2,13,dim=False,width=62)
g2.fill(14,0,62,"#1b1c21"); g2.segs(14,1,[("No code actions at 240:31.",G.TXT,"#1b1c21"),("   SPC a ?",G.TXT,"#1b1c21"),(" ask Minga",G.DIM,"#1b1c21")])
g2.fill(16,0,62,"#1b1c21"); g2.segs(16,1,[("No references to limit_label/1.",G.TXT,"#1b1c21"),("   SPC c d",G.TXT,"#1b1c21"),(" definition",G.DIM,"#1b1c21")])
tml(g2,18,"NORMAL",[(" chrome_state.ex ",G.TXT,"#30313a","b")])
write("Batch4_code_empty.dc.html",board("Batch 4: code intelligence with nothing to show",("Code empty states","a list only opens when there is something in it"),mac,"",tterms((g1,"TUI","SPC c x"),(g2,"","SPC c a, then SPC c D (two separate moments)")),
 [("diagnostics: r (preselected)","code.diagnostics.none (checks again)"),("diagnostics: SPC c l i","code.lsp_info"),("diagnostics: q / esc","edit.plain"),("actions: SPC a ?","minga.inline_ask (ask Minga about the line)"),("actions: (any key)","edit.plain (the echo fades)"),("references: SPC c d","edit.plain (at the definition)"),("references: (any key)","edit.plain")],
 "Empty actions and references never open a drawer: an empty list is a dead end you have to close. The echo line answers and gets out of the way. Diagnostics opens because you asked for the list; it says when it last checked so \"none\" is trustworthy."))

# ===== 4a. files empties
FROWS=[("Create lib/…/chrome_stat_test.ex","new file"),("Search the project for chrome_stat_test","SPC s p"),("Search ignored files too","-- -u")]
sw=pres("Nothing matches “chrome_stat_test”.","Searched 1,204 files in this project.",FROWS)
swd=drawer(("*find-file*","Find file"),'<span style="color:#6cb8f5">chrome_stat_test</span>',f'{hint("↩","run")}{sp()}{hint("esc","close")}',sw,h=196)
m1=minimac(editor_area(code(3,dim=True))+swd+mini_ml("*find-file*"),"chrome_state.ex","…/session")
tr=f'<div style="display:flex;flex:1;min-height:0"><div style="width:236px;background:#23242a;border-right:1px solid rgba(255,255,255,0.07);position:relative">{es_tree()}</div><div style="flex:1"></div></div>'
m2=minimac(tr+mini_ml("*file-tree*"),"new_project","~/code")
pj=es("No projects yet.","Minga remembers folders you open.",[("SPC p a","Add a folder"),("SPC f f","Open a file")])
m3=minimac(editor_area("")+drawer(("*projects*","Switch Project"),'',f'{hint("esc","close")}',pj,h=170)+mini_ml("*projects*"),"*scratch*","")
mac=row3(labeled("SPC ,","no match",m1),labeled("SPC o p","an empty folder",m2),labeled("SPC p p","no known projects",m3))
def mini_t(title,head,desc,actions,bottom,glyph=None,tcol=None):
    g=tgrid(42,14); d=tbox(g,0,9,42,title,bottom)
    tes(d,head,desc,actions,tcol=tcol,glyph=glyph,r=1)
    blit(g,d,3); tml(g,13,"NORMAL",[(f" {title[0][0]} ",G.TXT,"#30313a","b")]); return g
t1=tgrid(42,14); _d=tbox(t1,0,9,42,[("*find-file*",G.SUB),("  chrome_stat_test",G.BLUE)],[("⌃J ⌃K",G.TXT),(" move  ",G.DIM),("↩",G.TXT),(" run",G.DIM)])
tpres(_d,"Nothing matches.","Searched 1,204 files.",[("Create the file","new"),("Search the project","SPC s p"),("Search ignored too","-- -u")],r=1)
blit(t1,_d,3); tml(t1,13,"NORMAL",[(" *find-file* ",G.TXT,"#30313a","b")])
t2=mini_t([("*file-tree*",G.SUB),("  new_project/",G.TXT,"b")],"new_project/ is empty.",None,[("a","New file"),("A","New folder")],[("q",G.TXT),(" close",G.DIM)])
t3=mini_t([("*projects*",G.SUB),("  Switch Project",G.TXT,"b")],"No projects yet.","Minga remembers folders you open.",[("SPC p a","Add a folder"),("SPC f f","Open a file")],[("esc",G.TXT),(" close",G.DIM)])
write("Batch4_files_empty.dc.html",board("Batch 4: files with nothing in them",("File empty states","each one names the single thing you probably wanted to do next"),mac,"",tterms((t1,"TUI","SPC ,"),(t2,"","SPC o p"),(t3,"","SPC p p")),
 [("switcher: ↩ on Create","edit.plain (a new file at the typed path, in the project's best-guess folder)"),("switcher: ↩ on Search the project","search.project (same text)"),("switcher: ↩ on Search ignored","files.switcher (searches ignored files too)"),("switcher: esc","edit.plain"),("tree: a / A","files.tree (new file / folder prompt)"),("tree: q","edit.plain"),("projects: SPC p a","start.project_switcher (after adding)"),("projects: SPC f f","files.switcher"),("projects: esc","edit.plain")],
 "The switcher prompt owns typed letters, so its next steps are rows you move to with ⌃J ⌃K and run with ↩, never chords. The tree is a special buffer, so a and A are bare keys there, like dired."))

# ===== 4b. git, extensions, queue
gs=es("Nothing to commit on main.","Up to date with origin/main · last commit 2 h ago",[("l","Show log"),("SPC g B","Blame this file")],hover=1,glyph="Done")
n1=minimac(editor_area(code(3,dim=True))+drawer(("*git-status*","Git Status"),'',f'{hint("q","close")}',gs,h=170)+mini_ml("*git-status*"),"chrome_state.ex","…/session")
ex=es("No extensions installed.","Extensions add languages, tools and commands.",[("SPC h e l","Browse extensions"),("SPC f p","Open your config")])
n2=minimac(editor_area("")+drawer(("*extensions*","Extensions"),'',f'{hint("q","close")}',ex,h=170)+mini_ml("*extensions*"),"*scratch*","")
qu=es("Nothing queued.","Messages you queue while Minga works wait here.",[("↩","Back to the composer")])
convo='<div style="flex:1;min-height:0;padding:10px 16px;font-size:12.5px;color:#c9c7c2"><div style="color:#b98cf0;font-size:11px;font-weight:600">Minga</div><div>Plan limit now shows in the modeline.</div></div>'
n3=minimac(convo+drawer(("*minga-queue*","Queue"),'',f'{hint("q","close")}',qu,h=150,focus=True)+mini_ml("*minga-queue*"),"Show the plan limit…","conversation")
mac=row3(labeled("SPC g g","a clean tree",n1),labeled("SPC h e l","no extensions",n2),labeled("SPC a q q","an empty queue",n3))
u1=mini_t([("*git-status*",G.SUB),("  Git Status",G.TXT,"b")],"Nothing to commit on main.","Up to date with origin/main",[("l","Show log"),("SPC g B","Blame this file")],[("q",G.TXT),(" close",G.DIM)],glyph=("●",G.GREEN))
u2=mini_t([("*extensions*",G.SUB),("  Extensions",G.TXT,"b")],"No extensions installed.","Add languages, tools, commands.",[("SPC h e l","Browse extensions"),("SPC f p","Open your config")],[("q",G.TXT),(" close",G.DIM)])
u3=mini_t([("*minga-queue*",G.SUB),("  Queue",G.TXT,"b")],"Nothing queued.","Queued messages wait here.",[("↩","Back to the composer")],[("q",G.TXT),(" close",G.DIM)])
write("Batch4_git_ext_queue_empty.dc.html",board("Batch 4: git, extensions and the queue, empty",("Status empty states","calm, specific, and one key away from the obvious next step"),mac,"",tterms((u1,"TUI","SPC g g"),(u2,"","SPC h e l"),(u3,"","SPC a q q")),
 [("git: l","git.log (recent commits)"),("git: SPC g B","git.blame"),("git: q","edit.plain"),("extensions: SPC h e l","settings.extensions (the catalogue)"),("extensions: SPC f p","edit.plain (your config)"),("extensions: q","edit.plain"),("queue: ↩ (preselected) or q","minga.conversation (focus back to the composer)")],
 "A clean tree uses the Done shape because it is a finished, good state; nothing here uses amber or red. The queue's empty state teaches the one key that fills it."))

# ===== 5. search.quickfix
def qrow(sel,file,line,txt,minga=False):
    bg="background:rgba(26,149,242,0.85);color:#fff;" if sel else ""
    # Every row here is one of Minga's changes, so a per-row mark would carry no information.
    return f'<div style="height:24px;display:flex;align-items:center;gap:10px;padding:0 14px;{bg}font-family:ui-monospace,monospace;font-size:12px"><span style="color:{"#fff" if sel else "#8fc7ff"};text-decoration:underline">{file}:{line}</span><span style="color:{"#e6eefc" if sel else "#c9c7c2"}">{txt}</span></div>'
qbody=('<div style="padding:4px 0">'+qrow(True,"lib/minga_editor/session/chrome_state.ex","234","replaced 1 line with 3",True)+qrow(False,"lib/minga_editor/session/chrome_state.ex","239","added 2 lines",True)+qrow(False,"lib/minga_agent/usage_limit.ex","1","new file, 31 lines",True)+qrow(False,"test/minga_agent/usage_limit_test.exs","12","new file, 86 lines",True)+'</div>')
qd=drawer(("*quickfix*","Quickfix"),'<span style="color:#8f8d88">4 · from :Minga review</span>',f'{hint("↩","jump")}{sp()}{hint("]q [q","next / prev")}{sp()}{hint("q","close")}',qbody,h=140)
mac=macwin(editor_area(code(7))+qd+modeline(file="*quickfix*",right=None,pos="1:1"))
g=G.Grid(TW,TH); tcode(g,9,dim=True)
d=tbox(g,0,8,TW,[("*quickfix*",G.SUB),("  Quickfix",G.TXT,"b"),("  4 · from :Minga review",G.DIM)],[("↩",G.TXT),(" jump  ",G.DIM),("]q [q",G.TXT),(" next / prev  ",G.DIM),("q",G.TXT),(" close",G.DIM)])
items=[("lib/minga_editor/session/chrome_state.ex:234","replaced 1 line with 3"),("lib/minga_editor/session/chrome_state.ex:239","added 2 lines"),("lib/minga_agent/usage_limit.ex:1","new file, 31 lines"),("test/minga_agent/usage_limit_test.exs:12","new file, 86 lines")]
SEL="#2c3e57"
for i,(f,t) in enumerate(items):
    r=1+i
    if i==0: d.bgrow(r,1,TW-2,SEL); d.put(r,1,"▌",G.BLUE,SEL)
    bg=SEL if i==0 else None
    d.put(r,3,f,G.BLUE,bg,"u"); d.put(r,3+len(f)+2,t,G.CODE,bg)
blit(g,d,10); tml(g,18,"NORMAL",[(" *quickfix* ",G.TXT,"#30313a","b"),(" 1 of 4 ",G.SUB,"#25262c")])
write("Batch4_search_quickfix.dc.html",board("Batch 4: the quickfix list",(":Minga review  ·  ⌃Q from project search","Vim's quickfix, filled by Minga's changes or a search, in the drawer style"),mac,"",tterm(g,"TUI","bubbles/list rows, OSC 8 paths, the selection bar"),
 [("↩","edit.plain (the file at that line; the drawer stays)"),("]q / [q","edit.plain (next / previous item, from anywhere)"),(":cdo / :cfdo","edit.plain (run a command over every item; listed in which-key under SPC s q, not on screen)"),("q / esc","edit.plain (closes the drawer; the list remains for ]q)")],
 "No per-row marks: every item here is one of Minga's changes and the header says so. A list that mixes sources would show a thin authorship strand per row instead. ]q keeps working after the drawer closes, as in Vim."))

# ===== 6. git.blame
# One row per code line; every line belongs to a commit. Consecutive lines from the same
# commit form a group: author and age show on the group's first line only, with a hairline above it.
BL=[("JS","2 h","",1),("JS","2 h","",0),("JS","3 d","",1),("JS","3 d","",0),("JS","3 d","",0),("Minga","4 m","m",1),("Minga","4 m","m",0),("Minga","4 m","m",0),("Minga","4 m","m",0),("AK","2 w","",1),("AK","2 w","",0),("You","now","y",1),("AK","2 w","",1)]
def blame_col(i):
    who,age,kind,first=BL[i]
    col="#b98cf0" if kind=="m" else ("#6cb8f5" if kind=="y" else "#8f8d88")
    rule="box-shadow:inset 0 1px 0 rgba(255,255,255,0.07);" if first and i>0 else ""
    inner=f'<span style="width:48px">{who}</span><span style="color:#7a7c85">{age}</span>' if first else ''
    return f'<span style="width:128px;box-sizing:border-box;flex:none;align-self:stretch;display:flex;align-items:center;gap:8px;padding:0 8px;font-size:11.5px;color:{col};background:#25262c;{rule}">{inner}</span>'
lines=code(13,minga="on").split("\n")
bl="\n".join(l.replace('<div class="ln" style="">','<div class="ln" style="">'+blame_col(i),1) for i,l in enumerate(lines))
pop='<div style="position:absolute;left:140px;top:200px;width:400px;border-radius:8px;border:1px solid rgba(255,255,255,0.12);background:#2a2b32;box-shadow:0 8px 24px rgba(0,0,0,0.45);padding:9px 12px;font-size:12px;line-height:18px"><div style="color:#b98cf0;font-weight:600">Minga · 4 minutes ago</div><div style="color:#dcdce2">Task: Show the plan limit instead of “rate limited”</div><div style="color:#8f8d88">Unreviewed · change 1 of 2 · <span style="font-family:ui-monospace,monospace">↩</span> open the conversation</div></div>'
BLS='<span style="color:#8f8d88">blame</span>'
mac=f'<div style="position:relative">{macwin(editor_area(bl)+modeline(right=None,minga=BLS))}{pop}</div>'
g=G.Grid(TW,TH)
for i in range(13):
    n,t=TC[i]; who,age,kind,first=BL[i]
    c=G.PURPLE if kind=="m" else (G.BLUE if kind=="y" else G.DIM)
    g.put(i,0,(f" {who:<6}{age:>4} " if first else " "*12),c,"#24252b")
    g.put(i,12,f"{n:>4} ",G.DIM); g.put(i,19,t,G.CODE)
    if 234<=n<=237: g.put(i,17,"╳" if n==234 else "┃",G.PURPLED)
g.put(14,1,"K on a Minga line:  Minga · 4 minutes ago · Show the plan limit instead of “rate limited” · unreviewed",G.PURPLE)
tml(g,18,"NORMAL",[(" chrome_state.ex ",G.TXT,"#30313a","b"),(" blame ",G.SUB,"#25262c")]," 240:31 ")
write("Batch4_git_blame.dc.html",board("Batch 4: blame",("SPC g B","a narrow column, not a new buffer: who and how long ago, with Minga as an author"),mac,"",tterm(g,"TUI","same column; K shows the detail in the echo area"),
 [("K (or hover)","git.blame (detail popover: commit, or Minga's task and review state)"),("↩ on a Minga line","minga.conversation (that task)"),("↩ on a commit line","git.log (that commit)"),("SPC g B / q","edit.plain (closes the column)")],
 "Uncommitted lines by Minga show \"Minga\" in the minga role colour, yours in the you role. Initials keep the column narrow; K shows full names. The column sits left of the line numbers so the twist and your blue strand stay where they always are."))

