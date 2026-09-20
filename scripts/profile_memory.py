# -*- coding: utf-8 -*-
"""
PiggyCount 内存采集（B6 基线，Android 真机/模拟器）
===================================================
三路取数，各司其职：
  1) `/proc/<pid>/status` 的 VmRSS / VmHWM —— **进程 RSS 与峰值**（KB）。
     选它而不是 dumpsys 的 TOTAL RSS：dumpsys 的列顺序随 Android 版本变（老版本
     最后一列叫 "Rss Dirty"，不是 RSS），而 status 文件是稳定格式。
  2) `dumpsys meminfo <pkg>` 的分区行 —— Native Heap / Graphics / .so mmap …
     只有 dumpsys 能给出这个拆解，而**位图与纹理都记在 native 侧**，
     Dart 堆看不全。**取不到就留空**（best-effort），不影响 RSS 主曲线。
  3) VM Service 每个 isolate 的 `getMemoryUsage` —— **Dart 堆**。1) 与 3) 相减
     才能把"是 Dart 对象常驻还是位图常驻"分开，这正是本轮 M10-M21 各项的判据。
     可选：不传 --vm 也能出基线。

用法（每个场景单独跑一次，--label 就是验收表里的"场景/峰值时刻动作"）:
  python scripts/profile_memory.py --adb-serial <serial> --package com.wait.piggycount \\
      --label 冷启动稳定 --dataset M --version-sha $(git rev-parse --short HEAD) \\
      --seconds 90 --interval 1 --out docs/evidence/mem-baseline-2026-09-19
  # 首页滚动档加 --swipes 30（复用 scripts/profile_frames.py 的滑动实现）

输出（都带 --label 后缀）:
  <out>-<label>.samples.csv   逐次采样
  <out>-<label>.summary.json  峰值/稳态/泄漏斜率
  <out>-rows.md               每次跑**追加**一行，列名固定，直接粘进验收表

泄漏斜率 = 窗口三等分后"最晚 1/3 与最早 1/3 的 RSS 中位数差 / 时间差"，单位 KB/min
（不用最小二乘：±100KB 的采样抖动会被拟合成 ~180KB/min 的假斜率，见 slope_kb_per_min）。
判定：>2000 记 LEAK，200~2000 记观察，其余 PASS —— 阈值定在 MB 级，因为抖动残量落在
百 KB/min 这一档，而真泄漏（整本账本明文常驻、位图不释放）是 MB/min 量级。

自检: python scripts/profile_memory.py --self-check
"""
import argparse
import csv
import json
import os
import re
import statistics
import subprocess
import sys
import time
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.stdout.reconfigure(encoding='utf-8')
sys.stderr.reconfigure(encoding='utf-8')
import profile_frames as pf  # 复用滑动实现 swipe_list

# dumpsys meminfo 里关心的分区行（行名 → 记录键），取第一列数字 = Pss(KB)
BREAKDOWN_ROWS = {
    'Native Heap': 'native_heap',
    'Dalvik Heap': 'dalvik_heap',
    '.so mmap': 'so_mmap',
    '.art mmap': 'art_mmap',
    '.dex mmap': 'dex_mmap',
    'Graphics': 'graphics',
    'EGL mtrack': 'egl_mtrack',
    'Stack': 'stack',
    'UNKNOWN': 'unknown',
}
HEADERS = ['场景', '数据集', '版本sha', 'TOTAL_RSS_MB', 'Native_Heap_MB', 'Graphics_MB',
           'Dart_heap_MB', '峰值_MB', '峰值时刻动作', '稳态_MB',
           '5min泄漏斜率_KB_per_min', '判定']


def adb_out(serial, args):
    r = subprocess.run(['adb', '-s', serial] + args, capture_output=True, text=True)
    return r.returncode, ((r.stdout or '') + (r.stderr or '')).strip()


def pidof(serial, package):
    rc, out = adb_out(serial, ['shell', 'pidof', '-s', package])
    m = re.search(r'\d+', out or '')
    if rc != 0 or not m:
        raise RuntimeError(f'应用没在跑（pidof {package} 无结果）—— 先手动启动再到目标页面')
    return m.group(0)


def parse_status(text):
    """/proc/<pid>/status → {'rss':KB, 'hwm':KB}。"""
    out = {}
    for key, name in (('VmRSS:', 'rss'), ('VmHWM:', 'hwm')):
        m = re.search(rf'^{key}\s+(\d+)\s+kB', text, re.M)
        if m:
            out[name] = int(m.group(1))
    return out


def parse_breakdown(text):
    """dumpsys meminfo → 各分区 Pss(KB)。列名对不上就整体留空，不猜。"""
    got = {}
    for line in text.splitlines():
        s = line.strip()
        for name, key in BREAKDOWN_ROWS.items():
            if s.startswith(name):
                nums = re.findall(r'\b\d+\b', s[len(name):])
                if nums:
                    got[key] = int(nums[0])
                break
    return got


def parse_vm_service(info):
    """getMemoryUsage 的结果 → 归一化键（字节）。单独拆出来是为了不连设备也能验。"""
    return {
        'heap_usage': info.get('heapUsage'),
        'heap_capacity': info.get('heapCapacity'),
        'external': info.get('external'),
    }


def dart_heap(vm):
    """走 GET + query string（与 profile_frames 同一取数方式，但要带 isolateId）。"""
    def rpc(method, params=None):
        url = vm.rstrip('/') + '/' + method
        if params:
            url += '?' + urllib.parse.urlencode(params)
        with urllib.request.urlopen(url, timeout=30) as resp:
            out = json.load(resp)
        if 'error' in out:
            raise RuntimeError(f'{method}: {out["error"]}')
        return out.get('result')

    return {
        (iso.get('name') or 'isolate').replace(' ', '_'):
            parse_vm_service(rpc('getMemoryUsage', {'isolateId': iso['id']}))
        for iso in rpc('getVM').get('isolates', [])
    }


def slope_kb_per_min(samples):
    """泄漏斜率（KB/min）：窗口三等分，取**最早 1/3 与最晚 1/3 的 RSS 中位数差**，
    除以两组中位时刻之差。
    为什么不是最小二乘：±100KB 的采样抖动/GC 锯齿会被回归拟合成 ~180KB/min 的假斜率
    （自检里那条 zig 就是），中位数差对它是 0；抖动残量约 100KB/窗口跨度，
    所以判据阈值定在 MB 级（见 verdict），真实泄漏（整本账本明文、位图不释放）是 MB/min 量级。"""
    n = len(samples)
    if n < 9:
        return None
    k = n // 3
    first, last = samples[:k], samples[-k:]
    m1 = statistics.median(s['rss'] for s in first)
    m2 = statistics.median(s['rss'] for s in last)
    minutes = (last[len(last) // 2]['t'] - first[len(first) // 2]['t']) / 60.0
    if minutes <= 0:
        return None
    return round((m2 - m1) / minutes, 1)


def verdict(slope):
    if slope is None:
        return '样本不足'
    return 'LEAK' if slope > 2000 else ('观察' if slope > 200 else 'PASS')


def self_check():
    """不连设备也能验的那部分：解析与斜率。"""
    status_new = ("Name:\tpiggycount\nVmHWM:\t  262144 kB\nVmRSS:\t  246810 kB\n"
                  "Threads:\t31\n")
    assert parse_status(status_new) == {'rss': 246810, 'hwm': 262144}, parse_status(status_new)
    dumpsys = """
                   Pss      Pss   Shared  Private   Shared  Private  SwapPss  Rss
                 Total    Clean    Clean    Dirty    Clean    Dirty     Dirty  Dirty
  Native Heap    54012     1000      200    53000        0     1000       20    54500
        Graphics  131072        0   131072        0        0        0   131072        0
      .so mmap     8421     4000     3000     1000     2000      500       10     9000
       TOTAL    123456   ...
"""
    got = parse_breakdown(dumpsys)
    assert got == {'native_heap': 54012, 'graphics': 131072, 'so_mmap': 8421}, got
    assert parse_breakdown('啥都没有') == {}
    rising = [{'t': i * 1.0, 'rss': 200000 + i * 10000} for i in range(20)]
    flat = [{'t': i * 1.0, 'rss': 200000} for i in range(20)]
    zig = [{'t': i * 1.0, 'rss': 200000 + (i % 2) * 100} for i in range(20)]
    assert slope_kb_per_min(rising) == 600000.0, slope_kb_per_min(rising)
    assert slope_kb_per_min(flat) == 0.0, slope_kb_per_min(flat)
    assert slope_kb_per_min(flat[:2]) is None
    # ±100KB 锯齿（GC 锯齿/采样抖动）必须是 0 —— 最小二乘在这里会给出 ~180KB/min 假斜率
    assert slope_kb_per_min(zig) == 0.0, slope_kb_per_min(zig)
    assert verdict(3000) == 'LEAK' and verdict(500) == '观察' and verdict(100) == 'PASS'
    assert verdict(None) == '样本不足'
    assert parse_vm_service(
        {'heapUsage': 1, 'heapCapacity': 2, 'external': 3}) == {
        'heap_usage': 1, 'heap_capacity': 2, 'external': 3}
    print('self-check ok')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--self-check', action='store_true')
    ap.add_argument('--adb-serial')
    ap.add_argument('--package', default='com.wait.piggycount')
    ap.add_argument('--label')
    ap.add_argument('--dataset', default='M', choices=['S', 'M', 'L', 'none'])
    ap.add_argument('--version-sha', default='')
    ap.add_argument('--seconds', type=int, default=90)
    ap.add_argument('--interval', type=float, default=1.0)
    ap.add_argument('--vm', help='VM Service URL，如 http://127.0.0.1:16384/xxxx=')
    ap.add_argument('--swipes', type=int, default=0, help='>0 则期间滑动这么多次（复用 profile_frames）')
    ap.add_argument('--out')
    args = ap.parse_args()
    if args.self_check:
        self_check()
        return
    for req in ('adb_serial', 'label', 'out'):
        if not getattr(args, req):
            ap.error(f'--{req.replace("_", "-")} 必填')

    samples = []
    t_start = time.time()
    t_end = t_start + args.seconds
    swipes_left = args.swipes
    warned = False

    while time.time() < t_end:
        pid = pidof(args.adb_serial, args.package)
        rc, status = adb_out(args.adb_serial, ['shell', 'cat', f'/proc/{pid}/status'])
        got = parse_status(status)
        if 'rss' not in got:
            sys.exit(f'读不到 /proc/{pid}/status 的 VmRSS：{status[:200]}')
        row = {'t': round(time.time() - t_start, 1), 'pid': pid}
        row.update(got)
        rc, dump = adb_out(args.adb_serial, ['shell', 'dumpsys', 'meminfo', args.package])
        row.update(parse_breakdown(dump))
        if args.vm:
            try:
                row['dart'] = dart_heap(args.vm)
            except Exception as e:
                row['dart'] = ''
                row['dart_error'] = str(e)
                if not warned:
                    print(f'  [warn] VM Service 取数失败，只留 dumpsys 侧: {e}')
                    warned = True
        samples.append(row)
        print(f"  RSS={row['rss'] / 1024:.1f}MB HWM={row.get('hwm', 0) / 1024:.1f}MB "
              f"native={(row.get('native_heap') or 0) / 1024:.1f}MB "
              f"graphics={(row.get('graphics') or 0) / 1024:.1f}MB "
              f"dart={sum((v or {}).get('heap_usage') or 0 for v in (row.get('dart') or {}).values()) / 1048576:.1f}MB",
              flush=True)
        if swipes_left > 0:
            pf.swipe_list(args.adb_serial, 1)
            swipes_left -= 1
        time.sleep(max(0.0, args.interval))

    peak = max(samples, key=lambda s: s['rss'])
    tail = samples[len(samples) * 3 // 4:] or samples
    steady = statistics.median(s['rss'] for s in tail)
    slope = slope_kb_per_min(samples)
    dart_last = next((s['dart'] for s in reversed(samples) if s.get('dart')), {})
    dart_mb = {k: round(((v or {}).get('heap_usage') or 0) / 1048576, 2)
               for k, v in dart_last.items()}

    base = f'{args.out}-{args.label.replace(" ", "_")}'
    keys = sorted({k for s in samples for k in s} | {'dart'})
    with open(base + '.samples.csv', 'w', newline='', encoding='utf-8-sig') as f:
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        for s in samples:
            w.writerow({**s, 'dart': json.dumps(s['dart'], ensure_ascii=False)
                        if s.get('dart') else ''})

    summary = {
        'label': args.label, 'dataset': args.dataset, 'versionSha': args.version_sha,
        'samples': len(samples), 'durationSec': args.seconds,
        'firstRssMB': round(samples[0]['rss'] / 1024, 1),
        'lastRssMB': round(samples[-1]['rss'] / 1024, 1),
        'peakRssMB': round(peak['rss'] / 1024, 1), 'peakAtT': peak['t'],
        'hwmMB': round(max(s.get('hwm', 0) for s in samples) / 1024, 1),
        'steadyRssMB': round(steady / 1024, 1),
        'nativeHeapMB': round((samples[-1].get('native_heap') or 0) / 1024, 1),
        'graphicsMB': round((samples[-1].get('graphics') or 0) / 1024, 1),
        'soMmapMB': round((samples[-1].get('so_mmap') or 0) / 1024, 1),
        'dartHeapMB': dart_mb,
        'leakSlopeKBperMin': slope, 'verdict': verdict(slope),
    }
    with open(base + '.summary.json', 'w', encoding='utf-8') as f:
        json.dump(summary, f, ensure_ascii=False, indent=2)

    rows_md = args.out + '-rows.md'
    write_header = not os.path.exists(rows_md)
    with open(rows_md, 'a', encoding='utf-8') as f:
        if write_header:
            f.write('| ' + ' | '.join(HEADERS) + ' |\n')
            f.write('|' + '---|' * len(HEADERS) + '\n')
        f.write('| ' + ' | '.join(str(x) for x in [
            args.label, args.dataset, args.version_sha, summary['lastRssMB'],
            summary['nativeHeapMB'], summary['graphicsMB'],
            round(sum(dart_mb.values()), 2) if dart_mb else '—',
            summary['peakRssMB'], f'{args.label}@t={peak["t"]}s',
            summary['steadyRssMB'], slope, summary['verdict']]) + ' |\n')
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print('行已追加:', rows_md)


if __name__ == '__main__':
    main()
