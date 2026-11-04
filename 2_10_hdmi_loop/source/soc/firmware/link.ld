/* PicoRV32 链接脚本
 *
 * 程序从 0x1000 开始（与 picosoc_lane.v 的 PROGADDR_RESET 一致），
 * RAM 一共 32 KB（0x0000 ~ 0x7FFF），栈从 0x8000 往下长。
 *
 * 注意: 不要用 MEMORY { ... } 定义区域 —— 一旦用了, 链接器会把段放到
 * 区域的 ORIGIN, 把 . = 0x1000 覆盖掉, 入口就跑到 0 去了。
 * 之前踩过这个坑。直接用位置计数器最可靠。
 */
OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
    . = 0x00001000;

    .text.init : { *(.text.init) }
    .text      : { *(.text*)     }
    .rodata    : { *(.rodata*)   }
    .data      : { *(.data*)     }

    .bss : {
        _bss_start = .;
        *(.bss*) *(.bss.*) *(COMMON)
        _bss_end = .;
    }

    _end = .;
}
