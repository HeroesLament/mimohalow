// MimoHalow.Hw.Rx.Eig1 bench: two-chain 12-bit samples at one per 16 cycles
// (2 MS/s on 32 MHz). stim.txt: "<n> <emin> <np> <nsym_1> .. <nsym_np>",
// then n lines "<i0> <q0> <i1> <q1>" (hex12). Each `done` (sync) is answered
// two cycles later with set_nsym = the next nsym (standing in for the SIG
// decoder). out.txt: per Cpe output "<j> <d> <re hex27> <im hex27> <g>
// <theta>", per sync "D <td> <ts_off>", then "S <sync> <det> <drop> <overrun>".
`timescale 1ns/1ps
module tb;
  reg clk = 0, enable = 0, valid = 0, set_nsym = 0;
  reg [11:0] i0 = 0, q0 = 0, i1 = 0, q1 = 0;
  reg [31:0] emin = 0;
  reg [10:0] nsym = 0;
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
  wire [10:0] e_j;

  eig1 dut (.clk(clk), .enable(enable), .valid(valid), .i0(i0), .q0(q0), .i1(i1), .q1(q1),
    .emin(emin), .set_nsym(set_nsym), .nsym(nsym),
    .detect(detect), .det_count(det_count), .done(done), .ts_off(ts_off), .dphi(dphi),
    .sync_td(sync_td), .sync_count(sync_count), .drop_count(drop_count), .overrun(overrun),
    .scale(scale), .noise(noise), .e_valid(e_valid), .e_i(e_i), .e_q(e_q), .e_g(e_g),
    .e_d(e_d), .e_j(e_j), .e_last(e_last), .e_theta(e_theta));

  integer fi, fo, n, t, k, rc, np, pi, x;
  integer ns [0:15];
  integer pend;
  reg [11:0] a, b, c, d;

  task tick; begin
    #5 clk = 1; #5 clk = 0;
    set_nsym = 0;
    if (pend > 0) begin
      pend = pend - 1;
      if (pend == 0) begin set_nsym = 1; nsym = ns[pi]; pi = pi + 1; end
    end
    if (done) begin $fdisplay(fo, "D %0d %0d", sync_td, ts_off); pend = 2; end
    if (e_valid) $fdisplay(fo, "%0d %0d %h %h %0d %0d", e_j, e_d, e_i, e_q, e_g, e_theta);
  end endtask

  initial begin
    pend = 0; pi = 0;
    fi = $fopen("stim.txt", "r");
    fo = $fopen("out.txt", "w");
    rc = $fscanf(fi, "%d %d %d", n, x, np);
    emin = x;
    for (k = 0; k < np; k = k + 1) rc = $fscanf(fi, "%d", ns[k]);
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
