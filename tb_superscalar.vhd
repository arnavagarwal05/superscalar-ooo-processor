library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pkg.all;

-- Testbench for superscalar_top
--
-- Test program (byte addresses):
--   0x0000: LLI  R1, 5          R1 = 0x0005
--   0x0002: LLI  R2, 3          R2 = 0x0003
--   0x0004: ADD  R3, R1, R2     R3 = R1 + R2 = 0x0008  (ADA variant)
--   0x0006: BEQ  R0, R0, 0      infinite loop (halt)
--
-- Instruction encoding (16-bit):
--   LLI  R1, 5  : opcode=0011 RA=001 imm9=000000101 => 0x3205
--   LLI  R2, 3  : opcode=0011 RA=010 imm9=000000011 => 0x3403
--   ADD  R3=R1+R2: opcode=0001 RA=001 RB=010 RC=011 cmp=0 cond=00 => 0x1298
--   BEQ  R0,R0,0: opcode=1000 RA=000 RB=000 imm6=000000 => 0x8000
--
-- Expected results after ~50 cycles:
--   regs_out(1) = 0x0005
--   regs_out(2) = 0x0003
--   regs_out(3) = 0x0008

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

  constant CLK_PERIOD : time := 10 ns;

  -- Test program
  type program_t is array (natural range <>) of std_logic_vector(15 downto 0);
  constant PROG : program_t(0 to 3) := (
    x"3205",   -- LLI  R1, 5       byte addr 0x0000
    x"3403",   -- LLI  R2, 3       byte addr 0x0002
    x"1298",   -- ADD  R3, R1, R2  byte addr 0x0004
    x"8000"    -- BEQ  R0, R0, 0   byte addr 0x0006  (halt loop)
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
      imem_wr_data => imem_wr_data
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

    -- One extra cycle for memory write to settle
    wait until rising_edge(clk);

    -- Release reset — processor starts fetching from PC=0
    reset <= '0';

    -- Run for 50 cycles — enough for all 4 instructions to
    -- fetch, decode, rename, issue, execute, and retire
    for i in 0 to 49 loop
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
           & " C=" & std_logic'image(c_flag)
           & " Z=" & std_logic'image(z_flag);
    end loop;
  end process;

end architecture;
