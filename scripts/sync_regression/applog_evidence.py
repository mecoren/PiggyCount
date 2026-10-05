# -*- coding: utf-8 -*-
"""把 App 持久化日志（flutter.app_logs 环）里的传输证据按轮次切出来。

## 两种模式

**默认（推荐）—— 汇总 ⑦ 产出的逐轮冻结副本**
  `evidence.py` 现在每轮动作结束都会把解析后的 app_logs 全文落成
  `<tag>_<port>_<stage>_applogs.txt`。既然每轮都已经有**精确保留**的那一段，
  就不需要再去切环、也不需要猜时间窗 —— 直接遍历这些文件汇总即可。
  这消除了本脚本原先最大的脆弱点：`WINDOWS` 是一组**手写的挂钟时间窗**
  （`("R1","16:29","16:39")`…），轮次时间一变、或环被挤爆，窗口就空了。

**`--ring` —— 旧数据兜底（依赖环 + 手写时间窗）**
  对 ⑦ 之前的运行（如 `run_20261004/`、`run_20260916/`）仍然只能切环。
  必须显式给 `--windows "R1=17:26-17:42,R2=17:46-17:51"`，不再内置任何窗口。

用法::

  python applog_evidence.py [out.txt]                     # 汇总冻结副本
  python applog_evidence.py [out.txt] --ring --windows "R1=17:26-17:42,..."
"""
import datetime
import glob
import json
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
PKG = "com.wait.piggycount.dev.debug"
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rundir  # noqa: E402  —— 产物目录统一解析（见 rundir.py）
RD = rundir.run_dir()

PAT = re.compile(
    r"Starting upload|Post-upload verify passed|上传完成:|云端新账本导入完成|"
    r"完整性终审通过|全量覆盖下载完成|TxImport 交易导入完成|"
    r"云端指纹: 无|无候选账本|合并后回传完成|全量上传完成|发现云端账本")

PORTS = (("16384", "A 上传端"), ("16416", "B 接收端"))


# ---------------------------------------------------------------- 冻结副本模式
def summarize_frozen():
    """遍历 evidence.py 落下的 `<...>_applogs.txt`，按轮次汇总。"""
    files = sorted(glob.glob(os.path.join(RD, "*_applogs.txt")))
    if not files:
        return ["（未找到任何 *_applogs.txt —— evidence.py 是否已接入本轮流程？）"]
    lines = [f"===== 逐轮冻结副本汇总（{len(files)} 份）=====",
             "来源: evidence.py 在每轮动作结束时落盘的 app_logs 全文（不经环、不需时间窗）",
             ""]
    for path in files:
        name = os.path.basename(path)
        m = re.match(r"(.+?)_(\d{5})_(.+)_applogs\.txt$", name)
        tag, port, stage = (m.group(1), m.group(2), m.group(3)) if m else (name, "?", "?")
        with open(path, encoding="utf-8", errors="replace") as f:
            raw = f.read()
        keep = [ln for ln in raw.splitlines() if PAT.search(ln)]
        lines.append(f"--- {tag} / port={port} / stage={stage} ---")
        lines.append(f"    文件 {name}  总 {len(raw.splitlines())} 行 / 传输相关 {len(keep)} 行")
        up = sum(1 for ln in keep if "Starting upload" in ln)
        ver = sum(1 for ln in keep if "Post-upload verify passed" in ln)
        integ = sum(1 for ln in keep if "完整性终审通过" in ln)
        imp = [ln for ln in keep if "云端新账本导入完成" in ln]
        tx = [ln for ln in keep if "TxImport 交易导入完成" in ln]
        done = [ln for ln in keep if "上传完成" in ln or "全量覆盖下载完成" in ln]
        lines.append(f"    上传: Starting upload={up} / verify passed={ver}")
        lines.append(f"    下载: 完整性终审通过={integ} / 终态={done[-1][:120] if done else '—'}")
        if imp:
            lines.append(f"    导入: {imp[-1][:140]}")
        if tx:
            lines.append(f"    逐本导入: {tx[-1][:140]}")
        for ln in keep[:3]:
            lines.append(f"      · {ln.strip()[:150]}")
        lines.append("")
    return lines


# ---------------------------------------------------------------- 环模式（兜底）
def read_ring(port):
    r = subprocess.run(["adb", "-s", f"127.0.0.1:{port}", "exec-out", "run-as",
                        PKG, "cat",
                        f"/data/data/{PKG}/shared_prefs/FlutterSharedPreferences.xml"],
                       capture_output=True)
    s = r.stdout.decode("utf-8", "replace")
    m = re.search(r'<string name="flutter\.app_logs">(.*?)</string>', s, re.S)
    if not m:
        return []
    t = (m.group(1).replace("&quot;", '"').replace("&amp;", "&")
         .replace("&lt;", "<").replace("&gt;", ">").replace("&#39;", "'"))
    try:
        arr = json.loads(t)
    except Exception as e:                       # noqa: BLE001
        print(f"  {port}: app_logs 解析失败 {e}")
        return []
    out = []
    for a in arr:
        msg = str(a.get("message", ""))
        if not PAT.search(msg):
            continue
        ts = datetime.datetime.fromtimestamp(a["timestamp"] / 1000)
        out.append((ts.strftime("%H:%M:%S"), str(a.get("tag", "")), msg))
    return out


def parse_windows(spec):
    """'R1=17:26-17:42,R2=17:46-17:51' -> [('R1','17:26','17:42'), ...]"""
    wins = []
    for part in spec.split(","):
        part = part.strip()
        if not part or "=" not in part:
            continue
        tag, rng = part.split("=", 1)
        lo, _, hi = rng.partition("-")
        wins.append((tag.strip(), lo.strip(), hi.strip()))
    return wins


def summarize_ring(windows):
    if not windows:
        return ["（--ring 模式必须给 --windows \"R1=17:26-17:42,...\" —— "
                "本脚本不再内置任何时间窗）"]
    lines = []
    for port, who in PORTS:
        logs = read_ring(port)
        lines.append(f"########## {port}（{who}）共 {len(logs)} 条传输相关日志 ##########")
        for tag, lo, hi in windows:
            seg = [x for x in logs if lo <= x[0] < hi]
            up = sum(1 for x in seg if x[2].startswith("Starting upload"))
            ver = sum(1 for x in seg if x[2].startswith("Post-upload verify passed"))
            done = [x[2] for x in seg if x[2].startswith("上传完成")]
            finals = [x for x in seg if x[2].startswith("全量覆盖下载完成")]
            integ = sum(1 for x in seg if x[2].startswith("完整性终审通过"))
            imp = [x[2] for x in seg if x[2].startswith("云端新账本导入完成")]
            tx = [x[2] for x in seg if x[2].startswith("TxImport 交易导入完成")]
            lines.append(f"  [{tag}] 窗口 {lo}~{hi}  日志 {len(seg)} 条")
            lines.append(f"      上传: Starting upload={up} / Post-upload verify"
                         f" passed={ver} / 上传完成={done[-1] if done else '—'}")
            lines.append(f"      下载: 完整性终审通过={integ} / 终态="
                         f"{finals[0][2] if finals else '—'}")
            if imp:
                lines.append(f"      导入: {imp}")
            if tx:
                lines.append(f"      逐本导入: {tx[-1]}")
        lines.append("  # 原始行（前 6 条 + 后 6 条）")
        for t, tg, msg in (logs[:6] + logs[-6:]):
            lines.append(f"    {t} {msg[:160]}")
        lines.append("")
    return lines


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    out_name = args[0] if args else None
    if "--ring" in sys.argv:
        if "--windows" not in sys.argv:
            print("--ring 模式需要 --windows", file=sys.stderr)
            return 2
        lines = summarize_ring(parse_windows(
            sys.argv[sys.argv.index("--windows") + 1]))
    else:
        lines = summarize_frozen()
    text = "\n".join(lines)
    print(text)
    if out_name:
        with open(os.path.join(RD, out_name), "w", encoding="utf-8",
                  newline="") as f:
            f.write(text)
        print(f"-> {out_name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
