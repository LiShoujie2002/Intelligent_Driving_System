@echo off
cd /d "%~dp0"
echo ============================================
echo  FPGA video + YOLOP v3 demo
echo ============================================
echo  Before running, make sure:
echo    1. FPGA board is programmed and powered
echo    2. HDMI video is playing into the board
echo    3. Monitor is connected to the board HDMI OUT
echo    4. This PC NIC is 192.168.1.105 / 24
echo.
echo  Press ESC in the video window to quit.
echo ============================================
echo.
"E:\anaconda3\envs\my_pytorch\python.exe" pc_receiver.py --model "C:\yolop_v5_pkg" --device cuda:0 --show --record demo_recording.mp4
echo.
echo Demo stopped.
pause