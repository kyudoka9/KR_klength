-- ================================================================================ --
-- KR Bignum Custom Functions Unit for NEORV32                                      --
-- -------------------------------------------------------------------------------- --
-- Implements arbitrary-precision arithmetic primitives as custom RISC-V             --
-- instructions, targeting the inner loops of Pari/GP's multi-precision kernel.      --
--                                                                                  --
-- Instruction Encoding (R-type, custom-0 opcode 0b0001011):                        --
--                                                                                  --
--   funct3  funct7     Mnemonic    Operation                          Cycles        --
--   ------  -------    --------    ---------                          ------        --
--   000     0000000    ADDWC       rd = rs1 + rs2 + carry_in           1            --
--   001     0000000    SUBWB       rd = rs1 - rs2 - borrow_in          1            --
--   010     0000000    MULFULL     {HIREG,rd} = rs1 * rs2              3 (DSP48E1)  --
--   011     0000000    ADDMUL      {HIREG,rd} = rs1 * rs2 + HIREG      3 (DSP48E1)  --
--   100     0000000    DIVDW       {HIREG,rd} = {HIREG,rs1} / rs2      34           --
--   101     0000000    CLZ         rd = count_leading_zeros(rs1)        1            --
--   110     0000000    RDHIREG     rd = HIREG                          1            --
--   110     0000001    RDCARRY     rd = {31'd0, carry}                  1            --
--   111     0000000    WRHIREG     HIREG = rs1; rd = old HIREG          1            --
--   111     0000001    WRCARRY     carry = rs1[0]; rd = {31'd0, old carry} 1         --
--                                                                                  --
-- HIREG is a shadow register mirroring Pari/GP's 'hiremainder' global.             --
-- Carry/borrow is a 1-bit internal flag, also mirroring Pari/GP's 'overflow'.      --
--                                                                                  --
-- Copyright 2026 Kyudoka Research, H. Ismail <ismh@kyudoka.org>                    --
-- License: BSD-3-Clause                                                            --
-- ================================================================================ --

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity neorv32_cpu_alu_cfu is
  port (
    -- global control --
    clk_i    : in  std_ulogic;
    rstn_i   : in  std_ulogic;
    -- operation trigger --
    start_i  : in  std_ulogic;
    -- operands --
    type_i   : in  std_ulogic;
    funct3_i : in  std_ulogic_vector(2 downto 0);
    funct7_i : in  std_ulogic_vector(6 downto 0);
    imm12_i  : in  std_ulogic_vector(11 downto 0);
    rs1_i    : in  std_ulogic_vector(31 downto 0);
    rs2_i    : in  std_ulogic_vector(31 downto 0);
    -- result and status --
    result_o : out std_ulogic_vector(31 downto 0);
    valid_o  : out std_ulogic
  );
end neorv32_cpu_alu_cfu;

architecture neorv32_cpu_alu_cfu_rtl of neorv32_cpu_alu_cfu is

  -- instruction type identifiers --
  constant r_type_c : std_ulogic := '0';
  constant i_type_c : std_ulogic := '1';

  -- R-type instruction identifiers (funct3) --
  constant ADDWC_F3   : std_ulogic_vector(2 downto 0) := "000";
  constant SUBWB_F3   : std_ulogic_vector(2 downto 0) := "001";
  constant MULFULL_F3 : std_ulogic_vector(2 downto 0) := "010";
  constant ADDMUL_F3  : std_ulogic_vector(2 downto 0) := "011";
  constant DIVDW_F3   : std_ulogic_vector(2 downto 0) := "100";
  constant CLZ_F3     : std_ulogic_vector(2 downto 0) := "101";
  constant RDHIREG_F3 : std_ulogic_vector(2 downto 0) := "110";
  constant WRHIREG_F3 : std_ulogic_vector(2 downto 0) := "111";

  -- =========================================================================
  -- Shadow registers (Pari/GP model)
  -- =========================================================================
  signal hireg   : std_ulogic_vector(31 downto 0); -- hiremainder
  signal carry   : std_ulogic;                      -- overflow / carry flag

  -- =========================================================================
  -- Multiplier signals (3-cycle pipeline, maps to DSP48E1)
  -- =========================================================================
  signal mul_start    : std_ulogic;
  signal mul_is_addmul: std_ulogic; -- 0=MULFULL, 1=ADDMUL
  signal mul_opa      : unsigned(31 downto 0);
  signal mul_opb      : unsigned(31 downto 0);

  -- Pipeline stage 1: capture operands
  signal mul_s1_valid : std_ulogic;
  signal mul_s1_addmul: std_ulogic;
  signal mul_s1_a     : unsigned(31 downto 0);
  signal mul_s1_b     : unsigned(31 downto 0);
  signal mul_s1_acc   : unsigned(31 downto 0); -- captured HIREG for ADDMUL

  -- Pipeline stage 2: multiply (DSP48E1 does this in fabric)
  signal mul_s2_valid : std_ulogic;
  signal mul_s2_addmul: std_ulogic;
  signal mul_s2_prod  : unsigned(63 downto 0);
  signal mul_s2_acc   : unsigned(31 downto 0);

  -- Pipeline stage 3: accumulate and output
  signal mul_s3_valid : std_ulogic;
  signal mul_s3_lo    : std_ulogic_vector(31 downto 0);
  signal mul_s3_hi    : std_ulogic_vector(31 downto 0);

  -- =========================================================================
  -- Divider signals (iterative, 32+2 cycles)
  -- =========================================================================
  signal div_start    : std_ulogic;
  signal div_busy     : std_ulogic;
  signal div_done     : std_ulogic;
  signal div_count    : unsigned(5 downto 0); -- 0..33
  signal div_dividend : unsigned(63 downto 0); -- {hireg, rs1}
  signal div_divisor  : unsigned(31 downto 0);
  signal div_quotient : unsigned(31 downto 0);
  signal div_remainder: unsigned(31 downto 0);

  -- =========================================================================
  -- CLZ (count leading zeros) — purely combinational
  -- =========================================================================
  function f_clz32(x : std_ulogic_vector(31 downto 0)) return std_ulogic_vector is
    variable n : unsigned(5 downto 0);
    variable v : std_ulogic_vector(31 downto 0);
  begin
    n := to_unsigned(0, 6);
    v := x;
    -- binary search: check upper half, shift if zero
    if v(31 downto 16) = x"0000" then n := n + 16; v(31 downto 16) := v(15 downto 0); v(15 downto 0) := x"0000"; end if;
    if v(31 downto 24) = x"00"   then n := n + 8;  v(31 downto 24) := v(23 downto 16); end if;
    if v(31 downto 28) = x"0"    then n := n + 4;  v(31 downto 28) := v(27 downto 24); end if;
    if v(31 downto 30) = "00"    then n := n + 2;  v(31 downto 30) := v(29 downto 28); end if;
    if v(31) = '0'               then n := n + 1;  end if;
    if x = x"00000000"           then n := to_unsigned(32, 6); end if;
    return std_ulogic_vector(n);
  end function;

begin

  -- ===========================================================================
  -- Multiplier Pipeline (3 cycles, intended for DSP48E1 inference)
  -- ===========================================================================
  mul_pipe: process(clk_i, rstn_i)
    variable product_64  : unsigned(63 downto 0);
    variable accum_result : unsigned(64 downto 0); -- 65-bit for carry detection
  begin
    if rstn_i = '0' then
      mul_s1_valid  <= '0';
      mul_s1_addmul <= '0';
      mul_s1_a      <= (others => '0');
      mul_s1_b      <= (others => '0');
      mul_s1_acc    <= (others => '0');
      mul_s2_valid  <= '0';
      mul_s2_addmul <= '0';
      mul_s2_prod   <= (others => '0');
      mul_s2_acc    <= (others => '0');
      mul_s3_valid  <= '0';
      mul_s3_lo     <= (others => '0');
      mul_s3_hi     <= (others => '0');
    elsif rising_edge(clk_i) then
      -- Stage 1: capture operands
      mul_s1_valid  <= mul_start;
      mul_s1_addmul <= mul_is_addmul;
      mul_s1_a      <= mul_opa;
      mul_s1_b      <= mul_opb;
      mul_s1_acc    <= unsigned(hireg); -- snapshot HIREG at dispatch time

      -- Stage 2: multiply (DSP48E1 infers here)
      mul_s2_valid  <= mul_s1_valid;
      mul_s2_addmul <= mul_s1_addmul;
      mul_s2_prod   <= mul_s1_a * mul_s1_b;
      mul_s2_acc    <= mul_s1_acc;

      -- Stage 3: accumulate (for ADDMUL) and register output
      mul_s3_valid <= mul_s2_valid;
      if mul_s2_addmul = '1' then
        -- ADDMUL: product + hireg (captured in s1)
        accum_result := ('0' & mul_s2_prod) + ('0' & resize(mul_s2_acc, 64));
        mul_s3_lo <= std_ulogic_vector(accum_result(31 downto 0));
        mul_s3_hi <= std_ulogic_vector(accum_result(63 downto 32));
      else
        -- MULFULL: just the product
        mul_s3_lo <= std_ulogic_vector(mul_s2_prod(31 downto 0));
        mul_s3_hi <= std_ulogic_vector(mul_s2_prod(63 downto 32));
      end if;
    end if;
  end process mul_pipe;


  -- ===========================================================================
  -- Divider (iterative restoring division, 34 cycles)
  -- Computes {HIREG, rs1} / rs2 -> quotient in rd, remainder in HIREG
  -- ===========================================================================
  div_engine: process(clk_i, rstn_i)
    variable trial : unsigned(32 downto 0); -- 33-bit for subtraction
  begin
    if rstn_i = '0' then
      div_busy      <= '0';
      div_done      <= '0';
      div_count     <= (others => '0');
      div_dividend  <= (others => '0');
      div_divisor   <= (others => '0');
      div_quotient  <= (others => '0');
      div_remainder <= (others => '0');
    elsif rising_edge(clk_i) then
      div_done <= '0'; -- default: not done

      if div_start = '1' and div_busy = '0' then
        -- Start new division
        div_busy     <= '1';
        div_count    <= to_unsigned(32, 6); -- 32 iterations
        div_dividend <= unsigned(hireg) & unsigned(rs1_i);
        div_divisor  <= unsigned(rs2_i);
        div_quotient <= (others => '0');

      elsif div_busy = '1' then
        if div_count = 0 then
          -- Done: quotient is assembled, remainder is in dividend upper half
          div_busy      <= '0';
          div_done      <= '1';
          div_remainder <= div_dividend(63 downto 32);
        else
          -- Restoring division step: shift left, trial subtract
          trial := ('0' & div_dividend(62 downto 31)) - ('0' & div_divisor);
          if trial(32) = '0' then
            -- Subtraction succeeded (trial >= 0)
            div_dividend <= trial(31 downto 0) & div_dividend(30 downto 0) & '0';
            div_quotient <= div_quotient(30 downto 0) & '1';
          else
            -- Subtraction would underflow, shift without subtracting
            div_dividend <= div_dividend(62 downto 0) & '0';
            div_quotient <= div_quotient(30 downto 0) & '0';
          end if;
          div_count <= div_count - 1;
        end if;
      end if;
    end if;
  end process div_engine;


  -- ===========================================================================
  -- Main Control: instruction dispatch and HIREG/carry management
  -- ===========================================================================
  main_ctrl: process(clk_i, rstn_i)
    variable sum33   : unsigned(32 downto 0); -- 33-bit for carry/borrow detection
  begin
    if rstn_i = '0' then
      hireg       <= (others => '0');
      carry       <= '0';
      mul_start   <= '0';
      mul_is_addmul <= '0';
      mul_opa     <= (others => '0');
      mul_opb     <= (others => '0');
      div_start   <= '0';
    elsif rising_edge(clk_i) then
      -- Clear one-shot triggers
      mul_start <= '0';
      div_start <= '0';

      -- Update HIREG from multiplier pipeline completion
      if mul_s3_valid = '1' then
        hireg <= mul_s3_hi;
      end if;

      -- Update HIREG from divider completion
      if div_done = '1' then
        hireg <= std_ulogic_vector(div_remainder);
      end if;

      -- Dispatch new instruction
      if start_i = '1' and type_i = r_type_c then
        case funct3_i is

          when ADDWC_F3 => -- ADDWC: rd = rs1 + rs2 + carry
            sum33 := ('0' & unsigned(rs1_i)) + ('0' & unsigned(rs2_i)) + ("" & carry);
            carry <= sum33(32);
            -- result is registered by ALU output stage

          when SUBWB_F3 => -- SUBWB: rd = rs1 - rs2 - borrow
            sum33 := ('0' & unsigned(rs1_i)) - ('0' & unsigned(rs2_i)) - ("" & carry);
            carry <= sum33(32); -- borrow flag

          when MULFULL_F3 => -- MULFULL: {HIREG,rd} = rs1 * rs2
            mul_start     <= '1';
            mul_is_addmul <= '0';
            mul_opa       <= unsigned(rs1_i);
            mul_opb       <= unsigned(rs2_i);

          when ADDMUL_F3 => -- ADDMUL: {HIREG,rd} = rs1 * rs2 + HIREG
            mul_start     <= '1';
            mul_is_addmul <= '1';
            mul_opa       <= unsigned(rs1_i);
            mul_opb       <= unsigned(rs2_i);

          when DIVDW_F3 => -- DIVDW: {HIREG,rd} = {HIREG,rs1} / rs2
            div_start <= '1';

          when CLZ_F3 => -- CLZ: single-cycle, no state update
            null;

          when RDHIREG_F3 => -- RDHIREG / RDCARRY (distinguished by funct7)
            null; -- RDHIREG: no state change; RDCARRY: no state change

          when WRHIREG_F3 => -- WRHIREG / WRCARRY (distinguished by funct7)
            if funct7_i(0) = '1' then
              carry <= rs1_i(0); -- WRCARRY: carry = rs1[0]
            else
              hireg <= rs1_i;    -- WRHIREG: HIREG = rs1
            end if;

          when others =>
            null;

        end case;
      end if;

    end if;
  end process main_ctrl;


  -- ===========================================================================
  -- Result multiplexer and valid signal
  -- ===========================================================================
  result_mux: process(type_i, funct3_i, funct7_i, rs1_i, rs2_i, hireg, carry,
                      mul_s3_valid, mul_s3_lo, div_done, div_quotient, div_busy)
    variable sum33 : unsigned(32 downto 0);
  begin
    result_o <= (others => '0');
    valid_o  <= '0';

    if type_i = r_type_c then
      case funct3_i is

        when ADDWC_F3 => -- combinational result, 1 cycle
          sum33 := ('0' & unsigned(rs1_i)) + ('0' & unsigned(rs2_i)) + ("" & carry);
          result_o <= std_ulogic_vector(sum33(31 downto 0));
          valid_o  <= '1';

        when SUBWB_F3 => -- combinational result, 1 cycle
          sum33 := ('0' & unsigned(rs1_i)) - ('0' & unsigned(rs2_i)) - ("" & carry);
          result_o <= std_ulogic_vector(sum33(31 downto 0));
          valid_o  <= '1';

        when MULFULL_F3 | ADDMUL_F3 => -- 3-cycle pipeline
          result_o <= mul_s3_lo;
          valid_o  <= mul_s3_valid;

        when DIVDW_F3 => -- 34-cycle iterative
          result_o <= std_ulogic_vector(div_quotient);
          valid_o  <= div_done;

        when CLZ_F3 => -- combinational, 1 cycle
          result_o <= x"000000" & "00" & f_clz32(rs1_i);
          valid_o  <= '1';

        when RDHIREG_F3 => -- RDHIREG or RDCARRY, 1 cycle
          if funct7_i(0) = '1' then
            -- RDCARRY: rd = {31'd0, carry}
            result_o <= (31 downto 1 => '0') & carry;
          else
            -- RDHIREG: rd = HIREG
            result_o <= hireg;
          end if;
          valid_o  <= '1';

        when WRHIREG_F3 => -- WRHIREG or WRCARRY, 1 cycle
          if funct7_i(0) = '1' then
            -- WRCARRY: rd = {31'd0, old carry}
            result_o <= (31 downto 1 => '0') & carry;
          else
            -- WRHIREG: rd = old HIREG
            result_o <= hireg;
          end if;
          valid_o  <= '1';

        when others =>
          result_o <= (others => '0');
          valid_o  <= '0'; -- illegal instruction exception

      end case;

    else -- I-type: reserved for future use (e.g., scheduler interface)
      result_o <= (others => '0');
      valid_o  <= '0'; -- currently no I-type instructions defined
    end if;
  end process result_mux;

end neorv32_cpu_alu_cfu_rtl;
