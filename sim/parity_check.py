#!/usr/bin/env python3
"""parity_check.py -- Phase-2 parity oracle.

Phase 2 replaces the 8bpp-INDEXED framebuffer with a 32bpp RGB888 framebuffer.
For PARITY (bit-identical output), the new write-time {color,intensity}->RGB888
conversion MUST equal the current palette LUT for all 256 {color[2:0],z[4:0]}
inputs.  This asserts that equality, and documents the byte packing + ascal
read order so the RTL constants are locked.

Current palette (rtl/vector_fb_ddram.sv:143-151):
    channel_val = {pal_int[4:0], pal_int[4:2]}      // 5-bit z -> 8-bit channel
    R = pal_rgb[2] ? channel_val : 0
    G = pal_rgb[1] ? channel_val : 0
    B = pal_rgb[0] ? channel_val : 0

New write-time conversion (to bake into vector_fb_ddram.sv stage 2):
    chan  = {z[4:0], z[4:2]}                          // identical formula
    new32 = {8'h00, B, G, R}                          // little-endian word
where the 32-bit word's byte0=R, byte1=G, byte2=B (ascal.vhd:665-666, fmt 0110:
    r=>shift(0 TO 7), g=>shift(8 TO 15), b=>shift(16 TO 23)).
"""
import sys


def channel_val(z5):
    # {z[4:0], z[4:2]} : 5-bit intensity replicated MSBs into low 3 bits -> 8-bit
    return ((z5 & 0x1F) << 3) | ((z5 >> 2) & 0x7)


def palette_rgb(color, z5):
    """Current hardware palette entry -> (R,G,B) 8-bit each."""
    cv = channel_val(z5)
    r = cv if (color & 4) else 0
    g = cv if (color & 2) else 0
    b = cv if (color & 1) else 0
    return r, g, b


def rtl_new32(color, z5):
    """Proposed write-time conversion -> the 32-bit FB word {00,B,G,R}."""
    cv = channel_val(z5)
    r = cv if (color & 4) else 0
    g = cv if (color & 2) else 0
    b = cv if (color & 1) else 0
    return (0 << 24) | (b << 16) | (g << 8) | r        # byte0=R,1=G,2=B,3=00


def ascal_read_rgb(word32):
    """ascal 32bpp (fmt 0110) unpacks byte0=R, byte1=G, byte2=B."""
    r = word32 & 0xFF
    g = (word32 >> 8) & 0xFF
    b = (word32 >> 16) & 0xFF
    return r, g, b


def main():
    bad = 0
    for color in range(8):
        for z5 in range(32):
            want = palette_rgb(color, z5)                  # what the indexed FB shows
            got = ascal_read_rgb(rtl_new32(color, z5))     # what the RGB FB will show
            if want != got:
                bad += 1
                if bad <= 8:
                    print(f'  MISMATCH color={color} z={z5}: palette={want} rgb-fb={got}')
    total = 8 * 32
    if bad == 0:
        print(f'PARITY OK: all {total} {{color,z}} inputs identical (palette == RGB-FB via ascal).')
        # show a few representative values for the record
        print('  samples (color,z -> R,G,B):')
        for color, z5 in [(1, 31), (1, 16), (4, 31), (6, 31), (7, 31), (2, 8)]:
            print(f'    c{color} z{z5:<2} -> {palette_rgb(color, z5)}  '
                  f'word32=0x{rtl_new32(color, z5):08X}')
        print('  byte packing: word = {00,B,G,R} (byte0=R); FB_FORMAT=5\'b00110 ([4]=0=RGB)')
        return 0
    print(f'PARITY FAIL: {bad}/{total} mismatches')
    return 1


if __name__ == '__main__':
    sys.exit(main())
