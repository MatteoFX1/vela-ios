# Live check: does Highway Radar's heat map tile server (found in the Ausbloke fork) cover Britain?
# Fetches a few tiles and reports HTTP status, size and how much of each tile is non-black.
import io, math, sys, urllib.request
try:
    from PIL import Image
except ImportError:
    Image = None
def tile(lat, lng, z):
    n = 2 ** z
    x = int((lng + 180) / 360 * n)
    y = int((1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n)
    return x, y
places = [("Southampton", 50.91, -1.40), ("M27 Eastleigh", 50.95, -1.35), ("Central London", 51.51, -0.12),
          ("Manchester", 53.48, -2.24), ("Cardiff", 51.48, -3.18), ("Glasgow", 55.86, -4.25), ("Perth WA", -31.95, 115.86)]
for name, lat, lng in places:
    for z in (8, 10, 12):
        x, y = tile(lat, lng, z)
        url = f"https://tiles.cmbe.cc/heat_map/get/{z}/{x}/{y}.webp"
        try:
            r = urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "Kite-check"}), timeout=20)
            data = r.read(); code = r.status
        except Exception as e:
            print(f"{name} z{z} {x}/{y}: failed {e}"); continue
        lit = "?"
        if Image is not None:
            try:
                im = Image.open(io.BytesIO(data)).convert("L")
                px = list(im.getdata())
                lit = f"{sum(1 for p in px if p > 8) * 100 / len(px):.1f}% lit, max {max(px)}"
            except Exception as e:
                lit = f"unreadable ({e})"
        print(f"{name} z{z} {x}/{y}: HTTP {code}, {len(data)} bytes, {lit}")
