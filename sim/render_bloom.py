#!/usr/bin/env python3
"""render_bloom.py -- Phase-1 LOOK-LOCK sim for additive vector bloom.

Companion to docs/SPEC-bloom-esb.md.  This is the mandatory sim-first gate
before any Quartus build, because the look is exactly what failed last time
(the Black Widow "dithered pixelated acid trip").

What it models
--------------
The ONE load-bearing hardware change: the DDR-FB read-modify-write pixel
writer (BW rtl/fb_writer.sv lines 117-120) currently OVERWRITES the target
pixel slot.  The proposed change is per-channel SATURATING-ADD.  That single
op delivers both halves of the spec's "bloom":
  (a) additive intensity   -- bright/dwelt strokes accumulate, clamp to white
  (b) intersection overlap -- crossings sum, different colors mix additively

The captured pixel-write logs (pixels_<scene>.txt: "x,y,z,c" per write) ARE
the exact event stream the RMW writer processes -- one line == one RMW.  So
SUMMING those writes is a faithful model of OR/overwrite -> saturating-ADD.
Repeated writes to one pixel (beam dwell at a vertex) and writes from two
strokes to one pixel (a crossing) both accumulate -- which is the whole point.

A/B panels rendered (so the contrast the user demanded is explicit)
-------------------------------------------------------------------
  1. SHARP        -- current overwrite / last-write-wins (== render.py).  Baseline.
  2. ADD-888 lo   -- saturating-ADD, RGB888, low gain.   The proposed bloom.
  3. ADD-888 hi   -- saturating-ADD, RGB888, high gain.
  4. ADD-565 hi   -- same, quantized to RGB565.  Exposes the banding suspect.
  5. BW 1/4-RES   -- the REJECTED recipe: 1/4-res stride-4 5-tap [1,4,6,4,1]
                     Gaussian H/V + composite out=sat(sharp+max(0,bloom-sharp)/2),
                     all RGB565.  The cautionary baseline -- "looked terrible."
  6. ADD-888+HALO -- proposed bloom + an OPTIONAL clean FULL-res additive
                     spread (the spec's only-if-done-right glow, NOT 1/4-res).

Usage
-----
  python render_bloom.py [scene]      # one of: high_score logo intro instr
  python render_bloom.py all          # all four

Outputs (per scene), into sim/bloom_out/:
  bloom_<scene>_sheet.png             # the labeled A/B contact sheet (the deliverable)
  bloom_<scene>_sharp.png             # full-res individuals for pixel-peeping
  bloom_<scene>_add888.png
  bloom_<scene>_bw_gauss.png
and prints accumulation diagnostics (write-count distribution = the falsifiable
"is dwell/overlap actually happening" signal).
"""

import os
import sys

import numpy as np

try:
    from PIL import Image, ImageDraw
except ImportError:
    print('Need Pillow: pip install Pillow')
    sys.exit(1)

# ---------------------------------------------------------------------------
# Geometry + color, matched bit-for-bit to render.py / starwars.sv
# ---------------------------------------------------------------------------
W, H = 980, 700
CX, CY = 490, 349            # render.py origin (note: 349, not H//2)

SCENES = ['high_score', 'logo', 'intro', 'instr']

# Per-write contribution = GAIN * (z/Z_REF if USE_Z else 1) * color_unit, in
# 0..255 per active channel.  Z_REF = the constant-scene nominal intensity.
Z_REF = 112.0
USE_Z = True                 # intensity-weight writes where the log carries it

# DECISIVE (vector_fb_ddram.sv:230-232): the hardware FIFO `push_pix` only
# pushes when the FB pixel coordinate CHANGES -> consecutive-identical writes
# are already deduped in hardware.  So the additive RMW writer accumulates the
# DEDUP stream, not the raw clock-by-clock log.  DEDUP is the faithful model;
# RAW (clock-by-clock dwell) is shown only as a labeled contrast.
GAIN = 0.90                  # single beam-visit brightness (dedup floor == 1)

# Full-res additive halo (spec 4.4).  NOTE finding: because hardware dedups
# dwell AND this content barely overlaps, saturating-ADD alone does NOT glow --
# the visible beam halo comes from this clean full-res spread.  Promoted from
# optional to load-bearing-for-the-look.
HALO_STRENGTH = 0.70
HALO_PASSES = 4              # repeated 5-tap ~ wider clean Gaussian, full-res

OUTDIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'bloom_out')


def map_to_fb(x, y):
    """Vectorized copy of render.py's scaling: X*1.75, Y*1.25, Y inverted.
    numpy >> on int64 is arithmetic (floor) shift, matching Python's >> that
    render.py uses, so this reproduces the established 'sharp' mapping exactly."""
    x = x.astype(np.int64)
    y = y.astype(np.int64)
    x_scaled = (x * 2) - (x >> 2)          # *1.75 in half-pixels
    y_scaled = y + (y >> 2)                # *1.25 in half-pixels
    nx = (x_scaled >> 1) + 490
    ny = 349 - (y_scaled >> 1)
    inb = (nx >= 0) & (nx < W) & (ny >= 0) & (ny < H)
    return nx, ny, inb


def color_units(c):
    """c -> (N,3) float in {0,1}: R=c&4, G=c&2, B=c&1 (render.py pal)."""
    c = c.astype(np.int64)
    r = (c & 4) >> 2
    g = (c & 2) >> 1
    b = (c & 1)
    return np.stack([r, g, b], axis=1).astype(np.float64)


def load_writes(path):
    """Parse 'x,y,z,c' rows. Returns dict of arrays (raw, dups preserved).

    Also computes `keep`: the mask that drops CONSECUTIVE-identical (nx,ny,c)
    writes.  The drawer pipeline emits each painted FB pixel for ~5-6 clocks
    while sub-pixel Bresenham advances; tb_drawer logs every clock, so the raw
    stream has a ~5-6x redundancy FLOOR on every pixel (see sweep.py, which
    dedups the same way for stroke counting).  `keep` collapses each run to one
    write == "one RMW per distinct beam visit", which is the defensible model
    of what the hardware writer should add.  Genuine crossings survive (the two
    strokes are non-consecutive in the stream); only pipeline redundancy is
    removed."""
    data = np.loadtxt(path, delimiter=',', dtype=np.int64)
    x, y, z, c = data[:, 0], data[:, 1], data[:, 2], data[:, 3]
    nx, ny, inb = map_to_fb(x, y)
    # run-length key on the post-mapping FB pixel + color
    key = (nx & 0xFFFF) | ((ny & 0xFFFF) << 16) | ((c & 0xF) << 32)
    keep = np.ones(len(key), bool)
    keep[1:] = key[1:] != key[:-1]
    return dict(x=x, y=y, z=z, c=c, nx=nx, ny=ny, inb=inb, keep=keep)


# ---------------------------------------------------------------------------
# Renderers
# ---------------------------------------------------------------------------
def render_sharp(wr):
    """Current behavior: overwrite / last-write-wins. numpy fancy-assignment
    keeps the last write for duplicate (y,x) -- exactly render.py semantics."""
    img = np.zeros((H, W, 3), np.uint8)
    m = wr['inb']
    units = color_units(wr['c'])[m]
    ny, nx = wr['ny'][m], wr['nx'][m]
    img[ny, nx] = (units * 255).astype(np.uint8)
    return img


def accumulate(wr, gain, dedup=True):
    """Saturating-ADD model: scatter-add per-write light into a float buffer
    (np.add.at accumulates duplicates).  Returns the UNCLAMPED float buffer so
    callers can clamp (888), quantize (565), or spread (halo).

    dedup=True (faithful): one RMW per distinct beam visit, matching the
    hardware FIFO push_pix gate.  dedup=False (contrast): clock-by-clock raw."""
    m = wr['inb'] & wr['keep'] if dedup else wr['inb']
    units = color_units(wr['c'])[m]                  # (N,3) in {0,1}
    if USE_Z:
        wgt = (wr['z'][m].astype(np.float64) / Z_REF)[:, None]
    else:
        wgt = 1.0
    contrib = units * wgt * (gain * 255.0)           # (N,3) float
    acc = np.zeros((H, W, 3), np.float64)
    np.add.at(acc, (wr['ny'][m], wr['nx'][m]), contrib)
    return acc


def clamp888(acc):
    return np.clip(acc, 0, 255).astype(np.uint8)


def quant565(img888):
    """Round-trip RGB888 through RGB565 to surface the banding suspect."""
    a = img888.astype(np.uint16)
    r = (a[..., 0] >> 3) << 3
    g = (a[..., 1] >> 2) << 2
    b = (a[..., 2] >> 3) << 3
    # replicate high bits into the low bits, as a real 565->888 expand would
    r |= r >> 5
    g |= g >> 6
    b |= b >> 5
    return np.stack([r, g, b], axis=2).astype(np.uint8)


def blur5(a):
    """Separable 5-tap [1,4,6,4,1]/16 Gaussian (edge-padded). a:(h,w,3) float."""
    w = np.array([1, 4, 6, 4, 1], np.float64) / 16.0
    p = np.pad(a, ((0, 0), (2, 2), (0, 0)), mode='edge')
    hsum = sum(w[k] * p[:, k:k + a.shape[1], :] for k in range(5))
    p = np.pad(hsum, ((2, 2), (0, 0), (0, 0)), mode='edge')
    vsum = sum(w[k] * p[k:k + a.shape[0], :, :] for k in range(5))
    return vsum


def render_bw_gaussian(sharp888):
    """The REJECTED Black Widow bloom, reproduced faithfully:
       1/4-res STRIDE-4 point sample (thin lines alias to dotted -> 'dithered'),
       5-tap [1,4,6,4,1] Gaussian H then V, NEAREST upscale x4 (-> 'pixelated'),
       composite out=sat(sharp + max(0,bloom-sharp)/2), all in RGB565 (banding)."""
    sharp565 = quant565(sharp888).astype(np.float64)
    # 1/4-res by stride-4 point sampling (NOT area average -- the faithful flaw)
    small = sharp565[::4, ::4, :]                     # (175, 245, 3)
    small = quant565(clamp888(small)).astype(np.float64)
    bloom_small = blur5(small)
    bloom_small = quant565(clamp888(bloom_small)).astype(np.float64)
    # NEAREST upscale x4 back to full res
    up = np.repeat(np.repeat(bloom_small, 4, axis=0), 4, axis=1)
    up = up[:H, :W, :]
    if up.shape[0] < H or up.shape[1] < W:
        up = np.pad(up, ((0, H - up.shape[0]), (0, W - up.shape[1]), (0, 0)), mode='edge')
    # energy-preserving composite, alpha = 0.5
    contrib = np.clip(up - sharp565, 0, None) * 0.5
    out = np.clip(sharp565 + contrib, 0, 255)
    return quant565(out.astype(np.uint8))


def render_halo(acc):
    """Optional clean glow: FULL-res additive spread (NOT 1/4-res). Repeated
    5-tap blur of the accumulation buffer, added back, clamped. RGB888."""
    spread = acc.copy()
    for _ in range(HALO_PASSES):
        spread = blur5(spread)
    out = acc + HALO_STRENGTH * spread
    return clamp888(out)


# ---------------------------------------------------------------------------
# Contact sheet
# ---------------------------------------------------------------------------
def panel(img888, label, pw, ph):
    """One labeled panel: half-res image with a black caption bar above."""
    im = Image.fromarray(img888, 'RGB').resize((pw, ph), Image.LANCZOS)
    bar = 26
    canvas = Image.new('RGB', (pw, ph + bar), (0, 0, 0))
    canvas.paste(im, (0, bar))
    d = ImageDraw.Draw(canvas)
    d.text((6, 7), label, fill=(255, 255, 255))
    return canvas


def make_sheet(scene, panels, pw, ph):
    cols = 3
    rows = (len(panels) + cols - 1) // cols
    bar = 26
    title_h = 30
    sheet = Image.new('RGB', (cols * pw, title_h + rows * (ph + bar)), (16, 16, 16))
    d = ImageDraw.Draw(sheet)
    d.text((8, 8), f'BLOOM LOOK-LOCK  scene={scene}  '
                   f'gain={GAIN} z_weight={USE_Z} halo=s{HALO_STRENGTH}x{HALO_PASSES}',
           fill=(255, 255, 0))
    for i, p in enumerate(panels):
        r, cc = divmod(i, cols)
        sheet.paste(p, (cc * pw, title_h + r * (ph + bar)))
    return sheet


def _px_counts(wr, mask):
    flat = wr['ny'][mask].astype(np.int64) * W + wr['nx'][mask].astype(np.int64)
    counts = np.bincount(flat)
    return counts[counts > 0]


def _hist(counts):
    edges = [1, 2, 3, 5, 9, 17, 33, 65, 10 ** 9]
    prev, parts = 1, []
    for e in edges:
        n = int(((counts >= prev) & (counts < e)).sum())
        parts.append(f'{prev}:{n}' if prev == e - 1
                     else f'{prev}-{e-1 if e < 10**9 else "+"}:{n}')
        prev = e
    return '  '.join(parts)


def diagnostics(scene, wr):
    """Falsifiable signal: how much do writes actually pile up per pixel?
    Compares RAW (with pipeline-redundancy floor) vs DEDUP (one RMW per beam
    visit -- the model we render).  If dedup max/px is ~1-2 only crossings
    accumulate; higher means real dwell/overlap is present."""
    inb = wr['inb']
    raw = _px_counts(wr, inb)
    ded = _px_counts(wr, inb & wr['keep'])
    z = wr['z'][inb]
    print(f'[{scene}] in-bounds writes raw={int(inb.sum())} '
          f'dedup={int((inb & wr["keep"]).sum())} of {len(inb)} total  '
          f'(unique px={len(raw)})')
    print(f'         RAW   writes/px  max={raw.max():>3} mean={raw.mean():5.2f} | ' + _hist(raw))
    print(f'         DEDUP writes/px  max={ded.max():>3} mean={ded.mean():5.2f} | ' + _hist(ded))
    print(f'         z: min={z.min()} max={z.max()} '
          f'{"(varies -> real intensity)" if z.min() != z.max() else "(constant)"}')


def build_variants(wr):
    """Return ordered (label, uint8 image) pairs for every A/B variant."""
    sharp = render_sharp(wr)
    acc = accumulate(wr, GAIN, dedup=True)              # faithful (hw dedups)
    acc_raw = accumulate(wr, GAIN * 0.12, dedup=False)  # contrast (~8x more writes)
    return [
        ('1. SHARP (current overwrite)', sharp),
        (f'2. ADD-888 dedup g={GAIN} (faithful, hw-dedups)', clamp888(acc)),
        (f'3. ADD-888 + full-res halo s={HALO_STRENGTH} (the glow)', render_halo(acc)),
        ('4. ADD-565 + halo (banding test)', quant565(render_halo(acc))),
        ('5. BW 1/4-res Gaussian (REJECTED)', render_bw_gaussian(sharp)),
        ('6. ADD-888 RAW dwell (NOT hw: push_pix dedups)', clamp888(acc_raw)),
    ]


def run_scene(scene):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), f'pixels_{scene}.txt')
    if not os.path.exists(path):
        print(f'  !! missing {path} (run sweep.py first)')
        return
    wr = load_writes(path)
    diagnostics(scene, wr)

    variants = build_variants(wr)
    os.makedirs(OUTDIR, exist_ok=True)
    for lbl, img in variants:
        tag = lbl.split('.')[0]
        Image.fromarray(img, 'RGB').save(os.path.join(OUTDIR, f'bloom_{scene}_{tag}.png'))

    pw, ph = W // 2, H // 2
    panels = [panel(img, lbl, pw, ph) for lbl, img in variants]
    sheet = make_sheet(scene, panels, pw, ph)
    out = os.path.join(OUTDIR, f'bloom_{scene}_sheet.png')
    sheet.save(out)
    print(f'         -> {out}')


def main():
    arg = sys.argv[1] if len(sys.argv) > 1 else 'all'
    scenes = SCENES if arg == 'all' else [arg]
    for s in scenes:
        if s not in SCENES:
            print(f'Unknown scene "{s}". Pick: {", ".join(SCENES)} (or "all")')
            continue
        run_scene(s)


if __name__ == '__main__':
    main()
