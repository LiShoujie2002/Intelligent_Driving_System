#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""在 torch 1.8.1 上试跑 YOLOP v5 交付包，看兼容性。

v5 包要求 torch>=2.7，本机是 1.8.1。这个脚本先打兼容补丁再加载，
能跑通就说明可以在本机直接用。
"""

import sys
import time

PKG = r"C:\yolop_v5_pkg"

# ---- torch 1.8.1 兼容补丁（必须在 import model 之前）----
import torch
if not hasattr(torch, "inference_mode"):
    torch.inference_mode = torch.no_grad
    print("[patch] torch.inference_mode -> no_grad")

_orig_load = torch.load
def _load_compat(*a, **kw):
    kw.pop("weights_only", None)
    return _orig_load(*a, **kw)
torch.load = _load_compat
print("[patch] torch.load: 去掉 weights_only")

sys.path.insert(0, PKG)

print("torch:", torch.__version__, "cuda:", torch.cuda.is_available())

try:
    from model import Predictor, CLASSES
    print("import model.py OK, CLASSES =", CLASSES)
except Exception as e:
    print("!! import 失败:", type(e).__name__, e)
    sys.exit(1)

t0 = time.time()
try:
    pred = Predictor("cuda:0", confidence=0.25, nms_iou=0.5)
except Exception as e:
    print("!! 加载权重失败:", type(e).__name__, e)
    sys.exit(2)
print(f"加载耗时 {time.time()-t0:.1f}s")

import numpy as np
import cv2

# 用包里自带的示例图片
img_path = PKG + r"\输入素材\行人场景.jpg"
img = cv2.imdecode(np.fromfile(img_path, np.uint8), cv2.IMREAD_COLOR)
print("测试图片:", img.shape)

t1 = time.time()
res = pred.predict([img])[0]
dt = time.time() - t1
print(f"推理耗时 {dt*1000:.1f} ms，检出 {len(res['detections'])} 个目标")

for d in res["detections"][:8]:
    print(f"  {d['category']:14s} score={d['score']:.2f} "
          f"box={d['box_xyxy']} light={d.get('light_color')}")

# 连续跑几次看平均耗时
t2 = time.time()
N = 10
for _ in range(N):
    pred.predict([img])
print(f"平均 {((time.time()-t2)/N)*1000:.1f} ms/帧")
