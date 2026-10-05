# -*- coding: utf-8 -*-
"""一轮「上传 / 下载」闭环的驱动器。

上传与下载的确认弹窗都是**两级**（第一次说明影响，第二次「再次确认」），
所以这里不写死点几下，而是循环：看 UI 处于「待确认」就点确认，处于「进行中」
就等，完成后退出——这样弹窗级数变化也不会跑飞。

用法:
  python round.py upload   <tag> [port]
  python round.py download <tag> [port]
"""
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence  # noqa: E402
import flows  # noqa: E402
import uidrv  # noqa: E402

RW = uidrv.RW

# 「待确认」特征：弹窗文案里带这些词，且存在可点的 确定/确认/覆盖上传/覆盖下载
CONFIRM_HINTS = ("将把本地", "云端全部账本将完全覆盖", "再次确认",
                 "确认将", "覆盖上传", "覆盖下载")
CONFIRM_KEYS = ("覆盖上传", "覆盖下载", "确定", "确认")
# 「进行中」特征
BUSY_HINTS = ("正在全量上传", "正在上传账本", "正在从云端恢复", "正在下载",
              "正在校验", "正在比对")
# 「完成」特征
DONE_HINTS = ("全量上传完成", "全量下载完成", "已上传")


def confirm_loop(port, tag, action, timeout=3000):
    """点满所有确认弹窗，然后等动作结束。返回 (ok, elapsed)。"""
    t0 = time.time()
    clicks = 0
    seen_busy = False
    last = ""
    while time.time() - t0 < timeout:
        xml = uidrv.dump_xml(port)
        # 1) 完成？
        if any(h in xml for h in DONE_HINTS):
            uidrv.dump_xml(port, f"{tag}_{port}_{action}_done")
            flows.log(f"{action} 完成，用时 {time.time()-t0:.0f}s，确认 {clicks} 次")
            return True, time.time() - t0
        # 2) 待确认？
        if any(h in xml for h in CONFIRM_HINTS):
            n = None
            for k in CONFIRM_KEYS:
                n = uidrv.find(xml, k)
                if n:
                    break
            if n:
                # 二次确认弹窗的标题固定是动作名，用它区分并留证
                flows.log(f"确认弹窗 → 点「{k if n else ''}」({clicks+1})")
                uidrv.tap(port, n["cx"], n["cy"])
                clicks += 1
                time.sleep(3)
                continue
        # 3) 进行中？
        if any(h in xml for h in BUSY_HINTS):
            if not seen_busy:
                flows.log("进入进行中遮罩")
                seen_busy = True
            time.sleep(10)
            continue
        # 4) 遮罩已消失但没见到完成文案：给一次宽限，再抓 UI 存证
        if seen_busy:
            time.sleep(6)
            xml2 = uidrv.dump_xml(port, f"{tag}_{port}_{action}_after")
            if any(h in xml2 for h in DONE_HINTS) or not any(
                    h in xml2 for h in BUSY_HINTS):
                flows.log(f"{action} 遮罩消失 ({time.time()-t0:.0f}s)")
                return True, time.time() - t0
        time.sleep(5)
    uidrv.dump_xml(port, f"{tag}_{port}_{action}_timeout")
    flows.log(f"{action} 超时 ({time.time()-t0:.0f}s)")
    return False, time.time() - t0


def main():
    action = sys.argv[1]
    tag = sys.argv[2]
    port = sys.argv[3] if len(sys.argv) > 3 else ("16384" if action == "upload"
                                                   else "16416")
    flows.log(f"===== {tag} {action} on {port} =====")
    uidrv.dump_xml(port, f"{tag}_{port}_{action}_pre")
    # 先把「本轮开始前」的 logcat 存档（含冷启动那一段，别丢），再清缓冲：
    # 这样 <action>_logcat.txt 恰好只覆盖本轮动作，无需事后按挂钟时间猜窗口。
    evidence.capture_logcat(port, tag, f"{action}_pre", clear=False)
    uidrv.shell(port, "logcat -c")
    key = "全量上传" if action == "upload" else "全量下载"
    n = uidrv.find(uidrv.dump_xml(port), key)
    if not n:
        flows.log(f"[FAIL] 未找到「{key}」，请确认已停在同步页")
        return 2
    uidrv.tap(port, n["cx"], n["cy"])
    time.sleep(3)
    ok, el = confirm_loop(port, tag, action)
    # ★ 证据当场落盘（⑦）：app_logs 环只有 2000 条且跨重启存活，R1 的条目
    #   会被后续轮次挤出去 —— 本轮就吃过这个亏（只能从旧 prefs 快照里捞回 R1）。
    #   所以动作一结束立刻冻结：解析后的 app_logs 全文 + prefs 快照 + UI + logcat。
    #   `_pre` 阶段先 clear logcat，使该轮 logcat 恰好覆盖该轮动作，
    #   不必像 applog_evidence.py 那样事后按挂钟时间猜窗口。
    evidence.capture(port, tag, action, ui=True,
                     note=f"{action} ok={ok} elapsed={el:.0f}s")
    print(f"RESULT {tag} {action} port={port} ok={ok} elapsed={el:.0f}s")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
