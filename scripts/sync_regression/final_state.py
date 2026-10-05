# -*- coding: utf-8 -*-
"""收尾状态取证：三件配置/密钥文件的 sha256 + cloud_active_type + 加密开关 + 条目数。

只读，不改任何东西。用于回答「整轮测试有没有动过云备份配置」——
把测试前 baseline_cloud_config.txt 与测试后本脚本的输出并排比对即可。

用法: python final_state.py <out.txt>
"""
import hashlib
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
PKG = "com.wait.piggycount.dev.debug"
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rundir  # noqa: E402  —— 产物目录统一解析（见 rundir.py）
RD = rundir.run_dir()
PORTS = ("16384", "16416")
GUARD = ("FlutterSharedPreferences.xml", "FlutterSecureStorage.xml",
         "FlutterSecureKeyStorage.xml")


def read(port, fn):
    r = subprocess.run(["adb", "-s", f"127.0.0.1:{port}", "exec-out", "run-as",
                        PKG, "cat", f"/data/data/{PKG}/shared_prefs/{fn}"],
                       capture_output=True)
    return r.stdout


def main():
    lines = []
    for p in PORTS:
        lines.append(f"## 端点 127.0.0.1:{p}")
        for fn in GUARD:
            raw = read(p, fn)
            lines.append(f"  {fn}\tsha256={hashlib.sha256(raw).hexdigest()}"
                         f"\tbytes={len(raw)}")
        prefs = read(p, "FlutterSharedPreferences.xml").decode("utf-8", "replace")
        for key in ("cloud_active_type", "piggycount_enc_enabled",
                    "piggycount_enc_verifier"):
            # ★ 20261004 修：SharedPreferences 里同名的键**存储类型不固定**。
            # `cloud_active_type` 是 <string name="...">值</string>，
            # 而 `piggycount_enc_enabled` 实测是 <boolean name="..." value="true" />。
            # 旧实现只写了字符串形式 `name">([^<]*)<`，于是布尔键恒判「(缺)」——
            # 20261004b 轮就因此把「加密仍开启」误读成「键丢了」。
            # 三种形态都要认：string 带文本 / boolean|int|long 带 value= 属性。
            m = (re.search(rf'<string name="[^"]*{key}">([^<]*)</string>', prefs)
                 or re.search(rf'<[a-z]+ name="[^"]*{key}"\s+value="([^"]*)"', prefs))
            val = m.group(1) if m else "(缺)"
            if key.endswith("verifier") and m:
                val = val[:16] + "…"
            lines.append(f"  {key} = {val}")
        sec = read(p, "FlutterSecureStorage.xml").decode("utf-8", "replace")
        lines.append(f"  FlutterSecureStorage 条目数 = {sec.count('<string name=')}")
        lines.append("")
    text = "\n".join(lines)
    print(text)
    if len(sys.argv) > 1:
        with open(os.path.join(RD, sys.argv[1]), "w", encoding="utf-8",
                  newline="") as f:
            f.write(text)
        print(f"-> {sys.argv[1]}")


if __name__ == "__main__":
    main()
