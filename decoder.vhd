library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pkg.all;

-- Decoder: pure combinational
-- Takes a 16-bit instruction + its PC, outputs all decoded fields
-- One instance per instruction slot (we instantiate 2 in the top level)

entity decoder is
  port(
    instruction : in  std_logic_vector(15 downto 0);
    pc_in       : in  std_logic_vector(15 downto 0);
    valid_in    : in  std_logic;
    decoded     : out decoded_instr_t
  );
end entity;

architecture rtl of decoder is
  signal op : std_logic_vector(3 downto 0);
begin

  op <= instruction(15 downto 12);

  process(all)
    variable d : decoded_instr_t;
  begin
    -- Start with defaults (NOP)
    d := DECODED_NOP;
    d.valid  := valid_in;
    d.pc     := pc_in;
    d.opcode := op;

    -- Extract raw fields (always available, may not be used)
    d.ra   := instruction(11 downto 9);
    d.rb   := instruction(8 downto 6);
    d.rc   := instruction(5 downto 3);
    d.imm6 := instruction(5 downto 0);
    d.imm9 := instruction(8 downto 0);
    d.complement := instruction(2);
    d.condition  := instruction(1 downto 0);

    case op is

      ---------------------------------------------------------------
      -- ADI: opcode 0000, RA=src, RB=dest, imm6
      -- rc = ra + sign_ext(imm6), modifies C and Z
      ---------------------------------------------------------------
      when OP_ADI =>
        d.src1_reg := d.ra;
        d.has_src1 := '1';
        d.has_src2 := '0';       -- immediate, not register
        d.dest_reg := d.rb;
        d.has_dest := '1';
        d.writes_c := '1';
        d.writes_z := '1';

      ---------------------------------------------------------------
      -- ADD family: opcode 0001
      -- ADA/ADC/ADZ/AWC/ACA/ACC/ACZ/ACW
      -- src1=RA, src2=RB, dest=RC
      -- complement bit (bit 2) selects complement of RB
      -- condition bits (1:0): 00=always, 01=Z, 10=C, 11=carry-operand
      ---------------------------------------------------------------
      when OP_ADD =>
        d.src1_reg := d.ra;
        d.has_src1 := '1';
        d.src2_reg := d.rb;
        d.has_src2 := '1';
        d.dest_reg := d.rc;
        d.has_dest := '1';
        d.writes_c := '1';
        d.writes_z := '1';

        -- Predication and flag reads
        case d.condition is
          when "00" =>   -- ADA or ACA: always execute
            d.is_predicated := '0';
            -- AWC/ACW use carry as operand (condition=11 below)
            -- but condition=00 means no flag read for predication
            d.reads_c := '0';
            d.reads_z := '0';
          when "01" =>   -- ADZ or ACZ: execute if Z=1
            d.is_predicated := '1';
            d.reads_z := '1';
          when "10" =>   -- ADC or ACC: execute if C=1
            d.is_predicated := '1';
            d.reads_c := '1';
          when "11" =>   -- AWC or ACW: always execute, C is an operand to the adder
            d.is_predicated := '0';
            d.reads_c := '1';  -- needs C value for computation
          when others => null;
        end case;

      ---------------------------------------------------------------
      -- NAND family: opcode 0010
      -- NDU/NDC/NDZ/NCU/NCC/NCZ
      -- src1=RA, src2=RB, dest=RC
      -- Only writes Z (not C)
      ---------------------------------------------------------------
      when OP_NDU =>
        d.src1_reg := d.ra;
        d.has_src1 := '1';
        d.src2_reg := d.rb;
        d.has_src2 := '1';
        d.dest_reg := d.rc;
        d.has_dest := '1';
        d.writes_c := '0';   -- NAND does NOT write carry
        d.writes_z := '1';

        case d.condition is
          when "00" =>   -- NDU or NCU
            d.is_predicated := '0';
          when "01" =>   -- NDZ or NCZ
            d.is_predicated := '1';
            d.reads_z := '1';
          when "10" =>   -- NDC or NCC
            d.is_predicated := '1';
            d.reads_c := '1';
          when others => null;
        end case;

      ---------------------------------------------------------------
      -- LLI: opcode 0011, dest=RA, imm9 zero-extended into lower 9 bits
      -- No flag update, no sources
      ---------------------------------------------------------------
      when OP_LLI =>
        d.dest_reg := d.ra;
        d.has_dest := '1';
        d.has_src1 := '0';
        d.has_src2 := '0';

      ---------------------------------------------------------------
      -- LW: opcode 0100, dest=RA, src1=RB (base addr), imm6 (offset)
      -- Writes Z based on loaded value (not address!)
      ---------------------------------------------------------------
      when OP_LW =>
        d.dest_reg := d.ra;
        d.has_dest := '1';
        d.src1_reg := d.rb;   -- base address register
        d.has_src1 := '1';
        d.has_src2 := '0';    -- offset is immediate
        d.writes_z := '1';
        d.is_load  := '1';

      ---------------------------------------------------------------
      -- SW: opcode 0101, src1=RA (data), src2=RB (base addr), imm6
      -- No destination, no flag update
      ---------------------------------------------------------------
      when OP_SW =>
        d.has_dest := '0';
        d.src1_reg := d.ra;   -- data to store
        d.has_src1 := '1';
        d.src2_reg := d.rb;   -- base address
        d.has_src2 := '1';
        d.is_store := '1';

      ---------------------------------------------------------------
      -- LM: opcode 0110 (load multiple)
      -- Handled by LM/SM cracker, decoder just flags it
      ---------------------------------------------------------------
      when OP_LM =>
        d.is_load := '1';
        d.src1_reg := d.ra;  -- base address register
        d.has_src1 := '1';
        -- LM/SM cracker will generate individual micro-ops
        -- For now, mark it so the cracker knows to intervene

      ---------------------------------------------------------------
      -- SM: opcode 0111 (store multiple)
      ---------------------------------------------------------------
      when OP_SM =>
        d.is_store := '1';
        d.src1_reg := d.ra;
        d.has_src1 := '1';

      ---------------------------------------------------------------
      -- BEQ: opcode 1000
      -- Compare RA and RB, branch to PC + imm6*2 if equal
      ---------------------------------------------------------------
      when OP_BEQ =>
        d.src1_reg := d.ra;
        d.has_src1 := '1';
        d.src2_reg := d.rb;
        d.has_src2 := '1';
        d.has_dest := '0';
        d.is_branch := '1';

      ---------------------------------------------------------------
      -- BLT: opcode 1001
      ---------------------------------------------------------------
      when OP_BLT =>
        d.src1_reg := d.ra;
        d.has_src1 := '1';
        d.src2_reg := d.rb;
        d.has_src2 := '1';
        d.has_dest := '0';
        d.is_branch := '1';

      ---------------------------------------------------------------
      -- BLE: opcode 1010
      ---------------------------------------------------------------
      when OP_BLE =>
        d.src1_reg := d.ra;
        d.has_src1 := '1';
        d.src2_reg := d.rb;
        d.has_src2 := '1';
        d.has_dest := '0';
        d.is_branch := '1';

      ---------------------------------------------------------------
      -- JAL: opcode 1100
      -- dest=RA (stores PC+2), jump to PC + imm9*2
      ---------------------------------------------------------------
      when OP_JAL =>
        d.dest_reg := d.ra;
        d.has_dest := '1';
        d.has_src1 := '0';
        d.has_src2 := '0';
        d.is_branch := '1';
        d.is_jump   := '1';  -- unconditional

      ---------------------------------------------------------------
      -- JLR: opcode 1101
      -- dest=RA (stores PC+2), jump to address in RB
      ---------------------------------------------------------------
      when OP_JLR =>
        d.dest_reg := d.ra;
        d.has_dest := '1';
        d.src1_reg := d.rb;  -- jump target is in RB
        d.has_src1 := '1';
        d.has_src2 := '0';
        d.is_branch := '1';
        d.is_jump   := '1';

      ---------------------------------------------------------------
      -- JRI: opcode 1111
      -- jump to RA + imm9*2, no dest written
      ---------------------------------------------------------------
      when OP_JRI =>
        d.src1_reg := d.ra;
        d.has_src1 := '1';
        d.has_dest := '0';
        d.is_branch := '1';
        d.is_jump   := '1';

      when others =>
        -- Unknown opcode: treat as NOP
        d.valid := '0';

    end case;

    decoded <= d;
  end process;

end architecture;
