# OpenSTA switching-activity power report.
#
# Accuracy note (be honest about this in interviews): the activity comes
# from an RTL simulation VCD mapped onto the netlist by name, not from a
# gate-level simulation -- post-synthesis nets that don't exist in RTL
# (decomposed logic) fall back to the default activity, so absolute
# numbers are estimates; *relative* baseline-vs-optimized comparisons on
# the same flow are meaningful, and the pure-RTL toggle comparison
# (scripts/toggle_count.py) is the tool-independent cross-check.
#
# Run: sta flow/power.tcl   (after yosys flow/synth.ys and a tb_power run)

read_liberty flow/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
read_verilog flow/netlist.v
link_design accel_top

create_clock -name clk -period 10 [get_ports clk]
set_input_delay  1 -clock clk [all_inputs]
set_output_delay 1 -clock clk [all_outputs]

read_vcd -scope tb_power/dut sim/power.vcd

report_power
report_power -hierarchy
