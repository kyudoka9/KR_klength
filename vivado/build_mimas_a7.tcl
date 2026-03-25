# ================================================================================ #
# KR RISC-V Scientific Coprocessor — Vivado Build Script                           #
# Numato Mimas A7 V2.0 — XC7A50T-1FGG484                                          #
#                                                                                  #
# Usage: vivado -mode batch -source build_mimas_a7.tcl                             #
#   or:  vivado -mode tcl -source build_mimas_a7.tcl                               #
#                                                                                  #
# Copyright 2026 Kyudoka Research, H. Ismail <ismh@kyudoka.org>                    #
# ================================================================================ #

# Paths (relative to this script's directory)
set script_dir [file dirname [file normalize [info script]]]
set proj_dir   [file normalize "$script_dir/.."]
set neorv32_rtl "$proj_dir/neorv32/rtl/core"
set kr_rtl      "$proj_dir/rtl"
set constraints "$proj_dir/constraints"
set output_dir  "$proj_dir/vivado/output"

# Create output directory
file mkdir $output_dir

# ============================================================================
# Create project
# ============================================================================
create_project kr_riscv_mimas_a7 "$output_dir/kr_riscv_mimas_a7" -part xc7a50tfgg484-1 -force

set_property target_language VHDL [current_project]

# ============================================================================
# Add NEORV32 core sources (VHDL library: neorv32)
# ============================================================================
# Read the file list and add all core VHDL files
set neorv32_files [glob -directory $neorv32_rtl *.vhd]
add_files -norecurse $neorv32_files
set_property library neorv32 [get_files -filter {FILE_TYPE == VHDL && NAME =~ "*/neorv32/rtl/core/*"}]

# ============================================================================
# Replace the default CFU with our bignum CFU
# ============================================================================
# Remove the default XTEA CFU from the project
remove_files [get_files -quiet "*/neorv32_cpu_alu_cfu.vhd"]

# Add our bignum CFU (same entity name, drop-in replacement)
add_files -norecurse "$kr_rtl/kr_bignum_cfu.vhd"
set_property library neorv32 [get_files "*/kr_bignum_cfu.vhd"]

# ============================================================================
# Add board-level top module
# ============================================================================
add_files -norecurse "$kr_rtl/kr_neorv32_mimas_a7.vhd"
# Top module uses default library (work), references neorv32 library

# ============================================================================
# Add constraints
# ============================================================================
add_files -fileset constrs_1 -norecurse "$constraints/mimas_a7.xdc"

# ============================================================================
# Set top module
# ============================================================================
set_property top kr_neorv32_mimas_a7 [current_fileset]

# ============================================================================
# Synthesis settings
# ============================================================================
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} -value {-retiming} -objects [get_runs synth_1]
set_property strategy Flow_PerfOptimized_high [get_runs synth_1]

# ============================================================================
# Implementation settings
# ============================================================================
set_property strategy Performance_ExploreWithRemap [get_runs impl_1]

# ============================================================================
# Run synthesis
# ============================================================================
puts "================================================================"
puts " KR RISC-V: Starting synthesis..."
puts "================================================================"
launch_runs synth_1 -jobs [exec nproc]
wait_on_run synth_1

# Check synthesis status
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERROR: Synthesis failed!"
    exit 1
}
puts "Synthesis complete."

# ============================================================================
# Run implementation (place & route)
# ============================================================================
puts "================================================================"
puts " KR RISC-V: Starting implementation..."
puts "================================================================"
launch_runs impl_1 -jobs [exec nproc]
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: Implementation failed!"
    exit 1
}
puts "Implementation complete."

# ============================================================================
# Generate bitstream
# ============================================================================
puts "================================================================"
puts " KR RISC-V: Generating bitstream..."
puts "================================================================"
launch_runs impl_1 -to_step write_bitstream -jobs [exec nproc]
wait_on_run impl_1

puts "================================================================"
puts " KR RISC-V: Build complete!"
puts " Bitstream: $output_dir/kr_riscv_mimas_a7/kr_riscv_mimas_a7.runs/impl_1/kr_neorv32_mimas_a7.bit"
puts "================================================================"

# ============================================================================
# Report utilization
# ============================================================================
open_run impl_1
report_utilization -file "$output_dir/utilization_report.txt"
report_timing_summary -file "$output_dir/timing_report.txt"

puts "\nUtilization summary:"
report_utilization -hierarchical -hierarchical_depth 2

# Close project
close_project
