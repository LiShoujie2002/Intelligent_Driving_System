"""Inference-only v5 four-class model and original preprocessing."""
from pathlib import Path
import copy
import hashlib
import cv2
import numpy as np
import torch
from lib.models.YOLOP import MCnet, YOLOP
from lib.core.general import non_max_suppression
from traffic_light_color import recognize_traffic_light_color

ROOT = Path(__file__).resolve().parent
WEIGHT_SHA256 = 'f917a2f0a1c3966c9b05bb32e68a10d19af4116950d42f9705d0d3181352fc6e'
CLASSES = ('vehicle', 'person', 'rider', 'traffic_light')
PREPROCESSING = 'rgb_imagenet_mean_std_640x384_v2'


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as file:
        for chunk in iter(lambda: file.read(2**20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def preprocess(frame):
    height, width = frame.shape[:2]
    scale = min(640 / width, 384 / height)
    nw, nh = round(width * scale), round(height * scale)
    left, top = (640 - nw) // 2, (384 - nh) // 2
    canvas = np.full((384, 640, 3), 114, np.uint8)
    canvas[top:top+nh, left:left+nw] = cv2.resize(frame, (nw, nh), interpolation=cv2.INTER_AREA)
    rgb = cv2.cvtColor(canvas, cv2.COLOR_BGR2RGB)
    tensor = torch.from_numpy(np.ascontiguousarray(rgb.transpose(2, 0, 1))).float() / 255
    tensor = (tensor - torch.tensor([.485, .456, .406]).view(3, 1, 1)) / torch.tensor([.229, .224, .225]).view(3, 1, 1)
    return tensor, (scale, left, top, nw, nh)


class Predictor:
    def __init__(self, device='auto', confidence=.25, nms_iou=.5):
        if not 0 < confidence < 1 or not 0 < nms_iou < 1:
            raise ValueError('Confidence and NMS IoU must be between 0 and 1')
        self.device = torch.device('cuda:0' if torch.cuda.is_available() else 'cpu') if device == 'auto' else torch.device(device)
        if self.device.type == 'cuda' and not torch.cuda.is_available():
            raise RuntimeError('CUDA不可用；选择auto或cpu，或切换到已有GPU解释器。')
        self.weight = ROOT / 'weights/v5_best_det4.pth'
        if sha256(self.weight) != WEIGHT_SHA256:
            raise ValueError('v5最佳权重校验失败，请重新复制完整使用包。')
        checkpoint = torch.load(self.weight, map_location='cpu', weights_only=True)
        if checkpoint['epoch'] != 122 or tuple(checkpoint['classes']) != CLASSES or checkpoint['preprocessing'] != PREPROCESSING:
            raise ValueError('Expected verified v5 epoch122 four-class checkpoint')
        config = copy.deepcopy(YOLOP)
        config[config[0][0]+1][2][0] = 4
        self.net = MCnet(config)
        self.net.nc, self.net.names, self.net.gr = 4, list(CLASSES), 1.
        self.net.load_state_dict(checkpoint['model_state'], strict=True)
        self.net.to(self.device).eval()
        self.confidence, self.nms_iou = confidence, nms_iou

    @torch.inference_mode()
    def predict(self, frames):
        prepared = [preprocess(frame) for frame in frames]
        output = self.net(torch.stack([item[0] for item in prepared]).to(self.device))
        boxes = non_max_suppression(output[0][0], self.confidence, self.nms_iou)
        road = output[1].argmax(dim=1).cpu().numpy().astype(np.uint8)
        lane = output[2].argmax(dim=1).cpu().numpy().astype(np.uint8)
        results = []
        for frame, detection, rmask, lmask, (_, geometry) in zip(frames, boxes, road, lane, prepared):
            height, width = frame.shape[:2]
            scale, left, top, nw, nh = geometry
            masks = [cv2.resize(mask[top:top+nh, left:left+nw], (width, height), interpolation=cv2.INTER_NEAREST) for mask in (rmask, lmask)]
            items = []
            for row in detection.cpu().tolist():
                box = [max(0, min(width-1, round((row[0]-left)/scale))),
                       max(0, min(height-1, round((row[1]-top)/scale))),
                       max(0, min(width-1, round((row[2]-left)/scale))),
                       max(0, min(height-1, round((row[3]-top)/scale)))]
                x1, y1, x2, y2 = box
                if x2 <= x1 or y2 <= y1:
                    continue
                cls = CLASSES[int(row[5])]
                color = recognize_traffic_light_color(frame[y1:y2, x1:x2]) if cls == 'traffic_light' else None
                items.append(dict(category=cls, score=float(row[4]), box_xyxy=box,
                                  light_color=color.color if color else None,
                                  light_color_score=color.confidence if color else None))
            results.append(dict(detections=items, road_mask=masks[0], lane_mask=masks[1],
                                packed_road=np.packbits(rmask, axis=1), packed_lane=np.packbits(lmask, axis=1)))
        return results
