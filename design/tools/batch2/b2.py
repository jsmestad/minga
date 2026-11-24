import os as _os
TOOLS = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))
BOARDS = _os.environ.get("BOARDS_DIR", _os.path.join(TOOLS, "..", "boards"))  # committed boards, read only
OUT_DIR = _os.environ.get("OUT_DIR", _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "out"))
_os.makedirs(OUT_DIR, exist_ok=True)
import os
S = TOOLS
src=open(S+"/batch1/b1.py").read()
head=src[:src.index("# ===== 1.")]
os.environ.setdefault("OUT_DIR",S+"/batch2/out")
exec(head)
OUT=os.environ["OUT_DIR"]; os.makedirs(OUT,exist_ok=True)

def mline(num,text,bg="",numcol="#7a7c85",mark=""):
    return f'<div class="ln" style="background:{bg}"><span class="num" style="color:{numcol}">{num}</span><span class="sign"></span><span class="bar">{mark}</span><span class="code">{text}</span></div>'
def needs_seg():
    return f'<span style="display:flex;align-items:center;gap:6px;color:#f2b544">{B.st("Needs you",12)}Needs you</span>'
ADDBG="rgba(127,191,122,0.10)"

# ===== 1. minga.approval.diff
new=[('defmodule MingaAgent.UsageLimitTest do',kw),('  use ExUnit.Case, async: true',None),('',None),('  alias MingaAgent.UsageLimit',None),('',None),('  describe "classify/1" do',None),('    test "a 429 with usage_limit_reached is a usage limit" do',None),('      error = %{status: 429, body: %{"error" => %{"type" => "usage_limit_reached"}}}',None),('      assert UsageLimit.classify(error) == :usage_limit',None),('    end',None)]
lines="".join(mline(i+1,('<span style="color:#7fbf7a">+</span> ')+H.escape(t),ADDBG,"#7fbf7a") for i,(t,_) in enumerate(new))
hdr=f'''<div style="height:30px;flex:none;display:flex;align-items:center;gap:10px;padding:0 16px;border-bottom:1px solid rgba(255,255,255,0.06);font-size:12px;background:#23242a">{B.st("Needs you",12)}<span style="font-weight:600">Add tests for the usage-limit classifier</span><span style="color:#f2b544">wants to create</span><span style="font-family:ui-monospace,monospace;color:#c9c7c2">test/minga_agent/usage_limit_test.exs</span><span style="color:#7fbf7a">+86</span><span style="flex:1"></span><span style="color:#8f8d88">new file · 86 lines</span></div>'''
body=f'<div style="flex:1;min-height:0;display:flex;flex-direction:column">{hdr}<div style="flex:1;overflow:hidden;padding-top:6px;font-family:ui-monospace,monospace;font-size:13px;color:#c9c7c2">{lines}</div></div>'
prompt=f'''<div style="flex:none;background:#1b1c21;border-top:1px solid #f2b544;padding:8px 14px;font-size:13px;display:flex;align-items:center;gap:6px"><span style="color:#ecebe8">Create <span style="font-family:ui-monospace,monospace">usage_limit_test.exs</span>?</span><span style="flex:1"></span>{hint("y","once")}<span style="width:6px"></span>{hint("a","always")}<span style="width:6px"></span>{hint("t","this turn")}<span style="width:6px"></span>{hint("n","deny")}<span style="width:6px"></span>{hint("]h","next")}<span style="width:6px"></span>{hint("esc","back")}</div>'''
mac=macwin(body+prompt+modeline(file="*minga-approval*",minga=needs_seg(),right=None,pos="1:1"),title="*minga-approval*",path="Add tests for the usage-limit classifier")
g=G.Grid(TW,TH)
g.box(0,0,15,TW,G.FOCUS,G.BG,title=[("◉ ",G.AMBER),("Add tests for the usage-limit classifier",G.TXT,"b"),("  wants to create ",G.AMBER),("usage_limit_test.exs",G.TXT)],right=[("+86",G.GREEN)])
GB="#1f2a22"
for i,(t,_) in enumerate(new[:12]):
    r=1+i; g.bgrow(r,1,TW-2,GB); g.put(r,2,f"{i+1:>3} ",G.GREEN,GB); g.put(r,6,"+ ",G.GREEN,GB); g.put(r,8,t[:TW-10],G.CODE,GB)
pb=G.Grid(TW,3,bg="#1b1c21"); pb.box(0,0,3,TW,G.AMBER,"#1b1c21",bottom=[("y",G.TXT),(" once  ",G.DIM),("a",G.TXT),(" always  ",G.DIM),("t",G.TXT),(" this turn  ",G.DIM),("n",G.TXT),(" deny  ",G.DIM),("]h",G.TXT),(" next  ",G.DIM),("esc",G.TXT),(" back",G.DIM)])
pb.put(1,2,"Create usage_limit_test.exs?",G.TXT)
for y in range(3):
    for x in range(TW): g.c[15+y][x]=list(pb.c[y][x])
tmode(g,18,parts=[(" *minga-approval* ",G.TXT,"#30313a","b"),(" ◉ Needs you ",G.AMBER,"#3a3120","b")],right=" 1:1 ")
write("Batch2_minga_approval_diff.dc.html",board("Batch 2: approval with its diff",("= on a needs-you row","see exactly what Minga will create or change; the question stays answerable"),mac,"",tterm(g,"TUI","the diff fills the drawer; the prompt sits in a bordered minibuffer"),
 [("y","minga.tasks.working (approved once)"),("a","minga.tasks.working (always for this session)"),("t","minga.tasks.working (for this turn)"),("n","minga.tasks.working (denied, Minga is told why it stopped)"),("]h / [h","next / previous change when the request edits several places"),("esc / q","minga.tasks.needs_you")],
 "The prompt border uses the needs-you colour role. Same keys as the drawer row and the notification, so the answer does not depend on where you see the question."))

# ===== 2. minga.task.output
out=[("$ mix test test/minga_agent/session_test.exs","#8f8d88",""),("Compiling 2 files (.ex)","#a5a39e",""),("..........","#a5a39e",""),
 ("1) test resume keeps the queued inputs (MingaAgent.SessionTest)","#e5707a","rgba(229,112,122,0.10)"),
 ("   <u>test/minga_agent/session_test.exs:142</u>","#c9c7c2","rgba(229,112,122,0.10)"),
 ("   ** (MatchError) no match of right hand side value: {:error, :session_not_found}","#e5707a","rgba(229,112,122,0.10)"),
 ("   code: {:ok, session} = Session.resume(id)","#c9c7c2","rgba(229,112,122,0.10)"),
 ("   stacktrace:","#a5a39e","rgba(229,112,122,0.10)"),
 ("     <u>lib/minga_agent/session.ex:318</u>: MingaAgent.Session.resume/1","#c9c7c2","rgba(229,112,122,0.10)"),
 ("","",""),("Finished in 1.9 seconds","#a5a39e",""),("38 tests, 1 failure","#e5707a","")]
LINK=lambda t: t.replace("<u>",'<u style="color:#8fc7ff">')
ol="".join(f'<div style="height:22px;display:flex;align-items:center;padding:0 16px;background:{bg};color:{c}"><span style="white-space:pre">{LINK(t)}</span></div>' for t,c,bg in out)
hdr=f'''<div style="height:30px;flex:none;display:flex;align-items:center;gap:10px;padding:0 16px;border-bottom:1px solid rgba(255,255,255,0.06);font-size:12px;background:#23242a"><span style="color:#8f8d88;font-family:ui-monospace,monospace;font-size:11.5px">*minga-output*</span>{B.st("Failed",12)}<span style="font-weight:600">Run the session test suite</span><span style="color:#e5707a">Failed · exit 1 · 11m ago</span><span style="flex:1"></span>{hint("r","retry")}<span style="width:6px"></span>{hint("f","ask Minga to fix")}<span style="width:6px"></span>{hint("↩","open file:line")}<span style="width:6px"></span>{hint("q","close")}</div>'''
body=f'<div style="flex:1;min-height:0;display:flex;flex-direction:column">{hdr}<div style="flex:1;overflow:hidden;padding-top:6px;font-family:ui-monospace,monospace;font-size:12.5px">{ol}</div></div>'
mac=macwin(body+modeline(file="*minga-output*",minga=f'{B.st("Failed",12)}<span style="color:#e5707a">1 failed</span>',right="read only",pos="5:4"),title="*minga-output*",path="Run the session test suite")
g=G.Grid(TW,TH)
g.box(0,0,18,TW,G.FOCUS,G.BG,title=[("*minga-output*",G.SUB),("  ◆ ",G.RED),("Run the session test suite",G.TXT,"b"),("  Failed · exit 1",G.RED)],bottom=[("r",G.TXT),(" retry  ",G.DIM),("f",G.TXT),(" ask Minga to fix  ",G.DIM),("↩",G.TXT),(" open file:line  ",G.DIM),("q",G.TXT),(" close",G.DIM)],bottom_right=[("11m ago",G.FAINT)])
RB="#33262a"
for i,(t,c,bg) in enumerate(out):
    r=1+i; plain=t.replace("<u>","").replace("</u>","")
    b=RB if bg else None
    if b: g.bgrow(r,1,TW-2,RB)
    col={"#8f8d88":G.DIM,"#a5a39e":G.SUB,"#e5707a":G.RED,"#8fc7ff":G.BLUE,"#c9c7c2":G.CODE,"":G.TXT}[c]
    if "<u>" in t:
        pre,rest=t.split("<u>",1); link,post=rest.split("</u>",1)
        x=g.put(r,2,pre,G.CODE,b); x=g.put(r,x,link,G.BLUE,b,"bu"); g.put(r,x,post,G.CODE,b)
    else:
        g.put(r,2,plain[:TW-4],col,b)
tmode(g,18,parts=[(" *minga-output* ",G.TXT,"#30313a","b"),(" ◆ 1 failed ",G.RED,"#3a2328","b")],right=" 5:4 ")
write("Batch2_minga_task_output.dc.html",board("Batch 2: a task's output",("o on a failed or waiting row","the run's output as a read-only buffer; the failure is highlighted and its paths open"),mac,"",tterm(g,"TUI","same buffer, paths are OSC 8 links"),
 [("r","minga.tasks.working (retry the task)"),("f","minga.conversation (asks Minga to fix it, with this output attached)"),("↩ on a file:line","edit.plain (opens the file at that line)"),("]] / [[","next / previous failure"),("q","minga.tasks.list")],
 "Read only: Vim motions, search and yank work, nothing edits the log. A waiting task's output shows the same buffer with the Waiting state and its retry time."))

# ===== 3. start.first_run
def opt(sel,label,note=""):
    bg="background:rgba(26,149,242,0.16);box-shadow:inset 3px 0 0 #6cb8f5;" if sel else ""
    return f'<div style="display:flex;align-items:center;gap:10px;height:30px;padding:0 14px;border-radius:6px;{bg}"><span style="color:{"#ecebe8" if sel else "#c9c7c2"};font-weight:{600 if sel else 400}">{label}</span><span style="color:#8f8d88;font-size:12px">{note}</span></div>'
fr=f'''<div style="flex:1;min-height:0;display:flex;align-items:center;justify-content:center;background:#1e1f24">
<div style="width:560px;display:flex;flex-direction:column;gap:14px">
<div style="display:flex;align-items:baseline;gap:14px"><span style="font-family:'Instrument Serif',serif;font-style:italic;font-size:44px;color:#b98cf0">minga</span><span style="font-family:'Instrument Serif',serif;font-style:italic;font-size:26px;color:#ecebe8">Servus.</span></div>
<div style="color:#a5a39e;font-size:13px">Three quick choices. Change any of them later in settings.</div>
<div style="display:flex;gap:18px;font-size:12px;color:#8f8d88"><span style="color:#ecebe8;font-weight:600">1 Keys</span><span>2 Minga</span><span>3 Theme</span></div>
<div style="display:flex;flex-direction:column;gap:4px">{opt(True,"Vim","modal editing, SPC as leader (default)")}{opt(False,"CUA","familiar shortcuts, no modes")}</div>
<div style="display:flex;flex-direction:column;gap:3px;font-size:12px;color:#7a7c85;margin-top:4px"><div>2 Minga · sign in to a provider, or skip for now</div><div>3 Theme · Catppuccin Frappé (default)</div></div>
<div style="font-size:12px;margin-top:6px">{hint("j/k","choose")}<span style="width:10px;display:inline-block"></span>{hint("↩","next")}<span style="width:10px;display:inline-block"></span>{hint("esc","skip, keep defaults")}</div>
</div></div>'''
mac=macwin(fr+modeline(file="Welcome",right=None,pos="1 of 3"),title="minga",path="",)
g=G.Grid(TW,TH)
cx=34
g.put(2,cx,"minga",G.PURPLE,None,"i"); g.put(2,cx+8,"Servus.",G.TXT,None,"b")
g.put(4,cx,"Three quick choices. Change any of them later in settings.",G.SUB)
g.segs(6,cx,[("1 Keys",G.TXT,None,"b"),("    2 Minga    3 Theme",G.DIM)])
SEL="#2c2f37"; g.bgrow(8,cx-1,58,SEL); g.put(8,cx-1,"▌",G.BLUE,SEL)
g.segs(8,cx+1,[("Vim",G.TXT,SEL,"b"),("   modal editing, SPC as leader (default)",G.DIM,SEL)])
g.segs(9,cx+1,[("CUA",G.CODE),("   familiar shortcuts, no modes",G.DIM)])
g.put(11,cx,"2 Minga · sign in to a provider, or skip for now",G.FAINT)
g.put(12,cx,"3 Theme · Catppuccin Frappé (default)",G.FAINT)
g.segs(14,cx,[("j/k",G.TXT),(" choose   ",G.DIM),("↩",G.TXT),(" next   ",G.DIM),("esc",G.TXT),(" skip, keep defaults",G.DIM)])
tmode(g,18,parts=[(" Welcome ",G.TXT,"#30313a","b")],right=" 1 of 3 ")
write("Batch2_start_first_run.dc.html",board("Batch 2: first run",("First launch","Servus., then three choices, each answered with j/k and ↩"),mac,"",tterm(g,"TUI","same three steps, centred in the terminal"),
 [("↩ (step 3)","start.empty"),("esc (any step)","start.empty (defaults: Vim, skip sign-in, Catppuccin Frappé)"),("↩ (steps 1, 2)","the next step")],
 "Step 2 offers Sign in (opens the provider's own sign-in) or Skip for now; Minga never asks for a key in this screen. Step 3 previews each theme live as you move. Servus. appears only here."))

# ===== 4. start.quit.confirm
q=f'''<div style="flex:none;background:#1b1c21;border-top:1px solid #5b9bd5;padding:8px 14px;font-size:13px;display:flex;flex-direction:column;gap:6px">
<div style="display:flex;align-items:center;gap:10px"><span style="color:#ecebe8;font-weight:600">Quit Minga?</span><span style="color:#a5a39e">2 unsaved files</span><span style="color:#7a7c85">·</span><span style="display:flex;align-items:center;gap:6px;color:#b98cf0">{B.st("Working",12)}Minga is editing chrome_state.ex</span></div>
<div style="display:flex;align-items:center;gap:6px;font-size:12px;color:#8f8d88"><span>Minga's task stops; its changes stay for review next time.</span><span style="flex:1"></span>{hint("s","save all and quit")}<span style="width:8px"></span>{hint("d","discard and quit")}<span style="width:8px"></span>{hint("esc","cancel")}</div></div>'''
mac=macwin(editor_area(code(10,minga="unreviewed"))+q+modeline(file="chrome_state.ex",minga=f'{B.st("Working",12)}<span style="color:#b98cf0">Minga</span><span style="color:#c9c7c2">editing 2/3</span>',right="Elixir"))
g=G.Grid(TW,TH); tcode(g,13,minga="unreviewed",dim=False)
pb=G.Grid(TW,4,bg="#1b1c21"); pb.box(0,0,4,TW,G.FOCUS,"#1b1c21",title=[("Quit Minga?",G.TXT,"b")],bottom=[("s",G.TXT),(" save all and quit  ",G.DIM),("d",G.TXT),(" discard and quit  ",G.DIM),("esc",G.TXT),(" cancel",G.DIM)])
pb.segs(1,2,[("2 unsaved files",G.SUB),("  ·  ",G.FAINT),("◐ ",G.PURPLED),("Minga is editing chrome_state.ex",G.PURPLE)])
pb.put(2,2,"Minga's task stops; its changes stay for review next time.",G.DIM)
for y in range(4):
    for x in range(TW): g.c[14+y][x]=list(pb.c[y][x])
tmode(g,18,parts=[(" chrome_state.ex ",G.TXT,"#30313a","b"),(" ◐ Minga editing 2/3 ",G.PURPLE,"#25262c")])
write("Batch2_start_quit_confirm.dc.html",board("Batch 2: quit with something at stake",("SPC q q or ⌘Q","the prompt says what is at stake; s and d name the action, so there is no y/n guessing"),mac,"",tterm(g,"TUI","bordered minibuffer with the stakes in the title line"),
 [("s","start.quit.farewell (saves every unsaved file first)"),("d","start.quit.farewell (unsaved edits are dropped)"),("esc","edit.plain")],
 "Only shown when something is at stake; a clean quit goes straight to the farewell. Minga's unreviewed changes are never discarded by quitting."))

# ===== 5. start.quit.farewell
fw=f'''<div style="flex:1;min-height:0;opacity:0.35">{editor_area(code(10))}</div>
<div style="height:26px;flex:none;display:flex;align-items:center;gap:12px;padding:0 16px;background:#25262c;border-top:1px solid rgba(255,255,255,0.07)"><span style="font-family:'Instrument Serif',serif;font-style:italic;font-size:17px;color:#ecebe8">Ciao.</span><span style="color:#8f8d88;font-size:12px">3 tasks done today · everything saved</span></div>'''
mac=f'<div style="opacity:0.9">{macwin(fw)}</div>'
g=G.Grid(TW,TH,bg="#1a1b1f")
g.segs(0,0,[("~/code/minga",G.BLUE),(" main",G.PURPLE),(" ❯ ",G.GREEN),("minga lib/minga_editor/session/chrome_state.ex",G.TXT)])
g.segs(1,0,[("Ciao.",G.TXT,None,"b"),(" 3 tasks done today.",G.DIM)])
g.segs(2,0,[("~/code/minga",G.BLUE),(" main",G.PURPLE),(" ❯ ",G.GREEN),(" ",None,G.TXT)])
write("Batch2_start_quit_farewell.dc.html",board("Batch 2: farewell",("The app closes","one line, then it is gone"),mac,"",tterm(g,"TUI","the terminal is restored and Minga leaves one line"),
 [("(none)","the app exits")],
 "macOS: the modeline shows Ciao. for a moment while the window fades (no fade with Reduce Motion). TUI: printed after the terminal is restored, so it stays in your scrollback. The summary only appears when there is one to give."))
