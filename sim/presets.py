#!/usr/bin/env python3
"""presets.py -- bloom TOGGLE/PRESET matrix + glow WIDTH ladder.

The effect decomposes into orthogonal toggles so users who want a plain glow can
skip the opinionated vector-faithful extras (AA, beam-overlap, white-hot):

  toggle          off                         on (vector-faithful)
  --------------  --------------------------  ----------------------------------
  AA lines        1px (crisp original)        Wu coverage (angle-independent)
  Beam overlap    overwrite (orig colors)     sat-ADD (crossings sum + color-mix)
  White-hot core  flat primaries              over-driven cores -> white
  Glow (halo)     -- universal "bloom", everyone gets it (strength + WIDTH) --
  Intensity       normal                      overdrive ~x4

Row 1 = three presets (Off / Glow-only non-vector / AA+glow no-overlap / Vector).
Row 2 = glow WIDTH ladder (narrow..ultrawide) on the Vector preset -- "go wide".

Usage: python presets.py [scene] [mag]
"""
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

import render_bloom as R
import render_bloom_vec as V

scene = sys.argv[1] if len(sys.argv) > 1 else 'high_score'
mag = int(sys.argv[2]) if len(sys.argv) > 2 else 4

strokes = V.scene_strokes(scene)
acc_over = V.render_strokes(strokes, aa=False, merge='over')   # 1px, original colors
acc_aamax = V.render_strokes(strokes, aa=True, merge='max')    # AA, no additive
acc_add = V.render_strokes(strokes, aa=True, merge='add')      # AA + beam overlap

row1 = [
    ('OFF (sharp 1px, no glow)',
     V.bloom_compose(acc_over, overdrive=1.0, s=0.0, white=False)),
    ('GLOW only -- non-vector (1px+halo, orig colors)',
     V.bloom_compose(acc_over, overdrive=1.0, s=0.9, passes=2, down=2, white=False)),
    ('AA + GLOW, no overlap (smooth, orig colors)',
     V.bloom_compose(acc_aamax, overdrive=1.0, s=0.9, passes=2, down=2, white=False)),
    ('VECTOR full (AA+overlap+white-hot x4)',
     V.bloom_compose(acc_add, overdrive=4.0, s=0.7, passes=2, down=2, white=True)),
]
# Row 2: glow WIDTH ladder on the vector preset (overdrive+white-hot held)
row2 = [
    ('width narrow (full-res p2)',
     V.bloom_compose(acc_add, overdrive=4.0, s=0.7, passes=2, down=1, white=True)),
    ('width standard (1/2-res p2)',
     V.bloom_compose(acc_add, overdrive=4.0, s=0.7, passes=2, down=2, white=True)),
    ('width WIDE (1/2-res p4)',
     V.bloom_compose(acc_add, overdrive=4.0, s=0.8, passes=4, down=2, white=True)),
    ('width ULTRAWIDE (1/4-res p4)',
     V.bloom_compose(acc_add, overdrive=4.0, s=0.9, passes=4, down=4, white=True)),
]

# densest 240x180 window on the vector preset
cw, ch = 240, 180
lum = row1[3][1].max(2).astype(np.float64)
integ = np.pad(lum, ((1, 0), (1, 0))).cumsum(0).cumsum(1)
best, bx, by = -1, 0, 0
for yy in range(0, V.H - ch, 24):
    for xx in range(0, V.W - cw, 24):
        s = integ[yy + ch, xx + cw] - integ[yy, xx + cw] - integ[yy + ch, xx] + integ[yy, xx]
        if s > best:
            best, bx, by = s, xx, yy

bar, th = 24, 28
pw, ph = cw * mag, ch * mag
sheet = Image.new('RGB', (4 * pw, th + 2 * (ph + bar)), (16, 16, 16))
ImageDraw.Draw(sheet).text((8, 8),
    f'BLOOM PRESETS + WIDTH  {scene}  densest ({bx},{by})+{cw}x{ch} x{mag}   '
    f'row1=toggle presets  row2=glow width ladder (vector)', fill=(255, 255, 0))
for r, row in enumerate([row1, row2]):
    for c, (lbl, img) in enumerate(row):
        big = V.crop_mag(img, bx, by, cw, ch, mag)
        canvas = Image.new('RGB', (pw, ph + bar), (0, 0, 0))
        canvas.paste(Image.fromarray(big, 'RGB'), (0, bar))
        ImageDraw.Draw(canvas).text((6, 6), lbl, fill=(255, 255, 255))
        sheet.paste(canvas, (c * pw, th + r * (ph + bar)))
out = os.path.join(R.OUTDIR, f'presets_{scene}.png')
sheet.save(out)
print(f'[{scene}] presets + width ladder -> {out}')
