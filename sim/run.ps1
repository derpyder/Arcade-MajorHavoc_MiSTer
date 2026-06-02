# Build + run GHDL simulation of avg.vhd + vector_drawer.vhd
# against the MAME-captured high-score vector RAM (vec_T01500.bin).

$ErrorActionPreference = "Stop"
$GHDL = "C:\Users\mattl\bin\ghdl\bin\ghdl.exe"

Set-Location $PSScriptRoot

# 1. Prep input files
Write-Host "[1/4] Generating hex inputs..." -ForegroundColor Cyan
python prep.py

# 2. Analyze (compile) RTL sources -- order matters
Write-Host "[2/4] Analyzing sources..." -ForegroundColor Cyan
& $GHDL -a --std=08 -frelaxed dpram_sim.vhd
& $GHDL -a --std=08 -frelaxed ..\rtl\avg\vector_drawer.vhd
& $GHDL -a --std=08 -frelaxed ..\rtl\avg\avg.vhd
& $GHDL -a --std=08 -frelaxed tb_drawer.vhd

# 3. Elaborate the testbench
Write-Host "[3/4] Elaborating tb_drawer..." -ForegroundColor Cyan
& $GHDL -e --std=08 -frelaxed tb_drawer

# 4. Run -- writes tb_pixel_writes.txt
Write-Host "[4/4] Simulating..." -ForegroundColor Cyan
& $GHDL -r --std=08 -frelaxed tb_drawer --stop-time=200ms --ieee-asserts=disable

if (Test-Path tb_pixel_writes.txt) {
    $nlines = (Get-Content tb_pixel_writes.txt | Measure-Object -Line).Lines
    Write-Host "Simulation produced $nlines pixel write events." -ForegroundColor Green
} else {
    Write-Host "tb_pixel_writes.txt not created -- simulation failed." -ForegroundColor Red
}
