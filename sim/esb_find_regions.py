#!/usr/bin/env python3
"""Empirically locate which esb.zip file+offset each MAME CPU region
comes from.  No assumptions about the memory map -- just pattern-match
MAME's dumped bytes against every 8KB-aligned window of every ROM file.

This tells us the GROUND-TRUTH file->CPU mapping, which we then compare
against our HDL esb_main_rom wiring to find the bug.
"""
import os
import zipfile

HERE = os.path.dirname(__file__)
MAME_DUMP = os.path.join(HERE, '../../starwars-mister/.tools/mame0287/snap/esb_cpu_full.bin')
ZIP = os.path.join(HERE, '../../starwars-empirestrikesback/esb.zip')

mame = open(MAME_DUMP, 'rb').read()
z = zipfile.ZipFile(ZIP)
files = {n: z.read(n) for n in z.namelist()}


def find_source(cpu_lo, length=64):
    """Find which file+offset contains MAME's bytes at cpu_lo."""
    needle = mame[cpu_lo:cpu_lo + length]
    hits = []
    for name, data in files.items():
        # slide over the file
        for off in range(0, max(1, len(data) - length + 1)):
            if data[off:off + length] == needle:
                hits.append((name, off))
                break
    return hits


print('CPU region -> esb.zip source (64-byte signature match):')
print('-' * 64)
for cpu_addr, label in [
    (0x6000, '$6000 (bank1 lo)'),
    (0x7000, '$7000'),
    (0xA000, '$A000 (bank2)'),
    (0xC000, '$C000 (bank2)'),
    (0xE000, '$E000 (bank2)'),
    (0xF000, '$F000'),
    (0xFFC0, '$FFC0 (vectors)'),
]:
    hits = find_source(cpu_addr)
    if hits:
        for name, off in hits:
            print(f'  CPU ${cpu_addr:04X} {label:18s} = {name} + 0x{off:04X}')
    else:
        print(f'  CPU ${cpu_addr:04X} {label:18s} = NOT FOUND in any file')

print()
print('Reset vector region detail:')
rv = (mame[0xFFFE] << 8) | mame[0xFFFF]
print(f'  MAME reset vector @ $FFFE = ${rv:04X}')
print(f'  MAME $FFF0-$FFFF: ' + ' '.join(f'{mame[0xFFF0+i]:02X}' for i in range(16)))
print()

# For each main file, show its tail (where a reset vector would live)
print('Tail bytes (offset 0x1FF0-0x1FFF = low-half end) of each 16KB main file:')
for name in ['136031.101', '136031.102', '136031.203', '136031.104']:
    d = files[name]
    print(f'  {name} [0x1FF0]: ' + ' '.join(f'{d[0x1FF0+i]:02X}' for i in range(16)))
    print(f'  {name} [0x3FF0]: ' + ' '.join(f'{d[0x3FF0+i]:02X}' for i in range(16)))
