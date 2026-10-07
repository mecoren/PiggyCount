# -*- coding: utf-8 -*-
"""把注入好的 seed DB 与附件物理文件推进设备（16384 = A 端）。

adb push 不能直接写 App 私有目录，标准做法：先推到 /data/local/tmp，
再用 `run-as`（以 App 身份）cp 进 app_flutter/ —— 落地文件天然属 App uid。
"""
import os
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
PKG = "com.wait.piggycount.dev.debug"
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rundir  # noqa: E402  —— 用 repo_root()，别自己数 dirname 层级（见 rundir.py）
ROOT = rundir.repo_root()                                  # -> 仓库根
SEED_DB = os.path.join(ROOT, "scripts", "live_db", "seed_16384.sqlite")
ATT_DIR = os.path.join(ROOT, "scripts", "live_db", "seed_attachments")
PORT = "16384"
TMP = "/data/local/tmp"


def sh(*args):
    return subprocess.run(["adb", "-s", f"127.0.0.1:{PORT}"] + list(args),
                          capture_output=True).stdout.decode("utf-8", "replace")


def runas(cmd):
    return sh("shell", f"run-as {PKG} {cmd}")


def main():
    # 1) 停 App，避免打开的连接把旧 WAL 写回
    sh("shell", f"am force-stop {PKG}")
    # 2) 清掉旧 WAL/SHM（连同旧库一起换掉）
    for f in ("piggycount.sqlite", "piggycount.sqlite-wal", "piggycount.sqlite-shm"):
        runas(f"rm -f app_flutter/{f}")
    runas("sh -c 'rm -rf app_flutter/attachments/*'")

    # 3) 推 DB
    size = os.path.getsize(SEED_DB)
    print(f"push DB {size} bytes ...")
    sh("push", SEED_DB, f"{TMP}/seed.sqlite")
    runas(f"cp {TMP}/seed.sqlite app_flutter/piggycount.sqlite")

    # 4) 推附件
    files = sorted(f for f in os.listdir(ATT_DIR) if not f.startswith("."))
    print(f"push {len(files)} 个附件 ...")
    # ★ 必须先建目录：A 端从没落过附件时 `app_flutter/attachments/` 不存在，
    #   下面的 `run-as cp` 会**静默失败**（不报错、附件为空），实测踩过。
    runas("mkdir -p app_flutter/attachments")
    for f in files:
        sh("push", os.path.join(ATT_DIR, f), f"{TMP}/{f}")
    # 逐个 cp（sh -c 带通配在 run-as 下不稳，逐个最保险）
    for f in files:
        runas(f"cp {TMP}/{f} app_flutter/attachments/{f}")
        runas(f"rm -f {TMP}/{f}")

    # 5) 校验
    print("\n--- 设备端校验 ---")
    print(runas("ls -l app_flutter/piggycount.sqlite").strip())
    landed = runas("ls app_flutter/attachments/").split()
    print("附件:", landed)
    if len(landed) != len(files):
        print(f"  [FAIL] 附件落地数 {len(landed)} != 源 {len(files)}")
        sys.exit(1)
    sh("shell", f"rm -f {TMP}/seed.sqlite")


if __name__ == "__main__":
    main()
