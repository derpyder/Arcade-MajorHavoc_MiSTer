-- majorhavoc.vhd  --  Major Havoc (Atari, 1983) dual-6502 game module
-- ===========================================================================
-- P1 DRAFT (the boot gate).  UNTESTED -- needs a GHDL dual-CPU boot sim that
-- reaches alpha `vggo` ($1640).  See D:\deck\fpga\majorhavoc\HANDOFF-majorhavoc.md.
--
-- Implements, from MAME src/mame/atari/mhavoc.cpp (verbatim maps, 2026-05-29 fetch):
--   * ALPHA 6502 @ 2.5 MHz (10/4) + GAMMA 6502 @ 1.25 MHz (10/8), separate buses.
--   * Full alpha + gamma memory maps (RAM / banked RAM / I/O / comram / vecram /
--     vecrom / banked+fixed program ROM ; gamma RAM / POKEY / inputs / EEPROM / ROM).
--   * ROM banking: rompg $1740 (2 bits -> 4x 8K pages at $2000-$3FFF),
--     rampg $1780 (1 bit -> 2x paged-RAM banks).
--   * Inter-CPU comms: a2g latch (alpha $17C0 -> gamma $3000) + g2a latch
--     (gamma $5000 -> alpha $1000) with xmtd/rcvd handshake flags; gamma takes an
--     NMI when alpha writes $17C0; both CPUs IRQ at ~5 kHz.
--
-- STUBBED for P1 (fleshed out later): AVG vector output (P2 -- vecram is plain RAM
-- here, vggo just latched), quad POKEY audio (P4), 2804 EEPROM (P4 -- plain RAM here).
--
-- !! VALIDATE IN SIM: the comms handshake-flag bit positions/polarity in IN0/IN1 are
--    best-effort from the handoff; confirm against MAME INPUT_PORTS(mhavoc) + the
--    jessaskey self-test (mhavocpe-ref/Source/mh_alpha.asm) before trusting them.
-- ===========================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.std_logic_arith.all;

entity majorhavoc is
  port(
    reset_h          : in  std_logic;
    clk              : in  std_logic;   -- 10 MHz master ; alpha_ena=clk/4, gamma_ena=clk/8
    pause_h          : in  std_logic;

    -- AVG vector output (stubbed in P1)
    analog_x_out     : out std_logic_vector(9 downto 0);
    analog_y_out     : out std_logic_vector(9 downto 0);
    analog_z_out     : out std_logic_vector(7 downto 0);
    rgb_out          : out std_logic_vector(2 downto 0);
    BEAM_ENA         : out std_logic;
    analog_sound_out : out std_logic_vector(7 downto 0);

    -- inputs
    IN0              : in  std_logic_vector(7 downto 0);  -- alpha $1200 (coins/diag/cocktail/self-test)
    IN1              : in  std_logic_vector(7 downto 0);  -- gamma $2800 (fire/shield + flags)
    DSW1             : in  std_logic_vector(7 downto 0);  -- POKEY 0 allpot ($2000): gameplay DIPs
    DSW2             : in  std_logic_vector(7 downto 0);  -- gamma $4000
    DIAL             : in  std_logic_vector(7 downto 0);  -- gamma $3800 roller

    -- frame strobes (for an eventual DDR framebuffer, mirrors tempest.vhd)
    frame_done       : out std_logic;   -- AVG halted
    start_frame      : out std_logic;   -- vggo

    -- ROM download (concatenated: alpha 64K | gamma 16K | vectorrom 8K | avg 32K | prom)
    dn_addr          : in  std_logic_vector(17 downto 0);
    dn_data          : in  std_logic_vector(7 downto 0);
    dn_wr            : in  std_logic;

    dbg              : out std_logic_vector(15 downto 0)
  );
end majorhavoc;

architecture rtl of majorhavoc is
  -- ---- clock enables ----
  -- SPEED FIX: clk is the 12.096MHz SW chassis clock but MH wants 10MHz.  game_ce gates the game to
  -- 5/6 of clk = 10.08MHz (+0.8%, imperceptible).  Gating the two free-running counters (clkdiv +
  -- irq5k_div) slows everything uniformly: CPUs (alpha/gamma_ena), AVG (avg_ena=alpha_ena), POKEY
  -- (ENA=gamma_ena), IRQ (irq5k_tick) all ride these, ratios preserved.  No clock split -> the ROM
  -- download stays in the clk domain (a clk_10 PLL split black-screened on that very CDC).
  signal ce_cnt      : integer range 0 to 5 := 0;
  signal game_ce     : std_logic;   -- high 5 of every 6 clk cycles
  signal clkdiv      : std_logic_vector(2 downto 0) := "000";
  signal alpha_ena   : std_logic;   -- clk/4  -> ~2.52 MHz (game-ticks)
  signal gamma_ena   : std_logic;   -- clk/8  -> ~1.26 MHz
  signal reset_l     : std_logic;

  -- ---- ALPHA bus ----
  signal a_addr      : std_logic_vector(23 downto 0);
  signal a_din       : std_logic_vector(7 downto 0);
  signal a_dout      : std_logic_vector(7 downto 0);
  signal a_rw_l      : std_logic;
  signal a_irq_l     : std_logic;
  signal a_ad        : std_logic_vector(15 downto 0);   -- a_addr(15:0) alias

  -- ---- GAMMA bus ----
  signal g_addr      : std_logic_vector(23 downto 0);
  signal g_din       : std_logic_vector(7 downto 0);
  signal g_dout      : std_logic_vector(7 downto 0);
  signal g_rw_l      : std_logic;
  signal g_irq_l     : std_logic;
  signal g_nmi_l     : std_logic;
  signal g_ad        : std_logic_vector(15 downto 0);

  -- ---- ROM/RAM data ----
  signal arom_dout   : std_logic_vector(7 downto 0);    -- alpha ROM (64K: $8000-$FFFF fixed + $2000-$3FFF banked)
  signal arom_addr   : std_logic_vector(15 downto 0);
  signal grom_dout   : std_logic_vector(7 downto 0);    -- gamma ROM (16K)
  -- (vecram + vecrom $4000-$7FFF now live INSIDE avg_majorhavoc; the alpha accesses them
  --  through the AVG cpu interface -> avg_dout.)

  signal arama_dout  : std_logic_vector(7 downto 0);    -- alpha unbanked RAM A $0000-$01FF (holds zp $A5)
  signal aramb_dout  : std_logic_vector(7 downto 0);    -- alpha unbanked RAM B $0800-$09FF (separate!)
  signal abank_dout  : std_logic_vector(7 downto 0);    -- alpha banked RAM $0200-$07FF/$0A00-$0FFF
  signal comram_dout : std_logic_vector(7 downto 0);    -- shared beta RAM $1800-$1FFF
  signal gram_dout   : std_logic_vector(7 downto 0);    -- gamma RAM $0000-$07FF
  signal eep_dout    : std_logic_vector(7 downto 0);    -- 2804 EEPROM (stub RAM) $6000-$61FF

  -- ---- banking ----
  signal rompg       : std_logic_vector(1 downto 0) := "00";   -- $1740
  signal rampg       : std_logic := '0';                       -- $1780

  -- ---- inter-CPU comms ----
  signal a2g_latch   : std_logic_vector(7 downto 0) := (others=>'0');  -- alpha->gamma
  signal g2a_latch   : std_logic_vector(7 downto 0) := (others=>'0');  -- gamma->alpha
  signal alpha_xmtd  : std_logic := '0';   -- alpha has written a2g, gamma not yet read
  signal gamma_rcvd  : std_logic := '0';   -- gamma has read a2g
  signal gamma_xmtd  : std_logic := '0';   -- gamma has written g2a, alpha not yet read
  signal alpha_rcvd  : std_logic := '0';   -- alpha has read g2a
  signal gamma_nmi_pend : std_logic := '0';

  -- ---- alpha control outputs ($1600 out_0_w) ----
  signal invx, invy  : std_logic := '0';
  signal player_sel  : std_logic := '0';
  signal gamma_reset : std_logic := '1';   -- D3 (0=run) ; held reset until alpha clears
  signal beta_reset  : std_logic := '1';

  -- ---- AVG (Analog Vector Generator) ----
  signal vggo        : std_logic;
  signal vgrst       : std_logic;
  signal avg_halted  : std_logic;          -- real halt from avg_majorhavoc
  signal avg_ena     : std_logic;          -- AVG clock enable (clk/4)
  signal avg_cs_l    : std_logic;          -- alpha accessing $4000-$7FFF (vecram/vecrom)
  signal avg_dout    : std_logic_vector(7 downto 0);   -- AVG -> alpha (vecram/vecrom read)
  signal avg_dbg     : std_logic_vector(15 downto 0);
  signal avg_cidx    : std_logic_vector(4 downto 0);   -- colour RAM index from AVG (5-bit: 0-31; sparkle uses 0x10+)
  signal avg_cdata   : std_logic_vector(7 downto 0);   -- colorram[avg_cidx] -> AVG
  signal rgb_out_i   : std_logic_vector(2 downto 0);   -- AVG rgb (also feeds BEAM_ENA)
  -- DIAG: force a non-black colorram value to prove the colour-decode + render path while the
  -- game is still in its pre-attract blank state (STAT $6000 -> colorram[0]=$0F black).  false=real.
  constant DIAG_FORCE_COLOR : boolean := false;
  -- 32-entry colour RAM ($1400-$141F, alpha-written; active-low {RED,WeakRed,GRN,BLUE} nibble).
  -- Entries 0-15 = normal colours (4-bit STAT colour); 16-31 = the sparkle palette (MAME reads
  -- colorram[0xf + bitswap(spkl)]).  (Was 16 w/ a_ad(3:0) -> $1410-$141F aliased onto $1400-$140F.)
  type colorram_t is array(0 to 31) of std_logic_vector(7 downto 0);
  signal colorram    : colorram_t := (others => (others => '0'));
  signal colram_we   : std_logic;

  -- ---- IRQ: 5 kHz LS161 dividers (MHAVOC_CLOCK_5K = 10 MHz/2048 = 4882.8 Hz), per mhavoc.cpp ----
  signal irq5k_div   : integer range 0 to 2047 := 0;
  signal irq5k_tick  : std_logic := '0';
  signal a_irqclk    : std_logic_vector(7 downto 0) := (others=>'0');  -- alpha LS161 count
  signal a_irqclk_en : std_logic := '1';                              -- counts only while enabled
  signal alpha_irq_pend : std_logic := '0';                          -- latched alpha IRQ (cleared by $1700)
  signal g_irqclk    : std_logic_vector(7 downto 0) := (others=>'0');  -- gamma LS161 (free-run, IRQ=bit3 level)

  -- ---- 2.4 kHz reference ($1200 D1, a_def.ah i_24khz) ----
  signal clk24_ctr   : integer range 0 to 2082 := 0;
  signal clk24       : std_logic := '0';

  -- ---- decodes ----
  signal arom_cs, comram_cs, abank_cs, arama_cs, aramb_cs : std_logic;
  signal abank_we, arama_we, aramb_we, comram_we : std_logic;
  signal gram_cs, grom_cs, eep_cs, pokey_cs : std_logic;
  -- Quad POKEY (4x on the gamma $2000-$203F bus; audio summed -> analog_sound_out)
  signal p0_dout, p1_dout, p2_dout, p3_dout : std_logic_vector(7 downto 0);
  signal p0_audio, p1_audio, p2_audio, p3_audio : std_logic_vector(7 downto 0);
  signal p0_cs_l, p1_cs_l, p2_cs_l, p3_cs_l : std_logic;
  signal pokey_addr : std_logic_vector(3 downto 0);
  signal pokey_rd   : std_logic_vector(7 downto 0);

begin
  reset_l <= not reset_h;
  a_ad <= a_addr(15 downto 0);
  g_ad <= g_addr(15 downto 0);

  -- =======================================================================
  -- Clock enables: alpha = clk/4, gamma = clk/8  (master = 10 MHz)
  -- =======================================================================
  process(clk) begin
    if rising_edge(clk) then
      if ce_cnt = 5 then ce_cnt <= 0; else ce_cnt <= ce_cnt + 1; end if;  -- 0..5 rolling
      if game_ce = '1' then clkdiv <= clkdiv + 1; end if;                 -- advance 5 of 6 cycles
    end if;
  end process;
  game_ce   <= '0' when ce_cnt = 5 else '1';                                       -- 5/6 duty -> 10.08MHz
  -- AND game_ce into the enables so they stay SINGLE-cycle pulses (clkdiv holds during the skipped
  -- cycle; without this the CPU would double-clock on a held "11"/"111").
  alpha_ena <= '1' when clkdiv(1 downto 0) = "11"  and game_ce = '1' else '0';  -- every 4th game-tick
  gamma_ena <= '1' when clkdiv(2 downto 0) = "111" and game_ce = '1' else '0';  -- every 8th game-tick

  -- =======================================================================
  -- CPUs
  -- =======================================================================
  alpha: entity work.T65 port map (
    Mode => "00", Res_n => reset_l, Enable => alpha_ena, Clk => clk,
    Rdy => not pause_h, Abort_n => '1', IRQ_n => a_irq_l, NMI_n => '1', SO_n => '1',
    R_W_n => a_rw_l, Sync => open, EF => open, MF => open, XF => open,
    ML_n => open, VP_n => open, VDA => open, VPA => open,
    A => a_addr, DI => a_din, DO => a_dout
  );

  gamma: entity work.T65 port map (
    Mode => "00", Res_n => reset_l and not gamma_reset, Enable => gamma_ena, Clk => clk,
    Rdy => not pause_h, Abort_n => '1', IRQ_n => g_irq_l, NMI_n => g_nmi_l, SO_n => '1',
    R_W_n => g_rw_l, Sync => open, EF => open, MF => open, XF => open,
    ML_n => open, VP_n => open, VDA => open, VPA => open,
    A => g_addr, DI => g_din, DO => g_dout
  );

  -- =======================================================================
  -- ROMs (loaded from download; see entity header for the concatenation)
  --   alpha 64K  : dn 0x00000-0x0FFFF  (= MAME alpha region $8000-$17FFF)
  --   gamma 16K  : dn 0x10000-0x13FFF
  --   vectorrom 8K: dn 0x14000-0x15FFF
  -- =======================================================================
  arom : entity work.dpram generic map (16,8) port map (
    clock_a => clk, wren_a => dn_wr and (not dn_addr(17) and not dn_addr(16)), -- 0x00000-0x0FFFF
    address_a => dn_addr(15 downto 0), data_a => dn_data,
    clock_b => clk, address_b => arom_addr, q_b => arom_dout );

  grom : entity work.dpram generic map (14,8) port map (
    clock_a => clk, wren_a => dn_wr and dn_addr(16) and not dn_addr(15) and not dn_addr(14), -- 0x10000-0x13FFF
    address_a => dn_addr(13 downto 0), data_a => dn_data,
    clock_b => clk, address_b => g_ad(13 downto 0), q_b => grom_dout );

  -- (vector ROM $5000-$7FFF now lives inside avg_majorhavoc, loaded from dn 0x14000-0x15FFF.)

  -- alpha ROM addressing:
  --   fixed   $8000-$FFFF -> arom[$0000-$7FFF]      (addr - $8000)
  --   banked  $2000-$3FFF -> arom[$8000 + rompg*$2000 + (addr-$2000)]
  arom_addr <= ('0' & a_ad(14 downto 0)) when a_ad(15) = '1'    -- $8000-$FFFF
               else ('1' & rompg & a_ad(12 downto 0));          -- $2000-$3FFF banked

  -- =======================================================================
  -- RAMs
  -- =======================================================================
  -- alpha unbanked RAM A ($0000-$01FF) -- 512B.  MAME alpha_map: map(0x0000,0x01ff).ram().
  -- *** This holds zp $A5 (the $1600 out_0 shadow w/ D3=gamma-run).  RAM A and RAM B MUST be
  --     separate (they are two distinct .ram() shares in MAME); the old single-1K-aram decode
  --     aliased $00A5<->$08A5<->$04A5, so a RAM-B write to $08A5 wiped $A5's D3 bit and the IRQ
  --     handler's player-mux write ($87C9 STA $1600 = $A5 & $DF) then RESET the gamma every frame
  --     -> the boot-handshake "infinite retry".  (Root-caused in sim 2026-05-31.)
  arama : entity work.dpram generic map (9,8) port map (
    clock_a => clk, wren_a => arama_we, address_a => a_ad(8 downto 0), data_a => a_dout,
    clock_b => clk, address_b => a_ad(8 downto 0), q_b => arama_dout );

  -- alpha unbanked RAM B ($0800-$09FF) -- 512B.  MAME alpha_map: map(0x0800,0x09ff).ram().
  aramb : entity work.dpram generic map (9,8) port map (
    clock_a => clk, wren_a => aramb_we, address_a => a_ad(8 downto 0), data_a => a_dout,
    clock_b => clk, address_b => a_ad(8 downto 0), q_b => aramb_dout );

  -- alpha banked RAM ($0200-$07FF + $0A00-$0FFF), 2 banks via rampg -- 2x 2K.  MAME:
  -- map(0x0200,0x07ff)+map(0x0a00,0x0fff) both .bankrw(rambank); rambank entry = rampg (0/1).
  -- Both windows alias the same rampg-selected bank; a_ad(10:0) (bit11 dropped) makes the two
  -- windows coincide, rampg selects bank.  (Addressing kept as before -- only the decode was wrong.)
  abank : entity work.dpram generic map (12,8) port map (
    clock_a => clk, wren_a => abank_we, address_a => rampg & a_ad(10 downto 0), data_a => a_dout,
    clock_b => clk, address_b => rampg & a_ad(10 downto 0), q_b => abank_dout );

  -- shared beta/comm RAM ($1800-$1FFF) -- 2K, both CPUs (alpha here; beta=banked code, not a CPU)
  comram : entity work.dpram generic map (11,8) port map (
    clock_a => clk, wren_a => comram_we, address_a => a_ad(10 downto 0), data_a => a_dout,
    clock_b => clk, address_b => a_ad(10 downto 0), q_b => comram_dout );

  -- (VG RAM $4000-$4FFF now lives inside avg_majorhavoc -- see the AVG instantiation below.)

  -- gamma RAM ($0000-$07FF) -- 2K
  gram : entity work.dpram generic map (11,8) port map (
    clock_a => clk, wren_a => gram_cs and not g_rw_l and gamma_ena, address_a => g_ad(10 downto 0), data_a => g_dout,
    clock_b => clk, address_b => g_ad(10 downto 0), q_b => gram_dout );

  -- 2804 EEPROM stub: plain RAM ($6000-$61FF) -- 512B  (P4: real NVRAM)
  eeprom : entity work.dpram generic map (9,8) port map (
    clock_a => clk, wren_a => eep_cs and not g_rw_l and gamma_ena, address_a => g_ad(8 downto 0), data_a => g_dout,
    clock_b => clk, address_b => g_ad(8 downto 0), q_b => eep_dout );

  -- =======================================================================
  -- ALPHA address decode + read mux  (MAME alpha_map)
  -- =======================================================================
  -- MAME alpha_map RAM regions (exact): $0000-01FF RAM A, $0200-07FF bank, $0800-09FF RAM B,
  -- $0A00-0FFF bank.  Within $0xxx: a_ad(10:9)=00 -> unbanked (A if a11=0, B if a11=1); else bank.
  arama_cs  <= '1' when a_ad(15 downto 12) = x"0" and a_ad(11 downto 9) = "000" else '0'; -- $0000-01FF
  aramb_cs  <= '1' when a_ad(15 downto 12) = x"0" and a_ad(11 downto 9) = "100" else '0'; -- $0800-09FF
  abank_cs  <= '1' when a_ad(15 downto 12) = x"0" and (a_ad(10) = '1' or a_ad(9) = '1') else '0'; -- $0200-07FF/$0A00-0FFF
  comram_cs <= '1' when a_ad(15 downto 11) = "00011" else '0';                  -- $1800-$1FFF
  avg_cs_l  <= '0' when a_ad(15 downto 14) = "01" else '1';                     -- $4000-$7FFF -> AVG (vecram+vecrom)
  arom_cs   <= '1' when a_ad(15) = '1' or a_ad(15 downto 13) = "001" else '0';  -- $8000-$FFFF | $2000-$3FFF

  arama_we  <= arama_cs  and not a_rw_l and alpha_ena;
  aramb_we  <= aramb_cs  and not a_rw_l and alpha_ena;
  abank_we  <= abank_cs  and not a_rw_l and alpha_ena;
  comram_we <= comram_cs and not a_rw_l and alpha_ena;
  colram_we <= '1' when a_ad(15 downto 5) = "00010100000" and a_rw_l='0' and alpha_ena='1' else '0'; -- $1400-$141F

  a_din <= arama_dout  when arama_cs='1'  else
           aramb_dout  when aramb_cs='1'  else
           abank_dout  when abank_cs='1'  else
           g2a_latch   when a_ad(15 downto 8) = x"10" else                       -- $1000 gamma read port
           -- $1200 IN0 -- CANONICAL mhavoc.cpp INPUT_PORTS(mhavoc), verified vs mamedev master:
           --   b0=avg done(=avg_halted), b1=2.4kHz(=clk24), b2=gamma_xmtd, b3=gamma_rcvd,
           --   b4=diag-step(SVC2,act-low), b5=service1(act-low), b7:6=coin/service mux.
           --   External diag/service/coin supplied via IN0(7:4).
           --   NOTE: this is the REAL mhavoc bit map, NOT the PE a_def.ah layout the prior draft
           --   used.  The comms bits sit at b2/b3 (PE coincidentally also b2/b3) but the SIGNALS
           --   were swapped: real = b2 gamma_xmtd, b3 gamma_rcvd (both active-high, direct).
           (IN0(7 downto 4) & gamma_rcvd & gamma_xmtd & clk24 & avg_halted)
                        when a_ad(15 downto 8) = x"12" else
           comram_dout when comram_cs='1' else
           avg_dout    when avg_cs_l='0'  else                                   -- $4000-$7FFF vecram/vecrom
           arom_dout   when arom_cs='1'   else
           x"00";

  -- alpha I/O writes
  process(clk) begin
    if rising_edge(clk) then
      if reset_h='1' then
        rompg <= "00"; rampg <= '0'; gamma_reset <= '1'; beta_reset <= '1';
        invx <= '0'; invy <= '0'; player_sel <= '0';
      elsif alpha_ena='1' and a_rw_l='0' then
        case a_ad(15 downto 6) is
          when "0001011000" => -- $1600 out_0_w
            invy <= a_dout(7); invx <= a_dout(6); player_sel <= a_dout(5);
            gamma_reset <= not a_dout(3); beta_reset <= not a_dout(2);
          when "0001011101" => rompg <= a_dout(1 downto 0);   -- $1740
          when "0001011110" => rampg <= a_dout(0);            -- $1780
          when others => null;
        end case;
      end if;
    end if;
  end process;

  vggo  <= '1' when a_ad(15 downto 6) = "0001011001" else '0';   -- $1640
  vgrst <= '1' when a_ad(15 downto 6) = "0001011011" else '0';   -- $16C0
  start_frame <= vggo;
  frame_done  <= avg_halted;

  -- =======================================================================
  -- GAMMA address decode + read mux  (MAME gamma_map)
  -- =======================================================================
  gram_cs  <= '1' when g_ad(15 downto 13) = "000" else '0';                     -- $0000-$1FFF (RAM + mirror)
  pokey_cs <= '1' when g_ad(15 downto 11) = "00100" else '0';                   -- $2000-$27FF quad POKEY
  eep_cs   <= '1' when g_ad(15 downto 13) = "011" else '0';                     -- $6000-$7FFF EEPROM (mirror)
  grom_cs  <= '1' when g_ad(15) = '1' else '0';                                 -- $8000-$FFFF ROM (mirror)

  -- Quad POKEY decode (MAME mhavoc quad_pokeyn): select = g_ad(4:3); register =
  -- {g_ad(5), g_ad(2:0)} (the PCB's quirky address-line wiring -> ALLPOT for DSW1 lands at +$20).
  pokey_addr <= g_ad(5) & g_ad(2 downto 0);
  p0_cs_l <= '0' when pokey_cs='1' and g_ad(4 downto 3)="00" else '1';
  p1_cs_l <= '0' when pokey_cs='1' and g_ad(4 downto 3)="01" else '1';
  p2_cs_l <= '0' when pokey_cs='1' and g_ad(4 downto 3)="10" else '1';
  p3_cs_l <= '0' when pokey_cs='1' and g_ad(4 downto 3)="11" else '1';
  pokey_rd <= p0_dout when g_ad(4 downto 3)="00" else
              p1_dout when g_ad(4 downto 3)="01" else
              p2_dout when g_ad(4 downto 3)="10" else p3_dout;

  g_din <= gram_dout  when gram_cs='1' else
           pokey_rd   when pokey_cs='1' else                                    -- $2000-$27FF quad POKEY read
           -- $2800 IN1 -- CANONICAL mhavoc.cpp: b0=alpha_xmtd, b1=alpha_rcvd (both active-high,
           -- direct); b2=TIRDY (unused on base mhavoc -- no TMS5200); b3=unused; b7:4=fire/shield
           -- buttons (P1 b7:6, P2 b5:4).  External buttons supplied via IN1(7:2).
           (IN1(7 downto 2) & alpha_rcvd & alpha_xmtd) when g_ad(15 downto 11) = "00101" else  -- $2800
           a2g_latch  when g_ad(15 downto 11) = "00110" else                    -- $3000 alpha read port
           DIAL       when g_ad(15 downto 11) = "00111" else                    -- $3800 roller
           DSW2       when g_ad(15 downto 11) = "01000" else                    -- $4000 DSW2
           eep_dout   when eep_cs='1' else
           grom_dout  when grom_cs='1' else
           x"00";

  -- =======================================================================
  -- Inter-CPU comms latches + handshake (MAME gamma_w/alpha_w/alpha_r/gamma_r)
  -- =======================================================================
  process(clk) begin
    if rising_edge(clk) then
      if reset_h='1' then
        alpha_xmtd<='0'; gamma_rcvd<='0'; gamma_xmtd<='0'; alpha_rcvd<='0';
        gamma_nmi_pend<='0';
      else
        -- alpha resets gamma ($1600 D3=0) -> clear all 4 handshake flags (MAME out_0_w)
        if alpha_ena='1' and a_rw_l='0' and a_ad(15 downto 6)="0001011000" and a_dout(3)='0' then
          alpha_xmtd<='0'; gamma_rcvd<='0'; gamma_xmtd<='0'; alpha_rcvd<='0';
        end if;
        -- alpha writes $17C0 -> a2g latch, pulse gamma NMI
        if alpha_ena='1' and a_rw_l='0' and a_ad(15 downto 6)="0001011111" then -- $17C0
          a2g_latch <= a_dout; alpha_xmtd<='1'; gamma_rcvd<='0'; gamma_nmi_pend<='1';
        end if;
        -- gamma reads $3000 -> clears
        if gamma_ena='1' and g_rw_l='1' and g_ad(15 downto 11)="00110" then
          gamma_rcvd<='1'; alpha_xmtd<='0';
        end if;
        -- gamma writes $5000 -> g2a latch
        if gamma_ena='1' and g_rw_l='0' and g_ad(15 downto 11)="01010" then     -- $5000
          g2a_latch <= g_dout; gamma_xmtd<='1'; alpha_rcvd<='0';
        end if;
        -- alpha reads $1000 -> clears
        if alpha_ena='1' and a_rw_l='1' and a_ad(15 downto 8)=x"10" then
          alpha_rcvd<='1'; gamma_xmtd<='0';
        end if;
        -- consume the NMI pulse once delivered
        if gamma_ena='1' and gamma_nmi_pend='1' then gamma_nmi_pend<='0'; end if;
      end if;
    end if;
  end process;
  g_nmi_l <= '0' when gamma_nmi_pend='1' else '1';

  -- =======================================================================
  -- IRQ: faithful port of mhavoc.cpp cpu_irq_clock + the two irq_ack handlers.
  --   5 kHz LS161 tick = every 2048 master clocks.
  --   ALPHA: counts while enabled; ASSERT + self-disable when (count & 0x0C)==0x0C
  --          (12 ticks ~= 2.46 ms);  $1700 ack -> clear line, count=0, re-enable.
  --   GAMMA: free-running counter; IRQ line = bit3 (level, 8 ticks hi / 8 lo);
  --          $4000 ack -> count=0 (resets the phase, line follows bit3).
  -- =======================================================================
  process(clk) begin
    if rising_edge(clk) then
      irq5k_tick <= '0';
      if game_ce = '1' then                 -- gate to the slowed game rate (keeps IRQ:CPU ratio)
        if irq5k_div = 2047 then irq5k_div <= 0; irq5k_tick <= '1';
        else irq5k_div <= irq5k_div + 1; end if;
      end if;
    end if;
  end process;

  process(clk)
    variable a_next : std_logic_vector(7 downto 0);
  begin
    if rising_edge(clk) then
      if reset_h='1' then
        a_irqclk <= (others=>'0'); a_irqclk_en <= '1'; alpha_irq_pend <= '0';
        g_irqclk <= (others=>'0');
      else
        if irq5k_tick='1' then
          if a_irqclk_en='1' then
            a_next := a_irqclk + 1;
            a_irqclk <= a_next;
            if a_next(3)='1' and a_next(2)='1' then     -- (count & 0x0C)==0x0C
              alpha_irq_pend <= '1'; a_irqclk_en <= '0';
            end if;
          end if;
          g_irqclk <= g_irqclk + 1;                      -- gamma free-runs
        end if;
        -- alpha IRQ ack: write $1700
        if alpha_ena='1' and a_rw_l='0' and a_ad(15 downto 6)="0001011100" then
          alpha_irq_pend <= '0'; a_irqclk <= (others=>'0'); a_irqclk_en <= '1';
        end if;
        -- gamma IRQ ack: write $4000 (read side = DSW2, handled in g_din mux)
        if gamma_ena='1' and g_rw_l='0' and g_ad(15 downto 11)="01000" then
          g_irqclk <= (others=>'0');
        end if;
      end if;
    end if;
  end process;
  a_irq_l <= not alpha_irq_pend;     -- latched, active-low to T65
  g_irq_l <= not g_irqclk(3);        -- level = bit3 of free-running LS161

  -- 2.4 kHz reference for $1200 D1 (10 MHz / 2 / 2083 ~= 2.4 kHz square)
  process(clk) begin
    if rising_edge(clk) then
      if clk24_ctr = 2082 then clk24_ctr <= 0; clk24 <= not clk24;
      else clk24_ctr <= clk24_ctr + 1; end if;
    end if;
  end process;

  -- =======================================================================
  -- P2: AVG color vector generator
  -- =======================================================================
  avg_ena <= alpha_ena;   -- clk/4 (2.5 MHz); gives the AVG's 1-clock vecram read time to settle

  -- 32-entry colour RAM ($1400-$141F), alpha-written.  AVG presents avg_cidx (5-bit), we return the byte.
  process(clk) begin
    if rising_edge(clk) then
      if colram_we='1' then
        colorram(conv_integer(a_ad(4 downto 0))) <= a_dout;   -- 5-bit index -> 32 distinct entries
      end if;
    end if;
  end process;
  avg_cdata <= x"06" when DIAG_FORCE_COLOR else colorram(conv_integer(avg_cidx));

  myavg: entity work.avg_majorhavoc port map (
    clk          => clk,
    clken        => avg_ena,
    cpu_data_in  => avg_dout,                 -- AVG -> alpha (vecram/vecrom read)
    cpu_data_out => a_dout,                   -- alpha -> AVG (vecram write)
    cpu_addr     => a_ad(13 downto 0),        -- $4000-$7FFF -> AVG $0000-$3FFF
    cpu_cs_l     => avg_cs_l,
    cpu_rw_l     => a_rw_l,
    vgrst        => vgrst,
    vggo         => vggo,
    halted       => avg_halted,
    xout         => analog_x_out,
    yout         => analog_y_out,
    zout         => analog_z_out,
    rgbout       => rgb_out_i,
    color_idx    => avg_cidx,
    color_data   => avg_cdata,
    dbg          => avg_dbg,
    dn_addr      => dn_addr,
    dn_data      => dn_data,
    dn_wr        => dn_wr
  );
  rgb_out  <= rgb_out_i;
  BEAM_ENA <= '1' when rgb_out_i /= "000" else '0';

  -- ---- Quad POKEY (gamma $2000-$203F): 4 chips, audio summed -> analog_sound_out ----
  -- ENA = gamma_ena (1.25 MHz, MHAVOC_CLOCK_1_25M); CLK = master.  Pattern from tempest.vhd's
  -- 2x POKEY.  AUDIO_S=0 (unsigned) is set in the top.
  -- DSW1 (gameplay DIPs) is read by the game through POKEY 0's ALLPOT register, so its 8 pot
  -- pins carry the DSW1 byte (MAME mhavoc: m_pokey[0]->allpot_r).  POKEYs 1-3 have no pots wired.
  p0: entity work.pokey port map (
    ADDR=>pokey_addr, DIN=>g_dout, DOUT=>p0_dout, DOUT_OE_L=>open, RW_L=>g_rw_l,
    CS=>'1', CS_L=>p0_cs_l, AUDIO_OUT=>p0_audio, PIN=>DSW1, ENA=>gamma_ena, CLK=>clk );
  p1: entity work.pokey port map (
    ADDR=>pokey_addr, DIN=>g_dout, DOUT=>p1_dout, DOUT_OE_L=>open, RW_L=>g_rw_l,
    CS=>'1', CS_L=>p1_cs_l, AUDIO_OUT=>p1_audio, PIN=>x"00", ENA=>gamma_ena, CLK=>clk );
  p2: entity work.pokey port map (
    ADDR=>pokey_addr, DIN=>g_dout, DOUT=>p2_dout, DOUT_OE_L=>open, RW_L=>g_rw_l,
    CS=>'1', CS_L=>p2_cs_l, AUDIO_OUT=>p2_audio, PIN=>x"00", ENA=>gamma_ena, CLK=>clk );
  p3: entity work.pokey port map (
    ADDR=>pokey_addr, DIN=>g_dout, DOUT=>p3_dout, DOUT_OE_L=>open, RW_L=>g_rw_l,
    CS=>'1', CS_L=>p3_cs_l, AUDIO_OUT=>p3_audio, PIN=>x"00", ENA=>gamma_ena, CLK=>clk );
  -- sum the 4 (each /4) -> 8-bit unsigned mono
  analog_sound_out <= ("00" & p0_audio(7 downto 2)) + ("00" & p1_audio(7 downto 2))
                    + ("00" & p2_audio(7 downto 2)) + ("00" & p3_audio(7 downto 2));

  -- debug: alpha PC heartbeat-ish + comms flags
  dbg <= a2g_latch & alpha_xmtd & gamma_rcvd & gamma_xmtd & alpha_rcvd & rompg & vggo & avg_halted;

end rtl;
