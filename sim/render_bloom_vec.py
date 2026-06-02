#!/usr/bin/env python3
"""render_bloom_vec.py -- VECTOR-FAITHFUL, anti-aliased additive bloom.

Why this exists (user critique, 2026-05-29): render_bloom.py blooms the
already-RASTERIZED framebuffer (the 1px Bresenham pixel log).  That inherits
rasterization artifacts:
  - H/V lines are solid -> bloom strong + even.
  - diagonals are a Bresenham staircase: ~max(dx,dy) pixels for a true length
    ~sqrt(2)x longer => ~1/sqrt(2) the energy per unit length => a diagonal
    blooms WEAKER and lumpier than an H/V line.
On a real vector display brightness is per-unit-arc-length and ANGLE-INDEPENDENT:
a diagonal beam is exactly as bright as an H or V beam.

Fix = deposit energy from the VECTOR geometry with ANTI-ALIASED, coverage-
normalized line rendering (a perpendicular-distance kernel == what the BW
pipeline's Wu AA drawer buys in hardware), THEN bloom.  AA fills the staircase
with fractional-coverage pixels so energy/length is constant at any angle.

This script renders, both ALIASED (1px, == current) and AA (vector kernel):
  - a synthetic equal-length STAR BURST (0/45/90/135 deg) -- the angle-
    independence proof.
  - a real scene from the AVG decoder strokes.
Each shown as core + (core+halo).

Usage: python render_bloom_vec.py [scene]
"""
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

import render_bloom as R
from avg_starwars_mame import AvgStarwars, load_prom_hex, M_XCENTER, M_YCENTER

W, H = R.W, R.H
GAIN = R.GAIN
AA_RADIUS = 1.1          # AA line half-width (px); ~2.2px soft line
HALO_S = 0.7             # user-approved glow strength
SCENES = {'high_score': 'T01500', 'logo': 'T11500', 'intro': 'T10000', 'instr': 'T20000'}


def pal01(c):
    return np.array([1.0 if c & 4 else 0.0, 1.0 if c & 2 else 0.0, 1.0 if c & 1 else 0.0])


# ---------------------------------------------------------------------------
# Line deposit primitives (additive, into a float HxWx3 accumulator)
# ---------------------------------------------------------------------------
def deposit_1px(acc, x0, y0, x1, y1, rgb, energy, merge='add'):
    """Aliased: one pixel per major-axis step (Bresenham-equivalent).  A 45 deg
    line gets ~dx pixels for a sqrt(2)*dx true length -> fewer px per unit
    length than H/V -> dimmer/lumpier when bloomed.  Reproduces the problem.
    merge='add' = beam-overlap (sat-ADD); 'over' = overwrite (last-wins, no mix,
    preserves original game colors -- the non-vector path)."""
    n = int(max(abs(x1 - x0), abs(y1 - y0)))
    if n == 0:
        xs, ys = [int(round(x0))], [int(round(y0))]
    else:
        i = np.arange(n + 1)
        xs = np.round(x0 + (x1 - x0) * i / n).astype(int)
        ys = np.round(y0 + (y1 - y0) * i / n).astype(int)
    for x, y in zip(np.atleast_1d(xs), np.atleast_1d(ys)):
        if 0 <= x < W and 0 <= y < H:
            if merge == 'over':
                acc[y, x] = energy * rgb
            else:
                acc[y, x] += energy * rgb


def deposit_aa(acc, x0, y0, x1, y1, rgb, energy, r=AA_RADIUS, merge='add'):
    """Anti-aliased: perpendicular-distance kernel.  Brightness = energy*K(d)
    where K is a function of perpendicular distance ONLY -> identical cross-
    section profile (and peak) at ANY angle => angle-independent + AA.  Round
    caps via endpoint clamping.  merge='add' = beam-overlap (sat-ADD, crossings
    sum + color-mix); 'max' = AA without overlap (smooth lines + glow, original
    colors, no additive whitening -- a middle preset)."""
    minx = max(0, int(math.floor(min(x0, x1) - r)))
    maxx = min(W - 1, int(math.ceil(max(x0, x1) + r)))
    miny = max(0, int(math.floor(min(y0, y1) - r)))
    maxy = min(H - 1, int(math.ceil(max(y0, y1) + r)))
    if maxx < minx or maxy < miny:
        return
    ys, xs = np.mgrid[miny:maxy + 1, minx:maxx + 1]
    xs = xs.astype(np.float64)
    ys = ys.astype(np.float64)
    abx, aby = x1 - x0, y1 - y0
    L2 = abx * abx + aby * aby
    if L2 < 1e-9:
        projx, projy = x0, y0
    else:
        t = np.clip(((xs - x0) * abx + (ys - y0) * aby) / L2, 0.0, 1.0)
        projx = x0 + t * abx
        projy = y0 + t * aby
    d = np.sqrt((xs - projx) ** 2 + (ys - projy) ** 2)
    k = np.where(d < r, 0.5 * (1.0 + np.cos(np.pi * np.clip(d / r, 0, 1))), 0.0)
    sub = acc[miny:maxy + 1, minx:maxx + 1]
    for ch in range(3):
        if rgb[ch]:
            v = energy * rgb[ch] * k
            if merge == 'max':
                sub[..., ch] = np.maximum(sub[..., ch], v)
            else:
                sub[..., ch] += v


def soft_profile(d, core, Rw):
    """Cross-section profile: flat peak across the `core` px, cosine falloff over
    `Rw` px to 0.  Peak==1 (caller scales by intensity).  WIDTH (Rw) and peak are
    independent; core is only marginally hotter than the bloom (one soft dome)."""
    a = np.abs(d)
    half = core / 2.0
    fall = 0.5 * (1.0 + np.cos(np.pi * np.clip((a - half) / Rw, 0, 1)))
    return np.where(a <= half, 1.0, np.where(a <= half + Rw, fall, 0.0))


def deposit_soft(acc, x0, y0, x1, y1, rgb, peak, core=1.0, Rw=1.1, merge='add'):
    """CORRECTED bloom: deposit the line as a soft-edged profile of WIDTH Rw and
    PEAK = intensity (orthogonal knobs; user model 2026-05-29).  The profile IS
    the bloom -- no separate spike-making added-halo pass.  Rw~1 == sharp AA line;
    Rw~5 == 'blooms 5px out'.  Additive merge -> crossings sum (white-hot node)."""
    rad = core / 2.0 + Rw
    minx = max(0, int(math.floor(min(x0, x1) - rad)))
    maxx = min(W - 1, int(math.ceil(max(x0, x1) + rad)))
    miny = max(0, int(math.floor(min(y0, y1) - rad)))
    maxy = min(H - 1, int(math.ceil(max(y0, y1) + rad)))
    if maxx < minx or maxy < miny:
        return
    ys, xs = np.mgrid[miny:maxy + 1, minx:maxx + 1]
    xs = xs.astype(np.float64); ys = ys.astype(np.float64)
    abx, aby = x1 - x0, y1 - y0
    L2 = abx * abx + aby * aby
    if L2 < 1e-9:
        projx, projy = x0, y0
    else:
        t = np.clip(((xs - x0) * abx + (ys - y0) * aby) / L2, 0.0, 1.0)
        projx = x0 + t * abx; projy = y0 + t * aby
    d = np.sqrt((xs - projx) ** 2 + (ys - projy) ** 2)
    k = soft_profile(d, core, Rw)
    sub = acc[miny:maxy + 1, minx:maxx + 1]
    for ch in range(3):
        if rgb[ch]:
            v = peak * rgb[ch] * k
            sub[..., ch] = np.maximum(sub[..., ch], v) if merge == 'max' else sub[..., ch] + v


def glow_acc(strokes, width=1.1, intensity=230.0, merge='add'):
    """Float accumulator of soft-profile lines.  Width (falloff radius) and
    intensity (peak, z-weighted per stroke) are ORTHOGONAL.  Uncapped (energy)."""
    acc = np.zeros((H, W, 3), np.float64)
    imax = max((e for *_, e in strokes), default=1.0)   # stroke energy = gain*inten
    for fx0, fy0, fx1, fy1, rgb, e in strokes:
        peak = intensity * (e / imax)                   # z-weighted peak
        deposit_soft(acc, fx0, fy0, fx1, fy1, rgb, peak, Rw=width, merge=merge)
    return acc


def render_glow(strokes, width=1.1, intensity=230.0, merge='add', white=True):
    acc = glow_acc(strokes, width, intensity, merge)
    return toward_white(acc) if white else R.clamp888(acc)


def multiscale_bloom(acc, halation_s=0.7, halation_th=160.0, halation_down=4,
                     halation_passes=3, veil_s=0.12, veil_down=8, veil_passes=3,
                     white=True):
    """Match the real-CRT reference (Tempest photo, 2026-05-29): the tight per-
    line glow is already in `acc`; add an energy-GATED WIDE halation so only
    bright lines/nodes spill wide (a 1px web line stays tight; the convergence
    node + starburst halate wide), plus a faint very-wide veil (CRT veiling
    glare).  Bright-pass = clip(energy - threshold); wide/veil use the cheap
    lo-res-area+bilinear spread (finding #6).  toward_white -> white-hot cores."""
    bp = np.clip(acc - halation_th, 0.0, None)          # only the bright stuff
    wide = spread(bp, halation_passes, halation_down)    # mid-wide halation
    veil = spread(bp, veil_passes, veil_down)            # very-wide faint glare
    total = acc + halation_s * wide + veil_s * veil
    return toward_white(total) if white else R.clamp888(total)


def halo(acc, s=HALO_S, passes=R.HALO_PASSES):
    sp = acc.copy()
    for _ in range(passes):
        sp = R.blur5(sp)
    return R.clamp888(acc + s * sp)


WHITE_SPILL = 0.45       # how hard over-driven cores bleed toward white


def toward_white(energy, spill=WHITE_SPILL):
    """Vector-CRT over-saturation: where a channel is driven past full, the
    excess bleeds into the other channels so the CORE goes white-hot (a real
    over-driven phosphor desaturates toward white at the beam center), while the
    surrounding halo keeps its color.  `energy` is uncapped float HxWx3."""
    over = np.clip(energy - 255.0, 0.0, None)            # per-channel excess
    spilled = over.sum(axis=2, keepdims=True) * spill    # white add
    return np.clip(np.clip(energy, 0, 255) + spilled, 0, 255).astype(np.uint8)


def spread(e, passes, down=1):
    """Glow spread (separable Gaussian).  `down` downsamples (area) before
    blurring and bilinear-upsamples after -- so WIDE glows are cheap and stay
    clean (finding #6: lo-res done with area+bilinear is artifact-free, and wide
    smooth glows hide low res even better).  Effective radius ~ down*passes."""
    if down > 1:
        sw, sh = W // down, H // down
        small = np.asarray(Image.fromarray(R.clamp888(e), 'RGB').resize((sw, sh), Image.BOX), np.float64)
        for _ in range(passes):
            small = R.blur5(small)
        return np.asarray(Image.fromarray(R.clamp888(small), 'RGB').resize((W, H), Image.BILINEAR), np.float64)
    sp = e.copy()
    for _ in range(passes):
        sp = R.blur5(sp)
    return sp


def bloom_compose(acc, overdrive=1.0, s=HALO_S, passes=R.HALO_PASSES, down=1, white=True):
    """Full bright-vector composite: overdrive the beam energy, add the halo
    (from uncapped energy so bright cores glow harder), then tone-map with
    white-hot core saturation.  (passes,down) = glow WIDTH; s = glow STRENGTH.
    `white=False` = plain per-channel clip."""
    e = acc * overdrive
    total = e + s * spread(e, passes, down)
    return toward_white(total) if white else R.clamp888(total)


# ---------------------------------------------------------------------------
# Scene strokes (AVG decoder) -> FB coords (render_mame_faithful mapping)
# ---------------------------------------------------------------------------
def mame_to_fb(mx, my):
    pitch = 1 << 14
    cur_px = (mx - M_XCENTER) / pitch
    cur_py = -(my - M_YCENTER) / pitch
    x_scaled = cur_px * 1.75
    y_scaled = cur_py * 1.25
    return x_scaled + 490.0, 349.0 - y_scaled


def scene_strokes(scene):
    prom = load_prom_hex('avg_prom.hex')
    mame = os.path.join('..', '..', 'starwars-mister', '.tools', 'mame0287')
    mem = open(os.path.join(mame, 'snap', f'vec_{SCENES[scene]}.bin'), 'rb').read()
    strokes, _ = AvgStarwars(prom).run(mem)
    out = []
    imax = max((s[5] for s in strokes if s[5]), default=1)
    for x0m, y0m, x1m, y1m, color, inten in strokes:
        if inten == 0:
            continue
        fx0, fy0 = mame_to_fb(x0m, y0m)
        fx1, fy1 = mame_to_fb(x1m, y1m)
        out.append((fx0, fy0, fx1, fy1, pal01(color), GAIN * (inten / imax) * 255.0))
    return out


def render_strokes(strokes, aa, merge='add'):
    """aa: True=AA coverage kernel, False=1px Bresenham.  merge: 'add'=beam
    overlap (sat-ADD), 'over'/'max'=no overlap (preserve original colors)."""
    acc = np.zeros((H, W, 3), np.float64)
    dep = deposit_aa if aa else deposit_1px
    for fx0, fy0, fx1, fy1, rgb, energy in strokes:
        dep(acc, fx0, fy0, fx1, fy1, rgb, energy, merge=merge)
    return acc


# ---------------------------------------------------------------------------
# Synthetic equal-length star burst -- the angle-independence proof
# ---------------------------------------------------------------------------
def star_strokes(cx, cy, length, n_spokes=8):
    e = GAIN * 255.0
    white = np.array([1.0, 1.0, 1.0])
    out = []
    for k in range(n_spokes):
        ang = math.pi * k / n_spokes      # 0..180, every 180/n deg
        dx = math.cos(ang) * length
        dy = math.sin(ang) * length
        out.append((cx - dx, cy - dy, cx + dx, cy + dy, white, e))
    return out


# ---------------------------------------------------------------------------
# Layout helpers
# ---------------------------------------------------------------------------
def crop_mag(img, x0, y0, cw, ch, mag):
    c = img[y0:y0 + ch, x0:x0 + cw]
    return np.repeat(np.repeat(c, mag, axis=0), mag, axis=1)


def sheet(title, panels, pw, ph):
    bar, th = 24, 28
    s = Image.new('RGB', (len(panels) * pw, th + ph + bar), (16, 16, 16))
    ImageDraw.Draw(s).text((8, 8), title, fill=(255, 255, 0))
    for i, (lbl, img) in enumerate(panels):
        canvas = Image.new('RGB', (pw, ph + bar), (0, 0, 0))
        canvas.paste(Image.fromarray(img, 'RGB'), (0, bar))
        ImageDraw.Draw(canvas).text((6, 6), lbl, fill=(255, 255, 255))
        s.paste(canvas, (i * pw, th))
    return s


def main():
    os.makedirs(R.OUTDIR, exist_ok=True)

    # 1. STAR BURST proof (equal-length spokes at 8 angles incl. H, V, diagonals)
    cx, cy, L = 130, 130, 110
    star = star_strokes(cx, cy, L)
    acc_al = render_strokes(star, aa=False)
    acc_aa = render_strokes(star, aa=True)
    cw, ch, mag = 260, 260, 3
    panels = [
        ('aliased 1px core', crop_mag(R.clamp888(acc_al), 0, 0, cw, ch, mag)),
        ('AA vector core', crop_mag(R.clamp888(acc_aa), 0, 0, cw, ch, mag)),
        ('aliased + halo', crop_mag(halo(acc_al), 0, 0, cw, ch, mag)),
        ('AA + halo (uniform)', crop_mag(halo(acc_aa), 0, 0, cw, ch, mag)),
    ]
    out = os.path.join(R.OUTDIR, 'aa_star.png')
    sheet('STAR BURST: diagonal vs H/V bloom  (equal-length spokes, white)  '
          f'gain={GAIN} halo s={HALO_S}', panels, cw * mag, ch * mag).save(out)
    # quantify the REAL difference: total deposited energy per unit TRUE LENGTH
    # for one isolated spoke.  Bresenham draws max(|cos|,|sin|)*L px for a
    # length-L spoke -> a 45deg spoke gets 1/sqrt(2)~71% the energy/length of an
    # H spoke; AA deposits constant energy/length at any angle.  THIS is why a
    # diagonal blooms weaker -- and why AA fixes it.
    def energy_per_len(ang, aa):
        a = render_strokes([(200.0, 200.0, 200.0 + L * math.cos(ang),
                             200.0 + L * math.sin(ang), np.array([1., 1., 1.]),
                             GAIN * 255.0)], aa)
        return a.sum() / L
    for nm, aa in [('aliased', False), ('AA', True)]:
        e0 = energy_per_len(0.0, aa)
        e22 = energy_per_len(math.radians(22.5), aa)
        e45 = energy_per_len(math.radians(45), aa)
        print(f'star {nm:7s} energy/length: H=1.00  22.5deg={e22/max(e0,1e-9):.2f}  '
              f'45deg={e45/max(e0,1e-9):.2f}  (1.00 == angle-independent)')
    print(f'  -> {out}')

    # 2. Real scene
    scene = sys.argv[1] if len(sys.argv) > 1 else 'logo'
    strokes = scene_strokes(scene)
    racc_al = render_strokes(strokes, aa=False)
    racc_aa = render_strokes(strokes, aa=True)
    al_h, aa_h = halo(racc_al), halo(racc_aa)
    # full-frame half-res view (always shows the whole scene)
    full = [('aliased 1px + halo (current)', np.asarray(Image.fromarray(al_h).resize((W // 2, H // 2), Image.LANCZOS))),
            ('AA vector + halo (proposed)', np.asarray(Image.fromarray(aa_h).resize((W // 2, H // 2), Image.LANCZOS)))]
    out_full = os.path.join(R.OUTDIR, f'vec_{scene}_full.png')
    sheet(f'VECTOR-FAITHFUL bloom {scene} FULL  gain={GAIN} halo s={HALO_S}',
          full, W // 2, H // 2).save(out_full)
    # crop to DENSEST 240x180 window (centroid lands in hollow wireframes)
    lum = aa_h.max(2).astype(np.float64)
    cw, ch, mag = 240, 180, 4
    # coarse block-sum via cumulative integral image -> argmax window
    integ = np.pad(lum, ((1, 0), (1, 0))).cumsum(0).cumsum(1)
    best, bx, by = -1, 0, 0
    for yy in range(0, H - ch, 30):
        for xx in range(0, W - cw, 30):
            s = (integ[yy + ch, xx + cw] - integ[yy, xx + cw]
                 - integ[yy + ch, xx] + integ[yy, xx])
            if s > best:
                best, bx, by = s, xx, yy
    rpanels = [
        ('aliased 1px + halo (current)', crop_mag(al_h, bx, by, cw, ch, mag)),
        ('AA vector + halo (proposed)', crop_mag(aa_h, bx, by, cw, ch, mag)),
    ]
    out2 = os.path.join(R.OUTDIR, f'vec_{scene}.png')
    sheet(f'VECTOR-FAITHFUL bloom {scene}  densest ({bx},{by})+{cw}x{ch} x{mag}  '
          f'gain={GAIN} halo s={HALO_S}', rpanels, cw * mag, ch * mag).save(out2)
    print(f'[{scene}] {len(strokes)} visible strokes  full->{out_full}  crop->{out2}')


if __name__ == '__main__':
    main()
