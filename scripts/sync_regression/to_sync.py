# -*- coding: utf-8 -*-
"""把设备导航到「我的 → 同步」页（云同步页），供 round.py 使用。

用法: python to_sync.py <port> [tag]
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import flows  # noqa: E402
import uidrv  # noqa: E402

port = sys.argv[1]
tag = sys.argv[2] if len(sys.argv) > 2 else None

# 先确认当前是否已在同步页（在的话就不用乱点，避免误触）
xml = uidrv.dump_xml(port)
if uidrv.has_key(xml, "全量上传"):
    flows.log(f"{port} 已在同步页")
    sys.exit(0)

# 逐层退出到首页
for _ in range(6):
    xml = uidrv.dump_xml(port)
    if uidrv.has_key(xml, "明细") and uidrv.has_key(xml, "记账") \
            and uidrv.has_key(xml, "我的"):
        break
    uidrv.shell(port, "input keyevent 4")
    time.sleep(2.5)

ok = flows.open_sync_page(port, tag)
flows.log(f"{port} 同步页就绪={ok}")
sys.exit(0 if ok else 1)
