#!/usr/bin/env python3
# Render the 4 flip combinations of the Tempest attract from the raw display list,
# so the orientation can be PICKED by eye (each is solid by construction). Labels
# name the exact tempest_sw.sv fxs/fys you'd set for that option.
from PIL import Image, ImageDraw
FRAME = "../../../Arcade-Tempest/sim/tempest_frame.txt"
W, H = 980, 700

def base(ax, ay):
    cx = ax ^ 512; sx = cx >> 1; scx = sx - 256
    cy = ay ^ 512; sy = cy >> 1; scy = sy - 256
    return scx, scy

# (label, fxs(scx), fys(scy))  -- the 4 flip combos around FB centre (490,350)
OPTS = [
    ("A_none  fxs=490+scx fys=350+scy", lambda scx, scy: (490 + scx, 350 + scy)),
    ("B_flipX fxs=490-scx fys=350+scy", lambda scx, scy: (490 - scx, 350 + scy)),
    ("C_flipY fxs=490+scx fys=350-scy", lambda scx, scy: (490 + scx, 350 - scy)),
    ("D_flipXY fxs=490-scx fys=350-scy (current core)", lambda scx, scy: (490 - scx, 350 - scy)),
]

pts = []
for l in open(FRAME):
    f = l.split()
    if len(f) < 4: continue
    ax, ay, rgb, az = map(int, f[:4])
    if (az >> 3) == 0 or rgb == 0: continue           # only visible draws
    scx, scy = base(ax, ay)
    chan = ((az >> 3) << 3) | ((az >> 3) >> 2) & 0x1f  # ~ {z,z[4:2]} 8-bit
    col = ((rgb & 4) and chan or 0, (rgb & 2) and chan or 0, (rgb & 1) and chan or 0)
    pts.append((scx, scy, col))

tiles = []
for label, fn in OPTS:
    img = Image.new("RGB", (W, H), (0, 0, 0)); px = img.load()
    for scx, scy, col in pts:
        x, y = fn(scx, scy)
        if 0 <= x < W and 0 <= y < H: px[x, y] = col
    d = ImageDraw.Draw(img); d.text((10, 8), label, fill=(255, 255, 255))
    img.save(f"orient_{label.split()[0]}.png")
    tiles.append(img)

# 2x2 montage, downscaled
sc = 2
mont = Image.new("RGB", (2 * W // sc, 2 * H // sc), (20, 20, 20))
for i, t in enumerate(tiles):
    t2 = t.resize((W // sc, H // sc))
    mont.paste(t2, ((i % 2) * (W // sc), (i // 2) * (H // sc)))
mont.save("orient_montage.png")
print("wrote orient_montage.png + orient_A..D.png  (", len(pts), "visible pts )")
