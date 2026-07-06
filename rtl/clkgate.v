// Behavioral integrated-clock-gate (ICG): transparent-low latch + AND. The
// latch lets the enable propagate only while the clock is low, so the gate
// never clips or glitches a high phase (the testbench checks en_l is stable
// while clk is high). In its own file so a synthesis flow can swap in the
// library ICG cell (e.g. sky130_fd_sc_hd__dlclkp) instead of inferring a latch.
`default_nettype none

module clkgate (
    input  wire clk,
    input  wire en,
    output wire gclk
);

  reg en_l;

  always @(clk or en)
    if (!clk) en_l = en;     // latch, transparent while clk low
                             // (blocking assign: level-sensitive latch idiom)

  assign gclk = clk & en_l;

endmodule

`default_nettype wire
