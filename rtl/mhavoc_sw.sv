// ============================================================================
// mhavoc_sw.sv -- Major Havoc game module on the Star Wars MiSTer chassis.
//
// Replaces tempest_sw.sv / starwars.sv.  Hosts majorhavoc.vhd (dual T65 6502
// alpha+gamma + memory map + avg_majorhavoc + banked vector ROM) and feeds its
// AVG vector output into the PROVEN vector_fb_ddram DDR framebuffer (the same
// renderer that ships in Star Wars + Tempest), through the present_gate.
//
// Differences vs tempest_sw.sv:
//   * Game = majorhavoc (dual-CPU) with IN0/IN1/DSW2/DIAL inputs + dn_addr[17:0].
//   * NO bit-9 centering here: avg_majorhavoc ALREADY centres its output
//     (xout = ~vd_x(9) & vd_x(8:0) = +512), so cx = tmp_x directly (Tempest's
//     tempest.vhd emits raw-centred-at-0 coords, hence its {~tmp_x[9],..} flip).
//   * clk = clk_12 (12.096 MHz).  MH wants 10 MHz (alpha=clk/4=2.5MHz, gamma=clk/8, IRQ=clk/2048,
//     POKEY via gamma_ena) so the game runs ~21% fast.  A clk_10 PLL-split fix BLACK-SCREENED: the
//     ROM-download strobe (dn_wr = ioctl_wr, clk_12) was missed by the slower clk_10 game domain ->
//     corrupted ROM.  PROPER FIX (TODO, HANDOFF 8f): keep clk=clk_12 and gate clkdiv + irq5k with a
//     ~5/6 clock-enable -> alpha/gamma/POKEY (all ride gamma_ena/alpha_ena) slow to ~10.08 MHz, no CDC.
//   * Audio = silence for now (quad POKEY is P4; analog_sound_out is stubbed).
//
// !! HW-TUNABLE (first pass, same as Tempest): the coords->980x720 mapping
//    (orientation + scale, OSD knobs) and the Z intensity.  Tune on the cab.
// ============================================================================

module mhavoc_sw (
	input         clk_12,
	input         clk_50,
	input         clk_vid,
	input         reset,

	input         osd_raster_flicker,
	input         osd_120hz_mode,
	input  [1:0]  osd_rotate,       // HW bring-up: 0 / 90 / 180 / 270
	input         osd_flip,         //             horizontal mirror
	input  [1:0]  osd_scale,        //             0=/2 (safe), 1=x3/4, 2=x1
	input         osd_gate_bypass,  //             1 = bypass the gate (native passthrough)
	input  [2:0]  osd_persist,      // vector persistence: N lists accumulated/buffer (0..7 -> 6,8,10,12,14,4,2,1)

	// DDRAM framebuffer (straight pass-through to the emu module)
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,
`ifdef MISTER_FB_PALETTE
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif

	output [15:0] audio_out_l,
	output [15:0] audio_out_r,

	// video timing (RGB zeroed; FB supplies pixels via ascal)
	output  [2:0] video_r,
	output  [2:0] video_g,
	output  [2:0] video_b,
	output        hsync,
	output        vsync,
	output        vblank,
	output        hblank,

	// Major Havoc inputs
	input   [7:0] in0,    // alpha $1200: b7:6=coin/service mux, b5=service1, b4=diag (all act-low); b3:0 internal
	input   [7:0] in1,    // gamma $2800: b7=P1 fire, b6=P1 shield, b5=P2 fire, b4=P2 shield (act-low); b1:0 internal
	input   [7:0] dsw2,   // gamma $4000: coinage DIP
	input   [7:0] dial,   // gamma $3800: 8-bit roller position

	output  [7:0] led,

	// ROM download
	input  [24:0] dn_addr,
	input   [7:0] dn_data,
	input         dn_wr
);

	// ------------------------------------------------------------------------
	// Major Havoc game module (dual T65 + memory map + avg_majorhavoc + bank ROM)
	// ------------------------------------------------------------------------
	wire [9:0]  tmp_x, tmp_y;
	wire [7:0]  tmp_z;
	wire [2:0]  tmp_rgb;
	wire        tmp_beam_ena, tmp_frame_done, tmp_start_frame;
	wire [7:0]  tmp_audio;
	wire [15:0] tmp_dbg;

	majorhavoc mhavoc_game (
		.reset_h(reset),
		.clk(clk_12),                 // 12.096 MHz -> game ~21% fast (TODO gate to ~10MHz; HANDOFF 8f)
		.pause_h(1'b0),
		.analog_sound_out(tmp_audio),
		.analog_x_out(tmp_x),
		.analog_y_out(tmp_y),
		.analog_z_out(tmp_z),
		.BEAM_ENA(tmp_beam_ena),
		.rgb_out(tmp_rgb),
		.IN0(in0),
		.IN1(in1),
		.DSW2(dsw2),
		.DIAL(dial),
		.frame_done(tmp_frame_done),
		.start_frame(tmp_start_frame),
		.dn_addr(dn_addr[17:0]),
		.dn_data(dn_data),
		.dn_wr(dn_wr),
		.dbg(tmp_dbg)
	);

	// ------------------------------------------------------------------------
	// Coordinate mapping: MH AVG coords (ALREADY centred 0..1023 by avg_majorhavoc)
	// -> 980x720 framebuffer, OSD-tunable orientation + scale.  Pipeline:
	//   already-centred -> scale -> centre-about-0 -> rotate/mirror -> offset to
	//   FB centre -> gate beam off when out of bounds (never clamp).
	// Default (status 0): 0deg, no mirror, x1.25 (Fill) -> ~91% of 720 height, SOLID via the FB
	// write-side line-fill (Bresenham-fills the gaps that scaling >1 would leave between the AVG's
	// native-resolution walked points).  OSD can drop to Full(x1)/3-Qtr/Half if a scene clips.
	// ------------------------------------------------------------------------
	wire [9:0]  cx = tmp_x;                          // MH coords already centred (no bit-9 flip)
	wire [9:0]  cy = tmp_y;

	// OSD Vector Scale (effective scale = sc_num/4).  Default 0 = x1.25 ("Fill", ~91% of the 720
	// height) -- the vector_fb_ddram WRITE-SIDE LINE-FILL makes it SOLID (Bresenham-fills the gaps
	// that scaling >1 would otherwise leave; sim 100% solid).  sc_num=5 needs the widened cxs[12:2].
	wire [2:0]  sc_num = (osd_scale == 2'd0) ? 3'd5 : // x1.25 (Fill, default, solid via line-fill)
	                     (osd_scale == 2'd1) ? 3'd4 : // x1
	                     (osd_scale == 2'd2) ? 3'd3 : // x3/4
	                                           3'd2;   // /2
	wire [12:0] cxs  = cx * sc_num;                   // up to 1023*5 = 5115 (13 bits)
	wire [12:0] cys  = cy * sc_num;
	wire [10:0] sx   = cxs[12:2];                      // >>2  (up to 1278, 11 bits)
	wire [10:0] sy   = cys[12:2];
	wire [9:0]  half = {sc_num, 7'd0};                // sc_num*128 = scaled centre (256..640)

	wire signed [12:0] scx = $signed({2'b00, sx}) - $signed({3'b000, half});
	wire signed [12:0] scy = $signed({2'b00, sy}) - $signed({3'b000, half});

	reg signed [12:0] rx, ry;
	always @* begin
		case (osd_rotate)
			2'd0:    begin rx =  scx; ry =  scy; end // 0
			2'd1:    begin rx =  scy; ry = -scx; end // 90 CW
			2'd2:    begin rx = -scx; ry = -scy; end // 180
			default: begin rx = -scy; ry =  scx; end // 270
		endcase
		if (osd_flip) rx = -rx;                       // horizontal mirror
	end

	// HW orientation baseline (same as Tempest's verified orient "C"): flip Y only.
	// MH renders right-side-up with Y flipped (render_mhavoc.py used H-1-sy).  X not
	// flipped.  OSD Rotate/Mirror adjust relative to this.  !! HW-VERIFY for MH.
	wire signed [13:0] fxs = 14'sd490 + rx;           // X not flipped
	wire signed [13:0] fys = 14'sd360 - ry;           // flip Y -> right-side-up (centre 360 = 720/2)
	wire in_bounds = (fxs >= 0) && (fxs < 14'sd980) && (fys >= 0) && (fys < 14'sd720);

	wire [9:0]  rast_x   = fxs[9:0];
	wire [9:0]  rast_y   = fys[9:0];
	// Z = real AVG intensity (avg_majorhavoc zout[7:3]).  0 on blanked MOVES so a move
	// writes a BLACK pixel = invisible (FB ADD mode add-0 = no-op).
	wire [4:0]  rast_z   = tmp_z[7:3];
	wire [2:0]  rast_rgb = tmp_rgb;
	// BEAM_ON = |rgb (draw every walked lit point); blanked while out of bounds.
	wire        rast_beam= (|tmp_rgb) && in_bounds;

	// ====================================================================
	// PHOSPHOR-PERSISTENCE present-gate (rtl/present_gate.sv) -- accumulate N complete
	// AVG lists (vggo->vggo) into one draw buffer, no clear between (FB clears on EOF
	// only).  N = OSD "Persistence" (default 3).  Identical use to tempest_sw.
	// ====================================================================
	reg vggo_d = 1'b0;
	always @(posedge clk_12) vggo_d <= tmp_start_frame;
	wire vggo_rise = tmp_start_frame & ~vggo_d;

	// FB clear-busy synced to clk_12 (present-gate domain) for the blank HANDSHAKE: the gate holds
	// the beam off until the FB clear actually finishes (no fixed-blank overrun -> no black frames).
	wire fb_clear_busy;                          // from vector_fb_ddram (clk_sys / 50 MHz)
	reg  [1:0] cb_sync = 2'b0;
	always @(posedge clk_12) cb_sync <= {cb_sync[0], fb_clear_busy};

	wire pg_beam_window, pg_eof, pg_start, pg_degraded;
	present_gate pgate (
		.clk         (clk_12),
		.reset       (reset),
		.vggo_rise   (vggo_rise),
		.clear_busy  (cb_sync[1]),
		.persist     (osd_persist),
		.beam_window (pg_beam_window),
		.eof         (pg_eof),
		.frame_start (pg_start),
		.degraded    (pg_degraded)
	);

	wire gated_beam  = osd_gate_bypass ? rast_beam       : (rast_beam & pg_beam_window);
	wire gated_done  = osd_gate_bypass ? tmp_frame_done  : pg_eof;
	wire gated_start = osd_gate_bypass ? tmp_start_frame : pg_start;

	// ====================================================================
	// DIAGNOSTIC (drops vs cadence) -- a top bar drawn into every buffer:
	//   RED   = FB FIFO overflowed this buffer (beam drops / list too dense)
	//   BLUE  = present-gate timed out (vggo too slow = cadence/refresh problem)
	//   GREEN = healthy (no overflow, lists arriving fast)
	// Glance at the TOP edge: the maze should read GREEN; whatever the side-scroll
	// shows tells us the bottleneck.  Set DIAG_DROPS_BAR=0 to remove (it's a probe).
	// ====================================================================
	localparam DIAG_DROPS_BAR = 1'b0;   // probe off for the real build (drops-vs-cadence answered: refresh ceiling)
	reg        ff_acc = 1'b0, dg_acc = 1'b0;   // events accumulated during the current buffer
	reg        ff_show = 1'b0, dg_show = 1'b0; // snapshot drawn in the bar (previous buffer)
	reg [10:0] mk = 11'd0;
	reg        marking = 1'b0;
	always @(posedge clk_12) begin
		if (gated_start) begin
			ff_show <= ff_acc;  dg_show <= dg_acc;   // present the buffer we just finished
			ff_acc  <= 1'b0;    dg_acc  <= 1'b0;     // reset for the new buffer
			marking <= 1'b1;    mk      <= 11'd0;    // start drawing the bar
		end else begin
			if (fifo_full_led) ff_acc <= 1'b1;
			if (pg_degraded)   dg_acc <= 1'b1;
			if (marking) begin
				if (mk >= 11'd979) marking <= 1'b0; else mk <= mk + 11'd1;
			end
		end
	end
	wire [2:0] mk_rgb  = ff_show ? 3'b100 : (dg_show ? 3'b001 : 3'b010);  // R / B / G
	wire       diag_on = DIAG_DROPS_BAR & marking;
	wire [9:0] fb_x    = diag_on ? mk[9:0] : rast_x;
	wire [9:0] fb_y    = diag_on ? 10'd8   : rast_y;
	wire [4:0] fb_z    = diag_on ? 5'd31   : rast_z;
	wire [2:0] fb_rgb  = diag_on ? mk_rgb  : rast_rgb;
	wire       fb_beam = diag_on ? 1'b1    : gated_beam;

	// ------------------------------------------------------------------------
	// DDR vector framebuffer -- the proven SW renderer, UNMODIFIED (980x720).
	// ------------------------------------------------------------------------
	wire fifo_full_led;
	vector_fb_ddram rasterizer (
		.reset(reset),
		.clk_sys(clk_50),
		.clk_12(clk_12),

		.X_VECTOR(fb_x),       // = rast_x, except the diagnostic top-bar override (DIAG_DROPS_BAR)
		.Y_VECTOR(fb_y),
		.Z_VECTOR(fb_z),
		.RGB(fb_rgb),
		.BEAM_ENA(1'b1),
		.BEAM_ON(fb_beam),

		.START_FRAME(gated_start),
		.FRAME_DONE(gated_done),
		.OSD_FLICKER(osd_raster_flicker),
		.FIFO_FULL_LED(fifo_full_led),
		.CLEAR_BUSY(fb_clear_busy),

		.DDRAM_CLK(DDRAM_CLK),
		.DDRAM_BUSY(DDRAM_BUSY),
		.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
		.DDRAM_ADDR(DDRAM_ADDR),
		.DDRAM_DOUT(DDRAM_DOUT),
		.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
		.DDRAM_RD(DDRAM_RD),
		.DDRAM_DIN(DDRAM_DIN),
		.DDRAM_BE(DDRAM_BE),
		.DDRAM_WE(DDRAM_WE),

		.FB_EN(FB_EN),
		.FB_FORMAT(FB_FORMAT),
		.FB_WIDTH(FB_WIDTH),
		.FB_HEIGHT(FB_HEIGHT),
		.FB_BASE(FB_BASE),
		.FB_STRIDE(FB_STRIDE),
		.FB_VBL(FB_VBL),
		.FB_LL(FB_LL),
		.FB_FORCE_BLANK(FB_FORCE_BLANK)
`ifdef MISTER_FB_PALETTE
		,
		.FB_PAL_CLK(FB_PAL_CLK),
		.FB_PAL_ADDR(FB_PAL_ADDR),
		.FB_PAL_DOUT(FB_PAL_DOUT),
		.FB_PAL_DIN(FB_PAL_DIN),
		.FB_PAL_WR(FB_PAL_WR)
`endif
	);

	// ------------------------------------------------------------------------
	// Audio: quad POKEY is P4 (not yet) -> silence.  MH POKEY will be UNSIGNED
	// (AUDIO_S=0 in the top, per the Tempest lesson).  Mono -> both channels.
	// ------------------------------------------------------------------------
	assign audio_out_l = {tmp_audio, tmp_audio};
	assign audio_out_r = {tmp_audio, tmp_audio};

	// ------------------------------------------------------------------------
	// Video timing (980x720 raster, 1056x861 total) -- lifted from starwars.sv.
	// RGB zeroed: ascal scans the framebuffer; the core only supplies sync.
	// ------------------------------------------------------------------------
	assign video_r = 3'b000;
	assign video_g = 3'b000;
	assign video_b = 3'b000;

	reg ce_pix;
	always @(posedge clk_vid) begin
		if (osd_120hz_mode) ce_pix <= 1'b1;
		else                ce_pix <= ~ce_pix;
	end

	reg  [10:0] h_cnt = 0;
	reg  [10:0] v_cnt = 0;
	wire [10:0] h_total  = 11'd1055;
	wire [10:0] v_total  = 11'd860;
	wire [10:0] hs_start = 11'd1004;
	wire [10:0] hs_end   = 11'd1036;
	wire [10:0] vs_start = 11'd723;   // active(720)+3
	wire [10:0] vs_end   = 11'd729;   // active(720)+9 -> 6-line sync, v_total 860 unchanged
	wire h_end = (h_cnt == h_total);
	wire v_end = (v_cnt == v_total);
	always @(posedge clk_vid) begin
		if (ce_pix) begin
			if (h_end) begin
				h_cnt <= 0;
				if (v_end) v_cnt <= 0; else v_cnt <= v_cnt + 1'd1;
			end else h_cnt <= h_cnt + 1'd1;
		end
	end
	assign hsync  = ~(h_cnt >= hs_start && h_cnt < hs_end); // active low
	assign vsync  = ~(v_cnt >= vs_start && v_cnt < vs_end); // active low
	assign hblank = (h_cnt >= 11'd980);
	assign vblank = (v_cnt >= 11'd720);

	assign led = {7'd0, fifo_full_led};

endmodule
