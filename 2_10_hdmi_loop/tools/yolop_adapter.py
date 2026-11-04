# -*- coding: utf-8 -*-
"""
YOLOP v3 适配层 —— 把队友的模型接到 FPGA 视频链路上

做三件事：
  1. 兼容老版本 torch（当前环境是 1.8.1，缺 inference_mode / weights_only）
  2. 把模型输出（四类框 + 灯色）转换成我们协议的格式
  3. 坐标从 640×360（FPGA 发的图）换算到 1280×720（原始帧）

用法：
    from yolop_adapter import YolopAdapter
    ad = YolopAdapter(r'C:\\Users\\Lenovo\\Desktop\\YOLOP_v3_全功能使用包_20261102',
                      device='cpu')
    boxes = ad.detect(rgb_640x360)      # 返回协议格式的框列表
"""

import sys
import time
from pathlib import Path

import numpy as np

# ---------------------------------------------------------------------------
#  torch 兼容性补丁（torch < 1.9 没有 inference_mode，< 1.13 不认 weights_only）
#  只在本进程内生效，不改队友的包
# ---------------------------------------------------------------------------
import torch

if not hasattr(torch, 'inference_mode'):
    torch.inference_mode = torch.no_grad

_orig_load = torch.load
def _load_compat(*args, **kwargs):
    kwargs.pop('weights_only', None)      # 老版本不认识这个参数
    return _orig_load(*args, **kwargs)
torch.load = _load_compat

# ---------------------------------------------------------------------------
#  协议映射
# ---------------------------------------------------------------------------
#  模型类别 -> 我们的 class_id
#     0 = vehicle      1 = person      2 = traffic_light     3 = rider
CLASS_MAP = {
    'vehicle':       0,
    'person':        1,
    'traffic_light': 2,
    'rider':         3,
}

#  灯色 -> subclass
COLOR_MAP = {
    None:      0,
    'unknown': 0,
    'red':     1,
    'yellow':  2,
    'green':   3,
}

MAX_BOXES = 32


class YolopAdapter:
    def __init__(self, pkg_dir, device='cpu', confidence=0.25, nms_iou=0.5):
        pkg = Path(pkg_dir).resolve()
        if not (pkg / 'model.py').exists():
            raise FileNotFoundError(f'{pkg} 下找不到 model.py')
        sys.path.insert(0, str(pkg))

        from model import Predictor     # noqa: E402

        t0 = time.time()
        self.pred = Predictor(device=device, confidence=confidence, nms_iou=nms_iou)
        self.load_s = time.time() - t0

        self.n_frames = 0
        self.total_infer = 0.0

    # -----------------------------------------------------------------------
    def detect(self, rgb):
        """rgb: numpy uint8 (360,640,3)，RGB 顺序。

        返回 [(x1,y1,x2,y2, class_id, subclass, conf), ...]，坐标是 1280×720。
        """
        import cv2

        h, w = rgb.shape[:2]
        bgr = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)

        t0 = time.time()
        res = self.pred.predict([bgr])[0]
        dt = time.time() - t0
        self.n_frames += 1
        self.total_infer += dt

        # FPGA 发的是 ÷2 降采样图，所以坐标乘 2 回到 1280×720
        sx = 1280.0 / w
        sy = 720.0 / h

        out = []
        for d in res['detections']:
            cid = CLASS_MAP.get(d['category'])
            if cid is None:
                continue
            sub = COLOR_MAP.get(d.get('light_color'), 0) if cid == 2 else 0
            x1, y1, x2, y2 = d['box_xyxy']
            out.append((int(round(x1 * sx)), int(round(y1 * sy)),
                        int(round(x2 * sx)), int(round(y2 * sy)),
                        cid, sub, int(round(d['score'] * 100))))
            if len(out) >= MAX_BOXES:
                break
        return out

    def stats(self):
        avg = self.total_infer / self.n_frames if self.n_frames else 0
        return f"{self.n_frames} 帧，平均 {avg*1000:.1f} ms/帧（{1/max(avg,1e-6):.1f} fps）"
