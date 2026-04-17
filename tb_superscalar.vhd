library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pkg.all;

-- Comprehensive testbench for superscalar_top
-- 14 test cases covering all implemented instructions:
--   T1:  LLI, ADI, ADA, NDU  (ALU basics)
--   T2:  ADZ true + false     (predicated add-if-zero)
--   T3:  ADC false + true     (predicated add-if-carry)
--   T4:  AWC                  (add with carry operand)
--   T5:  ACA                  (complement add = A + ~B)
--   T6:  LW                   (load from pre-initialized memory)
--   T7:  BEQ taken            (skip one instruction)
--   T8:  BEQ not-taken        (fall through)
--   T9:  BLT taken            (signed less-than)
--   T10: BLE taken            (signed less-or-equal)
--   T11: JAL                  (jump and link)
--   T12: JLR                  (jump to register)
--   T13: JRI                  (jump register + immediate)
--   T14: SW                   (store smoke test)
--
-- Each test: assert reset, load program into imem, optionally init dmem,
-- release reset, run N cycles, check register values.

entity tb_superscalar is
end entity;

architecture sim of tb_superscalar is

  signal clk   : std_logic := '0';
  signal reset : std_logic := '1';

  signal regs_out : reg_file_t;
  signal c_flag   : std_logic;
  signal z_flag   : std_logic;

  signal imem_wr_en   : std_logic := '0';
  signal imem_wr_addr : std_logic_vector(15 downto 0) := (others => '0');
  signal imem_wr_data : std_logic_vector(15 downto 0) := (others => '0');

  signal dmem_wr_en   : std_logic := '0';
  signal dmem_wr_addr : std_logic_vector(15 downto 0) := (others => '0');
  signal dmem_wr_data : std_logic_vector(15 downto 0) := (others => '0');

  constant CLK_PERIOD : time := 10 ns;

begin

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

  clk <= not clk after CLK_PERIOD / 2;

  process
    variable num_tests  : integer := 0;
    variable num_passed : integer := 0;
    variable test_ok    : boolean;

    -- Helper: check one register value
    procedure check_reg(
      constant name : in string;
      constant idx  : in integer;
      constant exp  : in std_logic_vector(15 downto 0)
    ) is
    begin
      if regs_out(idx) = exp then
        report name & ": PASS R" & integer'image(idx) &
               " = 0x" & to_hstring(exp);
      else
        report name & ": FAIL R" & integer'image(idx) &
               " expected 0x" & to_hstring(exp) &
               " got 0x" & to_hstring(regs_out(idx)) severity error;
        test_ok := false;
      end if;
    end procedure;

    -- Helper: write one word to instruction memory (byte address)
    procedure wr_imem(
      constant addr : in integer;
      constant data : in std_logic_vector(15 downto 0)
    ) is
    begin
      imem_wr_addr <= std_logic_vector(to_unsigned(addr, 16));
      imem_wr_data <= data;
      imem_wr_en   <= '1';
      wait until rising_edge(clk);
    end procedure;

    -- Helper: write one word to data memory (byte address)
    procedure wr_dmem(
      constant addr : in integer;
      constant data : in std_logic_vector(15 downto 0)
    ) is
    begin
      dmem_wr_addr <= std_logic_vector(to_unsigned(addr, 16));
      dmem_wr_data <= data;
      dmem_wr_en   <= '1';
      wait until rising_edge(clk);
      dmem_wr_en   <= '0';
    end procedure;

    -- Helper: assert reset and hold for 4 cycles
    procedure begin_test(constant name : in string) is
    begin
      report "========== " & name & " ==========";
      reset <= '1';
      for i in 0 to 3 loop
        wait until rising_edge(clk);
      end loop;
    end procedure;

    -- Helper: release reset, run for N cycles
    procedure run_test(constant cycles : in integer) is
    begin
      imem_wr_en <= '0';
      dmem_wr_en <= '0';
      wait until rising_edge(clk);
      reset <= '0';
      for i in 0 to cycles-1 loop
        wait until rising_edge(clk);
      end loop;
    end procedure;

    -- Helper: record test result
    procedure end_test is
    begin
      num_tests := num_tests + 1;
      if test_ok then
        num_passed := num_passed + 1;
        report "  -> PASSED";
      else
        report "  -> FAILED" severity error;
      end if;
    end procedure;

  begin

    --------------------------------------------------------------------
    -- T1: ALU basics (LLI, ADI, ADA, NDU)
    --   LLI R1, 5      -> R1 = 0x0005
    --   LLI R2, 3      -> R2 = 0x0003
    --   ADI R3, R1, 2  -> R3 = 5+2 = 7
    --   ADA R4, R1, R2 -> R4 = 5+3 = 8
    --   NDU R5, R1, R2 -> R5 = ~(5&3) = 0xFFFE
    --   BEQ R0,R0,0    -> halt
    --------------------------------------------------------------------
    begin_test("T1: ALU basics (LLI, ADI, ADA, NDU)");
    wr_imem(16#0000#, x"3205");  -- LLI R1, 5
    wr_imem(16#0002#, x"3403");  -- LLI R2, 3
    wr_imem(16#0004#, x"02C2");  -- ADI R3, R1, 2
    wr_imem(16#0006#, x"12A0");  -- ADA R4, R1, R2
    wr_imem(16#0008#, x"22A8");  -- NDU R5, R1, R2
    wr_imem(16#000A#, x"8000");  -- BEQ R0,R0,0
    run_test(60);
    test_ok := true;
    check_reg("T1", 1, x"0005");
    check_reg("T1", 2, x"0003");
    check_reg("T1", 3, x"0007");
    check_reg("T1", 4, x"0008");
    check_reg("T1", 5, x"FFFE");
    end_test;

    --------------------------------------------------------------------
    -- T2: Predicated ADZ (true then false)
    --   After reset: Z=1, C=0
    --   LLI R1, 5           -> R1 = 5
    --   LLI R2, 3           -> R2 = 3
    --   ADZ R3, R1, R2      -> Z=1 => exec, R3=8, new Z=0
    --   ADZ R4, R1, R2      -> Z=0 => NOP, R4 stays 0
    --   BEQ R0,R0,0         -> halt
    --------------------------------------------------------------------
    begin_test("T2: Predicated ADZ (true + false)");
    wr_imem(16#0000#, x"3205");  -- LLI R1, 5
    wr_imem(16#0002#, x"3403");  -- LLI R2, 3
    wr_imem(16#0004#, x"1299");  -- ADZ R3, R1, R2
    wr_imem(16#0006#, x"12A1");  -- ADZ R4, R1, R2
    wr_imem(16#0008#, x"8000");  -- halt
    run_test(60);
    test_ok := true;
    check_reg("T2", 1, x"0005");
    check_reg("T2", 2, x"0003");
    check_reg("T2", 3, x"0008");
    check_reg("T2", 4, x"0000");
    end_test;

    --------------------------------------------------------------------
    -- T3: Predicated ADC (false then setup carry then true)
    --   After reset: C=0
    --   LLI R1, 5           -> R1 = 5
    --   LLI R2, 3           -> R2 = 3
    --   ADC R3, R1, R2      -> C=0 => NOP, R3=0
    --   NDU R6, R0, R0      -> R6 = ~0 = 0xFFFF
    --   ADI R7, R6, 1       -> R7 = 0xFFFF+1 = 0, C=1
    --   ADC R4, R1, R2      -> C=1 => exec, R4=8
    --   BEQ R0,R0,0         -> halt
    --------------------------------------------------------------------
    begin_test("T3: Predicated ADC (false + true)");
    wr_imem(16#0000#, x"3205");  -- LLI R1, 5
    wr_imem(16#0002#, x"3403");  -- LLI R2, 3
    wr_imem(16#0004#, x"129A");  -- ADC R3, R1, R2
    wr_imem(16#0006#, x"2030");  -- NDU R6, R0, R0
    wr_imem(16#0008#, x"0DC1");  -- ADI R7, R6, 1
    wr_imem(16#000A#, x"12A2");  -- ADC R4, R1, R2
    wr_imem(16#000C#, x"8000");  -- halt
    run_test(80);
    test_ok := true;
    check_reg("T3", 1, x"0005");
    check_reg("T3", 2, x"0003");
    check_reg("T3", 3, x"0000");
    check_reg("T3", 6, x"FFFF");
    check_reg("T3", 7, x"0000");
    check_reg("T3", 4, x"0008");
    end_test;

    --------------------------------------------------------------------
    -- T4: AWC (add with carry as operand)
    --   NDU R6, R0, R0      -> R6 = 0xFFFF
    --   ADI R7, R6, 1       -> R7 = 0, C=1
    --   LLI R1, 5           -> R1 = 5
    --   LLI R2, 3           -> R2 = 3
    --   AWC R3, R1, R2      -> R3 = 5+3+C = 5+3+1 = 9
    --   BEQ R0,R0,0         -> halt
    --------------------------------------------------------------------
    begin_test("T4: AWC (add with carry)");
    wr_imem(16#0000#, x"2030");  -- NDU R6, R0, R0
    wr_imem(16#0002#, x"0DC1");  -- ADI R7, R6, 1
    wr_imem(16#0004#, x"3205");  -- LLI R1, 5
    wr_imem(16#0006#, x"3403");  -- LLI R2, 3
    wr_imem(16#0008#, x"129B");  -- AWC R3, R1, R2
    wr_imem(16#000A#, x"8000");  -- halt
    run_test(80);
    test_ok := true;
    check_reg("T4", 6, x"FFFF");
    check_reg("T4", 7, x"0000");
    check_reg("T4", 1, x"0005");
    check_reg("T4", 2, x"0003");
    check_reg("T4", 3, x"0009");
    end_test;

    --------------------------------------------------------------------
    -- T5: ACA (complement add: result = A + ~B)
    --   LLI R1, 10          -> R1 = 0x000A
    --   LLI R2, 3           -> R2 = 0x0003
    --   ACA R3, R1, R2      -> R3 = 10 + ~3 = 10 + 0xFFFC = 0x0006
    --   BEQ R0,R0,0         -> halt
    --------------------------------------------------------------------
    begin_test("T5: ACA (complement add)");
    wr_imem(16#0000#, x"320A");  -- LLI R1, 10
    wr_imem(16#0002#, x"3403");  -- LLI R2, 3
    wr_imem(16#0004#, x"129C");  -- ACA R3, R1, R2
    wr_imem(16#0006#, x"8000");  -- halt
    run_test(60);
    test_ok := true;
    check_reg("T5", 1, x"000A");
    check_reg("T5", 2, x"0003");
    check_reg("T5", 3, x"0006");
    end_test;

    --------------------------------------------------------------------
    -- T6: LW (load word from pre-initialized memory)
    --   LW R1, R0, 0        -> R1 = dmem[0] = 0xBEEF
    --   BEQ R0,R0,0         -> halt
    --   dmem[0] pre-initialized to 0xBEEF
    --------------------------------------------------------------------
    begin_test("T6: LW (load word)");
    wr_imem(16#0000#, x"4200");  -- LW R1, R0, 0
    wr_imem(16#0002#, x"8000");  -- halt
    wr_dmem(0, x"BEEF");
    run_test(60);
    test_ok := true;
    check_reg("T6", 1, x"BEEF");
    end_test;

    --------------------------------------------------------------------
    -- T7: BEQ taken (skip one instruction)
    --   0x0000: LLI R1, 5
    --   0x0002: BEQ R0, R0, 2   -> taken, target = 0x0002+4 = 0x0006
    --   0x0004: LLI R2, 99      -> SKIPPED
    --   0x0006: LLI R3, 7
    --   0x0008: BEQ R0,R0,0     -> halt
    --------------------------------------------------------------------
    begin_test("T7: BEQ taken");
    wr_imem(16#0000#, x"3205");  -- LLI R1, 5
    wr_imem(16#0002#, x"8002");  -- BEQ R0, R0, 2
    wr_imem(16#0004#, x"3463");  -- LLI R2, 99
    wr_imem(16#0006#, x"3607");  -- LLI R3, 7
    wr_imem(16#0008#, x"8000");  -- halt
    run_test(100);
    test_ok := true;
    check_reg("T7", 1, x"0005");
    check_reg("T7", 2, x"0000");
    check_reg("T7", 3, x"0007");
    end_test;

    --------------------------------------------------------------------
    -- T8: BEQ not-taken (fall through)
    --   0x0000: LLI R1, 5
    --   0x0002: LLI R2, 3
    --   0x0004: BEQ R1, R2, 2   -> not taken (5 != 3)
    --   0x0006: LLI R3, 7       -> reached
    --   0x0008: BEQ R0,R0,0     -> halt
    --------------------------------------------------------------------
    begin_test("T8: BEQ not-taken");
    wr_imem(16#0000#, x"3205");  -- LLI R1, 5
    wr_imem(16#0002#, x"3403");  -- LLI R2, 3
    wr_imem(16#0004#, x"8282");  -- BEQ R1, R2, 2
    wr_imem(16#0006#, x"3607");  -- LLI R3, 7
    wr_imem(16#0008#, x"8000");  -- halt
    run_test(60);
    test_ok := true;
    check_reg("T8", 1, x"0005");
    check_reg("T8", 2, x"0003");
    check_reg("T8", 3, x"0007");
    end_test;

    --------------------------------------------------------------------
    -- T9: BLT taken (signed: 3 < 5)
    --   0x0000: LLI R1, 3
    --   0x0002: LLI R2, 5
    --   0x0004: BLT R1, R2, 2   -> taken (3<5), target = 0x0004+4 = 0x0008
    --   0x0006: LLI R3, 99      -> SKIPPED
    --   0x0008: LLI R4, 42
    --   0x000A: BEQ R0,R0,0     -> halt
    --------------------------------------------------------------------
    begin_test("T9: BLT taken");
    wr_imem(16#0000#, x"3203");  -- LLI R1, 3
    wr_imem(16#0002#, x"3405");  -- LLI R2, 5
    wr_imem(16#0004#, x"9282");  -- BLT R1, R2, 2
    wr_imem(16#0006#, x"3663");  -- LLI R3, 99
    wr_imem(16#0008#, x"382A");  -- LLI R4, 42
    wr_imem(16#000A#, x"8000");  -- halt
    run_test(100);
    test_ok := true;
    check_reg("T9", 1, x"0003");
    check_reg("T9", 2, x"0005");
    check_reg("T9", 3, x"0000");
    check_reg("T9", 4, x"002A");
    end_test;

    --------------------------------------------------------------------
    -- T10: BLE taken (equal case: 5 <= 5)
    --   0x0000: LLI R1, 5
    --   0x0002: LLI R2, 5
    --   0x0004: BLE R1, R2, 2   -> taken (5<=5), target = 0x0008
    --   0x0006: LLI R3, 99      -> SKIPPED
    --   0x0008: LLI R4, 42
    --   0x000A: BEQ R0,R0,0     -> halt
    --------------------------------------------------------------------
    begin_test("T10: BLE taken (equal)");
    wr_imem(16#0000#, x"3205");  -- LLI R1, 5
    wr_imem(16#0002#, x"3405");  -- LLI R2, 5
    wr_imem(16#0004#, x"A282");  -- BLE R1, R2, 2
    wr_imem(16#0006#, x"3663");  -- LLI R3, 99
    wr_imem(16#0008#, x"382A");  -- LLI R4, 42
    wr_imem(16#000A#, x"8000");  -- halt
    run_test(100);
    test_ok := true;
    check_reg("T10", 1, x"0005");
    check_reg("T10", 2, x"0005");
    check_reg("T10", 3, x"0000");
    check_reg("T10", 4, x"002A");
    end_test;

    --------------------------------------------------------------------
    -- T11: JAL (jump and link)
    --   0x0000: JAL R1, 3       -> R1 = PC+2 = 0x0002, jump to PC+6 = 0x0006
    --   0x0002: LLI R2, 99      -> SKIPPED (never fetched: JAL predicted taken)
    --   0x0004: LLI R3, 99      -> SKIPPED
    --   0x0006: LLI R4, 42
    --   0x0008: BEQ R0,R0,0     -> halt
    --------------------------------------------------------------------
    begin_test("T11: JAL");
    wr_imem(16#0000#, x"C203");  -- JAL R1, 3
    wr_imem(16#0002#, x"3463");  -- LLI R2, 99
    wr_imem(16#0004#, x"3663");  -- LLI R3, 99
    wr_imem(16#0006#, x"382A");  -- LLI R4, 42
    wr_imem(16#0008#, x"8000");  -- halt
    run_test(100);
    test_ok := true;
    check_reg("T11", 1, x"0002");
    check_reg("T11", 2, x"0000");
    check_reg("T11", 3, x"0000");
    check_reg("T11", 4, x"002A");
    end_test;

    --------------------------------------------------------------------
    -- T12: JLR (jump to register, link return address)
    --   0x0000: LLI R1, 8       -> R1 = 0x0008
    --   0x0002: LLI R6, 1       -> R6 = 1 (filler)
    --   0x0004: JLR R2, R1      -> R2 = PC+2 = 0x0006, jump to R1 = 0x0008
    --   0x0006: LLI R3, 99      -> SKIPPED
    --   0x0008: LLI R4, 42
    --   0x000A: BEQ R0,R0,0     -> halt
    --------------------------------------------------------------------
    begin_test("T12: JLR");
    wr_imem(16#0000#, x"3208");  -- LLI R1, 8
    wr_imem(16#0002#, x"3C01");  -- LLI R6, 1
    wr_imem(16#0004#, x"D440");  -- JLR R2, R1
    wr_imem(16#0006#, x"3663");  -- LLI R3, 99
    wr_imem(16#0008#, x"382A");  -- LLI R4, 42
    wr_imem(16#000A#, x"8000");  -- halt
    run_test(100);
    test_ok := true;
    check_reg("T12", 1, x"0008");
    check_reg("T12", 6, x"0001");
    check_reg("T12", 2, x"0006");
    check_reg("T12", 3, x"0000");
    check_reg("T12", 4, x"002A");
    end_test;

    --------------------------------------------------------------------
    -- T13: JRI (jump register + immediate, no link)
    --   0x0000: LLI R1, 4       -> R1 = 0x0004
    --   0x0002: JRI R1, 2       -> jump to R1 + 2*2 = 4+4 = 0x0008
    --   0x0004: LLI R2, 99      -> SKIPPED
    --   0x0006: LLI R3, 99      -> SKIPPED
    --   0x0008: LLI R4, 42
    --   0x000A: BEQ R0,R0,0     -> halt
    --------------------------------------------------------------------
    begin_test("T13: JRI");
    wr_imem(16#0000#, x"3204");  -- LLI R1, 4
    wr_imem(16#0002#, x"F202");  -- JRI R1, 2
    wr_imem(16#0004#, x"3463");  -- LLI R2, 99
    wr_imem(16#0006#, x"3663");  -- LLI R3, 99
    wr_imem(16#0008#, x"382A");  -- LLI R4, 42
    wr_imem(16#000A#, x"8000");  -- halt
    run_test(100);
    test_ok := true;
    check_reg("T13", 1, x"0004");
    check_reg("T13", 2, x"0000");
    check_reg("T13", 3, x"0000");
    check_reg("T13", 4, x"002A");
    end_test;

    --------------------------------------------------------------------
    -- T14: SW (store word smoke test -- verify pipeline survives)
    --   0x0000: LLI R1, 0xAB    -> R1 = 0x00AB
    --   0x0002: LLI R2, 4       -> R2 = 0x0004 (store address)
    --   0x0004: SW  R1, R2, 0   -> dmem[4] = R1 (can't verify without LW)
    --   0x0006: LLI R3, 42      -> R3 = 42 (proves pipeline didn't stall)
    --   0x0008: BEQ R0,R0,0     -> halt
    --------------------------------------------------------------------
    begin_test("T14: SW (smoke test)");
    wr_imem(16#0000#, x"32AB");  -- LLI R1, 0xAB
    wr_imem(16#0002#, x"3404");  -- LLI R2, 4
    wr_imem(16#0004#, x"5280");  -- SW R1, R2, 0
    wr_imem(16#0006#, x"362A");  -- LLI R3, 42
    wr_imem(16#0008#, x"8000");  -- halt
    run_test(80);
    test_ok := true;
    check_reg("T14", 1, x"00AB");
    check_reg("T14", 2, x"0004");
    check_reg("T14", 3, x"002A");
    end_test;

    --------------------------------------------------------------------
    -- Summary
    --------------------------------------------------------------------
    report "===========================================";
    report "RESULTS: " & integer'image(num_passed) & " / " &
           integer'image(num_tests) & " tests passed";
    if num_passed = num_tests then
      report "*** ALL TESTS PASSED ***";
    else
      report "*** SOME TESTS FAILED ***" severity error;
    end if;

    wait;
  end process;

end architecture;
