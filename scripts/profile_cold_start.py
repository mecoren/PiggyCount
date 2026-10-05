# -*- coding: utf-8 -*-
"""
PiggyCount 冷启动 / 页面切换基线采集（建议建议 #13 的另两条腿）
================================================================
`profile_frames.py` 覆盖「列表滚动 FPS」，本脚本补齐另两条基线：

  --mode cold  冷启动耗时：`am force-stop` → `am start -W` 取 TotalTime/WaitTime
               （Android 官方口径；TotalTime 含进程创建 + 首帧渲染）
  --mode nav   页面切换帧耗时：复用 `profile_frames.py` 的 VM timeline 解析，
               期间用 `adb shell input tap` 驱动一串坐标点击（切页）

用法::

  # 冷启动（10 次）
  python scripts/profile_cold_start.py --mode cold --adb-serial <serial> \
      --package com.wait.piggycount --runs 10 \
      --out docs/evidence/perf-baseline-2026-10-05

  # 页面切换（先手动停在起始页，给出要点的一串坐标）
  python scripts/profile_cold_start.py --mode nav --adb-serial <serial> \
      --vm http://127.0.0.1:<port>/<token>= \
      --taps "540,1800;540,300;540,1800;540,300" \
      --out docs/evidence/perf-baseline-2026-10-05

输出（都带 --label 后缀）::
  <out>-<label>.summary.json  统计
  <out>-rows.md               每次跑**追加**一行，列名固定，直接粘进验收表

判定阈值（**启发式，非实测**，拿到真机后按实际分布校准）::
  冷启动 TotalTime：≤1200ms PASS / ≤2500ms 观察 / 其余 SLOW
  切页 UI 帧 p90：  ≤16.67ms PASS / ≤32ms 观察 / 其余 JANK

自检（不连设备）: python scripts/profile_cold_start.py --self-check
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import profile_frames as pf  # noqa: E402  （同目录，复用 timeline 解析/统计）

HEADERS = ['场景', '数据集', '版本sha', '采样数', '中位(ms)', 'p90(ms)',
           '最差(ms)', '判定']

_TOTAL_RE = re.compile(r'TotalTime:\s*(\d+)')
_WAIT_RE = re.compile(r'WaitTime:\s*(\d+)')

JANK_FRAME_MS = 16.67   # 60fps 单帧预算
BAD_P90_MS = 32.0       # 两个预算 = 明显掉帧
COLD_PASS_MS = 1200
COLD_WATCH_MS = 2500


def adb(serial, *args):
    r = subprocess.run(['adb', '-s', serial] + list(args),
                       capture_output=True, text=True)
    return r.returncode, r.stdout


def parse_am_start(out):
    """解析 `am start -W` 输出。缺 TotalTime → None；缺 WaitTime → 该项 None。"""
    m = _TOTAL_RE.search(out or '')
    if not m:
        return None
    w = _WAIT_RE.search(out or '')
    return {'total_ms': int(m.group(1)),
            'wait_ms': int(w.group(1)) if w else None}


def stats(xs):
    xs = sorted(xs)
    n = len(xs)
    def pct(p):
        return xs[min(n - 1, int(p / 100.0 * n))]
    return {'count': n, 'median': pct(50), 'p90': pct(90), 'max': xs[-1],
            'avg': round(sum(xs) / n, 2)}


def verdict_cold(median_ms):
    if median_ms is None:
        return '样本不足'
    return 'PASS' if median_ms <= COLD_PASS_MS else (
        '观察' if median_ms <= COLD_WATCH_MS else 'SLOW')


def verdict_frames(p90_ms):
    if p90_ms is None:
        return '样本不足'
    return 'PASS' if p90_ms <= JANK_FRAME_MS else (
        '观察' if p90_ms <= BAD_P90_MS else 'JANK')


def self_check():
    """不连设备也能验的那部分：am start 解析、统计、判级。"""
    out = ("Starting: Intent { cmp=com.wait.piggycount/.MainActivity }\n"
           "Status: ok\n"
           "LaunchState: COLD\n"
           "TotalTime: 823\n"
           "WaitTime: 851\n")
    assert parse_am_start(out) == {'total_ms': 823, 'wait_ms': 851}, parse_am_start(out)
    # 无 TotalTime（启动失败/打印异常）→ 不能当 0 混进统计
    assert parse_am_start('Status: ok\n') is None
    # WaitTime 缺失不许崩
    assert parse_am_start('TotalTime: 700\n') == {'total_ms': 700, 'wait_ms': None}
    assert stats([10, 20, 30, 40]) == {
        'count': 4, 'median': 30, 'p90': 40, 'max': 40, 'avg': 25.0}
    assert verdict_cold(None) == '样本不足'
    assert verdict_cold(800) == 'PASS'
    assert verdict_cold(2000) == '观察'
    assert verdict_cold(3000) == 'SLOW'
    assert verdict_frames(10) == 'PASS'
    assert verdict_frames(20) == '观察'
    assert verdict_frames(40) == 'JANK'
    assert verdict_frames(None) == '样本不足'
    print('self-check ok')


def _append_row(out_base, label, dataset, version_sha, st, verdict):
    rows_md = out_base + '-rows.md'
    write_header = not os.path.exists(rows_md)
    with open(rows_md, 'a', encoding='utf-8') as f:
        if write_header:
            f.write('| ' + ' | '.join(HEADERS) + ' |\n')
            f.write('|' + '---|' * len(HEADERS) + '\n')
        f.write('| ' + ' | '.join(str(x) for x in [
            label, dataset, version_sha, st.get('count', 0),
            st.get('median', '—'), st.get('p90', '—'), st.get('max', '—'),
            verdict]) + ' |\n')
    return rows_md


def run_cold(args):
    totals, waits = [], []
    for i in range(args.runs):
        adb(args.adb_serial, 'shell', 'am', 'force-stop', args.package)
        time.sleep(args.cooldown)
        _, out = adb(args.adb_serial, 'shell', 'am', 'start', '-W',
                     '-n', f'{args.package}/{args.activity}')
        parsed = parse_am_start(out)
        if parsed is None:
            print(f'  run {i + 1}: 无法解析 am start 输出:\n{out}', flush=True)
            continue
        totals.append(parsed['total_ms'])
        if parsed['wait_ms'] is not None:
            waits.append(parsed['wait_ms'])
        print(f"  run {i + 1}: TotalTime={parsed['total_ms']}ms "
              f"WaitTime={parsed['wait_ms']}", flush=True)
    if not totals:
        print('没有采到有效样本（检查 --package/--activity 与设备连接）')
        return 2
    st = stats(totals)
    st['wait_median'] = stats(waits)['median'] if waits else None
    vd = verdict_cold(st['median'])
    base = f'{args.out}-{args.label}'
    with open(base + '.summary.json', 'w', encoding='utf-8') as f:
        json.dump({'mode': 'cold', 'package': args.package,
                   'activity': args.activity, 'runs': args.runs,
                   'totalMs': st, 'verdict': vd}, f,
                  ensure_ascii=False, indent=2)
    rows = _append_row(args.out, args.label, args.dataset, args.version_sha,
                       st, vd)
    print(json.dumps({'mode': 'cold', **st, 'verdict': vd},
                     ensure_ascii=False, indent=2))
    print('行已追加:', rows)
    return 0


def run_nav(args):
    if not args.vm:
        print('--mode nav 需要 --vm（VM Service URL）以取 timeline')
        return 2
    if not args.taps:
        print('--mode nav 需要 --taps "x,y;x,y"（切页点击序列）')
        return 2
    pf.rpc(args.vm, 'clearVMTimeline')
    time.sleep(0.3)
    for pair in args.taps.split(';'):
        pair = pair.strip()
        if not pair:
            continue
        x, y = pair.split(',')
        adb(args.adb_serial, 'shell', 'input', 'tap', x.strip(), y.strip())
        time.sleep(args.tap_interval)
    tl = pf.rpc(args.vm, 'getVMTimeline')
    events = tl.get('traceEvents', [])
    ui_ms, raster_ms, _names = pf.parse_frames(events)
    with open(f'{args.out}-{args.label}-nav-raw-timeline.json', 'w',
              encoding='utf-8') as f:
        json.dump(tl, f, ensure_ascii=False)
    if not ui_ms:
        print('没采到帧事件：确认 --vm 的 timeline 流含 Dart/Embedder，'
              '且点击确实发生了页面切换')
        return 2
    st = stats(ui_ms)
    st['raster_p90'] = pf.stats(raster_ms)['p90'] if raster_ms else None
    vd = verdict_frames(st['p90'])
    base = f'{args.out}-{args.label}'
    with open(base + '.summary.json', 'w', encoding='utf-8') as f:
        json.dump({'mode': 'nav', 'taps': args.taps, 'uiMs': st,
                   'verdict': vd}, f, ensure_ascii=False, indent=2)
    rows = _append_row(args.out, args.label, args.dataset, args.version_sha,
                       st, vd)
    print(json.dumps({'mode': 'nav', **st, 'verdict': vd},
                     ensure_ascii=False, indent=2))
    print('行已追加:', rows)
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--self-check', action='store_true')
    ap.add_argument('--mode', choices=['cold', 'nav'], default='cold')
    ap.add_argument('--adb-serial')
    ap.add_argument('--package', default='com.wait.piggycount')
    ap.add_argument('--activity', default='.MainActivity')
    ap.add_argument('--vm', help='VM Service URL（--mode nav 必填）')
    ap.add_argument('--taps', help='切页点击序列 "x,y;x,y;..."（--mode nav）')
    ap.add_argument('--tap-interval', type=float, default=1.2)
    ap.add_argument('--runs', type=int, default=10)
    ap.add_argument('--cooldown', type=float, default=1.5,
                    help='force-stop 后等待秒数，避免残留进程影响冷启动判定')
    ap.add_argument('--label', default=None)
    ap.add_argument('--dataset', default='M', choices=['S', 'M', 'L', 'none'])
    ap.add_argument('--version-sha', default='')
    ap.add_argument('--out')
    args = ap.parse_args()

    if args.self_check:
        self_check()
        return
    for req in ('adb_serial', 'out'):
        if not getattr(args, req):
            ap.error(f'--{req.replace("_", "-")} 必填')
    if args.label is None:
        args.label = '冷启动' if args.mode == 'cold' else '页面切换'

    sys.exit(run_cold(args) if args.mode == 'cold' else run_nav(args))


if __name__ == '__main__':
    main()
