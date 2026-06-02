#!/usr/bin/env python3
"""logo_scene.py -- compose a full Star Wars scene with the calibrated bloom,
at SOURCE resolution, to compare against the real-tube wireframe photo.

Pipeline (all source-res, SPEC 5.2):
  AA beam strokes (z-weighted, over-driven)         -> tight core energy
  + wide colored halation (blur of the energy)      -> the beam glow (beam color)
  + faint very-wide veil                            -> scene ambient floor
  -> white-hot tone-map                             -> intense cores desaturate to white
The hue-shift (white core -> colored halo) emerges: the core whitens where
intense+tight; the halo is the blurred BEAM color (blue for the blue wireframe).

Usage: python logo_scene.py [scene] [scale]
"""
import os
import sys

import numpy as np
from PIL import Image

import render_bloom as R_
import render_bloom_vec as V
from avg_starwars_mame import AvgStarwars, load_prom_hex, M_XCENTER, M_YCENTER

# beam colors (the tube's vector hues; SW "blue" reads cyan-blue)
PALETTE = {1: (0.35, 0.62, 1.0), 2: (0.30, 1.0, 0.45), 3: (0.40, 0.9, 1.0),
           4: (1.0, 0.30, 0.22), 5: (1.0, 0.40, 1.0), 6: (1.0, 0.82, 0.32),
           7: (1.0, 1.0, 1.0)}
Z_FLOOR = 0.45            # dim strokes still render (more uniform, like the tube)

scene = sys.argv[1] if len(sys.argv) > 1 else 'logo'
scale = int(sys.argv[2]) if len(sys.argv) > 2 else 4


def beam_strokes(scene):
    prom = load_prom_hex('avg_prom.hex')
    mame = os.path.join('..', '..', 'starwars-mister', '.tools', 'mame0287')
    mem = open(os.path.join(mame, 'snap', f'vec_{V.SCENES[scene]}.bin'), 'rb').read()
    strokes, _ = AvgStarwars(prom).run(mem)
    imax = max((s[5] for s in strokes if s[5]), default=1)
    out = []
    for x0m, y0m, x1m, y1m, color, inten in strokes:
        if inten == 0:
            continue
        fx0, fy0 = V.mame_to_fb(x0m, y0m)
        fx1, fy1 = V.mame_to_fb(x1m, y1m)
        col = np.array(PALETTE.get(color, (1, 1, 1)), float)
        e = Z_FLOOR + (1 - Z_FLOOR) * (inten / imax)     # z-weight with floor
        out.append((fx0, fy0, fx1, fy1, col, e * 255))
    return out


def compose(strokes, intensity=360, aa_w=0.8, halo_s=2.0, veil_s=0.7, spill=0.42):
    """Calibrated look (2026-05-29): THIN beam core (aa_w~0.8) + WIDE lush bloom +
    veil, all independent of core width.  halo_s is boosted to keep the lush glow
    despite the thin (low-energy) core.  Beam-line width, bloom width, and
    intensity are separate knobs."""
    core = V.glow_acc(strokes, width=aa_w, intensity=intensity)   # thin beam-colored energy
    halo = V.spread(core, passes=5, down=4)                       # wide colored bloom
    veil = V.spread(core, passes=5, down=8)                       # very-wide faint ambient floor
    total = core + halo_s * halo + veil_s * veil
    return V.toward_white(total, spill)


strokes = beam_strokes(scene)
img = compose(strokes)
Image.fromarray(img, 'RGB').save(os.path.join(R_.OUTDIR, f'logo_scene_{scene}.png'))

# scaled view (simulating the integer scaler) of the wireframe region
lum = img.max(2).astype(float)
ys, xs = np.where(lum > 25)
cx, cy = (int(xs.mean()), int(ys.mean())) if len(xs) else (V.W // 2, V.H // 2)
cw, ch = 520, 460
x0 = max(0, min(V.W - cw, cx - cw // 2)); y0 = max(0, min(V.H - ch, cy - ch // 2))
crop = img[y0:y0 + ch, x0:x0 + cw]
big = Image.fromarray(crop, 'RGB').resize((cw * scale, ch * scale), Image.BILINEAR)
big.save(os.path.join(R_.OUTDIR, f'logo_scene_{scene}_x{scale}.png'))
print(f'[{scene}] {len(strokes)} strokes  full=logo_scene_{scene}.png  '
      f'crop x{scale}=logo_scene_{scene}_x{scale}.png  (crop {x0},{y0}+{cw}x{ch})')
