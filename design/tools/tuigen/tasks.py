import sys; sys.path.insert(0,'.')
from grid import *
W,H=150,38
g=Grid(W,H)
D1="#5f616a"; D2="#4a4c54"
L=[(229,"defp chrome_state(ws) do"),(230,"  %{status: workspace_agent_status(ws), limit: usage_limit(ws)}"),(231,"end"),(232,""),
   (233,"# Status comes from one owner: the session's presence."),(234,"@spec workspace_agent_status(Workspace.t()) :: AgentPresence.state()"),
   (235,"defp workspace_agent_status(ws) do"),(236,"  ws |> payload() |> AgentPresence.of()"),(237,"end"),(238,""),(239,"defp usage_limit(ws) do"),
   (240,"  ws |> payload() |> limit_label()"),(241,"end"),(242,""),(243,"def agent_label(%{state: :working, action: a}), do: a"),
   (244,"def agent_label(%{state: :needs_you}), do: \"Needs you\""),(245,"def agent_label(%{state: :done}), do: \"Done\""),(246,"def agent_label(_), do: \"\""),
   (247,""),(248,"defp payload(%Workspace{payload: p}), do: p"),(249,""),(250,"defp limit_label(%{plan: plan, resets_at: at}) do"),
   (251,"  \"#{plan} limit reached, resets \" <> relative(at)"),(252,"end"),(253,""),(254,"defp limit_label(_), do: nil"),(255,""),
   (256,"@spec relative(DateTime.t()) :: String.t()"),(257,"defp relative(at) do"),(258,"  at |> DateTime.diff(DateTime.utc_now(), :minute) |> minutes()"),
   (259,"end"),(260,""),(261,"defp minutes(n) when n < 60, do: \"in #{n} min\""),(262,"defp minutes(n), do: \"in #{div(n, 60)} h\""),(263,"")]
auth={229:("│","#3b5f80"),230:("│","#3b5f80"),234:("╳","#6a4f8f"),235:("┃","#6a4f8f"),236:("┃","#6a4f8f"),237:("┃","#6a4f8f")}
for i,(n,t) in enumerate(L):
    r=i+1
    g.put(r,0,f"{n:>5} ",D2)
    if n in auth: g.put(r,7,auth[n][0],auth[n][1])
    if n==240: g.put(r,6,"E","#7a4248")
    g.put(r,9,t,D1)
# drawer: a Lip Gloss layer floating over the dimmed editor
top=13; h=22; DX=7; DW=W-14
d=Grid(DW,h,bg=SURF)
d.box(0,0,h,DW,FOCUS,SURF,title=[("*minga-tasks*",SUB),("  Minga Tasks",TXT,"b")],
      right=[("◉ 1",AMBER),("  ",SUB),("◐ 1",PURPLE),("  ",SUB),("○ 1",SUB),("  ",SUB),("◆ 1",RED),("  ",SUB),("● 1",GREEN)],
      bottom=[("j/k",TXT),(" move  ",DIM),("↩",TXT),(" open  ",DIM),("i",TXT),(" inspect  ",DIM),("x",TXT),(" stop  ",DIM),("/",TXT),(" filter  ",DIM),("q",TXT),(" close",DIM)],
      bottom_right=[("SPC a a",FAINT)])
SEL="#33302a"
r=2
for y in range(r,r+5): d.bgrow(y,1,DW-2,SEL)
d.put(r,1,"▌",AMBER,SEL)
d.segs(r,3,[("◉ ",AMBER),("Add tests for the usage-limit classifier",TXT,None,"b")])
d.segs(r,64,[("Needs you",AMBER,None,"b"),(" · wants to create a file",SUB)])
d.put(r,DW-5,"2m",DIM)
d.segs(r+1,5,[("Create ",SUB),("test/minga_agent/usage_limit_test.exs",BLUE,None,"lk"),("  +86",GREEN)])
d.put(r+2,5,"“Table tests for the classifier, including the recorded Pro response.”",DIM,None,"i")
d.segs(r+4,5,[("y",AMBER,None,"b"),(" Approve once     ",TXT),("a",AMBER,None,"b"),(" Always for this session     ",TXT),("t",AMBER,None,"b"),(" This turn     ",TXT),("n",AMBER,None,"b"),(" Deny     ",TXT),("=",SUB,None,"b"),(" Show diff     ",SUB),("↩",SUB,None,"b"),(" Open conversation",SUB)])
for y in range(r+1,r+5): d.put(y,1,"▌",AMBER,SEL)
rows=[("◐",PURPLED,"Show the plan limit instead of “rate limited”",[("Editing ",PURPLE),("chrome_state.ex",PURPLE,"lk"),(" · step 2 of 3",PURPLE)],("i","Inspect"),"4m"),
      ("○",SUB,"Refactor the picker sources",[("Waiting · rate limited, retry in 40 s",SUB)],("r","Retry now"),"9m"),
      ("◆",RED,"Run the session test suite",[("Failed · test run crashed",RED)],("o","Output"),"11m"),
      ("●",GREEN,"Update the agent docs for the Spine",[("Done · 2 files to review",GREEN)],("↩","Review"),"12m")]
y=r+6
for gl,gc,title,state,act,age in rows:
    d.segs(y,3,[(gl+" ",gc),(title,TXT)])
    d.segs(y,64,[(p[0],p[1],None,p[2] if len(p)>2 else None) for p in state])
    d.segs(y,DW-32,[(act[0],TXT,None,"b"),(" "+act[1],SUB)])
    d.put(y,DW-2-len(age)-1,age,DIM)
    d.put(y+1,3,"─"*(DW-6),"#2c2d34") if gl!="●" else None
    y+=2
d.segs(y+1,5,[("/",TXT,None,"b"),(" filter: ",DIM),("type to narrow by goal, file or state",FAINT,None,"i")])
g.blit(d,top,DX); g.shadow(top,DX,h,DW)
# modeline
r=36; g.fill(r,0,W,"#25262c")
g.segs(r,0,[(" NORMAL ","#12304a",BLUE,"b"),(" ",None,"#25262c"),(" ◉ Needs you ",AMBER,"#3a3120","b"),(" ",None,"#25262c"),(" *minga-tasks* ",TXT,"#30313a","b"),(" ",None,"#25262c"),
  ("  main +11 ",SUB,"#25262c"),(" ◐ ",PURPLED,"#25262c"),("Minga editing chrome_state.ex 2/3 ",PURPLE,"#25262c"),(" E 1 ",RED,"#3a2328","b")])
g.segs(r,W-len(" 3:1 ")-1,[(" 3:1 ",TXT,"#30313a")])
open("tasks_grid.html","w").write(g.html())
body=term(g.html(),"SPC a a: the tasks drawer","editor above dims while the drawer has focus")
annot="""<h4>What renders what</h4>
<div class="it"><span class="k">Drawer</span> a Lip Gloss layer floating over the dimmed editor (<code>lipgloss.NewLayer</code> + <code>Canvas</code>, already used in go/tui), inset past the line numbers, with a soft drop shadow: dim <code>▌</code> on the right edge, <code>▀</code> under the bottom. <code>RoundedBorder()</code> takes the focus colour only while focused. Body on <code>Surface</code>.</div>
<div class="it"><span class="k">Header in the border</span> buffer name dim, title bold, state counts right-aligned in the top border. Key help in the bottom border (<code>help.Model</code> short view). No extra hint line above the modeline.</div>
<div class="it"><span class="k">Rows</span> <code>bubbles/list</code> with a custom delegate: glyph, goal, state words in the state colour, one action, age. Hairline separators in <code>SurfaceAlt</code>.</div>
<div class="it"><span class="k">Selection</span> a full-width <code>Background</code> bar plus a left <code>▌</code> in the row's state colour. The needs-you row expands in place to show the request and its four answers.</div>
<div class="it"><span class="k">Links</span> file paths are OSC 8 hyperlinks (Lip Gloss v2 <code>Hyperlink</code>): a faint underline, clickable in the terminal, opening the file in Minga.</div>
<div class="it"><span class="k">Working</span> ◐ is a <code>bubbles/spinner</code> with <code>Frames: ◐ ◓ ◑ ◒</code>, 8 fps, static when motion is reduced.</div>
<div class="it"><span class="k">Dimmed editor</span> foreground faded while focus is in the drawer, so the eye goes to the drawer. Restored on <code>q</code>.</div>
<div class="it"><span class="k">One key, one meaning</span> <code>r</code> only retries, <code>o</code> shows output, <code>↩</code> opens.</div>"""
open(os.path.join(OUT_DIR,"V41TuiTasks.dc.html"),"w").write(page("TUI: tasks drawer",body,annot))
