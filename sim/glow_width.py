#!/usr/bin/env python3
"""glow_width.py -- CORRECTED width ladder: width and intensity orthogonal.

Uses render_glow (soft-profile bloom).  Sweeps WIDTH at FIXED intensity, so a
wider bloom spreads further WITHOUT getting hotter (the earlier width ladder
wrongly bumped strength with width).  Second row: INTENSITY at fixed width.

Usage: python glow_width.py [scene] [mag]
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

INT = 235
row1 = [(f'width R={w}px  (intensity FIXED {INT})', V.render_glow(strokes, width=w, intensity=INT))
        for w in [1.5, 3.0, 5.0, 8.0]]
row2 = [(f'intensity {i}  (width FIXED R=4px)', V.render_glow(strokes, width=4.0, intensity=i))
        for i in [120, 180, 240]]

# densest window on the widest variant
cw, ch = 240, 180
lum = row1[-1][1].max(2).astype(np.float64)
integ = np.pad(lum, ((1, 0), (1, 0))).cumsum(0).cumsum(1)
best, bx, by = -1, 0, 0
for yy in range(0, V.H - ch, 24):
    for xx in range(0, V.W - cw, 24):
        s = integ[yy + ch, xx + cw] - integ[yy, xx + cw] - integ[yy + ch, xx] + integ[yy, xx]
        if s > best:
            best, bx, by = s, xx, yy

# prove decoupling numerically: mean brightness of CORE pixels (top 2% brightest,
# i.e. the line centers) should stay ~constant across widths.
print('=== width @ fixed intensity: peak stays flat, only SPREAD (lit px) grows ===')
for lbl, img in row1:
    f = img.max(2).astype(np.float64)
    lit = f[f > 10]
    p95 = np.percentile(lit, 95)               # near-peak core brightness
    print(f'  {lbl:42s} core(p95)={p95:.0f}  lit px={int(lit.size)}')

bar, th = 24, 28
pw, ph = cw * mag, ch * mag
ncol = max(len(row1), len(row2))
sheet = Image.new('RGB', (ncol * pw, th + 2 * (ph + bar)), (16, 16, 16))
ImageDraw.Draw(sheet).text((8, 8),
    f'GLOW WIDTH (corrected: width <-> intensity orthogonal)  {scene}  x{mag}  '
    'row1=width@fixed-intensity  row2=intensity@fixed-width', fill=(255, 255, 0))
for r, row in enumerate([row1, row2]):
    for c, (lbl, img) in enumerate(row):
        big = V.crop_mag(img, bx, by, cw, ch, mag)
        canvas = Image.new('RGB', (pw, ph + bar), (0, 0, 0))
        canvas.paste(Image.fromarray(big, 'RGB'), (0, bar))
        ImageDraw.Draw(canvas).text((6, 6), lbl, fill=(255, 255, 255))
        sheet.paste(canvas, (c * pw, th + r * (ph + bar)))
out = os.path.join(R.OUTDIR, f'glow_width_{scene}.png')
sheet.save(out)
print(f'[{scene}] -> {out}')
