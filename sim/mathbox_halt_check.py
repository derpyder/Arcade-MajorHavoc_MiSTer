#!/usr/bin/env python3
"""Does our increment-only mathbox sequencer HALT for every ESB program?

rtl/mathbox.sv advances the microcode address by PURE INCREMENT within a
256-entry page (mpa <= {mpa[9:8], mpa[7:0]+1}) and halts only when it
*reaches* a microinstruction with the HALT bit set (exec_strobe[2] =
prom1[mpa] bit 2).  There are NO conditional microcode jumps.

That works for Star Wars (it ships).  But if any ESB mathbox program's
HALT isn't reachable by pure incrementing from its entry point, the
sequencer loops forever -> `running` stays 1 -> math_run stuck high ->
the 6809 polls the busy flag forever -> FREEZE (music keeps playing,
frame frozen, math-computed HUD elements missing).

This checks, for every entry point (MW0 value 0..255), whether the
increment path hits a HALT before wrapping all the way around its page.
Compares ESB PROMs vs SW PROMs.  Any entry that halts under SW but NOT
under ESB (or vice versa) is a candidate freeze.

PROM mapping (rtl/mathbox.sv:118-145, + MRA load order):
  prom1 carries the HALT bit (ip[11:8] bit 2).  MRA loads the 4 mathbox
  PROMs in order -> prom0,prom1,prom2,prom3.
    SW : prom1 = 136021-111.7j
    ESB: prom1 = 136031.109
  mpa is 10-bit: [9:8]=page (preserved), [7:0]=offset (increments, wraps
  at 256).  MW0 write sets mpa = {cpu_din, 2'b00}.
"""
import zipfile

SW_ZIP  = '../../starwars-mister/.tools/mame0287/roms/starwars.zip'
ESB_ZIP = '../../starwars-empirestrikesback/esb.zip'


def load(zippath, name):
    z = zipfile.ZipFile(zippath)
    try:
        return z.read(name)
    finally:
        z.close()


def halt_map(prom1):
    """prom1: 1024 bytes (low nibble used), bit 2 = HALT.
    For each entry point E (0..255): mpa0 = (E<<2) & 0x3FF; page = mpa0[9:8];
    offset starts at mpa0[7:0]; increment offset (wrap 256) within page;
    report steps-to-HALT or None if it loops 256 without HALT."""
    res = {}
    for E in range(256):
        mpa0 = (E << 2) & 0x3FF
        page = mpa0 & 0x300
        off = mpa0 & 0xFF
        steps = None
        for s in range(257):
            mpa = page | off
            if prom1[mpa] & 0x4:        # HALT bit
                steps = s
                break
            off = (off + 1) & 0xFF
        res[E] = steps
    return res


sw_prom1  = load(SW_ZIP,  '136021-111.7j')
esb_prom1 = load(ESB_ZIP, '136031.109')
print(f'SW  prom1 (136021-111.7j): {len(sw_prom1)} bytes')
print(f'ESB prom1 (136031.109):    {len(esb_prom1)} bytes')

sw  = halt_map(sw_prom1)
esb = halt_map(esb_prom1)

sw_nohalt  = [E for E in range(256) if sw[E]  is None]
esb_nohalt = [E for E in range(256) if esb[E] is None]

print()
print(f'SW  entry points that NEVER halt (increment-only): {len(sw_nohalt)}')
print(f'ESB entry points that NEVER halt (increment-only): {len(esb_nohalt)}')
print()
if esb_nohalt:
    print('ESB non-halting entries (MW0 value, hex):')
    print('  ' + ' '.join(f'{E:02X}' for E in esb_nohalt))
print()
# The smoking gun: entries that halt under SW but hang under ESB
sw_ok_esb_hang = [E for E in range(256) if sw[E] is not None and esb[E] is None]
print(f'Entries that HALT on SW but HANG on ESB: {len(sw_ok_esb_hang)}')
if sw_ok_esb_hang:
    print('  ' + ' '.join(f'{E:02X}' for E in sw_ok_esb_hang))
    print('  ^ if ESB writes any of these to MW0 ($4700), that is the freeze.')
