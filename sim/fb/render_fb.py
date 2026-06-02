#!/usr/bin/env python3
# Render fb_out.txt (x y r g b) -> fb_replay.png + ASCII map. This is what the
# framebuffer actually contains after replaying the real Tempest display list.
import sys
pts = []
for line in open("fb_out.txt"):
    p = line.split()
    if len(p) == 5:
        pts.append(tuple(map(int, p)))
print(f"lit pixels: {len(pts)}")
if not pts:
    print(">>> framebuffer EMPTY"); sys.exit(0)
xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
print(f"x: {min(xs)}..{max(xs)}   y: {min(ys)}..{max(ys)}")

# ASCII density map over 980x700 (so it's readable without an image)
GW, GH = 80, 40
g = [[0]*GW for _ in range(GH)]
for x, y, r, gr, b in pts:
    gx = min(GW-1, x*GW//980); gy = min(GH-1, y*GH//700)
    g[gy][gx] += 1
mx = max(1, max(max(r) for r in g))
ramp = " .:-=+*#%@"
print("   +" + "-"*GW + "+")
for gy in range(GH):
    print("   |" + "".join(ramp[min(8, g[gy][gx]*9//mx)] for gx in range(GW)) + "|")
print("   +" + "-"*GW + "+")

try:
    from PIL import Image
    img = Image.new("RGB", (980, 700), (0,0,0)); px = img.load()
    for x, y, r, gr, b in pts:
        if 0 <= x < 980 and 0 <= y < 700:
            px[x, y] = (r, gr, b)
    img.save("fb_replay.png"); print("wrote fb_replay.png")
except ImportError:
    print("(no PIL)")
