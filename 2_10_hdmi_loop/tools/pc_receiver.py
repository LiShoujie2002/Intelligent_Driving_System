#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
FPGA ↔ PC 视频链路 —— PC 端参考实现

================================ 前提 ================================
    1. PC 网卡必须设成 192.168.1.105 / 255.255.255.0
       （FPGA 里的目的 IP 是写死的，地址不对一包都收不到）
    2. 网线直连板子的 RJ45 口
    3. 不需要管理员权限，不需要原始套接字，不需要 ARP

================================ 用法 ================================
    python pc_receiver.py                 演示模式：假"模型"画一个移动的框
    python pc_receiver.py --save out.png  把收到的一帧存成图片

============================ 接自己的模型 ==============================
    1. 写一个函数：
           def my_model(rgb):
               # rgb: numpy uint8, 形状 (360, 640, 3), RGB 顺序
               # 返回: [(x1, y1, x2, y2, class_id, subclass, conf), ...]
               #       坐标必须是 **1280x720 原始帧坐标系**
               ...
               return boxes
    2. 把下面 demo_model() 替换成我的函数，或者在 main() 里改一行。

============================ 协议要点 ==================================
    * UDP 5000 收视频，UDP 5002 发检测结果
    * 每包 = 32 字节应用头 + 最多 1440 字节图像
    * 每帧 320 包，必须按 packet_id 拼成一条连续字节流
    * 图像 640x360 RGB565，行优先，无行填充
    * 包可能切在一行中间甚至一个像素的两半之间 —— 按字节流拼接就对了
"""

import argparse
import socket
import struct
import sys
import threading
import time

# ---------------------------------------------------------------------------
#  协议常量
# ---------------------------------------------------------------------------
FPGA_IP      = "192.168.1.11"
PC_IP        = "192.168.1.105"
PORT_VIDEO   = 5000          # FPGA → PC
PORT_DETECT  = 5002          # PC → FPGA
SRC_W, SRC_H = 1280, 720     # 原始帧坐标系（检测框用这个）
DST_W, DST_H = 640, 360      # 实际传输的图像尺寸

MAGIC = b'PNG1'
# magic ver type flags | frame_id packet_id | total sw sh dw dh | fmt resize plen rsv
HDR  = struct.Struct('>4sBBHIIHHHHHBBHH')   # 32 字节
BOX  = struct.Struct('>HHHHBBBBI')          # 16 字节

MSG_VIDEO  = 0x01
MSG_DETECT = 0x02


# ---------------------------------------------------------------------------
#  收包
# ---------------------------------------------------------------------------
class FrameReceiver:
    def __init__(self, port=PORT_VIDEO):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16 * 1024 * 1024)
        self.sock.bind(("0.0.0.0", port))
        self.pending = {}          # frame_id -> {packet_id: bytes}
        self.stats = {"frames_ok": 0, "frames_bad": 0, "pkts": 0}

        # 后台线程持续收包，只保留"最新一整帧"。
        # 这样推理慢的时候不会积压延迟，也不会把一帧拆坏。
        self._latest = None
        self._lock = threading.Lock()
        self._running = True
        self._thread = threading.Thread(target=self._worker, daemon=True)
        self._thread.start()

    def _worker(self):
        while self._running:
            got = self.recv_frame(timeout=1.0)
            if got is not None:
                with self._lock:
                    self._latest = got

    def latest(self, timeout=3.0):
        """取最新一整帧（取走即清空）。没有就等。"""
        t0 = time.time()
        while time.time() - t0 < timeout:
            with self._lock:
                v = self._latest
                self._latest = None
            if v is not None:
                return v
            time.sleep(0.002)
        return None

    def recv_frame(self, timeout=3.0):
        """阻塞收一帧。返回 (frame_id, payload_bytes) 或 None（超时/残缺）。

        注意：这个循环里**只做收包和拼接**，不要做任何耗时处理。
        """
        self.sock.settimeout(timeout)
        t0 = time.time()

        while time.time() - t0 < timeout * 2:
            try:
                pkt, _ = self.sock.recvfrom(3000)
            except socket.timeout:
                return None
            if len(pkt) < 32:
                continue

            (magic, ver, mtype, flags, fid, pid, ptot,
             sw, sh, dw, dh, pfmt, rmode, plen, _rsv) = HDR.unpack(pkt[:32])

            if magic != MAGIC or mtype != MSG_VIDEO:
                continue

            d = self.pending.setdefault(fid, {})
            d[pid] = pkt[32:32 + plen]
            self.stats["pkts"] += 1

            if flags & 1:                       # LAST
                parts = self.pending.pop(fid, None)
                # 丢掉比这帧更老的残留
                for old in [k for k in self.pending if k < fid]:
                    self.pending.pop(old, None)
                if parts is None or len(parts) != ptot:
                    self.stats["frames_bad"] += 1
                    continue
                data = b''.join(parts[i] for i in range(ptot))
                self.stats["frames_ok"] += 1
                return fid, data
        return None

    def drain(self):
        """丢掉积压的数据报，保证拿到的是最新帧。

        模型推理如果比视频慢，不丢积压的话延迟会一直累积。
        """
        self.sock.setblocking(False)
        try:
            while True:
                try:
                    self.sock.recvfrom(3000)
                except (BlockingIOError, socket.error):
                    break
        finally:
            self.sock.setblocking(True)

    def close(self):
        self.sock.close()


def decode_rgb565(data, w=DST_W, h=DST_H):
    """RGB565 字节流 → numpy uint8 RGB 图像 (h, w, 3)"""
    import numpy as np
    arr = np.frombuffer(data, dtype=np.uint8).reshape(-1, 2)
    v = (arr[:, 0].astype(np.uint16) << 8) | arr[:, 1]
    r = ((v >> 11) & 0x1F) << 3
    g = ((v >> 5) & 0x3F) << 2
    b = (v & 0x1F) << 3
    return np.stack([r, g, b], axis=-1).astype(np.uint8).reshape(h, w, 3)


# ---------------------------------------------------------------------------
#  发检测结果
# ---------------------------------------------------------------------------
_detect_sock = None

def send_detections(frame_id, boxes):
    """把检测框回传给 FPGA，屏幕上会显示出来。

    boxes: [(x1, y1, x2, y2, class_id, subclass, conf), ...]
           * 坐标是 **1280x720 原始帧坐标系**
           * class_id: 0=车 1=人 2=红绿灯（决定画框的颜色：绿/黄/红）
           * subclass: 红绿灯颜色 0=无 1=红 2=黄 3=绿
           * conf: 0..100 整数百分比
           * 最多 32 个，超出的丢弃
    """
    global _detect_sock
    if _detect_sock is None:
        _detect_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        _detect_sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)

    def _clamp(v, hi):
        v = int(v)
        return 0 if v < 0 else (hi if v > hi else v)

    payload = b''.join(
        BOX.pack(_clamp(x1, SRC_W - 1), _clamp(y1, SRC_H - 1),
                 _clamp(x2, SRC_W - 1), _clamp(y2, SRC_H - 1),
                 int(cls) & 0xFF, int(sub) & 0xFF, int(conf) & 0xFF, 0, 0)
        for (x1, y1, x2, y2, cls, sub, conf) in boxes[:32]
    )

    hdr = HDR.pack(MAGIC, 1, MSG_DETECT, 0x00, frame_id, 0, 1,
                   0, 0, 0, 0, 0, 0, len(payload), 0)

    _detect_sock.sendto(hdr + payload, ('192.168.1.255', PORT_DETECT))


# ---------------------------------------------------------------------------
#  示例"模型"：画一个来回移动的框，用来验证链路
# ---------------------------------------------------------------------------
def demo_model(rgb, frame_id):
    t = frame_id % 100
    x = 100 + t * 10
    return [(x, 150, x + 300, 500, 2, 0, 90)]     # 类别 2 = 红绿灯 → 红框


# ---------------------------------------------------------------------------
def list_local_ips():
    ips = []
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if ip not in ips:
                ips.append(ip)
    except OSError:
        pass
    return ips


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--save", metavar="PNG", help="收到一帧就存成图片后退出")
    ap.add_argument("--duration", type=float, default=0, help="运行秒数，0=一直跑")
    ap.add_argument("--no-send", action="store_true", help="跑模型但不回传（只测速度）")
    ap.add_argument("--model", metavar="DIR", help="YOLOP 使用包目录，给了就加载真模型")
    ap.add_argument("--device", default="cuda:0", help="cuda:0 或 cpu，默认 cuda:0")
    ap.add_argument("--show", action="store_true", help="在本机窗口实时显示带框的画面")
    ap.add_argument("--record", metavar="MP4", help="把带框的画面录成视频")
    ap.add_argument("--csv", metavar="CSV", help="把每帧回传的框坐标记成 CSV，用来查异常框")
    args = ap.parse_args()

    model = None
    if args.model:
        from yolop_adapter import YolopAdapter
        print(f"加载模型: {args.model}  ({args.device}) ...")
        model = YolopAdapter(args.model, device=args.device)
        print(f"  加载完成，耗时 {model.load_s:.1f}s")

    ips = list_local_ips()
    print(f"本机地址: {ips}")
    if PC_IP not in ips:
        print(f"!! 警告: 网卡不是 {PC_IP}，大概率收不到数据")
        print(f"   请把接板子的网卡设成 {PC_IP}/24")

    rx = FrameReceiver(PORT_VIDEO)
    print(f"监听 UDP :{PORT_VIDEO}，等待帧 ...")

    t0 = time.time()
    last = t0
    n = 0
    recorder = None
    csv_f = None

    try:
        while True:
            got = rx.latest()                # 后台线程只留最新一帧
            if got is None:
                print("  超时，没收到完整帧")
                break
            fid, data = got
            n += 1

            if args.save:
                from PIL import Image
                Image.fromarray(decode_rgb565(data), "RGB").save(args.save)
                print(f"已保存 {args.save}（帧号 {fid}）")
                break

            if model is not None:
                boxes = model.detect(decode_rgb565(data))
            else:
                boxes = demo_model(None, fid)

            if not args.no_send:
                send_detections(fid, boxes)

            # 诊断：把回传的坐标原样记下来，事后查异常框（坐标必须是 1280x720）
            if args.csv:
                if csv_f is None:
                    csv_f = open(args.csv, "w", encoding="utf-8")
                    csv_f.write("frame,idx,x1,y1,x2,y2,cls,sub,conf\n")
                for bi, (x1, y1, x2, y2, cls, sub, conf) in enumerate(boxes):
                    csv_f.write(f"{fid},{bi},{x1},{y1},{x2},{y2},{cls},{sub},{conf}\n")

            # 本机显示 / 录屏（FPGA 那边只显示原始画面，带框的结果在这里看）
            if args.show or args.record:
                import cv2
                img = decode_rgb565(data)
                cv_img = cv2.cvtColor(img, cv2.COLOR_RGB2BGR)
                # 框坐标是 1280x720，画面是 640x360，显示前除以 2
                for (x1, y1, x2, y2, cls, sub, conf) in boxes:
                    color = {0: (0, 255, 0), 1: (0, 255, 255),
                             2: (0, 0, 255), 3: (255, 0, 255)}.get(cls, (255, 255, 255))
                    p1 = (x1 // 2, y1 // 2)
                    p2 = (x2 // 2, y2 // 2)
                    cv2.rectangle(cv_img, p1, p2, color, 2)
                    cv2.putText(cv_img, str(cls), (p1[0], max(12, p1[1] - 4)),
                                cv2.FONT_HERSHEY_SIMPLEX, 0.4, color, 1)
                if args.record:
                    if recorder is None:
                        recorder = cv2.VideoWriter(args.record,
                                                   cv2.VideoWriter_fourcc(*'mp4v'),
                                                   20.0, (640, 360))
                    recorder.write(cv_img)
                if args.show:
                    cv2.imshow('FPGA video + YOLOP', cv_img)
                    if cv2.waitKey(1) & 0xFF == 27:      # ESC 退出
                        break

            now = time.time()
            if now - last >= 1.0:
                last = now
                fps = n / max(now - t0, 1e-6)
                extra = f"  推理 {model.stats()}" if model is not None else ""
                print(f"  帧 {fid}  {len(data)} 字节  "
                      f"完整 {rx.stats['frames_ok']} 残缺 {rx.stats['frames_bad']}  "
                      f"{fps:.1f} fps  → 回传 {len(boxes)} 个框{extra}")

            if args.duration and (now - t0) >= args.duration:
                break
    except KeyboardInterrupt:
        print("\n中断")
    finally:
        # Ctrl+C 也必须走到这里：不 release，mp4 写完的索引就丢了，文件打不开
        rx.close()
        if recorder is not None:
            recorder.release()
            print(f"已保存录像 {args.record}")
        if csv_f is not None:
            csv_f.close()
            print(f"已保存坐标记录 {args.csv}")
        print(f"\n共收 {rx.stats['frames_ok']} 帧，残缺 {rx.stats['frames_bad']} 帧")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n中断")
        sys.exit(0)
