# ================================================================================ #
# KR k-Length Computing Platform — Vivado Build Script                             #
# Digilent Genesys 2 — XC7K325T-2FFG900C                                          #
#                                                                                  #
# Usage: vivado -mode batch -source build_genesys2.tcl                             #
#   or:  vivado -mode tcl -source build_genesys2.tcl                               #
#                                                                                  #
# Copyright 2026 Kyudoka Research, H. Ismail <ismh@kyudoka.org>                    #
# ================================================================================ #

# Paths (relative to this script's directory)
set script_dir [file dirname [file normalize [info script]]]
set proj_dir   [file normalize "$script_dir/.."]
set neorv32_rtl "$proj_dir/neorv32/rtl/core"
set kr_rtl      "$proj_dir/rtl"
set constraints "$proj_dir/constraints"
set output_dir  "$proj_dir/vivado/output/kr_klength_genesys2"

# Create output directory
file mkdir $output_dir

# ============================================================================
# Create project
# ============================================================================
create_project kr_klength_genesys2 "$output_dir" -part xc7k325tffg900-2 -force

set_property target_language VHDL [current_project]

# ============================================================================
# Add NEORV32 core sources (VHDL library: neorv32)
# ============================================================================
set neorv32_files [glob -directory $neorv32_rtl *.vhd]
add_files -norecurse $neorv32_files
set_property library neorv32 [get_files -filter {FILE_TYPE == VHDL && NAME =~ "*/neorv32/rtl/core/*"}]

# ============================================================================
# Replace the default CFU with our bignum CFU
# ============================================================================
remove_files [get_files -quiet "*/neorv32_cpu_alu_cfu.vhd"]

add_files -norecurse "$kr_rtl/kr_bignum_cfu.vhd"
set_property library neorv32 [get_files "*/kr_bignum_cfu.vhd"]

# ============================================================================
# Add KR k-Length Computing Verilog sources
# ============================================================================
set klength_v_files [glob -directory $kr_rtl kr_klength_*.v]
add_files -norecurse $klength_v_files

add_files -norecurse "$kr_rtl/kr_decomp_engine.v"

# ============================================================================
# Add Genesys 2 board-level top module
# ============================================================================
add_files -norecurse "$kr_rtl/kr_neorv32_klength_genesys2.vhd"

# ============================================================================
# Add constraints
# ============================================================================
add_files -fileset constrs_1 -norecurse "$constraints/genesys2_klength.xdc"

# ============================================================================
# Set top module
# ============================================================================
set_property top kr_neorv32_klength_genesys2 [current_fileset]

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
puts " KR k-Length: Starting synthesis (Genesys 2)..."
puts "================================================================"
launch_runs synth_1 -jobs [exec nproc]
wait_on_run synth_1

if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERROR: Synthesis failed!"
    exit 1
}
puts "Synthesis complete."

# ============================================================================
# Run implementation (place & route)
# ============================================================================
puts "================================================================"
puts " KR k-Length: Starting implementation (Genesys 2)..."
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
puts " KR k-Length: Generating bitstream (Genesys 2)..."
puts "================================================================"
launch_runs impl_1 -to_step write_bitstream -jobs [exec nproc]
wait_on_run impl_1

# ============================================================================
# Reports
# ============================================================================
open_run impl_1
report_utilization -file "$output_dir/utilization_report.txt"
report_timing_summary -file "$output_dir/timing_report.txt"

puts "\nUtilization summary:"
report_utilization -hierarchical -hierarchical_depth 2

puts "================================================================"
puts " KR k-Length: Build complete! (Genesys 2)"
puts " Bitstream: $output_dir/kr_klength_genesys2.runs/impl_1/kr_neorv32_klength_genesys2.bit"
puts "================================================================"

# Close project
close_project
