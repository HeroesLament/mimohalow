// MimoHalow.Hw.Rx.Decim4 bench. stim.txt: "<n>" then n lines "<i0> <q0>
// <i1> <q1>" (hex12), one `valid` every 4 cycles. out.txt: per o_valid the
// four outputs (hex12).
`timescale 1ns/1ps
module tb;
  reg clk = 0, enable = 0, valid = 0;
  reg [11:0] i0 = 0, q0 = 0, i1 = 0, q1 = 0;
  wire o_valid;
  wire [11:0] o_i0, o_q0, o_i1, o_q1;

  decim4 dut (.clk(clk), .enable(enable), .valid(valid), .i0(i0), .q0(q0), .i1(i1), .q1(q1),
    .o_valid(o_valid), .o_i0(o_i0), .o_q0(o_q0), .o_i1(o_i1), .o_q1(o_q1));

  integer fi, fo, n, t, k, rc;
  reg [11:0] a, b, c, d;

  task tick; begin
    #5 clk = 1; #5 clk = 0;
    if (o_valid) $fdisplay(fo, "%h %h %h %h", o_i0, o_q0, o_i1, o_q1);
  end endtask

  initial begin
    fi = $fopen("stim.txt", "r");
    fo = $fopen("out.txt", "w");
    rc = $fscanf(fi, "%d\n", n);
    tick; tick;
    enable = 1;
    for (t = 0; t < n; t = t + 1) begin
      rc = $fscanf(fi, "%h %h %h %h\n", a, b, c, d);
      i0 = a; q0 = b; i1 = c; q1 = d; valid = 1;
      tick;
      valid = 0;
      for (k = 0; k < 3; k = k + 1) tick;
    end
    for (k = 0; k < 100; k = k + 1) tick;
    $fclose(fo);
    $finish;
  end
endmodule
