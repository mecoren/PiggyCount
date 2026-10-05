# -*- coding: utf-8 -*-
"""比对两台设备附件的**物理文件**（内容寻址 sha_*.jpg），而不只是 DB 里的元数据行。

DB 里 transaction_attachments 一致 ≠ 设备上真有这些字节。附件是内容寻址
（文件名 = sha256），所以直接对 app_flutter/attachments/ 下每个文件算 sha256，
两端按文件名对齐比对即可。

用法: python att_check.py <tag> <16384|16416> <16384|16416>
"""
import hashlib
import os
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
PKG = "com.wait.piggycount.dev.debug"
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rundir  # noqa: E402  —— 产物目录统一解析（见 rundir.py）
RD = rundir.run_dir()
ATT = f"/data/data/{PKG}/app_flutter/attachments"


def hashes(port):
    r = subprocess.run(["adb", "-s", f"127.0.0.1:{port}", "exec-out", "run-as",
                        PKG, "ls", ATT], capture_output=True)
    names = [n for n in r.stdout.decode("utf-8", "replace").split()
             if n.strip() and not n.startswith("sha_") is None]
    names = [n for n in names if n.strip()]
    out = {}
    for n in names:
        if not n.endswith(".jpg"):
            continue
        h = subprocess.run(["adb", "-s", f"127.0.0.1:{port}", "exec-out", "run-as",
                            PKG, "sha256sum", f"{ATT}/{n}"], capture_output=True)
        digest = h.stdout.decode("utf-8", "replace").split()[0] if h.stdout else "?"
        out[n] = digest
    return out


def main():
    tag = sys.argv[1]
    pa, pb = sys.argv[2], sys.argv[3]
    ha, hb = hashes(pa), hashes(pb)
    print(f"== {tag} 附件物理文件比对 ==")
    print(f"  {pa}: {len(ha)} 个   {pb}: {len(hb)} 个")
    only_a, only_b = sorted(set(ha) - set(hb)), sorted(set(hb) - set(ha))
    bad = [n for n in sorted(set(ha) & set(hb)) if ha[n] != hb[n]]
    for n in only_a:
        print(f"  [!!] 仅 {pa}: {n}")
    for n in only_b:
        print(f"  [!!] 仅 {pb}: {n}")
    for n in bad:
        print(f"  [!!] 内容不同: {n} A={ha[n][:16]} B={hb[n][:16]}")
    ok = not (only_a or only_b or bad)
    for n in sorted(set(ha) & set(hb)):
        print(f"  [OK] {n[:20]}.. {ha[n][:16]} == {hb[n][:16]}")
    with open(os.path.join(RD, f"{tag}_att_md5.txt"), "w", encoding="utf-8") as f:
        for n in sorted(set(ha) | set(hb)):
            f.write(f"{n}\t{ha.get(n,'-')}\t{hb.get(n,'-')}\n")
    print(f"  结论: {'全部一致 ✅' if ok else '存在差异 ❌'}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
