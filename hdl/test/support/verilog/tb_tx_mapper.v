// MimoHalow.Hw.Tx.Mapper bench. stim.txt: "<ncases>" then per case
// "<mod> <nbits>" and <nbits> lines of one coded bit. Random stalls on both
// handshakes. out.txt: per point "<bin> <i> <q> <last>" (decimal, i/q
// signed), then "E <cycles>" when <nbits>/Ncbps * 52 points are out.
`timescale 1ns/1ps
module tb;
  reg clk = 0, start = 0, i_valid = 0, i_bit = 0, o_ready = 0;
  reg [2:0] mod = 0;
  wire i_ready, o_valid, o_last;
  wire [4:0] o_i, o_q;
  wire [5:0] o_bin;

  mapper dut (.clk(clk), .start(start), .mod(mod), .i_valid(i_valid), .i_bit(i_bit),
    .o_ready(o_ready), .i_ready(i_ready), .o_valid(o_valid), .o_i(o_i), .o_q(o_q),
    .o_bin(o_bin), .o_last(o_last));

  integer fi, fo, ncase, c, i, rc, a, nbits, nin, nout, want, cyc;
  reg bits [0:65535];
  reg [15:0] lfsr = 16'hBEEF;

  task tick; begin
    #5 clk = 1;
    if (o_valid && o_ready) begin
      $fdisplay(fo, "%0d %0d %0d %0d", o_bin, $signed(o_i), $signed(o_q), o_last);
      nout = nout + 1;
    end
    if (i_valid && i_ready) nin = nin + 1;
    #1;
    lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    o_ready = lfsr[2] | lfsr[9];
    i_valid = (nin < nbits) && (lfsr[4] | lfsr[11]);
    i_bit = bits[nin];
    #4 clk = 0;
    cyc = cyc + 1;
  end endtask

  initial begin
    fi = $fopen("stim.txt", "r");
    fo = $fopen("out.txt", "w");
    rc = $fscanf(fi, "%d\n", ncase);
    for (c = 0; c < ncase; c = c + 1) begin
      rc = $fscanf(fi, "%d %d\n", a, nbits);
      mod = a;
      for (i = 0; i < nbits; i = i + 1) rc = $fscanf(fi, "%d\n", bits[i]);
      want = (nbits / (52 * (a == 0 ? 1 : a == 1 ? 2 : a == 2 ? 4 : a == 3 ? 6 : 8))) * 52;
      nin = 0; nout = 0; cyc = 0;
      #1 start = 1; tick; start = 0;
      while (nout < want && cyc < 400000) tick;
      $fdisplay(fo, "E %0d", cyc);
      tick; tick;
    end
    $fclose(fo);
    $finish;
  end
endmodule
