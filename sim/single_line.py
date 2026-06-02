#!/usr/bin/env python3
"""single_line.py -- calibrate ONE vector line against the real-tube close-up
reference (2026-05-29): a thin near-WHITE-CYAN core with a substantial, smooth,
saturated-BLUE halo.

Model that reproduces it: deposit an over-driven COLORED soft profile, then
white-hot tone-map.  The beam center saturates every channel -> white core; the
falloff keeps the dominant channel -> colored halo.  Width (Rw) and intensity
(peak) stay orthogonal; the halo is wide+smooth (a real glow, not a faint haze).

Grid: rows = halo WIDTH Rw, cols = INTENSITY (over-drive peak).
Usage: python single_line.py
"""
import os

import numpy as np
from PIL import Image, ImageDraw

import render_bloom as R_
import render_bloom_vec as V

Wc, Hc = 560, 320
BLUE = np.array([0.22, 0.55, 1.0])          # cyan-blue beam (matches the photo)
SPILL = 0.45


def line(peak, Rw):
    acc = np.zeros((Hc, Wc, 3), np.float64)
    V.deposit_soft(acc, 70, 60, 490, 270, BLUE, peak, core=1.0, Rw=Rw)
    return V.toward_white(acc, SPILL)


widths = [4.0, 7.0, 11.0]
peaks = [400, 650, 950]
bar = 22
sheet = Image.new('RGB', (len(peaks) * Wc, 28 + len(widths) * (Hc + bar)), (10, 10, 10))
ImageDraw.Draw(sheet).text((8, 8), 'SINGLE LINE vs real-tube reference   '
                           'rows=halo width Rw   cols=intensity (over-drive peak)   '
                           f'spill={SPILL}', fill=(255, 255, 0))
for r, Rw in enumerate(widths):
    for c, pk in enumerate(peaks):
        img = line(pk, Rw)
        # report core vs halo: peak channel at center and a few px off
        canvas = Image.new('RGB', (Wc, Hc + bar), (0, 0, 0))
        canvas.paste(Image.fromarray(img, 'RGB'), (0, bar))
        ImageDraw.Draw(canvas).text((6, 5), f'Rw={Rw}px  peak={pk}', fill=(255, 255, 0))
        sheet.paste(canvas, (c * Wc, 28 + r * (Hc + bar)))

out = os.path.join(R_.OUTDIR, 'single_line.png')
sheet.save(out)

# numeric cross-section for the middle cell (Rw=7, peak=650): white core -> blue halo
acc = np.zeros((Hc, Wc, 3), np.float64)
V.deposit_soft(acc, 70, 60, 490, 270, BLUE, 650, core=1.0, Rw=7.0)
img = V.toward_white(acc, SPILL)
# sample perpendicular to the line at its midpoint
mx, my = 280, 165
nx, ny = (270 - 60), -(490 - 70)            # normal to (dx,dy)=(420,210)
nlen = (nx * nx + ny * ny) ** 0.5
nx, ny = nx / nlen, ny / nlen
print('cross-section (perp dist -> R,G,B), Rw=7 peak=650:')
for d in range(0, 12, 1):
    px, py = int(round(mx + nx * d)), int(round(my + ny * d))
    if 0 <= px < Wc and 0 <= py < Hc:
        print(f'  d={d:2d}px  {tuple(int(v) for v in img[py, px])}')
print(f'-> {out}')
