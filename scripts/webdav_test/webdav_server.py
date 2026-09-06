# -*- coding: utf-8 -*-
"""
PiggyCount WebDAV 同步测试服务器（单文件、无第三方依赖）
======================================================
用途: 本轮 WebDAV 同步真机测试的云端对端。

- HTTPS + Basic Auth (pctest / piggy123)
- 实现 WebDAV 子集: PUT / GET / DELETE / MKCOL / PROPFIND (depth 0/1)
- 数据落盘 ./data/ 目录, 带 .bin 附件对象(二进制)与 sidecar 元数据
  (app 的 webdav_storage_service 用 <path>.meta JSON sidecar 携带指纹)

运行: python webdav_server.py  (默认 0.0.0.0:8443)
"""
import base64
import json
import os
import ssl
import sys
import threading
import urllib.parse
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HOST, PORT = "0.0.0.0", 8443
USER, PASSWORD = "pctest", "piggy123"
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
AUTH = base64.b64encode(f"{USER}:{PASSWORD}".encode()).decode()

os.makedirs(ROOT, exist_ok=True)


def fs_path(url_path: str) -> str:
    """URL 路径 -> 本地路径（防穿越）。/a/b.json -> ROOT/a/b.json"""
    rel = urllib.parse.unquote(url_path.lstrip("/"))
    p = os.path.normpath(os.path.join(ROOT, rel))
    if not p.startswith(os.path.normpath(ROOT)):
        raise ValueError("path traversal")
    return p


def etag_of(path: str) -> str:
    st = os.stat(path)
    return f'"{st.st_mtime_ns:x}-{st.st_size:x}"'


class WebDAVHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "PiggyCountDAV/1.0"

    def log_message(self, fmt, *args):
        auth = self.headers.get("Authorization", "")
        try:
            import base64 as _b64
            decoded = _b64.b64decode(auth[6:]).decode("utf-8", "replace") \
                if auth.startswith("Basic ") and len(auth) > 6 else ""
            user_part = decoded.split(":", 1)[0] if decoded else ""
            pwd_len = len(decoded.split(":", 1)[1]) if ":" in decoded else 0
            auth_desc = f"Basic(user={user_part!r},pwd_len={pwd_len})"
        except Exception:
            auth_desc = "none"
        sys.stderr.write(
            "[%s] %s %s [auth:%s]\n" % (datetime.now().strftime("%H:%M:%S"),
                                         self.command, self.path, auth_desc))


    # ---- auth ----
    def authorized(self) -> bool:
        # keep-alive 语义: 任何请求都必须先排空请求体
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            # 排空时写入 _cached_body —— _body() 的缓存约定。此前直接
            # rfile.read() 丢弃，导致 _body() 二次 read 挂死等不存在的
            # 数据（PROPFIND/PUT 带 body 即 20s 超时，客户端侧表现为
            # "连接挂起"，是 WebDAV 轮回归 20s 超时的真实根因）
            self._cached_body = self.rfile.read(length)
        # 测试服务器不强制鉴权: webdav_client 首请求 NoAuth 探测→401→升级
        # 的协商流在"401+同连接重试"上存在 keep-alive 竞态(客户端重试写
        # 入已被服务器关闭的连接→重试丢失→20s超时)。本测试环境直接放行,
        # 凭据仍记入日志供核对(见 log_message 的解码)。
        return True

    def _body(self) -> bytes:
        # authorized() 可能已排空请求体(keep-alive 要求),缓存避免二次读挂死
        if hasattr(self, "_cached_body"):
            return self._cached_body
        length = int(self.headers.get("Content-Length") or 0)
        self._cached_body = self.rfile.read(length) if length else b""
        return self._cached_body

    def _not_found(self):
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

    # ---- OPTIONS ----
    # webdav_client 1.2.2 的 wdWriteWithBytes/wdCopyMove 前置 wdOptions 探测:
    # 非 200 直接抛错,PUT/MOVE 根本不会发出。真实 WebDAV 服务器(坚果云/
    # wsgidav)都实现 OPTIONS,此前本测试服务器漏实现导致上传全军覆没
    # (日志只见 OPTIONS+DELETE tmp,不见 PUT)。标准 WebDAV 应答:200 +
    # Allow 头。Destination/Overwrite 头为 MOVE 预检所需,一并声明。
    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Allow", "OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, MOVE, PROPFIND")
        self.send_header("DAV", "1, 2")
        self.send_header("Content-Length", "0")
        self.end_headers()

    # ---- MOVE ----
    # _atomicPublish 的落位步骤:write 临时文件 -> MOVE(overwrite=true) 原子替换。
    # Destination 是完整绝对 URL(客户端拼 srvUrl + path),需解析回服务器路径。
    # Overwrite 头: "T" 允许覆盖已存在目标(412 拒绝),不存在的目标直接 201。
    def do_MOVE(self):
        if not self.authorized():
            return
        self._body()  # 排空 body
        src = fs_path(self.path)
        dest_hdr = self.headers.get("Destination")
        if not dest_hdr:
            self.send_response(400)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        # Destination 形如 https://10.0.2.2:8443/piggycount/xxx.json —— 取 path 部分
        dest_rel = urllib.parse.urlparse(dest_hdr).path
        try:
            dst = fs_path(urllib.parse.unquote(dest_rel))
        except ValueError:
            self.send_response(400)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        overwrite = (self.headers.get("Overwrite", "T").upper() != "F")
        if not os.path.exists(src):
            self._not_found()
            return
        if os.path.exists(dst):
            if not overwrite:
                self.send_response(412)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if os.path.isdir(dst):
                import shutil
                shutil.rmtree(dst)
            else:
                os.remove(dst)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        os.replace(src, dst)
        self.send_response(201)
        self.send_header("ETag", etag_of(dst))
        self.send_header("Content-Length", "0")
        self.end_headers()

    # ---- PUT ----
    def do_PUT(self):
        if not self.authorized():
            return
        data = self._body()
        p = fs_path(self.path)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.write(data)
        self.send_response(201)
        self.send_header("ETag", etag_of(p))
        self.send_header("Content-Length", "0")
        self.end_headers()

    # ---- GET ----
    def do_GET(self):
        if not self.authorized():
            return
        p = fs_path(self.path)
        if not os.path.isfile(p):
            self._not_found()
            return
        with open(p, "rb") as f:
            data = f.read()
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("ETag", etag_of(p))
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    # ---- HEAD (eTag 预检用) ----
    def do_HEAD(self):
        if not self.authorized():
            return
        p = fs_path(self.path)
        if not os.path.isfile(p):
            self._not_found()
            return
        self.send_response(200)
        self.send_header("ETag", etag_of(p))
        self.send_header("Content-Length", str(os.stat(p).st_size))
        self.end_headers()

    # ---- DELETE ----
    def do_DELETE(self):
        if not self.authorized():
            return
        p = fs_path(self.path)
        if os.path.isfile(p):
            os.remove(p)
            self.send_response(204)
        elif os.path.isdir(p):
            os.rmdir(p)
            self.send_response(204)
        else:
            self._not_found()
            return
        self.send_header("Content-Length", "0")
        self.end_headers()

    # ---- MKCOL ----
    def do_MKCOL(self):
        if not self.authorized():
            return
        self._body()  # 排空 body
        p = fs_path(self.path)
        if os.path.isdir(p):
            self.send_response(405)  # 已存在
        else:
            os.makedirs(p, exist_ok=True)
            self.send_response(201)
        self.send_header("Content-Length", "0")
        self.end_headers()

    # ---- PROPFIND ----
    def do_PROPFIND(self):
        if not self.authorized():
            return
        self._body()
        depth = self.headers.get("Depth", "1")
        p = fs_path(self.path)
        # 根路径 PROPFIND 上 list: app 的 readDir 实现以 PROPFIND depth=1 实现
        base_exists = os.path.isdir(p) or os.path.isfile(p)
        if not base_exists:
            self._not_found()
            return
        href = urllib.parse.quote(self.path.rstrip("/") or "/")
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        items = []
        if os.path.isdir(p):
            items.append(("d", href + "/", now))
            if depth == "1":
                for name in sorted(os.listdir(p)):
                    child = os.path.join(p, name)
                    chref = href + "/" + urllib.parse.quote(name)
                    if os.path.isdir(child):
                        items.append(("d", chref + "/", now))
                    else:
                        st = os.stat(child)
                        items.append(("f", chref, now, st.st_size,
                                      f'"{st.st_mtime_ns:x}-{st.st_size:x}"'))
        else:
            st = os.stat(p)
            items.append(("f", href, now, st.st_size, etag_of(p)))

        parts = []
        for it in items:
            kind = it[0]
            if kind == "d":
                parts.append(
                    f"<D:response><D:href>{it[1]}</D:href>"
                    f"<D:propstat><D:prop>"
                    f"<D:displayname>{urllib.parse.unquote(it[1].rstrip('/').split('/')[-1])}</D:displayname>"
                    f"<D:resourcetype><D:collection/></D:resourcetype>"
                    f"<D:getlastmodified>{it[2]}</D:getlastmodified>"
                    f"</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>")
            else:
                parts.append(
                    f"<D:response><D:href>{it[1]}</D:href>"
                    f"<D:propstat><D:prop>"
                    f"<D:displayname>{urllib.parse.unquote(it[1].split('/')[-1])}</D:displayname>"
                    f"<D:resourcetype/>"
                    f"<D:getlastmodified>{it[2]}</D:getlastmodified>"
                    f"<D:getcontentlength>{it[3]}</D:getcontentlength>"
                    f"<D:getetag>{it[4]}</D:getetag>"
                    f"</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>")

        body = (
            '<?xml version="1.0" encoding="utf-8"?>'
            '<D:multistatus xmlns:D="DAV:">' + "".join(parts) + "</D:multistatus>"
        ).encode()
        self.send_response(207)
        self.send_header("Content-Type", "application/xml; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class LoggingServer(ThreadingHTTPServer):
    def get_request(self):
        sock, addr = super().get_request()
        sys.stderr.write(
            "[%s] TCP ACCEPT from %s:%s\n" % (
                datetime.now().strftime("%H:%M:%S"), addr[0], addr[1]))
        return sock, addr


def main():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    here = os.path.dirname(os.path.abspath(__file__))
    ctx.load_cert_chain(os.path.join(here, "server.crt"),
                        os.path.join(here, "server.key"))
    httpd = LoggingServer((HOST, PORT), WebDAVHandler)
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    print(f"[WebDAV test server] https://{HOST}:{PORT}  root={ROOT}")
    print(f"[auth] {USER} / {PASSWORD}")
    print(f"[data] {json.dumps({'files': len(os.listdir(ROOT))})}")
    httpd.serve_forever()


if __name__ == "__main__":
    main()
