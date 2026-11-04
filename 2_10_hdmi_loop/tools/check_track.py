#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按 IoU 把相邻帧的框配对，看框是不是稳定跟着物体。

不按 idx 配 —— 模型输出的框顺序每帧会变，按 idx 比会误判成"跳变"。
"""

import csv, collections

by_frame = collections.defaultdict(list)
with open("boxes.csv", newline="", encoding="utf-8") as f:
    for r in csv.DictReader(f):
        d = {k: int(v) for k, v in r.items()}
        by_frame[d["frame"]].append((d["x1"], d["y1"], d["x2"], d["y2"], d["cls"]))

frames = sorted(by_frame)


def iou(a, b):
    ax1, ay1, ax2, ay2, _ = a
    bx1, by1, bx2, by2, _ = b
    ix1, iy1 = max(ax1, bx1), max(ay1, by1)
    ix2, iy2 = min(ax2, bx2), min(ay2, by2)
    iw, ih = max(0, ix2 - ix1), max(0, iy2 - iy1)
    inter = iw * ih
    ua = (ax2 - ax1) * (ay2 - ay1) + (bx2 - bx1) * (by2 - by1) - inter
    return inter / ua if ua > 0 else 0.0


pairs = 0
matched = 0
teleports = []          # 上一帧有这个框，下一帧最像的 IoU 也很低
counts = []

for a, b in zip(frames, frames[1:]):
    if b - a != 1:
        continue
    A, B = by_frame[a], by_frame[b]
    counts.append(len(B))
    for box in A:
        best = max((iou(box, o) for o in B), default=0.0)
        pairs += 1
        if best >= 0.3:
            matched += 1
        else:
            teleports.append((best, a, box))

print(f"参与配对的框: {pairs}")
print(f"下一帧仍能找到对应 (IoU>=0.3): {matched}  ({matched/max(pairs,1)*100:.1f}%)")
print(f"找不到对应（疑似瞬移/丢失）: {len(teleports)}")

teleports.sort()
print("\n最差配对样例:")
for best, fr, box in teleports[:5]:
    x1, y1, x2, y2, c = box
    print(f"  帧{fr} ({x1},{y1})-({x2},{y2}) w={x2-x1} h={y2-y1} cls={c} 最佳IoU={best:.2f}")

if counts:
    print(f"\n每帧框数: 最少 {min(counts)} 最多 {max(counts)} 平均 {sum(counts)/len(counts):.1f}")
    changes = [abs(x - y) for x, y in zip(counts, counts[1:])]
    print(f"相邻帧框数变化: 平均 {sum(changes)/max(len(changes),1):.1f}")
