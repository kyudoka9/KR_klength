# Copyright 2026 Kyudoka Research, H. Ismail <ismh@kyudoka.org>
# KR RISC-V Scientific Coprocessor — Pin Assignments
# Numato Mimas A7 V2.0 — XC7A50T-1FGG484

# Configuration
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]

# 100 MHz oscillator
set_property -dict {PACKAGE_PIN H4 IOSTANDARD LVCMOS33} [get_ports clk_100mhz]
create_clock -period 10.000 -name sys_clk [get_ports clk_100mhz]

# UART — FT2232H Channel A (/dev/ttyUSB0)
# Verified from Mimas A7 V2.0 schematic (MimasA7.pdf sheet 8)
# WARNING: J18/H18 from deprecated XDCs are NOT valid IO pins
set_property -dict {PACKAGE_PIN Y21 IOSTANDARD LVCMOS33 SLEW FAST} [get_ports uart_tx]
set_property -dict {PACKAGE_PIN Y22 IOSTANDARD LVCMOS33}           [get_ports uart_rx]
set_false_path -from [get_ports uart_rx]
set_false_path -to [get_ports uart_tx]

# LEDs (active high)
set_property -dict {PACKAGE_PIN K17 IOSTANDARD LVCMOS33 SLEW FAST} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN J17 IOSTANDARD LVCMOS33 SLEW FAST} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN L14 IOSTANDARD LVCMOS33 SLEW FAST} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN L15 IOSTANDARD LVCMOS33 SLEW FAST} [get_ports {led[3]}]
set_property -dict {PACKAGE_PIN L16 IOSTANDARD LVCMOS33 SLEW FAST} [get_ports {led[4]}]
set_property -dict {PACKAGE_PIN K16 IOSTANDARD LVCMOS33 SLEW FAST} [get_ports {led[5]}]
set_property -dict {PACKAGE_PIN M15 IOSTANDARD LVCMOS33 SLEW FAST} [get_ports {led[6]}]
set_property -dict {PACKAGE_PIN M16 IOSTANDARD LVCMOS33 SLEW FAST} [get_ports {led[7]}]

# Push Buttons (active-high) — BTN0 used as reset
set_property -dict {PACKAGE_PIN P20 IOSTANDARD LVCMOS33} [get_ports {btn[0]}]
set_property -dict {PACKAGE_PIN P19 IOSTANDARD LVCMOS33} [get_ports {btn[1]}]
set_property -dict {PACKAGE_PIN P17 IOSTANDARD LVCMOS33} [get_ports {btn[2]}]
set_property -dict {PACKAGE_PIN N17 IOSTANDARD LVCMOS33} [get_ports {btn[3]}]

# DIP Switches
set_property -dict {PACKAGE_PIN G22 IOSTANDARD LVCMOS33} [get_ports {sw[0]}]
set_property -dict {PACKAGE_PIN G21 IOSTANDARD LVCMOS33} [get_ports {sw[1]}]
set_property -dict {PACKAGE_PIN D21 IOSTANDARD LVCMOS33} [get_ports {sw[2]}]
set_property -dict {PACKAGE_PIN E21 IOSTANDARD LVCMOS33} [get_ports {sw[3]}]
set_property -dict {PACKAGE_PIN D22 IOSTANDARD LVCMOS33} [get_ports {sw[4]}]
set_property -dict {PACKAGE_PIN E22 IOSTANDARD LVCMOS33} [get_ports {sw[5]}]
set_property -dict {PACKAGE_PIN A21 IOSTANDARD LVCMOS33} [get_ports {sw[6]}]
set_property -dict {PACKAGE_PIN B21 IOSTANDARD LVCMOS33} [get_ports {sw[7]}]
