#!/usr/bin/env python3
"""Scan all captured vec_*.bin dumps for low-visible-stroke vggos.

If SW emits any vggos that produce zero (or near-zero) visible pixel
writes -- i.e., 'state-only' vggos that set up scale/intensity/color
but don't draw -- those will trigger an EOF on an empty draw buffer,
which gets stashed to ready_buf and eventually swaps to display_buf,
producing a momentary BLACK frame on the scaler.

This is the "empty vggo" theory for the constant-but-non-uniform 3-4 Hz
black flash on hardware.  If we see ANY captured frames with 0 visible
strokes, the theory has empirical legs and we can fix it with a
'has_drawn' gate in vector_fb_ddram.sv.

Uses the MAME-faithful decoder so the answer is what MAME would render.
"""
import glob
import os

from avg_starwars_mame import AvgStarwars, load_prom_hex

HERE = os.path.dirname(__file__)
os.chdir(HERE)

prom = load_prom_hex('avg_prom.hex')
decoder = AvgStarwars(prom)

snap_dir = '../../starwars-mister/.tools/mame0287/snap'
vec_files = sorted(glob.glob(os.path.join(snap_dir, 'vec_T*.bin')))

print(f'Scanning {len(vec_files)} vec captures...')
print(f'{"file":<25} {"trace_events":>12} {"clipped_strokes":>15} {"visible_strokes":>15}')
print('-' * 75)

empty_count = 0
near_empty_count = 0
for vf in vec_files:
    with open(vf, 'rb') as f:
        mem = f.read()
    strokes, trace = decoder.run(mem)
    # trace = every vg_add_point_buf call (visible at strobe3 time)
    # strokes = post-vg_flush Cohen-Sutherland clipped
    visible = sum(1 for s in strokes if s[5] > 0)  # intensity > 0

    flag = ''
    if visible == 0:
        empty_count += 1
        flag = '  <- EMPTY'
    elif visible < 10:
        near_empty_count += 1
        flag = '  <- near-empty'

    name = os.path.basename(vf)
    print(f'{name:<25} {len(trace):>12} {len(strokes):>15} {visible:>15}{flag}')

print()
print(f'Empty vggos (0 visible strokes): {empty_count}/{len(vec_files)}')
print(f'Near-empty vggos (<10 visible):  {near_empty_count}/{len(vec_files)}')

if empty_count > 0:
    print()
    print('CONFIRMED: SW emits empty vggos.  These will cause display_buf to')
    print('point at a cleared (all-zero) buffer at the next FB_VBL after the')
    print('empty vggo\'s EOF, producing a momentary BLACK scaler frame.')
elif near_empty_count > 0:
    print()
    print('Found near-empty vggos.  Need to check if any actually produce 0 FB')
    print('writes after the starwars.sv coord transform + bounds clipping.')
