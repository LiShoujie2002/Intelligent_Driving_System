# PicoRV32 软核接入说明

> 基础任务 2「软硬协同」的落地部分。软核替代外接 MCU，片内直连寄存器组，
> 不需要任何额外硬件和接线。

## 文件清单

| 文件 | 来源 | 说明 |
|---|---|---|
| `picorv32.v` | vendor 原样 | RISC-V 内核（85 KB，不要改） |
| `simpleuart.v` | vendor 原样 | UART 收发 |
| `picosoc_lane.v` | **自己写** | SoC 顶层：CPU + 32KB RAM + UART + 寄存器组接口 |
| `firmware/main.c` | 自己写 | 应用：读状态、切显示模式、监视帧计数 |
| `firmware/crt0.S` | 自己写 | 启动代码（清 bss，跳 main） |
| `firmware/link.ld` | 自己写 | 链接脚本（程序从 0x1000 开始） |
| `firmware/build.bat` / `Makefile` | 自己写 | 构建脚本 |

`gpio.v` 是 vendor demo 带的，本工程**没用到**，不用加进 PDS。

---

## 存储器映射

```
0x0000_0000 - 0x0000_7FFF   32 KB RAM（程序从 0x1000 开始，栈从 0x8000 向下）
0x0000_8000                 UART 分频寄存器
0x0000_8010                 UART 数据寄存器（写会自动停总线到发送完成）
0x0000_8020 - 0x0000_841F   reg_bank 256 个 32 位寄存器
0x0000_8420                 调试 LED
```

`reg_bank` 的地址换算：`地址 = 0x8020 + (寄存器索引 << 2)`，
索引与 `reg_bank.v` 里的注释一一对应。

---

## 一、装 RISC-V 工具链

任选其一，装完确认 `riscv64-unknown-elf-gcc` 在 `PATH` 里：

- **Nuclei Studio**（推荐，小眼睛的资料包里就用它）
- **xPack RISC-V GCC**（Windows 版，独立安装）
- SiFive Freedom 工具链

验证：
```bash
riscv64-unknown-elf-gcc --version
```

## 二、编译固件

```bash
cd source/soc/firmware
build.bat                                     # Windows
# 或者有 make 的环境: make
```

产物 `firmware.hex`。**把它复制到 PDS 的工程根目录**
（`e:\ZiGuangProject\2_10_hdmi_loop\`），因为 `$readmemh` 是相对综合工作目录找的。

> 如果综合时报 "can't open firmware.hex"，看 PDS 日志里综合是从哪个目录跑的，
> 把文件放到那个目录。

---

## 三、PDS 工程改动

### 1. 加源文件

`source/soc/` 下三个 Verilog 加进工程：
- `picorv32.v`
- `simpleuart.v`
- `picosoc_lane.v`

### 2. 引脚约束（加到 `hdmi_loop.fdc`）

UART 接板载 CP2102：

```tcl
define_attribute {p:uart_rxd} {PAP_IO_DIRECTION} {INPUT}
define_attribute {p:uart_rxd} {PAP_IO_LOC} {B24}
define_attribute {p:uart_rxd} {PAP_IO_VCCIO} {3.3}
define_attribute {p:uart_rxd} {PAP_IO_STANDARD} {LVCMOS33}
define_attribute {p:uart_rxd} {PAP_IO_NONE} {TRUE}

define_attribute {p:uart_txd} {PAP_IO_DIRECTION} {OUTPUT}
define_attribute {p:uart_txd} {PAP_IO_LOC} {C24}
define_attribute {p:uart_txd} {PAP_IO_VCCIO} {3.3}
define_attribute {p:uart_txd} {PAP_IO_STANDARD} {LVCMOS33}
define_attribute {p:uart_txd} {PAP_IO_DRIVE} {8}
define_attribute {p:uart_txd} {PAP_IO_NONE} {TRUE}
define_attribute {p:uart_txd} {PAP_IO_SLEW} {SLOW}
```

### 3. `hdmi_loop.v` 里例化

```verilog
// ---- 顶层加两个端口 ----
input   uart_rxd,
output  uart_txd,

// ---- 软核 ----
wire [ 7:0] rb_addr;
wire [31:0] rb_wdata, rb_rdata;
wire        rb_we, rb_re;

picosoc_lane u_soc (
    .clk      ( cfg_clk      ),      // 先用 10MHz, 够用且不用改 PLL
    .resetn   ( rstn_out     ),      // PLL 锁定后约 1ms 拉高
    .ser_tx   ( uart_txd     ),
    .ser_rx   ( uart_rxd     ),
    .rb_addr  ( rb_addr      ),
    .rb_wdata ( rb_wdata     ),
    .rb_we    ( rb_we        ),
    .rb_re    ( rb_re        ),
    .rb_rdata ( rb_rdata     ),
    .led      ( led_dbg      ),
    .cpu_trap ( cpu_trap     )
);
```

**注意**：`reg_bank` 的时钟要改成 `cfg_clk`（和软核同域），原来的 `spi_slave`
可以删掉或者留着备用。

### 4. 跨时钟域（重要）

`reg_bank` 移到 `cfg_clk` 域之后，和像素域之间要加同步器：

**配置输出 → 像素域**（准静态，两级触发器即可）：
```verilog
reg [1:0] mode_s1, mode_s2;
always @(posedge pixclk_out) begin
    mode_s1 <= cfg_mode;
    mode_s2 <= mode_s1;
end
// video_process 的 .mode 接 mode_s2
```
`bypass / edge_thr / roi_top / roi_bot / lane_w` 同理。

**状态输入 → CPU 域**（同理反向）：
```verilog
reg [11:0] h_act_s1, h_act_s2;
always @(posedge cfg_clk) begin
    h_act_s1 <= h_act;
    h_act_s2 <= h_act_s1;
end
```
`v_act / frame_cnt / video_stable` 同理。

> `frame_cnt` 是 16 位计数器，逐位同步偶尔会读到"半个新值"，**作为状态监视无害**。
> 如果将来要拿它做精确计时，改成格雷码或者加握手。

---

## 四、验证顺序

按这个顺序，每一步都能独立定位问题：

| 步 | 做什么 | 预期 | 不通说明 |
|---|---|---|---|
| 1 | 只加 `picosoc_lane`，RAM 里放空程序 | 综合通过，CPU 不 trap | 总线/复位有问题 |
| 2 | 烧录，串口接 PC（115200） | 打印 `=== PicoRV32 boot ===` | 时钟/复位/UART 分频 |
| 3 | 看 `magic = 0x504e4750 OK` | **链路通了** | 寄存器地址或 CDC |
| 4 | 看 `H_ACT = 1280 V_ACT = 720` | 状态读取正常 | 状态同步器 |
| 5 | 看显示模式自动切换 4 次 | **软核真的控制了 FPGA** | `cfg_mode` 同步或接线 |
| 6 | 板载 LED 每帧闪一次 | 主循环在跑 | — |

**第 5 步就是"软硬协同"的证据**——评审看到 MCU 发命令、FPGA 换个显示模式，这条任务就算落地了。

---

## 五、已知限制

1. **改固件要重新综合**（程序是 `$readmemh` 烧进 BRAM 的）。2~5 分钟一次，
   调试期会比较慢。后面嫌慢可以接 JTAG 在线调试（vendor demo 里已经有
   `pad_TCK/TMS/TDI/TDO` 的接口）。
2. **CPU 先用 10 MHz**。决策逻辑每帧才处理几百个点，10 MHz 完全够。
   真要提速，给 PLL 加一路 50 MHz 输出即可，本模块不用改。
3. **没有中断**（`ENABLE_IRQ(0)`）。当前是轮询式，够用。将来要事件驱动
   再把 IRQ 打开。
4. **`cfg_en` 目前没接到视频流水线**。等软核跑通后再决定它控制什么
   （打开/关闭处理、省电、还是纯粹的状态位）。
