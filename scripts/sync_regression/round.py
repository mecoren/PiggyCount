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


def tap_fullsync(port, action):
    """点「全量上传 / 全量下载」，返回命中节点（None = 没找到 / 不可点）。

    ★ 不可点即「后端未连上」的快失败判据（2026-10-10 WebDAV 轮实测）：
      当云服务配置不可用（例：WebDAV URL 填成垃圾值 `1` → provider 初始化失败）时，
      同步页会把这两个按钮渲染成**禁用态**，uiautomator 里表现为**一个不可点的合并卡片
      节点**：desc 同时含两个按钮文案（`全量上传&#10;以本地全部账本覆盖云端&#10;
      全量下载&#10;以云端全部账本覆盖本地`）、bounds 覆盖两块（实测 `[43,1086][1157,1449]`）。
      此时 `uidrv.find` 会命中该卡片并把 tap 落在两按钮之间的空隙上 —— 上传/下载**静默
      不发起**，而 `confirm_loop` 会一直等确认弹窗直到 3000s 超时，现场看不出原因。
      故这里**不再盲点**：节点不可点就直接判失败并打印诊断，让编排立刻停下。
      正常态下两个按钮是各自可点的节点（实测 `[79,1154][1121,1282]`），走原路径。
    """
    key = "全量上传" if action == "upload" else "全量下载"
    xml = uidrv.dump_xml(port)
    n = uidrv.find(xml, key)
    if not n:
        return None
    if not n["clickable"]:
        flows.log(f"[FAIL] 命中的「{key}」节点不可点（bounds={n['bounds']}，"
                  f"desc={n['desc'][:60]!r}）—— 通常是云服务配置不可用导致按钮禁用；"
                  f"请先到「我的 → 云服务」确认后端连接正常")
        return None
    flows.log(f"点「{key}」@{n['cx']},{n['cy']} ({n['bounds']})")
    uidrv.tap(port, n["cx"], n["cy"])
    return n


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
    if tap_fullsync(port, action) is None:
        flows.log(f"[FAIL] 未找到「全量上传/全量下载」，请确认已停在同步页")
        return 2
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
