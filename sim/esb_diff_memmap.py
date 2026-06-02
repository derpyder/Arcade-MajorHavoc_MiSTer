#!/usr/bin/env python3
"""Diff our HDL ESB memory map vs MAME's actual ESB CPU view.

MAME ground truth: snap/esb_cpu_full.bin = a dump of the esb maincpu
program space $0000-$FFFF after 3s of running (esb_dump.cmd).

We compare region by region.  The non-banked ESB main ROM ($6000-$7FFF)
must match exactly if our esb_main_rom mapping is right.  The bank2
region ($A000-$FFFF) and slapstic region ($8000-$9FFF) are banked; we
report matches per candidate bank so we can tell which bank MAME had
active and whether ANY of our banks produce MAME's bytes.

This is the ESB analog of diff_decoders.py -- MAME is ground truth, our
model is the candidate, the first mismatching region is the bug.
"""
import os
from esb_memmap import EsbMemMap

HERE = os.path.dirname(__file__)
MAME_DUMP = os.path.join(HERE, '../../starwars-mister/.tools/mame0287/snap/esb_cpu_full.bin')
ZIP = os.path.join(HERE, '../../starwars-empirestrikesback/esb.zip')

mame = open(MAME_DUMP, 'rb').read()
m = EsbMemMap(ZIP)


def region_match(lo, hi, slap_bank=3, bank2_page=0):
    total = hi - lo + 1
    match = 0
    first_mismatch = None
    for a in range(lo, hi + 1):
        ours = m.cpu_read(a, slap_bank=slap_bank, bank2_page=bank2_page)
        if ours is None:
            continue
        theirs = mame[a]
        if ours == theirs:
            match += 1
        elif first_mismatch is None:
            first_mismatch = (a, ours, theirs)
    return match, total, first_mismatch


print('=== reset/IRQ vectors ===')
for va, nm in [(0xFFFE, 'RESET'), (0xFFF8, 'IRQ')]:
    ours = (m.cpu_read(va) << 8) | m.cpu_read(va + 1)
    theirs = (mame[va] << 8) | mame[va + 1]
    flag = 'MATCH' if ours == theirs else '*** MISMATCH ***'
    print(f'  {nm:6s} ours=${ours:04X}  mame=${theirs:04X}  {flag}')

print()
print('=== bank1 $6000-$7FFF (MAME dump is 3s in = likely page 1) ===')
for pg in (0, 1):
    mt, tot, fm = region_match(0x6000, 0x7FFF, bank2_page=pg)
    print(f'  page {pg}: {mt}/{tot} match ({100*mt//tot}%)')

print()
print('=== bank2 $A000-$FFFF (try both pages) ===')
for pg in (0, 1):
    mt, tot, fm = region_match(0xA000, 0xFFFF, bank2_page=pg)
    print(f'  page {pg}: {mt}/{tot} match ({100*mt//tot}%)')
    if pg == 1 and fm:
        a, o, t = fm
        print(f'    first page-1 mismatch @ ${a:04X}: ours={o:02X} mame={t:02X}')

print()
print('=== slapstic region $8000-$9FFF (try each bank) ===')
for bank in range(4):
    mt, tot, fm = region_match(0x8000, 0x9FFF, slap_bank=bank)
    print(f'  bank {bank}: {mt}/{tot} match ({100*mt//tot}%)')

print()
print('=== where does MAME boot? compare first 16 code bytes at $EDEE ===')
rv = (mame[0xFFFE] << 8) | mame[0xFFFF]
print(f'  mame reset target = ${rv:04X}')
ours_row = ' '.join(f'{m.cpu_read(rv+i):02X}' if m.cpu_read(rv+i) is not None else "--" for i in range(16))
mame_row = ' '.join(f'{mame[rv+i]:02X}' for i in range(16))
print(f'  ours: {ours_row}')
print(f'  mame: {mame_row}')
