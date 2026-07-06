// Power-measurement workload, not a checker (tb_accel's bit-exact regression
// covers functional correctness).
//
// Runs three M=32 GEMM jobs separated by 200-cycle idle gaps, where clock
// gating pays off, and dumps power.vcd of the whole DUT for the VCD
// toggle-count flow (scripts/toggle_count.py) and the Yosys/OpenSTA power
// flow (flow/).
`timescale 1ns / 1ps
`default_nettype none

module tb_power;

  localparam CLK_PERIOD = 10;

  reg         clk = 1'b0;
  reg         rst_n = 1'b0;
  reg  [11:0] awaddr = 12'd0;
  reg         awvalid = 1'b0;
  reg  [31:0] wdata = 32'd0;
  reg  [3:0]  wstrb = 4'd0;
  reg         wvalid = 1'b0;
  wire        awready, wready, bvalid;
  wire [1:0]  bresp;
  reg         bready = 1'b1;
  reg  [11:0] araddr = 12'd0;
  reg         arvalid = 1'b0;
  wire        arready, rvalid;
  wire [31:0] rdata;
  wire [1:0]  rresp;
  reg         rready = 1'b1;
  wire        irq;

  integer job, m, t, seed = 32'hACC0;
  reg [31:0] got;

  accel_top dut (
      .clk(clk), .rst_n(rst_n),
      .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid),
      .s_axil_awready(awready),
      .s_axil_wdata(wdata), .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid),
      .s_axil_wready(wready),
      .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
      .s_axil_araddr(araddr), .s_axil_arvalid(arvalid),
      .s_axil_arready(arready),
      .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid),
      .s_axil_rready(rready),
      .irq(irq));

  always #(CLK_PERIOD / 2) clk = ~clk;

  task axil_write(input [11:0] addr, input [31:0] data);
    begin
      @(negedge clk);
      awaddr = addr; awvalid = 1; wdata = data; wstrb = 4'hF; wvalid = 1;
      @(posedge clk);
      while (!(awready && wready)) @(posedge clk);
      @(negedge clk);
      awvalid = 0; wvalid = 0;
      while (!bvalid) @(posedge clk);
      @(posedge clk);
    end
  endtask

  task axil_read(input [11:0] addr, output [31:0] data);
    begin
      @(negedge clk);
      araddr = addr; arvalid = 1;
      @(posedge clk);
      while (!arready) @(posedge clk);
      @(negedge clk);
      arvalid = 0;
      while (!rvalid) @(posedge clk);
      data = rdata;
      @(posedge clk);
    end
  endtask

  initial begin
    $dumpfile("power.vcd");
    $dumpvars(0, dut);

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    axil_write(12'h008, 32'd32);      // M
    axil_write(12'h00C, 32'd127);     // SCALE
    axil_write(12'h010, 32'd16);      // SHIFT
    axil_write(12'h014, 32'd0);       // CFG

    for (job = 0; job < 3; job = job + 1) begin
      for (m = 0; m < 4; m = m + 1)
        axil_write(12'h100 + 4*m, $random(seed));
      for (m = 0; m < 32; m = m + 1)
        axil_write(12'h200 + 4*m, $random(seed));
      axil_write(12'h000, 32'd1);     // start

      got = 0;
      t = 0;
      while (!got[0] && t < 300) begin
        axil_read(12'h004, got);
        t = t + 1;
      end
      if (!got[0]) $display("WORKLOAD ERROR: job %0d never finished", job);
      else         $display("job %0d done", job);

      repeat (200) @(posedge clk);    // idle gap: the clock-gating target
    end

    $display("WORKLOAD DONE");
    $finish;
  end

  initial begin
    #2_000_000;
    $display("WORKLOAD ERROR: timeout");
    $finish;
  end

endmodule

`default_nettype wire
