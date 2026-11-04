# PicoRV32 固件构建
#
# 需要 RISC-V 工具链: riscv64-unknown-elf-gcc
#   Nuclei Studio / xPack RISC-V GCC / SiFive toolchain 都带这个前缀

# 工具链前缀按你装的发行版改:
#   xPack           -> riscv-none-elf-
#   Nuclei Studio   -> riscv-nuclei-elf-
#   MSYS2 / SiFive  -> riscv64-unknown-elf-
PREFIX  ?= riscv64-unknown-elf-

CC      ?= $(PREFIX)gcc
OBJCOPY ?= $(PREFIX)objcopy
SIZE    ?= $(PREFIX)size

CFLAGS  = -march=rv32im -mabi=ilp32 -Os -ffreestanding -nostdlib -nostartfiles \
          -fno-builtin -Wall -Wextra -T link.ld

all: firmware.hex

firmware.elf: crt0.S main.c link.ld
	$(CC) $(CFLAGS) -o $@ crt0.S main.c
	$(SIZE) $@

firmware.bin: firmware.elf
	$(OBJCOPY) -O binary $< $@

firmware.hex: firmware.bin bin2hex.py
	python bin2hex.py $< $@

clean:
	-rm -f firmware.elf firmware.bin firmware.hex

.PHONY: all clean
