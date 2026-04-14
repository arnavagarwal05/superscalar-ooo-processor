library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pkg.all;

-- Store Buffer (4 entries, FIFO)
-- Written by execute pipes when a store computes its address+data
-- Committed by retire unit when the store reaches ROB head
-- Committed entries drain to data memory (1 per cycle)
-- Loads check store buffer for forwarding (address match)

entity store_buffer is
  port(
    clk, reset, flush : in std_logic;

    -- Write port (from CDB — when a store completes execution)
    -- We check CDB for store instructions and capture addr+data
    cdb0 : in cdb_t;
    cdb1 : in cdb_t;

    -- Commit port (from retire — marks entry as safe to drain to memory)
    commit_en0  : in std_logic;
    commit_tag0 : in std_logic_vector(3 downto 0);  -- ROB tag of retiring store
    commit_en1  : in std_logic;
    commit_tag1 : in std_logic_vector(3 downto 0);

    -- Drain port (to data memory — writes committed stores)
    drain_valid : out std_logic;
    drain_addr  : out std_logic_vector(15 downto 0);
    drain_data  : out std_logic_vector(15 downto 0);

    -- Store-to-load forwarding (checked by loads in execute)
    fwd_check_addr : in  std_logic_vector(15 downto 0);
    fwd_check_en   : in  std_logic;
    fwd_hit        : out std_logic;  -- 1 if matching store found
    fwd_data       : out std_logic_vector(15 downto 0);

    -- Status
    num_free : out unsigned(2 downto 0)  -- free entries count
  );
end entity;

architecture rtl of store_buffer is
  signal entries : sb_array_t;
  -- FIFO pointers for ordering
  signal wr_ptr   : unsigned(1 downto 0);  -- next write position
  signal drain_ptr: unsigned(1 downto 0);  -- next entry to drain
begin

  -----------------------------------------------------------------------
  -- Store-to-load forwarding: combinational
  -- Search all valid entries for address match
  -- If multiple match, newest (highest write order) wins
  -----------------------------------------------------------------------
  process(all)
    variable hit : std_logic;
    variable dat : std_logic_vector(15 downto 0);
  begin
    hit := '0';
    dat := (others => '0');

    if fwd_check_en = '1' then
      -- Search from oldest to newest; newest match overwrites
      for i in 0 to SB_SIZE-1 loop
        if entries(i).valid = '1' and entries(i).addr = fwd_check_addr then
          hit := '1';
          dat := entries(i).data;
        end if;
      end loop;
    end if;

    fwd_hit  <= hit;
    fwd_data <= dat;
  end process;

  -----------------------------------------------------------------------
  -- Drain: oldest committed entry
  -----------------------------------------------------------------------
  process(all)
  begin
    drain_valid <= '0';
    drain_addr  <= (others => '0');
    drain_data  <= (others => '0');

    if entries(to_integer(drain_ptr)).valid = '1'
       and entries(to_integer(drain_ptr)).committed = '1' then
      drain_valid <= '1';
      drain_addr  <= entries(to_integer(drain_ptr)).addr;
      drain_data  <= entries(to_integer(drain_ptr)).data;
    end if;
  end process;

  -----------------------------------------------------------------------
  -- Free count
  -----------------------------------------------------------------------
  process(all)
    variable cnt : unsigned(2 downto 0);
  begin
    cnt := (others => '0');
    for i in 0 to SB_SIZE-1 loop
      if entries(i).valid = '0' then
        cnt := cnt + 1;
      end if;
    end loop;
    num_free <= cnt;
  end process;

  -----------------------------------------------------------------------
  -- Clocked: write from CDB, commit from retire, drain advance
  -----------------------------------------------------------------------
  process(clk, reset)
  begin
    if reset = '1' then
      for i in 0 to SB_SIZE-1 loop
        entries(i) <= SB_ENTRY_EMPTY;
      end loop;
      wr_ptr    <= (others => '0');
      drain_ptr <= (others => '0');

    elsif rising_edge(clk) then

      if flush = '1' then
        -- On flush: invalidate all uncommitted entries
        -- Committed entries remain (they are architecturally correct)
        for i in 0 to SB_SIZE-1 loop
          if entries(i).committed = '0' then
            entries(i).valid <= '0';
          end if;
        end loop;
        -- Reset write pointer (drain pointer stays — committed stores still drain)
        wr_ptr <= drain_ptr;

      else

        -----------------------------------------------------------
        -- Write: capture stores from CDB
        -----------------------------------------------------------
        if cdb0.valid = '1' and cdb0.is_store = '1' then
          entries(to_integer(wr_ptr)).valid     <= '1';
          entries(to_integer(wr_ptr)).addr      <= cdb0.store_addr;
          entries(to_integer(wr_ptr)).data      <= cdb0.store_data;
          entries(to_integer(wr_ptr)).rob_tag   <= cdb0.rob_tag;
          entries(to_integer(wr_ptr)).committed <= '0';
          wr_ptr <= wr_ptr + 1;
        end if;

        if cdb1.valid = '1' and cdb1.is_store = '1' then
          -- If cdb0 also wrote this cycle, wr_ptr already advanced
          if cdb0.valid = '1' and cdb0.is_store = '1' then
            entries(to_integer(wr_ptr + 1)).valid     <= '1';
            entries(to_integer(wr_ptr + 1)).addr      <= cdb1.store_addr;
            entries(to_integer(wr_ptr + 1)).data      <= cdb1.store_data;
            entries(to_integer(wr_ptr + 1)).rob_tag   <= cdb1.rob_tag;
            entries(to_integer(wr_ptr + 1)).committed <= '0';
            wr_ptr <= wr_ptr + 2;
          else
            entries(to_integer(wr_ptr)).valid     <= '1';
            entries(to_integer(wr_ptr)).addr      <= cdb1.store_addr;
            entries(to_integer(wr_ptr)).data      <= cdb1.store_data;
            entries(to_integer(wr_ptr)).rob_tag   <= cdb1.rob_tag;
            entries(to_integer(wr_ptr)).committed <= '0';
            wr_ptr <= wr_ptr + 1;
          end if;
        end if;

        -----------------------------------------------------------
        -- Commit: mark entries whose ROB tag matches retiring store
        -----------------------------------------------------------
        if commit_en0 = '1' then
          for i in 0 to SB_SIZE-1 loop
            if entries(i).valid = '1' and entries(i).committed = '0'
               and entries(i).rob_tag = commit_tag0 then
              entries(i).committed <= '1';
            end if;
          end loop;
        end if;

        if commit_en1 = '1' then
          for i in 0 to SB_SIZE-1 loop
            if entries(i).valid = '1' and entries(i).committed = '0'
               and entries(i).rob_tag = commit_tag1 then
              entries(i).committed <= '1';
            end if;
          end loop;
        end if;

        -----------------------------------------------------------
        -- Drain: free the oldest committed entry (it was written to memory)
        -----------------------------------------------------------
        if entries(to_integer(drain_ptr)).valid = '1'
           and entries(to_integer(drain_ptr)).committed = '1' then
          entries(to_integer(drain_ptr)).valid <= '0';
          drain_ptr <= drain_ptr + 1;
        end if;

      end if;
    end if;
  end process;

end architecture;
