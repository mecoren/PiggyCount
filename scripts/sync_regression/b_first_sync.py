# -*- coding: utf-8 -*-
"""B 端首轮：冷启动 → 「发现云端账本」点「下载」→ 等导入完成。

新装设备本地无账本时，同步页会显示「未找到账本」且不渲染上传/下载卡片，
所以云端数据的首次落地走启动期的「发现云端账本」弹窗（点「下载」），
后续轮次本地已有账本，才走同步页「全量下载」。

用法: python b_first_sync.py <port> <tag>
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import flows  # noqa: E402
import uidrv  # noqa: E402

port = sys.argv[1]
tag = sys.argv[2]

uidrv.shell(port, "logcat -c")
ok = flows.boot(port, tag=tag, discover="download", merge="apply", cold=True)
print(f"########## {port} 首页就绪={ok}（已点「下载」）##########")
done = flows.wait_import_done(port, tag, timeout=1800)
print(f"########## {port} 导入完成={done} ##########")

raw = flows.logcat(port, fresh=False)
with open(os.path.join(uidrv.RW, f"{tag}_{port}_logcat.txt"), "w",
          encoding="utf-8", errors="replace", newline="") as f:
    f.write(raw)
for line in raw.splitlines():
    if any(k in line for k in ("云端账本发现完成", "云端账本导入完成", "交易导入完成",
                               "云端新账本导入完成", "附件")):
        print("  " + line.strip()[:210])
sys.exit(0 if ok and done else 1)
