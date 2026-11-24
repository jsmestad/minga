import os as _os
TOOLS = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))
BOARDS = _os.environ.get("BOARDS_DIR", _os.path.join(TOOLS, "..", "boards"))  # committed boards, read only
OUT_DIR = _os.environ.get("OUT_DIR", _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "out"))
_os.makedirs(OUT_DIR, exist_ok=True)
import sys; sys.path.insert(0,'.')
from grid import *
W,H=150,38
g=Grid(W,H)
LW=52
g.box(0,0,36,LW,FOCUS,SURF,title=[("*minga-review*",TXT,"b")],right=[("SPC a r",FAINT)],
      bottom=[("y",TXT),(" keep ",DIM),("n",TXT),(" reject ",DIM),("=",TXT),(" diff ",DIM),("Y",TXT),(" all ",DIM),("]h",TXT),(" next ",DIM),("q",TXT),(" close",DIM)])
T="#5b5e68"
g.segs(2,2,[("● ",GREEN),("Show the plan limit instead of “rate limited”",TXT,None,"b")])
g.segs(3,2,[("│",T),("  Done 3 min ago · 3 files · ",DIM),("+40",GREEN),(" ",DIM),("−12",RED)])
g.segs(4,2,[("│",T)])
g.segs(5,2,[("├",T),("─",T),(" Unreviewed",TXT,None,"b"),("  2 changes in 2 files",DIM)])
SEL="#2b3646"
g.bgrow(6,1,LW-2,SEL); g.put(6,1,"▌",BLUE,SEL)
g.segs(6,2,[("│",T),("  ",None),("├",T),("─",T),(" ",None),("session/chrome_state.ex",TXT,None,"b")]); g.put(6,LW-4,"1",SUB)
g.segs(7,2,[("│",T),("  ",None),("│",T),("  ",None),("└",T),("─",T),(" @@ 231 ",DIM),("replaced 1 line with 3",SUB)]); g.put(7,LW-10,"current",BLUE)
g.segs(8,2,[("│",T),("  ",None),("└",T),("─",T),(" ",None),("minga_agent/usage_limit.ex",TXT)]); g.put(8,LW-6,"new",GREEN)
g.segs(9,2,[("│",T)])
g.segs(10,2,[("└",T),("─",T),(" Kept",TXT,None,"b"),("  2 changes",DIM)])
g.segs(11,2,[("   ",None),("├",T),("─",T),(" ",None),("minga_agent/retry.ex",SUB)]); g.segs(11,LW-9,[("+6",GREEN),(" −9",RED)])
g.segs(12,2,[("   ",None),("└",T),("─",T),(" ",None),("session/chrome_state.ex",SUB)]); g.put(12,LW-8,"@@ 239",DIM)
g.put(14,2,"─"*(LW-4),"#33353d")
g.put(15,2,"Also in the quickfix list:",DIM); g.segs(15,29,[(":copen",PURPLE)])
g.put(16,2,"In a file: ",DIM); g.segs(16,13,[("]h",TXT,None,"b"),(" next  ",DIM),("SPC a y",TXT,None,"b"),(" keep",DIM)])
# right pane
RX=LW
g.box(0,RX,36,W-RX,BORDER,BG,title=[("chrome_state.ex",TXT,"b"),("  ",DIM),("lib/minga_editor/session",DIM,"lk")],right=[("change 1 of 2",PURPLE)])
DEL="#3a2328"; ADD="#1f3326"
lines=[(229,"defp workspace_payload(%Workspace{payload: p}), do: p",None,None,None),(230,"",None,None,None),
 (231,"# Status comes from one owner.",None,None,CMT),
 ("−","ws.payload.agent_status |> status_label()",DEL,("╳",PURPLED),"#d9a5a2"),
 (232,"ws |> payload() |> AgentPresence.of()",ADD,("┃",PURPLED),CODE),
 (233,"|> AgentPresence.state()",ADD,("┃",PURPLED),CODE),
 (234,"# one owner, see AgentPresence",ADD,("┃",PURPLED),CMT),
 (235,"end",None,None,KW),(236,"",None,None,None),
 (237,"def agent_label(%{state: :working, action: a}), do: a",None,None,CODE),
 (238,"def agent_label(%{state: :needs_you}), do: \"Needs you\"",None,None,CODE),
 (239,"def agent_label(%{state: :done}), do: \"Done\"",ADD,("╳",PURPLED),CODE),
 (240,"def agent_label(_), do: \"\"",ADD,("┃",PURPLED),CODE),(241,"",None,None,None)]
for i,(n,t,bg,auth,col) in enumerate(lines):
    r=2+i
    if bg: g.bgrow(r,RX+1,W-RX-2,bg)
    g.put(r,RX+1,f"{n:>5} " if isinstance(n,int) else f"{n:>5} ",(RED if n=="−" else (GREEN if bg==ADD else FAINT)))
    if auth: g.put(r,RX+8,auth[0],auth[1])
    g.put(r,RX+10,t,col or CODE)
    if n==232: g.put(r,RX+10+len(t)," ",BG,BLUE)
g.put(3+len(lines),RX+3,"The twist marks where each Minga change starts; its two strands run down the change.",FAINT,None,"i")
r=36; g.fill(r,0,W,"#25262c")
g.segs(r,0,[(" NORMAL ","#12304a",BLUE,"b"),(" ",None,"#25262c"),(" ◉ Needs you ",AMBER,"#3a3120","b"),(" ",None,"#25262c"),(" *minga-review* ",TXT,"#30313a","b"),(" ",None,"#25262c"),
  ("  main +11 ",SUB,"#25262c"),(" ● ",GREEN,"#25262c"),("Minga done · 2 to review ",GREEN,"#25262c")])
g.segs(r,W-len(" 6:3 ")-1,[(" 6:3 ",TXT,"#30313a")])
body=term(g.html(),"SPC a r: review as a buffer","two panes, one border style, focus colour on the active pane")
annot="""<h4>What renders what</h4>
<div class="it"><span class="k">Two panes</span> each a <code>RoundedBorder</code>. Only the focused pane's border takes the focus colour; the other stays <code>PopupBorder</code>. That is the whole separation scheme, everywhere.</div>
<div class="it"><span class="k">Header path</span> <code>lib/minga_editor/session</code> is an OSC 8 hyperlink (Lip Gloss v2 <code>Hyperlink</code>) to the folder.</div>
<div class="it"><span class="k">Review tree</span> <code>lipgloss/tree</code> with <code>tree.RoundedEnumerator</code>-style connectors (├─ └─ │) for task › section › file › change, in a dim enumerator style. Files fold with <code>za</code> like any Vim fold. Every row is Minga's work, so list rows carry no twist; the twist lives only in the code gutter. The section names say what is unreviewed and what is kept.</div>
<div class="it"><span class="k">Diff</span> rendered in place: removed lines on a red-tinted background, added lines on a green tint, the twist ribbon in the authorship column. Tints come from the theme's diff roles, so they survive 256 colours.</div>
<div class="it"><span class="k">Keys</span> in the bottom border of the review buffer only. In the file, y n = q stay Vim.</div>
<div class="it"><span class="k">Header</span> file name bold, path dim, change position in Minga's purple, all inside the top border.</div>"""
open(OUT_DIR+"/V41TuiReview.dc.html","w").write(page("TUI: review",body,annot))
