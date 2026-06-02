--Atari (Analog) Vector Generator - Tempest variant.
--
--Cloned from avg.vhd (Jeroen Domburg's behavioral AVG, which is explicitly
--"compatible with the Tempest AVG, which uses the same micro-instruction ROM").
--Tempest differs from Black Widow only in:
--  * vector RAM is 4K ($2000-$2FFF) not 2K  -> 4K inferred vecram
--  * vector ROM is 4K ($3000-$3FFF)         -> 4K vecrom, loaded from dn 0x5000
--  * RAM/ROM split at address bit 12 (8K AVG space, 13-bit cpu_addr)
--  * colour: a 16-entry CPU colour RAM lookup + X/Y swap (PHASE 2 - not yet here;
--    this Phase-1 version keeps Black Widow's direct colour so the CPU can boot
--    and issue vggo; vectors render but colours are not yet Tempest-correct).
--
-- Black Widow arcade hardware implemented in an FPGA
-- (C) 2012 Jeroen Domburg (jeroen AT spritesmods.com)
-- GPLv3 - see avg.vhd / COPYING.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

use work.pkg_bwidow.all;

entity avg_tempest is
    Port ( cpu_data_in : out  STD_LOGIC_VECTOR (7 downto 0);
           cpu_data_out : in  STD_LOGIC_VECTOR (7 downto 0);
           cpu_addr : in  STD_LOGIC_VECTOR (12 downto 0);   -- 8K AVG space ($2000-$3FFF)
           cpu_cs_l : in  STD_LOGIC;
           cpu_rw_l : in  STD_LOGIC;
			  vgrst : in STD_LOGIC;
			  vggo : in STD_LOGIC;
			  halted : out STD_LOGIC;
           xout : out  STD_LOGIC_VECTOR (9 downto 0);
           yout : out  STD_LOGIC_VECTOR (9 downto 0);
           zout : out  STD_LOGIC_VECTOR (7 downto 0);
           rgbout : out  STD_LOGIC_VECTOR (2 downto 0);
           color_idx  : out STD_LOGIC_VECTOR (3 downto 0);   -- Tempest colour RAM index
           color_data : in  STD_LOGIC_VECTOR (7 downto 0);   -- colorram[color_idx] (from tempest.vhd)
		  	  dbg : out std_logic_vector(15 downto 0);
			  clken: in STD_LOGIC;
           clk : in  STD_LOGIC;
			  dn_addr           : in 	std_logic_vector(15 downto 0);
			  dn_data         	 : in 	std_logic_vector(7 downto 0);
			  dn_wr				 : in 	std_logic
		);
end avg_tempest;

architecture Behavioral of avg_tempest is
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
	-- 4K inferred vector RAM (1-clock read, like the dpram-based vecrom this AVG
	-- also reads through the same memory_din mux).
	type vecram_t is array(0 to 4095) of std_logic_vector(7 downto 0);
	signal vecram: vecram_t;
	-- 4K vector ROM download decode (dn 0x5000-0x5FFF)
	signal vecrom_dn_cs: std_logic;
	signal off_screen: std_logic;   -- drawer flag: TRUE position overflowed the 10-bit screen (warp)
begin

	-- 4K vector RAM (inferred dual-purpose single port, like ram2k but 12-bit)
	vecram_we <= (not vecram_cs_l) and (not vecram_rw_l);
	process(clk) begin
		if rising_edge(clk) then
			if vecram_we='1' then
				vecram(conv_integer(memory_addr(11 downto 0))) <= vecram_din;
			end if;
			vecram_dout <= vecram(conv_integer(memory_addr(11 downto 0)));
		end if;
	end process;
	-- This 1-clock inferred read is correct because the AVG FSM is clken-gated
	-- (1-in-8 in the real core) while this read and the memory_addr process run
	-- every clk -- so memory_addr and vecram_dout settle between FSM steps.
	-- Validated in sim/tb_avg_tempest.vhd with clken at 1-in-8: instruction reads
	-- 6805 -> SETCOLOR idx=5 -> rgb=110 (colorram[5]=0x05). (An earlier apparent
	-- "fetch bug" was just the unit test forcing clken=1, which starved settling.)

	-- 4K vector ROM, loaded from the download at 0x5000-0x5FFF
	vecrom_dn_cs <= '1' when dn_addr(15 downto 12)="0101" else '0';
	myvecrom: entity work.dpram generic map (12,8)
	port map (
		clock_a   => clk,
		wren_a    => dn_wr and vecrom_dn_cs,
		address_a => dn_addr(11 downto 0),
		data_a    => dn_data,
		clock_b   => clk,
		address_b => memory_addr(11 downto 0),
		q_b       => vecrom_dout
	);

	vectordrawer: vector_drawer port map (
		clk => clk,
		clk_ena => clken,
		scale => vec_scale,
		rel_x => vec_dx,
		rel_y => vec_dy,
		zero => vec_zero,
		draw => vec_draw,
		done => vec_done,
		xout => xout,
		yout => yout,
		off_screen => off_screen
	);

	process (clk) begin
		if clk'event and clk='1' then
			if clken='1' then
				vec_zero<='0';
				vec_draw<='0';
				if vgrst='1' then
					pc<="00000000000000";
					instruction<=x"0000";
					state<=ISHALTED;
					sp<="00";
					rgb<="000";
					color_idx_reg<="0000";
					intensity<=(others=>'0');
					intens_mod<=(others=>'0');
					vec_dx<=(others=>'0');
					vec_dy<=(others=>'0');
					vec_scale<=(others=>'0');
					vec_zero<='1';
					vec_draw<='0';
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
					-- Tempest STAT (MAME avg_tempest::handler_6): for the 0x60 opcode,
					-- instruction(11) selects colour-index latch vs intensity latch.
					if instruction(11)='1' then
						color_idx_reg<=instruction(3 downto 0);   -- 4-bit colour RAM index
					else
						intensity<=instruction(7 downto 4)&"0000"; -- 4-bit intensity
					end if;
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
					if vggo='1' then state<=FETCHINSLO; end if;
					rgb<="000";
					vec_zero<='1';
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

	-- RAM/ROM split at bit 12 (RAM $2000-$2FFF = 0x0000-0x0FFF, ROM $3000-$3FFF = 0x1000-0x1FFF)
	memory_din<=vecram_dout when memory_addr(12)='0' else vecrom_dout;

	process (clk) begin
		if clk'event and clk='1' then
			if cpu_cs_l='0' then
				--CPU wants to access vector memory
				vecram_rw_l<=cpu_rw_l;
				memory_addr<='0' & cpu_addr;
				vecram_din<=cpu_data_out;
				if cpu_addr(12)='0' then
					vecram_cs_l<='0';
				else
					vecram_cs_l<='1';
				end if;
				if cpu_addr(12)='0' then
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

	--idiotic scheme for the intensity... thanks to the mame source for this line.
	zout<=intensity when intens_mod="001" else intens_mod&"00000";

	-- Tempest colour: present the latched index to tempest.vhd's colour RAM and
	-- resolve colorram[idx] -> hue. The nibble {d3,d2,d1,d0} is active-low and
	-- maps to {G, B, Rhi, Rlo} (MAME avg_tempest::handler_7). First cut collapses
	-- the 2-bit red to 1 bit; rgb(2)=R, rgb(1)=G, rgb(0)=B (framebuffer bit order).
	-- Blank on halt or a zero-intensity (move) vector.
	color_idx <= color_idx_reg;
	rgbout <= "000" when (state=ISHALTED) or (off_screen='1')   -- blank off-screen (warp clip)
	          else ( ((not color_data(1)) or (not color_data(0)))
	                 & (not color_data(3))
	                 & (not color_data(2)) );
end Behavioral;
