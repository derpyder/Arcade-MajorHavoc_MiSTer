printf "=== ESB boot trace ===\n"
printf "reset vector @ FFFE = %04X\n", w@0xfffe
printf "irq vector   @ FFF8 = %04X\n", w@0xfff8
gtime 3000
printf "=== after 3s ===\n"
printf "PC now = %04X\n", pc
save snap/esb_cpu_full.bin,0x0000,0x10000
printf "=== dumped 0000-FFFF ===\n"
quit
