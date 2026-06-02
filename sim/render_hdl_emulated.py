#!/usr/bin/env python3
"""Render output of the Python HDL emulator -- should match what the
GHDL sim produces (modulo Bresenham step-by-step pixel walk).  Used to
A/B against MAME-faithful render for the same vec dump.

Usage: render_hdl_emulated.py <vec_*.bin> <out.png>
"""
import sys
try:
    from PIL import Image, ImageDraw
except ImportError:
    print('Need Pillow: pip install Pillow')
    sys.exit(1)
from avg_starwars_hdl import AvgStarwarsHDL, M_XCENTER, M_YCENTER
from avg_starwars_mame import load_prom_hex

if len(sys.argv) < 3:
    print(__doc__)
    sys.exit(1)
src, dst = sys.argv[1], sys.argv[2]

W, H = 980, 700


def pal(c):
    return (255 if (c & 4) else 0,
            255 if (c & 2) else 0,
            255 if (c & 1) else 0)


def mame_to_fb(mx, my):
    pitch = 1 << 14   # current HDL drawer pitch (bit-14)
    rel_x = mx - M_XCENTER
    rel_y = my - M_YCENTER
    cur_px = rel_x // pitch
    cur_py = -rel_y // pitch
    x_scaled = (cur_px * 2) - (cur_px >> 2)
    y_scaled = cur_py + (cur_py >> 2)
    new_x = (x_scaled >> 1) + 490
    new_y = 349 - (y_scaled >> 1)
    return new_x, new_y


prom = load_prom_hex('avg_prom.hex')
decoder = AvgStarwarsHDL(prom)
with open(src, 'rb') as f:
    mem = f.read()
strokes, _ = decoder.run(mem)

img = Image.new('RGB', (W, H), (0, 0, 0))
draw = ImageDraw.Draw(img)
for x0m, y0m, x1m, y1m, color, intensity in strokes:
    if intensity == 0:
        continue
    fx0, fy0 = mame_to_fb(x0m, y0m)
    fx1, fy1 = mame_to_fb(x1m, y1m)
    draw.line([fx0, fy0, fx1, fy1], fill=pal(color), width=1)
img.save(dst)
print(f'rendered {len(strokes)} clipped strokes -> {dst}')
