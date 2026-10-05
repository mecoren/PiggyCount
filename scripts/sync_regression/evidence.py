# -*- coding: utf-8 -*-
"""每轮证据**当场落盘** —— 不再依赖「下一轮还能读到」。

★ 为什么必须当场存（20261004 实盘教训，差点让报告缺证）：
  App 内 `flutter.app_logs` 是长度 **2000 的环形缓冲**，且跨重启存活。
  R1 刚跑完时它的条目还在；等 R2/R3 继续往环里写，R1 的条目就被挤出去了。
  等到写报告、想去核对「R1 时 B 端到底导入了什么」时，环里已经没有了。
  本轮最后只能从 `WDR2_16416_16416_prefs.xml` —— 一份**碰巧**在 R2 时点
  留下来的 prefs 快照 —— 里把 R1 的日志捞回来。**这是运气，不是方法。**

  同一类问题的第二个来源：`logcat` 缓冲会被 `logcat -c` 清掉，也会被系统轮转。
  `run_20260916/`、`run_20261004/` 里的 `*_logcat.txt` 大多是 **0 字节**
  （旧写法 `-s flutter:V flutter:I …` 多 spec 后者覆盖前者 → 等价 `flutter:E`），
  导致那些轮次根本没有 logcat 可用。

  结论：**每一轮动作一结束，立刻把 app_logs / logcat / UI dump 落到磁盘。**
  这是唯一不依赖缓冲容量的做法。

落盘产物（全部写进 rundir.run_dir()，即 gitignore 的 `scripts/live_db/` 下）::

    <tag>_<port>_<stage>_applogs.txt    flutter.app_logs 解析后的全文（**核心**）
    <tag>_<port>_<stage>_prefs.xml      shared_prefs 原始快照（环的冻结副本，含密文配置摘要）
    <tag>_<port>_<stage>_logcat.txt     logcat -d -s flutter:V
    <tag>_<port>_<stage>_ui.xml/.png    UI 语义树 + 截图（ui=True 时）
    _evidence_index.txt                 本次运行所有证据的索引（追加写）

用法（脚本里）::

    import evidence
    evidence.capture(port, tag, "R1", ui=True, note="upload ok, 43s")

用法（命令行，事后补一份当前状态）::

    python evidence.py <port> <tag> <stage> [--ui]
"""
import json
import os
import re
import sys
import time

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import flows  # noqa: E402
import rundir  # noqa: E402
import uidrv  # noqa: E402

RD = rundir.run_dir()
PKG = uidrv.PKG
INDEX = "_evidence_index.txt"

# 关键证词：索引里只留这些「一眼能判过没过」的行，避免索引被淹没
KEY_PATTERNS = (
    ("上传", r"(Starting upload|Post-upload verify passed|全量上传完成|上传完成[:：].*)"),
    ("下载", r"(全量覆盖下载完成|完整性终审通过|正在从云端恢复.*)"),
    ("导入", r"(云端新账本导入完成|TxImport 交易导入完成.*)"),
    ("候选", r"(无候选账本.*|云端指纹[:：].*|发现云端账本.*)"),
    ("附件", r"(附件.*(完成|失败|恢复).*)"),
    ("错误", r"(ERROR|异常|失败|Exception)"),
)


def _p(tag, port, stage, suffix):
    path = os.path.join(RD, f"{tag}_{port}_{stage}_{suffix}")
    if rundir.is_inside_repo_tracked(path):
        raise RuntimeError(
            f"证据路径落在 harness 目录内（{path}）—— 调用方必须经 rundir.run_dir()")
    return path


def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    # newline="" —— 禁止 Windows 文本模式把 \n 翻成 \r\n（否则 sha256 比对假性 DIFF）
    with open(path, "w", encoding="utf-8", errors="replace", newline="") as f:
        f.write(text)
    return len(text.splitlines())


def key_lines(applogs_text, limit_per_group=2):
    """从 app_logs 全文里挑出关键证词行（索引用）。"""
    out = []
    lines = applogs_text.splitlines()
    for label, pat in KEY_PATTERNS:
        rx = re.compile(pat)
        hits = [ln for ln in lines if rx.search(ln)]
        for ln in hits[-limit_per_group:]:
            out.append(f"      {label}: {ln.strip()[:150]}")
    return out


def capture_applogs(port, tag, stage, keep_prefs=True):
    """落盘 flutter.app_logs 解析全文（**防 ring 覆盖的主力**）。

    复用 flows.app_logs()：它顺带把 shared_prefs 原始快照写到
    `<tag>_<port>_prefs.xml`。我们把它重定向成**带 stage 的文件名**，
    这样每轮都冻结一份环，而不是所有轮共用一份、互相覆盖。

    返回 (行数, 文本)。
    """
    text = flows.app_logs(port, f"{tag}_{port}_{stage}")
    if not text:
        # app_logs 键缺失（首次启动 / prefs 被清）——不要静默通过
        text = "（flutter.app_logs 键缺失或为空）"
    n = _write(_p(tag, port, stage, "applogs.txt"), text)
    if not keep_prefs:
        try:
            os.remove(_p(tag, port, stage, "prefs.xml"))
        except OSError:
            pass
    return n, text


def capture_logcat(port, tag, stage, clear=False):
    """落盘 logcat -d -s flutter:V。返回行数。

    clear=True 会先 `logcat -c` 清缓冲。**在轮次开始时用 clear=True**，
    这样该轮的 logcat 恰好覆盖该轮动作，不需要事后按挂钟时间猜窗口
    （applog_evidence.py 的 WINDOWS 就是这么猜的，脆弱）。
    """
    txt = flows.logcat(port, fresh=clear)
    return _write(_p(tag, port, stage, "logcat.txt"), txt)


def capture_ui(port, tag, stage):
    """落盘 UI 语义树 + 截图（uidrv.dump_xml 自己处理 .xml/.png 两个后缀）。"""
    xml = uidrv.dump_xml(port, f"{tag}_{port}_{stage}_ui")
    return len(xml.splitlines())


def append_index(port, tag, stage, note="", counts=None):
    """在运行级索引里追加一行（含关键证词），使「哪轮有证据」一目了然。"""
    path = os.path.join(RD, INDEX)
    counts = dict(counts or {})
    # ★ 必须先摘掉 _applogs_text 再拼 head，否则整份日志会被塞进索引行
    applogs = counts.pop("_applogs_text", None)
    head = (f"[{time.strftime('%H:%M:%S')}] {stage} port={port} tag={tag} "
            + " ".join(f"{k}={v}" for k, v in counts.items()))
    if note:
        head += f"  # {note}"
    lines = [head]
    if applogs:
        lines.extend(key_lines(applogs))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a", encoding="utf-8", errors="replace", newline="") as f:
        f.write("\n".join(lines) + "\n")
    return path


def capture(port, tag, stage, ui=False, clear_logcat=False, note="",
            keep_prefs=True, index=True):
    """一站式：app_logs + logcat +（可选）UI dump，并追加索引行。

    返回 {"applogs": n, "logcat": n, "ui": n|None}
    """
    counts = {}
    n_app, app_text = capture_applogs(port, tag, stage, keep_prefs=keep_prefs)
    counts["applogs"] = n_app
    counts["logcat"] = capture_logcat(port, tag, stage, clear=clear_logcat)
    if ui:
        counts["ui"] = capture_ui(port, tag, stage)
    if index:
        append_index(port, tag, stage, note=note,
                     counts=dict(counts, _applogs_text=app_text))
    flows.log(f"证据已落盘 {tag}_{port}_{stage}_*  "
              f"(applogs={counts['applogs']} logcat={counts['logcat']}"
              + (f" ui={counts['ui']}" if ui else "") + ")")
    return counts


# ---------------------------------------------------------------- CLI
def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) < 3:
        print(__doc__)
        return 2
    port, tag, stage = args[0], args[1], args[2]
    r = capture(port, tag, stage, ui=("--ui" in sys.argv),
                clear_logcat=("--clear" in sys.argv))
    print(json.dumps(r, ensure_ascii=False))
    print(f"-> {RD}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
