#!/usr/bin/env python3
"""intensity_ladder.py -- pick the bright-vector overdrive level + show the
white-hot core saturation (real vector games were BRIGHT; over-driven beams go
white at the core with a colored halo).  Also offsets the AA softening: an
over-driven AA line clips to a solid bright core while keeping a thin soft edge.

Renders the AA vector-faithful bloom on a COLORED scene at increasing overdrive,
contrasting plain per-channel clip vs white-hot core saturation.

Usage: python intensity_ladder.py [scene] [mag]
"""
import os
import sys

import numpy as np
from PIL import Image

import render_bloom as R
import render_bloom_vec as V

scene = sys.argv[1] if len(sys.argv) > 1 else 'high_score'
mag = int(sys.argv[2]) if len(sys.argv) > 2 else 4

strokes = V.scene_strokes(scene)
acc = V.render_strokes(strokes, aa=True)            # base gain (0.9) baked in

LADDER = [
    ('x1 clip (current locked)', V.bloom_compose(acc, overdrive=1.0, white=False)),
    ('x4 clip (flat primaries)', V.bloom_compose(acc, overdrive=4.0, white=False)),
    ('x2.5 white-hot core', V.bloom_compose(acc, overdrive=2.5, white=True)),
    ('x4 white-hot core', V.bloom_compose(acc, overdrive=4.0, white=True)),
    ('x6 white-hot core', V.bloom_compose(acc, overdrive=6.0, white=True)),
]

# densest 240x180 window (avoid hollow centers)
cw, ch = 240, 180
lum = LADDER[3][1].max(2).astype(np.float64)
integ = np.pad(lum, ((1, 0), (1, 0))).cumsum(0).cumsum(1)
best, bx, by = -1, 0, 0
for yy in range(0, V.H - ch, 24):
    for xx in range(0, V.W - cw, 24):
        s = integ[yy + ch, xx + cw] - integ[yy, xx + cw] - integ[yy + ch, xx] + integ[yy, xx]
        if s > best:
            best, bx, by = s, xx, yy

panels = [(lbl, V.crop_mag(img, bx, by, cw, ch, mag)) for lbl, img in LADDER]
out = os.path.join(R.OUTDIR, f'intensity_{scene}.png')
V.sheet(f'INTENSITY LADDER {scene}  AA vector + halo  densest ({bx},{by})+{cw}x{ch} x{mag}  '
        f'white_spill={V.WHITE_SPILL}', panels, cw * mag, ch * mag).save(out)
# report how much of the frame is white-hot at each level (max-min channel small + bright)
for lbl, img in LADDER:
    f = img.astype(np.float64)
    bright = f.max(2) > 200
    whiteish = bright & ((f.max(2) - f.min(2)) < 60)
    n = max(int(bright.sum()), 1)
    print(f'  {lbl:26s}: bright px={bright.sum():6d}  white-hot frac={whiteish.sum()/n:.0%}')
print(f'[{scene}] -> {out}')
