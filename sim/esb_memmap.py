#!/usr/bin/env python3
"""Python model of OUR HDL ESB memory map (rtl/starwars.sv mod_esb path).

Mirror to the way avg_starwars_hdl.py models the drawer: this models what
byte the 6809 CPU reads at each address $6000-$FFFF when mod_esb=1, exactly
as the HDL main_din_mux + esb_main_rom_cpu_addr + slap_rom wiring computes
it.  Diff against MAME's actual ESB CPU view (esb_mame_dump.py) pinpoints
any memory-map bug -- the ESB analog of the per-VCTR AVG diff that found
the three drawer bugs.

Two regions are banked and need the active bank to resolve:
  $8000-$9FFF  slapstic page (bank from the slapstic state machine)
  $A000-$FFFF  bank2 (page from outlatch[4]); we model the DEFAULT page

Everything else in $6000-$FFFF is fixed ROM.

Usage:
  from esb_memmap import EsbMemMap
  m = EsbMemMap('../../starwars-empirestrikesback/esb.zip')
  byte = m.cpu_read(0xFFFE, slap_bank=3, bank2_page=0)
"""
import zipfile


class EsbMemMap:
    def __init__(self, esb_zip_path):
        z = zipfile.ZipFile(esb_zip_path)
        self.files = {name: z.read(name) for name in z.namelist()}
        z.close()

        # ---- Reconstruct the dn_addr stream exactly as the MRA produces ----
        # (file order + pad sizes from releases/Empire Strikes Back.mra)
        stream = bytearray()
        def add(name):
            stream.extend(self.files[name])
        def pad(n):
            stream.extend(b'\x00' * n)

        add('136031.101')          # 0x00000  16KB main
        add('136031.102')          # 0x04000  16KB main
        add('136031.203')          # 0x08000  16KB main
        add('136031.104')          # 0x0C000  16KB main
        pad(4096)                  # 0x10000  4KB pad
        add('136021-105.1l')       # 0x11000  256B AVG PROM
        add('136031.110')          # 0x11100  1KB mathbox
        add('136031.109')          # 0x11500  1KB mathbox
        add('136031.108')          # 0x11900  1KB mathbox
        add('136031.107')          # 0x11D00  1KB mathbox
        pad(7936)                  # 0x12100  ~8KB pad
        add('136031.105')          # 0x14000  16KB slapstic 0+1
        add('136031.106')          # 0x18000  16KB slapstic 2+3
        add('136031.111')          # 0x1C000  4KB vector ROM
        pad(4096)                  # 0x1D000  4KB pad
        add('136031.113')          # 0x1E000  16KB audio
        add('136031.112')          # 0x22000  16KB audio
        self.stream = bytes(stream)

        # ---- The HDL loads BRAMs from dn_addr ranges (rtl/starwars.sv) ----
        # esb_main_rom : 64KB from dn 0x00000-0x0FFFF
        self.esb_main_rom = self.stream[0x00000:0x10000]
        # slap_rom : 32KB from dn 0x14000-0x1BFFF  (dn_esb_slap_addr = dn-0x4000)
        self.slap_rom = self.stream[0x14000:0x1C000]

    # ---- HDL esb_main_rom_cpu_addr mapping (rtl/starwars.sv) ----
    # page (= outlatch[4]) lands at BRAM addr[13]: page 0 = file low
    # half, page 1 = file high half.  bank1 ($6000) and bank2
    # ($A000-$FFFF) share the same page bit.
    def _esb_main_addr(self, cpu_addr, page=0):
        top3 = (cpu_addr >> 13) & 7
        off13 = cpu_addr & 0x1FFF
        p = (page & 1) << 13
        if top3 == 0b011:   # $6000-$7FFF bank1 (136031.101) base 0x0000
            return 0x0000 | p | off13
        if top3 == 0b101:   # $A000-$BFFF bank2 file0 (136031.102) base 0x4000
            return 0x4000 | p | off13
        if top3 == 0b110:   # $C000-$DFFF bank2 file1 (136031.203) base 0x8000
            return 0x8000 | p | off13
        if top3 == 0b111:   # $E000-$FFFF bank2 file2 (136031.104) base 0xC000
            return 0xC000 | p | off13
        return None

    def cpu_read(self, cpu_addr, slap_bank=3, bank2_page=0):
        """Return the byte our HDL returns for a CPU read at cpu_addr.

        slap_bank: current slapstic bank (0..3); 3 is the ESB power-up bank.
        bank2_page: 0 = default low-half view (what the HDL currently does;
                    the alt page is not yet wired).
        """
        if 0x6000 <= cpu_addr <= 0x7FFF:
            a = self._esb_main_addr(cpu_addr, page=bank2_page)
            return self.esb_main_rom[a]
        if 0x8000 <= cpu_addr <= 0x9FFF:
            # slap_rom cpu_addr_a = {slap_bs, main_addr[12:0]}
            a = ((slap_bank & 3) << 13) | (cpu_addr & 0x1FFF)
            return self.slap_rom[a]
        if 0xA000 <= cpu_addr <= 0xFFFF:
            a = self._esb_main_addr(cpu_addr, page=bank2_page)
            return self.esb_main_rom[a]
        return None  # not a ROM region in our model


if __name__ == '__main__':
    import sys, os
    here = os.path.dirname(__file__)
    zip_path = os.path.join(here, '../../starwars-empirestrikesback/esb.zip')
    m = EsbMemMap(zip_path)

    print('=== file sizes in esb.zip ===')
    for name, data in sorted(m.files.items()):
        print(f'  {name:20s} {len(data):6d}')

    print()
    print('=== HDL view of 6809 vectors (default bank2 page) ===')
    # 6809 vectors live at $FFF0-$FFFF; reset = $FFFE/$FFFF (big-endian)
    names = {0xFFFE: 'RESET', 0xFFFC: 'NMI', 0xFFFA: 'SWI',
             0xFFF8: 'IRQ', 0xFFF6: 'FIRQ', 0xFFF4: 'SWI2', 0xFFF2: 'SWI3'}
    for va in sorted(names, reverse=True):
        hi = m.cpu_read(va)
        lo = m.cpu_read(va + 1)
        print(f'  {names[va]:6s} @ {va:04X}: {hi:02X}{lo:02X}  '
              f'-> vector points at ${hi:02X}{lo:02X}')

    print()
    print('=== first 16 bytes our HDL returns at reset-vector target ===')
    rv = (m.cpu_read(0xFFFE) << 8) | m.cpu_read(0xFFFF)
    print(f'  reset target = ${rv:04X}')
    if 0x6000 <= rv <= 0xFFFF:
        row = ' '.join(f'{m.cpu_read(rv + i):02X}' for i in range(16))
        print(f'  [{rv:04X}] {row}')
    else:
        print(f'  reset target ${rv:04X} is outside ROM space -- '
              f'CPU would execute RAM/garbage = black screen')
