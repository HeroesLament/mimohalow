// eig1 receive chain bench: MrcCombiner -> Cpe, the emitted RTL under
// iverilog. stim.txt as tb_mrc_combiner ("<bin> <chain> <tag> <re> <im>",
// one FFT bin per 4 cycles). out.txt: per Cpe output
// "<j> <d> <re hex27> <im hex27> <g> <theta>".
`timescale 1ns/1ps
module tb;
  reg clk = 0, enable = 0, in_valid = 0, in_chain = 0;
  reg [25:0] in_i = 0, in_q = 0;
  reg [5:0] in_bin = 0;
  reg [11:0] in_tag = 0;

  wire c_valid, c_last, c_stream, c_pilot;
  wire [25:0] c_i, c_q;
  wire [20:0] c_g;
  wire [5:0] c_d;
  wire [10:0] c_j;
  wire [3:0] scale;
  wire [41:0] noise;

  wire e_valid, e_last;
  wire [26:0] e_i, e_q;
  wire [20:0] e_g;
  wire [5:0] e_d;
  wire [10:0] e_j;
  wire [15:0] e_theta;

  mrc_combiner comb (.clk(clk), .enable(enable), .in_valid(in_valid), .in_i(in_i), .in_q(in_q),
    .in_bin(in_bin), .in_chain(in_chain), .in_tag(in_tag),
    .e_valid(c_valid), .e_i(c_i), .e_q(c_q), .e_g(c_g), .e_d(c_d), .e_j(c_j), .e_stream(c_stream),
    .e_last(c_last), .e_pilot(c_pilot), .scale(scale), .noise(noise));

  cpe cpe0 (.clk(clk), .enable(enable), .in_valid(c_valid), .in_i(c_i), .in_q(c_q), .in_g(c_g),
    .in_d(c_d), .in_j(c_j), .in_last(c_last), .in_pilot(c_pilot),
    .e_valid(e_valid), .e_i(e_i), .e_q(e_q), .e_g(e_g), .e_d(e_d), .e_j(e_j), .e_last(e_last),
    .e_theta(e_theta));

  integer fi, fo, n, t, k, rc, b, ch, tg;
  reg [25:0] a, c;

  task tick; begin #5 clk = 1; #5 clk = 0; end endtask
  task seen;
    if (e_valid) $fdisplay(fo, "%0d %0d %h %h %0d %0d", e_j, e_d, e_i, e_q, e_g, e_theta);
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
    for (k = 0; k < 300; k = k + 1) begin tick; seen; end
    $fclose(fo);
    $finish;
  end
endmodule
