// MimoHalow.Hw.Tx.VPrecoder co-simulation bench. stim.txt: "<nv>", nv lines
// "<addr> <data hex64>" (table writes), then "<n>", n lines
// "<bin> <i hex16> <q hex16> <last>". The sink drops ready pseudo-randomly.
// out.txt: per accepted output beat "<bin> <ant> <i hex> <q hex> <last>".
`timescale 1ns/1ps
module tb;
  reg clk = 0, enable = 0, s_valid = 0, s_last = 0, o_ready = 0, v_we = 0;
  reg [15:0] s_i = 0, s_q = 0;
  reg [5:0] s_bin = 0, v_addr = 0;
  reg [63:0] v_data = 0;
  wire s_ready, o_valid, o_ant, o_last;
  wire [15:0] o_i, o_q;
  wire [5:0] o_bin;

  v_precoder dut (.clk(clk), .enable(enable), .s_valid(s_valid), .s_i(s_i), .s_q(s_q), .s_bin(s_bin),
    .s_stream(1'b0), .s_last(s_last), .s_ready(s_ready), .o_ready(o_ready), .o_valid(o_valid),
    .o_i(o_i), .o_q(o_q), .o_bin(o_bin), .o_ant(o_ant), .o_last(o_last),
    .v_we(v_we), .v_addr(v_addr), .v_data(v_data));

  integer fi, fo, n, t, k, rc, b, l, seed;
  reg [15:0] a, c;
  reg [63:0] d;
  reg took;

  // Sample handshakes just before the rising edge, then clock.
  task tick; begin
    #4;
    if (o_valid && o_ready) $fdisplay(fo, "%0d %0d %h %h %0d", o_bin, o_ant, o_i, o_q, o_last);
    took = s_valid && s_ready;
    #1 clk = 1; #5 clk = 0;
    o_ready = ($random(seed) & 3) != 0;
  end endtask

  initial begin
    seed = 7;
    fi = $fopen("stim.txt", "r");
    fo = $fopen("out.txt", "w");
    rc = $fscanf(fi, "%d\n", n);
    for (t = 0; t < n; t = t + 1) begin
      rc = $fscanf(fi, "%d %h\n", b, d);
      v_we = 1; v_addr = b; v_data = d;
      tick;
    end
    v_we = 0;
    enable = 1;
    rc = $fscanf(fi, "%d\n", n);
    for (t = 0; t < n; t = t + 1) begin
      rc = $fscanf(fi, "%d %h %h %d\n", b, a, c, l);
      s_bin = b; s_i = a; s_q = c; s_last = l; s_valid = 1;
      took = 0;
      while (!took) tick;
      s_valid = 0;
      if (($random(seed) & 1) == 0) tick;
    end
    for (k = 0; k < 40; k = k + 1) tick;
    $fclose(fo);
    $finish;
  end
endmodule
