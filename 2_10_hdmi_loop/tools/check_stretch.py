#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按位置(IoU)配对相邻帧的框，找"同一个物体尺寸突变"的事件。

不看序号 —— 模型每帧输出顺序会变，按序号比会误判。
如果一个框和上一帧某个框 IoU>=0.5（明显是同一个物体），
但宽或高变成 2 倍以上，那才是真正的"拉长"。
"""

import csv
import collections

FILENAME = "boxes_v5.csv"

by_frame = collections.defaultdict(list)
with open(FILENAME, newline="", encoding="utf-8") as f:
    for r in csv.DictReader(f):
        d = {k: int(v) for k, v in r.items()}
        by_frame[d["frame"]].append((d["x1"], d["y1"], d["x2"], d["y2"], d["cls"], d["conf"]))

frames = sorted(by_frame)
print(f"{len(frames)} 帧，{sum(len(v) for v in by_frame.values())} 个框")


def iou(a, b):
    ix1, iy1 = max(a[0], b[0]), max(a[1], b[1])
    ix2, iy2 = min(a[2], b[2]), min(a[3], b[3])
    iw, ih = max(0, ix2 - ix1), max(0, iy2 - iy1)
    inter = iw * ih
    ua = (a[2]-a[0])*(a[3]-a[1]) + (b[2]-b[0])*(b[3]-b[1]) - inter
    return inter / ua if ua > 0 else 0.0


pairs = 0
stretch = []
for a, b in zip(frames, frames[1:]):
    if b - a != 1:
        continue
    for box in by_frame[a]:
        best, bestb = 0.0, None
        for o in by_frame[b]:
            v = iou(box, o)
            if v > best:
                best, bestb = v, o
        if best < 0.5 or bestb is None:
            continue
        pairs += 1
        wa, wb = box[2]-box[0], bestb[2]-bestb[0]
        ha, hb = box[3]-box[1], bestb[3]-bestb[1]
        rw = max(wa, wb)/max(min(wa, wb), 1)
        rh = max(ha, hb)/max(min(ha, hb), 1)
        if rw >= 2.0 or rh >= 2.0:
            stretch.append((max(rw, rh), a, box, bestb, best))

print(f"能配上(IoU>=0.5)的相邻帧框对: {pairs}")
print(f"其中尺寸突变(宽或高 >=2 倍): {len(stretch)}  ({len(stretch)/max(pairs,1)*100:.2f}%)")

stretch.sort(reverse=True, key=lambda t: t[0])
for ratio, fr, a, b, i in stretch[:8]:
    print(f"  帧{fr}->{fr+1}  IoU={i:.2f}  "
          f"({a[0]},{a[1]})-({a[2]},{a[3]}) w={a[2]-a[0]} h={a[3]-a[1]}  ->  "
          f"({b[0]},{b[1]})-({b[2]},{b[3]}) w={b[2]-b[0]} h={b[3]-b[1]}  比值{ratio:.2f}")
