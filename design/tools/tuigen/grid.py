import html
# palette (theme roles in go/tui/internal/ui/theme.go)
BG="#1e1f24"; SURF="#23242a"; SURF2="#2a2b32"; DIMBG="#1a1b1f"
TXT="#e6e4df"; SUB="#a5a39e"; DIM="#7a7c85"; FAINT="#55575f"; GHOST="#4a4c53"
BORDER="#62656f"; FOCUS="#5b9bd5"
BLUE="#6cb8f5"; BLUEB="#4f9fe0"; PURPLE="#b98cf0"; PURPLED="#a463e6"; PSHADE="#7a52b8"
AMBER="#f2b544"; RED="#e5707a"; GREEN="#7fbf7a"; SAND="#d8c08a"
KW="#ff7ab2"; STR="#a6d189"; MOD="#dabaff"; CMT="#7f8c98"; CODE="#c9c7c2"; FN="#8fc7ff"

class Grid:
    def __init__(s,w,h,bg=BG,fg=TXT):
        s.w,s.h=w,h
        s.c=[[[" ",fg,bg,""] for _ in range(w)] for _ in range(h)]
    def put(s,r,c,text,fg=None,bg=None,deco=None):
        for i,ch in enumerate(text):
            x=c+i
            if 0<=x<s.w and 0<=r<s.h:
                cell=s.c[r][x]; cell[0]=ch
                if fg: cell[1]=fg
                if bg: cell[2]=bg
                if deco is not None: cell[3]=deco
        return c+len(text)
    def segs(s,r,c,parts):
        for p in parts:
            t=p[0]; fg=p[1] if len(p)>1 else None; bg=p[2] if len(p)>2 else None; d=p[3] if len(p)>3 else None
            c=s.put(r,c,t,fg,bg,d)
        return c
    def fill(s,r,c,w,bg,fg=None):
        for x in range(c,min(c+w,s.w)):
            s.c[r][x][0]=" "; s.c[r][x][2]=bg
            if fg: s.c[r][x][1]=fg
    def bgrow(s,r,c,w,bg):
        for x in range(c,min(c+w,s.w)): s.c[r][x][2]=bg
    def rect(s,r,c,h,w,bg):
        for y in range(r,r+h): s.fill(y,c,w,bg)
    def box(s,r,c,h,w,bc,bg,title=None,right=None,bottom=None,bottom_right=None):
        s.rect(r,c,h,w,bg)
        s.put(r,c,"╭"+"─"*(w-2)+"╮",bc,bg); s.put(r+h-1,c,"╰"+"─"*(w-2)+"╯",bc,bg)
        for y in range(r+1,r+h-1): s.put(y,c,"│",bc,bg); s.put(y,c+w-1,"│",bc,bg)
        if title:
            x=c+2; s.put(r,x," ",None,bg); x+=1
            for p in title: x=s.put(r,x,p[0],p[1],bg,p[2] if len(p)>2 else None)
            s.put(r,x," ",None,bg)
        if right:
            L=sum(len(p[0]) for p in right)+2; x=c+w-2-L; s.put(r,x," ",None,bg); x+=1
            for p in right: x=s.put(r,x,p[0],p[1],bg)
            s.put(r,x," ",None,bg)
        if bottom:
            x=c+2; s.put(r+h-1,x," ",None,bg); x+=1
            for p in bottom: x=s.put(r+h-1,x,p[0],p[1],bg)
            s.put(r+h-1,x," ",None,bg)
        if bottom_right:
            L=sum(len(p[0]) for p in bottom_right)+2; x=c+w-2-L; s.put(r+h-1,x," ",None,bg); x+=1
            for p in bottom_right: x=s.put(r+h-1,x,p[0],p[1],bg)
            s.put(r+h-1,x," ",None,bg)
    def blit(s,o,r,c):
        for y in range(o.h):
            for x in range(o.w):
                if 0<=r+y<s.h and 0<=c+x<s.w: s.c[r+y][c+x]=list(o.c[y][x])
    def shadow(s,r,c,h,w,col="#0c0d10"):
        for y in range(r+1,r+h):
            if c+w<s.w: s.c[y][c+w][0]="▌"; s.c[y][c+w][1]=col
        for x in range(c+1,c+w):
            if r+h<s.h: s.c[r+h][x][0]="▀"; s.c[r+h][x][1]=col
        if r+h<s.h and c+w<s.w: s.c[r+h][c+w][0]="▘"; s.c[r+h][c+w][1]=col
    def map_colors(s,f):
        for row in s.c:
            for cell in row: cell[1]=f(cell[1]); cell[2]=f(cell[2])
    def html(s,cls="tg"):
        out=[]
        SH={PURPLED:"#4a2c75","#6a4f8f":"#33264a","#a463e6":"#4a2c75"}
        for row in s.c:
            for cell in row:
                if cell[0] in ("╳","┃") and cell[1] in SH:
                    cell[2]=SH[cell[1]]; cell[0]={"╳":"▚","┃":"▐"}[cell[0]]
            spans=[]; i=0
            while i<s.w:
                ch,fg,bg,d=row[i]
                if ord(ch)<128 or ch=="─":
                    j=i; buf=""
                    while j<s.w and (ord(row[j][0])<128 or row[j][0]=="─") and (row[j][0]=="─")==(ch=="─") and row[j][1:]==[fg,bg,d]:
                        buf+=row[j][0]; j+=1
                else:
                    buf=ch; j=i+1
                st=f"width:{len(buf)}ch;color:{fg};background-color:{bg};"
                inner=html.escape(buf)
                if ch=="─":
                    st+=f"background-image:linear-gradient(to bottom,transparent calc(50% - 0.5px),{fg} calc(50% - 0.5px),{fg} calc(50% + 0.5px),transparent calc(50% + 0.5px));"; inner=""
                elif buf in ("▌","▀","▘"):
                    if buf=="▌": st+=f"background-image:linear-gradient(to right,{fg} 50%,transparent 50%);"
                    elif buf=="▀": st+=f"background-image:linear-gradient(to bottom,{fg} 50%,transparent 50%);"
                    else: st+=f"background-image:linear-gradient(to right,{fg} 50%,transparent 50%);background-size:100% 50%;background-repeat:no-repeat;background-position:top;"
                    inner=""
                elif buf in JUNC:
                    vert=f"linear-gradient(to right,transparent calc(50% - 0.5px),{fg} calc(50% - 0.5px),{fg} calc(50% + 0.5px),transparent calc(50% + 0.5px))"
                    hor=f"linear-gradient(to bottom,transparent calc(50% - 0.5px),{fg} calc(50% - 0.5px),{fg} calc(50% + 0.5px),transparent calc(50% + 0.5px))"
                    (vs,vp),(hs,hp)=JUNC[buf]
                    st+=f"background-image:{vert},{hor};background-size:{vs},{hs};background-position:{vp},{hp};background-repeat:no-repeat;"
                    inner=""
                elif buf in ("▚","▐"):
                    L,S=fg,bg
                    if buf=="▐": st+=f"background-image:linear-gradient(to right,{S} 50%,{L} 50%);"
                    else: st+=f"background-image:linear-gradient(to right,{L} 50%,{S} 50%),linear-gradient(to right,{S} 50%,{L} 50%);background-size:100% 50%,100% 50%;background-position:top,bottom;background-repeat:no-repeat;"
                    inner=""
                elif buf in BOXV:
                    w=BOXV[buf]
                    st+=f"background-image:linear-gradient(to right,transparent calc(50% - {w/2}px),{fg} calc(50% - {w/2}px),{fg} calc(50% + {w/2}px),transparent calc(50% + {w/2}px));"; inner=""
                elif buf in CORN:
                    pos,sides,rad=CORN[buf]
                    bd=";".join(f"border-{x}:1px solid {fg}" for x in sides)
                    st+="position:relative;"; inner=f'<i style="position:absolute;{pos};{bd};border-{rad}-radius:6px"></i>'
                if d=="b": st+="font-weight:700;"
                elif d=="i": st+="font-style:italic;"
                elif d=="u": st+="text-decoration:underline wavy #e5707a;text-decoration-thickness:1.5px;text-underline-offset:3px;"
                elif d=="ud": st+="text-decoration:underline dotted #d8c08a;text-decoration-thickness:1.5px;text-underline-offset:3px;"
                elif d=="lk": st+=f"text-decoration:underline solid color-mix(in srgb,{fg} 45%,transparent);text-decoration-thickness:1px;text-underline-offset:3px;"
                elif d=="hc": st+=f"box-shadow:inset 0 0 0 1px {fg};"; inner=" "
                elif d=="bc": st+=f"background-color:{fg};color:{bg};"
                elif d=="bu": st+="font-weight:700;text-decoration:underline;text-underline-offset:3px;"
                spans.append(f'<span style="{st}">{inner}</span>')
                i=j
            out.append('<div class="r">'+"".join(spans)+'</div>')
        return f'<div class="{cls}">'+"".join(out)+'</div>'

BOXV={"│":1,"┃":2.5}
JUNC={"├":(("100% 100%","0 0"),("50% 100%","100% 0")),"└":(("100% 50%","0 0"),("50% 100%","100% 0")),
      "┌":(("100% 50%","0 100%"),("50% 100%","100% 0")),"┐":(("100% 50%","0 100%"),("50% 100%","0 0")),
      "┬":(("100% 50%","0 100%"),("100% 100%","0 0")),"┴":(("100% 50%","0 0"),("100% 100%","0 0")),
      "┘":(("100% 50%","0 0"),("50% 100%","0 0")),"┤":(("100% 100%","0 0"),("50% 100%","0 0"))}
CORN={"╭":("left:50%;top:50%;right:0;bottom:0",("left","top"),"top-left"),
      "╮":("left:0;top:50%;right:50%;bottom:0",("right","top"),"top-right"),
      "╰":("left:50%;top:0;right:0;bottom:50%",("left","bottom"),"bottom-left"),
      "╯":("left:0;top:0;right:50%;bottom:50%",("right","bottom"),"bottom-right")}

CSS=""".tg{font-family:'SF Mono',Menlo,ui-monospace,monospace;font-size:12px;line-height:15px;}
.tg .r{height:15px;white-space:pre;display:flex}
.tg .r span{display:inline-block;height:15px;line-height:15px;overflow:visible;text-align:left;flex:none}
.tg.small{font-size:10.5px;line-height:13px}.tg.small .r,.tg.small .r span{height:13px;line-height:13px}"""

def page(title,body,annot):
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{html.escape(title)}</title>
<script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
<style>
body{{margin:0}}
{CSS}
.an{{font-family:-apple-system,'SF Pro Text',system-ui,sans-serif;font-size:11.5px;line-height:16px;color:#a5a39e}}
.an h4{{margin:0 0 6px;font-size:12px;color:#e6e4df;font-weight:600}}
.an .it{{margin:0 0 9px}}
.an .k{{color:#e6e4df;font-weight:600}}
.an code{{font-family:'SF Mono',Menlo,monospace;font-size:10.5px;color:#b98cf0}}
</style>
</helmet>
<div style="width:1440px;height:900px;box-sizing:border-box;background:#141519;color:#e6e4df;font-family:-apple-system,system-ui,sans-serif;border-radius:12px;overflow:hidden;padding:20px 24px;display:flex;gap:22px">
{body}
<div class="an" style="width:250px;flex:none;padding-top:4px">{annot}</div>
</div>
</x-dc>
<script type="text/x-dc" data-dc-script data-props='{{"$preview":{{"width":1440,"height":900}}}}'>
class Component extends DCLogic {{
  renderVals() {{
    return {{}};
  }}
}}
</script>
</body>
</html>
"""

def term(grid_html,label,sub="",w=None):
    return f"""<div style="flex:none">
<div style="font-size:12px;color:#a5a39e;margin:0 0 6px"><span style="color:#e6e4df;font-weight:600">{label}</span>  {sub}</div>
<div style="border-radius:10px;overflow:hidden;border:1px solid #2e3038;box-shadow:0 10px 30px rgba(0,0,0,0.45);background:{BG}">
<div style="height:22px;background:#2a2b31;display:flex;align-items:center;gap:7px;padding:0 10px;font-size:11px;color:#8f8d88"><span style="width:10px;height:10px;border-radius:5px;background:#ff5f57"></span><span style="width:10px;height:10px;border-radius:5px;background:#febc2e"></span><span style="width:10px;height:10px;border-radius:5px;background:#28c840"></span><span style="flex:1;text-align:center">minga  ~/code/minga  zsh</span></div>
<div style="padding:2px 0">{grid_html}</div>
</div></div>"""

# Elixir line helpers
def code_line(g,r,num,parts,c0=0,sign=None,auth=None,numcol=DIM,curline=False,bgline=None):
    if bgline: g.bgrow(r,c0,g.w-c0,bgline)
    g.put(r,c0,f"{num:>5} ",numcol)
    if sign: g.put(r,c0+6,sign[0],sign[1],None,"b")
    if auth: g.put(r,c0+7,auth[0],auth[1])
    x=c0+9
    for p in parts:
        x=g.put(r,x,p[0],p[1] if len(p)>1 else CODE,None,p[2] if len(p)>2 else None)
    return x

# colour degradation
XT=[0,95,135,175,215,255]
def hex2rgb(h): h=h.lstrip('#'); return tuple(int(h[i:i+2],16) for i in (0,2,4))
def rgb2hex(t): return "#%02x%02x%02x"%t
def to256(h):
    r,g,b=hex2rgb(h)
    def q(v): return min(range(6),key=lambda i:abs(XT[i]-v))
    cube=(XT[q(r)],XT[q(g)],XT[q(b)])
    gi=min(range(24),key=lambda i:abs(8+10*i-(r+g+b)/3)); gray=(8+10*gi,)*3
    d=lambda a:sum((x-y)**2 for x,y in zip(a,(r,g,b)))
    return rgb2hex(cube if d(cube)<=d(gray) else gray)
ANSI16=[(0,0,0),(205,49,49),(13,188,121),(229,229,16),(36,114,200),(188,63,188),(17,168,205),(229,229,229),(102,102,102),(241,76,76),(35,209,139),(245,245,67),(59,142,234),(214,112,214),(41,184,219),(255,255,255)]
def to16(h):
    r,g,b=hex2rgb(h)
    if max(r,g,b)<70: return "#000000" if max(r,g,b)<45 else "#1e1e1e"
    return rgb2hex(min(ANSI16,key=lambda a:sum((x-y)**2 for x,y in zip(a,(r,g,b)))))
