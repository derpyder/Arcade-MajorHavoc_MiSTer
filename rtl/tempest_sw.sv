// ============================================================================
// tempest_sw.sv -- Tempest game module on the Star Wars MiSTer chassis.
//
// Replaces starwars.sv.  Hosts tempest.vhd (T65 6502 + memory map + avg_tempest
// + 2x POKEY) and feeds its AVG vector output into the PROVEN vector_fb_ddram
// DDR framebuffer (the whole point of moving off the unproven Black Widow DDR).
//
// Video timing (980x700 raster) is lifted verbatim from starwars.sv; RGB is
// zeroed because ascal scans the framebuffer directly.  Tempest is mono audio.
//
// !! HW-TUNABLE (first pass): the Tempest-coords -> 980x700 mapping (orientation
//    + scale) and the Z intensity.  Tune on hardware.
// ============================================================================

module tempest_sw (
	input         clk_12,
	input         clk_50,
	input         clk_vid,
	input         reset,

	input         osd_raster_flicker,
	input         osd_120hz_mode,
	input  [1:0]  osd_rotate,       // HW bring-up: 0 / 90 / 180 / 270
	input         osd_flip,         //             horizontal mirror
	input  [1:0]  osd_scale,        //             0=/2 (safe), 1=x3/4, 2=x1
	input         osd_gate_bypass, //             1 = bypass the gate (native passthrough)
	input  [1:0]  osd_persist,     // vector persistence: lists accumulated/buffer
	                               //   0=3 (default,~_n), 1=4, 2=6, 3=2

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

	// Tempest inputs
	input   [7:0] sw_b4,   // IN2  -> POKEY2 pots (difficulty/rating/fire/zap/start)
	input   [7:0] sw_d4,   // IN1_DSW0 -> POKEY1 pots (spinner low nibble + cabinet)
	input   [7:0] in0,     // IN0  (coins/tilt/service/diag, active low; bit6=avg halt, bit7=3kHz)
	input   [7:0] dsw1,    // DSW1 ($0D00)
	input   [7:0] dsw2,    // DSW2 ($0E00)

	output  [7:0] led,

	// ROM download
	input  [24:0] dn_addr,
	input   [7:0] dn_data,
	input         dn_wr
);

	// ------------------------------------------------------------------------
	// Tempest game module (T65 + memory map + avg_tempest + 2x POKEY + mathbox)
	// ------------------------------------------------------------------------
	wire [9:0]  tmp_x, tmp_y;
	wire [7:0]  tmp_z;
	wire [2:0]  tmp_rgb;
	wire        tmp_beam_ena, tmp_frame_done, tmp_start_frame;
	wire [7:0]  tmp_audio;
	wire [15:0] tmp_dbg;

	tempest tempest_game (
		.reset_h(reset),
		.clk(clk_12),
		.pause_h(1'b0),
		.analog_sound_out(tmp_audio),
		.analog_x_out(tmp_x),
		.analog_y_out(tmp_y),
		.analog_z_out(tmp_z),
		.BEAM_ENA(tmp_beam_ena),
		.rgb_out(tmp_rgb),
		.SW_B4(sw_b4),
		.SW_D4(sw_d4),
		.dn_addr(dn_addr[15:0]),
		.dn_data(dn_data),
		.dn_wr(dn_wr),
		.input_0(in0),
		.input_3(dsw1),
		.input_4(dsw2),
		.frame_done(tmp_frame_done),
		.start_frame(tmp_start_frame),
		.dbg(tmp_dbg),
		.hs_address(16'd0),
		.hs_data_out(),
		.hs_data_in(8'd0),
		.hs_write(1'b0)
	);

	// ------------------------------------------------------------------------
	// Coordinate mapping: Tempest AVG coords -> 980x700 framebuffer, with
	// OSD-tunable orientation + scale (the HW bring-up knobs).  Pipeline:
	//   centre (bit9 invert) -> scale -> centre-about-0 -> rotate/mirror ->
	//   offset to FB centre -> gate beam off when out of bounds (never clamp).
	// Default (status 0): 0deg, no mirror, /2 -> a ~512^2 image centred in
	// 980x700 = GUARANTEED fully on-screen (no clipping).  Dial from the cab.
	// ------------------------------------------------------------------------
	wire [9:0]  cx = {~tmp_x[9], tmp_x[8:0]};        // Tempest coords, centred 0..1023
	wire [9:0]  cy = {~tmp_y[9], tmp_y[8:0]};

	wire [2:0]  sc_num = (osd_scale == 2'd0) ? 3'd2 : // /2   (safe default)
	                     (osd_scale == 2'd1) ? 3'd3 : // x3/4
	                                           3'd4;   // x1
	wire [12:0] cxs  = cx * sc_num;                  // up to 1023*4 = 4092
	wire [12:0] cys  = cy * sc_num;
	wire [9:0]  sx   = cxs[11:2];                     // >>2
	wire [9:0]  sy   = cys[11:2];
	wire [9:0]  half = {sc_num, 7'd0};               // sc_num*128 = scaled centre (256/384/512)

	wire signed [12:0] scx = $signed({3'b000, sx}) - $signed({3'b000, half});
	wire signed [12:0] scy = $signed({3'b000, sy}) - $signed({3'b000, half});

	reg signed [12:0] rx, ry;
	always @* begin
		case (osd_rotate)
			2'd0:    begin rx =  scx; ry =  scy; end // 0
			2'd1:    begin rx =  scy; ry = -scx; end // 90 CW
			2'd2:    begin rx = -scx; ry = -scy; end // 180
			default: begin rx = -scy; ry =  scx; end // 270
		endcase
		if (osd_flip) rx = -rx;                      // horizontal mirror
	end

	// HW orientation baseline (FB-sim verified, orient "C"): flip Y ONLY.  fys=350-ry
	// puts the attract right-side-up with the (c)ATARI/BONUS/CREDITS block along the
	// bottom and FORWARD-reading text.  X is NOT flipped: fxs=490-rx mirrors the text
	// (orient "D"), so keep fxs=490+rx.  OSD Rotate/Mirror adjust relative to this.
	wire signed [13:0] fxs = 14'sd490 + rx;          // X not flipped (490-rx would mirror text)
	wire signed [13:0] fys = 14'sd350 - ry;          // flip Y -> right-side-up (was ry + 350)
	wire in_bounds = (fxs >= 0) && (fxs < 14'sd980) && (fys >= 0) && (fys < 14'sd700);

	wire [9:0]  rast_x   = fxs[9:0];
	wire [9:0]  rast_y   = fys[9:0];
	// Z = real AVG intensity (avg_tempest zout[7:3]) -> brightness.  0 on blanked MOVES
	// (intens_mod=0) so a move writes a BLACK pixel = invisible (ADD_MODE add-0 = no-op).
	// This is what kills the "holocaust": before, rast_z was hardwired full, so the
	// CENTER->object move legs drew at full brightness.
	wire [4:0]  rast_z   = tmp_z[7:3];
	wire [2:0]  rast_rgb = tmp_rgb;
	// BEAM_ON = |rgb (draw EVERY walked point) -- exactly the proven Black Widow feed
	// (bwidow_top.vhd:293 BEAM_ON=rgb0|rgb1|rgb2; Z=zout[7:4]; bwidow_dw blanks on Z==0).
	// avg_tempest here is byte-identical to that BW core, which renders Tempest correctly.
	wire        rast_beam= (|tmp_rgb) && in_bounds;

	// ====================================================================
	// PHOSPHOR-PERSISTENCE present-gate (rtl/present_gate.sv).  Emulates the real
	// tube: accumulate N COMPLETE AVG lists (vggo->vggo) into one draw buffer with
	// NO clear between them (the FB only clears on EOF), so N redraws pile into a
	// union = a crude phosphor.  A beam dropped by DDR contention in one redraw is
	// refilled by another (-> no intermittent dropped beams), and every list is
	// complete (-> projectile tail never cut, no firing flash).  N = OSD-tunable
	// "Persistence" (default 3 == the known-good "_n" accumulation).
	//
	// The FB swaps ready->display on its own scan-out vblank and shows the last
	// completed buffer steadily between EOFs, so the per-EOF beam-off clear window
	// is invisible (no dark flash) and free-running (no vblank lock) is fine: each
	// presented union is identical frame-to-frame, so there is no beat to see.
	// Uses vggo only (avg_halted's short idle broke prior edge gates).  Degrades to
	// a time-window accumulator if vggo dies -> never black, never worse than _n.
	// The SW rasterizer + coordinate math above stay byte-for-byte UNMODIFIED.
	// ====================================================================
	// vggo (avg_go / $4800) rising edge = AVG list start.  tmp_start_frame is in the
	// clk_12 domain (same as this gate and the FB FIFO write side) -> no new CDC.
	reg vggo_d = 1'b0;
	always @(posedge clk_12) vggo_d <= tmp_start_frame;
	wire vggo_rise = tmp_start_frame & ~vggo_d;

	wire pg_beam_window, pg_eof, pg_start;
	present_gate pgate (
		.clk         (clk_12),
		.reset       (reset),
		.vggo_rise   (vggo_rise),
		.persist     (osd_persist),
		.beam_window (pg_beam_window),
		.eof         (pg_eof),
		.frame_start (pg_start)
	);

	// Bypass (OSD Frame Gate=Off) = native AVG passthrough (every ~240Hz list, no
	// accumulation -- the diagnostic).  Otherwise: accumulate N complete lists/buffer.
	wire gated_beam  = osd_gate_bypass ? rast_beam       : (rast_beam & pg_beam_window);
	wire gated_done  = osd_gate_bypass ? tmp_frame_done  : pg_eof;
	wire gated_start = osd_gate_bypass ? tmp_start_frame : pg_start;

	// ------------------------------------------------------------------------
	// DDR vector framebuffer -- the proven SW renderer, UNMODIFIED (980x700).
	// ------------------------------------------------------------------------
	wire fifo_full_led;
	vector_fb_ddram rasterizer (
		.reset(reset),
		.clk_sys(clk_50),
		.clk_12(clk_12),

		.X_VECTOR(rast_x),
		.Y_VECTOR(rast_y),
		.Z_VECTOR(rast_z),
		.RGB(rast_rgb),
		.BEAM_ENA(1'b1),
		.BEAM_ON(gated_beam),

		.START_FRAME(gated_start),
		.FRAME_DONE(gated_done),
		.OSD_FLICKER(osd_raster_flicker),
		.FIFO_FULL_LED(fifo_full_led),

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
	// Audio: Tempest is mono (2x POKEY summed in tempest.vhd) -> both channels.
	// ------------------------------------------------------------------------
	assign audio_out_l = {tmp_audio, tmp_audio};
	assign audio_out_r = {tmp_audio, tmp_audio};

	// ------------------------------------------------------------------------
	// Video timing (980x700 raster, 1056x861 total) -- lifted from starwars.sv.
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
	wire [10:0] vs_start = 11'd703;
	wire [10:0] vs_end   = 11'd709;
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
	assign vblank = (v_cnt >= 11'd700);

	assign led = {7'd0, fifo_full_led};

endmodule
