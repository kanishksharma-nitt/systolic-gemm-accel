// Weight-stationary processing element: holds one INT8 weight, multiplies the
// activation flowing in from the left, adds the product to the partial sum
// flowing down from above. Both outputs are registered (one pipeline stage).
`default_nettype none

module mac_pe (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               w_we,      // capture w_in into the weight register
    input  wire signed [7:0]  w_in,
    input  wire               v_en,      // this cycle's activation is valid
    input  wire signed [7:0]  a_in,      // activation from the PE on the left
    input  wire signed [31:0] psum_in,   // partial sum from the PE above
    output reg  signed [7:0]  a_out,     // to the PE on the right
    output reg  signed [31:0] psum_out   // to the PE below
);

  reg signed [7:0] w_q;

  // Operand isolation study (low-power retrofit): zero the multiplier input on
  // invalid wavefronts. This measured negative here (+2.9% toggles): after the
  // hierarchical clock gating, the garbage operands are already static, so the
  // isolation muxes only add window-boundary transitions. Kept as an opt-in
  // (-DLP_OPERAND_ISOLATION) with the same nets either way, so the A/B VCD
  // comparison counts an identical net set. The bit-exact regression holds in
  // both configs (an invalid wavefront's psum is never sampled).
`ifdef LP_OPERAND_ISOLATION
  wire signed [7:0]  a_use = v_en ? a_in : 8'sd0;
`else
  wire signed [7:0]  a_use = a_in;
  wire               _v_unused = v_en;
`endif
  wire signed [15:0] prod  = a_use * w_q;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      w_q      <= 8'sd0;
      a_out    <= 8'sd0;
      psum_out <= 32'sd0;
    end else begin
      if (w_we) w_q <= w_in;
      a_out    <= a_in;
      psum_out <= psum_in + {{16{prod[15]}}, prod};
    end
  end

endmodule

`default_nettype wire
