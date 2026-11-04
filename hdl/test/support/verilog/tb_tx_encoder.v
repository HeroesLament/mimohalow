// MimoHalow.Hw.Tx.Encoder bench. stim.txt: "<ncases>" then per case a line
// "<seed> <rate> <nbits> <len>" (decimal) followed by <len> lines of one PSDU
// byte (hex). Random stalls on both handshakes (LFSR). out.txt: per case one
// line per coded bit ("0"/"1"), then "E <cycles>".
`timescale 1ns/1ps
module tb;
  reg clk = 0, start = 0, in_valid = 0, o_ready = 0;
  reg [6:0] seed = 0;
  reg [1:0] rate = 0;
  reg [15:0] nbits = 0;
  reg [9:0] len = 0;
  reg [7:0] in_byte = 0;
  wire in_ready, o_valid, o_bit, busy, done;

  encoder dut (.clk(clk), .start(start), .seed(seed), .rate(rate), .nbits(nbits),
    .len(len), .in_valid(in_valid), .in_byte(in_byte), .o_ready(o_ready),
    .in_ready(in_ready), .o_valid(o_valid), .o_bit(o_bit), .busy(busy), .done(done));

  integer fi, fo, ncase, c, i, rc, a, b, cyc, nb, got_done;
  reg [7:0] mem [0:1023];
  reg [15:0] lfsr = 16'hACE1;

  // Output bits are sampled on the edge where o_valid && o_ready.
  task tick; begin
    #5 clk = 1;
    if (o_valid && o_ready) $fdisplay(fo, "%0d", o_bit);
    if (in_valid && in_ready) nb = nb + 1;
    if (done) got_done = 1;
    #1;
    lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    o_ready = lfsr[0] | lfsr[3];
    in_valid = (nb < len) && (lfsr[5] | lfsr[7]);
    in_byte = mem[nb];
    #4 clk = 0;
    cyc = cyc + 1;
  end endtask

  initial begin
    fi = $fopen("stim.txt", "r");
    fo = $fopen("out.txt", "w");
    rc = $fscanf(fi, "%d\n", ncase);
    for (c = 0; c < ncase; c = c + 1) begin
      rc = $fscanf(fi, "%d %d %d %d\n", a, b, nbits, len);
      seed = a; rate = b;
      for (i = 0; i < len; i = i + 1) rc = $fscanf(fi, "%h\n", mem[i]);
      nb = 0; got_done = 0; cyc = 0;
      in_valid = 0; o_ready = 0;
      #1 start = 1; tick; start = 0;
      while (!got_done && cyc < 400000) tick;
      $fdisplay(fo, "E %0d", cyc);
      tick; tick;
    end
    $fclose(fo);
    $finish;
  end
endmodule
