# -*- coding: utf-8 -*-
"""
PiggyCount 帧率采集（DevTools Performance 等价数据）
====================================================
通过 Dart VM Service 的 Profiler/timeline 接口采集滑动帧耗时，
等价于 DevTools Performance 页面的帧统计：
  - http://127.0.0.1:43231/b2Z_Eh32e3k=/getVMTimeline
  - Analyzer 帧事件由 Engine 在 'Embedder' 流中标记（BeginFrame/DrawFrame
    或 Impeller 的帧事件）， Dart 侧 UI build/layout/paint 记录在 'Dart' 流。

用法:
  python scripts/profile_frames.py --vm http://127.0.0.1:43231/b2Z_Eh32e3k= \
      --adb-serial emulator-5556 --seconds 12 --out docs/evidence/frame-profile

流程:
  1. clearVMTimeline
  2. setVMTimelineFlags(Dart, Embedder)
  3. ADB input swipe 模拟连续滑动（首页交易列表 / 分析页图表）
  4. 采集 getVMTimeline, 解析帧事件
  5. 输出: ui 帧耗时 / gpu 帧耗时 / fps 分布
"""
import argparse
import json
import subprocess
import sys
import time
import urllib.request


def rpc(vm, method, params=None):
    """Dart VM Service 只接受 GET（POST 405）；参数走 query string。
    本脚本用到的 clearVMTimeline/getVMTimeline 均无参数，timeline 流
    默认已含 Dart/Embedder/GC/Microtask（getVMTimelineFlags 可验证）。"""
    url = vm.rstrip('/') + '/' + method
    with urllib.request.urlopen(url, timeout=60) as resp:
        out = json.load(resp)
    if 'error' in out:
        raise RuntimeError(f'{method}: {out["error"]}')
    return out.get('result')


def adb(serial, *args):
    r = subprocess.run(['adb', '-s', serial] + list(args),
                        capture_output=True, text=True)
    return r.returncode, r.stdout.strip()


def swipe_list(serial, count, interval=0.9):
    """在屏幕中部做长距离上滑/下滑, 模拟用户连续滑动列表"""
    w, h = 1080, 1920  # emulator-5556 实测
    for i in range(count):
        # 交替上滑与下滑, 保证内容来回滚动
        if i % 2 == 0:
            x1, y1, x2, y2 = w // 2, int(h * 0.72), w // 2, int(h * 0.28)
        else:
            x1, y1, x2, y2 = w // 2, int(h * 0.30), w // 2, int(h * 0.74)
        adb(serial, 'shell', 'input', 'swipe', str(x1), str(y1),
            str(x2), str(y2), '350')
        time.sleep(interval)


def parse_frames(events):
    """从 VM timeline 提取每帧的耗时。

    Engine(Embedder 流) 每帧产生带 'phase' 的帧事件; Impeller 下
    'GPURasterizer::Draw' / 'Rasterizer::Draw' 记录 GPU 耗时;
    Dart 流的 'Animator::BeginFrame'~'Animator::Draw' 包住 UI 耗时。
    兼容两种命名: 旧 Skia (vsync/BeginFrame/DrawFrame) 与 Impeller。
    """
    ui_durations = []   # 毫秒, UI (build/layout/paint) 线程
    raster_durations = []  # 毫秒, GPU/raster 线程
    by_name = {}
    for ev in events:
        name = ev.get('name', '')
        ph = ev.get('ph')
        ts = ev.get('ts')
        dur = ev.get('dur')
        cat = ev.get('cat', '')
        if ph != 'X':
            continue
        lname = name.lower()
        if ('beginframe' in lname or 'engine::beginframe' in lname
                or 'animator::beginframe' in lname):
            ui_durations.append(dur / 1000.0)
        elif ('gpurasterizer::draw' in lname or 'rasterizer::draw' in lname
                or 'impeller::rasterizer' in lname or 'flush' in lname
                and 'raster' in cat.lower()):
            raster_durations.append(dur / 1000.0)
        by_name.setdefault(name, 0)
        by_name[name] += 1
    return ui_durations, raster_durations, by_name


def stats(xs):
    if not xs:
        return None
    xs = sorted(xs)
    n = len(xs)
    def pct(p):
        return xs[min(n - 1, int(p / 100.0 * n))]
    return {
        'count': n,
        'avg': round(sum(xs) / n, 2),
        'p50': round(pct(50), 2),
        'p90': round(pct(90), 2),
        'p99': round(pct(99), 2),
        'max': round(xs[-1], 2),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--vm', required=True)
    ap.add_argument('--adb-serial', required=True)
    ap.add_argument('--seconds', type=int, default=12)
    ap.add_argument('--swipes', type=int, default=12)
    ap.add_argument('--out', required=True)
    args = ap.parse_args()

    # 1. 清空 timeline（流默认已含 Dart/Embedder/GC/Microtask，
    #    经 getVMTimelineFlags 验证，无需 setVMTimelineFlags —— 该接口
    #    的 recordedStreams 参数格式与文档不符且非必需）
    rpc(args.vm, 'clearVMTimeline')
    time.sleep(0.5)

    # 2. 采集前的基线（用户手动导航到要测的页面后运行脚本）
    print(f'采集 {args.seconds}s 滑动帧数据 (swipes={args.swipes})...')
    t0 = time.time()
    swipe_list(args.adb_serial, args.swipes)
    while time.time() - t0 < args.seconds:
        time.sleep(0.5)

    # 3. 拉取 timeline
    tl = rpc(args.vm, 'getVMTimeline')
    with open(args.out + '-raw-timeline.json', 'w', encoding='utf-8') as f:
        json.dump(tl, f, ensure_ascii=False)
    events = tl.get('traceEvents', [])
    print(f'timeline 事件总数: {len(events)}')

    ui_ms, raster_ms, names = parse_frames(events)
    ui_s = stats(ui_ms)
    raster_s = stats(raster_ms)
    total_s = args.seconds
    frame_count = len(ui_ms)
    print(json.dumps({
        'ui': ui_s, 'raster': raster_s,
        'frames': frame_count,
        'approx_fps': round(frame_count / total_s, 1) if frame_count else None,
    }, ensure_ascii=False, indent=2))

    with open(args.out + '-summary.json', 'w', encoding='utf-8') as f:
        json.dump({
            'durationSec': total_s,
            'ui': ui_s,
            'raster': raster_s,
            'frameEvents': frame_count,
            'eventNames': {k: v for k, v in sorted(
                names.items(), key=lambda kv: -kv[1])[:40]},
        }, f, ensure_ascii=False, indent=2)
    print('saved:', args.out + '-summary.json')


if __name__ == '__main__':
    main()
