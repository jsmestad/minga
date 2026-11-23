import sys; sys.path.insert(0,'.')
from grid import *
W=150
# (a) conversation, 22 rows
H=21; g=Grid(W,H)
CX=76
code=[(231,"# Status comes from one owner.",CMT,None),(232,"@spec workspace_agent_status(...)",KW,("╳",PURPLED)),(233,"defp workspace_agent_status(ws) do",CODE,("┃",PURPLED)),
      (234,"  ws |> payload() |> AgentPresence.of()",CODE,("┃",PURPLED)),(235,"  |> AgentPresence.state()",CODE,("┃",PURPLED)),(236,"end",KW,None)]
for i,(n,t,c,a) in enumerate(code):
    r=1+i; g.put(r,0,f"{n:>5} ",FAINT)
    if a: g.put(r,7,a[0],a[1])
    x=g.put(r,9,t,c)
    if n==234: g.put(r,x,"▏",PURPLED); g.put(r,x+2," Minga ","#14151a",PURPLED,"b")
g.box(0,CX,13,W-CX,BORDER,SURF,title=[("◐ ",PURPLED),("Show the plan limit instead of “rate limited”",TXT,"b")],right=[("4 min · GPT-6.2 Sol",DIM)])
x0=CX+2
g.put(1,x0,"You",BLUE,None,"b"); g.put(2,x0,"Show the plan limit and when it resets instead of \"rate limited\".",TXT)
g.put(4,x0,"Minga",PURPLE,None,"b")
g.put(5,x0,"A 429 with usage_limit_reached is its own case. I'll carry the plan,",CODE)
g.put(6,x0,"window and reset time on the error and say it once.",CODE)
g.segs(8,x0,[("● ",GREEN),("Read ",SUB),("native.ex",SUB,None,"lk"),(" and found where 429s are classified",SUB)])
g.segs(9,x0,[("● ",GREEN),("Edited ",SUB),("retry.ex",SUB,None,"lk"),(" so a usage limit is not retried  ",SUB),("+12",GREEN),(" −3",RED)])
g.segs(10,x0,[("◆ ",RED),("Test run failed · ",RED),("retry_test.exs:31",RED,None,"lk"),("   ",RED),("o",TXT,None,"b"),(" output",DIM)])
g.segs(11,x0,[("◐ ",PURPLED),("Editing ",PURPLE),("chrome_state.ex",PURPLE,None,"lk")])
# queue panel
g.box(13,CX,3,W-CX,BORDER,SURF2,title=[("*minga-queue*",SUB),("  2 queued",DIM)],right=[("dd",TXT),(" remove  ",DIM),("p",TXT),(" paste",DIM)])
g.put(14,CX+2,"1  Then run the session tests and fix what fails.   2  Update the docs.",SUB)
# composer
g.box(16,CX,4,W-CX,FOCUS,BG,title=[("Composer",TXT,"b")],bottom=[("↩",TXT),(" send  ",DIM),("⌥↩",TXT),(" queue  ",DIM),("SPC a s",TXT),(" stop  ",DIM),("i",TXT),(" insert",DIM)])
g.put(17,CX+2,"Also show the reset time in the modeline,",TXT); g.put(18,CX+2,"next to the needs-you segment",TXT); g.put(18,CX+2+29," ",BG,BLUE)
r=20; g.fill(r,0,W,"#25262c")
g.segs(r,0,[(" NORMAL ","#12304a",BLUE,"b"),(" ",None,"#25262c"),(" ◉ Needs you ",AMBER,"#3a3120","b"),(" ",None,"#25262c"),(" *minga-composer* ",TXT,"#30313a","b"),(" ",None,"#25262c"),(" ◐ ",PURPLED,"#25262c"),("Minga editing chrome_state.ex 2/3",PURPLE,"#25262c")])
g.segs(r,W-len(" Markdown  2:29 ")-1,[(" Markdown ",SUB,"#25262c"),(" 2:29 ",TXT,"#30313a")])
ga=g.html()
# (b) find file, 18 rows
H=18; f=Grid(W,H)
for i,(n,t) in enumerate([(229,"defp workspace_payload(%Workspace{payload: p}), do: p"),(230,""),(231,"# Status comes from one owner.")]):
    f.put(1+i,0,f"{n:>5} ","#4a4c54"); f.put(1+i,9,t,"#5f616a")
for i,(n,t) in enumerate([(232,"@spec workspace_agent_status(...)"),(233,"defp workspace_agent_status(ws) do"),(234,"  ws |> payload() |> AgentPresence.of()"),(235,"  |> AgentPresence.state()"),(236,"end"),(237,""),(238,"def agent_label(%{state: :working, action: a}), do: a"),(239,"def agent_label(%{state: :needs_you}), do: \"Needs you\""),(240,"def agent_label(%{state: :done}), do: \"Done\""),(241,"def agent_label(_), do: \"\""),(242,""),(243,"defp payload(%Workspace{payload: p}), do: p"),(244,"")]):
    f.put(4+i,0,f"{n:>5} ","#4a4c54"); f.put(4+i,9,t,"#5f616a")
FW=W-14; FX=7
ff=Grid(FW,13,bg=SURF)
ff.box(0,0,13,FW,FOCUS,SURF,title=[("Find file",TXT,"b")],right=[("3 of 1,204",DIM)],
      bottom=[("↩",TXT),(" open  ",DIM),("⌃V",TXT),(" split  ",DIM),("⌃T",TXT),(" pin  ",DIM),("⌃J ⌃K",TXT),(" move  ",DIM),("esc",TXT),(" close",DIM)],bottom_right=[("SPC ,",FAINT)])
ff.segs(1,2,[("› ",BLUE,None,"b"),("chro",TXT)]); ff.put(1,8," ",SURF,BLUE)
ff.put(2,2,"─"*(FW-4),"#33353d")
SEL="#2b3646"
ff.put(3,2,"Pinned",DIM,None,"b")
ff.bgrow(4,1,FW-2,SEL); ff.put(4,1,"▌",BLUE,SEL)
ff.segs(4,3,[("1 ",DIM),("chro",BLUE,None,"bu"),("me_state.ex",TXT,None,"b"),("  lib/minga_editor/session",DIM)])
ff.segs(5,3,[("2 ",DIM),("chro",BLUE,None,"bu"),("me_state_test.exs",TXT),("  test/minga_editor/session",DIM)])
ff.put(6,2,"Changed",DIM,None,"b")
ff.segs(7,3,[("◐ ",PURPLED),("Show the plan limit instead of “rate limited”",SUB),("   ",DIM),("╳",PURPLED),(" ",DIM),("chro",BLUE,None,"bu"),("me_state.ex",TXT),("  2 changes",DIM)])
ff.segs(7,FW-16,[("editing now",PURPLE)])
ff.put(8,2,"Recent",DIM,None,"b")
ff.segs(9,3,[("  ",DIM),("chro",BLUE,None,"bu"),("me_state_bench.exs",TXT),("  bench",DIM)]); ff.put(9,FW-10,"2 min",DIM)
f.blit(ff,3,FX); f.shadow(3,FX,13,FW)
r=17; f.fill(r,0,W,"#25262c")
f.segs(r,0,[(" INSERT ","#10301a","#7fd08a","b"),(" ",None,"#25262c"),(" ◉ Needs you ",AMBER,"#3a3120","b"),(" ",None,"#25262c"),(" *find-file* ",TXT,"#30313a","b"),(" ",None,"#25262c"),("  main +11 ",SUB,"#25262c"),(" ◐ ",PURPLED,"#25262c"),("Minga editing chrome_state.ex 2/3",PURPLE,"#25262c")])
gb=f.html()
body='<div style="display:flex;flex-direction:column;gap:14px">'+term(ga,"Talking to Minga","conversation split, queue and composer")+term(gb,"SPC , find file","typing goes to the prompt, so actions use control keys")+'</div>'
annot="""<h4>What renders what</h4>
<div class="it"><span class="k">Conversation</span> a bordered <code>viewport</code> on <code>Surface</code>: speaker labels in their colour, plain prose, tool steps as one line with a state glyph. No bubbles, no rails.</div>
<div class="it"><span class="k">Queue</span> a small bordered buffer on <code>SurfaceAlt</code>, editable with dd and p; its keys sit in its border.</div>
<div class="it"><span class="k">Composer</span> <code>bubbles/textarea</code> in a <code>RoundedBorder</code> that turns the focus colour while focused. Hints live in its bottom border and only while focused. ⌘. has no terminal key, so stop is <code>SPC a s</code>.</div>
<div class="it"><span class="k">Links</span> file names and <code>file:line</code> in tool steps are OSC 8 hyperlinks (Lip Gloss v2 <code>Hyperlink</code>).</div>
<div class="it"><span class="k">Find file</span> floats as a layer over the dimmed editor with a soft half-block drop shadow (<code>lipgloss.NewLayer</code> / <code>Canvas</code>, already used in go/tui). <code>bubbles/textinput</code> prompt, results as a sectioned list, matched characters bold and underlined in your blue, full-width selection bar.</div>
<div class="it"><span class="k">Editor behind</span> dimmed while a drawer has focus.</div>"""
open(os.path.join(OUT_DIR,"V41TuiTalkOpen.dc.html"),"w").write(page("TUI: talk and find file",body,annot))
