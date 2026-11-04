// MimoHalow.Hw.Tx.TxPhy bench. stim.txt: "<ncases>" then per case
// "<seed> <rate> <mod> <nsym> <nbits> <len>", "<sig[95:64]> <sig[63:32]>
// <sig[31:0]>" (hex), then len lines "<byte>" (hex). The buffer is a
// synchronous-read 24-bit RAM as on the host side; tick every 4 cycles (the
// 8 MS/s TX request). out.txt: per sample "<i> <q>" (signed decimal), then
// "E <cycles> <underruns>".
`timescale 1ns/1ps
module tb;
  reg clk = 0, start = 0, tick = 0;
  reg [6:0] seed = 0;
  reg [1:0] rate = 0;
  reg [2:0] mod = 0;
  reg [9:0] nsym = 0;
  reg [15:0] nbits = 0;
  reg [9:0] len = 0;
  reg [95:0] sig = 0;
  reg [23:0] b_data = 0;
  wire [9:0] b_addr;
  wire o_valid, busy, done, under;
  wire [11:0] o_i, o_q;

  tx_phy dut (.clk(clk), .start(start), .seed(seed), .rate(rate), .mod(mod), .nsym(nsym),
    .nbits(nbits), .len(len), .sig(sig), .b_data(b_data), .tick(tick), .b_addr(b_addr),
    .o_valid(o_valid), .o_i(o_i), .o_q(o_q), .busy(busy), .done(done), .under(under));

  reg [23:0] mem [0:1023];
  integer fi, fo, ncase, c, i, rc, a0, a1, a2, a3, a4, a5, bt, cyc, got_last, nu, ph;
  reg [31:0] s2, s1, s0;

  always @(posedge clk) b_data <= mem[b_addr];

  task step; begin
    #5 clk = 1;
    if (o_valid) $fdisplay(fo, "%0d %0d", $signed(o_i), $signed(o_q));
    if (done) got_last = 1;
    if (under) nu = nu + 1;
    #1;
    ph = (ph + 1) % 4;
    tick = (ph == 0);
    #4 clk = 0;
    cyc = cyc + 1;
  end endtask

  initial begin
    fi = $fopen("stim.txt", "r");
    fo = $fopen("out.txt", "w");
    rc = $fscanf(fi, "%d\n", ncase);
    ph = 0;
    for (c = 0; c < ncase; c = c + 1) begin
      rc = $fscanf(fi, "%d %d %d %d %d %d\n", a0, a1, a2, a3, a4, a5);
      seed = a0; rate = a1; mod = a2; nsym = a3; nbits = a4; len = a5;
      rc = $fscanf(fi, "%h %h %h\n", s2, s1, s0);
      sig = {s2, s1, s0};
      for (i = 0; i < 1024; i = i + 1) mem[i] = 24'h0;
      for (i = 0; i < a5; i = i + 1) begin
        rc = $fscanf(fi, "%h\n", bt);
        mem[i / 3][(i % 3) * 8 +: 8] = bt;
      end
      got_last = 0; cyc = 0; nu = 0;
      #1 start = 1; step; start = 0;
      while (!got_last && cyc < 4000000) step;
      $fdisplay(fo, "E %0d %0d", cyc, nu);
      for (i = 0; i < 40; i = i + 1) step;
    end
    $fclose(fo);
    $finish;
  end
endmodule
