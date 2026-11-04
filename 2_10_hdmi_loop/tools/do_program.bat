@echo off
cd /d "%~dp0"
set PDS=E:\pango\PDS_2022.2-SP6.4\bin
set PRJ=e:\ZiGuangProject\2_10_hdmi_loop
echo Programming FPGA ...
tasklist /FI "IMAGENAME eq cdt_js.exe" 2>nul | find /I "cdt_js.exe" >nul
if errorlevel 1 (
    start "" /min "%PDS%\cdt_js.exe" -work_dir "%PRJ%"
    echo Waiting for JTAG server ...
    timeout /t 15 >nul
)
"%PDS%\cdt_cfg_shell.exe" -file "%PRJ%\program_main.tcl" -work_dir "%PRJ%"
echo.
echo Done. Wait 8-10 seconds for the link and HDMI to settle before testing.
pause