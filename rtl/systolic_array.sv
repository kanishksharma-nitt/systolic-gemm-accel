// N x N weight-stationary systolic array computing C = A x B, INT8 in /
// INT32 accumulate.
//
// B[r][c] is preloaded into PE(r,c) (one row of B per w_load cycle). A rows
// then stream in from the left: row r of the array receives A[m][r] delayed
// by r cycles (skew registers), so the partial products for output row m
// line up as the partial sum cascades down each column. The bottom of
// column c emits C[m][c] = sum_k A[m][k]*B[k][c] exactly N+c cycles after
// A row m was presented at the input.
`default_nettype none

module systolic_array #(
    parameter N = 4
) (
    input  wire              clk,
    input  wire              rst_n,
    // weight load: one row of B per cycle while w_load is high
    input  wire              w_load,
    input  wire [1:0]        w_row,
    input  wire [8*N-1:0]    w_flat,    // byte c = B[w_row][c]
    // activation stream: one row of A per cycle while in_valid is high
    input  wire              in_valid,
    input  wire [8*N-1:0]    a_flat,    // byte k = A[m][k]
    // column results (column c lags column 0 by c cycles)
    output wire [32*N-1:0]   col_psum,  // word c = C[m][c] when col_valid[c]
    output wire [N-1:0]      col_valid
);

  genvar r, c;
  integer i;

  // ------------------------------------------------------------------
  // Input skew: skew[k] is a_flat delayed k+1 cycles. Row r>0 taps its
  // activation byte from skew[r-1], row 0 takes it combinationally.
  // ------------------------------------------------------------------
  reg [8*N-1:0] skew [0:N-1];

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (i = 0; i < N; i = i + 1) skew[i] <= {8*N{1'b0}};
    end else begin
      skew[0] <= a_flat;
      for (i = 1; i < N; i = i + 1) skew[i] <= skew[i-1];
    end
  end

  // valid pipeline: column c result is valid N+c cycles after in_valid
  reg [2*N-1:0] vpipe;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) vpipe <= {2*N{1'b0}};
    else        vpipe <= {vpipe[2*N-2:0], in_valid};
  end

  // ------------------------------------------------------------------
  // PE mesh. a_h[r][c] feeds PE(r,c) from the left, ps_v[r][c] from above.
  // ------------------------------------------------------------------
  wire signed [7:0]  a_h  [0:N-1][0:N];
  wire signed [31:0] ps_v [0:N][0:N-1];

  generate
    for (r = 0; r < N; r = r + 1) begin : g_row
      if (r == 0) assign a_h[r][0] = a_flat[7:0];
      else        assign a_h[r][0] = skew[r-1][8*r +: 8];

      for (c = 0; c < N; c = c + 1) begin : g_col
        if (r == 0) assign ps_v[0][c] = 32'sd0;

        // PE(r,c) computes on the wavefront delayed r+c cycles from in_valid,
        // the same alignment as its activation (r skew stages + c horizontal
        // pipe stages), taken from the existing vpipe. VIDX folds to a legal
        // index even in the unused r+c==0 branch.
        localparam integer VIDX = (r + c == 0) ? 0 : r + c - 1;

        mac_pe u_pe (
            .clk     (clk),
            .rst_n   (rst_n),
            .w_we    (w_load && (w_row == r[1:0])),
            .w_in    (w_flat[8*c +: 8]),
            .v_en    ((r + c == 0) ? in_valid : vpipe[VIDX]),
            .a_in    (a_h[r][c]),
            .psum_in (ps_v[r][c]),
            .a_out   (a_h[r][c+1]),
            .psum_out(ps_v[r+1][c])
        );
      end
    end

    for (c = 0; c < N; c = c + 1) begin : g_out
      assign col_psum[32*c +: 32] = ps_v[N][c];
      assign col_valid[c]         = vpipe[N-1+c];
    end
  endgenerate

endmodule

`default_nettype wire
