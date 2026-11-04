"""Image/video inference with all detection and segmentation outputs."""
from pathlib import Path
from datetime import datetime
from fractions import Fraction
import argparse
import json
import subprocess
import time
import sys

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
import cv2
import numpy as np
import torch
import imageio_ffmpeg
from model import Predictor, sha256, WEIGHT_SHA256
from render import Renderer

IMAGE_TYPES = {'.jpg', '.jpeg', '.png', '.bmp', '.webp'}
VIDEO_TYPES = {'.mp4', '.avi', '.mov', '.mkv', '.m4v', '.wmv'}


def write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')


def metadata(result, index=0, fps=1):
    return dict(frame=index, seconds=index/fps, detections=result['detections'],
                drivable_fraction=float((result['road_mask']==1).mean()), lane_fraction=float((result['lane_mask']==1).mean()))


def image_file(predictor, source, folder):
    frame = cv2.imdecode(np.fromfile(str(source), np.uint8), cv2.IMREAD_COLOR)
    if frame is None:
        raise ValueError(f'无法读取图片：{source}')
    result = predictor.predict([frame])[0]
    marked = Renderer(frame.shape[0], predictor.confidence).draw(frame, result)
    for name, content in (('检测结果.jpg', marked), ('可行驶区域.png', result['road_mask']*255), ('车道线.png', result['lane_mask']*255)):
        cv2.imencode(Path(name).suffix, content)[1].tofile(str(folder/name))
    write(folder/'预测.json', metadata(result))
    return dict(type='image', source=source.name, frames=1, width=frame.shape[1], height=frame.shape[0])


def video_file(predictor, source, folder, batch_size, save_masks):
    cap = cv2.VideoCapture(str(source))
    if not cap.isOpened():
        raise ValueError(f'无法读取视频：{source}')
    width, height = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    fps, expected = cap.get(cv2.CAP_PROP_FPS), int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    if fps <= 0 or min(width, height) < 1:
        cap.release()
        raise ValueError('视频尺寸或帧率无效')
    target = folder/'全功能检测.mp4'
    command = [imageio_ffmpeg.get_ffmpeg_exe(), '-hide_banner', '-loglevel', 'error', '-nostdin',
               '-f', 'rawvideo', '-pix_fmt', 'bgr24', '-s', f'{width}x{height}',
               '-r', str(Fraction(fps).limit_denominator(100000)), '-i', 'pipe:0', '-i', str(source),
               '-map', '0:v:0', '-map', '1:a?', '-vf', 'pad=ceil(iw/2)*2:ceil(ih/2)*2',
               '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20', '-pix_fmt', 'yuv420p', '-threads', '2',
               '-c:a', 'aac', '-b:a', '128k', '-movflags', '+faststart', str(target)]
    renderer = Renderer(height, predictor.confidence)
    processed, masks = 0, []
    started = time.perf_counter()
    with (folder/'编码日志.txt').open('wb') as log, (folder/'逐帧预测.jsonl').open('w', encoding='utf-8') as records:
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=log)
        try:
            while True:
                frames = []
                for _ in range(batch_size):
                    ok, frame = cap.read()
                    if not ok:
                        break
                    frames.append(frame)
                if not frames:
                    break
                for frame, result in zip(frames, predictor.predict(frames)):
                    marked = renderer.draw(frame, result, processed/fps)
                    process.stdin.write(marked.tobytes())
                    records.write(json.dumps(metadata(result, processed, fps), ensure_ascii=False)+'\n')
                    if save_masks:
                        masks.append(np.stack([result['packed_road'], result['packed_lane']]))
                    if processed in (0, expected//2, expected-1):
                        cv2.imencode('.jpg', marked)[1].tofile(str(folder/f'预览_{processed:04d}.jpg'))
                    processed += 1
                if processed % 100 == 0 or processed == expected:
                    print(f'{source.name}: {processed}/{expected}帧，耗时{time.perf_counter()-started:.1f}秒', flush=True)
            process.stdin.close()
            if process.wait(timeout=60) != 0:
                raise RuntimeError('视频编码失败，请查看编码日志')
        finally:
            cap.release()
            if process.poll() is None:
                process.kill(); process.wait()
    if expected > 0 and processed != expected:
        raise RuntimeError(f'输入解码未完成：{processed}/{expected}')
    if save_masks:
        np.savez_compressed(folder/'道路与车道线掩码.npz', packed_masks=np.stack(masks),
                            mask_shape=np.array([384, 640]), original_shape=np.array([height, width]),
                            channels=np.array(['drivable', 'lane']), bitorder=np.array('big'))
    return dict(type='video', source=source.name, frames=processed,
                fps=fps, width=width, height=height, output_width=width+(width%2), output_height=height+(height%2),
                duration_seconds=processed/fps, video_sha256=sha256(target),
                audio='original audio mapped if present, transcoded to AAC', elapsed_seconds=time.perf_counter()-started)


def main():
    parser = argparse.ArgumentParser(description='YOLOP v5: detection, traffic-light colour, drivable area and lane lines')
    parser.add_argument('--source', required=True, help='Image, video or directory')
    parser.add_argument('--output', default='runs', help='Output directory')
    parser.add_argument('--device', default='auto', help='auto, cpu or cuda:0')
    parser.add_argument('--conf', type=float, default=.25)
    parser.add_argument('--iou', type=float, default=.5)
    parser.add_argument('--batch-size', type=int, default=4)
    parser.add_argument('--threads', type=int, default=4)
    parser.add_argument('--save-masks', action='store_true', help='Also save packed per-frame video segmentation masks')
    args = parser.parse_args()
    if min(args.batch_size, args.threads) < 1:
        parser.error('batch-size and threads must be positive')
    source = Path(args.source).expanduser().resolve()
    output = Path(args.output).expanduser().resolve()
    files = sorted([p for p in source.iterdir() if p.is_file() and p.suffix.lower() in IMAGE_TYPES | VIDEO_TYPES]) if source.is_dir() else [source]
    if not files or any(not p.is_file() or p.suffix.lower() not in IMAGE_TYPES | VIDEO_TYPES for p in files):
        parser.error('Input must be a supported image, video or nonempty directory')
    torch.set_num_threads(args.threads)
    cv2.setNumThreads(1)
    predictor = Predictor(args.device, args.conf, args.iou)
    run = output/('detect_'+datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    run.mkdir(parents=True, exist_ok=False)
    records = []
    for index, path in enumerate(files, 1):
        folder = run/f'{index:02d}_{path.stem}'
        folder.mkdir()
        print(f'[{index}/{len(files)}] {path.name}; device={predictor.device}', flush=True)
        record = image_file(predictor, path, folder) if path.suffix.lower() in IMAGE_TYPES else video_file(predictor, path, folder, args.batch_size, args.save_masks)
        record.update(output_folder=folder.name)
        write(folder/'运行记录.json', record)
        records.append(record)
    write(run/'运行汇总.json', dict(model='YOLOP v5', checkpoint_epoch=122, weight_sha256=WEIGHT_SHA256,
                               confidence=predictor.confidence, nms_iou=predictor.nms_iou,
                               device=str(predictor.device), files=records,
                               tasks=['vehicle', 'person', 'rider', 'traffic_light+HSV', 'drivable_area', 'lane_line']))
    print('Results: '+str(run), flush=True)


if __name__ == '__main__':
    main()
