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
# ★ DISCOVER 必须并入 MODAL_MARKERS（2026-10-07 r2 修复）：
#   它同样是带全屏 barrier 的模态，若只在 dismiss_blockers 里单独处理而**不**计入
#   「仍有模态」判据，则 `wait_settled` 的观测窗口漏看它 —— 弹窗在 12s 窗口之后才
#   渲染时，boot() 会误报「首页就绪=True」，随后 barrier 吃掉所有 tap（open_mine 连点
#   失败、b_first_sync 空等 1800s）。并入后：wait_settled 能捕获迟到的它并交
#   dismiss_blockers 按 discover 策略处理（skip→跳过 / download→下载）。
MODAL_MARKERS = BLOCKERS + OVERLAY + MERGE_BUTTONS + (DISCOVER,)


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


def wait_settled(port, seconds=12.0, discover="skip", merge="apply", poll=3.0):
    """冷启动后的「稳定观察期」：等启动同步检查的弹窗**迟到登场**。

    为什么需要：该检查要等云端探测完才渲染弹窗，而 dismiss_blockers 只依据
    **当前** dump 判定 —— 启动后头几秒「无模态 + 有『我的』」就已成立，于是
    误报「已就绪」，随后弹出的 modal barrier 会吃掉所有 tap。
    实测（20261007）：B 端 R1 首次同步因此空等到 harness 超时（12.9 分钟、
    RSS 548→604MB、除 [mem] 外零日志），而服务端 8 个账本 JSON 早已下完、
    始终没人点「下载」。

    返回 True = 观察期内（或清理后重新起算的观察期内）界面始终干净。
    """
    if seconds <= 0:
        return True
    t0 = time.time()
    while time.time() - t0 < seconds:
        time.sleep(poll)
        if any(m in uidrv.dump_xml(port) for m in MODAL_MARKERS):
            log("稳定观察期捕获迟到的启动弹窗，重新清理")
            if not dismiss_blockers(port, rounds=6, discover=discover, merge=merge):
                return False
            t0 = time.time()      # 清理后重新起算观察期
    return True


def boot(port, tag=None, discover="skip", merge="apply", cold=True, settle=12.0):
    """冷启动到首页。cold=True 先 force-stop，确保走完整的启动同步检查。

    settle: 判定就绪后**再观察**的秒数（默认 12s = 3 轮 poll，见 wait_settled）。
        传 0 关闭 —— 需要「启动后立刻取快照」的调用点可关掉，代价是可能漏掉
        迟到的启动弹窗。要跑「首次同步 / 引导下载」类路径时**不要**关。
    """
    if cold:
        uidrv.shell(port, f"am force-stop {PKG}")
        time.sleep(2)
    uidrv.launch(port)
    log(f"{port} 启动中 ...")
    ok = dismiss_blockers(port, discover=discover, merge=merge)
    if ok:
        ok = wait_settled(port, seconds=settle, discover=discover, merge=merge)
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
def _confirm_dialog(port, keys, timeout=60, rounds=3, next_timeout=8):
    """逐层点掉危险确认弹窗，返回**最后**点中的 key（一个都没点到则 None）。

    ★ 全量上传 / 全量下载是**两层**确认：第一层「覆盖上传」，第二层
      「再次确认：覆盖后云端原有数据无法恢复，确定要继续吗？」。
      只点一层会把流程卡死 —— 实测 20261007：`_converge.py` 用了单层版本，
      卡在第二层 130s，期间**一个字节都没发出去**（服务端零请求），
      而日志里已经打印过「确认弹窗点『确定』」，极易误判成上传慢。
      `round.py` 自带的 `confirm_loop` 是循环版本，故既有编排器未受影响；
      这里把能力补回公共封装，避免下一个调用者再踩。

    next_timeout: 第二层起的等待上限（短）—— 此时正常情况已无确认键。
    """
    clicked = []
    for _ in range(rounds):
        t0 = time.time()
        limit = timeout if not clicked else next_timeout
        hit = None
        while time.time() - t0 < limit:
            xml = uidrv.dump_xml(port)
            for k in keys:
                n = uidrv.find(xml, k)
                if n:
                    uidrv.tap(port, n["cx"], n["cy"])
                    log(f"确认弹窗点「{k}」(第 {len(clicked) + 1} 层)")
                    hit = k
                    break
            if hit:
                break
            time.sleep(3)
        if not hit:
            break
        clicked.append(hit)
        time.sleep(2)
    return clicked[-1] if clicked else None


def upload_full(port, tag, confirm_keys=("覆盖上传", "确定", "确认")):
    """同步页 → 全量上传 → **逐层**确认 → 等到完成。

    确认是两层（见 `_confirm_dialog`），`_confirm_dialog` 会循环点掉。
    """
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
    """同步页 → 全量下载 → **逐层**确认 → 等到完成（确认是两层，见 `_confirm_dialog`）。"""
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


# ---------------------------------------------------------------- 页面内滚动
def scroll_to_top(port, times=4):
    """把当前页面滚回顶部。

    同步页很长（上传/下载/自动同步/备份三件套/恢复/加密…），目标按钮常在屏外，
    直接 `find` 会一无所获；而 `input swipe` 从上往下滑 = 内容向下 = 视图回到顶部。
    """
    for _ in range(times):
        uidrv.shell(port, "input swipe 600 800 600 2200 250")
        time.sleep(0.8)


def tap_in_page(port, key, wait=3.0, max_scroll=4, bottom=2578):
    """在当前页找 key 并点击；找不到就向下滚一点再找。

    bottom：只点**可点且中心在屏幕内**的节点（dump 里会出现屏外 bounds，
    照它 tap 会点到状态栏/导航栏）。1200×2608 屏取 2578 留出导航条高度。
    """
    for i in range(max_scroll):
        xml = uidrv.dump_xml(port)
        n = uidrv.find(xml, key)
        if n and n["cy"] <= bottom:
            log(f"tap {key!r} @ {n['cx']},{n['cy']} (轮{i+1})")
            uidrv.tap(port, n["cx"], n["cy"])
            time.sleep(wait)
            return True
        uidrv.shell(port, "input swipe 600 1900 600 1100 250")
        time.sleep(1.0)
    log(f"[FAIL] 页内找不到可点的 {key!r}")
    return False


# ---------------------------------------------------------------- 备份 / 恢复
# 文案全部取自 lib/l10n/app_zh.arb（勿凭印象写匹配键）：
#   backupSuccessMessage  = 备份已上传：piggycount-bak/{fileName}
#   backupFailedXxxMessage= 备份失败，请检查网络后重试。 / 云端认证失败…
#   backupRunningStatus / backupPackingProgress = 正在创建备份… / 正在打包账本 x/y…
#   backupListEmptyMessage= 云端还没有备份。
#   restoreConfirm1Message= 将使用 {date} 的备份覆盖本地全部账本数据…
#   restoreResultMessage  = 恢复完成：成功 {n} 个，失败 {m} 个。
#   dangerConfirmCountdown= 确认（{seconds}秒）  ← 危险确认按钮**倒计时期间禁用**
BACKUP_UPLOADED = "备份已上传："
BACKUP_PREFIX = "piggycount-bak/"
BACKUP_FAILED = "备份失败"
BACKUP_RUNNING = ("正在创建备份", "正在打包账本")
BACKUP_LIST_EMPTY = "云端还没有备份"
RESTORE_CONFIRM1 = "将使用"          # restoreConfirm1Message 的稳定前缀
RESTORE_RESULT = "恢复完成："
RESTORE_RUNNING = ("正在从备份恢复", "正在恢复账本")
LAST_BACKUP = "最近备份："
LAST_BACKUP_NONE = "最近备份：尚无记录"
# 危险确认按钮的倒计时形态：确认（5秒）→ 归零后才变成可点的「确定」
COUNTDOWN_RE = re.compile(r"确认（\d+秒）")
# `[Backup] 备份完成: …` 的**两种形态**都要吃下：
#   旧（2026-10-07 之前的构建）：(跳过=0, 128KB)            ← 尾字段其实是附件原始字节和
#   新（P3 修复后）        ：(跳过=0, 附件总量=128KB, 整包=3.7MB)
# 只认新格式会让 harness 在未含修复的构建上静默失效，故尾两组设为可选。
# 真机样本（run_20261007_s3/*_fulltest.txt）：
#   [Backup] 备份完成: PiggyCount-2026-10-07.zip 账本=8 附件=7 (跳过=0, 128KB)
BACKUP_DONE_RE = re.compile(
    r"\[Backup\] 备份完成: (\S+) 账本=(\d+) 附件=(\d+) "
    r"\(跳过=(\d+),\s*(?:附件总量=)?([^,)]+?)(?:,\s*整包=([^)]+))?\)")
RESTORE_DONE_RE = re.compile(
    r"\[Backup\] 备份恢复完成: (\S+) 成功=(\d+) 失败=(\d+)")


def _descs(xml):
    """全部非空 content-desc（Flutter 文本落在这里，`text` 恒为空）。"""
    return [m for m in re.findall(r'content-desc="([^"]*)"', xml) if m]


def last_backup_caption(port):
    """读「最近备份：<日期> · <成功|失败>」/「最近备份：尚无记录」。

    ★ 只作**旁证与报告引用**，绝不能单独当完成判据 —— 见 backup_now 的说明。
    """
    for d in _descs(uidrv.dump_xml(port)):
        if d.startswith(LAST_BACKUP):
            return d
    return None


def parse_backup_done_line(text):
    """从日志文本里解析 `[Backup] 备份完成: …`（返回 None 表示没有）。

    兼容两种格式（见 BACKUP_DONE_RE）：旧构建没有「整包」字段时 `zipBytes=None`
    —— 此时**不能**拿附件字节和冒充整包体积（那正是 2026-10-07 报告 §6.1/§6.5
    记录的文案歧义：128KB 被读成整包，实际整包 3,891,707B）。
    """
    m = BACKUP_DONE_RE.search(text or "")
    if not m:
        return None
    tail, zip_bytes = m.group(5).strip(), m.group(6)
    return {"fileName": m.group(1), "ledgers": int(m.group(2)),
            "attachments": int(m.group(3)), "attachmentsSkipped": int(m.group(4)),
            "attachmentsBytes": None if zip_bytes else tail,
            "zipBytes": zip_bytes.strip() if zip_bytes else None,
            "raw": m.group(0)}


def _dismiss_plain_dialog(port, keys=("确定", "关闭", "完成"), wait=2.5):
    """点掉一个普通信息/结果弹窗（无倒计时）。"""
    xml = uidrv.dump_xml(port)
    for k in keys:
        n = uidrv.find(xml, k)
        if n and not COUNTDOWN_RE.search(n["desc"] + n["text"]):
            uidrv.tap(port, n["cx"], n["cy"])
            time.sleep(wait)
            return True
    return False


def backup_now(port, tag, probe=None, timeout=600, poll=5.0):
    """同步页 →「立即备份」→ 判定完成。返回证据字典（失败返回 None）。

    ★ 旧判据是**假阳性**，别再抄：`"最近备份" in xml and "尚无记录" not in xml`
      只反映「**当天**有没有过备份」，与本次操作无关 —— 同日补跑、甚至上一阶段
      （S3 段）留下的记录都会让它恒真，于是**备份尚未落盘就报成功**。
      2026-10-07 实测踩中，报告 §6.4 留档。

    现在的判据 = **本次操作自己的产物**，三层互相独立：
      ① 结果弹窗「备份已上传：piggycount-bak/<fileName>」（backupSuccessMessage）。
         进入前先清掉可能残留的结果弹窗，保证它只可能来自本次操作。
      ② logcat 的 `[Backup] 备份完成: <file> 账本=N 附件=N (跳过=N, 附件总量=X, 整包=Y)`。
         结构化交叉校验：账本数应等于本地账本数、整包体积应 > 0。
         开跑前 `logcat -c`，所以这行也必然来自本次。
      ③ 可选 probe(fileName)：服务端落盘核验。WebDAV 本地测试服务可直接查
         `scripts/webdav_test/data/piggycount/piggycount-bak/`；S3 侧暂无列举工具，
         传 None 表示**未做服务端独立核验**（如实记进 evidence，别当已验）。
    """
    # 清残留结果弹窗
    for _ in range(3):
        xml = uidrv.dump_xml(port)
        if BACKUP_UPLOADED not in xml and BACKUP_FAILED not in xml:
            break
        if not _dismiss_plain_dialog(port):
            break

    before = last_backup_caption(port)         # 旁证：仅用于报告
    uidrv.shell(port, "logcat -c")
    if not tap_in_page(port, "立即备份", wait=4.0):
        return None

    uidrv.dump_xml(port, f"{tag}_{port}_backupnow_tapped")
    t0 = time.time()
    ev = {"fileName": None, "dialogSeen": False, "failed": False,
          "log": None, "probe": None, "captionBefore": before,
          "captionAfter": None, "seconds": None}
    while time.time() - t0 < timeout:
        xml = uidrv.dump_xml(port)
        if BACKUP_UPLOADED in xml:
            for d in _descs(xml):
                if d.startswith(BACKUP_UPLOADED):
                    ev["fileName"] = d.split(BACKUP_PREFIX, 1)[-1].strip()
                    break
            ev["dialogSeen"] = True
        if BACKUP_FAILED in xml:
            ev["failed"] = True
        raw = logcat(port, fresh=False)
        ev["log"] = parse_backup_done_line(raw) or ev["log"]
        if ev["dialogSeen"] or ev["failed"]:
            break
        if not any(k in xml for k in BACKUP_RUNNING) and ev["log"]:
            break                              # 弹窗已收起但日志已到
        time.sleep(poll)

    ev["seconds"] = round(time.time() - t0, 1)
    uidrv.dump_xml(port, f"{tag}_{port}_backupnow_done")
    with open(os.path.join(RW, f"{tag}_{port}_logcat.txt"), "w",
              encoding="utf-8", errors="replace", newline="") as f:
        f.write(logcat(port, fresh=False))
    # 弹窗收起后才读得到刷新后的「最近备份」卡片
    _dismiss_plain_dialog(port)
    ev["captionAfter"] = last_backup_caption(port)
    if probe and ev["fileName"]:
        try:
            ev["probe"] = bool(probe(ev["fileName"]))
        except Exception as e:                 # noqa: BLE001 —— 探测失败不掩盖主判据
            ev["probe"] = f"probe_error: {e}"

    ok = (ev["dialogSeen"] and not ev["failed"] and ev["log"] is not None)
    log(f"立即备份 完成={ok} 文件={ev['fileName']} 日志={ev['log']} "
        f"服务端核验={ev['probe']} ({ev['seconds']}s)")
    return ev if ok else None


def read_prefs(port, name):
    """读设备端 FlutterSharedPreferences.xml 并解析成 {key: value}（只读）。

    结构性证据（不受 UI 文案/前序用例污染），定时备份开关一类断言优先用它。
    本函数**只读**；本模块的约定仍是「绝不改写 shared_prefs / secure storage」。
    """
    raw = uidrv.adb(port, "exec-out", "run-as", PKG, "cat",
                    f"/data/data/{PKG}/shared_prefs/FlutterSharedPreferences.xml")
    with open(os.path.join(RW, name + ".xml"), "w", encoding="utf-8",
              errors="replace", newline="") as f:
        f.write(raw)
    out = {}
    for m in re.finditer(
            r'<(\w+) name="([^"]*)"(?: value="([^"]*)")?\s*(?:/>|>(.*?)</\1>)', raw):
        typ, k, v, inner = m.groups()
        out[k] = v if v is not None else (inner or "")
    return out


def set_backup_auto(port, tag, on=True):
    """同步页 →「定时备份」开关 + 读 prefs 校验（结构性证据，非 UI 文本）。

    返回 {enabled, time, requested}（缺失的键为 None）。
    """
    scroll_to_top(port)
    tap_in_page(port, "定时备份", wait=3.5)
    uidrv.dump_xml(port, f"{tag}_{port}_backupauto")
    prefs = read_prefs(port, f"{tag}_{port}_prefs")
    return {"enabled": prefs.get("flutter.backup_auto_enabled"),
            "time": prefs.get("flutter.backup_time"),
            "requested": on}


def confirm_danger_dialogs(port, rounds=2, timeout=90, wait=3.0):
    """点掉危险确认弹窗（**逐关等倒计时归零**）。返回实际点掉的关数。

    弹窗按钮在倒计时期间是 `确认（N秒）` 且 **disabled**（`_DangerConfirmDialog`），
    直接点「确定」会误伤或干脆点不到 —— 必须等它变成真正的 okLabel 再点。
    （早期 harness 用 `"（" not in desc` 这个 hack 判断，现按文案正规化。）
    """
    done = 0
    t0 = time.time()
    while done < rounds and time.time() - t0 < timeout:
        xml = uidrv.dump_xml(port)
        if not COUNTDOWN_RE.search(xml):
            n = uidrv.find(xml, "确定") or uidrv.find(xml, "确认")
            if n:
                uidrv.tap(port, n["cx"], n["cy"])
                done += 1
                log(f"危险确认第 {done} 关已点")
                time.sleep(wait)
                continue
        if done == 0 and RESTORE_CONFIRM1 not in xml:
            break                              # 压根没进确认流程
        time.sleep(2)
    return done


def restore_from_backup(port, tag, pick=None, timeout=900, poll=8.0):
    """同步页 →「从备份恢复」→ 选备份 → 两关危险确认 → 判定完成。

    判据是**本次操作的直接产物**：结果弹窗
    `恢复完成：成功 {success} 个，失败 {failed} 个。`（restoreResultMessage），
    解析出 success/failed 并**要求 failed == 0**。
    （旧 harness 用「`恢复中` 不在界面上」当完成判据 —— 和 §6.4 同类缺陷：
    一个「某文案不存在」的判据在流程没真正开始时也成立。）

    pick: 选哪条备份。None = 列表里第一条含「PiggyCount」的可点项；
          传 str 则按子串匹配（如 '2026-10-07'）。
    """
    scroll_to_top(port)
    if not tap_in_page(port, "从备份恢复", wait=4.0):
        return None
    xml = uidrv.dump_xml(port, f"{tag}_{port}_restore_sheet")
    if BACKUP_LIST_EMPTY in xml:
        log("[FAIL] 云端还没有备份，无法恢复")
        return None

    key = pick or "PiggyCount"
    cands = [n for n in uidrv.nodes(xml)
             if n["clickable"] and (key in n["desc"] or key in n["text"])]
    if not cands:
        log(f"[FAIL] 备份列表里找不到 {key!r}")
        return None
    uidrv.tap(port, cands[0]["cx"], cands[0]["cy"])
    log(f"选择备份 {cands[0]['desc'][:80]!r}")
    time.sleep(4)
    uidrv.dump_xml(port, f"{tag}_{port}_restore_pick")

    # 危险确认是两关，各带 5s 倒计时（见 confirm_danger_dialogs）
    uidrv.shell(port, "logcat -c")
    rounds = confirm_danger_dialogs(port, rounds=2)
    uidrv.dump_xml(port, f"{tag}_{port}_restore_confirm")

    t0 = time.time()
    ev = {"success": None, "failed": None, "seconds": None, "rounds": rounds,
          "raw": None}
    while time.time() - t0 < timeout:
        xml = uidrv.dump_xml(port)
        if RESTORE_RESULT in xml:
            for d in _descs(xml):
                m = re.search(r"成功\s*(\d+)\s*个，失败\s*(\d+)\s*个", d)
                if m:
                    ev["success"], ev["failed"] = int(m.group(1)), int(m.group(2))
                    break
        m = RESTORE_DONE_RE.search(logcat(port, fresh=False))
        if m:
            # 日志里的结构化行（[Backup] 备份恢复完成: <file> 成功=N 失败=M …）
            # 与结果弹窗互为印证；弹窗被漏采（转场太快）时仍能判定。
            ev["success"], ev["failed"] = int(m.group(2)), int(m.group(3))
            ev["raw"] = m.group(0)
        if ev["success"] is not None:
            break                              # 弹窗或日志任一给出结论即收工
        if rounds == 0 and not any(k in xml for k in RESTORE_RUNNING):
            break                              # 确认没点成，别空等到超时
        time.sleep(poll)

    ev["seconds"] = round(time.time() - t0, 1)
    uidrv.dump_xml(port, f"{tag}_{port}_restore_done")
    _dismiss_plain_dialog(port)
    ok = ev["success"] is not None and (ev["failed"] or 0) == 0
    log(f"从备份恢复 完成={ok} 成功={ev['success']} 失败={ev['failed']} "
        f"确认关数={rounds} ({ev['seconds']}s)")
    return ev if ok else None
