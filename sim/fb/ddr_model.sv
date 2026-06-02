// Behavioral DDR model for vector_fb_ddram sim — v2: models REAL shared-bus
// contention. The framebuffer's DDR port shares one DDR3 with the HDMI scan-out
// + HPS, so DDRAM_BUSY is high a large fraction of the time (the thing BUSY=0
// hid). Also models burst writes (for verifying USE_BURST_CLEAR) and variable
// read latency. Sparse memory (non-zero words only).
`timescale 1ns/1ps
module ddr_model #(
	parameter int BUSY_DUTY = 8     // BUSY high BUSY_DUTY of every 16 clk_sys cycles (contention)
)(
	input              clk,
	output             busy,
	input      [7:0]   burstcnt,
	input      [28:0]  addr,
	output reg [63:0]  dout,
	output reg         dout_ready,
	input              rd,
	input      [63:0]  din,
	input      [7:0]   be,
	input              we
);
	bit [63:0] mem [int];
	integer nwr = 0, nrd = 0;

	// ---- contention: a competing master (scan-out / HPS) steals the bus ----
	reg [3:0] cctr = 0;
	always @(posedge clk) cctr <= cctr + 4'd1;
	assign busy = (cctr < BUSY_DUTY[3:0]);     // BUSY_DUTY/16 duty cycle high

	task automatic wr(input [28:0] a);
		bit [63:0] cur;
		cur = mem.exists(a) ? mem[a] : 64'd0;
		for (int b = 0; b < 8; b++) if (be[b]) cur[b*8 +: 8] = din[b*8 +: 8];
		if (cur != 0) mem[a] = cur; else if (mem.exists(a)) mem.delete(a);
		nwr++;
	endtask

	// ---- write: accepted only when (we && !busy); burst auto-increments ----
	reg        in_wb = 0;
	reg [28:0] wb_base;
	reg [7:0]  wb_beat;
	// ---- read: accepted when (rd && !busy), 2-cycle latency after acceptance ----
	reg        rd_d1, rd_d2;
	reg [28:0] ra1, ra2;

	always @(posedge clk) begin
		dout_ready <= 1'b0;
		if (we && !busy) begin
			if (burstcnt > 8'd1) begin                 // burst write
				if (!in_wb) begin in_wb <= 1'b1; wb_base <= addr; wb_beat <= 8'd1; wr(addr); end
				else begin
					wr(wb_base + wb_beat); wb_beat <= wb_beat + 8'd1;
					if (wb_beat == burstcnt - 8'd1) in_wb <= 1'b0;
				end
			end else begin wr(addr); in_wb <= 1'b0; end // single beat
		end else if (!we) in_wb <= 1'b0;

		rd_d1 <= (rd && !busy); ra1 <= addr;
		rd_d2 <= rd_d1;         ra2 <= ra1;
		if (rd_d2) begin
			dout       <= mem.exists(ra2) ? mem[ra2] : 64'd0;
			dout_ready <= 1'b1;
			nrd++;
		end
	end
endmodule
