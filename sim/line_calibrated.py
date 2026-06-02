#!/usr/bin/env python3
"""line_calibrated.py -- rebuild a single line to MATCH the sampled real-tube
profile (sample_ref.py):
  - core is CYAN (~111,214,236), NOT white  (fixes "too hot")
  - bloom is a long-tailed wide glow (~40% of core still at 76px)  (fixes "lacking bloom outwards")
  - hue shifts cyan->blue with distance: PER-CHANNEL widths (B >> G > R)

Model: each line is the sum of soft profiles, one per channel-group, with
different radii.  R tight, G medium, B = tight core + very-wide long tail.
Renders the line, re-samples its perpendicular profile, prints MINE vs REF.
"""
import os

import numpy as np
from PIL import Image, ImageDraw

import render_bloom as R_
import render_bloom_vec as V

Wc, Hc = V.W, V.H            # deposit_soft clamps to module W/H, so match it

# Reference sampled profile (from sample_ref.py) for side-by-side
REF = {0: (111, 214, 236), 4: (128, 228, 244), 8: (89, 191, 222), 11: (45, 135, 185),
       14: (23, 88, 151), 18: (18, 39, 118), 24: (22, 21, 105), 32: (22, 20, 103),
       44: (21, 19, 102), 60: (21, 18, 97), 76: (19, 17, 93)}

# Per-channel components: (peak, Rw) tuned to the sampled falloff.
# R: low + tight.  G: medium.  B: bright core + a very-wide long tail + veil.
COMPONENTS = [
    # (r,g,b peak), Rw
    ((118, 150, 150), 5.0),    # bright cyan core (tight): sets d0 cyan, falls fast
    ((0,   70,  70), 12.0),    # green+blue mid shoulder
    ((0,    0, 120), 30.0),    # blue wide
    ((18,  16,  78), 95.0),    # blue long tail / veil (keeps ~40% far out)
]


def render_line():
    acc = np.zeros((Hc, Wc, 3), np.float64)
    for (r, g, b), Rw in COMPONENTS:
        col = np.array([r, g, b], np.float64)
        col = col / max(col.max(), 1)              # unit color
        peak = max(r, g, b)
        V.deposit_soft(acc, 60, 140, 920, 600, col, peak, core=1.0, Rw=Rw)
    return np.clip(acc, 0, 255).astype(np.uint8)


img = render_line()
Image.fromarray(img, 'RGB').save(os.path.join(R_.OUTDIR, 'line_calibrated.png'))

# re-sample MY line with the same perpendicular method
lum = img.max(2).astype(np.float64)
xs = np.arange(Wc); ys = lum.argmax(0).astype(np.float64); peak = lum.max(0)
good = peak > 0.5 * peak.max()
m, b = np.polyfit(xs[good], ys[good], 1)
plen = (m * m + 1) ** 0.5; pnx, pny = -m / plen, 1.0 / plen
DMAX = 80
acc = np.zeros((2 * DMAX + 1, 3)); cnt = np.zeros(2 * DMAX + 1)
for x0 in range(60, Wc - 60, 3):
    cy = m * x0 + b
    for i, d in enumerate(range(-DMAX, DMAX + 1)):
        px = int(round(x0 + d * pnx)); py = int(round(cy + d * pny))
        if 0 <= px < Wc and 0 <= py < Hc:
            acc[i] += img[py, px]; cnt[i] += 1
prof = acc / np.maximum(cnt[:, None], 1)

print(f'{"d":>4}  {"MINE (R,G,B)":>16}   {"REF (R,G,B)":>16}')
for d in [0, 4, 8, 11, 14, 18, 24, 32, 44, 60, 76]:
    mine = tuple(int(v) for v in prof[DMAX + d])
    ref = REF.get(d, ('', '', ''))
    print(f'{d:>4}  {str(mine):>16}   {str(ref):>16}')
print('-> bloom_out/line_calibrated.png')
