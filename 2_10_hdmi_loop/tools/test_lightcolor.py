#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""红绿灯颜色通路自检：直接往 FPGA 发类别 2 的框，每 4 秒换一种灯色。

屏幕上应该依次出现：
    红色框(1=红) → 黄色框(2=黄) → 绿色框(3=绿) → 灰色框(0=未知) → 循环
框和左上角的数字 2 会同时变色。

用法: python test_lightcolor.py [秒数]
"""

import socket
import struct
import sys
import time

FPGA_DST = ('192.168.1.255', 5002)
HDR = struct.Struct('>4sBBHIIHHHHHBBHH')
BOX = struct.Struct('>HHHHBBBBI')
MAGIC = b'PNG1'

COLORS = [(1, '红'), (2, '黄'), (3, '绿'), (0, '灰(未知)')]

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)

duration = float(sys.argv[1]) if len(sys.argv) > 1 else 60.0
t0 = time.time()
idx = 0
next_change = t0

print("开始发送。屏幕上应看到框和数字 2 依次变色：红 → 黄 → 绿 → 灰")
while time.time() - t0 < duration:
    now = time.time()
    if now >= next_change:
        sub, name = COLORS[idx % len(COLORS)]
        print(f"  {time.strftime('%H:%M:%S')}  灯色 = {name}  (sub={sub})")
        idx += 1
        next_change = now + 4.0

    sub = COLORS[(idx - 1) % len(COLORS)][0]
    payload = BOX.pack(200, 150, 800, 500, 2, sub, 90, 0, 0)
    hdr = HDR.pack(MAGIC, 1, 2, 0, int(now * 30) & 0xFFFFFFFF, 0, 1,
                   0, 0, 0, 0, 0, 0, len(payload), 0)
    sock.sendto(hdr + payload, FPGA_DST)
    time.sleep(0.05)

print("结束")
