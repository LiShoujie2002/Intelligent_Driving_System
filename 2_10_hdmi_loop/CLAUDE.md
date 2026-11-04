# 项目工作约定（Claude Code）

## 开始会话

1. **先读 `HANDOFF.md`**（项目状态、下一步、已知坑），不要重新扫全工程。
2. 只读当前任务相关的文件；不确定时先用 Grep 定位，再 Read 片段。
3. **模型端**（桌面 `TriLiteNet-tiny-detect1.0(1)`）和 **FPGA 端**（本工程）
   分不同会话做，避免两边的上下文互相污染。

## 上下文纪律（最重要）

- **禁止整份读取**：
  - `logbackup/`、`compile/`、`place_route/`、`report_timing/`、
    `generate_bitstream/`、`device_map/` 下的日志
  - 任何 `*.hex`、`*.jsonl`、`*.sbit`、`*.pds`
  - `source/soc/picorv32.v`（85 KB，vendor 原样，不需要读）
- 大文件只读片段：`Read` 用 `offset` / `limit`；日志用
  `Select-Object -Last 40` 或 `Select-String`。
- 搜索用 `Grep` + `head_limit`，不要 `Get-Content` 全量输出。
- **探索/审查交给 subagent**，主会话只接收结论，不接收文件内容。
- 不要把完整源码、完整日志、长截图粘进对话；把结果写进文件再引用路径。
- 每个里程碑后更新 `HANDOFF.md` 的“最近进展 / 下一步”，**不要依赖聊天记忆**。
- 长任务前用 `/compact` 压缩；切换主题用 `/clear`（先确认 HANDOFF 已更新）。
- 单个会话尽量只推进一条工作流；需要跨流时新开会话。

## 文件编码

| 文件 | 编码 |
|---|---|
| `hdmi_loop.fdc` | GBK（改它用 PowerShell + 代码页 936） |
| `source/*.v` | UTF-8 + LF |
| `source/cnn/vec/cfg.vh` | GBK（Python 默认编码生成） |
| 其它生成文件 | 先确认编码再写 |

## 常用命令

- 综合/布局布线：PDS 打开 `hdmi_loop.pds`
- CNN 仿真：`source/cnn` 下 `xvlog` / `xelab` / `xsim`
- 测试向量：`python gen_conv_vectors.py <配置名>`
- 固件：`source/soc/firmware/build.bat`，产物 `firmware.hex`
  复制到工程根目录（`$readmemh` 从那里找）

## 交付前

- 更新 `HANDOFF.md`：改了哪些文件、验证结果、下一步
- 时序报告确认 0 个失败端点
- 资源占用记录到 HANDOFF
