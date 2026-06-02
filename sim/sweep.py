#!/usr/bin/env python3
"""Run the GHDL tb_drawer sim against all named scenes, capture per-scene
pixel write outputs, and compare to MAME's expected stroke counts.

Identifies which scenes still have missing/wrong content after the latest
drawer fixes -- guides where to look for further bugs.
"""

import os
import subprocess
import shutil
from collections import Counter

HERE = os.path.dirname(__file__)
os.chdir(HERE)

GHDL = r'C:\Users\mattl\bin\ghdl\bin\ghdl.exe'
SCENES = ['high_score', 'logo', 'intro', 'instr']

# Expected in-window stroke counts per scene (from Python decode_avg with
# Cohen-Sutherland accept criterion on MAME visible window).
EXPECTED = {
    'high_score': {'c1': 23, 'c2': 6, 'c4': 4, 'c6': 1, 'c7': 39, 'total': 73},
    'logo':       {'c1': 302, 'c2': 12, 'c4': 3, 'c6': 1, 'c7': 44, 'total': 362},
    'intro':      {'c1': 4, 'c2': 5, 'c4': 3, 'c6': 1, 'c7': 47, 'total': 60},
    'instr':      {'c1': 5, 'c2': 0, 'c4': 18, 'c6': 1, 'c7': 47, 'total': 71},
}

results = {}
for scene in SCENES:
    print(f'\n=== {scene} ===')
    # 1. Prep input
    subprocess.run(['python', 'prep.py', scene], check=True)
    # 2. Run sim (compile is incremental since RTL hasn't changed)
    subprocess.run([GHDL, '-r', '--std=08', '-frelaxed', 'tb_drawer',
                    '--stop-time=2sec', '--ieee-asserts=disable'],
                   check=True, capture_output=True)
    # 3. Read pixel writes
    with open('tb_pixel_writes.txt') as f:
        raw = [tuple(map(int, line.strip().split(',')))
               for line in f if line.strip()]
    # Dedupe consecutive same (x, y, c)
    dedup = []
    prev = None
    for p in raw:
        key = (p[0], p[1], p[3])
        if key != prev:
            dedup.append(p)
            prev = key

    cols_dedup = Counter(p[3] for p in dedup)
    cols_raw   = Counter(p[3] for p in raw)
    # Stroke count = clusters separated by pixel jumps > 5
    strokes = 0
    prev = None
    for p in dedup:
        if prev is None or abs(p[0] - prev[0]) > 5 or abs(p[1] - prev[1]) > 5:
            strokes += 1
        prev = p

    results[scene] = {
        'raw': len(raw),
        'dedup': len(dedup),
        'colors_dedup': dict(cols_dedup),
        'colors_raw': dict(cols_raw),
        'strokes': strokes,
    }
    # Save scene-specific copy
    shutil.copy('tb_pixel_writes.txt', f'pixels_{scene}.txt')

print('\n\n========== SUMMARY ==========')
print(f'{"scene":<12} {"strokes":>8} {"colors (dedup)":<40} {"expected colors":<40}')
print('-' * 110)
for scene in SCENES:
    r = results[scene]
    cd = ','.join(f'c{c}:{n}' for c, n in sorted(r['colors_dedup'].items()))
    ex = ','.join(f'c{c[1:]}:{n}' for c, n in sorted(EXPECTED[scene].items()) if c != 'total')
    print(f'{scene:<12} {r["strokes"]:>8} {cd:<40} {ex:<40}')
print()
print(f'Expected stroke totals: {", ".join(f"{s}={EXPECTED[s][chr(39)+chr(116)+chr(111)+chr(116)+chr(97)+chr(108)+chr(39).strip(chr(39))]}" for s in SCENES)}')
