# Live check: how British speed cameras in OpenStreetMap record which way they check traffic.
# For cameras on one-way roads, compares OSM "direction" with the way traffic flows. Kite 0.7.6
# takes "direction" as the way traffic goes, so "same as traffic" should be by far the most.
import json, math, urllib.request, urllib.parse, collections, sys
Q = """[out:json][timeout:240];area["ISO3166-1"="GB"][admin_level=2]->.gb;
node[highway=speed_camera](area.gb)->.c;(.c;way(bn.c)[highway];);out body geom;"""
data = None
for ep in ["https://overpass-api.de/api/interpreter","https://overpass.kumi.systems/api/interpreter","https://overpass.private.coffee/api/interpreter"]:
    try:
        req = urllib.request.Request(ep, data=("data="+urllib.parse.quote(Q)).encode(), headers={"User-Agent":"Kite-check"})
        data = json.load(urllib.request.urlopen(req, timeout=300)); break
    except Exception as e: print("mirror failed", ep, e, file=sys.stderr)
els = data["elements"]
cams = {e["id"]: e for e in els if e["type"]=="node"}
ways = [e for e in els if e["type"]=="way"]
PTS = "N NNE NE ENE E ESE SE SSE S SSW SW WSW W WNW NW NNW".split()
def parse(v):
    out=[]
    for p in v.replace(",",";").split(";"):
        p=p.strip().upper()
        if not p: continue
        if p in PTS: out.append(PTS.index(p)*22.5); continue
        try: out.append(float(p)%360)
        except: return None
    return out or None
def brg(a,b):
    la1,lo1,la2,lo2=map(math.radians,(a["lat"],a["lon"],b["lat"],b["lon"]))
    y=math.sin(lo2-lo1)*math.cos(la2); x=math.cos(la1)*math.sin(la2)-math.sin(la1)*math.cos(la2)*math.cos(lo2-lo1)
    return math.degrees(math.atan2(y,x))%360
def diff(a,b): d=abs(a-b)%360; return min(d,360-d)
vals=collections.Counter(); keys=collections.Counter()
for c in cams.values():
    t=c.get("tags",{})
    for k in ("direction","camera:direction","traffic_sign:direction"):
        if k in t: keys[k]+=1
    v=t.get("direction") or t.get("camera:direction")
    vals["none" if v is None else ("number/compass" if parse(v) else v.lower())]+=1
print("cameras", len(cams)); print("tag keys", dict(keys)); print("values", vals.most_common(15))
same=opp=side=0; fwd=bwd=0; ex=[]
for w in ways:
    t=w.get("tags",{}); ow=t.get("oneway"); mw=t.get("highway") in ("motorway","motorway_link")
    one = ow in ("yes","1","true") or (mw and ow!="no") or t.get("junction")=="roundabout"
    rev = ow=="-1"
    for i,n in enumerate(w["nodes"]):
        c=cams.get(n)
        if not c: continue
        v=(c.get("tags",{}).get("direction") or "").lower()
        if v=="forward": fwd+=1
        if v=="backward": bwd+=1
        d=parse(c.get("tags",{}).get("direction") or "")
        if not d or not (one or rev): continue
        g=w["geometry"]; a=g[max(i-1,0)]; b=g[min(i+1,len(g)-1)]
        if a==b: continue
        flow=brg(a,b); flow=(flow+180)%360 if rev else flow
        m=min(diff(x,flow) for x in d)
        if m<60: same+=1
        elif m>120: opp+=1; ex.append((c["id"],d,round(flow)))
        else: side+=1
print(f"on one-way roads with a number/compass direction: same as traffic {same}, opposite {opp}, sideways {side}")
print("forward/backward on any road:", fwd, bwd)
print("opposite examples:", ex[:10])
on = set(n for w in ways for n in w["nodes"])
print("not on a road", sum(1 for c in cams if c not in on))
