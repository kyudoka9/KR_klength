-- ================================================================================ --
-- KR k-Length Computing Platform — Board-Level Top for Digilent Genesys 2          --
-- -------------------------------------------------------------------------------- --
-- Instantiates NEORV32 SoC with XBUS-connected KR k-Length Computing fabric       --
-- on XC7K325T-2FFG900C. 200 MHz LVDS differential input clock, MMCM generates     --
-- 100 MHz (NEORV32), 125 MHz (Ethernet, future), 200 MHz (IDELAYCTRL, future).    --
-- UART0 via FT2232H channel B, 8 LEDs via GPIO.                                   --
--                                                                                  --
-- Address Map (XBUS):                                                              --
--   0xF0000000 - 0xF000003F  KR k-Length register interface                        --
--   0xF0010000 - 0xF001FFFF  KR k-Length shared BRAM (RISC-V side, port A)        --
--                                                                                  --
-- Address decoding:                                                                --
--   bits [31:20] = 0xF00      -> select k-length fabric on XBUS                    --
--   bit  [16]    = 0          -> register interface                                 --
--   bit  [16]    = 1          -> shared BRAM port A                                 --
--                                                                                  --
-- MMCM configuration (200 MHz LVDS input):                                         --
--   VCO = 200 MHz * 5.0 / 1 = 1000 MHz                                            --
--   CLKOUT0 = 1000 / 10.0 = 100 MHz  (NEORV32 system clock)                       --
--   CLKOUT1 = 1000 / 8    = 125 MHz  (Ethernet, future)                            --
--   CLKOUT2 = 1000 / 5    = 200 MHz  (IDELAYCTRL, future)                          --
--                                                                                  --
-- Copyright 2026 Kyudoka Research, H. Ismail <ismh@kyudoka.org>                    --
-- License: BSD-3-Clause                                                            --
-- ================================================================================ --

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

library neorv32;
use neorv32.neorv32_package.all;

entity kr_neorv32_klength_genesys2 is
  port (
    -- 200 MHz LVDS differential clock (AD12/AD11)
    sysclk_p    : in  std_logic;
    sysclk_n    : in  std_logic;

    -- Active-low reset (R19)
    cpu_resetn  : in  std_logic;

    -- LEDs (active high)
    led         : out std_logic_vector(7 downto 0);

    -- UART (FT2232H channel B)
    uart_txd    : out std_logic;  -- FPGA -> Host (Y20)
    uart_rxd    : in  std_logic   -- Host -> FPGA (Y23)
  );
end entity;

architecture rtl of kr_neorv32_klength_genesys2 is

  -- --------------------------------------------------------------------------
  -- Clock infrastructure
  -- --------------------------------------------------------------------------
  signal sysclk_ibuf   : std_logic;  -- single-ended after IBUFDS
  signal sysclk_bufg   : std_logic;  -- buffered 200 MHz into MMCM
  signal mmcm_clkfb    : std_logic;  -- MMCM feedback
  signal mmcm_locked   : std_logic;

  signal clk_100m_unbuf : std_logic; -- MMCM CLKOUT0 (100 MHz, unbuffered)
  signal clk_125m_unbuf : std_logic; -- MMCM CLKOUT1 (125 MHz, unbuffered)
  signal clk_200m_unbuf : std_logic; -- MMCM CLKOUT2 (200 MHz, unbuffered)

  signal clk_100m      : std_logic;  -- 100 MHz buffered (NEORV32 system clock)
  signal clk_125m      : std_logic;  -- 125 MHz buffered (Ethernet, future)
  signal clk_200m      : std_logic;  -- 200 MHz buffered (IDELAYCTRL, future)

  -- --------------------------------------------------------------------------
  -- Reset
  -- --------------------------------------------------------------------------
  -- Genesys 2 cpu_resetn is active-low, matching NEORV32's rstn_i directly.
  -- Hold NEORV32 in reset until MMCM is locked.
  signal rstn_i        : std_ulogic;
  signal rst_h         : std_logic;  -- active-high reset for k-length Verilog

  -- --------------------------------------------------------------------------
  -- GPIO
  -- --------------------------------------------------------------------------
  signal gpio_out      : std_ulogic_vector(31 downto 0);
  signal gpio_in       : std_ulogic_vector(31 downto 0);

  -- --------------------------------------------------------------------------
  -- UART bridge signal (std_ulogic from NEORV32 -> std_logic board port)
  -- --------------------------------------------------------------------------
  signal uart_txd_s    : std_ulogic;

  -- --------------------------------------------------------------------------
  -- XBUS (Wishbone) signals from NEORV32
  -- --------------------------------------------------------------------------
  signal xbus_adr      : std_ulogic_vector(31 downto 0);
  signal xbus_dat_w    : std_ulogic_vector(31 downto 0); -- write data (CPU -> bus)
  signal xbus_dat_r    : std_ulogic_vector(31 downto 0); -- read data  (bus -> CPU)
  signal xbus_we       : std_ulogic;
  signal xbus_sel      : std_ulogic_vector(3 downto 0);
  signal xbus_stb      : std_ulogic;
  signal xbus_cyc      : std_ulogic;
  signal xbus_ack      : std_ulogic;
  signal xbus_err      : std_ulogic;

  -- --------------------------------------------------------------------------
  -- Address decoder outputs
  -- --------------------------------------------------------------------------
  signal sel_klength   : std_logic; -- bits [31:20] = 0xF00
  signal sel_regs      : std_logic; -- regs:  sel_klength AND NOT bit[16]
  signal sel_bram      : std_logic; -- bram:  sel_klength AND bit[16]

  -- --------------------------------------------------------------------------
  -- k-Length fabric Wishbone slave signals (std_logic for Verilog boundary)
  -- --------------------------------------------------------------------------
  -- Register interface
  signal wb_regs_adr   : std_logic_vector(31 downto 0);
  signal wb_regs_dat_w : std_logic_vector(31 downto 0);
  signal wb_regs_dat_r : std_logic_vector(31 downto 0);
  signal wb_regs_we    : std_logic;
  signal wb_regs_stb   : std_logic;
  signal wb_regs_ack   : std_logic;

  -- BRAM port A interface
  signal wb_bram_adr   : std_logic_vector(31 downto 0);
  signal wb_bram_dat_w : std_logic_vector(31 downto 0);
  signal wb_bram_dat_r : std_logic_vector(31 downto 0);
  signal wb_bram_we    : std_logic;
  signal wb_bram_stb   : std_logic;
  signal wb_bram_ack   : std_logic;

  -- Status / IRQ from k-length fabric
  signal kl_busy       : std_logic;
  signal kl_done       : std_logic;
  signal kl_irq        : std_logic;

  -- --------------------------------------------------------------------------
  -- Component declaration for the Verilog k-length top module
  -- --------------------------------------------------------------------------
  component kr_klength_top is
    generic (
      N_CHANNELS  : integer := 8;
      TAG_BITS    : integer := 10;
      DATA_BITS   : integer := 32;
      BRAM_ADDR_W : integer := 13
    );
    port (
      clk             : in  std_logic;
      rst             : in  std_logic;
      -- Wishbone slave: register interface
      wb_regs_adr_i   : in  std_logic_vector(31 downto 0);
      wb_regs_dat_i   : in  std_logic_vector(31 downto 0);
      wb_regs_dat_o   : out std_logic_vector(31 downto 0);
      wb_regs_we_i    : in  std_logic;
      wb_regs_stb_i   : in  std_logic;
      wb_regs_ack_o   : out std_logic;
      -- Wishbone slave: BRAM port A (RISC-V side)
      wb_bram_adr_i   : in  std_logic_vector(31 downto 0);
      wb_bram_dat_i   : in  std_logic_vector(31 downto 0);
      wb_bram_dat_o   : out std_logic_vector(31 downto 0);
      wb_bram_we_i    : in  std_logic;
      wb_bram_stb_i   : in  std_logic;
      wb_bram_ack_o   : out std_logic;
      -- Status
      busy            : out std_logic;
      done            : out std_logic;
      irq             : out std_logic
    );
  end component;

begin

  -- ==========================================================================
  -- Differential Clock Input (LVDS 200 MHz)
  -- ==========================================================================
  -- IBUFDS converts the LVDS pair to single-ended, then BUFG drives the MMCM.
  u_ibufds : IBUFDS
  generic map (
    DIFF_TERM    => false,       -- External termination on Genesys 2
    IBUF_LOW_PWR => false,       -- High-performance mode
    IOSTANDARD   => "LVDS"
  )
  port map (
    I  => sysclk_p,
    IB => sysclk_n,
    O  => sysclk_ibuf
  );

  u_bufg_in : BUFG
  port map (
    I => sysclk_ibuf,
    O => sysclk_bufg
  );

  -- ==========================================================================
  -- MMCM: Generate 100 / 125 / 200 MHz from 200 MHz input
  -- ==========================================================================
  -- VCO = 200 MHz * (CLKFBOUT_MULT_F / DIVCLK_DIVIDE) = 200 * 5.0 / 1 = 1000 MHz
  -- Kintex-7 speed grade -2: VCO range 600-1200 MHz -> 1000 MHz is valid.
  u_mmcm : MMCME2_BASE
  generic map (
    BANDWIDTH          => "OPTIMIZED",
    CLKFBOUT_MULT_F    => 5.0,        -- VCO = 200 * 5.0 = 1000 MHz
    CLKFBOUT_PHASE     => 0.0,
    CLKIN1_PERIOD       => 5.0,        -- 200 MHz = 5.0 ns period
    DIVCLK_DIVIDE      => 1,
    REF_JITTER1        => 0.010,
    STARTUP_WAIT       => false,
    -- Output clocks
    CLKOUT0_DIVIDE_F   => 10.0,       -- 1000 / 10.0 = 100 MHz
    CLKOUT0_DUTY_CYCLE => 0.5,
    CLKOUT0_PHASE      => 0.0,
    CLKOUT1_DIVIDE     => 8,          -- 1000 / 8 = 125 MHz
    CLKOUT1_DUTY_CYCLE => 0.5,
    CLKOUT1_PHASE      => 0.0,
    CLKOUT2_DIVIDE     => 5,          -- 1000 / 5 = 200 MHz
    CLKOUT2_DUTY_CYCLE => 0.5,
    CLKOUT2_PHASE      => 0.0
  )
  port map (
    CLKFBOUT  => mmcm_clkfb,
    CLKFBIN   => mmcm_clkfb,
    CLKIN1    => sysclk_bufg,
    CLKOUT0   => clk_100m_unbuf,
    CLKOUT1   => clk_125m_unbuf,
    CLKOUT2   => clk_200m_unbuf,
    CLKOUT3   => open,
    CLKOUT4   => open,
    CLKOUT5   => open,
    CLKOUT6   => open,
    CLKOUT0B  => open,
    CLKOUT1B  => open,
    CLKOUT2B  => open,
    CLKOUT3B  => open,
    LOCKED    => mmcm_locked,
    PWRDWN    => '0',
    RST       => '0'
  );

  -- Buffer each MMCM output
  u_bufg_100m : BUFG port map (I => clk_100m_unbuf, O => clk_100m);
  u_bufg_125m : BUFG port map (I => clk_125m_unbuf, O => clk_125m);
  u_bufg_200m : BUFG port map (I => clk_200m_unbuf, O => clk_200m);

  -- ==========================================================================
  -- Reset Logic
  -- ==========================================================================
  -- cpu_resetn is active-low from the Genesys 2 board, which matches
  -- NEORV32's rstn_i directly. Gate with MMCM lock so the SoC stays in
  -- reset until clocks are stable.
  rstn_i <= std_ulogic(cpu_resetn) and std_ulogic(mmcm_locked);

  -- Active-high reset for the k-length Verilog module
  rst_h  <= not std_logic(rstn_i);

  -- ==========================================================================
  -- UART output bridge (std_ulogic -> std_logic)
  -- ==========================================================================
  uart_txd <= std_logic(uart_txd_s);

  -- ==========================================================================
  -- GPIO input: no switches on Genesys 2 in this configuration, tie low
  -- ==========================================================================
  gpio_in <= (others => '0');

  -- ==========================================================================
  -- NEORV32 Processor SoC
  -- ==========================================================================
  neorv32_inst : neorv32_top
  generic map (
    -- Clock --
    CLOCK_FREQUENCY   => 100_000_000,   -- 100 MHz from MMCM CLKOUT0

    -- Boot --
    BOOT_MODE_SELECT  => 0,

    -- ISA Extensions --
    RISCV_ISA_C       => true,
    RISCV_ISA_M       => true,
    RISCV_ISA_Zicntr  => true,
    RISCV_ISA_Xcfu    => true,

    -- Tuning --
    CPU_FAST_MUL_EN   => true,
    CPU_FAST_SHIFT_EN => true,

    -- Memory (larger: Kintex-7 has ample BRAM) --
    IMEM_EN           => true,
    IMEM_SIZE         => 64 * 1024,     -- 64 KB instruction memory
    DMEM_EN           => true,
    DMEM_SIZE         => 32 * 1024,     -- 32 KB data memory

    -- External bus (Wishbone) --
    XBUS_EN           => true,
    XBUS_TIMEOUT      => 4096,
    XBUS_REGSTAGE_EN  => true,

    -- Peripherals --
    IO_GPIO_NUM       => 8,
    IO_UART0_EN       => true,
    IO_UART0_TX_FIFO  => 32,
    IO_UART0_RX_FIFO  => 32,
    IO_CLINT_EN       => true,
    IO_GPTMR_NUM      => 1
  )
  port map (
    -- Global control --
    clk_i       => std_ulogic(clk_100m),
    rstn_i      => rstn_i,

    -- GPIO --
    gpio_o      => gpio_out,
    gpio_i      => gpio_in,

    -- UART0 --
    uart0_txd_o => uart_txd_s,
    uart0_rxd_i => std_ulogic(uart_rxd),

    -- External bus (Wishbone) --
    xbus_adr_o  => xbus_adr,
    xbus_dat_o  => xbus_dat_w,
    xbus_we_o   => xbus_we,
    xbus_sel_o  => xbus_sel,
    xbus_stb_o  => xbus_stb,
    xbus_cyc_o  => xbus_cyc,
    xbus_dat_i  => xbus_dat_r,
    xbus_ack_i  => xbus_ack,
    xbus_err_i  => xbus_err,

    -- External interrupt from k-length fabric --
    irq_mei_i   => std_ulogic(kl_irq)
  );

  -- LED output from GPIO
  led <= std_logic_vector(gpio_out(7 downto 0));

  -- ==========================================================================
  -- XBUS Address Decoder
  -- ==========================================================================
  -- k-length fabric selected when bits [31:20] = 0xF00
  sel_klength <= '1' when (std_logic_vector(xbus_adr(31 downto 20)) = x"F00")
                          and (std_logic(xbus_cyc) = '1')
                 else '0';

  -- bit [16] distinguishes register space (0) from BRAM space (1)
  sel_regs <= sel_klength and not std_logic(xbus_adr(16));
  sel_bram <= sel_klength and     std_logic(xbus_adr(16));

  -- ==========================================================================
  -- XBUS -> k-Length Wishbone Slave routing
  -- ==========================================================================
  -- Address and write data are shared; strobe is gated by address decode
  wb_regs_adr   <= std_logic_vector(xbus_adr);
  wb_regs_dat_w <= std_logic_vector(xbus_dat_w);
  wb_regs_we    <= std_logic(xbus_we);
  wb_regs_stb   <= std_logic(xbus_stb) and sel_regs;

  wb_bram_adr   <= std_logic_vector(xbus_adr);
  wb_bram_dat_w <= std_logic_vector(xbus_dat_w);
  wb_bram_we    <= std_logic(xbus_we);
  wb_bram_stb   <= std_logic(xbus_stb) and sel_bram;

  -- ==========================================================================
  -- Read-data mux and acknowledge back to NEORV32
  -- ==========================================================================
  xbus_dat_r <= std_ulogic_vector(wb_regs_dat_r) when sel_regs = '1' else
                std_ulogic_vector(wb_bram_dat_r)  when sel_bram = '1' else
                (others => '0');

  xbus_ack   <= std_ulogic(wb_regs_ack) when sel_regs = '1' else
                std_ulogic(wb_bram_ack)  when sel_bram = '1' else
                '0';

  -- Bus error: strobe to unselected address region
  xbus_err   <= std_ulogic(xbus_stb) and std_ulogic(xbus_cyc)
                and not std_ulogic(sel_klength);

  -- ==========================================================================
  -- KR k-Length Computing Fabric
  -- ==========================================================================
  kr_klength_inst : kr_klength_top
  generic map (
    N_CHANNELS  => 48,          -- 48 MAC channels (exploit Kintex-7 resources)
    TAG_BITS    => 10,
    DATA_BITS   => 32,
    BRAM_ADDR_W => 15           -- 2^15 = 32768 words = 128 KB operand storage
  )
  port map (
    clk             => clk_100m,
    rst             => rst_h,   -- active-high reset for Verilog module

    -- Register interface
    wb_regs_adr_i   => wb_regs_adr,
    wb_regs_dat_i   => wb_regs_dat_w,
    wb_regs_dat_o   => wb_regs_dat_r,
    wb_regs_we_i    => wb_regs_we,
    wb_regs_stb_i   => wb_regs_stb,
    wb_regs_ack_o   => wb_regs_ack,

    -- BRAM port A (RISC-V side)
    wb_bram_adr_i   => wb_bram_adr,
    wb_bram_dat_i   => wb_bram_dat_w,
    wb_bram_dat_o   => wb_bram_dat_r,
    wb_bram_we_i    => wb_bram_we,
    wb_bram_stb_i   => wb_bram_stb,
    wb_bram_ack_o   => wb_bram_ack,

    -- Status
    busy            => kl_busy,
    done            => kl_done,
    irq             => kl_irq
  );

end architecture;
