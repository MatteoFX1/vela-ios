# Live check: for British speed cameras mapped beside the road (not on it) with a direction,
# does the side of the road they stand on agree with the direction? Traffic keeps left, so a
# camera checking traffic going one way stands on that traffic's left. Kite 0.7.6 only skips a
# camera when both say it checks the other way.
import json, math, urllib.request, urllib.parse, sys
Q = """[out:json][timeout:240];area["ISO3166-1"="GB"][admin_level=2]->.gb;
node[highway=speed_camera][direction](area.gb)->.c;
.c out;
way(around.c:30)[highway~"^(motorway|trunk|primary|secondary|tertiary|unclassified|residential|motorway_link|trunk_link|primary_link)$"];out tags geom;"""
data = None
for ep in ["https://overpass-api.de/api/interpreter","https://overpass.kumi.systems/api/interpreter","https://overpass.private.coffee/api/interpreter"]:
    try:
        req = urllib.request.Request(ep, data=("data="+urllib.parse.quote(Q)).encode(), headers={"User-Agent":"Kite-check"})
        data = json.load(urllib.request.urlopen(req, timeout=300)); break
    except Exception as e: print("mirror failed", ep, e, file=sys.stderr)
els = data["elements"]
cams = [e for e in els if e["type"]=="node"]
ways = [e for e in els if e["type"]=="way"]
PTS = "N NNE NE ENE E ESE SE SSE S SSW SW WSW W WNW NW NNW".split()
def parse(v):
    out=[]
    for p in v.replace(",",";").split(";"):
        p=p.strip().upper()
        if p in PTS: out.append(PTS.index(p)*22.5); continue
        try: out.append(float(p)%360)
        except: return None
    return out or None
def xy(p, o): return ((p["lon"]-o["lon"])*111320*math.cos(math.radians(o["lat"])), (p["lat"]-o["lat"])*110540)
def diff(a,b): d=abs(a-b)%360; return min(d,360-d)
agree=dis=onroad=far=0; dis_ex=[]
for c in cams:
    d=parse(c.get("tags",{}).get("direction",""))
    if not d or len(d)!=1: continue
    best=None
    for w in ways:
        g=w["geometry"]
        for a,b in zip(g,g[1:]):
            ax,ay=xy(a,c); bx,by=xy(b,c)
            dx,dy=bx-ax,by-ay; L=dx*dx+dy*dy
            if L==0: continue
            t=max(0,min(1,-(ax*dx+ay*dy)/L)); px,py=ax+t*dx,ay+t*dy
            dist=math.hypot(px,py)
            if best is None or dist<best[0]:
                cross=dx*(-ay)-dy*(-ax)  # >0: camera left of a->b
                best=(dist, math.degrees(math.atan2(dx,dy))%360, cross)
    if best is None or best[0]>25: far+=1; continue
    if best[0]<2: onroad+=1; continue
    side_dir = best[1] if best[2]>0 else (best[1]+180)%360
    if diff(side_dir,d[0])<60: agree+=1
    elif diff(side_dir,d[0])>120: dis+=1; dis_ex.append(c["id"])
print(f"cameras with one direction: beside the road, side agrees {agree}, side disagrees {dis}; on the road {onroad}; no road within 25 m {far}")
print("disagree examples:", dis_ex[:15])
