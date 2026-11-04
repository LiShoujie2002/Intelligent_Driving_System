#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""看框的尺寸分布：最大的框有多大。"""
import csv, statistics

rows = [{k: int(v) for k, v in r.items()}
        for r in csv.DictReader(open("boxes.csv", encoding="utf-8"))]

ws = sorted(((r["x2"] - r["x1"], r) for r in rows), reverse=True, key=lambda t: t[0])
hs = sorted(((r["y2"] - r["y1"], r) for r in rows), reverse=True, key=lambda t: t[0])

print("最大宽度 TOP5:")
for w, r in ws[:5]:
    print(f"  帧{r['frame']} ({r['x1']},{r['y1']})-({r['x2']},{r['y2']}) "
          f"w={w} h={r['y2']-r['y1']} cls={r['cls']}")

print("最大高度 TOP5:")
for h, r in hs[:5]:
    print(f"  帧{r['frame']} ({r['x1']},{r['y1']})-({r['x2']},{r['y2']}) "
          f"w={r['x2']-r['x1']} h={h} cls={r['cls']}")

print(f"宽度中位数 {statistics.median(x[0] for x in ws):.0f}   "
      f"高度中位数 {statistics.median(x[0] for x in hs):.0f}")
print(f"宽度>640 的框: {sum(1 for w, _ in ws if w > 640)} 个")
print(f"高度>360 的框: {sum(1 for h, _ in hs if h > 360)} 个")
