import re,sys,colorsys
FRAPPE=dict(mauve="CA9EE6",red="E78284",peach="EF9F76",yellow="E5C890",green="A6D189",teal="81C8BE",blue="8CAAEE",pink="F4B8E4",lavender="BABBF1",sky="99D1DB",
 ramp=["232634","292C3C","303446","414559","51576D","626880","737994","838BA7","949CBB","A5ADCE","B5BFE2","C6D0F5"],light=False)
LATTE=dict(mauve="8839EF",red="D20F39",peach="FE640B",yellow="DF8E1D",green="40A02B",teal="179299",blue="1E66F5",pink="EA76CB",lavender="7287FD",sky="04A5E5",
 ramp=["DCE0E8","E6E9EF","EFF1F5","CCD0DA","BCC0CC","ACB0BE","9CA0B0","8C8FA1","7C7F93","6C6F85","5C5F77","4C4F69"],light=True)
# Minga roles -> theme accents
HUES=[(240,"lavender"),(275,"mauve"),(210,"blue"),(38,"peach"),(355,"red"),(105,"green"),(48,"yellow"),(330,"pink"),(175,"teal"),(195,"sky")]
def hsl(h):
    r,g,b=(int(h[i:i+2],16)/255 for i in (0,2,4)); H,L,S=colorsys.rgb_to_hls(r,g,b); return H*360,S,L
def mapc(h,T):
    H,S,L=hsl(h)
    if S<0.2 or L<0.18:
        ramp=T["ramp"]
        # dark default palette lightness 0.10..0.90 -> ramp index
        t=max(0,min(1,(L-0.10)/0.80))
        i=round(t*(len(ramp)-1))
        if T["light"]:
            # keep backgrounds light, text dark: backgrounds (low L) map to the light end
            order=["EFF1F5","E6E9EF","DCE0E8","CCD0DA","BCC0CC","ACB0BE","9CA0B0","8C8FA1","7C7F93","6C6F85","5C5F77","4C4F69"]
            return order[i]
        return ramp[i]
    name=min(HUES,key=lambda x:min(abs(x[0]-H),360-abs(x[0]-H)))[1]
    base=T[name]
    if L<0.35:  # dark tints of an accent (e.g. twist shade, tinted chips): blend toward background
        bg=T["ramp"][2] if not T["light"] else "EFF1F5"
        a=0.45
        mix=lambda x,y:"%02X"%round(int(x,16)*a+int(y,16)*(1-a))
        return "".join(mix(base[i:i+2],bg[i:i+2]) for i in (0,2,4))
    return base
T={"frappe":FRAPPE,"latte":LATTE}[sys.argv[1]]
s=open(sys.argv[2]).read()
s=re.sub(r"#([0-9a-fA-F]{6})\b",lambda m:"#"+mapc(m.group(1),T),s)
if T["light"]:
    s=re.sub(r"rgba\(255,\s*255,\s*255,",r"rgba(0,0,0,",s)
open(sys.argv[3],"w").write(s)
