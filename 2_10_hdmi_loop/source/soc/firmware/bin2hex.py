# -*- coding: utf-8 -*-
"""把 objcopy 出来的 .bin 转成 $readmemh 能读的 32 位字 hex（小端）。

用法: python bin2hex.py firmware.bin firmware.hex
"""
import sys

if len(sys.argv) < 3:
    print('用法: python bin2hex.py <in.bin> <out.hex>')
    sys.exit(1)

src, dst = sys.argv[1], sys.argv[2]
data = bytearray(open(src, 'rb').read())

if len(data) % 4:
    data += b'\x00' * (4 - len(data) % 4)

with open(dst, 'w') as f:
    for i in range(0, len(data), 4):
        f.write('%08x\n' % int.from_bytes(data[i:i + 4], 'little'))

print('%s -> %s : %d words (%d bytes)'
      % (src, dst, len(data) // 4, len(data)))
