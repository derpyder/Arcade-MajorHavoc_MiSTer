#!/usr/bin/env python3
"""Render a MAME-equivalent expected output from a vec_*.bin dump using
the Python AVG simulator.  Each visible VCTR produces a line from the
previous point to the current point; Cohen-Sutherland clipping handled
against MAME's visible window.

Usage:  render_mame_expected.py <vec_T*.bin> <out.png>
"""

import sys
try:
    from PIL import Image, ImageDraw
except ImportError:
    print('Need Pillow: pip install Pillow')
    sys.exit(1)

if len(sys.argv) < 3:
    print(__doc__)
    sys.exit(1)
src, dst = sys.argv[1], sys.argv[2]

# Our framebuffer
W, H = 980, 700

# MAME visible window
X_MIN, X_MAX = 0, 250 * 65536
Y_MIN, Y_MAX = 0, 280 * 65536
M_XCENTER = 125 * 65536
M_YCENTER = 140 * 65536

def pal(c):
    return (
        255 if c & 4 else 0,  # R
        255 if c & 2 else 0,  # G
        255 if c & 1 else 0,  # B
    )

def mame_to_fb(mx, my):
    """Map MAME m_xpos / m_ypos to our framebuffer pixel coords using
    starwars.sv's transform.  Mirror's hardware behaviour: our drawer's
    cur_px = (m_xpos - m_xcenter) / pitch; then starwars.sv applies
    1.75x X / 1.25x Y / Y-invert."""
    rel_x = mx - M_XCENTER
    rel_y = my - M_YCENTER       # MAME: m_ypos increases downward
    # PITCH: choose so MAME's visible width fills our framebuffer width.
    # MAME visible halfwidth = 8192000 m_xpos.  We want that to map to
    # fb halfwidth = 980/2 = 490 px.  starwars.sv has effective scale
    # 0.875 (X), so cur_px should be 490/0.875 = 560 for MAME's edge.
    # pitch = 8192000 / 560 = ~14629.  Closest power of 2 = 16384 = 2^14.
    pitch = 1 << 14
    cur_px = rel_x // pitch
    cur_py = -rel_y // pitch     # negate: MAME's downward y maps to fb's downward y after we invert
    # starwars.sv scaling
    x_scaled = (cur_px * 2) - (cur_px >> 2)   # *1.75
    y_scaled = cur_py + (cur_py >> 2)          # *1.25
    new_x = (x_scaled >> 1) + 490
    new_y = 349 - (y_scaled >> 1)              # Y-inverted
    return new_x, new_y


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
                # Cohen-Sutherland accept: line might cross visible window
                x0, y0 = last_xy
                x1, y1 = cur_xy
                accept = not (
                    (x0 < X_MIN and x1 < X_MIN) or
                    (x0 > X_MAX and x1 > X_MAX) or
                    (y0 < Y_MIN and y1 < Y_MIN) or
                    (y0 > Y_MAX and y1 > Y_MAX)
                )
                if accept:
                    lines.append((x0, y0, x1, y1, m_color))
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


with open(src, 'rb') as f:
    mem = f.read()
lines = walk(mem)

img = Image.new('RGB', (W, H), (0, 0, 0))
draw = ImageDraw.Draw(img)
for x0m, y0m, x1m, y1m, col in lines:
    fx0, fy0 = mame_to_fb(x0m, y0m)
    fx1, fy1 = mame_to_fb(x1m, y1m)
    draw.line([fx0, fy0, fx1, fy1], fill=pal(col), width=1)
img.save(dst)
print(f'rendered {len(lines)} lines -> {dst}')
