// AXI4-Lite register block.
//
// The AXI4-Lite protocol handling is alexforencich's `axil_reg_if`
// (verilog-axi, MIT, vendored under rtl/third_party/). The design-specific
// logic here is the register-map decode, the buffer windows, and the
// start/done handling.
//
// Register map (byte addresses, 32-bit registers, full-word writes assumed):
//   0x000  CTRL    W   bit0: start (self-clearing pulse)
//   0x004  STATUS  R   bit0: done (sticky, cleared by start), bit1: busy
//   0x008  M       RW  number of A rows, 1..MAX_M
//   0x00C  SCALE   RW  requant multiplier, unsigned 16-bit
//   0x010  SHIFT   RW  requant arithmetic right shift, 0..31
//   0x014  CFG     RW  bit0: relu_en, bit1: irq_en
//   0x100  +4*r    W   B row r  = {B[r][3], B[r][2], B[r][1], B[r][0]}
//   0x200  +4*m    W   A row m  = {A[m][3], A[m][2], A[m][1], A[m][0]}
//   0x400  +4*m    R   C row m  = {C[m][3], C[m][2], C[m][1], C[m][0]}
`default_nettype none

module axil_regs (
    input  wire        clk,
    input  wire        rst_n,
    // AXI4-Lite slave
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
    // control / status
    output reg         start,       // 1-cycle pulse
    output reg  [6:0]  m_rows,
    output reg  [15:0] scale,
    output reg  [4:0]  shift,
    output reg         relu_en,
    output wire        irq,
    input  wire        busy,
    input  wire        done_set,    // pulse from the core FSM
    // buffer write ports
    output reg         wbuf_we,
    output reg  [1:0]  wbuf_addr,
    output reg         abuf_we,
    output reg  [5:0]  abuf_addr,
    output reg  [31:0] buf_wdata,
    // result buffer read port (asynchronous read in accel_top)
    output wire [5:0]  cbuf_addr,
    input  wire [31:0] cbuf_rdata
);

  reg done;
  reg irq_en;

  assign irq = done && irq_en;

  // ------------------------------------------------------------------
  // AXI4-Lite protocol handling: vendored third-party core. Single-cycle
  // register operations: ack is tied to en, wait states unused.
  // ------------------------------------------------------------------
  wire [11:0] wr_addr, rd_addr;
  wire [31:0] wr_data;
  wire [3:0]  wr_strb;
  wire        wr_en, rd_en;
  reg  [31:0] rd_data;

  axil_reg_if #(
      .DATA_WIDTH(32),
      .ADDR_WIDTH(12),
      .TIMEOUT(4)
  ) u_reg_if (
      .clk(clk),
      .rst(!rst_n),
      .s_axil_awaddr (s_axil_awaddr),
      .s_axil_awprot (3'b000),
      .s_axil_awvalid(s_axil_awvalid),
      .s_axil_awready(s_axil_awready),
      .s_axil_wdata  (s_axil_wdata),
      .s_axil_wstrb  (s_axil_wstrb),
      .s_axil_wvalid (s_axil_wvalid),
      .s_axil_wready (s_axil_wready),
      .s_axil_bresp  (s_axil_bresp),
      .s_axil_bvalid (s_axil_bvalid),
      .s_axil_bready (s_axil_bready),
      .s_axil_araddr (s_axil_araddr),
      .s_axil_arprot (3'b000),
      .s_axil_arvalid(s_axil_arvalid),
      .s_axil_arready(s_axil_arready),
      .s_axil_rdata  (s_axil_rdata),
      .s_axil_rresp  (s_axil_rresp),
      .s_axil_rvalid (s_axil_rvalid),
      .s_axil_rready (s_axil_rready),
      .reg_wr_addr   (wr_addr),
      .reg_wr_data   (wr_data),
      .reg_wr_strb   (wr_strb),
      .reg_wr_en     (wr_en),
      .reg_wr_wait   (1'b0),
      .reg_wr_ack    (wr_en),
      .reg_rd_addr   (rd_addr),
      .reg_rd_en     (rd_en),
      .reg_rd_data   (rd_data),
      .reg_rd_wait   (1'b0),
      .reg_rd_ack    (rd_en)
  );

  // ------------------------------------------------------------------
  // Register-map decode (the design-specific part)
  // ------------------------------------------------------------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      start     <= 1'b0;
      m_rows    <= 7'd4;
      scale     <= 16'd1;
      shift     <= 5'd0;
      relu_en   <= 1'b0;
      irq_en    <= 1'b0;
      done      <= 1'b0;
      wbuf_we   <= 1'b0;
      wbuf_addr <= 2'd0;
      abuf_we   <= 1'b0;
      abuf_addr <= 6'd0;
      buf_wdata <= 32'd0;
    end else begin
      start   <= 1'b0;
      wbuf_we <= 1'b0;
      abuf_we <= 1'b0;

      if (done_set) done <= 1'b1;

      if (wr_en) begin
        buf_wdata <= wr_data;
        case (wr_addr[11:8])
          4'h0: begin
            case (wr_addr[4:2])
              3'd0: begin                       // CTRL
                if (wr_data[0]) begin
                  start <= 1'b1;
                  done  <= 1'b0;
                end
              end
              3'd2: m_rows <= wr_data[6:0];     // M
              3'd3: scale  <= wr_data[15:0];
              3'd4: shift  <= wr_data[4:0];
              3'd5: begin                       // CFG
                relu_en <= wr_data[0];
                irq_en  <= wr_data[1];
              end
              default: ;                        // STATUS is read-only
            endcase
          end
          4'h1: begin                           // B window
            wbuf_we   <= 1'b1;
            wbuf_addr <= wr_addr[3:2];
          end
          4'h2: begin                           // A window
            abuf_we   <= 1'b1;
            abuf_addr <= wr_addr[7:2];
          end
          default: ;                            // unmapped: OKAY, no effect
        endcase
      end
    end
  end

  // read mux (combinational; rd_addr is held stable while rd_en is up)
  assign cbuf_addr = rd_addr[7:2];

  always @* begin
    case (rd_addr[11:8])
      4'h0: begin
        case (rd_addr[4:2])
          3'd1: rd_data = {30'd0, busy, done};
          3'd2: rd_data = {25'd0, m_rows};
          3'd3: rd_data = {16'd0, scale};
          3'd4: rd_data = {27'd0, shift};
          3'd5: rd_data = {30'd0, irq_en, relu_en};
          default: rd_data = 32'd0;
        endcase
      end
      4'h4: rd_data = cbuf_rdata;               // C window
      default: rd_data = 32'd0;
    endcase
  end

  wire _unused = &{1'b0, wr_strb, wr_addr[7:5], wr_addr[1:0],
                   rd_addr[1:0], rd_en};

endmodule

`default_nettype wire
