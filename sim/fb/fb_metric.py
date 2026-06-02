#!/usr/bin/env python3
# Framebuffer SOLIDITY metric for the write-side LINE-FILL.
#
# Builds a SOLID golden = Bresenham between consecutive LIT points WITHIN a segment (a
# move/blank/OOB breaks continuity, exactly like the FB's beam_gap), then compares the
# sim's fb_out.txt:
#   retention = |sim & solid| / |solid|   (1.00 = lines fully solid)
#   missing   = solid pixels absent in sim = the remaining GAPS (dots)  -> want ~0
#   spurious  = sim pixels not in the solid set (stray / fill-across-move) -> want ~0
#
# Coord map = mhavoc_sw "Fill" scale x1.25 (sc_num=5), matching tb_fb_trails.
import sys
FRAME = "../../../Arcade-MajorHavoc/sim/mhavoc_frame.txt"
OUT   = sys.argv[1] if len(sys.argv) > 1 else "fb_out.txt"

def mapx(ax): sx = (ax * 5) >> 2; return 490 + (sx - 640)   # x1.25, matches tb mapx
def mapy(ay): sy = (ay * 5) >> 2; return 360 - (sy - 640)   # x1.25, matches tb mapy
def inb(x, y): return 0 <= x < 980 and 0 <= y < 720

def bres(x0, y0, x1, y1):
    pts = []
    dx = abs(x1 - x0); dy = abs(y1 - y0)
    sx = 1 if x1 > x0 else -1; sy = 1 if y1 > y0 else -1
    err = dx - dy; x, y = x0, y0
    while True:
        pts.append((x, y))
        if x == x1 and y == y1: break
        e2 = 2 * err
        if e2 > -dy: err -= dy; x += sx
        if e2 <  dx: err += dx; y += sy
    return pts

solid = set()
seg_gaps = 0   # number of consecutive-lit pairs that had a gap (>1px) -> the dotted segments
prev = None    # previous LIT pixel (x,y), or None after a move/blank/OOB (continuity break)
for l in open(FRAME):
    f = l.split()
    if len(f) < 4: continue
    ax, ay, rgb, az = map(int, f[:4])
    x, y = mapx(ax), mapy(ay)
    lit = (az >> 3) > 0 and rgb != 0 and inb(x, y)
    if lit:
        solid.add((x, y))
        if prev is not None:
            if abs(x - prev[0]) > 1 or abs(y - prev[1]) > 1: seg_gaps += 1
            for p in bres(prev[0], prev[1], x, y): solid.add(p)
        prev = (x, y)
    else:
        prev = None   # move / blank / OOB breaks continuity (no fill across it)

sim = set()
for l in open(OUT):
    p = l.split()
    if len(p) == 5: sim.add((int(p[0]), int(p[1])))

inter = sim & solid; missing = solid - sim; spurious = sim - solid
g = len(solid) or 1
print(f"solid golden pixels:            {len(solid)}   (segment gaps to fill: {seg_gaps})")
print(f"sim lit pixels:                 {len(sim)}")
print(f"retention |sim&solid|/solid:    {len(inter)}/{len(solid)} = {100*len(inter)/g:.1f}%")
print(f"missing (remaining GAPS/dots):  {len(missing)}   <- want ~0 (fill closed the gaps)")
print(f"spurious (sim not in solid):    {len(spurious)}   <- want small (Bresenham ties / overdraw)")
