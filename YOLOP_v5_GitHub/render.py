"""Show all detected classes and both genuine segmentation outputs."""
from pathlib import Path
import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

COLORS = {'vehicle': (255, 215, 0), 'person': (40, 180, 255), 'rider': (210, 90, 240)}
NAMES = {'vehicle': '车辆', 'person': '行人', 'rider': '骑行者'}
LIGHT_COLORS = {'red': (255, 70, 70), 'yellow': (255, 220, 30), 'green': (50, 235, 90), 'unknown': (200, 200, 200)}
LIGHT_NAMES = {'red': '红灯', 'yellow': '黄灯', 'green': '绿灯', 'unknown': '灯色未知'}


def font(size):
    for path in (Path(__file__).parent / 'fonts/msyh.ttc', Path('C:/Windows/Fonts/msyh.ttc'),
                 Path('/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc')):
        if path.exists():
            return ImageFont.truetype(str(path), size)
    raise FileNotFoundError('未找到中文字体。Windows默认支持；其他系统请将中文字体置于fonts/msyh.ttc。')


class Renderer:
    def __init__(self, height, confidence):
        self.label = font(max(15, round(height/720*15)))
        self.hud = font(max(17, round(height/720*18)))
        self.confidence = confidence

    def draw(self, frame, result, seconds=None):
        marked = frame.copy()
        for mask, color, alpha in ((result['road_mask'], [0, 230, 0], .32),
                                    (result['lane_mask'], [0, 0, 255], .82)):
            selected = mask == 1
            marked[selected] = np.rint((1-alpha)*marked[selected] + alpha*np.array(color)).astype(np.uint8)
        height, width = marked.shape[:2]
        image = Image.fromarray(cv2.cvtColor(marked, cv2.COLOR_BGR2RGB))
        draw = ImageDraw.Draw(image)
        occupied = []
        for item in result['detections']:
            cls, lamp = item['category'], item['light_color']
            color = LIGHT_COLORS[lamp] if cls == 'traffic_light' else COLORS[cls]
            draw.rectangle(item['box_xyxy'], outline=color, width=max(2, round(height/420)))
        for item in sorted(result['detections'], key=lambda item: -item['score']):
            cls, lamp = item['category'], item['light_color']
            color = LIGHT_COLORS[lamp] if cls == 'traffic_light' else COLORS[cls]
            name = LIGHT_NAMES[lamp] if cls == 'traffic_light' else NAMES[cls]
            text = f'{name} {item["score"]:.2f}'
            b = draw.textbbox((0, 0), text, font=self.label)
            tw, th = b[2]-b[0]+8, b[3]-b[1]+7
            x1, y1, x2, y2 = item['box_xyxy']
            x = max(0, min(width-tw, x1))
            candidates = [(x, max(0, min(height-th, y)), x+tw, max(0, min(height-th, y))+th) for y in (y1-th, y2+2, y1+2)]
            def overlap(rect):
                return sum(max(0, min(rect[2], q[2])-max(rect[0], q[0])) * max(0, min(rect[3], q[3])-max(rect[1], q[1])) for q in occupied)
            rect = min(candidates, key=overlap)
            occupied.append(rect)
            draw.rectangle(rect, fill=color)
            draw.text((rect[0]+4, rect[1]+3-b[1]), text, font=self.label, fill=(15, 15, 15))
        lines = ['YOLOP v5 · 第122轮最佳权重 · 全功能检测',
                 f'绿色：可行驶区域｜红色：车道线｜检测阈值{self.confidence:g}']
        if seconds is not None:
            lines[0] += f' · {seconds:.1f}秒'
        boxes = [draw.textbbox((0, 0), line, font=self.hud) for line in lines]
        hh = max(b[3]-b[1] for b in boxes)+8
        ww = max(b[2]-b[0] for b in boxes)+20
        draw.rectangle((8, 8, 8+ww, 16+2*hh), fill=(20, 25, 35))
        for i, (line, b) in enumerate(zip(lines, boxes)):
            draw.text((17, 11+i*hh-b[1]), line, font=self.hud, fill=(245, 245, 245))
        return cv2.cvtColor(np.asarray(image), cv2.COLOR_RGB2BGR)
