library ieee;
use ieee.std_logic_1164.all;
use work.pkg.all;

-- Intra-dependency checker
-- Pure combinational: checks if instruction 2 in a fetch pair
-- depends on instruction 1 (register or flag dependency)
-- If so, I2 must get I1's ROB tag instead of reading from RAT/ARF

entity intra_dep_checker is
  port(
    i1 : in decoded_instr_t;
    i2 : in decoded_instr_t;
    -- outputs: does I2's source come from I1?
    i2_src1_from_i1 : out std_logic;
    i2_src2_from_i1 : out std_logic;
    i2_c_from_i1    : out std_logic;
    i2_z_from_i1    : out std_logic
  );
end entity;

architecture rtl of intra_dep_checker is
begin

  -- I2's src1 depends on I1 if:
  --   I1 writes to a register (has_dest=1)
  --   AND I2 reads from src1 (has_src1=1)
  --   AND the register numbers match
  --   AND both instructions are valid
  i2_src1_from_i1 <= '1' when (i1.valid = '1' and i2.valid = '1'
                                and i1.has_dest = '1' and i2.has_src1 = '1'
                                and i1.dest_reg = i2.src1_reg)
                     else '0';

  -- Same check for I2's src2
  i2_src2_from_i1 <= '1' when (i1.valid = '1' and i2.valid = '1'
                                and i1.has_dest = '1' and i2.has_src2 = '1'
                                and i1.dest_reg = i2.src2_reg)
                     else '0';

  -- I2 reads C flag, I1 writes C flag
  i2_c_from_i1 <= '1' when (i1.valid = '1' and i2.valid = '1'
                             and i1.writes_c = '1' and i2.reads_c = '1')
                  else '0';

  -- I2 reads Z flag, I1 writes Z flag
  i2_z_from_i1 <= '1' when (i1.valid = '1' and i2.valid = '1'
                             and i1.writes_z = '1' and i2.reads_z = '1')
                  else '0';

end architecture;
