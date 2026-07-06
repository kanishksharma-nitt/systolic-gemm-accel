# Targets: run (default), build, lint, golden, clean. Run from sim/.
.DEFAULT_GOAL := run

TOP    = tb_accel
VVP    = sim.vvp
PYTHON ?= python3

build:
	iverilog -g2012 -Wall -s $(TOP) -o $(VVP) -f files.f

run: build
	@out=$$(vvp $(VVP)); \
	echo "$$out"; \
	echo "$$out" | grep -q "TEST PASSED"

lint:
	verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSED \
	  lint.vlt \
	  --top-module accel_top \
	  ../rtl/third_party/verilog-axi/rtl/axil_reg_if.v \
	  ../rtl/third_party/verilog-axi/rtl/axil_reg_if_rd.v \
	  ../rtl/third_party/verilog-axi/rtl/axil_reg_if_wr.v \
	  ../rtl/clkgate.v ../rtl/mac_pe.sv ../rtl/systolic_array.sv ../rtl/requant.sv \
	  ../rtl/axil_regs.sv ../rtl/accel_top.sv

# regenerate test/cases.mem (python3, stdlib only, deterministic)
golden:
	cd .. && $(PYTHON) python/gemm_golden.py

# ------------------------- low-power measurement flow --------------------
# REPORT names the output (baseline.txt before the low-power commits,
# optimized.txt after); flow/reports/ keeps both for the comparison.
REPORT ?= baseline.txt

power:
	iverilog -g2012 -Wall -s tb_power -o power.vvp -f files_power.f
	vvp power.vvp
	mkdir -p ../flow/reports
	cd .. && $(PYTHON) scripts/toggle_count.py sim/power.vcd \
	  flow/reports/$(REPORT)

power_compare:
	cd .. && $(PYTHON) scripts/toggle_compare.py \
	  flow/reports/baseline.txt flow/reports/optimized.txt

# fetch the SkyWater liberty file for the Yosys/OpenSTA flow (Linux)
fetch_lib:
	mkdir -p ../flow/lib
	curl -L -o ../flow/lib/sky130_fd_sc_hd__tt_025C_1v80.lib \
	  https://raw.githubusercontent.com/The-OpenROAD-Project/OpenROAD-flow-scripts/master/flow/platforms/sky130hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib

clean:
	rm -f $(VVP) power.vvp *.vcd
