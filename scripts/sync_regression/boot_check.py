# -*- coding: utf-8 -*-
"""冷启动某端并抓取启动期日志（看云端指纹 / 发现云端账本 / 同步状态）。

用法: python boot_check.py <port> <tag> [discover]
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import flows  # noqa: E402
import uidrv  # noqa: E402

port = sys.argv[1]
tag = sys.argv[2]
discover = sys.argv[3] if len(sys.argv) > 3 else "skip"

uidrv.shell(port, "logcat -c")
ok = flows.boot(port, tag=tag, discover=discover, merge="apply", cold=True)
time.sleep(6)
raw = flows.logcat(port, fresh=False)
with open(os.path.join(uidrv.RW, f"{tag}_{port}_boot_logcat.txt"), "w",
          encoding="utf-8", errors="replace", newline="") as f:
    f.write(raw)

keys = ("云端指纹", "云端账本发现完成", "发现云端账本", "SyncDiff", "inSync",
        "Starting upload", "上传完成", "云端有更新", "同步状态检查失败",
        "merge", "下载")
print(f"########## {port} 首页就绪={ok} ##########")
for line in raw.splitlines():
    if any(k in line for k in keys):
        print("  " + line.strip()[:220])
