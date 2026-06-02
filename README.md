# Major Havoc (Atari, 1983) for MiSTer FPGA

A MiSTer FPGA core for **Major Havoc**, Atari's 1983 dual-CPU color-vector
maze/action game. There is no Major Havoc core on MiSTer main; this one is built by
grafting a new Major Havoc game module onto the proven **Star Wars** color-vector
chassis
([Videodr0me/Arcade-StarWars_MiSTer](https://github.com/Videodr0me/Arcade-StarWars_MiSTer)),
reusing its DDR3 vector framebuffer, display path, and OSD.

> **Status (v1):** boots and is **playable on real DE10-Nano hardware** — the maze,
> the reactor, and the space sequences render; quad-POKEY audio, the roller
> (analog stick / USB spinner / USB mouse), fire, shield, and coins all work; the
> game runs at **authentic speed** (see [Authentic speed](#authentic-speed)); and
> the display is stable (see [Vector presentation](#vector-presentation)).

> ⚠️ **ROMs required — not included.** This core does nothing without the Major
> Havoc romset. You must supply **`mhavoc.zip`** (MAME `mhavoc`) in your MiSTer's
> `games/mame/` folder. No ROMs are distributed here (Major Havoc is © 1983 Atari).
> See [Install](#install).

---

## Why "Star Wars chassis"?

Major Havoc and Star Wars run on closely related Atari Analog Vector Generator (AVG)
hardware. Rather than re-implement the hard parts — the DDR3 triple-buffered vector
framebuffer, the MISTER_FB scan-out, the clock/CDC plumbing, the OSD — this core
hosts a Major Havoc **game module** inside Videodr0me's Star Wars project and routes
its AVG vector output into the same `vector_fb_ddram` rasterizer that ships in Star
Wars.

One consequence: the Quartus project, the top-level entity, and the output bitstream
are still named `Arcade-StarWars` internally. What you flash is renamed to
**`Arcade-MajorHavoc.rbf`**, and the MRA's `<rbf>Arcade-MajorHavoc</rbf>` points at it.

## What's in this core (vs. the Star Wars chassis it sits on)

**New — the Major Havoc game module** (`rtl/majorhavoc.vhd`,
`rtl/avg/avg_majorhavoc.vhd`, `rtl/mhavoc_sw.sv`), transcribed from MAME's
`atari/mhavoc.cpp`:

- **Dual 6502 (T65)** — the **Alpha** CPU (2.5 MHz, main game + AVG) and the
  **Gamma** CPU (1.25 MHz, I/O + audio + roller + comms), with the full Major Havoc
  memory map, the banked program ROM, the banked vector ROM, the alpha/gamma
  inter-processor comms latches, and the 5 kHz / ~250 Hz IRQ chain.
- **Color AVG** (`avg_majorhavoc.vhd`) — a Major Havoc variant of Jeroen Domburg's
  behavioral Black Widow AVG, centred and color-mapped for MH.
- **Quad POKEY** audio (4× POKEY summed) on the gamma bus.
- The **roller** (Major Havoc's 8-bit relative dial) and the coin/service inputs.
- A **coordinate map** (MH AVG coords → the 980×720 framebuffer, with OSD
  orientation + scale) and a **phosphor-persistence present-gate**
  (`rtl/present_gate.sv`) — see below.

**Reused, unchanged — Videodr0me's Star Wars chassis:** `vector_fb_ddram.sv` (the
DDR3 triple-buffer vector framebuffer), the MISTER_FB display path, the `sys/`
MiSTer framework, clock/CDC plumbing, and the OSD/DIP infrastructure.

## Authentic speed

Major Havoc is the odd one out among the Atari AVG games: it used a **10 MHz**
crystal (Alpha 6502 at 10/4 = 2.5 MHz), whereas Star Wars, Tempest, Black Widow and
Gravitar all used the **12.096 MHz** crystal the Star Wars chassis runs at. Dropping
MH straight onto the chassis therefore ran the whole game (and its audio pitch)
**~21% fast**.

To fix this without a second clock domain (a separate 10 MHz PLL output corrupts the
ROM download across the clock boundary), the game is kept on the 12.096 MHz chassis
clock but **gated by a clock-enable** (`game_ce`, high 5 of every 6 cycles →
effective ~10.08 MHz, +0.8%). The CPUs, AVG, IRQ rate, and POKEY all derive from the
gated counters, so everything slows uniformly with the hardware ratios preserved.
Sim-verified (the AVG redraw period lands at the authentic rate, geometry identical).

## Vector presentation

A real Major Havoc redraws its whole vector display list many times a second, and
the CRT phosphor *integrates* those redraws: any beam a single redraw happens to
miss is refilled by the next. A DDR framebuffer has no phosphor, so presenting one
redraw per displayed frame exposes every beam the shared-DDR bus drops, and a list
cut mid-draw drops its tail.

`rtl/present_gate.sv` emulates the phosphor: it accumulates **N complete AVG lists**
(each bounded by the CPU's once-per-list `vggo` strobe) into one draw buffer with no
clear between them — a union of N redraws — then presents. Dropped beams get refilled
across redraws, and because every accumulated list is *complete*, no tail is cut. The
framebuffer keeps swapping on its own scan-out vblank, so the per-frame clear window
is never visible. **N is a live OSD knob** ("Persistence"). The framebuffer also
supports a fast **selective-erase** path (replay only the drawn pixels as black,
~1 ms vs a ~16 ms full clear) used at the crisp/N=1 setting; verified in simulation
(`sim/fb/`).

## Install

1. Copy **`releases/Arcade-MajorHavoc.rbf`** to your MiSTer's `_Arcade/cores/`
   (keep exactly one `Arcade-MajorHavoc*.rbf` there).
2. Copy **`releases/MajorHavoc.mra`** to `_Arcade/`.
3. **Required:** put the Major Havoc romset **`mhavoc.zip`** (MAME `mhavoc`) in
   `games/mame/`. **The core will not run without it** — the MRA loads the ROMs
   from this zip. ROMs are not included in this repo or release.

Launch the MRA from the MiSTer arcade menu.

## Controls

| Input | Action |
|---|---|
| **Roller** — left analog stick, **or** a USB spinner, **or** a USB mouse (X axis) | Move the ship / steer through the maze |
| **Fire** (pad A / mouse left) | Fire |
| **Shield** (pad B / mouse right) | Shield |
| **Coin** | Insert coin (the game starts on Fire after a credit) |

The roller has a velocity-shaped response: gentle for fine aim on slow movement,
faster on a quick flick, ported from the tuned Tempest spinner. The analog stick uses
a softer curve (more of the throw dedicated to slow/medium speeds). A real spinner or
mouse gives the most authentic feel; the analog stick works on any pad.

## OSD options

Beyond the standard MiSTer video/scaler options, this core exposes:

- **Aspect ratio** — *Optimized* (auto scale to your output) or *Pixel Perfect* (1:1).
- **Rotate / Flip** — orientation relative to the built-in baseline.
- **Vector Scale** — *Fill (1.25×)* / *Full (1×)* / *Three-Qtr* / *Half*. Fill is the
  default; drop it if a scene clips on your display.
- **Frame Gate** — *On* (normal) presents via the persistence gate; *Off* is a
  native AVG pass-through diagnostic.
- **Persistence** — how many complete vector redraws are accumulated per displayed
  frame (**12** default, then 14 / 10 / 8 / 6 / 4 / 2 / 1 "Crisp"). Higher = more
  phosphor-like fill and steadier image; lower = crisper but flickerier (1 = the
  selective-erase 60 Hz path).

## Known limitations

- **Hi-score persistence** is not implemented (the EAROM is stubbed), so scores
  reset on power cycle.
- Internal project/bitstream identity is `Arcade-StarWars` (see
  [above](#why-star-wars-chassis)).

## Building

Quartus Prime 17.0 (Cyclone V / DE10-Nano):

```
quartus_sh --flow compile Arcade-StarWars
# -> output_files/Arcade-StarWars.rbf  ->  rename to Arcade-MajorHavoc.rbf
```

Simulation lives in `sim/` (ModelSim ASE framebuffer / present-gate tests) and a GHDL
render/cadence testbench under `../Arcade-MajorHavoc/sim/`. See `HANDOFF-mhavoc-sw.md`
for the sim recipes and design history.

## Credits & license

This core stands on a lot of prior work:

- **Videodr0me** — the Star Wars MiSTer port and the `vector_fb_ddram` DDR3 vector
  framebuffer chassis this core is built on.
- **Jeroen Domburg (Sprite_tm)** — the behavioral Black Widow AVG that
  `avg_majorhavoc` is derived from.
- **T65 / POKEY** authors and the broader MiSTer/MAME communities — the Atari vector
  hardware lineage and reference models.
- **MAME** — the authoritative Major Havoc memory map and hardware behavior.

Original code is **GPLv3** (see `COPYING`); third-party modules retain their own
licenses (see file headers and `LICENSES`). This is a non-commercial,
preservation-oriented project and is not affiliated with Atari.
