# -*- coding: utf-8 -*-
"""清空两台设备的本地业务库，但**绝不触碰** shared_prefs / secure storage。

按项目约定（AGENTS.md）：清库只删 `piggycount.sqlite*` + `attachments/`，
shared_prefs 里存着云服务配置与同步加密密钥，删了就等于毁掉用户的云备份配置。

本脚本在删除前后对 shared_prefs/FlutterSecureStorage/FlutterSecureKeyStorage
做 sha256 指纹比对，指纹不一致即报错退出——把「配置没被动过」变成可复核的证据。
"""
import hashlib
import os
import subprocess
import sys
import time

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
PKG = "com.wait.piggycount.dev.debug"
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rundir  # noqa: E402  —— 产物目录统一解析（见 rundir.py）
RD = rundir.run_dir()
PORTS = ("16384", "16416")
GUARD = ("FlutterSharedPreferences.xml", "FlutterSecureStorage.xml",
         "FlutterSecureKeyStorage.xml")
DB_GLOB = "piggycount.sqlite piggycount.sqlite-wal piggycount.sqlite-shm"


def sh(port, cmd):
    return subprocess.run(["adb", "-s", f"127.0.0.1:{port}", "shell", cmd],
                          capture_output=True).stdout.decode("utf-8", "replace")


def guard_fingerprints(port):
    """对三个配置/密钥文件取 sha256（只读，不改）。"""
    out = {}
    for fn in GUARD:
        r = subprocess.run(["adb", "-s", f"127.0.0.1:{port}", "exec-out", "run-as",
                            PKG, "cat", f"/data/data/{PKG}/shared_prefs/{fn}"],
                           capture_output=True)
        out[fn] = hashlib.sha256(r.stdout).hexdigest()[:16] + f"/{len(r.stdout)}B"
    return out


def clear(port, keep_attachments=False):
    print(f"\n===== 清空 {port} =====")
    before = guard_fingerprints(port)
    sh(port, f"am force-stop {PKG}")
    time.sleep(3)
    for f in DB_GLOB.split():
        sh(port, f"run-as {PKG} rm -f app_flutter/{f}")
    if not keep_attachments:
        # 只删内容，保留 attachments 目录本身（App 启动时若目录缺失会走另一条分支）
        sh(port, f"run-as {PKG} sh -c 'rm -rf app_flutter/attachments/*'")
    time.sleep(1)
    listing = sh(port, f"run-as {PKG} ls -la app_flutter/")
    print("  app_flutter 现状:")
    for line in listing.strip().splitlines():
        print("   ", line)
    after = guard_fingerprints(port)
    print("  配置/密钥指纹（删前 → 删后）:")
    ok = True
    for fn in GUARD:
        same = before[fn] == after[fn]
        ok = ok and same
        print(f"    [{'一致' if same else '!!! 变了'}] {fn}: {before[fn]} → {after[fn]}")
    # 把指纹落盘，供报告引用
    with open(os.path.join(RD, f"guard_{port}.txt"), "w", encoding="utf-8") as f:
        for fn in GUARD:
            f.write(f"{fn}\t{before[fn]}\t{after[fn]}\n")
    return ok


if __name__ == "__main__":
    allok = True
    for p in PORTS:
        allok = clear(p) and allok
    print("\n==== 配置保全结论:", "全部未改动 ✅" if allok else "有改动 ❌", "====")
    sys.exit(0 if allok else 1)
