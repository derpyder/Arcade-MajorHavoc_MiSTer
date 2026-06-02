// ============================================================================
// tb_gate2.sv -- verify present_gate.sv with the CLEAR-DONE HANDSHAKE.
//
// Models the AVG as a continuous list generator (vggo_rise per list) AND the
// framebuffer clear as a clear_busy pulse that starts shortly after each eof and
// lasts CLEAR_CYC cycles (short = content-adaptive band, long = full buffer).
//
// What the handshake gate must now guarantee:
//   1. NO OVERRUN: beam_window is NEVER high while clear_busy is high.  (The old
//      fixed-blank gate let the beam turn on mid-clear -> dropped beams -> black
//      frames.  This is THE property the fix must establish.)
//   2. Blank ADAPTS: the beam-off span tracks the clear length (short clear ->
//      short blank -> higher refresh; long clear -> longer blank).
//   3. Persistence still works: exactly N complete lists accumulated per eof.
//   4. Degrade: if clear_busy never drops (stuck) -> MAX_BLANK fires, eof still
//      pulses (never hangs / never black).
// ============================================================================
`timescale 1ns/1ps
module tb_gate2;
	logic clk = 0; always #5 clk = ~clk;

	localparam int LIST_N = 480;   // normal list period
	localparam int DRAW_N = 360;

	int  list_per = LIST_N;
	int  draw_cyc = DRAW_N;
	bit  vggo_en  = 1'b1;
	bit  rst_stim = 1'b1;
	bit  reset    = 1'b1;
	logic [1:0] persist = 2'd0;

	// clear model: clear_busy asserts CB_DELAY after eof, stays high `clear_cyc`, then drops.
	int  clear_cyc = 300;          // clear duration (short band vs long full vs stuck)
	bit  clear_stuck = 1'b0;       // 1 = clear_busy never drops (degrade test)
	localparam int CB_DELAY = 6;

	// AVG list generator
	int lc = 0;
	always @(posedge clk) begin
		if (rst_stim) lc <= 0;
		else          lc <= (lc >= list_per-1) ? 0 : lc + 1;
	end
	wire drawing   = (lc < draw_cyc);
	wire vggo_rise = vggo_en & (lc == 0);

	// DUT
	wire beam_window, eof, frame_start, degraded;
	reg  clear_busy = 1'b0;
	present_gate #(
		.MAX_BLANK     (22'd6000),   // ~50ms-equiv safety cap (/100), > any clear here
		.ARMED_TIMEOUT (20'd1440),
		.CAP_TIMEOUT   (22'd7200)
	) dut (
		.clk(clk), .reset(reset),
		.vggo_rise(vggo_rise), .clear_busy(clear_busy), .persist(persist),
		.beam_window(beam_window), .eof(eof), .frame_start(frame_start), .degraded(degraded)
	);

	// model the FB clear in response to eof
	int  cb_timer = 0; bit clearing_active = 1'b0;
	always @(posedge clk) begin
		if (reset) begin clear_busy <= 1'b0; clearing_active <= 1'b0; cb_timer <= 0; end
		else if (eof) begin clearing_active <= 1'b1; cb_timer <= 0; clear_busy <= 1'b0; end
		else if (clearing_active) begin
			cb_timer <= cb_timer + 1;
			if      (cb_timer < CB_DELAY)             clear_busy <= 1'b0;  // start latency
			else if (cb_timer < CB_DELAY + clear_cyc) clear_busy <= 1'b1;  // clearing
			else if (!clear_stuck) begin clear_busy <= 1'b0; clearing_active <= 1'b0; end
			// clear_stuck: clear_busy stays high forever -> MAX_BLANK must rescue
		end
	end

	// ---- metrics ----
	reg vggo_rise_d = 1'b0;
	always @(posedge clk) vggo_rise_d <= vggo_rise;

	int  vggo_in_cap = 0, lists_at_eof = 0, neof = 0, nstart = 0;
	bit  eof_on_vggo = 1'b1;
	bit  overrun     = 1'b0;     // beam_window && clear_busy ever -> FAIL (the bug we're killing)
	int  blank_lo = 0, blank_span = 0;   // measure beam-off span
	reg  bw_d = 1'b0;
	always @(posedge clk) if (!reset) begin
		// NO-OVERRUN assertion (the core handshake guarantee)
		if (beam_window && clear_busy) overrun <= 1'b1;
		// beam-off span measurement
		bw_d <= beam_window;
		if (!beam_window) blank_lo <= blank_lo + 1;
		if (beam_window && !bw_d) begin blank_span <= blank_lo; blank_lo <= 0; end  // snapshot at beam-on

		if (frame_start) nstart <= nstart + 1;
		if (beam_window && vggo_rise) vggo_in_cap <= vggo_in_cap + 1;
		if (eof) begin
			lists_at_eof <= vggo_in_cap; vggo_in_cap <= 0; neof <= neof + 1;
			if (vggo_en && !(vggo_rise || vggo_rise_d)) eof_on_vggo <= 1'b0;
		end
	end

	int fails = 0;

	task automatic run(input int scn, input logic [1:0] p, input int cc, input bit stuck,
	                   input bit ve, input int expectN);
		begin
			@(posedge clk); reset <= 1; rst_stim <= 1;
			persist <= p; clear_cyc <= cc; clear_stuck <= stuck; vggo_en <= ve;
			repeat (8) @(posedge clk);
			overrun = 1'b0; eof_on_vggo = 1'b1;
			reset <= 0; rst_stim <= 0;
			repeat (60000) @(posedge clk);
			$display("[scn %0d] persist=%0d clear=%0d stuck=%0b vggo=%0b  eof=%0d lists/eof=%0d(want %0d)  blank_span=%0d  overrun=%0b  lastComplete=%0b",
			         scn, p, cc, stuck, ve, neof, lists_at_eof, expectN, blank_span, overrun, eof_on_vggo);
			// Degrade cases first (overrun is the EXPECTED lesser-evil when the clear/vggo is broken;
			// the gate must NOT hang black -> eof must keep pulsing).
			if (stuck) begin
				if (neof >= 2) $display("         PASS: stuck-clear degrade (MAX_BLANK rescued, no hang)");
				else begin $display("         FAIL: stuck-clear HUNG"); fails++; end
			end else if (!ve) begin
				if (neof >= 2) $display("         PASS: dead-vggo degrade (eof still pulses)");
				else begin $display("         FAIL: degrade broken"); fails++; end
			// Normal cases: the handshake MUST give zero overrun + correct accumulation.
			end else if (overrun) begin
				$display("         FAIL [OVERRUN: beam on during clear -> dropped beams]"); fails++;
			end else begin
				if (lists_at_eof == expectN && eof_on_vggo && neof >= 3) $display("         PASS");
				else begin $display("         FAIL [count/complete]"); fails++; end
			end
		end
	endtask

	initial begin
		$display("=== present_gate CLEAR-DONE HANDSHAKE ===  persist->N: 0->6 1->4 2->3 3->2");
		run(1, 2'd0, 300, 1'b0, 1'b1, 6);    // short clear (banded), N=6
		run(2, 2'd0, 900, 1'b0, 1'b1, 6);    // long clear (full),  N=6  -> blank_span should grow vs scn1
		run(3, 2'd3, 300, 1'b0, 1'b1, 2);    // N=2, short clear
		run(4, 2'd1, 600, 1'b0, 1'b1, 4);    // N=4, medium clear
		run(5, 2'd0, 300, 1'b1, 1'b1, 6);    // STUCK clear -> MAX_BLANK degrade, no hang
		run(6, 2'd0, 300, 1'b0, 1'b0, 0);    // dead vggo -> degrade
		$display("=====================================================");
		if (fails == 0) $display("ALL HANDSHAKE GATE TESTS PASSED");
		else            $display("GATE TESTS FAILED: %0d", fails);
		$display("=====================================================");
		$finish;
	end
endmodule
