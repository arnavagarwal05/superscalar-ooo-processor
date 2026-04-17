library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pkg.all;

-- Reorder Buffer (ROB)
-- 16-entry circular FIFO with head and tail pointers
-- Allocate at tail (from dispatch), complete by tag (from CDB), retire at head

entity rob is
  port(
    clk, reset, flush : in std_logic;

    -- Allocate ports (from dispatch, at tail)
    alloc_en0    : in  std_logic;
    alloc_data0  : in  rob_entry_t;
    alloc_en1    : in  std_logic;
    alloc_data1  : in  rob_entry_t;
    -- Allocated tags returned to dispatch
    alloc_tag0   : out std_logic_vector(3 downto 0);
    alloc_tag1   : out std_logic_vector(3 downto 0);

    -- CDB complete ports (2 buses)
    cdb0 : in cdb_t;
    cdb1 : in cdb_t;

    -- Retire interface: expose head and head+1 entries
    head_entry  : out rob_entry_t;
    head1_entry : out rob_entry_t;

    -- Retire control (from retire unit)
    retire0 : in std_logic;  -- retire head
    retire1 : in std_logic;  -- retire head+1 (only if retire0 also set)

    -- Value read ports (for dispatch operand resolution)
    -- Dispatch checks if a ROB entry is done and grabs its value
    rd_tag0      : in  std_logic_vector(3 downto 0);
    rd_val0      : out std_logic_vector(15 downto 0);
    rd_done0     : out std_logic;
    rd_c0        : out std_logic;
    rd_z0        : out std_logic;
    rd_tag1      : in  std_logic_vector(3 downto 0);
    rd_val1      : out std_logic_vector(15 downto 0);
    rd_done1     : out std_logic;
    rd_c1        : out std_logic;
    rd_z1        : out std_logic;

    -- Full entries array (for dispatch operand resolution)
    entries_out : out rob_array_t;

    -- Status
    head_ptr : out std_logic_vector(3 downto 0);
    tail_ptr : out std_logic_vector(3 downto 0);
    num_free : out unsigned(4 downto 0)  -- 0 to 16
  );
end entity;

architecture rtl of rob is
  signal entries : rob_array_t;
  signal head    : unsigned(3 downto 0);
  signal tail    : unsigned(3 downto 0);
  signal count   : unsigned(4 downto 0);  -- number of occupied entries
begin

  -- Tags for newly allocated entries = current tail, tail+1
  alloc_tag0 <= std_logic_vector(tail);
  alloc_tag1 <= std_logic_vector(tail + 1);

  -- Expose head entries for retire unit
  head_entry  <= entries(to_integer(head));
  head1_entry <= entries(to_integer(head + 1));

  -- Pointers for external use
  head_ptr <= std_logic_vector(head);
  tail_ptr <= std_logic_vector(tail);
  num_free <= to_unsigned(ROB_SIZE, 5) - count;

  -- Expose full entries array for dispatch operand resolution
  entries_out <= entries;

  -- Value read ports: dispatch reads ROB to check if operand is ready
  rd_val0  <= entries(to_integer(unsigned(rd_tag0))).result;
  rd_done0 <= entries(to_integer(unsigned(rd_tag0))).done;
  rd_c0    <= entries(to_integer(unsigned(rd_tag0))).c_val;
  rd_z0    <= entries(to_integer(unsigned(rd_tag0))).z_val;
  rd_val1  <= entries(to_integer(unsigned(rd_tag1))).result;
  rd_done1 <= entries(to_integer(unsigned(rd_tag1))).done;
  rd_c1    <= entries(to_integer(unsigned(rd_tag1))).c_val;
  rd_z1    <= entries(to_integer(unsigned(rd_tag1))).z_val;

  process(clk, reset)
    variable new_head : unsigned(3 downto 0);
    variable new_tail : unsigned(3 downto 0);
    variable new_count: unsigned(4 downto 0);
  begin
    if reset = '1' then
      head  <= (others => '0');
      tail  <= (others => '0');
      count <= (others => '0');
      for i in 0 to ROB_SIZE-1 loop
        entries(i) <= ROB_ENTRY_EMPTY;
      end loop;

    elsif rising_edge(clk) then

      if flush = '1' then
        -- On flush: reset tail to head, invalidate everything
        tail  <= head;
        count <= (others => '0');
        for i in 0 to ROB_SIZE-1 loop
          entries(i).valid <= '0';
          entries(i).done  <= '0';
        end loop;

      else
        new_head  := head;
        new_tail  := tail;
        new_count := count;

        ---------------------------------------------------------------
        -- CDB complete: mark entries as done, store results
        ---------------------------------------------------------------
        if cdb0.valid = '1' then
          entries(to_integer(unsigned(cdb0.rob_tag))).done          <= '1';
          entries(to_integer(unsigned(cdb0.rob_tag))).result        <= cdb0.result;
          entries(to_integer(unsigned(cdb0.rob_tag))).c_val         <= cdb0.c_val;
          entries(to_integer(unsigned(cdb0.rob_tag))).z_val         <= cdb0.z_val;
          entries(to_integer(unsigned(cdb0.rob_tag))).is_nop        <= cdb0.is_nop;
          entries(to_integer(unsigned(cdb0.rob_tag))).branch_taken  <= cdb0.branch_taken;
          entries(to_integer(unsigned(cdb0.rob_tag))).branch_target <= cdb0.branch_target;
          entries(to_integer(unsigned(cdb0.rob_tag))).mispredicted  <= cdb0.mispredicted;
        end if;

        if cdb1.valid = '1' then
          entries(to_integer(unsigned(cdb1.rob_tag))).done          <= '1';
          entries(to_integer(unsigned(cdb1.rob_tag))).result        <= cdb1.result;
          entries(to_integer(unsigned(cdb1.rob_tag))).c_val         <= cdb1.c_val;
          entries(to_integer(unsigned(cdb1.rob_tag))).z_val         <= cdb1.z_val;
          entries(to_integer(unsigned(cdb1.rob_tag))).is_nop        <= cdb1.is_nop;
          entries(to_integer(unsigned(cdb1.rob_tag))).branch_taken  <= cdb1.branch_taken;
          entries(to_integer(unsigned(cdb1.rob_tag))).branch_target <= cdb1.branch_target;
          entries(to_integer(unsigned(cdb1.rob_tag))).mispredicted  <= cdb1.mispredicted;
        end if;

        ---------------------------------------------------------------
        -- Retire: advance head
        ---------------------------------------------------------------
        if retire0 = '1' then
          entries(to_integer(new_head)).valid <= '0';
          entries(to_integer(new_head)).done  <= '0';
          new_head  := new_head + 1;
          new_count := new_count - 1;
        end if;

        if retire1 = '1' then
          entries(to_integer(new_head)).valid <= '0';
          entries(to_integer(new_head)).done  <= '0';
          new_head  := new_head + 1;
          new_count := new_count - 1;
        end if;

        ---------------------------------------------------------------
        -- Allocate: write new entries at tail
        ---------------------------------------------------------------
        if alloc_en0 = '1' then
          entries(to_integer(new_tail)) <= alloc_data0;
          entries(to_integer(new_tail)).valid <= '1';
          entries(to_integer(new_tail)).done  <= '0';
          new_tail  := new_tail + 1;
          new_count := new_count + 1;
        end if;

        if alloc_en1 = '1' then
          entries(to_integer(new_tail)) <= alloc_data1;
          entries(to_integer(new_tail)).valid <= '1';
          entries(to_integer(new_tail)).done  <= '0';
          new_tail  := new_tail + 1;
          new_count := new_count + 1;
        end if;

        head  <= new_head;
        tail  <= new_tail;
        count <= new_count;

      end if;
    end if;
  end process;

end architecture;
