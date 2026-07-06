// INT8 systolic-array GEMM accelerator, C = A x B:
//   A: M x 4 (INT8, M up to MAX_M), B: 4 x 4 (INT8), C: M x 4 (INT8 after
//   requantize). Larger matrices are tiled in software.
//
// FSM: IDLE -> LOAD_W (4 cycles, one B row per cycle) -> STREAM (one A row
// per cycle) -> DRAIN (flush the array + requant pipeline) -> back to IDLE
// with STATUS.done set.
`default_nettype none

module accel_top #(
    parameter N     = 4,
    parameter MAX_M = 64
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [11:0] s_axil_awaddr,
    input  wire        s_axil_awvalid,
    output wire        s_axil_awready,
    input  wire [31:0] s_axil_wdata,
    input  wire [3:0]  s_axil_wstrb,
    input  wire        s_axil_wvalid,
    output wire        s_axil_wready,
    output wire [1:0]  s_axil_bresp,
    output wire        s_axil_bvalid,
    input  wire        s_axil_bready,
    input  wire [11:0] s_axil_araddr,
    input  wire        s_axil_arvalid,
    output wire        s_axil_arready,
    output wire [31:0] s_axil_rdata,
    output wire [1:0]  s_axil_rresp,
    output wire        s_axil_rvalid,
    input  wire        s_axil_rready,
    output wire        irq
);

  localparam S_IDLE   = 2'd0;
  localparam S_LOAD_W = 2'd1;
  localparam S_STREAM = 2'd2;
  localparam S_DRAIN  = 2'd3;

  localparam [31:0] W_LAST_W = N - 1;
  localparam [1:0]  W_LAST   = W_LAST_W[1:0];

  // last column result appears N+(N-1) cycles after the last A row, plus one
  // requant stage; drain a little longer for margin
  localparam DRAIN_CYC = 2*N + 4;

  // control / status / buffer wiring
  wire        start;
  wire [6:0]  m_rows;
  wire [15:0] scale;
  wire [4:0]  shift;
  wire        relu_en;
  wire        busy;
  wire        wbuf_we, abuf_we;
  wire [1:0]  wbuf_addr;
  wire [5:0]  abuf_addr;
  wire [31:0] buf_wdata;
  wire [5:0]  cbuf_addr;
  wire [31:0] cbuf_rdata;

  reg [1:0] state;
  reg [1:0] wcnt;
  reg [6:0] mcnt;
  reg [3:0] dcnt;
  reg       done_set;

  assign busy = (state != S_IDLE);

  axil_regs u_regs (
      .clk            (clk),
      .rst_n          (rst_n),
      .s_axil_awaddr  (s_axil_awaddr),
      .s_axil_awvalid (s_axil_awvalid),
      .s_axil_awready (s_axil_awready),
      .s_axil_wdata   (s_axil_wdata),
      .s_axil_wstrb   (s_axil_wstrb),
      .s_axil_wvalid  (s_axil_wvalid),
      .s_axil_wready  (s_axil_wready),
      .s_axil_bresp   (s_axil_bresp),
      .s_axil_bvalid  (s_axil_bvalid),
      .s_axil_bready  (s_axil_bready),
      .s_axil_araddr  (s_axil_araddr),
      .s_axil_arvalid (s_axil_arvalid),
      .s_axil_arready (s_axil_arready),
      .s_axil_rdata   (s_axil_rdata),
      .s_axil_rresp   (s_axil_rresp),
      .s_axil_rvalid  (s_axil_rvalid),
      .s_axil_rready  (s_axil_rready),
      .start          (start),
      .m_rows         (m_rows),
      .scale          (scale),
      .shift          (shift),
      .relu_en        (relu_en),
      .irq            (irq),
      .busy           (busy),
      .done_set       (done_set),
      .wbuf_we        (wbuf_we),
      .wbuf_addr      (wbuf_addr),
      .abuf_we        (abuf_we),
      .abuf_addr      (abuf_addr),
      .buf_wdata      (buf_wdata),
      .cbuf_addr      (cbuf_addr),
      .cbuf_rdata     (cbuf_rdata)
  );

  // ------------------------------------------------------------------
  // Weight (B) and activation (A) buffers: one 32-bit word per matrix row,
  // written through the AXI windows, read asynchronously by the FSM
  // (infers distributed RAM on FPGA).
  // ------------------------------------------------------------------
  reg [31:0] wbuf [0:N-1];
  reg [31:0] abuf [0:MAX_M-1];

  always @(posedge clk) begin
    if (wbuf_we) wbuf[wbuf_addr] <= buf_wdata;
    if (abuf_we) abuf[abuf_addr] <= buf_wdata;
  end

  // ------------------------------------------------------------------
  // Core FSM
  // ------------------------------------------------------------------
  reg           w_load;
  reg           in_valid;
  reg [8*N-1:0] w_flat;
  reg [8*N-1:0] a_flat;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state    <= S_IDLE;
      wcnt     <= 2'd0;
      mcnt     <= 7'd0;
      dcnt     <= 4'd0;
      done_set <= 1'b0;
      w_load   <= 1'b0;
      in_valid <= 1'b0;
      w_flat   <= {8*N{1'b0}};
      a_flat   <= {8*N{1'b0}};
    end else begin
      done_set <= 1'b0;
      w_load   <= 1'b0;
      in_valid <= 1'b0;

      case (state)
        S_IDLE: begin
          if (start) begin
            state <= S_LOAD_W;
            wcnt  <= 2'd0;
          end
        end

        S_LOAD_W: begin
          w_load <= 1'b1;
          w_flat <= wbuf[wcnt];
          // w_row follows wcnt one cycle late (registered together with
          // w_load/w_flat below)
          wcnt   <= wcnt + 2'd1;
          if (wcnt == W_LAST) begin
            state <= S_STREAM;
            mcnt  <= 7'd0;
          end
        end

        S_STREAM: begin
          in_valid <= 1'b1;
          a_flat   <= abuf[mcnt[5:0]];
          mcnt     <= mcnt + 7'd1;
          if (mcnt == m_rows - 7'd1) begin
            state <= S_DRAIN;
            dcnt  <= 4'd0;
          end
        end

        S_DRAIN: begin
          dcnt <= dcnt + 4'd1;
          if (dcnt == DRAIN_CYC - 1) begin
            state    <= S_IDLE;
            done_set <= 1'b1;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

  // w_row must be aligned with the registered w_load/w_flat
  reg [1:0] w_row;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) w_row <= 2'd0;
    else if (state == S_LOAD_W) w_row <= wcnt;
  end

  // ------------------------------------------------------------------
  // Hierarchical clock gating (low-power retrofit):
  //   gclk_array: the PE mesh only clocks while a job runs, so the idle gaps
  //               between jobs cost nothing
  //   gclk_req  : the requant stage + result banks only clock while column
  //               results are in flight (start included so the write pointers
  //               still reset)
  // The unchanged bit-exact regression covers functional equivalence; the ICG
  // checks in tb_accel cover glitch-freedom.
  // ------------------------------------------------------------------
  wire gclk_array, gclk_req;
  wire [N-1:0] rq_valid_w;
  wire req_busy = start || (|col_valid) || (|rq_valid_w);

  clkgate u_cg_array (.clk(clk), .en(busy),     .gclk(gclk_array));
  clkgate u_cg_req   (.clk(clk), .en(req_busy), .gclk(gclk_req));

  // ------------------------------------------------------------------
  // Array + per-column requantize + result banks
  // ------------------------------------------------------------------
  wire [32*N-1:0] col_psum;
  wire [N-1:0]    col_valid;

  systolic_array #(.N(N)) u_array (
      .clk      (gclk_array),
      .rst_n    (rst_n),
      .w_load   (w_load),
      .w_row    (w_row),
      .w_flat   (w_flat),
      .in_valid (in_valid),
      .a_flat   (a_flat),
      .col_psum (col_psum),
      .col_valid(col_valid)
  );

  // per-column requantizers; columns finish at different cycles, so each
  // byte lane of the result buffer keeps its own write pointer
  wire [N-1:0]   rq_valid;
  wire [8*N-1:0] rq_q;
  assign rq_valid_w = rq_valid;

  genvar c;
  generate
    for (c = 0; c < N; c = c + 1) begin : g_req
      // data-gating half of the operand-isolation study (opt-in; measured
      // negative on this workload, see mac_pe.sv)
`ifdef LP_OPERAND_ISOLATION
      wire signed [31:0] acc_g = col_valid[c] ? col_psum[32*c +: 32]
                                              : 32'sd0;
`else
      wire signed [31:0] acc_g = col_psum[32*c +: 32];
`endif
      requant u_requant (
          .clk      (gclk_req),
          .rst_n    (rst_n),
          .in_valid (col_valid[c]),
          .acc      (acc_g),
          .scale    (scale),
          .shift    (shift),
          .relu_en  (relu_en),
          .out_valid(rq_valid[c]),
          .q        (rq_q[8*c +: 8])
      );
    end
  endgenerate

  // result buffer: one 32-bit word per C row, byte lane c = column c
  reg [31:0] cmem [0:MAX_M-1];
  reg [5:0]  ccnt [0:N-1];
  integer k;

  always @(posedge gclk_req or negedge rst_n) begin
    if (!rst_n) begin
      for (k = 0; k < N; k = k + 1) ccnt[k] <= 6'd0;
    end else if (start) begin
      for (k = 0; k < N; k = k + 1) ccnt[k] <= 6'd0;
    end else begin
      for (k = 0; k < N; k = k + 1) begin
        if (rq_valid[k]) begin
          cmem[ccnt[k]][8*k +: 8] <= rq_q[8*k +: 8];
          ccnt[k] <= ccnt[k] + 6'd1;
        end
      end
    end
  end

  assign cbuf_rdata = cmem[cbuf_addr];

endmodule

`default_nettype wire
