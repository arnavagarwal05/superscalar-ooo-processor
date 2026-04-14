library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pkg.all;

-- Reservation Station (unified, 8 entries)
-- Accepts up to 2 dispatched instructions per cycle
-- Snoops 2 CDB buses to capture operand values
-- Outputs up to 2 ready instructions per cycle (oldest-first)

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
  signal entries : rs_array_t;
  signal age_counter : unsigned(3 downto 0);  -- monotonically increasing dispatch counter
begin

  process(clk, reset)
    variable e : rs_entry_t;
    -- for issue selection
    variable ready       : std_logic_vector(RS_SIZE-1 downto 0);
    variable oldest_idx  : integer;
    variable second_idx  : integer;
    variable oldest_age  : unsigned(3 downto 0);
    variable second_age  : unsigned(3 downto 0);
    variable found_first : boolean;
    variable found_second: boolean;
    variable first_is_mem: boolean;
    -- for allocation
    variable free0_found : boolean;
    variable free0_idx   : integer;
    variable free1_found : boolean;
    variable free1_idx   : integer;
    variable free_count  : unsigned(3 downto 0);
  begin
    if reset = '1' or flush = '1' then
      for i in 0 to RS_SIZE-1 loop
        entries(i).busy <= '0';
      end loop;
      age_counter <= (others => '0');

    elsif rising_edge(clk) then

      -----------------------------------------------------------------
      -- Phase 1: CDB snoop — capture values for waiting operands
      -----------------------------------------------------------------
      for i in 0 to RS_SIZE-1 loop
        if entries(i).busy = '1' then

          -- Snoop CDB bus 0
          if cdb0.valid = '1' then
            -- Check operand 1
            if entries(i).v1 = '0' and entries(i).opr1(3 downto 0) = cdb0.rob_tag then
              entries(i).opr1 <= cdb0.result;
              entries(i).v1   <= '1';
            end if;
            -- Check operand 2
            if entries(i).v2 = '0' and entries(i).opr2(3 downto 0) = cdb0.rob_tag then
              entries(i).opr2 <= cdb0.result;
              entries(i).v2   <= '1';
            end if;
            -- Check C flag
            if entries(i).needs_c = '1' and entries(i).c_ready = '0'
               and entries(i).c_tag = cdb0.rob_tag and cdb0.writes_c = '1' then
              entries(i).c_val   <= cdb0.c_val;
              entries(i).c_ready <= '1';
            end if;
            -- Check Z flag
            if entries(i).needs_z = '1' and entries(i).z_ready = '0'
               and entries(i).z_tag = cdb0.rob_tag and cdb0.writes_z = '1' then
              entries(i).z_val   <= cdb0.z_val;
              entries(i).z_ready <= '1';
            end if;
          end if;

          -- Snoop CDB bus 1 (same logic)
          if cdb1.valid = '1' then
            if entries(i).v1 = '0' and entries(i).opr1(3 downto 0) = cdb1.rob_tag then
              entries(i).opr1 <= cdb1.result;
              entries(i).v1   <= '1';
            end if;
            if entries(i).v2 = '0' and entries(i).opr2(3 downto 0) = cdb1.rob_tag then
              entries(i).opr2 <= cdb1.result;
              entries(i).v2   <= '1';
            end if;
            if entries(i).needs_c = '1' and entries(i).c_ready = '0'
               and entries(i).c_tag = cdb1.rob_tag and cdb1.writes_c = '1' then
              entries(i).c_val   <= cdb1.c_val;
              entries(i).c_ready <= '1';
            end if;
            if entries(i).needs_z = '1' and entries(i).z_ready = '0'
               and entries(i).z_tag = cdb1.rob_tag and cdb1.writes_z = '1' then
              entries(i).z_val   <= cdb1.z_val;
              entries(i).z_ready <= '1';
            end if;
          end if;

        end if;
      end loop;

      -----------------------------------------------------------------
      -- Phase 2: Issue — find 2 oldest ready entries, free them
      -- (Ready check uses values AFTER CDB snoop above)
      -----------------------------------------------------------------
      -- This is handled combinationally below for output,
      -- but we need to clear busy bits here
      -- The issue outputs are computed combinationally (see below)

      -- Find ready entries and pick oldest
      found_first  := false;
      found_second := false;
      oldest_idx   := 0;
      second_idx   := 0;
      oldest_age   := (others => '1');
      second_age   := (others => '1');
      first_is_mem := false;

      for i in 0 to RS_SIZE-1 loop
        e := entries(i);
        -- ready condition
        ready(i) := e.busy
                     and e.v1 and e.v2
                     and (not e.needs_c or e.c_ready)
                     and (not e.needs_z or e.z_ready);

        if ready(i) = '1' then
          if not found_first or e.age < oldest_age then
            -- push current first to second
            if found_first then
              found_second := true;
              second_idx   := oldest_idx;
              second_age   := oldest_age;
            end if;
            found_first := true;
            oldest_idx  := i;
            oldest_age  := e.age;
            first_is_mem := (e.is_load = '1' or e.is_store = '1');
          elsif not found_second or e.age < second_age then
            found_second := true;
            second_idx   := i;
            second_age   := e.age;
          end if;
        end if;
      end loop;

      -- Clear issued entries
      if found_first then
        entries(oldest_idx).busy <= '0';
      end if;
      if found_second then
        entries(second_idx).busy <= '0';
      end if;

      -----------------------------------------------------------------
      -- Phase 3: Allocate — write new dispatched entries into free slots
      -----------------------------------------------------------------
      free0_found := false;
      free1_found := false;
      free0_idx   := 0;
      free1_idx   := 0;

      for i in 0 to RS_SIZE-1 loop
        if entries(i).busy = '0' then
          -- Don't allocate into a slot we just freed from issue
          -- (it will be busy='0' after the issue phase above)
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
        entries(free0_idx) <= disp_entry0;
        entries(free0_idx).age <= age_counter;
        age_counter <= age_counter + 1;
      end if;

      if disp_en1 = '1' and free1_found then
        entries(free1_idx) <= disp_entry1;
        entries(free1_idx).age <= age_counter + 1;
        age_counter <= age_counter + 2;
      end if;

    end if;
  end process;

  -----------------------------------------------------------------------
  -- Combinational issue outputs
  -- (The actual clearing happens in the clocked process above)
  -----------------------------------------------------------------------
  process(all)
    variable rdy : std_logic;
    variable best_idx, second_best_idx : integer;
    variable best_age, second_best_age : unsigned(3 downto 0);
    variable found1, found2 : boolean;
    variable e : rs_entry_t;
  begin
    issue0_valid <= '0';
    issue1_valid <= '0';
    issue0_entry <= entries(0);
    issue1_entry <= entries(0);

    found1 := false;
    found2 := false;
    best_idx := 0;
    second_best_idx := 0;
    best_age := (others => '1');
    second_best_age := (others => '1');

    for i in 0 to RS_SIZE-1 loop
      e := entries(i);
      rdy := e.busy
             and e.v1 and e.v2
             and (not e.needs_c or e.c_ready)
             and (not e.needs_z or e.z_ready);

      if rdy = '1' then
        if not found1 or e.age < best_age then
          if found1 then
            found2 := true;
            second_best_idx := best_idx;
            second_best_age := best_age;
          end if;
          found1   := true;
          best_idx := i;
          best_age := e.age;
        elsif not found2 or e.age < second_best_age then
          found2 := true;
          second_best_idx := i;
          second_best_age := e.age;
        end if;
      end if;
    end loop;

    if found1 then
      issue0_valid <= '1';
      issue0_entry <= entries(best_idx);
    end if;
    if found2 then
      issue1_valid <= '1';
      issue1_entry <= entries(second_best_idx);
    end if;
  end process;

  -- Count free entries
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
