library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pkg.all;

-- Retire Unit
-- Commits up to 2 instructions per cycle from ROB head, in program order
-- Updates ARF and architectural flags
-- Detects mispredictions and R0 writes -> triggers flush
-- Commits stores in store buffer
-- Updates branch predictor BHT

entity retire_unit is
  port(
    clk, reset : in std_logic;

    -- ROB head entries (from ROB)
    head_entry  : in rob_entry_t;
    head1_entry : in rob_entry_t;
    rob_head    : in std_logic_vector(3 downto 0);

    -- Retire signals (to ROB — advance head pointer)
    retire0 : out std_logic;
    retire1 : out std_logic;

    -- ARF write ports
    arf_wr_en0   : out std_logic;
    arf_wr_addr0 : out std_logic_vector(2 downto 0);
    arf_wr_data0 : out std_logic_vector(15 downto 0);
    arf_wr_en1   : out std_logic;
    arf_wr_addr1 : out std_logic_vector(2 downto 0);
    arf_wr_data1 : out std_logic_vector(15 downto 0);

    -- Flag updates to ARF
    c_wr_en  : out std_logic;
    c_wr_val : out std_logic;
    z_wr_en  : out std_logic;
    z_wr_val : out std_logic;

    -- Flush output
    flush        : out std_logic;
    flush_target : out std_logic_vector(15 downto 0);

    -- RAT restore signal (on flush, frontend RAT resets to all-invalid)
    rat_restore : out std_logic;

    -- Store buffer commit
    sb_commit_en0  : out std_logic;
    sb_commit_tag0 : out std_logic_vector(3 downto 0);
    sb_commit_en1  : out std_logic;
    sb_commit_tag1 : out std_logic_vector(3 downto 0);

    -- Branch predictor update
    bht_update_en    : out std_logic;
    bht_update_pc    : out std_logic_vector(15 downto 0);
    bht_update_taken : out std_logic
  );
end entity;

architecture rtl of retire_unit is
begin

  process(all)
    variable do_retire0    : std_logic;
    variable do_retire1    : std_logic;
    variable do_flush      : std_logic;
    variable flush_tgt     : std_logic_vector(15 downto 0);
    variable wr0_en        : std_logic;
    variable wr1_en        : std_logic;
    variable c_en, z_en    : std_logic;
    variable c_v, z_v      : std_logic;
    variable sb0_en, sb1_en: std_logic;
    variable bht_en        : std_logic;
    variable bht_pc        : std_logic_vector(15 downto 0);
    variable bht_taken     : std_logic;
    -- For second retire, we accumulate flag values from first
    variable c_en2, z_en2  : std_logic;
    variable c_v2, z_v2    : std_logic;
  begin
    -- Defaults
    do_retire0 := '0';
    do_retire1 := '0';
    do_flush   := '0';
    flush_tgt  := (others => '0');
    wr0_en     := '0';
    wr1_en     := '0';
    c_en       := '0';  z_en := '0';
    c_v        := '0';  z_v  := '0';
    c_en2      := '0';  z_en2 := '0';
    c_v2       := '0';  z_v2  := '0';
    sb0_en     := '0';  sb1_en := '0';
    bht_en     := '0';
    bht_pc     := (others => '0');
    bht_taken  := '0';

    -------------------------------------------------------------------
    -- Retire slot 0: ROB head
    -------------------------------------------------------------------
    if head_entry.valid = '1' and head_entry.done = '1' then
      do_retire0 := '1';

      -- Check for misprediction
      if head_entry.mispredicted = '1' then
        do_flush  := '1';
        if head_entry.branch_taken = '1' then
          flush_tgt := head_entry.branch_target;
        else
          -- Branch was not taken but predicted taken
          -- Correct PC = instruction PC + 2 (next sequential)
          flush_tgt := std_logic_vector(unsigned(head_entry.pc) + 2);
        end if;
      end if;

      -- Check for non-branch writing to R0 (control flow change)
      if head_entry.has_dest = '1' and head_entry.dest_reg = "000"
         and head_entry.is_branch = '0' and head_entry.is_nop = '0' then
        do_flush  := '1';
        flush_tgt := head_entry.result;  -- new PC = written value
      end if;

      -- Write result to ARF (if has destination and not NOP)
      if head_entry.has_dest = '1' and head_entry.is_nop = '0' then
        wr0_en := '1';
      end if;

      -- Update architectural flags (if instruction writes them and not NOP)
      if head_entry.writes_c = '1' and head_entry.is_nop = '0' then
        c_en := '1';
        c_v  := head_entry.c_val;
      end if;
      if head_entry.writes_z = '1' and head_entry.is_nop = '0' then
        z_en := '1';
        z_v  := head_entry.z_val;
      end if;

      -- Commit store in store buffer
      if head_entry.is_store = '1' then
        sb0_en := '1';
      end if;

      -- Update branch predictor
      if head_entry.is_branch = '1' then
        bht_en    := '1';
        bht_pc    := head_entry.pc;
        bht_taken := head_entry.branch_taken;
      end if;

      -----------------------------------------------------------------
      -- Retire slot 1: ROB head+1
      -- Only if slot 0 retired successfully and did NOT trigger a flush
      -----------------------------------------------------------------
      if do_flush = '0' then
        if head1_entry.valid = '1' and head1_entry.done = '1' then
          do_retire1 := '1';

          -- Check for misprediction
          if head1_entry.mispredicted = '1' then
            do_flush  := '1';
            if head1_entry.branch_taken = '1' then
              flush_tgt := head1_entry.branch_target;
            else
              flush_tgt := std_logic_vector(unsigned(head1_entry.pc) + 2);
            end if;
          end if;

          -- Check for non-branch writing R0
          if head1_entry.has_dest = '1' and head1_entry.dest_reg = "000"
             and head1_entry.is_branch = '0' and head1_entry.is_nop = '0' then
            do_flush  := '1';
            flush_tgt := head1_entry.result;
          end if;

          -- Write result to ARF
          if head1_entry.has_dest = '1' and head1_entry.is_nop = '0' then
            wr1_en := '1';
          end if;

          -- Flags (slot 1 values — will override slot 0 if both write)
          if head1_entry.writes_c = '1' and head1_entry.is_nop = '0' then
            c_en2 := '1';
            c_v2  := head1_entry.c_val;
          end if;
          if head1_entry.writes_z = '1' and head1_entry.is_nop = '0' then
            z_en2 := '1';
            z_v2  := head1_entry.z_val;
          end if;

          -- Commit store
          if head1_entry.is_store = '1' then
            sb1_en := '1';
          end if;

          -- BHT update (slot 1 branch — we can only update one per cycle,
          -- if slot 0 was also a branch, slot 0 already took the update port.
          -- In practice two consecutive branches are very rare.
          -- We prioritize slot 1 since it's later in program order.)
          if head1_entry.is_branch = '1' then
            bht_en    := '1';
            bht_pc    := head1_entry.pc;
            bht_taken := head1_entry.branch_taken;
          end if;

        end if;
      end if;

    end if;

    -------------------------------------------------------------------
    -- Drive outputs
    -------------------------------------------------------------------
    retire0 <= do_retire0;
    retire1 <= do_retire1;

    arf_wr_en0   <= wr0_en;
    arf_wr_addr0 <= head_entry.dest_reg;
    arf_wr_data0 <= head_entry.result;

    arf_wr_en1   <= wr1_en;
    arf_wr_addr1 <= head1_entry.dest_reg;
    arf_wr_data1 <= head1_entry.result;

    -- Flags: if both slots write, slot 1 (later in program order) wins
    -- We output the later one's values as the "final" flag write
    if c_en2 = '1' then
      c_wr_en  <= '1';
      c_wr_val <= c_v2;
    elsif c_en = '1' then
      c_wr_en  <= '1';
      c_wr_val <= c_v;
    else
      c_wr_en  <= '0';
      c_wr_val <= '0';
    end if;

    if z_en2 = '1' then
      z_wr_en  <= '1';
      z_wr_val <= z_v2;
    elsif z_en = '1' then
      z_wr_en  <= '1';
      z_wr_val <= z_v;
    else
      z_wr_en  <= '0';
      z_wr_val <= '0';
    end if;

    flush        <= do_flush;
    flush_target <= flush_tgt;
    rat_restore  <= do_flush;

    sb_commit_en0  <= sb0_en;
    sb_commit_tag0 <= std_logic_vector(unsigned(rob_head));
    sb_commit_en1  <= sb1_en;
    sb_commit_tag1 <= std_logic_vector(unsigned(rob_head) + 1);

    bht_update_en    <= bht_en;
    bht_update_pc    <= bht_pc;
    bht_update_taken <= bht_taken;

  end process;

end architecture;
