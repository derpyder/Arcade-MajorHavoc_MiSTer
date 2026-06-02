#!/usr/bin/env python3
"""bloom_engine_model.py -- RTL-FAITHFUL fixed-point model of the halation
bloom_engine (Phase 3b).  This is the GOLDEN REFERENCE: every op is integer /
shift, mappable 1:1 to the SystemVerilog bloom_engine, so the RTL can be diffed
against it.  See docs/SPEC-halation-phase3b.md.

Pipeline (all source-res, integer):
  core FB (32bpp, additive)  -- the Phase-3a FB content
  -> 1/2-res area-average downsample
  -> separable 5-tap [1,4,6,4,1]/16 blur, N passes (the wide colored bloom)
  -> 1/4-res veil (further area-avg + wide blur, faint)
  -> upsample (nearest + one blur == cheap bilinear; NOT BW's bare-nearest)
  -> composite: clip( (core*OD>>8) + (S_BLOOM*bloom_up>>8) + (S_VEIL*veil_up>>8) )
  -> white-hot tone-map: out = clip(ch) + (SPILL * sum_over_255 >>8), clip 255

All multipliers are .8 fixed-point (value/256).  These constants are what the
RTL must use; they are printed at the end for transcription.
"""
import os
import sys

import numpy as np
from PIL import Image

import render_bloom as R

W, H = R.W, R.H

# ---- fixed-point params (the RTL constants) ----
# NOTE: the RTL blurs the FB (no per-line info), so on thin 1px-Bresenham cores
# the blur amplitude is low -> strengths are cranked to compensate.  The Phase-3c
# AA drawer (Tempest fix) thickens cores -> richer bloom -> these will drop.
# These map to OSD "bloom strength / intensity / width" knobs; tune on hardware.
OD       = 512   # core overdrive, .8 fp (512/256 = 2.0x) -> headroom for white-hot
S_BLOOM  = 768   # wide-bloom strength, .8 fp (3.0x)
S_VEIL   = 256   # veil strength, .8 fp (1.0x)
SPILL    = 115   # white-hot spill, .8 fp (115/256 ~ 0.45)
BLOOM_PASSES = 4 # 5-tap passes on the 1/2-res buffer (sets bloom width)
VEIL_PASSES  = 4 # 5-tap passes on the 1/4-res buffer (very wide, faint)


def core_fb(scene):
    """Phase-3a FB content: additive (saturating) accumulation of the captured
    beam writes, 8bpp/channel, hardware-dedup'd (push_pix)."""
    wr = R.load_writes(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    f'pixels_{scene}.txt'))
    m = wr['inb'] & wr['keep']
    units = R.color_units(wr['c'])[m]                     # (N,3) in {0,1}
    acc = np.zeros((H, W, 3), np.int32)
    np.add.at(acc, (wr['ny'][m], wr['nx'][m]), (units * 255).astype(np.int32))
    return np.clip(acc, 0, 255).astype(np.int32)          # 8-bit FB, sat-ADD clamp


def area_avg2(a):
    """2x2 area-average downsample (integer, rounded). a:(h,w,3) -> (h/2,w/2,3)."""
    h, w = a.shape[0] & ~1, a.shape[1] & ~1
    a = a[:h, :w]
    s = a[0::2, 0::2] + a[1::2, 0::2] + a[0::2, 1::2] + a[1::2, 1::2] + 2
    return (s >> 2).astype(np.int32)


def blur5(a, passes):
    """Separable 5-tap [1,4,6,4,1]/16, integer, edge-clamped. RTL: a MAC + >>4."""
    for _ in range(passes):
        for ax in (1, 0):
            p = np.pad(a, ((2, 2) if ax == 0 else (0, 0),
                           (2, 2) if ax == 1 else (0, 0), (0, 0)), mode='edge')
            if ax == 1:
                a = (p[:, 0:-4] + (p[:, 1:-3] << 2) + p[:, 2:-2] * 6
                     + (p[:, 3:-1] << 2) + p[:, 4:] + 8) >> 4
            else:
                a = (p[0:-4] + (p[1:-3] << 2) + p[2:-2] * 6
                     + (p[3:-1] << 2) + p[4:] + 8) >> 4
    return a.astype(np.int32)


def up_smooth(a, factor):
    """Upsample by `factor` (nearest replicate) + one 5-tap blur == cheap
    bilinear (smooth, NOT BW's bare-nearest that blocked).  Crop/pad to HxW."""
    big = np.repeat(np.repeat(a, factor, axis=0), factor, axis=1)
    big = big[:H, :W]
    if big.shape[0] < H or big.shape[1] < W:
        big = np.pad(big, ((0, H - big.shape[0]), (0, W - big.shape[1]), (0, 0)), mode='edge')
    return blur5(big, 1)


def white_hot(total):
    """Over-driven cores desaturate to white: out = clip(ch) + SPILL*sum(over)."""
    over = np.clip(total - 255, 0, None)                  # per-channel excess
    spill = (over.sum(2, keepdims=True) * SPILL) >> 8
    return np.clip(np.clip(total, 0, 255) + spill, 0, 255).astype(np.uint8)


def bloom(core):
    half = area_avg2(core)
    bloom_half = blur5(half, BLOOM_PASSES)
    veil_q = blur5(area_avg2(half), VEIL_PASSES)          # 1/4-res
    bloom_up = up_smooth(bloom_half, 2)
    veil_up = up_smooth(veil_q, 4)
    total = ((core * OD) >> 8) + ((S_BLOOM * bloom_up) >> 8) + ((S_VEIL * veil_up) >> 8)
    return white_hot(total)


def main():
    scene = sys.argv[1] if len(sys.argv) > 1 else 'logo'
    os.makedirs(R.OUTDIR, exist_ok=True)
    core = core_fb(scene)
    out = bloom(core)
    Image.fromarray(np.clip(core, 0, 255).astype(np.uint8), 'RGB').save(
        os.path.join(R.OUTDIR, f'be_{scene}_core.png'))
    Image.fromarray(out, 'RGB').save(os.path.join(R.OUTDIR, f'be_{scene}_bloom.png'))
    lum = out.max(2)
    print(f'[{scene}] core lit px={int((core.max(2)>0).sum())}  '
          f'bloom lit px={int((lum>0).sum())}  white-hot px={int(((lum>200)&((out.max(2)-out.min(2))<60)).sum())}')
    print('RTL fixed-point constants (.8 fp = value/256):')
    print(f'  OD={OD} S_BLOOM={S_BLOOM} S_VEIL={S_VEIL} SPILL={SPILL} '
          f'BLOOM_PASSES={BLOOM_PASSES} VEIL_PASSES={VEIL_PASSES}')
    print(f'  ops: area_avg2 (a+b+c+d+2)>>2 ; blur5 (x0+4x1+6x2+4x3+x4+8)>>4 ; '
          f'composite (k*v+0)>>8 ; white-hot clip(ch)+(SPILL*sum_over>>8)')
    print(f'  -> be_{scene}_core.png, be_{scene}_bloom.png')


if __name__ == '__main__':
    main()
