@echo off
ghdl -a --std=08 pkg.vhd
ghdl -a --std=08 memories.vhd
ghdl -a --std=08 arf.vhd
ghdl -a --std=08 branch_predictor.vhd
ghdl -a --std=08 fetch_unit.vhd
ghdl -a --std=08 decoder.vhd
ghdl -a --std=08 intra_dep_checker.vhd
ghdl -a --std=08 rename_dispatch.vhd
ghdl -a --std=08 reservation_station.vhd
ghdl -a --std=08 execute_alu.vhd
ghdl -a --std=08 rob.vhd
ghdl -a --std=08 store_buffer.vhd
ghdl -a --std=08 retire_unit.vhd
ghdl -a --std=08 superscalar_top.vhd
ghdl -a --std=08 tb_instr.vhd
ghdl -e --std=08 tb_instr
ghdl -r --std=08 tb_instr --wave=wave.ghw
echo.
echo === Open wave.ghw in GTKWave to view signals ===
