-- ================================================================================ --
-- KR k-Length Computing Platform — Board-Level Top for Numato Mimas A7            --
-- -------------------------------------------------------------------------------- --
-- Instantiates NEORV32 SoC with XBUS-connected KR k-Length Computing fabric       --
-- on XC7A50T-1FGG484. 100 MHz input clock, UART0 via FT2232H, LEDs, buttons,     --
-- switches.                                                                        --
--                                                                                  --
-- Address Map (XBUS):                                                              --
--   0xF0000000 - 0xF000003F  KR k-Length register interface                        --
--   0xF0010000 - 0xF001FFFF  KR k-Length shared BRAM (RISC-V side, port A)        --
--                                                                                  --
-- Address decoding:                                                                --
--   bits [31:20] = 0xF00      → select k-length fabric on XBUS                    --
--   bit  [16]    = 0          → register interface                                 --
--   bit  [16]    = 1          → shared BRAM port A                                 --
--                                                                                  --
-- Copyright 2026 Kyudoka Research, H. Ismail <ismh@kyudoka.org>                    --
-- License: BSD-3-Clause                                                            --
-- ================================================================================ --

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library neorv32;
use neorv32.neorv32_package.all;

entity kr_neorv32_klength_top is
  port (
    -- 100 MHz oscillator (pin H4)
    clk_100mhz  : in  std_logic;

    -- Push buttons (active-high; BTN0 = reset)
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

architecture rtl of kr_neorv32_klength_top is

  -- --------------------------------------------------------------------------
  -- Clock / Reset
  -- --------------------------------------------------------------------------
  signal clk_i      : std_ulogic;
  signal rstn_i     : std_ulogic;

  -- --------------------------------------------------------------------------
  -- GPIO
  -- --------------------------------------------------------------------------
  signal gpio_out   : std_ulogic_vector(31 downto 0);
  signal gpio_in    : std_ulogic_vector(31 downto 0);

  -- --------------------------------------------------------------------------
  -- UART bridge signal (std_ulogic from NEORV32 -> std_logic board port)
  -- --------------------------------------------------------------------------
  signal uart_txd_s : std_ulogic;

  -- --------------------------------------------------------------------------
  -- XBUS (Wishbone) signals from NEORV32
  -- --------------------------------------------------------------------------
  signal xbus_adr   : std_ulogic_vector(31 downto 0);
  signal xbus_dat_w : std_ulogic_vector(31 downto 0); -- write data (CPU -> bus)
  signal xbus_dat_r : std_ulogic_vector(31 downto 0); -- read data  (bus -> CPU)
  signal xbus_we    : std_ulogic;
  signal xbus_sel   : std_ulogic_vector(3 downto 0);
  signal xbus_stb   : std_ulogic;
  signal xbus_cyc   : std_ulogic;
  signal xbus_ack   : std_ulogic;
  signal xbus_err   : std_ulogic;

  -- --------------------------------------------------------------------------
  -- Address decoder outputs
  -- --------------------------------------------------------------------------
  signal sel_klength    : std_logic; -- bits [31:20] = 0xF00
  signal sel_regs       : std_logic; -- regs:  sel_klength AND NOT bit[16]
  signal sel_bram       : std_logic; -- bram:  sel_klength AND bit[16]

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
  -- Clock and Reset
  -- ==========================================================================
  clk_i  <= std_ulogic(clk_100mhz);
  rstn_i <= not std_ulogic(btn(0)); -- BTN0 active-high -> active-low rstn

  -- ==========================================================================
  -- UART output bridge (std_ulogic -> std_logic)
  -- ==========================================================================
  uart_tx <= std_logic(uart_txd_s);

  -- ==========================================================================
  -- GPIO input: switches on bits 7:0
  -- ==========================================================================
  gpio_in(7 downto 0)  <= std_ulogic_vector(sw);
  gpio_in(31 downto 8) <= (others => '0');

  -- ==========================================================================
  -- NEORV32 Processor SoC
  -- ==========================================================================
  neorv32_inst : neorv32_top
  generic map (
    -- Clock --
    CLOCK_FREQUENCY   => 100_000_000,

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

    -- Memory --
    IMEM_EN           => true,
    IMEM_SIZE         => 32 * 1024,
    DMEM_EN           => true,
    DMEM_SIZE         => 16 * 1024,

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
    clk_i       => clk_i,
    rstn_i      => rstn_i,

    -- GPIO --
    gpio_o      => gpio_out,
    gpio_i      => gpio_in,

    -- UART0 --
    uart0_txd_o => uart_txd_s,
    uart0_rxd_i => std_ulogic(uart_rx),

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
    N_CHANNELS  => 8,
    TAG_BITS    => 10,
    DATA_BITS   => 32,
    BRAM_ADDR_W => 13
  )
  port map (
    clk             => std_logic(clk_i),
    rst             => not std_logic(rstn_i), -- active-high reset for Verilog module

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
