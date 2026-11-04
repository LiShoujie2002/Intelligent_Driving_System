#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""抓 8 秒 UDP，统计每个帧缺哪些包 —— 定位是"全丢"还是"丢特定包"。"""

import socket, struct, time, collections

HDR = struct.Struct('>4sBBHIIHHHHHBBHH')
MAGIC = b'PNG1'

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 64 * 1024 * 1024)
s.bind(('0.0.0.0', 5000))
s.settimeout(1.0)

frames = collections.defaultdict(collections.Counter)   # fid -> Counter(pid)
ptot_of = {}
t0 = time.time()
npkt = 0
missed_ids = collections.Counter()
n_short = 0
n_magic = 0
n_type = 0
n_total = 0

while time.time() - t0 < 8:
    try:
        pkt, _ = s.recvfrom(3000)
    except socket.timeout:
        continue
    n_total += 1
    if len(pkt) < 32:
        n_short += 1
        continue
    magic, ver, mtype, flags, fid, pid, ptot, sw, sh, dw, dh, pfmt, rmode, plen, rsv = HDR.unpack(pkt[:32])
    if magic != MAGIC:
        n_magic += 1
        continue
    if mtype != 1:
        n_type += 1
        continue
    npkt += 1
    frames[fid][pid] += 1
    ptot_of[fid] = ptot

dur = time.time() - t0
print(f"总收 {n_total} 包（无效: 短包 {n_short} 魔数错 {n_magic} 类型错 {n_type}）")
print(f"有效视频包 {npkt}，{dur:.1f} 秒，{npkt/dur:.0f} pkt/s")
print(f"涉及 {len(frames)} 个帧号")

complete = 0
shown = 0
for fid in sorted(frames):
    got = frames[fid]
    tot = ptot_of[fid]
    if len(got) == tot and all(v == 1 for v in got.values()):
        complete += 1
    else:
        miss = sorted(set(range(tot)) - set(got))
        for m in miss:
            missed_ids[m] += 1
        if shown < 3:
            dup = {p: c for p, c in got.items() if c > 1}
            print(f"  帧 {fid}: 收到的包号数 {len(got)}/{tot}，缺 {miss[:6]}{'...' if len(miss)>6 else ''}，重复 {dup}")
            shown += 1
print(f"完整帧 {complete} / {len(frames)}")

if missed_ids:
    print("缺失包号 TOP10:", missed_ids.most_common(10))
    print(f"缺失包号范围: {min(missed_ids)} .. {max(missed_ids)}")
else:
    print("没有缺失包号记录")

# 看帧号是否连续
ids = sorted(frames)
if len(ids) > 2:
    gaps = [b - a for a, b in zip(ids, ids[1:])]
    print(f"帧号范围 {ids[0]}..{ids[-1]}，帧号跳变: min={min(gaps)} max={max(gaps)}")
