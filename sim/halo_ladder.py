#!/usr/bin/env python3
"""halo_ladder.py -- pick the OSD halo levels (spec 5: Off/Subtle/Standard/Heavy)
and expose RGB565 banding at the strongest level.

Renders the additive-accumulated frame with a sweep of full-res halo strengths,
cropped + magnified so the glow (and any 565 banding in the soft falloff) is
visible.  This is the tunable the user picks defaults from.

Usage: python halo_ladder.py [scene] [cx cy cw ch mag]
"""
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

import render_bloom as R

scene = sys.argv[1] if len(sys.argv) > 1 else 'logo'
wr = R.load_writes(os.path.join(os.path.dirname(os.path.abspath(__file__)), f'pixels_{scene}.txt'))
acc = R.accumulate(wr, R.GAIN, dedup=True)


def halo(acc, strength, passes=R.HALO_PASSES):
    spread = acc.copy()
    for _ in range(passes):
        spread = R.blur5(spread)
    return R.clamp888(acc + strength * spread)


LADDER = [
    ('Off  s=0.0', R.clamp888(acc)),
    ('Subtle  s=0.4', halo(acc, 0.4)),
    ('Standard  s=0.9', halo(acc, 0.9)),
    ('Heavy  s=1.8', halo(acc, 1.8)),
    ('Heavy@565 (banding)', R.quant565(halo(acc, 1.8))),
]

# crop region
if len(sys.argv) >= 6:
    cx, cy, cw, ch = (int(sys.argv[i]) for i in (2, 3, 4, 5))
else:
    m = wr['inb'] & wr['keep']
    over = np.where(np.bincount(wr['ny'][m].astype(np.int64) * R.W + wr['nx'][m],
                                minlength=R.W * R.H) >= 1)[0]
    ys, xs = np.divmod(over, R.W)
    cx, cy, cw, ch = int(xs.mean()), int(ys.mean()), 220, 165
mag = int(sys.argv[6]) if len(sys.argv) >= 7 else 4
x0 = max(0, min(R.W - cw, cx - cw // 2))
y0 = max(0, min(R.H - ch, cy - ch // 2))

pw, ph, bar, title_h = cw * mag, ch * mag, 24, 28
cols = len(LADDER)
sheet = Image.new('RGB', (cols * pw, title_h + ph + bar), (16, 16, 16))
ImageDraw.Draw(sheet).text((8, 8),
    f'HALO LADDER {scene}  ({x0},{y0})+{cw}x{ch} x{mag}  gain={R.GAIN} passes={R.HALO_PASSES}',
    fill=(255, 255, 0))
for i, (lbl, img) in enumerate(LADDER):
    crop = img[y0:y0 + ch, x0:x0 + cw]
    big = np.repeat(np.repeat(crop, mag, axis=0), mag, axis=1)
    canvas = Image.new('RGB', (pw, ph + bar), (0, 0, 0))
    canvas.paste(Image.fromarray(big, 'RGB'), (0, bar))
    ImageDraw.Draw(canvas).text((6, 6), lbl, fill=(255, 255, 255))
    sheet.paste(canvas, (i * pw, title_h))

out = os.path.join(R.OUTDIR, f'halo_ladder_{scene}.png')
sheet.save(out)
print(f'[{scene}] halo ladder ({x0},{y0})+{cw}x{ch} x{mag} -> {out}')
