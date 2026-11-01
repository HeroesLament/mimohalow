// Hw.RxSync co-simulation bench (Hw.StfDetector -> Hw.LtfSync): the emitted
// RTL under iverilog, one sample per 4 cycles. stim.txt: "<n> <emin>" then n
// lines "<i hex> <q hex>". out.txt: per `done` pulse
// "<sync_td> <ts_off> <theta> <theta2> <dphi>" (decimal, hex, hex, hex), then
// "C <sync_count> <det_count>".
`timescale 1ns/1ps
module tb;
  reg clk = 0, valid = 0, enable = 0;
  reg [11:0] i = 0, q = 0;
  reg [31:0] emin = 0;
  wire detect, pass, done, busy;
  wire [31:0] det_pr, det_pi, det_r, sync_td;
  wire [15:0] det_count, sync_count, theta, theta2;
  wire [5:0] ts_off;
  wire [23:0] dphi;

  rx_sync dut (.clk(clk), .enable(enable), .valid(valid), .i(i), .q(q), .emin(emin),
    .detect(detect), .det_pr(det_pr), .det_pi(det_pi), .det_r(det_r), .det_count(det_count),
    .pass(pass), .done(done), .busy(busy), .ts_off(ts_off), .theta(theta), .theta2(theta2),
    .dphi(dphi), .sync_td(sync_td), .sync_count(sync_count));

  integer fi, fo, n, t, k, rc;
  reg [31:0] e;
  reg [11:0] a, b;

  task tick; begin #5 clk = 1; #5 clk = 0; end endtask
  task seen;
    if (done) $fdisplay(fo, "%0d %0d %h %h %h", sync_td, ts_off, theta, theta2, dphi);
  endtask

  initial begin
    fi = $fopen("stim.txt", "r");
    fo = $fopen("out.txt", "w");
    rc = $fscanf(fi, "%d %d\n", n, e);
    emin = e;
    tick; tick;
    enable = 1;
    for (t = 0; t < n; t = t + 1) begin
      rc = $fscanf(fi, "%h %h\n", a, b);
      i = a; q = b; valid = 1;
      tick; seen;
      valid = 0;
      for (k = 0; k < 3; k = k + 1) begin tick; seen; end
    end
    for (k = 0; k < 400; k = k + 1) begin tick; seen; end
    $fdisplay(fo, "C %0d %0d", sync_count, det_count);
    $fclose(fo);
    $finish;
  end
endmodule
