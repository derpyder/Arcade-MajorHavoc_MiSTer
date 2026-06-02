-- tb_slapstic.vhd -- validate the d18c7db SLAPSTIC type-101 path.
--
-- WHY: the d18c7db slapstic was originally used for Gauntlet (type 104).
-- ESB is the first thing to drive its type-101 configuration, so that
-- path is unvalidated.  This TB drives the canonical ESB bank-switch
-- sequences and checks O_BS, confirming:
--   1. type 101 powers up at ini_bank = 3,
--   2. the $8000-then-$80N0 enable+select sequence picks the right bank,
--   3. the chip steps once per clean I_ASn rising edge with CSn low
--      (the access model our starwars.sv strobe is built to produce).
--
-- The slapstic steps on I_ASn RISING edge (slapstic.vhd:596,
-- "sl_ASn_last='0' and I_ASn='1'") while I_CSn='0'.  Each access here
-- presents I_A, holds CSn low, and pulses I_ASn low->high once -- the
-- clean per-access stimulus starwars.sv's slap_strobe is designed to
-- deliver (slap_strobe high for 1 clk_12 -> I_ASn low 1 clk then high).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_slapstic is
end entity;

architecture sim of tb_slapstic is
    signal clk    : std_logic := '0';
    signal asn    : std_logic := '1';   -- I_ASn idle high
    signal csn    : std_logic := '1';   -- I_CSn idle high (inactive)
    signal a      : std_logic_vector(13 downto 0) := (others => '0');
    signal bs     : std_logic_vector(1 downto 0);
    constant T    : time := 80 ns;       -- clk_12 period

    signal fail_count : integer := 0;
begin
    clk <= not clk after T/2;

    dut: entity work.slapstic
        port map (
            I_CK        => clk,
            I_ASn       => asn,
            I_CSn       => csn,
            I_A         => a,
            O_BS        => bs,
            I_SLAP_TYPE => 101
        );

    stim: process
        -- One slapstic access: present address, CSn low, pulse ASn
        -- low for one clk then high (rising edge = the step), matching
        -- starwars.sv slap_strobe (1 clk_12 wide, I_ASn = ~strobe).
        procedure access_addr(addr : in integer) is
        begin
            wait until rising_edge(clk);
            a   <= std_logic_vector(to_unsigned(addr, 14));
            csn <= '0';
            asn <= '0';                  -- strobe asserted (slap_strobe high)
            wait until rising_edge(clk);
            asn <= '1';                  -- strobe deasserted -> RISING edge: chip steps here
            wait until rising_edge(clk);
            csn <= '1';                  -- back to idle between accesses
            wait until rising_edge(clk);
        end procedure;

        procedure check(msg : in string; expect : in std_logic_vector(1 downto 0)) is
        begin
            if bs = expect then
                report "PASS: " & msg & " O_BS=" & integer'image(to_integer(unsigned(bs)))
                    severity note;
            else
                report "FAIL: " & msg & " expected " & integer'image(to_integer(unsigned(expect)))
                    & " got " & integer'image(to_integer(unsigned(bs)))
                    severity warning;
                fail_count <= fail_count + 1;
            end if;
        end procedure;
    begin
        -- Let the type-101 config load (slapstic loads params when
        -- I_SLAP_TYPE changes; give it a few clocks).
        for i in 0 to 20 loop wait until rising_edge(clk); end loop;

        -- Power-up bank for type 101 = ini_bank = "11" = 3.
        check("power-up bank", "11");

        -- Switch to bank 1: enable ($8000 -> offset 0x0000), select $8090.
        access_addr(16#0000#);   -- enable
        access_addr(16#0090#);   -- bank1 select value (0x0090)
        check("switch to bank 1", "01");

        -- Switch to bank 2: $8000 then $80A0.
        access_addr(16#0000#);
        access_addr(16#00A0#);
        check("switch to bank 2", "10");

        -- Switch to bank 0: $8000 then $8080.
        access_addr(16#0000#);
        access_addr(16#0080#);
        check("switch to bank 0", "00");

        -- Switch to bank 3: $8000 then $80B0.
        access_addr(16#0000#);
        access_addr(16#00B0#);
        check("switch to bank 3", "11");

        -- Interleave non-bank accesses (normal reads) between enable and
        -- select must NOT corrupt -- e.g. enable, then read a normal addr
        -- ($8100 = 0x0100, not a bank value), then it should stay ENABLED
        -- and a following $8090 still selects bank 1.
        access_addr(16#0000#);   -- enable
        access_addr(16#0100#);   -- normal read (not a magic addr)
        access_addr(16#0090#);   -- bank1 select
        check("enable + stray read + select bank1", "01");

        -- ===== ALTERNATE (devious) banking -- the path ESB uses for game
        -- control flow (VecFever) and the one never validated.  Type-101:
        --   enable $8000 -> alt2 $9DFF (offset 0x1DFF) -> alt3 $9B5C+n
        --   (offset 0x1B5C+n, alt_bank=n, altshift=0) -> alt4 $8080
        --   (offset 0x0080) commits cur_bank=n.
        -- $9DFF must NOT match bit1 (0x1DFF & 0x1FF0 = 0x1DF0 != 0x1540) so
        -- it takes the alt path, not bitwise.  If our slapstic mis-handles
        -- this, the game's RTS returns to the wrong bank -> bad code/jump ->
        -- the crash-to-RAM we see ~5 vggos into gameplay.
        access_addr(16#0000#);   -- enable
        access_addr(16#1DFF#);   -- alt2
        access_addr(16#1B5C#);   -- alt3, alt_bank = 0x1B5C & 3 = 0
        access_addr(16#0080#);   -- alt4 commit
        check("ALT bank 0 ($9DFF,$9B5C,$8080)", "00");

        access_addr(16#0000#);
        access_addr(16#1DFF#);
        access_addr(16#1B5D#);   -- alt_bank = 0x1B5D & 3 = 1
        access_addr(16#0080#);
        check("ALT bank 1 ($9B5D)", "01");

        access_addr(16#0000#);
        access_addr(16#1DFF#);
        access_addr(16#1B5E#);   -- alt_bank = 2
        access_addr(16#0080#);
        check("ALT bank 2 ($9B5E)", "10");

        access_addr(16#0000#);
        access_addr(16#1DFF#);
        access_addr(16#1B5F#);   -- alt_bank = 3
        access_addr(16#0080#);
        check("ALT bank 3 ($9B5F)", "11");

        if fail_count = 0 then
            report "=== ALL SLAPSTIC TYPE-101 CHECKS PASSED ===" severity note;
        else
            report "=== SLAPSTIC TYPE-101 FAILURES: " & integer'image(fail_count)
                & " ===" severity error;
        end if;
        std.env.stop(0);
    end process;
end architecture;
