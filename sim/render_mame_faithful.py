#!/usr/bin/env python3
"""Render the MAME-faithful AVG decoder's output to a PNG that should
match MAME 0287's actual screen for the same vec_*.bin.

Usage: render_mame_faithful.py <vec_*.bin> <out.png>
"""

import sys
try:
    from PIL import Image, ImageDraw
except ImportError:
    print('Need Pillow: pip install Pillow')
    sys.exit(1)

from avg_starwars_mame import AvgStarwars, load_prom_hex, M_XCENTER, M_YCENTER

if len(sys.argv) < 3:
    print(__doc__)
    sys.exit(1)
src, dst = sys.argv[1], sys.argv[2]

# Our framebuffer
W, H = 980, 700


def pal(c):
    # MAME vector_device::color111: bit0=R, bit1=G, bit2=B in MAME source
    # BUT inspection of mame_avgdvg_ref.cpp + the existing palette mapping
    # in vector_fb_ddram.sv shows BGR: bit0=B, bit1=G, bit2=R.  Use BGR to
    # match our hardware -- inverting here would just disguise a real
    # color mapping discrepancy if one exists.
    r = 255 if (c & 4) else 0
    g = 255 if (c & 2) else 0
    b = 255 if (c & 1) else 0
    return (r, g, b)


def mame_to_fb(mx, my):
    """Map MAME m_xpos/m_ypos onto our 980x700 framebuffer.

    MAME visible width = 250 MAME-px * 65536 m_xpos = 16384000.
    Our drawer currently uses pitch=2^15, plus starwars.sv's 1.75x X
    and 1.25x Y scaling.  For the MAME-faithful reference we want the
    rendered output to fill the FB, so we pick pitch s.t. MAME's edge
    (8192000 m_xpos from center) maps to FB's edge after starwars.sv
    scaling.

    FB halfwidth = 980/2 = 490 px.  After 1.75x X scaling on drawer
    output, drawer cur_px range that fills FB is +/- 490/0.875 = +/- 560.
    So pitch = 8192000 / 560 = 14629 ~ 2^14.

    Use 2^14 so this reference shows what the user's hardware *would*
    look like if drawer pitch were correctly calibrated.
    """
    pitch = 1 << 14
    rel_x = mx - M_XCENTER
    rel_y = my - M_YCENTER  # MAME's y increases downward
    cur_px = rel_x // pitch
    cur_py = -rel_y // pitch
    # starwars.sv X*1.75, Y*1.25, Y inversion around 349
    x_scaled = (cur_px * 2) - (cur_px >> 2)  # *1.75
    y_scaled = cur_py + (cur_py >> 2)        # *1.25
    new_x = (x_scaled >> 1) + 490
    new_y = 349 - (y_scaled >> 1)
    return new_x, new_y


prom = load_prom_hex('avg_prom.hex')
decoder = AvgStarwars(prom)
with open(src, 'rb') as f:
    mem = f.read()
strokes, _ = decoder.run(mem)

img = Image.new('RGB', (W, H), (0, 0, 0))
draw = ImageDraw.Draw(img)
for x0m, y0m, x1m, y1m, color, intensity in strokes:
    if intensity == 0:
        continue  # invisible move
    fx0, fy0 = mame_to_fb(x0m, y0m)
    fx1, fy1 = mame_to_fb(x1m, y1m)
    draw.line([fx0, fy0, fx1, fy1], fill=pal(color), width=1)
img.save(dst)
print(f'rendered {len(strokes)} clipped strokes -> {dst}')
