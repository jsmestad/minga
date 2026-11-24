"""Tiny CSS-keyframe timeline helpers for looping 'screen recording' boards (no JavaScript)."""
import html, re

# Catppuccin Frappé
BASE="#303446"; MANTLE="#292C3C"; CRUST="#232634"; S0="#414559"; S1="#51576D"; S2="#626880"
OV0="#737994"; OV1="#838BA7"; SUB0="#A5ADCE"; TXT="#C6D0F5"
MAUVE="#CA9EE6"; BLUE="#8CAAEE"; PEACH="#EF9F76"; RED="#E78284"; GREEN="#A6D189"; YELLOW="#E5C890"; TEAL="#81C8BE"
SHADE="#6f5a8a"; ACCENT="#0A84FF"  # twist shade (mauve over base); macOS system accent for native menus

class TL:
    def __init__(self, D):
        self.D=D; self.css=[]; self.n=0
    def p(self,t):
        return max(0.0,min(100.0,round(t/self.D*100,3)))
    def _name(self,prefix):
        self.n+=1; return f"{prefix}{self.n}"
    def _emit(self,name,frames,prop_fn,easing=None):
        out=[]
        seen=set()
        for pc,v in sorted(frames,key=lambda x:x[0]):
            key=round(pc,3)
            while key in seen: key=round(key+0.001,3)
            seen.add(key)
            ez=f"animation-timing-function:{easing};" if easing else ""
            out.append(f"{key}%{{{prop_fn(v)}{ez}}}")
        self.css.append(f"@keyframes {name}{{{''.join(out)}}}")
        self.css.append(f".{name}{{animation:{name} {self.D}s linear infinite}}")
        return name
    def vis(self,segs,fade=0.12):
        """Opacity timeline. segs: list of (t_on, t_off). Returns a class name."""
        def val(t):
            return 1 if any(a<=t<=b for a,b in segs) else 0
        pts={0.0:val(0.0),100.0:val(self.D)}
        for a,b in segs:
            if a>0: pts[self.p(max(0,a-fade))]=0; pts[self.p(a)]=1
            if b<self.D: pts[self.p(b)]=1; pts[self.p(min(self.D,b+fade))]=0
        frames=sorted(pts.items())
        return self._emit(self._name("v"),frames,lambda v:f"opacity:{v};")
    def path(self,pts,step=False):
        """Pointer movement. pts: list of (t,x,y). Returns class name (transform translate)."""
        frames=[(0.0,(pts[0][1],pts[0][2]))]+[(self.p(t),(x,y)) for t,x,y in pts]+[(100.0,(pts[-1][1],pts[-1][2]))]
        ez="steps(1,end)" if step else "cubic-bezier(.45,0,.25,1)"
        return self._emit(self._name("m"),frames,lambda v:f"transform:translate({v[0]}px,{v[1]}px);",ez)
    def ripple(self,t,dur=0.45):
        """Click ripple at time t: returns class name (scale + opacity)."""
        a=self.p(t); b=self.p(min(self.D,t+dur)); a0=max(0,a-0.01)
        frames=[(0,(0,0.2)),(a0,(0,0.2)),(a,(0.55,0.3)),(b,(0,1.7)),(100,(0,1.7))]
        return self._emit(self._name("r"),frames,lambda v:f"opacity:{v[0]};transform:translate(-50%,-50%) scale({v[1]});")
    def style(self):
        return "\n".join(self.css)

def esc(s): return html.escape(s, quote=False)

def ab(x,y,inner,w=None,h=None,cls="",style=""):
    ws=f"width:{w}px;" if w is not None else ""; hs=f"height:{h}px;" if h is not None else ""
    return f'<div class="{cls}" style="position:absolute;left:{x}px;top:{y}px;{ws}{hs}{style}">{inner}</div>'

POINTER='<svg width="18" height="26" viewBox="0 0 18 26" style="display:block"><path d="M1 1 L1 20 L5.4 15.6 L8.5 23.2 L11.7 21.9 L8.6 14.6 L14.9 14.6 Z" fill="#000" stroke="#fff" stroke-width="1.4" stroke-linejoin="round"/></svg>'

def pointer(tl,pts):
    cls=tl.path(pts)
    return f'<div class="{cls}" style="position:absolute;left:-1px;top:-1px;z-index:99;pointer-events:none;filter:drop-shadow(0 1px 1px rgba(0,0,0,.5))">{POINTER}</div>'

def ripples(tl,clicks,color="#ffffff"):
    out=[]
    for t,x,y in clicks:
        c=tl.ripple(t)
        out.append(f'<div class="{c}" style="position:absolute;left:{x}px;top:{y}px;width:34px;height:34px;border-radius:50%;border:2px solid {color};background:rgba(255,255,255,.18);z-index:98;pointer-events:none"></div>')
    return "".join(out)

# ---------- Elixir-ish highlighter (Frappé roles) ----------
KW={"def","defp","do","end","when","fn"}
def hl(src):
    out=[]; i=0
    toks=re.findall(r'#.*$|"[^"]*"|:\w+|@\w+|[A-Z]\w*(?:\.\w+)*|\w+|\s+|.',src)
    prev=""
    for t in toks:
        if t.startswith("#"): out.append(f'<span style="color:{OV1};font-style:italic">{esc(t)}</span>')
        elif t.startswith('"'): out.append(f'<span style="color:{GREEN}">{esc(t)}</span>')
        elif t.startswith("@"): out.append(f'<span style="color:{MAUVE}">{esc(t)}</span>')
        elif t.startswith(":") and len(t)>1: out.append(f'<span style="color:{TEAL}">{esc(t)}</span>')
        elif t in KW: out.append(f'<span style="color:{MAUVE}">{esc(t)}</span>')
        elif t[:1].isupper(): out.append(f'<span style="color:{YELLOW}">{esc(t)}</span>')
        elif re.match(r"\w+$",t) and prev.strip() in ("def","defp","|>","."): out.append(f'<span style="color:{BLUE}">{esc(t)}</span>')
        else: out.append(esc(t))
        if t.strip(): prev=t
    return "".join(out)

def twist(kind,H=18,bg=BASE):
    if kind=="head":
        return (f'<svg width="10" height="{H}" viewBox="0 0 10 {H}" style="display:block;overflow:visible">'
                f'<path d="M7 3 C7 8, 3 8, 3 12 L3 {H}" fill="none" stroke="{SHADE}" stroke-width="2.4" stroke-linecap="round"/>'
                f'<path d="M3 3 C3 8, 7 8, 7 12 L7 {H}" fill="none" stroke="{bg}" stroke-width="4.6" stroke-linecap="round"/>'
                f'<path d="M3 3 C3 8, 7 8, 7 12 L7 {H}" fill="none" stroke="{MAUVE}" stroke-width="2.4" stroke-linecap="round"/></svg>')
    if kind=="body":
        return (f'<svg width="10" height="{H}" viewBox="0 0 10 {H}" style="display:block"><path d="M3 0 L3 {H}" stroke="{SHADE}" stroke-width="2.4"/>'
                f'<path d="M7 0 L7 {H}" stroke="{MAUVE}" stroke-width="2.4"/></svg>')
    if kind=="last":
        return (f'<svg width="10" height="{H}" viewBox="0 0 10 {H}" style="display:block"><path d="M3 0 L3 {H-4}" stroke="{SHADE}" stroke-width="2.4" stroke-linecap="round"/>'
                f'<path d="M7 0 L7 {H-4}" stroke="{MAUVE}" stroke-width="2.4" stroke-linecap="round"/></svg>')
    return ""

LH=18
def code_block(lines,y0=48,cursor=None,err=None,width=1360):
    """lines: list of (num, text, twistkind|None, sign|None). Returns html of absolutely placed rows."""
    out=[]
    for i,(n,t,tw,sign) in enumerate(lines):
        y=y0+i*LH
        cur= (n==cursor)
        bg=f"background:{S0}55;" if cur else ""
        body=hl(t)
        if err and n==err[0]:
            a,b=err[1],err[2]
            body=hl(t[:a])+f'<span style="text-decoration:underline wavy {RED};text-underline-offset:3px">{hl(t[a:b])}</span>'+hl(t[b:])
        sg=""
        if sign=="E": sg=f'<span style="position:absolute;left:50px;top:3px;width:3px;height:12px;border-radius:1.5px;background:{RED}"></span>'
        if sign=="W": sg=f'<span style="position:absolute;left:50px;top:3px;width:3px;height:12px;border-radius:1.5px;border:1.5px solid {YELLOW};box-sizing:border-box"></span>'
        tws=f'<span style="position:absolute;left:58px;top:0">{twist(tw)}</span>' if tw else ""
        out.append(f'<div style="position:absolute;left:0;top:{y}px;width:{width}px;height:{LH}px;{bg}font-family:\'SF Mono\',Menlo,ui-monospace,monospace;font-size:13px;line-height:{LH}px;color:{TXT}">'
                   f'<span style="position:absolute;left:0;width:44px;text-align:right;color:{TXT if cur else OV0}">{n}</span>{sg}{tws}'
                   f'<span style="position:absolute;left:80px;white-space:pre">{body}</span></div>')
    return "".join(out)

def board(title,label,sub,window_html,caption_html,storyboard_steps,tl,extra_css="",right_html=""):
    steps="".join(f'<li>{esc(s)}</li>' for s in storyboard_steps)
    return f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>{esc(title)}</title><script src="./support.js"></script></head><body><x-dc>
<helmet><link rel="preconnect" href="https://fonts.googleapis.com"><link href="https://fonts.googleapis.com/css2?family=Instrument+Serif:ital@0;1&display=swap" rel="stylesheet"><style>body{{margin:0}}
{tl.style()}
{extra_css}
.sb{{display:none}}
@media (prefers-reduced-motion: reduce){{ .stage *{{animation:none!important}} .stage{{display:none}} .sb{{display:block}} }}
</style></helmet>
<div style="width:1440px;height:900px;box-sizing:border-box;background:{CRUST};color:{TXT};font-family:-apple-system,system-ui,sans-serif;border-radius:12px;overflow:hidden;position:relative">
<div style="position:absolute;left:40px;top:14px;font-size:13px;color:{OV1}"><b style="color:{TXT};font-weight:600">{esc(label)}</b> &nbsp;{esc(sub)} &nbsp;<span style="color:{OV0}">· loops</span></div>
<div class="stage">{window_html}{caption_html}{right_html}</div>
<div class="sb" style="position:absolute;left:40px;top:60px;width:1360px;font-size:14px;line-height:24px;color:{TXT}"><div style="color:{OV1};margin-bottom:8px">Reduced motion: the steps, without animation</div><ol>{steps}</ol></div>
</div>
</x-dc><script type="text/x-dc" data-dc-script data-props='{{"$preview":{{"width":1440,"height":900}}}}'>class Component extends DCLogic {{ renderVals() {{ return {{}}; }} }}</script></body></html>'''

def captions(tl,items,x=40,y=820,w=1360):
    out=[f'<div style="position:absolute;left:{x}px;top:{y}px;width:{w}px;height:44px;border-radius:10px;background:{MANTLE};border:1px solid {S0}"></div>']
    for i,(a,b,text) in enumerate(items):
        c=tl.vis([(a,b)],fade=0.15)
        out.append(f'<div class="{c}" style="position:absolute;left:{x+18}px;top:{y+11}px;width:{w-36}px;font-size:15px;line-height:22px;color:{TXT}"><span style="color:{MAUVE};font-weight:600;margin-right:10px">{i+1}</span>{esc(text)}</div>')
    return "".join(out)

def macwin(inner,x=40,y=80,w=1360,h=700,title_html=""):
    return (f'<div style="position:absolute;left:{x}px;top:{y}px;width:{w}px;height:{h}px;border-radius:10px;background:{BASE};box-shadow:0 18px 50px rgba(0,0,0,.55);border:1px solid {S0};overflow:visible">'
            f'<div style="position:absolute;left:0;top:0;width:{w}px;height:36px;background:{MANTLE};border-radius:10px 10px 0 0;border-bottom:1px solid {S0}"></div>'
            f'<span style="position:absolute;left:14px;top:12px;width:12px;height:12px;border-radius:6px;background:#ff5f57"></span>'
            f'<span style="position:absolute;left:34px;top:12px;width:12px;height:12px;border-radius:6px;background:#febc2e"></span>'
            f'<span style="position:absolute;left:54px;top:12px;width:12px;height:12px;border-radius:6px;background:#28c840"></span>'
            f'<span style="position:absolute;left:80px;top:8px;font-family:\'Instrument Serif\',serif;font-style:italic;font-size:17px;color:{OV1}">minga</span>'
            f'<div style="position:absolute;left:0;top:10px;width:{w}px;text-align:center;font-size:13px">{title_html}</div>'
            f'{inner}</div>')
