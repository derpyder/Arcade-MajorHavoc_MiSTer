`timescale 1ns/1ps
// ============================================================================
// tb_coord.sv -- verify the mhavoc_sw coord-map (x1.3125 Fill) with the REAL
// Verilog width semantics that Python could not see.
//
// The wire chain below is COPIED VERBATIM from rtl/mhavoc_sw.sv (osd_scale=0,
// osd_rotate=0, osd_flip=0).  Same declared widths -> ModelSim evaluates the
// same truncation/extension rules as Quartus.  The width-truncation bug that
// produced the "4 quadrants" was `(537*sc_n)>>4` truncating to an 11-bit target
// (64 instead of 704).  The shipping form here uses a WIDE product (cxs[14:0])
// and a pure-shift centre (half = {sc_n,5'd0}); this TB proves it is width-safe:
// the AVG centre (512,512) MUST land on (490,360) and half MUST be 672.
// ============================================================================
module tb_coord;
  reg [9:0] cx, cy;

  localparam [1:0] osd_scale = 2'd0;   // Fill

  wire [4:0]  sc_n = (osd_scale == 2'd0) ? 5'd21 :
                     (osd_scale == 2'd1) ? 5'd16 :
                     (osd_scale == 2'd2) ? 5'd12 : 5'd8;
  wire [14:0] cxs  = cx * sc_n;
  wire [14:0] cys  = cy * sc_n;
  wire [10:0] sx   = cxs[14:4];
  wire [10:0] sy   = cys[14:4];
  wire [9:0]  half = {sc_n, 5'd0};
  wire signed [12:0] scx = $signed({2'b00, sx}) - $signed({3'b000, half});
  wire signed [12:0] scy = $signed({2'b00, sy}) - $signed({3'b000, half});
  // osd_rotate=0, osd_flip=0:
  wire signed [12:0] rx = scx;
  wire signed [12:0] ry = scy;
  wire signed [13:0] fxs = 14'sd490 + rx;
  wire signed [13:0] fys = 14'sd360 - ry;
  wire in_bounds = (fxs >= 0) && (fxs < 14'sd980) && (fys >= 0) && (fys < 14'sd720);

  integer fails = 0;

  task show(input [9:0] x, input [9:0] y);
    begin
      cx = x; cy = y; #1;
      $display("cx=%4d cy=%4d | sc_n=%0d half=%0d sx=%4d sy=%4d | scx=%5d scy=%5d | fxs=%5d fys=%5d inb=%0d",
               cx, cy, sc_n, half, sx, sy, scx, scy, fxs, fys, in_bounds);
    end
  endtask

  task expect_eq(input [31:0] got, input [31:0] exp, input [255:0] name);
    begin
      if (got !== exp) begin
        $display("  *** FAIL: %0s = %0d, expected %0d", name, got, exp);
        fails = fails + 1;
      end else
        $display("  ok: %0s = %0d", name, got);
    end
  endtask

  initial begin
    $display("=== MH coord-map  (osd_scale=0 -> x1.3125 Fill, rotate=0 flip=0) ===");
    show(512, 512);   // CENTER
    show(612, 512);   // +100 x  -> 490 + 100*1.3125 = 621.25
    show(412, 512);   // -100 x  -> 490 - 131 = 359
    show(512, 612);   // +100 y  -> 360 - 131 = 229
    show(512, 412);   // -100 y  -> 360 + 131 = 491
    show(512, 238);   // ~top edge of fill window  (fys ~ 720)
    show(512, 786);   // ~bottom edge of fill window (fys ~ 0)
    show(1023,1023);  // coord corner -> out of bounds (no content there)
    show(0,   0);     // coord corner -> out of bounds

    $display("");
    $display("=== width-safety assertions (the bug would break these) ===");
    cx = 512; cy = 512; #1;
    expect_eq(half, 672, "half (=512*21>>4)");          // pure-shift centre, NOT 64
    expect_eq(sx,   672, "sx at centre");
    expect_eq($signed(scx), 0, "scx at centre");
    expect_eq($signed(fxs), 490, "fxs at centre");
    expect_eq($signed(fys), 360, "fys at centre");
    expect_eq(in_bounds, 1, "centre in_bounds");
    // scale magnitude: +100 AVG-x -> +131 fb px (1.3125x), within +/-1 of 621
    cx = 612; cy = 512; #1;
    if ($signed(fxs) >= 620 && $signed(fxs) <= 622) $display("  ok: +100x scale -> fxs=%0d (~621)", fxs);
    else begin $display("  *** FAIL: +100x scale -> fxs=%0d (expected ~621)", fxs); fails = fails + 1; end

    $display("");
    if (fails == 0) $display("RESULT: PASS  (coord-map width-safe, centred, x1.3125)");
    else            $display("RESULT: FAIL  (%0d checks failed)", fails);
    $finish;
  end
endmodule
