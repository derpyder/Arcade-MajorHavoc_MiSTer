gtime 3000
printf "=== ESB T=3s, PC=%04X ===\n",pc
save snap/esb_vec_3s.bin,0x0000,0x4000
printf "=== dumped vector mem 0000-3FFF ===\n"
quit
