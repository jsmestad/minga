import os as _os
TOOLS = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))
BOARDS = _os.environ.get("BOARDS_DIR", _os.path.join(TOOLS, "..", "boards"))  # committed boards, read only
OUT_DIR = _os.environ.get("OUT_DIR", _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "out"))
_os.makedirs(OUT_DIR, exist_ok=True)
W='<svg width="13" height="13" viewBox="0 0 16 16" aria-label="Working" style="flex:none;vertical-align:-2px"><circle cx="8" cy="8" r="5.5" fill="none" stroke="#a463e6" stroke-opacity="0.28" stroke-width="1.5"/><path d="M8 2.5 A5.5 5.5 0 0 1 13.5 8" fill="none" stroke="#a463e6" stroke-width="1.5" stroke-linecap="round"/><circle cx="13.5" cy="8" r="2.1" fill="#a463e6"/></svg>'
D='<svg width="13" height="13" viewBox="0 0 16 16" aria-label="Done" style="flex:none;vertical-align:-2px"><circle cx="8" cy="8" r="3.4" fill="#7fbf7a"/></svg>'
def g(s,size):
    return s.replace('width="13" height="13"',f'width="{size}" height="{size}"')
def step(glyph,text,right=""):
    return f'<div style="display:flex;align-items:center;gap:8px;font-size:12.5px;color:#a5a39e">{glyph}<span>{text}</span><span style="flex:1"></span><span>{right}</span></div>'
def started(glyph,name,cur=False):
    bg="background:rgba(108,184,245,0.10);border-radius:5px;margin:0 -8px;padding:0 8px;" if cur else ""
    return f'<div style="display:flex;align-items:center;gap:8px;font-size:12.5px;color:#a5a39e;height:22px;{bg}"><span style="width:52px">Started</span>{glyph}<span style="color:#dcdce2">{name}</span></div>'
left=f'''<div style="flex:1;min-width:0;display:flex;flex-direction:column;background:#1e1f24">
  <div class="mono" style="height:28px;flex:none;display:flex;align-items:center;gap:8px;padding:0 22px;border-bottom:1px solid rgba(255,255,255,0.06);font-size:12px;color:#a5a39e">{g(W,12)}<span style="color:#ecebe8;font-family:-apple-system,sans-serif">Review the marketing site for unfair claims</span><span style="flex:1"></span><span>8 min · GPT-6.2 Sol</span></div>
  <div style="flex:1;padding:18px 28px 0;display:flex;flex-direction:column;gap:16px;font-size:14px;line-height:17px;max-width:720px">
    <div><div style="color:#6cb8f5;font-size:11.5px;font-weight:600;margin-bottom:2px">You</div><div>Read the five site pages as a skeptical senior engineer coming from Hacker News. Any unfair claims about other editors? Any jargon that does not land?</div></div>
    <div><div style="color:#b98cf0;font-size:11.5px;font-weight:600;margin-bottom:2px">Minga</div><div style="color:#dcdce2">I will split this four ways: facts, fairness, jargon, and how skeptics react to change. Then I will put the hardest hits in one list.</div></div>
    <div style="display:flex;flex-direction:column;gap:2px">
      {started(W,"Fact-Check Auditor")}
      {started(W,"Competitive Fairness Critic")}
      {started(D,"Editorial and Jargon Roaster",True)}
      {started(W,"Driving Technical Change Skeptics")}
    </div>
    <div><div style="color:#b98cf0;font-size:11.5px;font-weight:600;margin-bottom:2px">Minga</div><div style="color:#dcdce2">1 of 4 reports in, from the Editorial and Jargon Roaster. Waiting on the other three before I put the findings together.</div></div>
    {step(W,'<span style="color:#b98cf0">3 subagents working</span>')}
  </div>
  <div style="margin:0 22px 12px;border:1px dashed rgba(255,255,255,0.16);border-radius:8px;padding:10px 12px 10px">
    <div style="font-size:11px;color:#8f8d88;margin-bottom:6px">Board note: <span class="mono" style="color:#b98cf0">SPC a a</span> shows the same task as a tree in the tasks drawer</div>
    <div class="mono" style="font-size:12px;line-height:17px;color:#c9c7c2">
      <div style="display:flex;align-items:center;gap:8px">{W}<span style="color:#ecebe8;font-weight:600;font-family:-apple-system,sans-serif">Review the marketing site for unfair claims</span><span style="flex:1"></span><span style="color:#a5a39e">1 of 4 reports in</span><span style="color:#7a7c85;width:30px;text-align:right">8m</span></div>
      <div style="display:flex;align-items:center;gap:8px"><span style="color:#62656f">├─</span>{W}<span style="width:270px">Fact-Check Auditor</span><span style="color:#a5a39e">reading compare.html</span><span style="flex:1"></span><span style="color:#7a7c85;width:30px;text-align:right">3m</span></div>
      <div style="display:flex;align-items:center;gap:8px"><span style="color:#62656f">├─</span>{W}<span style="width:270px">Competitive Fairness Critic</span><span style="color:#a5a39e">checking 9 claims</span><span style="flex:1"></span><span style="color:#7a7c85;width:30px;text-align:right">3m</span></div>
      <div style="display:flex;align-items:center;gap:8px;background:rgba(108,184,245,0.12);margin:0 -6px;padding:0 6px;border-radius:4px"><span style="color:#62656f">├─</span>{D}<span style="width:270px">Editorial and Jargon Roaster</span><span style="color:#7fbf7a">Done · sent to parent</span><span style="flex:1"></span><span style="color:#7a7c85;width:30px;text-align:right">3m</span></div>
      <div style="display:flex;align-items:center;gap:8px"><span style="color:#62656f">└─</span>{W}<span style="width:270px">Driving Technical Change Skeptics</span><span style="color:#a5a39e">persona 4 of 7</span><span style="flex:1"></span><span style="color:#7a7c85;width:30px;text-align:right">3m</span></div>
    </div>
  </div>
  <div class="mono" style="margin:0 22px 14px;padding:10px 12px;border-radius:8px;background:#23242a;border:1px solid rgba(255,255,255,0.08);min-height:44px;box-sizing:border-box;font-size:13px;color:#7a7c85">Tell Minga what to change next</div>
</div>'''
def strip():
    items=[(W,False),(W,False),(D,True),(W,False)]
    out=""
    for gl,sel in items:
        st="padding:3px 3px 2px;border-bottom:2px solid #6cb8f5;" if sel else "padding:3px 3px 2px;border-bottom:2px solid transparent;"
        out+=f'<span style="display:inline-flex;{st}">{g(gl,12)}</span>'
    return out
right=f'''<div style="width:620px;flex:none;display:flex;flex-direction:column;background:#222329;border-left:1px solid rgba(108,184,245,0.55)">
  <div style="flex:none;padding:8px 20px 8px;border-bottom:1px solid rgba(255,255,255,0.06)">
    <div style="display:flex;align-items:center;gap:8px;font-size:12px;color:#a5a39e"><span style="color:#8f8d88">Review the marketing site</span><span style="color:#62656f">›</span>{g(D,12)}<span style="color:#ecebe8;font-weight:600;font-size:13px">Editorial and Jargon Roaster</span><span style="flex:1"></span><span style="display:inline-flex;align-items:center;gap:2px">{strip()}</span><span class="mono" style="margin-left:6px;color:#a5a39e">3 of 4</span></div>
    <div style="display:flex;align-items:center;gap:14px;margin-top:4px;font-size:12px;color:#a5a39e"><span style="color:#7fbf7a">Done</span><span>worked 3m</span><span>GPT-6.2 Sol</span><span style="flex:1"></span>
      <span class="mono"><span class="k" style="color:#6cb8f5">]]</span>next</span><span class="mono"><span class="k" style="color:#6cb8f5">[[</span>prev</span><span class="mono"><span class="k" style="color:#6cb8f5">za</span>fold</span><span class="mono"><span class="k" style="color:#6cb8f5">q</span>close</span></div>
  </div>
  <div style="flex:1;overflow:hidden;padding:14px 22px 0;display:flex;flex-direction:column;gap:16px;font-size:13px;line-height:17px">
    <div>
      <div style="display:flex;align-items:center;gap:8px;font-size:12px;color:#a5a39e"><span style="color:#7a7c85">▸</span><span style="color:#dcdce2;font-weight:600">Brief</span><span>from Minga, the parent task</span></div>
      <div style="margin:3px 0 0 16px;color:#7a7c85;font-size:12.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">You are a ruthless editorial and jargon roaster. Read all five site pages as a skeptical senior engineer who writes Go or Rust…</div>
    </div>
    <div>
      <div style="display:flex;align-items:center;gap:8px;font-size:12px;color:#a5a39e;margin-bottom:6px"><span style="color:#7a7c85">▾</span><span style="color:#dcdce2;font-weight:600">So far</span></div>
      <div style="display:flex;flex-direction:column;gap:6px;margin-left:16px">
        {step(D,'Read <span class="mono" style="font-size:12px;color:#dcdce2">index</span>, <span class="mono" style="font-size:12px;color:#dcdce2">guides</span>, <span class="mono" style="font-size:12px;color:#dcdce2">compare</span>, <span class="mono" style="font-size:12px;color:#dcdce2">pricing</span> and <span class="mono" style="font-size:12px;color:#dcdce2">about</span>')}
        {step(D,'Flagged 14 phrases that only make sense to Elixir insiders')}
        {step(D,'Checked every comparison against its linked source')}
        {step(D,'Ranked the findings by what they cost a first-time reader')}
      </div>
    </div>
    <div>
      <div style="display:flex;align-items:center;gap:8px;font-size:12px;color:#a5a39e;margin-bottom:6px"><span style="color:#7a7c85">▾</span><span style="color:#dcdce2;font-weight:600">Result</span><span>sent to parent · 2 min ago</span></div>
      <div style="margin-left:16px;padding:10px 14px;border-left:2px solid rgba(127,191,122,0.6);background:rgba(127,191,122,0.05);border-radius:0 6px 6px 0;color:#dcdce2;font-size:13px;line-height:20px;display:flex;flex-direction:column;gap:7px">
        <div>1. “BEAM-powered” appears six times before it is explained. Lead with what it does for the reader.</div>
        <div>2. “Supervision tree” on the home page is jargon for a Hacker News reader. Move it below the fold.</div>
        <div>3. The VS Code comparison calls it “bloated”. That reads as a cheap shot; show startup numbers instead.</div>
        <div style="color:#a5a39e">11 more findings in the full report.</div>
      </div>
    </div>
  </div>
  <div class="mono" style="margin:10px 16px 14px;padding:10px 12px;border-radius:8px;background:#2b2c33;border:1px solid rgba(255,255,255,0.09);min-height:44px;box-sizing:border-box;font-size:13px;color:#7a7c85">Message this subagent</div>
</div>'''
head=open(BOARDS+'/V41Talk.dc.html').read()
pre=head[:head.index('</div><div style="flex:1;display:flex;min-height:0">')]
pre=pre.replace("<title>V4.1: talking to Minga</title>","<title>V4.1: peeking at a subagent</title>")
pre=pre.replace('<span style="font-weight:600">Show the plan limit instead of “rate limited”</span>  <span style="color:#8f8d88">with chrome_state.ex · main</span>','<span style="font-weight:600">Review the marketing site for unfair claims</span>  <span style="color:#8f8d88">with Editorial and Jargon Roaster · main</span>')
mode=f'''<div style="height:28px;flex:none;display:flex;align-items:center;gap:16px;padding:0 12px;background:#24252b;border-top:1px solid rgba(255,255,255,0.06);font-size:12px;color:#a5a39e">
  <span style="padding:1px 8px;border-radius:5px;background:rgba(108,184,245,0.22);color:#6cb8f5;font-weight:700;font-size:11px" class="mono">NORMAL</span>
  <span style="color:#ecebe8">*minga: Editorial and Jargon Roaster*</span>
  <span>main +11</span>
  <span style="display:flex;align-items:center;gap:6px;color:#b98cf0">{W}Minga 3 subagents working</span>
  <span style="flex:1"></span>
  <span class="mono">12:1</span>
</div>'''
tail='''</div>
</x-dc>
<script type="text/x-dc" data-dc-script data-props='{"$preview":{"width":1440,"height":900}}'>
class Component extends DCLogic {
  renderVals() {
    return {};
  }
}
</script>
</body>
</html>'''
out=pre+'</div><div style="flex:1;display:flex;min-height:0">'+left+right+'</div>'+mode+tail
open(OUT_DIR+"/V41SubagentMac.dc.html","w").write(out)
