// MimoHalow.Hw.PhyHost bench: data_clk 32 MHz (one 8 MS/s frame per 4
// cycles), axi_clk 100 MHz. stim.txt: "<n> <ctl hex>", then n lines
// "<i0> <q0> <i1> <q1>" (hex12). After the stimulus the axi side reads the
// window: "W <word1>" (write count), "M <word2> <word3> <word4>", then
// "R <entry hex>" for every ring entry 0 .. count-1.
`timescale 1ns/1ps
module tb;
  reg dclk = 0, aclk = 0, valid = 0, ctrl3_wr = 0, tick = 0;
  reg [31:0] ctl = 0, ctrl3 = 0;
  reg [14:0] mem_raddr = 0;
  reg [11:0] i0 = 0, q0 = 0, i1 = 0, q1 = 0;
  wire [31:0] mem_rdata;
  wire o_valid, tx_busy, tx_sel, detect;
  wire [11:0] o_i, o_q;
  wire [15:0] sync_count;

  phy_host dut (.axi_clk(aclk), .data_clk(dclk), .ctl(ctl), .ctrl3(ctrl3), .ctrl3_wr(ctrl3_wr),
    .mem_raddr(mem_raddr), .mem_rdata(mem_rdata), .valid(valid), .i0(i0), .q0(q0), .i1(i1), .q1(q1),
    .tick(tick), .o_valid(o_valid), .o_i(o_i), .o_q(o_q), .tx_busy(tx_busy), .tx_sel(tx_sel),
    .detect(detect), .sync_count(sync_count));

  always #5 aclk = ~aclk;          // 100 MHz
  always #15.625 dclk = ~dclk;     // 32 MHz

  integer fi, fo, n, t, k, rc, cnt;
  reg [31:0] c;
  reg [11:0] a, b, e, d;

  task aread(input [14:0] addr, output [31:0] v); begin
    @(posedge aclk); mem_raddr = addr;
    @(posedge aclk); @(posedge aclk); @(posedge aclk);
    v = mem_rdata;
  end endtask

  reg [31:0] v1, v2, v3;
  initial begin
    fi = $fopen("stim.txt", "r");
    fo = $fopen("out.txt", "w");
    rc = $fscanf(fi, "%d %h\n", n, c);
    repeat (4) @(posedge dclk);
    ctl = c;
    repeat (8) @(posedge dclk);
    for (t = 0; t < n; t = t + 1) begin
      rc = $fscanf(fi, "%h %h %h %h\n", a, b, e, d);
      @(negedge dclk); i0 = a; q0 = b; i1 = e; q1 = d; valid = 1;
      @(negedge dclk); valid = 0;
      @(negedge dclk); @(negedge dclk);
    end
    repeat (20000) @(posedge dclk);
    aread(15'd1, v1); cnt = v1[15:0];
    $fdisplay(fo, "W %0d", cnt);
    aread(15'd2, v1); aread(15'd3, v2); aread(15'd4, v3);
    $fdisplay(fo, "M %h %h %h", v1, v2, v3);
    for (k = 0; k < cnt; k = k + 1) begin
      aread(15'd2048 + k, v1);
      $fdisplay(fo, "R %h", v1);
    end
    $fclose(fo);
    $finish;
  end
endmodule
