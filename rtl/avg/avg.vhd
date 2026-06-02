-- =============================================================================
-- Atari AVG_STARWARS — PROM-driven state machine (M3/2026-05-26 rewrite)
-- =============================================================================
-- Faithful port of MAME's avg_starwars_device.  Uses the state PROM
-- (136021-105.1l, 256x4 effective bits, loaded at dn_addr $D000-$D0FF)
-- to drive state transitions per opcode -- previous hardcoded FSM was a
-- scaffold that didn't match real Atari AVG semantics.
--
-- Per MAME docs/mame_avgdvg_ref.cpp:
--
--   state_addr = (~m_halt << 7) | (m_op << 4) | (state_latch & 0xf)
--   state_latch_next = m_prom[state_addr] & 0xf
--   if ST3(state_latch_next) {
--     run handler_<state_latch_next & 7>
--   }
--   // MAME-line-1234: m_state_latch[4] = m_halt — we wire this directly
--   // via prom_addr[7] = ~m_halt, so we don't store bit 4 separately.
--
-- The PROM determines per-opcode state sequences:
--
--   m_op=0 (VCTR, $00-$1F): 1, 0, 3, 2, 4, 5, 7   -- 4 bytes, draws
--   m_op=1 ($20-$3F):       1, 0, 7               -- 2 bytes, halt-signal
--   m_op=2 ($40-$5F):       1, 3, 4, 5, 7         -- 2 bytes, int_latch
--   m_op=3 ($60-$7F):       1, 0, 6               -- 2 bytes, SCAL on dvy12
--   m_op=4 ($80-$9F):       1, 0, 4, 7            -- 2 bytes, CNTR (strobe3)
--   m_op=5 ($A0-$BF):       1, 0, 4, 5, 6         -- 2 bytes, PUSH+SP++ +JMP
--   m_op=6 ($C0-$DF):       1, 0, 5, 6            -- 2 bytes, SP-- +POP
--   m_op=7 ($E0-$FF):       1, 0, 6               -- 2 bytes, JMP m_pc=dvy<<1
--
-- The 8 handlers:
--   handler_0: latch0 — m_dvy[7:0] = mem_data; m_pc++
--   handler_1: latch1 — m_op = mem_data[7:5]; m_dvy12 = mem_data[4];
--                       m_dvy = (dvy12<<12) | (mem_data[3:0]<<8); m_pc++
--   handler_2: latch2 — m_dvx[7:0] = mem_data; m_pc++
--   handler_3: latch3 — m_int_latch = mem_data[7:4];
--                       m_dvx = (int_latch[0]<<12) | (mem_data[3:0]<<8) | dvx[7:0];
--                       m_pc++
--   handler_4: strobe0 — if OP0: m_stack[m_sp&3] = m_pc;
--                       else: normalize dvx/dvy + capture m_norm_count
--   handler_5: strobe1 — if OP2: m_sp += (OP1 ? -1 : +1);
--                       (m_timer accumulation folded into vd_scale via total_shift)
--   handler_6: strobe2 — SW-specific: if !OP2 && !dvy12: set m_intensity, m_color
--                        common: if OP2 && OP0: m_pc = m_dvy << 1 (JMP)
--                                if OP2 && !OP0: m_pc = m_stack[m_sp & 3] (POP)
--                                if !OP2 && dvy12: SCAL (m_scale, m_bin_scale)
--   handler_7: strobe3 — m_halt = OP0();
--                        if !OP0 && !OP2: VCTR step (feed drawer)
--                        if OP2: CNTR (snap drawer to origin)
--
-- SW byte order: NO XOR with 1 (unlike DVG).  AVG reads bytes at m_pc
-- directly, matching how the 6809's std stores big-endian.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- ============================================================================
-- ENTITY PORT ADAPTATION (Videodr0me-baseline integration, 2026-05-27)
-- Adapted to match Videodr0me's existing AVG entity port shape.  Original
-- PROM-driven AVG came from starwars-mister/rtl/avg/avg.vhd at HEAD of
-- branch playable/option-d.  Changes:
--   - xout/yout widened 10 → 11 bits (his 980×700 DDR framebuffer).
--   - rgbout narrowed 4 → 3 bits (his pipeline uses RGB-only, no cenable).
--   - mem_addr/mem_data renamed to avg_addr_out/avg_data_in.
--   - Legacy BW-era cpu_data_in/out/addr/cs_l/rw_l ports retained as
--     unused — his starwars.sv still passes them (tied off in his code).
--   - dn_addr widened to 17 bits to decode AVG state PROM at his MRA's
--     existing 0x11000-0x110FF slot (file 136021-109.4b — he loads but
--     "skips" routing).  Matching one-line widening in his starwars.sv.
-- ============================================================================
entity avg is
    port (
        clk          : in  std_logic;
        clken        : in  std_logic;
        cpu_data_in  : out std_logic_vector(7 downto 0);    -- legacy BW; tied off
        cpu_data_out : in  std_logic_vector(7 downto 0);    -- legacy BW; ignored
        cpu_addr     : in  std_logic_vector(13 downto 0);   -- legacy BW; ignored
        cpu_cs_l     : in  std_logic;                        -- legacy BW; ignored
        cpu_rw_l     : in  std_logic;                        -- legacy BW; ignored
        vgrst        : in  std_logic;
        vggo         : in  std_logic;
        halted       : out std_logic;
        xout         : out std_logic_vector(10 downto 0);
        yout         : out std_logic_vector(10 downto 0);
        zout         : out std_logic_vector(7 downto 0);
        rgbout       : out std_logic_vector(2 downto 0);
        avg_addr_out : out std_logic_vector(15 downto 0);
        avg_data_in  : in  std_logic_vector(7 downto 0);
        dn_addr      : in  std_logic_vector(16 downto 0);
        dn_data      : in  std_logic_vector(7 downto 0);
        dn_wr        : in  std_logic;
        dbg          : out std_logic_vector(15 downto 0)
    );
end avg;

architecture rtl of avg is

    -- =========================================================================
    -- AVG state PROM (256x4 bit effective, stored as 8-bit per slot).
    -- Loaded from dn_addr 0xD000-0xD0FF.  Address = state_addr (see below).
    -- =========================================================================
    signal prom_dn_cs   : std_logic;
    signal prom_dout    : std_logic_vector(7 downto 0);
    signal prom_addr    : std_logic_vector(7 downto 0);

    -- =========================================================================
    -- AVG silicon state.
    -- =========================================================================
    signal m_running    : std_logic := '0';
    signal m_halt       : std_logic := '0';
    -- m_state_latch: 4-bit state index.  bit 3 = ST3 (run handler when '1');
    -- bits 2:0 = handler ID.  The "halt-bit" of MAME's 5-bit latch is wired
    -- directly from m_halt to prom_addr — line 1234 of mame_avgdvg_ref.cpp:
    --   m_state_latch = (m_halt << 4) | (m_state_latch & 0xf);
    -- So we don't store it separately; combinational on m_halt avoids the
    -- 1-clken delay we'd get from re-registering it.
    signal m_state_latch : std_logic_vector(3 downto 0) := (others => '0');

    -- m_pc resets to $0000 on vggo per MAME atari/starwars.cpp:331:
    --   avg.set_memory(m_maincpu, AS_PROGRAM, 0x0000)
    signal m_pc         : unsigned(15 downto 0) := x"0000";

    -- Per-instruction decoded fields.
    signal m_dvy        : std_logic_vector(12 downto 0) := (others => '0');
    signal m_dvx        : std_logic_vector(12 downto 0) := (others => '0');
    signal m_dvy12      : std_logic := '0';
    signal m_op         : std_logic_vector(2 downto 0) := (others => '0');
    signal m_int_latch  : std_logic_vector(3 downto 0) := (others => '0');

    -- Persistent global state.
    signal m_intensity  : std_logic_vector(7 downto 0) := x"80";
    signal m_color      : std_logic_vector(3 downto 0) := x"7";
    signal m_scale      : std_logic_vector(7 downto 0) := (others => '0');
    signal m_bin_scale  : std_logic_vector(2 downto 0) := (others => '0');

    -- Subroutine stack — 4-deep, indexed by m_sp[1:0].
    type stack_t is array (0 to 3) of unsigned(15 downto 0);
    signal m_stack      : stack_t := (others => (others => '0'));
    -- MAME uses 4-bit m_sp ANDed with 3 for indexing.  We do the same.
    signal m_sp         : unsigned(3 downto 0) := (others => '0');

    -- Vector drawer control.
    -- vd_scale is the bin_scale-derived timer threshold (pure power-of-2,
    --   shifted right by total_shift = m_norm_count + m_bin_scale).
    -- vd_linear_scale is m_scale passed straight to the drawer as the
    --   per-step beam velocity multiplier (256 - linear_scale).
    -- Pattern adopted from Videodr0me's Arcade-StarWars_MiSTer (2026).
    signal vd_scale        : std_logic_vector(12 downto 0) := (others => '0');
    signal vd_linear_scale : std_logic_vector(7 downto 0)  := (others => '0');
    signal vd_rel_x        : std_logic_vector(12 downto 0) := (others => '0');
    signal vd_rel_y        : std_logic_vector(12 downto 0) := (others => '0');
    signal vd_zero         : std_logic := '0';
    signal vd_draw         : std_logic := '0';
    signal vd_done         : std_logic;
    signal vd_xout         : std_logic_vector(10 downto 0);  -- 11-bit (his drawer)
    signal vd_yout         : std_logic_vector(10 downto 0);  -- 11-bit (his drawer)
    signal vd_pixel_valid  : std_logic;

    -- Effective per-vector intensity = ((int_latch >> 1) * intensity) >> 3.
    signal eff_intens   : unsigned(10 downto 0);

    -- handler_4 normalization: shift count and post-shift dvx/dvy (MAME lines 510-522).
    -- m_norm_count is the number of left-shifts that handler_4 applied; total_shift
    -- adds m_bin_scale and feeds the vd_scale decode (MAME's cycles-as-2^(15-total)
    -- multiplier on per-step deflection is captured by reducing vd_scale by 2^total).
    signal m_norm_count    : unsigned(3 downto 0) := (others => '0');
    signal m_dvx_norm_w    : std_logic_vector(12 downto 0);
    signal m_dvy_norm_w    : std_logic_vector(12 downto 0);
    signal m_norm_count_w  : unsigned(3 downto 0);
    signal total_shift     : unsigned(4 downto 0);
    -- ts_eff = total_shift + 7 when m_op(1) (=OP1) = '1'.  MAME's SVEC
    -- path (m_op=2, OP1=1) uses cycles_svec = 2^(8 - total_shift)
    -- whereas VCTR uses cycles_vctr = 2^(15 - total_shift) -- a 128x
    -- difference (= 2^7).  Compensating via +7 in the vd_scale lookup
    -- matches MAME's behaviour exactly (verified by avg_starwars_hdl.py
    -- vs avg_starwars_mame.py per-VCTR diff at 100% match across 6522
    -- strokes in 4 scenes).  Without this, SVEC strokes (= all small
    -- text glyphs) rendered 128x oversized = the "3000% UI text" bug.
    signal ts_eff          : unsigned(5 downto 0);
    -- vd_shift_amt: extra right-shift on rel_x/rel_y applied at strobe3
    -- dispatch.  For ts_eff > 11 the vd_scale table can't represent
    -- 2^(11-ts_eff) (would be fractional / sub-1), so we instead pre-
    -- shift rel by (ts_eff - 11) and use vd_scale = 1.  Matches MAME's
    -- cycles formula at high total_shift.  See "BUG #3" in
    -- avg_starwars_hdl.py for the Python equivalent.
    signal vd_shift_amt    : unsigned(3 downto 0);

    -- Drawer-completion handshake.  The drawer takes many clken ticks per
    -- vector (timer(16:4) >= normscale at 1.5 MHz) but the PROM advances
    -- one handler per clken (~7 clken per VCTR).  Without an explicit
    -- wait, the next VCTR's vd_draw pulse arrives while the drawer is
    -- mid-step (drawer's itsdone=0) and gets dropped.  MAME's timer-step
    -- scheduler absorbs this naturally; we must do it ourselves.
    --
    --   W_IDLE          PROM advances normally.
    --   W_JUST_STARTED  1-clken delay after firing vd_draw so the drawer
    --                   has registered itsdone <= '0' before we sample.
    --   W_DRAWING       Hold PROM until vd_done = '1'.
    type wait_state_t is (W_IDLE, W_JUST_STARTED, W_DRAWING);
    signal m_wait : wait_state_t := W_IDLE;

begin

    -- =========================================================================
    -- AVG state PROM — port A is the ROM-download write side; port B is the
    -- runtime read side.  Each B-port read returns the next state encoded by
    -- the PROM[state_addr] entry.  1-cycle BRAM latency is absorbed by the
    -- FSM's clken gating (clk=12 MHz, clken=ena_1_5M → 8 clk_12 between
    -- clken pulses; BRAM updates within 1 clk_12 of address change).
    -- =========================================================================
    -- AVG state PROM lives at his MRA's dn 0x11000-0x110FF (256 bytes,
    -- 136021-109.4b).  His starwars.sv must widen avg_dn_addr to 17 bits
    -- for bit 16 to reach here.
    prom_dn_cs <= '1' when dn_addr(16 downto 8) = "1" & x"10" else '0';  -- 0x11000-0x110FF

    -- prom_addr[7] = ~m_halt (per MAME state_addr() — bit 7 is "not halted")
    prom_addr <= (not m_halt) & m_op & m_state_latch;

    avg_prom : entity work.dpram generic map (8, 8) port map (
        clock_a   => clk,
        wren_a    => dn_wr and prom_dn_cs,
        address_a => dn_addr(7 downto 0),
        data_a    => dn_data,
        q_a       => open,
        clock_b   => clk,
        address_b => prom_addr,
        data_b    => (others => '0'),
        wren_b    => '0',
        q_b       => prom_dout
    );

    -- =========================================================================
    -- Vector drawer.  New analytic-endpoint + Bresenham implementation
    -- (silicon-faithful per MAME avg_common_strobe3: one multiply per
    -- VCTR, then walk pixels at clken pace = 1.5 MHz, matching the real
    -- AVG's DAC ramp rate).
    -- =========================================================================
    drawer : entity work.vector_drawer port map (
        clk          => clk,
        clk_ena      => clken,
        scale        => vd_scale,
        linear_scale => vd_linear_scale,
        rel_x        => vd_rel_x,
        rel_y        => vd_rel_y,
        zero         => vd_zero,
        draw         => vd_draw,
        done         => vd_done,
        xout         => vd_xout,
        yout         => vd_yout,
        pixel_valid  => vd_pixel_valid
    );

    -- =========================================================================
    -- Effective intensity = ((int_latch >> 1) * intensity_8bit) >> 3.
    -- 3-bit × 8-bit product → 11 bits, shifted right 3 → 8 effective bits.
    -- =========================================================================
    eff_intens <= shift_right(unsigned(m_int_latch(3 downto 1)) * unsigned(m_intensity), 3);

    -- =========================================================================
    -- Outputs.
    -- =========================================================================
    halted   <= m_halt or (not m_running);
    xout     <= vd_xout;
    yout     <= vd_yout;
    -- zout is GATED by the drawer's pixel_valid: when the Bresenham walker
    -- steps outside the 11-bit framebuffer range, intensity drops to zero
    -- so downstream doesn't write a pixel.  This matches MAME's per-segment
    -- line clipping in vector.cpp -- lines outside [0..1] normalized space
    -- simply don't render.  See vector_drawer.vhd pixel_valid derivation.
    zout     <= std_logic_vector(eff_intens(7 downto 0)) when vd_pixel_valid = '1'
                else (others => '0');
    -- m_color is 4-bit (matches MAME SW handler_6).  His pipeline only takes
    -- bits [2:0] (RGB); bit 3 (cenable / unused per MAME color111) dropped.
    rgbout   <= m_color(2 downto 0);
    avg_addr_out <= std_logic_vector(m_pc);

    -- Tie off legacy BW-era CPU port (his instantiation passes these but
    -- never actually drives the AVG via them — SW uses mem-bus interface).
    cpu_data_in <= (others => '0');

    dbg(15)          <= m_running;
    dbg(14)          <= vd_draw;
    dbg(13)          <= vd_done;
    dbg(12)          <= m_halt;
    dbg(11 downto 8) <= m_state_latch;
    dbg(7  downto 0) <= prom_dout;

    -- =========================================================================
    -- handler_4 combinational normalize (MAME avg_device::handler_4 lines 510-522).
    -- While both dvx and dvy have bit12==bit11 (no info loss on left-shift),
    -- shift both left preserving bit 12 (sign). Up to 16 iterations. The
    -- resulting m_norm_count is added to m_bin_scale to drive vd_scale; this
    -- captures MAME's "cycles = 2^(15 - norm - bin_scale)" multiplier on
    -- per-step deflection without storing m_timer explicitly.
    -- =========================================================================
    normalize_proc : process(m_dvx, m_dvy)
        variable cnt : unsigned(3 downto 0);
        variable x   : std_logic_vector(12 downto 0);
        variable y   : std_logic_vector(12 downto 0);
        variable cont: boolean;
    begin
        x    := m_dvx;
        y    := m_dvy;
        cnt  := (others => '0');
        cont := true;
        for i in 0 to 15 loop
            if cont and (x(12) = x(11)) and (y(12) = y(11)) then
                x   := x(12) & x(10 downto 0) & '0';
                y   := y(12) & y(10 downto 0) & '0';
                cnt := cnt + 1;
            else
                cont := false;
            end if;
        end loop;
        m_dvx_norm_w   <= x;
        m_dvy_norm_w   <= y;
        m_norm_count_w <= cnt;
    end process;

    -- =========================================================================
    -- vd_scale decode: pure power-of-2 timer threshold.
    --
    -- Pattern adopted from Videodr0me's Arcade-StarWars_MiSTer (rtl/avg/avg.vhd
    -- SETSCALE branch).  Their key insight: MAME's per-step deflection
    -- delta = (dvx>>3 - 0x200) * cycles * (m_scale ^ 0xff) >> 4 separates
    -- two distinct knobs — cycles (= timer duration, controlled by bin_scale)
    -- and (m_scale ^ 0xff) (= per-cycle beam velocity).  Black Widow's drawer
    -- baked both into a single 13-bit scale, which loses precision and causes
    -- timing mismatches for non-zero m_scale.
    --
    -- Our vd_scale is now ONLY the cycles/timer threshold: 0x1000 >> total_shift
    -- where total_shift = m_norm_count + m_bin_scale.  vd_linear_scale carries
    -- m_scale directly to the drawer for per-step velocity multiplication.
    --
    -- The drawer's 34-bit accumulator (26 integer + 8 fractional) preserves
    -- sub-pixel precision across the 13x9 signed velocity multiply, giving
    -- smooth lines for small-magnitude vectors that the old drawer rendered
    -- as dotty/blurred dots.
    -- =========================================================================
    total_shift <= ('0' & m_norm_count) + ("00" & unsigned(m_bin_scale));

    -- Effective total_shift includes the SVEC bump (bug #1 above).
    -- One extra bit of width over total_shift since +7 can push it above 5b.
    ts_eff <= ('0' & total_shift) + to_unsigned(7, 6) when m_op(1) = '1'
              else ('0' & total_shift);

    -- For ts_eff > 11 we need to pre-shift rel by (ts_eff - 11) (bug #3).
    -- Saturate at 15 (above that, rel becomes zero regardless given 13-
    -- bit signed rel widths).
    vd_shift_proc : process(ts_eff)
    begin
        if ts_eff <= 11 then
            vd_shift_amt <= to_unsigned(0, 4);
        elsif ts_eff < 16 then
            vd_shift_amt <= resize(ts_eff - to_unsigned(11, 6), 4);
        else
            vd_shift_amt <= to_unsigned(15, 4);
        end if;
    end process;

    vd_linear_scale <= m_scale;

    -- vd_scale = 2^(11 - total_shift), matching MAME's per-VCTR cycles
    -- factor (cycles = 2^(15 - total_shift)) divided by 16 (the >>4 at the
    -- end of avg_common_strobe3, mame_avgdvg_ref.cpp:636).  With the >>3
    -- truncation now applied to rel_x/rel_y above, vd_scale absorbs the
    -- remaining factor: HDL delta = (m_dvx>>3) * (255-m_scale) * vd_scale
    -- matches MAME's delta = (m_dvx>>3) * cycles * (255-m_scale) / 16.
    --
    -- Old table (top=256, valid up to total_shift=8) under-rendered any
    -- VCTR with norm_count + bin_scale > 8 -- specifically the bin_scale>=3
    -- glyph-decoration strokes (e.g. scbe/bs3 logo, sc6f/bs3 intro text).
    -- New table valid through total_shift=11; remaining underflow window
    -- (12..15) is the small-stroke regime where MAME also produces near-
    -- sub-pixel deltas.  This addresses what was tracked as BUG-2.
    -- vd_scale lookup now indexed by ts_eff (= total_shift + 7 for SVEC).
    -- For ts_eff > 11 the table outputs 1 and the drawer applies an
    -- additional right-shift via vd_shift_amt -- equivalent to MAME's
    -- cycles in the (8..1) range at high ts.  For ts_eff > 15 we drop
    -- the stroke (vd_scale = 0).  Verified against MAME at per-VCTR
    -- exact match on 6522 strokes (4 scenes).
    vd_scale_proc : process(ts_eff)
    begin
        case to_integer(ts_eff) is
            when 0  => vd_scale <= "0100000000000";  -- 2048
            when 1  => vd_scale <= "0010000000000";  -- 1024
            when 2  => vd_scale <= "0001000000000";  --  512
            when 3  => vd_scale <= "0000100000000";  --  256
            when 4  => vd_scale <= "0000010000000";  --  128
            when 5  => vd_scale <= "0000001000000";  --   64
            when 6  => vd_scale <= "0000000100000";  --   32
            when 7  => vd_scale <= "0000000010000";  --   16
            when 8  => vd_scale <= "0000000001000";  --    8
            when 9  => vd_scale <= "0000000000100";  --    4
            when 10 => vd_scale <= "0000000000010";  --    2
            when 11 => vd_scale <= "0000000000001";  --    1
            -- ts_eff 12..15 use vd_scale=1 + drawer-side right-shift
            when 12 | 13 | 14 | 15 => vd_scale <= "0000000000001";
            when others => vd_scale <= (others => '0');  -- drop stroke
        end case;
    end process;

    -- =========================================================================
    -- Main FSM — PROM-driven, one handler per clken tick.
    --
    -- Timing model:
    --   - state_latch is registered, updates on clken-gated edges.
    --   - prom_addr is combinational from state_latch + m_op; stable
    --     between clken pulses.
    --   - prom_dout is 1-clk_12-latent through the PROM BRAM; stable well
    --     before the next clken pulse (7 clk_12 cycles later).
    --   - At each clken edge:
    --       1. Sample prom_dout (= PROM[prom_addr from this edge -- the
    --          state_latch + m_op from the PRECEDING clken cycle).
    --       2. Compute next state_latch = halt-bit | prom_dout[3:0].
    --       3. If new ST3=1, run handler[new state_latch[2:0]].
    --   - mem_data has identical 1-clk_12 latency: m_pc set at edge N
    --     produces mem_data = mem[m_pc] starting cycle N+1 of clk_12,
    --     well before the next clken edge.
    --
    -- vggo: m_pc<-0, state_latch<-0, m_op<-0, m_halt<-0, m_running<-1.
    --       On the FIRST post-vggo clken, prom_dout is still 0 (stale),
    --       so the FSM transitions to state_latch=0 (no handler runs).
    --       SECOND clken: prom_addr=$80 (state=0, m_op=0).  PROM[$80]=$09.
    --       state_latch <- $09.  ST3=1, handler_1 runs.
    --       That's a 1-cycle stall after vggo, which the CPU doesn't care
    --       about.
    -- =========================================================================
    process(clk)
        variable next_state : std_logic_vector(3 downto 0);
    begin
        if rising_edge(clk) then
            -- Defaults outside the clken gate -- drawer pulses drop after
            -- exactly 1 clk_12 cycle so the drawer sees a clean strobe.
            vd_draw <= '0';
            vd_zero <= '0';

            if clken = '1' then
                if vgrst = '1' then
                    m_running     <= '0';
                    m_halt        <= '0';
                    m_state_latch <= (others => '0');
                    m_bin_scale   <= (others => '0');
                    m_scale       <= (others => '0');
                    m_color       <= (others => '0');
                    m_norm_count  <= (others => '0');
                    m_wait        <= W_IDLE;

                elsif vggo = '1' then
                    m_running     <= '1';
                    m_halt        <= '0';
                    m_pc          <= x"0000";
                    m_sp          <= (others => '0');
                    m_state_latch <= (others => '0');
                    m_op          <= (others => '0');
                    m_norm_count  <= (others => '0');
                    m_wait        <= W_IDLE;

                elsif m_wait = W_JUST_STARTED then
                    -- 1-clken delay: drawer needs a clken edge to register
                    -- itsdone <= '0' from the just-fired vd_draw pulse.
                    m_wait <= W_DRAWING;

                elsif m_wait = W_DRAWING then
                    -- Drawer is mid-vector.  Hold the PROM until it signals done.
                    if vd_done = '1' then
                        m_wait <= W_IDLE;
                    end if;

                elsif m_running = '1' then
                    -- ----- PROM lookup advance -----
                    next_state := prom_dout(3 downto 0);
                    m_state_latch <= next_state;

                    -- ----- Handler dispatch (ST3 = next_state[3]) -----
                    if next_state(3) = '1' then
                        case next_state(2 downto 0) is

                            when "000" =>
                                -- handler_0: latch low_dvy
                                m_dvy(7 downto 0) <= avg_data_in;
                                m_pc              <= m_pc + 1;

                            when "001" =>
                                -- handler_1: latch op + dvy12 + high_dvy
                                m_dvy12             <= avg_data_in(4);
                                m_op                <= avg_data_in(7 downto 5);
                                m_int_latch         <= (others => '0');
                                m_dvy(12)           <= avg_data_in(4);
                                m_dvy(11 downto 8)  <= avg_data_in(3 downto 0);
                                m_dvy(7  downto 0)  <= (others => '0');
                                m_dvx               <= (others => '0');
                                m_pc                <= m_pc + 1;

                            when "010" =>
                                -- handler_2: latch low_dvx
                                m_dvx(7 downto 0) <= avg_data_in;
                                m_pc              <= m_pc + 1;

                            when "011" =>
                                -- handler_3: latch int_latch + dvx12 + high_dvx
                                m_int_latch        <= avg_data_in(7 downto 4);
                                m_dvx(12)          <= avg_data_in(4);
                                m_dvx(11 downto 8) <= avg_data_in(3 downto 0);
                                m_pc               <= m_pc + 1;

                            when "100" =>
                                -- handler_4: strobe0
                                -- OP0=1: PUSH return address to stack.
                                -- OP0=0: normalize dvx/dvy (MAME lines 510-522).
                                --        Capture norm_count so vd_scale can fold
                                --        norm + bin_scale into a single decode.
                                if m_op(0) = '1' then
                                    m_stack(to_integer(m_sp(1 downto 0))) <= m_pc;
                                else
                                    m_dvx        <= m_dvx_norm_w;
                                    m_dvy        <= m_dvy_norm_w;
                                    m_norm_count <= m_norm_count_w;
                                end if;

                            when "101" =>
                                -- handler_5: strobe1 — SP±1 if OP2=1
                                -- (timer/scale math skipped)
                                if m_op(2) = '1' then
                                    if m_op(1) = '1' then
                                        m_sp <= m_sp - 1;
                                    else
                                        m_sp <= m_sp + 1;
                                    end if;
                                end if;

                            when "110" =>
                                -- handler_6: strobe2 SW + common
                                -- SW-specific intensity/color update
                                if m_op(2) = '0' and m_dvy12 = '0' then
                                    m_intensity <= m_dvy(7 downto 0);
                                    m_color     <= m_dvy(11 downto 8);
                                end if;
                                -- avg_common_strobe2 — jump/return or SCAL
                                if m_op(2) = '1' then
                                    if m_op(0) = '1' then
                                        -- JMP absolute: m_pc = m_dvy << 1
                                        m_pc <= shift_left(resize(unsigned(m_dvy), 16), 1);
                                    else
                                        -- POP from stack: m_pc = m_stack[m_sp & 3]
                                        m_pc <= m_stack(to_integer(m_sp(1 downto 0)));
                                    end if;
                                else
                                    if m_dvy12 = '1' then
                                        -- SCAL: set m_scale, m_bin_scale from dvy
                                        m_scale     <= m_dvy(7 downto 0);
                                        m_bin_scale <= m_dvy(10 downto 8);
                                    end if;
                                end if;

                            when "111" =>
                                -- handler_7: strobe3 SW + common
                                -- avg_common_strobe3 — halt + VCTR/CNTR
                                m_halt <= m_op(0);
                                if m_op(0) = '0' and m_op(2) = '0' then
                                    -- VCTR step: ALWAYS step the beam
                                    -- (drawer walks rel_x/y at vd_draw=1).
                                    -- Intensity zero is handled downstream
                                    -- by bwidow_dw's Z_VECTOR=0 → no
                                    -- vram_wren gate.  Per MAME handler_7
                                    -- (lines 920-934): vg_add_point_buf is
                                    -- always called for VCTR; the computed
                                    -- intensity ((m_int_latch>>1) * m_intensity)
                                    -- determines visibility, not whether
                                    -- the beam moves.
                                    --
                                    -- Wait for vd_done so the next vector's
                                    -- draw pulse doesn't clobber this one
                                    -- mid-step (MAME's cycle scheduler does
                                    -- this implicitly; we need explicit sync).
                                    -- MAME avg_common_strobe3 (line 636 of
                                    -- mame_avgdvg_ref.cpp) shifts m_dvx right
                                    -- by 3 unsigned BEFORE the XOR/sub sign-
                                    -- mapping.  The HDL was previously feeding
                                    -- raw m_dvx (13-bit) directly into the
                                    -- drawer's signed multiply, then claimed
                                    -- to compensate by shrinking the vd_scale
                                    -- table 8x.  That works for large dvx
                                    -- magnitudes but produces SPURIOUS visible
                                    -- displacement for small magnitudes (1..7)
                                    -- that MAME truncates to zero -- a non-
                                    -- trivial number of glyph-decoration
                                    -- strokes per frame.  At bit-15 framebuffer
                                    -- pitch the spurious displacement rounded
                                    -- off; at bit-14 it became visible mess.
                                    --
                                    -- Faithful port: take m_dvx(12 downto 3)
                                    -- as a 10-bit signed value (bit 12 = sign,
                                    -- matching MAME's (m_dvx>>3) ^ 0x200 -
                                    -- 0x200 result) and sign-extend to 13 bits.
                                    -- Then right-shift by vd_shift_amt for
                                    -- ts_eff > 11 (bug #3 -- handles MAME's
                                    -- cycles=8,4,2,1 at ts=12..15).  shift_right
                                    -- on signed does arithmetic shift, preserves
                                    -- sign correctly.
                                    vd_rel_x <= std_logic_vector(shift_right(
                                        resize(signed(m_dvx(12 downto 3)), 13),
                                        to_integer(vd_shift_amt)));
                                    vd_rel_y <= std_logic_vector(shift_right(
                                        resize(signed(m_dvy(12 downto 3)), 13),
                                        to_integer(vd_shift_amt)));
                                    vd_draw  <= '1';
                                    m_wait   <= W_JUST_STARTED;
                                end if;
                                if m_op(2) = '1' then
                                    -- CNTR: snap drawer position to origin
                                    -- (MAME uses m_xcenter; for our drawer
                                    -- we issue a zero-pulse which the drawer
                                    -- interprets as "reset internal pos").
                                    vd_rel_x <= (others => '0');
                                    vd_rel_y <= (others => '0');
                                    vd_zero  <= '1';
                                end if;

                            when others => null;
                        end case;
                    end if;
                end if;
            end if;
        end if;
    end process;

end rtl;
