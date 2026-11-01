import math, cairosvg, io, json
from PIL import Image
def arc(cx,cy,r,gap):
    a0=math.radians(90+gap); a1=math.radians(90-gap+360)
    x0,y0=cx+r*math.cos(a0),cy+r*math.sin(a0); x1,y1=cx+r*math.cos(a1),cy+r*math.sin(a1)
    return f"M{x0:.1f},{y0:.1f} A{r},{r} 0 1 1 {x1:.1f},{y1:.1f}"
def star(cx,cy,R,k=0.22):
    # 4-point concave star with quadratic curves
    p=[(cx,cy-R),(cx+R,cy),(cx,cy+R),(cx-R,cy)]
    d=f"M{p[0][0]},{p[0][1]}"
    for i in range(4):
        a,b=p[i],p[(i+1)%4]
        d+=f" Q{cx+(a[0]+b[0]-2*cx)*k:.1f},{cy+(a[1]+b[1]-2*cy)*k:.1f} {b[0]},{b[1]}"
    return d+"Z"
TH={
 "light":dict(bg=[("0","#FCD789"),("0.45","#E9B48A"),("0.7","#C99AA6"),("1","#8A6CC0")],wave="#9C7FD0",waveop=.45),
 "dark":dict(bg=[("0","#2B3160"),("0.5","#1A1B42"),("1","#130F2E")],wave="#8E86E8",waveop=.28),
}
def app(theme,inset,rad):
    t=TH[theme]; s=1024-2*inset
    stops="".join(f'<stop offset="{o}" stop-color="{c}"/>' for o,c in t["bg"])
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
<defs><linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">{stops}</linearGradient>
<linearGradient id="st" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FFD27A"/><stop offset="0.35" stop-color="#FF86B0"/><stop offset="0.65" stop-color="#55D8FA"/><stop offset="1" stop-color="#7063FB"/></linearGradient>
<radialGradient id="glow"><stop offset="0" stop-color="#FFFFFF" stop-opacity=".35"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></radialGradient>
<clipPath id="c"><rect x="{inset}" y="{inset}" width="{s}" height="{s}" rx="{rad}"/></clipPath>
<filter id="sh" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="10" stdDeviation="12" flood-color="#000" flood-opacity=".22"/></filter></defs>
<g clip-path="url(#c)"><rect width="1024" height="1024" fill="url(#bg)"/>
<path d="M{inset},{700} C300,560 600,640 1024,330 L1024,1024 L{inset},1024Z" fill="{t['wave']}" opacity="{t['waveop']*0.5}"/>
<path d="M430,1024 C560,760 760,640 1024,250 L1024,1024Z" fill="{t['wave']}" opacity="{t['waveop']}"/></g>
<circle cx="512" cy="497" r="150" fill="url(#glow)"/>
<path d="{arc(512,470,252,31)}" fill="none" stroke="#FFFFFF" stroke-width="46" stroke-linecap="round" filter="url(#sh)"/>
<path d="{star(512,497,142)}" fill="url(#st)"/></svg>'''
def mono(color="#000000"):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64">
<path d="{arc(32,30,25,33)}" fill="none" stroke="{color}" stroke-width="7" stroke-linecap="round"/>
<path d="{star(32,32,13,0.2)}" fill="{color}"/></svg>'''
out={}
for th in TH:
    out[f"app-{th}.svg"]=app(th,100,185)      # macOS grid
    out[f"app-{th}-win.svg"]=app(th,32,200)   # Windows, near full bleed
out["tray-mono.svg"]=mono()
out["tray-mono-white.svg"]=mono("#FFFFFF")
for k,v in out.items(): open(k,"w").write(v)
def png(svg,size): return Image.open(io.BytesIO(cairosvg.svg2png(bytestring=svg.encode(),output_width=size,output_height=size)))
for th in TH:
    png(out[f"app-{th}.svg"],1024).save(f"app-{th}-1024.png")
    sizes=[16,24,32,48,64,128,256]
    ims=[png(out[f"app-{th}-win.svg"],s) for s in sizes]
    ims[-1].save(f"AISubGauge-{th}.ico",sizes=[(s,s) for s in sizes],append_images=ims[:-1])
    for s,im in zip(sizes,ims): im.save(f"ico-{th}-{s}.png")
for s in [16,18,20,24,32,36,64]:
    png(out["tray-mono.svg"],s).save(f"tray-mono-{s}.png"); png(out["tray-mono-white.svg"],s).save(f"tray-mono-white-{s}.png")
