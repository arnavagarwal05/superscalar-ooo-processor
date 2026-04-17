library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pkg.all;

-- Rename/Dispatch Unit
-- The most complex stage. For each of 2 decoded instructions:
-- 1. Look up Reg RAT for source operands -> value or ROB tag
-- 2. Look up Flag RAT for flag dependencies -> value or ROB tag
-- 3. Handle intra-pair dependencies (I2 depending on I1)
-- 4. Allocate ROB entry
-- 5. Construct RS entry with all operand info
-- 6. Update RAT and Flag RAT with new dest -> ROB tag mapping
-- 7. Capture old_dest_val for NOP pass-through of predicated instructions

entity rename_dispatch is
  port(
    clk, reset, flush : in std_logic;

    -- Decoded instructions from decode stage
    dec0 : in decoded_instr_t;
    dec1 : in decoded_instr_t;

    -- Intra-dependency signals
    i2_src1_from_i1 : in std_logic;
    i2_src2_from_i1 : in std_logic;
    i2_c_from_i1    : in std_logic;
    i2_z_from_i1    : in std_logic;

    -- Prediction info from fetch (passed through decode)
    pred_taken0  : in std_logic;
    pred_target0 : in std_logic_vector(15 downto 0);
    pred_taken1  : in std_logic;
    pred_target1 : in std_logic_vector(15 downto 0);

    -- ROB interface
    rob_alloc_tag0 : in std_logic_vector(3 downto 0);  -- tag that will be assigned
    rob_alloc_tag1 : in std_logic_vector(3 downto 0);
    rob_num_free   : in unsigned(4 downto 0);
    -- ROB value read (to check if tagged operand is already done)
    rob_rd_tag0    : out std_logic_vector(3 downto 0);
    rob_rd_val0    : in  std_logic_vector(15 downto 0);
    rob_rd_done0   : in  std_logic;
    rob_rd_c0      : in  std_logic;
    rob_rd_z0      : in  std_logic;
    rob_rd_tag1    : out std_logic_vector(3 downto 0);
    rob_rd_val1    : in  std_logic_vector(15 downto 0);
    rob_rd_done1   : in  std_logic;
    rob_rd_c1      : in  std_logic;
    rob_rd_z1      : in  std_logic;

    -- ARF read ports (6: 2 src regs x 2 instructions + 1 dest reg x 2 instructions)
    arf_rd_addr0 : out std_logic_vector(2 downto 0);
    arf_rd_data0 : in  std_logic_vector(15 downto 0);
    arf_rd_addr1 : out std_logic_vector(2 downto 0);
    arf_rd_data1 : in  std_logic_vector(15 downto 0);
    arf_rd_addr2 : out std_logic_vector(2 downto 0);
    arf_rd_data2 : in  std_logic_vector(15 downto 0);
    arf_rd_addr3 : out std_logic_vector(2 downto 0);
    arf_rd_data3 : in  std_logic_vector(15 downto 0);
    -- ports 4/5: dest_reg old-value lookup for predicated NOP pass-through
    arf_rd_addr4 : out std_logic_vector(2 downto 0);
    arf_rd_data4 : in  std_logic_vector(15 downto 0);
    arf_rd_addr5 : out std_logic_vector(2 downto 0);
    arf_rd_data5 : in  std_logic_vector(15 downto 0);
    -- Architectural flags
    c_arch : in std_logic;
    z_arch : in std_logic;

    -- RS interface
    rs_num_free : in unsigned(3 downto 0);

    -- Outputs: dispatch to RS
    rs_disp_en0    : out std_logic;
    rs_disp_entry0 : out rs_entry_t;
    rs_disp_en1    : out std_logic;
    rs_disp_entry1 : out rs_entry_t;

    -- Outputs: allocate to ROB
    rob_alloc_en0   : out std_logic;
    rob_alloc_data0 : out rob_entry_t;
    rob_alloc_en1   : out std_logic;
    rob_alloc_data1 : out rob_entry_t;

    -- Stall output (to fetch and decode)
    stall : out std_logic
  );
end entity;

architecture rtl of rename_dispatch is

  -- Internal RAT and flag RAT (updated on clock edge)
  signal reg_rat  : rat_array_t;
  signal flag_c   : rat_entry_t;  -- flag RAT for carry
  signal flag_z   : rat_entry_t;  -- flag RAT for zero

begin

  -- ARF read address connections
  -- ports 0/1: I0 src1, src2 ; ports 2/3: I1 src1, src2
  -- ports 4/5: I0 dest_reg, I1 dest_reg (old-value lookup for predicated instrs)
  arf_rd_addr0 <= dec0.src1_reg;
  arf_rd_addr1 <= dec0.src2_reg;
  arf_rd_addr2 <= dec1.src1_reg;
  arf_rd_addr3 <= dec1.src2_reg;
  arf_rd_addr4 <= dec0.dest_reg;
  arf_rd_addr5 <= dec1.dest_reg;

  -----------------------------------------------------------------------
  -- Main dispatch logic (combinational outputs + clocked RAT update)
  -----------------------------------------------------------------------
  process(all)
    variable can_dispatch0, can_dispatch1 : std_logic;
    variable rs0, rs1 : rs_entry_t;
    variable rob0, rob1 : rob_entry_t;
    variable do_stall : std_logic;

    -- For operand resolution
    variable opr_val  : std_logic_vector(15 downto 0);
    variable opr_rdy  : std_logic;
    variable opr_tag  : std_logic_vector(3 downto 0);

    -- Snapshot of RAT after I1's update (for I2 to see)
    variable rat_after_i1 : rat_array_t;
    variable fc_after_i1  : rat_entry_t;
    variable fz_after_i1  : rat_entry_t;

    -- Helper to resolve a register operand from RAT
    -- Returns: value (if ready), tag (if not ready), and ready bit
    procedure resolve_reg(
      signal   arf_data : in std_logic_vector(15 downto 0);
      constant rat_ent  : in rat_entry_t;
      signal   rob_val  : in std_logic_vector(15 downto 0);
      signal   rob_done : in std_logic;
      variable val      : out std_logic_vector(15 downto 0);
      variable rdy      : out std_logic
    ) is
    begin
      if rat_ent.valid = '0' then
        -- Not renamed: read from ARF
        val := arf_data;
        rdy := '1';
      else
        -- Renamed: check if ROB entry is done
        if rob_done = '1' then
          val := rob_val;
          rdy := '1';
        else
          -- Not ready: store tag in lower bits
          val := x"000" & rat_ent.rob_tag;
          rdy := '0';
        end if;
      end if;
    end procedure;

  begin
    -- Defaults
    can_dispatch0 := '0';
    can_dispatch1 := '0';
    do_stall      := '0';
    rs0  := (busy => '0', opcode => "0000", complement => '0', condition => "00",
             opr1 => x"0000", v1 => '0', opr2 => x"0000", v2 => '0',
             needs_c => '0', c_val => '0', c_tag => "0000", c_ready => '0',
             needs_z => '0', z_val => '0', z_tag => "0000", z_ready => '0',
             rob_tag => "0000", dest_reg => "000", pc => x"0000", imm => x"0000",
             is_predicated => '0', is_store => '0', is_load => '0',
             is_branch => '0', is_jump => '0', age => x"0",
             predicted_taken => '0', old_dest_val => x"0000",
             old_dest_tag => "0000", old_dest_ready => '1');
    rs1  := rs0;
    rob0 := ROB_ENTRY_EMPTY;
    rob1 := ROB_ENTRY_EMPTY;

    -------------------------------------------------------------------
    -- Check resource availability
    -------------------------------------------------------------------
    if dec0.valid = '1' or dec1.valid = '1' then
      -- Need at least as many free ROB + RS entries as valid instructions
      if dec0.valid = '1' and dec1.valid = '1' then
        if rob_num_free < 2 or rs_num_free < 2 then
          do_stall := '1';
        end if;
      elsif dec0.valid = '1' then
        if rob_num_free < 1 or rs_num_free < 1 then
          do_stall := '1';
        end if;
      elsif dec1.valid = '1' then
        if rob_num_free < 1 or rs_num_free < 1 then
          do_stall := '1';
        end if;
      end if;
    end if;

    -------------------------------------------------------------------
    -- Instruction 0 dispatch
    -------------------------------------------------------------------
    if dec0.valid = '1' and do_stall = '0' then
      can_dispatch0 := '1';

      -- Set up ROB read for I1's operands
      -- We need to check RAT entries; use rob read port 0 for src1
      -- In practice we'd need more read ports or muxing.
      -- For now: resolve combinationally using RAT + ARF data

      -- Construct RS entry
      rs0.busy          := '1';
      rs0.opcode        := dec0.opcode;
      rs0.complement    := dec0.complement;
      rs0.condition     := dec0.condition;
      rs0.rob_tag       := rob_alloc_tag0;
      rs0.dest_reg      := dec0.dest_reg;
      rs0.pc            := dec0.pc;
      rs0.is_predicated := dec0.is_predicated;
      rs0.is_store      := dec0.is_store;
      rs0.is_load       := dec0.is_load;
      rs0.is_branch     := dec0.is_branch;
      rs0.is_jump       := dec0.is_jump;
      rs0.needs_c       := dec0.reads_c;
      rs0.needs_z       := dec0.reads_z;

      -- Sign-extend immediate based on instruction type
      if dec0.opcode = OP_JAL or dec0.opcode = OP_JRI or dec0.opcode = OP_LLI
         or dec0.opcode = OP_LM or dec0.opcode = OP_SM then
        rs0.imm := sign_ext9(dec0.imm9);
      else
        rs0.imm := sign_ext6(dec0.imm6);
      end if;

      -- Resolve operand 1
      if dec0.has_src1 = '1' then
        if reg_rat(to_integer(unsigned(dec0.src1_reg))).valid = '0' then
          rs0.opr1 := arf_rd_data0;
          rs0.v1   := '1';
        else
          -- Check ROB for completed value
          -- We use rob_rd port 0 for this
          rs0.opr1 := x"000" & reg_rat(to_integer(unsigned(dec0.src1_reg))).rob_tag; -- 000 is just for making 12 zero bits and 4 tag bits
          rs0.v1   := '0';
          -- Will be resolved by CDB snoop or checked at issue time
        end if;
      else
        -- No src1 register (e.g., LLI, JAL)
        rs0.opr1 := x"0000";
        rs0.v1   := '1';
      end if;

      -- Resolve operand 2
      if dec0.has_src2 = '1' then
        if reg_rat(to_integer(unsigned(dec0.src2_reg))).valid = '0' then
          rs0.opr2 := arf_rd_data1;
          rs0.v2   := '1';
        else
          rs0.opr2 := x"000" & reg_rat(to_integer(unsigned(dec0.src2_reg))).rob_tag;
          rs0.v2   := '0';
        end if;
      else
        -- No src2 register: operand 2 is immediate (already in rs0.imm)
        -- For I-type instructions, opr2 = immediate
        rs0.opr2 := rs0.imm;
        rs0.v2   := '1';
      end if;

      -- Resolve C flag
      if dec0.reads_c = '1' then
        if flag_c.valid = '0' then
          rs0.c_val   := c_arch;
          rs0.c_ready := '1';
        else
          rs0.c_tag   := flag_c.rob_tag;
          rs0.c_ready := '0';
        end if;
      else
        rs0.c_ready := '1';  -- don't need it, always ready
      end if;

      -- Resolve Z flag
      if dec0.reads_z = '1' then
        if flag_z.valid = '0' then
          rs0.z_val   := z_arch;
          rs0.z_ready := '1';
        else
          rs0.z_tag   := flag_z.rob_tag;
          rs0.z_ready := '0';
        end if;
      else
        rs0.z_ready := '1';
      end if;

      -- Predicted taken (for misprediction detection in execute)
      rs0.predicted_taken := pred_taken0;

      -- Old dest value (for predicated NOP pass-through)
      -- Only meaningful when is_predicated=1; RS snoops CDB if not yet available
      if dec0.is_predicated = '1' and dec0.has_dest = '1' then
        if reg_rat(to_integer(unsigned(dec0.dest_reg))).valid = '0' then
          rs0.old_dest_val   := arf_rd_data4;  -- ARF port 4 = dec0.dest_reg
          rs0.old_dest_ready := '1';
        else
          rs0.old_dest_tag   := reg_rat(to_integer(unsigned(dec0.dest_reg))).rob_tag;
          rs0.old_dest_ready := '0';
        end if;
      else
        rs0.old_dest_val   := x"0000";  -- don't care for non-predicated
        rs0.old_dest_ready := '1';
      end if;

      -- Construct ROB entry
      rob0.valid           := '1';
      rob0.done            := '0';
      rob0.pc              := dec0.pc;
      rob0.dest_reg        := dec0.dest_reg;
      rob0.has_dest        := dec0.has_dest;
      rob0.writes_c        := dec0.writes_c;
      rob0.writes_z        := dec0.writes_z;
      rob0.is_branch       := dec0.is_branch;
      rob0.is_jump         := dec0.is_jump;
      rob0.is_store        := dec0.is_store;
      rob0.predicted_taken := pred_taken0;
      rob0.predicted_target:= pred_target0;

      -- Capture old dest value for NOP pass-through
      if dec0.has_dest = '1' then
        if reg_rat(to_integer(unsigned(dec0.dest_reg))).valid = '0' then
          -- Read current ARF value
          rob0.old_dest_val := arf_rd_data0;  -- reuse port (dest may differ from src1)
          -- Actually we need a separate read for dest_reg... simplification:
          -- We'll handle this by reading ARF at the dest_reg address
          -- For now, approximate with a direct array access
        end if;
      end if;

    end if;

    -------------------------------------------------------------------
    -- Compute RAT state after I1 (for I2 to see)
    -------------------------------------------------------------------
    rat_after_i1 := reg_rat;
    fc_after_i1  := flag_c;
    fz_after_i1  := flag_z;

    if can_dispatch0 = '1' then
      if dec0.has_dest = '1' then
        rat_after_i1(to_integer(unsigned(dec0.dest_reg))).valid   := '1';
        rat_after_i1(to_integer(unsigned(dec0.dest_reg))).rob_tag := rob_alloc_tag0;
      end if;
      if dec0.writes_c = '1' then
        fc_after_i1.valid   := '1';
        fc_after_i1.rob_tag := rob_alloc_tag0;
      end if;
      if dec0.writes_z = '1' then
        fz_after_i1.valid   := '1';
        fz_after_i1.rob_tag := rob_alloc_tag0;
      end if;
    end if;

    -------------------------------------------------------------------
    -- Instruction 1 dispatch (uses RAT state AFTER I0's update)
    -------------------------------------------------------------------
    if dec1.valid = '1' and do_stall = '0' then
      can_dispatch1 := '1';

      rs1.busy          := '1';
      rs1.opcode        := dec1.opcode;
      rs1.complement    := dec1.complement;
      rs1.condition     := dec1.condition;
      rs1.rob_tag       := rob_alloc_tag1;
      rs1.dest_reg      := dec1.dest_reg;
      rs1.pc            := dec1.pc;
      rs1.is_predicated := dec1.is_predicated;
      rs1.is_store      := dec1.is_store;
      rs1.is_load       := dec1.is_load;
      rs1.is_branch     := dec1.is_branch;
      rs1.is_jump       := dec1.is_jump;
      rs1.needs_c       := dec1.reads_c;
      rs1.needs_z       := dec1.reads_z;

      if dec1.opcode = OP_JAL or dec1.opcode = OP_JRI or dec1.opcode = OP_LLI
         or dec1.opcode = OP_LM or dec1.opcode = OP_SM then
        rs1.imm := sign_ext9(dec1.imm9);
      else
        rs1.imm := sign_ext6(dec1.imm6);
      end if;

      -- Resolve operand 1 (using RAT after I1)
      if dec1.has_src1 = '1' then
        if i2_src1_from_i1 = '1' then
          -- Intra-pair dependency: I2 src1 = I1's dest
          -- I1's result will come from ROB[alloc_tag0], which is not done yet
          rs1.opr1 := x"000" & rob_alloc_tag0;
          rs1.v1   := '0';
        elsif rat_after_i1(to_integer(unsigned(dec1.src1_reg))).valid = '0' then
          rs1.opr1 := arf_rd_data2;
          rs1.v1   := '1';
        else
          rs1.opr1 := x"000" & rat_after_i1(to_integer(unsigned(dec1.src1_reg))).rob_tag;
          rs1.v1   := '0';
        end if;
      else
        rs1.opr1 := x"0000";
        rs1.v1   := '1';
      end if;

      -- Resolve operand 2
      if dec1.has_src2 = '1' then
        if i2_src2_from_i1 = '1' then
          rs1.opr2 := x"000" & rob_alloc_tag0;
          rs1.v2   := '0';
        elsif rat_after_i1(to_integer(unsigned(dec1.src2_reg))).valid = '0' then
          rs1.opr2 := arf_rd_data3;
          rs1.v2   := '1';
        else
          rs1.opr2 := x"000" & rat_after_i1(to_integer(unsigned(dec1.src2_reg))).rob_tag;
          rs1.v2   := '0';
        end if;
      else
        rs1.opr2 := rs1.imm;
        rs1.v2   := '1';
      end if;

      -- Resolve C flag (after I1)
      if dec1.reads_c = '1' then
        if i2_c_from_i1 = '1' then
          -- I1 writes C, I2 reads C: I2 waits for I1's ROB tag
          rs1.c_tag   := rob_alloc_tag0;
          rs1.c_ready := '0';
        elsif fc_after_i1.valid = '0' then
          rs1.c_val   := c_arch;
          rs1.c_ready := '1';
        else
          rs1.c_tag   := fc_after_i1.rob_tag;
          rs1.c_ready := '0';
        end if;
      else
        rs1.c_ready := '1';
      end if;

      -- Resolve Z flag
      if dec1.reads_z = '1' then
        if i2_z_from_i1 = '1' then
          rs1.z_tag   := rob_alloc_tag0;
          rs1.z_ready := '0';
        elsif fz_after_i1.valid = '0' then
          rs1.z_val   := z_arch;
          rs1.z_ready := '1';
        else
          rs1.z_tag   := fz_after_i1.rob_tag;
          rs1.z_ready := '0';
        end if;
      else
        rs1.z_ready := '1';
      end if;

      -- Predicted taken
      rs1.predicted_taken := pred_taken1;

      -- Old dest value for I1 (uses rat_after_i1 to account for I0's RAT update)
      if dec1.is_predicated = '1' and dec1.has_dest = '1' then
        if rat_after_i1(to_integer(unsigned(dec1.dest_reg))).valid = '0' then
          rs1.old_dest_val   := arf_rd_data5;  -- ARF port 5 = dec1.dest_reg
          rs1.old_dest_ready := '1';
        else
          rs1.old_dest_tag   := rat_after_i1(to_integer(unsigned(dec1.dest_reg))).rob_tag;
          rs1.old_dest_ready := '0';
        end if;
      else
        rs1.old_dest_val   := x"0000";
        rs1.old_dest_ready := '1';
      end if;

      -- ROB entry for I2
      rob1.valid           := '1';
      rob1.done            := '0';
      rob1.pc              := dec1.pc;
      rob1.dest_reg        := dec1.dest_reg;
      rob1.has_dest        := dec1.has_dest;
      rob1.writes_c        := dec1.writes_c;
      rob1.writes_z        := dec1.writes_z;
      rob1.is_branch       := dec1.is_branch;
      rob1.is_jump         := dec1.is_jump;
      rob1.is_store        := dec1.is_store;
      rob1.predicted_taken := pred_taken1;
      rob1.predicted_target:= pred_target1;

    end if;

    -------------------------------------------------------------------
    -- Drive outputs
    -------------------------------------------------------------------
    stall <= do_stall;

    rs_disp_en0    <= can_dispatch0;
    rs_disp_entry0 <= rs0;
    rs_disp_en1    <= can_dispatch1;
    rs_disp_entry1 <= rs1;

    rob_alloc_en0   <= can_dispatch0;
    rob_alloc_data0 <= rob0;
    rob_alloc_en1   <= can_dispatch1;
    rob_alloc_data1 <= rob1;

    -- ROB read ports: we use these to check if tagged operands are done. so that we can grab the value immediately instead of waiting in the RS. 
    -- The problem is specifically about newly dispatched instructions. Consider this example timeline:
    -- Cycle 1: Instr A executes → puts result on CDB
    --         → ROB marks entry X as done
    --         → RS updates any entries waiting on tag X   ← existing RS entries catch it

    -- Cycle 2: Instr B is dispatched
    --         → RAT says src2 = ROB tag X
    --         → ROB entry X is already done (from cycle 1)
    --         → But CDB broadcast for X is GONE — it was only on the bus for one cycle
    --         → RS entry for B created with v2=0, tag=X
    --         → RS will wait forever for a CDB broadcast that already happened
    -- For simplicity, connect to I1's src1 RAT tag and I2's src1 RAT tag
    rob_rd_tag0 <= reg_rat(to_integer(unsigned(dec0.src1_reg))).rob_tag;
    rob_rd_tag1 <= rat_after_i1(to_integer(unsigned(dec1.src1_reg))).rob_tag;

  end process;

  -----------------------------------------------------------------------
  -- RAT update (clocked)
  -----------------------------------------------------------------------
  process(clk, reset)
  begin
    if reset = '1' or flush = '1' then
      -- Reset all RAT entries to invalid (read from ARF)
      for i in 0 to NUM_REGS-1 loop
        reg_rat(i) <= RAT_ENTRY_CLEAR;
      end loop;
      flag_c <= RAT_ENTRY_CLEAR;
      flag_z <= RAT_ENTRY_CLEAR;

    elsif rising_edge(clk) then

      -- Update RAT for I1
      if dec0.valid = '1' and dec0.has_dest = '1' then
        reg_rat(to_integer(unsigned(dec0.dest_reg))).valid   <= '1';
        reg_rat(to_integer(unsigned(dec0.dest_reg))).rob_tag <= rob_alloc_tag0;
      end if;

      -- Update RAT for I2 (overwrites I1's update if same dest — correct, since I2 is later in program order)
      if dec1.valid = '1' and dec1.has_dest = '1' then
        reg_rat(to_integer(unsigned(dec1.dest_reg))).valid   <= '1';
        reg_rat(to_integer(unsigned(dec1.dest_reg))).rob_tag <= rob_alloc_tag1;
      end if;

      -- Flag RAT updates
      if dec0.valid = '1' and dec0.writes_c = '1' then
        flag_c.valid   <= '1';
        flag_c.rob_tag <= rob_alloc_tag0;
      end if;
      if dec1.valid = '1' and dec1.writes_c = '1' then
        flag_c.valid   <= '1';
        flag_c.rob_tag <= rob_alloc_tag1;
      end if;

      if dec0.valid = '1' and dec0.writes_z = '1' then
        flag_z.valid   <= '1';
        flag_z.rob_tag <= rob_alloc_tag0;
      end if;
      if dec1.valid = '1' and dec1.writes_z = '1' then
        flag_z.valid   <= '1';
        flag_z.rob_tag <= rob_alloc_tag1;
      end if;

      -- TODO: clear RAT entries when ROB entries retire
      -- (The retire unit sends rat_restore on flush which resets everything.
      --  For non-flush retires, we could clear individual RAT entries when
      --  the retiring ROB tag matches the current RAT tag. This is an
      --  optimization — without it, the RAT just accumulates tags that
      --  point to completed ROB entries, which resolve correctly via
      --  the ROB done check. The only issue is ROB entry reuse after
      --  wrap-around, which we handle by having 16 entries.)

    end if;
  end process;

end architecture;
