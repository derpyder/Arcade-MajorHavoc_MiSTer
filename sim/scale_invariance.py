#!/usr/bin/env python3
"""scale_invariance.py -- prove the bloom is PERSISTENT across integer scales /
screen sizes when applied at SOURCE resolution (SPEC 5.2), and show why a
display-pixel bloom is NOT.

CORRECT (source-res): bake the calibrated bloom into the source frame, then let
the integer scaler (ascal, bilinear) enlarge the whole thing.  The bloom is a
fixed FRACTION of the picture -> identical relative glow on a 10" 2x or a 40"
4K 6x panel.  WRONG (display-px): bloom applied after scaling at a fixed pixel
radius -> shrinks relative to the picture as the scale rises.

Calibrated source-res line profile (from sample_ref.py on the real tube):
  - CYAN core (~111,214,236), NOT white
  - per-channel widths B >> G > R (cyan core -> wide deep-blue tail)
  - tail ~13 SOURCE px (becomes ~78 display px at 6x -> matches the photo)
"""
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

import render_bloom as R_
import render_bloom_vec as V

SRC_W, SRC_H = 260, 190                      # a source-frame region
PANEL_W = 620                                # common "screen" size for fair comparison
SCALES = [2, 4, 6]

# calibrated per-channel components in SOURCE px: (r,g,b peak), Rw
COMPONENTS = [
    ((111, 0,   0),   2.5),                  # R: tight (cyan core only)
    ((0,   214, 0),   4.5),                  # G: medium
    ((0,   0,   150), 3.5),                  # B core
    ((20,  18,  98),  13.0),                 # B-dominant long tail (the outward bloom)
    ((14,  12,  60),  24.0),                 # faint very-wide veil (CRT glare)
]
LINES = [(60, 24, 60, 168), (130, 24, 130, 168), (200, 24, 200, 168)]  # 3 verticals, 70px apart


def deposit_line(acc, x0, y0, x1, y1, color, peak, Rw):
    """Soft-profile line that respects acc's own size (NOT the module W/H)."""
    Hc, Wc = acc.shape[:2]
    rad = Rw + 1
    minx = max(0, int(np.floor(min(x0, x1) - rad))); maxx = min(Wc - 1, int(np.ceil(max(x0, x1) + rad)))
    miny = max(0, int(np.floor(min(y0, y1) - rad))); maxy = min(Hc - 1, int(np.ceil(max(y0, y1) + rad)))
    ys, xs = np.mgrid[miny:maxy + 1, minx:maxx + 1]
    xs = xs.astype(float); ys = ys.astype(float)
    abx, aby = x1 - x0, y1 - y0
    L2 = abx * abx + aby * aby
    t = np.clip(((xs - x0) * abx + (ys - y0) * aby) / max(L2, 1e-9), 0, 1)
    d = np.sqrt((xs - (x0 + t * abx)) ** 2 + (ys - (y0 + t * aby)) ** 2)
    k = V.soft_profile(d, 1.0, Rw)
    sub = acc[miny:maxy + 1, minx:maxx + 1]
    for ch in range(3):
        if color[ch]:
            sub[..., ch] += peak * color[ch] * k


def source_bloomed():
    acc = np.zeros((SRC_H, SRC_W, 3), float)
    for (r, g, b), Rw in COMPONENTS:
        col = np.array([r, g, b], float); col = col / max(col.max(), 1)
        for (x0, y0, x1, y1) in LINES:
            deposit_line(acc, x0, y0, x1, y1, col, max(r, g, b), Rw)
    return np.clip(acc, 0, 255).astype(np.uint8)


def source_sharp():
    acc = np.zeros((SRC_H, SRC_W, 3), float)
    col = np.array([0.47, 0.90, 1.0])        # cyan beam
    for (x0, y0, x1, y1) in LINES:
        deposit_line(acc, x0, y0, x1, y1, col, 236, 0.8)
    return np.clip(acc, 0, 255).astype(np.uint8)


def to_panel(img_arr):
    im = Image.fromarray(img_arr, 'RGB')
    return im.resize((PANEL_W, PANEL_W * SRC_H // SRC_W), Image.BILINEAR)


src_bloom = source_bloomed()
src_sharp = source_sharp()
Image.fromarray(src_bloom, 'RGB').save(os.path.join(R_.OUTDIR, 'src_bloom.png'))

DISPLAY_BLOOM_PX = 7                          # the WRONG fixed display-pixel radius

right, wrong = [], []
for s in SCALES:
    # CORRECT: bloom baked in source, ascal (bilinear) enlarges it
    big = Image.fromarray(src_bloom, 'RGB').resize((SRC_W * s, SRC_H * s), Image.BILINEAR)
    right.append((s, big.resize((PANEL_W, PANEL_W * SRC_H // SRC_W), Image.BILINEAR)))
    # WRONG: sharp scaled, then a FIXED display-px bloom applied at output res
    bigs = Image.fromarray(src_sharp, 'RGB').resize((SRC_W * s, SRC_H * s), Image.BILINEAR)
    arr = np.asarray(bigs, float)
    halo = np.asarray(bigs.filter(ImageFilter.GaussianBlur(DISPLAY_BLOOM_PX)), float)
    out = np.clip(arr + 1.4 * halo, 0, 255).astype(np.uint8)
    wrong.append((s, Image.fromarray(out, 'RGB').resize((PANEL_W, PANEL_W * SRC_H // SRC_W), Image.BILINEAR)))

# numeric: bloom radius as % of image width, per scale
print('bloom width as % of picture width (should be CONSTANT for correct):')
print(f'  CORRECT source-res: tail Rw=13 src px / {SRC_W} = {13/SRC_W*100:.1f}% at EVERY scale')
for s in SCALES:
    print(f'  WRONG display-px:  {DISPLAY_BLOOM_PX}px / {SRC_W*s} = {DISPLAY_BLOOM_PX/(SRC_W*s)*100:.1f}% at x{s}')

ph = PANEL_W * SRC_H // SRC_W
bar, th = 26, 30
sheet = Image.new('RGB', (3 * PANEL_W, th + 2 * (ph + bar)), (16, 16, 16))
d = ImageDraw.Draw(sheet)
d.text((8, 9), 'SCALE INVARIANCE  (same "screen" size; only the integer scale differs)  '
        'TOP=source-res bloom (correct, persistent)  BOTTOM=display-px bloom (wrong, shrinks)',
        fill=(255, 255, 0))
for col, (s, im) in enumerate(right):
    sheet.paste(im, (col * PANEL_W, th))
    d.text((col * PANEL_W + 6, th + 4), f'CORRECT  x{s}  bloom=5.0% of pic (constant)', fill=(120, 255, 120))
for col, (s, im) in enumerate(wrong):
    y = th + ph + bar
    sheet.paste(im, (col * PANEL_W, y))
    d.text((col * PANEL_W + 6, y + 4), f'WRONG  x{s}  bloom={DISPLAY_BLOOM_PX/(SRC_W*s)*100:.1f}% of pic', fill=(255, 140, 140))
out = os.path.join(R_.OUTDIR, 'scale_invariance.png')
sheet.save(out)
print(f'-> {out}')
