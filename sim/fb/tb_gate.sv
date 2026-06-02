// Validate the ONE-FRAME-CAPTURE present-gate (tempest_sw.sv): per 30Hz tick, after a clear
// blank, capture EXACTLY one AVG frame (two avg_halted frame-done risings), lock out, degrade
// to beam-on if no boundary. Measures cap_on beam-cycles PER TICK PERIOD: healthy == ~one DRAW
// (one frame). ~3*DRAW would mean it still smears; 0 would mean black.
`timescale 1ns/1ps
module tb_gate #(
	parameter int IDLE   = 200,    // avg_halted HIGH (idle) cycles per frame
	parameter int DRAW   = 100,    // avg_halted LOW (draw) cycles per frame
	parameter bit GLITCH = 1'b0,
	parameter int TP     = 2400,   // tick period (scaled): ~8 frames/period
	parameter int BLANK  = 1536,   // ~64% (matches 255999/399999)
	parameter int TOUT   = 2016    // ~84% (matches 335999/399999)
);
	logic clk=0; always #5 clk=~clk;
	logic reset=1;

	logic avg_halted = 1'b1; integer fctr=0;
	always @(posedge clk) begin
		if (reset) begin avg_halted<=1'b1; fctr<=0; end
		else begin
			fctr <= (fctr==IDLE+DRAW-1)?0:fctr+1;
			avg_halted <= (fctr<IDLE)?1'b1:1'b0;
			if (GLITCH && fctr==IDLE/2)      avg_halted<=1'b0;
			if (GLITCH && fctr==IDLE+DRAW/2) avg_halted<=1'b1;
		end
	end
	wire tmp_frame_done = avg_halted;

	// ---- tempest_sw one-frame-capture gate (replicated) ----
	reg [18:0] tick_cnt=0; reg tick=0;
	always @(posedge clk) begin
		if (tick_cnt==TP) begin tick_cnt<=0; tick<=1; end else begin tick_cnt<=tick_cnt+1; tick<=0; end
	end
	reg fd_d2=1; always @(posedge clk) fd_d2<=tmp_frame_done;
	wire fd_rise = tmp_frame_done & ~fd_d2;
	reg armed=0, cap_on=0, captured=0;
	always @(posedge clk) begin
		if (reset || tick) begin armed<=0; cap_on<=0; captured<=0; end
		else begin
			if ((tick_cnt>=BLANK) && !armed && !cap_on && !captured) armed<=1;
			if (armed && fd_rise)                begin armed<=0; cap_on<=1; end
			else if (armed && (tick_cnt>=TOUT))  begin armed<=0; cap_on<=1; end
			else if (cap_on && fd_rise)          begin cap_on<=0; captured<=1; end
		end
	end

	// measure PIXELS captured per period = cap_on AND drawing (avg_halted==0); idle paints
	// nothing (rgb=0).  Healthy == exactly DRAW (one complete frame); <DRAW=partial; >DRAW=smear.
	wire drawing = ~avg_halted;
	integer period_pix=0, last_period_pix=0, nperiod=0, ncap=0;
	reg cap_on_d=0;
	always @(posedge clk) if (!reset) begin
		if (tick) begin last_period_pix<=period_pix; period_pix<=0; nperiod<=nperiod+1; end
		else if (cap_on && drawing) period_pix<=period_pix+1;
		if (cap_on & ~cap_on_d) ncap<=ncap+1;
		cap_on_d<=cap_on;
	end

	initial begin
		repeat(20) @(posedge clk); reset=0;
		repeat(10*TP) @(posedge clk);
		$display("CFG IDLE=%0d DRAW=%0d GLITCH=%0b (one-frame capture)  periods=%0d capture-starts/period=%0.1f",
			IDLE, DRAW, GLITCH, nperiod, nperiod? 1.0*ncap/nperiod : 0.0);
		$display("  PIXELS captured in last full period = %0d   (healthy == DRAW=%0d = ONE complete frame)",
			last_period_pix, DRAW);
		if (last_period_pix==0)             $display("  >>> BLACK (no capture)");
		else if (last_period_pix < DRAW-DRAW/4) $display("  >>> PARTIAL frame (incomplete geometry)");
		else if (last_period_pix > DRAW+DRAW/4) $display("  >>> SMEAR (>one frame)");
		else                                $display("  >>> GOOD: exactly one complete frame");
		$finish;
	end
endmodule
