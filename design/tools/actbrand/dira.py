# Direction A act menu ("decision first"), shared by every board that draws an act menu.
# exec() this file inside a generator that already defines MONO, CUR, B (marks), G (tuigen grid) and blit.
# Mirrors actbrand/ab.py so ActMenu_DirectionA and the batch boards stay identical.

ACC="#b98cf0"
EDGE={"minga":"#a463e6","failure":"#e5707a","neutral":"rgba(255,255,255,0.22)"}
TINT={"minga":"rgba(164,99,230,0.14)","failure":"rgba(229,112,122,0.12)","neutral":"rgba(108,184,245,0.14)"}
RING={"minga":"rgba(164,99,230,0.55)","failure":"rgba(229,112,122,0.5)","neutral":"rgba(108,184,245,0.55)"}
SF="-apple-system,'SF Pro Text',system-ui,sans-serif"

def a_head(glyph,title,meta,role,filt=None,compact=False):
    """One header line: state glyph, target in words, and a dim "› filter" hint at the right.
    Only while typing does a second line show the input."""
    pad="8px 14px 7px" if not compact else "7px 12px 6px"
    caret=EDGE[role] if role!="neutral" else "#a5a39e"
    g=f'<span style="display:inline-flex">{glyph}</span>' if glyph else ''
    hint='' if (filt or compact) else f'<span style="flex:1"></span><span style="font-family:{MONO};font-size:11px;color:#6e7079;white-space:nowrap"><span style="color:{caret}">›</span> filter</span>'
    line=(f'<div style="display:flex;align-items:center;gap:7px;white-space:nowrap">{g}'
      f'<span style="font-size:12.5px;font-weight:600;color:#ecebe8">{title}</span><span style="font-size:12px;color:#8f8d88">{meta}</span>{hint}</div>')
    typed=(f'<div style="margin-top:6px;display:flex;align-items:center;gap:5px;font-family:{MONO};font-size:12px"><span style="color:{caret};font-weight:700">›</span><span style="color:#ecebe8">{filt}</span>{CUR}</div>' if filt else '')
    return f'<div style="padding:{pad}">{line}{typed}</div>'

def a_glabel(t):
    # dim label followed by a thin rule to the edge
    return (f'<div style="display:flex;align-items:center;gap:8px;padding:6px 14px 2px;font-size:11px;font-weight:600;color:#7a7c85;letter-spacing:0.01em">'
            f'<span style="white-space:nowrap">{t}</span><span style="flex:1;height:1px;background:rgba(255,255,255,0.08)"></span></div>')
def a_row(key,label,note="",direct="",sel=False,role="minga"):
    bg=f"background:{TINT[role]};box-shadow:inset 0 0 0 1px {RING[role]};" if sel else ""
    n=f'<span style="color:#8f8d88;font-size:11.5px;margin-left:8px;white-space:nowrap">{note}</span>' if note else ""
    d=f'<span style="font-family:{MONO};font-size:11px;color:#6e7079;white-space:nowrap">{direct}</span>' if direct else ""
    return (f'<div style="height:24px;display:flex;align-items:center;margin:0 6px;padding:0 8px;border-radius:6px;{bg}">'
      f'<span style="width:22px;flex:none;font-family:{MONO};font-size:12.5px;font-weight:700;color:{ACC}">{key}</span>'
      f'<span style="font-size:12.5px;color:{"#f2f1ee" if sel else "#dcdce2"};white-space:nowrap">{label}</span>{n}<span style="flex:1"></span>{d}</div>')
def a_foot(show=True,entry="g.  ⌃.  right-click"):
    if not show: return ""
    return (f'<div style="margin-top:4px;padding:5px 14px;border-top:1px solid rgba(255,255,255,0.06);display:flex;gap:14px;font-size:11px;color:#7a7c85">'
      f'<span><span style="font-family:{MONO};color:#c9c7c2">↩</span> run</span><span><span style="font-family:{MONO};color:#c9c7c2">j k</span> move</span><span><span style="font-family:{MONO};color:#c9c7c2">esc</span> close</span>'
      f'<span style="flex:1"></span><span style="font-family:{MONO}">{entry}</span></div>')
def a_half(key,label,cons,direct,sel,role):
    # Two centred rows: "key Label", then the consequence with the direct key (if any) after it.
    if sel: st=f"background:{TINT[role]};box-shadow:inset 0 0 0 1px {RING[role]};"
    else:   st="background:rgba(255,255,255,0.035);box-shadow:inset 0 0 0 1px rgba(255,255,255,0.08);"
    dk=f'<span style="font-family:{MONO};font-size:10.5px;color:#6e7079;margin-left:8px">{direct}</span>' if direct else ''
    sub=(f'<div style="margin-top:2px;font-size:11.5px;color:#a5a39e;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{cons}{dk}</div>' if (cons or direct) else "")
    return (f'<div style="flex:1 1 0;min-width:0;border-radius:8px;padding:7px 10px;text-align:center;{st}">'
      f'<div style="display:flex;align-items:baseline;justify-content:center;gap:8px"><span style="font-family:{MONO};font-size:14px;font-weight:700;color:{ACC}">{key}</span>'
      f'<span style="font-size:13.5px;font-weight:600;color:#f2f1ee;white-space:nowrap">{label}</span></div>{sub}</div>')
def a_decision(pair,role):
    return f'<div style="display:flex;gap:6px;padding:2px 10px 6px">{"".join(a_half(*p,role) for p in pair)}</div>'
def a_primary(key,label,cons,direct,role):
    return f'<div style="padding:2px 10px 6px">{a_half(key,label,cons,direct,True,role)}</div>'
def a_shell(inner,role,w,left,top,extra=""):
    return (f'<div style="position:absolute;left:{left}px;top:{top}px;width:{w}px;background:#26272e;border:1px solid rgba(255,255,255,0.10);border-left:3px solid {EDGE[role]};'
      f'border-radius:9px;box-shadow:0 16px 38px rgba(0,0,0,0.55),0 1px 0 rgba(255,255,255,0.04) inset;font-family:{SF};color:#dcdce2;overflow:hidden;text-align:left;{extra}">{inner}</div>')

def menuA(glyph,title,meta,role,top,groups,w=400,left=0,top_px=0,filt=None,foot=True,compact=False,entry="g.  ⌃.  right-click"):
    """top: ("decision",[(key,label,cons,direct,sel),(...)]) | ("primary",(key,label,cons,direct)) | None.
    groups: [(label, [(key,label,note,direct), ...]), ...]; destructive rows go last and are never preselected."""
    body=a_head(glyph,title,meta,role,filt=filt,compact=compact)
    if top and top[0]=="decision": body+=a_decision(top[1],role)
    elif top and top[0]=="primary": body+=a_primary(*top[1],role)
    for lab,rows in groups:
        if lab: body+=a_glabel(lab)
        for r in rows:
            k,l=r[0],r[1]; note=r[2] if len(r)>2 else ""; d=r[3] if len(r)>3 else ""; sel=len(r)>4 and r[4]
            body+=a_row(k,l,note,d,sel=sel,role=role)
    body+=a_foot(foot,entry)
    return a_shell(body,role,w,left,top_px)

# ---------- TUI: Lip Gloss rounded panel in the target's role colour.
# Header in the top border with a dim "› filter" hint at the right; the decision bar is two equal halves,
# two rows each; section headers are dim labels with a rule; the panel is exactly as tall as its content;
# editor behind dims, the gutter beside the panel is covered, half-block drop shadow.
def _trole(role):
    return {"minga":G.PURPLED,"failure":G.RED,"neutral":G.BORDER}[role]
RAISED="#34363e"
def _dim_editor(g):
    for row in g.c:
        for cell in row:
            if cell[0]!=" " and cell[1] not in (None,): cell[1]=G.FAINT
def tmenuA(g,r,c,w,role,title,top,groups,bottom=None,filt=None,cover_gutter=True,dim=True):
    MP=_trole(role)
    rows_n=(1 if filt else 0)+(3 if top else 0)+sum((1 if lab else 0)+len(rr) for lab,rr in groups)
    h=rows_n+2
    if dim: _dim_editor(g)
    d=G.Grid(w,h,bg=SURF)
    bottom=bottom or [("↩",G.TXT),(" run  ",G.DIM),("j k",G.TXT),(" move  ",G.DIM),("esc",G.TXT),(" close",G.DIM)]
    d.box(0,0,h,w,MP,SURF,title=title,right=None if filt else [("›",MP),(" filter",G.DIM)],bottom=bottom)
    y=1
    if filt:
        d.segs(y,2,[("›",MP,None,"b"),(" ",None),(filt,G.TXT),("▏",G.BLUE)]); y+=1
    inner=w-4  # cells between the border padding
    if top:
        if top[0]=="decision": halves=[(k,l,cn,sel) for (k,l,cn,_,sel) in top[1]]
        else:
            k,l,cn,_=top[1]; halves=[(k,l,cn,True)]
        n=len(halves); gap=1; hw=(inner-gap*(n-1))//n
        x=2
        for i,(k,l,cn,sel) in enumerate(halves):
            if i==n-1: hw=inner-(x-2)  # the last half runs to the border
            bg=MP if sel else RAISED; fg="#1e1f24" if sel else G.TXT; sub="#2a2340" if sel else G.DIM
            d.rect(y,x,2,hw,bg)
            t1=f"{k} {l}"; t2=cn or ""
            if len(t2)>hw-2: t2=t2.replace(" lines","")
            if len(t2)>hw-2: t2=t2[:hw-3]+"…"
            d.put(y,x+(hw-len(t1))//2,t1,fg,bg,"b")
            if t2: d.put(y+1,x+(hw-len(t2))//2,t2,sub if sel else G.DIM,bg)
            x+=hw+gap
        y+=3  # two rows plus one blank row below the bar
    for lab,rr in groups:
        if lab:
            d.put(y,2,lab,G.DIM); d.put(y,2+len(lab)+1,"─"*(w-4-len(lab)-1),"#62656f"); y+=1
        for row in rr:
            k,l=row[0],row[1]; note=row[2] if len(row)>2 else ""; dk=row[3] if len(row)>3 else ""
            d.put(y,2,k,G.PURPLE,None,"b"); d.put(y,5,l,G.TXT)
            x=5+len(l)
            if note and x+2+len(note)<w-3-len(dk): d.put(y,x+2,note,G.DIM)
            if dk: d.put(y,w-2-len(dk),dk,G.DIM)
            y+=1
    if cover_gutter:
        for yy in range(r,min(r+h,g.h)):
            for xx in range(0,min(c,g.w)): g.c[yy][xx]=[" ",G.FAINT,G.BG,""]
    blit(g,d,r,c)
    g.shadow(r,c,h,w)
    return h
