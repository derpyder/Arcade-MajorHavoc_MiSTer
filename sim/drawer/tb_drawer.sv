// Unit-test the vector_drawer off_screen flag. Two things to prove:
//  (1) off_screen == (signed-13(xpos[25:13]) != signed-10(xpos[22:13])) every cycle
//      i.e. the flag fires EXACTLY when the 10-bit output WRAPS (misrepresents the true position).
//  (2) NORMAL on-screen vectors keep off_screen=0 the whole walk (no false blank of real geometry);
//      only oversized "warp" vectors trip it.
`timescale 1ns/1ps
module tb_drawer;
	logic clk=0; always #5 clk=~clk;
	logic clk_ena=1'b1;
	logic [12:0] scale=0; logic signed [12:0] rel_x=0, rel_y=0;
	logic zero=0, draw=0, done;
	logic [9:0] xout, yout;
	logic off_screen;

	vector_drawer dut(.clk(clk), .clk_ena(clk_ena), .scale(scale), .rel_x(rel_x), .rel_y(rel_y),
	                  .zero(zero), .draw(draw), .done(done), .xout(xout), .yout(yout), .off_screen(off_screen));

	integer assert_fail=0;
	always @(posedge clk) if (clk_ena && !zero) begin
		int sx13, sx10, sy13, sy10; bit exp;
		sx13 = $signed(dut.xpos[25:13]); sx10 = $signed(dut.xpos[22:13]);
		sy13 = $signed(dut.ypos[25:13]); sy10 = $signed(dut.ypos[22:13]);
		exp  = (sx13 != sx10) || (sy13 != sy10);
		if (off_screen !== exp) begin
			assert_fail++;
			if (assert_fail<6) $display("  MISMATCH off=%b exp=%b xpos13=%0d xout10=%0d", off_screen, exp, sx13, sx10);
		end
	end

	integer off_cyc;
	task automatic do_zero; begin zero<=1; @(posedge clk); zero<=0; repeat(40) @(posedge clk); end endtask
	task automatic draw_vec(input string nm, input [12:0] s, input signed [12:0] rx, ry); begin
		wait(done==1'b1); @(posedge clk);
		off_cyc=0;
		scale<=s; rel_x<=rx; rel_y<=ry; draw<=1; @(posedge clk); draw<=0;
		@(posedge clk);
		while(done!=1'b1) begin @(posedge clk); if (off_screen) off_cyc++; end
		$display("  %-22s s=%0d rx=%0d ry=%0d -> xout=%0d yout=%0d  off_NOW=%b  off_cycles_during_walk=%0d  (true xpos13=%0d)",
			nm, s, rx, ry, xout, yout, off_screen, off_cyc, $signed(dut.xpos[25:13]));
	end endtask

	initial begin
		repeat(5) @(posedge clk); do_zero;
		$display("--- ON-SCREEN vectors: expect off_cycles=0 (must NOT blank normal geometry) ---");
		draw_vec("on +x",  13'h040, 13'sd300, 13'sd0);  do_zero;
		draw_vec("on -x",  13'h040,-13'sd300, 13'sd0);  do_zero;
		draw_vec("on +y",  13'h040, 13'sd0,  13'sd300); do_zero;
		draw_vec("on +xy", 13'h040, 13'sd250, 13'sd250);do_zero;
		$display("--- WARP-SIZED vectors: expect off_screen to fire + xout to WRAP (xout != true xpos13) ---");
		draw_vec("warp +x x2",  13'h1FF, 13'sd4000,13'sd0);  do_zero;
		draw_vec("warp +x x4",  13'h3FF, 13'sd4000,13'sd0);  do_zero;
		draw_vec("warp +x x8",  13'h7FF, 13'sd4000,13'sd0);  do_zero;
		draw_vec("warp -x x8",  13'h7FF,-13'sd4000,13'sd0);  do_zero;
		draw_vec("warp +y x8",  13'h7FF, 13'sd0, 13'sd4000);
		$display("RESULT: formula-mismatch cycles = %0d  (0 = off_screen flag is correct by construction)", assert_fail);
		$finish;
	end
	initial begin #80ms; $display("TIMEOUT"); $finish; end
endmodule
