@echo off
setlocal enabledelayedexpansion

REM RISC-V firmware build (Windows)
REM NOTE: keep this file pure ASCII + CRLF. Chinese text breaks cmd.exe parsing
REM       when the console codepage differs from the ANSI codepage.

cd /d "%~dp0"

REM ---- auto-detect toolchain prefix ----
set PREFIX=
for %%P in (riscv-none-elf- riscv64-unknown-elf- riscv-nuclei-elf- riscv32-unknown-elf- riscv-none-embed-) do (
    if "!PREFIX!"=="" (
        where %%Pgcc >nul 2>nul
        if !errorlevel! equ 0 set PREFIX=%%P
    )
)

if "!PREFIX!"=="" (
    echo.
    echo *** RISC-V toolchain not found ***
    echo.
    echo Install one of these and add its bin dir to PATH:
    echo   xPack:         riscv-none-elf-gcc      ^(recommended^)
    echo   Nuclei Studio: riscv-nuclei-elf-gcc
    echo   MSYS2:         riscv64-unknown-elf-gcc
    echo.
    exit /b 1
)

echo Toolchain: !PREFIX!
set CC=!PREFIX!gcc
set OBJCOPY=!PREFIX!objcopy
set SIZE=!PREFIX!size

set CFLAGS=-march=rv32im -mabi=ilp32 -Os -ffreestanding -nostdlib -nostartfiles -fno-builtin -Wall -Wextra -T link.ld

echo [1/3] compile
%CC% %CFLAGS% -o firmware.elf crt0.S main.c
if errorlevel 1 goto :fail
%SIZE% firmware.elf

echo [2/3] elf -> bin
REM argument order matters: input first, output second
%OBJCOPY% -O binary firmware.elf firmware.bin
if errorlevel 1 goto :fail

echo [3/3] bin -> hex
python bin2hex.py firmware.bin firmware.hex
if errorlevel 1 goto :fail

echo.
echo OK: firmware.hex
echo Copy it to the PDS project root (2_10_hdmi_loop\) - $readmemh looks there.
goto :eof

:fail
echo.
echo *** BUILD FAILED ***
exit /b 1