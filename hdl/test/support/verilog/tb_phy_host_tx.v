// MimoHalow.Hw.PhyHost transmit bench, digital loopback: data_clk 32 MHz
// with `tick` every 4 cycles (the TX port's 8 MS/s request), axi_clk 100 MHz.
// The TX port sample is held as in the board top (zero when idle) and fed
// back as both receive chains, one `valid` per tick. stim.txt: "<n> <ctl
// hex>", then n commands: "W <hex>" (CTRL3 write), "G" (wait for a frame:
// tx_busy up then down), "Z <ticks>" (idle). out.txt: "T <i> <q>" per TX
// sample, then "W <ring count>", "M <word2> <word3> <word4>", "R <entry>".
`timescale 1ns/1ps
module tb;
  reg dclk = 0, aclk = 0, valid = 0, ctrl3_wr = 0, tick = 0;
  reg [31:0] ctl = 0, ctrl3 = 0;
  reg [14:0] mem_raddr = 0;
  reg [11:0] hi = 0, hq = 0;
  wire [31:0] mem_rdata;
  wire o_valid, tx_busy, tx_sel, detect;
  wire [11:0] o_i, o_q;
  wire [15:0] sync_count;

  phy_host dut (.axi_clk(aclk), .data_clk(dclk), .ctl(ctl), .ctrl3(ctrl3), .ctrl3_wr(ctrl3_wr),
    .mem_raddr(mem_raddr), .mem_rdata(mem_rdata), .valid(valid), .i0(hi), .q0(hq), .i1(hi), .q1(hq),
    .tick(tick), .o_valid(o_valid), .o_i(o_i), .o_q(o_q), .tx_busy(tx_busy), .tx_sel(tx_sel),
    .detect(detect), .sync_count(sync_count));

  always #5 aclk = ~aclk;          // 100 MHz
  always #15.625 dclk = ~dclk;     // 32 MHz

  integer fo, fi, n, t, k, rc, cnt, ph, nt;
  reg [31:0] c, w;
  reg [7:0] op;
  reg [31:0] v1, v2, v3;

  // Tick / loopback on data_clk.
  initial ph = 0;
  always @(posedge dclk) begin
    if (tick) begin
      if (o_valid) begin hi <= o_i; hq <= o_q; $fdisplay(fo, "T %0d %0d", $signed(o_i), $signed(o_q)); end
      else if (!tx_busy) begin hi <= 0; hq <= 0; end
    end
    valid <= tick;
    ph <= (ph + 1) % 4;
    tick <= (ph == 3);
  end

  task aread(input [14:0] addr, output [31:0] v); begin
    @(posedge aclk); mem_raddr = addr;
    @(posedge aclk); @(posedge aclk); @(posedge aclk);
    v = mem_rdata;
  end endtask

  task awrite(input [31:0] v); begin
    @(posedge aclk); #1 ctrl3 = v; ctrl3_wr = 1;
    @(posedge aclk); #1 ctrl3_wr = 0;
    @(posedge aclk); @(posedge aclk);
  end endtask

  initial begin
    fi = $fopen("stim.txt", "r");
    fo = $fopen("out.txt", "w");
    rc = $fscanf(fi, "%d %h\n", n, c);
    repeat (4) @(posedge dclk);
    ctl = c;
    for (t = 0; t < n; t = t + 1) begin
      rc = $fscanf(fi, "%s", op);
      if (op == "W") begin rc = $fscanf(fi, "%h\n", w); awrite(w); end
      else if (op == "G") begin
        k = 0;
        while (!tx_busy && k < 100000) begin @(posedge dclk); k = k + 1; end
        while (tx_busy) @(posedge dclk);
      end
      else begin rc = $fscanf(fi, "%d\n", nt); repeat (4 * nt) @(posedge dclk); end
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
