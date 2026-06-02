#!/usr/bin/env python3
"""Render the sim's pixel writes to a PNG bitmap.  Compare side-by-side
with MAME's same-scene screenshot to spot what our RTL renders wrong.

Usage:  render.py pixels_high_score.txt high_score.png
"""

import sys

try:
    from PIL import Image
except ImportError:
    print('Need Pillow: pip install Pillow')
    sys.exit(1)

if len(sys.argv) < 3:
    print(__doc__)
    sys.exit(1)
src, dst = sys.argv[1], sys.argv[2]

# Our drawer extracts cur_px/cur_py as signed 11-bit (-1024..+1023)
# representing framebuffer offsets from screen center.  Render at the
# real framebuffer's 980x700 with origin at center (490, 350).
W, H = 980, 700
CX, CY = W // 2, H // 2

# m_color -> RGB (matches MAME color111 and our pipeline's pal_rgb mapping:
#   bit 0 = Blue, bit 1 = Green, bit 2 = Red)
def pal(c):
    r = 255 if c & 4 else 0
    g = 255 if c & 2 else 0
    b = 255 if c & 1 else 0
    return r, g, b

img = Image.new('RGB', (W, H), (0, 0, 0))
px = img.load()

# starwars.sv applies:
#   x_scaled = avg_x * 1.75   (half-pixels)
#   x_pixel  = x_scaled >> 1  (pixels)
#   new_x    = x_pixel + 490
#   y_scaled = avg_y * 1.25   (half-pixels)
#   y_pixel  = y_scaled >> 1
#   new_y    = 349 - y_pixel  (inverted)
#   beam_in_bounds = (new_x >= 0 && new_x < 980) && (new_y >= 0 && new_y < 700)

n_written = 0
n_clipped = 0
with open(src) as f:
    for line in f:
        parts = line.strip().split(',')
        if len(parts) < 4:
            continue
        x, y, z, c = int(parts[0]), int(parts[1]), int(parts[2]), int(parts[3])
        # 1.75× and 1.25× via the same math starwars.sv uses (half-pixels)
        x_scaled = (x * 2) - (x >> 2)
        y_scaled = y + (y >> 2)
        new_x = (x_scaled >> 1) + 490
        new_y = 349 - (y_scaled >> 1)
        if 0 <= new_x < W and 0 <= new_y < H:
            px[new_x, new_y] = pal(c)
            n_written += 1
        else:
            n_clipped += 1

img.save(dst)
print(f'rendered {n_written} fb pixels (clipped {n_clipped}) -> {dst}')
