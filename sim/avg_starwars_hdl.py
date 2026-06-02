#!/usr/bin/env python3
"""Python emulation of OUR HDL pipeline (avg.vhd + vector_drawer.vhd).

Mirror to avg_starwars_mame.py.  Same AVG state machine driven by the
same PROM, same opcode parse, same intermediate state -- but the per-VCTR
math in strobe3 uses our drawer's algorithm instead of MAME's
avg_common_strobe3.  This lets us diff per-VCTR against the MAME-faithful
decoder to find the math bug responsible for the 3000% UI text symptom.

If MAME-faithful and HDL-emulated decoders both produce the same trace
for a given vec_*.bin, then the HDL is mathematically correct and any
sim/hardware misrender is downstream (starwars.sv transform, scaler, or
framebuffer).  If they diverge per-VCTR, the divergent rows pinpoint the
HDL bug.

HDL math currently implemented (post-fix avg.vhd / vector_drawer.vhd):

  rel_x = sign_extend(m_dvx_post_norm[12:3], 13)      # >>3 truncation
  rel_y = sign_extend(m_dvy_post_norm[12:3], 13)
  scale_factor = 256 - m_scale                         # 1..256
  total_shift = m_norm_count + m_bin_scale
  vd_scale = 2^(11 - total_shift) if total_shift <= 11 else 0
  delta_x = signed(rel_x) * scale_factor * vd_scale
  delta_y = signed(rel_y) * scale_factor * vd_scale
  xpos += delta_x   # signed 34-bit accumulator
  ypos -= delta_y   # NOTE: HDL drawer ypos accumulates -delta (Y-invert in sw.sv)

xpos/ypos here are RELATIVE to the screen center (different from MAME's
absolute m_xpos/m_ypos which add to M_XCENTER).  For diff against MAME,
convert at trace-emit time:
  hdl_m_xpos_equivalent = M_XCENTER + hdl_xpos
  hdl_m_ypos_equivalent = M_YCENTER - hdl_ypos   # invert to MAME convention
"""

import sys

# Reuse the MAME port's state machine + constants
from avg_starwars_mame import (
    M_XCENTER, M_YCENTER, M_XDAC_XOR, M_YDAC_XOR,
    VGVECTOR, VGCLIP, MAXVECT, load_prom_hex, _i32,
)


# vd_scale table from our HDL after the widening fix (8x bigger than
# pre-fix, valid through total_shift=11).  Mirrors avg.vhd vd_scale_proc.
_VD_SCALE = {
    0:  2048, 1:  1024, 2: 512, 3: 256,
    4:   128, 5:    64, 6:  32, 7:  16,
    8:     8, 9:     4, 10:  2, 11:  1,
}


def _hdl_rel_shift(m_d):
    """Sign-extend m_d[12:3] as 13-bit signed.  Mirrors the HDL line
       vd_rel_x <= std_logic_vector(resize(signed(m_dvx(12 downto 3)), 13))
       which gives signed 10-bit range -512..+511 sign-extended to 13."""
    top10 = (m_d >> 3) & 0x3ff
    if top10 & 0x200:               # bit 9 of the 10-bit slice = sign
        top10 |= ~0x3ff & 0x1fff    # sign-extend to 13 bits
    # Interpret 13-bit two's complement as signed Python int
    if top10 & 0x1000:
        return top10 - 0x2000
    return top10


class AvgStarwarsHDL:
    """Mirror of AvgStarwars but with HDL drawer math in strobe3."""

    def __init__(self, prom_bytes):
        if len(prom_bytes) < 256:
            raise ValueError(f'PROM too short: {len(prom_bytes)} bytes')
        self.m_prom = bytes(prom_bytes[:256])

    # ----- macro helpers -----
    def _OP0(self): return (self.m_op >> 0) & 1
    def _OP1(self): return (self.m_op >> 1) & 1
    def _OP2(self): return (self.m_op >> 2) & 1
    def _ST3(self): return (self.m_state_latch >> 3) & 1

    def _state_addr(self):
        return ((((self.m_state_latch >> 4) ^ 1) << 7)
                | (self.m_op << 4)
                | (self.m_state_latch & 0xf)) & 0xff

    def _update_databus(self):
        # SW reads m_membase + m_pc directly (no ^1 byte swap)
        if 0 <= self.m_pc < len(self.mem):
            self.m_data = self.mem[self.m_pc]
        else:
            self.m_data = 0

    def _vg_add_point_buf(self, x, y, color, intensity):
        if self.m_nvect < MAXVECT:
            self.m_vectbuf.append({
                'status': VGVECTOR, 'x': x, 'y': y,
                'color': color, 'intensity': intensity,
            })
            self.m_nvect += 1

    def _vg_flush(self):
        out = []
        cx0, cy0 = 0, 0
        cx1, cy1 = 0x5000000, 0x5000000
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
                if x0 < cx0:
                    y0 += (cx0 - x0) * (y1 - y0) // (x1 - x0 or 1); x0 = cx0
                elif x0 > cx1:
                    y0 += (cx1 - x0) * (y1 - y0) // (x1 - x0 or 1); x0 = cx1
                if x1 < cx0:
                    y1 += (cx0 - x1) * (y1 - y0) // (x1 - x0 or 1); x1 = cx0
                elif x1 > cx1:
                    y1 += (cx1 - x1) * (y1 - y0) // (x1 - x0 or 1); x1 = cx1
                if (y0 < cy0 and y1 < cy0) or (y0 > cy1 and y1 > cy1):
                    continue
                if y0 < cy0:
                    x0 += (cy0 - y0) * (x1 - x0) // (y1 - y0 or 1); y0 = cy0
                elif y0 > cy1:
                    x0 += (cy1 - y0) * (x1 - x0) // (y1 - y0 or 1); y0 = cy1
                if y1 < cy0:
                    x1 += (cy0 - y1) * (x1 - x0) // (y1 - y0 or 1); y1 = cy0
                elif y1 > cy1:
                    x1 += (cy1 - y1) * (x1 - x0) // (y1 - y0 or 1); y1 = cy1
                out.append((x0, y0, x1, y1, v['color'], v['intensity']))
            elif v['status'] == VGCLIP:
                cx0, cy0 = v['x'], v['y']
                cx1, cy1 = v.get('arg1', 0x5000000), v.get('arg2', 0x5000000)
        self.m_vectbuf = []
        self.m_nvect = 0
        return out

    # ----- avg_device handlers (same as MAME port; the AVG state
    #       machine is identical -- the difference is only in strobe3) -----
    def _handler_0(self):
        self.m_dvy = (self.m_dvy & 0x1f00) | self.m_data
        self.m_pc += 1
        return 0

    def _handler_1(self):
        self.m_dvy12 = (self.m_data >> 4) & 1
        self.m_op = self.m_data >> 5
        self.m_int_latch = 0
        self.m_dvy = (self.m_dvy12 << 12) | ((self.m_data & 0xf) << 8)
        self.m_dvx = 0
        # HDL tracks normalize shifts separately from m_timer
        self.m_norm_count = 0
        self.m_pc += 1
        return 0

    def _handler_2(self):
        self.m_dvx = (self.m_dvx & 0x1f00) | self.m_data
        self.m_pc += 1
        return 0

    def _handler_3(self):
        self.m_int_latch = self.m_data >> 4
        self.m_dvx = (((self.m_int_latch & 1) << 12)
                      | ((self.m_data & 0xf) << 8)
                      | (self.m_dvx & 0xff))
        self.m_pc += 1
        return 0

    def _handler_4(self):
        if self._OP0():
            self.m_stack[self.m_sp & 3] = self.m_pc
        else:
            i = 0
            while (((self.m_dvy ^ (self.m_dvy << 1)) & 0x1000) == 0
                   and ((self.m_dvx ^ (self.m_dvx << 1)) & 0x1000) == 0
                   and i < 16):
                self.m_dvy = (self.m_dvy & 0x1000) | ((self.m_dvy << 1) & 0x1fff)
                self.m_dvx = (self.m_dvx & 0x1000) | ((self.m_dvx << 1) & 0x1fff)
                # Track norm_count for HDL vd_scale lookup
                self.m_timer = (self.m_timer >> 1) & 0x7fff
                self.m_timer |= 0x4000 | (self._OP1() << 7)
                i += 1
            self.m_norm_count = i
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

    def _handler_5(self):
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
                self.m_pc = self.m_dvy << 1
            else:
                self.m_pc = self.m_stack[self.m_sp & 3]
        else:
            if self.m_dvy12:
                self.m_scale = self.m_dvy & 0xff
                self.m_bin_scale = (self.m_dvy >> 8) & 7
        return 0

    def _handler_6_sw(self):
        if (not self._OP2()) and (not self.m_dvy12):
            self.m_intensity = self.m_dvy & 0xff
            self.m_color = (self.m_dvy >> 8) & 0xf
        return self._avg_common_strobe2()

    # ----- THE DIFFERENT PIECE: HDL drawer math in strobe3 -----
    def _avg_common_strobe3_hdl(self):
        cycles = 0
        self.m_halt = self._OP0()
        if (not self._OP0()) and (not self._OP2()):
            # HDL drawer math:
            #   rel = m_dvx >> 3, sign-extended as 10-bit signed
            #   scale_factor = 256 - m_scale (1..256)
            #   total_shift = norm_count + bin_scale
            #   vd_scale lookup table (= 2^(11-total_shift), 0 if >11)
            #   delta = rel * scale_factor * vd_scale
            #
            # SVEC (m_op=2, OP1=1) FIX: MAME's m_timer accumulates the SAME
            # bits as VCTR but is &= 0xff'd in handler_4/handler_5 when
            # OP1=1, and handler_7's cycles uses (0x100 - m_timer&0xff)
            # instead of (0x8000 - m_timer).  Net effect: cycles_svec =
            # 2^(8-total_shift) where VCTR has 2^(15-total_shift) -- SVEC
            # cycles are 128x SMALLER.  Without compensating, SVEC strokes
            # render 128x MAME's size = the 3000% UI text symptom (text
            # glyphs are drawn with SVEC opcodes).  Compensate by bumping
            # effective total_shift by 7 for SVEC -- equivalent to dividing
            # vd_scale by 128.
            rel_x = _hdl_rel_shift(self.m_dvx)
            rel_y = _hdl_rel_shift(self.m_dvy)
            # SCALE_FACTOR FIX (bug #2):
            # MAME uses (m_scale ^ 0xff) = 255 - m_scale, range 0..255.
            # Our HDL uses (256 - m_scale) = 1..256.  Off-by-one
            # produces a 0.4% over-scale per stroke at m_scale=0, which
            # at m_scale=255 becomes infinite ratio (MAME=0 displacement,
            # HDL=1).  Use bit-NOT to match MAME exactly.
            scale_factor = 0xff ^ self.m_scale
            total_shift = self.m_norm_count + self.m_bin_scale
            if self._OP1():        # SVEC path (bug #1)
                total_shift += 7
            # HIGH-TOTAL-SHIFT FIX (bug #3):
            # MAME's cycles formula keeps producing cycles=2^(15-ts) for
            # ts in [12..15] (= 8, 4, 2, 1) -- the strokes still render
            # at sub-pixel scale.  Our HDL vd_scale table truncates to
            # zero above ts=11, dropping these strokes entirely.  The
            # equivalent calculation is to >> the product instead of
            # truncating: for ts>11, delta = rel*sf >> (ts-11).
            if total_shift <= 11:
                vd_scale = _VD_SCALE[total_shift]
                dx = rel_x * scale_factor * vd_scale
                dy = rel_y * scale_factor * vd_scale
            elif total_shift <= 15:
                shift_amt = total_shift - 11
                dx = (rel_x * scale_factor) >> shift_amt
                dy = (rel_y * scale_factor) >> shift_amt
            else:
                dx = 0
                dy = 0
            # HDL drawer xpos accumulator (relative to screen center).
            # We track absolute m_xpos for comparison with MAME by
            # adding to M_XCENTER at trace emission.
            self.m_xpos = _i32(self.m_xpos + dx)
            self.m_ypos = _i32(self.m_ypos - dy)
            # cycles output unused in HDL (no timer-based scheduling)
        if self._OP2():
            self.m_xpos = M_XCENTER
            self.m_ypos = M_YCENTER
            self._vg_add_point_buf(self.m_xpos, self.m_ypos, 0, 0)
        return cycles

    def _handler_7_sw(self):
        # Snapshot per-VCTR inputs BEFORE strobe3 mutates state
        pre_dvx = self.m_dvx
        pre_dvy = self.m_dvy
        pre_scale = self.m_scale
        pre_bs = self.m_bin_scale
        pre_norm = self.m_norm_count
        pre_int = self.m_intensity
        pre_int_latch = self.m_int_latch
        pre_color = self.m_color
        pre_op = self.m_op

        cycles = self._avg_common_strobe3_hdl()

        if (not pre_op & 1) and (not (pre_op >> 2) & 1):
            eff_int = ((pre_int_latch >> 1) * pre_int) >> 3
            self._vg_add_point_buf(
                self.m_xpos, self.m_ypos, pre_color, eff_int,
            )
            self.trace.append({
                'pc': self.m_pc,
                'm_op': pre_op,
                'm_state_latch': self.m_state_latch,
                'm_dvx': pre_dvx,
                'm_dvy': pre_dvy,
                'm_scale': pre_scale,
                'm_bin_scale': pre_bs,
                'm_norm_count': pre_norm,
                'm_color': pre_color,
                'm_intensity': pre_int,
                'm_int_latch': pre_int_latch,
                'm_xpos': self.m_xpos,
                'm_ypos': self.m_ypos,
                'eff_int': eff_int,
            })
        return cycles

    def run(self, mem):
        self.mem = bytes(mem)
        self.m_state_latch = 0
        self.m_bin_scale = 0
        self.m_scale = 0
        self.m_color = 0
        self.m_pc = 0
        self.m_sp = 0
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
        self.m_norm_count = 0
        self.m_vectbuf = []
        self.m_nvect = 0
        self.trace = []
        iters = 0
        MAX_ITERS = 5_000_000
        while iters < MAX_ITERS:
            iters += 1
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
            self.m_state_latch = ((self.m_halt << 4)
                                  | (self.m_state_latch & 0xf))
            if self.m_halt and (self.m_state_latch & 0x10):
                break
        strokes = self._vg_flush()
        return strokes, self.trace


if __name__ == '__main__':
    if len(sys.argv) < 3:
        print('Usage: avg_starwars_hdl.py <vec_*.bin> <out.csv>')
        sys.exit(1)
    src, out_csv = sys.argv[1], sys.argv[2]
    prom = load_prom_hex('avg_prom.hex')
    decoder = AvgStarwarsHDL(prom)
    with open(src, 'rb') as f:
        mem = f.read()
    strokes, trace = decoder.run(mem)
    print(f'{len(strokes)} clipped strokes, {len(trace)} trace events')
    with open(out_csv, 'w') as f:
        f.write('idx,pc,m_op,m_dvx,m_dvy,m_scale,m_bin_scale,m_norm_count,'
                'total_shift,m_color,m_intensity,m_int_latch,m_xpos,m_ypos,'
                'eff_int\n')
        for i, t in enumerate(trace):
            ts = t['m_norm_count'] + t['m_bin_scale']
            f.write(f'{i},{t["pc"]},{t["m_op"]},'
                    f'{t["m_dvx"]},{t["m_dvy"]},{t["m_scale"]},'
                    f'{t["m_bin_scale"]},{t["m_norm_count"]},{ts},'
                    f'{t["m_color"]},{t["m_intensity"]},'
                    f'{t["m_int_latch"]},{t["m_xpos"]},{t["m_ypos"]},'
                    f'{t["eff_int"]}\n')
    print(f'trace -> {out_csv}')
