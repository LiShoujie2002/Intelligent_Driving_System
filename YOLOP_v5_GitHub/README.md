# YOLOP v5 多任务道路场景推理

本目录是一套面向道路视频的 **YOLOP v5 推理交付包**。模型在一次前向计算中完成目标检测、可行驶区域分割和车道线分割，并对检测到的交通灯使用 HSV 规则进行红、黄、绿二次判色。

当前代码仅包含推理链路，不包含训练、数据集制作或指标评测脚本。

## 功能概览

| 功能 | 当前实现 |
|---|---|
| 目标检测 | `vehicle`、`person`、`rider`、`traffic_light` 四类 |
| 交通灯判色 | 在交通灯检测框内进行 HSV 分析，输出 `red`、`yellow`、`green` 或 `unknown` |
| 可行驶区域分割 | 输出与原图等尺寸的二值掩码 |
| 车道线分割 | 输出与原图等尺寸的二值掩码 |
| 输入类型 | 单张图片、单个视频、仅扫描一层的文件夹 |
| 输出类型 | 标注图/视频、JSON/JSONL 检测结果、分割掩码和运行记录 |

## 目录结构

```text
YOLOP_v5_GitHub/
├─ infer.py                    # 命令行推理入口，处理图片、视频和目录
├─ model.py                    # 权重加载、预处理、模型推理和后处理接口
├─ render.py                   # 检测框、中文标签和分割结果可视化
├─ traffic_light_color.py      # 交通灯 HSV 判色与小目标候选工具
├─ requirements.txt            # Python 依赖
├─ weights/
│  └─ v5_best_det4.pth         # 第 122 轮四类检测、多任务权重
└─ lib/
   ├─ models/                  # YOLOP 网络结构与基础模块
   ├─ core/                    # NMS、评估等通用逻辑
   └─ utils/                   # 图像增强、绘图、锚框等辅助代码
```

## 环境要求

- Python 3.10 或更高版本，推荐 Python 3.12。
- PyTorch 2.7 或更高版本；GPU 推理时安装与本机 CUDA 匹配的构建。
- FFmpeg 由 `imageio-ffmpeg` 提供，用于视频编码和原音频转码。
- 中文标签需要微软雅黑或 Noto CJK 字体。

安装依赖：

```bash
python -m pip install -r requirements.txt
```

如果需要 NVIDIA GPU，请先按照本机 CUDA 环境安装对应版本的 `torch` 和 `torchvision`，再安装其余依赖。例如项目原使用环境为 PyTorch 2.11.0、torchvision 0.26.0、CUDA 12.8：

```bash
python -m pip install torch==2.11.0 torchvision==0.26.0 --index-url https://download.pytorch.org/whl/cu128
python -m pip install -r requirements.txt
```

> `render.py` 会依次查找 `fonts/msyh.ttc`、Windows 微软雅黑和 Linux Noto CJK。其他系统可将中文字体放到 `fonts/msyh.ttc`。

## 快速开始

### 推理图片

```bash
python infer.py --source path/to/image.jpg
```

### 推理视频

```bash
python infer.py --source path/to/video.mp4 --device auto
```

### 批量推理目录

```bash
python infer.py --source path/to/media_folder --output runs
```

目录输入只扫描当前层，不递归进入子目录。支持的格式如下：

- 图片：`.jpg`、`.jpeg`、`.png`、`.bmp`、`.webp`
- 视频：`.mp4`、`.avi`、`.mov`、`.mkv`、`.m4v`、`.wmv`

## 命令行参数

| 参数 | 默认值 | 说明 |
|---|---:|---|
| `--source` | 必填 | 图片、视频或目录路径 |
| `--output` | `runs` | 输出根目录 |
| `--device` | `auto` | `auto`、`cpu` 或 `cuda:0` 等 PyTorch 设备 |
| `--conf` | `0.25` | 目标检测置信度阈值，必须在 0 到 1 之间 |
| `--iou` | `0.5` | NMS IoU 阈值，必须在 0 到 1 之间 |
| `--batch-size` | `4` | 视频逐批推理帧数；显存不足时改为 1 |
| `--threads` | `4` | PyTorch CPU 线程数 |
| `--save-masks` | 关闭 | 保存视频逐帧压缩分割掩码 |

示例：

```bash
python infer.py ^
  --source input.mp4 ^
  --output runs ^
  --device cuda:0 ^
  --conf 0.25 ^
  --iou 0.5 ^
  --batch-size 4 ^
  --save-masks
```

PowerShell 或 Linux/macOS 终端可将续行符改为反引号或反斜杠，也可以写在同一行。

## 输出说明

每次运行创建一个独立目录：

```text
runs/detect_YYYYMMDD_HHMMSS_microseconds/
├─ 运行汇总.json
└─ 01_输入文件名/
   ├─ 运行记录.json
   └─ ...
```

### 图片输出

```text
检测结果.jpg       # 检测框、交通灯颜色、可行驶区域和车道线叠加图
可行驶区域.png     # 0/255 二值图
车道线.png         # 0/255 二值图
预测.json          # 检测结果和分割面积比例
运行记录.json       # 输入与输出基本信息
```

### 视频输出

```text
全功能检测.mp4       # H.264 视频，存在原音频时转码为 AAC 并保留
逐帧预测.jsonl       # 每行对应一帧，含时间、检测框和分割比例
预览_XXXX.jpg        # 首帧、中间帧和末帧附近的预览图
编码日志.txt          # FFmpeg 错误输出
运行记录.json
道路与车道线掩码.npz  # 仅在 --save-masks 时生成
```

`道路与车道线掩码.npz` 中的 `packed_masks` 使用 `np.packbits` 压缩，通道顺序为 `drivable`、`lane`，模型掩码尺寸为 384×640，位序为 `big`。

## Python 接口

```python
import cv2
from model import Predictor

frame = cv2.imread("test.jpg")
predictor = Predictor(device="auto", confidence=0.25, nms_iou=0.5)
result = predictor.predict([frame])[0]

print(result["detections"])
road_mask = result["road_mask"]
lane_mask = result["lane_mask"]
```

`predict()` 接收 BGR `numpy.ndarray` 列表，返回同长度的结果列表。单帧结果结构如下：

```python
{
    "detections": [
        {
            "category": "vehicle",
            "score": 0.93,
            "box_xyxy": [x1, y1, x2, y2],
            "light_color": None,
            "light_color_score": None,
        }
    ],
    "road_mask": ...,      # uint8，尺寸与原图一致，取值 0/1
    "lane_mask": ...,      # uint8，尺寸与原图一致，取值 0/1
    "packed_road": ...,    # 384×640 模型掩码的压缩位图
    "packed_lane": ...,
}
```

交通灯条目会额外给出 `light_color` 和 `light_color_score`。灯色分数是 HSV 颜色相对置信度，不是目标检测置信度。

## 推理流程

1. 原图按比例缩放并补边到 640×384，补边值为 114。
2. BGR 转 RGB，缩放到 `[0, 1]`，再使用 ImageNet 均值和方差归一化。
3. YOLOP 主干和三个任务头同时输出检测、可行驶区域和车道线结果。
4. 检测结果执行 NMS，并将坐标映射回原图。
5. 两路分割结果裁掉补边后，使用最近邻插值恢复到原图尺寸。
6. 对 `traffic_light` 检测框执行 HSV 红、黄、绿判色；颜色区域过小或不够占优时输出 `unknown`。
7. `render.py` 将可行驶区域绘制为绿色、车道线绘制为红色，并叠加检测框和中文标签。

## 权重校验

代码固定加载：

```text
weights/v5_best_det4.pth
```

权重约 30.6 MiB，`model.py` 内置 SHA-256：

```text
f917a2f0a1c3966c9b05bb32e68a10d19af4116950d42f9705d0d3181352fc6e
```

加载时还会校验检查点轮次为 122、类别顺序和预处理标识。文件损坏、被替换或检查点元数据不一致时会直接报错，避免静默使用错误权重。

## 已知限制

- 这是推理交付包，不能直接用于继续训练。
- 文件夹输入不递归扫描子目录。
- 视频输出需要重新编码，速度取决于模型设备、批量大小和 FFmpeg 性能。
- `--save-masks` 会把所有视频帧的压缩掩码先保存在内存中，长视频可能占用较多内存。
- 交通灯颜色是基于检测框内 HSV 规则的后处理，受曝光、反光、框偏移和灯体尺寸影响。
- `traffic_light_color.py` 中还保留了颜色连通域小灯候选函数，但当前 `Predictor` 主流程只对 YOLOP 已检测出的交通灯框判色。
- 当前包记录的四类固定监测集 mAP50 为 49.27%，该数值不能代表分割质量或交通灯颜色准确率，也没有随本目录提供可复现的评测数据集。

## 许可

模型结构基于 YOLOP 项目整理，许可信息见 [LICENSE](LICENSE)。使用权重、数据和第三方依赖时，还应遵守各自的授权条款。
