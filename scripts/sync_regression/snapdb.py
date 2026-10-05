# -*- coding: utf-8 -*-
"""把设备上的 piggycount.sqlite(+wal+shm) 拉回本地。

**必须连 -wal 一起拉**：Drift 走 WAL 模式，App 运行期间的新提交可能还留在
piggycount.sqlite-wal 里没 checkpoint 到主文件。只 `cat piggycount.sqlite`
会静默丢掉这些行（实测 S3 第一轮就因此把 A 的 40008 笔看成 40000 笔，
凭空多出 8 笔「仅 B 有」的假差异）。本地按同名 `-wal`/`-shm` 落盘，
Python sqlite3 打开时会自动重放 WAL，三件套缺一不可。

拉取一律用 `adb exec-out`：`adb shell cat` 会把 \\n 转成 \\r\\n，二进制必坏。
"""
import os
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
PKG = "com.wait.piggycount.dev.debug"
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rundir  # noqa: E402  —— 产物目录统一解析（见 rundir.py）
RD = rundir.run_dir()
REMOTE = f"/data/data/{PKG}/app_flutter"
FILES = ("piggycount.sqlite", "piggycount.sqlite-wal", "piggycount.sqlite-shm")


def pull(port, out, stop=True):
    if stop:
        # force-stop 让连接关闭，SQLite 会在最后连接关闭时 checkpoint（best effort）；
        # 就算没 checkpoint，下面的 -wal 一起拉也能保证数据完整。
        subprocess.run(["adb", "-s", f"127.0.0.1:{port}", "shell",
                        f"am force-stop {PKG}"], capture_output=True)
    base = os.path.join(RD, out)          # out 形如 S3R1_A.sqlite
    got = []
    for fn in FILES:
        local = base if fn == "piggycount.sqlite" else f"{base}-{fn.split('-')[-1]}"
        r = subprocess.run(["adb", "-s", f"127.0.0.1:{port}", "exec-out", "run-as",
                            PKG, "cat", f"{REMOTE}/{fn}"], capture_output=True)
        if r.returncode != 0 or not r.stdout:
            if os.path.exists(local):
                os.remove(local)
            continue
        with open(local, "wb") as f:
            f.write(r.stdout)
        got.append((os.path.basename(local), len(r.stdout)))
    print(f"{port} -> {out}: " + ", ".join(f"{n}={s}B" for n, s in got))
    return base


if __name__ == "__main__":
    if len(sys.argv) == 3:
        pull(sys.argv[1], sys.argv[2])
    else:
        for port, out in (("16384", "A_16384.sqlite"), ("16416", "B_16416.sqlite")):
            pull(port, out)
