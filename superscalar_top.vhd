library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pkg.all;

-- Superscalar Top Level
-- Wires together all modules: fetch, decode, rename/dispatch, RS, execute, CDB, ROB, retire, memories

entity superscalar_top is
  port(
    clk   : in  std_logic;
    reset : in  std_logic;
    -- Testbench outputs
    regs_out : out reg_file_t;
    c_flag   : out std_logic;
    z_flag   : out std_logic;
    -- Instruction memory write port (for testbench initialization)
    imem_wr_en   : in std_logic;
    imem_wr_addr : in std_logic_vector(15 downto 0);
    imem_wr_data : in std_logic_vector(15 downto 0);
    -- Data memory write port (for testbench initialization, active during reset only)
    dmem_wr_en   : in std_logic;
    dmem_wr_addr : in std_logic_vector(15 downto 0);
    dmem_wr_data : in std_logic_vector(15 downto 0)
  );
end entity;

architecture rtl of superscalar_top is

  -- Flush / stall
  signal flush        : std_logic;
  signal flush_target : std_logic_vector(15 downto 0);
  signal stall        : std_logic;
  signal rat_restore  : std_logic;

  -- Fetch -> Decode
  signal f_valid1, f_valid2   : std_logic;
  signal f_instr1, f_instr2   : std_logic_vector(15 downto 0);
  signal f_pc1, f_pc2         : std_logic_vector(15 downto 0);
  signal f_pred1, f_pred2     : std_logic;
  signal f_ptgt1, f_ptgt2     : std_logic_vector(15 downto 0);

  -- Instruction memory
  signal imem_addr : std_logic_vector(15 downto 0);
  signal imem_data : std_logic_vector(31 downto 0);

  -- Branch predictor
  signal bht_lookup_pc1, bht_lookup_pc2 : std_logic_vector(15 downto 0);
  signal bht_predict1, bht_predict2     : std_logic;
  signal bht_update_en    : std_logic;
  signal bht_update_pc    : std_logic_vector(15 downto 0);
  signal bht_update_taken : std_logic;

  -- Decode outputs
  signal dec0, dec1 : decoded_instr_t;

  -- Decode -> Rename pipeline register
  signal dec0_r, dec1_r : decoded_instr_t;
  signal pred0_r, pred1_r : std_logic;
  signal ptgt0_r, ptgt1_r : std_logic_vector(15 downto 0);

  -- Intra-dep
  signal i2s1, i2s2, i2c, i2z : std_logic;

  -- ARF
  signal arf_rd_addr0, arf_rd_addr1 : std_logic_vector(2 downto 0);
  signal arf_rd_addr2, arf_rd_addr3 : std_logic_vector(2 downto 0);
  signal arf_rd_addr4, arf_rd_addr5 : std_logic_vector(2 downto 0);
  signal arf_rd_data0, arf_rd_data1 : std_logic_vector(15 downto 0);
  signal arf_rd_data2, arf_rd_data3 : std_logic_vector(15 downto 0);
  signal arf_rd_data4, arf_rd_data5 : std_logic_vector(15 downto 0);
  signal arf_wr_en0, arf_wr_en1     : std_logic;
  signal arf_wr_addr0, arf_wr_addr1 : std_logic_vector(2 downto 0);
  signal arf_wr_data0, arf_wr_data1 : std_logic_vector(15 downto 0);
  signal c_arch, z_arch             : std_logic;
  signal c_wr_en, z_wr_en           : std_logic;
  signal c_wr_val, z_wr_val         : std_logic;

  -- ROB
  signal rob_alloc_en0, rob_alloc_en1   : std_logic;
  signal rob_alloc_data0, rob_alloc_data1 : rob_entry_t;
  signal rob_alloc_tag0, rob_alloc_tag1 : std_logic_vector(3 downto 0);
  signal rob_head_entry, rob_head1_entry: rob_entry_t;
  signal rob_retire0, rob_retire1       : std_logic;
  signal rob_head_ptr, rob_tail_ptr     : std_logic_vector(3 downto 0);
  signal rob_num_free                   : unsigned(4 downto 0);
  signal rob_rd_tag0, rob_rd_tag1       : std_logic_vector(3 downto 0);
  signal rob_rd_val0, rob_rd_val1       : std_logic_vector(15 downto 0);
  signal rob_rd_done0, rob_rd_done1     : std_logic;
  signal rob_rd_c0, rob_rd_c1           : std_logic;
  signal rob_rd_z0, rob_rd_z1           : std_logic;

  -- RS
  signal rs_disp_en0, rs_disp_en1       : std_logic;
  signal rs_disp_entry0, rs_disp_entry1 : rs_entry_t;
  signal rs_issue0_valid, rs_issue1_valid : std_logic;
  signal rs_issue0_entry, rs_issue1_entry : rs_entry_t;
  signal rs_num_free                     : unsigned(3 downto 0);

  -- CDB: _pre = raw ALU output, final cdb0/cdb1 has memory data substituted for loads
  signal cdb0_pre, cdb1_pre : cdb_t;
  signal cdb0, cdb1         : cdb_t;

  -- Store buffer
  signal sb_commit_en0, sb_commit_en1   : std_logic;
  signal sb_commit_tag0, sb_commit_tag1 : std_logic_vector(3 downto 0);
  signal sb_drain_valid                 : std_logic;
  signal sb_drain_addr, sb_drain_data   : std_logic_vector(15 downto 0);
  signal sb_num_free                    : unsigned(2 downto 0);

  -- Data memory
  signal dmem_a_addr, dmem_a_din, dmem_a_dout : std_logic_vector(15 downto 0);
  signal dmem_a_wr, dmem_a_rd                 : std_logic;
  signal dmem_b_addr, dmem_b_din, dmem_b_dout : std_logic_vector(15 downto 0);
  signal dmem_b_wr, dmem_b_rd                 : std_logic;

begin

  --------------------------------------------------------------------------
  -- Instantiations
  --------------------------------------------------------------------------

  u_bht : entity work.branch_predictor
    port map(clk, reset,
      bht_lookup_pc1, bht_predict1,
      bht_lookup_pc2, bht_predict2,
      bht_update_en, bht_update_pc, bht_update_taken);

  u_fetch : entity work.fetch_unit
    port map(clk, reset, stall, flush, flush_target,
      imem_addr, imem_data,
      bht_predict1, bht_predict2, bht_lookup_pc1, bht_lookup_pc2,
      f_valid1, f_instr1, f_pc1, f_pred1, f_ptgt1,
      f_valid2, f_instr2, f_pc2, f_pred2, f_ptgt2);

  u_imem : entity work.instr_mem
    port map(clk, imem_addr, imem_data,
      imem_wr_en, imem_wr_addr, imem_wr_data);

  u_dec0 : entity work.decoder
    port map(f_instr1, f_pc1, f_valid1, dec0);

  u_dec1 : entity work.decoder
    port map(f_instr2, f_pc2, f_valid2, dec1);

  u_intradep : entity work.intra_dep_checker
    port map(dec0, dec1, i2s1, i2s2, i2c, i2z);

  -- Decode -> Rename pipeline register
  process(clk, reset)
  begin
    if reset = '1' or flush = '1' then
      dec0_r  <= DECODED_NOP;
      dec1_r  <= DECODED_NOP;
      pred0_r <= '0'; pred1_r <= '0';
      ptgt0_r <= x"0000"; ptgt1_r <= x"0000";
    elsif rising_edge(clk) then
      if stall = '0' then
        dec0_r  <= dec0;
        dec1_r  <= dec1;
        pred0_r <= f_pred1;
        pred1_r <= f_pred2;
        ptgt0_r <= f_ptgt1;
        ptgt1_r <= f_ptgt2;
      end if;
    end if;
  end process;

  u_arf : entity work.arf
    port map(clk, reset,
      arf_rd_addr0, arf_rd_data0,
      arf_rd_addr1, arf_rd_data1,
      arf_rd_addr2, arf_rd_data2,
      arf_rd_addr3, arf_rd_data3,
      arf_rd_addr4, arf_rd_data4,
      arf_rd_addr5, arf_rd_data5,
      arf_wr_en0, arf_wr_addr0, arf_wr_data0,
      arf_wr_en1, arf_wr_addr1, arf_wr_data1,
      c_arch, z_arch,
      c_wr_en, c_wr_val, z_wr_en, z_wr_val,
      regs_out);

  u_rename : entity work.rename_dispatch
    port map(clk, reset, flush or rat_restore,
      dec0_r, dec1_r,
      i2s1, i2s2, i2c, i2z,
      pred0_r, ptgt0_r, pred1_r, ptgt1_r,
      rob_alloc_tag0, rob_alloc_tag1, rob_num_free,
      rob_rd_tag0, rob_rd_val0, rob_rd_done0, rob_rd_c0, rob_rd_z0,
      rob_rd_tag1, rob_rd_val1, rob_rd_done1, rob_rd_c1, rob_rd_z1,
      arf_rd_addr0, arf_rd_data0,
      arf_rd_addr1, arf_rd_data1,
      arf_rd_addr2, arf_rd_data2,
      arf_rd_addr3, arf_rd_data3,
      arf_rd_addr4, arf_rd_data4,
      arf_rd_addr5, arf_rd_data5,
      c_arch, z_arch,
      rs_num_free,
      rs_disp_en0, rs_disp_entry0,
      rs_disp_en1, rs_disp_entry1,
      rob_alloc_en0, rob_alloc_data0,
      rob_alloc_en1, rob_alloc_data1,
      stall);

  u_rs : entity work.reservation_station
    port map(clk, reset, flush,
      rs_disp_en0, rs_disp_entry0,
      rs_disp_en1, rs_disp_entry1,
      cdb0, cdb1,
      rs_issue0_valid, rs_issue0_entry,
      rs_issue1_valid, rs_issue1_entry,
      rs_num_free);

  -- Execute pipe 0
  u_exec0 : entity work.execute_alu
    port map(
      rs_issue0_valid,
      rs_issue0_entry.opcode, rs_issue0_entry.complement, rs_issue0_entry.condition,
      rs_issue0_entry.opr1, rs_issue0_entry.opr2,
      rs_issue0_entry.c_val, rs_issue0_entry.z_val,
      rs_issue0_entry.imm, rs_issue0_entry.pc,
      rs_issue0_entry.rob_tag,
      rs_issue0_entry.is_predicated,
      rs_issue0_entry.is_store, rs_issue0_entry.is_load,
      rs_issue0_entry.is_branch, rs_issue0_entry.is_jump,
      rs_issue0_entry.old_dest_val,
      rs_issue0_entry.predicted_taken,
      cdb0_pre);

  -- Execute pipe 1
  u_exec1 : entity work.execute_alu
    port map(
      rs_issue1_valid,
      rs_issue1_entry.opcode, rs_issue1_entry.complement, rs_issue1_entry.condition,
      rs_issue1_entry.opr1, rs_issue1_entry.opr2,
      rs_issue1_entry.c_val, rs_issue1_entry.z_val,
      rs_issue1_entry.imm, rs_issue1_entry.pc,
      rs_issue1_entry.rob_tag,
      rs_issue1_entry.is_predicated,
      rs_issue1_entry.is_store, rs_issue1_entry.is_load,
      rs_issue1_entry.is_branch, rs_issue1_entry.is_jump,
      rs_issue1_entry.old_dest_val,
      rs_issue1_entry.predicted_taken,
      cdb1_pre);

  u_rob : entity work.rob
    port map(clk, reset, flush,
      rob_alloc_en0, rob_alloc_data0,
      rob_alloc_en1, rob_alloc_data1,
      rob_alloc_tag0, rob_alloc_tag1,
      cdb0, cdb1,
      rob_head_entry, rob_head1_entry,
      rob_retire0, rob_retire1,
      rob_rd_tag0, rob_rd_val0, rob_rd_done0, rob_rd_c0, rob_rd_z0,
      rob_rd_tag1, rob_rd_val1, rob_rd_done1, rob_rd_c1, rob_rd_z1,
      rob_head_ptr, rob_tail_ptr, rob_num_free);

  u_retire : entity work.retire_unit
    port map(clk, reset,
      rob_head_entry, rob_head1_entry, rob_head_ptr,
      rob_retire0, rob_retire1,
      arf_wr_en0, arf_wr_addr0, arf_wr_data0,
      arf_wr_en1, arf_wr_addr1, arf_wr_data1,
      c_wr_en, c_wr_val, z_wr_en, z_wr_val,
      flush, flush_target, rat_restore,
      sb_commit_en0, sb_commit_tag0,
      sb_commit_en1, sb_commit_tag1,
      bht_update_en, bht_update_pc, bht_update_taken);

  u_sb : entity work.store_buffer
    port map(clk, reset, flush,
      cdb0, cdb1,
      sb_commit_en0, sb_commit_tag0,
      sb_commit_en1, sb_commit_tag1,
      sb_drain_valid, sb_drain_addr, sb_drain_data,
      x"0000", '0',  -- fwd check (TODO: connect to load pipe)
      open, open,
      sb_num_free);

  u_dmem : entity work.data_mem
    port map(clk,
      dmem_a_addr, dmem_a_din, dmem_a_dout, dmem_a_wr, dmem_a_rd,
      dmem_b_addr, dmem_b_din, dmem_b_dout, dmem_b_wr, dmem_b_rd);

  -- Data memory port A: testbench init takes priority (only active during reset),
  -- otherwise used by store buffer drain
  dmem_a_addr <= dmem_wr_addr  when dmem_wr_en = '1' else sb_drain_addr;
  dmem_a_din  <= dmem_wr_data  when dmem_wr_en = '1' else sb_drain_data;
  dmem_a_wr   <= dmem_wr_en    when dmem_wr_en = '1' else sb_drain_valid;
  dmem_a_rd   <= '0';
  dmem_b_din  <= (others => '0');  -- port B is read-only (loads)
  dmem_b_wr   <= '0';

  --------------------------------------------------------------------------
  -- Load data path (combinational)
  -- execute_alu puts the computed address in cdb_pre.result for loads.
  -- Route that address to data memory port B (async read), then replace
  -- result with the returned data before broadcasting on the final CDB.
  -- Pipe 0 gets priority; pipe 1 uses port B only if pipe 0 has no load.
  -- Note: two simultaneous loads are not supported (no second read port).
  --------------------------------------------------------------------------
  process(all)
    variable c0 : cdb_t;
    variable c1 : cdb_t;
  begin
    c0 := cdb0_pre;
    c1 := cdb1_pre;

    -- Default: no load read on port B
    dmem_b_addr <= (others => '0');
    dmem_b_rd   <= '0';

    if cdb0_pre.valid = '1' and cdb0_pre.is_load = '1' then
      -- Pipe 0 has a load: send address to port B
      dmem_b_addr  <= cdb0_pre.result;
      dmem_b_rd    <= '1';
      -- Replace result with loaded data; recompute Z
      c0.result    := dmem_b_dout;
      if dmem_b_dout = x"0000" then
        c0.z_val := '1';
      else
        c0.z_val := '0';
      end if;

    elsif cdb1_pre.valid = '1' and cdb1_pre.is_load = '1' then
      -- Pipe 1 has a load and pipe 0 does not: use port B for pipe 1
      dmem_b_addr  <= cdb1_pre.result;
      dmem_b_rd    <= '1';
      c1.result    := dmem_b_dout;
      if dmem_b_dout = x"0000" then
        c1.z_val := '1';
      else
        c1.z_val := '0';
      end if;
    end if;

    cdb0 <= c0;
    cdb1 <= c1;
  end process;

  -- Flag outputs
  c_flag <= c_arch;
  z_flag <= z_arch;

end architecture;
