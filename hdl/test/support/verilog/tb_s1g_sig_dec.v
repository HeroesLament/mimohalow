// MimoHalow.Hw.Rx.S1gSigDec bench. stim.txt: "<n>" then n lines
// "<j> <d> <q hex27>", one per 4 cycles; j = 2047 is an idle slot.
// out.txt: per sig_done "<ok> <discard> <nsym_total> <bits hex48> <ndata>".
`timescale 1ns/1ps
module tb;
  reg clk = 0, enable = 0, e_valid = 0;
  reg [26:0] e_q = 0;
  reg [5:0] e_d = 0;
  reg [10:0] e_j = 0;
  wire sig_done, sig_ok, discard, f_aggr, f_smoothing;
  wire [10:0] nsym_total, f_ndata;
  wire [47:0] sig_bits;
  wire [4:0] q;
  wire [3:0] f_mcs;
  wire [8:0] f_length, f_id;
  wire [1:0] f_nsts;

  s1g_sig_dec dut (.clk(clk), .enable(enable), .e_valid(e_valid), .e_q(e_q), .e_d(e_d), .e_j(e_j),
    .sig_done(sig_done), .sig_ok(sig_ok), .discard(discard), .nsym_total(nsym_total),
    .sig_bits(sig_bits), .q(q), .f_mcs(f_mcs), .f_length(f_length), .f_aggr(f_aggr),
    .f_smoothing(f_smoothing), .f_id(f_id), .f_nsts(f_nsts), .f_ndata(f_ndata));

  integer fi, fo, n, t, k, rc, j, d;
  reg [26:0] a;

  task tick; begin
    #5 clk = 1; #5 clk = 0;
    if (sig_done) $fdisplay(fo, "%0d %0d %0d %h %0d", sig_ok, discard, nsym_total, sig_bits, f_ndata);
  end endtask

  initial begin
    fi = $fopen("stim.txt", "r");
    fo = $fopen("out.txt", "w");
    rc = $fscanf(fi, "%d\n", n);
    tick; tick;
    enable = 1;
    for (t = 0; t < n; t = t + 1) begin
      rc = $fscanf(fi, "%d %d %h\n", j, d, a);
      if (j != 2047) begin e_j = j; e_d = d; e_q = a; e_valid = 1; end
      tick;
      e_valid = 0;
      for (k = 0; k < 3; k = k + 1) tick;
    end
    for (k = 0; k < 3000; k = k + 1) tick;
    $fclose(fo);
    $finish;
  end
endmodule
