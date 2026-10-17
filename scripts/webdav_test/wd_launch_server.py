# -*- coding: utf-8 -*-
"""启动 WebDAV 测试服务器，并把 stdout/stderr 落到审计文件。

为什么需要这个启动器：在本项目的执行环境里，用 PowerShell 的文件重定向
（`1> out.log 2> err.log`）启动的常驻进程，其输出**不会**落进被重定向的文件
（实测两份文件恒为 0 字节，但服务本身确实在监听并正常应答 —— 请求日志丢失
会让「服务端 DELETE=0」的审计失去证据）。改为在 Python 进程内部把
`sys.stdout` / `sys.stderr` 换成文件句柄（OS 级、行缓冲），输出去向就不再依赖壳层。

审计口径：服务端每个请求都会经 `webdav_server.py::log_message` 写一行到
  stderr（`[HH:MM:SS] <METHOD> <path> [auth:...]`），另有 `LoggingServer.get_request`
  的 `TCP ACCEPT`。WD 阶段的审计窗口 = 本启动器创建/覆盖的两个文件。

用法: python wd_launch_server.py [YYYYMMDD]
     轮次标记缺省为当天日期；日志写到 wd_wdphase_<标记>.log / .err
"""
import datetime
import os
import runpy
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
STAMP = sys.argv[1] if len(sys.argv) > 1 else datetime.datetime.now().strftime("%Y%m%d")

sys.stdout = open(os.path.join(HERE, f"wd_wdphase_{STAMP}.log"), "w",
                  buffering=1, encoding="utf-8", errors="replace")
sys.stderr = open(os.path.join(HERE, f"wd_wdphase_{STAMP}.err"), "w",
                  buffering=1, encoding="utf-8", errors="replace")

runpy.run_path(os.path.join(HERE, "webdav_server.py"), run_name="__main__")
