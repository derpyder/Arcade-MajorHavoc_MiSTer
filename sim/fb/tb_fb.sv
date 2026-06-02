// FB isolation harness: drive vector_fb_ddram with known lit pixels, read back DDR.
// Question: does the framebuffer actually write lit (z>0) pixels to memory?
`timescale 1ns/1ps
module tb_fb;
	logic clk_sys=0, clk_12=0, reset=1;
	always #10 clk_sys = ~clk_sys;    // 50 MHz
	always #41 clk_12  = ~clk_12;     // ~12 MHz

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

	ddr_model ddr (
		.clk(clk_sys), .busy(ddr_busy), .burstcnt(ddr_burst), .addr(ddr_addr),
		.dout(ddr_dout), .dout_ready(ddr_dout_ready), .rd(ddr_rd), .din(ddr_din), .be(ddr_be), .we(ddr_we)
	);

	int n0, n1, n2, noth, nsamp;
	initial begin
		reset = 1;
		repeat(10) @(posedge clk_sys);
		reset = 0;
		$display("FBSIM: waiting for initial clear (358400 words)...");
		wait (dut.clearing == 1'b0);
		$display("FBSIM: clear done @ %0t; draw_buf=%0d -> feeding 20 lit pixels", $time, dut.draw_buf);
		@(posedge clk_12);
		for (int i = 0; i < 20; i++) begin
			@(posedge clk_12);
			X <= 10'd100 + i*10; Y <= 10'd100 + i*8; Z <= 5'd24; RGB <= 3'b111; BEAM_ON <= 1'b1;
		end
		@(posedge clk_12); BEAM_ON <= 1'b0;
		repeat(40)  @(posedge clk_12);           // let FIFO drain into DDR (RMW)
		FRAME_DONE <= 1'b1; @(posedge clk_12); FRAME_DONE <= 1'b0;  // EOF
		repeat(400) @(posedge clk_sys);          // EOF -> swap
		FB_VBL <= 1'b1; repeat(6) @(posedge clk_sys); FB_VBL <= 1'b0;  // ready -> display
		repeat(200) @(posedge clk_sys);

		n0=0; n1=0; n2=0; noth=0; nsamp=0;
		foreach (ddr.mem[a]) begin
			if (ddr.mem[a] != 0) begin
				if      (a >= 'h06000000 && a < 'h06057800) n0++;
				else if (a >= 'h06057800 && a < 'h060AF000) n1++;
				else if (a >= 'h060AF000 && a < 'h06106800) n2++;
				else noth++;
				if (nsamp < 8) begin $display("  word[%h]=%h", a, ddr.mem[a]); nsamp++; end
			end
		end
		$display("FBSIM RESULT: nonzero words  buf0=%0d  buf1=%0d  buf2=%0d  other=%0d", n0, n1, n2, noth);
		$display("FBSIM: ddr writes=%0d reads=%0d  display_buf=%0d draw_buf=%0d ready_buf=%0d fifo_full=%b",
			ddr.nwr, ddr.nrd, dut.display_buf, dut.draw_buf, dut.ready_buf, FIFO_FULL_LED);
		$display("FBSIM: VERDICT -> ~20 nonzero in one buffer = FB writes pixels OK; all-zero = FB drops them");
		$finish;
	end
	initial begin #80ms; $display("FBSIM: TIMEOUT (clear too slow?)"); $finish; end
endmodule
