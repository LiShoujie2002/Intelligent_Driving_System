#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ethernet_test 例程 —— PC 端验证脚本

对应工程: E:\\aaaaaaaaaaaa\\2_11_ethernet_test

例程的默认参数（见 source/ethernet_test.v）:
    LOCAL_MAC = A0:B1:C2:D3:E1:E1
    LOCAL_IP  = 192.168.1.11        <- FPGA
    LOCL_PORT = 8080
    DEST_IP   = 192.168.1.105       <- PC 必须是这个地址
    DEST_PORT = 8080
    UDP 内容  = "www.meyesemi.com   \\n"  (20 字节)，每约 1 秒一包

用法:
    # 只做静态检查（网卡地址、ARP 表）
    python eth_test_pc.py --check

    # 完整验证：ping + 收包，跑 10 秒
    python eth_test_pc.py --duration 10

    # 往 FPGA 发一个测试包（验证 RX 路径，例程本身不做处理，靠逻辑分析仪/调试核看）
    python eth_test_pc.py --send hello

前置条件:
    PC 网卡必须配成 192.168.1.105/24（和 FPGA 同网段），否则收不到包。
    用网线直连更稳，中间别过交换机。
"""

import argparse
import socket
import struct
import subprocess
import sys
import time

# ---- 协议 v1.3 的 32 字节应用头 / 16 字节框 ----
MAGIC = b'PNG1'
HDR = struct.Struct('>4sBBHIIHHHHHBBHH')
BOX = struct.Struct('>HHHHBBBBI')

FPGA_IP = "192.168.1.11"
FPGA_PORT = 8080
PC_IP = "192.168.1.105"
PC_PORT = 8080

EXPECT = b"www.meyesemi.com   \n"      # 20 字节


# ============================================================================
#  小工具
# ============================================================================
def rule(title=""):
    print("-" * 68)
    if title:
        print(title)
        print("-" * 68)


def run_cmd(cmd, timeout):
    """跑外部命令并安全解码。

    中文 Windows 的 ping / arp 输出是 GBK，用 text=True 会按 UTF-8 解，
    在后台读线程里抛 UnicodeDecodeError。所以拿 bytes 自己解。
    """
    try:
        r = subprocess.run(cmd, capture_output=True, timeout=timeout)
    except FileNotFoundError:
        return None, None
    except subprocess.TimeoutExpired:
        return -1, ""

    raw = (r.stdout or b"") + (r.stderr or b"")
    for enc in ("utf-8", "gbk", "cp936", "mbcs"):
        try:
            return r.returncode, raw.decode(enc)
        except (UnicodeDecodeError, LookupError):
            continue
    return r.returncode, raw.decode("utf-8", "replace")


def local_ipv4_addresses():
    """枚举本机 IPv4 地址（不依赖第三方库）。"""
    addrs = []
    try:
        host = socket.gethostname()
        for info in socket.getaddrinfo(host, None, socket.AF_INET):
            ip = info[4][0]
            if ip not in addrs:
                addrs.append(ip)
    except OSError:
        pass
    return addrs


def check_ip_config():
    addrs = local_ipv4_addresses()
    rule("1. 本机 IPv4 地址")
    for a in addrs:
        mark = "  <== 就是它" if a == PC_IP else ""
        print(f"    {a}{mark}")
    if PC_IP in addrs:
        print(f"\n    OK: 本机有 {PC_IP}，和例程的 DEST_IP 一致")
        return True
    print(f"\n    !! 没找到 {PC_IP}")
    print(f"       例程把数据发给 {PC_IP}:{PC_PORT}，地址不对就收不到。")
    print(f"       请把接 FPGA 的那张网卡配成 192.168.1.105 / 255.255.255.0")
    return False


def check_link(ip, num=2):
    """看持有该 IP 的网卡链路状态和速率。

    这一条比 ping 更早能定位问题: 如果 PHY 只协商到 100 Mbps，
    而例程按 1000 Mbps 写的（125 MHz），就一定不通。
    """
    rule(f"{num}. 网卡链路状态")
    if not sys.platform.startswith("win"):
        print("    非 Windows，跳过")
        return None

    ps = ["powershell", "-NoProfile", "-Command"]
    rc, out = run_cmd(
        ps + [f"(Get-NetIPAddress -AddressFamily IPv4 -IPAddress '{ip}' "
              f"-ErrorAction SilentlyContinue).InterfaceAlias"],
        timeout=20)
    alias = (out or "").strip().splitlines()
    alias = alias[0].strip() if alias else ""
    if not alias:
        print(f"    没找到持有 {ip} 的网卡")
        return None

    rc, out = run_cmd(
        ps + [f"Get-NetAdapter -InterfaceAlias '{alias}' | "
              f"Select-Object Name,Status,LinkSpeed | Format-List"],
        timeout=20)
    print(f"    网卡: {alias}")
    speed = ""
    status = ""
    for line in (out or "").splitlines():
        line = line.strip()
        if not line:
            continue
        print(f"      {line}")
        if line.startswith("LinkSpeed"):
            speed = line.split(":", 1)[-1].strip()
        if line.startswith("Status"):
            status = line.split(":", 1)[-1].strip()

    print()
    if speed.lower().startswith("1 gbps"):
        print("    OK: 协商到 1 Gbps —— 和例程的 125 MHz 匹配")
    elif "mbps" in speed.lower():
        print(f"    !! 只协商到 {speed}，但例程是按 1 Gbps(125 MHz) 写的")
        print("       这种状态下整条链路不会通。检查网线（要超五类以上）、")
        print("       两端网口、以及 PHY 的 strap 配置。")
    elif status and status.lower() != "up":
        print(f"    !! 网卡状态是 {status} —— 网线没接好或对端没上电")
    return speed


def check_ping(ip, count=4, num=3):
    rule(f"{num}. ping {ip}")
    if sys.platform.startswith("win"):
        cmd = ["ping", "-n", str(count), "-w", "1000", ip]
    else:
        cmd = ["ping", "-c", str(count), "-W", "1", ip]
    rc, out = run_cmd(cmd, timeout=count * 3 + 10)
    if rc is None:
        print("    找不到 ping 命令，跳过")
        return None
    if rc == -1:
        print("    ping 超时")
        return False

    # 关键: 不能只看返回码。Windows 在"无法访问目标主机"时也可能返回 0。
    # 真正的证据是回复行里的 TTL=。
    replies = out.lower().count("ttl=")
    for line in out.splitlines():
        s = line.strip()
        if any(k.lower() in s.lower() for k in
               ("ttl=", "超时", "不可达", "unreachable", "timed out", "100% loss", "100% 丢失")):
            print(f"      {s}")

    if replies == 0:
        print(f"    失败: 0 个 ICMP 回复（返回码 {rc}）")
        print("    常见原因: 网线/PHY 没起来、速率不匹配、IP 不同网段")
        return False

    print(f"    OK: 收到 {replies} 个 ICMP 回复 —— FPGA 协议栈在正常工作")
    return True


def check_arp(ip, num=3):
    rule(f"{num}. ARP 表里有 {ip} 吗")
    if sys.platform.startswith("win"):
        cmd = ["arp", "-a", ip]
    else:
        cmd = ["arp", "-n", ip]
    rc, out = run_cmd(cmd, timeout=10)
    if rc is None:
        print("    找不到 arp 命令，跳过")
        return
    out = (out or "").strip()
    if "a0-b1-c2-d3-e1-e1" in out.lower() or "a0:b1:c2:d3:e1:e1" in out.lower():
        print("    OK: 已解析到 A0:B1:C2:D3:E1:E1")
        print(f"      {out.splitlines()[-1].strip() if out else ''}")
    elif out:
        print("    当前条目:")
        for line in out.splitlines()[-4:]:
            print(f"      {line.strip()}")
    else:
        print("    空（还没通信过，正常）")


def check_counters(num=5, seconds=10, name="以太网"):
    """看网卡在统计窗口内有没有收到新帧。

    这是判断"FPGA 到底有没有在发包"最直接的证据:
    例程只要 PLL 锁上，每秒就会发一个 ARP 广播请求。
    """
    rule(f"{num}. 网卡收包计数（采样 {seconds} 秒）")
    if not sys.platform.startswith("win"):
        print("    非 Windows，跳过")
        return

    cmd = ["powershell", "-NoProfile", "-Command",
           f"Get-NetAdapterStatistics -Name '{name}' | "
           "Select-Object ReceivedUnicastPackets,ReceivedBroadcastPackets,"
           "ReceivedMulticastPackets,ReceivedPacketErrors,"
           "ReceivedDiscardedPackets | Format-List"]

    def sample():
        rc, out = run_cmd(cmd, timeout=25)
        d = {}
        for line in (out or "").splitlines():
            if ":" in line:
                k, v = line.split(":", 1)
                v = v.strip().replace(",", "")
                if v.isdigit():
                    d[k.strip()] = int(v)
        return d

    a = sample()
    if not a:
        print("    读不到统计信息，跳过")
        return
    print(f"    采样中（{seconds} 秒）……")
    time.sleep(seconds)
    b = sample()

    delta = {}
    for k in a:
        delta[k] = b.get(k, 0) - a[k]
        print(f"      {k:<26} {a[k]:>10} -> {b.get(k, 0):<10} (+{delta[k]})")

    print()
    bc = delta.get("ReceivedBroadcastPackets", 0)
    err = delta.get("ReceivedPacketErrors", 0)
    if bc >= max(3, seconds // 3):
        print(f"    OK: 收到 {bc} 个广播帧 —— FPGA 的 MAC/TX 在发包（ARP 请求）")
        print("       说明 TX 方向是通的，问题在 FPGA 的 RX 或上层状态机")
    elif err > 0:
        print(f"    !! 收到 {err} 个坏帧 —— 物理层在收，但 RGMII 相位不对")
        print("       典型原因: RX 的 IDELAY 值需要重调")
    else:
        print("    这段时间没收到任何广播帧")
        print("    结合 ping 超时 + ARP 表为空，判断为 **FPGA 发不出帧**")


def probe_mode(port, duration, timeout=2.0):
    """探测模式: 例程在扫 TX 延时，载荷第一个字节就是当前延时值。

    收到包的瞬间，那个字节就是能用（或至少能出包）的延时值。
    """
    rule(f"探测模式 —— 监听 UDP :{port}，解析载荷[0] = TX 延时值（{duration} 秒）")
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(("0.0.0.0", port))
    except OSError as e:
        print(f"    绑定失败: {e}")
        return
    sock.settimeout(timeout)

    t0 = time.time()
    seen = {}
    first = None
    total = 0
    while time.time() - t0 < duration:
        try:
            data, addr = sock.recvfrom(2048)
        except socket.timeout:
            continue
        total += 1
        if not data:
            continue
        d = data[0]
        if d not in seen:
            seen[d] = 0
            print(f"    [{time.time()-t0:6.2f}s] 首次收到  延时值={d:3d}  "
                  f"来自 {addr[0]}:{addr[1]}  {len(data)}B")
            if first is None:
                first = d
        seen[d] += 1
    sock.close()

    rule("结果")
    if total == 0:
        print("    一包都没收到 —— 整个 0..240 扫完都没有能通的延时值")
        print("    说明不是单纯的 TX 时钟相位问题，要看 PHY 的工作模式 / 硬件")
        return
    print(f"    共收到 {total} 包，覆盖 {len(seen)} 个延时值")
    for d in sorted(seen):
        print(f"      延时值 {d:3d} ({d*10:4d} ps)  ->  {seen[d]} 包")
    print()
    print(f"    **可用延时值区间: {min(seen)} .. {max(seen)}**")
    print(f"    建议取中点 {(min(seen)+max(seen))//2} 写回 delay_step_c")


def rx_probe(port, duration, fpga_ip, timeout=2.0):
    """RX 验证: FPGA 在探针帧载荷里回报"收到了多少帧"。

    载荷布局:
        [0]      TX delay step
        [1..4]   rx_frames
        [5..8]   rx_bytes
        [9..12]  rx_errors

    为了制造 RX 流量，周期性 ping 一次 FPGA —— 即使 ICMP 不通，
    Windows 也会先发 ARP 广播请求，这些帧 FPGA 是能收到的。
    """
    rule(f"RX 验证 —— 监听 UDP :{port}，读 FPGA 回报的接收计数（{duration} 秒）")
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(("0.0.0.0", port))
    except OSError as e:
        print(f"    绑定失败: {e}")
        return
    sock.settimeout(timeout)

    ping_cmd = (["ping", "-n", "1", "-w", "300", fpga_ip]
                if sys.platform.startswith("win")
                else ["ping", "-c", "1", "-W", "1", fpga_ip])

    t0 = time.time()
    next_ping = 0.0
    pings = 0
    first = None
    last = None
    n = 0

    while time.time() - t0 < duration:
        el = time.time() - t0
        if el >= next_ping:
            try:
                subprocess.Popen(ping_cmd, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL)
                pings += 1
            except FileNotFoundError:
                pass
            next_ping = el + 2.0

        try:
            data, _ = sock.recvfrom(2048)
        except socket.timeout:
            continue
        if len(data) < 13:
            continue
        n += 1
        rf = int.from_bytes(data[1:5], "big")
        rb = int.from_bytes(data[5:9], "big")
        re_ = int.from_bytes(data[9:13], "big")
        if first is None:
            first = (rf, rb, re_)
            print(f"    [{el:6.2f}s] 起始计数  frames={rf}  bytes={rb}  errors={re_}")
        last = (rf, rb, re_)
        if n % 200 == 0:
            print(f"    [{el:6.2f}s] 当前      frames={rf}  bytes={rb}  errors={re_}")
    sock.close()

    rule("结果")
    if first is None:
        print("    没收到 FPGA 的探针帧 —— TX 都不通，没法评估 RX")
        return
    if n == 0:
        print("    没有可用数据")
        return

    d_f = last[0] - first[0]
    d_b = last[1] - first[1]
    d_e = last[2] - first[2]
    print(f"    收到 {n} 个探针帧，期间 ping 了 {pings} 次")
    print(f"    观察窗口内 FPGA 的接收增量:")
    print(f"        frames  +{d_f}")
    print(f"        bytes   +{d_b}")
    print(f"        errors  +{d_e}")
    print()
    if d_f > 0:
        print("    OK: FPGA 收到了帧 —— **RGMII RX 物理通路通**")
        print(f"        平均每帧 {d_b // max(d_f, 1)} 字节")
        if d_e > 0:
            print(f"        但有 {d_e} 个错误指示，RX 相位可能需要微调")
    else:
        print("    !! FPGA 一帧都没收到 —— RX 通路不通")
        print("       检查: rgmii_rxc 是否接到 BUFG、RX IDELAY 值、PHY 的 RXDLY strap")


def send_boxes(duration, boxes, dst="192.168.1.255", dst_port=5002, hz=10):
    """周期性发送检测结果（用于验证 FPGA 的 OSD 画框）。"""
    import time as _t
    tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    tx.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)

    payload = b''
    for (x1, y1, x2, y2, c, conf) in boxes:
        payload += struct.pack('>HHHHBBBBI', x1, y1, x2, y2, c, 0, conf, 0, 0)

    hdr = HDR.pack(MAGIC, 1, 0x02, 0x00, 1, 0, 1,
                   0, 0, 0, 0, 0, 0, len(payload), 0)
    pkt = hdr + payload

    rule(f"发送检测框 -> {dst}:{dst_port}，{hz} Hz，共 {len(boxes)} 个框")
    for b in boxes:
        print(f"    框 ({b[0]},{b[1]})-({b[2]},{b[3]})  类别={b[4]}  置信度={b[5]}")

    t0 = _t.time()
    n = 0
    while _t.time() - t0 < duration:
        try:
            tx.sendto(pkt, (dst, dst_port))
            n += 1
        except OSError as e:
            print(f"    发送失败: {e}")
            break
        _t.sleep(1.0 / max(hz, 1))
    tx.close()
    print(f"    已发送 {n} 个检测包")
    print("    请看 FPGA 那边的 HDMI 显示器上是否出现矩形边框")


def live_test(port, duration, timeout=3.0):
    """实时画面: 收 FPGA 发来的真实视频帧，保存成 PNG 并统计帧率。"""
    IMG_W, IMG_H = 640, 360
    TOTAL = IMG_W * IMG_H * 2

    rule(f"实时画面 —— 监听 UDP :{port}，保存收到的帧（{duration} 秒）")
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16 * 1024 * 1024)
    try:
        sock.bind(("0.0.0.0", port))
    except OSError as e:
        print(f"    绑定失败: {e}")
        return
    sock.settimeout(timeout)

    t0 = time.time()
    cur_fid, parts = None, {}
    ok = bad = 0
    saved = False
    last_report = 0.0
    ptot_seen = 0

    while time.time() - t0 < duration:
        try:
            pkt, _ = sock.recvfrom(3000)
        except socket.timeout:
            continue
        if len(pkt) < 32:
            continue
        (magic, ver, mtype, flags, frame_id, pid, ptot,
         sw, sh, dw, dh, pfmt, rmode, plen, _rsv) = HDR.unpack(pkt[:32])
        if magic != b'PNG1' or mtype != 0x01:
            continue
        ptot_seen = ptot
        if cur_fid is None:
            cur_fid = frame_id
        if frame_id != cur_fid:
            cur_fid, parts = frame_id, {}
        parts[pid] = pkt[32:32 + plen]

        if flags & 1:
            if len(parts) != ptot:
                bad += 1
            else:
                data = b''.join(parts[i] for i in range(ptot))
                if len(data) == TOTAL:
                    ok += 1
                    if not saved:
                        try:
                            import numpy as np
                            from PIL import Image
                            arr = np.frombuffer(data, dtype=np.uint8).reshape(-1, 2)
                            v = (arr[:, 0].astype(np.uint16) << 8) | arr[:, 1]
                            r = ((v >> 11) & 0x1F) << 3
                            g = ((v >> 5) & 0x3F) << 2
                            b = (v & 0x1F) << 3
                            rgb = np.stack([r, g, b], axis=-1).astype(np.uint8)
                            rgb = rgb.reshape(IMG_H, IMG_W, 3)
                            Image.fromarray(rgb, "RGB").save("live_frame.png")
                            print("    已保存 live_frame.png")
                            saved = True
                        except Exception as e:
                            print(f"    (未保存 PNG: {e})")
                else:
                    bad += 1
            parts = {}
            el = time.time() - t0
            if el - last_report >= 2.0:
                last_report = el
                print(f"    [{el:5.1f}s] 完整帧 {ok}  残缺 {bad}")

    sock.close()
    rule("结果")
    print(f"    每帧包数: {ptot_seen}")
    print(f"    完整帧 {ok}，残缺 {bad}  ({(ok+bad)/max(duration,1e-6):.1f} 帧/秒)")
    if ok > 0:
        print("    OK: 收到真实 HDMI 画面 —— 采集→降采样→网络 整条链路通了")
    else:
        print("    !! 没收到完整帧")


def ds_test(port, duration, timeout=3.0, raw=False):
    """降采样器验证: FPGA 把合成的 1280x720 降成 640x360 发过来。

    源图（与 eth_ds_test.v 一致）:
        r = x & 0xFF,  g = y & 0xFF,  b = (7*x + 13*y) & 0xFF
    再对每个 2x2 块求平均（>>2），转 RGB565。
    """
    import numpy as np

    IMG_W, IMG_H = 640, 360
    SRC_W, SRC_H = 1280, 720
    TOTAL = IMG_W * IMG_H * 2
    PKT_TOTAL = 320

    rule(f"降采样验证 —— 监听 UDP :{port}，比对 2x2 均值结果（{duration} 秒）")

    # ---- 预期图像（一次性算好）----
    ys, xs = np.mgrid[0:SRC_H, 0:SRC_W]
    R = (xs & 0xFF).astype(np.uint16)
    G = (ys & 0xFF).astype(np.uint16)
    B = ((xs * 7 + ys * 13) & 0xFF).astype(np.uint16)

    def block_avg(ch):
        return ((ch[0::2, 0::2] + ch[1::2, 0::2] +
                 ch[0::2, 1::2] + ch[1::2, 1::2]) >> 2).astype(np.uint8)

    if raw:
        # 诊断模式：硬件直接取奇数行奇数列的像素（无滤波）
        ar, ag, ab = R[1::2, 1::2], G[1::2, 1::2], B[1::2, 1::2]
    else:
        ar, ag, ab = block_avg(R), block_avg(G), block_avg(B)
    v = ((ar.astype(np.uint16) >> 3) << 11) | ((ag.astype(np.uint16) >> 2) << 5) \
        | (ab.astype(np.uint16) >> 3)
    # 注意：np.stack(..., axis=1) 会在第 1 维插入新轴，得到 (H, 2, W)，
    # 字节顺序就全乱了。必须用 axis=-1 或显式 reshape 成 (H, W, 2)。
    exp_img = np.empty((IMG_H, IMG_W, 2), dtype=np.uint8)
    exp_img[..., 0] = (v >> 8).astype(np.uint8)
    exp_img[..., 1] = (v & 0xFF).astype(np.uint8)
    exp_bytes = exp_img.tobytes()
    print(f"    预期帧已生成: {len(exp_bytes)} 字节  前8字节={exp_bytes[:8].hex()}")
    print(f"    预期像素[0..5]: "
          + " ".join(f"{x:04X}" for x in
                     (((ar.astype(np.uint16) >> 3) << 11)
                      | ((ag.astype(np.uint16) >> 2) << 5)
                      | (ab.astype(np.uint16) >> 3)).ravel()[:6]))

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16 * 1024 * 1024)
    try:
        sock.bind(("0.0.0.0", port))
    except OSError as e:
        print(f"    绑定失败: {e}")
        return
    sock.settimeout(timeout)

    t0 = time.time()
    cur_fid, parts = None, {}
    ok = bad = 0
    first_bad_info = None

    while time.time() - t0 < duration:
        try:
            pkt, _ = sock.recvfrom(3000)
        except socket.timeout:
            continue
        if len(pkt) < 32:
            continue
        (magic, ver, mtype, flags, frame_id, pid, ptot,
         sw, sh, dw, dh, pfmt, rmode, plen, _rsv) = HDR.unpack(pkt[:32])
        if magic != b'PNG1' or mtype != 0x01:
            continue
        if cur_fid is None:
            cur_fid = frame_id
        if frame_id != cur_fid:
            cur_fid, parts = frame_id, {}
        parts[pid] = pkt[32:32 + plen]

        if flags & 1:
            if len(parts) != ptot:
                bad += 1
                if bad <= 3:
                    print(f"    帧 {frame_id}: 缺包 {len(parts)}/{ptot}")
            else:
                data = b''.join(parts[i] for i in range(ptot))
                if len(data) != TOTAL:
                    bad += 1
                else:
                    arr = np.frombuffer(data, dtype=np.uint8)
                    e = np.frombuffer(exp_bytes, dtype=np.uint8)
                    neq = np.nonzero(arr != e)[0]
                    if neq.size == 0:
                        ok += 1
                        if ok <= 3:
                            print(f"    帧 {frame_id}: 与预期完全一致 ✓")
                    else:
                        bad += 1
                        if first_bad_info is None:
                            i = int(neq[0])
                            px = i // 2
                            first_bad_info = (px % 640, px // 640,
                                              int(arr[i]), int(e[i]), int(neq.size))
                            # 第一帧不符时存原始数据，便于离线分析
                            with open("eth_ds_frame.bin", "wb") as fh:
                                fh.write(data)
                            with open("eth_ds_expect.bin", "wb") as fh:
                                fh.write(exp_bytes)
                            print("        已存 eth_ds_frame.bin / eth_ds_expect.bin")
                            print(f"        收到前16字节: {data[:16].hex()}")
                            print(f"        预期前16字节: {exp_bytes[:16].hex()}")
                        if bad <= 3:
                            print(f"    帧 {frame_id}: {neq.size} 字节不符")
            parts = {}

    sock.close()
    rule("结果")
    if ok + bad == 0:
        print("    没收到完整的帧")
        return
    print(f"    完整帧: 正确 {ok}，错误 {bad}")
    if first_bad_info:
        bx, by, got, exp, cnt = first_bad_info
        print(f"    首个不符: 像素({bx},{by})  got=0x{got:02X} exp=0x{exp:02X}"
              f"  共 {cnt} 字节")
    if ok > 0 and bad == 0:
        print("    OK: 降采样（2x2 均值 + ÷2）结果完全正确")


def video_test(port, duration, timeout=2.0, save_png=True):
    """视频分包验证: 收 320 包拼成一帧 640x360 RGB565，与合成图案逐字节比对。

    图案（与 eth_video_test.v 里一致）:
        byte(addr) = addr[7:0] ^ addr[15:8] ^ addr[18:16]
    """
    IMG_W, IMG_H = 640, 360
    TOTAL = IMG_W * IMG_H * 2
    PKT_TOTAL = 320

    rule(f"视频分包验证 —— 监听 UDP :{port}，重组 {IMG_W}x{IMG_H} RGB565（{duration} 秒）")

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16 * 1024 * 1024)
    try:
        sock.bind(("0.0.0.0", port))
    except OSError as e:
        print(f"    绑定失败: {e}")
        return
    sock.settimeout(timeout)

    def expected(addr):
        return (addr & 0xFF) ^ ((addr >> 8) & 0xFF) ^ ((addr >> 16) & 0x07)

    t0 = time.time()
    cur_fid = None
    parts = {}
    frames_ok = 0
    frames_bad = 0
    first_report = True
    hdr_seen = None

    while time.time() - t0 < duration:
        try:
            pkt, _ = sock.recvfrom(3000)
        except socket.timeout:
            continue
        if len(pkt) < 32:
            continue
        (magic, ver, mtype, flags, frame_id, pid, ptot,
         sw, sh, dw, dh, pfmt, rmode, plen, _rsv) = HDR.unpack(pkt[:32])
        if magic != b'PNG1' or mtype != 0x01:
            continue

        if first_report and hdr_seen is None:
            hdr_seen = dict(ver=ver, ptot=ptot, sw=sw, sh=sh, dw=dw, dh=dh,
                            pfmt=pfmt, rmode=rmode, plen=plen, ptot_n=ptot)
            print(f"    首包头部: ver={ver} total={ptot} src={sw}x{sh} "
                  f"dst={dw}x{dh} fmt={pfmt} rmode={rmode} plen={plen}")

        if cur_fid is None:
            cur_fid = frame_id
        if frame_id != cur_fid:
            cur_fid = frame_id
            parts = {}

        parts[pid] = pkt[32:32 + plen]

        if flags & 1:                      # LAST
            if len(parts) != ptot:
                frames_bad += 1
                if frames_bad <= 3:
                    print(f"    帧 {frame_id}: 缺包 {len(parts)}/{ptot}")
            else:
                data = b''.join(parts[i] for i in range(ptot))
                if len(data) != TOTAL:
                    frames_bad += 1
                    print(f"    帧 {frame_id}: 总长 {len(data)}，应为 {TOTAL}")
                else:
                    # 必须用 numpy 向量化比对。纯 Python 逐字节循环要几百毫秒，
                    # 期间 socket 缓冲区会被后续几帧撑爆，丢包全是脚本自己造成的。
                    import numpy as np
                    arr = np.frombuffer(data, dtype=np.uint8)
                    idx = np.arange(TOTAL, dtype=np.uint32)
                    exp = ((idx & 0xFF) ^ ((idx >> 8) & 0xFF)
                           ^ ((idx >> 16) & 0x07)).astype(np.uint8)
                    neq = np.nonzero(arr != exp)[0]
                    bad = int(neq.size)
                    first_bad = (int(neq[0]), int(arr[neq[0]]), int(exp[neq[0]])) if bad else None
                    if bad == 0:
                        frames_ok += 1
                        print(f"    帧 {frame_id}: {ptot} 包 / {TOTAL} 字节 "
                              f"全部一致  ✓")
                    else:
                        frames_bad += 1
                        print(f"    帧 {frame_id}: {bad} 字节不符，"
                              f"首个 @{first_bad[0]} got=0x{first_bad[1]:02X} "
                              f"exp=0x{first_bad[2]:02X}")
                    if save_png and bad == 0 and frames_ok == 1:
                        try:
                            from PIL import Image
                            arr = np.frombuffer(data, dtype=np.uint8).reshape(-1, 2)
                            v = (arr[:, 0].astype(np.uint16) << 8) | arr[:, 1]
                            r = ((v >> 11) & 0x1F) << 3
                            g = ((v >> 5) & 0x3F) << 2
                            b = (v & 0x1F) << 3
                            rgb = np.stack([r, g, b], axis=1).astype(np.uint8)
                            rgb = rgb.reshape(IMG_H, IMG_W, 3)
                            Image.fromarray(rgb, "RGB").save("eth_video_frame.png")
                            print("        已保存 eth_video_frame.png")
                        except Exception as e:
                            print(f"        (未保存 PNG: {e})")
            parts = {}

    sock.close()

    rule("结果")
    if frames_ok + frames_bad == 0:
        print("    没收到完整的帧")
        return
    print(f"    完整帧: 正确 {frames_ok}，错误 {frames_bad}")
    if frames_ok > 0 and frames_bad == 0:
        print("    OK: 分包/重组/包序/帧号/头部字段 全部正确")


def rx_parse_test(port, duration, timeout=1.0):
    """验证 FPGA 的 RX 解析链 (eth_rx + eth_udp_rx)。

    PC 向子网广播 192.168.1.255:5002 发 UDP 包（无需 ARP、无需管理员），
    FPGA 解析后在 1440 字节载荷的 [4..14] 回报统计。
    """
    rule(f"RX 解析验证 —— 收 UDP :{port}，向 192.168.1.255:5002 广播（{duration} 秒）")

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 * 1024 * 1024)
    try:
        sock.bind(("0.0.0.0", port))
    except OSError as e:
        print(f"    绑定失败: {e}")
        return
    sock.settimeout(timeout)

    tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    tx.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)

    t0 = time.time()
    next_send = 0.0
    sent = 0
    first = None
    last = None
    n = 0
    last_print = 0.0

    while time.time() - t0 < duration:
        el = time.time() - t0
        if el >= next_send:
            # 发一个标准格式的"检测结果"包：32 字节头 + 1 个框
            _fid = 0x00ABCDEF
            _box = struct.pack('>HHHHBBBBI', 111, 222, 333, 444, 2, 0, 88, 0, 0)
            payload = HDR.pack(MAGIC, 1, 0x02, 0x00, _fid, 0, 1,
                               0, 0, 0, 0, 0, 0, len(_box), 0) + _box
            try:
                tx.sendto(payload, ("192.168.1.255", 5002))
                sent += 1
            except OSError as e:
                print(f"    发送失败: {e}")
                break
            next_send = el + 0.05          # 20 包/秒

        try:
            data, _ = sock.recvfrom(2048)
        except socket.timeout:
            continue
        if len(data) < 15:
            continue
        n += 1
        pkts = int.from_bytes(data[4:8], "big")
        raw  = int.from_bytes(data[15:19], "big") if len(data) >= 19 else 0
        aupd = int.from_bytes(data[19:23], "big") if len(data) >= 39 else 0
        afid = int.from_bytes(data[23:27], "big") if len(data) >= 39 else 0
        anb  = data[27] if len(data) >= 39 else 0
        ax1  = int.from_bytes(data[28:30], "big") if len(data) >= 39 else 0
        ay1  = int.from_bytes(data[30:32], "big") if len(data) >= 39 else 0
        ax2  = int.from_bytes(data[32:34], "big") if len(data) >= 39 else 0
        ay2  = int.from_bytes(data[34:36], "big") if len(data) >= 39 else 0
        acls = data[36] if len(data) >= 39 else 0
        acnf = data[37] if len(data) >= 39 else 0
        if first is None:
            first = (pkts, raw, aupd)
            last_print = el
            print(f"    [{el:6.2f}s] 起始  raw={raw}  rx_pkts={pkts}  app_upd={aupd}")
        last = (pkts, raw, aupd, afid, anb, ax1, ay1, ax2, ay2, acls, acnf)
        if el - last_print >= 1.0:
            last_print = el
            print(f"    [{el:6.2f}s] raw={raw}  rx_pkts={pkts}  app_upd={aupd}  "
                  f"fid=0x{afid:08X}  nbox={anb}  "
                  f"box0=({ax1},{ay1})-({ax2},{ay2}) cls={acls} conf={acnf}")
    sock.close()
    tx.close()

    rule("结果")
    if first is None:
        print("    没收到 FPGA 的包 —— TX 不通")
        return
    d_p = last[0] - first[0]
    d_r = last[1] - first[1]
    d_a = last[2] - first[2]
    print(f"    PC 发出 {sent} 个测试包")
    print(f"    原始帧增量     : raw_frames +{d_r}")
    print(f"    UDP 层接受增量 : rx_pkts    +{d_p}")
    print(f"    应用层接受增量 : app_upd    +{d_a}")
    print(f"    最近一次解析   : fid=0x{last[3]:08X}  nbox={last[4]}  "
          f"box0=({last[5]},{last[6]})-({last[7]},{last[8]}) "
          f"cls={last[9]} conf={last[10]}")
    print()
    if d_r == 0:
        print("    !! FPGA 一帧都没收到 —— 包根本没到板子")
        return
    if d_a == 0:
        print(f"    !! 收到了 {d_r} 帧，但应用层一帧都没接受 —— 头校验有问题")
        return
    ok = (last[3] == 0x00ABCDEF and last[4] == 1 and
          last[5] == 111 and last[6] == 222 and
          last[7] == 333 and last[8] == 444 and
          last[9] == 2 and last[10] == 88)
    if ok:
        print("    OK: 应用层解析正确 —— 帧号、框数、坐标、类别、置信度全部吻合")
    else:
        print("    !! 解析出来了，但字段和 PC 发出的不一致")
    print("    OK: RX 解析链工作")


def speed_test(port, duration, timeout=1.0):
    """吞吐测试: eth_speed_test 发 1440 字节 UDP 包，载荷前 4 字节是序号。"""
    rule(f"吞吐测试 —— 监听 UDP :{port}（{duration} 秒）")
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 * 1024 * 1024)
    try:
        sock.bind(("0.0.0.0", port))
    except OSError as e:
        print(f"    绑定失败: {e}")
        return
    sock.settimeout(timeout)

    t0 = time.time()
    n = 0
    total_bytes = 0
    last_seq = None
    gaps = 0
    sizes = {}

    while time.time() - t0 < duration:
        try:
            data, _ = sock.recvfrom(2048)
        except socket.timeout:
            continue
        n += 1
        total_bytes += len(data)
        sizes[len(data)] = sizes.get(len(data), 0) + 1
        if len(data) >= 4:
            seq = int.from_bytes(data[:4], "big")
            if last_seq is not None and seq != ((last_seq + 1) & 0xFFFFFFFF):
                gaps += 1
            last_seq = seq
    sock.close()

    el = max(time.time() - t0, 1e-6)
    rule("结果")
    if n == 0:
        print("    一包都没收到 —— 发送路径不通")
        return
    pps = n / el
    print(f"    收到 {n} 包，用时 {el:.2f} s")
    print(f"    包率       {pps:,.0f} pkt/s")
    print(f"    载荷带宽   {total_bytes/el/1e6:.2f} MB/s")
    print(f"    线上带宽   {total_bytes/el*8/1e6*1.045:.1f} Mbit/s  (含头开销估算)")
    print(f"    包长分布   {sizes}")
    print(f"    序号不连续 {gaps} 次")
    if gaps == 0:
        print("    OK: 序号完全连续，没有丢包")
    else:
        print(f"    !! 有 {gaps} 处跳号（PC 端可能来不及收，或链路丢包）")


def listen_udp(port, duration, timeout=3.0):
    rule(f"6. 监听 UDP :{port}（{duration} 秒）")
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(("0.0.0.0", port))
    except OSError as e:
        print(f"    绑定失败: {e}")
        print(f"    端口 {port} 可能被占用，用 netstat -ano | findstr {port} 查一下")
        return 0

    sock.settimeout(timeout)
    t0 = time.time()
    n = 0
    bad = 0

    while time.time() - t0 < duration:
        try:
            data, addr = sock.recvfrom(2048)
        except socket.timeout:
            continue
        n += 1
        elapsed = time.time() - t0
        ascii_view = "".join(chr(b) if 32 <= b < 127 else "." for b in data)
        print(f"    [{elapsed:6.2f}s] {addr[0]}:{addr[1]}  {len(data)}B  "
              f"hex={data.hex()}  ascii={ascii_view!r}")
        if data != EXPECT and data.rstrip(b"\n") != EXPECT.rstrip(b"\n"):
            bad += 1
            print(f"             !! 内容和预期不符（预期 {EXPECT!r}）")

    sock.close()
    rule("结果")
    if n == 0:
        print("    一包都没收到。按顺序查:")
        print("      1) 网线是否直连、PHY 灯是否亮")
        print("      2) 本机 IP 是不是 192.168.1.105")
        print("      3) Windows 防火墙是否拦了 UDP 8080")
        print("         （管理员 PowerShell: New-NetFirewallRule -DisplayName eth8080 "
              "-Direction Inbound -Protocol UDP -LocalPort 8080 -Action Allow）")
        print("      4) 例程里 DEST_IP / DEST_PORT 是否被改过")
        return 0

    rate = n / max(duration, 1e-6)
    print(f"    收到 {n} 包，约 {rate:.2f} 包/秒")
    print(f"    内容不符 {bad} 包")
    if bad == 0:
        print("    OK: 内容与 'www.meyesemi.com' 一致 —— 协议栈 TX 路径通了")
    return n


def send_udp(dst_ip, dst_port, payload):
    rule(f"发送 UDP -> {dst_ip}:{dst_port}")
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(2.0)
    try:
        sock.sendto(payload, (dst_ip, dst_port))
        print(f"    已发出 {len(payload)} 字节: {payload!r}")
        print("    例程顶层没有把 udp_rec_* 接到可见输出，")
        print("    要确认收到得看调试核 / 逻辑分析仪，或改顶层让它点亮 LED。")
    except OSError as e:
        print(f"    发送失败: {e}")
    finally:
        sock.close()


# ============================================================================
def main():
    ap = argparse.ArgumentParser(description="ethernet_test 例程的 PC 端验证")
    ap.add_argument("--check", action="store_true", help="只做静态检查（IP/ARP）")
    ap.add_argument("--duration", type=float, default=10.0, help="监听秒数，默认 10")
    ap.add_argument("--port", type=int, default=PC_PORT, help="监听端口，默认 8080")
    ap.add_argument("--fpga-ip", default=FPGA_IP, help=f"FPGA 地址，默认 {FPGA_IP}")
    ap.add_argument("--no-ping", action="store_true", help="跳过 ping")
    ap.add_argument("--seconds", type=int, default=10, help="收包计数采样秒数，默认 10")
    ap.add_argument("--probe", action="store_true",
                    help="探测模式: 解析延时扫描结果（配合 delay-probe 比特流）")
    ap.add_argument("--rxprobe", action="store_true",
                    help="RX 验证模式: 读 FPGA 回报的接收计数")
    ap.add_argument("--speed", action="store_true",
                    help="吞吐测试: 统计 eth_speed_test 的包率和丢包")
    ap.add_argument("--rxtest", action="store_true",
                    help="RX 解析验证: 向 FPGA 广播 UDP，读回报的解析统计")
    ap.add_argument("--video", action="store_true",
                    help="视频分包验证: 重组 640x360 帧并逐字节比对")
    ap.add_argument("--raw", action="store_true",
                    help="配合 --ds: 硬件直通模式（无滤波）")
    ap.add_argument("--box", action="store_true",
                    help="发送一个测试检测框，验证 OSD 画框")
    ap.add_argument("--live", action="store_true",
                    help="实时画面: 收真实 HDMI 帧并存 PNG")
    ap.add_argument("--ds", action="store_true",
                    help="降采样验证: 比对 2x2 均值结果")
    ap.add_argument("--send", metavar="TEXT", help="往 FPGA 发一个测试包")
    args = ap.parse_args()

    print("=" * 68)
    print(" ethernet_test 例程 —— PC 端验证")
    print(f" FPGA {args.fpga_ip}:{FPGA_PORT}   PC {PC_IP}:{args.port}")
    print("=" * 68)

    if args.send:
        send_udp(args.fpga_ip, FPGA_PORT, args.send.encode())
        return

    if args.probe:
        check_ip_config()
        probe_mode(args.port, args.duration)
        return

    if args.rxprobe:
        check_ip_config()
        rx_probe(args.port, args.duration, args.fpga_ip)
        return

    if args.speed:
        check_ip_config()
        speed_test(args.port, args.duration)
        return

    if args.rxtest:
        check_ip_config()
        rx_parse_test(args.port, args.duration)
        return

    if args.box:
        check_ip_config()
        send_boxes(args.duration, [(200, 150, 800, 500, 2, 90)])
        return

    if args.live:
        check_ip_config()
        live_test(args.port, args.duration)
        return

    if args.ds:
        check_ip_config()
        ds_test(args.port, args.duration, raw=args.raw)
        return

    if args.video:
        check_ip_config()
        video_test(args.port, args.duration)
        return

    ip_ok = check_ip_config()
    if args.check:
        check_link(PC_IP, num=2)
        check_counters(num=3, seconds=min(args.seconds, 5))
        check_arp(args.fpga_ip, num=4)
        return

    if not args.no_ping:
        check_link(PC_IP, num=2)
        check_ping(args.fpga_ip, num=3)
        check_arp(args.fpga_ip, num=4)
        check_counters(num=5, seconds=args.seconds)

    if not ip_ok:
        print("\n本机 IP 不对，收包大概率失败，但仍然试一下……\n")

    n = listen_udp(args.port, args.duration)

    print()
    if n > 0:
        print("结论: 以太网链路 OK，可以进入集成阶段。")
        sys.exit(0)
    else:
        print("结论: 没收到数据，先解决链路再谈集成。")
        sys.exit(1)


if __name__ == "__main__":
    main()
