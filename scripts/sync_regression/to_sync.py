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

# ★ 前台守门（2026-10-07 r2 修复）：clear_db.py / push_seed.py 都会 `am force-stop`
#   而**不**重启 App，编排里紧跟在它们之后的首次 to_sync 就会对着**桌面**连按 BACK、
#   再找「我的」必然失败（实测：A 端 S3R1_A1_to_sync 133s 超时，boot_fail.xml 抓到的是
#   启动器而非 App）。旧版默认「调用前 App 已在跑」，只在人工分步操作时才成立。
_fg = uidrv.shell(port, "dumpsys window | grep -E 'mCurrentFocus'")
if "piggycount" not in _fg:
    flows.log(f"{port} App 不在前台，拉起 ...")
    uidrv.launch(port)
    time.sleep(12)
    # 冷启动期间可能弹「发现云端账本 / 云端有更新」：一律**不**并云端（skip），
    # 否则会把云端旧内容拉进 A，污染本轮「A 上传」的语义。
    flows.dismiss_blockers(port, rounds=6, discover="skip", merge="skip")

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
