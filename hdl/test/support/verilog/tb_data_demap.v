// MimoHalow.Hw.Rx.DataDemap bench. stim.txt: "<n>" then n lines, one per
// cycle: "0 <j> <d> <x hex27> <y hex27> <g>" (a Cpe point), "1 <mcs> <ndata>
// <discard>" (sig_done pulse), "2 <cycles>" (idle). out.txt: per p_valid
// "<a hex6> <b hex6> <first> <last>", then "E <early>".
`timescale 1ns/1ps
module tb;
  reg clk = 0, enable = 0, e_valid = 0, sig_done = 0, sig_discard = 0;
  reg [26:0] e_i = 0, e_q = 0;
  reg [20:0] e_g = 0;
  reg [5:0] e_d = 0;
  reg [10:0] e_j = 0, f_ndata = 0;
  reg [3:0] f_mcs = 0;
  wire p_valid, p_first, p_last;
  wire [5:0] p_a, p_b;
  wire [4:0] q;
  wire [7:0] early;

  data_demap dut (.clk(clk), .enable(enable), .e_valid(e_valid), .e_i(e_i), .e_q(e_q), .e_g(e_g),
    .e_d(e_d), .e_j(e_j), .sig_done(sig_done), .sig_discard(sig_discard), .f_mcs(f_mcs),
    .f_ndata(f_ndata), .p_valid(p_valid), .p_a(p_a), .p_b(p_b), .p_first(p_first), .p_last(p_last),
    .q(q), .early(early));

  integer fi, fo, n, t, k, rc, kind, j, d, g, m, nd, ds, cy;
  reg [26:0] x, y;

  task tick; begin
    #5 clk = 1; #5 clk = 0;
    if (p_valid) $fdisplay(fo, "%h %h %0d %0d", p_a, p_b, p_first, p_last);
  end endtask

  initial begin
    fi = $fopen("stim.txt", "r");
    fo = $fopen("out.txt", "w");
    rc = $fscanf(fi, "%d\n", n);
    tick; tick;
    enable = 1;
    for (t = 0; t < n; t = t + 1) begin
      rc = $fscanf(fi, "%d", kind);
      if (kind == 0) begin
        rc = $fscanf(fi, "%d %d %h %h %d\n", j, d, x, y, g);
        e_j = j; e_d = d; e_i = x; e_q = y; e_g = g; e_valid = 1;
        tick; e_valid = 0;
      end else if (kind == 1) begin
        rc = $fscanf(fi, "%d %d %d\n", m, nd, ds);
        f_mcs = m; f_ndata = nd; sig_discard = ds; sig_done = 1;
        tick; sig_done = 0;
      end else begin
        rc = $fscanf(fi, "%d\n", cy);
        for (k = 0; k < cy; k = k + 1) tick;
      end
    end
    for (k = 0; k < 2000; k = k + 1) tick;
    $fdisplay(fo, "E %0d", early);
    $fclose(fo);
    $finish;
  end
endmodule
