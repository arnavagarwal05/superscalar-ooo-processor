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
    -- T15: Store-to-load forwarding
    --   SW then immediate LW to same address — load must get data
    --   from store buffer before it drains to memory.
    --   0x0000: LLI R1, 0xAB   -> R1 = 0x00AB (store data)
    --   0x0002: LLI R2, 4      -> R2 = 0x0004 (address)
    --   0x0004: SW  R1, R2, 0  -> SB[addr=4] = 0x00AB
    --   0x0006: LW  R3, R2, 0  -> R3 = 0x00AB (forwarded from SB)
    --   0x0008: BEQ R0,R0,0    -> halt
    --------------------------------------------------------------------
    begin_test("T15: Store-to-load forwarding");
    wr_imem(16#0000#, x"32AB");  -- LLI R1, 0xAB
    wr_imem(16#0002#, x"3404");  -- LLI R2, 4
    wr_imem(16#0004#, x"5280");  -- SW R1, R2, 0
    wr_imem(16#0006#, x"4680");  -- LW R3, R2, 0
    wr_imem(16#0008#, x"8000");  -- halt
    run_test(100);
    test_ok := true;
    check_reg("T15", 1, x"00AB");
    check_reg("T15", 2, x"0004");
    check_reg("T15", 3, x"00AB");
    end_test;

    --------------------------------------------------------------------
    -- T16: Comprehensive stress test (31 instructions)
    --
    -- Phase 1 (0x00-0x0C): Init R1..R7 = 1..7
    -- Phase 2 (0x0E-0x14): Dependency chain
    --   ADA R1,R1,R2  -> R1 = 1+2 = 3
    --   ADA R1,R1,R3  -> R1 = 3+3 = 6
    --   ADA R1,R1,R4  -> R1 = 6+4 = 10
    --   ADI R1,R1,5   -> R1 = 10+5 = 15
    -- Phase 3 (0x16-0x1A): WAW hazard
    --   LLI R2,10 then LLI R2,20 -> R2 = 20 (second wins)
    --   ADI R3,R2,1   -> R3 = 21 (must use R2=20)
    -- Phase 4 (0x1C-0x20): Store-to-load forwarding
    --   LLI R4,0x50; SW R3,R4,0; LW R5,R4,0 -> R5 = 21
    -- Phase 5 (0x22-0x2A): Predicated instructions
    --   ADA R6,R5,R5  -> R6=42, C=0, Z=0
    --   ADC R7,R1,R2  -> C=0 so NOP, R7 stays 7
    --   LLI R6,0; ADA R6,R6,R6 -> R6=0, Z=1
    --   ADZ R7,R1,R2  -> Z=1 so execute, R7=15+20=35
    -- Phase 6 (0x2C-0x32): Branch taken + not-taken
    --   BEQ R1,R2,2   -> not taken (15!=20)
    --   LLI R6,0x42   -> executes (R6=66)
    --   BEQ R1,R1,2   -> taken, skip next
    --   LLI R6,0x99   -> SKIPPED
    -- Phase 7 (0x34-0x3A): JAL jump-over
    --   JAL R3,3      -> R3=0x36, jump to 0x3A
    --   LLI R1,0xFF   -> SKIPPED
    --   LLI R2,0xFF   -> SKIPPED
    --   ADI R4,R5,10  -> R4 = 21+10 = 31
    -- 0x3C: BEQ R0,R0,0 -> halt
    --
    -- Expected: R1=15, R2=20, R3=0x36, R4=31, R5=21, R6=66, R7=35
    --------------------------------------------------------------------
    begin_test("T16: Comprehensive (31 instr)");
    -- Phase 1: init
    wr_imem(16#0000#, x"3201");  -- LLI R1, 1
    wr_imem(16#0002#, x"3402");  -- LLI R2, 2
    wr_imem(16#0004#, x"3603");  -- LLI R3, 3
    wr_imem(16#0006#, x"3804");  -- LLI R4, 4
    wr_imem(16#0008#, x"3A05");  -- LLI R5, 5
    wr_imem(16#000A#, x"3C06");  -- LLI R6, 6
    wr_imem(16#000C#, x"3E07");  -- LLI R7, 7
    -- Phase 2: dependency chain
    wr_imem(16#000E#, x"1288");  -- ADA R1, R1, R2
    wr_imem(16#0010#, x"12C8");  -- ADA R1, R1, R3
    wr_imem(16#0012#, x"1308");  -- ADA R1, R1, R4
    wr_imem(16#0014#, x"0245");  -- ADI R1, R1, 5
    -- Phase 3: WAW
    wr_imem(16#0016#, x"340A");  -- LLI R2, 10
    wr_imem(16#0018#, x"3414");  -- LLI R2, 20
    wr_imem(16#001A#, x"04C1");  -- ADI R3, R2, 1
    -- Phase 4: store-load forwarding
    wr_imem(16#001C#, x"3850");  -- LLI R4, 0x50
    wr_imem(16#001E#, x"5700");  -- SW R3, R4, 0
    wr_imem(16#0020#, x"4B00");  -- LW R5, R4, 0
    -- Phase 5: predicated
    wr_imem(16#0022#, x"1B70");  -- ADA R6, R5, R5  (sets C=0, Z=0)
    wr_imem(16#0024#, x"12BA");  -- ADC R7, R1, R2  (C=0 -> NOP)
    wr_imem(16#0026#, x"3C00");  -- LLI R6, 0
    wr_imem(16#0028#, x"1DB0");  -- ADA R6, R6, R6  (0+0=0, Z=1)
    wr_imem(16#002A#, x"12B9");  -- ADZ R7, R1, R2  (Z=1 -> R7=35)
    -- Phase 6: branches
    wr_imem(16#002C#, x"8282");  -- BEQ R1, R2, 2   (not taken)
    wr_imem(16#002E#, x"3C42");  -- LLI R6, 0x42
    wr_imem(16#0030#, x"8242");  -- BEQ R1, R1, 2   (taken -> 0x34)
    wr_imem(16#0032#, x"3C99");  -- LLI R6, 0x99    (SKIPPED)
    -- Phase 7: JAL
    wr_imem(16#0034#, x"C603");  -- JAL R3, 3       (R3=0x36, -> 0x3A)
    wr_imem(16#0036#, x"32FF");  -- LLI R1, 0xFF    (SKIPPED)
    wr_imem(16#0038#, x"34FF");  -- LLI R2, 0xFF    (SKIPPED)
    wr_imem(16#003A#, x"0B0A");  -- ADI R4, R5, 10
    wr_imem(16#003C#, x"8000");  -- halt
    run_test(500);
    test_ok := true;
    check_reg("T16", 1, x"000F");  -- 15
    check_reg("T16", 2, x"0014");  -- 20
    check_reg("T16", 3, x"0036");  -- JAL return addr
    check_reg("T16", 4, x"001F");  -- 31
    check_reg("T16", 5, x"0015");  -- 21 (forwarded load)
    check_reg("T16", 6, x"0042");  -- 66 (branch skipped 0x99)
    check_reg("T16", 7, x"0023");  -- 35 (ADZ executed)
    end_test;

    --------------------------------------------------------------------
    -- T17: Loop test — sum 1..5 using backward BLT branch
    --
    --   0x00: LLI R1, 5       counter = 5
    --   0x02: LLI R2, 0       accumulator = 0
    --   loop:
    --   0x04: ADA R2, R2, R1  acc += counter
    --   0x06: ADI R1, R1, -1  counter--
    --   0x08: BLT R0, R1, -2  if 0 < counter, branch to 0x04
    --   exit:
    --   0x0A: LLI R3, 0x55    marker (proves loop exited)
    --   0x0C: BEQ R0, R0, 0   halt
    --
    -- 5 iterations: R2 = 5+4+3+2+1 = 15, R1 = 0, R3 = 0x55
    --------------------------------------------------------------------
    begin_test("T17: Loop (sum 1..5)");
    wr_imem(16#0000#, x"3205");  -- LLI R1, 5
    wr_imem(16#0002#, x"3400");  -- LLI R2, 0
    wr_imem(16#0004#, x"1450");  -- ADA R2, R2, R1
    wr_imem(16#0006#, x"027F");  -- ADI R1, R1, -1
    wr_imem(16#0008#, x"907E");  -- BLT R0, R1, -2  (-> 0x04)
    wr_imem(16#000A#, x"3655");  -- LLI R3, 0x55
    wr_imem(16#000C#, x"8000");  -- halt
    run_test(300);
    test_ok := true;
    check_reg("T17", 1, x"0000");  -- counter exhausted
    check_reg("T17", 2, x"000F");  -- sum = 15
    check_reg("T17", 3, x"0055");  -- exit marker
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
