import os as _os
TOOLS = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))
BOARDS = _os.environ.get("BOARDS_DIR", _os.path.join(TOOLS, "..", "boards"))  # committed boards, read only
OUT_DIR = _os.environ.get("OUT_DIR", _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "out"))
_os.makedirs(OUT_DIR, exist_ok=True)
import os, subprocess
S = TOOLS
os.environ.setdefault("OUT_DIR",S+"/batch6/out")
b3=open(S+"/batch3/b3.py").read()
exec(b3[:b3.index("# ===== 1. errors.crash_reconnect")])
OUT=os.environ["OUT_DIR"]; os.makedirs(OUT,exist_ok=True)

MONO="font-family:ui-monospace,'SF Mono',Menlo,monospace"
def sec(t): return f'<div style="margin:16px 0 6px;font-size:11.5px;font-weight:600;color:#8f8d88">{t}</div>'
def num_row(n,name,path,right,sel=False):
    bg="background:rgba(26,149,242,0.16);box-shadow:inset 2px 0 0 #6cb8f5;" if sel else ""
    return f'<div style="height:24px;display:flex;align-items:center;gap:12px;padding:0 10px;border-radius:5px;{bg}font-size:12.5px"><span style="{MONO};color:#b98cf0;font-weight:700;width:10px">{n}</span><span style="{MONO};color:#ecebe8">{name}</span><span style="{MONO};color:#7a7c85;font-size:11.5px">{path}</span><span style="flex:1"></span><span style="color:#7a7c85;font-size:11.5px">{right}</span></div>'
def task_row(lab,goal,state,age,col):
    return f'<div style="height:24px;display:flex;align-items:center;gap:10px;padding:0 10px;font-size:12.5px">{B.st(lab,13)}<span style="color:#dcdce2">{goal}</span><span style="color:{col}">{state}</span><span style="flex:1"></span><span style="color:#7a7c85;font-size:11.5px">{age}</span></div>'
# Actions are their own "Next" section: one row per action, a fixed-width key column and a label.
# They are rows like any other on the home buffer (j/k reach them); only the first is preselected,
# and only when nothing above it holds the selection.
def acts_line(*pairs, sel_first=False):
    rows=""
    for i,(key,lab) in enumerate(pairs):
        sel = sel_first and i==0
        bg="background:#2c3e57;box-shadow:inset 2px 0 0 #6cb8f5;" if sel else ""
        kc="#6cb8f5" if sel else "#b98cf0"
        rows+=f'<div style="height:24px;display:flex;align-items:center;padding:0 10px;border-radius:5px;width:300px;{bg}font-size:12.5px"><span style="{MONO};width:84px;flex:none;font-weight:700;font-size:12px;color:{kc}">{key}</span><span style="color:#dcdce2">{lab}</span></div>'
    return sec("Next")+rows
def home_area(inner,wide=True):
    return f'<div style="flex:1;min-height:0;overflow:hidden;display:flex;justify-content:center"><div style="width:{760 if wide else 560}px;padding:22px 8px 0">{inner}</div></div>'
def head(name,path,line):
    return f'<div style="display:flex;align-items:baseline;gap:12px"><span style="font-size:20px;font-weight:700;color:#ecebe8">{name}</span><span style="{MONO};font-size:12px;color:#8f8d88">{path}</span></div><div style="margin-top:4px;font-size:12.5px;color:#a5a39e">{line}</div>'
def home_ml(file="*home*",minga=None,needs=False,right=None):
    ny=f'<span style="display:flex;align-items:center;gap:6px;padding:0 10px;color:#f2b544">{B.st("Needs you",12)}1 needs you</span>' if needs else ""
    m=seg(minga) if minga else ""
    return f'''<div style="height:26px;flex:none;display:flex;align-items:center;background:#25262c;border-top:1px solid rgba(255,255,255,0.07);font-size:12px;color:#a5a39e">{mode_pill("NORMAL")}{ny}{seg(f'<span style="color:#ecebe8;font-weight:600">{file}</span>')}{seg('<span style="color:#8f8d88">main</span><span style="color:#8f8d88">+11</span>') if right!="nogit" else ""}{m}<span style="flex:1"></span>{seg('<span style="font-family:ui-monospace,monospace;font-size:11.5px">1:1</span>',"padding-right:14px")}</div>'''
WORKING=seg_state("Working","Minga editing retry.ex 2/3","#b98cf0")

# shell snippet shown beside the TUI frame
def shell_snip(cwd,cmd,w=60,branch=" main"):
    g=G.Grid(w,3,bg="#14151a")
    g.segs(0,1,[(cwd,G.BLUE,"#14151a"),(branch,G.PURPLE,"#14151a"),(" ❯ ",G.GREEN,"#14151a"),(cmd,G.TXT,"#14151a","b")])
    g.put(1,1,"Minga takes over the terminal. On quit it prints",G.DIM,"#14151a")
    g.put(2,1,"Ciao. and you are back at this prompt.",G.DIM,"#14151a")
    return G.term(g.html(),"Launched from a shell","")
def tui_home(title_name,path,line,sections,actions,needs=False,minga=None,file="*home*",grid_h=TH,git=True,line2=None,sel_first=False):
    g=G.Grid(TW,grid_h)
    g.put(1,4,title_name,G.TXT,None,"b"); g.put(1,5+len(title_name),path,G.DIM)
    g.put(2,4,line,G.SUB)
    r=4
    if line2: g.put(3,4,line2,G.SUB); r=5
    for name,rows in sections:
        g.put(r,4,name,G.DIM,None,"b"); r+=1
        for parts in rows:
            g.segs(r,4,parts); r+=1
        r+=1
    g.put(r,4,"Next",G.DIM,None,"b"); r+=1
    kw=max(len(a[0]) for a in actions)+3
    for i,(key,lab) in enumerate(actions):
        if sel_first and i==0:
            g.bgrow(r,2,TW-4,"#2c3e57"); g.put(r,4,f" {key} ","#14151a",G.BLUE,"b"); g.put(r,5+kw,lab,G.TXT,"#2c3e57")
        else:
            g.put(r,5,key,G.PURPLE,None,"b"); g.put(r,5+kw,lab,G.CODE)
        r+=1
    parts=[]
    if needs: parts.append((" ◉ 1 needs you ",G.AMBER,"#3a3120","b"))
    parts.append((f" {file} ",G.TXT,"#30313a","b"))
    if git: parts.append((" main +11 ",G.SUB,"#25262c"))
    if minga: parts.append((minga,G.PURPLE,"#25262c"))
    tmode(g,grid_h-2,"NORMAL",parts," 1:1 ")
    return g

# ===== 1. start.open_dir.home
recent=(num_row(1,"chrome_state.ex","lib/minga_editor/session","2 h ago",sel=True)+num_row(2,"retry.ex","lib/minga_agent","2 h ago")
        +num_row(3,"usage_limit_test.exs","test/minga_agent","yesterday"))
tasks=(task_row("Needs you","Add tests for the usage-limit classifier","Needs you","2m","#f2b544")
       +task_row("Done","Update the agent docs for the Spine","Done · 2 files to review","12m","#7fbf7a"))
inner=(head("minga","~/code/minga","main · 11 changed · last commit 2 h ago")+sec("Recent in this project")+recent+sec("Minga tasks")+tasks
       +acts_line(("SPC SPC","Find a file"),("SPC a n","New task"),("SPC o p","File tree"),("SPC p p","Switch project")))
mac=macwin(home_area(inner)+home_ml(needs=True),title="minga",path="~/code/minga",h=450)
g=tui_home("minga","~/code/minga","main · 11 changed · last commit 2 h ago",
  [("Recent in this project",[[("1 ",G.PURPLE,None,"b"),("chrome_state.ex ",G.TXT),("lib/minga_editor/session",G.DIM),("   2 h ago",G.DIM)],[("2 ",G.PURPLE,None,"b"),("retry.ex ",G.TXT),("lib/minga_agent",G.DIM),("   2 h ago",G.DIM)],[("3 ",G.PURPLE,None,"b"),("usage_limit_test.exs ",G.TXT),("test/minga_agent",G.DIM),("   yesterday",G.DIM)]]),
   ("Minga tasks",[[("◉ ",G.AMBER),("Add tests for the usage-limit classifier  ",G.CODE),("Needs you",G.AMBER)],[("● ",G.GREEN),("Update the agent docs for the Spine  ",G.CODE),("Done · 2 files to review",G.GREEN)]])],
  [("SPC SPC","Find a file"),("SPC a n","New task"),("SPC o p","File tree"),("SPC p p","Switch project")],needs=True)
tui=f'<div style="display:flex;gap:16px;align-items:flex-start">{tterm(g,"TUI","the same home buffer, launched in ~/code/minga")}</div>'
note=f'<div style="margin-bottom:10px">{shell_snip("~/code/minga","minga .")}</div><code>minga</code> with no arguments inside a project means <code>minga .</code>. Shown when this project has no saved session; with one, Minga restores it instead. 1 to 9 open a recent file; j/k and ↩ work on any row. The home buffer is a resting view: nothing to close, SPC p h always brings it back.'
write("Batch6_start_open_dir_home.dc.html",board("Batch 6: opening a project directory",("minga .  ·  first open, no saved session","the folder becomes the project root and Minga shows its home: where you were, what Minga is doing, what to do next"),mac,"",tui,
 [("1 to 9","edit.plain (that recent file)"),("↩ on a file row","edit.plain"),("↩ on a task row","minga.conversation (that task)"),("SPC SPC","files.project_find"),("SPC a n","minga.task.new"),("SPC o p","files.tree"),("SPC p p","start.project_switcher"),("SPC p h","start.open_dir.home (from anywhere, later)")],note))

# ===== 2. start.open_dir.restored
def pane(codehtml,title_file,active=True):
    bc="" if active else "opacity:0.78;"
    foot="" if active else f'<div style="height:22px;flex:none;display:flex;align-items:center;padding:0 10px;font-size:11.5px;color:#8f8d88;background:#232429;border-top:1px solid rgba(255,255,255,0.06)">{title_file}</div>'
    return f'<div style="flex:1;min-width:0;display:flex;flex-direction:column;{bc}"><div style="flex:1;min-height:0;overflow:hidden;padding-top:6px;{MONO};font-size:13px;color:#c9c7c2">{codehtml}</div>{foot}</div>'
RET=[(37,f'{kw("def")} retryable?(%{{status: 429}} = error), {kw("do")}:'),(38,'  not usage_limit?(error)'),(39,''),(40,f'{kw("def")} retryable?(%{{status: s}}) {kw("when")} s &gt;= 500,'),(41,f'  {kw("do")}: true'),(42,''),(43,f'{kw("def")} retryable?(_), {kw("do")}: false'),(44,''),(45,f'{kw("defp")} usage_limit?(%{{body: b}}), {kw("do")}:'),(46,'  b["type"] == "usage_limit_reached"')]
rcode="\n".join(f'<div class="ln"><span class="num" style="color:#7a7c85">{n}</span><span class="sign"></span><span class="bar"></span><span class="code">{t}</span></div>' for n,t in RET)
split=f'<div style="flex:1;min-height:0;display:flex">{pane(code(10,minga="on"),"chrome_state.ex  lib/minga_editor/session")}<div style="width:1px;background:rgba(255,255,255,0.08)"></div>{pane(rcode,"retry.ex",active=False)}</div>'
ec=echo(f'<span style="color:#dcdce2">Restored 3 files from last time.</span><span style="flex:1"></span>{hint("SPC q n","start fresh")}{sp()}{hint("SPC p h","project home")}')
mac=macwin(split+ec+modeline(minga=WORKING.replace("Minga editing retry.ex 2/3","Minga editing retry.ex 2/3")),h=430)
g=G.Grid(TW,TH)
for i in range(11):
    n,t=TC[i]; g.put(i,0,f"{n:>5} ",G.DIM); g.put(i,7,("╳" if n==234 else "┃") if 234<=n<=237 else " ",G.PURPLED); g.put(i,9,t[:52],G.CODE)
    if i<len(RET):
        n2,_=RET[i]; plain=["def retryable?(%{status: 429} = error), do:","  not usage_limit?(error)","","def retryable?(%{status: s}) when s >= 500,","  do: true","","def retryable?(_), do: false","","defp usage_limit?(%{body: b}), do:",'  b["type"] == "usage_limit_reached"'][i]
        g.put(i,64,"│","#3a3c44"); g.put(i,66,f"{n2:>3} ",G.DIM); g.put(i,70,plain[:56],"#9a988f")
g.fill(11,64,64,"#232429"); g.put(11,65,"retry.ex",G.DIM,"#232429")
g.fill(13,0,TW,"#1b1c21"); g.segs(13,1,[("Restored 3 files from last time.",G.TXT,"#1b1c21"),("   SPC q n",G.TXT,"#1b1c21"),(" start fresh   ",G.DIM,"#1b1c21"),("SPC p h",G.TXT,"#1b1c21"),(" project home",G.DIM,"#1b1c21")])
tmode(g,18,"NORMAL",[(" chrome_state.ex ",G.TXT,"#30313a","b"),(" main +11 ",G.SUB,"#25262c"),(" ◐ Minga editing retry.ex 2/3 ",G.PURPLE,"#25262c")])
write("Batch6_start_open_dir_restored.dc.html",board("Batch 6: opening a project with a saved session",("minga .  ·  a saved session exists","files, splits and cursors come back as you left them; the echo line offers a clean start"),mac,"",tterm(g,"TUI","same restore; the third file is open but hidden in the buffer list"),
 [("SPC q n","start.open_dir.home (closes the restored files, keeps Minga's tasks)"),("SPC p h","start.open_dir.home (opens home in this window; files stay open)"),("(any other key)","edit.working (the echo fades on the next keystroke)")],
 "The session stores open files, cursors, scroll and the active buffer. Minga's tasks are not part of the window session; they keep running, so the modeline still says what Minga is doing. Start fresh never discards unsaved edits or Minga's unreviewed changes."))

# ===== 3. start.open_dir.subdir
def frow(name,path,sel=False):
    bg="background:rgba(26,149,242,0.85);color:#fff;" if sel else ""
    return f'<div style="height:24px;display:flex;align-items:center;gap:10px;padding:0 14px;{bg}font-size:12.5px"><span style="{MONO};color:{"#fff" if sel else "#ecebe8"}">{name}</span><span style="{MONO};font-size:11.5px;color:{"#dbe8fb" if sel else "#7a7c85"}">{path}</span></div>'
files=frow("retry.ex","lib/minga_agent",True)+frow("session.ex","lib/minga_agent")+frow("usage_limit.ex","lib/minga_agent")+frow("runtime.ex","lib/minga_agent")+frow("provider_registry.ex","lib/minga_agent")
body=f'<div style="height:30px;display:flex;align-items:center;gap:8px;padding:0 14px;font-size:13px;border-bottom:1px solid rgba(255,255,255,0.05)"><span style="color:#8f8d88">Find file ›</span><span style="{MONO};color:#6cb8f5">lib/minga_agent/</span><span style="width:2px;height:15px;background:#6cb8f5"></span><span style="flex:1"></span><span style="color:#7a7c85;font-size:11.5px">38 of 1,204</span></div><div style="padding:4px 0">{files}</div>'
dr=drawer(("*find-file*","Find file"),'',f'{hint("↩","open")}{sp()}{hint("⌃V","split")}{sp()}{hint("esc","project home")}',body,h=200)
homedim=f'<div style="opacity:0.4">{head("minga","~/code/minga","main · 11 changed")}</div>'
ec=echo(f'<span style="color:#dcdce2">Project root: <span style="{MONO}">~/code/minga</span> (found <span style="{MONO}">mix.exs</span> above <span style="{MONO}">lib/minga_agent</span>).</span>')
mac=macwin(home_area(homedim)+dr+ec+home_ml(file="*find-file*"),title="minga",path="~/code/minga",h=430)
g=G.Grid(TW,TH)
g.put(1,4,"minga  ~/code/minga","#55575f",None,"b")
d=G.Grid(TW,10,bg=SURF); d.box(0,0,10,TW,G.FOCUS,SURF,title=[("*find-file*",G.SUB),("  Find file",G.TXT,"b")],bottom=[("↩",G.TXT),(" open  ",G.DIM),("⌃V",G.TXT),(" split  ",G.DIM),("esc",G.TXT),(" project home",G.DIM)])
d.segs(1,2,[("Find file › ",G.DIM),("lib/minga_agent/",G.BLUE),("▏",G.BLUE)]); d.put(1,TW-14,"38 of 1,204",G.DIM)
SEL="#2c3e57"
for i,(f,p) in enumerate([("retry.ex","lib/minga_agent"),("session.ex","lib/minga_agent"),("usage_limit.ex","lib/minga_agent"),("runtime.ex","lib/minga_agent"),("provider_registry.ex","lib/minga_agent")]):
    r=3+i; bg=SEL if i==0 else None
    if i==0: d.bgrow(r,1,TW-2,SEL); d.put(r,1,"▌",G.BLUE,SEL)
    d.put(r,3,f,G.TXT,bg,"b" if i==0 else None); d.put(r,4+len(f),p,G.SUB if i==0 else G.DIM,bg)
blit(g,d,6)
g.fill(16,0,TW,"#1b1c21"); g.put(16,1,"Project root: ~/code/minga (found mix.exs above lib/minga_agent).",G.TXT,"#1b1c21")
tmode(g,18,"NORMAL",[(" *find-file* ",G.TXT,"#30313a","b"),(" main +11 ",G.SUB,"#25262c")]," 1:1 ")
note=f'<div style="margin-bottom:10px">{shell_snip("~/code/minga","minga lib/minga_agent")}</div>A subdirectory never becomes its own root: Minga walks up to the nearest project marker and opens the switcher scoped to the folder you named. The prompt is editable, so backspace widens to the whole project.'
write("Batch6_start_open_dir_subdir.dc.html",board("Batch 6: opening a folder inside a project",("minga lib/minga_agent","the root is found above; the switcher opens already filtered to the folder you named"),mac,"",tterm(g,"TUI","same switcher, prefilled prompt"),
 [("↩","edit.plain (that file)"),("⌃V","windows.split (open in a split)"),("(typing)","files.switcher (the filter narrows or widens)"),("esc","start.open_dir.home")],note))

# ===== 4. start.open_dir.not_project
inner=(head("notes","~/Downloads/notes","Not a project: no .git, mix.exs, package.json or other marker here.")
       +f'<div style="margin-top:6px;font-size:12.5px;color:#a5a39e">Minga uses this folder as the root for now.</div>'
       +sec("Recent in this folder")+'<div style="padding:0 10px;font-size:12.5px;color:#7a7c85">Nothing opened here yet.</div>'
       +acts_line(("SPC o p","File tree"),("SPC SPC","Find a file"),("SPC p a","Remember as a project"),("SPC a n","New task"),sel_first=True))
mac=macwin(home_area(inner)+home_ml(right="nogit"),title="notes",path="~/Downloads/notes",h=470)
g=tui_home("notes","~/Downloads/notes","Not a project: no .git, mix.exs, package.json or other marker here.",
  [("Recent in this folder",[[("Nothing opened here yet.",G.DIM)]])],
  [("SPC o p","File tree"),("SPC SPC","Find a file"),("SPC p a","Remember as a project"),("SPC a n","New task")],git=False,line2="Minga uses this folder as the root for now.",sel_first=True)
note=f'<div style="margin-bottom:10px">{shell_snip("~/Downloads/notes","minga .",branch="")}</div>No marker is not an error, so there is no warning colour. Project search, the file tree and Minga still work inside the folder (git segments appear only if it is a repository); SPC p a adds it to known projects so it shows up in SPC p p.'
write("Batch6_start_open_dir_not_project.dc.html",board("Batch 6: opening a folder that is not a project",("minga .  ·  in a folder with no project marker","the folder is the root; home says so in one line and offers the file tree"),mac,"",tterm(g,"TUI","same home, no git segment in the modeline"),
 [("SPC o p (preselected)","files.tree"),("SPC SPC","files.project_find"),("SPC p a","start.project_switcher (after adding)"),("SPC a n","minga.task.new"),("SPC p h","start.open_dir.not_project (from anywhere, later)")],note))

# ===== 5. start.empty redraw
proj=(num_row(1,"minga","~/code/self/minga","today · ◐ 1 working",sel=True)+num_row(2,"headsdown","~/code/work/headsdown","yesterday")
      +num_row(3,"dfiles","~/code/self/dfiles","3 d ago")+num_row(4,"notes","~/Downloads/notes","last week"))
inner=(head("Minga","~","No project here.")+sec("Recent projects")+proj
       +acts_line(("SPC p p","Switch project"),("SPC f f","Find a file"),("SPC p a","Add a project")))
mac=macwin(home_area(inner)+home_ml(right="nogit"),title="*home*",path="~",h=470)
g=tui_home("Minga","~","No project here.",
  [("Recent projects",[[("1 ",G.PURPLE,None,"b"),("minga ",G.TXT),("~/code/self/minga",G.DIM),("   today · ",G.DIM),("◐ 1 working",G.PURPLE)],[("2 ",G.PURPLE,None,"b"),("headsdown ",G.TXT),("~/code/work/headsdown",G.DIM),("   yesterday",G.DIM)],[("3 ",G.PURPLE,None,"b"),("dfiles ",G.TXT),("~/code/self/dfiles",G.DIM),("   3 d ago",G.DIM)],[("4 ",G.PURPLE,None,"b"),("notes ",G.TXT),("~/Downloads/notes",G.DIM),("   last week",G.DIM)]])],
  [("SPC p p","Switch project"),("SPC f f","Find a file"),("SPC p a","Add a project")],git=False)
note=f'<div style="margin-bottom:10px">{shell_snip("~","minga",branch="")}</div>Outside any project, home lists recent projects instead of files. A project with Minga still working shows it, so you can go straight back. Opening a project restores its session if it has one.'
write("Batch6_start_empty.dc.html",board("Batch 6: launched outside any project",("minga  ·  in your home folder","home lists recent projects, numbered"),mac,"",tterm(g,"TUI","same list"),
 [("1 to 9","start.open_dir.restored (or start.open_dir.home when that project has no saved session)"),("↩ on a row","start.open_dir.restored"),("SPC p p","start.project_switcher"),("SPC f f","files.switcher"),("SPC p a","start.project_switcher (after adding)")],note))

