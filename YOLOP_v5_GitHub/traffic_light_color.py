"""Traffic-light colour recognition for YOLOv4-tiny detections.

YOLOv4-tiny/COCO supplies the traffic-light bounding box (class 9). This
module performs a lightweight second stage that classifies the cropped lamp
as red, yellow, green, or unknown from its HSV colour response.
"""

from dataclasses import dataclass

import cv2
import numpy as np


@dataclass(frozen=True)
class TrafficLightColorResult:
    color: str
    confidence: float
    scores: dict


_HSV_RANGES = {
    "red": (
        (np.array([0, 80, 90]), np.array([10, 255, 255])),
        (np.array([170, 80, 90]), np.array([179, 255, 255])),
    ),
    "yellow": (
        (np.array([12, 80, 100]), np.array([38, 255, 255])),
    ),
    "green": (
        (np.array([38, 55, 70]), np.array([95, 255, 255])),
    ),
}


def _color_score(hsv, ranges):
    mask = np.zeros(hsv.shape[:2], dtype=np.uint8)
    for lower, upper in ranges:
        mask = cv2.bitwise_or(mask, cv2.inRange(hsv, lower, upper))

    kernel = np.ones((3, 3), dtype=np.uint8)
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel)
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel)

    saturation = hsv[:, :, 1].astype(np.float32) / 255.0
    value = hsv[:, :, 2].astype(np.float32) / 255.0
    weighted = (mask > 0).astype(np.float32) * saturation * value
    return float(weighted.sum()), mask


def recognize_traffic_light_color(image_bgr, min_area_ratio=0.008, min_dominance=1.12):
    """Classify a cropped traffic-light image.

    ``confidence`` is a relative colour confidence, not the YOLO confidence.
    Ambiguous or very small colour regions return ``unknown``.
    """
    if image_bgr is None or image_bgr.size == 0:
        return TrafficLightColorResult("unknown", 0.0, {})

    height, width = image_bgr.shape[:2]
    if height < 3 or width < 3:
        return TrafficLightColorResult("unknown", 0.0, {})

    pad_x = max(1, int(width * 0.08))
    pad_y = max(1, int(height * 0.04))
    inner = image_bgr[pad_y:height - pad_y, pad_x:width - pad_x]
    if inner.size == 0:
        inner = image_bgr

    hsv = cv2.cvtColor(inner, cv2.COLOR_BGR2HSV)
    raw_scores = {}
    masks = {}
    for name, ranges in _HSV_RANGES.items():
        raw_scores[name], masks[name] = _color_score(hsv, ranges)

    ranked = sorted(raw_scores.items(), key=lambda item: item[1], reverse=True)
    best_color, best_score = ranked[0]
    second_score = ranked[1][1]
    pixels = float(inner.shape[0] * inner.shape[1])
    active_ratio = float(np.count_nonzero(masks[best_color])) / pixels
    dominance = best_score / max(second_score, 1e-6)

    if active_ratio < min_area_ratio or dominance < min_dominance:
        return TrafficLightColorResult("unknown", 0.0, raw_scores)

    area_confidence = min(1.0, active_ratio / 0.08)
    dominance_confidence = min(1.0, (dominance - 1.0) / 2.0)
    confidence = 0.55 * area_confidence + 0.45 * dominance_confidence
    return TrafficLightColorResult(best_color, round(float(confidence), 3), raw_scores)


def crop_box(image, box):
    """Safely crop an ``[x, y, width, height]`` box to image bounds."""
    x, y, width, height = box
    image_height, image_width = image.shape[:2]
    x1 = max(0, int(x))
    y1 = max(0, int(y))
    x2 = min(image_width, int(x + width))
    y2 = min(image_height, int(y + height))
    if x2 <= x1 or y2 <= y1:
        return None
    return image[y1:y2, x1:x2]


def detect_small_traffic_lights(image_bgr, roi_bottom_ratio=0.64):
    """Propose tiny active lamps that COCO YOLOv4-tiny commonly misses.

    This is a conservative, colour-based fallback for distant signals only.
    It returns ``(box, colour, confidence)`` tuples. Boxes are expanded around
    the luminous component so the result is visible in an HD video.
    """
    height, width = image_bgr.shape[:2]
    hsv = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2HSV)
    strict_ranges = {
        "red": (((0, 140, 180), (10, 255, 255)), ((170, 140, 180), (179, 255, 255))),
        "yellow": (((12, 130, 180), (38, 255, 255)),),
        "green": (((38, 100, 160), (95, 255, 255)),),
    }
    proposals = []
    roi_bottom = int(height * roi_bottom_ratio)

    for colour, ranges in strict_ranges.items():
        mask = np.zeros((height, width), dtype=np.uint8)
        for lower, upper in ranges:
            mask = cv2.bitwise_or(
                mask,
                cv2.inRange(hsv, np.array(lower, dtype=np.uint8), np.array(upper, dtype=np.uint8)),
            )
        mask[roi_bottom:, :] = 0
        count, _, stats, _ = cv2.connectedComponentsWithStats(mask, 8)
        for index in range(1, count):
            x, y, component_width, component_height, area = map(int, stats[index])
            if not 2 <= area <= 180 or component_width > 24 or component_height > 24:
                continue
            aspect = component_width / max(component_height, 1)
            fill = area / float(component_width * component_height)
            if not 0.45 <= aspect <= 2.2 or fill < 0.35:
                continue
            if component_width < 2 or component_height < 2:
                continue

            # A real active lamp normally sits inside a dark signal housing.
            # Requiring a dark neighbourhood rejects red flags, advertising
            # pixels and most vehicle tail lamps in the supplied road video.
            pad = max(12, 4 * max(component_width, component_height))
            local_value = hsv[
                max(0, y - pad):min(height, y + component_height + pad),
                max(0, x - pad):min(width, x + component_width + pad),
                2,
            ]
            dark_neighbourhood_ratio = float(np.mean(local_value < 100))
            if dark_neighbourhood_ratio < 0.75:
                continue

            # Require a locally bright compact peak, then expand the tiny lamp
            # into a box that is visible and useful to the colour classifier.
            center_x = x + component_width // 2
            center_y = y + component_height // 2
            box_width = max(18, component_width * 3)
            box_height = max(24, component_height * 4)
            box_x = max(0, center_x - box_width // 2)
            box_y = max(0, center_y - box_height // 2)
            box_width = min(box_width, width - box_x)
            box_height = min(box_height, height - box_y)
            confidence = min(
                0.85, 0.40 + area / 80.0 + fill * 0.15 + dark_neighbourhood_ratio * 0.10
            )
            proposals.append(([box_x, box_y, box_width, box_height], colour, confidence))

    return proposals

