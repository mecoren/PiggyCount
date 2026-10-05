# -*- coding: utf-8 -*-
"""通过 App 界面把设备的后端切到 S3 / WebDAV（纯 UI，不改写任何配置文件）。

沿用 run_20261001 的 S_switch.py 口径：我的 → 云服务 → 点后端卡片 → 确定。
切换后立即回读 shared_prefs 里的 cloud_active_type 作为证据。
"""
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import flows  # noqa: E402
import uidrv  # noqa: E402

RW, PKG = uidrv.RW, uidrv.PKG
CARD = {"s3": "S3 协议存储", "webdav": "自定义 WebDAV"}
LABEL = {"s3": "当前: S3", "webdav": "当前: WebDAV"}


def active_type(port):
    raw = uidrv.adb(port, "exec-out", "run-as", PKG, "cat",
                    f"/data/data/{PKG}/shared_prefs/FlutterSharedPreferences.xml")
    m = re.search(r'cloud_active_type">([^<]*)', raw)
    return m.group(1) if m else "?"


def switch_one(port, target):
    print(f"########## {port} -> {target} ##########", flush=True)
    flows.boot(port, discover="skip")
    if not flows.open_mine(port):
        print("  [FAIL] 未进入「我的」")
        return False
    if not uidrv.click_until(port, "云服务", "当前:", tries=5, wait=4.0):
        print("  [FAIL] 未进入「云服务」")
        return False
    xml = uidrv.dump_xml(port, f"sw_{port}_cloud")
    if LABEL[target] in xml:
        print(f"  已是 {target}，无需切换")
    else:
        n = uidrv.find(xml, CARD[target])
        if not n:
            print(f"  [FAIL] 未找到 {CARD[target]} 卡片")
            return False
        uidrv.tap(port, n["cx"], n["cy"])
        time.sleep(4)
        xml = uidrv.dump_xml(port, f"sw_{port}_confirm")
        n = uidrv.find(xml, "确定") or uidrv.find(xml, "确认")
        if not n:
            print("  [FAIL] 未出现确认弹窗")
            return False
        uidrv.tap(port, n["cx"], n["cy"])
        flows.log("已确认切换")
        time.sleep(8)
    xml = uidrv.dump_xml(port, f"sw_{port}_after")
    print(f"  界面显示 {LABEL[target]}: {LABEL[target] in xml}")
    print(f"  cloud_active_type = {active_type(port)}")
    return active_type(port) == target


if __name__ == "__main__":
    target = sys.argv[1]
    ports = sys.argv[2:] or ["16384", "16416"]
    ok = True
    for p in ports:
        ok = switch_one(p, target) and ok
    print("SWITCH_DONE", target, "ok" if ok else "WITH_FAIL")
    sys.exit(0 if ok else 1)
