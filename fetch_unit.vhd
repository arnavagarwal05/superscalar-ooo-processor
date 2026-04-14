library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pkg.all;

-- Fetch Unit
-- Manages PC, fetches 2 instructions per cycle from instruction memory
-- Integrates branch predictor: partial decode of fetched instructions to detect branches
-- Handles stall (ROB/RS full) and flush (mispredict from retire)

entity fetch_unit is
  port(
    clk, reset : in std_logic;

    -- Stall: hold PC, don't advance
    stall : in std_logic;

    -- Flush: redirect PC from retire
    flush        : in std_logic;
    flush_target : in std_logic_vector(15 downto 0);

    -- Instruction memory interface
    imem_addr : out std_logic_vector(15 downto 0);
    imem_data : in  std_logic_vector(31 downto 0);  -- 2 instructions

    -- Branch predictor interface
    bht_predict1 : in std_logic;  -- prediction for instr at PC
    bht_predict2 : in std_logic;  -- prediction for instr at PC+2
    bht_lookup_pc1 : out std_logic_vector(15 downto 0);
    bht_lookup_pc2 : out std_logic_vector(15 downto 0);

    -- Outputs to decode stage (pipeline register)
    out_valid1 : out std_logic;
    out_instr1 : out std_logic_vector(15 downto 0);
    out_pc1    : out std_logic_vector(15 downto 0);
    out_pred_taken1 : out std_logic;
    out_pred_target1: out std_logic_vector(15 downto 0);

    out_valid2 : out std_logic;
    out_instr2 : out std_logic_vector(15 downto 0);
    out_pc2    : out std_logic_vector(15 downto 0);
    out_pred_taken2 : out std_logic;
    out_pred_target2: out std_logic_vector(15 downto 0)
  );
end entity;

architecture rtl of fetch_unit is
  signal pc : std_logic_vector(15 downto 0);

  -- Pipeline register (fetch -> decode)
  signal buf_valid1, buf_valid2 : std_logic;
  signal buf_instr1, buf_instr2 : std_logic_vector(15 downto 0);
  signal buf_pc1, buf_pc2       : std_logic_vector(15 downto 0);
  signal buf_pred1, buf_pred2   : std_logic;
  signal buf_ptgt1, buf_ptgt2   : std_logic_vector(15 downto 0);
begin

  -- Send PC to instruction memory (combinational)
  imem_addr <= pc;

  -- Send PC to branch predictor for lookup
  bht_lookup_pc1 <= pc;
  bht_lookup_pc2 <= std_logic_vector(unsigned(pc) + 2);

  -- Output the pipeline register contents
  out_valid1  <= buf_valid1;
  out_instr1  <= buf_instr1;
  out_pc1     <= buf_pc1;
  out_pred_taken1  <= buf_pred1;
  out_pred_target1 <= buf_ptgt1;

  out_valid2  <= buf_valid2;
  out_instr2  <= buf_instr2;
  out_pc2     <= buf_pc2;
  out_pred_taken2  <= buf_pred2;
  out_pred_target2 <= buf_ptgt2;

  process(clk, reset)
    variable instr1, instr2 : std_logic_vector(15 downto 0);
    variable op1, op2       : std_logic_vector(3 downto 0);
    variable i1_is_branch, i1_is_jump : boolean;
    variable i2_is_branch, i2_is_jump : boolean;
    variable i1_predicted_taken : std_logic;
    variable i2_predicted_taken : std_logic;
    variable i1_target, i2_target : std_logic_vector(15 downto 0);
    variable next_pc : std_logic_vector(15 downto 0);
    variable imm6_ext, imm9_ext : std_logic_vector(15 downto 0);
  begin
    if reset = '1' then
      pc <= (others => '0');
      buf_valid1 <= '0';
      buf_valid2 <= '0';
      buf_instr1 <= (others => '0');
      buf_instr2 <= (others => '0');
      buf_pc1    <= (others => '0');
      buf_pc2    <= (others => '0');
      buf_pred1  <= '0';
      buf_pred2  <= '0';
      buf_ptgt1  <= (others => '0');
      buf_ptgt2  <= (others => '0');

    elsif rising_edge(clk) then

      if flush = '1' then
        -- Redirect PC, invalidate buffer
        pc <= flush_target;
        buf_valid1 <= '0';
        buf_valid2 <= '0';

      elsif stall = '1' then
        -- Hold everything: PC doesn't advance, buffer keeps old values
        null;

      else
        -- Normal fetch cycle
        instr1 := imem_data(31 downto 16);  -- instruction at PC
        instr2 := imem_data(15 downto 0);   -- instruction at PC+2

        op1 := instr1(15 downto 12);
        op2 := instr2(15 downto 12);

        ---------------------------------------------------------------
        -- Partial decode: identify branches and compute targets
        ---------------------------------------------------------------

        -- Instruction 1
        i1_is_branch := (op1 = OP_BEQ or op1 = OP_BLT or op1 = OP_BLE);
        i1_is_jump   := (op1 = OP_JAL or op1 = OP_JLR or op1 = OP_JRI);
        i1_target    := (others => '0');
        i1_predicted_taken := '0';

        if i1_is_branch then
          -- Conditional branch: use BHT prediction
          i1_predicted_taken := bht_predict1;
          -- Target = PC + sign_ext(imm6) * 2
          imm6_ext := sign_ext6(instr1(5 downto 0));
          i1_target := std_logic_vector(unsigned(pc) +
                       unsigned(imm6_ext(14 downto 0) & '0'));
        elsif op1 = OP_JAL then
          -- JAL: always taken, target = PC + sign_ext(imm9) * 2
          i1_predicted_taken := '1';
          imm9_ext := sign_ext9(instr1(8 downto 0));
          i1_target := std_logic_vector(unsigned(pc) +
                       unsigned(imm9_ext(14 downto 0) & '0'));
        elsif op1 = OP_JLR or op1 = OP_JRI then
          -- JLR/JRI: target needs register value, can't predict. in jlr, a bht can tell if this branch was taken but not where, our simple bht is useless here. 
          -- Predict not-taken, will flush later when resolved
          i1_predicted_taken := '0';
        end if;

        -- Instruction 2 (same logic but at PC+2)
        i2_is_branch := (op2 = OP_BEQ or op2 = OP_BLT or op2 = OP_BLE);
        i2_is_jump   := (op2 = OP_JAL or op2 = OP_JLR or op2 = OP_JRI);
        i2_target    := (others => '0');
        i2_predicted_taken := '0';

        if i2_is_branch then
          i2_predicted_taken := bht_predict2;
          imm6_ext := sign_ext6(instr2(5 downto 0));
          i2_target := std_logic_vector(unsigned(pc) + 2 +
                       unsigned(imm6_ext(14 downto 0) & '0'));
        elsif op2 = OP_JAL then
          i2_predicted_taken := '1';
          imm9_ext := sign_ext9(instr2(8 downto 0));
          i2_target := std_logic_vector(unsigned(pc) + 2 +
                       unsigned(imm9_ext(14 downto 0) & '0'));
        elsif op2 = OP_JLR or op2 = OP_JRI then
          i2_predicted_taken := '0';
        end if;

        ---------------------------------------------------------------
        -- Determine validity and next PC
        ---------------------------------------------------------------
        next_pc := std_logic_vector(unsigned(pc) + 4);  -- default: PC+4

        if i1_predicted_taken = '1' then
          -- I1 predicted taken: I2 is invalid (wrong path), redirect to I1 target
          buf_valid1 <= '1';
          buf_valid2 <= '0';
          next_pc    := i1_target;
        elsif i2_predicted_taken = '1' then
          -- I1 not taken, I2 predicted taken: both valid, redirect to I2 target
          buf_valid1 <= '1';
          buf_valid2 <= '1';
          next_pc    := i2_target;
        else
          -- Neither predicted taken: both valid, PC+4
          buf_valid1 <= '1';
          buf_valid2 <= '1';
        end if;

        -- Fill pipeline register
        buf_instr1 <= instr1;
        buf_instr2 <= instr2;
        buf_pc1    <= pc;
        buf_pc2    <= std_logic_vector(unsigned(pc) + 2);
        buf_pred1  <= i1_predicted_taken;
        buf_pred2  <= i2_predicted_taken;
        buf_ptgt1  <= i1_target;
        buf_ptgt2  <= i2_target;

        -- Update PC
        pc <= next_pc;

      end if;
    end if;
  end process;

end architecture;
