library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pkg.all;

-- Simple per-instruction testbench
-- Tests each instruction independently with a short program + halt
-- Skips LM/SM (not implemented)
--
-- Encoding cheat-sheet:
--   LLI  Rd, k    : 0011_Rd_k[8:0]                       0x3000|(Rd<<9)|k
--   ADI  Rd, Rs, k: 0000_Rs_Rd_k[5:0]  (Rs=src, Rd=dst)  0x0000|(Rs<<9)|(Rd<<6)|k
--   ADD  Rc,Ra,Rb  : 0001_Ra_Rb_Rc_cmp_cond               0x1000|(Ra<<9)|(Rb<<6)|(Rc<<3)|(cmp<<2)|cond
--   NDU  Rc,Ra,Rb  : 0010_Ra_Rb_Rc_cmp_cond               (same, opcode=0010)
--   BEQ  Ra,Rb,off : 1000_Ra_Rb_off[5:0]
--   BLT  Ra,Rb,off : 1001_Ra_Rb_off[5:0]
--   BLE  Ra,Rb,off : 1010_Ra_Rb_off[5:0]
--   JAL  Rd, off9  : 1100_Rd_off[8:0]
--   JLR  Rd, Rs    : 1101_Rd_Rs_000000   (link->Rd, jump->Rs)
--   JRI  Rs, off9  : 1111_Rs_off[8:0]    (jump to Rs + 2*off)
--   LW   Rd, Rb,off: 0100_Rd_Rb_off[5:0]
--   SW   Ra, Rb,off: 0101_Ra_Rb_off[5:0] (Ra=data, Rb=base)
--   cond: 00=always 01=Z 10=C 11=carry_in(AWC)
--   cmp : 0=normal  1=complement src2

entity tb_instr is
end entity;

architecture sim of tb_instr is
  signal clk          : std_logic := '0';
  signal reset        : std_logic := '1';
  signal regs_out     : reg_file_t;
  signal c_flag       : std_logic;
  signal z_flag       : std_logic;
  signal imem_wr_en   : std_logic := '0';
  signal imem_wr_addr : std_logic_vector(15 downto 0) := (others => '0');
  signal imem_wr_data : std_logic_vector(15 downto 0) := (others => '0');
  signal dmem_wr_en   : std_logic := '0';
  signal dmem_wr_addr : std_logic_vector(15 downto 0) := (others => '0');
  signal dmem_wr_data : std_logic_vector(15 downto 0) := (others => '0');
  constant CLK_PERIOD : time := 10 ns;
begin

  dut : entity work.superscalar_top
    port map(
      clk          => clk,          reset        => reset,
      regs_out     => regs_out,     c_flag       => c_flag,
      z_flag       => z_flag,
      imem_wr_en   => imem_wr_en,   imem_wr_addr => imem_wr_addr,
      imem_wr_data => imem_wr_data,
      dmem_wr_en   => dmem_wr_en,   dmem_wr_addr => dmem_wr_addr,
      dmem_wr_data => dmem_wr_data
    );

  clk <= not clk after CLK_PERIOD / 2;

  process
    variable passed : integer := 0;
    variable total  : integer := 0;

    procedure wi(constant a : integer; constant d : std_logic_vector(15 downto 0)) is
    begin
      imem_wr_addr <= std_logic_vector(to_unsigned(a, 16));
      imem_wr_data <= d;
      imem_wr_en   <= '1';
      wait until rising_edge(clk);
    end procedure;

    procedure wd(constant a : integer; constant d : std_logic_vector(15 downto 0)) is
    begin
      dmem_wr_addr <= std_logic_vector(to_unsigned(a, 16));
      dmem_wr_data <= d;
      dmem_wr_en   <= '1';
      wait until rising_edge(clk);
    end procedure;

    -- Write 4 halts starting at byte address a (covers 8 bytes)
    procedure halt_here(constant a : integer) is
    begin
      wi(a,   x"8000");  -- BEQ R0,R0,0
      wi(a+2, x"8000");
      wi(a+4, x"8000");
      wi(a+6, x"8000");
    end procedure;

    procedure setup is
    begin
      reset <= '1';
      for i in 0 to 3 loop wait until rising_edge(clk); end loop;
    end procedure;

    procedure go(constant n : integer) is
    begin
      imem_wr_en <= '0';
      dmem_wr_en <= '0';
      wait until rising_edge(clk);
      reset <= '0';
      for i in 0 to n-1 loop wait until rising_edge(clk); end loop;
    end procedure;

    procedure chk(constant name : string; constant r : integer;
                  constant exp  : std_logic_vector(15 downto 0)) is
    begin
      total := total + 1;
      if regs_out(r) = exp then
        report name & ": PASS  R" & integer'image(r) & "=0x" & to_hstring(exp);
        passed := passed + 1;
      else
        report name & ": FAIL  R" & integer'image(r) &
               "  expected=0x" & to_hstring(exp) &
               "  got=0x"      & to_hstring(regs_out(r)) severity error;
      end if;
    end procedure;

  begin

    --------------------------------------------------------------------------
    -- T1: LLI  — load lower immediate
    --   LLI R1, 0xAB  -> R1 = 0x00AB
    --------------------------------------------------------------------------
    report "=== T1: LLI ===";
    setup;
    wi(16#00#, x"32AB");  -- LLI R1, 0xAB     (0011_001_010101011)
    halt_here(16#02#);
    go(30);
    chk("LLI", 1, x"00AB");

    --------------------------------------------------------------------------
    -- T2: ADI  — add immediate
    --   LLI R1,10 ; ADI R2,R1,7  -> R2 = 17
    --------------------------------------------------------------------------
    report "=== T2: ADI ===";
    setup;
    wi(16#00#, x"320A");  -- LLI R1, 10
    wi(16#02#, x"0287");  -- ADI R2,R1,7   (0000_001_010_000111 : src=R1 dst=R2 imm=7)
    halt_here(16#04#);
    go(30);
    chk("ADI", 2, x"0011");  -- 17

    --------------------------------------------------------------------------
    -- T3: ADA  — add always
    --   LLI R1,5 ; LLI R2,8 ; ADA R3,R1,R2  -> R3 = 13
    --------------------------------------------------------------------------
    report "=== T3: ADA ===";
    setup;
    wi(16#00#, x"3205");  -- LLI R1, 5
    wi(16#02#, x"3408");  -- LLI R2, 8
    wi(16#04#, x"1298");  -- ADA R3,R1,R2  (0001_001_010_011_0_00)
    halt_here(16#06#);
    go(40);
    chk("ADA", 3, x"000D");  -- 13

    --------------------------------------------------------------------------
    -- T4: NDU  — NAND unconditional
    --   LLI R1,0xFF ; LLI R2,0xFF ; NDU R3,R1,R2
    --   -> R3 = 0x00FF NAND 0x00FF = NOT(0x00FF) = 0xFF00
    --------------------------------------------------------------------------
    report "=== T4: NDU ===";
    setup;
    wi(16#00#, x"32FF");  -- LLI R1, 0xFF
    wi(16#02#, x"34FF");  -- LLI R2, 0xFF
    wi(16#04#, x"2298");  -- NDU R3,R1,R2  (0010_001_010_011_0_00)
    halt_here(16#06#);
    go(40);
    chk("NDU", 3, x"FF00");

    --------------------------------------------------------------------------
    -- T5: ACA  — add complement always  (R1 + NOT R2, complement=1)
    --   LLI R1,10 ; LLI R2,3 ; ACA R3,R1,R2
    --   -> R3 = 0x000A + 0xFFFC = 0x0006  (carry=1)
    --------------------------------------------------------------------------
    report "=== T5: ACA ===";
    setup;
    wi(16#00#, x"320A");  -- LLI R1, 10
    wi(16#02#, x"3403");  -- LLI R2, 3
    wi(16#04#, x"129C");  -- ACA R3,R1,R2  (0001_001_010_011_1_00, cmp=1)
    halt_here(16#06#);
    go(40);
    chk("ACA", 3, x"0006");  -- 10 + ~3 = 6

    --------------------------------------------------------------------------
    -- T6: AWC  — add with carry (uses carry from previous instruction)
    --   LLI R1,1 ; ADI R1,R1,-1 -> R1=0 C=1 ; AWC R2,R0,R0 -> R2=0+0+1=1
    --   ADI R1,R1,63: imm6=111111 sign-extends to 0xFFFF=-1, so 1+(-1)=0 with C=1
    --------------------------------------------------------------------------
    report "=== T6: AWC ===";
    setup;
    wi(16#00#, x"3201");  -- LLI R1, 1
    wi(16#02#, x"027F");  -- ADI R1,R1,63(=-1)  (0000_001_001_111111) -> R1=0, C=1
    wi(16#04#, x"1013");  -- AWC R2,R0,R0  (0001_000_000_010_0_11, cond=11=AWC) -> R2=0+0+1=1
    halt_here(16#06#);
    go(40);
    chk("AWC", 2, x"0001");

    --------------------------------------------------------------------------
    -- T7: ADZ  — add if Z=1  (Z IS 1 -> executes)
    --   LLI R3,5 ; LLI R4,7 ; ADI R1,R0,0 (sets Z=1) ; ADZ R2,R3,R4 -> R2=12
    --------------------------------------------------------------------------
    report "=== T7: ADZ (Z=1, executes) ===";
    setup;
    wi(16#00#, x"3605");  -- LLI R3, 5
    wi(16#02#, x"3807");  -- LLI R4, 7
    wi(16#04#, x"0040");  -- ADI R1,R0,0  (0000_000_001_000000) -> R1=0, Z=1
    wi(16#06#, x"1711");  -- ADZ R2,R3,R4 (0001_011_100_010_0_01, cond=01=Z)
    halt_here(16#08#);
    go(50);
    chk("ADZ(Z=1)", 2, x"000C");  -- 5+7=12

    --------------------------------------------------------------------------
    -- T8: ADZ  — add if Z=0  (Z IS 0 -> NOP, dest keeps old value)
    --   Note: ARF initialises Z=1 after reset; use ADI R1,R0,5 (non-zero
    --   result) to clear Z to 0 first, then LLI R2,99; ADZ stays NOP.
    --------------------------------------------------------------------------
    report "=== T8: ADZ (Z=0, NOP) ===";
    setup;
    wi(16#00#, x"0045");  -- ADI R1,R0,5   (0000_000_001_000101) -> R1=5, Z=0
    wi(16#02#, x"3463");  -- LLI R2, 99
    wi(16#04#, x"1711");  -- ADZ R2,R3,R4  (Z=0 -> NOP, R2 stays 99)
    halt_here(16#06#);
    go(50);
    chk("ADZ(Z=0)", 2, x"0063");  -- stays 99

    --------------------------------------------------------------------------
    -- T9: ADC  — add if C=1  (C IS 1 -> executes)
    --   LLI R3,5 ; LLI R4,7 ; LLI R1,1 ; ADI R1,R1,-1 -> C=1 ; ADC R2,R3,R4 -> R2=12
    --------------------------------------------------------------------------
    report "=== T9: ADC (C=1, executes) ===";
    setup;
    wi(16#00#, x"3605");  -- LLI R3, 5
    wi(16#02#, x"3807");  -- LLI R4, 7
    wi(16#04#, x"3201");  -- LLI R1, 1
    wi(16#06#, x"027F");  -- ADI R1,R1,-1  -> R1=0, C=1
    wi(16#08#, x"1712");  -- ADC R2,R3,R4  (0001_011_100_010_0_10, cond=10=C)
    halt_here(16#0A#);
    go(50);
    chk("ADC(C=1)", 2, x"000C");  -- 5+7=12

    --------------------------------------------------------------------------
    -- T10: SW + LW  — store then load
    --   LLI R1,0xAB ; LLI R2,16 ; SW R1,R2,0 ; LW R3,R2,0 -> R3=0xAB
    --------------------------------------------------------------------------
    report "=== T10: SW + LW ===";
    setup;
    wi(16#00#, x"32AB");  -- LLI R1, 0xAB
    wi(16#02#, x"3410");  -- LLI R2, 16   (data memory address 16)
    wi(16#04#, x"5280");  -- SW R1,R2,0   (0101_001_010_000000 : data=R1 base=R2)
    wi(16#06#, x"4680");  -- LW R3,R2,0   (0100_011_010_000000 : dst=R3 base=R2)
    halt_here(16#08#);
    go(60);
    chk("SW+LW", 3, x"00AB");

    --------------------------------------------------------------------------
    -- T11: BEQ taken
    --   LLI R1,5 ; LLI R2,5 ; BEQ R1,R2,2 (taken, skip 0x06) ; LLI R3,0x99(skip) ; LLI R3,0x42
    --------------------------------------------------------------------------
    report "=== T11: BEQ taken ===";
    setup;
    wi(16#00#, x"3205");  -- LLI R1, 5
    wi(16#02#, x"3405");  -- LLI R2, 5
    wi(16#04#, x"8282");  -- BEQ R1,R2,2  (taken -> 0x04+4=0x08)
    wi(16#06#, x"3699");  -- LLI R3,0x99  SKIPPED
    wi(16#08#, x"3642");  -- LLI R3,0x42
    halt_here(16#0A#);
    go(60);
    chk("BEQ taken", 3, x"0042");

    --------------------------------------------------------------------------
    -- T12: BEQ not-taken
    --   LLI R1,3 ; LLI R2,5 ; BEQ R1,R2,2 (not taken) ; LLI R3,0x42 (executes)
    --------------------------------------------------------------------------
    report "=== T12: BEQ not-taken ===";
    setup;
    wi(16#00#, x"3203");  -- LLI R1, 3
    wi(16#02#, x"3405");  -- LLI R2, 5
    wi(16#04#, x"8282");  -- BEQ R1,R2,2  (not taken, 3!=5)
    wi(16#06#, x"3642");  -- LLI R3,0x42
    halt_here(16#08#);
    go(60);
    chk("BEQ not-taken", 3, x"0042");

    --------------------------------------------------------------------------
    -- T13: BLT taken  (signed less-than)
    --   LLI R1,3 ; LLI R2,5 ; BLT R1,R2,2 (3<5 taken, skip) ; LLI R3,0x99(skip) ; LLI R3,0x42
    --------------------------------------------------------------------------
    report "=== T13: BLT taken ===";
    setup;
    wi(16#00#, x"3203");  -- LLI R1, 3
    wi(16#02#, x"3405");  -- LLI R2, 5
    wi(16#04#, x"9282");  -- BLT R1,R2,2  (3<5 taken -> 0x08)
    wi(16#06#, x"3699");  -- LLI R3,0x99  SKIPPED
    wi(16#08#, x"3642");  -- LLI R3,0x42
    halt_here(16#0A#);
    go(60);
    chk("BLT taken", 3, x"0042");

    --------------------------------------------------------------------------
    -- T14: BLE taken  (equal case)
    --   LLI R1,5 ; LLI R2,5 ; BLE R1,R2,2 (5<=5 taken) ; LLI R3,0x99(skip) ; LLI R3,0x42
    --------------------------------------------------------------------------
    report "=== T14: BLE taken ===";
    setup;
    wi(16#00#, x"3205");  -- LLI R1, 5
    wi(16#02#, x"3405");  -- LLI R2, 5
    wi(16#04#, x"A282");  -- BLE R1,R2,2  (5<=5 taken -> 0x08)
    wi(16#06#, x"3699");  -- LLI R3,0x99  SKIPPED
    wi(16#08#, x"3642");  -- LLI R3,0x42
    halt_here(16#0A#);
    go(60);
    chk("BLE taken", 3, x"0042");

    --------------------------------------------------------------------------
    -- T15: JAL  — jump and link
    --   JAL R1,2 at 0x00: R1=0x02, jump to 0x00+4=0x04
    --   LLI R2,0x99 at 0x02 SKIPPED ; LLI R2,0x42 at 0x04
    --------------------------------------------------------------------------
    report "=== T15: JAL ===";
    setup;
    wi(16#00#, x"C202");  -- JAL R1,2   (1100_001_000000010: link=R1, imm=2, target=0x04)
    wi(16#02#, x"3499");  -- LLI R2,0x99  SKIPPED
    wi(16#04#, x"3442");  -- LLI R2,0x42
    halt_here(16#06#);
    go(50);
    chk("JAL link", 1, x"0002");  -- PC+2 saved
    chk("JAL skip", 2, x"0042");  -- landed at 0x04

    --------------------------------------------------------------------------
    -- T16: JLR  — jump to link register
    --   LLI R2,0x08 ; JLR R1,R2 at 0x02: R1=0x04, jump to R2=0x08
    --   (0x04 and 0x06 skipped) ; LLI R3,0x42 at 0x08
    --------------------------------------------------------------------------
    report "=== T16: JLR ===";
    setup;
    wi(16#00#, x"3408");  -- LLI R2, 0x08    (target address)
    wi(16#02#, x"D280");  -- JLR R1,R2  (1101_001_010_000000: link=R1, target=R2)
    wi(16#04#, x"3699");  -- LLI R3,0x99  SKIPPED
    wi(16#06#, x"3699");  -- LLI R3,0x99  SKIPPED
    wi(16#08#, x"3642");  -- LLI R3,0x42
    halt_here(16#0A#);
    go(60);
    chk("JLR link", 1, x"0004");  -- PC+2 = 0x02+2 = 0x04
    chk("JLR jump", 3, x"0042");

    --------------------------------------------------------------------------
    -- T17: JRI  — jump register + immediate
    --   LLI R1,0x04 ; JRI R1,2 at 0x02: jump to R1+2*2=0x04+4=0x08
    --   (0x04,0x06 skipped) ; LLI R2,0x42 at 0x08
    --------------------------------------------------------------------------
    report "=== T17: JRI ===";
    setup;
    wi(16#00#, x"3204");  -- LLI R1, 0x04
    wi(16#02#, x"F202");  -- JRI R1,2  (1111_001_000000010: src=R1, imm=2, target=0x04+4=0x08)
    wi(16#04#, x"3499");  -- LLI R2,0x99  SKIPPED
    wi(16#06#, x"3499");  -- LLI R2,0x99  SKIPPED
    wi(16#08#, x"3442");  -- LLI R2,0x42
    halt_here(16#0A#);
    go(60);
    chk("JRI", 2, x"0042");

    --------------------------------------------------------------------------
    -- T18: ACZ  — add complement if Z=1  (executes)
    --   LLI R1,10 ; LLI R2,3 ; ADI R4,R0,0 (Z=1) ; ACZ R3,R1,R2 -> R3 = 10+~3 = 6
    --------------------------------------------------------------------------
    report "=== T18: ACZ (Z=1, executes) ===";
    setup;
    wi(16#00#, x"320A");  -- LLI R1, 10
    wi(16#02#, x"3403");  -- LLI R2, 3
    wi(16#04#, x"0100");  -- ADI R4,R0,0  (0000_000_100_000000) -> R4=0, Z=1
    wi(16#06#, x"129D");  -- ACZ R3,R1,R2 (0001_001_010_011_1_01, cmp=1 cond=01)
    halt_here(16#08#);
    go(50);
    chk("ACZ(Z=1)", 3, x"0006");  -- 10 + ~3 = 6

    --------------------------------------------------------------------------
    -- T19: ACC  — add complement if C=1  (executes)
    --   LLI R1,10 ; LLI R2,3 ; LLI R5,1 ; ADI R5,R5,-1 (C=1) ; ACC R3,R1,R2 -> R3 = 6
    --------------------------------------------------------------------------
    report "=== T19: ACC (C=1, executes) ===";
    setup;
    wi(16#00#, x"320A");  -- LLI R1, 10
    wi(16#02#, x"3403");  -- LLI R2, 3
    wi(16#04#, x"3A01");  -- LLI R5, 1
    wi(16#06#, x"0B7F");  -- ADI R5,R5,63(=-1) (0000_101_101_111111) -> R5=0, C=1
    wi(16#08#, x"129E");  -- ACC R3,R1,R2 (0001_001_010_011_1_10, cmp=1 cond=10)
    halt_here(16#0A#);
    go(50);
    chk("ACC(C=1)", 3, x"0006");  -- 10 + ~3 = 6

    --------------------------------------------------------------------------
    -- T20: ACW  — add complement with carry  (R1 + ~R2 + C)
    --   LLI R1,10 ; LLI R2,3 ; set C=1 ; ACW R3,R1,R2 -> R3 = 10+~3+1 = 7
    --------------------------------------------------------------------------
    report "=== T20: ACW (add complement with carry) ===";
    setup;
    wi(16#00#, x"320A");  -- LLI R1, 10
    wi(16#02#, x"3403");  -- LLI R2, 3
    wi(16#04#, x"3A01");  -- LLI R5, 1
    wi(16#06#, x"0B7F");  -- ADI R5,R5,-1 -> C=1
    wi(16#08#, x"129F");  -- ACW R3,R1,R2 (0001_001_010_011_1_11, cmp=1 cond=11)
    halt_here(16#0A#);
    go(50);
    chk("ACW", 3, x"0007");  -- 10 + ~3 + 1 = 7

    --------------------------------------------------------------------------
    -- T21: NDZ  — NAND if Z=1  (executes)
    --   LLI R1,0xFF ; LLI R2,0x0F ; ADI R4,R0,0 (Z=1) ; NDZ R3,R1,R2 -> R3 = 0xFFF0
    --------------------------------------------------------------------------
    report "=== T21: NDZ (Z=1, executes) ===";
    setup;
    wi(16#00#, x"32FF");  -- LLI R1, 0xFF
    wi(16#02#, x"340F");  -- LLI R2, 0x0F
    wi(16#04#, x"0100");  -- ADI R4,R0,0 -> Z=1
    wi(16#06#, x"2299");  -- NDZ R3,R1,R2 (0010_001_010_011_0_01, cond=01)
    halt_here(16#08#);
    go(50);
    chk("NDZ(Z=1)", 3, x"FFF0");  -- 0xFF NAND 0x0F = NOT(0x000F) = 0xFFF0

    --------------------------------------------------------------------------
    -- T22: NDC  — NAND if C=1  (executes)
    --   LLI R1,0xFF ; LLI R2,0x0F ; set C=1 ; NDC R3,R1,R2 -> R3 = 0xFFF0
    --------------------------------------------------------------------------
    report "=== T22: NDC (C=1, executes) ===";
    setup;
    wi(16#00#, x"32FF");  -- LLI R1, 0xFF
    wi(16#02#, x"340F");  -- LLI R2, 0x0F
    wi(16#04#, x"3A01");  -- LLI R5, 1
    wi(16#06#, x"0B7F");  -- ADI R5,R5,-1 -> C=1
    wi(16#08#, x"229A");  -- NDC R3,R1,R2 (0010_001_010_011_0_10, cond=10)
    halt_here(16#0A#);
    go(50);
    chk("NDC(C=1)", 3, x"FFF0");

    --------------------------------------------------------------------------
    -- T23: NCU  — NAND complement unconditional (always)
    --   LLI R1,0xFF ; LLI R2,0xFF ; NCU R3,R1,R2 -> R3 = 0xFF NAND ~0xFF = 0xFFFF
    --   ~0x00FF = 0xFF00.  0x00FF NAND 0xFF00 = NOT(0) = 0xFFFF
    --------------------------------------------------------------------------
    report "=== T23: NCU (NAND complement always) ===";
    setup;
    wi(16#00#, x"32FF");  -- LLI R1, 0xFF
    wi(16#02#, x"34FF");  -- LLI R2, 0xFF
    wi(16#04#, x"229C");  -- NCU R3,R1,R2 (0010_001_010_011_1_00, cmp=1 cond=00)
    halt_here(16#06#);
    go(40);
    chk("NCU", 3, x"FFFF");

    --------------------------------------------------------------------------
    -- T24: NCZ  — NAND complement if Z=1  (executes)
    --   LLI R1,0xFF ; LLI R2,0xFF ; ADI R4,R0,0 (Z=1) ; NCZ R3,R1,R2 -> R3 = 0xFFFF
    --------------------------------------------------------------------------
    report "=== T24: NCZ (Z=1, executes) ===";
    setup;
    wi(16#00#, x"32FF");  -- LLI R1, 0xFF
    wi(16#02#, x"34FF");  -- LLI R2, 0xFF
    wi(16#04#, x"0100");  -- ADI R4,R0,0 -> Z=1
    wi(16#06#, x"229D");  -- NCZ R3,R1,R2 (0010_001_010_011_1_01, cmp=1 cond=01)
    halt_here(16#08#);
    go(50);
    chk("NCZ(Z=1)", 3, x"FFFF");

    --------------------------------------------------------------------------
    -- T25: NCC  — NAND complement if C=1  (executes)
    --   LLI R1,0xFF ; LLI R2,0xFF ; set C=1 ; NCC R3,R1,R2 -> R3 = 0xFFFF
    --------------------------------------------------------------------------
    report "=== T25: NCC (C=1, executes) ===";
    setup;
    wi(16#00#, x"32FF");  -- LLI R1, 0xFF
    wi(16#02#, x"34FF");  -- LLI R2, 0xFF
    wi(16#04#, x"3A01");  -- LLI R5, 1
    wi(16#06#, x"0B7F");  -- ADI R5,R5,-1 -> C=1
    wi(16#08#, x"229E");  -- NCC R3,R1,R2 (0010_001_010_011_1_10, cmp=1 cond=10)
    halt_here(16#0A#);
    go(50);
    chk("NCC(C=1)", 3, x"FFFF");

    --------------------------------------------------------------------------
    -- T26: LW  — load from pre-initialized data memory
    --   dmem[0x20] = 0xABCD (pre-written) ; LLI R2,0x20 ; LW R3,R2,0 -> R3 = 0xABCD
    --------------------------------------------------------------------------
    report "=== T26: LW (from pre-init dmem) ===";
    setup;
    wd(16#20#, x"ABCD");  -- init dmem[0x20] = 0xABCD
    wi(16#00#, x"3420");  -- LLI R2, 0x20   (address 32)
    wi(16#02#, x"4680");  -- LW R3,R2,0   (0100_011_010_000000)
    halt_here(16#04#);
    go(40);
    chk("LW", 3, x"ABCD");

    --------------------------------------------------------------------------
    -- Summary
    --------------------------------------------------------------------------
    report "======================================";
    report "RESULT: " & integer'image(passed) & " / " & integer'image(total) & " checks passed";
    report "======================================";
    wait;
  end process;

end architecture;
