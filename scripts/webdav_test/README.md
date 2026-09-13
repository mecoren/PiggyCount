# WebDAV 同步回归测试环境

PiggyCount 的 WebDAV 后端（`flutter_cloud_sync_webdav`）真机/模拟器回归测试用云端对端。一轮完整回归无需重新配置服务器、证书、探针——本目录已固化全部组件。

## 一键启动

```bash
cd scripts/webdav_test
./start.sh              # 内置单文件服务器（零依赖，默认）
./start.sh --wsgidav    # wsgidav（行为更接近坚果云/NAS 等真实服务器）
./start.sh --fresh      # 清空数据目录后启动（干净环境）
```

内置服务器默认只绑回环（`127.0.0.1`，模拟器的 `10.0.2.2` 即映射宿主 loopback）。如需真机走局域网访问，改绑非回环地址时**无需改源码**：

```bash
python webdav_server.py --host 0.0.0.0 --port 8443   # 启动即打印暴露告警
# 或环境变量：WEBDAV_HOST=0.0.0.0 WEBDAV_PORT=8443 python webdav_server.py
```

> ⚠️ 本服务不强制鉴权（见下），绑定非回环地址 = 把无鉴权服务暴露到局域网，仅限本机测试环境。历史轮曾为此在启动器里内存改写绑定（`scripts/live_db/run_20260913/start_webdav_local.py`），仓库脚本配置化后该启动器已退化为直接委托。

| 项 | 值 |
|---|---|
| 地址（宿主机） | `https://127.0.0.1:8443` |
| 地址（Android 模拟器） | `https://10.0.2.2:8443` |
| 用户名 / 密码 | `pctest` / `piggy123` |
| remotePath | `/piggycount/`（App 内默认） |

自签证书无需安装 CA：App 的 debug 构建对 `10.0.2.2:8443` / `127.0.0.1:8443` 自动放宽证书校验（`webdav_provider.dart` 的 `_isDevTestServer`，仅 debug + 仅这两个 host）。生产与其他 URL 完全不受影响。

## 组件说明

| 文件/目录 | 用途 |
|---|---|
| `start.sh` | 一键启动（证书缺失时自动生成，见下） |
| `webdav_server.py` | 内置单文件 WebDAV 服务器（HTTPS + PUT/GET/DELETE/MKCOL/PROPFIND，无第三方依赖）。**不强制鉴权**——见源码注释：webdav_client 首请求 NoAuth→401→升级的协商流在「401 + 同连接 keep-alive 重试」上有竞态，测试环境直接放行并把凭据记日志。App 侧 W5 修复（预置 BasicAuth）后每个请求直接携带凭据，日志可核对。绑定/端口支持 `--host/--port` 或 `WEBDAV_HOST/WEBDAV_PORT` 覆盖（默认 `127.0.0.1:8443`）；DELETE 按RFC 4918 递归删除目录；PROPFIND displayname 已做 XML 转义；URL 路径穿越（编码 `../` / 兄弟目录前缀绕过）返回 400 不断连 |
| `wsgidav.yaml` | wsgidav 配置（强制 Basic Auth，`./share` 为根） |
| `ca.*` / `server.*` / `san.ext` | 自签证书链（SAN 覆盖 localhost / 127.0.0.1 / 10.0.2.2） |
| `data/` | 内置服务器的数据落盘目录（App 写入的 ledger JSON、附件、sidecar 元数据都在这里，可直接查看/对比） |
| `share/` | wsgidav 模式的数据目录（同上） |
| `dart_probe/` | 独立 dart 探针工程（`dart run bin/probe.dart`），用于在 App 之外验证 webdav_client 的底层行为（鉴权协商、PROPFIND 解析、PUT/GET 往返） |

## 回归步骤（A/B 双端）

1. 启动服务器（见上）。日志会打印每个请求的 method / path / Authorization 摘要。
2. A 设备（模拟器）：App 配置 WebDAV → `https://10.0.2.2:8443`，凭据如上。
3. 注入/编辑测试数据后上传（A 端推送）。
4. B 设备（或清数据后的同机 App）：同凭据连接，验证启动检查 / 手动下载 / 汇率、预算、周期规则、附件的对比。
5. 需要对比两端 DB / 云端 JSON：直接查 `data/piggycount/`（或 wsgidav 模式的 `share/piggycount/`）。

## 常见坑（历史踩坑记录）

- **401 + keep-alive 重试竞态**：webdav_client 的 NoAuth 首请求 → 401 → 同连接重试在部分服务器上会写入已被服务端关闭的连接，重试静默丢失直到 20s 超时。App 侧 W5（预置 BasicAuth）已根治；内置测试服务器为规避该竞态不强制鉴权。
- **davs:// 不被支持**：WebDAV over TLS 必须写 `https://`（provider 校验会直接拒绝 `davs://`）。
- **证书 SAN 不含 10.0.2.2**：重生成证书时务必带 `san.ext`（脚本已内置）。
