#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""用现有的 YolopAdapter 加载 v5 包，验证接口一致。"""

import numpy as np
import cv2
import sys

from yolop_adapter import YolopAdapter

PKG = r"C:\yolop_v5_pkg"

ad = YolopAdapter(PKG, device="cuda:0")
print(f"加载完成 {ad.load_s:.1f}s")

# 用包里自带的示例图，缩到 640x360 模拟 FPGA 传上来的画面
img = cv2.imdecode(np.fromfile(PKG + r"\输入素材\行人场景.jpg", np.uint8), cv2.IMREAD_COLOR)
small = cv2.resize(img, (640, 360), interpolation=cv2.INTER_AREA)
rgb = cv2.cvtColor(small, cv2.COLOR_BGR2RGB)

boxes = ad.detect(rgb)
print(f"检出 {len(boxes)} 个框（坐标应为 1280x720 空间）")
for b in boxes[:8]:
    print(f"  x1={b[0]:4d} y1={b[1]:4d} x2={b[2]:4d} y2={b[3]:4d} cls={b[4]} sub={b[5]} conf={b[6]}")

# 越界检查
bad = [b for b in boxes if b[0] < 0 or b[1] < 0 or b[2] > 1279 or b[3] > 719 or b[2] <= b[0] or b[3] <= b[1]]
print(f"异常框: {len(bad)}")

for _ in range(5):
    ad.detect(rgb)
print(ad.stats())
