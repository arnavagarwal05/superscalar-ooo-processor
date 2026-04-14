library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pkg.all;

-- Architectural Register File (ARF)
-- 8 × 16-bit registers, R0 always holds PC
-- 4 async read ports (for rename/dispatch — 2 src regs × 2 instructions)
-- 2 sync write ports (for retire — up to 2 instructions retiring per cycle)
-- Architectural flag register: C and Z

entity arf is
  port(
    clk, reset : in std_logic;

    -- 4 async read ports
    rd_addr0 : in  std_logic_vector(2 downto 0);
    rd_data0 : out std_logic_vector(15 downto 0);
    rd_addr1 : in  std_logic_vector(2 downto 0);
    rd_data1 : out std_logic_vector(15 downto 0);
    rd_addr2 : in  std_logic_vector(2 downto 0);
    rd_data2 : out std_logic_vector(15 downto 0);
    rd_addr3 : in  std_logic_vector(2 downto 0);
    rd_data3 : out std_logic_vector(15 downto 0);

    -- 2 sync write ports (from retire)
    wr_en0   : in  std_logic;
    wr_addr0 : in  std_logic_vector(2 downto 0);
    wr_data0 : in  std_logic_vector(15 downto 0);
    wr_en1   : in  std_logic;
    wr_addr1 : in  std_logic_vector(2 downto 0);
    wr_data1 : in  std_logic_vector(15 downto 0);

    -- Architectural flags
    c_arch_out : out std_logic;
    z_arch_out : out std_logic;
    c_wr_en    : in  std_logic;
    c_wr_val   : in  std_logic;
    z_wr_en    : in  std_logic;
    z_wr_val   : in  std_logic;

    -- Full register dump (for testbench / debug)
    regs_out : out reg_file_t
  );
end entity;

architecture rtl of arf is
  signal regs   : reg_file_t;
  signal c_flag : std_logic;
  signal z_flag : std_logic;
begin

  -- Async reads: combinational, no clock needed
  rd_data0 <= regs(to_integer(unsigned(rd_addr0)));
  rd_data1 <= regs(to_integer(unsigned(rd_addr1)));
  rd_data2 <= regs(to_integer(unsigned(rd_addr2)));
  rd_data3 <= regs(to_integer(unsigned(rd_addr3)));

  c_arch_out <= c_flag;
  z_arch_out <= z_flag;
  regs_out   <= regs;

  -- Sync writes on rising edge
  process(clk, reset)
  begin
    if reset = '1' then
      for i in 0 to NUM_REGS-1 loop
        regs(i) <= (others => '0');
      end loop;
      c_flag <= '0';
      z_flag <= '1';  -- Z=1 initially (result of 0)

    elsif rising_edge(clk) then

      -- Write port 0 (retire slot 0)
      -- Port 0 has lower priority if both write same register
      if wr_en0 = '1' then
        regs(to_integer(unsigned(wr_addr0))) <= wr_data0;
      end if;

      -- Write port 1 (retire slot 1)
      -- Port 1 has higher priority (later in program order)
      if wr_en1 = '1' then
        regs(to_integer(unsigned(wr_addr1))) <= wr_data1;
      end if;

      -- Flag updates
      -- Same priority: if both retire slots update flags,
      -- slot 1 (later in program order) wins
      if c_wr_en = '1' then
        c_flag <= c_wr_val;
      end if;
      if z_wr_en = '1' then
        z_flag <= z_wr_val;
      end if;

    end if;
  end process;

end architecture;
