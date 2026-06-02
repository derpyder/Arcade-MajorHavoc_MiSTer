--=============================================================================--
-- Tempest (Atari, 1981) game logic.
--===========================================================================--
--
-- Tempest runs on Atari's Analog Vector-Generator hardware (PCB A037383), a
-- sibling of the Black Widow / Gravitar / Space Duel board this core already
-- implements: same 6502 (T65), same Atari AVG colour vector generator, same
-- 2x POKEY, same ER2055 EAROM. The differences Tempest adds are:
--   * a different memory map (this file),
--   * a 16-entry CPU-written colour RAM at $0800 (the classic colour cycling),
--   * an Atari math box (Battlezone/Red Baron/Tempest shared device) at $60xx,
--   * a spinner (read through POKEY 1's pot/ALLPOT lines),
--   * a rotated monitor (X/Y swap, handled in avg_tempest / orientation).
--
-- Memory map transcribed from MAME atari/tempest.cpp main_map():
--   $0000-$07FF  RAM (2K)
--   $0800-$080F  AVG colour RAM (write only)            <- Tempest palette
--   $0C00        IN0  (coins/tilt/selftest/diag + AVG-halt b6 + 3kHz b7)
--   $0D00        DSW1 (coinage / bonus coins)
--   $0E00        DSW2 (lives / bonus life / language / minimum)
--   $2000-$2FFF  Vector RAM (4K)
--   $3000-$3FFF  Vector ROM (4K)
--   $4000        coin counters + AVG flip x/y           (write)
--   $4800        AVG go                                 (write)
--   $5000        watchdog clear / IRQ acknowledge       (write)
--   $5800        AVG reset                              (write)
--   $6000-$603F  EAROM write (addr+data)
--   $6040        R: mathbox status   W: EAROM control
--   $6050        R: EAROM read
--   $6060        R: mathbox result low
--   $6070        R: mathbox result high
--   $6080-$609F  W: mathbox go (operation/register load)
--   $60C0-$60CF  POKEY 1
--   $60D0-$60DF  POKEY 2
--   $60E0        start LEDs + FLIP/player select        (write)
--   $9000-$DFFF  Program ROM (20K)
--   $F000-$FFFF  mirror of $D000 ROM (reset/IRQ vectors)
--
-- Same GPL lineage as the rest of this core (Jeroen Domburg / Dave Woo /
-- fpgaarcade / alanswx). Math box is MiSTer-devel Arcade-BattleZone (behavioral
-- model of MAME's Eric-Smith mathbox.cpp, BSD-3).

library ieee;
   use ieee.std_logic_1164.all;
   use IEEE.STD_LOGIC_ARITH.ALL;
   use IEEE.STD_LOGIC_UNSIGNED.ALL;

use work.pkg_bwidow.all;

entity tempest is
  port(
		reset_h   : in    std_logic;
		clk			: in    std_logic; --12 MHz
		pause_h   : in    std_logic;
		analog_sound_out    : out std_logic_vector(7 downto 0);
		analog_x_out    : out std_logic_vector(9 downto 0);
		analog_y_out    : out std_logic_vector(9 downto 0);
		analog_z_out    : out std_logic_vector(7 downto 0);
		BEAM_ENA          : out   std_logic;
		rgb_out    : out std_logic_vector(2 downto 0);
		frame_done : out std_logic;   -- avg_halted (FB EOF / frame done)
		start_frame: out std_logic;   -- avg_go / vggo (FB frame start)
		SW_B4				 : in std_logic_vector(7 downto 0);   -- IN2       (POKEY 2 pots)
		SW_D4				 : in std_logic_vector(7 downto 0);   -- IN1_DSW0  (POKEY 1 pots / spinner)
		dn_addr           : in 	std_logic_vector(15 downto 0);
		dn_data         	 : in 	std_logic_vector(7 downto 0);
		dn_wr				 : in 	std_logic	;
		input_0        : in  std_logic_vector( 7 downto 0);   -- IN0  bits 0-5 (coins/tilt/service/diag)
		input_3        : in  std_logic_vector( 7 downto 0);   -- DSW1 ($0D00)
		input_4        : in  std_logic_vector( 7 downto 0);   -- DSW2 ($0E00)

		dbg				 : out std_logic_vector(15 downto 0);

		-- HISCORE (program-RAM snoop, same mechanism as bwidow)
		hs_address   : in  std_logic_vector(15 downto 0);
		hs_data_out  : out std_logic_vector(7 downto 0);
		hs_data_in   : in  std_logic_vector(7 downto 0);
		hs_write     : in  std_logic
	);
end tempest;

architecture Behaviour of tempest is
	signal c_addr			: std_logic_vector(23 downto 0);
	signal c_din			: std_logic_vector(7 downto 0);
	signal c_dout			: std_logic_vector(7 downto 0);
	signal c_rw_l			: std_logic;
	signal c_irq_l			: std_logic;
	signal avg_dout		: std_logic_vector(7 downto 0);
	signal pgmrom_dout	: std_logic_vector(7 downto 0);
	signal pgmram_dout	: std_logic_vector(7 downto 0);
	signal pgmrom_addr	: std_logic_vector(14 downto 0);
	signal pgmrom_off		: std_logic_vector(15 downto 0);
	signal pgmram_addr	: std_logic_vector(10 downto 0);
	signal avgmem_addr	: std_logic_vector(15 downto 0);
	signal earom_dout		: std_logic_vector(7 downto 0);
	signal pokeya_dout	: std_logic_vector(7 downto 0);
	signal pokeyb_dout	: std_logic_vector(7 downto 0);
	signal mb_dout			: std_logic_vector(7 downto 0);
	signal mb_addr			: std_logic_vector(7 downto 0);
	signal mb_we			: std_logic;
	signal pokeya_cs_l	: std_logic;
	signal pokeyb_cs_l	: std_logic;
	signal pgmram_cs_l	: std_logic;
	signal avgmem_cs_l	: std_logic;
	signal earom_write_l	: std_logic;
	signal earom_con_l	: std_logic;
	signal pgmrom_cs		: std_logic;
	signal pokeya_audio	: std_logic_vector(7 downto 0);
	signal pokeyb_audio	: std_logic_vector(7 downto 0);
	signal in0				: std_logic_vector(7 downto 0);
	signal cnt_3khz		: std_logic_vector(8 downto 0) := (others => '0');
	signal ena_1_5M		: std_logic := '0';
	signal reset_l			: std_logic;
	signal avg_rst			: std_logic;
	signal avg_go			: std_logic;
	signal avg_halted		: std_logic;
	signal avg_dbg			: std_logic_vector(15 downto 0);
	signal clkdiv			: std_logic_vector(2 downto 0) := "000";
	signal irqctr			: std_logic_vector(3 downto 0) := "0000";
	-- no-JTAG screen-debug state latches
	signal vggo_fired		: std_logic := '0';
	signal hb_ctr			: std_logic_vector(21 downto 0) := (others => '0');
	signal intack_l		: std_logic;
	signal flip_x			: std_logic := '0';
	signal flip_y			: std_logic := '0';
	signal player_sel		: std_logic := '0';
	signal led_latch		: std_logic_vector(7 downto 0) := (others => '0');
	signal coin_latch		: std_logic_vector(7 downto 0) := (others => '0');
	-- 16-entry colour RAM, CPU-written at $0800-$080F (used by avg_tempest in Phase 2)
	type colorram_t is array(0 to 15) of std_logic_vector(7 downto 0);
	signal colorram		: colorram_t := (others => (others => '0'));
	signal colorram_we	: std_logic;
	signal avg_color_idx	: std_logic_vector(3 downto 0);
	signal avg_color_data: std_logic_vector(7 downto 0);

	-- program ROM download decode ($9000-$DFFF -> dn 0x0000-0x4FFF, 20K)
	signal pgmrom_dn_cs	: std_logic;

	-- mathBox is SystemVerilog (rtl/mathbox.sv); a component (not `entity work.`)
	-- lets Quartus bind by name to the SV module (and GHDL to the sim stub).
	component mathBox is
		port (
			addr         : in  std_logic_vector(7 downto 0);
			DI           : in  std_logic_vector(7 downto 0);
			we           : in  std_logic;
			clk          : in  std_logic;
			clk_en       : in  std_logic;
			rst          : in  std_logic;
			mod_redbaron : in  std_logic;
			mod_tempest  : in  std_logic;
			dataOut      : out std_logic_vector(7 downto 0)
		);
	end component;
begin
	pokeya: pokey port map (   -- POKEY 1 @ $60C0
		ADDR      => c_addr(3 downto 0),
		DIN       => c_dout,
		DOUT      => pokeya_dout,
		DOUT_OE_L => open,
		RW_L      => c_rw_l,
		CS        => '1',
		CS_L      => pokeya_cs_l,
		AUDIO_OUT => pokeya_audio,
		PIN       => SW_D4,        -- IN1_DSW0 (spinner low nibble + cabinet)
		ENA       => ena_1_5M,
		CLK       => clk
	);

	pokeyb: pokey port map (   -- POKEY 2 @ $60D0
		ADDR      => c_addr(3 downto 0),
		DIN       => c_dout,
		DOUT      => pokeyb_dout,
		DOUT_OE_L => open,
		RW_L      => c_rw_l,
		CS        => '1',
		CS_L      => pokeyb_cs_l,
		AUDIO_OUT => pokeyb_audio,
		PIN       => SW_B4,        -- IN2 (difficulty + fire/zap + start)
		ENA       => ena_1_5M,
		CLK       => clk
	);

	cpu: T65 port map (
		Mode    => "00",           -- 6502
		Res_n   => reset_l,
		Enable  => ena_1_5M,
		Clk     => clk,
		Rdy     => not pause_h,
		Abort_n => '1',
		IRQ_n   => c_irq_l,
		NMI_n   => '1',
		SO_n    => '1',
		R_W_n   => c_rw_l,
		Sync    => open,
		EF      => open,
		MF      => open,
		XF      => open,
		ML_n    => open,
		VP_n    => open,
		VDA     => open,
		VPA     => open,
		A       => c_addr,
		DI      => c_din,
		DO      => c_dout
	);

	-- Program ROM: 32K dual-port; written from download 0x0000-0x4FFF.
	-- CPU reads $9000-$DFFF and the $F000-$FFFF vector mirror of $D000.
	pgmrom_dn_cs <= '1' when dn_addr(15 downto 12) = "0000"
						or dn_addr(15 downto 12) = "0001"
						or dn_addr(15 downto 12) = "0010"
						or dn_addr(15 downto 12) = "0011"
						or dn_addr(15 downto 12) = "0100" else '0';
	mypgmrom: entity work.dpram generic map (15,8)
	port map (
		clock_a   => clk,
		wren_a    => dn_wr and pgmrom_dn_cs,
		address_a => dn_addr(14 downto 0),
		data_a    => dn_data,
		clock_b   => clk,
		address_b => pgmrom_addr,
		q_b       => pgmrom_dout
	);

	mypgmram: entity work.dpram2k port map (
		addr_a		=> pgmram_addr,
		data_in_a	=> c_dout,
		data_out_a	=> pgmram_dout,
		ena_a			=> '1',
		cs_l_a		=> pgmram_cs_l,
		rw_l_a 		=> c_rw_l,
		clk_a			=> clk,

		addr_b		=> hs_address(10 downto 0),
		data_in_b	=> hs_data_in,
		data_out_b	=> hs_data_out,
		ena_b			=> '1',
		we_b			=> hs_write,
		clk_b			=> clk
	);

	myearom: earom port map (
		reset_l	=> reset_l,
		clk		=> clk,
		data_in	=> c_dout,
		data_out => earom_dout,
		addr		=> c_addr(5 downto 0),
		write_l	=> earom_write_l,
		con_l		=> earom_con_l
	);

	-- Atari math box (Battlezone/Red Baron/Tempest shared behavioral model).
	-- Tempest writes ops at $6080-$609F (offset 0x00-0x1f); the FSM decodes
	-- those at 0x60-0x7f, so feed addr="011"&a[4:0] on writes. Reads use the
	-- raw low byte ($6040 status / $6060 lo / $6070 hi), matched by mod_tempest.
	mymathbox: mathBox port map (
		addr			=> mb_addr,
		DI				=> c_dout,
		we				=> mb_we,
		clk			=> clk,
		clk_en		=> ena_1_5M,
		rst			=> reset_h,
		mod_redbaron => '0',
		mod_tempest	=> '1',
		dataOut		=> mb_dout
	);

	myavg: entity work.avg_tempest port map (
		clk => clk,
		clken => ena_1_5M,
		cpu_data_in => avg_dout,
		cpu_data_out => c_dout,
		cpu_addr => avgmem_addr(12 downto 0),
		cpu_cs_l => avgmem_cs_l,
		cpu_rw_l => c_rw_l,
		vgrst => avg_rst,
		vggo => avg_go,
		halted => avg_halted,
		xout => analog_x_out,
		yout => analog_y_out,
		zout => analog_z_out,
		rgbout => rgb_out,
		color_idx => avg_color_idx,
		color_data => avg_color_data,
		dbg => avg_dbg,
		dn_addr =>dn_addr,
		dn_data =>dn_data,
		dn_wr =>dn_wr
	);

	------------------------------------------------------------------
	-- Address decode
	------------------------------------------------------------------
	-- chip selects (writes / region enables)
	pgmram_cs_l <= '0' when c_addr(15 downto 11)="00000" else '1';        -- $0000-$07FF
	colorram_we <= '1' when c_addr(15 downto 4)=x"080" and c_rw_l='0' and ena_1_5M='1' else '0'; -- $0800-$080F
	avgmem_cs_l <= '0' when c_addr(15 downto 13)="001" else '1';          -- $2000-$3FFF (RAM+ROM)
	pokeya_cs_l <= '0' when c_addr(15 downto 4)=x"60C" else '1';          -- $60C0-$60CF
	pokeyb_cs_l <= '0' when c_addr(15 downto 4)=x"60D" else '1';          -- $60D0-$60DF
	earom_write_l <= '0' when c_addr(15 downto 6)="0110000000" and c_rw_l='0' else '1'; -- $6000-$603F
	earom_con_l   <= '0' when c_addr=x"006040" and c_rw_l='0' else '1';   -- $6040 (write = control)
	avg_go  <= '1' when c_addr(15 downto 8)=x"48" else '0';               -- $4800
	avg_rst <= '1' when c_addr(15 downto 8)=x"58" else '0';               -- $5800
	intack_l <= '0' when c_addr(15 downto 8)=x"50" else '1';              -- $5000 IRQ ack / watchdog
	pgmrom_cs <= '1' when c_addr(15 downto 12)="1001"     -- $9000
						or c_addr(15 downto 12)="1010"        -- $A000
						or c_addr(15 downto 12)="1011"        -- $B000
						or c_addr(15 downto 12)="1100"        -- $C000
						or c_addr(15 downto 12)="1101"        -- $D000
						or c_addr(15 downto 12)="1111"        -- $F000 (vectors, mirror of $D000)
						else '0';

	-- math box strobe: CPU write to $6080-$609F
	mb_we   <= '1' when c_addr(15 downto 5)="01100000100" and c_rw_l='0' else '0';  -- $6080-$609F
	mb_addr <= ("011" & c_addr(4 downto 0)) when mb_we='1' else c_addr(7 downto 0);

	-- IN0 @ $0C00 : low 6 bits from .sv (coins/tilt/service/diag, active low),
	-- bit 6 = AVG done/halt, bit 7 = ~3kHz square (cnt_3khz bit 8)
	in0 <= cnt_3khz(8) & avg_halted & input_0(5 downto 0);
	frame_done  <= avg_halted;
	start_frame <= avg_go;

	-- CPU read mux
	c_din <= pgmram_dout	when c_addr(15 downto 11)="00000" else   -- $0000-$07FF
				in0			when c_addr(15 downto 8)=x"0C" else        -- $0C00 IN0
				input_3		when c_addr(15 downto 8)=x"0D" else        -- $0D00 DSW1
				input_4		when c_addr(15 downto 8)=x"0E" else        -- $0E00 DSW2
				avg_dout		when c_addr(15 downto 13)="001" else       -- $2000-$3FFF vector RAM/ROM
				mb_dout		when c_addr=x"006040" else                 -- $6040 mathbox status
				earom_dout	when c_addr=x"006050" else                 -- $6050 EAROM read
				mb_dout		when c_addr=x"006060" else                 -- $6060 mathbox lo
				mb_dout		when c_addr=x"006070" else                 -- $6070 mathbox hi
				pokeya_dout	when c_addr(15 downto 4)=x"60C" else       -- $60C0 POKEY 1
				pokeyb_dout	when c_addr(15 downto 4)=x"60D" else       -- $60D0 POKEY 2
				pgmrom_dout	when pgmrom_cs='1' else                    -- $9000-$DFFF / $F000-$FFFF
				x"00";

	-- program ROM address: $9000-$DFFF -> 0x0000-0x4FFF; $F000-$FFFF -> $D000 image (0x4000)
	pgmrom_off  <= c_addr(15 downto 0) - x"9000";
	pgmrom_addr <= ("100" & c_addr(11 downto 0)) when c_addr(15 downto 12)="1111"  -- $F000->0x4000 ($D000 image)
					 else pgmrom_off(14 downto 0);

	-- AVG window offset ($2000-$3FFF -> 0x0000-0x1FFF)
	avgmem_addr <= c_addr(15 downto 0) - x"2000";

	-- program RAM (2K, no banking on Tempest)
	pgmram_addr <= c_addr(10 downto 0);

	-- colour RAM write
	process(clk) begin
		if rising_edge(clk) then
			if colorram_we='1' then
				colorram(conv_integer(c_addr(3 downto 0))) <= c_dout;
			end if;
		end if;
	end process;

	-- colour RAM lookup feeding avg_tempest's colour resolution
	avg_color_data <= colorram(conv_integer(avg_color_idx));

	-- $4000 coin counters + AVG flip ; $60E0 LEDs + FLIP/player select
	process(clk) begin
		if rising_edge(clk) then
			if ena_1_5M='1' and c_rw_l='0' then
				if c_addr(15 downto 8)=x"40" then       -- $4000
					coin_latch <= c_dout;
					flip_x <= c_dout(3);
					flip_y <= c_dout(4);
				end if;
				if c_addr=x"0060E0" then                -- $60E0
					led_latch <= c_dout;
					player_sel <= c_dout(2);
				end if;
			end if;
		end if;
	end process;

	-- no-JTAG screen-debug: latch "did vggo ever fire" + a clock heartbeat
	process(clk) begin
		if rising_edge(clk) then
			if reset_h='1' then
				vggo_fired <= '0';
				hb_ctr <= (others => '0');
			elsif ena_1_5M='1' then
				hb_ctr <= hb_ctr + 1;
				if avg_go='1' then vggo_fired <= '1'; end if;
			end if;
		end if;
	end process;
	-- dbg(0)=vggo fired, dbg(1)=clock heartbeat (~0.7Hz), dbg(2)=AVG halted
	dbg <= "0000000000000" & avg_halted & hb_ctr(20) & vggo_fired;

	analog_sound_out <= (("0"&pokeya_audio(7 downto 1)) + ("0"&pokeyb_audio(7 downto 1)));

	reset_l <= not reset_h;

	-- IRQ ~250 Hz (3kHz/12), acknowledged by any access to $5000 (wdclr).
	c_irq_l <= not(irqctr(3) and irqctr(2));

	process(clk) begin
		if clk'EVENT and clk='1' then
			clkdiv <= clkdiv + "001";
			if (clkdiv="000") then
				ena_1_5M <= '1';
				cnt_3khz <= cnt_3khz + "000000001";
				if cnt_3khz="000000000" and intack_l='1' and c_irq_l='1' then
					irqctr <= irqctr + "0001";
				end if;
			else
				ena_1_5M <= '0';
			end if;
			if intack_l='0' then
				irqctr <= "0000";
			end if;
		end if;
	end process;

	BEAM_ENA <= ena_1_5M;

end Behaviour;
