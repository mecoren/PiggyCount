# -*- coding: utf-8 -*-
"""双端同步回归的公共流程封装（基于 uidrv 的 uiautomator 驱动）。

只做「通过 App UI 操作系统」的事：冷启动、关弹窗、进同步页、上传、下载、读日志。
绝不直接改写 shared_prefs / secure storage —— 云配置与加密密钥由 App 自己维护。
"""
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import uidrv  # noqa: E402

RW = uidrv.RW
PKG = uidrv.PKG
ADB = uidrv.ADB

# 文案匹配属性说明（排查坑，20261004 踩过）：
#   Flutter 的文本落在 uiautomator dump 的 **content-desc** 上，`text` 恒为空。
#   所以 `grep 'text="…"'` 永远一无所获，必须 grep `content-desc="…"`。
#   uidrv.nodes/find 同时覆盖 desc 与 text，下面对 flows 只需写可见文案即可。
#   当年就是 grep 错属性 → 误判成「uiautomator 漏采 Flutter 遮罩」，
#   实际上遮罩（标题/正文/三个按钮）**全部**都在 dump 里。

# 启动期可能出现的阻塞弹窗（同步状态检查失败 / 云端更新检查失败）
BLOCKERS = ("同步状态检查失败", "检查网络后重试", "云端更新检查失败")
# 启动同步检查的**结果遮罩**（startup_sync_overlay.dart）：发现差异后强制阻断
# 底层交互（AbsorbPointer + barrierDismissible:false），必须点「确定」才收起来，
# 否则后续所有 input tap 都被背景层吃掉，表现为「点了没反应」。
OVERLAY = ("云端账本信息与本地不同", "启动检查不会自动合并")
# 冷启动时云端留有旧数据 → 「发现云端账本」；切换后端场景要点「跳过」避免引入云端数据
DISCOVER = "发现云端账本"
# 「云端有更新」合并确认弹窗（**三按钮语义不同**，选哪个直接决定测试口径，
# 因此必须由调用方显式指定策略，绝不能笼统「点确定」）：
#   一键应用全部 → 云端全部合并到本地（默认）
#   逐个确认     → 逐条确认（自动化里一般不用）
#   暂不合并     → 放弃本次合并、仅关闭弹窗
#
# ★ 标记必须用**这三个按钮文案**，不能用「云端有更新」当匹配键：
#   实测「我的」页与「云同步页」的列表项副标题就是 `同步\n云端有更新`
#   （状态展示），裸子串匹配会把**正常页面**误判成弹窗、于是永远到不了首页。
#   全量 dump 统计：「云端有更新」命中 17 份，三个按钮命中 12 份 ——
#   多出来的 5 份（S3R4_*_syncpage / *_mine / *_download_pre）全是误报源。
#   `MERGE_DIALOG_NAME` 只用于日志可读性，**禁止**拿它做 in/has_key 匹配。
MERGE_BUTTONS = ("一键应用全部", "逐个确认", "暂不合并")
MERGE_POLICY = {"apply": MERGE_BUTTONS[0],   # 一键应用全部
                "each": MERGE_BUTTONS[1],    # 逐个确认
                "skip": MERGE_BUTTONS[2]}    # 暂不合并
MERGE_DIALOG_NAME = "云端有更新"             # 仅供日志显示
APPLY_ALL = MERGE_POLICY["apply"]            # 兼容旧调用点

# 出现任一即说明「屏幕上仍有会拦截点击的模态」。此时**绝不能**因为底层页面元素
# （如「我的」）已经出现在语义树里就判定「到达首页」：模态的 barrier 会吃掉后续
# tap，表现为随后的 open_mine 连点 6 轮失败。20261004 switch_backend.py 实测：
# boot 返回 True、但「我的」怎么点都进不去 —— 只因语义树里「我的」是可见的。
MODAL_MARKERS = BLOCKERS + OVERLAY + MERGE_BUTTONS


def log(msg):
    print(f"  [{time.strftime('%H:%M:%S')}] {msg}", flush=True)


# ---------------------------------------------------------------- 日志
def logcat(port, fresh=True):
    """取 flutter tag 的 logcat（App 自有 logger 同时也写这里，实时可读）。

    ★ 坑（20261004 本轮实测更正）：**不要**写成
    `logcat -d flutter:V flutter:I flutter:W flutter:E *:S` ——
    同一 tag 给多个 filter spec 时**后者覆盖前者**，等价于 `flutter:E *:S`，
    于是 INFO 级日志被全部过滤掉，抓回来恒为 **0 行**。
    （旧实现就是这么写的，所以 run_20261004/run_20260916 里的 `*_logcat.txt`
    大多是 0 字节，当时只能退回复用 shared_prefs 里的 app_logs。）
    正确写法：`-s flutter:V`（`-s` 已把默认级别设为 silent）。
    """
    if fresh:
        uidrv.shell(port, "logcat -c")
    return uidrv.adb(port, "logcat", "-d", "-s", "flutter:V")


def app_logs(port, tag):
    """从 shared_prefs 的 flutter.app_logs 里取 App 内部结构化日志（补充来源）。"""
    path = os.path.join(RW, f"{tag}_{port}_prefs.xml")
    raw = uidrv.adb(port, "exec-out", "run-as", PKG, "cat",
                    f"/data/data/{PKG}/shared_prefs/FlutterSharedPreferences.xml")
    with open(path, "wb") as f:
        f.write(raw.encode("utf-8", "replace"))
    s = raw
    m = re.search(r'<string name="flutter\.app_logs">(.*?)</string>', s, re.S)
    if not m:
        return ""
    txt = (m.group(1).replace("&quot;", '"').replace("&amp;", "&")
           .replace("&lt;", "<").replace("&gt;", ">").replace("&#39;", "'"))
    try:
        arr = json.loads(txt)
    except Exception:
        return txt
    return "\n".join(
        f"{a.get('timestamp')} [{a.get('tag')}] {a.get('message')}"
        + (f" ERR={a.get('error')}" if a.get("error") else "")
        for a in arr)


# ---------------------------------------------------------------- 启动 / 弹窗
def dismiss_blockers(port, rounds=6, discover="skip", merge="apply", verbose=True):
    """关闭启动阻塞弹窗 / 合并确认弹窗。返回是否**真的**到达首页。

    返回 True 的充要条件：界面含「我的」**且**无任何 MODAL_MARKERS 残留。
    只看「我的」在不在语义树里是不够的 —— 模态打开时底层元素照样可见
    （见 MODAL_MARKERS 注释）。

    discover: 'skip' 点「跳过」(不拉云端数据) | 'download' 点「下载」 | None 不处理
    merge:    'apply' 一键应用全部 | 'each' 逐个确认 | 'skip' 暂不合并 | None 不处理
    """
    for i in range(rounds):
        xml = uidrv.dump_xml(port)
        if any(b in xml for b in BLOCKERS):
            n = uidrv.find(xml, "确定") or uidrv.find(xml, "关闭")
            if n:
                log(f"关闭阻塞弹窗(轮{i+1})")
                uidrv.tap(port, n["cx"], n["cy"])
                time.sleep(3)
                continue
        # 合并确认弹窗**必须排在 OVERLAY 之前**：它内部同时也含「云端账本信息与
        # 本地不同」，但其按钮叫「一键应用全部 / 逐个确认 / 暂不合并」而非「确定」，
        # 走 OVERLAY 分支会 find 不到「确定」而空转到轮次耗尽。
        if merge and any(b in xml for b in MERGE_BUTTONS):
            key = MERGE_POLICY[merge]
            n = uidrv.find(xml, key)
            if n:
                log(f"处理「{MERGE_DIALOG_NAME}」→ {key}(轮{i+1})")
                uidrv.tap(port, n["cx"], n["cy"])
                time.sleep(6)
                continue
        if any(o in xml for o in OVERLAY):
            n = uidrv.find(xml, "确定")
            if n:
                log(f"关闭启动同步检查结果遮罩(轮{i+1})")
                uidrv.tap(port, n["cx"], n["cy"])
                time.sleep(4)
                continue
        if discover and DISCOVER in xml:
            key = "跳过" if discover == "skip" else "下载"
            n = uidrv.find(xml, key) or uidrv.find(xml, "关闭")
            if n:
                log(f"处理「{DISCOVER}」→ {key}(轮{i+1})")
                uidrv.tap(port, n["cx"], n["cy"])
                time.sleep(6)
                continue
        if not any(m in xml for m in MODAL_MARKERS) and uidrv.has_key(xml, "我的"):
            return True
        time.sleep(4)
    # 轮次耗尽仍未就绪：**留证据**（xml + png），并把残留的模态文案打出来，
    # 免得下游只看到一句「未进入我的」而不知道卡在哪个弹窗上。
    xml = uidrv.dump_xml(port, "boot_fail")
    left = [m for m in MODAL_MARKERS if m in xml]
    if left:
        log(f"启动后仍有模态未处理: {left}（证据 boot_fail.xml/.png）")
    return uidrv.has_key(xml, "我的") and not left


def boot(port, tag=None, discover="skip", merge="apply", cold=True):
    """冷启动到首页。cold=True 先 force-stop，确保走完整的启动同步检查。"""
    if cold:
        uidrv.shell(port, f"am force-stop {PKG}")
        time.sleep(2)
    uidrv.launch(port)
    log(f"{port} 启动中 ...")
    ok = dismiss_blockers(port, discover=discover, merge=merge)
    if tag:
        uidrv.dump_xml(port, f"{tag}_{port}_home")
    log(f"{port} 首页就绪={ok}")
    return ok


# ---------------------------------------------------------------- 导航
def open_mine(port):
    if uidrv.click_until(port, "我的", "云同步与备份", tries=6, wait=4.0):
        return True
    # 失败兜底：绝大多数情况是启动模态的 barrier 还在吃 tap（见 MODAL_MARKERS 注释）。
    # 先清一遍模态、留证据，再重试一次 —— 免得调用方只看到一句「未进入我的」，
    # 误以为是导航文案变了。20261004 switch_backend 就是卡在这里。
    log("进入「我的」失败，疑似残留模态拦截点击，清理后重试")
    ok = dismiss_blockers(port, rounds=3, discover=None, merge="apply")
    log(f"模态清理后首页就绪={ok}")
    return uidrv.click_until(port, "我的", "云同步与备份", tries=4, wait=4.0)


def open_sync_page(port, tag=None):
    """我的 → 同步（云同步页）。"""
    if not open_mine(port):
        return False
    if not uidrv.click_until(port, "同步", "全量上传", tries=6, wait=4.0):
        log("进入同步页失败")
        return False
    if tag:
        uidrv.dump_xml(port, f"{tag}_{port}_syncpage")
    return True


# ---------------------------------------------------------------- 上传 / 下载
def _confirm_dialog(port, keys, timeout=60):
    """等待确认弹窗并点其中一个 key。返回点中的 key 或 None。"""
    t0 = time.time()
    while time.time() - t0 < timeout:
        xml = uidrv.dump_xml(port)
        for k in keys:
            n = uidrv.find(xml, k)
            if n:
                uidrv.tap(port, n["cx"], n["cy"])
                log(f"确认弹窗点「{k}」")
                return k
        time.sleep(3)
    return None


def upload_full(port, tag, confirm_keys=("覆盖上传", "确定", "确认")):
    """同步页 → 全量上传 → 确认 → 等到完成。"""
    uidrv.dump_xml(port, f"{tag}_{port}_before_upload")
    n = uidrv.find(uidrv.dump_xml(port), "全量上传")
    if not n:
        log("未找到「全量上传」")
        return False
    uidrv.tap(port, n["cx"], n["cy"])
    time.sleep(3)
    k = _confirm_dialog(port, confirm_keys)
    if not k:
        log("未出现上传确认弹窗")
        return False
    return wait_upload_done(port, tag)


def wait_upload_done(port, tag, timeout=2400):
    """等上传完成的遮罩消失（'正在全量上传所有本地账本…' 消失或出现完成文案）。"""
    t0 = time.time()
    seen_busy = False
    while time.time() - t0 < timeout:
        xml = uidrv.dump_xml(port)
        if "正在全量上传" in xml or "正在上传账本" in xml:
            seen_busy = True
        elif seen_busy or "全量上传完成" in xml or "已上传" in xml:
            if "正在全量上传" not in xml and "正在上传账本" not in xml:
                uidrv.dump_xml(port, f"{tag}_{port}_upload_done")
                log(f"上传完成 ({time.time()-t0:.0f}s)")
                return True
        time.sleep(10)
    uidrv.dump_xml(port, f"{tag}_{port}_upload_timeout")
    log(f"上传等待超时 ({time.time()-t0:.0f}s)")
    return False


def download_full(port, tag, confirm_keys=("覆盖下载", "确定", "确认")):
    """同步页 → 全量下载 → 确认 → 等到完成。"""
    n = uidrv.find(uidrv.dump_xml(port), "全量下载")
    if not n:
        log("未找到「全量下载」")
        return False
    uidrv.tap(port, n["cx"], n["cy"])
    time.sleep(3)
    k = _confirm_dialog(port, confirm_keys)
    if not k:
        log("未出现下载确认弹窗")
        return False
    return wait_download_done(port, tag)


def wait_download_done(port, tag, timeout=2400):
    t0 = time.time()
    seen_busy = False
    while time.time() - t0 < timeout:
        xml = uidrv.dump_xml(port)
        if "正在从云端恢复" in xml or "正在下载" in xml or "正在全量下载" in xml:
            seen_busy = True
        elif seen_busy:
            if not any(k in xml for k in ("正在从云端恢复", "正在下载", "正在全量下载")):
                uidrv.dump_xml(port, f"{tag}_{port}_download_done")
                log(f"下载完成 ({time.time()-t0:.0f}s)")
                return True
        time.sleep(10)
    uidrv.dump_xml(port, f"{tag}_{port}_download_timeout")
    log(f"下载等待超时 ({time.time()-t0:.0f}s)")
    return False


def consume_startup_dialog(port, tag, timeout=180, merge="apply"):
    """冷启动后消费云端更新弹窗：发现云端账本→下载 / 云端有更新→按策略合并。

    返回 'merge' | 'download' | None（没有弹窗，已直接落在首页）。
    就绪判定同样要求**无模态残留** —— 模态开着时「我的」照样在语义树里，
    只看它会立刻 return None 而把弹窗留在屏幕上（旧实现的坑）。
    """
    t0 = time.time()
    xml = uidrv.dump_xml(port, f"{tag}_{port}_discover")
    while time.time() - t0 < timeout:
        if merge and any(b in xml for b in MERGE_BUTTONS):
            key = MERGE_POLICY[merge]
            n = uidrv.find(xml, key)
            if n:
                uidrv.tap(port, n["cx"], n["cy"])
                log(f"处理「{MERGE_DIALOG_NAME}」→ {key}")
                return "merge"
        if DISCOVER in xml:
            n = uidrv.find(xml, "下载")
            if n:
                uidrv.tap(port, n["cx"], n["cy"])
                log("点「下载」")
                return "download"
        if not any(m in xml for m in MODAL_MARKERS) and uidrv.has_key(xml, "我的"):
            return None
        time.sleep(8)
        xml = uidrv.dump_xml(port, f"{tag}_{port}_discover")
    return None


def wait_import_done(port, tag, timeout=1800):
    """等 B 端导入/合并落库结束（靠 logcat 里的完成标记）。"""
    t0 = time.time()
    marks = ("云端新账本导入完成", "云端账本导入完成", "合并后回传完成",
             "无候选账本，全部都是最新", "变更已应用", "完整性终审")
    while time.time() - t0 < timeout:
        raw = logcat(port, fresh=False)
        with open(os.path.join(RW, f"{tag}_{port}_logcat.txt"), "w",
                  encoding="utf-8", errors="replace", newline="") as f:
            f.write(raw)
        if "导入失败" in raw or "解密失败" in raw or "密码错误" in raw:
            log("导入/解密出现失败标记")
            uidrv.dump_xml(port, f"{tag}_{port}_fail")
            return False
        if raw.count("合并后回传完成") >= 8 or "无候选账本，全部都是最新" in raw:
            log(f"合并落库完成 ({time.time()-t0:.0f}s)")
            return True
        if ("云端新账本导入完成" in raw or "云端账本导入完成" in raw) and \
                "正在导入" not in raw:
            log(f"导入完成 ({time.time()-t0:.0f}s)")
            return True
        time.sleep(15)
    log(f"导入等待超时 ({time.time()-t0:.0f}s)")
    uidrv.dump_xml(port, f"{tag}_{port}_import_timeout")
    return False


# ---------------------------------------------------------------- 文本输入
def tap_and_type(port, key, text, preclear=True):
    """找到字段（按 key 定位）→ 点击 → 全选清空 → 输入。"""
    xml = uidrv.dump_xml(port)
    n = uidrv.find(xml, key)
    if not n:
        return False
    uidrv.tap(port, n["cx"], n["cy"])
    time.sleep(1.5)
    if preclear:
        # Ctrl+A 后退格（adb shell input keyevent KEYCODE_MOVE_END + 大量 DEL）
        uidrv.shell(port, "input keyevent KEYCODE_MOVE_END")
        for _ in range(60):
            uidrv.shell(port, "input keyevent 67")
    uidrv.shell(port, f"input text '{text}'")
    time.sleep(1)
    return True
