-- GHDL testbench for slapstic101 (decapped MAME type-101).
-- Replays the exact access sequences observed in MAME -log during real ESB play:
--   * direct banking (attract): $8000 then $80x0  -> banks 0..3
--   * ALTERNATE banking (gameplay): $8000, $9E00(alt1), $FFFF(alt2 dummy/outside),
--     $9B5x(alt3 -> bank=x&3), $80xx(alt4 commit)
--   * NEGATIVE: same alt without the out-of-range $FFFF -> sequence breaks, NO switch
--     (this is exactly why the old in-range-only HDL crashed ESB gameplay).
-- Run:  ghdl -a --std=08 -frelaxed -fsynopsys ../rtl/slapstic101.vhd tb_slapstic101.vhd
--       ghdl -e --std=08 -frelaxed -fsynopsys tb_slapstic101 ; ghdl -r ... tb_slapstic101
library ieee;
	use ieee.std_logic_1164.all;
	use ieee.numeric_std.all;

entity tb_slapstic101 is end tb_slapstic101;

architecture sim of tb_slapstic101 is
	signal clk  : std_logic := '0';
	signal step : std_logic := '0';
	signal rst  : std_logic := '1';
	signal addr : std_logic_vector(15 downto 0) := (others => '0');
	signal bs   : std_logic_vector(1 downto 0);
	constant TCK : time := 10 ns;
	signal done : boolean := false;
begin
	dut : entity work.slapstic101
		port map (I_CK => clk, I_STEP => step, I_RESET => rst, I_A => addr, O_BS => bs);

	clk <= not clk after TCK/2 when not done else '0';

	process
		variable nerr : integer := 0;

		-- present one 6809 bus access and pulse STEP once
		procedure acc(constant ad : std_logic_vector(15 downto 0)) is
		begin
			wait until falling_edge(clk);
			addr <= ad; step <= '1';
			wait until falling_edge(clk);
			step <= '0';
		end procedure;

		procedure expect(constant b : integer; constant msg : string) is
		begin
			if to_integer(unsigned(bs)) /= b then
				report "FAIL [" & msg & "]: bank=" & integer'image(to_integer(unsigned(bs)))
				       & " expected " & integer'image(b) severity error;
				nerr := nerr + 1;
			else
				report "PASS [" & msg & "]: bank=" & integer'image(b) severity note;
			end if;
		end procedure;

		-- direct bank select helper: enable then select
		procedure direct(constant sel : std_logic_vector(15 downto 0)) is
		begin
			acc(x"8000");   -- reset -> active
			acc(sel);       -- $80x0 -> bank, idle
		end procedure;
	begin
		-- power-up
		rst <= '1'; acc(x"8000"); rst <= '0';
		acc(x"8000");                         -- swallow one cycle
		expect(3, "power-up bankstart");

		-- direct banking (what ESB attract uses)
		direct(x"8090"); expect(1, "direct bank1");
		direct(x"8080"); expect(0, "direct bank0");
		direct(x"80A0"); expect(2, "direct bank2");
		direct(x"80B0"); expect(3, "direct bank3");

		-- ALTERNATE banking (what ESB gameplay uses) — to bank 2, from bank 1
		direct(x"8090"); expect(1, "alt: preset bank1");
		acc(x"8000");                         -- reset -> active
		acc(x"9E00");                         -- alt1  -> alt_valid
		acc(x"FFFF");                         -- alt2  (OUTSIDE range, the 6809 dummy) -> alt_select
		acc(x"9B5E");                         -- alt3  -> loaded = $5E & 3 = 2 -> alt_commit
		acc(x"8090");                         -- alt4  ($80xx) -> commit
		expect(2, "ALT -> bank2 (full sequence w/ $FFFF)");

		-- ALT to bank 0 and bank 3 (low 2 bits of alt3 select the bank)
		direct(x"8090");
		acc(x"8000"); acc(x"9E00"); acc(x"FFFF"); acc(x"9B5C"); acc(x"8090");
		expect(0, "ALT -> bank0 ($9B5C)");
		direct(x"8090");
		acc(x"8000"); acc(x"9E00"); acc(x"FFFF"); acc(x"9B5F"); acc(x"8090");
		expect(3, "ALT -> bank3 ($9B5F)");

		-- NEGATIVE: the OLD bug. Same alt but the slapstic never sees the
		-- out-of-range $FFFF (old HDL only saw in-range $8000-$9FFF). The
		-- in-range $9B5E arrives while in ALT_VALID -> sequence breaks -> no switch.
		direct(x"80B0"); expect(3, "neg: preset bank3");
		acc(x"8000");                         -- active
		acc(x"9E00");                         -- alt_valid
		acc(x"9B5E");                         -- in-range in ALT_VALID -> BREAK (no $FFFF seen)
		acc(x"8000");                         -- back to active (harmless)
		expect(3, "NEG: no $FFFF => bank UNCHANGED (reproduces old bug)");

		-- summary
		if nerr = 0 then
			report "==== ALL SLAPSTIC101 TESTS PASSED ====" severity note;
		else
			report "==== SLAPSTIC101 FAILURES: " & integer'image(nerr) & " ====" severity error;
		end if;
		done <= true;
		wait;
	end process;
end sim;
