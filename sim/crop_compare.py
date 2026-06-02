#!/usr/bin/env python3
"""crop_compare.py -- magnified crop A/B of the bloom variants.

The full-frame contact sheet (render_bloom.py) is too zoomed-out to judge the
halo glow, RGB565 banding, or the BW 1/4-res blockiness.  This crops a small
region and magnifies it NEAREST (so per-pixel structure -- banding/blockiness --
is shown honestly) across all variants.

Auto-centers on the densest-overlap pixel (where additive bloom does the most),
or pass an explicit center.

Usage:
  python crop_compare.py <scene> [cx cy] [cw ch mag]
"""
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

import render_bloom as R

scene = sys.argv[1] if len(sys.argv) > 1 else 'logo'
path = os.path.join(os.path.dirname(os.path.abspath(__file__)), f'pixels_{scene}.txt')
wr = R.load_writes(path)

m = wr['inb'] & wr['keep']
flat = wr['ny'][m].astype(np.int64) * R.W + wr['nx'][m].astype(np.int64)
counts = np.bincount(flat, minlength=R.W * R.H)

if len(sys.argv) >= 4:
    cx, cy = int(sys.argv[2]), int(sys.argv[3])
else:
    # centroid of overlapping (count>=2) pixels, where additive action lives
    over = np.where(counts >= 2)[0]
    if len(over) == 0:
        over = np.where(counts >= 1)[0]
    ys, xs = np.divmod(over, R.W)
    cx, cy = int(xs.mean()), int(ys.mean())

cw = int(sys.argv[4]) if len(sys.argv) >= 6 else 200
ch = int(sys.argv[5]) if len(sys.argv) >= 6 else 150
mag = int(sys.argv[6]) if len(sys.argv) >= 7 else 4

x0 = max(0, min(R.W - cw, cx - cw // 2))
y0 = max(0, min(R.H - ch, cy - ch // 2))
print(f'[{scene}] crop center=({cx},{cy}) box=({x0},{y0})+{cw}x{ch} mag={mag}  '
      f'peak overlap={counts.max()} @ flat')

variants = R.build_variants(wr)

pw, ph = cw * mag, ch * mag
bar = 24
cols = 3
rows = (len(variants) + cols - 1) // cols
title_h = 28
sheet = Image.new('RGB', (cols * pw, title_h + rows * (ph + bar)), (16, 16, 16))
d = ImageDraw.Draw(sheet)
d.text((8, 8), f'CROP {scene}  ({x0},{y0})+{cw}x{ch} x{mag}  '
               f'gain={R.GAIN} halo=s{R.HALO_STRENGTH}x{R.HALO_PASSES}',
       fill=(255, 255, 0))

for i, (lbl, img) in enumerate(variants):
    crop = img[y0:y0 + ch, x0:x0 + cw]
    big = np.repeat(np.repeat(crop, mag, axis=0), mag, axis=1)
    im = Image.fromarray(big, 'RGB')
    r, cc = divmod(i, cols)
    canvas = Image.new('RGB', (pw, ph + bar), (0, 0, 0))
    canvas.paste(im, (0, bar))
    ImageDraw.Draw(canvas).text((6, 6), lbl, fill=(255, 255, 255))
    sheet.paste(canvas, (cc * pw, title_h + r * (ph + bar)))

out = os.path.join(R.OUTDIR, f'crop_{scene}.png')
os.makedirs(R.OUTDIR, exist_ok=True)
sheet.save(out)
print(f'  -> {out}')
