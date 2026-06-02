-- Behavioral dual-port RAM substitute for the Altera altsyncram in
-- rtl/dpram.vhd.  Used ONLY for simulation -- the synthesized build
-- still uses the real altsyncram primitive.
--
-- Same entity name, same port shape -- GHDL elaborates against this file
-- and bypasses the altera_mf dependency.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dpram is
    generic (
        addr_width_g : integer := 8;
        data_width_g : integer := 8
    );
    port (
        address_a : in  std_logic_vector(addr_width_g-1 downto 0);
        address_b : in  std_logic_vector(addr_width_g-1 downto 0);
        clock_a   : in  std_logic := '1';
        clock_b   : in  std_logic;
        data_a    : in  std_logic_vector(data_width_g-1 downto 0);
        data_b    : in  std_logic_vector(data_width_g-1 downto 0) := (others => '0');
        enable_a  : in  std_logic := '1';
        enable_b  : in  std_logic := '1';
        wren_a    : in  std_logic := '0';
        wren_b    : in  std_logic := '0';
        q_a       : out std_logic_vector(data_width_g-1 downto 0);
        q_b       : out std_logic_vector(data_width_g-1 downto 0)
    );
end entity;

architecture sim of dpram is
    type mem_t is array(0 to 2**addr_width_g - 1) of std_logic_vector(data_width_g-1 downto 0);
    shared variable mem : mem_t := (others => (others => '0'));
begin
    process(clock_a)
    begin
        if rising_edge(clock_a) and enable_a = '1' then
            if wren_a = '1' then
                mem(to_integer(unsigned(address_a))) := data_a;
            end if;
            q_a <= mem(to_integer(unsigned(address_a)));
        end if;
    end process;

    process(clock_b)
    begin
        if rising_edge(clock_b) and enable_b = '1' then
            if wren_b = '1' then
                mem(to_integer(unsigned(address_b))) := data_b;
            end if;
            q_b <= mem(to_integer(unsigned(address_b)));
        end if;
    end process;
end architecture;
