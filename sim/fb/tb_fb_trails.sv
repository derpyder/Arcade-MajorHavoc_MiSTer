// 2-FRAME TRAILS / CLEAR-CADENCE sim. Draws frame A, swaps, draws frame B into a
// RECYCLED buffer that we PRE-FILL with a marker (stale-content stand-in). If the
// inter-frame buffer clear doesn't fully zero that buffer under DDR contention, the
// marker survives = trails. Verifies frame B is COMPLETE (no clear-induced drops) AND
// CLEAN (no surviving marker). Buffer rotation (verified): reset clears buf1; A draws
// buf1; A-EOF triggers clear of buf2; B draws buf2; so B's buffer = buf2 (base word
// 0x060B4000, 720-tall). We pre-fill buf2 with marker after the initial clear, before A's EOF.
`timescale 1ns/1ps
module tb_fb_trails;
	parameter int BUSY_DUTY = 8;        // -gBUSY_DUTY=<0..16>
	localparam [63:0] MARKER = 64'h00FFFFFF_00FFFFFF;  // both slots = white (stale-content stand-in)
	localparam [28:0] BUF2 = 29'h060B4000;
	localparam int    BUFW = 368640;    // words per buffer (720*4096/8)

	logic clk_sys=0, clk_12=0, reset=1;
	always #10 clk_sys = ~clk_sys;
	always #41 clk_12  = ~clk_12;

	logic        ddr_busy, ddr_dout_ready, ddr_rd, ddr_we, ddr_clk;
	logic [7:0]  ddr_burst, ddr_be;
	logic [28:0] ddr_addr;
	logic [63:0] ddr_dout, ddr_din;

	logic [9:0] X=0, Y=0; logic [4:0] Z=0; logic [2:0] RGB=0;
	logic BEAM_ON=0, BEAM_ENA=1, START_FRAME=0, FRAME_DONE=0, OSD_FLICKER=0, FIFO_FULL_LED;
	logic FB_VBL=0, FB_LL=0, fb_en, fb_force_blank;
	logic [4:0] fb_format; logic [11:0] fb_w, fb_h; logic [31:0] fb_base; logic [13:0] fb_stride;

	vector_fb_ddram dut (
		.clk_sys(clk_sys), .clk_12(clk_12), .reset(reset),
		.X_VECTOR(X), .Y_VECTOR(Y), .Z_VECTOR(Z), .RGB(RGB), .BEAM_ON(BEAM_ON), .BEAM_ENA(BEAM_ENA),
		.DDRAM_CLK(ddr_clk), .DDRAM_BUSY(ddr_busy), .DDRAM_BURSTCNT(ddr_burst), .DDRAM_ADDR(ddr_addr),
		.DDRAM_DOUT(ddr_dout), .DDRAM_DOUT_READY(ddr_dout_ready), .DDRAM_RD(ddr_rd),
		.DDRAM_DIN(ddr_din), .DDRAM_BE(ddr_be), .DDRAM_WE(ddr_we),
		.FB_EN(fb_en), .FB_FORMAT(fb_format), .FB_WIDTH(fb_w), .FB_HEIGHT(fb_h),
		.FB_BASE(fb_base), .FB_STRIDE(fb_stride), .FB_VBL(FB_VBL), .FB_LL(FB_LL), .FB_FORCE_BLANK(fb_force_blank),
		.START_FRAME(START_FRAME), .FRAME_DONE(FRAME_DONE), .OSD_FLICKER(OSD_FLICKER), .FIFO_FULL_LED(FIFO_FULL_LED)
	);
	ddr_model #(.BUSY_DUTY(BUSY_DUTY)) ddr (
		.clk(clk_sys), .busy(ddr_busy), .burstcnt(ddr_burst), .addr(ddr_addr),
		.dout(ddr_dout), .dout_ready(ddr_dout_ready), .rd(ddr_rd), .din(ddr_din), .be(ddr_be), .we(ddr_we)
	);

	// mhavoc_sw coord map -- MH coords are ALREADY centred (avg_majorhavoc +512), so NO ^512
	// here (cx=ax directly), unlike Tempest.  Matches mhavoc_sw.sv: scale half, fxs=490+rx, fys=360-ry.
	// Test the LINE-FILL at the "Fill" scale x1.25 (sc_num=5): sx = ax*5>>2, half = 5*128 = 640.
	// (At x1 gaps are <=1px so the fill never triggers; x1.25 spreads points -> exercises the fill.)
	function automatic int mapx(input int ax);
		int sx; sx = (ax*5) >> 2; return 490 + (sx - 640);
	endfunction
	function automatic int mapy(input int ay);
		int sy; sy = (ay*5) >> 2; return 360 - (sy - 640);  // centre 360 = 720/2
	endfunction

	// clear-duration + FIFO instrumentation
	integer npush=0, npop=0, max_occ=0, ovf=0, clr_cyc=0, clr_max=0, clr_run=0;
	reg [13:0] rd_prev=0; reg [13:0] wr_prev=0; reg clr_prev=0;
	always @(posedge clk_sys) begin
		if (dut.rd_ptr != rd_prev) npop++;  rd_prev <= dut.rd_ptr;
		if ((npush-npop) > max_occ) max_occ = npush-npop;
		if ((npush-npop) > 8192) ovf++;
		if (dut.clearing) begin clr_cyc++; clr_run++; if (clr_run>clr_max) clr_max=clr_run; end
		else clr_run <= 0;
	end
	// push count = wr_ptr advances (the write side now pushes from several FSM branches incl. line-fill)
	always @(posedge clk_12) begin if (!reset && dut.wr_ptr != wr_prev) npush++; wr_prev <= dut.wr_ptr; end

	integer fin, fout, r, ax, ay, rgb, az, fxs, fys;
	int a, lit, n1, white_survivors;

	task feed_frame;
		fin = $fopen("D:/deck/fpga/majorhavoc/Arcade-MajorHavoc/sim/mhavoc_frame.txt", "r");
		if (fin == 0) begin $display("TRAILS: cannot open frame file"); $finish; end
		while (!$feof(fin)) begin
			r = $fscanf(fin, "%d %d %d %d\n", ax, ay, rgb, az);
			if (r == 4) begin
				fxs = mapx(ax); fys = mapy(ay);
				if (fxs >= 0 && fxs < 980 && fys >= 0 && fys < 720) begin
					X <= fxs[9:0]; Y <= fys[9:0]; Z <= az[7:3]; RGB <= rgb[2:0]; BEAM_ON <= (rgb != 0);
				end else BEAM_ON <= 1'b0;
				repeat(4) @(posedge clk_12);   // avg_ena = clk/4: hold each point 4 cycles (line-fill slack)
			end
		end
		$fclose(fin);
		@(posedge clk_12); BEAM_ON <= 1'b0;
		repeat(100) @(posedge clk_12);
		FRAME_DONE <= 1'b1; @(posedge clk_12); FRAME_DONE <= 1'b0;
	endtask

	initial begin
		reset = 1; repeat(10) @(posedge clk_sys); reset = 0;
		wait (dut.clearing == 1'b0);             // initial clear (buf1) done
		$display("TRAILS: initial clear done; draw_buf=%0d. Pre-filling buf2 with MARKER...", dut.draw_buf);
		for (a = 0; a < BUFW; a++) ddr.mem[BUF2 + a] = MARKER;   // stale content stand-in
		$display("TRAILS: buf2 pre-filled (%0d marker words). Drawing frame A...", BUFW);

		feed_frame;                              // FRAME A -> buf1 ; A-EOF triggers clear of buf2
		repeat(500) @(posedge clk_sys);
		FB_VBL <= 1'b1; repeat(6) @(posedge clk_sys); FB_VBL <= 1'b0;   // swap -> display A
		$display("TRAILS: frame A done; display_buf=%0d draw_buf=%0d (buf2 clearing=%b).",
			dut.display_buf, dut.draw_buf, dut.clearing);
		$display("TRACK: frame A drew buf1 -> tracked rows %0d..%0d  (content band; the adaptive clear shrinks to this; full band is 0..719)",
			dut.buf_ymin[1], dut.buf_ymax[1]);

		// CORRECTNESS test: triple-buffering gives buf2 ~2 frames before B reuses it, so
		// let its clear COMPLETE (the realistic slack) before drawing B.  The aggressive
		// back-to-back case (clear NOT done) is the budget risk, reported separately.
		wait (dut.clearing == 1'b0);
		$display("TRAILS: buf2 clear COMPLETE; drawing frame B into the (now clean) buffer...");

		feed_frame;                              // FRAME B -> buf2 (clean)
		repeat(20000) @(posedge clk_sys);        // let B fully drain (clear is done, ~280us)
		FB_VBL <= 1'b1; repeat(6) @(posedge clk_sys); FB_VBL <= 1'b0;   // swap -> display B
		repeat(300) @(posedge clk_sys);

		// read back buf2 = frame B's buffer
		fout = $fopen("fb_out.txt", "w");
		n1 = 0; lit = 0; white_survivors = 0;
		foreach (ddr.mem[addr]) begin
			if (addr >= BUF2 && addr < BUF2 + BUFW && ddr.mem[addr] != 0) begin
				int byte0, x0, y0, x1, y1; logic [63:0] w;
				w = ddr.mem[addr]; n1++;
				byte0 = (addr - BUF2) * 8;
				x0 = (byte0/4) % 1024; y0 = byte0/4096;
				x1 = ((byte0+4)/4) % 1024; y1 = (byte0+4)/4096;
				if (w[23:0]  == 24'hFFFFFF || w[55:32] == 24'hFFFFFF) white_survivors++;
				if (w[23:0]  != 0) begin $fdisplay(fout, "%0d %0d %0d %0d %0d", x0, y0, w[7:0],   w[15:8],  w[23:16]);  lit++; end
				if (w[55:32] != 0) begin $fdisplay(fout, "%0d %0d %0d %0d %0d", x1, y1, w[39:32], w[47:40], w[55:48]); lit++; end
			end
		end
		$fclose(fout);
		$display("TRAILS RESULT: buf2 nonzero words=%0d  lit pixels=%0d  white(marker)-survivor words=%0d",
			n1, lit, white_survivors);
		$display("TRAILS FIFO: pushed=%0d popped=%0d max_occ=%0d overflow_cyc=%0d", npush, npop, max_occ, ovf);
		$display("TRAILS CLEAR: total clearing cycles=%0d  longest single clear=%0d cycles (%.2f ms @50MHz)",
			clr_cyc, clr_max, clr_max * 20.0e-6);
		$display("TRAILS: display_buf=%0d (expect 2 = frame B) -> fb_out.txt", dut.display_buf);
		$finish;
	end
	initial begin #400ms; $display("TRAILS: TIMEOUT"); $finish; end
endmodule
