#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""同一帧分别用 v3 和 v5 模型检测，对比结果。"""

import numpy as np
import cv2
from PIL import Image

from yolop_adapter import YolopAdapter

img = np.array(Image.open("current_frame.png").convert("RGB"))
print("帧尺寸:", img.shape)

for name, pkg in (("v3", r"C:\yolop_pkg"), ("v5", r"C:\yolop_v5_pkg")):
    ad = YolopAdapter(pkg, device="cuda:0")
    boxes = ad.detect(img)
    # 预热后再测一次
    boxes = ad.detect(img)
    print(f"\n=== {name} ===  检出 {len(boxes)} 个框")
    for b in boxes[:8]:
        print(f"  ({b[0]:4d},{b[1]:4d})-({b[2]:4d},{b[3]:4d}) cls={b[4]} sub={b[5]} conf={b[6]}")
    if not boxes:
        print("  （没有检到任何目标）")
