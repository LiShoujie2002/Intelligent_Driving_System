# 项目交接说明（HANDOFF）

> 最后更新：2026-11-02
> 本文是从 2026-10-15 ~ 10-23 的长会话里浓缩出来的，目的是让后续会话不必依赖
> 完整聊天记录。原始 transcript 的恢复方法见文末。

---

## 0. 最近进展 / 下一步

**⚠️ 紧急（2026-10-30 发现）**
- PDS 许可 `E:\pango\new_pds_F4A80DA47D72.lic` **2026-11-03 到期**，过期后无法综合/布局布线。
  续期优先级高于一切开发工作。

**最近进展（2026-10-30）**
- 架构改为「FPGA 采集 → 网口送 PC → PC 推理 → 回传检测框 → FPGA 叠加」，
  不再做模型上板（CNN 加速器暂停）。
- 硬件核实：板载 **RTL8211F-CG**，RGMII，引脚见 `docs/以太网传输协议_v1.md` 附录；
  Pango IP 目录**没有**可用于 pg2l200h 的 RJ45 MAC（SGMII/QSGMII/XAUI 只能走 HSST 光口）。
- 写出协议草案 `docs/以太网传输协议_v1.md`（32 字节应用头，UDP，无 ARP，UDP 校验填 0）。
- 发现 `E:\avm_board_work\` 有**同型号 PG2L200H 已验收**的工程：DDR3-800（100 MHz 同域）
  + AXI 仲裁器 + UART 桥 + 脚本化构建流程，可复用；**其中没有任何以太网代码**。
- **找到厂商千兆以太网例程** `E:\aaaaaaaaaaaa\2_11_ethernet_test\`：
  器件 PG2L200H/FBB676/-6，引脚与手册一致，RGMII 125 MHz，
  `All Constraints Met`（WNS +3.367 ns），已生成比特流。
  含完整 MAC/ARP/ICMP/IPv4/UDP 协议栈（`rgmii_interface.v` 封装了
  GTP_ODDR_E1 / GTP_IDDR_E1 / GTP_IDELAY_E2，不用自己碰原语）。
  **这解掉了 RGMII MAC 这个最大风险点。**
- **板上实测（2026-10-30，重要）**：
  - 换了符合 8 芯的 Cat5e 后链路协商到 **1 Gbps**（之前那根只能百兆）
  - 厂商 demo 烧进去后 **一帧都发不出去**（PHY 活动灯在闪、PC 计数全 0）
  - 写了探针设计替代顶层（备份为 `ethernet_test.v.bak`）：绕过厂商协议栈，
    自己产生前导码 + CRC32 FCS，每 1 ms 发一帧，载荷带当前 TX 延时值
  - **结果：30 秒收到 29,984 帧，TX 延时 0..240 全部可通**
  - 结论：**物理层完好，问题在厂商协议栈（`mac_tx` / ARP 状态机）**
  - 关键教训：**MAC 必须自己发前导码和 FCS**，PHY 不补；少了就是 CRC 错、对端丢弃
  - **RX 也验证通过**：探针帧载荷里回传 FPGA 的接收计数，30 秒内收到 3 帧
    （每帧 72 字节 = ARP 广播的最小帧），`errors = 0`
  - 至此 `rgmii_interface.v` **收发双向都在板上验证可用**，可当黑盒使用
- 工具链要点（省时间）：
  - `pds_shell.exe -file impl.tcl` **不会加载现有工程**，必须自己写 build tcl
    （见 `build_probe.tcl`：`set_arch` + 逐个 `add_design -verilog` + `add_constraint -fdc`）
  - 工程里有厂商插的 **Fabric Debugger**，探针绑在 `eth_udp_test` 内部信号上；
    一旦改动顶层，dev_map 会报 `Inserter-0005: Net ... cannot be found` →
    需删掉 `.pds` 里的 `wgt_my_fic_src` 块并把 `.fic` 改名（已处理，备份 `.bak`）
  - 烧录流程：`cdt_js.exe -work_dir <dir>` 起 JtagServer（端口 65420），
    再 `cdt_cfg_shell.exe -file program_probe.tcl`
  - **JtagServer 偶尔首次 `cfg_scan_chain` 报 "No devices detected"**，
    重启 cdt_js 并等 12 秒即可，不是硬件问题
- 协议文档升级到 **v1.3**：上传尺寸改为 **640×360（÷2 精确抽取 + 2×2 均值）**，
  不再绑定某个模型输入尺寸（新模型在 PC 上，输入分辨率未知）
- **自研 UDP 发送器完成并板上验证**（`source/eth/`）：
  - `eth_frame_tx.v`：前导码 + MAC 头 + 数据 + CRC32 FCS + 最小帧填充
  - `eth_udp_tx.v`：IPv4 头（组合逻辑算校验和）+ UDP 头（校验和填 0）
  - 实测：**7,302 pkt/s × 1440 字节 = 87.9 Mbit/s，序号零丢包**
  - IPv4 校验和正确性由「Windows 协议栈能投递到 socket」间接证明
- **修掉一个致命自锁环**：`phy_rstn = rstn`（PLL 锁）而 PLL 输入是 PHY 的
  `rgmii_rxc` → 烧录时 PHY 被复位、不再输出 RXC、PLL 永远锁不上。
  **每次烧录有概率锁死网口**。改为 `phy_rstn = 1'b1`（板上拉 + PHY 内部上电复位）。
  **主工程必须照此处理。**
- **自研接收链完成并板上验证**（`source/eth/`）：
  - `eth_rx.v`：剥 8 字节前导码，输出 `dv/data/byte_idx/sof/eof`
  - `eth_udp_rx.v`：逐字节比对 MAC/EtherType/IPv4/端口，通过后吐 UDP 载荷
  - 实测：PC 广播发 200 个包，FPGA **解析 200 个，包长 32、首字节 0x50 全部正确**
  - 踩坑：`sof` 与 `case(byte_idx==0)` 同拍写 `mac_me`，Verilog 后写的赢，
    写成 `mac_me & ...` 会用上一帧旧值导致复位后恒 0。首字节必须**直接赋值**。
- **视频分包发送完成并板上验证**：`eth_udp_video_tx.v`
  - 640×360 RGB565 → **320 包/帧**，每包 32B 应用头 + 1440B 图像
  - 实测：**109 帧连续，每帧 320 包、460,800 字节逐字节一致，0 错误**
  - PC 端脚本 `--video` 能重组并保存 `tools/eth_video_frame.png`
  - 踩坑：**包间必须留间隔**（`PKT_GAP` 参数）。背靠背发 320 包是 3.8 ms
    内 480 KB ≈ 线速，PC 软件收包会丢；间隔 20000 拍（≈5.8k pkt/s）时零丢包
  - **30 fps 已验证通过**：`PKT_GAP=11000` → ~10k pkt/s，
    实测 **20 秒 600 帧，逐字节一致，仅首帧（socket 未就绪）失败**
  - 重要经验：**PC 端收包循环里不能做重活**。最初用纯 Python 逐字节比对
    46 万字节要几百毫秒，期间 socket 缓冲被后续几帧撑爆，表现为大量丢包
    （看起来像链路问题）。改用 numpy 向量化后立刻正常。
- **降采样器 `video_downsample.v` 已完成并板上验证**
  - 实测：合成 1280×720 → 2×2 均值 + ÷2 → **297 帧逐字节一致，0 错误**
  - 装的工具：**Icarus Verilog**（`C:\iverilog\bin`，`iverilog` + `vvp`），
    testbench 见 `source/eth/video_downsample_tb.v`、`eth_udp_video_tx_tb.v`
  - 修的 4 个 bug：
    1. **Verilog 乘法位宽**：`a*b` 结果位宽 = max(两操作数)，不是相加。
       `ds_y[8:0] * 10'd640` 只保留 10 位、>1023 回绕 → 整帧地址乱。
       必须写成 `({8'd0,ds_y} * 18'd640)`。
    2. **帧间隔阈值**：100000 太大（合成源垂直消隐仅 ~50400 拍），行号从不复位。
       改 5000（720p 垂直消隐 ~49500、水平消隐 ~370，两头都有余量）。
    3. **帧同步竞态**：`y` 清零与 `frame_sync` 同拍；清零改到消隐期内。
    4. **水平窗口右偏一列**：`de_out` 条件 `x_d1[0]` → `!x_d1[0]`，
       窗口才落在 (0,1) 而不是 (1,2)。
  - **PC 端也有个 bug**：`np.stack([hi, lo], axis=1)` 得到 (H,2,W) 而不是
    (H,W,2)，字节顺序全乱 —— 一度让所有比对基准都是错的。
    必须用 `np.empty((H,W,2))` 显式赋值。
  - `eth_udp_video_tx` 新增 `FB_PREFETCH` 参数（帧缓存读延迟补偿）：
    `eth_video_test` 的合成源用 1，`eth_ds_test` 的双口 RAM 用 1（实测一致）。
- **跨时钟域结构已验证**（`eth_ds_xclk_test.v`）：
  - 像素域（62.5 MHz 测试时钟，真实工程是 74.25 MHz）跑降采样 + 写帧缓存，
    网络域（125 MHz）读帧缓存 + 分包发送
  - 双口 BRAM + toggle 握手，**330 帧逐字节一致**（1 帧因 PC 端偶发丢包未收全）
  - 这是并入主工程前的最后一个结构性未知点，现已排除
- **应用层接收解析完成**（`eth_app_rx.v`）：
  - 解析 32 字节协议头（magic/version/msg_type）+ 16 字节/框，最多 32 个框
  - 先用暂存区，整帧校验通过才一次性提交，避免坏帧把正在显示的框改坏
  - 仿真（`eth_app_rx_tb.v`）+ 板上都验证：PC 发 240 个检测包，
    **240 个全部解析正确**，帧号 `0x00ABCDEF`、框数 1、
    坐标 `(111,222)-(333,444)`、类别 2、置信度 88 全部吻合
  - 踩坑：`buf` 作为标识符在 iverilog 里会报语法错误，改名即可
- **以太网已并入主工程 `2_10_hdmi_loop`，闭环打通**
  - `hdmi_loop.v` 新增：net_clk（PHY 的 rxc 经 PLL）、`rgmii_interface`、
    `net_video_uplink`（降采样+帧缓存+发送）、`net_rx_path`（接收+CDC）、`osd_overlay`
  - `hdmi_loop.fdc` 追加 RGMII 引脚 + `create_clock net_clk` + 跨域 false_path
  - **PHY 复位复用已有的 `rstn_out`（G25，配置后 1ms 拉高）**，不要新建 phy_rstn 端口
  - 实测：**真实 HDMI 画面 640×360 @20fps 上传，零丢包**
  - 实测：**PC 发检测框 → FPGA 解析 → 屏幕画框，位置一分不差**
    （逐像素验证：框在 (200,150)-(800,500)，红 `0xF800`）
  - 视觉调试小技巧：`UPLINK_FROM_OSD=1` 让上传流取自叠加后，PC 就能
    直接量出框的位置，不依赖人眼；验证完记得改回 0
  - 固件：去掉 4 种模式轮换，固定 `mode=0`（原图）+ OSD 叠加；
    车道线识别已取消（`lane_detect.v` 仍在工程里但不再使用）
  - 诊断开关（默认都为 0，保留备用）：`OSD_DIAG`（三色指示 RX 状态）、
    `UPLINK_FROM_OSD`
- **★ 完整闭环打通（2026-11-02，最终形态）**
  ```
  HDMI 输入 → ÷2 降采样 640×360 → 网口 → PC(YOLOP v3) → 回传坐标 → OSD 画框 → HDMI 显示
  ```
  - 实测：**19.4 fps，每帧 8~13 个框，绿框正常框住车辆并跟随运动**
  - 吞吐：推理 38.9 ms/帧（GPU），端到端 19.4 fps，残缺 1 帧/900 帧
  - **四条必须记住的坑**（都现场踩过）：
    1. **六个视频输出（DE/HS/VS/RGB）必须在同一个 always 块里寄存**。
       分成两个块（OSD 内部寄存 DE/RGB、顶层单独寄存 HS/VS）会让
       MS7210 采样不稳，表现为**画面左右抖动**。
    2. **上传通路必须取自输出寄存级本身**（`de_r/rr/gr/br`），
       **不能改成 `vid_in_r`**。改成取原始输入后屏幕就不画框了 ——
       这一级寄存器需要上传通路作为它的内部扇出，否则会被综合
       优化进 I/O 单元，画框数据丢失。
    3. **烧录后要等 8~10 秒再判断**。链路和 HDMI 还没就绪时表现为
       "一包都不发/没有画面"，极易误判成故障。
    4. **显示器必须接着**。拔掉后 PC 拿不到 EDID 会停 HDMI 输出，
       FPGA 没有像素时钟 → 整条链路静默失效，看起来完全像网络故障。
  - 模型侧：YOLOP v3（640×384 等比补边，四类 vehicle/person/rider/traffic_light）
    - 适配层 `tools/yolop_adapter.py`：含 torch 1.8.1 兼容补丁
      （`inference_mode` → `no_grad`、去掉 `weights_only`），
      类别映射 vehicle=0/person=1/traffic_light=2/rider=3，
      坐标 ×2 从 640×360 换回 1280×720
    - 环境：`E:\anaconda3\envs\my_pytorch\python.exe`（torch 1.8.1+cu111，RTX 3050 Ti）
    - PC 端运行：`python pc_receiver.py --model <包目录> --device cuda:0 [--show] [--record x.mp4]`
  - 注意：模型看到的画面里带有已画好的框（2 像素细线），实测不影响检测效果

- **已整理成可交付给队友联调的状态**：
  - `docs/以太网传输协议_v1.md` 升到 **v1.4**，寻址章节与实现逐条对齐
    （FPGA 发广播 MAC + 目的 IP 写死 192.168.1.105；PC 发 192.168.1.255:5002；
    不做 ARP；PC 不需要管理员权限）
  - `tools/pc_receiver.py`：队友侧的参考实现，收帧/解码/回传都封装好，
    接模型只要改一个函数；自带演示模式（画一个移动的框）可直接验证闭环
  - 实测：`pc_receiver.py` 收 161 帧零残缺、20 fps、每帧回传 1 个框

- **OSD 加分类序号（2026-11-02 晚，板上已验证）**
  - 现象：PC 窗口/录像里的框带数字，板子显示器上只有颜色 → 因为
    **FPGA 侧没有字库**，`osd_overlay` 原来只能画纯色矩形。
  - `osd_overlay.v` 新增 10 位数字的 8×8 点阵（内置 `font_digit()` 函数），
    在框**左上角上方** `(bx1, by1-17)` 画 `LBL_W×LBL_H` 的**黑底 + 类别色数字**。
  - 新增参数：`LABEL_EN`（默认 1，可关）、`LBL_SCL`（默认 2，即 16×16 像素）。
  - **字模查表只做一份，放在 32 次循环之外**（先记下命中的框索引，
    循环后统一查表）。放进循环里会复制 32 份 ROM mux，面积和延迟都不划算。
  - `by1 < 17` 时 `by1-17` 下溢成 655xx，比较恒假，序号自然不画 —— 不会跑出屏幕。
  - 自检 `osd_overlay_tb.v`：四个类别各一个框，逐像素统计。
    点数与字模位 1 个数严格吻合（'0'=28 点×4='112px'，'1'=19→76，'2'=22→88，'3'=23→92），
    余下像素全黑，`PASS`。
  - 综合：最差 slack **+407 ps**，LUT 10901/159800（12.2%），已烧录，
    **板上目视确认：红框 + 红色数字 `2`**（用 `pc_receiver.py` 自带演示模式验证，
    不依赖模型和 HDMI 源内容）。

- **评估结论：不改摄像头输入（2026-11-02，已决定不做的方向）**
  - 背景：有官方 FMC 扩展板、OV5640 已接好；参考工程 `E:\aaaaaaaaaaaa\HDMI_DDR3_OV5640_100h`
    （PG2L100H-6FBG676）。两者 `.fdc` 逐端口比对：**29 个同名端口引脚全一致**
    （含 MS7210 的 `hd_scl`=K22 / `hd_sda`=K23），引脚大概率可复用，但要实测确认。
  - **不能改的原因**：本工程是直通架构（`pixclk_out = pixclk_in`），HDMI 输入同时是
    全系统的时钟和时间基准；摄像头 PCLK 84 MHz/16 位域 42 MHz、只有 VSYNC+HREF
    没有 HS、帧率 30，三者都对不上 → 必须补 DDR3 帧缓存 + 本地时序发生器。
  - **BRAM 装不下**：DRM 36 Kb×415 = 1.867 MB；720p RGB565 一帧 = 409.6 DRM，
    当前已用 140.5，单缓冲 550 > 415。所以 720p 必须上 DDR3。
  - 若将来重开：DDR3 IP 用 `E:\avm_board_work`（同型号已验证）；
    **第一步永远是先做摄像头探针验证引脚，不要直接动主工程**。
  - 更短的替代路线（未采纳）：摄像头配 640×480 + 输出 VGA，单缓冲 136.5 DRM
    塞得进 BRAM，不用 DDR3，但协议和 PC 端坐标要跟着改。

- **30fps 乒乓改造：已回退，未成功（2026-11-02 晚）**
  - 目标：原来采集（16.7ms）和发送（32ms）串行，周期 48.7ms = 20fps。
    改成两块 bank 后应只受发送限制 = 32ms ≈ 31fps。
  - **结论：改造后每帧第 0 号包系统性丢失（184 帧里丢 176 次），帧几乎全部残缺，
    回退到原版。原版实测 159/161 完整帧，第 0 号包只丢 1 次。**
  - 改造过程中确认修好的两个真 bug（以后再动这块要带上）：
    1. **网络域复位后死锁**：`outstanding<2` 门限会让采集停摆，而网络侧
       `cap_done_tog` 翻了两次后回到复位值，边沿丢失 → 永远不发、网口 0 包。
       修法：网络域给一个 `net_alive` 电平，像素域等它有效再采集，且
       采集 FSM 的复位跟着 `net_alive` 走（`pix_cap_rstn`）。
    2. **帧间必须有间隔**：`vid_done` 只表示最后一个数据字节被 UDP 层取走，
       此时 MAC 还在发 FCS，加上以太网最小帧间隔 96ns —— 相邻帧紧挨着会让
       新帧打头就出问题。加了 `FRAME_IFG` 计数器。**这个修复本身没解决丢包，
       但道理是对的，保留在 WIP 版本里。**
  - **未解之谜（下次接手从这里开始）**：加 1.6ms 帧间隔后第 0 号包仍然丢。
    已排除：网卡侧 0 错误 0 丢弃；`macpkt_cnt`（tx_en 上升沿）显示 FPGA 确实
    约 10k 包/秒 ≈ 320 包/帧，但网卡只收到 7.5k。怀疑点：MAC 在帧边界处
    与 PHY 的交接，或 `eth_udp_video_tx` 的 `frame_start` 处理。
    **建议下一步**：把 PKT_GAP 调大让包率降到 6.4k（和老版本一样），
    如果第 0 号包回来了，就说明是速率/PHY 能力问题而不是逻辑问题。
  - 资料都在 `wip_pingpong/`：改造版 RTL、两个 testbench、丢包诊断脚本、
    综合日志。源文件已恢复成改造前（`net_video_uplink.v` 与备份逐字节一致）。
  - 诊断工具（留着有用）：`tools/diag_drop.py` 抓 8 秒统计缺哪些包号；
    `tools/read_dbg.ps1` 带时间戳读串口调试字。

- **模型换成 YOLOP v5 + 红绿灯按灯色上色（2026-11-03）**
  - **v5 交付包**：`C:\Users\Lenovo\Desktop\YOLOP_v5_第122轮最佳_交付包_20261102`，
    已建 ASCII 快捷方式 **`C:\yolop_v5_pkg`**（v3 的是 `C:\yolop_pkg`，两个都留着）。
  - **v5 在 torch 1.8.1 上可直接跑**（包里的 requirements 写 torch>=2.7，实际不需要升级）：
    `yolop_adapter.py` 里已有的兼容补丁（`inference_mode` → `no_grad`、
    去掉 `weights_only`）已经够用，**适配层一行没改**——v3/v5 的
    `Predictor` 接口和返回结构完全一致，类别按名字映射，映射表可直接复用。
  - 实测：加载 1.8 s，推理 **36.7 ms/帧**（v3 是 38.9），示例图检出 9 个目标、异常框 0。
  - `run_demo.bat` / `run_record.bat` 已指向 `C:\yolop_v5_pkg`。
  - **红绿灯颜色上屏**：协议第 9 字节（subclass）以前被 `eth_app_rx` 直接跳过，
    现在解析了。改动 4 个文件：
    `eth_app_rx.v`（加 `o_sub`）、`net_rx_path.v`（跨域搬运）、
    `hdmi_loop.v`（连线）、`osd_overlay.v`（类别 2 按灯色选颜色）。
  - 颜色规则：红 `(255,0,0)` / 黄 `(255,255,0)` / 绿 `(0,255,0)` / **未知=灰 `(128,128,128)`**。
    **注意：以前交通灯一律画红，现在未知会画灰。** 车绿、人黄、骑行白不变。
  - 验证：`osd_overlay_tb` PASS（类别 2 给了 sub=3 → 绿）、`eth_app_rx_tb` OK，
    板上用 `tools/test_lightcolor.py` 四色循环目视确认 ✓。
  - 时序满足，DRM 仍 140.5（灯色只多了几百个触发器）。
  - **firmware.hex 已重新生成为干净版（2660 字节）**——之前 11-02 18:37 那份
    是带调试打印的 2870 字节版本，注意不要用错。

- **框"异常拉长"的最终定论（2026-11-03）**
  - **FPGA 侧的原因已经修掉**：框表原来收到就立刻更新（约 20 次/秒，和 60Hz
    视频帧完全异步），撞上扫描中途就会上半屏旧框、下半屏新框。
    修法：`osd_overlay.v` 里加**帧消隐期锁存**（`dnbox/dbx1.../dbsub`，
    在 `frame_begin` 时整表锁入）。修完飞框**明显减少**。
  - **剩下的是模型输出本身**：让用户同时看 PC 那个小窗口（OpenCV 画的、
    同一份坐标、无跨时钟域、分辨率更高），**小窗口里也会偶尔飞框**。
    所以残余部分不在 FPGA，别再往硬件上找。
  - 数据佐证：`boxes_v5.csv` 1132 帧 / 11676 个框，按 IoU≥0.5 配对的
    6776 对里，宽或高突变 ≥2 倍的只有 **2 次（0.03%）**，且都是 24×26
    级别的小框波动。最大框 468×416，越界 0、反向 0。
  - **用户决定不再追这个（"不改了，这样吧"）**。这一版就是最终版。

- **★ 新踩的坑：反复烧录后 PHY 接收通路会卡死（2026-11-02 晚）**
  - 现象：**画面正常、网口在发数据（PC 能收满帧 20fps），但屏幕上没有框**。
    PC 侧确认每帧都在回传 11~23 个框，`sent_broadcast` 计数 20/秒正常，
    接收模块的 MAC 广播过滤也没问题，OSD 的 `enable` 硬接 `1'b1`。
  - 结论：**TX 正常、RX 不通**。反复 JTAG 烧录之后 PHY 会进这个状态，
    RGMII 接收延时是固定值（`delay_step_b=8'd247`，没有自适应），
    所以不是校准漂移，是 PHY 内部状态坏了。
  - **唯一有效的恢复办法：整板断电 5 秒再上电**，然后重新烧录。
    单纯重新烧录不够（试过两次都没用）。
  - 判断方法：用 `pc_receiver.py` 不带 `--model` 跑（固定发一个红框），
    红框出现=RX 正常；红框不出现但 PC 确实在发=PHY 要断电。
  - **以后遇到"画面正常但没框"，第一件事就是断电，别去改代码。**

- **★ 最终定版：2026-11-02 14:51 那一版（加完分类序号、未动乒乓）**
  - 用户明确认定这是"完美"的版本。**后续不要再在原工程上改。**
  - 码流：`generate_bitstream/hdmi_loop.sbit`（14:51 生成，9188552 字节）
    和 `backup_20261102_1659_before_pingpong/hdmi_loop_before_pingpong.sbit`
    以及 `backup_20261102_osd_framelatch/hdmi_loop_WORKING_20fps.sbit` 是同一个文件。
  - 源码：`source/eth/net_video_uplink.v` 与同名备份逐字节一致；
    `source/eth/osd_overlay.v` 是 181 行的序号版（无帧锁存）。
  - 实测：299 帧、1 残缺、18~19 fps、每帧 8~20 个框。
  - **2026-11-02 晚复测确认（断电恢复后）**：真模型绿框正常框住车辆并跟随，
    用户确认"框得很好，是完美版本的感觉"。**这一版就是交付版本。**
  - 曾被尝试并已回退的两个方向（都留了资料，别再原地重试）：
    1. 乒乓提帧率 → `wip_pingpong/`，见上面那条
    2. OSD 框表帧消隐锁存（修"框边飞出"）→
       `backup_20261102_osd_framelatch/osd_overlay_after.v`，综合被中止未上板

- **`pc_receiver.py` 两处修（2026-11-02 晚）**
  - **Ctrl+C 会弄坏录像**：原来 `recorder.release()` 写在循环之后，
    中断时执行不到 → mp4 索引没写完、文件打不开。改成 `try/except/finally`，
    任何退出方式都会关闭录像。
  - `run_record.bat` 加 `--show`：录制时有窗口，按 ESC 能停；
    之前纯录制模式没有窗口，ESC 根本收不到事件。

**最近进展（2026-10-23）**
- 恢复长会话文本，建立本接手文档
- 确认模型仓当前 checkpoint 是旧 b2 结构，与代码不兼容（`strict=True` 会失败）
- 确认实际训练输入是 416×256（letterbox 后），不是 416×416
- 建立 `CLAUDE.md` 上下文纪律
- **`conv3x3_layer` 全配置回归通过**：standard / stride2 / dil2 / dil4 / dil16 /
  wide / wide_dw / real_dw / real_l1 全部逐位一致
- **`conv_layer_top.v` 流式整层引擎 v0 完成**：11 个配置全部逐位一致
  （含 `real_b1` 346112 项、`real_dw` 378560 项、`real_l1` 173056 项）
- 修复三个实现级 bug：
  1. `acc_mem` 整向量相加导致负通道借位串到相邻通道（偶发 +1）→ 改成逐 32 位通道独立相加
  2. depthwise 权重地址把全局输入通道和组内偏移混用 → 拆出 `wt_ci`
  3. `window_gen.valid_out` 对齐窗口左上角 w00，不是右下角 w22 →
     输出坐标用 `py_w1 - 2*DILATE`（padded 坐标再减一个 padding）
- `line_delay` 增加行缓存零初始化，消除第一行 X

**下一步（硬件侧）**
1. `conv_layer_top` 的 1×1 pointwise 模式（当前只支持 3×3 + depthwise）
2. 分块/tile 累加：v0 的 `acc_mem` 按整层输出实例化，real_b1 需要 ~2 MB，
   上板前必须改成按行/按 tile 累加
3. `line_delay` 的零初始化改成复位清零（或确认 Pango 支持 BRAM 初值）
4. 层描述符 + manifest → 硬件参数生成脚本
5. 特征图缓冲接口与片上 BRAM 预算定稿
6. 视频前端降采样器（参数化 1280×720 → W×H）

**模型侧（队友负责）**
- 用新 b2 重新训练
- 评估是否把输入改成 512×288
- 导出 manifest / int8 权重 / 黄金模型

> 会话纪律见 `CLAUDE.md`；每次里程碑后更新本节，而不是把聊天当记忆。

---

## 1. 目标与范围

- 全国大学生嵌入式芯片与系统设计竞赛 2026 · 紫光同创赛道 · 赛题三（ADAS）
- 板卡：小眼睛盘古 200Pro，FPGA `PG2L200H-6FBB676`
- 已确认：**只做基础任务**；视频输入**只走一路 HDMI**
- 三个基础任务：
  1. 图像采集与显示（采集—处理—显示闭环）
  2. 软硬协同通信（MCU/软核 ↔ FPGA）
  3. 图像处理与识别（道路环境监测）

> 注意：10/22 晚的实际工作已经推进到 CNN 卷积加速器（检测模型），
> 这与“基础任务不需要 AI”的早期判断不一致。属于待确认的范围问题。

---

## 2. 当前 RTL 架构

```
HDMI RX (MS7200)
   │ pixclk_in / de / hs / vs / RGB
   ▼
输入 IOB 寄存器 vid_in_r
   │
   ├──► video_timing ──► h_act/v_act/frame_cnt/stable ──► CDC ──┐
   │                                                            │
   ▼                                                            │
video_process（像素域，逐像素流水，延迟 1 行 + 4 像素）           │
   灰度 → 双行缓存(整行含消隐) → Sobel → 二值化 → 模式叠加       │
   │        └──► lane_detect（ROI 分带 + 左右半区质心）           │
   ▼                                                            │
HDMI TX (MS7210)                                                │
                                                                │
PicoRV32 (cfg_clk 10MHz) + 32KB RAM + UART 115200 ──► reg_bank ──┘
```

- 像素域：`pixclk_in`，当前按 **720p / 74.25 MHz** 约束
- 控制域：`cfg_clk` = PLL CLKOUT0 = **10 MHz**
- 两个域只交换准静态信号，RTL 两级同步 + fdc `set_false_path`

### 文件地图

| 文件 | 作用 |
|---|---|
| `source/hdmi_loop.v` | 顶层、CDC、流水线接线 |
| `source/video_process.v` | 灰度 / 双行缓存 / Sobel / 二值 / 叠加 |
| `source/lane_detect.v` | 分带质心车道线检测（无除法） |
| `source/video_timing.v` | 数 de 测分辨率、帧计数、稳定标志 |
| `source/reg_bank.v` | 软核 ↔ 硬件寄存器组 |
| `source/soc/picosoc_lane.v` | PicoRV32 + RAM + UART + 寄存器总线 |
| `source/soc/firmware/main.c` | 固件：自检、读时序、切模式、心跳灯 |
| `source/cnn/*.v` | CNN 加速器单元（未进 PDS） |
| `hdmi_loop.fdc` | 引脚 + 时序约束（**GBK 编码**） |
| `hdmi_loop.pds` | PDS 工程文件 |
| `firmware.hex` | 软核程序（`$readmemh` 从工程根目录读） |

---

## 3. 已验证的现状（2026-10-22）

### 3.1 顶层构建

- bitstream：`generate_bitstream/hdmi_loop.sbit`（9.19 MB）
- 时序：**0 个失败端点**
  - `pixclk_in` 建立 WNS = +0.964 ns（slow）/ +5.817 ns（fast）
  - `cfg_clk` 建立 WNS = +86.552 ns
- 资源：LUT 2,987（1.87%）、FF 2,220、APM 11/740、DRM 15.5/415、IO 63/400

### 3.2 视频链

- Sobel + 双行缓存 + 4 种模式：原图 / 纯边缘 / 边缘叠加 / 车道线叠加
- 行缓存**整行含消隐**，用 `hs` 定界（不能用 `de`，否则消隐期 de 常 1，MS7210 锁不上）
- 输出相对输入延迟恒为 **1 行 + 4 像素**

### 3.3 软硬协同

- PicoRV32 @ 10 MHz，UART 115200（分频 86）
- 固件流程：读 magic `0x504E4750` → 等 video_stable → 打印 H/V_ACT → 读行计数
  → 依次切 4 种显示模式 → 心跳灯
- 可写寄存器：`mode / bypass / edge_thr`
- 已上板跑通过的结论来自历史会话；工程里没有留上板日志

### 3.4 CNN 加速器单元

| 单元 | 验证 |
|---|---|
| `line_delay.v` | ✅ DEPTH=31/47 |
| `window_gen.v` | ✅ D=1/2/4/8/16 |
| `mac9x8.v` | ✅ 300 拍 × 8 通道（流水 OFFSET=2） |
| `acc_mem.v` | ✅ 64 项 × 2 通道 × 3 趟 |
| `conv3x3_layer.v` | ✅ `real_b1`（208×208, 7→8）输出与黄金模型逐位一致 |

性能估算：72 MAC/周期 × 150 MHz = **10.8 GMAC/s**，181 M MACs/帧 → **16.8 ms/帧 ≈ 60 fps**。

---

## 4. 阶段计划（来自 10/22 会话）

```
阶段 A  CNN 计算内核
  ✅ line_delay / window_gen / mac9x8 / acc_mem
  ⬜ conv_layer_top 整层集成
  ⬜ 补测 dw / stride2 / dil2 / dil4 / dil16 配置

阶段 B  给 CNN 喂图
  ⬜ 降采样器 1280×720 → 模型输入
  ⬜ 输入帧缓存（416×416×3 ≈ 519 KB；若 512×288 ≈ 442 KB）
  ⬜ 视频通路 → CNN 的握手接口

阶段 C  跑通整个网络
  ⬜ 权重 ROM + manifest 加载
  ⬜ 层调度状态机
  ⬜ 特征图双缓冲管理

阶段 D  出结果
  ⬜ 检测头解码（sigmoid/exp/anchor）
  ⬜ 检测框 → reg_bank → 软核 NMS
  ⬜ OSD 画框
```

片上 DRM 总量 1.87 MB，单张输入图最大约 519 KB，双缓冲峰值约 1 MB，
**先按片上做，DDR3 作为后备**。

降采样方案待定：等比缩放 + 上下留黑边（推荐）/ 拉伸 / 中心裁剪。
1280×720 → 416×416 不是整数倍，且宽高比不同。

---

## 5. 已知缺口 / 风险

1. **CNN 未进 PDS**：`hdmi_loop.pds` 源文件列表没有 `source/cnn/*.v`。
2. **`conv3x3_layer` 是功能验证版**：每像素串行乘加，不是流式性能版。
   流式版需要把 `window_gen + mac9x8 + acc_mem` 拼成 `conv_layer_top`。
3. **运行时参数没接线**：`cfg_roi_top / cfg_roi_bot / cfg_lane_w / cfg_en`
   在 `reg_bank` 里可读写，但 `lane_detect` 用硬编码 720p 参数，改了不生效。
4. **分辨率状态不一致**：fdc 按 720p 约束；注释说切 1080p 要改 6.734 ns，
   同时还要改 `lane_detect` 参数、ROI、LINE_MAX。
5. **隐式线网**：`hdmi_loop.v` 的 `rx_init_done / rx_rst_n` 未声明，
   目前无害，但会掩盖拼写错误。
6. **无版本管理**：不是 git 仓库，日志/备份 300+ 文件。
7. **模型 checkpoint 与代码不匹配**（详见第 6 节）。

---

## 6. 模型侧现状（`..\lane_sim\` 与桌面仓库）

- 模型仓库：`C:\Users\Lenovo\Desktop\TriLiteNet-tiny-detect1.0(1)`
- 检测 3 类：`vehicle / person / traffic_light`，外加红绿灯颜色 4 类
- 10/22 重新 profile：**181 M MACs @416×416，117,317 参数**
- `b2` 已改为深度可分离；但仍保留 `DepthwiseESP` 的 dilation 1~16、FPN/PAN、YOLO 头
- tiny 通道配置非常小：`[4, 8, 16, 32, 64]`

### 关键发现：现有 checkpoint 是旧结构

- `runs/bdd100k_detector_tiny_epochs240/best_weights/best_ema.pth`（10/22 10:06）
- 里面的 b2 键是旧的 `model.0.b2.conv.weight / b2.bn.*`
- 当前代码的 b2 是 `DepthwiseSeparableConv`，键应为 `model.0.b2.0.depthwise.weight` 等
- `tools/test.py` 和 `tools/demo.py` 都是 `strict=True` 加载 → **现在直接跑会报不兼容**
- `tools/train.py` 支持 `strict=False` 热启动，但新的 b2 会随机初始化

因此：**旧 checkpoint 不能代表当前结构，必须用新 b2 重新训练后再评估。**

---

## 7. 关键设计约定 / 坑

- **编码**：`.fdc` 是 GBK；`source/*.v` 是 UTF-8 + LF；
  `source/cnn/vec/cfg.vh` 是 Python 默认编码生成的（GBK）。
  改 `.fdc` 必须用 PowerShell 显式指定 936 代码页。
- **行缓存**：`LINE_MAX >= H_TOTAL`（720p=1650，1080p=2200）。
- **Sobel 延迟记账**：叠加用 `w_d1`（列 c-4），不能用 `w_d2`。
- **lane_detect 无除法**：`|x*cnt - sum| <= LANE_W*cnt`。
- **固件**：改 `main.c` 后要重新综合（`$readmemh` 烧进 BRAM），
  并把 `firmware.hex` 复制到工程根目录。
- **`build.bat` 必须是纯 ASCII + CRLF**。原先的版本是 LF + UTF-8 中文，
  `cmd.exe` 会把整个文件当一行解析，报一堆 `'xxx' is not recognized`。
  控制台代码页 65001 / ANSI 936 不一致时，批处理里的中文还会吞括号。
  现在脚本已改成纯英文，改它的时候别再加中文注释。

---

## 8. 建议的接手顺序

1. 先补跑 `conv3x3_layer` 的 dw / stride2 / dil2 / dil4 / dil16 向量测试。
2. 写 `conv_layer_top.v`（padded 流 + 输出通道组循环 + 重定标），逐位比对。
3. 确定降采样方案，写降采样器 + 输入帧缓存。
4. 模型侧用新 b2 重新训练，并把输入从 416×416 改为 **512×288（16:9）**。
5. CNN 进 PDS，做上板回归。

---

## 9. 长会话上下文恢复

原始 transcript：
`C:\Users\Lenovo\.claude\projects\e--ZiGuangProject-2-10-hdmi-loop\be932f95-060b-4c79-8239-933172616f12.jsonl`

抽取纯文本（PowerShell，UTF-8 读取）：

```powershell
$p='C:\Users\Lenovo\.claude\projects\e--ZiGuangProject-2-10-hdmi-loop\be932f95-060b-4c79-8239-933172616f12.jsonl'
$lines=[System.IO.File]::ReadAllLines($p,[Text.Encoding]::UTF8)
foreach($ln in $lines){
  $o=$ln|ConvertFrom-Json
  if($o.type -in 'user','assistant'){
    foreach($b in $o.message.content){ if($b.type -eq 'text'){ $b.text } }
  }
}
```

本次抽取得到约 295 KB 文本，关键结论已浓缩到本文。
之后遇到上下文超限，**先写 HANDOFF，再继续**，不要把整段聊天当记忆。
