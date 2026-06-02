# GHDL sim of avg.vhd + vector_drawer against MAME-captured frames

What's here:
- `tb_drawer.vhd` — testbench that loads a MAME-captured vector RAM
  snapshot + the AVG state PROM, drives `vggo`, and logs every clk-cycle
  pixel write (`xout, yout, zout, rgbout`).
- `dpram_sim.vhd` — behavioural DPRAM substitute for the Altera
  `altsyncram` primitive (so GHDL can elaborate without `altera_mf`).
- `prep.py` — pulls 16KB of vector RAM from `.tools/mame0287/snap/vec_*.bin`
  and the AVG PROM from `starwars.zip`, writes them as hex files for the
  testbench to load via VHDL `textio`.
- `sweep.py` — runs the sim against the four named scenes (high_score,
  logo, intro, instr) and prints per-scene color counts.
- `render.py` — converts a per-pixel log into a PNG bitmap with the
  same X/Y scaling `starwars.sv` applies (1.75x X, 1.25x Y, Y inverted).
- `run.ps1` — one-shot compile + run for the high-score scene.

## Usage

```powershell
# Single scene
python prep.py high_score          # writes vec_mem.hex + avg_prom.hex
.\run.ps1                          # compile and simulate
python render.py tb_pixel_writes.txt out.png

# All scenes
python sweep.py
for s in high_score logo intro instr; do
    python render.py pixels_$s.txt render_$s.png
done
```

## Bug-hunting workflow

1. Pick a scene whose hardware output is "wrong" per visual inspection
2. Run sim, render to PNG, compare to MAME's snap/starwars/000X.png
3. The diff between MAME-screenshot and our render shows which AVG output
   gets rendered correctly vs wrong by our RTL.
4. To dig deeper: add instrumentation to `tb_drawer.vhd`'s pixel_cap or
   debug_counts processes (e.g., log start/end positions per VCTR via
   the `dbg` signal's draw/done pulses).

## Known issues this caught

- **2026-05-28 / commit e949074** — zero-displacement strokes (starfield
  dots, glyph anchor points) were silently dropped because WALK
  terminated in 1 clk cycle (80ns) -- too short for the FB pipeline.
  Fixed by gating termination on clk_ena.  Verified by running this
  testbench: c7 dot count went from 0 to 38 (vs MAME's 39 expected).

## Bloom look-lock (Phase 1 of docs/SPEC-bloom-esb.md)

Sim-first proof of the additive-bloom look, BEFORE any Quartus build (the look
is exactly what failed in the Black Widow attempt). Operates on the same
`pixels_<scene>.txt` write logs.

- `render_bloom.py [scene|all]` — A/B contact sheet per scene + per-variant PNGs
  + write-count diagnostics. Models the one hardware change (RMW writer
  overwrite -> per-channel saturating-ADD) against current sharp + the REJECTED
  BW ¼-res Gaussian. Outputs to `bloom_out/`.
- `crop_compare.py <scene> [cx cy cw ch mag]` — magnified crop of all variants
  (auto-centers on densest overlap). Use to judge halo cleanliness, 565 banding,
  BW blockiness, color-mix at crossings.
- `halo_ladder.py [scene]` — Off/Subtle/Standard/Heavy glow ladder + 565 banding,
  cropped+magnified. Picks the OSD halo levels (spec §5).
- `halo_res_test.py [scene]` — isolates why BW failed: full-res vs ½-res(area+
  bilinear) vs ¼-res(area+bilinear) vs ¼-res(point+nearest=BW), glow held equal.
- `render_bloom_vec.py [scene]` — VECTOR-FAITHFUL model: blooms from the AVG
  decoder's stroke geometry, aliased-1px vs anti-aliased coverage-kernel, then
  halo. `aa_star.png` (equal-length spokes) + `vec_<scene>.png` prove the fix for
  the angle-dependent-bloom problem: aliased 45° lines bloom at ~70% of H/V and
  staircase; AA holds bloom flat at every angle. The additive FB must be fed by
  an AA drawer (BW Wu AA drawer / VIS-1), not the current 1px Bresenham.
- `intensity_ladder.py [scene]` — bright-vector overdrive + WHITE-HOT core
  saturation ladder on a colored scene. Real vector games were bright; over-
  driven beam cores desaturate toward white with a colored halo. `intensity_
  <scene>.png`: per-channel clip stays flat-primary at any brightness; white-hot
  (`out=clip(ch)+0.45*sum(max(0,ch-255))`) turns cores white at ~x4 overdrive.
  Also offsets AA softening + recovers bright white crossings/vertices.
- `presets.py [scene]` — TOGGLE/PRESET matrix + glow WIDTH ladder. Proves the
  effect decomposes into orthogonal toggles (AA / beam-overlap / white-hot each
  on/off) so users can pick a plain Glow (non-vector: orig colors) vs full Vector.
  Row 2 = glow width narrow→ultrawide; wide glows go cheap at ½–¼-res. See SPEC
  §5.1 for the OSD design.
- `bloom_profile.py` — proves width⊥intensity on a single line (peak constant
  across radii; soft dome, no spike). The corrected bloom-shape model.
- `sample_ref.py [img]` — color-samples a real-tube reference photo: detects the
  line, averages perpendicular cross-sections → the actual (distance→RGB) falloff
  + hue. (Grab a pasted reference from the clipboard via PowerShell
  `Clipboard.GetImage().Save(...)` first.) The calibration target.
- `single_line.py` / `line_calibrated.py` — reproduce one real-tube line:
  over-driven CYAN core (not white) + per-channel widths (B≫G≫R) → wide deep-blue
  tail, matched to the sampled profile.
- `scale_invariance.py` — proves SPEC §5.2: a source-res bloom is a constant % of
  the picture at every integer scale (persistent), vs a display-px bloom that
  shrinks per scale. Holds the calibrated source-res params (cyan core, per-
  channel radii R2.5/G4.5/Bcore3.5/Btail13/veil24 source px).

Result is recorded in `docs/SPEC-bloom-esb.md §0.5`. Key facts the sim proved:
the hardware FIFO already dedups consecutive writes (`vector_fb_ddram.sv:230-232`),
so additive accumulation = one RMW per beam visit; on this content that yields a
z tonal range + sparse color-mix but NOT a glow — the glow is the full-res
additive halo (½-res area+bilinear is the cheap-clean sweet spot; the BW failure
was point-sample+nearest-upscale, not the ¼-resolution). Bit depth: RGB888 (565
bands the falloff). Needs `numpy` + `Pillow`.
