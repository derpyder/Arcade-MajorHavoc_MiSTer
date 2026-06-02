#!/bin/bash
# runfb.sh <BUSY_DUTY 0..16> [vlog-defines]   e.g.  ./runfb.sh 0   |   ./runfb.sh 8 +define+BLANK_MOVES
# Compiles + runs tb_fb_replay at the given DDR contention duty, then prints the
# quantitative solidity metric (NOT an image). ModelSim ASE ~2s.
MS=/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem
DUTY=${1:-8}
DEFS=${2:-}
"$MS/vlog.exe" -sv $DEFS ddr_model.sv tb_fb_replay.sv ../../rtl/vector_fb_ddram.sv > vlog.log 2>&1 \
  || { echo "VLOG FAIL:"; cat vlog.log; exit 1; }
"$MS/vsim.exe" -c -gBUSY_DUTY=$DUTY -do "run -all; quit -f" tb_fb_replay > vsim.log 2>&1
grep -E "FBREPLAY RESULT|FBREPLAY FIFO|FBREPLAY ISSUE|fed=" vsim.log | sed 's/^# //'
echo "=== metric  BUSY_DUTY=$DUTY  DEFS='${DEFS:-none}' ==="
python fb_metric.py
