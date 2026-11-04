# 2_10_hdmi_loop：FPGA HDMI 与 YOLOP 以太网闭环

本工程面向紫光同创盘古 200Pro 平台，实现 HDMI 输入直通、视频降采样上传、PC 端 YOLOP 推理结果回传以及 FPGA 端 OSD 检测框叠加。

当前集成版本以 **1280×720 输入、74.25 MHz 像素时钟**为工作基准。FPGA 将视频降采样为 640×360 RGB565，通过千兆以太网 UDP 发送给 PC；PC 完成模型推理后，将最多 32 个检测框回传，FPGA 在原始 720p 画面上实时叠加并输出到 HDMI 显示器。

## 系统数据流

```text
HDMI 信号源
    │ 1280×720 RGB888
    ▼
MS7200 HDMI RX
    │ pixclk_in / DE / HS / VS / RGB
    ├──────────────► 原图像素通路 ─► OSD 检测框 ─► MS7210 HDMI TX ─► 显示器
    │
    └─► 2×2 均值降采样 ─► 640×360 RGB565 双缓冲
                              │
                              ▼ UDP :5000
                         PC 接收与 YOLOP 推理
                              │
                              ▼ UDP :5002，最多 32 框
                         FPGA 解析与跨时钟域更新
```

系统不依赖外部 DDR。视频上传使用片上存储器双缓冲；网络异常或 PC 未运行时，HDMI 原图直通仍可工作，只是没有新的检测框。

## 硬件与工程配置

| 项目 | 配置 |
|---|---|
| FPGA | 紫光同创 PG2L200H |
| 封装/速度等级 | FBB676 / -6 |
| PDS 架构 | Logos2 |
| 顶层模块 | `hdmi_loop` |
| HDMI 接收/发送 | MS7200 / MS7210，经 I²C 初始化 |
| 以太网 PHY | RTL8211F-CG，RGMII 千兆接口 |
| 控制软核 | PicoRV32，10 MHz，32 KiB RAM |
| 串口 | 115200 baud |
| 当前视频基准 | 1280×720，像素时钟 74.25 MHz |
| 网络时钟 | RGMII 125 MHz |

> 顶层文件仍保留一组 1080p 测试图参数，但当前 OSD、降采样器、网络包头和时序约束均按 1280×720 固定配置。直接输入 1080p 不属于当前已集成工作模式。

## 当前功能

- HDMI RX/TX 芯片上电和 I²C 配置。
- HDMI 像素、同步信号输入寄存和输出寄存，保证 RGB、DE、HS、VS 对齐。
- 自动测量有效区宽高、帧计数和视频稳定状态。
- 1280×720 RGB888 到 640×360 RGB565 的 2×2 均值降采样。
- 片上双缓冲跨像素域/网络域传输。
- Ethernet II、IPv4、UDP、前导码和 CRC32/FCS 的硬件发送链路。
- UDP 视频分包上传，PC 侧按帧号和包号重组。
- UDP 检测结果接收、协议过滤、最多 32 个框解析。
- 720p OSD 边框与类别编号叠加，交通灯可按子类显示红/黄/绿。
- PicoRV32 通过寄存器组读取视频状态、输出串口诊断信息并驱动心跳灯。

## 目录结构

```text
2_10_hdmi_loop/
├─ source/
│  ├─ hdmi_loop.v               # 顶层，连接 HDMI、软核、网络和 OSD
│  ├─ ms72xx_ctl.v              # HDMI RX/TX 初始化总控
│  ├─ ms7200_ctl.v              # MS7200 配置
│  ├─ ms7210_ctl.v              # MS7210 配置
│  ├─ iic_dri.v                 # I²C 驱动
│  ├─ video_timing.v            # 有效分辨率、帧与稳定状态测量
│  ├─ reg_bank.v                # 软硬件寄存器组
│  ├─ eth/                      # 降采样、缓存、UDP/MAC、RGMII、接收和 OSD
│  └─ soc/                      # PicoRV32 SoC、UART 和固件
├─ ipcore/PLL/                  # PDS 生成的控制时钟 PLL
├─ tools/                       # PC 收图、模型适配、诊断和测试脚本
├─ docs/
│  ├─ 联调步骤.md
│  └─ 以太网传输协议_v1.md
├─ hdmi_loop.fdc                # 引脚、时钟和时序约束
├─ hdmi_loop.pds                # PDS GUI 工程
├─ build_main.tcl               # PDS 命令行构建脚本
├─ program_main.tcl             # 下载脚本
├─ firmware.hex                 # 顶层 SoC 当前加载的固件镜像
├─ generate_bitstream/          # 已生成的位流
└─ compile/、synthesize/、...    # PDS 自动生成的构建产物和报告
```

`compile`、`synthesize`、`device_map`、`place_route`、`report_timing` 和 `generate_bitstream` 均为工具生成目录，修改设计时应以 `source`、`ipcore`、`hdmi_loop.fdc` 和工程脚本为准。

## 关键模块

| 模块 | 职责 |
|---|---|
| `hdmi_loop.v` | 顶层复位、时钟域同步、HDMI 直通、网络上传、检测结果接收和 OSD |
| `video_downsample.v` | 2×2 均值滤波并转换为 RGB565 |
| `net_video_uplink.v` | 双缓冲管理、跨时钟域握手和视频发送调度 |
| `eth_udp_video_tx.v` | 32 字节应用头、图像分包和 UDP 发送控制 |
| `eth_udp_tx.v` | IPv4/UDP 头和 IPv4 校验和 |
| `eth_frame_tx.v` | Ethernet II、前导码、最小帧填充和 CRC32/FCS |
| `rgmii_interface.v` | Pango DDR/IODELAY 原语与 RTL8211F RGMII 接口 |
| `eth_rx.v` / `eth_udp_rx.v` / `eth_app_rx.v` | 以太网、UDP 和应用层检测框解析 |
| `net_rx_path.v` | 网络域框表到像素域的 ping-pong 快照传递 |
| `osd_overlay.v` | 最多 32 个框、类别数字和颜色叠加 |
| `picosoc_lane.v` | PicoRV32、RAM、UART、寄存器组总线和调试 LED |
| `reg_bank.v` | 视频状态与控制参数的内存映射寄存器 |

## 网络配置

当前网络参数直接写在 Verilog 参数和 PC 参考脚本中：

| 项目 | 值 |
|---|---|
| FPGA IP | `192.168.1.11` |
| FPGA MAC | `A0:B1:C2:D3:E1:E1` |
| PC 网卡 IP | `192.168.1.105` |
| 子网掩码 | `255.255.255.0` |
| FPGA → PC 视频端口 | UDP `5000` |
| PC → FPGA 检测端口 | UDP `5002` |
| 目的 MAC | 广播 `FF:FF:FF:FF:FF:FF` |

PC 网卡必须协商到 **1 Gbps**。建议板卡与 PC 直连，并手动设置 PC 网卡地址：

```text
IP 地址：192.168.1.105
子网掩码：255.255.255.0
网关：留空
```

当前上传端不实现 ARP，直接使用广播 MAC；检测接收路径关闭了目的 IP 严格检查，以便接收 PC 发往 `192.168.1.255:5002` 的广播包。

## 视频与检测协议

详细字节定义见 [docs/以太网传输协议_v1.md](docs/以太网传输协议_v1.md)。当前代码的关键参数如下：

- 应用层 magic：ASCII `PNG1`。
- 所有多字节字段使用大端网络序。
- 每个 UDP 视频包包含 32 字节应用头和最多 1440 字节图像数据。
- 一帧 640×360 RGB565 共 460,800 字节，正好拆为 320 包。
- 图像按行优先排列，无行填充；包边界可以落在任意字节位置。
- 检测框回传格式为 32 字节应用头加若干 16 字节框记录。
- 检测框坐标必须使用 1280×720 原始图坐标系。
- 最多接收 32 个框，超出部分应由 PC 端截断。

类别约定：

| `class_id` | 含义 | 默认 OSD 颜色 |
|---:|---|---|
| 0 | 车辆 | 绿色 |
| 1 | 行人 | 黄色 |
| 2 | 交通灯 | 按 `subclass` 显示红/黄/绿，未知时为红色 |
| 3 | 骑行者 | 紫色 |

交通灯 `subclass`：0=未知、1=红、2=黄、3=绿。

## PC 端快速联调

安装 PC 脚本依赖：

```bash
python -m pip install numpy pillow opencv-python
```

### 1. 只验证收图与回传

```bash
cd tools
python pc_receiver.py
```

脚本会生成一个移动的演示框，用于独立验证视频收包、RGB565 解码、检测包回传和 FPGA OSD。正常时终端应持续显示完整帧、残缺帧和帧率统计，板端显示器出现移动框。

保存一帧：

```bash
python pc_receiver.py --save frame.png
```

### 2. 接入 YOLOP 推理包

```bash
python pc_receiver.py --model "D:\path\to\YOLOP_v5_GitHub" --device cuda:0 --show
```

录像和坐标诊断：

```bash
python pc_receiver.py ^
  --model "D:\path\to\YOLOP_v5_GitHub" ^
  --device cuda:0 ^
  --show ^
  --record demo.mp4 ^
  --csv boxes.csv
```

`tools/yolop_adapter.py` 负责类别映射、交通灯子类映射，以及从 640×360 推理图坐标乘 2还原到 1280×720。

> `tools/run_demo.bat` 和 `tools/run_record.bat` 中的 Python 解释器及模型目录是旧机器的绝对路径，使用前必须修改。

## 构建 PicoRV32 固件

固件位于 `source/soc/firmware`，需要支持 RV32IM 的 RISC-V GCC 工具链。Windows 下可执行：

```bat
cd source\soc\firmware
build.bat
```

脚本会依次生成 `firmware.elf`、`firmware.bin` 和 `firmware.hex`。生成后将 `firmware.hex` 复制到工程根目录，再重新综合，以便 `picosoc_lane.v` 的 `$readmemh` 使用最新固件。

固件启动后通过 UART 输出：

- 寄存器组 magic 校验；
- 当前有效分辨率和视频稳定状态；
- 帧计数与 DE 行计数诊断；
- 当前显示模式说明。

随后 LED0 周期翻转，用于判断软核和 10 MHz 控制时钟是否正常。

## PDS 构建与烧录

### GUI 构建

1. 使用 Pango Design Suite 打开 `hdmi_loop.pds`。
2. 确认器件为 `PG2L200H / FBB676 / -6`，顶层为 `hdmi_loop`。
3. 依次运行综合、映射、布局布线、时序报告和位流生成。
4. 生成的位流位于 `generate_bitstream/hdmi_loop.sbit`。

### TCL 构建

`build_main.tcl` 已列出当前参与综合的全部 RTL 和约束文件，但文件路径写死为：

```text
E:/ZiGuangProject/2_10_hdmi_loop/...
```

在其他目录使用前，必须将这些路径改为实际工程路径或改写为基于脚本目录的相对路径。`program_main.tcl` 中的位流路径同样需要修改。

已有 `generate_bitstream/hdmi_loop.sbit` 是 2026-11-03 的构建产物。重新构建需要有效的 PDS 许可；`HANDOFF.md` 记录的旧许可有效期截至 2026-11-03，当前环境应配置新的许可证。

## 寄存器与软核地址

PicoRV32 地址空间：

| 地址 | 功能 |
|---:|---|
| `0x0000_0000`～`0x0000_7FFF` | 32 KiB RAM，程序复位入口为 `0x1000` |
| `0x0000_8000` | UART 分频寄存器 |
| `0x0000_8010` | UART 数据寄存器 |
| `0x0000_8020` 起 | `reg_bank` 映射区 |
| `0x0000_8420` | 调试 LED |

`reg_bank` 主要寄存器：

| 寄存器偏移 | 属性 | 含义 |
|---:|---|---|
| `0x00` | R | magic `0x504E4750`（`PNGP`） |
| `0x04` | R | `{v_act, h_act}` |
| `0x08` | R | 帧计数和视频稳定标志 |
| `0x0C` | R | 检测数量预留字段 |
| `0x10` | RW | 使能、旁路和模式 |
| `0x14` | RW | 边缘阈值 |
| `0x18` | RW | ROI 上下边界 |
| `0x1C` | RW | 车道线宽度参数 |
| `0x20` | RW | LED 参数 |
| `0x24` | R | 行/链路诊断计数 |

当前顶层已经移除原灰度/Sobel/车道线处理模块的例化，显示通路固定为“原图 + OSD 检测框”。因此 `mode`、`edge_thr`、ROI 和 `lane_w` 仍保留在寄存器表中，但不会改变当前 HDMI 图像。

## 仿真与诊断资源

`source/eth` 中包含多个独立 testbench：

- `video_downsample_tb.v`：降采样和 RGB565 数据检查；
- `eth_udp_video_tx_tb.v`：UDP 视频头与分包；
- `net_video_uplink_tb.v`、`net_video_uplink_full_tb.v`：缓存和跨时钟域整链路；
- `eth_app_rx_tb.v`：检测结果应用层解析；
- `osd_overlay_tb.v`：框坐标、类别颜色和标签叠加。

`tools` 中还提供丢包诊断、尺寸/拉伸检查、框坐标检查、模型比较、串口读取和以太网测试脚本。推荐按照 [docs/联调步骤.md](docs/联调步骤.md) 先验证网络闭环，再接入模型。

## 当前实现限制与注意事项

- **视频格式固定**：当前上传、OSD 和协议字段按 1280×720 → 640×360 配置。
- **实测帧率约 20 fps**：采集与发送目前串行，不能按协议设计稿中的 30 fps 假设验收。
- **上传画面可能带上一次 OSD 框**：顶层刻意从 HDMI 输出寄存级取上传源，以防综合器将 OSD 输出寄存器吸收到 I/O 单元后导致屏幕框消失。
- **无 DDR**：改为更高分辨率或更高帧率前，需要重新评估片上 RAM 和带宽。
- **路径不可移植**：构建 TCL、烧录 TCL 和演示 BAT 都有绝对路径。
- **时序仍需审查**：现有构建成功生成位流，布局布线报告显示约 8% 逻辑利用率，但报告中仍有未约束 I/O 警告，且出现 179 ps 保持余量低于 200 ps 告警阈值。修改 RTL、引脚或时钟后必须重新检查完整时序报告。
- **约束按 720p 编写**：`pixclk_in` 周期为 13.468 ns；若切换到 1080p，需要同时修改像素时钟、输入/输出延迟、OSD/降采样尺寸和协议字段，不能只改顶层参数。
- **框不会自动超时清空**：PC 停止回传后，当前 OSD 会继续使用最后一次成功接收的框表；需要时应在 RTL 中增加超时清空逻辑。

## 常见问题

### PC 完全收不到视频

1. 检查网卡是否为 `192.168.1.105/24`。
2. 检查链路是否协商到 1 Gbps，100 Mbps 通常无法承载当前包流。
3. 检查 HDMI 输入和 HDMI 输出显示器是否都已连接；部分信号源依赖显示器 EDID。
4. 使用 `tools/pc_receiver.py` 的演示模式排除模型问题。

### 能收图但残缺帧很多

- 不要在 UDP 收包线程中执行模型推理。
- 增大系统 UDP 接收缓冲区。
- 检查网卡节能、杀毒软件和防火墙策略。
- 使用 `tools/diag_drop.py` 统计缺失包号。

### FPGA 有画面但没有检测框

1. 先运行不带模型的 `pc_receiver.py`，确认演示框能回传。
2. 检查回传地址是否为广播 `192.168.1.255:5002`。
3. 检查框坐标是否已经换算到 1280×720。
4. 检查 `class_id`、框数量和应用头 magic/version/type。

### 框位置缩小一半或偏移

PC 接收到的是 640×360 图像，但协议要求回传 1280×720 坐标。模型框必须按输入缩放过程逆变换后再乘到原图坐标系，不能直接回传模型输入坐标。

## 相关文档

- [FPGA 与 PC 联调步骤](docs/联调步骤.md)
- [以太网传输协议](docs/以太网传输协议_v1.md)
- [工程交接记录](HANDOFF.md)
- [PicoRV32 子系统说明](source/soc/README.md)

工程中的旧文档记录了不同开发阶段的设想和测试结果。发生冲突时，以当前 RTL、PC 脚本和本 README 标出的“当前实现”为准。
