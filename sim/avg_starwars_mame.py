#!/usr/bin/env python3
"""MAME-faithful Atari AVG simulator for Star Wars (avg_starwars_device).

Direct port of docs/mame_avgdvg_ref.cpp avgdvg_device_base + avg_device +
avg_starwars_device.  The previous one-shot opcode-dispatch decoder
(render_mame_expected.py's walk()) was a simplification of the real
PROM-stepped state machine -- consistent with MAME for some opcode
sequences but quietly wrong for others.  Visible symptoms:

  - vec_T08000..T09500 (the full STAR WARS logo frames) rendered without
    the S of "STAR" and the S of "WARS" -- present in every MAME 0287
    screenshot (0017..0020.png) but missing from the simplified port.
  - All corner HUD elements (SCORE 00 top-left, GAME OVER 1 COIN 1 PLAY
    top-center, 0 WAVE top-right) missing.
  - Starfield mostly missing.
  - Stroke count came close (287 lines vs MAME's visible ~250-300) so it
    wasn't dropping whole categories -- it was computing wrong endpoints
    or hitting wrong clip decisions for specific stroke sequences.

This port runs the state machine literally:

  while cycles < VGSLICE:
      m_state_latch = (m_state_latch & 0x10) | (m_prom[state_addr()] & 0xf)
      if ST3():
          update_databus()
          dispatch handler_X based on m_state_latch & 7
      if m_halt and not (m_state_latch & 0x10):
          schedule halt visibility
      m_state_latch = (m_halt << 4) | (m_state_latch & 0xf)
      cycles += 8

State address generation, handler dispatch, and PROM table all come from
the real silicon -- the PROM is loaded from avg_prom.hex (which prep.py
extracts from starwars.zip).

Star Wars-specific overrides from avg_starwars_device:
  - update_databus(): reads m_membase + m_pc directly (no XOR 1 byte
    swap the base AVG uses; SW slapstic banking handles ordering).
  - handler_6 (starwars_strobe2): m_intensity is 8 bits from low byte
    of m_dvy, m_color is 4 bits from bits 11:8.  Base AVG uses 4-bit
    intensity from a different field.  This difference likely explains
    most of the visible glyph dropouts -- the simplified decoder mapped
    intensity wrong, so eff_int's > 0 visibility check came out wrong
    for certain stroke classes.
  - handler_7 (starwars_strobe3): emits vg_add_point_buf with intensity
    = (m_int_latch >> 1) * m_intensity >> 3.  Multiplicative, unlike
    base AVG's ternary.

Usage:
  decoder = AvgStarwars(prom_hex='avg_prom.hex')
  strokes, trace = decoder.run(vec_mem_bytes)
  # strokes: list of (x0, y0, x1, y1, color, intensity) tuples after
  #          vg_flush's Cohen-Sutherland clipping
  # trace:   per-vg_add_point_buf trace dict, keys:
  #          pc, m_op, m_state_latch, m_dvx, m_dvy, m_scale, m_bin_scale,
  #          m_color, m_intensity, m_int_latch, m_xpos, m_ypos, eff_int
"""

# -----------------------------------------------------------------
# Constants
# -----------------------------------------------------------------
VGSLICE  = 10000
VGVECTOR = 0
VGCLIP   = 1
MAXVECT  = 10000      # MAME uses 1024; we go higher to be safe with traces

# Star Wars screen geometry (from MAME avg_starwars_device construction)
M_XCENTER = 125 * 65536
M_YCENTER = 140 * 65536
M_XMIN, M_XMAX = 0, 250 * 65536
M_YMIN, M_YMAX = 0, 280 * 65536

# DAC XOR for AVG default (0x200) -- matches both base avg_device and SW
M_XDAC_XOR = 0x200
M_YDAC_XOR = 0x200


def _i32(v):
    v &= 0xFFFFFFFF
    if v >= 0x80000000:
        v -= 0x100000000
    return v


class AvgStarwars:
    def __init__(self, prom_bytes):
        """prom_bytes: 256-byte AVG state PROM (low nibble used)."""
        if len(prom_bytes) < 256:
            raise ValueError(f'PROM too short: {len(prom_bytes)} bytes')
        self.m_prom = bytes(prom_bytes[:256])

    # ----- macro helpers (OP0/OP1/OP2/ST3) -----
    def _OP0(self): return (self.m_op >> 0) & 1
    def _OP1(self): return (self.m_op >> 1) & 1
    def _OP2(self): return (self.m_op >> 2) & 1
    def _ST3(self): return (self.m_state_latch >> 3) & 1

    # ----- state machine address generation (avg_device::state_addr) -----
    def _state_addr(self):
        return ((((self.m_state_latch >> 4) ^ 1) << 7)
                | (self.m_op << 4)
                | (self.m_state_latch & 0xf)) & 0xff

    # ----- SW databus read (avg_starwars_device::update_databus) -----
    def _update_databus(self):
        # SW reads m_membase + m_pc directly (no ^1 byte swap).
        # m_membase = 0 for our captured vec dump.
        if 0 <= self.m_pc < len(self.mem):
            self.m_data = self.mem[self.m_pc]
        else:
            self.m_data = 0

    # ----- vg buffer mgmt (avgdvg_device_base) -----
    def _vg_add_point_buf(self, x, y, color, intensity):
        if self.m_nvect < MAXVECT:
            self.m_vectbuf.append({
                'status': VGVECTOR, 'x': x, 'y': y,
                'color': color, 'intensity': intensity,
            })
            self.m_nvect += 1

    def _vg_flush(self):
        """Cohen-Sutherland-clip m_vectbuf and emit (x0,y0,x1,y1,col,int)."""
        out = []
        # Default clip window (avgdvg_device_base::vg_flush)
        cx0, cy0 = 0, 0
        cx1, cy1 = 0x5000000, 0x5000000

        # Find first non-CLIP entry as starting endpoint
        i = 0
        while i < self.m_nvect and self.m_vectbuf[i]['status'] == VGCLIP:
            i += 1
        if i >= self.m_nvect:
            self.m_vectbuf = []
            self.m_nvect = 0
            return out
        xs, ys = self.m_vectbuf[i]['x'], self.m_vectbuf[i]['y']

        for i in range(self.m_nvect):
            v = self.m_vectbuf[i]
            if v['status'] == VGVECTOR:
                xe, ye = v['x'], v['y']
                x0, y0, x1, y1 = xs, ys, xe, ye
                xs, ys = xe, ye

                if (x0 < cx0 and x1 < cx0) or (x0 > cx1 and x1 > cx1):
                    continue
                # Clip X
                if x0 < cx0:
                    y0 += (cx0 - x0) * (y1 - y0) // (x1 - x0 or 1)
                    x0 = cx0
                elif x0 > cx1:
                    y0 += (cx1 - x0) * (y1 - y0) // (x1 - x0 or 1)
                    x0 = cx1
                if x1 < cx0:
                    y1 += (cx0 - x1) * (y1 - y0) // (x1 - x0 or 1)
                    x1 = cx0
                elif x1 > cx1:
                    y1 += (cx1 - x1) * (y1 - y0) // (x1 - x0 or 1)
                    x1 = cx1

                if (y0 < cy0 and y1 < cy0) or (y0 > cy1 and y1 > cy1):
                    continue
                # Clip Y
                if y0 < cy0:
                    x0 += (cy0 - y0) * (x1 - x0) // (y1 - y0 or 1)
                    y0 = cy0
                elif y0 > cy1:
                    x0 += (cy1 - y0) * (x1 - x0) // (y1 - y0 or 1)
                    y0 = cy1
                if y1 < cy0:
                    x1 += (cy0 - y1) * (x1 - x0) // (y1 - y0 or 1)
                    y1 = cy0
                elif y1 > cy1:
                    x1 += (cy1 - y1) * (x1 - x0) // (y1 - y0 or 1)
                    y1 = cy1

                out.append((x0, y0, x1, y1, v['color'], v['intensity']))
            elif v['status'] == VGCLIP:
                cx0, cy0 = v['x'], v['y']
                cx1, cy1 = v.get('arg1', 0x5000000), v.get('arg2', 0x5000000)

        self.m_vectbuf = []
        self.m_nvect = 0
        return out

    # ----- avg_device handlers -----
    def _handler_0(self):  # avg_latch0
        self.m_dvy = (self.m_dvy & 0x1f00) | self.m_data
        self.m_pc += 1
        return 0

    def _handler_1(self):  # avg_latch1
        self.m_dvy12 = (self.m_data >> 4) & 1
        self.m_op = self.m_data >> 5  # 3-bit op from top
        self.m_int_latch = 0
        self.m_dvy = (self.m_dvy12 << 12) | ((self.m_data & 0xf) << 8)
        self.m_dvx = 0
        self.m_pc += 1
        return 0

    def _handler_2(self):  # avg_latch2
        self.m_dvx = (self.m_dvx & 0x1f00) | self.m_data
        self.m_pc += 1
        return 0

    def _handler_3(self):  # avg_latch3
        self.m_int_latch = self.m_data >> 4
        self.m_dvx = (((self.m_int_latch & 1) << 12)
                      | ((self.m_data & 0xf) << 8)
                      | (self.m_dvx & 0xff))
        self.m_pc += 1
        return 0

    def _handler_4(self):  # avg_strobe0
        if self._OP0():
            self.m_stack[self.m_sp & 3] = self.m_pc
        else:
            # Normalize: shift dvx/dvy until top bits differ (or 16 cycles).
            # Also shifts m_timer in tandem.
            i = 0
            while (((self.m_dvy ^ (self.m_dvy << 1)) & 0x1000) == 0
                   and ((self.m_dvx ^ (self.m_dvx << 1)) & 0x1000) == 0
                   and i < 16):
                self.m_dvy = (self.m_dvy & 0x1000) | ((self.m_dvy << 1) & 0x1fff)
                self.m_dvx = (self.m_dvx & 0x1000) | ((self.m_dvx << 1) & 0x1fff)
                self.m_timer = (self.m_timer >> 1) & 0x7fff
                self.m_timer |= 0x4000 | (self._OP1() << 7)
                i += 1
            if self._OP1():
                self.m_timer &= 0xff
        return 0

    def _avg_common_strobe1(self):
        if self._OP2():
            if self._OP1():
                self.m_sp = (self.m_sp - 1) & 0xf
            else:
                self.m_sp = (self.m_sp + 1) & 0xf
        return 0

    def _handler_5(self):  # avg_strobe1
        if not self._OP2():
            for _ in range(self.m_bin_scale):
                self.m_timer = (self.m_timer >> 1) & 0x7fff
                self.m_timer |= 0x4000 | (self._OP1() << 7)
            if self._OP1():
                self.m_timer &= 0xff
        return self._avg_common_strobe1()

    def _avg_common_strobe2(self):
        if self._OP2():
            if self._OP0():
                # JSR/JMP target
                self.m_pc = self.m_dvy << 1
                # Tempest/Quantum special-case skipped (SW doesn't loop)
            else:
                # RTS
                self.m_pc = self.m_stack[self.m_sp & 3]
        else:
            if self.m_dvy12:
                self.m_scale = self.m_dvy & 0xff
                self.m_bin_scale = (self.m_dvy >> 8) & 7
        return 0

    # ----- SW-specific overrides -----
    def _handler_6_sw(self):  # avg_starwars_device::starwars_strobe2
        if (not self._OP2()) and (not self.m_dvy12):
            self.m_intensity = self.m_dvy & 0xff           # 8-bit !!
            self.m_color = (self.m_dvy >> 8) & 0xf
        return self._avg_common_strobe2()

    def _avg_common_strobe3(self):
        cycles = 0
        self.m_halt = self._OP0()
        if (not self._OP0()) and (not self._OP2()):
            if self._OP1():
                cycles = 0x100 - (self.m_timer & 0xff)
            else:
                cycles = 0x8000 - self.m_timer
            self.m_timer = 0
            # NOTE: precedence trap.  In Python `a + b >> 4` = `(a+b)>>4`
            # because `+` binds tighter than `>>`.  MAME's C++ code reads
            # the same way (C++ also has `+` > `>>`) -- the cast to int
            # outer shift applies to the whole sum.  Match MAME literally:
            # treat the entire delta expression as the operand of >> 4,
            # then add to m_xpos.  This is the corrected reading; the
            # earlier port omitted the inner parens and divided m_xpos
            # itself by 16 each VCTR, drifting it to MAME (0,0) within
            # a few strokes -- visible as a starburst from the top-left.
            dx = (((((self.m_dvx >> 3) ^ M_XDAC_XOR) - 0x200)
                   * cycles * (self.m_scale ^ 0xff)) >> 4)
            dy = (((((self.m_dvy >> 3) ^ M_YDAC_XOR) - 0x200)
                   * cycles * (self.m_scale ^ 0xff)) >> 4)
            self.m_xpos = _i32(self.m_xpos + dx)
            self.m_ypos = _i32(self.m_ypos - dy)
        if self._OP2():
            cycles = 0x8000 - self.m_timer
            self.m_timer = 0
            self.m_xpos = M_XCENTER
            self.m_ypos = M_YCENTER
            self._vg_add_point_buf(self.m_xpos, self.m_ypos, 0, 0)
        return cycles

    def _handler_7_sw(self):  # avg_starwars_device::starwars_strobe3
        cycles = self._avg_common_strobe3()
        if (not self._OP0()) and (not self._OP2()):
            eff_int = ((self.m_int_latch >> 1) * self.m_intensity) >> 3
            self._vg_add_point_buf(
                self.m_xpos, self.m_ypos,
                self.m_color, eff_int,
            )
            # Record trace at the moment a visible point is emitted
            self.trace.append({
                'pc': self.m_pc,
                'm_op': self.m_op,
                'm_state_latch': self.m_state_latch,
                'm_dvx': self.m_dvx,
                'm_dvy': self.m_dvy,
                'm_scale': self.m_scale,
                'm_bin_scale': self.m_bin_scale,
                'm_color': self.m_color,
                'm_intensity': self.m_intensity,
                'm_int_latch': self.m_int_latch,
                'm_xpos': self.m_xpos,
                'm_ypos': self.m_ypos,
                'eff_int': eff_int,
            })
        return cycles

    # ----- one vggo -----
    def run(self, mem):
        """Run one vggo on `mem` (bytes); return (strokes, trace).

        strokes: list of (x0,y0,x1,y1,color,intensity), post-clip.
        trace:   list of per-vg_add_point_buf state dicts (visible only).
        """
        self.mem = bytes(mem)
        # avg_device.vgrst
        self.m_state_latch = 0
        self.m_bin_scale = 0
        self.m_scale = 0
        self.m_color = 0
        # avg_device.vggo
        self.m_pc = 0
        self.m_sp = 0
        # Everything else
        self.m_dvx = 0
        self.m_dvy = 0
        self.m_dvy12 = 0
        self.m_op = 0
        self.m_int_latch = 0
        self.m_intensity = 0
        self.m_xpos = M_XCENTER
        self.m_ypos = M_YCENTER
        self.m_xcenter = M_XCENTER
        self.m_ycenter = M_YCENTER
        self.m_halt = 0
        self.m_timer = 0
        self.m_data = 0
        self.m_stack = [0, 0, 0, 0]
        self.m_vectbuf = []
        self.m_nvect = 0
        self.trace = []

        # avgdvg_device_base::run_state_machine, but loop until m_halt
        # (we don't model 6809 timing here -- just drain to HALT).
        iters = 0
        MAX_ITERS = 5_000_000
        while iters < MAX_ITERS:
            iters += 1
            # next state from PROM
            self.m_state_latch = ((self.m_state_latch & 0x10)
                                  | (self.m_prom[self._state_addr()] & 0xf))

            if self._ST3():
                self._update_databus()
                sel = self.m_state_latch & 7
                if   sel == 0: self._handler_0()
                elif sel == 1: self._handler_1()
                elif sel == 2: self._handler_2()
                elif sel == 3: self._handler_3()
                elif sel == 4: self._handler_4()
                elif sel == 5: self._handler_5()
                elif sel == 6: self._handler_6_sw()
                elif sel == 7: self._handler_7_sw()

            # Halt-visibility latch (bit 4 of m_state_latch)
            new_halt_bit = self.m_halt << 4
            self.m_state_latch = new_halt_bit | (self.m_state_latch & 0xf)

            # Real silicon delays halt by ~cycles; we simply stop when the
            # halt bit gets latched in.  This matches what tb_drawer does
            # (it stops when halted='1' rises).
            if self.m_halt and (self.m_state_latch & 0x10):
                break

        strokes = self._vg_flush()
        return strokes, self.trace


# -----------------------------------------------------------------
# Convenience: load PROM from the hex file prep.py writes
# -----------------------------------------------------------------
def load_prom_hex(path='avg_prom.hex'):
    bytes_out = bytearray()
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            bytes_out.append(int(line, 16))
    return bytes(bytes_out)


if __name__ == '__main__':
    import sys
    if len(sys.argv) < 3:
        print('Usage: avg_starwars_mame.py <vec_*.bin> <out.csv>')
        sys.exit(1)
    src, out_csv = sys.argv[1], sys.argv[2]
    prom = load_prom_hex('avg_prom.hex')
    decoder = AvgStarwars(prom)
    with open(src, 'rb') as f:
        mem = f.read()
    strokes, trace = decoder.run(mem)
    print(f'{len(strokes)} clipped strokes, {len(trace)} trace events')
    with open(out_csv, 'w') as f:
        f.write('idx,pc,m_op,m_state_latch,m_dvx,m_dvy,m_scale,m_bin_scale,'
                'm_color,m_intensity,m_int_latch,m_xpos,m_ypos,eff_int\n')
        for i, t in enumerate(trace):
            f.write(f'{i},{t["pc"]},{t["m_op"]},{t["m_state_latch"]},'
                    f'{t["m_dvx"]},{t["m_dvy"]},{t["m_scale"]},'
                    f'{t["m_bin_scale"]},{t["m_color"]},{t["m_intensity"]},'
                    f'{t["m_int_latch"]},{t["m_xpos"]},{t["m_ypos"]},'
                    f'{t["eff_int"]}\n')
    print(f'trace -> {out_csv}')
