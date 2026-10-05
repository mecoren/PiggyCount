# -*- coding: utf-8 -*-
"""WebDAV 服务端数据目录快照（只读）：文件清单 + 体积 + sha256。

用于两端「服务端侧证据」：
  * 上传前后对比（哪些对象被原地覆盖、有没有多出新槽位）；
  * 与 App 端 DB 的附件/账本互相印证（服务端对象数应等于账本数）；
  * 检查 `.tmp` / 半成品残留（PUT 是否原子落地）。

用法: python wd_cloud_snapshot.py <out.txt> [--dir <数据目录>]
"""
import hashlib
import os
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rundir  # noqa: E402  —— 产物目录统一解析（见 rundir.py）
RD = rundir.run_dir()
# 相对仓库根推导，别写死盘符（换机器 / 换 checkout 路径就失效）
DEFAULT_DIR = os.path.join(rundir.repo_root(), "scripts", "webdav_test", "data",
                           "piggycount")


def main():
    out_name = sys.argv[1] if len(sys.argv) > 1 else "wd_cloud_snapshot.txt"
    root = DEFAULT_DIR
    if "--dir" in sys.argv:
        root = sys.argv[sys.argv.index("--dir") + 1]

    lines = [f"===== WebDAV 服务端数据目录快照 =====",
             f"目录: {root}",
             f"时间: {__import__('datetime').datetime.now():%Y-%m-%d %H:%M:%S}", ""]
    if not os.path.isdir(root):
        print("目录不存在"); sys.exit(1)

    total = 0
    for name in sorted(os.listdir(root)):
        p = os.path.join(root, name)
        if os.path.isdir(p):
            sub = sorted(os.listdir(p))
            sz = sum(os.path.getsize(os.path.join(p, s)) for s in sub
                     if os.path.isfile(os.path.join(p, s)))
            lines.append(f"  [DIR ] {name}/  {len(sub)} 项  {sz}B"
                         f"{'  <-- 非账本目录，App 不识别' if not name.startswith('ledger') else ''}")
        else:
            sz = os.path.getsize(p)
            total += sz
            h = hashlib.sha256(open(p, "rb").read()).hexdigest()
            lines.append(f"  [FILE] {name}  {sz}B  sha256={h[:32]}…")
    tops = [n for n in os.listdir(root) if n.startswith("ledger_")]
    tmps = [n for n in os.listdir(root) if n.endswith(".tmp") or ".tmp." in n]
    lines += ["",
              f"  ledger_* 对象数 = {len(tops)}",
              f"  .tmp 残留 = {len(tmps)} {tmps if tmps else '(无)'}",
              f"  顶层文件合计 = {total}B"]
    text = "\n".join(lines)
    print(text)
    with open(os.path.join(RD, out_name), "w", encoding="utf-8", newline="") as f:
        f.write(text)
    print(f"\n-> {out_name}")


if __name__ == "__main__":
    main()
