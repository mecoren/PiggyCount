# -*- coding: utf-8 -*-
"""PiggyCount 双端 UI 驱动（uiautomator dump + input tap 的鲁棒封装）。

用法:
  python uidrv.py <port> dump  <name>             # dump 并保存 <name>.xml / <name>.png
  python uidrv.py <port> texts                    # 打印所有 text/desc 节点（含 bounds）
  python uidrv.py <port> wait  <key> [timeout]    # 轮询直到 key 出现，返回 0/1
  python uidrv.py <port> tapkey <key> [postwait]  # 找到 key 并点击
  python uidrv.py <port> tap   <x> <y>
  python uidrv.py <port> launch|stop|back|home

匹配优先级（避免把点击落到"正文里含该词"的节点）：
  1) 精确匹配 + clickable  2) 精确匹配  3) 包含 + clickable  4) 包含
匹配范围同时覆盖 text 与 content-desc；包含匹配时优先选择**最短文本**的节点
（避免 'S3' 命中 '投资理财账本·…·S3REG3·…' 这类长串）。
"""
import os
import re
import subprocess
import sys
import time

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

PKG = "com.wait.piggycount.dev.debug"
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rundir  # noqa: E402  —— 产物目录统一解析（见 rundir.py）
RW = rundir.run_dir()
ADB = os.environ.get("ADB", "adb")


def adb(port, *args, timeout=180):
    cmd = [ADB, "-s", f"127.0.0.1:{port}"] + list(args)
    r = subprocess.run(cmd, capture_output=True, timeout=timeout)
    return r.stdout.decode("utf-8", "replace")


def shell(port, cmd, timeout=180):
    return adb(port, "shell", cmd, timeout=timeout)


def dump_xml(port, name=None, shot=True):
    """dump 当前界面 XML（带**自愈重试**）。

    ★ 2026-10-10 踩坑：设备侧的 uiautomator 进程会**偶发卡死** —— 表现为
      `uiautomator dump` 既不输出也不写文件（`cat /sdcard/d.xml` 得到
      "No such file or directory"），随后每一次 dump 都失败。旧实现只重试一次
      同样的命令，于是「重试」同样失败，调用方（如 wait_upload_done 的轮询）
      会一直空转：本轮实测编排在「上传已完成」的状态下空转 5 分钟以上，
      现场只看到「什么都没发生」。
      自愈做法：失败后 `pkill -f uiautomator` 杀掉卡死实例（uiautomator 由
      `uiautomator dump` 命令自身拉起，杀掉后下一次调用会重新起一个干净的），
      再重试。实测一次 pkill 即恢复。
    """
    last = ""
    for attempt in range(3):
        shell(port, "rm -f /sdcard/d.xml")
        shell(port, "uiautomator dump /sdcard/d.xml")
        xml = adb(port, "exec-out", "cat", "/sdcard/d.xml", timeout=180)
        if "<hierarchy" in xml:
            break
        last = xml
        if attempt < 2:
            shell(port, "pkill -f uiautomator")
            time.sleep(3)
    if name:
        # newline="" —— 禁止 Windows 文本模式把 \n 翻成 \r\n（否则 sha256 比对会假性 DIFF）
        with open(os.path.join(RW, name + ".xml"), "w", encoding="utf-8",
                  errors="replace", newline="") as f:
            f.write(xml)
        if shot:
            adb(port, "shell", "screencap", "-p", "/sdcard/s.png")
            png = subprocess.run([ADB, "-s", f"127.0.0.1:{port}", "exec-out",
                                  "cat", "/sdcard/s.png"], capture_output=True).stdout
            with open(os.path.join(RW, name + ".png"), "wb") as f:
                f.write(png)
    return xml


def nodes(xml):
    out = []
    for tag in re.findall(r"<node[^>]*>", xml):
        dm = re.search(r'content-desc="([^"]*)"', tag)
        tm = re.search(r'text="([^"]*)"', tag)
        bm = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
        if not bm:
            continue
        x1, y1, x2, y2 = (int(v) for v in bm.groups())
        if x2 <= x1 or y2 <= y1:
            continue
        desc = dm.group(1) if dm else ""
        text = tm.group(1) if tm else ""
        if not desc and not text:
            continue
        out.append({
            "desc": desc, "text": text,
            "clickable": 'clickable="true"' in tag,
            "cx": (x1 + x2) // 2, "cy": (y1 + y2) // 2,
            "bounds": f"[{x1},{y1}][{x2},{y2}]",
            "len": len(desc) + len(text),
        })
    return out


def find(xml, key):
    ns = nodes(xml)
    for exact, clickable in ((True, True), (True, False), (False, True), (False, False)):
        cands = []
        for n in ns:
            hit = None
            for v in (n["desc"], n["text"]):
                if not v:
                    continue
                if (v == key) if exact else (key in v):
                    hit = v
                    break
            if hit is None:
                continue
            if clickable and not n["clickable"]:
                continue
            cands.append((len(hit), n))
        if cands:
            cands.sort(key=lambda t: t[0])
            return cands[0][1]
    return None


def has_key(xml, key):
    return find(xml, key) is not None


def tap(port, x, y):
    shell(port, f"input tap {x} {y}")


def click_until(port, key, verify, tries=6, wait=3.0, verbose=True):
    """反复「dump → 找 key → 点击 → 校验 verify」，直到 verify 出现在界面里。

    启动/页面切换期间首次 tap 常被吞（Flutter 首帧未就绪），故必须带校验重试。
    """
    for i in range(tries):
        xml = dump_xml(port)
        if verify and verify in xml:
            return True
        n = find(xml, key)
        if n is None:
            if verbose:
                print(f"    [click_until] 轮{i+1} 未找到 {key!r}")
            time.sleep(wait)
            continue
        if verbose:
            print(f"    [click_until] 轮{i+1} tap {key!r} @ {n['cx']} {n['cy']}")
        tap(port, n["cx"], n["cy"])
        time.sleep(wait)
    return bool(verify and verify in dump_xml(port))


def launch(port):
    shell(port, f"monkey -p {PKG} -c android.intent.category.LAUNCHER 1")


def main():
    port = sys.argv[1]
    op = sys.argv[2] if len(sys.argv) > 2 else "texts"
    if op == "dump":
        xml = dump_xml(port, sys.argv[3] if len(sys.argv) > 3 else None)
        print("dump bytes:", len(xml))
    elif op == "texts":
        if len(sys.argv) > 3 and os.path.exists(sys.argv[3]):
            with open(sys.argv[3], encoding="utf-8", errors="replace") as f:
                xml = f.read()
        else:
            xml = dump_xml(port)
        for n in nodes(xml):
            print(f"{n['bounds']} click={n['clickable']} desc={n['desc']!r} text={n['text']!r}")
    elif op == "wait":
        key = sys.argv[3]
        timeout = int(sys.argv[4]) if len(sys.argv) > 4 else 90
        t0 = time.time()
        while time.time() - t0 < timeout:
            xml = dump_xml(port)
            if has_key(xml, key):
                print("FOUND", key)
                sys.exit(0)
            time.sleep(3)
        print("TIMEOUT", key)
        sys.exit(1)
    elif op == "tapkey":
        key = sys.argv[3]
        post = float(sys.argv[4]) if len(sys.argv) > 4 else 3.0
        xml = dump_xml(port)
        n = find(xml, key)
        if n is None:
            print("NOT_FOUND", key)
            sys.exit(1)
        print(f"tap {key!r} @ {n['cx']} {n['cy']} ({n['bounds']})")
        tap(port, n["cx"], n["cy"])
        time.sleep(post)
    elif op == "tap":
        tap(port, int(sys.argv[3]), int(sys.argv[4]))
    elif op == "launch":
        launch(port)
    elif op == "stop":
        shell(port, f"am force-stop {PKG}")
    elif op == "back":
        shell(port, "input keyevent 4")
    elif op == "home":
        shell(port, "input keyevent 3")
    else:
        print("unknown op", op)
        sys.exit(2)


if __name__ == "__main__":
    main()
