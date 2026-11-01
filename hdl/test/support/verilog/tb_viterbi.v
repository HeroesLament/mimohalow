// MimoHalow.Hw.Rx.Viterbi bench. stim.txt: "<n>" then n lines
// "<gap> <first> <last> <a hex6> <b hex6>": wait <gap> idle cycles, then one
// pair. out.txt: per out_valid "<bit> <last>", then "O <overflow>".
`timescale 1ns/1ps
module tb;
  reg clk = 0, enable = 0, in_valid = 0, in_first = 0, in_last = 0;
  reg [5:0] in_a = 0, in_b = 0;
  wire out_valid, out_bit, out_last, overflow;

  viterbi dut (.clk(clk), .enable(enable), .in_valid(in_valid), .in_a(in_a), .in_b(in_b),
    .in_first(in_first), .in_last(in_last), .out_valid(out_valid), .out_bit(out_bit),
    .out_last(out_last), .overflow(overflow));

  integer fi, fo, n, t, k, rc, g, f, l;
  reg [5:0] a, b;

  task tick; begin
    #5 clk = 1; #5 clk = 0;
    if (out_valid) $fdisplay(fo, "%0d %0d", out_bit, out_last);
  end endtask

  initial begin
    fi = $fopen("stim.txt", "r");
    fo = $fopen("out.txt", "w");
    rc = $fscanf(fi, "%d\n", n);
    tick; tick;
    enable = 1;
    for (t = 0; t < n; t = t + 1) begin
      rc = $fscanf(fi, "%d %d %d %h %h\n", g, f, l, a, b);
      for (k = 0; k < g; k = k + 1) tick;
      in_first = f; in_last = l; in_a = a; in_b = b; in_valid = 1;
      tick;
      in_valid = 0;
    end
    for (k = 0; k < 4000; k = k + 1) tick;
    $fdisplay(fo, "O %0d", overflow);
    $fclose(fo);
    $finish;
  end
endmodule
