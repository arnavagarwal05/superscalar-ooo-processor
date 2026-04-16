library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pkg.all;

-- Reservation Station (unified, 8 entries)
-- Accepts up to 2 dispatched instructions per cycle
-- Snoops 2 CDB buses to capture operand values
-- Outputs up to 2 ready instructions per cycle (oldest-first)
--
-- Fix: all three phases (snoop, issue, allocate) operate on a local
-- variable 'updated' that is initialised from the 'entries' signal at
-- the start of each rising edge.  Because variable assignments are
-- immediately visible within the same process activation, Phase 2 sees
-- the post-snoop ready state and Phase 3 sees the post-issue free slots.
-- Issue outputs are registered (one-cycle latency from ready to issue).

entity reservation_station is
  port(
    clk, reset, flush : in std_logic;

    -- Dispatch: write up to 2 new entries
    disp_en0    : in  std_logic;
    disp_entry0 : in  rs_entry_t;
    disp_en1    : in  std_logic;
    disp_entry1 : in  rs_entry_t;

    -- CDB snoop (2 buses)
    cdb0 : in cdb_t;
    cdb1 : in cdb_t;

    -- Issue outputs (up to 2 ready instructions)
    issue0_valid : out std_logic;
    issue0_entry : out rs_entry_t;
    issue1_valid : out std_logic;
    issue1_entry : out rs_entry_t;

    -- Status
    num_free : out unsigned(3 downto 0)  -- number of free entries
  );
end entity;

architecture rtl of reservation_station is
  signal entries     : rs_array_t;
  signal age_counter : unsigned(3 downto 0);

  -- Registered issue outputs (driven from the clocked process)
  signal issue0_valid_r : std_logic;
  signal issue0_entry_r : rs_entry_t;
  signal issue1_valid_r : std_logic;
  signal issue1_entry_r : rs_entry_t;
begin

  process(clk, reset)
    -- Local variable copy: all phases read/write this, so updates in
    -- Phase 1 are immediately visible to Phase 2, and Phase 2 free-ups
    -- are immediately visible to Phase 3.
    variable updated     : rs_array_t;
    variable e           : rs_entry_t;
    -- issue selection
    variable oldest_idx  : integer;
    variable second_idx  : integer;
    variable oldest_age  : unsigned(3 downto 0);
    variable second_age  : unsigned(3 downto 0);
    variable found_first : boolean;
    variable found_second: boolean;
    variable first_is_mem: boolean;
    -- allocation
    variable free0_found : boolean;
    variable free0_idx   : integer;
    variable free1_found : boolean;
    variable free1_idx   : integer;
  begin
    if reset = '1' or flush = '1' then
      for i in 0 to RS_SIZE-1 loop
        entries(i).busy <= '0';
      end loop;
      age_counter    <= (others => '0');
      issue0_valid_r <= '0';
      issue1_valid_r <= '0';

    elsif rising_edge(clk) then

      -- Snapshot signal into variable so all phases share the same view
      updated := entries;

      -----------------------------------------------------------------
      -- Phase 1: CDB snoop — update variable immediately
      -----------------------------------------------------------------
      for i in 0 to RS_SIZE-1 loop
        if updated(i).busy = '1' then

          -- Snoop CDB bus 0
          if cdb0.valid = '1' then
            if updated(i).v1 = '0' and updated(i).opr1(3 downto 0) = cdb0.rob_tag then
              updated(i).opr1 := cdb0.result;
              updated(i).v1   := '1';
            end if;
            if updated(i).v2 = '0' and updated(i).opr2(3 downto 0) = cdb0.rob_tag then
              updated(i).opr2 := cdb0.result;
              updated(i).v2   := '1';
            end if;
            if updated(i).needs_c = '1' and updated(i).c_ready = '0'
               and updated(i).c_tag = cdb0.rob_tag and cdb0.writes_c = '1' then
              updated(i).c_val   := cdb0.c_val;
              updated(i).c_ready := '1';
            end if;
            if updated(i).needs_z = '1' and updated(i).z_ready = '0'
               and updated(i).z_tag = cdb0.rob_tag and cdb0.writes_z = '1' then
              updated(i).z_val   := cdb0.z_val;
              updated(i).z_ready := '1';
            end if;
          end if;

          -- Snoop CDB bus 1
          if cdb1.valid = '1' then
            if updated(i).v1 = '0' and updated(i).opr1(3 downto 0) = cdb1.rob_tag then
              updated(i).opr1 := cdb1.result;
              updated(i).v1   := '1';
            end if;
            if updated(i).v2 = '0' and updated(i).opr2(3 downto 0) = cdb1.rob_tag then
              updated(i).opr2 := cdb1.result;
              updated(i).v2   := '1';
            end if;
            if updated(i).needs_c = '1' and updated(i).c_ready = '0'
               and updated(i).c_tag = cdb1.rob_tag and cdb1.writes_c = '1' then
              updated(i).c_val   := cdb1.c_val;
              updated(i).c_ready := '1';
            end if;
            if updated(i).needs_z = '1' and updated(i).z_ready = '0'
               and updated(i).z_tag = cdb1.rob_tag and cdb1.writes_z = '1' then
              updated(i).z_val   := cdb1.z_val;
              updated(i).z_ready := '1';
            end if;
          end if;

        end if;
      end loop;

      -----------------------------------------------------------------
      -- Phase 2: Issue — select 2 oldest ready entries from updated
      -- (sees post-snoop values because 'updated' is a variable)
      -----------------------------------------------------------------
      found_first  := false;
      found_second := false;
      oldest_idx   := 0;
      second_idx   := 0;
      oldest_age   := (others => '1');
      second_age   := (others => '1');
      first_is_mem := false;

      for i in 0 to RS_SIZE-1 loop
        e := updated(i);
        if e.busy = '1'
           and e.v1 = '1' and e.v2 = '1'
           and (e.needs_c = '0' or e.c_ready = '1')
           and (e.needs_z = '0' or e.z_ready = '1') then

          if not found_first or e.age < oldest_age then
            if found_first then
              found_second := true;
              second_idx   := oldest_idx;
              second_age   := oldest_age;
            end if;
            found_first  := true;
            oldest_idx   := i;
            oldest_age   := e.age;
            first_is_mem := (e.is_load = '1' or e.is_store = '1');
          elsif not found_second or e.age < second_age then
            found_second := true;
            second_idx   := i;
            second_age   := e.age;
          end if;
        end if;
      end loop;

      -- Latch issue outputs and clear busy in variable
      issue0_valid_r <= '0';
      issue1_valid_r <= '0';
      if found_first then
        issue0_valid_r        <= '1';
        issue0_entry_r        <= updated(oldest_idx);
        updated(oldest_idx).busy := '0';   -- immediately visible to Phase 3
      end if;
      if found_second then
        issue1_valid_r        <= '1';
        issue1_entry_r        <= updated(second_idx);
        updated(second_idx).busy := '0';   -- immediately visible to Phase 3
      end if;

      -----------------------------------------------------------------
      -- Phase 3: Allocate — find free slots in updated (sees just-freed
      -- slots from Phase 2 because 'updated' is a variable)
      -----------------------------------------------------------------
      free0_found := false;
      free1_found := false;
      free0_idx   := 0;
      free1_idx   := 0;

      for i in 0 to RS_SIZE-1 loop
        if updated(i).busy = '0' then
          if not free0_found then
            free0_found := true;
            free0_idx   := i;
          elsif not free1_found then
            free1_found := true;
            free1_idx   := i;
          end if;
        end if;
      end loop;

      if disp_en0 = '1' and free0_found then
        updated(free0_idx)     := disp_entry0;
        updated(free0_idx).age := age_counter;
        age_counter <= age_counter + 1;
      end if;

      if disp_en1 = '1' and free1_found then
        updated(free1_idx)     := disp_entry1;
        updated(free1_idx).age := age_counter + 1;
        age_counter <= age_counter + 2;
      end if;

      -- Write variable back to signal once — single source of truth
      for i in 0 to RS_SIZE-1 loop
        entries(i) <= updated(i);
      end loop;

    end if;
  end process;

  -- Issue outputs are registered signals (no combinational process needed)
  issue0_valid <= issue0_valid_r;
  issue0_entry <= issue0_entry_r;
  issue1_valid <= issue1_valid_r;
  issue1_entry <= issue1_entry_r;

  -- Count free entries (combinational, one cycle stale — acceptable for stall)
  process(all)
    variable cnt : unsigned(3 downto 0);
  begin
    cnt := (others => '0');
    for i in 0 to RS_SIZE-1 loop
      if entries(i).busy = '0' then
        cnt := cnt + 1;
      end if;
    end loop;
    num_free <= cnt;
  end process;

end architecture;
