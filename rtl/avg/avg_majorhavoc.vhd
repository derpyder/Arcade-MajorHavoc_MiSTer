--Atari (Analog) Vector Generator - Major Havoc variant.
--
--Cloned from avg_tempest.vhd (itself from Jeroen Domburg's behavioral AVG). Same AVG
--family + same micro-instruction PROM (136002-125) as Tempest/Gravitar, so the FSM and
--opcodes are identical. Major Havoc differs only in the memory map and colour.
--
--  IMPORTANT: the AVG's INTERNAL pc space is NOT the same as the alpha CPU's view (MAME
--  set_memory(alpha, AS_PROGRAM, $4000) + the mhavoc_data() override).  Two distinct decodes:
--
--  * AVG fetch path (memory_din, 14-bit pc; MAME avg_mhavoc_device::update_databus):
--      pc $0000-$0FFF  vector RAM  (4K)                         -> inferred 4K vecram
--      pc $1000-$1FFF  vector ROM  (4K)                         -> vecrom[$0000-$0FFF] (.210 lo 4K)
--      pc $2000-$3FFF  BANKED ROM  (8K window, bank = m_map)     -> .106/.107 bankrom
--        = m_bank_region[(m_map<<13) | (pc & $1FFF)]; m_map = STAT bits 9:8 (latched in SETCOLOR).
--      (The AVG never reaches the .210 hi 4K -- its pc bit13=1 goes to the bank instead.)
--    vecrom (.210) is 8K @ dn 0x14000-0x15FFF; bankrom (.106+.107) is 32K @ dn 0x16000-0x1DFFF.
--
--  * alpha CPU view ($4000-$7FFF -> 14-bit cpu_addr; served by cpu_data_in, NOT memory_din):
--      $4000-$4FFF vecram ; $5000-$5FFF vecrom lo ; $6000-$7FFF vecrom hi (.210 hi 4K, mirrored).
--    (MAME alpha_map: $5000 vectorrom @0, $6000 vectorrom @$1000 mirror $1000.  The CPU has NO
--     access to the banked .106/.107 -- that region is read only by the AVG's own pc.)
--
--  * Colour: a 16-entry CPU colour RAM ($1400) lookup. ColorRAM nibble is active-low
--    {RED, WeakRed, GRN, BLUE} = {d3,d2,d1,d0}; $00=white(all on), $0F=black(all off).
--    (Tempest's was {G,B,Rhi,Rlo} -- different order, hence MH's own decode below.)
--
-- (C) 2012 Jeroen Domburg (jeroen AT spritesmods.com), GPLv3 - see avg.vhd / COPYING.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

use work.pkg_bwidow.all;

entity avg_majorhavoc is
    Port ( cpu_data_in : out  STD_LOGIC_VECTOR (7 downto 0);
           cpu_data_out : in  STD_LOGIC_VECTOR (7 downto 0);
           cpu_addr : in  STD_LOGIC_VECTOR (13 downto 0);   -- 16K AVG space ($4000-$7FFF)
           cpu_cs_l : in  STD_LOGIC;
           cpu_rw_l : in  STD_LOGIC;
           vgrst : in STD_LOGIC;
           vggo : in STD_LOGIC;
           halted : out STD_LOGIC;
           xout : out  STD_LOGIC_VECTOR (9 downto 0);
           yout : out  STD_LOGIC_VECTOR (9 downto 0);
           zout : out  STD_LOGIC_VECTOR (7 downto 0);
           rgbout : out  STD_LOGIC_VECTOR (2 downto 0);
           color_idx  : out STD_LOGIC_VECTOR (4 downto 0);   -- MH colour RAM index (5-bit; sparkle uses 0x10+)
           color_data : in  STD_LOGIC_VECTOR (7 downto 0);   -- colorram[color_idx] (from majorhavoc.vhd)
           dbg : out std_logic_vector(15 downto 0);
           clken: in STD_LOGIC;
           clk : in  STD_LOGIC;
           dn_addr           : in 	std_logic_vector(17 downto 0);
           dn_data         	 : in 	std_logic_vector(7 downto 0);
           dn_wr				 : in 	std_logic
        );
end avg_majorhavoc;

architecture Behavioral of avg_majorhavoc is
	type stackarraytype is array (natural range <>) of std_logic_vector(13 downto 0);
	type statetype is (FETCHINSLO, FETCHINSHI, EXECINS, FETCHOPHI, FETCHOPLO, DRAWVECLONG,
						DRAWVECSHORT, WAITVECDONE, ISHALTED, SETCOLOR, SETSCALE, CENTER,
						PUSHPCFORJUMP, POPPC, JUMP);
	signal pc: STD_LOGIC_VECTOR(13 downto 0);
	signal instruction: STD_LOGIC_VECTOR(15 downto 0);
	signal operand: STD_LOGIC_VECTOR(15 downto 0);
	signal state: statetype;
	signal stack: stackarraytype(3 downto 0);
	signal sp: STD_LOGIC_VECTOR(1 downto 0);
	signal vecram_dout: STD_LOGIC_VECTOR(7 downto 0);
	signal vecram_din: STD_LOGIC_VECTOR(7 downto 0);
	signal vecrom_dout: STD_LOGIC_VECTOR(7 downto 0);
	signal vecram_cs_l: STD_LOGIC;
	signal vecram_rw_l: STD_LOGIC;
	signal vecram_we: STD_LOGIC;
	signal memory_din: STD_LOGIC_VECTOR(7 downto 0);
	signal memory_addr: STD_LOGIC_VECTOR(13 downto 0);
	signal vec_scale: STD_LOGIC_VECTOR(12 downto 0);
	signal vec_dx: STD_LOGIC_VECTOR(12 downto 0);
	signal vec_dy: STD_LOGIC_VECTOR(12 downto 0);
	signal vec_zero: STD_LOGIC;
	signal vec_draw: STD_LOGIC;
	signal vec_done: STD_LOGIC;
	signal retryRead: STD_LOGIC;
	signal intensity: STD_LOGIC_VECTOR(7 downto 0);
	signal intens_mod: STD_LOGIC_VECTOR(2 downto 0);
	signal rgb: STD_LOGIC_VECTOR(2 downto 0);
	signal color_idx_reg: STD_LOGIC_VECTOR(3 downto 0) := "0000";
	signal map_reg: STD_LOGIC_VECTOR(1 downto 0) := "00";             -- AVG bank select (m_map = STAT bits 9:8)
	signal xflip_reg: STD_LOGIC := '0';                               -- AVG X-flip (MAME m_xdac_xor) = STAT bit 10
	signal sparkle_reg: STD_LOGIC := '0';                             -- AVG sparkle enable (m_enspkl) = STAT bit 11
	signal spkl_shift: STD_LOGIC_VECTOR(7 downto 0) := "00000001";    -- sparkle LFSR (MAME m_spkl_shift)
	signal spkl_palette: STD_LOGIC_VECTOR(3 downto 0);                -- bitswap<4>(spkl,0,2,4,6) -> 0..15
	signal vggo_prev: STD_LOGIC := '0';                               -- for vggo edge detect (restart)
	signal pending_vggo: STD_LOGIC := '0';                            -- B: a mid-draw vggo, applied on HALT
	signal stat_ins: STD_LOGIC_VECTOR(15 downto 0) := (others=>'0');  -- DEBUG: last SETCOLOR opcode executed
	signal vec_ins:  STD_LOGIC_VECTOR(15 downto 0) := (others=>'0');  -- DEBUG: last DRAW-long instruction
	signal vec_op:   STD_LOGIC_VECTOR(15 downto 0) := (others=>'0');  -- DEBUG: last DRAW-long operand
	-- 4K inferred vector RAM ($4000-$4FFF)
	type vecram_t is array(0 to 4095) of std_logic_vector(7 downto 0);
	signal vecram: vecram_t;
	-- 8K vector ROM download decode (dn 0x14000-0x15FFF = the .210 vectorrom)
	signal vecrom_dn_cs: std_logic;
	signal vecrom_addr: std_logic_vector(12 downto 0);
	-- 32K BANKED vector ROM (.106 banks0/1 + .107 banks2/3), dn 0x16000-0x1DFFF
	signal bank_dout: std_logic_vector(7 downto 0);
	signal bank_dn_cs: std_logic;
	signal bank_wraddr: std_logic_vector(17 downto 0);                -- dn_addr - 0x16000 (download offset)
	signal bank_addr: std_logic_vector(14 downto 0);                  -- (m_map<<13) | (pc & $1FFF)
	-- raw beam position from vector_drawer (centred at 0); the entity xout/yout add the centre offset
	signal vd_x: std_logic_vector(9 downto 0);
	signal vd_y: std_logic_vector(9 downto 0);
	signal vec_dx_f: std_logic_vector(12 downto 0);                  -- vec_dx after X-flip (rel_x feed)
	constant DIAG_FORCE_XFLIP: std_logic := '0';                     -- DEBUG: force X-flip on to verify mirroring
	constant DIAG_FORCE_SPARKLE: std_logic := '0';                   -- DEBUG: force sparkle on to verify the twinkle path
begin

	-- 4K vector RAM (inferred dual-purpose single port)
	vecram_we <= (not vecram_cs_l) and (not vecram_rw_l);
	process(clk) begin
		if rising_edge(clk) then
			if vecram_we='1' then
				vecram(conv_integer(memory_addr(11 downto 0))) <= vecram_din;
			end if;
			vecram_dout <= vecram(conv_integer(memory_addr(11 downto 0)));
		end if;
	end process;

	-- 8K vector ROM, loaded from the MH download at 0x14000-0x15FFF.
	-- vecrom addr: lo 4K ($5000-$5FFF, memory_addr(13)=0) -> $0000-$0FFF;
	--              hi 4K ($6000-$7FFF, memory_addr(13)=1) -> $1000-$1FFF.
	vecrom_dn_cs <= '1' when dn_addr(17 downto 13)="01010" else '0';   -- 0x14000-0x15FFF
	vecrom_addr  <= memory_addr(13) & memory_addr(11 downto 0);
	myvecrom: entity work.dpram generic map (13,8)
	port map (
		clock_a   => clk,
		wren_a    => dn_wr and vecrom_dn_cs,
		address_a => dn_addr(12 downto 0),
		data_a    => dn_data,
		clock_b   => clk,
		address_b => vecrom_addr,
		q_b       => vecrom_dout
	);

	-- 32K BANKED vector ROM (.106 banks 0+1 | .107 banks 2+3), loaded from the MH download at
	-- 0x16000-0x1DFFF.  Read only by the AVG fetch (pc $2000-$3FFF, memory_addr(13)='1'); the bank
	-- is m_map (STAT bits 9:8, latched in map_reg).  MAME mhavoc_data: m_bank_region[(m_map<<13) |
	-- (pc & $1FFF)].  Same 1-clock registered-read pipeline as myvecrom (slots into memory_din below).
	bank_dn_cs  <= '1' when (dn_addr >= "010110000000000000"            -- >= 0x16000
	                    and  dn_addr <= "011101111111111111") else '0';  -- <= 0x1DFFF
	bank_wraddr <= dn_addr - "010110000000000000";                        -- 0-based offset into the 32K
	bank_addr   <= map_reg & memory_addr(12 downto 0);                    -- (m_map<<13) | (pc & $1FFF)
	mybankrom: entity work.dpram generic map (15,8)
	port map (
		clock_a   => clk,
		wren_a    => dn_wr and bank_dn_cs,
		address_a => bank_wraddr(14 downto 0),
		data_a    => dn_data,
		clock_b   => clk,
		address_b => bank_addr,
		q_b       => bank_dout
	);

	-- X-flip (MAME mhavoc_strobe2: STAT b10 -> m_xdac_xor=0x1FF inverts the X DAC): negate the X delta
	-- so symmetric content (e.g. maze halves) draws mirrored.  Flipping the per-vector dx mirrors X
	-- about the screen centre (the entity xout adds +512).  Per-STAT, latched in xflip_reg.
	vec_dx_f <= (b"0000000000000" - vec_dx) when (xflip_reg='1' or DIAG_FORCE_XFLIP='1') else vec_dx;

	vectordrawer: vector_drawer port map (
		clk => clk,
		clk_ena => clken,
		scale => vec_scale,
		rel_x => vec_dx_f,
		rel_y => vec_dy,
		zero => vec_zero,
		draw => vec_draw,
		done => vec_done,
		xout => vd_x,
		yout => vd_y
	);

	-- Centre the picture.  vector_drawer zeros the beam at CNTR (origin coordinate 0), so signed
	-- excursions wrap mod-1024 and tear the image into the four corners.  MAME centres the AVG at
	-- m_xcenter/m_ycenter (mid-screen) and the X/Y DACs XOR the position with 0x200 to convert the
	-- signed accumulator to unsigned screen coords.  Add 512 (= flip bit 9) on BOTH axes so the
	-- picture sits centred on screen.  (X-flip is applied upstream as a vec_dx negate -> see vec_dx_f.)
	xout <= (not vd_x(9)) & vd_x(8 downto 0);
	yout <= (not vd_y(9)) & vd_y(8 downto 0);

	process (clk) begin
		if clk'event and clk='1' then
			if clken='1' then
				vec_zero<='0';
				vec_draw<='0';
				vggo_prev<=vggo;
				-- Sparkle LFSR free-runs (MAME mhavoc_strobe3): next = (shift<<1) | (b6 xor b5 xor 1),
				-- reset to 0 if the low 7 bits hit all-ones (the lock state).  SETCOLOR re-seeds it below.
				if spkl_shift(6 downto 0) = "1111111" then
					spkl_shift<="00000000";
				else
					spkl_shift<=spkl_shift(6 downto 0) & (spkl_shift(6) xor spkl_shift(5) xor '1');
				end if;
				if vgrst='1' then
					pc<="00000000000000";
					instruction<=x"0000";
					state<=ISHALTED;
					sp<="00";
					rgb<="000";
					color_idx_reg<="0000";
					sparkle_reg<='0';                          -- MAME mhavoc_vgrst clears m_enspkl
					intensity<=(others=>'0');
					intens_mod<=(others=>'0');
					vec_dx<=(others=>'0');
					vec_dy<=(others=>'0');
					vec_scale<=(others=>'0');
					vec_zero<='1';
					vec_draw<='0';
					pending_vggo<='0';                         -- B: vgrst clears any deferred restart
				elsif vggo='1' and vggo_prev='0' then
					-- B (defer-restart): a vggo while HALTED restarts immediately (normal); a vggo that
					-- arrives MID-DRAW is LATCHED (pending_vggo) instead of abandoning the in-progress
					-- list -> the AVG finishes the current COMPLETE list, then restarts on halt.  The
					-- latch (not a drop) keeps the content vggo from being lost (the old halted-only bug
					-- restarted-only-when-halted and dropped it; here it is remembered).
					if state=ISHALTED then
						pc<="00000000000000";
						sp<="00";
						state<=FETCHINSLO;
					else
						pending_vggo<='1';
					end if;
				elsif state=EXECINS then
					if instruction(15 downto 13)="000" then --draw relative vector
						state<=FETCHOPLO;
					elsif instruction(15 downto 13)="001" then --halt
						state<=ISHALTED;
					elsif instruction(15 downto 13)="010" then --draw short
						state<=DRAWVECSHORT;
					elsif instruction(15 downto 12)="0110" then --new color
						state<=SETCOLOR;
					elsif instruction(15 downto 12)="0111" then --new scale
						state<=SETSCALE;
					elsif instruction(15 downto 13)="100" then --center
						state<=CENTER;
					elsif instruction(15 downto 13)="101" then --jump to subroutine
						state<=PUSHPCFORJUMP;
					elsif instruction(15 downto 13)="110" then --return from subroutine
						state<=POPPC;
					elsif instruction(15 downto 13)="111" then --jump to address
						state<=JUMP;
					end if;
				elsif state=DRAWVECLONG then
					vec_dy<=instruction(12 downto 0);
					vec_dx<=operand(12 downto 0);
					intens_mod<=operand(15 downto 13);
					vec_ins<=instruction; vec_op<=operand;   -- DEBUG
					vec_draw<='1';
					state<=WAITVECDONE;
				elsif state=DRAWVECSHORT then
					vec_dy(5 downto 1)<=instruction(12 downto 8);
					vec_dy(0)<='0';
					if instruction(12)='0' then
						vec_dy(12 downto 6)<="0000000";
					else
						vec_dy(12 downto 6)<="1111111";
					end if;
					vec_dx(5 downto 1)<=instruction(4 downto 0);
					vec_dx(0)<='0';
					if instruction(4)='0' then
						vec_dx(12 downto 6)<="0000000";
					else
						vec_dx(12 downto 6)<="1111111";
					end if;
					intens_mod<=instruction(7 downto 5);
					vec_draw<='1';
					state<=WAITVECDONE;
				elsif state=WAITVECDONE then
					if vec_done='1' then
						state<=FETCHINSLO;
					end if;
				elsif state=SETCOLOR then
					-- Major Havoc 0x60 colour/intensity opcode carries the 4-bit colorram INDEX in
					-- instruction(3:0) and the 4-bit intensity in instruction(7:4), BOTH set every
					-- time (cf. Black Widow avg.vhd which used (2:0) as a direct 3-bit colour).
					-- (Tempest's bit11-select scheme leaves the index at 0 here -> colorram[0]=$0F
					--  black -> blank screen; observed in sim, hence MH's own decode.)
					color_idx_reg<=instruction(3 downto 0);    -- 4-bit colour RAM index
					intensity<=instruction(7 downto 4)&"0000"; -- 4-bit intensity
					map_reg<=instruction(9 downto 8);          -- AVG bank select (m_map = STAT bits 9:8)
					xflip_reg<=instruction(10);                -- AVG X-flip (mirror X) = STAT bit 10
					sparkle_reg<=instruction(11);              -- AVG sparkle enable = STAT bit 11
					if instruction(11)='1' then                -- seed the sparkle LFSR from the STAT (content-correlated)
						spkl_shift<=instruction(7 downto 0);
					end if;
					stat_ins<=instruction;                     -- DEBUG: capture the SETCOLOR opcode
					state<=FETCHINSLO;
				elsif state=SETSCALE then
					if instruction(10 downto 8)="000" then
						vec_scale<=       ("100000000"-('0'&instruction(7 downto 0)))&"0000";
					elsif instruction(10 downto 8)="001" then
						vec_scale<='0'&   ("100000000"-('0'&instruction(7 downto 0)))&"000";
					elsif instruction(10 downto 8)="010" then
						vec_scale<="00"&  ("100000000"-('0'&instruction(7 downto 0)))&"00";
					elsif instruction(10 downto 8)="011" then
						vec_scale<="000"& ("100000000"-('0'&instruction(7 downto 0)))&"0";
					elsif instruction(10 downto 8)="100" then
						vec_scale<="0000"&("100000000"-('0'&instruction(7 downto 0)));
					elsif instruction(10 downto 8)="101" then
						vec_scale<="00000"&("10000000"-     instruction(7 downto 1));
					elsif instruction(10 downto 8)="110" then
						vec_scale<="000000"&("1000000"-     instruction(7 downto 2));
					elsif instruction(10 downto 8)="111" then
						vec_scale<="0000000"&("100000"-     instruction(7 downto 3));
					end if;
					state<=FETCHINSLO;
				elsif state=CENTER then
					intens_mod<="000"; --blank
					vec_zero<='1';
					state<=WAITVECDONE;
				elsif state=PUSHPCFORJUMP then
					if (sp="00") then stack(0)<=pc; end if;
					if (sp="01") then stack(1)<=pc; end if;
					if (sp="10") then stack(2)<=pc; end if;
					if (sp="11") then stack(3)<=pc; end if;
					sp<=sp+"01";
					state<=JUMP;
				elsif state=JUMP then
					pc(13 downto 1)<=instruction(12 downto 0);
					pc(0)<='0';
					state<=FETCHINSLO;
				elsif state=POPPC then
					if (sp="01") then pc<=stack(0); end if;
					if (sp="10") then pc<=stack(1); end if;
					if (sp="11") then pc<=stack(2); end if;
					if (sp="00") then pc<=stack(3); end if;
					sp<=sp-"01";
					state<=FETCHINSLO;
				elsif state=ISHALTED then
					pc<=(others=>'0');
					rgb<="000";
					vec_zero<='1';
					if pending_vggo='1' then            -- B: apply the deferred vggo now that we've HALTED
						pc<="00000000000000";
						sp<="00";
						state<=FETCHINSLO;
						pending_vggo<='0';
					end if;
				elsif cpu_cs_l='0' then
					retryRead<='1';
				elsif retryRead='1' then
					retryRead<='0';
				elsif state=FETCHINSLO then
					instruction(7 downto 0)<=memory_din;
					pc<=pc+"00000000000001";
					state<=FETCHINSHI;
				elsif state=FETCHINSHI then
					instruction(15 downto 8)<=memory_din;
					pc<=pc+"00000000000001";
					state<=EXECINS;
				elsif state=FETCHOPLO then
					operand(7 downto 0)<=memory_din;
					pc<=pc+"00000000000001";
					state<=FETCHOPHI;
				elsif state=FETCHOPHI then
					operand(15 downto 8)<=memory_din;
					pc<=pc+"00000000000001";
					state<=DRAWVECLONG;
				else
					state<=FETCHINSLO;
				end if;
			end if;
		end if;
	end process;

	-- AVG fetch RAM/ROM/BANK split (memory_din feeds the AVG state machine ONLY; the alpha CPU's
	-- $6000-$7FFF reads are served separately by cpu_data_in below, so they keep vecrom-hi):
	--   pc $0000-$0FFF (memory_addr(13:12)="00") = vector RAM
	--   pc $2000-$3FFF (memory_addr(13)='1')     = banked vector ROM (.106/.107), bank = map_reg
	--   pc $1000-$1FFF (else)                    = vector ROM (.210 lo 4K)
	memory_din <= vecram_dout when memory_addr(13 downto 12)="00" else
	              bank_dout   when memory_addr(13)='1'            else
	              vecrom_dout;

	process (clk) begin
		if clk'event and clk='1' then
			if cpu_cs_l='0' then
				--CPU wants to access vector memory ($4000-$7FFF)
				vecram_rw_l<=cpu_rw_l;
				memory_addr<=cpu_addr;
				vecram_din<=cpu_data_out;
				if cpu_addr(13 downto 12)="00" then
					vecram_cs_l<='0';
				else
					vecram_cs_l<='1';
				end if;
				if cpu_addr(13 downto 12)="00" then
					cpu_data_in<=vecram_dout;
				else
					cpu_data_in<=vecrom_dout;
				end if;
			else
				--AVG has access.
				vecram_rw_l<='1';
				vecram_cs_l<='0';
				memory_addr<=pc;
			end if;
		end if;
	end process;

	dbg(15)<=clk;
	dbg(14)<=clken;
	dbg(13)<='0';
	dbg(12)<=retryRead;
	dbg(11)<=cpu_cs_l;
	dbg(10)<=cpu_rw_l;
	dbg(9)<=vecram_cs_l;
	dbg(8)<=vecram_rw_l;
	dbg(7 downto 4)<=memory_addr(3 downto 0);
	dbg(3 downto 0)<=vecram_din(3 downto 0);

	halted<='1' when state=ISHALTED else '0';

	zout<=intensity when intens_mod="001" else intens_mod&"00000";

	-- Major Havoc colour: present the latched index to majorhavoc.vhd's colour RAM and resolve
	-- colorram[idx] -> hue. Nibble {d3,d2,d1,d0} active-low = {RED, WeakRed, GRN, BLUE}.
	-- First cut collapses the 2-bit red (full d3 + weak d2) to 1 bit. rgb(2)=R, rgb(1)=G, rgb(0)=B.
	-- Blank on halt.
	--
	-- SPARKLE (MAME mhavoc_strobe3): when enabled the colour twinkles from the UPPER palette
	-- colorram[0xF + bitswap<4>(spkl,0,2,4,6)] driven by the free-running LFSR; else the normal 4-bit
	-- index (entries 0-15).  (Behavioural twinkle: this colours the whole vector from the sparkle
	-- palette rather than MAME's sparse half-step dots -- a first cut; not visually validated since the
	-- attract frame has no sparkle STAT.  Exact dotting + rand-seeding deferred to gameplay content.)
	spkl_palette <= spkl_shift(0) & spkl_shift(2) & spkl_shift(4) & spkl_shift(6);  -- bitswap<4>(spkl,0,2,4,6)
	color_idx <= ("01111" + ("0" & spkl_palette)) when (sparkle_reg='1' or DIAG_FORCE_SPARKLE='1')
	             else ("0" & color_idx_reg);
	rgbout <= "000" when state=ISHALTED
	          else ( ((not color_data(3)) or (not color_data(2)))   -- R = ~RED OR ~WeakRed
	                 & (not color_data(1))                          -- G = ~GRN
	                 & (not color_data(0)) );                       -- B = ~BLUE
end Behavioral;
