-- tb_drawer.vhd -- GHDL testbench for our AVG + vector_drawer pipeline.
--
-- Loads vec_mem.hex (16KB MAME-captured vector RAM/ROM) and avg_prom.hex
-- (256B AVG state PROM) at simulation start.  Then drives a single vggo
-- frame and captures every pixel write event (xout, yout, zout, rgbout
-- when zout > 0) to tb_pixel_writes.txt.
--
-- The captured pixel events are what our RTL ACTUALLY produces.  Compare
-- against the Python decoder's expected list to find any divergence
-- between intended behaviour and actual RTL output.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_drawer is
end entity;

architecture sim of tb_drawer is
    signal clk          : std_logic := '0';
    signal clken        : std_logic := '0';
    signal vggo         : std_logic := '0';
    signal vgrst        : std_logic := '1';
    signal halted       : std_logic;
    signal xout         : std_logic_vector(10 downto 0);
    signal yout         : std_logic_vector(10 downto 0);
    signal zout         : std_logic_vector(7 downto 0);
    signal rgbout       : std_logic_vector(2 downto 0);
    signal avg_addr_out : std_logic_vector(15 downto 0);
    signal avg_data_in  : std_logic_vector(7 downto 0);
    signal dn_addr      : std_logic_vector(16 downto 0) := (others => '0');
    signal dn_data      : std_logic_vector(7 downto 0)  := (others => '0');
    signal dn_wr        : std_logic := '0';
    signal dbg          : std_logic_vector(15 downto 0);
    signal cpu_data_in  : std_logic_vector(7 downto 0);

    type byte_mem_t is array(0 to 16383) of std_logic_vector(7 downto 0);
    signal vector_mem : byte_mem_t := (others => x"20");  -- 0x20 = HALT

    constant CLK_PERIOD : time := 80 ns;       -- ~12 MHz

    -- Hex string -> std_logic_vector
    function hex2byte(hs : string) return std_logic_vector is
        variable result : std_logic_vector(7 downto 0) := (others => '0');
        variable nibble : integer;
    begin
        for i in 1 to 2 loop
            case hs(i) is
                when '0' => nibble := 0;
                when '1' => nibble := 1;
                when '2' => nibble := 2;
                when '3' => nibble := 3;
                when '4' => nibble := 4;
                when '5' => nibble := 5;
                when '6' => nibble := 6;
                when '7' => nibble := 7;
                when '8' => nibble := 8;
                when '9' => nibble := 9;
                when 'a' | 'A' => nibble := 10;
                when 'b' | 'B' => nibble := 11;
                when 'c' | 'C' => nibble := 12;
                when 'd' | 'D' => nibble := 13;
                when 'e' | 'E' => nibble := 14;
                when 'f' | 'F' => nibble := 15;
                when others    => nibble := 0;
            end case;
            result(7 downto 4) := result(3 downto 0);
            result(3 downto 0) := std_logic_vector(to_unsigned(nibble, 4));
        end loop;
        return result;
    end function;

    file pixel_log  : text open write_mode is "tb_pixel_writes.txt";
    file stroke_log : text open write_mode is "tb_strokes.txt";

begin
    -- Clock
    clk <= not clk after CLK_PERIOD/2;

    -- clken: 1-of-8 pulse (~1.5 MHz)
    process(clk)
        variable cnt : integer range 0 to 7 := 0;
    begin
        if rising_edge(clk) then
            if cnt = 0 then
                clken <= '1';
            else
                clken <= '0';
            end if;
            if cnt = 7 then cnt := 0; else cnt := cnt + 1; end if;
        end if;
    end process;

    -- Vector memory model: combinational read from preloaded array
    avg_data_in <= vector_mem(to_integer(unsigned(avg_addr_out(13 downto 0))));

    -- DUT
    dut: entity work.avg port map (
        clk          => clk,
        clken        => clken,
        cpu_data_in  => cpu_data_in,
        cpu_data_out => (others => '0'),
        cpu_addr     => (others => '0'),
        cpu_cs_l     => '1',
        cpu_rw_l     => '1',
        vgrst        => vgrst,
        vggo         => vggo,
        halted       => halted,
        xout         => xout,
        yout         => yout,
        zout         => zout,
        rgbout       => rgbout,
        avg_addr_out => avg_addr_out,
        avg_data_in  => avg_data_in,
        dn_addr      => dn_addr,
        dn_data      => dn_data,
        dn_wr        => dn_wr,
        dbg          => dbg
    );

    -- Stimulus
    stim: process
        file mem_file  : text;
        file prom_file : text;
        variable line_buf : line;
        variable hex_str  : string(1 to 2);
        variable addr     : integer;
        variable n_loaded : integer;
        variable last_xy  : std_logic_vector(21 downto 0) := (others => '0');
        variable cur_xy   : std_logic_vector(21 downto 0);
    begin
        report "Loading vec_mem.hex..." severity note;
        file_open(mem_file, "vec_mem.hex", read_mode);
        addr := 0;
        n_loaded := 0;
        while not endfile(mem_file) and addr < 16384 loop
            readline(mem_file, line_buf);
            read(line_buf, hex_str);
            vector_mem(addr) <= hex2byte(hex_str);
            addr := addr + 1;
            n_loaded := n_loaded + 1;
        end loop;
        file_close(mem_file);
        report "Loaded " & integer'image(n_loaded) & " vector bytes" severity note;

        wait for CLK_PERIOD * 4;

        report "Loading PROM via dn_*..." severity note;
        file_open(prom_file, "avg_prom.hex", read_mode);
        addr := 0;
        while not endfile(prom_file) and addr < 256 loop
            readline(prom_file, line_buf);
            read(line_buf, hex_str);
            wait until rising_edge(clk);
            dn_addr <= std_logic_vector(to_unsigned(16#11000# + addr, 17));
            dn_data <= hex2byte(hex_str);
            dn_wr   <= '1';
            wait until rising_edge(clk);
            dn_wr   <= '0';
            addr := addr + 1;
        end loop;
        file_close(prom_file);
        report "PROM loaded" severity note;

        -- Release reset
        wait for CLK_PERIOD * 8;
        vgrst <= '0';
        wait for CLK_PERIOD * 16;

        -- Trigger vggo -- hold for many clk cycles to guarantee at least
        -- one clken pulse sees it high.  Then drop and let AVG run.
        report "Triggering vggo" severity note;
        wait until rising_edge(clk);
        vggo <= '1';
        wait for CLK_PERIOD * 16;    -- 2 full clken periods
        vggo <= '0';

        -- Wait for halted (or timeout)
        wait until halted = '1' for 1 sec;
        report "Simulation done; halted=" & std_logic'image(halted) severity note;
        wait for CLK_PERIOD * 4;
        report "===END===" severity note;
        std.env.stop(0);
    end process;

    -- Pixel write capture: log every clk edge where zout > 0.  Without
    -- clken gating we catch the 1-clk-cycle pixel-writes that happen for
    -- zero-displacement strokes (starfield dots).  Post-process dedupes
    -- repeated writes during multi-cycle Bresenham walks.
    pixel_cap: process(clk)
        variable line_buf : line;
    begin
        if rising_edge(clk) then
            if unsigned(zout) > 0 then
                write(line_buf, integer'image(to_integer(signed(xout))));
                write(line_buf, string'(","));
                write(line_buf, integer'image(to_integer(signed(yout))));
                write(line_buf, string'(","));
                write(line_buf, integer'image(to_integer(unsigned(zout))));
                write(line_buf, string'(","));
                write(line_buf, integer'image(to_integer(unsigned(rgbout))));
                writeline(pixel_log, line_buf);
            end if;
        end if;
    end process;

    -- Per-stroke endpoint capture.  We FRAME each stroke as the window
    -- [vd_draw rising .. vd_done rising] and latch the last cycle where
    -- the drawer emitted a visible pixel (zout > 0) inside that window.
    -- On vd_done rising, write the latched endpoint.
    --
    -- Naively logging (xout, yout, zout, rgbout) at vd_done rising gives
    -- zout=0 for EVERY stroke, because by the time itsdone='1' the
    -- drawer has already transitioned WALK -> IDLE.  pixel_valid is
    -- gated to '0' in IDLE, and avg.vhd gates zout by pixel_valid -- so
    -- the at-done-edge sample is unconditionally invisible.  See
    -- vector_drawer.vhd:354 (pixel_valid <= '1' when state=WALK) and
    -- avg.vhd:255 (zout gated by vd_pixel_valid).
    --
    -- Skipping strokes with no valid pixel ALSO aligns sim_strokes with
    -- burndown.py's python_decode(), which only emits entries for
    -- strokes whose eff_int > 0.  Without this filter the sim/py
    -- count ratio is ~2x noise (off-FB walks + zero-intensity strokes).
    --
    -- prev_done initialises to '1' to match the drawer's reset value
    -- (itsdone defaults to '1' in vector_drawer.vhd:94) -- otherwise
    -- we'd see a spurious "rising edge" on the first clock cycle.
    stroke_cap: process(clk)
        variable line_buf  : line;
        variable prev_done : std_logic := '1';
        variable prev_draw : std_logic := '0';
        variable last_xout : std_logic_vector(10 downto 0) := (others => '0');
        variable last_yout : std_logic_vector(10 downto 0) := (others => '0');
        variable last_zout : std_logic_vector(7 downto 0)  := (others => '0');
        variable last_rgb  : std_logic_vector(2 downto 0)  := (others => '0');
        variable saw_valid : boolean := false;
    begin
        if rising_edge(clk) then
            -- New stroke starts at vd_draw rising: clear per-stroke latch.
            if dbg(14) = '1' and prev_draw = '0' then
                saw_valid := false;
            end if;

            -- Inside the stroke window, latch every cycle the drawer
            -- emits a visible pixel.  Last one wins = stroke endpoint
            -- (inside FB; for off-FB strokes the last in-FB position).
            if unsigned(zout) > 0 then
                last_xout := xout;
                last_yout := yout;
                last_zout := zout;
                last_rgb  := rgbout;
                saw_valid := true;
            end if;

            -- vd_done rises: stroke complete.  Dump if it produced any
            -- visible content.  Strokes that walked entirely off-FB or
            -- had eff_intens=0 are dropped (matches python_decode).
            if dbg(13) = '1' and prev_done = '0' and saw_valid then
                write(line_buf, integer'image(to_integer(signed(last_xout))));
                write(line_buf, string'(","));
                write(line_buf, integer'image(to_integer(signed(last_yout))));
                write(line_buf, string'(","));
                write(line_buf, integer'image(to_integer(unsigned(last_zout))));
                write(line_buf, string'(","));
                write(line_buf, integer'image(to_integer(unsigned(last_rgb))));
                writeline(stroke_log, line_buf);
            end if;
            prev_done := dbg(13);
            prev_draw := dbg(14);
        end if;
    end process;

    -- AVG event counters: count handler transitions, draw pulses, etc.
    -- Reset all counters when vggo asserts (so we measure the actual frame).
    debug_counts: process(clk)
        variable n_draw_pulses    : integer := 0;
        variable n_walks_finished : integer := 0;
        variable n_handlers_run   : integer := 0;
        variable n_zout_nonzero   : integer := 0;
        variable prev_draw        : std_logic := '0';
        variable prev_done        : std_logic := '0';
        variable prev_state       : std_logic_vector(3 downto 0) := (others => '0');
        variable prev_vggo        : std_logic := '0';
        variable saw_running      : boolean := false;
        variable reported         : boolean := false;
    begin
        if rising_edge(clk) then
            -- Reset counters at vggo rising edge
            if vggo = '1' and prev_vggo = '0' then
                n_draw_pulses := 0;
                n_walks_finished := 0;
                n_handlers_run := 0;
                n_zout_nonzero := 0;
                saw_running := false;
                reported := false;
            end if;
            prev_vggo := vggo;

            -- dbg(15)=m_running so we know if AVG is mid-frame
            if dbg(15) = '1' then
                saw_running := true;
            end if;

            if dbg(14) = '1' and prev_draw = '0' then
                n_draw_pulses := n_draw_pulses + 1;
            end if;
            if dbg(13) = '1' and prev_done = '0' then
                n_walks_finished := n_walks_finished + 1;
            end if;
            if dbg(11 downto 8) /= prev_state then
                n_handlers_run := n_handlers_run + 1;
            end if;
            if unsigned(zout) > 0 then
                n_zout_nonzero := n_zout_nonzero + 1;
            end if;
            prev_draw  := dbg(14);
            prev_done  := dbg(13);
            prev_state := dbg(11 downto 8);

            -- Once AVG was running and now halted, print counters.
            if saw_running and dbg(12) = '1' and not reported then
                reported := true;
                report "  draw pulses fired:         " & integer'image(n_draw_pulses) severity note;
                report "  drawer walks finished:     " & integer'image(n_walks_finished) severity note;
                report "  state transitions:         " & integer'image(n_handlers_run) severity note;
                report "  zout>0 clock cycles:       " & integer'image(n_zout_nonzero) severity note;
            end if;
        end if;
    end process;
end architecture;
