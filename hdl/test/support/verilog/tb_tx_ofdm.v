// MimoHalow.Hw.Tx.Ofdm bench. stim.txt: "<ncases>" then per case
// "<mod> <nsym>", "<sig[95:64]> <sig[63:32]> <sig[31:0]>" (hex), and nsym * 52
// lines "<bin> <i> <q> <last>" (decimal, i/q signed). Random stalls on both
// handshakes. out.txt: per sample "<i> <q>" (signed decimal), then "E <cycles>".
`timescale 1ns/1ps
module tb;
  reg clk = 0, start = 0, p_valid = 0, p_last = 0, o_ready = 0;
  reg [2:0] mod = 0;
  reg [9:0] nsym = 0;
  reg [95:0] sig = 0;
  reg [4:0] p_i = 0, p_q = 0;
  reg [5:0] p_bin = 0;
  wire p_ready, o_valid, o_last, busy;
  wire [15:0] o_i, o_q;

  ofdm dut (.clk(clk), .start(start), .mod(mod), .nsym(nsym), .sig(sig),
    .p_valid(p_valid), .p_i(p_i), .p_q(p_q), .p_bin(p_bin), .p_last(p_last),
    .o_ready(o_ready), .p_ready(p_ready), .o_valid(o_valid), .o_i(o_i), .o_q(o_q),
    .o_last(o_last), .busy(busy));

  integer fi, fo, ncase, c, i, rc, a, b, np, nin, cyc, got_last, bb, ii, qq, ll;
  reg [31:0] s2, s1, s0;
  reg [5:0] pbins [0:65535];
  reg [4:0] pis [0:65535];
  reg [4:0] pqs [0:65535];
  reg lasts [0:65535];
  reg [15:0] lfsr = 16'h1D0F;

  task tick; begin
    #5 clk = 1;
    if (o_valid && o_ready) begin
      $fdisplay(fo, "%0d %0d", $signed(o_i), $signed(o_q));
      if (o_last) got_last = 1;
    end
    if (p_valid && p_ready) nin = nin + 1;
    #1;
    lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    o_ready = lfsr[1] | lfsr[6];
    p_valid = (nin < np) && (lfsr[3] | lfsr[8]);
    p_bin = pbins[nin]; p_i = pis[nin]; p_q = pqs[nin]; p_last = lasts[nin];
    #4 clk = 0;
    cyc = cyc + 1;
  end endtask

  initial begin
    fi = $fopen("stim.txt", "r");
    fo = $fopen("out.txt", "w");
    rc = $fscanf(fi, "%d\n", ncase);
    for (c = 0; c < ncase; c = c + 1) begin
      rc = $fscanf(fi, "%d %d\n", a, b);
      mod = a; nsym = b;
      rc = $fscanf(fi, "%h %h %h\n", s2, s1, s0);
      sig = {s2, s1, s0};
      np = b * 52;
      for (i = 0; i < np; i = i + 1) begin
        rc = $fscanf(fi, "%d %d %d %d\n", bb, ii, qq, ll);
        pbins[i] = bb; pis[i] = ii; pqs[i] = qq; lasts[i] = ll;
      end
      nin = 0; got_last = 0; cyc = 0;
      #1 start = 1; tick; start = 0;
      while (!got_last && cyc < 2000000) tick;
      $fdisplay(fo, "E %0d", cyc);
      tick; tick;
    end
    $fclose(fo);
    $finish;
  end
endmodule
