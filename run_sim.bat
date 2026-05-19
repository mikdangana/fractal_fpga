@echo off
setlocal

set VIVADO_BIN=C:\Xilinx\2025.1\Vivado\bin
set SRCDIR=%~dp0

echo === Compiling VHDL sources ===
%VIVADO_BIN%\xvhdl.bat --work work --2008 "%SRCDIR%counter.vhd" "%SRCDIR%fractal.vhd" "%SRCDIR%tb_fractal.vhd"
if %ERRORLEVEL% neq 0 ( echo [FAIL] xvhdl & exit /b 1 )

echo === Elaborating tb_fractal ===
%VIVADO_BIN%\xelab.bat --debug typical --relax -L work work.tb_fractal -s tb_fractal_sim
if %ERRORLEVEL% neq 0 ( echo [FAIL] xelab & exit /b 1 )

echo === Running simulation ===
%VIVADO_BIN%\xsim.bat tb_fractal_sim --runall --log sim_output.txt
if %ERRORLEVEL% neq 0 ( echo [FAIL] xsim & exit /b 1 )

echo === Done. Output in sim_output.txt ===
endlocal
