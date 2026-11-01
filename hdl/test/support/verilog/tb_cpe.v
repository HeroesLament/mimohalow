// MimoHalow.Hw.Rx.Cpe co-simulation bench. stim.txt: "<n>" then n lines
// "<j> <d> <pilot> <last> <re hex26> <im hex26> <g>", one tone per 4 cycles.
// out.txt: per e_valid "<j> <d> <re hex27> <im hex27> <g> <last> <theta>".
`timescale 1ns/1ps
module tb;
  reg clk = 0, enable = 0, in_valid = 0, in_last = 0, in_pilot = 0;
  reg [25:0] in_i = 0, in_q = 0;
  reg [20:0] in_g = 0;
  reg [5:0] in_d = 0;
  reg [10:0] in_j = 0;
  wire e_valid, e_last;
  wire [26:0] e_i, e_q;
  wire [20:0] e_g;
  wire [5:0] e_d;
  wire [10:0] e_j;
  wire [15:0] e_theta;

  cpe dut (.clk(clk), .enable(enable), .in_valid(in_valid), .in_i(in_i), .in_q(in_q), .in_g(in_g),
    .in_d(in_d), .in_j(in_j), .in_last(in_last), .in_pilot(in_pilot),
    .e_valid(e_valid), .e_i(e_i), .e_q(e_q), .e_g(e_g), .e_d(e_d), .e_j(e_j), .e_last(e_last),
    .e_theta(e_theta));

  integer fi, fo, n, t, k, rc, j, d, p, l, g;
  reg [25:0] a, c;

  task tick; begin #5 clk = 1; #5 clk = 0; end endtask
  task seen;
    if (e_valid) $fdisplay(fo, "%0d %0d %h %h %0d %0d %0d", e_j, e_d, e_i, e_q, e_g, e_last, e_theta);
  endtask

  initial begin
    fi = $fopen("stim.txt", "r");
    fo = $fopen("out.txt", "w");
    rc = $fscanf(fi, "%d\n", n);
    tick; tick;
    enable = 1;
    for (t = 0; t < n; t = t + 1) begin
      rc = $fscanf(fi, "%d %d %d %d %h %h %d\n", j, d, p, l, a, c, g);
      in_j = j; in_d = d; in_pilot = p; in_last = l; in_i = a; in_q = c; in_g = g; in_valid = 1;
      tick; seen;
      in_valid = 0;
      for (k = 0; k < 3; k = k + 1) begin tick; seen; end
    end
    for (k = 0; k < 200; k = k + 1) begin tick; seen; end
    $fclose(fo);
    $finish;
  end
endmodule
