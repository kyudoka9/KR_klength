-- ================================================================================ --
-- KR RISC-V Scientific Coprocessor — Board-Level Top for Numato Mimas A7           --
-- -------------------------------------------------------------------------------- --
-- Instantiates NEORV32 SoC with bignum CFU on XC7A50T-1FGG484.                    --
-- 100 MHz input clock, UART0 via FT2232H, LEDs, buttons, switches.               --
--                                                                                  --
-- Copyright 2026 Kyudoka Research, H. Ismail <ismh@kyudoka.org>                    --
-- License: BSD-3-Clause                                                            --
-- ================================================================================ --

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library neorv32;
use neorv32.neorv32_package.all;

entity kr_neorv32_mimas_a7 is
  port (
    -- 100 MHz oscillator (pin H4)
    clk_100mhz  : in  std_logic;

    -- Push buttons (directly usable as active-high reset)
    btn         : in  std_logic_vector(3 downto 0);

    -- LEDs (active high)
    led         : out std_logic_vector(7 downto 0);

    -- DIP switches
    sw          : in  std_logic_vector(7 downto 0);

    -- UART (FT2232H)
    uart_tx     : out std_logic; -- FPGA -> Host
    uart_rx     : in  std_logic  -- Host -> FPGA
  );
end entity;

architecture rtl of kr_neorv32_mimas_a7 is

  -- Internal signals
  signal clk_i      : std_ulogic;
  signal rstn_i     : std_ulogic;
  signal gpio_out   : std_ulogic_vector(31 downto 0);
  signal gpio_in    : std_ulogic_vector(31 downto 0);
  signal uart_txd_s : std_ulogic;

begin

  -- Clock and reset
  clk_i  <= std_ulogic(clk_100mhz);
  rstn_i <= not std_ulogic(btn(0)); -- BTN0 as active-high reset -> active-low rstn

  -- UART output bridge (std_ulogic -> std_logic)
  uart_tx <= std_logic(uart_txd_s);

  -- GPIO input: switches on bits 7:0
  gpio_in(7 downto 0)  <= std_ulogic_vector(sw);
  gpio_in(31 downto 8) <= (others => '0');

  -- NEORV32 Processor SoC
  neorv32_inst: neorv32_top
  generic map (
    -- Clock --
    CLOCK_FREQUENCY  => 100_000_000, -- 100 MHz

    -- Boot --
    BOOT_MODE_SELECT => 0,           -- internal bootloader (UART upload)

    -- ISA Extensions --
    RISCV_ISA_C      => true,        -- compressed instructions (smaller code)
    RISCV_ISA_M      => true,        -- hardware multiply/divide
    RISCV_ISA_Zicntr => true,        -- base counters (for benchmarking)
    RISCV_ISA_Xcfu   => true,        -- *** CUSTOM FUNCTIONS UNIT (bignum) ***

    -- Tuning --
    CPU_FAST_MUL_EN  => true,        -- use DSP48E1 for M-extension multiplier
    CPU_FAST_SHIFT_EN => true,       -- barrel shifter for shifts

    -- Memory --
    IMEM_EN          => true,
    IMEM_SIZE        => 32 * 1024,   -- 32 KB instruction memory (BRAM)
    DMEM_EN          => true,
    DMEM_SIZE        => 16 * 1024,   -- 16 KB data memory (BRAM)

    -- Peripherals --
    IO_GPIO_NUM      => 8,           -- 8 GPIO pairs (mapped to LEDs + switches)
    IO_UART0_EN      => true,        -- UART0 for bootloader and debug output
    IO_UART0_TX_FIFO => 32,          -- TX FIFO depth
    IO_UART0_RX_FIFO => 32,          -- RX FIFO depth
    IO_CLINT_EN      => true,        -- timer (needed for benchmarking)
    IO_GPTMR_NUM     => 1            -- 1 general-purpose timer
  )
  port map (
    -- Global control --
    clk_i       => clk_i,
    rstn_i      => rstn_i,

    -- GPIO --
    gpio_o      => gpio_out,
    gpio_i      => gpio_in,

    -- UART0 --
    uart0_txd_o => uart_txd_s,
    uart0_rxd_i => std_ulogic(uart_rx)
  );

  -- LED output from GPIO
  led <= std_logic_vector(gpio_out(7 downto 0));

end architecture;
