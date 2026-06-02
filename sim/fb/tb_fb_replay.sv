// FB replay harness: feed the REAL captured Tempest display list (ax ay rgb az)
// through tempest_sw's exact coord-map + rast_z=az[7:3] into vector_fb_ddram,
// then dump the resulting framebuffer pixels for rendering. Reproduces (or not)
// the near-black, isolating coord-map/Z-path functional bugs from HW timing.
`timescale 1ns/1ps
module tb_fb_replay;
	parameter int BUSY_DUTY = 8;   // override at vsim: -gBUSY_DUTY=<0..16> (contention sweep)
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

	// tempest_sw coord map (defaults: rotate 0, scale half), replicated exactly —
	// INCLUDING the 180deg flip (fxs=490-rx, fys=350-ry) that tempest_sw.sv bakes in.
	function automatic int mapx(input int ax);
		int cx, sx, scx, fxs;
		cx  = ax ^ 512;          // {~ax[9], ax[8:0]} centre
		sx  = cx >> 1;           // scale /2  (sc_num=2 -> cx*2>>2)
		scx = sx - 256;          // - half (sc_num<<7 = 256)
		fxs = 490 + scx;         // X not flipped (matches tempest_sw fxs=490+rx; 490-scx mirrors text)
		return fxs;
	endfunction
	function automatic int mapy(input int ay);
		int cy, sy, scy, fys;
		cy  = ay ^ 512;
		sy  = cy >> 1;
		scy = sy - 256;
		fys = 350 - scy;         // flip Y about FB centre (matches tempest_sw fys=350-ry)
		return fys;
	endfunction

	integer fin, fout, r, ax, ay, rgb, az, fxs, fys, nfed, ndraw, nbeam;
	int n1, lit, b0;

	// --- FIFO / write-path instrumentation: overflow vs flush vs collision ---
	integer npush=0, npop=0, max_occ=0, ovf=0, pixwr_acc=0;
	integer issue_rise=0, issue_hot=0;   // pixel-write issues; issues that CLOBBER a pending write
	reg [13:0] rd_prev=0;
	reg we_prev=0; reg [28:0] addr_prev=0;
	always @(posedge clk_12) if (!reset && dut.fifo_we) npush++;       // pixels entering FIFO
	always @(posedge clk_sys) begin
		if (dut.rd_ptr != rd_prev) npop++;                            // pixels leaving FIFO (rd_ptr +1/pop)
		rd_prev <= dut.rd_ptr;
		if ((npush - npop) > max_occ) max_occ = npush - npop;         // peak logical occupancy
		if ((npush - npop) > 8192)    ovf++;                          // cycles past FIFO depth = corruption
		if (!reset && ddr_we && !ddr_busy && ddr_be != 8'hFF) pixwr_acc++; // accepted PIXEL writes (be!=FF skips clear)
		// pixel-write issue detection (be!=FF == not a clear beat)
		if (!reset && dut.ddram_be_reg != 8'hFF) begin
			if (dut.ddram_we_reg && !we_prev) issue_rise++;                       // we 0->1 = fresh issue
			if (dut.ddram_we_reg &&  we_prev && dut.ddram_addr_reg != addr_prev)  // addr changed while we held high
				issue_hot++;                                                     //   = CLOBBERED a pending (unaccepted) write
		end
		we_prev   <= dut.ddram_we_reg;
		addr_prev <= dut.ddram_addr_reg;
	end

`ifdef TRACE
	// cycle-accurate trace of the read pipeline once drawing is underway
	integer tcyc=0, tlog=0, tfd;
	initial tfd = $fopen("trace.txt","w");
	always @(posedge clk_sys) begin
		if (!dut.clearing && (dut.stage2_valid || dut.stage3_valid || dut.ddram_we_reg)) tlog <= 1;
		if (tlog && tcyc < 120) begin
			tcyc <= tcyc + 1;
			$fdisplay(tfd, "c=%0d busy=%b clr=%b st=%0d s3v=%b s2v=%b rd=%0d s2d=%h we=%b be=%h addr=%h",
				tcyc, ddr_busy, dut.clearing, dut.rmw_state, dut.stage3_valid, dut.stage2_valid,
				dut.rd_ptr, dut.stage2_data, dut.ddram_we_reg, dut.ddram_be_reg, dut.ddram_addr_reg);
		end
	end
`endif

	initial begin
		reset = 1; repeat(10) @(posedge clk_sys); reset = 0;
		$display("FBREPLAY: waiting initial clear...");
		wait (dut.clearing == 1'b0);
		$display("FBREPLAY: clear done; replaying tempest_frame.txt; draw_buf=%0d", dut.draw_buf);
		fin = $fopen("D:/deck/fpga/tempest/Arcade-Tempest/sim/tempest_frame.txt", "r");
		if (fin == 0) begin $display("FBREPLAY: cannot open frame file"); $finish; end
		nfed=0; ndraw=0; nbeam=0;
		while (!$feof(fin)) begin
			r = $fscanf(fin, "%d %d %d %d\n", ax, ay, rgb, az);
			if (r == 4) begin
				fxs = mapx(ax); fys = mapy(ay);
				@(posedge clk_12);
				if (fxs >= 0 && fxs < 980 && fys >= 0 && fys < 700) begin
					X <= fxs[9:0]; Y <= fys[9:0]; Z <= az[7:3]; RGB <= rgb[2:0];
					BEAM_ON <= (rgb != 0);   // tempest_sw _e: rast_beam = |rgb && in_bounds
					if (rgb != 0) nbeam++;
					if (az != 0) ndraw++;
				end else BEAM_ON <= 1'b0;
				nfed++;
			end
		end
		$fclose(fin);
		@(posedge clk_12); BEAM_ON <= 1'b0;
		$display("FBREPLAY: fed=%0d  beam-on(|rgb)=%0d  lit(az>0)=%0d", nfed, nbeam, ndraw);
		repeat(100) @(posedge clk_12);
		FRAME_DONE <= 1'b1; @(posedge clk_12); FRAME_DONE <= 1'b0;
		repeat(500) @(posedge clk_sys);
		FB_VBL <= 1'b1; repeat(6) @(posedge clk_sys); FB_VBL <= 1'b0;
		repeat(300) @(posedge clk_sys);

		// dump lit pixels from the displayed buffer (buf1 base 0x06057800)
		fout = $fopen("fb_out.txt", "w");
		n1=0; lit=0; b0 = 'h06057800;
		foreach (ddr.mem[a]) begin
			if (a >= 'h06057800 && a < 'h060AF000 && ddr.mem[a] != 0) begin
				int byte0, x0, y0, x1, y1; logic [63:0] w;
				w = ddr.mem[a]; n1++;
				byte0 = (a - b0) * 8;
				x0 = (byte0/4) % 1024; y0 = byte0/4096;
				x1 = ((byte0+4)/4) % 1024; y1 = (byte0+4)/4096;
				if (w[23:0]  != 0) begin $fdisplay(fout, "%0d %0d %0d %0d %0d", x0, y0, w[7:0],   w[15:8],  w[23:16]);  lit++; end
				if (w[55:32] != 0) begin $fdisplay(fout, "%0d %0d %0d %0d %0d", x1, y1, w[39:32], w[47:40], w[55:48]); lit++; end
			end
		end
		$fclose(fout);
		$display("FBREPLAY RESULT: buf1 nonzero words=%0d  lit pixels dumped=%0d  ddr writes=%0d reads=%0d",
			n1, lit, ddr.nwr, ddr.nrd);
		$display("FBREPLAY FIFO: pushed=%0d popped=%0d max_occ=%0d overflow_cyc=%0d | pixel_writes_accepted=%0d  LOST(push-acc)=%0d",
			npush, npop, max_occ, ovf, pixwr_acc, npush - pixwr_acc);
		$display("FBREPLAY ISSUE: issue_rise=%0d  issue_hot(clobber-pending)=%0d", issue_rise, issue_hot);
		$display("FBREPLAY: display_buf=%0d  fifo_full=%b  -> fb_out.txt (x y r g b)", dut.display_buf, FIFO_FULL_LED);
		$finish;
	end
	initial begin #200ms; $display("FBREPLAY: TIMEOUT"); $finish; end
endmodule
