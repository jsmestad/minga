import os as _os
TOOLS = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))
BOARDS = _os.environ.get("BOARDS_DIR", _os.path.join(TOOLS, "..", "boards"))  # committed boards, read only
OUT_DIR = _os.environ.get("OUT_DIR", _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "out"))
_os.makedirs(OUT_DIR, exist_ok=True)
import os, subprocess
S = TOOLS
src=open(S+"/batch1/b1.py").read()
head=src[:src.index("# ===== 1.")]
os.environ.setdefault("OUT_DIR",S+"/batch3/out")
exec(head)
OUT=os.environ["OUT_DIR"]; os.makedirs(OUT,exist_ok=True)

SURF="#23242a"
def seg_state(lab,txt,col): return f'<span style="display:flex;align-items:center;gap:6px;color:{col}">{B.st(lab,12)}{txt}</span>'
def echo(content,border="rgba(255,255,255,0.07)"):
    return f'<div style="flex:none;min-height:28px;display:flex;align-items:center;gap:10px;padding:5px 14px;background:#1b1c21;border-top:1px solid {border};font-size:12.5px">{content}</div>'
def sp(n=10): return f'<span style="width:{n}px;display:inline-block"></span>'
def tmline(g,r,mode,parts,right):
    g.fill(r,0,g.w,"#25262c")
    pill={"NORMAL":("#12304a",G.BLUE),"INSERT":("#12301a",G.GREEN),"TERM":("#12301a",G.GREEN)}[mode]
    x=g.segs(r,0,[(f" {mode} ",pill[0],pill[1],"b"),(" ",None,"#25262c")])
    for p in parts: x=g.segs(r,x,[p,(" ",None,"#25262c")])
    if right: g.segs(r,g.w-len(right),[(right,G.TXT,"#30313a")])
def blit(dst,src,r0,c0=0):
    for y in range(src.h):
        for x in range(src.w):
            if 0<=r0+y<dst.h and 0<=c0+x<dst.w: dst.c[r0+y][c0+x]=list(src.c[y][x])

# terminal block helpers (macOS)
def tline(text,col="#c9c7c2",glyph="",strand="",bg="",right=""):
    st=f'<span style="width:16px;flex:none;display:flex;justify-content:center">{glyph}</span>'
    au=f'<span style="width:10px;height:22px;flex:none;margin-right:8px;display:flex;justify-content:center">{strand}</span>'
    rt=f'<span style="flex:1"></span><span style="color:#8f8d88;font-size:11.5px;padding-right:14px">{right}</span>' if right else ""
    return f'<div style="height:22px;display:flex;align-items:center;padding-left:8px;background:{bg};color:{col};white-space:pre">{st}{au}<span>{text}</span>{rt}</div>'
YOU='<svg width="10" height="18" viewBox="0 0 10 18"><path d="M5 0 L5 18" stroke="#4f9fe0" stroke-width="1.5"/></svg>'
RULE='<div style="height:1px;background:rgba(255,255,255,0.06);margin:2px 0 2px 34px"></div>'
PROMPT='<span style="color:#6cb8f5">~/code/minga</span> <span style="color:#b98cf0">main</span> <span style="color:#7fbf7a">❯</span> '
def tmodeline(mode,name,cwd,state,right="zsh 4182"):
    pill={"TERM":("#7fbf7a","rgba(127,191,122,0.2)"),"NORMAL":("#6cb8f5","rgba(26,149,242,0.22)")}[mode]
    p=f'<span style="display:flex;align-items:center;padding:0 10px;margin:0 4px 0 6px;height:18px;border-radius:9px;background:{pill[1]};color:{pill[0]};font-weight:700;font-size:10.5px;letter-spacing:0.04em">{mode}</span>'
    return f'''<div style="height:26px;flex:none;display:flex;align-items:center;background:#25262c;border-top:1px solid rgba(255,255,255,0.07);font-size:12px;color:#a5a39e">{p}{seg(f'<span style="color:#ecebe8;font-weight:600">{name}</span>')}{seg(cwd)}{seg(state) if state else ""}<span style="flex:1"></span>{seg(f'<span style="font-family:ui-monospace,monospace;font-size:11.5px">{right}</span>',"padding-right:14px")}</div>'''

# ===== 1. errors.crash_reconnect
dimcode=f'<div style="flex:1;min-height:0;opacity:0.55">{editor_area(code(10))}</div>'
while_ml=modeline(file="chrome_state.ex",minga=seg_state("Waiting",'<span style="color:#a5a39e">Reconnecting to the editor core · your typing is kept</span>',"#a5a39e"),right=None)
after_echo=echo(f'{B.st("Done",12)}<span style="color:#dcdce2;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0">Minga\'s session restarted after a crash; your files and tasks are intact.</span><span style="flex:1"></span><span style="white-space:nowrap">{hint("SPC b m","log")}{sp()}{hint("esc","dismiss")}</span>')
wh=macwin(dimcode+while_ml,w=684)
af=macwin(editor_area(code(10))+after_echo+modeline(file="chrome_state.ex",minga=seg_state("Working",'<span style="color:#b98cf0">Minga</span> <span style="color:#c9c7c2">editing 2/3</span>',"#b98cf0"),right=None),w=684)
mac=f'<div style="display:flex;gap:24px"><div><div class="lab"><b>While it reconnects</b>  last frame stays on screen, keys are queued</div>{wh}</div><div><div class="lab"><b>After</b>  one line in the echo area, then it fades</div>{af}</div></div>'
def half(state):
    g=G.Grid(62,TH); tcode(g,15,dim=(state=="while"),width=62)
    if state=="while":
        tmline(g,18,"NORMAL",[(" chrome_state.ex ",G.TXT,"#30313a","b"),(" ○ Reconnecting · typing kept ",G.SUB,"#25262c")],"")
    else:
        g.fill(17,0,62,"#1b1c21"); g.segs(17,1,[("● ",G.GREEN,"#1b1c21"),("Session restarted after a crash; files and tasks intact.",G.TXT,"#1b1c21")])
        tmline(g,18,"NORMAL",[(" chrome_state.ex ",G.TXT,"#30313a","b"),(" ◐ Minga 2/3 ",G.PURPLE,"#25262c")],"")
        g.fill(19,0,62,"#1e1f24"); g.segs(19,1,[("SPC b m",G.TXT),(" log   ",G.DIM),("esc",G.TXT),(" dismiss",G.DIM)])
    return g
tui=f'<div style="display:flex;gap:14px">{tterm(half("while"),"TUI","while")}{tterm(half("after"),"","after")}</div>'
write("Batch3_errors_crash_reconnect.dc.html",board("Batch 3: the core restarted",("Crash and reconnect","the supervisor restarted part of Minga; nothing you typed or own is lost, and Minga says so plainly"),mac,"",tui,
 [("(reconnected)","edit.plain, with the one-line notice in the echo area"),("SPC b m","files.messages (what restarted, and why)"),("esc","edit.plain (dismiss the notice)")],
 "While reconnecting the frontend keeps the last committed frame and queues keys; nothing steals focus. The notice names what restarted only when it was more than the editor core (for example \"Minga's agent session restarted\")."))

# ===== 2. errors.lsp_failed
ml=modeline(file="chrome_state.ex",minga=seg_state("Failed",'<span style="color:#e5707a">elixir-ls failed</span>',"#e5707a"),right="Elixir")
ec=echo(f'{B.st("Failed",12)}<span style="color:#dcdce2">elixir-ls failed to start: <span style="font-family:ui-monospace,monospace;font-size:12px">erl</span> not found in PATH. Editing continues without diagnostics.</span><span style="flex:1"></span>{hint("SPC c l r","restart")}{sp()}{hint("SPC c l i","log")}{sp()}{hint("SPC c l I","manage tools")}{sp()}{hint("esc","dismiss")}',border="rgba(229,112,122,0.45)")
mac=macwin(editor_area(code(10))+ec+ml)
g=G.Grid(TW,TH); tcode(g,15,dim=False)
g.fill(16,0,TW,"#1b1c21")
g.segs(16,1,[("◆ ",G.RED,"#1b1c21"),("elixir-ls failed to start: erl not found in PATH. Editing continues without diagnostics.",G.TXT,"#1b1c21")])
g.fill(17,0,TW,"#1b1c21"); g.segs(17,3,[("SPC c l r",G.TXT,"#1b1c21"),(" restart   ",G.DIM,"#1b1c21"),("SPC c l i",G.TXT,"#1b1c21"),(" log   ",G.DIM,"#1b1c21"),("SPC c l I",G.TXT,"#1b1c21"),(" manage tools   ",G.DIM,"#1b1c21"),("esc",G.TXT,"#1b1c21"),(" dismiss",G.DIM,"#1b1c21")])
tmline(g,18,"NORMAL",[(" chrome_state.ex ",G.TXT,"#30313a","b"),(" ◆ elixir-ls failed ",G.RED,"#3a2328","b")]," 240:31 ")
write("Batch3_errors_lsp_failed.dc.html",board("Batch 3: a language server failed",("elixir-ls failed to start","editing carries on; the modeline keeps the failure visible after the notice fades"),mac,"",tterm(g,"TUI","same notice in the echo area, failure segment in the modeline"),
 [("SPC c l r","edit.plain (restarts the server; the segment shows Working, then clears)"),("SPC c l i","code.lsp_info (the server's log and why it failed)"),("SPC c l I","code.lsp_tools (install or point Minga at the tool)"),("esc (Normal)","edit.plain (dismiss the notice; the modeline segment stays until it is fixed)")],
 "The actions are leader keys, not bare letters: a notice never captures keys you are typing, and r or l stay Vim. The modeline segment replaces the diagnostics count while the server is down, so a clean count is never a lie."))

# ===== 3. errors.config_error
ml=modeline(file="*scratch*",minga=seg_state("Failed",'<span style="color:#e5707a">config: defaults</span>',"#e5707a"),right=None,pos="1:1")
ec=echo(f'{B.st("Failed",12)}<span style="color:#dcdce2"><span style="font-family:ui-monospace,monospace;font-size:12px;color:#8fc7ff;text-decoration:underline">~/.config/minga/config.exs:14</span> undefined function <span style="font-family:ui-monospace,monospace;font-size:12px">set/3</span>. Minga opened with the defaults.</span><span style="flex:1"></span>{hint("SPC f p","open at line 14")}{sp()}{hint("SPC h r","reload")}{sp()}{hint("esc","dismiss")}',border="rgba(229,112,122,0.45)")
empty=f'<div style="flex:1;min-height:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:8px;color:#8f8d88;font-size:13px"><span style="font-family:\'Instrument Serif\',serif;font-style:italic;font-size:34px;color:#7a7c85">minga</span><span>SPC SPC find a file · SPC p p switch project</span></div>'
mac=macwin(empty+ec+ml,title="*scratch*",path="")
g=G.Grid(TW,TH)
g.put(6,58,"minga",G.DIM,None,"i"); g.put(8,44,"SPC SPC find a file · SPC p p switch project",G.FAINT)
g.fill(16,0,TW,"#1b1c21")
x=g.segs(16,1,[("◆ ",G.RED,"#1b1c21"),("~/.config/minga/config.exs:14",G.BLUE,"#1b1c21","bu"),(" undefined function set/3. Minga opened with the defaults.",G.TXT,"#1b1c21")])
g.fill(17,0,TW,"#1b1c21"); g.segs(17,3,[("SPC f p",G.TXT,"#1b1c21"),(" open at line 14   ",G.DIM,"#1b1c21"),("SPC h r",G.TXT,"#1b1c21"),(" reload   ",G.DIM,"#1b1c21"),("esc",G.TXT,"#1b1c21"),(" dismiss",G.DIM,"#1b1c21")])
tmline(g,18,"NORMAL",[(" *scratch* ",G.TXT,"#30313a","b"),(" ◆ config: defaults ",G.RED,"#3a2328","b")]," 1:1 ")
write("Batch3_errors_config_error.dc.html",board("Batch 3: config failed to load",("config.exs failed","Minga still opens, with the defaults, and points at the exact line"),mac,"",tterm(g,"TUI","the path is an OSC 8 link; the segment stays until the config loads"),
 [("SPC f p","edit.plain (config.exs, cursor on line 14)"),("SPC h r","edit.plain (reloads; the notice and segment clear on success, or update with the new error)"),("esc (Normal)","edit.plain (dismiss the notice; the segment stays)")],
 "The modeline segment \"config: defaults\" keeps the state honest after the notice fades. The same notice appears when a reload fails while you work, without replacing settings that already loaded."))

# ===== 4. terminal.drawer.normal
blk=(tline(PROMPT+'<span style="color:#ecebe8">mix test test/minga_agent</span>',glyph=B.st("Done",11),strand=YOU,right="exit 0 · 4.1 s")+
     tline("Finished in 3.9 seconds (2.1s async, 1.8s sync)",col="#a5a39e",strand=YOU)+tline("214 tests, 0 failures",col="#7fbf7a",strand=YOU)+RULE+
     tline(PROMPT+'<span style="color:#ecebe8">mix test --only integration</span>',glyph=B.st("Working",11),strand=YOU,right="running · 38 s",bg="rgba(26,149,242,0.10)")+
     tline("Compiling 3 files (.ex)",col="#a5a39e",strand=YOU,bg="rgba(26,149,242,0.10)")+tline('<span style="background:rgba(185,140,240,0.28)">  test editor opens a file and saves it (EditorIntegrationTest)</span>',col="#c9c7c2",strand=YOU))
newl='<div style="position:absolute;left:50%;bottom:8px;transform:translateX(-50%);padding:2px 12px;border-radius:10px;background:#30313a;color:#dcdce2;font-size:11.5px;box-shadow:0 2px 8px rgba(0,0,0,0.4)">↓ 12 new lines</div>'
dr=drawer(("*terminal 1*","Terminal"),'<span style="color:#8f8d88">~/code/minga</span>',f'{hint("]] [[","commands")}{sp()}{hint("yic","copy output")}{sp()}{hint("i","terminal")}{sp()}{hint("q","hide")}',f'<div style="position:absolute;inset:0;padding-top:4px;font-family:ui-monospace,monospace;font-size:12.5px">{blk}</div>{newl}',h=228)
mac=macwin(editor_area(code(5,dim=True))+dr+tmodeline("NORMAL","*terminal 1*","~/code/minga",seg_state("Working","mix test --only integration","#b98cf0")))
g=G.Grid(TW,TH); tcode(g,5,dim=True)
d=G.Grid(TW,13,bg=SURF)
d.box(0,0,13,TW,G.FOCUS,SURF,title=[("*terminal 1*",G.SUB),("  Terminal",G.TXT,"b"),("  ~/code/minga",G.DIM)],bottom=[("]] [[",G.TXT),(" commands  ",G.DIM),("yic",G.TXT),(" copy output  ",G.DIM),("i",G.TXT),(" terminal  ",G.DIM),("q",G.TXT),(" hide",G.DIM)])
def trow(r,glyph,gc,text,tc,right="",bg=None):
    if bg: d.bgrow(r,1,TW-2,bg)
    d.put(r,2,glyph,gc,bg); d.put(r,4,"│","#4f9fe0",bg); d.put(r,6,text,tc,bg)
    if right: d.put(r,TW-2-len(right),right,G.DIM,bg)
trow(1,"●",G.GREEN,"~/code/minga main ❯ mix test test/minga_agent",G.TXT,"exit 0 · 4.1 s")
trow(2," ",G.TXT,"Finished in 3.9 seconds (2.1s async, 1.8s sync)",G.SUB); trow(3," ",G.TXT,"214 tests, 0 failures",G.GREEN)
d.put(4,6,"─"*60,"#33353d")
CB="#1f2b3a"
trow(5,"◐",G.PURPLED,"~/code/minga main ❯ mix test --only integration",G.TXT,"running · 38 s",CB)
trow(6," ",G.TXT,"Compiling 3 files (.ex)",G.SUB,"",CB)
trow(7," ",G.TXT,"  test editor opens a file and saves it (EditorIntegrationTest)",G.CODE,"","#3a2f4d")
d.put(10,57," ↓ 12 new lines ",G.TXT,"#30313a")
blit(g,d,5)
tmline(g,18,"NORMAL",[(" *terminal 1* ",G.TXT,"#30313a","b"),(" ~/code/minga ",G.SUB,"#25262c"),(" ◐ mix test --only integration ",G.PURPLE,"#25262c")]," zsh 4182 ")
write("Batch3_terminal_drawer_normal.dc.html",board("Batch 3: the terminal in Normal mode",("⌃\\ ⌃N in the terminal drawer","read and copy the scrollback while the command keeps running; the view holds still"),mac,"",tterm(g,"TUI","same drawer, the new-lines marker sits at the bottom of the scrollback"),
 [("i, a, or ↩ on the live prompt","terminal.drawer (back to TERM, scrolled to the bottom)"),("]] / [[","terminal.drawer.normal (next / previous command block)"),("yic / yac","terminal.drawer.normal (copies the output / whole block)"),("↩ on a failed block","terminal.failed_block.menu"),("q","edit.plain (hides the drawer; the shell keeps running)"),("SPC o t","edit.plain (same as q)")],
 "\"↓ 12 new lines\" appears instead of scrolling while you read; G or i jumps to the bottom. Vim motions, / search and visual selection work on the scrollback; nothing you type reaches the shell until i."))

# ===== 5. terminal.exited
blk=(tline(PROMPT+'<span style="color:#ecebe8">iex -S mix</span>',glyph=B.st("Done",11),strand=YOU,right="exit 0 · 14 min")+
     tline("Erlang/OTP 29 [erts-16.0] [source] [64-bit] [smp:8:8]",col="#a5a39e",strand=YOU)+tline('iex(1)&gt; Minga.Config.get(:theme)',col="#c9c7c2",strand=YOU)+
     tline(":catppuccin_frappe",col="#a6d189",strand=YOU)+tline('iex(2)&gt; System.halt()',col="#c9c7c2",strand=YOU))
bar=f'<div style="flex:none;height:30px;display:flex;align-items:center;gap:10px;padding:0 16px;background:{SURF};border-top:1px solid rgba(255,255,255,0.08);font-size:12.5px">{B.st("Waiting",12)}<span style="color:#dcdce2">Shell exited (code 0)</span><span style="color:#7a7c85">·</span>{hint("↩","restart")}{sp(6)}{hint("q","close")}<span style="flex:1"></span><span style="color:#8f8d88;font-size:11.5px">scrollback kept</span></div>'
mac=macwin(f'<div style="flex:1;min-height:0;padding-top:6px;font-family:ui-monospace,monospace;font-size:12.5px;opacity:0.75">{blk}</div>'+bar+tmodeline("NORMAL","*terminal 2*","~/code/minga",'<span style="color:#a5a39e">exited 0</span>',right="zsh"),title="*terminal 2*",path="~/code/minga")
g=G.Grid(TW,TH)
rows=[("●",G.GREEN,"~/code/minga main ❯ iex -S mix",G.TXT,"exit 0 · 14 min"),(" ",G.TXT,"Erlang/OTP 29 [erts-16.0] [source] [64-bit] [smp:8:8]",G.DIM,""),(" ",G.TXT,"iex(1)> Minga.Config.get(:theme)",G.SUB,""),(" ",G.TXT,":catppuccin_frappe",G.GREEN,""),(" ",G.TXT,"iex(2)> System.halt()",G.SUB,"")]
for i,(gl,gc,t,tc,rt) in enumerate(rows):
    g.put(1+i,1,gl,gc); g.put(1+i,3,"│","#3b5f80"); g.put(1+i,5,t,tc)
    if rt: g.put(1+i,TW-1-len(rt),rt,G.DIM)
g.fill(16,0,TW,SURF); g.segs(16,1,[("○ ",G.SUB,SURF),("Shell exited (code 0)",G.TXT,SURF),("  ·  ",G.FAINT,SURF),("↩",G.TXT,SURF),(" restart   ",G.DIM,SURF),("q",G.TXT,SURF),(" close",G.DIM,SURF)])
g.put(16,TW-17,"scrollback kept",G.FAINT,SURF)
tmline(g,18,"NORMAL",[(" *terminal 2* ",G.TXT,"#30313a","b"),(" ~/code/minga ",G.SUB,"#25262c"),(" exited 0 ",G.SUB,"#25262c")]," zsh ")
write("Batch3_terminal_exited.dc.html",board("Batch 3: the shell exited",("A terminal window after its shell ended","the buffer keeps its scrollback so nothing you read disappears"),mac,"",tterm(g,"TUI","same bar above the modeline"),
 [("↩","terminal.window (a fresh shell in the same buffer and cwd)"),("q","edit.plain (closes the buffer; the window shows the previous buffer)"),("yic / /","terminal.exited (copy and search still work on the scrollback)")],
 "Typing exit in the drawer still closes the drawer and buffer at once (terminal.md). This state is for a shell that ends any other way, and for SPC o T windows, where closing would rearrange your layout without asking."))

# ===== 6. terminal.window
iex=(tline(PROMPT+'<span style="color:#ecebe8">iex -S mix</span>',glyph=B.st("Working",11),strand=YOU,right="running · 2 min")+
     tline("Erlang/OTP 29 [erts-16.0] [source] [64-bit] [smp:8:8]",col="#a5a39e",strand=YOU)+tline("Interactive Elixir (1.20.5) - press Ctrl+C to exit",col="#a5a39e",strand=YOU)+
     tline('iex(1)&gt; MingaEditor.UI.Theme.default()',col="#c9c7c2",strand=YOU)+tline(":catppuccin_frappe",col="#a6d189",strand=YOU)+tline('iex(2)&gt; <span style="background:#c9c7c2;color:#1e1f24"> </span>',col="#c9c7c2",strand=YOU))
def srow(sel,name,info,glyph):
    bg="background:rgba(26,149,242,0.85);color:#fff;" if sel else ""
    return f'<div style="height:24px;display:flex;align-items:center;gap:10px;padding:0 14px;{bg}font-size:12.5px">{glyph}<span style="font-family:ui-monospace,monospace;font-weight:{600 if sel else 400}">{name}</span><span style="color:{"#e6eefc" if sel else "#8f8d88"}">{info}</span></div>'
sw=f'''<div style="position:absolute;inset:0;font-size:12.5px">
<div style="height:28px;display:flex;align-items:center;gap:8px;padding:0 14px;border-bottom:1px solid rgba(255,255,255,0.06)"><span style="color:#6cb8f5">Find file ›</span><span style="color:#ecebe8">term</span><span style="width:2px;height:15px;background:#6cb8f5"></span><span style="flex:1"></span><span style="color:#8f8d88;font-size:11.5px">2 of 1,206</span></div>
<div style="padding:4px 14px 2px;color:#8f8d88;font-size:11px">Terminals</div>
{srow(True,"*terminal 2*","~/code/minga · iex -S mix running",B.st("Working",12))}{srow(False,"*terminal 1*","~/code/minga · exit 0 · drawer",B.st("Done",12))}</div>'''
dr=drawer(("*find-file*","Switch"),'',f'{hint("↩","open")}{sp()}{hint("⌃V","split")}{sp()}{hint("esc","close")}',sw,h=136)
mac=macwin(f'<div style="flex:1;min-height:0;padding-top:6px;font-family:ui-monospace,monospace;font-size:12.5px">{iex}</div>'+dr+tmodeline("TERM","*terminal 2*","~/code/minga",seg_state("Working","iex -S mix","#b98cf0"),right="zsh 4421"),title="*terminal 2*",path="~/code/minga")
g=G.Grid(TW,TH)
rows=[("◐",G.PURPLED,"~/code/minga main ❯ iex -S mix",G.TXT,"running · 2 min"),(" ",G.TXT,"Erlang/OTP 29 [erts-16.0] [source] [64-bit] [smp:8:8]",G.DIM,""),(" ",G.TXT,"Interactive Elixir (1.20.5) - press Ctrl+C to exit",G.DIM,""),(" ",G.TXT,"iex(1)> MingaEditor.UI.Theme.default()",G.SUB,""),(" ",G.TXT,":catppuccin_frappe",G.GREEN,""),(" ",G.TXT,"iex(2)> ",G.SUB,"")]
for i,(gl,gc,t,tc,rt) in enumerate(rows):
    g.put(i,1,gl,gc); g.put(i,3,"│","#4f9fe0"); g.put(i,5,t,tc)
    if rt: g.put(i,TW-1-len(rt),rt,G.DIM)
g.put(5,13," ",G.BG,G.TXT)
d=G.Grid(TW,7,bg=SURF)
d.box(0,0,7,TW,G.FOCUS,SURF,title=[("*find-file*",G.SUB),("  Switch",G.TXT,"b")],bottom=[("↩",G.TXT),(" open  ",G.DIM),("⌃V",G.TXT),(" split  ",G.DIM),("esc",G.TXT),(" close",G.DIM)])
d.segs(1,2,[("Find file › ",G.BLUE),("term",G.TXT),("▏",G.BLUE)]); d.put(1,TW-14,"2 of 1,206",G.DIM)
d.put(2,2,"Terminals",G.DIM)
SEL="#2c3e57"; d.bgrow(3,1,TW-2,SEL); d.put(3,1,"▌",G.BLUE,SEL); d.segs(3,3,[("◐ ",G.PURPLED,SEL),("*terminal 2*",G.TXT,SEL,"b"),("  ~/code/minga · iex -S mix running",G.SUB,SEL)])
d.segs(4,3,[("● ",G.GREEN),("*terminal 1*",G.CODE),("  ~/code/minga · exit 0 · drawer",G.DIM)])
blit(g,d,10)
tmline(g,18,"TERM",[(" *terminal 2* ",G.TXT,"#30313a","b"),(" ~/code/minga ",G.SUB,"#25262c"),(" ◐ iex -S mix ",G.PURPLE,"#25262c")]," zsh 4421 ")
write("Batch3_terminal_window.dc.html",board("Batch 3: a terminal in the window",("SPC o T","a terminal takes the current window, like any buffer; SPC , lists every terminal"),mac,"",tterm(g,"TUI","the switcher drawer over the window terminal"),
 [("⌃\\ ⌃N","terminal.drawer.normal (Normal mode on this terminal's scrollback)"),("SPC ,","files.switcher (terminals listed under Terminals with cwd and state)"),(":q","edit.plain (asks to kill the shell only if a job is running)"),("exit","terminal.exited")],
 "SPC o T always makes a new terminal (*terminal 2*); SPC o t keeps reusing the drawer's terminal. The switcher shows both, so you never lose one."))

# ===== 7. terminal.plain
plain=("".join(tline(t,col=c) for t,c in [('<span style="color:#7fbf7a">you@mba</span> <span style="color:#6cb8f5">~/code/minga</span> % mix test test/minga_agent',"#ecebe8"),("Finished in 3.9 seconds (2.1s async, 1.8s sync)","#a5a39e"),("214 tests, 0 failures","#7fbf7a"),('<span style="color:#7fbf7a">you@mba</span> <span style="color:#6cb8f5">~/code/minga</span> % git status -sb',"#ecebe8"),("## main...origin/main","#a5a39e"),(' M lib/minga_editor/session/chrome_state.ex',"#e5a87a"),('<span style="color:#7fbf7a">you@mba</span> <span style="color:#6cb8f5">~/code/minga</span> % <span style="background:#c9c7c2;color:#1e1f24"> </span>',"#ecebe8")]))
dr=drawer(("*terminal 1*","Terminal"),'<span style="color:#8f8d88">~/code/minga</span>',f'{hint("⌃\\ ⌃N","normal")}{sp()}{hint("SPC o t","hide")}',f'<div style="position:absolute;inset:0;padding-top:4px;font-family:ui-monospace,monospace;font-size:12.5px">{plain}</div>',h=200)
msg=f'''<div style="position:absolute;right:18px;top:44px;width:560px;border-radius:8px;border:1px solid rgba(255,255,255,0.12);background:#1b1c21;box-shadow:0 8px 24px rgba(0,0,0,0.45);font-size:12px;overflow:hidden">
<div style="padding:5px 12px;color:#8f8d88;font-size:11px;border-bottom:1px solid rgba(255,255,255,0.06)">Board note: the line it leaves in <span style="font-family:ui-monospace,monospace">*Messages*</span> (SPC b m), once</div>
<div style="padding:7px 12px;font-family:ui-monospace,monospace;font-size:11.5px;color:#c9c7c2;line-height:17px">[terminal] zsh has no shell integration, so command blocks are off. Source <span style="color:#8fc7ff;text-decoration:underline">minga-shell-integration.zsh</span> in ~/.zshrc to turn them on.</div></div>'''
mac=f'<div style="position:relative">{macwin(editor_area(code(6,dim=True))+dr+tmodeline("TERM","*terminal 1*","~/code/minga",""))}{msg}</div>'
g=G.Grid(TW,TH); tcode(g,6,dim=True)
d=G.Grid(TW,11,bg=SURF)
d.box(0,0,11,TW,G.FOCUS,SURF,title=[("*terminal 1*",G.SUB),("  Terminal",G.TXT,"b"),("  ~/code/minga",G.DIM)],bottom=[("⌃\\ ⌃N",G.TXT),(" normal  ",G.DIM),("SPC o t",G.TXT),(" hide",G.DIM)])
pl=[("you@mba ~/code/minga % mix test test/minga_agent",G.TXT),("Finished in 3.9 seconds (2.1s async, 1.8s sync)",G.SUB),("214 tests, 0 failures",G.GREEN),("you@mba ~/code/minga % git status -sb",G.TXT),("## main...origin/main",G.SUB),(" M lib/minga_editor/session/chrome_state.ex","#e5a87a"),("you@mba ~/code/minga % ",G.TXT)]
for i,(t,c) in enumerate(pl): d.put(1+i,2,t,c)
d.put(7,28," ",SURF,G.TXT)
blit(g,d,6)
tmline(g,18,"TERM",[(" *terminal 1* ",G.TXT,"#30313a","b"),(" ~/code/minga ",G.SUB,"#25262c")]," zsh 4182 ")
g.fill(19,0,TW,"#1e1f24"); g.segs(19,1,[("board note, *Messages* once: ",G.FAINT),("[terminal] zsh has no shell integration; command blocks are off.",G.DIM)])
write("Batch3_terminal_plain.dc.html",board("Batch 3: a terminal without shell integration",("SPC o t in a shell Minga cannot read","a plain terminal: no blocks, no glyphs, no nagging"),mac,"",tterm(g,"TUI","plain output; the one-time hint lives in *Messages*"),
 [("SPC o t","edit.plain (hides the drawer, shell keeps running)"),("⌃\\ ⌃N","terminal.drawer.normal (Normal mode works the same, minus ]] [[ and ic)"),("q (Normal)","edit.plain (hides the drawer)"),("SPC b m","files.messages (the one-time hint)")],
 "No gutter glyphs, no strands for command authorship, no block rules: Minga only draws what it knows. The hint is written to *Messages* once per shell and never shown as a notice."))

