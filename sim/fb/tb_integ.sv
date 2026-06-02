// ============================================================================
// tb_integ.sv -- INTEGRATION sim: present_gate + vector_fb_ddram + ddr_model,
// driven by a modeled free-running AVG.  This is the piece never tested before:
// the gate and FB TOGETHER, with FB.clearing feeding back to gate.clear_busy.
//
// The AVG free-runs: it strobes vggo once per list and emits a full-screen pixel
// stream every list (rows 0..719 scatter -> full-buffer clear, long enough to
// overrun a fixed blank).  The present_gate gates whether those pixels reach the
// FB (BEAM_ON = pix & beam_window) and tells the FB when to swap+clear (eof).
//
// THE MEASUREMENT: overrun_cyc = cycles where beam_window is high AND the FB is
// clearing.  Handshake working => 0 (beam never on during a clear).  Also logs
// blank/cap spans, eof count, and peak FIFO occupancy (overflow => dropped beams).
// ============================================================================
`timescale 1ns/1ps
module tb_integ;
	parameter int      BUSY_DUTY = 8;       // 50% DDR contention
	parameter [1:0]    PERSIST   = 2'd0;     // N=6
	parameter int      LIST_PTS  = 14000;    // points per list (~one redraw, full screen)

	logic clk_sys=0, clk_12=0, reset=1;
	always #10 clk_sys = ~clk_sys;           // 50 MHz
	always #41 clk_12  = ~clk_12;            // ~12 MHz

	// DDR
	logic        ddr_busy, ddr_dr, ddr_rd, ddr_we, ddr_clk;
	logic [7:0]  ddr_burst, ddr_be;
	logic [28:0] ddr_addr;
	logic [63:0] ddr_dout, ddr_din;

	// gate <-> FB
	wire bw, pg_eof, pg_start, pg_degraded;
	wire fb_clearing;
	reg  [1:0] cb_sync = 2'b0;               // FB.clearing (clk_sys) synced to clk_12 (as in mhavoc_sw)
	always @(posedge clk_12) cb_sync <= {cb_sync[0], fb_clearing};

	// ---- modeled AVG: avg_ena = clk_12/4, free-running list generator ----
	reg [1:0] ce = 0;  always @(posedge clk_12) ce <= ce + 1'b1;
	wire avg_ena = (ce == 0);

	int  idx = 0;
	reg  avg_vggo = 1'b0;
	logic [9:0] X=0, Y=0; logic [4:0] Z=0; logic [2:0] RGB=0; logic beam_on=0;
	always @(posedge clk_12) begin
		avg_vggo <= 1'b0;
		if (reset) begin idx <= 0; beam_on <= 0; end
		else if (avg_ena) begin
			// full-screen scatter: row 0..719, col 0..979
			X       <= (idx*13) % 980;
			Y       <= idx % 720;
			Z       <= 5'd20;
			RGB     <= 3'b010;
			beam_on <= bw;                   // gated by the present-gate beam window
			if (idx >= LIST_PTS-1) begin idx <= 0; avg_vggo <= 1'b1; end  // list wrap -> vggo
			else idx <= idx + 1;
		end
	end

	present_gate #(.MAX_BLANK(22'd600000)) pg (
		.clk(clk_12), .reset(reset), .vggo_rise(avg_vggo), .clear_busy(cb_sync[1]),
		.persist(PERSIST), .beam_window(bw), .eof(pg_eof), .frame_start(pg_start), .degraded(pg_degraded)
	);

	// scanout vblank ~60 Hz (drives the FB display<-ready swap)
	int vblc = 0; reg fbvbl = 0;
	always @(posedge clk_sys) begin
		vblc <= (vblc >= 83333) ? 0 : vblc + 1;
		fbvbl <= (vblc < 20);
	end

	logic fb_en, fb_fblank; logic [4:0] fb_fmt; logic [11:0] fb_w, fb_h; logic [31:0] fb_base; logic [13:0] fb_str;
	vector_fb_ddram fb (
		.clk_sys(clk_sys), .clk_12(clk_12), .reset(reset),
		.X_VECTOR(X), .Y_VECTOR(Y), .Z_VECTOR(Z), .RGB(RGB), .BEAM_ON(beam_on), .BEAM_ENA(1'b1),
		.DDRAM_CLK(ddr_clk), .DDRAM_BUSY(ddr_busy), .DDRAM_BURSTCNT(ddr_burst), .DDRAM_ADDR(ddr_addr),
		.DDRAM_DOUT(ddr_dout), .DDRAM_DOUT_READY(ddr_dr), .DDRAM_RD(ddr_rd),
		.DDRAM_DIN(ddr_din), .DDRAM_BE(ddr_be), .DDRAM_WE(ddr_we),
		.FB_EN(fb_en), .FB_FORMAT(fb_fmt), .FB_WIDTH(fb_w), .FB_HEIGHT(fb_h),
		.FB_BASE(fb_base), .FB_STRIDE(fb_str), .FB_VBL(fbvbl), .FB_LL(1'b0), .FB_FORCE_BLANK(fb_fblank),
		.START_FRAME(pg_start), .FRAME_DONE(pg_eof), .OSD_FLICKER(1'b0),
		.FIFO_FULL_LED(), .CLEAR_BUSY(fb_clearing)
	);

	// ROTATION INVARIANT CHECKS (the 3-buffer FB must keep display != draw != clear_target):
	//   coll_clr_disp = the buffer being CLEARED is the one being SCANNED OUT -> black on screen.
	//   coll_drw_disp = the buffer being DRAWN is the one being scanned out  -> tearing/partial.
	int coll_clr_disp=0, coll_drw_disp=0;
	always @(posedge clk_sys) if (!reset) begin
		if (fb.clearing && fb.clear_target_buf == fb.display_buf) coll_clr_disp++;
		if (fb.draw_buf == fb.display_buf)                        coll_drw_disp++;
	end
	ddr_model #(.BUSY_DUTY(BUSY_DUTY)) ddr (
		.clk(clk_sys), .busy(ddr_busy), .burstcnt(ddr_burst), .addr(ddr_addr),
		.dout(ddr_dout), .dout_ready(ddr_dr), .rd(ddr_rd), .din(ddr_din), .be(ddr_be), .we(ddr_we)
	);

	// ---- instrumentation (clk_12 domain) ----
	int overrun_cyc=0, blank_cyc=0, cap_cyc=0, neof=0, ndeg=0;
	int blank_run=0, blank_max=0, cap_run=0;
	int fifo_peak=0;
	reg bw_d=0;
	always @(posedge clk_12) if (!reset) begin
		if (bw && cb_sync[1]) overrun_cyc++;            // <-- THE BUG: beam on while clearing
		if (!bw) begin blank_cyc++; blank_run++; if (blank_run>blank_max) blank_max=blank_run; end
		else      begin cap_cyc++;  blank_run<=0; end
		if (pg_eof) neof++;
		if (pg_degraded) ndeg++;
		if (fb.fifo_used > fifo_peak) fifo_peak = fb.fifo_used;
	end

	initial begin
		reset = 1; repeat(20) @(posedge clk_sys); reset = 0;
		// run several present cycles (N=6 lists each ~ LIST_PTS*4 clk_12 + a full clear)
		repeat (12) @(posedge pg_eof);     // 12 presents (boot + steady state)
		$display("=== INTEG (PERSIST=%0d N, BUSY_DUTY=%0d) ===", PERSIST, BUSY_DUTY);
		$display("  eofs=%0d  degraded=%0d", neof, ndeg);
		$display("  OVERRUN cycles (beam on while clearing) = %0d   <- want 0", overrun_cyc);
		$display("  longest blank = %0d clk_12 (%.2f ms)   total blank/cap = %0d/%0d", blank_max, blank_max*83.0e-6, blank_cyc, cap_cyc);
		$display("  FIFO peak occupancy = %0d / 8192  (overflow => dropped beams)", fifo_peak);
		$display("  ROTATION: clear-vs-display collisions=%0d  draw-vs-display collisions=%0d (both want 0)",
		         coll_clr_disp, coll_drw_disp);
		begin
			int dlit; logic [28:0] dbase;
			dbase = (fb.display_buf==2'd3) ? 29'h0610E000 : (fb.display_buf==2'd2) ? 29'h060B4000 :
			        (fb.display_buf==2'd1) ? 29'h0605A000 : 29'h06000000;
			dlit = 0;
			foreach (ddr.mem[a]) if (a >= dbase && a < dbase + 368640) dlit++;
			$display("  display_buf=%0d  lit words=%0d (a full frame has thousands; ~0 = BLACK screen)", fb.display_buf, dlit);
		end
		if (overrun_cyc == 0 && coll_clr_disp == 0 && coll_drw_disp == 0)
			$display("  RESULT: handshake holds + rotation invariants OK -> FB path clean");
		else
			$display("  RESULT: PROBLEM (overrun=%0d clr-disp=%0d drw-disp=%0d)", overrun_cyc, coll_clr_disp, coll_drw_disp);
		$finish;
	end
	initial begin #800ms; $display("INTEG TIMEOUT"); $finish; end
endmodule
