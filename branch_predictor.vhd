library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pkg.all;

-- Branch predictor: 16-entry × 2-bit BHT (Branch History Table)
-- Indexed by PC(4 downto 1) — skip bit 0 since instructions are 2-byte aligned
-- 2-bit saturating counter: 00/01 = predict not-taken, 10/11 = predict taken
-- Predict = MSB of counter

entity branch_predictor is
  port(
    clk, reset : in std_logic;

    -- Lookup port 1 (for instruction at pc1)
    lookup_pc1 : in  std_logic_vector(15 downto 0);
    predict1   : out std_logic;  -- 1=taken, 0=not-taken

    -- Lookup port 2 (for instruction at pc2)
    lookup_pc2 : in  std_logic_vector(15 downto 0);
    predict2   : out std_logic;

    -- Update port (from retire, 1 update per cycle max)
    update_en   : in std_logic;
    update_pc   : in std_logic_vector(15 downto 0);
    update_taken: in std_logic  -- actual branch outcome
  );
end entity;

architecture rtl of branch_predictor is
  -- 16 entries, each 2 bits
  type bht_t is array (0 to BHT_SIZE-1) of unsigned(1 downto 0);
  signal bht : bht_t;
begin

  ---------------------------------------------------------------
  -- Lookup: combinational, just read the counter MSB
  ---------------------------------------------------------------
  predict1 <= std_logic(bht(to_integer(unsigned(lookup_pc1(4 downto 1))))(1));
  predict2 <= std_logic(bht(to_integer(unsigned(lookup_pc2(4 downto 1))))(1));

  ---------------------------------------------------------------
  -- Update: on clock edge, saturating increment/decrement
  ---------------------------------------------------------------
  process(clk, reset)
    variable idx : integer;
    variable cnt : unsigned(1 downto 0);
  begin
    if reset = '1' then
      -- Initialize all counters to weakly not-taken (01)
      for i in 0 to BHT_SIZE-1 loop
        bht(i) <= "01";
      end loop;

    elsif rising_edge(clk) then
      if update_en = '1' then
        idx := to_integer(unsigned(update_pc(4 downto 1)));
        cnt := bht(idx);

        if update_taken = '1' then
          -- Saturating increment: 00->01->10->11, 11 stays 11
          if cnt /= "11" then
            bht(idx) <= cnt + 1;
          end if;
        else
          -- Saturating decrement: 11->10->01->00, 00 stays 00
          if cnt /= "00" then
            bht(idx) <= cnt - 1;
          end if;
        end if;
      end if;
    end if;
  end process;

end architecture;
