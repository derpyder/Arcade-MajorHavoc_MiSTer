// ============================================================================
// tb_selerase.sv -- SELECTIVE-ERASE validation: present_gate(N=1) + vector_fb_ddram
// + ddr_model, driven by a modeled AVG that draws a MOVING solid bar.
//
// WHY a moving bar: the recycled buffer holds a frame from 2 presents ago, drawn at
// a DIFFERENT column (the bar steps by STEP each list).  If the replay-erase fails to
// zero every recorded word, the old bar's column SURVIVES into the redrawn buffer =
// a TRAIL, far (>= STEP) from the current bar.  A correct erase leaves exactly ONE
// bar.  (Static content can't reveal trails -- it overdraws itself.)
//
// ddr_model is SPARSE and DELETES words written to 0, so "lit words in a buffer" =
// non-zero entries; a leftover (un-erased) word is a literal trail we can count.
//
// MEASURES (per run):
//   (A) use_replay == 1 at steady-state EOFs   -> selective erase ENGAGED (not full clear)
//   (B) erase DDR writes per recycle ~ frame words (<< 368640) -> it's selective
//   (C) clearing span (clk_sys cycles) << full-clear span       -> erase is FAST
//   (D) display buffer = ONE bar: lit_count ~ bar words AND (max_xw-min_xw) <= bar/2
//       -> NO TRAILS.  (run also at BAR_W beyond CAP -> overflow -> full-clear fallback,
//        which must STILL leave no trails.)
// ============================================================================
`timescale 1ns/1ps
module tb_selerase;
	parameter int   BUSY_DUTY = 8;       // 50% DDR contention
	parameter int   BAR_W     = 60;      // bar width in columns (~ROWS*BAR_W/2 words)
	parameter int   ROWS      = 500;     // bar height (rows 100..100+ROWS)
	parameter int   STEP      = 137;     // column step per list (>> BAR_W so trails are far)
	parameter int   Y0        = 100;

	localparam int  XSPAN = 980 - BAR_W; // column wrap range

	logic clk_sys=0, clk_12=0, reset=1;
	always #10 clk_sys = ~clk_sys;        // 50 MHz
	always #41 clk_12  = ~clk_12;         // ~12 MHz

	// DDR
	logic        ddr_busy, ddr_dr, ddr_rd, ddr_we, ddr_clk;
	logic [7:0]  ddr_burst, ddr_be;
	logic [28:0] ddr_addr;
	logic [63:0] ddr_dout, ddr_din;

	// gate <-> FB
	wire bw, pg_eof, pg_start, pg_degraded, fb_clearing;
	reg  [1:0] cb_sync = 2'b0;
	always @(posedge clk_12) cb_sync <= {cb_sync[0], fb_clearing};

	// ---- modeled AVG: avg_ena = clk_12/4, draws a moving solid bar, vggo per list ----
	reg [1:0] ce = 0;  always @(posedge clk_12) ce <= ce + 1'b1;
	wire avg_ena = (ce == 0);

	reg  avg_vggo = 1'b0;
	logic [9:0] X=0, Y=0; logic [4:0] Z=0; logic [2:0] RGB=0; logic beam_on=0;
	int   col = 0;                         // current bar column (moves each list)
	int   ry = 0, cx = 0;
	always @(posedge clk_12) begin
		avg_vggo <= 1'b0;
		if (reset) begin ry<=0; cx<=0; beam_on<=0; col<=0; end
		else if (avg_ena) begin
			X       <= col + cx;
			Y       <= Y0 + ry;
			Z       <= 5'd20;
			RGB     <= 3'b010;
			// beam-OFF on the row-start sample (cx==0) = a "move" to the new row, like a real AVG.
			// Without this the always-on raster makes the line-fill chase a backward diagonal from
			// each row's end to the next row's start (a tb artifact, not an erase concern).
			beam_on <= bw && (cx != 0);    // only reaches FB while the gate's beam window is open
			if (cx == BAR_W-1) begin
				cx <= 0;
				if (ry == ROWS-1) begin
					ry <= 0;
					avg_vggo <= 1'b1;          // list complete -> vggo
					col <= (col + STEP >= XSPAN) ? (col + STEP - XSPAN) : (col + STEP);
				end else ry <= ry + 1;
			end else cx <= cx + 1;
		end
	end

	// ARMED_TIMEOUT raised here ONLY because this tb models one list as a single ~20ms mega-raster;
	// real MH redraws its whole list every ~4ms (<< the 12ms default), so the default never fires in
	// hardware.  Raising it lets the tb's slow list complete on a real vggo boundary (realistic frame).
	present_gate #(.MAX_BLANK(22'd600000), .ARMED_TIMEOUT(20'd400000), .CAP_TIMEOUT(22'd900000)) pg (
		.clk(clk_12), .reset(reset), .vggo_rise(avg_vggo), .clear_busy(cb_sync[1]),
		.persist(2'd0),                    // N=1 -> selective erase
		.beam_window(bw), .eof(pg_eof), .frame_start(pg_start), .degraded(pg_degraded)
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

	ddr_model #(.BUSY_DUTY(BUSY_DUTY)) ddr (
		.clk(clk_sys), .busy(ddr_busy), .burstcnt(ddr_burst), .addr(ddr_addr),
		.dout(ddr_dout), .dout_ready(ddr_dr), .rd(ddr_rd), .din(ddr_din), .be(ddr_be), .we(ddr_we)
	);

	// ---- rotation invariants + FIFO peak ----
	int coll_clr_disp=0, coll_drw_disp=0, fifo_peak=0;
	always @(posedge clk_sys) if (!reset) begin
		if (fb.clearing && fb.clear_target_buf == fb.display_buf) coll_clr_disp++;
		if (fb.draw_buf == fb.display_buf)                        coll_drw_disp++;
		if (fb.fifo_used > fifo_peak) fifo_peak = fb.fifo_used;
	end
	int ndeg=0;                              // gate degraded pulses = list longer than arm-timeout
	always @(posedge clk_12) if (!reset && pg_degraded) ndeg++;

	// ---- clearing-span + erase-write instrumentation (clk_sys), REPLAY vs FULL separated ----
	int  span_len=0, rep_span_max=0, full_span_max=0;   // cycles clearing high (per span)
	int  rep_writes_max=0, full_writes_max=0;           // DDR writes accepted during a span
	reg  clr_d=0; reg replay_seen=0, fullclr_seen=0; reg span_is_replay=0;
	int  nwr0=0;
	always @(posedge clk_sys) if (!reset) begin
		clr_d <= fb.clearing;
		if (!clr_d && fb.clearing) begin           // span BEGIN
			nwr0 = ddr.nwr; span_len = 0; span_is_replay = fb.use_replay;
		end
		if (fb.clearing) begin
			span_len++;
			if (fb.use_replay) replay_seen<=1; else fullclr_seen<=1;
		end
		if (clr_d && !fb.clearing) begin           // span END -> latch into the right bucket
			if (span_is_replay) begin
				if (span_len           > rep_span_max)   rep_span_max   = span_len;
				if (ddr.nwr - nwr0     > rep_writes_max) rep_writes_max = ddr.nwr - nwr0;
			end else begin
				if (span_len           > full_span_max)  full_span_max  = span_len;
				if (ddr.nwr - nwr0     > full_writes_max)full_writes_max= ddr.nwr - nwr0;
			end
		end
	end

	// ---- trail scan over the display buffer ----
	task automatic scan_display(output int lit, output int min_xw, output int max_xw, output int nbands);
		logic [28:0] dbase;
		int off, yy, xw, prev_xw;
		int xw_list[$];
		dbase = (fb.display_buf==2'd2) ? 29'h060B4000 :
		        (fb.display_buf==2'd1) ? 29'h0605A000 : 29'h06000000;
		lit=0; min_xw=99999; max_xw=-1;
		foreach (ddr.mem[a]) begin
			if (a >= dbase && a < dbase + 368640) begin
				off = a - dbase; yy = off/512; xw = off%512;
				if (yy >= Y0 && yy < Y0+ROWS) begin
					lit++;
					if (xw < min_xw) min_xw = xw;
					if (xw > max_xw) max_xw = xw;
					xw_list.push_back(xw);
				end
			end
		end
		// count distinct column "bands": sort xw, a gap > BAR_W means a new band (= a trail)
		nbands = 0;
		if (xw_list.size() > 0) begin
			xw_list.sort();
			nbands = 1; prev_xw = xw_list[0];
			foreach (xw_list[i]) begin
				if (xw_list[i] - prev_xw > BAR_W) nbands++;
				prev_xw = xw_list[i];
			end
		end
	endtask

	initial begin
		int lit, mn, mx, nb, exp_words, span;
		reset = 1; repeat(20) @(posedge clk_sys); reset = 0;
		repeat (16) @(posedge pg_eof);     // run well past boot (first 4 clears are full)
		// sample one more present, then scan the steady-state display buffer
		@(posedge pg_eof); repeat (2000) @(posedge clk_sys);
		scan_display(lit, mn, mx, nb);
		exp_words = ROWS * ((BAR_W+1)/2);

		$display("=== SEL-ERASE (BAR_W=%0d ~%0d words, STEP=%0d, BUSY_DUTY=%0d) ===", BAR_W, exp_words, STEP, BUSY_DUTY);
		$display("  selective replay engaged=%0b   full-clear (boot/overflow) used=%0b", replay_seen, fullclr_seen);
		$display("  REPLAY  span max = %6d clk_sys (%.2f ms)   writes/span max = %0d", rep_span_max,  rep_span_max*20.0e-6,  rep_writes_max);
		$display("  FULL    span max = %6d clk_sys (%.2f ms)   writes/span max = %0d   [full clear writes 368640]", full_span_max, full_span_max*20.0e-6, full_writes_max);
		$display("  display_buf=%0d  lit words=%0d (one bar ~= %0d)", fb.display_buf, lit, exp_words);
		$display("  column span min..max xw = %0d..%0d  (one bar width ~= %0d)  bands=%0d", mn, mx, (BAR_W+1)/2, nb);
		$display("  ROTATION: clear-vs-display=%0d  draw-vs-display=%0d (want 0)   FIFO peak=%0d/8192   gate-degraded=%0d", coll_clr_disp, coll_drw_disp, fifo_peak, ndeg);

		begin
			bit ok_lit, ok_trail, ok_rot, ok_sel, ok_fast;
			ok_lit   = (lit > exp_words/2) && (lit < exp_words*2);          // ~one bar present
			ok_trail = (nb == 1) && ((mx - mn) <= (BAR_W+1)/2 + 2);          // exactly one column band
			ok_rot   = (coll_clr_disp == 0) && (coll_drw_disp == 0);
			if (BAR_W*ROWS/2 <= 32768) begin                                // under CAP -> selective expected
				ok_sel  = replay_seen;
				ok_fast = (rep_span_max > 0) && (rep_span_max < 368640) && (rep_writes_max < 368640/4);
			end else begin                                                  // over CAP -> full-clear fallback
				ok_sel  = fullclr_seen;
				ok_fast = 1'b1;                                             // fallback is intentionally a full clear
			end
			if (ok_lit && ok_trail && ok_rot && ok_sel && ok_fast)
				$display("  RESULT: PASS -- no trails, %s erase, rotation OK",
				         (BAR_W*ROWS/2 <= 32768) ? "FAST selective" : "full-clear fallback");
			else
				$display("  RESULT: FAIL  (lit=%0b trail=%0b rot=%0b sel=%0b fast=%0b)",
				         ok_lit, ok_trail, ok_rot, ok_sel, ok_fast);
		end
		$finish;
	end
	initial begin #1200ms; $display("SEL-ERASE TIMEOUT"); $finish; end
endmodule
