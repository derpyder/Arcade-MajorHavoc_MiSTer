#!/usr/bin/env python3
"""Analyze AVG dump: count lines, dots, and per-color breakdown."""
import sys
from collections import Counter

X_MIN, X_MAX = 0, 250 * 65536
Y_MIN, Y_MAX = 0, 280 * 65536
M_XCENTER = 125 * 65536
M_YCENTER = 140 * 65536


def walk(mem):
    pc, sp = 0, 0
    m_dvx, m_dvy = 0, 0
    m_scale, m_bin_scale = 0, 0
    m_intensity, m_color = 0, 0
    m_xpos, m_ypos = M_XCENTER, M_YCENTER
    last_xy = (m_xpos, m_ypos)
    stack = [0]*4
    halted = False
    lines = []
    iters = 0

    def norm():
        nonlocal m_dvx, m_dvy
        c = 0
        while c < 16:
            if ((m_dvx ^ (m_dvx << 1)) & 0x1000) == 0 \
               and ((m_dvy ^ (m_dvy << 1)) & 0x1000) == 0:
                m_dvx = (m_dvx & 0x1000) | ((m_dvx << 1) & 0x1FFF)
                m_dvy = (m_dvy & 0x1000) | ((m_dvy << 1) & 0x1FFF)
                c += 1
            else:
                break
        return c

    def strobe3(ts):
        sx = ((m_dvx >> 3) ^ 0x200) - 0x200
        sy = ((m_dvy >> 3) ^ 0x200) - 0x200
        shift = max(0, 15 - ts)
        cycles = 1 << shift
        sf = m_scale ^ 0xFF
        return (sx * cycles * sf) // 16, (sy * cycles * sf) // 16

    def i32(v):
        v &= 0xFFFFFFFF
        if v >= 0x80000000: v -= 0x100000000
        return v

    while not halted and iters < 50000:
        iters += 1
        if pc < 0 or pc > 0xFFFF: break
        b0 = mem[pc]
        op = (b0 >> 5) & 7
        dvy12 = (b0 >> 4) & 1
        dvy_high = b0 & 0xF

        if op == 0 or op == 2:
            if op == 0:
                b1, b2, b3 = mem[pc+1], mem[pc+2], mem[pc+3]
                m_dvy = (dvy12 << 12) | (dvy_high << 8) | b1
                int_latch = (b2 >> 4) & 0xF
                m_dvx = (((b2 >> 4) & 1) << 12) | ((b2 & 0xF) << 8) | b3
                pc += 4
            else:
                b1 = mem[pc+1]
                int_latch = (b1 >> 4) & 0xF
                m_dvx = (((b1 >> 4) & 1) << 12) | ((b1 & 0xF) << 8) | (m_dvx & 0xFF)
                m_dvy = (dvy12 << 12) | (dvy_high << 8)
                pc += 2
            n = norm()
            dx, dy = strobe3(n + m_bin_scale)
            m_xpos = i32(m_xpos + dx)
            m_ypos = i32(m_ypos - dy)
            eff_int = ((int_latch >> 1) * m_intensity) >> 3
            cur_xy = (m_xpos, m_ypos)
            if eff_int > 0:
                lines.append((last_xy[0], last_xy[1], cur_xy[0], cur_xy[1], m_color))
            last_xy = cur_xy
        elif op == 1:
            halted = True
        elif op == 3:
            b1 = mem[pc+1]
            if dvy12 == 1:
                m_scale = b1
                m_bin_scale = dvy_high & 7
            else:
                m_intensity = b1
                m_color = dvy_high
            pc += 2
        elif op == 4:
            m_xpos, m_ypos = M_XCENTER, M_YCENTER
            last_xy = (m_xpos, m_ypos)
            pc += 2
        elif op == 5:
            b1 = mem[pc+1]
            stack[sp & 3] = pc + 2
            sp = (sp + 1) & 0xF
            pc = ((dvy12 << 12) | (dvy_high << 8) | b1) << 1
        elif op == 6:
            sp = (sp - 1) & 0xF
            pc = stack[sp & 3]
        elif op == 7:
            b1 = mem[pc+1]
            pc = ((dvy12 << 12) | (dvy_high << 8) | b1) << 1
    return lines


with open(sys.argv[1], 'rb') as f:
    mem = f.read()
lines = walk(mem)
print(f'Total visible-VCTR lines (no Cohen-Sutherland filter): {len(lines)}')
dots = [l for l in lines if l[0] == l[2] and l[1] == l[3]]
print(f'  dots (start==end): {len(dots)}')
print(f'  real lines: {len(lines) - len(dots)}')

# Now check how many are inside MAME's visible window
in_win = 0
crosses = 0
fully_out = 0
for x0, y0, x1, y1, c in lines:
    in0 = X_MIN <= x0 <= X_MAX and Y_MIN <= y0 <= Y_MAX
    in1 = X_MIN <= x1 <= X_MAX and Y_MIN <= y1 <= Y_MAX
    if in0 and in1:
        in_win += 1
    elif (x0 < X_MIN and x1 < X_MIN) or (x0 > X_MAX and x1 > X_MAX) \
         or (y0 < Y_MIN and y1 < Y_MIN) or (y0 > Y_MAX and y1 > Y_MAX):
        fully_out += 1
    else:
        crosses += 1
print(f'\nWith full window analysis:')
print(f'  both endpoints inside window: {in_win}')
print(f'  line crosses window (one in/one out, or both out but crossing): {crosses}')
print(f'  fully outside same side (clipped to nothing): {fully_out}')
print(f'  TOTAL MAME-rendered visible lines: {in_win + crosses}')
print()
print(f'By color:')
for c, n in sorted(Counter(l[4] for l in lines).items()):
    print(f'  c{c}: {n}')
