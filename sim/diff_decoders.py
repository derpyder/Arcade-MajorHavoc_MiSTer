#!/usr/bin/env python3
"""Per-VCTR diff: MAME-faithful decoder vs HDL-emulated decoder.

For a given vec_*.bin, run both decoders, align trace events index-by-
index, and emit a CSV with both endpoints + their divergence magnitude.
Sorting by divergence reveals the worst-offender strokes -- those rows
are the HDL bug fingerprint.

Outputs:
  diff_<scene>.csv   -- all VCTRs side by side
  diff_<scene>_worst.csv -- top 30 by xpos+ypos divergence

Usage: diff_decoders.py <vec_*.bin> <scene_label>
"""
import sys

from avg_starwars_mame import AvgStarwars, load_prom_hex
from avg_starwars_hdl import AvgStarwarsHDL

if len(sys.argv) < 3:
    print(__doc__)
    sys.exit(1)
src, label = sys.argv[1], sys.argv[2]

prom = load_prom_hex('avg_prom.hex')
mame_dec = AvgStarwars(prom)
hdl_dec = AvgStarwarsHDL(prom)
with open(src, 'rb') as f:
    mem = f.read()

_, mame_trace = mame_dec.run(mem)
_, hdl_trace = hdl_dec.run(mem)

n = min(len(mame_trace), len(hdl_trace))
print(f'mame trace: {len(mame_trace)} events, hdl trace: {len(hdl_trace)} events')

rows = []
for i in range(n):
    m, h = mame_trace[i], hdl_trace[i]
    dx = h['m_xpos'] - m['m_xpos']
    dy = h['m_ypos'] - m['m_ypos']
    mag = abs(dx) + abs(dy)
    rows.append({
        'i': i,
        'pc': m['pc'],
        'm_op': m['m_op'],
        'm_dvx': m['m_dvx'],
        'm_dvy': m['m_dvy'],
        'm_scale': m['m_scale'],
        'm_bin_scale': m['m_bin_scale'],
        'norm_count': h.get('m_norm_count', -1),
        'm_color': m['m_color'],
        'm_intensity': m['m_intensity'],
        'mame_xpos': m['m_xpos'],
        'hdl_xpos': h['m_xpos'],
        'dx': dx,
        'mame_ypos': m['m_ypos'],
        'hdl_ypos': h['m_ypos'],
        'dy': dy,
        'mag': mag,
    })

cols = ['i', 'pc', 'm_op', 'm_dvx', 'm_dvy', 'm_scale', 'm_bin_scale',
        'norm_count', 'm_color', 'm_intensity',
        'mame_xpos', 'hdl_xpos', 'dx',
        'mame_ypos', 'hdl_ypos', 'dy', 'mag']


def write_csv(path, items):
    with open(path, 'w') as f:
        f.write(','.join(cols) + '\n')
        for r in items:
            f.write(','.join(str(r[c]) for c in cols) + '\n')


write_csv(f'diff_{label}.csv', rows)
worst = sorted(rows, key=lambda r: -r['mag'])[:30]
write_csv(f'diff_{label}_worst.csv', worst)

# Quick summary
total_mag = sum(r['mag'] for r in rows)
exact_match = sum(1 for r in rows if r['mag'] == 0)
print(f'wrote diff_{label}.csv ({len(rows)} VCTRs)')
print(f'wrote diff_{label}_worst.csv (top 30 by divergence)')
print(f'exact-match VCTRs: {exact_match}/{len(rows)}')
print(f'total divergence magnitude: {total_mag}')
print()
print('Top 10 worst divergences:')
print(f'{"idx":>5} {"dvx":>6} {"dvy":>6} {"scl":>4} {"bs":>3} {"nc":>3} '
      f'{"mame_x":>10} {"hdl_x":>10} {"dx":>10} {"dy":>10}')
for r in worst[:10]:
    print(f'{r["i"]:>5} {r["m_dvx"]:>6} {r["m_dvy"]:>6} '
          f'{r["m_scale"]:>4} {r["m_bin_scale"]:>3} {r["norm_count"]:>3} '
          f'{r["mame_xpos"]:>10} {r["hdl_xpos"]:>10} '
          f'{r["dx"]:>10} {r["dy"]:>10}')
