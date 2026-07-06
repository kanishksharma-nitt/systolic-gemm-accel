// INT32 -> INT8 requantization: multiply by a per-tensor scale, arithmetic
// right shift, optional ReLU, saturate to [-128, 127]. One registered stage.
//
// q = sat8( relu?( (acc * scale) >>> shift ) )
//
// The golden model (python/gemm_golden.py) implements the identical integer
// arithmetic: Python's >> on ints is an arithmetic (floor) shift, matching
// Verilog >>> on a signed value.
`default_nettype none

module requant (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               in_valid,
    input  wire signed [31:0] acc,
    input  wire [15:0]        scale,     // unsigned multiplier
    input  wire [4:0]         shift,     // arithmetic right shift 0..31
    input  wire               relu_en,
    output reg                out_valid,
    output reg  signed [7:0]  q
);

  wire signed [47:0] prod      = acc * $signed({1'b0, scale});
  wire signed [47:0] shifted   = prod >>> shift;
  wire signed [47:0] rectified = (relu_en && shifted < 0) ? 48'sd0 : shifted;
  wire signed [7:0]  sat       = (rectified > 48'sd127)  ? 8'sd127  :
                                 (rectified < -48'sd128) ? -8'sd128 :
                                 rectified[7:0];

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid <= 1'b0;
      q         <= 8'sd0;
    end else begin
      out_valid <= in_valid;
      q         <= sat;
    end
  end

endmodule

`default_nettype wire
