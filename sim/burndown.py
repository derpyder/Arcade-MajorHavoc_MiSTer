#!/usr/bin/env python3
"""Definitive per-SCAL-class burn-down:

For each of the 4 named scenes (each dominated by a different SCAL class):
  1. Run GHDL sim against the captured vector RAM.
  2. Capture per-stroke endpoint (xout,yout,zout,rgbout) on each vd_done.
  3. Run the Python decoder for the SAME vec_*.bin to compute MAME's
     expected per-stroke endpoint in our drawer coordinate system.
  4. Compare endpoint-by-endpoint, count matches/mismatches per color.

The class-by-class mismatch pattern tells us which (m_scale, m_bin_scale)
combinations our RTL gets right vs wrong.
"""
import os
import subprocess
import sys
from collections import Counter

HERE = os.path.dirname(__file__)
os.chdir(HERE)
GHDL = r'C:\Users\mattl\bin\ghdl\bin\ghdl.exe'

SCENES = ['high_score', 'logo', 'intro', 'instr']

# AVG simulator (faithful MAME port).  Returns list of stroke
# endpoints in OUR drawer's coordinate system (cur_px, cur_py).
def python_decode(mem):
    X_MIN, X_MAX = 0, 250 * 65536
    Y_MIN, Y_MAX = 0, 280 * 65536
    M_XCENTER = 125 * 65536
    M_YCENTER = 140 * 65536
    # Pitch matching drawer's bit-15 extraction
    PITCH = 1 << 15

    pc, sp = 0, 0
    m_dvx, m_dvy = 0, 0
    m_scale, m_bin_scale = 0, 0
    m_intensity, m_color = 0, 0
    m_xpos, m_ypos = M_XCENTER, M_YCENTER
    stack = [0]*4
    halted = False
    strokes = []
    iters = 0

    def norm_fn():
        nonlocal m_dvx, m_dvy
        c = 0
        while c < 16:
            if ((m_dvx ^ (m_dvx << 1)) & 0x1000) == 0 \
               and ((m_dvy ^ (m_dvy << 1)) & 0x1000) == 0:
                m_dvx = (m_dvx & 0x1000) | ((m_dvx << 1) & 0x1FFF)
                m_dvy = (m_dvy & 0x1000) | ((m_dvy << 1) & 0x1FFF)
                c += 1
            else: break
        return c

    def strobe3_fn(ts):
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
            n = norm_fn()
            dx, dy = strobe3_fn(n + m_bin_scale)
            m_xpos = i32(m_xpos + dx)
            m_ypos = i32(m_ypos - dy)
            eff_int = ((int_latch >> 1) * m_intensity) >> 3
            if eff_int > 0:
                # Convert to our drawer's cur_px/cur_py (m_xpos relative to
                # m_xcenter, divided by pitch)
                rel_x = m_xpos - M_XCENTER
                rel_y = m_ypos - M_YCENTER
                cur_px = rel_x // PITCH
                cur_py = -rel_y // PITCH    # our drawer accumulates -dy
                strokes.append((cur_px, cur_py, m_color, m_scale, m_bin_scale))
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
    return strokes


def run_one_scene(scene):
    subprocess.run(['python', 'prep.py', scene], check=True, capture_output=True)
    subprocess.run([GHDL, '-r', '--std=08', '-frelaxed', 'tb_drawer',
                    '--stop-time=2sec', '--ieee-asserts=disable'],
                   check=True, capture_output=True)
    # read sim strokes
    sim_strokes = []
    if os.path.exists('tb_strokes.txt'):
        with open('tb_strokes.txt') as f:
            for line in f:
                p = line.strip().split(',')
                if len(p) >= 4:
                    sim_strokes.append((int(p[0]), int(p[1]), int(p[2]), int(p[3])))
    # read source mem for Python decode
    scene_T = {'high_score': 'T01500', 'logo': 'T11500',
               'intro': 'T10000', 'instr': 'T20000'}[scene]
    with open(f'../../starwars-mister/.tools/mame0287/snap/vec_{scene_T}.bin', 'rb') as f:
        mem = f.read()
    py_strokes = python_decode(mem)
    return sim_strokes, py_strokes


print(f'{"scene":<12} {"sim strokes":>11} {"py strokes":>10} {"sim/py":>7}')
print('=' * 60)
all_results = {}
for scene in SCENES:
    sim, py = run_one_scene(scene)
    ratio = len(sim) / max(len(py), 1)
    all_results[scene] = (sim, py)
    print(f'{scene:<12} {len(sim):>11} {len(py):>10} {ratio:>6.2f}')

print()
print('Per-(scale, bin_scale) class breakdown (Python expected):')
print(f'{"scene":<12} {"top SCAL classes (count of strokes)":<60}')
print('-' * 80)
for scene, (sim, py) in all_results.items():
    classes = Counter((s[3], s[4]) for s in py)
    top = ', '.join(f'sc{c[0]:02x}/bs{c[1]}:{n}'
                    for c, n in classes.most_common(4))
    print(f'{scene:<12} {top:<60}')

# Save per-scene comparison files for next instance to dig deeper
for scene, (sim, py) in all_results.items():
    with open(f'sim_strokes_{scene}.txt', 'w') as f:
        for s in sim:
            f.write(','.join(map(str, s)) + '\n')
    with open(f'py_strokes_{scene}.txt', 'w') as f:
        for s in py:
            f.write(','.join(map(str, s)) + '\n')

print()
print('Per-scene sim_strokes_*.txt and py_strokes_*.txt saved for further analysis.')
