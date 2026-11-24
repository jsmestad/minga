import os as _os
TOOLS = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))
BOARDS = _os.environ.get("BOARDS_DIR", _os.path.join(TOOLS, "..", "boards"))  # committed boards, read only
OUT_DIR = _os.environ.get("OUT_DIR", _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "out"))
_os.makedirs(OUT_DIR, exist_ok=True)
import os
OUT=OUT_DIR+'/'
P="#a463e6";A="#f2b544";G="#a5a39e";R="#e5707a";D="#7fbf7a";BG="#1e1f24"
def st(lab,size=14):
    body={
    "Working":f'<circle cx="8" cy="8" r="5.5" fill="none" stroke="{P}" stroke-opacity="0.28" stroke-width="1.5"/><path d="M8 2.5 A5.5 5.5 0 0 1 13.5 8" fill="none" stroke="{P}" stroke-width="1.5" stroke-linecap="round"/><circle cx="13.5" cy="8" r="2.1" fill="{P}"/>',
    "Needs you":f'<circle cx="8" cy="8" r="6" fill="{A}" fill-opacity="0.25"/><circle cx="8" cy="8" r="3.4" fill="{A}"/>',
    "Waiting":f'<circle cx="8" cy="8" r="3" fill="none" stroke="{G}" stroke-width="1.6"/>',
    "Failed":f'<rect x="4.6" y="4.6" width="6.8" height="6.8" rx="1.2" fill="{R}" transform="rotate(45 8 8)"/>',
    "Done":f'<circle cx="8" cy="8" r="3.4" fill="{D}"/>'}[lab]
    return f'<svg width="{size}" height="{size}" viewBox="0 0 16 16" aria-label="{lab}" style="flex:none">{body}</svg>'
H=26
def tw_head(bg=BG): return f'<svg width="10" height="{H}" viewBox="0 0 10 {H}" aria-label="Minga changed these lines" style="display:block;overflow:visible"><path d="M7 5 C7 11, 3 11, 3 17 L3 {H}" fill="none" stroke="#6b3fa3" stroke-width="2.6" stroke-linecap="round"/><path d="M3 5 C3 11, 7 11, 7 17 L7 {H}" fill="none" stroke="{bg}" stroke-width="5" stroke-linecap="round"/><path d="M3 5 C3 11, 7 11, 7 17 L7 {H}" fill="none" stroke="#a463e6" stroke-width="2.6" stroke-linecap="round"/></svg>'
def tw_body(shade="#6b3fa3"): return f'<svg width="10" height="{H}" viewBox="0 0 10 {H}" aria-hidden="true" style="display:block"><path d="M3 0 L3 {H}" stroke="{shade}" stroke-width="2.6"/><path d="M7 0 L7 {H}" stroke="#a463e6" stroke-width="2.6"/></svg>'
def tw_last(shade="#6b3fa3"): return f'<svg width="10" height="{H}" viewBox="0 0 10 {H}" aria-hidden="true" style="display:block"><path d="M3 0 L3 19" stroke="{shade}" stroke-width="2.6" stroke-linecap="round"/><path d="M7 0 L7 19" stroke="#a463e6" stroke-width="2.6" stroke-linecap="round"/></svg>'
def you(): return f'<svg width="10" height="{H}" viewBox="0 0 10 {H}" aria-label="Your uncommitted change" style="display:block"><path d="M5 0 L5 {H}" stroke="#4f9fe0" stroke-width="1.5"/></svg>'
def kw(t): return f'<span style="color:#ff7ab2">{t}</span>'
def mod(t): return f'<span style="color:#dabaff">{t}</span>'
def s_(t): return f'<span style="color:#a6d189">{t}</span>'
def cm(t): return f'<span style="color:#7f8c98">{t}</span>'
def err(t): return f'<span style="text-decoration: underline wavy {R}; text-decoration-skip-ink:none; text-underline-offset:3px">{t}</span>'

CODE=[
 (229,"",'',f'{kw("defp")} chrome_state(ws) {kw("do")}',''),
 (230,"",'',f'  %{{status: workspace_agent_status(ws), limit: usage_limit(ws)}}',''),
 (231,"",'',f'{kw("end")}',''),
 (232,"",'','',''),
 (233,"",'',cm("# Status comes from one owner: the session's presence."),''),
 (234,"",tw_head(),f'{kw("@spec")} workspace_agent_status({mod("Workspace")}.t()) :: {mod("AgentPresence")}.state()',''),
 (235,"",tw_body(),f'{kw("defp")} workspace_agent_status(ws) {kw("do")}',''),
 (236,"",tw_body(),f'  ws |&gt; payload() |&gt; {mod("AgentPresence")}.of()','minga'),
 (237,"",tw_last(),f'{kw("end")}',''),
 (238,"",'','',''),
 (239,"",you(),f'{kw("defp")} usage_limit(ws) {kw("do")}',''),
 (240,"err",you(),f'  ws |&gt; payload() |&gt; {err("limit_label")}()','you'),
 (241,"",you(),f'{kw("end")}',''),
 (242,"",'','',''),
 (243,"",'',f'{kw("def")} agent_label(%{{state: :working, action: a}}), {kw("do")}: a',''),
 (244,"",'',f'{kw("def")} agent_label(%{{state: :needs_you}}), {kw("do")}: {s_(chr(34)+"Needs you"+chr(34))}',''),
 (245,"",'',f'{kw("def")} agent_label(%{{state: :done}}), {kw("do")}: {s_(chr(34)+"Done"+chr(34))}',''),
 (246,"",'',f'{kw("def")} agent_label(_), {kw("do")}: {s_(chr(34)+chr(34))}',''),
 (247,"",'','',''),
 (248,"",'',f'{kw("defp")} payload(%{mod("Workspace")}{{payload: p}}), {kw("do")}: p',''),
]
def code_lines(n=None, cursor_msg=True):
    out=[]
    rows=CODE if n is None else CODE[:n]
    for num,flag,mark,text,extra in rows:
        sign=''
        if flag=="err": sign=f'<span style="display:block;width:3px;height:12px;border-radius:1.5px;background:{R};margin:0 auto"></span>'
        cur=''
        bg=''
        if extra=='minga':
            cur=f'<span style="display:inline-block;width:2px;height:16px;background:{P};vertical-align:-3px;margin-left:1px"></span><span style="margin-left:6px;padding:0 6px;border-radius:4px;background:{P};color:#fff;font-family:-apple-system,sans-serif;font-size:10.5px;line-height:16px;vertical-align:1px">Minga</span>'
        if extra=='you':
            bg='background:rgba(255,255,255,0.035);'
            cur=f'<span style="display:inline-block;width:8px;height:17px;background:#6cb8f5;opacity:0.85;vertical-align:-4px;margin-left:1px"></span>'
            if cursor_msg: cur+=f'<span style="margin-left:28px;color:#8e8e93;font-style:italic;font-family:-apple-system,sans-serif;font-size:12px">elixir: undefined function limit_label/1</span>'
        numc = "#c9c7c2" if extra=='you' else "#7a7c85"
        out.append(f'<div class="ln" style="{bg}"><span class="num" style="color:{numc}">{num}</span><span class="sign">{sign}</span><span class="bar">{mark}</span><span class="code">{text}{cur}</span></div>')
    return "\n".join(out)

def titlebar(title="chrome_state.ex", path="lib/minga_editor/session"):
    return f'''<div style="height:30px;flex:none;display:flex;align-items:center;gap:12px;padding:0 14px;background:#222329;border-bottom:1px solid rgba(255,255,255,0.06);position:relative">
  <div style="display:flex;gap:8px"><span style="width:12px;height:12px;border-radius:6px;background:#ff5f57"></span><span style="width:12px;height:12px;border-radius:6px;background:#febc2e"></span><span style="width:12px;height:12px;border-radius:6px;background:#28c840"></span></div>
  <span style="font-family:'Instrument Serif',serif;font-style:italic;font-size:15px;color:#8f8d88">minga</span>
  <div style="position:absolute;left:0;right:0;text-align:center;pointer-events:none;font-size:12.5px"><span style="font-weight:600">{title}</span>  <span style="color:#8f8d88">{path}</span></div>
</div>'''

def seg(html, extra=""): return f'<span style="display:flex;align-items:center;gap:6px;padding:0 10px;height:100%;{extra}">{html}</span>'
def sep(): return '<span style="width:1px;height:14px;background:rgba(255,255,255,0.09)"></span>'
def modeline(mode="NORMAL", modecol="#6cb8f5", modebg="rgba(26,149,242,0.22)", pending=None, file="chrome_state.ex"):
    branch=f'<svg width="11" height="11" viewBox="0 0 16 16" aria-hidden="true"><circle cx="4" cy="3.5" r="2" fill="none" stroke="#8f8d88" stroke-width="1.5"/><circle cx="4" cy="12.5" r="2" fill="none" stroke="#8f8d88" stroke-width="1.5"/><circle cx="12" cy="5.5" r="2" fill="none" stroke="#8f8d88" stroke-width="1.5"/><path d="M4 5.5 L4 10.5 M12 7.5 C12 10 4 9 4 10.5" fill="none" stroke="#8f8d88" stroke-width="1.5"/></svg>'
    left = f'''<span style="display:flex;align-items:center;padding:0 12px;height:100%;background:{modebg};color:{modecol};font-weight:700;font-size:11px;letter-spacing:0.04em">{mode}</span>
    {seg(f'<span style="color:#ecebe8;font-weight:600">{file}</span><span style="color:#6cb8f5">●</span>')}{sep()}
    {seg(f'{branch}<span>main</span><span style="color:#8f8d88">+11 −3</span>')}{sep()}
    {seg(f'{st("Working",13)}<span style="color:#b98cf0">Minga</span><span style="color:#c9c7c2">editing chrome_state.ex</span><span style="color:#8f8d88">2/3</span>')}{sep()}
    {seg(f'{st("Needs you",13)}<span style="color:{A}">Needs you</span><span style="color:#8f8d88;font-family:ui-monospace,monospace;font-size:11px">SPC a a</span>')}{sep()}
    {seg(f'<span style="color:{R}">1 error</span><span style="color:#8f8d88">·</span><span style="color:#c9c7c2">1 warning</span>')}'''
    if pending:
        left = f'''<span style="display:flex;align-items:center;padding:0 12px;height:100%;background:{modebg};color:{modecol};font-weight:700;font-size:11px;letter-spacing:0.04em">{mode}</span>{seg(f'<span style="font-family:ui-monospace,monospace;color:#ecebe8">{pending}</span><span style="color:#8f8d88">waiting for a key</span>')}'''
    return f'''<div style="height:28px;flex:none;display:flex;align-items:center;background:#25262c;border-top:1px solid rgba(255,255,255,0.07);font-size:12px;color:#a5a39e">
  {left}
  <span style="flex:1"></span>
  {seg('<span>Elixir</span>')}{sep()}{seg('<span style="font-family:ui-monospace,monospace;font-size:11.5px">240:31</span>')}{seg('<span style="color:#8f8d88">72%</span>','padding-right:14px')}
</div>'''

HEAD='''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{title}</title>
<script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Instrument+Serif:ital@0;1&display=swap" rel="stylesheet">
<style>
body{{margin:0}}
a{{color:#ecebe8;text-decoration:none}}a:hover{{color:#ffffff}}
.ln{{display:flex;align-items:center;height:26px}}
.num{{width:56px;text-align:right;padding-right:8px;flex:none}}
.sign{{width:8px;flex:none;display:flex;align-items:center}}
.bar{{width:10px;height:26px;flex:none;margin:0 4px 0 2px;position:relative}}
.code{{padding-left:10px;white-space:pre}}
.wk{{display:flex;align-items:baseline;gap:10px;height:25px;font-size:13px}}
.wk .k{{font-family:ui-monospace,'SF Mono',Menlo,monospace;font-size:13px;width:22px;text-align:right;flex:none}}
.wk .l{{color:#dcdce2}}
.wk .g{{color:#b98cf0}}
.wk .n{{color:#8f8d88;font-size:12px}}
.act{{display:inline-flex;align-items:baseline;gap:6px;margin-right:22px}}
.act .k{{font-family:ui-monospace,'SF Mono',Menlo,monospace;font-weight:700}}
</style>
</helmet>
<div style="width:1440px;height:900px;box-sizing:border-box;background:#1e1f24;color:#ecebe8;font-family:-apple-system,'SF Pro Text',system-ui,sans-serif;display:flex;flex-direction:column;font-size:13px;border-radius:12px;overflow:hidden;position:relative">
'''
TAIL='''
</div>
</x-dc>
<script type="text/x-dc" data-dc-script data-props='{"$preview":{"width":1440,"height":900}}'>
class Component extends DCLogic {
  renderVals() {
    return {};
  }
}
</script>
</body>
</html>
'''
NAV='''<div style="position:absolute;right:16px;top:40px;display:flex;gap:12px;font-size:11.5px;color:#6cb8f5;opacity:0.8"><a href="V4Edit.dc.html" style="color:#6cb8f5">Editing</a><a href="V4WhichKey.dc.html" style="color:#6cb8f5">SPC a</a><a href="V4Tasks.dc.html" style="color:#6cb8f5">Tasks</a></div>'''

# ---------- V4Edit
edit = HEAD.format(title="V4: editing while Minga works") + titlebar() + NAV + f'''
<div style="flex:1;padding-top:16px;font-family:ui-monospace,'SF Mono',Menlo,monospace;font-size:13.5px;color:#c9c7c2;position:relative">
{code_lines()}
</div>
''' + modeline() + TAIL
open(OUT+"V4Edit.dc.html","w").write(edit)

# ---------- V4WhichKey
def col(title, items, extra=""):
    rows=[]
    for k,l,kind,note in items:
        kc = {"go":"#b98cf0","you":"#6cb8f5","act":"#ecebe8","amber":A,"red":R}.get(kind,"#ecebe8")
        lab_style = 'class="g"' if kind=="go" else 'class="l"'
        n = f'<span class="n">{note}</span>' if note else ''
        rows.append(f'<div class="wk"><span class="k" style="color:{kc}">{k}</span><span {lab_style}>{l}</span>{n}</div>')
    return f'<div style="min-width:230px;{extra}"><div style="color:#8f8d88;font-size:11px;font-weight:600;margin:0 0 6px 32px">{title}</div>{"".join(rows)}</div>'

needs_badge = f'<span style="display:inline-flex;align-items:center;gap:5px;color:{A}">{st("Needs you",12)}1 needs you</span>'
work_badge = f'<span style="display:inline-flex;align-items:center;gap:5px;color:#b98cf0">{st("Working",12)}editing 2/3</span>'
panel = f'''
<div style="position:absolute;left:0;right:0;bottom:28px;background:rgba(37,38,44,0.97);border-top:1px solid rgba(255,255,255,0.10);box-shadow:0 -18px 40px rgba(0,0,0,0.35);padding:14px 28px 16px">
  <div style="display:flex;align-items:center;gap:10px;margin-bottom:12px;font-size:12.5px">
    <span style="font-family:ui-monospace,'SF Mono',Menlo,monospace;color:#8f8d88">SPC</span><span style="color:#55575f">›</span>
    <span style="font-family:ui-monospace,'SF Mono',Menlo,monospace;color:#b98cf0">a</span>
    <span style="font-weight:700;font-size:13.5px;color:#ecebe8">Minga</span>
    <span style="color:#55575f">·</span>{work_badge}<span style="color:#55575f">·</span>{needs_badge}
    <span style="flex:1"></span>
    <span style="color:#8f8d88;font-size:11.5px"><span style="font-family:ui-monospace,monospace">⌫</span> back   <span style="font-family:ui-monospace,monospace">esc</span> cancel</span>
  </div>
  <div style="display:flex;gap:40px">
    {col("Tasks",[("a","Tasks","act",f'<span style="color:{A}">· 1 needs you</span>'),("n","New task…","act",""),("p","Peek at a task","act",""),("w","Follow Minga","act",""),("s","Stop","red","")])}
    {col("Conversation",[("v","Conversation split","act",""),("q","Queue next message","act",""),("m","Model…","act",'<span>GPT-6.2 Sol</span>'),("T","Thinking…","act",'<span>medium</span>'),("h","Resume a session…","act","")])}
    {col("Changes",[("r","Review changes","act",'<span style="color:#b98cf0">· 3 to review</span>'),("Y","Keep all","act",""),("u","Reject all","act",""),("e","Rewrite selection","act",""),("?","Ask about this line","act","")])}
    {col("Context",[("b","Attach this buffer","act",""),("F","Attach a file…","act",""),("D","Attach diagnostics","act",f'<span style="color:{R}">· 1 error</span>'),("j","Draft attachments","act","")])}
  </div>
</div>'''
inset = f'''
<div style="position:absolute;right:28px;top:56px;width:400px;background:rgba(37,38,44,0.98);border:1px solid rgba(255,255,255,0.10);border-radius:10px;box-shadow:0 20px 50px rgba(0,0,0,0.5);padding:12px 18px 14px">
  <div style="display:flex;align-items:center;gap:8px;margin-bottom:8px;font-size:12px"><span style="font-family:ui-monospace,monospace;color:#8f8d88">SPC</span><span style="font-weight:700">Leader</span><span style="flex:1"></span><span style="color:#8f8d88;font-size:11px">one step earlier</span></div>
  <div style="display:flex;gap:26px">
    {col("",[("f","Files","go",""),("b","Buffers","go",""),("a","Minga","go",f'<span style="color:{A}">· 1</span>'),("g","Git","go",'<span>+11</span>')])}
    {col("",[("c","Code","go",f'<span style="color:{R}">· 1</span>'),("s","Search","go",""),("w","Windows","go",""),("SPC","Commands","act","")])}
  </div>
</div>'''
wk = HEAD.format(title="V4: SPC a, which-key") + titlebar() + NAV + f'''
<div style="flex:1;padding-top:16px;font-family:ui-monospace,'SF Mono',Menlo,monospace;font-size:13.5px;color:#c9c7c2;position:relative;opacity:0.55">
{code_lines(cursor_msg=False)}
</div>
{panel}
{inset}
<div style="position:absolute;left:28px;top:632px;color:#8f8d88;font-size:11.5px;font-style:italic;max-width:720px">Appears after a short pause. Type through it at full speed and it never shows. Purple keys open a group; the counts are live.</div>
''' + modeline(mode="NORMAL", pending="SPC a") + TAIL
open(OUT+"V4WhichKey.dc.html","w").write(wk)

# ---------- V4Tasks
def act(k,label,kc="#ecebe8",lc="#c9c7c2"):
    return f'<span class="act"><span class="k" style="color:{kc}">{k}</span><span style="color:{lc}">{label}</span></span>'
def row(state,goal,words,wcol,age,action,focused=False):
    bg = "background:rgba(26,149,242,0.10);box-shadow:inset 2px 0 0 #1a95f2;" if focused else ""
    return f'''<div style="display:flex;align-items:center;gap:12px;height:30px;padding:0 24px;{bg}">
  {st(state,14)}<span style="color:#ecebe8;font-weight:600;min-width:420px">{goal}</span>
  <span style="color:{wcol};min-width:300px">{words}</span>
  <span style="flex:1"></span>{action}<span style="color:#8f8d88;width:60px;text-align:right">{age}</span></div>'''
drawer = f'''
<div style="height:372px;flex:none;background:#222329;border-top:1px solid rgba(255,255,255,0.10);display:flex;flex-direction:column;font-size:13px">
  <div style="display:flex;align-items:center;gap:12px;height:34px;padding:0 24px;border-bottom:1px solid rgba(255,255,255,0.06)">
    <span style="font-weight:700">Minga tasks</span>
    <span style="color:#55575f">·</span><span style="display:inline-flex;align-items:center;gap:5px;color:{A}">{st("Needs you",12)}1 needs you</span>
    <span style="display:inline-flex;align-items:center;gap:5px;color:#b98cf0">{st("Working",12)}1 working</span>
    <span style="display:inline-flex;align-items:center;gap:5px;color:{G}">{st("Waiting",12)}1 waiting</span>
    <span style="display:inline-flex;align-items:center;gap:5px;color:{R}">{st("Failed",12)}1 failed</span>
    <span style="display:inline-flex;align-items:center;gap:5px;color:{D}">{st("Done",12)}1 done</span>
    <span style="flex:1"></span><span style="color:#8f8d88;font-size:11.5px">*minga-tasks*</span>
  </div>
  <div style="padding:6px 0;flex:1">
    <div style="background:rgba(26,149,242,0.10);box-shadow:inset 2px 0 0 #1a95f2;padding:2px 0 12px">
      <div style="display:flex;align-items:center;gap:12px;height:30px;padding:0 24px">
        {st("Needs you",14)}<span style="color:#ecebe8;font-weight:600;min-width:420px">Add tests for the usage-limit classifier</span>
        <span style="color:{A};min-width:300px">Needs you · wants to create a file</span><span style="flex:1"></span><span style="color:#8f8d88;width:60px;text-align:right">2m</span>
      </div>
      <div style="margin-left:50px;color:#c9c7c2;line-height:20px">Create <span style="font-family:ui-monospace,monospace;font-size:12.5px;color:#ecebe8">test/minga_agent/usage_limit_test.exs</span> <span style="color:{D}">+86</span></div>
      <div style="margin-left:50px;color:#8f8d88;line-height:20px;font-style:italic">"Table tests for the classifier, including the recorded Pro response."</div>
      <div style="margin:10px 0 0 50px;font-size:13px">
        {act("y","Approve once","#6cb8f5","#ecebe8")}{act("a","Always for this session")}{act("t","This turn")}{act("n","Deny",R)}{act("v","Show diff")}{act("↩","Open conversation")}
      </div>
    </div>
    {row("Working","Show the plan limit instead of “rate limited”","Editing chrome_state.ex · step 2 of 3","#b98cf0","4m",act("p","Peek","#ecebe8","#8f8d88"))}
    {row("Waiting","Refactor the picker sources","Waiting · rate limited, retry in 40 s",G,"9m",act("r","Retry now","#ecebe8","#8f8d88"))}
    {row("Failed","Run the session test suite","Failed · test run crashed",R,"11m",act("l","Log","#ecebe8","#8f8d88"))}
    {row("Done","Update the agent docs for the Spine","Done · 2 files to review",D,"12m",act("r","Review","#ecebe8","#8f8d88"))}
  </div>
  <div style="height:26px;display:flex;align-items:center;padding:0 24px;color:#8f8d88;font-size:11.5px;border-top:1px solid rgba(255,255,255,0.05)"><span style="font-family:ui-monospace,monospace">j/k</span>&nbsp;move · <span style="font-family:ui-monospace,monospace">&nbsp;/</span>&nbsp;filter · <span style="font-family:ui-monospace,monospace">&nbsp;q</span>&nbsp;close</div>
</div>'''
tasks = HEAD.format(title="V4: Minga tasks drawer") + titlebar() + NAV + f'''
<div style="flex:1;padding-top:16px;font-family:ui-monospace,'SF Mono',Menlo,monospace;font-size:13.5px;color:#c9c7c2;position:relative;overflow:hidden;opacity:0.7">
{code_lines(n=16, cursor_msg=False)}
</div>
{drawer}
''' + modeline(mode="TASKS", modecol="#b98cf0", modebg="rgba(164,99,230,0.20)", file="*minga-tasks*").replace('<span style="color:#6cb8f5">●</span>','') + TAIL
open(OUT+"V4Tasks.dc.html","w").write(tasks)
print("ok")
