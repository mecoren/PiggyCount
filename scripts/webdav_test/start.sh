#!/usr/bin/env bash
# WebDAV 同步回归测试环境一键启动
#
# 用法:
#   ./start.sh              # 前台运行（默认，日志直接输出，Ctrl+C 停止）
#   ./start.sh --wsgidav    # 用 wsgidav 而非内置单文件服务器（更接近真实服务器行为）
#   ./start.sh --fresh      # 清空 data/ 与 share/ 后再启动（干净环境）
#
# 服务器: https://127.0.0.1:8443  （Android 模拟器内用 https://10.0.2.2:8443）
# 凭据:   pctest / piggy123
# 说明:   自签证书 —— App debug 构建对 10.0.2.2:8443 / 127.0.0.1:8443
#         自动放宽证书校验（webdav_provider._isDevTestServer），无需装 CA。
set -euo pipefail
cd "$(dirname "$0")"

PORT=8443
MODE=builtin
FRESH=0
for arg in "$@"; do
  case "$arg" in
    --wsgidav) MODE=wsgidav ;;
    --fresh)   FRESH=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $arg（--help 查看用法）" >&2; exit 2 ;;
  esac
done

if [[ "$FRESH" == 1 ]]; then
  echo "[start] 清空 data/ 与 share/ ..."
  rm -rf data share
  mkdir -p data share
fi

# 自签证书存在性检查（缺失时自动生成，SAN 覆盖 127.0.0.1 / 10.0.2.2）
if [[ ! -f server.crt || ! -f server.key ]]; then
  echo "[start] 生成自签证书 ..."
  if [[ ! -f ca.key ]]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -keyout ca.key -subj "/CN=PiggyCount Test CA" >/dev/null 2>&1
  fi
  openssl req -newkey rsa:2048 -nodes -keyout server.key -subj "/CN=localhost" \
    -out server.csr >/dev/null 2>&1
  [[ -f san.ext ]] || printf 'subjectAltName=DNS:localhost,IP:127.0.0.1,IP:10.0.2.2\n' > san.ext
  openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -days 3650 -extfile san.ext -out server.crt >/dev/null 2>&1
fi

echo "[start] 模式: $MODE  端口: $PORT"
echo "[start] 地址: https://127.0.0.1:$PORT （模拟器: https://10.0.2.2:$PORT）"
echo "[start] 凭据: pctest / piggy123"

if [[ "$MODE" == wsgidav ]]; then
  if ! command -v wsgidav >/dev/null 2>&1; then
    echo "[start] wsgidav 未安装。安装: pip install wsgidav cheroot" >&2
    exit 1
  fi
  exec wsgidav --config wsgidav.yaml
else
  exec python webdav_server.py
fi
