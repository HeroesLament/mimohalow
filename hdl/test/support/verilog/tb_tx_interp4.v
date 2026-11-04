// MimoHalow.Hw.Tx.Interp4 bench. stim.txt: "<n>" then n lines "<i> <q>"
// (signed decimal, 16-bit, 4 fraction bits). The output is pulled at most
// every 4 cycles (the TX port's 8 MS/s request) with random gaps; input
// offered with random gaps. out.txt: per output "<i> <q>" (signed 12-bit),
// then "E <cycles> <underruns>" (cycles where a pull found no sample before
// the last one).
`timescale 1ns/1ps
module tb;
  reg clk = 0, start = 0, i_valid = 0, i_last = 0, o_ready = 0;
  reg [15:0] i_i = 0, i_q = 0;
  wire i_ready, o_valid, o_last;
  wire [11:0] o_i, o_q;

  interp4 dut (.clk(clk), .start(start), .i_valid(i_valid), .i_i(i_i), .i_q(i_q),
    .i_last(i_last), .o_ready(o_ready), .i_ready(i_ready), .o_valid(o_valid),
    .o_i(o_i), .o_q(o_q), .o_last(o_last));

  integer fi, fo, n, k, rc, nin, cyc, ph, got_last, under, started;
  integer xi [0:65535];
  integer xq [0:65535];
  reg [15:0] lfsr = 16'h7A31;

  task tick; begin
    #5 clk = 1;
    if (o_valid && o_ready) begin
      $fdisplay(fo, "%0d %0d", $signed(o_i), $signed(o_q));
      if (o_last) got_last = 1;
      started = 1;
    end
    if (o_ready && !o_valid && started && !got_last) under = under + 1;
    if (i_valid && i_ready) nin = nin + 1;
    #1;
    lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    ph = (ph + 1) % 4;
    o_ready = (ph == 0);
    i_valid = (nin < n) && (lfsr[2] | lfsr[5]);
    i_i = xi[nin]; i_q = xq[nin];
    i_last = (nin == n - 1);
    #4 clk = 0;
    cyc = cyc + 1;
  end endtask

  initial begin
    fi = $fopen("stim.txt", "r");
    fo = $fopen("out.txt", "w");
    rc = $fscanf(fi, "%d\n", n);
    for (k = 0; k < n; k = k + 1) rc = $fscanf(fi, "%d %d\n", xi[k], xq[k]);
    nin = 0; cyc = 0; ph = 0; got_last = 0; under = 0; started = 0;
    #1 start = 1; tick; start = 0;
    while (!got_last && cyc < 4000000) tick;
    $fdisplay(fo, "E %0d %0d", cyc, under);
    $fclose(fo);
    $finish;
  end
endmodule
