# Major Havoc on the Star Wars DDR chassis — handoff (HW bring-up)

> ## ▶ SESSION 8g (2026-06-05) — FULL-SCREEN: the "4 quadrants" was a VERILOG WIDTH BUG, not FB wrapping
> **Re-did the ×1.3125 Fill the RIGHT way; the 8f revert note's guess (FB address wrapping / the
> `in_bounds` gate failing to suppress) was WRONG.** The real cause of the 4-quadrant garble was a
> **Verilog width-truncation bug in the re-centre multiply.** The 8f fill wrote the content-bbox centre
> as `wire [10:0] half_x = (10'd537 * sc_n) >> 4;` — the whole expression takes its **narrow 11-bit
> target width**, so `537*21 = 11277` truncates to 11 bits (→1037) **BEFORE** the `>>4`, giving
> **half_x = 64 instead of 704** (and half_y = 72 not 712). Garbage centre offsets → content thrown to
> wrong positions → the "quadrants." **ModelSim-CONFIRMED** (`sim/fb/tb_w.sv`): `(10'd537*sc_n)>>4`
> with sc_n=21 → 64; the width-safe form → 704. Python "verified" the fill because it used the
> *intended* math (`537*21>>4 = 704`) — it cannot see an RTL width truncation. **Lesson burned in: sim
> the actual RTL widths, not a model.**
>
> **The `in_bounds` gate is actually CORRECT** (corrects the 8f note): in `vector_fb_ddram.sv`,
> `push_pix` requires `BEAM_ON`, and `rast_beam = (|tmp_rgb) && in_bounds` gates BEAM_ON — so
> out-of-bounds writes ARE suppressed, no wrapping. Not the cause.
>
> **FIX (user: "keep centered, scale 1.3125, and do it right") — `rtl/mhavoc_sw.sv` coord-map:**
> kept the **scale-locked AVG-centre (512) centering**, NOT the content-bbox re-centre. The scaled
> centre is `(512*sc_n)>>4 = sc_n*32 = {sc_n,5'd0} = half` — a **PURE SHIFT**, width-safe by
> construction (no multiply-in-a-narrow-target). Moved scale to /16 granularity: `sc_n` = 21/16/12/8
> → ×1.3125 (Fill) / ×1 / ×3⁄4 / ×1⁄2. Widened `cxs` to **15 bits** (`cx*sc_n` up to 1023·21=21483)
> and took the `>>4` on that WIDE wire (`cxs[14:4]`). Top OSD label → `Fill (1.31x)`.
>
> **SIM-VERIFIED THE REAL RTL THIS TIME — `sim/fb/tb_coord.sv`** (the exact coord-map wires + widths,
> ModelSim): centre (512,512)→**(490,360)**, `half=672` (the pure-shift centre, NOT 64), scale exactly
> ×1.3125 (+100 AVG-x → +131 fb px, symmetric), fill window AVG-Y ∈ [238,786] (±274 of centre) → full
> 0–720 height, coord corners (0,0)/(1023,1023) → out of bounds + gated. **RESULT: PASS.**
>
> **Build `build_fill_131.log` running → stage `releases/Arcade-MajorHavoc.rbf` → PENDING HW.**
> Remaining unknown is the SAME one as before (NOT a bug now): the fill window is ±274 AVG-units of
> centre; I calibrated to the **attract** (couldn't reach gameplay in the render sim — coin/service MUX
> IN0[7:6] unmodelled). If real gameplay geometry is taller it could clip top/bottom — **HW-verify; OSD
> drop to Full (×1) is the fallback.** Centre + width-safety are now proven, so a clip (if any) is a
> clean scale-down, not a garble.

> ## ▶ SESSION 8f (2026-06-02) — FLICKER = REFRESH CEILING (motion-smear); FIX = SELECTIVE-ERASE
> **The 8d handshake and 8e Fix-B were both sim-clean but had ZERO HW effect (user: "same result"
> twice).** The decisive clue: **"doesn't flicker when nothing is moving."** Static content fuses;
> motion smears. That is the **REFRESH CEILING**, not list-completeness — I chased the wrong layer
> twice. Mechanism: the present rate is capped because the **full-buffer clear is ~16.6 ms** (368640
> words). At high persistence N the period is clear + N·redraw → <30Hz → motion judders + the N
> superimposed redraws smear. Lowering N to shrink the period instead goes BLACK (the fixed 16.6 ms
> clear then dominates the beam-off duty). Same trade-off documented on Tempest (same chassis).
>
> **FIX — SELECTIVE-ERASE in `rtl/vector_fb_ddram.sv` (foundational; benefits Tempest/BW/Gravitar too).**
> Remember EXACTLY which words each buffer wrote (a per-buffer dirty list) and, on recycle, **replay
> just those as black** instead of zeroing the whole buffer. Erase drops **16.6 ms → 1.2–2.4 ms** → the
> present-gate blank shrinks → present rate reaches the 60 Hz scanout cap → **one redraw/frame fuses**
> (use at N=1). Design:
> - `dirty_mem[0:3*32768-1]` of 19-bit within-buffer word offsets (per buffer; A&S-confirmed inferred
>   as **altsyncram block RAM, NUMWORDS=98304**, ~192 M10K). `dirty_wptr[0:2]`, `dirty_ovf[0:2]`.
> - RECORD: on each stage3 BE-write, push `computed_pixel_addr[22:3]` into `dirty_mem[draw_buf]` with a
>   **dedup-vs-last** (kills the slot0/slot1 dup of one word). Overflow (>32768) → set `dirty_ovf`.
> - REPLAY-ERASE: a 2-state FSM (`E_READ`/`E_WRITE`) in the `clearing` branch zeros `clear_base_word +
>   dirty_mem[ct][i]` for i<wptr. Read/write are time-separated from RECORD (the pipeline is flushed
>   while clearing), so no RAM aliasing. On done: `dirty_wptr[ct]<=0`.
> - FALLBACK: `use_replay = USE_SELECTIVE_ERASE && !clr_full && !dirty_ovf[next_free]`. Boot clears
>   (first 4) and overflowed/dense (>CAP) buffers use the proven full/band clear (which also resets the
>   list). `localparam USE_SELECTIVE_ERASE=1'b1` toggles the whole thing; full clear is the safety net.
> - `present_gate.sv` persist REMAPPED: **0→N=1 (default, crisp/selective)**, 1→2, 2→4, 3→6 (glow =
>   full-clear fallback). OSD label `"OST,Persistence,1 Crisp (default),2,4,6"`.
>
> **SIM-VALIDATED — `sim/fb/tb_selerase.sv`** (moving solid bar so un-erased old columns = detectable
> trails; present_gate N=1 + FB + ddr_model contention). At BUSY_DUTY=8 (50%): BAR_W=60 (~15k words)
> erase **1.20 ms**, full render, **no trails** (bands=1), FIFO peak 2; BAR_W=120 (~30k) erase **2.40
> ms**, full render, no trails, degraded 0; BAR_W=140 (~35k > CAP) → **full-clear fallback**, full
> render, no trails. Rotation invariants (clear/draw-vs-display) = 0 throughout. (NOTE: the tb raises
> `ARMED_TIMEOUT` because it models a list as one ~20 ms mega-raster; **real MH redraws every ~4 ms**, so
> the 12 ms default never fires in HW — confirmed: with a fitting list, the partial render vanished →
> degraded=0, lit=full.) A&S: **0 errors**, dirty_mem = block RAM. Build `build_selerase.log`: **Full Compilation 0 errors,
> TIMING MET (setup +0.316ns / hold +0.201ns)**, fits 442/553 RAM blocks (80%; dirty-list ~+228 M10K),
> block-mem 62%, logic 20%. **Staged `releases/Arcade-MajorHavoc.rbf` (3.52 MB) — PENDING HW.**
> **NEXT: flash → judge MOTION flicker on the cab at Persistence=1 (Crisp, default).** Expectation:
> static was already fine; motion (tunnel/side-scroll) should now fuse (single 60Hz redraw, ~1-2ms
> erase). If a dense frame still smears, it may exceed DIRTY_CAP=32768 → full-clear fallback (raise CAP
> if RAM allows — 80% used, ~111 blocks free ≈ +15k entries). Persistence 2/4/6 = phosphor glow via the
> proven full-clear (today's look) — the escape hatch if selective-erase misbehaves on HW.
>
> **▶ 8f HW RESULT + MENU EXTENSION (2026-06-02): selective-erase/crisp was NOT the win — MORE
> accumulation is better.** On the cab: the 60Hz crisp (N=1, selective-erase) makes the *visible*
> side-scroll frames smooth, BUT **"persistence 6 still best, crisp is the WORST."** A single redraw is
> too sparse on its own; piling N redraws (no clear between) emulates the tube phosphor → fuller/brighter
> = better. So selective-erase (N=1) is now just the bottom menu option; the win is HIGH N (full-clear).
> User wants to explore past 6. **Extended the OSD Persistence menu to 8/10/12/14** (3-bit, 8 options:
> 6 default,8,10,12,14,4,2,1 Crisp). `present_gate.persist` + `mhavoc_sw.osd_persist` widened to [2:0];
> nlists case 0..7 = {6,8,10,12,14,4,2,1}. **Default restored to 6.** N<=14 (nlists[3:0]<=15), accumulation
> <=~35ms < the gate's 60ms CAP_TIMEOUT. All N>=2 = proven full-clear (dirty list overflows, by design).
>
> **⚠️ BIT-LOCATION GOTCHA (cost a build): this OSD/firmware will NOT cycle status bits >=32.** First
> attempt put the 3-bit field at **status[34:32]** ("OWY", widened `wire status` to [63:0] since [0:31]
> had no 3 contiguous free bits) → HW: the menu SHOWED but **"can't move it off 6"** (stuck at default).
> Proof it's the high bits: the prior build cycled fine at [29:28]; only the location changed. **FIX:
> keep the field in low-32 by RECLAIMING bit 27** → field at **status[29:27] ("ORT")**. Bit 27 was a dead
> `status[27]&nvram_dirty` term in `ioctl_upload_req` (no menu ever set it); dropped that term (save runs
> off status[4]/force_save) so odd persistence values don't spuriously fire an nvram save. `wire status`
> back to [31:0]. (Bits 28/29 = old persistence field; 30/31 = Vector Scale; 26 still free.) Build
> `build_persist2.log`: **0 errors, TIMING MET (worst slack +0.245ns)**, staged
> `releases/Arcade-MajorHavoc.rbf` (3.51 MB) — PENDING HW (the field now cycles in the low-32 region).
> **LESSON: O-options must live in status[0:31] on this framework; >=32 parses/displays but won't cycle.**
>
> **▶ 8f GAME-SPEED FIX — TRUE 10 MHz game clock (was ~21% fast).** HW: at persistence=8 the user saw
> ship-sprite DOUBLING (accumulation crossing a game-frame boundary — clock-INDEPENDENT, knee stays ~6)
> AND "sidescrolling feels really fast" = the GAME SPEED. MH wants a 10 MHz master (alpha=clk/4=2.5MHz,
> gamma=clk/8, IRQ=clk/2048, POKEY); the SW chassis clk_12 = **12.096774 MHz** ran the whole game
> 12.096/10 = **~21% fast** (and audio pitch +21%). FIX (the intended one, per the old mhavoc_sw comment):
> **repurpose the UNUSED 6 MHz PLL output (outclk_2) to a true 10.000 MHz** and feed ONLY the game.
> - `rtl/pll/pll_0002.v`: `output_clock_frequency2` 6.048387 → **10.000000 MHz** (VCO 750MHz/75 = exact).
> - Top: `clk_6`→`clk_10` (wire + `.outclk_2`), feed `mhavoc_sw.clk_12` port **`clk_10`** (the game +
>   present_gate + AVG now run 10 MHz). `clk_12` (12.096) STILL clocks the roller NCO + hps_io, so the
>   tuned roller is UNTOUCHED. FB stays clk_50. CDC game↔FB is the existing dual-clock FIFO + handshake.
> - `Arcade-StarWars.sdc`: added `emu_clk_10` (general[2]) to the async `set_clock_groups` (was unused).
> Build `build_10mhz.log` was 0 err / PLL confirmed 10.0 MHz / timing met... **but HW = BLACK SCREEN
> (OSD works, game dead/silent).** ROOT CAUSE: the ROM-download strobe **`dn_wr = ioctl_wr & rom_download`
> is a clk_12 (12.096 MHz, 83ns) pulse**, but the game's ROM WRITE port moved to clk_10 (100ns period) →
> the slower domain MISSES pulses → corrupted ROM load → dead 6502s. (clk_10 itself routed fine; OSD is
> on clk_12 so it survived.) `dn_wr` has no guaranteed gaps (raw ioctl_wr), so a simple stretch/toggle CDC
> is unsafe. **REVERTED the clk_10 split** (`build_revert.log`: PLL back to 6.048/unused, game back on
> clk_12, SDC group removed) → restored the working ~21%-fast build + the 8/10/12 persistence menu.
>
> **PROPER SPEED FIX — DONE + SIM-VALIDATED (gate the game on clk_12, NO clock crossing):**
> POKEY is `CLK=>clk, ENA=>gamma_ena`; CPUs ride alpha_ena/gamma_ena; AVG rides avg_ena=alpha_ena; IRQ
> rides `irq5k_tick` from `irq5k_div` — all off `clkdiv`. So in `rtl/majorhavoc.vhd` (BOTH copies):
> (1) `game_ce` = high 5 of every 6 clk (`ce_cnt` 0..5) → eff 10.08 MHz (+0.8%); (2) gate `clkdiv`
> increment with game_ce; (3) **AND game_ce into the alpha_ena/gamma_ena decodes** (keeps them single-
> cycle — else the held "11"/"111" double-clocks the CPU); (4) gate `irq5k_div` with game_ce. Everything
> slows uniformly, ratios preserved, game stays clk_12 → download clean (no CDC). **SIM-VALIDATED**
> (module-copy GHDL `runrender.sh 72000 108000 115ms`, `render_gated.log`): renders the attract, **VGGO→
> VGGO = 2.95 ms (was 2.46 ms = exactly 1.2× slower → 10.08 MHz)**, bbox **ax[168..907] ay[279..808]
> IDENTICAL to the known-good**, fit=20/OVERRUN=3 (= pre-gating, Fix B handles). SW A&S 0 err. Also made
> **persistence default = 8** (CONF_STR "8 (default),6,10,12,14,...", present_gate case 3'd0→8). Build
> `build_gating.log` → stage. **!! HW-VERIFY: speed feels right + still renders + audio pitch correct.**
> NOTE: the two majorhavoc.vhd copies are otherwise OUT OF SYNC (SW has real quad-POKEY; module copy has
> the POKEY stub) — only the gating + game logic match. Does NOT remove high-N doubling (clock-independent).
>
> **▶ 8f INPUT/PERSISTENCE TUNING (2026-06-02, after gating; `build_input.log`):**
> (1) **Persistence default → 12** (menu "12 (default),14,10,8,6,4,2,1 Crisp"; present_gate 3'd0→12).
> Still < the gate's CAP_TIMEOUT (14×2.95ms=41ms < 59ms).
> (2) **Analog-stick curve #2 — CONCAVE** (`m_rate = m_amag - m_amag^2/256` in Arcade-StarWars.sv):
> near-linear at the bottom, FLATTENS at the top → most of the throw = slow-medium, max ~HALVED
> (amag 127→64 vs old 127). Gentler slope than the old linear everywhere. D-pad fixed rate 80→40.
> "extreme less fast + more stick dedicated to slow-medium."
> (3) **Mouse/spinner #3 — ported from Tempest's slowgain build** (Arcade-StarWars.sv): added
> `ps2_mouse` to hps_io (USB mouse X→roller, LMB→fire, RMB→shield) + spinner_0/1, whichever moved.
> SLOWGAIN 3/4 (lossless carry, de-sensitize slow) + RATE-PACED ±1 stepper (velocity=step rate;
> queue gained steps, drain at one per PACE_DIV=6000 ≈ 34/60Hz-frame; STEP_CAP=20 bounds a flick).
> MH dial is 8-bit (wraps at 128, not Tempest's 8) so the brisk pace is safe. The `sp_mag!=0` gate
> preserves the analog-NCO fallback (no zero-delta-toggle starvation). A&S 0 err. **!! HW-VERIFY:
> spinner/mouse DIRECTION (flip `~sp_in[8]`), feel (PACE_DIV/STEP_CAP/slowgain), analog curve.**
> PACE_DIV/STEP_CAP/slowgain + the concave curve are all easy single-constant tweaks for HW tuning.
>
> **▶ 8f FULL-HEIGHT FILL (2026-06-02; `build_fill.log`):** user: "can't go full height 1080p with fill."
> Diagnosed: the FB→1080p aspect is FINE (Optimized auto_ary=1080 → 980x720 scaled 1.5x to 1470x1080,
> fills the height). The real problem was the **Vector Scale coord-map** (mhavoc_sw.sv): (a) Fill was only
> ×1.25, and (b) the content is **OFF-CENTRE** — render-sim bbox `ax[168..907] ay[279..808]` → content
> centre cx~537/cy~543, NOT the field centre 512, so at the 512-centred map it sat ~25/31 units low-right
> = a top gap + a bottom/right CLIP (the clip is why it couldn't just be scaled up). FIX (BW method, from
> their `8f20c88` "fill 13/16 calibrated to gameplay-not-attract via the golden FB sim"): switched the
> scale to **/16 granularity** (sc_n: Fill=21/16=×1.3125, Full=16, 3/4=12, Half=8) AND **re-centre** to
> the measured content centre (`half_x=537*sc_n/16`, `half_y=543*sc_n/16`). **Python-verified on the
> 42540-point captured display list: FB X 6..976 / Y 12..706, 0 clipped (0.0%), 96% height / 99% width.**
> CAVEAT (BW's lesson — gameplay can be TALLER than attract): could NOT reach MH gameplay in the render
> sim — the **coin/service MUX (IN0[7:6]) isn't modelled in the tb** (coin reads as service → "CREDITS 0",
> stayed in attract; rendered `mhavoc_raw.png` = the attract tunnel). So calibrated to the ATTRACT tunnel
> (representative — same perspective geometry the maze uses), with ~12-14px FB margin. tb now injects
> coin+fire (`inj` process) but needs the mux modelled to actually reach gameplay.
>
> **▶ 8f FILL — REVERTED (HW: 4-quadrant tiling; `build_revertfill.log`).** On the cab the fill build put
> the canvas in **4 quadrants** = FB address WRAPPING (out-of-bounds content tiling 2×2). The attract was
> sim-verified in-bounds (0 clipped), but HW gameplay/other scenes clearly use a WIDER coord range that,
> at the bigger ×1.3125 + re-centre, mapped out of bounds and WRAPPED instead of being gated off — so the
> attract calibration was unsafe for real content. **Reverted `mhavoc_sw.sv` coord-map to the working
> ×1.25 /4, field-512-centred version** (`git checkout 6e55f05 -- mhavoc_sw.sv`; kept the tb coin/fire
> inj). Everything else (gating, persistence-12, mouse/spinner) unchanged. **LESSON for a future fill:**
> (1) the `in_bounds` beam-gate must be confirmed to actually SUPPRESS out-of-bounds writes (the bigger
> content exposed wrapping the attract-sim didn't) — suspect the gate or a width path; (2) must measure
> REAL gameplay extent (model the coin/service mux to get past the attract), not the attract. Fill stays
> at the proven ×1.25 for now.
>
> **▶ CROSS-CORE (verified): only MH is affected.** The chassis clk_12 ≈ 12.096 MHz IS Star Wars' crystal,
> which **Tempest, Black Widow, Gravitar also used** (their 6502s = clk/8 = 1.5 MHz — confirmed in
> tempest `slapstic101.vhd` "12 MHz master" + bwidow.vhd "1.5MHz enable / 250Hz interrupt"). So those drop
> onto the chassis at correct speed. **MH is the lone 10 MHz / clk-4 oddball → the only one ~21% fast.**
> The shipped Tempest/BW/Gravitar need NO clock change.
> **NEXT: flash → verify speed feels right (vs MAME/video) + re-judge motion & persistence at 10 MHz.**

> ## ▶ SESSION 8e (2026-06-01) — STROBING root cause = AVG OVERRUN (NOT the chassis); FIX B building
> The side-scroll/tunnel flicker is **NOT the framebuffer/present-gate** — sim-PROVEN clean: an
> integration sim (`sim/fb/tb_integ.sv` = present_gate + FB + scanout + rotation-invariant checks),
> even at N=2, shows no overrun, no display/clear collision, display buffer full (14000 words). The
> flicker is the AVG drawing **partial/blank lists upstream**.
>
> **Diagnosis — game sim `../Arcade-MajorHavoc/sim/tb_mhavoc_render.vhd`, VGGO→HALT timing on the
> attract tunnel (reachable in sim, reproduces the flicker):** normal frames VGGO→VGGO 2.46 ms / AVG
> draw 0.69 ms (huge margin), but ~2/21 frames the CPU re-fires VGGO at **0.53 ms (< the 0.69 ms draw)**
> → the AVG is mid-draw → the OLD code RESTARTS on every vggo edge (abandons the partial list) and the
> following frame draws BLANK (3.2 µs near-empty = the IRQ blank-head / vector-RAM bank swap). **The CPU
> does NOT poll avg_halted (free-runs VGGO)**; MH relies on the real AVG being fast enough, and the FPGA
> `vector_drawer` ("timing is way off", per its own header) is too slow on the dense long-vector frames.
> Whole-screen (not per-object) → rules out the alpha/gamma mailbox race.
>
> **clk/2 AVG (global speedup) = DEAD END:** OVERRUN→0 but **0 lit points** (beam stuck at centre) — the
> vecram FETCH needs clk/4 to settle. Reverted.  (Speeding only the WALK is blocked by the held draw-pulse.)
>
> **FIX B (building `build_avgB.log`; in `avg_majorhavoc.vhd` — edited the module copy, `cp`'d to the SW
> copy, both match):** on a vggo that arrives MID-DRAW, **LATCH it (`pending_vggo`)** instead of
> restarting — the AVG finishes the COMPLETE current list, then applies the deferred vggo on HALT. The
> latch (NOT a drop) keeps the content vggo — the old halted-only attempt DROPPED it → blank (see the
> line-~218 comment). SIM (game render): geometry **INTACT** (14825 lit pts, bbox ax[168..907]
> ay[279..808]); the near-empty BLANK frames **GONE** (frame 9: 3.2 µs → 161 µs). Chassis (solid fill +
> roller + handshake) unchanged — B is purely the AVG/game module.
> **NEXT: flash `build_avgB` rbf → judge the attract-tunnel / side-scroll flicker on the cab.** If B
> isn't enough, the deeper fix is matching the `vector_drawer` per-vector timing to the real AVG.

> ## ▶ SESSION 8d (2026-06-01) — #2 strobing: diagnosis REFINED + CLEAR-DONE HANDSHAKE (low-risk)
> Built `build_handshake.log` (0 err, timing MET setup +0.748 / hold +0.100); staged
> `releases/Arcade-MajorHavoc.rbf`. **Pivoted away from the quad-buffer (session-8c) to a much
> lower-risk fix after a HW test refined the diagnosis.**
>
> **Diagnosis refined (HW):** asked the user to drop Persistence on the current build; result =
> "the more black frames the lower I go." That's the signature of the **clear OVERRUN**, not refresh
> judder: the clear runs ~6.6 ms past the fixed 10 ms present-blank, so the beam turns on into a
> still-clearing buffer EVERY present and the early beam is dropped.  At N=6 it eats ~1 of 6 redraws
> (the residual strobe); at low N it eats most → near-black frames.  So the strobing is dropped beams,
> and the fix is "don't un-blank until the clear is actually done" — NOT the refresh-raising quad-buffer.
>
> **FIX = CLEAR-DONE HANDSHAKE (no FB draw-pipeline change):**
> - `vector_fb_ddram.sv`: new output `CLEAR_BUSY = clearing` (just exposes the existing clear flag).
> - `mhavoc_sw.sv`: 2-FF sync `CLEAR_BUSY` (clk_sys) -> clk_12 (`cb_sync`), feed `present_gate.clear_busy`.
> - `present_gate.sv`: S_BLANK now waits for clear_busy SEEN-high-THEN-low (`seen_busy`), capped by
>   `MAX_BLANK` (~50 ms safety/degrade), replacing the fixed `BLANK_CYC`.  Blank now = the real clear
>   time (adapts to the content-adaptive band + contention); no fixed overrun -> no dropped beams.
> - SIM `sim/fb/tb_gate2.sv` (models clear_busy): **no overrun (beam never on during clear), blank_span
>   adapts 480/960 to clear length, accumulation = N correct + last-list-complete, safe degrade on
>   stuck-clear / dead-vggo.** FB unchanged (`tb_fb_trails` still 100% retention).
> - **BONUS: lowering Persistence is now CLEAN** (overrun gone -> no black-frame cliff) => a real
>   persistence/refresh dial.  HW: check side-scroll at default N=6 first, then drop N to taste.
>
> **If residual JUDDER remains after the handshake** (full-screen + high contention -> long blank ->
> low refresh), the **QUAD-BUFFER background clear (session-8c plan) is the fallback** to raise the
> refresh ceiling — but it's the risky arbiter surgery, only warranted if the handshake isn't enough.

> ## ▶ SESSION 8c (2026-06-01) — #1 SOLID FILL done (write-side line-fill); #2 (flash) plan
> User approved the two follow-ups (solid full-fill; kill the flash). **#1 DONE + sim-verified;
> built `build_linefill.log` (0 err, timing met setup +0.383); staged `releases/Arcade-MajorHavoc.rbf`.**
>
> **#1 SOLID FILL — write-side Bresenham line-fill in `vector_fb_ddram.sv`.** Root issue: the AVG's
> `vector_drawer` walks lines at NATIVE res, then `mhavoc_sw` scales the walked points -> Scale >1
> spreads them -> dotted. FIX: the AVG steps at `avg_ena = clk/4` (3 idle clk_12 cycles between
> points), so on the WRITE side, when a CONTINUATION point (no beam-off/move since last push) lands
> 2..3 px from the last pushed pixel, walk Bresenham last->new injecting the gap pixels into the FIFO
> across the idle cycles. The 50 MHz READ pipeline is UNTOUCHED. Key safety: at Scale x1 gaps are
> <=1px so the fill NEVER triggers -> the proven default path is byte-identical; fill only enhances
> Scale>1. **∴ Fill (x1.25) is now the SOLID default** (~91% V-fill). gap cap 3 fits the clk/4 slack;
> `beam_gap` blocks fill across moves; gaps >3 fall through to a plain push (no spurious line).
> SIM: repointed `tb_fb_trails` (feeds at clk/4 now) + NEW solid-golden `fb_metric.py` (Bresenham
> between consecutive lit points) -> **100.0% retention, 0 remaining gaps, 0 spurious, 0 trails @
> BUSY 4/8/12 (25/50/75% contention), FIFO max_occ 2.** Sims run with `+define+SIM_ROWCLEAR`.
>
> **#2 KILL THE FLASH — plan (next): QUAD-BUFFER clear-ahead.** Flash root: the recycled buffer is
> cleared AND drawn in the same ~10ms present-blank, so a full-screen clear (~16ms under contention)
> overruns -> early beam dropped -> flash (side-scroll + opening tunnel). A dirty-list fights the 6x
> persistence overdraw (no cheap HW dedup). Cleaner: add a 4TH DDR buffer + a CLEANING stage so a
> buffer is zeroed in the BACKGROUND over a full present-period (~30ms >> 16ms clear) and the draw
> buffer is always PRE-CLEARED. Clear never races the beam -> no flash; the present-blank can then
> shrink -> higher refresh (also helps residual tunnel flicker). DDR has room (4th buf @ word
> 0x0610E000 / byte 0x30870000). Work = restructure the buffer-rotation FSM (display/ready/draw/
> cleaning) + extend the safety clamp; sim with the trails harness (assert pre-cleared buffer is
> zeroed before draw + no marker survivors). NOT started.

> ## ▶ SESSION 8b (2026-06-01) — HW feedback on the session-8 build + fixes
> Cab results of the session-8 build: **music ✅**; **persistence 6 = side-scroll STILL flashes**;
> **roller: stick now does something (the starvation fix worked) but full-RIGHT → ship hedges LEFT**
> (reversed + far too weak); **Vector Scale Fill (1.25x) = DOTTED lines**. Fixes (built
> `build_roller_scale.log`; staged `releases/Arcade-MajorHavoc.rbf`):
>
> - **DOTTING ROOT CAUSE (important architectural fact):** `avg_majorhavoc` runs `vector_drawer`
>   (Bresenham) which walks each line at NATIVE resolution (≤1 unit/step); `mhavoc_sw` then SCALES
>   those already-walked points. At ×1.25 the points land 1.25 px apart → gaps → dotted. The FB
>   renderer plots POINTS, not interpolated lines. **∴ scaling >1.0 always dots; ×1.0 (1 px steps)
>   is the max that stays solid.** (The FB sim CAN'T catch this — it replays the same walked points,
>   so retention is 100% whether solid or dotted; solidity = walk-density vs scale, not point-count.)
>   → **Default scale reverted to Full (×1.0, solid, ~73% V).** 1.25 kept as a de-emphasized "Fill
>   1.25 (dotty)" last OSD option. **TRUE >73% fill needs line interpolation** — either scale the
>   deltas BEFORE `vector_drawer` (pre-walk, in avg_majorhavoc — plumb OSD scale in + widen vec_dx/dy
>   13→14-bit, watch walk-time/FIFO) OR add Bresenham line-fill between consecutive points in
>   `vector_fb_ddram`. **= the next real task if the user wants full-screen fill.**
> - **Roller direction + rate** (`Arcade-StarWars.sv`): flipped `m_inc` (now `m_ax[7]` / `~joy[0]`) and
>   negated `sp_delta` (MH dial = PORT_REVERSE); NCO tick moved bit[22]→**bit[20] (~4× faster)** so a
>   held stick / D-pad actually moves the ship (was "hedging"). "Hedge then stop" = classic stick-
>   mapped-AS-spinner (delta-on-motion only); the **D-pad (joy[0]/[1], continuous, no mapping) is the
>   unambiguous path** — if it now moves the ship correctly the roller logic is right, and the analog
>   stick works once mapped as **Analog Joystick (NOT spinner)** in MiSTer.
> - **Side-scroll flash UNFIXED** = the refresh ceiling: side-scroll is full-width content → the
>   content-adaptive clear is full-band (~16 ms under contention) > the 10 ms present-gate blank →
>   early-beam drop every buffer. Persistence 6 masks the maze but not full-screen motion. REAL FIX =
>   faster clear (selective-erase of only the prev frame's ~7k lit px, or true burst-stream) → higher
>   refresh → single frame fuses. Separate task (same ceiling as the opening tunnel).
>
> **HW-VERIFY next:** (a) **D-pad ◀▶ moves ship correctly + briskly?** (the key test). (b) roller still
> reversed/weak? adjust m_inc / bit[20]→[19]. (c) Full(×1) framing OK + solid? (d) side-scroll + tunnel
> flash need the clear-speed fix.

> ## ▶ SESSION 8 (2026-06-01) — HW tuning: defaults, vertical fill, roller FIX
> Cab feedback on the session-7 build: **music ✅**; screen-flicker ~90% stable (opening "tunnel of
> triangles" still flickers); needed vertical fill + working gamepad controls (no physical spinner).
> Three changes — built clean (`build_fill_roller.log`, 0 err, timing met setup +0.606); staged
> `releases/Arcade-MajorHavoc.rbf` (2.92 MB). **Built + staged; NOT yet HW-tested.**
>
> 1. **Persistence default 3 → 6** (`present_gate.sv`: persist value 0 → N=6; CONF_STR relabel
>    "6 (default)"). Frame Gate stays default-ON. (User: 6 is the most stable.)
> 2. **Vertical fill = new live OSD "Vector Scale"** (`Arcade-StarWars.sv` CONF_STR `OUV` = status[31:30];
>    `mhavoc_sw.sv` scale datapath WIDENED for sc_num=5 → ×1.25: `sx=cxs[12:2]` 11-bit, `scx` concat
>    `{2'b00,sx}`). Options **Fill(1.25x, DEFAULT) / Full(1x) / Three-Qtr / Half**. Sim-measured on the
>    attract: ×1.25 = **91% V-fill, 0.33% edge-crop** (31/9529 pts at the extreme top/right of the
>    OFF-CENTRE attract — native centre ~537,543 not 512); ×1.0 = 73%, 0 crop. fb_metric 100% retention
>    of in-bounds content @ ×1.25. **Back off to Full via OSD if any GAMEPLAY scene loses content**
>    (gameplay extent unknown — only the attract frame is captured; sim maps now set to ×1.25).
> 3. **Roller "both controls dead" FIXED** (`Arcade-StarWars.sv` m_dial block). ROOT CAUSE: the session-7
>    spinner branch had PRIORITY (`if (sp_tgl^sp_tgl_d) … else if (NCO)`); with `<special_controls>spinner`
>    the framework toggles the spinner bit even with NO physical spinner (zero-delta updates), so the
>    spinner branch ran every cycle (adding 0) and the analog/D-pad NCO else-branch NEVER ran → stick AND
>    d-pad both dead. FIX: **gamepad NCO is now PRIORITY; spinner fires only on (toggle edge AND
>    sp_delta≠0)**. The DIAL→game path is correct ($3800 decode good; music proves the gamma bus is live).
>
> **HW-VERIFY decision tree (next session):** (a) **D-pad ◀▶ moves the ship?** YES → roller fixed (analog
> stick then works once mapped via MiSTer 'Define analog'); STILL DEAD → the bug is the game-side $3800
> roller read (pre-existing — dig into majorhavoc.vhd roller use / avg). (b) Fill good at 1.25x? else OSD
> → Full. (c) roller DIRECTION (negate sp_delta / flip m_inc if reversed). (d) opening-tunnel flicker =
> the refresh ceiling (full-screen clear ~16ms > 10ms blank); real fix = faster/selective clear (separate
> task); persistence 6 masks the maze but not the full-screen tunnel.

> ## ✅ PORT-IN FROM TEMPEST v1.1 (2026-06-01, session 7) — 720 height + real spinner — DONE (sim-verified)
> **STATUS:** both DONE in RTL + SIM-VERIFIED + BUILT. Quartus `build_720spin.log` = **0 errors,
> timing MET** (setup slack +0.538 / hold +0.247 / recovery +4.211 ns). Staged
> `releases/Arcade-MajorHavoc.rbf` (2.88 MB). **NEXT = flash + HW-verify** (spinner direction; 720
> ×3-to-4K scale on a real panel). NB: a stale `releases/Arcade-MajorHavoc-DIAG.rbf` (session-6 probe
> build) sits alongside — copy only ONE `Arcade-MajorHavoc*.rbf` to the cab (the non-DIAG one).
> - **(A) 720 height** — `vector_fb_ddram.sv` (FB_HEIGHT 720, buf 0x5A000 words, FB_BASE 0x302D0000/
>   0x305A0000, draw/clear 0x0605A000/0x060B4000, clamp 0x0610DFFF, CLR_*_FULL 368624/368639,
>   pixel_y<720, band defaults/clamps 699→719); `mhavoc_sw.sv` (Y centre 350→360, in_bounds/raster
>   fys<720, vblank v_cnt>=720, vs 723/729, v_total 860 unchanged); `Arcade-StarWars.sv` auto-scale
>   ARY ×3/×2/×1.5/×1 = 0x1870/0x15A0/0x1438/0x12D0 + pixel-perfect ARY 0x12D0; thresholds 2160/1440/1080.
>   **SIM (`tb_fb_trails`+`fb_metric.py` repointed to MH frame + 720 map): tracked band rows 213..477
>   (= old 203..467 +10, content centred in 720); 100.0% golden retention, 0 missing, 0 spurious, 0
>   marker-survivors, no FIFO overflow — robust @ 25/50/75% DDR contention.**
> - **(B) USB spinner** — `Arcade-StarWars.sv`: `spinner_0/1[8:0]` wired on hps_io; XOR toggle-edge
>   (`spinner_0[8]^spinner_1[8]`); on each edge add the FULL signed 8-bit delta
>   `$signed(spinner_0[7:0])+$signed(spinner_1[7:0])` to the 8-bit `m_dial` (no >>>2 — DIAL is 8-bit,
>   unlike Tempest's 4-bit knob). Analog-stick NCO + D-pad kept as the bench-testable fallback. MRA
>   already has `<special_controls>spinner</special_controls>`. **HW-VERIFY direction (MAME IPT_DIAL
>   PORT_REVERSE — negate `sp_delta` if inverted); a physical spinner can't be bench-tested.**
>
> ---
> *Original port-in spec (now implemented), kept for reference:*
> Tempest (the parent chassis template) gained two chassis-level features. MH should adopt both;
> reference impl + sim-proof live in `D:\deck\fpga\tempest\Arcade-Tempest-SW\` (`docs-720-geometry.md`,
> `Arcade-StarWars.sv` spinner block, `sim/fb/tb_fb_replay.sv`).
>
> **(A) FB height 700 → 720 (for clean 4K integer scale).** MH-SW is still 700 (700×3=2100 ≠ 4K's
> 2160 → letterboxed). 720×3 = 2160 exact; ×1.5=1080, ×2=1440 all clean. The exact constant set
> (Tempest-proven, 100% retention in `fb_metric.py` after the change):
> - `vector_fb_ddram.sv`: `FB_HEIGHT 700→720`; buffer = 720*4096 = **0x2D0000 B / 0x5A000 words**;
>   FB_BASE buf1/2 = **0x302D0000 / 0x305A0000**; draw/clear word buf1/2 = **0x0605A000 / 0x060B4000**;
>   safety-clamp hi = **0x0610DFFF**; full-clear words **368640** (END_FULL 368624 / SINGLE 368639);
>   `pixel_y < 720`. `clear_addr` stays `[18:0]` (368639 = 19 bits, fits). Burst stays exact (÷16).
>   **MH content band differs** — MH's content-adaptive clear (buf_ymin/ymax) auto-tracks it, so the
>   fixed CLR_ROW_* row window is moot for MH; just keep the band logic and the new buffer size.
> - `mhavoc_sw.sv` coord centre: MH centres differently than Tempest (no ^512; +512 in avg) — bump
>   the **Y centre by +10** (350→360 equivalent) so content stays centred in the taller buffer, and
>   `in_bounds`/raster `fys < 720`. Raster timing: `vblank v_cnt>=720`, `vs_start 723`, `vs_end 729`
>   (v_total 860 unchanged). **Update the FB sim's readback window to the new buf offsets** (the
>   Tempest gotcha: a stale 700-era dump window read 8% retention — RTL was fine, the *test* lied).
> - `Arcade-StarWars.sv` auto-scale table: ARY ×3=**0x1870 (2160)**, ×2=0x15A0, ×1.5=0x1438, ×1=0x12D0;
>   thresholds gate ×3 at HDMI_HEIGHT≥2160, ×2≥1440, ×1.5≥1080.
>
> **(B) Real USB spinner → the roller.** Tempest now reads the real `hps_io spinner_0/1[8:0]` device
> (was analog-stick-only). MH's roller is an **8-bit DIAL** (not Tempest's 4-bit knob), so wire it the
> same way but keep 8-bit width: enable `.spinner_0(spinner_0), .spinner_1(spinner_1)` on hps_io;
> edge-detect the **toggle bit** with **XOR not OR** (`spinner_0[8]^spinner_1[8]` — OR masks updates,
> proven in sim); on each edge add the signed delta `spinner_0[7:0]`(+`spinner_1[7:0]`) to the roller
> accumulator. Keep the existing analog/L-R NCO as the bench-testable fallback (you can't test a
> physical spinner). MAME roller = `IPT_DIAL PORT_REVERSE` for MH — if direction is wrong, negate the
> delta (the existing `m_inc` flip note). MRA: add `<special_controls>spinner</special_controls>` (the
> framework then routes the USB spinner to spinner_0 automatically).
>
> Do these as their own step in the bring-up loop (sim the geometry via the repointed `tb_fb_replay`
> before flashing). Neither touches the dual-CPU/POKEY/clear work already in flight.


> ## ▶ RESUME HERE (session 6 — HW bring-up loop, mid-flight)
> The core is **on the cab and playable**: boot/attract/maze render correctly, the centered attract
> matches a real-cabinet photo. We are in the **HW bring-up + tuning loop** (the user flashes builds,
> I respond with fixes). Two builds were produced this session; the **latest source has the
> content-adaptive clear + quad POKEY** and a Quartus build was kicked (`build_pokey.log` → stage
> `output_files/Arcade-StarWars.rbf` as `releases/Arcade-MajorHavoc.rbf`).
>
> **HW findings this session (confirmed on the cab):**
> 1. **Maze renders; needs Persistence 6** to fully fill ("almost all modules visible" at 6).
> 2. **Side-scroll mode FLASHES.** Diagnosed with an on-screen drops-vs-cadence probe (top bar
>    RED=FIFO-overflow / BLUE=gate-timeout / GREEN=healthy): **side-scroll reads GREEN** ⇒ pipeline
>    healthy ⇒ the flash is the **present/refresh-rate ceiling**, NOT drops and NOT cadence.
> 3. **Root mechanism (FB sim, baseline on the MH frame):** the full buffer clear is **~16 ms under
>    50% DDR contention, which EXCEEDS the present_gate's 10 ms blank** → the FB is still `clearing`
>    when the gate opens the beam → early beam dropped EVERY buffer. That overrun-drop is very likely
>    *why the maze needs N=6* (accumulation refills it), and it caps the present rate (→ side-scroll flash).
>
> **The fix in flight (content-adaptive clear, sim-VERIFIED, in the pokey build):** `vector_fb_ddram`
> now tracks the min/max ROW drawn per buffer (`buf_ymin/buf_ymax[0:2]`, all `clk_sys`, no CDC) and
> clears ONLY that band on recycle (vs fixed rows 88..613). Sim (`sim/fb/tb_fb_trails.sv`, repointed to
> MH's frame + coord-map): **tracked band = rows 203..467 = the attract content exactly**; retention
> unchanged (4838 lit); marker-survivors 0; no trails by construction (clear band ⊇ content band ±2).
> A drawn buffer clears ~268 rows vs 526 → ~16 ms→~6 ms → now finishes INSIDE the 10 ms blank → kills
> the overrun-drop. `present_gate` `BLANK_CYC` left at 10 ms (safe; covers the ~6 ms clear).
>
> **Quad POKEY (audio, in the pokey build):** 4× `pokey.vhd` on the gamma `$2000-$203F` bus, MH quad
> decode (select=`g_ad[4:3]`, reg=`{g_ad[5],g_ad[2:0]}`), `ENA`=`gamma_ena`, audio summed ÷4 →
> `analog_sound_out` (unsigned, `AUDIO_S=0`). GHDL-clean. POKEY0 `PIN` tied 0 (= default DSW1; OSD-DIP
> wiring deferred). Audio is HW-verified — listen on the cab.
>
> **NEXT (the live loop):** flash the pokey build. (a) **Side-scroll:** try **Persistence 3–4** (the
> overrun-drop is fixed, so it should fill with fewer redraws = higher present rate = less flash). If
> still flashing, the next lever is **shortening `present_gate.BLANK_CYC`** (now safe since the clear
> is ~6 ms) or a **clear-done handshake** (gate waits for FB `!clearing` instead of a fixed blank).
> Escalation beyond that = per-pixel selective-erase (DDR dirty-list). (b) **Sound:** confirm it plays.
> (c) Still-pending HW tunables: orientation (OSD Rotate/Mirror), **scale → Full** (hardcoded Half;
> `osd_scale(2'd0)` in the top — bump to `2'd2` once oriented), roller direction (flip `m_inc`), the
> **clk_12 ~20% fast** (faithful = 10 MHz PLL outclk), DSW1 gameplay DIPs (wire `PIN`→an `sw[0]`-fed port).
>
> **COMMIT STATE:** top-level core committed `678cd4c` (D:\deck repo). The **session-6 changes —
> content-adaptive clear + present_gate `degraded` output + the (off) DIAG bar in mhavoc_sw + quad
> POKEY + files.qip + the MH sim-harness repoint — are in the WORKING TREE** of `Arcade-MajorHavoc-SW`
> (to be committed; see the commit at the end of session 6 if done). The module-project AVG work
> (bank/centering/X-flip/sparkle) is committed in `../Arcade-MajorHavoc` (`15885f0`/`f4f8fa1`/`db5e47d`).
>
> **Sim recipe (fast, ModelSim ASE ~2s):** `cd sim/fb && MS=/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem;
> "$MS/vlog.exe" -sv +define+SIM_ROWCLEAR ddr_model.sv tb_fb_trails.sv ../../rtl/vector_fb_ddram.sv &&
> "$MS/vsim.exe" -c -gBUSY_DUTY=8 -do "run -all; quit -f" tb_fb_trails` → grep `TRACK:`/`TRAILS`.
> (`tb_fb_trails` reads `../../../Arcade-MajorHavoc/sim/mhavoc_frame.txt`; coord-map = NO ^512.)

---

> **State (2026-05-31, session 5): the top-level core BUILDS CLEAN + closes timing + the render path
> is sim-validated. Ready to FLASH + bring up on the cab.** Not yet HW-tested; not yet committed.

## What this is
A buildable Major Havoc MiSTer core, built by re-hosting the validated `majorhavoc.vhd` game module
(dual 6502 + colour AVG + banked vector ROM, from `../Arcade-MajorHavoc/`) on the **proven Star Wars
DDR-framebuffer chassis** (the same `vector_fb_ddram` + `present_gate` that ship in Star Wars + Tempest).
This is the exact pattern of the Tempest-SW re-host; this core was copied from `Arcade-Tempest-SW` and
the Tempest game swapped for Major Havoc.

## Build status (Quartus 17.0 Lite, 5CSEBA6U23I7)
- `quartus_map` Analysis & Synthesis: **0 errors** (`build_as.log`).
- Full compile: **0 errors**; TimeQuest **setup slack +0.187 ns / hold +0.249 / recovery +3.382** = MET
  (tight but positive — multicorner OFF, same as the shipping Tempest-SW). `build_full.log`.
- Output: `output_files/Arcade-StarWars.rbf` → staged as `releases/Arcade-MajorHavoc.rbf` (2.8 MB).
- Render path sim-validated: `mhavoc_sw`'s coord-map applied to the captured attract (in the
  `../Arcade-MajorHavoc/sim` render) lands **100% inside 980x700, centred** = the coherent attract
  (perspective tunnel + ship + text). The DDR rasterizer itself is the proven SW one (unmodified).

## To flash + run on the cab
1. Copy `releases/Arcade-MajorHavoc.rbf` + `releases/MajorHavoc.mra` to `_Arcade/` (rbf under
   `_Arcade/cores/`). Keep exactly ONE `Arcade-MajorHavoc*.rbf` (stale-rbf gotcha from Tempest).
2. Put the canonical `mhavoc.zip` ROM set where the MRA finds it. ROM order in the MRA matches
   `../Arcade-MajorHavoc/sim/build_mhavoc_dl.py` exactly (.216/.217/.215/.318/.108/.210/.106/.107[+prom]).
3. Boot. Expect the ATTRACT (perspective tunnel + ship + credits text), centred but SMALL (scale is
   hardcoded Half = the safe no-clip default).

## HW bring-up checklist (the tunables — all in `rtl/mhavoc_sw.sv` / the top, OSD where noted)
- **Orientation**: OSD **Rotate** (0/90/180/270) + **Mirror**. Baseline = flip-Y only (`fys=350-ry`,
  `fxs=490+rx`), copied from Tempest's verified orient. MH is a horizontal monitor — adjust if rotated.
- **Scale**: hardcoded **Half** (`osd_scale(2'd0)` in the top's `mhavoc_core` instance). Once orientation
  is right, bump to **Full** (`2'd2`) so it fills the screen — re-add the "O89,Scale" CONF_STR option
  (pick free status bits; it was removed to avoid a status-bit clash) or just hardcode `2'd2`.
- **Roller direction**: MAME has `PORT_REVERSE` on the dial. If the ship/maze moves the wrong way, flip
  `m_inc` in the top's roller NCO (`Arcade-StarWars.sv`, the `m_dial` block).
- **Coin / Fire / Shield**: J1 = Fire(joy4)/Shield(joy5)/Coin(joy6)/Pause(joy7). MH starts on FIRE after
  a coin. DSW2 coinage default = sw[1] (MRA), 1C/1C. Verify a coin registers + Fire starts a game.
- **Clock speed**: game runs on `clk_12` (~20% fast: alpha=3MHz vs real 2.5). Functionally fine for
  bring-up; for correct speed add a 10 MHz PLL outclk (regen `rtl/pll` in the MegaWizard) and feed it to
  `.clk()` in `mhavoc_sw`.

## NOT done (next phases)
- **P4 audio**: quad POKEY ($2000-$203F) — `analog_sound_out` is silent. Also **DSW1** (lives/difficulty/
  bonus) is read via **POKEY 0 allpot**, so those gameplay DIPs are inert until POKEY lands.
- **coin/service player_1 mux**: the module passes `IN0(7:6)` straight (coin reads work; the service
  phase reads the same — credit-to-start default). Faithful fix = mux on `player_sel` inside majorhavoc.
- **2804 EEPROM** hiscore persistence (NVRAM tied off, like Tempest's EAROM stub).
- X-flip/sparkle are DONE in `avg_majorhavoc` (committed in the module project).

## File map (what changed vs the Tempest-SW chassis copy)
- `rtl/mhavoc_sw.sv` — NEW graft (majorhavoc → vector_fb_ddram + present_gate + inputs).
- `rtl/majorhavoc.vhd`, `rtl/avg/avg_majorhavoc.vhd` — copied from `../Arcade-MajorHavoc/rtl` (canonical).
- `rtl/pkg_bwidow.vhd`, `rtl/avg/vector_drawer.vhd` — overwritten with the MH-validated versions (the
  chassis copies had Tempest's `off_screen` warp-clip port that avg_majorhavoc doesn't use).
- `files.qip` — rewritten for the MH set. `Arcade-StarWars.qsf` — direct-file block deleted (files.qip only).
- `Arcade-StarWars.sv` — `mhavoc_sw mhavoc_core` instance, MH input build (coin/fire/shield/roller),
  CONF_STR "MajorHavoc", `dn_addr[17:0]`.
- `releases/MajorHavoc.mra`, `releases/Arcade-MajorHavoc.rbf` — NEW.
- Unused Tempest/SW rtl (tempest.vhd, avg_tempest, mathbox, slapstic, starwars.sv, pokey, earom, ...)
  is still on disk but NOT in files.qip → not compiled. Can be pruned later.

## Rebuild
`cd Arcade-MajorHavoc-SW && /c/intelFPGA_lite/17.0/quartus/bin64/quartus_sh.exe --flow compile Arcade-StarWars`
→ `output_files/Arcade-StarWars.rbf`. (A&S-only fast check: `quartus_map.exe Arcade-StarWars -c Arcade-StarWars`.)
