// MimoHalow.Hw.Rx.MrcCombiner co-simulation bench: the emitted RTL under
// iverilog, one FFT bin per 4 cycles. stim.txt: "<n>" then n lines
// "<bin> <chain> <tag> <re hex26> <im hex26>". out.txt: per e_valid
// "<j> <d> <re hex> <im hex> <g> <last>", then "N <scale> <noise>".
`timescale 1ns/1ps
module tb;
  reg clk = 0, enable = 0, in_valid = 0, in_chain = 0;
  reg [25:0] in_i = 0, in_q = 0;
  reg [5:0] in_bin = 0;
  reg [11:0] in_tag = 0;
  wire e_valid, e_last, e_stream;
  wire [25:0] e_i, e_q;
  wire [20:0] e_g;
  wire [5:0] e_d;
  wire [10:0] e_j;
  wire [3:0] scale;
  wire [41:0] noise;

  mrc_combiner dut (.clk(clk), .enable(enable), .in_valid(in_valid), .in_i(in_i), .in_q(in_q),
    .in_bin(in_bin), .in_chain(in_chain), .in_tag(in_tag),
    .e_valid(e_valid), .e_i(e_i), .e_q(e_q), .e_g(e_g), .e_d(e_d), .e_j(e_j), .e_stream(e_stream),
    .e_last(e_last), .scale(scale), .noise(noise));

  integer fi, fo, n, t, k, rc, b, ch, tg;
  reg [25:0] a, c;

  task tick; begin #5 clk = 1; #5 clk = 0; end endtask
  task seen;
    if (e_valid) $fdisplay(fo, "%0d %0d %h %h %0d %0d", e_j, e_d, e_i, e_q, e_g, e_last);
  endtask

  initial begin
    fi = $fopen("stim.txt", "r");
    fo = $fopen("out.txt", "w");
    rc = $fscanf(fi, "%d\n", n);
    tick; tick;
    enable = 1;
    for (t = 0; t < n; t = t + 1) begin
      rc = $fscanf(fi, "%d %d %d %h %h\n", b, ch, tg, a, c);
      in_bin = b; in_chain = ch; in_tag = tg; in_i = a; in_q = c; in_valid = 1;
      tick; seen;
      in_valid = 0;
      for (k = 0; k < 3; k = k + 1) begin tick; seen; end
    end
    for (k = 0; k < 20; k = k + 1) begin tick; seen; end
    $fdisplay(fo, "N %0d %0d", scale, noise);
    $fclose(fo);
    $finish;
  end
endmodule
