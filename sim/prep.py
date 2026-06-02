#!/usr/bin/env python3
"""Prepare hex inputs for tb_drawer.

Usage:  prep.py [scene]
  scene = high_score (default), logo, intro, scoring

Reads:
  ../../starwars-mister/.tools/mame0287/snap/vec_T<scene>.bin  (16KB)
  ../../starwars-mister/.tools/mame0287/roms/starwars.zip       (AVG PROM)

Writes:
  sim/vec_mem.hex       (one hex byte per line, 16384 lines)
  sim/avg_prom.hex      (256 hex bytes, one per line)
"""

import os
import sys
import zipfile

# Scene → MAME-captured snapshot timestamp (matches the dump filenames)
SCENES = {
    'high_score':  'T01500',   # png 3:  high-score table (39 c7 dots etc)
    'logo':        'T11500',   # png 23: STAR WARS 3D wireframe (c1-dominant)
    'intro':       'T10000',   # png 20: "COMMAND OF DARTH VADER" text
    'instr':       'T20000',   # png 40: "FLIGHT INSTRUCTIONS" text (red)
}

scene = sys.argv[1] if len(sys.argv) > 1 else 'high_score'
if scene not in SCENES:
    print(f'Unknown scene "{scene}".  Pick one of: {", ".join(SCENES)}')
    sys.exit(1)

HERE = os.path.dirname(__file__)
ROOT = os.path.abspath(os.path.join(HERE, '..'))
MAME = os.path.join(ROOT, '..', 'starwars-mister', '.tools', 'mame0287')

# 1. Vector memory: 16KB from the MAME dump
src_mem = os.path.join(MAME, 'snap', f'vec_{SCENES[scene]}.bin')
with open(src_mem, 'rb') as f:
    mem = f.read()
assert len(mem) == 16384, f'unexpected mem size {len(mem)}'
with open(os.path.join(HERE, 'vec_mem.hex'), 'w') as f:
    for b in mem:
        f.write(f'{b:02x}\n')

# 2. AVG PROM: 256B from starwars.zip
src_zip = os.path.join(MAME, 'roms', 'starwars.zip')
with zipfile.ZipFile(src_zip) as z:
    prom = z.read('136021-109.4b')
assert len(prom) == 256, f'unexpected prom size {len(prom)}'
with open(os.path.join(HERE, 'avg_prom.hex'), 'w') as f:
    for b in prom:
        f.write(f'{b:02x}\n')

print(f'[{scene}/{SCENES[scene]}] wrote vec_mem.hex ({len(mem)} bytes) and avg_prom.hex ({len(prom)} bytes)')
