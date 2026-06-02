#!/usr/bin/env python3
"""sample_ref.py -- color-sample the real-tube reference line's bloom.

Detects the bright line in ref_clip.png, samples many perpendicular cross-
sections, averages -> the real (distance-from-core -> RGB) falloff + the hue of
the blue spill at each distance.  This is the calibration target for the model.
"""
import os
import sys

import numpy as np
from PIL import Image

path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), 'bloom_out', 'ref_clip.png')
im = np.asarray(Image.open(path).convert('RGB'), np.float64)
H, W, _ = im.shape
lum = im.max(2)

# 1. detect the core line: brightest row per column, robust linear fit
xs = np.arange(W)
ys = lum.argmax(0).astype(np.float64)
peak = lum.max(0)
good = peak > 0.5 * peak.max()                 # only columns where the line is clearly present
m, b = np.polyfit(xs[good], ys[good], 1)
# refine: reject outliers > 8px from fit, refit
res = np.abs((m * xs + b) - ys)
good2 = good & (res < 8)
m, b = np.polyfit(xs[good2], ys[good2], 1)
ang = np.degrees(np.arctan2(m, 1))
# perpendicular unit vector
plen = (m * m + 1) ** 0.5
pnx, pny = -m / plen, 1.0 / plen
print(f'line: y={m:.3f}x+{b:.1f}  angle={ang:.1f}deg  (sampling perp, +d = down-left)')

# 2. sample perpendicular cross-sections, average over x along the line
DMAX = 80
acc = np.zeros((2 * DMAX + 1, 3))
cnt = np.zeros(2 * DMAX + 1)
for x0 in range(60, W - 60, 3):
    if not good2[x0]:
        continue
    cy = m * x0 + b
    for i, d in enumerate(range(-DMAX, DMAX + 1)):
        px = int(round(x0 + d * pnx)); py = int(round(cy + d * pny))
        if 0 <= px < W and 0 <= py < H:
            acc[i] += im[py, px]; cnt[i] += 1
prof = acc / np.maximum(cnt[:, None], 1)

# 3. report: distance, RGB, normalized hue, % of core brightness
core = prof[DMAX]
core_l = core.max()
print(f'\ncore (d=0): RGB={tuple(int(v) for v in core)}  lum={core_l:.0f}')
print(f'\n{"d":>4} {"R":>4}{"G":>4}{"B":>4}  {"lum%":>5}  hue(R:G:B normalized to B=100)')
for d in [0, 1, 2, 3, 4, 6, 8, 11, 14, 18, 24, 32, 44, 60, 76]:
    p = prof[DMAX + d]
    l = p.max()
    bb = max(p[2], 1)
    print(f'{d:>4} {int(p[0]):>4}{int(p[1]):>4}{int(p[2]):>4}  {100*l/core_l:>4.0f}%  '
          f'{p[0]/bb*100:>3.0f}:{p[1]/bb*100:>3.0f}:100')

# where does it fade to ~5% / ~1% of core?
ll = prof.max(1)
for frac in [0.5, 0.25, 0.1, 0.05, 0.02]:
    out = [d for d in range(0, DMAX) if ll[DMAX + d] < frac * core_l]
    print(f'falls below {int(frac*100):>2}% of core at d={out[0] if out else ">80"}px')
