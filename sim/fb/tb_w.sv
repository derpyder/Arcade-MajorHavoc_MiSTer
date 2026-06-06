module tb_w;
  reg [4:0] sc_n;
  // the SUSPECT expression I shipped (narrow 11-bit context on the multiply):
  wire [10:0] half_x_suspect = (10'd537 * sc_n) >> 4;
  // the width-safe version (full-width intermediate):
  wire [14:0] hxf = 10'd537 * sc_n;
  wire [10:0] half_x_fixed = hxf >> 4;
  initial begin
    sc_n = 5'd21; #1;
    $display("sc_n=21:  shipped=%0d   fixed=%0d   (correct=704)", half_x_suspect, half_x_fixed);
    sc_n = 5'd16; #1;
    $display("sc_n=16:  shipped=%0d   fixed=%0d   (correct=537)", half_x_suspect, half_x_fixed);
    $finish;
  end
endmodule
