library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pkg.all;

-- Testbench for superscalar_top
--
-- Test program (byte addresses):
--   0x0000: LLI  R1, 5          R1 = 0x0005
--   0x0002: LLI  R2, 3          R2 = 0x0003
--   0x0004: LLI  R5, 7          R5 = 0x0007
--   0x0006: ADD  R3, R1, R2     R3 = R1+R2 = 0x0008, Z=0  (ADA)
--   0x0008: ADZ  R5, R1, R2     Z=0 so NOP: R5 stays 0x0007
--   0x000A: LW   R4, R0, 0      R4 = dmem[0] = 0x000A (pre-initialized)
--   0x000C: BEQ  R0, R0, 0      infinite loop (halt)
--
-- Data memory is pre-initialized from testbench (dmem[0] = 0x000A).
--
-- Instruction encoding (16-bit):
--   LLI  R1, 5      : opcode=0011 RA=001 imm9=000000101             => 0x3205
--   LLI  R2, 3      : opcode=0011 RA=010 imm9=000000011             => 0x3403
--   LLI  R5, 7      : opcode=0011 RA=101 imm9=000000111             => 0x3A07
--   ADD  R3=R1+R2   : opcode=0001 RA=001 RB=010 RC=011 cmp=0 cond=00 => 0x1298
--   ADZ  R5=R1+R2   : opcode=0001 RA=001 RB=010 RC=101 cmp=0 cond=01 => 0x12A9
--   LW   R4, R0, 0  : opcode=0100 RA=100 RB=000 imm6=000000         => 0x4800
--   BEQ  R0, R0, 0  : opcode=1000 RA=000 RB=000 imm6=000000         => 0x8000
--
-- Expected results after ~100 cycles:
--   regs_out(1) = 0x0005
--   regs_out(2) = 0x0003
--   regs_out(3) = 0x0008
--   regs_out(4) = 0x000A  (loaded from pre-initialized memory)
--   regs_out(5) = 0x0007  (ADZ was NOP because Z=0)

entity tb_superscalar is
end entity;

architecture sim of tb_superscalar is

  signal clk   : std_logic := '0';
  signal reset : std_logic := '1';

  signal regs_out : reg_file_t;
  signal c_flag   : std_logic;
  signal z_flag   : std_logic;

  -- Imem write port
  signal imem_wr_en   : std_logic := '0';
  signal imem_wr_addr : std_logic_vector(15 downto 0) := (others => '0');
  signal imem_wr_data : std_logic_vector(15 downto 0) := (others => '0');

  -- Dmem write port (testbench pre-initialization)
  signal dmem_wr_en   : std_logic := '0';
  signal dmem_wr_addr : std_logic_vector(15 downto 0) := (others => '0');
  signal dmem_wr_data : std_logic_vector(15 downto 0) := (others => '0');

  constant CLK_PERIOD : time := 10 ns;

  -- Test program
  type program_t is array (natural range <>) of std_logic_vector(15 downto 0);
  constant PROG : program_t(0 to 6) := (
    x"3205",   -- LLI  R1, 5       byte addr 0x0000
    x"3403",   -- LLI  R2, 3       byte addr 0x0002
    x"3A07",   -- LLI  R5, 7       byte addr 0x0004
    x"1298",   -- ADD  R3, R1, R2  byte addr 0x0006  R3=8, Z=0
    x"12A9",   -- ADZ  R5, R1, R2  byte addr 0x0008  Z=0 -> NOP, R5 stays 7
    x"4800",   -- LW   R4, R0, 0   byte addr 0x000A  R4 = dmem[0]
    x"8000"    -- BEQ  R0, R0, 0   byte addr 0x000C  (halt loop)
  );

  -- Track pass/fail
  signal test_pass : boolean := true;

begin

  --------------------------------------------------------------------------
  -- DUT
  --------------------------------------------------------------------------
  u_dut : entity work.superscalar_top
    port map(
      clk          => clk,
      reset        => reset,
      regs_out     => regs_out,
      c_flag       => c_flag,
      z_flag       => z_flag,
      imem_wr_en   => imem_wr_en,
      imem_wr_addr => imem_wr_addr,
      imem_wr_data => imem_wr_data,
      dmem_wr_en   => dmem_wr_en,
      dmem_wr_addr => dmem_wr_addr,
      dmem_wr_data => dmem_wr_data
    );

  --------------------------------------------------------------------------
  -- Clock generator
  --------------------------------------------------------------------------
  clk <= not clk after CLK_PERIOD / 2;

  --------------------------------------------------------------------------
  -- Stimulus
  --------------------------------------------------------------------------
  process
  begin
    -- Hold reset for 4 cycles
    reset <= '1';
    for i in 0 to 3 loop
      wait until rising_edge(clk);
    end loop;

    -- Load instruction memory while processor is in reset
    -- Each instruction occupies 2 bytes; write one word per cycle
    for i in 0 to PROG'length-1 loop
      imem_wr_addr <= std_logic_vector(to_unsigned(i * 2, 16));
      imem_wr_data <= PROG(i);
      imem_wr_en   <= '1';
      wait until rising_edge(clk);
    end loop;
    imem_wr_en <= '0';

    -- Pre-initialize data memory: dmem[byte addr 0] = 0x000A
    -- LW R4,R0,0 will read this value
    dmem_wr_addr <= x"0000";
    dmem_wr_data <= x"000A";
    dmem_wr_en   <= '1';
    wait until rising_edge(clk);
    dmem_wr_en   <= '0';

    -- One extra cycle for memory write to settle
    wait until rising_edge(clk);

    -- Release reset — processor starts fetching from PC=0
    reset <= '0';

    -- Run for 100 cycles — enough for all 7 instructions to
    -- fetch, decode, rename, issue, execute, and retire
    for i in 0 to 99 loop
      wait until rising_edge(clk);
    end loop;

    --------------------------------------------------------------------------
    -- Check results
    --------------------------------------------------------------------------
    if regs_out(1) = x"0005" then
      report "PASS: R1 = 0x0005";
    else
      report "FAIL: R1 expected 0x0005, got 0x" & to_hstring(regs_out(1))
        severity error;
      test_pass <= false;
    end if;

    if regs_out(2) = x"0003" then
      report "PASS: R2 = 0x0003";
    else
      report "FAIL: R2 expected 0x0003, got 0x" & to_hstring(regs_out(2))
        severity error;
      test_pass <= false;
    end if;

    if regs_out(3) = x"0008" then
      report "PASS: R3 = 0x0008";
    else
      report "FAIL: R3 expected 0x0008, got 0x" & to_hstring(regs_out(3))
        severity error;
      test_pass <= false;
    end if;

    if regs_out(4) = x"000A" then
      report "PASS: R4 = 0x000A  (load from pre-initialized memory)";
    else
      report "FAIL: R4 expected 0x000A, got 0x" & to_hstring(regs_out(4))
        severity error;
      test_pass <= false;
    end if;

    if regs_out(5) = x"0007" then
      report "PASS: R5 = 0x0007  (ADZ was NOP because Z=0 after ADD)";
    else
      report "FAIL: R5 expected 0x0007, got 0x" & to_hstring(regs_out(5))
        severity error;
      test_pass <= false;
    end if;

    -- Note: test_pass is a signal so its update above won't be visible
    -- until the next delta cycle; read it after a wait
    wait for 1 ns;
    if test_pass then
      report "*** ALL TESTS PASSED ***";
    else
      report "*** SOME TESTS FAILED ***" severity error;
    end if;

    wait;  -- stop simulation
  end process;

  --------------------------------------------------------------------------
  -- Monitor: print register file every 10 cycles after reset
  --------------------------------------------------------------------------
  process
  begin
    wait until reset = '0';
    loop
      for i in 0 to 9 loop
        wait until rising_edge(clk);
      end loop;
      report "Cycle monitor - R1=" & to_hstring(regs_out(1))
           & " R2=" & to_hstring(regs_out(2))
           & " R3=" & to_hstring(regs_out(3))
           & " R4=" & to_hstring(regs_out(4))
           & " C=" & std_logic'image(c_flag)
           & " Z=" & std_logic'image(z_flag);
    end loop;
  end process;

end architecture;
