// Self-checking testbench for the INT8 systolic GEMM accelerator.
//
// Walks test/cases.mem (written by python/gemm_golden.py): for each case it
// programs the registers over AXI4-Lite, loads B and A through the buffer
// windows, starts the accelerator, polls STATUS until done, reads back C and
// compares every row word against the golden expectation.
`timescale 1ns / 1ps
`default_nettype none

module tb_accel;

  localparam CLK_PERIOD = 10;

  // register map
  localparam [11:0] A_CTRL   = 12'h000;
  localparam [11:0] A_STATUS = 12'h004;
  localparam [11:0] A_M      = 12'h008;
  localparam [11:0] A_SCALE  = 12'h00C;
  localparam [11:0] A_SHIFT  = 12'h010;
  localparam [11:0] A_CFG    = 12'h014;
  localparam [11:0] A_BBUF   = 12'h100;
  localparam [11:0] A_ABUF   = 12'h200;
  localparam [11:0] A_CBUF   = 12'h400;

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

  integer errors = 0;
  integer idx = 0;
  integer ncases, ci, m_rows, scale, shft, relu, m, t;
  reg [31:0] vec [0:2047];
  reg [31:0] got, exp;

  accel_top dut (
      .clk            (clk),
      .rst_n          (rst_n),
      .s_axil_awaddr  (awaddr),
      .s_axil_awvalid (awvalid),
      .s_axil_awready (awready),
      .s_axil_wdata   (wdata),
      .s_axil_wstrb   (wstrb),
      .s_axil_wvalid  (wvalid),
      .s_axil_wready  (wready),
      .s_axil_bresp   (bresp),
      .s_axil_bvalid  (bvalid),
      .s_axil_bready  (bready),
      .s_axil_araddr  (araddr),
      .s_axil_arvalid (arvalid),
      .s_axil_arready (arready),
      .s_axil_rdata   (rdata),
      .s_axil_rresp   (rresp),
      .s_axil_rvalid  (rvalid),
      .s_axil_rready  (rready),
      .irq            (irq)
  );

  always #(CLK_PERIOD / 2) clk = ~clk;

  // ------------------------------------------------------------------
  // Low-power safety nets (behavioral ICG properties):
  //  - a gate enable may only move while the clock is low (latch
  //    transparency window), so the AND can never clip a high phase
  //  - a gated-clock rising edge must coincide with a clk rising edge
  // Data integrity across gating is proven by the unchanged bit-exact
  // compare below.
  // ------------------------------------------------------------------
  always @(dut.u_cg_array.en_l or dut.u_cg_req.en_l) begin
    if (rst_n && clk !== 1'b0) begin
      errors = errors + 1;
      $display("FAIL: ICG enable moved while clk high at %0t", $time);
    end
  end

  always @(posedge dut.gclk_array or posedge dut.gclk_req) begin
    if (rst_n && clk !== 1'b1) begin
      errors = errors + 1;
      $display("FAIL: gated-clock edge without clk edge at %0t", $time);
    end
  end

  // ------------------------------------------------------------------
  // Minimal AXI4-Lite BFM: drive on negedge, sample handshakes on posedge.
  // ------------------------------------------------------------------
  task axil_write(input [11:0] addr, input [31:0] data);
    begin
      @(negedge clk);
      awaddr  = addr;
      awvalid = 1'b1;
      wdata   = data;
      wstrb   = 4'hF;
      wvalid  = 1'b1;
      @(posedge clk);
      while (!(awready && wready)) @(posedge clk);
      @(negedge clk);
      awvalid = 1'b0;
      wvalid  = 1'b0;
      while (!bvalid) @(posedge clk);
      @(posedge clk);  // let BVALID clear (BREADY held high)
    end
  endtask

  task axil_read(input [11:0] addr, output [31:0] data);
    begin
      @(negedge clk);
      araddr  = addr;
      arvalid = 1'b1;
      @(posedge clk);
      while (!arready) @(posedge clk);
      @(negedge clk);
      arvalid = 1'b0;
      while (!rvalid) @(posedge clk);
      data = rdata;
      @(posedge clk);  // let RVALID clear (RREADY held high)
    end
  endtask

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("tb_accel.vcd");
      $dumpvars(0, tb_accel);
    end

    $readmemh("../test/cases.mem", vec);

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    // register write/read sanity check
    axil_write(A_M, 32'd5);
    axil_read(A_M, got);
    if (got !== 32'd5) begin
      errors = errors + 1;
      $display("FAIL: M register readback got %0d expected 5", got);
    end

    ncases = vec[0];
    idx = 1;
    $display("running %0d cases", ncases);

    for (ci = 0; ci < ncases; ci = ci + 1) begin
      m_rows = vec[idx];
      scale  = vec[idx+1];
      shft   = vec[idx+2];
      relu   = vec[idx+3];
      idx    = idx + 4;

      axil_write(A_M,     m_rows);
      axil_write(A_SCALE, scale);
      axil_write(A_SHIFT, shft);
      axil_write(A_CFG,   relu);

      for (m = 0; m < 4; m = m + 1)
        axil_write(A_BBUF + 4*m, vec[idx + m]);
      idx = idx + 4;

      for (m = 0; m < m_rows; m = m + 1)
        axil_write(A_ABUF + 4*m, vec[idx + m]);
      idx = idx + m_rows;

      axil_write(A_CTRL, 32'd1);

      // poll STATUS.done with a timeout
      got = 32'd0;
      t = 0;
      while (!got[0] && t < 300) begin
        axil_read(A_STATUS, got);
        t = t + 1;
      end
      if (!got[0]) begin
        errors = errors + 1;
        $display("FAIL: case %0d timed out waiting for done", ci);
      end

      for (m = 0; m < m_rows; m = m + 1) begin
        axil_read(A_CBUF + 4*m, got);
        exp = vec[idx + m];
        if (got !== exp) begin
          errors = errors + 1;
          if (errors < 20)
            $display("FAIL: case %0d C row %0d got %08x expected %08x",
                     ci, m, got, exp);
        end
      end
      idx = idx + m_rows;
      $display("case %0d: M=%0d done in %0d polls, %0d total errors",
               ci, m_rows, t, errors);
    end

    if (errors == 0) $display("TEST PASSED");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  // global watchdog
  initial begin
    #5_000_000;
    $display("TEST FAILED: global timeout");
    $finish;
  end

endmodule

`default_nettype wire
