#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""分析 boxes.csv，找异常框：越界、反向、过大、帧间跳变。"""

import csv
import collections

ROWS = []
with open("boxes.csv", newline="", encoding="utf-8") as f:
    for r in csv.DictReader(f):
        ROWS.append({k: int(v) for k, v in r.items()})

W, H = 1280, 720
print(f"共 {len(ROWS)} 个框，涉及帧 {len({r['frame'] for r in ROWS})}")

def w(r): return r["x2"] - r["x1"]
def h(r): return r["y2"] - r["y1"]

oor   = [r for r in ROWS if r["x1"] < 0 or r["y1"] < 0 or r["x2"] >= W or r["y2"] >= H]
rev   = [r for r in ROWS if r["x2"] <= r["x1"] or r["y2"] <= r["y1"]]
huge  = [r for r in ROWS if w(r) > W * 0.6 or h(r) > H * 0.6]

print(f"越界   : {len(oor)}")
print(f"反向/零 : {len(rev)}")
print(f"过宽过高: {len(huge)}")

for name, lst in (("越界", oor), ("反向", rev), ("过大", huge)):
    for r in lst[:5]:
        print(f"  [{name}] 帧{r['frame']} idx{r['idx']} "
              f"({r['x1']},{r['y1']})-({r['x2']},{r['y2']}) "
              f"w={w(r)} h={h(r)} cls={r['cls']}")

# 帧间跳变：同一 idx 相邻帧中心的位移
by = collections.defaultdict(lambda: collections.defaultdict(list))
for r in ROWS:
    by[r["idx"]][r["frame"]].append(r)

jumps = []
for idx, frames in by.items():
    fs = sorted(frames)
    for a, b in zip(fs, fs[1:]):
        if b - a > 3:
            continue
        ra, rb = frames[a][0], frames[b][0]
        ca = ((ra["x1"] + ra["x2"]) / 2, (ra["y1"] + ra["y2"]) / 2)
        cb = ((rb["x1"] + rb["x2"]) / 2, (rb["y1"] + rb["y2"]) / 2)
        d = ((ca[0] - cb[0]) ** 2 + (ca[1] - cb[1]) ** 2) ** 0.5
        jumps.append((d, idx, a, b, ca, cb, ra, rb))

jumps.sort(reverse=True, key=lambda t: t[0])
print(f"\n帧间最大跳变 TOP5:")
for d, idx, a, b, ca, cb, ra, rb in jumps[:5]:
    print(f"  idx{idx} 帧{a}->{b} 位移 {d:.0f}px  "
          f"({ca[0]:.0f},{ca[1]:.0f})->({cb[0]:.0f},{cb[1]:.0f})  "
          f"宽 {w(ra)}->{w(rb)}")

# 宽度突变（同一 idx 相邻帧宽度比）
wj = []
for idx, frames in by.items():
    fs = sorted(frames)
    for a, b in zip(fs, fs[1:]):
        if b - a > 3:
            continue
        wa, wb = w(frames[a][0]), w(frames[b][0])
        if wa > 20 and wb > 20:
            wj.append((max(wa, wb) / min(wa, wb), idx, a, b, wa, wb))
wj.sort(reverse=True)
print(f"\n宽度突变 TOP5（比值）:")
for ratio, idx, a, b, wa, wb in wj[:5]:
    print(f"  idx{idx} 帧{a}->{b} 宽度 {wa}->{wb}  比值 {ratio:.2f}")

cnt = collections.Counter(r["cls"] for r in ROWS)
print(f"\n类别分布: {dict(cnt)}")
