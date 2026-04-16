library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pkg.all;

-- Execution unit (ALU + branch + address computation)
-- Pure combinational: results available same cycle as inputs
-- One instance per execution pipe (we have 2 identical pipes)
-- Handles: ADD/NAND family, ADI, LLI, BEQ/BLT/BLE, JAL/JLR/JRI, LW/SW address calc
-- Predicated instructions: if condition false, output old_dest_val as result (NOP pass-through)

entity execute_alu is
  port(
    -- Input from issue
    valid_in      : in  std_logic;
    opcode        : in  std_logic_vector(3 downto 0);
    complement    : in  std_logic;
    condition     : in  std_logic_vector(1 downto 0);
    opr1          : in  std_logic_vector(15 downto 0);
    opr2          : in  std_logic_vector(15 downto 0);
    c_in          : in  std_logic;  -- flag value (for predication or AWC operand)
    z_in          : in  std_logic;
    imm           : in  std_logic_vector(15 downto 0);  -- sign-extended immediate
    pc_in         : in  std_logic_vector(15 downto 0);
    rob_tag_in    : in  std_logic_vector(3 downto 0);
    is_predicated : in  std_logic;
    is_store_in   : in  std_logic;
    is_load_in    : in  std_logic;
    is_branch_in  : in  std_logic;
    is_jump_in    : in  std_logic;
    old_dest_val  : in  std_logic_vector(15 downto 0);  -- for NOP pass-through
    predicted_taken : in std_logic;  -- branch predictor's prediction

    -- Output to CDB
    cdb_out       : out cdb_t
  );
end entity;

architecture rtl of execute_alu is
begin

  process(all)
    variable cdb        : cdb_t;
    variable temp       : unsigned(16 downto 0);  -- 17 bits for carry detection
    variable a, b       : unsigned(15 downto 0);
    variable result     : std_logic_vector(15 downto 0);
    variable carry_out  : std_logic;
    variable zero_out   : std_logic;
    variable exec_cond  : std_logic;  -- should predicated instruction execute?
    variable is_nop     : std_logic;
    variable b_mod      : unsigned(15 downto 0);  -- possibly complemented operand 2
    variable taken      : std_logic;  -- branch actually taken?
    variable target     : std_logic_vector(15 downto 0);
  begin
    cdb := CDB_EMPTY;
    cdb.valid   := valid_in;
    cdb.rob_tag := rob_tag_in;
    cdb.is_store  := is_store_in;
    cdb.is_load   := is_load_in;
    cdb.is_branch := is_branch_in;

    result    := (others => '0');
    carry_out := '0';
    zero_out  := '0';
    is_nop    := '0';
    taken     := '0';
    target    := (others => '0');

    a := unsigned(opr1);
    b := unsigned(opr2);

    -------------------------------------------------------------------
    -- Step 1: Check predication condition
    -------------------------------------------------------------------
    exec_cond := '1';  -- default: execute
    if is_predicated = '1' then
      case condition is
        when "01" => exec_cond := z_in;   -- execute if Z=1
        when "10" => exec_cond := c_in;   -- execute if C=1
        when others => exec_cond := '1';  -- 00/11: always execute
      end case;
    end if;

    if is_predicated = '1' and exec_cond = '0' then
      -- NOP: pass through old value and input flags
      is_nop   := '1';
      result   := old_dest_val;
      carry_out := c_in;
      zero_out  := z_in;
    else

      -------------------------------------------------------------------
      -- Step 2: Compute based on opcode
      -------------------------------------------------------------------
      case opcode is

        when OP_ADD =>
          -- Complement operand 2 if complement bit set
          if complement = '1' then
            b_mod := not b;
          else
            b_mod := b;
          end if;

          -- Add with carry if condition = "11" (AWC/ACW)
          if condition = "11" then
            temp := ('0' & a) + ('0' & b_mod) + (x"0000" & c_in);
          else
            temp := ('0' & a) + ('0' & b_mod);
          end if;

          result    := std_logic_vector(temp(15 downto 0));
          carry_out := std_logic(temp(16));
          if temp(15 downto 0) = x"0000" then
            zero_out := '1';
          end if;

        when OP_ADI =>
          -- opr1 = RA value, imm = sign-extended imm6
          temp := ('0' & a) + ('0' & unsigned(imm));
          result    := std_logic_vector(temp(15 downto 0));
          carry_out := std_logic(temp(16));
          if temp(15 downto 0) = x"0000" then
            zero_out := '1';
          end if;

        when OP_NDU =>
          -- NAND: complement opr2 if complement bit set
          if complement = '1' then
            result := opr1 nand (not opr2);  -- NAND(A, NOT B) = NOT(A AND NOT B)
          else
            result := opr1 nand opr2;
          end if;
          carry_out := c_in;  -- NAND doesn't modify carry
          if result = x"0000" then
            zero_out := '1';
          end if;

        when OP_LLI =>
          -- Zero-extend imm9 into result
          result := "0000000" & opr1(8 downto 0);
          -- Actually the imm9 comes through the imm field
          result := "0000000" & imm(8 downto 0);
          -- No flag update for LLI

        when OP_LW =>
          -- Address computation for load: base (opr1) + offset (imm)
          result := std_logic_vector(unsigned(opr1) + unsigned(imm));
          -- This is just the address; actual memory read happens in memory unit
          -- Z flag will be set by memory unit based on loaded data

        when OP_SW =>
          -- Address computation for store: base (opr2) + offset (imm)
          result := std_logic_vector(unsigned(opr2) + unsigned(imm));
          -- Store data is opr1, store address is result
          cdb.store_addr := std_logic_vector(unsigned(opr2) + unsigned(imm));
          cdb.store_data := opr1;

        when OP_BEQ =>
          -- Compare opr1 (RA) and opr2 (RB)
          if opr1 = opr2 then
            taken := '1';
          end if;
          target := std_logic_vector(unsigned(pc_in) + unsigned(imm(14 downto 0) & '0'));

        when OP_BLT =>
          -- Signed comparison
          if signed(opr1) < signed(opr2) then
            taken := '1';
          end if;
          target := std_logic_vector(unsigned(pc_in) + unsigned(imm(14 downto 0) & '0'));

        when OP_BLE =>
          if signed(opr1) <= signed(opr2) then
            taken := '1';
          end if;
          target := std_logic_vector(unsigned(pc_in) + unsigned(imm(14 downto 0) & '0'));

        when OP_JAL =>
          -- PC+2 saved to dest register, jump to PC + imm9*2
          result := std_logic_vector(unsigned(pc_in) + 2);
          taken  := '1';
          target := std_logic_vector(unsigned(pc_in) + unsigned(imm(14 downto 0) & '0'));

        when OP_JLR =>
          -- PC+2 saved to dest register, jump to address in opr1 (=RB)
          result := std_logic_vector(unsigned(pc_in) + 2);
          taken  := '1';
          target := opr1;

        when OP_JRI =>
          -- Jump to RA + imm9*2
          taken  := '1';
          target := std_logic_vector(unsigned(opr1) + unsigned(imm(14 downto 0) & '0'));

        when others =>
          null;

      end case;
    end if;

    -------------------------------------------------------------------
    -- Step 3: Determine misprediction
    -------------------------------------------------------------------
    cdb.branch_taken  := taken;
    cdb.branch_target := target;
    if is_branch_in = '1' then      -- if the current instr is a branch 
      if taken /= predicted_taken then    -- if the actual branch outcome differs from the predicted outcome
        cdb.mispredicted := '1';
      elsif taken = '1' and target /= pc_in then
        -- Both predicted taken, but wrong target (shouldn't happen with our scheme)
        cdb.mispredicted := '1';
      else
        cdb.mispredicted := '0';
      end if;
    end if;

    -------------------------------------------------------------------
    -- Step 4: Package output
    -------------------------------------------------------------------
    cdb.result   := result;
    cdb.c_val    := carry_out;
    cdb.z_val    := zero_out;
    cdb.is_nop   := is_nop;

    -- Determine which flags this instruction writes
    -- (these come from the decoded instruction, passed through RS)
    case opcode is
      when OP_ADD | OP_ADI =>
        cdb.writes_c := '1';
        cdb.writes_z := '1';
      when OP_NDU =>
        cdb.writes_c := '0';
        cdb.writes_z := '1';
      when OP_LW =>
        cdb.writes_c := '0';
        cdb.writes_z := '1';  -- Z from loaded data, handled by mem unit
      when others =>
        cdb.writes_c := '0';
        cdb.writes_z := '0';
    end case;

    cdb_out <= cdb;
  end process;

end architecture;
