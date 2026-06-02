#!/usr/bin/env python3
"""halo_res_test.py -- isolate WHY the Black Widow bloom failed: the 1/4
RESOLUTION, or the SAMPLING METHOD (stride-4 point-sample + nearest upscale)?

Builds the same additive glow via different downsample/upsample paths so the
RTL phase can pick the cheapest spread that's still clean:
  - full-res spread (reference, most DDR bandwidth)
  - 1/2-res done RIGHT (area-average down, bilinear up)
  - 1/4-res done RIGHT (area-average down, bilinear up)
  - 1/4-res done WRONG (stride-4 point sample, nearest up) == the BW recipe

Usage: python halo_res_test.py [scene] [cx cy cw ch mag]
"""
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

import render_bloom as R

scene = sys.argv[1] if len(sys.argv) > 1 else 'logo'
wr = R.load_writes(os.path.join(os.path.dirname(os.path.abspath(__file__)), f'pixels_{scene}.txt'))
acc = R.accumulate(wr, R.GAIN, dedup=True)
S = 1.2  # glow strength held constant across methods


def _resize(a, w, h, mode):
    return np.asarray(Image.fromarray(R.clamp888(a), 'RGB').resize((w, h), mode), np.float64)


def spread_fullres(a):
    s = a.copy()
    for _ in range(R.HALO_PASSES):
        s = R.blur5(s)
    return s


def spread_downup(a, factor, down, up):
    """Downsample by `factor`, blur small, upsample back. down/up are PIL filters."""
    sw, sh = R.W // factor, R.H // factor
    small = _resize(a, sw, sh, down)
    small = R.blur5(small)            # same 5-tap, but on the smaller grid = wider effective kernel
    return _resize(small, R.W, R.H, up)


def spread_bw_wrong(a):
    """The rejected recipe: stride-4 POINT sample + NEAREST upscale, 5-tap."""
    small = a[::4, ::4, :]
    small = R.blur5(small)
    up = np.repeat(np.repeat(small, 4, axis=0), 4, axis=1)
    up = up[:R.H, :R.W, :]
    if up.shape[0] < R.H or up.shape[1] < R.W:
        up = np.pad(up, ((0, R.H - up.shape[0]), (0, R.W - up.shape[1]), (0, 0)), mode='edge')
    return up


VARIANTS = [
    ('full-res (ref)', spread_fullres(acc)),
    ('1/2-res area+bilinear', spread_downup(acc, 2, Image.BOX, Image.BILINEAR)),
    ('1/4-res area+bilinear', spread_downup(acc, 4, Image.BOX, Image.BILINEAR)),
    ('1/4-res point+nearest (BW)', spread_bw_wrong(acc)),
]
imgs = [(lbl, R.clamp888(acc + S * sp)) for lbl, sp in VARIANTS]

if len(sys.argv) >= 6:
    cx, cy, cw, ch = (int(sys.argv[i]) for i in (2, 3, 4, 5))
else:
    cx, cy, cw, ch = 487, 342, 220, 165
mag = int(sys.argv[6]) if len(sys.argv) >= 7 else 4
x0 = max(0, min(R.W - cw, cx - cw // 2))
y0 = max(0, min(R.H - ch, cy - ch // 2))

pw, ph, bar, title_h = cw * mag, ch * mag, 24, 28
sheet = Image.new('RGB', (len(imgs) * pw, title_h + ph + bar), (16, 16, 16))
ImageDraw.Draw(sheet).text((8, 8),
    f'HALO RES TEST {scene}  ({x0},{y0})+{cw}x{ch} x{mag}  glow s={S} (held constant)',
    fill=(255, 255, 0))
for i, (lbl, img) in enumerate(imgs):
    crop = img[y0:y0 + ch, x0:x0 + cw]
    big = np.repeat(np.repeat(crop, mag, axis=0), mag, axis=1)
    canvas = Image.new('RGB', (pw, ph + bar), (0, 0, 0))
    canvas.paste(Image.fromarray(big, 'RGB'), (0, bar))
    ImageDraw.Draw(canvas).text((6, 6), lbl, fill=(255, 255, 255))
    sheet.paste(canvas, (i * pw, title_h))
out = os.path.join(R.OUTDIR, f'halo_res_{scene}.png')
sheet.save(out)
print(f'[{scene}] halo res test -> {out}')
