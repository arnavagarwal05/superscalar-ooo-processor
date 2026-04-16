library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pkg.all;

-- Instruction Memory
-- this returns 32 bits (2 instructions) per read
-- it is byte-addressed, each instruction is 2 bytes
-- Read-only in normal operation (we initializ it from testbench)

entity instr_mem is
  port(
    clk      : in std_logic;
    addr     : in  std_logic_vector(15 downto 0);  -- PC value
    data_out : out std_logic_vector(31 downto 0);   -- 2 instructions

    -- Write port for initialization from testbench
    wr_en    : in  std_logic;
    wr_addr  : in  std_logic_vector(15 downto 0);
    wr_data  : in  std_logic_vector(15 downto 0)
  );
end entity;

architecture rtl of instr_mem is
-- 256 words of 16 bits (512 bytes addressable)
  type mem_t is array (0 to 255) of std_logic_vector(15 downto 0);
  signal mem : mem_t := (others => (others => '0'));
begin

  -- Async read: return 2 consecutive 16-bit words
  -- Word at addr (upper 16 bits) and word at addr+2 (lower 16 bits)
  -- addr is byte address, so word index = addr/2 = addr(15 downto 1)
  data_out(31 downto 16) <= mem(to_integer(unsigned(addr(15 downto 1)))); -- mem(0) hold instr at byte address 0, mem(1) holds instr at byte address 2. so divide by 2 to get the index i in mem(i)
  data_out(15 downto 0)  <= mem(to_integer(unsigned(addr(15 downto 1))) + 1);

  -- Write port (for testbench initialization)
  process(clk)
  begin
    if rising_edge(clk) then
      if wr_en = '1' then
        mem(to_integer(unsigned(wr_addr(15 downto 1)))) <= wr_data;
      end if;
    end if;
  end process;

end architecture;

------------------------------------------------------------------------

-- Data Memory — dual port
-- Port A and Port B can each independently read or write
-- Byte-addressed, 16-bit data words
-- Used by: execution pipes for loads, store buffer drain for stores

entity data_mem is
  port(
    clk : in std_logic;

    -- Port A
    a_addr   : in  std_logic_vector(15 downto 0);
    a_data_in: in  std_logic_vector(15 downto 0);
    a_data_out: out std_logic_vector(15 downto 0);
    a_wr_en  : in  std_logic;
    a_rd_en  : in  std_logic;

    -- Port B
    b_addr   : in  std_logic_vector(15 downto 0);
    b_data_in: in  std_logic_vector(15 downto 0);
    b_data_out: out std_logic_vector(15 downto 0);
    b_wr_en  : in  std_logic;
    b_rd_en  : in  std_logic
  );
end entity;

architecture rtl of data_mem is
  type mem_t is array (0 to 255) of std_logic_vector(15 downto 0);
  signal mem : mem_t := (others => (others => '0'));
begin

  -- Async reads
  a_data_out <= mem(to_integer(unsigned(a_addr(15 downto 1)))) when a_rd_en = '1'
                else (others => '0');
  b_data_out <= mem(to_integer(unsigned(b_addr(15 downto 1)))) when b_rd_en = '1'
                else (others => '0');

  -- Sync writes (port B priority over port A if same address)
  process(clk)
  begin
    if rising_edge(clk) then
      if a_wr_en = '1' then
        mem(to_integer(unsigned(a_addr(15 downto 1)))) <= a_data_in;
      end if;
      if b_wr_en = '1' then
        mem(to_integer(unsigned(b_addr(15 downto 1)))) <= b_data_in;
      end if;
    end if;
  end process;

end architecture;
