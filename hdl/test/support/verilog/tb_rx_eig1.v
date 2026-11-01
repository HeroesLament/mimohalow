// MimoHalow.Hw.Rx.Eig1 bench: two-chain 12-bit samples at one per 16 cycles
// (2 MS/s on 32 MHz). stim.txt: "<n> <emin>", then n lines "<i0> <q0> <i1>
// <q1>" (hex12). out.txt: per Cpe output "<j> <d> <re hex27> <im hex27> <g>
// <theta>", per sync "D <td> <ts_off>", per SIG "G <ok> <discard>
// <nsym_total> <bits hex48>", then "S <sync> <det> <drop> <overrun>".
`timescale 1ns/1ps
module tb;
  reg clk = 0, enable = 0, valid = 0;
  reg [11:0] i0 = 0, q0 = 0, i1 = 0, q1 = 0;
  reg [31:0] emin = 0;
  wire detect, done, e_valid, e_last;
  wire [15:0] det_count, sync_count, drop_count, e_theta;
  wire [5:0] ts_off, e_d;
  wire [23:0] dphi;
  wire [31:0] sync_td;
  wire [7:0] overrun;
  wire [3:0] scale;
  wire [41:0] noise;
  wire [26:0] e_i, e_q;
  wire [20:0] e_g;
  wire [10:0] e_j, nsym_total, f_ndata;
  wire sig_done, sig_ok, sig_discard, f_aggr;
  wire [47:0] sig_bits;
  wire [3:0] f_mcs;
  wire [8:0] f_length;

  eig1 dut (.clk(clk), .enable(enable), .valid(valid), .i0(i0), .q0(q0), .i1(i1), .q1(q1),
    .emin(emin),
    .detect(detect), .det_count(det_count), .done(done), .ts_off(ts_off), .dphi(dphi),
    .sync_td(sync_td), .sync_count(sync_count), .drop_count(drop_count), .overrun(overrun),
    .scale(scale), .noise(noise), .e_valid(e_valid), .e_i(e_i), .e_q(e_q), .e_g(e_g),
    .e_d(e_d), .e_j(e_j), .e_last(e_last), .e_theta(e_theta),
    .sig_done(sig_done), .sig_ok(sig_ok), .sig_discard(sig_discard), .nsym_total(nsym_total),
    .sig_bits(sig_bits), .f_mcs(f_mcs), .f_length(f_length), .f_aggr(f_aggr), .f_ndata(f_ndata));

  integer fi, fo, n, t, k, rc, x;
  reg [11:0] a, b, c, d;

  task tick; begin
    #5 clk = 1; #5 clk = 0;
    if (done) $fdisplay(fo, "D %0d %0d", sync_td, ts_off);
    if (sig_done) $fdisplay(fo, "G %0d %0d %0d %h", sig_ok, sig_discard, nsym_total, sig_bits);
    if (e_valid) $fdisplay(fo, "%0d %0d %h %h %0d %0d", e_j, e_d, e_i, e_q, e_g, e_theta);
  end endtask

  initial begin
    fi = $fopen("stim.txt", "r");
    fo = $fopen("out.txt", "w");
    rc = $fscanf(fi, "%d %d\n", n, x);
    emin = x;
    tick; tick;
    enable = 1;
    for (t = 0; t < n; t = t + 1) begin
      rc = $fscanf(fi, "%h %h %h %h\n", a, b, c, d);
      i0 = a; q0 = b; i1 = c; q1 = d; valid = 1;
      tick;
      valid = 0;
      for (k = 0; k < 15; k = k + 1) tick;
    end
    for (k = 0; k < 3000; k = k + 1) tick;
    $fdisplay(fo, "S %0d %0d %0d %0d", sync_count, det_count, drop_count, overrun);
    $fclose(fo);
    $finish;
  end
endmodule
