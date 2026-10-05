# -*- coding: utf-8 -*-
"""列出 prefs 里与「云服务 / 同步加密」相关的键（只读），用于证明云配置未被动过。

FlutterSharedPreferences.xml 里同时混着 flutter.app_logs（运行期日志环）等
**必然变化**的内容，所以「文件 sha256 一致」不是合适的判据；正确做法是只看
云配置键的取值。本脚本同时把「非日志键」的取值快照落盘以便逐键比对。

用法: python prefs_keys.py [out.txt]
"""
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
PKG = "com.wait.piggycount.dev.debug"
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rundir  # noqa: E402  —— 产物目录统一解析（见 rundir.py）
RD = rundir.run_dir()
CLOUD_RE = re.compile(r"cloud|enc_|sync|s3|webdav|dav|bucket|secret|access|endpoint",
                      re.I)
SKIP_RE = re.compile(r"app_logs|_log$|lastBoot|perf_", re.I)


def prefs(port):
    r = subprocess.run(["adb", "-s", f"127.0.0.1:{port}", "exec-out", "run-as",
                        PKG, "cat",
                        f"/data/data/{PKG}/shared_prefs/FlutterSharedPreferences.xml"],
                       capture_output=True)
    return r.stdout.decode("utf-8", "replace")


def main():
    out = []
    for port in ("16384", "16416"):
        s = prefs(port)
        out.append(f"## 端点 127.0.0.1:{port}  (prefs {len(s)}B)")
        pairs = []
        for m in re.finditer(r'<(\w+) name="([^"]+)"(?:\s+value="([^"]*)")?\s*'
                             r'(?:/>|>([^<]*)</\1>)', s, re.S):
            typ, key, vattr, vbody = m.group(1), m.group(2), m.group(3), m.group(4)
            val = vattr if vattr is not None else (vbody or "")
            pairs.append((typ, key, val))
        out.append(f"  prefs 键总数: {len(pairs)}")
        cloud = [(t, k, v) for t, k, v in pairs if CLOUD_RE.search(k)]
        out.append(f"  # 云服务/加密相关键 ({len(cloud)})")
        for t, k, v in cloud:
            shown = v if len(v) <= 72 else v[:72] + "…"
            out.append(f"    [{'*' if CLOUD_RE.search(k) else ' '}] {k} = {shown}")
        others = [(t, k, v) for t, k, v in pairs
                  if not CLOUD_RE.search(k) and not SKIP_RE.search(k)]
        out.append(f"  # 其它非日志键 ({len(others)}) —— 逐键取值指纹")
        import hashlib
        blob = "\n".join(f"{k}={v}" for _, k, v in sorted(others))
        out.append(f"    sha256(排序后 '键=值' 串) = "
                   f"{hashlib.sha256(blob.encode()).hexdigest()[:32]}")
        out.append("")
    text = "\n".join(out)
    print(text)
    if len(sys.argv) > 1:
        with open(os.path.join(RD, sys.argv[1]), "w", encoding="utf-8",
                  newline="") as f:
            f.write(text)
        print(f"-> {sys.argv[1]}")


if __name__ == "__main__":
    main()
