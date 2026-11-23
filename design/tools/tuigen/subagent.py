import sys; sys.path.insert(0,'.')
from grid import *
W,H=150,38
g=Grid(W,H)
HEAD="#23242a"; CUR="#25303d"; RES="#22291f"
LW=69
# left: parent conversation
g.fill(0,0,LW,HEAD)
g.segs(0,1,[("◐ ",PURPLED,HEAD),("Review the marketing site for unfair claims",TXT,HEAD,"b")])
g.put(0,LW-8,"8 min",SUB,HEAD)
def para(r,who,col,lines):
    g.put(r,2,who,col,None,"b")
    for i,l in enumerate(lines): g.put(r+1+i,2,l,TXT if who=="You" else CODE)
para(2,"You",BLUE,["Read the five site pages as a skeptical senior engineer coming","from Hacker News. Any unfair claims about other editors? Any","jargon that does not land?"])
para(7,"Minga",PURPLE,["I will split this four ways: facts, fairness, jargon, and how","skeptics react to change. Then I will put the hardest hits in","one list."])
subs=[("◐",PURPLED,"Fact-Check Auditor"),("◐",PURPLED,"Competitive Fairness Critic"),("●",GREEN,"Editorial and Jargon Roaster"),("◐",PURPLED,"Driving Technical Change Skeptics")]
for i,(gl,c,n) in enumerate(subs):
    r=12+i
    if i==2: g.bgrow(r,1,LW-3,CUR)
    g.segs(r,2,[("Started  ",DIM),(gl+" ",c),(n,TXT if i==2 else CODE)])
para(17,"Minga",PURPLE,["1 of 4 reports in, from the Editorial and Jargon Roaster.","Waiting on the other three before I put the findings together."])
g.segs(21,2,[("◐ ",PURPLED),("3 subagents working",PURPLE)])
g.box(31,1,4,LW-2,BORDER,BG)
g.put(32,3,"Tell Minga what to change next",FAINT)
# right: the peek split, focused
RX=LW+1; RW=W-RX
g.box(0,RX,36,RW,FOCUS,SURF,
      title=[("Review the marketing site",DIM),(" › ",FAINT),("● ",GREEN),("Editorial and Jargon Roaster",TXT,"b")],
      right=[("◐ ◐ ",PURPLED),("●",GREEN),(" ◐",PURPLED),("  3 of 4",SUB)],
      bottom=[("]t",BLUE),(" next  ",DIM),("[t",BLUE),(" prev  ",DIM),("za",BLUE),(" fold  ",DIM),("↩",BLUE),(" open  ",DIM),("q",BLUE),(" close",DIM)])
# selection mark under the selected sibling glyph in the strip
strip_len=len("◐ ◐ ●  ◐  3 of 4")
sx=RX+RW-2-(len("◐ ◐ ● ◐  3 of 4")+2)+1
g.put(1,sx+4,"▔",BLUE,SURF)
x=RX+2
g.segs(1,x,[("Done",GREEN,SURF),("   worked 3m   GPT-6.2 Sol",SUB,SURF)])
g.segs(3,x,[("▸ ",DIM,SURF),("Brief",TXT,SURF,"b"),("  (from parent)",SUB,SURF)])
g.put(4,x+2,"You are a ruthless editorial and jargon roaster. Read all five si…",FAINT,SURF,"i")
g.segs(6,x,[("▾ ",DIM,SURF),("So far",TXT,SURF,"b")])
steps=[("Read ",[("index",FN,"lk"),(", ",CODE),("guides",FN,"lk"),(", ",CODE),("compare",FN,"lk"),(", ",CODE),("pricing",FN,"lk"),(" and ",CODE),("about",FN,"lk")]),
       ("Flagged 14 phrases that only make sense to Elixir insiders",[]),
       ("Checked every comparison against its linked source",[]),
       ("Ranked the findings by what they cost a first-time reader",[])]
for i,(t,extra) in enumerate(steps):
    xx=g.segs(7+i,x+2,[("● ",GREEN,SURF),(t,CODE,SURF)])
    for p in extra: xx=g.put(7+i,xx,p[0],p[1],SURF,p[2] if len(p)>2 else None)
g.segs(12,x,[("▾ ",DIM,SURF),("Result",TXT,SURF,"b"),("  sent to parent · 2 min ago",SUB,SURF)])
res=["1. “BEAM-powered” appears six times before it is explained.","   Lead with what it does for the reader.",
     "2. “Supervision tree” on the home page is jargon for a Hacker","   News reader. Move it below the fold.",
     "3. The VS Code comparison calls it “bloated”. That reads as a","   cheap shot; show startup numbers instead."]
for i in range(len(res)+3):
    g.bgrow(13+i,x+2,RW-6,RES)
for i,l in enumerate(res): g.put(14+i,x+4,l,TXT,RES)
g.put(14+len(res)+1-1+1,x+4,"11 more findings in the full report",SUB,RES)
g.box(31,RX+2,4,RW-4,BORDER,SURF)
g.put(32,RX+4,"Message this subagent",FAINT,SURF)
# modeline + echo
r=36; g.fill(r,0,W,"#25262c")
g.segs(r,0,[(" NORMAL ","#12304a",BLUE,"b"),(" ",None,"#25262c"),(" *minga: Editorial and Jargon Roaster* ",TXT,"#30313a","b"),(" ",None,"#25262c"),
            ("  main +11 ",SUB,"#25262c"),(" ◐ ",PURPLED,"#25262c"),("Minga 3 subagents working",PURPLE,"#25262c")])
g.segs(r,W-8,[(" 12:1 ",TXT,"#30313a")])
main=g.html()
# inset: tasks drawer tree
t=Grid(112,7,bg=SURF)
t.box(0,0,7,112,BORDER,SURF,title=[("*minga-tasks*",TXT,"b"),("  Minga Tasks",SUB)])
t.segs(1,2,[("◐ ",PURPLED),("Review the marketing site for unfair claims",TXT,None,"b")]); t.put(1,80,"1 of 4 reports in",SUB); t.put(1,106,"8m",DIM)
rows=[("├─ ","◐",PURPLED,"Fact-Check Auditor","reading compare.html",SUB),("├─ ","◐",PURPLED,"Competitive Fairness Critic","checking 9 claims",SUB),
      ("├─ ","●",GREEN,"Editorial and Jargon Roaster","Done · sent to parent",GREEN),("└─ ","◐",PURPLED,"Driving Technical Change Skeptics","persona 4 of 7",SUB)]
for i,(br,gl,c,n,s,sc) in enumerate(rows):
    rr=2+i
    if gl=="●": t.bgrow(rr,1,110,"#2b3a4c")
    t.segs(rr,2,[(br,BORDER),(gl+" ",c),(n,TXT)]); t.put(rr,48,s,sc); t.put(rr,106,"3m",DIM)
inset=t.html("tg small")
body=term(main,"SPC a i: peeking at a subagent","parent conversation on the left, the subagent split focused on the right")
body=body[:-6]+f'<div style="margin-top:12px;font-size:12px;color:#e6e4df;font-weight:600">The same task in the tasks drawer <span style="font-weight:400;color:#a5a39e">SPC a a, a lipgloss/tree under the task</span></div><div style="margin-top:6px;border-radius:6px;overflow:hidden;display:inline-block">{inset}</div></div>'
annot="""<h4>What renders what</h4>
<div class="it"><span class="k">Peek split</span> a <code>lipgloss.RoundedBorder()</code> panel in the focus colour. Breadcrumb in the top border (parent dim, subagent bold with its state glyph); the sibling glyph strip and "3 of 4" right-aligned in the same border, a <code>▔</code> under the one you are on.</div>
<div class="it"><span class="k">Siblings</span> <code>]t</code> and <code>[t</code> step through them in place; the full list is one key away in the tasks drawer. No permanent third column.</div>
<div class="it"><span class="k">Sections</span> dim headers with <code>▸</code> / <code>▾</code>; Brief is folded by default (<code>za</code>) and shows one faint line. Body is a <code>bubbles/viewport</code>.</div>
<div class="it"><span class="k">Result</span> the hand-back to the parent on a faint green surface tint, so it reads as the outcome without a rail or a card.</div>
<div class="it"><span class="k">Composer</span> <code>bubbles/textarea</code> that messages this subagent only; its border turns the focus colour while you type.</div>
<div class="it"><span class="k">Help</span> in the bottom border only while the split has focus (principle 10). The parent conversation on the left shows no keys.</div>
<div class="it"><span class="k">Tasks drawer</span> <code>lipgloss/tree</code>: the task, then its subagents with <code>├─</code> <code>└─</code> and their state glyphs.</div>"""
open(os.path.join(OUT_DIR,"V41SubagentTui.dc.html"),"w").write(page("TUI: peeking at a subagent",body,annot))
