#!/usr/bin/env python3
"""bloom_profile.py -- the CORRECTED bloom model: a soft-edged line profile
where WIDTH and INTENSITY are orthogonal, and the core is NOT a hot spike above
the bloom.

User model (2026-05-29): a 1px line that "blooms 5px out" is an 11px-wide shape
(1px core + 5px falloff each side), peak at the core falling smoothly to 0 at
+/-5.5px.  The inner line should never get MUCH hotter than the bloom (one
continuous soft profile -- NOT a clipped white core with a faint haze).  Widening
the bloom must NOT brighten it; brightening must NOT widen it.

Profile P(d), d = perpendicular distance:
    |d| <= core/2          : 1.0                       (flat core)
    core/2 < |d| <= core/2+R : 0.5*(1+cos(pi*(|d|-core/2)/R))  (cosine falloff)
    else                   : 0.0
brightness = INTENSITY * P(d)    -> peak == INTENSITY (independent of R)
R == bloom radius (the "5px out")  -> width (independent of INTENSITY)

This script renders a single horizontal blue line and prints/【shows the
cross-section, sweeping R at fixed intensity (width changes, peak doesn't) and
intensity at fixed R (peak changes, width doesn't).
"""
import os

import numpy as np
from PIL import Image, ImageDraw

import render_bloom as R_

OUT = R_.OUTDIR
COLOR = np.array([0.30, 0.45, 1.0])     # a blue beam (stays colored -- not white)


def profile(d, core, R):
    a = np.abs(d)
    half = core / 2.0
    falloff = 0.5 * (1.0 + np.cos(np.pi * np.clip((a - half) / R, 0, 1)))
    return np.where(a <= half, 1.0, np.where(a <= half + R, falloff, 0.0))


def render_line(intensity, core, R, Wc=140, Hc=40):
    """Single horizontal blue line, perpendicular soft profile."""
    yc = Hc // 2
    ys = np.arange(Hc)[:, None]
    prof = profile(ys - yc, core, R)                 # (Hc,1)
    val = intensity * prof                            # (Hc,1) peak==intensity
    img = np.zeros((Hc, Wc, 3), np.float64)
    for ch in range(3):
        img[..., ch] = val[:, 0:1] * COLOR[ch]
    img[:, :10] = 0                                   # left margin black
    img[:, -10:] = 0
    return np.clip(img, 0, 255).astype(np.uint8), val[:, 0]


def strip(img, label, magx, magy):
    big = np.repeat(np.repeat(img, magy, axis=0), magx, axis=1)
    bar = 22
    canvas = Image.new('RGB', (big.shape[1], big.shape[0] + bar), (16, 16, 16))
    canvas.paste(Image.fromarray(big, 'RGB'), (0, bar))
    ImageDraw.Draw(canvas).text((6, 5), label, fill=(255, 255, 0))
    return canvas


INT = 220
CORE = 1.0
rows = []

print('=== WIDTH sweep (intensity fixed -> peak constant, falloff grows) ===')
print(f'{"variant":18} ' + ' '.join(f'd{d}' for d in range(0, 9)))
width_imgs = []
for Rr in [2, 4, 6, 8]:
    img, col = render_line(INT, CORE, Rr)
    width_imgs.append(strip(img, f'bloom R={Rr}px  peak={INT} (intensity FIXED)', 4, 4))
    yc = img.shape[0] // 2
    samp = [int(col[min(yc + d, len(col) - 1)]) for d in range(0, 9)]
    print(f'R={Rr}px peak={INT:<7} ' + ' '.join(f'{v:3d}' for v in samp))

print('\n=== INTENSITY sweep (width fixed R=5 -> falloff constant, peak grows) ===')
print(f'{"variant":18} ' + ' '.join(f'd{d}' for d in range(0, 9)))
int_imgs = []
for I in [110, 170, 230]:
    img, col = render_line(I, CORE, 5)
    int_imgs.append(strip(img, f'peak={I}  bloom R=5px (width FIXED)', 4, 4))
    yc = img.shape[0] // 2
    samp = [int(col[min(yc + d, len(col) - 1)]) for d in range(0, 9)]
    print(f'peak={I:<3} R=5px      ' + ' '.join(f'{v:3d}' for v in samp))

# assemble: width sweep on top, intensity sweep below
allp = width_imgs + int_imgs
w = max(p.width for p in allp)
H = sum(p.height for p in allp) + 30
sheet = Image.new('RGB', (w, H), (16, 16, 16))
ImageDraw.Draw(sheet).text((8, 8), 'BLOOM PROFILE: width vs intensity orthogonal; '
                           'core ~ bloom (soft dome, no spike)', fill=(255, 255, 0))
y = 30
for p in allp:
    sheet.paste(p, (0, y))
    y += p.height
out = os.path.join(OUT, 'bloom_profile.png')
sheet.save(out)
print(f'\n-> {out}')
