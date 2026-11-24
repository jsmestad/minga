exec(open('base41.py').read())
MONO="ui-monospace,'SF Mono',Menlo,monospace"

def code41(n=None, you_line=235, minga_line=236, cursor_msg=True):
    out=[]
    rows=CODE if n is None else CODE[:n]
    for num,flag,mark,text,extra in rows:
        sign=''
        if flag=="err": sign=f'<span style="display:block;width:3px;height:12px;border-radius:1.5px;background:{R};margin:0 auto"></span>'
        cur=''; bg=''
        if num==minga_line:
            cur=f'<span style="display:inline-block;width:2px;height:16px;background:{P};vertical-align:-3px;margin-left:1px"></span><span style="margin-left:6px;padding:0 6px;border-radius:4px;background:{P};color:#fff;font-family:-apple-system,sans-serif;font-size:10.5px;line-height:16px;vertical-align:1px">Minga</span>'
        if num==you_line:
            bg='background:rgba(255,255,255,0.035);'
            cur+=f'<span style="display:inline-block;width:8px;height:17px;background:#6cb8f5;opacity:0.85;vertical-align:-4px;margin-left:1px"></span>'
        numc = "#c9c7c2" if num==you_line else "#7a7c85"
        out.append(f'<div class="ln" style="{bg}"><span class="num" style="color:{numc}">{num}</span><span class="sign">{sign}</span><span class="bar">{mark}</span><span class="code">{text}{cur}</span></div>')
    return "\n".join(out)

def pill(mode="NORMAL", col="#6cb8f5", bg="rgba(26,149,242,0.22)"):
    return f'<span style="margin-left:8px;display:flex;align-items:center;padding:1px 9px;border-radius:9px;background:{bg};color:{col};font-weight:700;font-size:10.5px;letter-spacing:0.04em">{mode}</span>'
def errbar(): return f'<span style="display:inline-block;width:3px;height:11px;border-radius:1.5px;background:{R}"></span>'
def warnbar(): return '<span style="display:inline-block;width:3px;height:11px;border-radius:1.5px;box-shadow:inset 0 0 0 1.2px #d8c08a;box-sizing:border-box"></span>'
def needs(href="V41Tasks.dc.html"):
    return seg(f'<a href="{href}" style="display:flex;align-items:center;gap:6px;color:{A}">{st("Needs you",13)}<span>Needs you</span></a>')
def mline(level=0, mode="NORMAL", file="chrome_state.ex", dirty=True, change=True, pending=None, minga_here=True):
    # level 0 full, 1 drop filetype+position, 2 also git + minga words
    parts=[pill(mode)]
    if pending:
        parts.append(seg(f'<span style="font-family:{MONO};color:#ecebe8">{pending}</span><span style="color:#8f8d88">waiting for a key</span>'))
        right=seg('<span>Elixir</span>')+sep()+seg(f'<span style="font-family:{MONO};font-size:11.5px">235:3</span>','padding-right:14px')
        return f'<div style="height:28px;flex:none;display:flex;align-items:center;background:#25262c;border-top:1px solid rgba(255,255,255,0.07);font-size:12px;color:#a5a39e">{"".join(parts)}<span style="flex:1"></span>{right}</div>'
    parts.append(needs())
    f=f'<span style="color:#ecebe8;font-weight:600">{file}</span>'+(f'<span style="color:#6cb8f5">●</span>' if dirty else '')
    parts.append(seg(f)); parts.append(sep())
    if change: parts.append(seg(f'<span style="color:#b98cf0">change 1/2</span>')); parts.append(sep())
    if level<2:
        branch='<svg width="11" height="11" viewBox="0 0 16 16" aria-hidden="true"><circle cx="4" cy="3.5" r="2" fill="none" stroke="#8f8d88" stroke-width="1.5"/><circle cx="4" cy="12.5" r="2" fill="none" stroke="#8f8d88" stroke-width="1.5"/><circle cx="12" cy="5.5" r="2" fill="none" stroke="#8f8d88" stroke-width="1.5"/><path d="M4 5.5 L4 10.5 M12 7.5 C12 10 4 9 4 10.5" fill="none" stroke="#8f8d88" stroke-width="1.5"/></svg>'
        parts.append(seg(f'{branch}<span>main</span><span style="color:#8f8d88">+11</span>')); parts.append(sep())
        words = '<span style="color:#b98cf0">Minga</span><span style="color:#c9c7c2">here</span>' if minga_here else '<span style="color:#b98cf0">Minga</span><span style="color:#c9c7c2">editing chrome_state.ex</span>'
        parts.append(seg(f'{st("Working",13)}{words}<span style="color:#8f8d88">2/3</span>')); parts.append(sep())
    else:
        parts.append(seg(f'{st("Working",13)}<span style="color:#8f8d88">2/3</span>')); parts.append(sep())
    parts.append(seg(f'{errbar()}<span style="color:{R}">1</span><span style="width:6px"></span>{warnbar()}<span style="color:#c9c7c2">1</span>'))
    right=''
    if level==0:
        right=seg('<span>Elixir</span>')+sep()+seg(f'<span style="font-family:{MONO};font-size:11.5px">235:3</span>','padding-right:14px')
    return f'<div style="height:28px;flex:none;display:flex;align-items:center;background:#25262c;border-top:1px solid rgba(255,255,255,0.07);font-size:12px;color:#a5a39e;overflow:hidden">{"".join(parts)}<span style="flex:1"></span>{right}</div>'

NOTE='border:1px dashed rgba(255,255,255,0.22);border-radius:10px;background:rgba(20,21,26,0.92)'

# ---------- V41Edit
ladder = f'''
<div style="position:absolute;left:28px;right:28px;bottom:46px;{NOTE};padding:12px 16px 14px">
  <div style="color:#8f8d88;font-size:11.5px;font-style:italic;margin-bottom:10px">Board note, not UI: the same modeline as the window narrows. Filetype and position go first, then git, then Minga's words. Mode, needs you, file, change and errors stay.</div>
  <div style="display:flex;flex-direction:column;gap:8px">
    <div style="display:flex;align-items:center;gap:12px"><span style="width:70px;color:#8f8d88;font-size:11px;text-align:right">1440 pt</span><div style="width:1180px;border-radius:4px;overflow:hidden">{mline(0)}</div></div>
    <div style="display:flex;align-items:center;gap:12px"><span style="width:70px;color:#8f8d88;font-size:11px;text-align:right">1000 pt</span><div style="width:820px;border-radius:4px;overflow:hidden">{mline(1)}</div></div>
    <div style="display:flex;align-items:center;gap:12px"><span style="width:70px;color:#8f8d88;font-size:11px;text-align:right">700 pt</span><div style="width:560px;border-radius:4px;overflow:hidden">{mline(2)}</div></div>
  </div>
</div>'''
edit = HEAD.format(title="V4.1: editing, the modeline carries state") + titlebar() + f'''
<div style="flex:1;padding-top:16px;font-family:{MONO};font-size:13.5px;color:#c9c7c2;position:relative">
{code41()}
</div>
{ladder}
''' + mline(0) + TAIL
open(OUT+"V41Edit.dc.html","w").write(edit)

# ---------- V41WhichKey
def col(title, items):
    rows=[]
    for k,l,kc,note in items:
        n=f'<span class="n">{note}</span>' if note else ''
        rows.append(f'<div class="wk"><span class="k" style="color:{kc}">{k}</span><span class="l">{l}</span>{n}</div>')
    head=f'<div style="color:#8f8d88;font-size:11px;font-weight:600;margin:0 0 6px 32px">{title}</div>' if title else ''
    return f'<div style="min-width:230px">{head}{"".join(rows)}</div>'
W="#ecebe8"; GO="#b98cf0"
needs_badge=f'<span style="display:inline-flex;align-items:center;gap:5px;color:{A}">{st("Needs you",12)}1 needs you</span>'
work_badge=f'<span style="display:inline-flex;align-items:center;gap:5px;color:#b98cf0">{st("Working",12)}2/3</span>'
dim=lambda t: f'<span style="color:#6f7078;font-family:{MONO};font-size:11.5px">{t}</span>'
panel=f'''
<div style="position:absolute;left:0;right:0;bottom:28px;background:rgba(37,38,44,0.98);border-top:1px solid rgba(255,255,255,0.10);box-shadow:0 -18px 40px rgba(0,0,0,0.35);padding:14px 28px 16px">
  <div style="display:flex;align-items:center;gap:10px;margin-bottom:12px;font-size:12.5px">
    <span style="font-family:{MONO};color:#8f8d88">SPC</span><span style="color:#55575f">›</span>
    <span style="font-family:{MONO};color:{GO}">a</span><span style="font-weight:700;font-size:13.5px">Minga</span>
    <span style="color:#55575f">·</span>{work_badge}<span style="color:#55575f">·</span>{needs_badge}
    <span style="flex:1"></span><span style="color:#8f8d88;font-size:11.5px"><span style="font-family:{MONO}">⌫</span> back   <span style="font-family:{MONO}">esc</span> cancel</span>
  </div>
  <div style="display:flex;gap:40px">
    {col("Tasks",[("a","Tasks",W,f'<span style="color:{A}">· 1 needs you</span>'),("n","New task…",W,""),("i","Inspect a task",W,""),("w","Watch Minga",W,""),("s","Stop",R,dim("⌘."))])}
    {col("Conversation",[("v","Conversation",W,""),("f","Queue follow-up",W,""),("J","Queued inputs",W,""),("m","Model…",W,'<span>GPT-6.2 Sol</span>'),("h","Resume a session…",W,"")])}
    {col("Changes",[("r","Review",W,'<span style="color:#b98cf0">· 3</span>'),("u","Reject all…",W,""),("p","Publish edits",W,""),("e","Rewrite selection",W,""),("?","Ask about this line",W,"")])}
    {col("Context",[("b","Attach this buffer",W,""),("F","Attach a file…",W,""),("D","Attach diagnostics",W,f'<span style="color:{R}">· 1 error</span>'),("j","Draft attachments",W,"")])}
  </div>
</div>'''
inset=f'''
<div style="position:absolute;right:28px;top:48px;width:440px">
  <div style="color:#8f8d88;font-size:11.5px;font-style:italic;margin:0 0 6px 2px">Board note: the step before, after SPC alone</div>
  <div style="{NOTE};padding:12px 18px 14px">
    <div style="display:flex;align-items:center;gap:8px;margin-bottom:8px;font-size:12px"><span style="font-family:{MONO};color:#8f8d88">SPC</span><span style="font-weight:700">Leader</span></div>
    <div style="display:flex;gap:26px">
      {col("",[("SPC","Find file",W,""),(",","Switch buffer",W,""),("f","Files",GO,""),("b","Buffers",GO,""),("a","Minga",GO,f'<span style="color:{A}">· 1</span>')])}
      {col("",[("g","Git",GO,'<span>+11</span>'),("c","Code",GO,f'<span style="color:{R}">· 1</span>'),("s","Search",GO,""),("w","Windows",GO,"")])}
    </div>
  </div>
</div>'''
wk = HEAD.format(title="V4.1: SPC a, which-key") + titlebar() + f'''
<div style="flex:1;padding-top:16px;font-family:{MONO};font-size:13.5px;color:#c9c7c2;position:relative;opacity:0.55">
{code41()}
</div>
{panel}
{inset}
''' + mline(pending="SPC a") + TAIL
open(OUT+"V41WhichKey.dc.html","w").write(wk)

# ---------- V41Tasks
def act(k,label,kc=W,lc="#c9c7c2"):
    return f'<span class="act"><span class="k" style="color:{kc}">{k}</span><span style="color:{lc}">{label}</span></span>'
def row(state,goal,words,wcol,age,actions):
    return f'''<div style="display:flex;align-items:center;gap:12px;height:30px;padding:0 24px">
  {st(state,14)}<span style="color:#ecebe8;font-weight:600;min-width:400px">{goal}</span>
  <span style="color:{wcol};min-width:300px">{words}</span>
  <span style="flex:1"></span>{actions}<span style="color:#8f8d88;width:44px;text-align:right">{age}</span></div>'''
hint=lambda k,l: f'<span><span style="font-family:{MONO};color:#c9c7c2">{k}</span> {l}</span>'
drawer=f'''
<div style="height:356px;flex:none;background:#222329;border-top:1px solid rgba(255,255,255,0.14);display:flex;flex-direction:column;font-size:13px">
  <div style="display:flex;align-items:center;gap:12px;height:36px;padding:0 24px;border-bottom:1px solid rgba(255,255,255,0.06)">
    <span style="font-weight:700">Minga Tasks</span>
    <span style="display:inline-flex;align-items:center;gap:5px;color:{A}">{st("Needs you",12)}1</span>
    <span style="display:inline-flex;align-items:center;gap:5px;color:#b98cf0">{st("Working",12)}1</span>
    <span style="display:inline-flex;align-items:center;gap:5px;color:{G}">{st("Waiting",12)}1</span>
    <span style="display:inline-flex;align-items:center;gap:5px;color:{R}">{st("Failed",12)}1</span>
    <span style="display:inline-flex;align-items:center;gap:5px;color:{D}">{st("Done",12)}1</span>
    <span style="flex:1"></span>
    <span style="display:flex;gap:14px;color:#8f8d88;font-size:11.5px">{hint("j k","move")}{hint("/","filter")}{hint("↩","open")}{hint("x","stop task")}{hint("q","close")}</span>
  </div>
  <div style="padding:6px 0;flex:1">
    <div style="background:rgba(26,149,242,0.12);box-shadow:inset 2px 0 0 #1a95f2;padding:2px 0 12px">
      <div style="display:flex;align-items:center;gap:12px;height:30px;padding:0 24px">
        {st("Needs you",14)}<span style="color:#ecebe8;font-weight:600;min-width:400px">Add tests for the usage-limit classifier</span>
        <span style="color:{A};min-width:300px">Needs you · wants to create a file</span><span style="flex:1"></span><span style="color:#8f8d88;width:44px;text-align:right">2m</span>
      </div>
      <div style="margin-left:50px;color:#c9c7c2;line-height:20px">Create <span style="font-family:{MONO};font-size:12.5px;color:#ecebe8">test/minga_agent/usage_limit_test.exs</span> <span style="color:{D}">+86</span></div>
      <div style="margin-left:50px;color:#8f8d88;line-height:20px;font-style:italic">"Table tests for the classifier, including the recorded Pro response."</div>
      <div style="margin:10px 0 0 50px">{act("y","Approve once","#6cb8f5","#ecebe8")}{act("a","Always for this session")}{act("t","This turn")}{act("n","Deny",R)}{act("=","Show diff")}{act("↩","Open conversation")}</div>
    </div>
    {row("Working","Show the plan limit instead of “rate limited”","Editing chrome_state.ex · step 2 of 3","#b98cf0","4m",act("i","Inspect",W,"#8f8d88")+act("↩","Open",W,"#8f8d88"))}
    {row("Waiting","Refactor the picker sources","Waiting · rate limited, retry in 40 s",G,"9m",act("r","Retry now",W,"#8f8d88"))}
    {row("Failed","Run the session test suite","Failed · test run crashed",R,"11m",act("o","Output",W,"#8f8d88")+act("r","Retry",W,"#8f8d88"))}
    {row("Done","Update the agent docs for the Spine","Done · 2 files to review",D,"12m",act("↩","Review",W,"#8f8d88"))}
  </div>
</div>'''
tasks = HEAD.format(title="V4.1: Minga tasks drawer") + titlebar() + f'''
<div style="flex:1;padding-top:16px;font-family:{MONO};font-size:13.5px;color:#c9c7c2;position:relative;overflow:hidden;opacity:0.7">
{code41(n=15, you_line=None, minga_line=236)}
</div>
{drawer}
''' + mline(0, file="*minga-tasks*", dirty=False, change=False, minga_here=False) + TAIL
open(OUT+"V41Tasks.dc.html","w").write(tasks)

# ---------- V41Keys
TAG={"kept":("#7fbf7a","rgba(127,191,122,0.14)"),"changed":(A,"rgba(242,181,68,0.14)"),"new":("#6cb8f5","rgba(26,149,242,0.16)")}
def tag(t):
    c,b=TAG[t]; return f'<span style="padding:0 7px;border-radius:8px;background:{b};color:{c};font-size:10.5px;font-weight:600">{t}</span>'
def table(title, rows, sub=""):
    trs=[]
    for k,a,t,ln in rows:
        lnh=f'<span style="color:#6f7078;font-family:{MONO};font-size:11px">defaults.ex:{ln}</span>' if ln else ''
        tg=tag(t) if t else ''
        trs.append(f'<div style="display:flex;align-items:center;gap:10px;height:22px"><span style="font-family:{MONO};color:#ecebe8;width:122px;flex:none;font-size:12px;white-space:nowrap">{k}</span><span style="color:#c9c7c2;flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{a}</span>{tg}{lnh}</div>')
    s=f'<div style="color:#8f8d88;font-size:11px;margin:-4px 0 6px">{sub}</div>' if sub else ''
    return f'<div style="background:#24252b;border:1px solid rgba(255,255,255,0.06);border-radius:10px;padding:12px 14px"><div style="font-weight:700;font-size:13px;margin-bottom:8px">{title}</div>{s}{"".join(trs)}</div>'
leader=table("Leader SPC",[("SPC SPC","Find file in project","kept",122),(":","Commands, ⌘K","kept",39),("SPC ,","Switch buffer, file switcher","new",""),("SPC g k","Keep change at cursor","new",""),("SPC g r","Reject change at cursor","new",""),("SPC c x","Diagnostics list","new","")])
leadera=table("Leader SPC a  (Minga)",[("SPC a a","Tasks drawer","changed",138),("SPC a v","Conversation split","kept",140),("SPC a r","Review buffer","kept",158),("SPC a s","Stop, ⌘.","kept",141),("SPC a i","Inspect a task in a split","new",""),("SPC a w","Watch Minga in a split","new",""),("SPC a p","Publish agent edits","kept",159),("SPC a f","Queue follow-up","kept",165),("SPC a u","Reject all, asks first","changed",166),("SPC a J","Queued inputs buffer","kept","")])
infile=table("In a file",[("]h  [h","Next / previous Minga change","new",""),("ih  ah","Text object: one Minga change","new",""),("vah SPC g k","Keep every change in the selection","new",""),(".","Repeat keep or reject","new",""),(":'<,'>Minga keep","Keep a range (or reject)","new",""),("]d  [d","Next / previous diagnostic","",""),("K","Hover: diagnostic or docs","","")],"y n = Y q stay Vim here")
review=table("*minga-review*",[("y  n","Keep / reject change","",""),("=","Toggle inline diff","",""),("Y","Keep all, asks y/n first","",""),("]h  [h","Next / previous change","",""),("↩","Jump to the change in its file","",""),("q","Close","","")])
tasksk=table("*minga-tasks*",[("y a t n","Approve once, always, turn, deny","",""),("r","Retry (waiting and failed rows)","",""),("o","Output","",""),("i","Inspect","",""),("x","Stop task, asks first","",""),("↩","Open conversation or review","",""),("j k  /  q","Move, filter, close","","")])
switch=table("File switcher  SPC ,",[("↩","Open","",""),("⌃V","Open in split","",""),("⌃T","Pin or unpin","",""),("⌃J  ⌃K","Move","",""),("esc","Close","","")],"you type into the prompt, so actions use ⌃")
comp=table("Composer",[("↩","Newline (Insert)","",""),("↩  ⌘↩","Send or steer (Normal / any mode)","",""),("⌥↩","Queue next message","",""),("⌘.","Stop","","")])
rules=f'''<div style="display:flex;flex-direction:column;gap:10px">
<div style="border:1px solid rgba(164,99,230,0.45);border-radius:10px;padding:12px 14px;background:rgba(164,99,230,0.07)"><div style="font-weight:700;margin-bottom:4px">Undo is yours; Reject is for Minga</div><div style="color:#c9c7c2;line-height:18px">u and ⌘Z undo only your own edits. Minga's edits leave only through Reject, one Minga step at a time.</div></div>
<div style="border:1px solid rgba(26,149,242,0.45);border-radius:10px;padding:12px 14px;background:rgba(26,149,242,0.07)"><div style="font-weight:700;margin-bottom:4px">In a file, y n = Y q are always Vim</div><div style="color:#c9c7c2;line-height:18px">Bare letters act on Minga only in its own buffers, the way magit and fugitive do.</div></div>
<div style="color:#8f8d88;font-size:11.5px;line-height:17px;padding:0 4px">Notation: Mac glyphs for modifiers (⌃ ⌥ ⌘), leader sequences as SPC a a. Tags compare with lib/minga/keymap/defaults.ex today.</div>
</div>'''
keys = HEAD.format(title="V4.1: keys") + titlebar("Keys","V4.1 reference") + f'''
<div style="flex:1;padding:18px 24px;display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:14px;align-content:start;font-size:12.5px">
  <div style="display:flex;flex-direction:column;gap:14px">{leader}{infile}</div>
  <div style="display:flex;flex-direction:column;gap:14px">{leadera}{switch}</div>
  <div style="display:flex;flex-direction:column;gap:14px">{review}{tasksk}{comp}{rules}</div>
</div>
''' + TAIL
open(OUT+"V41Keys.dc.html","w").write(keys)
print("ok")
