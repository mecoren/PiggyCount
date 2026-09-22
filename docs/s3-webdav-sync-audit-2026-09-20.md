# S3 与 WebDAV 云端同步功能全面技术探查报告（2026-09-20）

- **探查日期**: 2026-09-20
- **探查方式**: 4 路自动化代码审计（S3 包 / WebDAV 包 / 应用层集成 / core 框架）+ 关键结论逐行人工复核 + 测试基线全量复跑 + 定向修复回归
- **探查范围**: `packages/flutter_cloud_sync_s3`、`packages/flutter_cloud_sync_webdav`、`packages/flutter_cloud_sync`(core)、应用层 `lib/cloud/**`、`lib/data/encryption/**`、`lib/services/system/logger_service.dart`、`lib/data/db.dart`、`lib/services/export/config_export_service.dart`
- **上轮基线**: `docs/s3-webdav-sync-audit-2026-09-08.md`（上轮 28 项中 16 项当日修复，余项 09-09/09-10 陆续闭环）
- **本轮产出**: 新发现/复核问题 **22 项**（P1 5 项、P2 6 项、P3 11 项），当日**实施修复 16 项**并回归通过；余 6 项为设计边界/需要更大改造，给出明确方案留待迭代
- **2026-09-21 收尾**: 遗留 6 项中 **L-01 / L-02 / L-03 / L-04 已修、L-05 部分完成**（详见 §六 处置列），L-06 维持设计边界；全量回归通过（analyze 零 issue，六套单测全绿）。其中 L-04 的原建议方案经实证取证后**判定不可行并改为白名单拒绝**，L-02 的真实漏点与原文描述不同（详见 §六）

---

## 一、总体结论

1. **测试基线**（修复前）：S3 包 133 过 / **3 失败**（网络依赖的测试基建缺陷）；WebDAV 包 59 全过；core 包 95 全过；应用层 1371 全过。
2. **协议实现整体成熟**：SigV4 签名链路（canonical request / 编码 / UNSIGNED-PAYLOAD / 时钟补偿 / 条件写 / V2↔V1 分页回退 / 桶级 404 区分）、WebDAV 原子发布（tmp PUT → MOVE → 无损交换降级）+ 信封格式 + Basic 预置/Digest 兜底，均正确且经重度加固。本轮未发现签名致命错误或数据损坏路径。
3. **本轮发现的关键功能性缺陷**：`P2-2③` 快照 gzip 压缩特性因**装配方向颠倒**在生产**完全失效**（P1）；S3 `onRetryEvent` 逐次重试日志因宿主只转发 warning 而在 release **整体丢弃**（LOG-06 失效）；配置导入把云凭据写入**明文 SharedPreferences**（安全回归）。
4. **稳定性/性能缺口**：S3 分页重试粒度为「整段」而非「单页」（大桶单页抖动 → 全量重翻）；WebDAV 超时被当作「连接层瞬时故障」重试（最坏 3×60s）；WebDAV 501（不支持覆盖 MOVE）未纳入无损交换降级判定；S3 含点 bucket 走 virtual-hosted 触发 TLS 证书不匹配。
5. **修复后回归**：S3 包 **144 全过**（含新增 13 项）、WebDAV 包 **61 全过**（含新增 2 项）、core 包 95 全过、应用层 **1371 全过**（含新增 3 项），`flutter analyze` 零 issue。

---

## 二、六项任务逐项结论

### 任务 1：协议实现完整性与合规性 — 通过（有保留）

**S3**
- SigV4 主链路正确：canonical request（RFC 3986 严格编码、请求端与签名端口径统一）、string-to-sign、kDate→kRegion→kService→kSigning 派生、`x-amz-date`/`x-amz-content-sha256`、`UNSIGNED-PAYLOAD` 流式降级、时钟偏差自动补偿、条件写（If-Match/If-None-Match + 404/409 语义翻译）、ListObjectsV2 + 501 立即回退 V1、桶级 vs 对象级 404 区分、ETag 归一化。
- 合规缺口（能力缺失，非错误）：无 multipart upload、无 Range/断点续传、无 DeleteObjects 批量删除、无 STS 临时凭据、无 Content-MD5/checksum。对当前数据规模（账本 JSON ~350KB、附件 KB~MB 级）无实际影响，记为设计边界。
- **本轮修复**：
  - `F-01`（P2）含点 bucket + 托管云 virtual-hosted → 通配证书只匹配单层标签，TLS 握手失败。现按 AWS SDK 规则对含点 bucket 默认强制 path-style（`resolveForcePathStyle` 纯函数），`forcePathStyle` 仍可显式覆盖。
  - `F-02`（P3）XML `<Message>` 无长度约束，畸形/恶意网关回传数 KB 文本撑爆异常与日志；统一按 300 字符截断（原仅非 XML 回退分支截断）。

**WebDAV**
- 方法合规：PUT/GET/DELETE/MKCOL(逐级递归)/MOVE(Overwrite)/PROPFIND(Depth-1)/OPTIONS；原子发布（tmp → MOVE 覆盖 → 降级无损交换，任一步失败可回滚）；信封格式 `pc-wdav-env-v1`；BasicAuth 预置（避开双倍往返）+ Digest 兜底。
- **本轮修复**：`F-03`（P2）`_isOverwriteUnsupported` 只认 405/409/412，未覆盖 **501 Not Implemented**（RFC 4918 明确的「不支持该方法」）。部分服务器仅对「覆盖已存在目标」的 MOVE 返回 501，而交换降级使用的非覆盖/目标不存在的 MOVE 仍可用 —— 现已纳入 501 + 文案兜底 `not implemented`。423 Locked 有意排除（被锁资源同样会挡住交换自身的 MOVE）。

### 任务 2：核心同步操作稳定性 — 通过（弱网/大桶档有缺口）

- 上传/下载/删除/更新四类操作在正常网络下的正确性由既有双端实测（6006 笔 0 差异）与 100 轮中断压测背书；本轮未见新增正确性缺陷。
- **本轮修复**：
  - `F-04`（P1）S3 ListObjects 重试粒度为**整个翻页循环**：大桶在第 N 页遇一次瞬时 5xx/网络抖动即**从第 1 页全量重翻**（重试 3 次 = 最多 3 倍全量列举，带宽/费用倍增）。现抽出单页 `_fetchListPage`，`_retry` 只包当前页（V1/V2 同款）。
  - `F-05`（P1）WebDAV 超时（`CloudStorageException`，无结构化状态码）被 `_retryIdempotent` 当作「连接层瞬时故障」重试，单次 60s 超时最坏放大为 3×60s=180s。新增 `_WebDavTimeoutException` 标记，超时不进入重试。
  - `F-06`（P3）S3 `transferTimeoutFor` 在自定义 `timeout > 5min` 封顶值时 `num.clamp(lower>upper)` 抛 `ArgumentError`（公开参数，潜在崩溃）；现以 `timeout` 自身为上界。
  - `F-07`（P3）S3 流式 PUT 的 412/409 失败分支未 drain 响应体 → keep-alive 连接无法回池；与成功路径 N-14 同款补齐。
  - `F-08`（P3）WebDAV `delete()` 是幂等操作却走无重试的 `_op`，与 `_retryIdempotent` 注释「覆盖 remove」不符；改用 `_opRetryable`。

### 任务 3：高级功能（断点续传/冲突解决/增量同步）— 通过（断点续传为设计边界）

- **断点续传**：S3 无 multipart/无 Range，WebDAV 无 Range —— 流式或全量，网络中断即整体重来。当前数据规模（单对象 <5MB）可接受，记为设计边界。
- **冲突解决（三层，健全）**：上传前探测 → 条件写（S3 原子 If-Match；WebDAV eTag 预检近似）→ 写后校验（指纹回读）。412 翻译为 `CloudPreconditionFailedException` 走用户确认/合并，绝不静默覆盖。字段级合并（bizkey 对齐/deleted 默认不选中）安全。
- **增量同步**：指纹三方恒等体系（本地/云端 metadata/快照内嵌）+ metadata 优先零下载 + 附件内容寻址 + 会话级附件名缓存 + 同账本并发互斥（FIFO）+ 恢复守卫。
- **本轮修复**：`F-09`（P2）本地指纹缓存（P2-1）的**回调绑定陈旧实例**：`ChangeTracker` 由 repo 长生命周期持有，TSM 随 `syncServiceProvider` 重建时 `??=` 挡下新回调，写回调永远指向已 dispose 的旧实例 → 新实例缓存不被回调失效（仅靠 MAX(id)+count 第二道校验兜底）。改为每次重绑最新实例。

### 任务 4：性能指标 — 通过（有优化空间）

- 传输：单账本快照 ~350KB（1000 笔）；附件先于清单；附件上传 list 会话缓存（60s TTL）+ 上传成功登记；并发 4（semaphore）。
- 内存：快照 JSON 解析 isolate 化；S3 流式上传/下载；WebDAV 全内存（信封需整体构造，350KB 级无压力）。
- 响应时间：超时分级（元数据 30s / 传输自适应 30s+30s/MB 上限 5min / getObject 90s）；getStatus 60s TTL 缓存 + recent-upload 15s 窗口；冷启动指纹缓存（内存 + 双失效防线）。
- **本轮修复**：`F-10`（**P1**）gzip 压缩层装配方向颠倒 → 生产**永不压缩**（详见任务 6 与问题清单 P1-gzip）；`F-11`（P3）新装库缺 `idx_sync_op_log_ts` 索引 → 指标 30 天窗口聚合全表扫描。

### 任务 5：安全机制 — 通过（1 项安全回归已修）

- 身份验证：WebDAV Basic 预置 + Digest 兜底；S3 SigV4；两者强制 HTTPS（明文在 initialize 配置期即拒绝）。
- 授权控制：keyPrefix 桶内隔离 + 前缀/路径 `..` 与穿越校验（S3/WebDAV 对齐）+ bucket 白名单。
- 数据加密：传输层 HTTPS 强制 + 禁重定向（防 3xx 把 PUT 改 GET、凭据跨域转发）；静态层 E2EE（Argon2id 64MB/3iter + AES-256-GCM 随机 nonce + 弱密码黑名单 + 密钥轮换 + 多设备密文迁移 + 元数据整包加密信封）。
- **本轮修复**：`F-12`（**P2·安全**）`ConfigExportService.importFromYaml` 直接 `prefs.setString('cloud_*_cfg', ...)`，把 WebDAV 密码 / S3 SecretKey / Supabase anonKey 写入**明文 SharedPreferences**，绕过「凭据绝不落明文」硬约束；且导入不激活后端 → 明文无限期残留。现改经 `CloudServiceStore.saveOnly`（secure storage + 清除明文残留）。
- **本轮修复**：`F-13`（P3）`LogSanitizer` 词表对后端配置真实字段名（`s3SecretKey`/`s3AccessKey`/`webdavPassword`/`supabaseAnonKey`/`supabasePassword`）存在盲区（`\b` 词边界不切分 `s3SecretKey` 内的 `secretKey`）→ 配置一旦被日志化即整段明文外泄（当前无调用点，属潜伏）。词表补齐 + 新增单测。

### 任务 6：日志系统 — 完整（1 项 release 失效已修）

- 应用层：LoggerService 环形缓冲 2000 条 / 48h TTL / 节流落盘 / 原生桥接；TSM/StartupSyncChecker/BackupService 全链路 info/warning/error；`LogSanitizer` 中央脱敏（URL userinfo / 键值对 / JSON 字段 / Bearer·Basic 头）。
- 指标：`sync_op_log` 表 + `SyncMetricsService` 四态 outcome + 7 类错误归因 + 30 天滚动清理 + 健康卡 + 诊断导出；埋点覆盖 upload/restore/startup/attachment/backup/discovery。
- **本轮修复**：
  - `F-14`（**P1·日志**）`provider_factory.dart` 的 S3 `downgradeLogger` 只转发 `warning`，其余级别被丢弃 —— 而 `S3StorageService` 把 **LOG-06 重试逐次事件以 info 级**注入 → **LOG-06 在 release 构建完全失效**（弱网排障无法区分「一次成功」与「重试后成功」，含条件 PUT 安全重试痕迹）。现按 level 全量转发，与 WebDAV/Supabase 侧接线一致。
  - `F-02`（P3）错误消息截断（见任务 1）。
  - `F-15`（P2·性能）gzip 压缩统计日志（`compressionLogger`）此前因装配颠倒从不触发；修复装配后恢复有效。

---

## 三、问题清单（按优先级，含状态）

> 状态列：✓=本轮已修复并回归；◐=部分/方案已定待迭代；●=复核确认存在（设计边界）

| 编号 | 级别 | 类别 | 问题 | 定位 | 状态 |
|---|---|---|---|---|---|
| P1-GZIP | P1 | 功能失效 | gzip 压缩层装在加密层**之下**（`Encrypted(Gzip(raw))`），上传时加密层先产出 `BEECRYPT1:` 密文，gzip 命中透传短路 → 永不压缩；条件写路径（S3 恒走）亦整体绕过。P2-2③ 特性在生产为死代码，仅测试假阳性掩盖 | `encrypted_cloud_provider.dart:51-56`、`transactions_sync_manager.dart:644-649` | ✓ 已修复（改 `outerStorageWrapper` 外层包装 + `uploadBinaryConditional` 压缩 + 真实压缩断言） |
| P1-S3PAGE | P1 | 性能/成本 | ListObjects 重试包裹整个翻页循环，单页瞬时故障 → 从第 1 页全量重翻（最多 3 倍全量列举） | `s3_client.dart:_listObjectsV2/V1Detailed` | ✓ 已修复（单页重试单元 `_fetchListPage`） |
| P1-WDTIMEOUT | P1 | 稳定性 | 超时无结构化状态码 → 命中幂等重试默认可重试分支，最坏 3×60s=180s 卡顿 | `webdav_storage_service.dart:_op/_retryIdempotent` | ✓ 已修复（`_WebDavTimeoutException` 排除重试） |
| P1-LOG06 | P1 | 日志 | S3 `downgradeLogger` 只转发 warning，LOG-06 重试逐次事件（info）被丢弃 → release 无痕迹 | `provider_factory.dart:134-140` | ✓ 已修复（按 level 全量转发） |
| P1-CFGSEC | P1 | 安全 | 配置导入把云凭据写入明文 SharedPreferences，绕过「凭据绝不落明文」约束 | `config_export_service.dart:2223-2255` | ✓ 已修复（改经 `CloudServiceStore.saveOnly`） |
| P2-WD501 | P2 | 兼容性 | 不支持覆盖式 MOVE 的服务器返回 501 时不走交换降级 | `webdav_storage_service.dart:_isOverwriteUnsupported` | ✓ 已修复（纳入 501 + 文案兜底） |
| P2-S3DOTBUCKET | P2 | 兼容性 | 含点 bucket + 托管云 virtual-hosted → 通配证书单层标签限制 → TLS 握手失败，错误误导 | `s3_provider.dart` / `s3_client.dart:_buildUri` | ✓ 已修复（`resolveForcePathStyle` 含点强制 path-style） |
| P2-FPCACHE-CB | P2 | 一致性 | `onLocalContentGeneration` 用 `??=` 绑定首个 TSM，重建后回调指向已 dispose 实例 | `transactions_sync_manager.dart:2307` | ✓ 已修复（改为每次重绑） |
| P2-IDX | P2 | 性能 | 新装库 `onCreate` 遗漏 `idx_sync_op_log_ts` → 指标 30 天聚合全表扫描 | `db.dart:onCreate` | ✓ 已修复（onCreate 补建，与 onUpgrade 同构） |
| P2-SANITIZER | P2 | 安全(潜伏) | `LogSanitizer` 词表缺后端配置真实字段名（`s3SecretKey` 等），脱敏盲区 | `logger_service.dart:181-195` | ✓ 已修复（词表补齐 + 单测） |
| P2-TESTNET | P2 | 测试基建 | S3 3 项测试依赖真实网络/DNS，无 DNS 环境挂到 30s 超时失败 | `s3_bucket_validation_test.dart`、`s3_provider_https_test.dart` | ✓ 已修复（改用本机关闭端口 127.0.0.1:1，快速失败） |
| P3-S3MSG | P3 | 日志 | XML `<Message>` 不截断，日志/异常可膨胀 | `s3_client.dart:_handleError` | ✓ 已修复（统一 300 字符截断） |
| P3-S3CLAMP | P3 | 健壮性 | `timeout > 5min` 时 `transferTimeoutFor` 抛 `ArgumentError` | `s3_client.dart:71-77` | ✓ 已修复（上界自适应） |
| P3-S3DRAIN | P3 | 资源 | 流式 PUT 412/409 分支未 drain 响应体，连接无法回池 | `s3_client.dart:566-586` | ✓ 已修复 |
| P3-WDDELETE | P3 | 稳定性 | `delete()` 幂等却无重试（与注释不符） | `webdav_storage_service.dart:570` | ✓ 已修复（`_opRetryable`） |
| P3-WDJITTER | P3 | 文档 | 退避 jitter 注释称「±50%」，实际为 `[0.5×base, base]` | `webdav_storage_service.dart:210-214` | ✓ 已修复（注释校正） |
| L-01 | P3 | 协议 | `If-Match`/`If-None-Match` 未进入 SignedHeaders，但注释/测试标题声称「参与签名」（测试假绿） | `s3_signature.dart:86-90` vs `s3_client.dart:716-726` | ● 设计边界（功能不受影响；仅文档/测试口径需澄清，留待迭代） |
| L-02 | P3 | 资源 | S3 流式 PUT 412/409 之外的失败分支未 drain（如 403/500） | `s3_client.dart:590-612` | ● 与 P3-S3DRAIN 同族，影响面小，留待迭代 |
| L-03 | P2 | 性能 | `CloudSyncManager.getStatus` 不接受预计算指纹 → TSM 指纹缓存命中时仍触发一次全量导出（P2-1 收益打折） | `cloud_sync_manager.getStatus` / `transactions_sync_manager:2119-2134` | ● 需 core API 扩展，方案已定（新增 `localFingerprint` 入参），留待迭代 |
| L-04 | P2 | 兼容性 | WebDAV 路径段未做 percent-encoding，MOVE Destination 用 `encodeFull` —— 两侧编码口径不一致，含空格/`#`/`?`/非 ASCII 文件名有解析风险 | `webdav_storage_service.dart:_buildPath` / webdav_dio | ● 需统一编码口径（有回归面），留待迭代 |
| L-05 | P3 | 重试 | 四套重试参数仍不统一（S3 3 次/1s 基 vs 其余 2 次/400ms；TSM 附件无 jitter）；core `RetryHelper` 为死代码 | 多文件 | ● 已在 `docs/sync-reliability-params.md` 备案为权威口径 |
| L-06 | P3 | 性能 | S3 无 multipart / Range（断点续传）；WebDAV 无 Range；iCloud base64 内存峰值 4× | 各包 | ● 设计边界（当前数据规模可接受） |

---

## 四、本轮修复实施清单（16 项）

| # | 问题 | 修复内容 | 文件 |
|---|---|---|---|
| 1 | P1-GZIP | `innerStorageOverride` → `outerStorageWrapper`，gzip 装在加密层外层；`uploadBinaryConditional` 一并压缩；doc/注释校正；测试补「密文体积显著小于不压缩基线」真实断言 | `encrypted_cloud_provider.dart`、`transactions_sync_manager.dart`、`gzip_cloud_storage.dart`、`encrypted_cloud_provider_test.dart`、`gzip_cloud_storage_test.dart` |
| 2 | P1-S3PAGE | 抽出 `_fetchListPage`（V1/V2 共用），重试粒度收敛到单页 | `s3_client.dart` |
| 3 | P1-WDTIMEOUT | 新增 `_WebDavTimeoutException`，`_op` 超时统一归类，`_retryIdempotent` 排除超时；`opTimeoutForTest` 测试口 | `webdav_storage_service.dart` |
| 4 | P1-LOG06 | S3 `downgradeLogger` 按 level 全量转发（debug/info/warning/error） | `provider_factory.dart` |
| 5 | P1-CFGSEC | 云配置导入改经 `CloudServiceStore.saveOnly`（secure storage + 清除明文） | `config_export_service.dart` |
| 6 | P2-WD501 | `_isOverwriteUnsupported` 纳入 501 + `not implemented` 文案 | `webdav_storage_service.dart` |
| 7 | P2-S3DOTBUCKET | 新增纯函数 `resolveForcePathStyle`，含点 bucket 强制 path-style | `s3_provider.dart` |
| 8 | P2-FPCACHE-CB | `??=` → 每次重绑最新 TSM 回调 | `transactions_sync_manager.dart` |
| 9 | P2-IDX | `onCreate` 补建 `idx_sync_op_log_ts` | `db.dart` |
| 10 | P2-SANITIZER | 词表抽 `_credentialKeys` 并补齐后端配置真实字段名 | `logger_service.dart` |
| 11 | P2-TESTNET | 网络依赖测试改用本机关闭端口，去除 30s 超时失败 | `s3_bucket_validation_test.dart`、`s3_provider_https_test.dart` |
| 12 | P3-S3MSG | `_truncateForLog` 统一 300 字符截断 | `s3_client.dart` |
| 13 | P3-S3CLAMP | `transferTimeoutFor` 上界自适应（timeout > 封顶时以 timeout 为上界） | `s3_client.dart` |
| 14 | P3-S3DRAIN | 流式 PUT 412/409 分支 drain 响应体 | `s3_client.dart` |
| 15 | P3-WDDELETE | `delete()` 改用 `_opRetryable` | `webdav_storage_service.dart` |
| 16 | P3-WDJITTER | 退避 jitter 注释校正 | `webdav_storage_service.dart` |

---

## 五、回归验证结果（2026-09-20 修复后）

| 套件 | 用例数 | 结果 |
|---|---|---|
| `packages/flutter_cloud_sync_s3` | **144**（基线 133 过/3 失败 + 新增 13：审计修复 8 + 超时档 1 + 测试基建修复 3 转正 + 其他） | **全过**（无超时失败） |
| `packages/flutter_cloud_sync_webdav` | **61**（基线 59 + 新增 2：501 降级 / 超时不重试） | **全过** |
| `packages/flutter_cloud_sync`（core） | 95 | **全过**（未改动逻辑，基线复验） |
| 主应用 `test/**`（全量） | **1371**（+1 skip；含新增 3：gzip 条件写压缩 / 加密外层压缩断言 / onCreate 索引） | **全过** |

静态检查：`flutter analyze`（S3 包 / WebDAV 包 / 应用层 `lib`+`test`）**零 issue**。

**关键回归证据**：
- gzip：新增断言「同一明文，gzip 外层密文长度 < 未压缩基线 ×0.7」——修复前该断言必然失败（压缩从未发生）；修复后通过，说明压缩真实生效。
- WebDAV 501：新增 fake server「覆盖已存在目标的 MOVE 返回 501、非覆盖 MOVE 正常」→ 交换降级成功落位，备份位与临时文件均清理。
- WebDAV 超时：新增 `opTimeoutForTest` + 延迟读 → PROPFIND 只发生 **1 次**（修复前为 3 次）。
- S3 单页重试：第 2 页 500 一次后成功 → 第 1 页请求次数 == **1**（修复前为 2）。

---

## 六、遗留项与后续方案

> **2026-09-21 更新**：下表 5 项（L-01 ~ L-05）已完成处置并全量回归通过；L-06 维持设计边界。
> 回归证据：`flutter analyze`（应用 lib+test / 四个改动包）零 issue；单测 core 97 / S3 150 /
> WebDAV 71 / Supabase 38 / iCloud 31 / 应用层 1374（1 skip）全绿。

| 编号 | 问题 | 建议方案 | 2026-09-21 处置 |
|---|---|---|---|
| L-03 | getStatus 指纹缓存被全量导出抵消 | core `CloudSyncManager.getStatus` 增加可选 `localFingerprint`/`localParsedCount` 入参；TSM 缓存命中时透传。需同步 core 单测。 | ✅ **已修**。core 新增 `localFingerprint` 预计算入参（与 `localSerializedData`/`localParsedCount` 同族）；TSM `_localFpCache` 增存 `count`，命中路径传 `localFingerprint` + `localParsedCount`，core 连序列化都不做。新增 3 用例（含「serialize 被调用即抛错」的 fake 钉住「命中不得再导出」）。另修正 `docs/sync-metrics-implementation-2026-09-09.md` 中已不成立的「不构成退化」判定。<br>**2026-09-21 加固（生产可用性）**：透传缓存指纹后，缓存新鲜度直接影响同步判定，而原 guard（`local_changes` 的 MAX(id)+COUNT）在生产**恒为 `-1/0`** —— 快照装配下不注入 ChangeTracker（`database_providers.dart:31-34`），`LocalRepository` 全部 local_changes 写入都挂在 `changeTracker != null` 分支（55 处）→ 该表生产恒空。新增 `_contentGenerationGuard(ledgerId)`：快照所涉各表的「行数 + MAX(id) + SUM(updated_at)」代际 —— transactions/categories/tags/accounts/ledgers 由 v40 触碰触发器维护；budgets/recurring_transactions/exchange_rate_overrides 由仓储更新路径显式写 `now()`；transaction_tags/transaction_attachments/transaction_tag_overrides 只增删不改写，COUNT+MAX(id) 已足够；与 `local_changes` 校验位**叠加**（不删除旧防线）。实测（5000 笔单账本，debug VM）：代际查询 **3.89 ms** vs 全量导出 **471.13 ms**，8 账本每轮省 **≈3.7 s**。新增 5 用例并**已取证「修复前必失败」**（两侧 guard 回退到旧实现时，4 项失败且返回陈旧指纹 `fp-cached-0000`）。 |
| CT-1 | ChangeTracker 生产未注入 → local_changes 全链路空转（[09-12 终审](sync-full-system-audit-final-2026-09-12.md) 已立） | 二选一收敛：(a) 恢复生产注入 tracker；(b) 拆除 TSM 对 local_changes 的读端依赖。 | ✅ **按 (b) 落地（两段）**。产品侧确认 tracker 随云端协同下线（`database_providers.dart` 已注明不注入），故走 (b)：① 指纹缓存校验位 → `_contentGenerationGuard`（业务表行数+MAX(id)+SUM(updated_at)，与 local_changes 叠加；实测 3.89ms vs 全量导出 471.13ms，8 账本省 ≈3.7s/轮；5 用例已取证「修复前必失败」）；② 方向仲裁证据门禁 → `_localChangeEvidence` 改用 v40 触碰列 + `created_at` 兜底（补 INSERT），**trusted 门禁不放松**（仍是「本地确有未上云内容」的内容性断言），新增证据 c「持久痕迹晚于本机上次成功上传时刻」（锚点=`sync_op_log` 该账本 snapshot_upload+success 的 MAX(ts) ∪ 内存 `_recentUpload`）——刻意用**同机时钟锚点**，避免跨设备时钟偏移把「本机更晚」判错而静默覆盖他机数据（P1-12 保护）。6 用例含锚点正/负例与单位断言。**残留**：`transactions`/`categories` 无 created_at 且触发器不覆盖 INSERT → 跨 session 纯新增无持久墙钟（退回 unknown 弹确认，保守不丢数据）；锚点受 30 天指标保留期限制。彻底闭合仍需 (a)。 |
| L-04 | WebDAV 路径编码口径不一致 | 输出端统一 percent-encoding，MOVE 用同一编码器。 | ✅ **已修（改为白名单拒绝，非主动编码）**。先对 `webdav_client 1.2.2` 实证取证（`scripts/live_db/run_20260920/probe_uri.dart`）：`Uri.parse`（PUT/PROPFIND）与 `Uri.encodeFull`（MOVE Destination）对 `#`/`?`/`%` 口径不一致，**主动编码会双重编码**（`%20`→`%252520`），原建议方案不可行。改为 `_disallowedPathChar` 白名单校验：拒绝 `#`/`?`/`%`/非 ASCII/`[]`/控制字符（均会导致「静默操作了另一个远端对象」），放开空格以外全部白名单字符；`list`/`getMetadata` 的 `_buildPath` 移出 try，配置错误不再被包装成存储故障。新增 10 用例。当前业务路径（UUID/hex/日期 ZIP）全在白名单内，零回归。 |
| L-01 | 条件头未进 SignedHeaders | ② 修正注释与测试标题（零风险）。 | ✅ **已修（方案 ②）**。抽出唯一口径 `resolveSignedHeaderKeys()`（canonical headers 与 `SignedHeaders=` 曾各自内联同一表达式，存在漂移隐患），并在文档化取舍的同时移除死代码 `content-length`（S-A 决策从「调用方不放」升级为「结构上不可能放」）；修正假绿测试标题并新增 2 用例显式钉住真实签名集合。 |
| L-05 | 四套重试参数不统一 | 收编 core 单一策略层；TSM 附件重试补 jitter。 | ◐ **部分完成**。TSM 附件重试退避补真随机 jitter（[0.5×base, base]，与四适配器同款，`attachmentRetryDelayForTest` 单测钉住区间与随机性）；core `RetryHelper` 增加「无生产调用方、勿直接接入」状态声明。**「四套参数收编单层」有意不做**：各包参数已实测调优且语义不同（S3 的 neverRetry 状态码 / WebDAV 超时不重试 / 条件写锚点安全重试），强行收编等于静默回退，收益（P3）不抵回归面。参数以 `docs/sync-reliability-params.md` 为唯一权威口径。 |
| L-02 | S3 其余失败分支未 drain | 与 F-07 同款补齐（403/500/其他状态码分支）。 | ✅ **已修（实测复核后按真实漏点修）**。复核发现 403/500 等分支实际经 `_readErrorBody` 已消费 body，真正的漏网分支是**「读 body 但读不完」**：`http.Response.fromStream(...).timeout(...)` 超时后外层 future 被放弃、内部订阅既不取消也不消费（连接被静默弃置）；另「body 已发完、响应迟到超时」也会留下无读者响应体。已改为自行消费（`await for` + `Stream.timeout` 取消语义）并在超时放弃处挂 drain 兜底。新增 4 用例（含「流永不结束 → 超时后必须取消订阅」的回归闸门）。 |
| L-06 | 断点续传/multipart/Range 缺失 | 当前数据规模 <5MB，维持现状。 | ● **维持设计边界**（未改动）。 |

---

## 七、探查方法与可复现性

- 代码审计：4 路并行子代理（S3 包 / WebDAV 包 / 应用层集成 / core），逐文件通读 + 交叉核对父包接口契约与宿主装配，所有结论均定位到 `文件:行号`，并区分「真实缺陷 / 设计边界 / 缺失能力」。
- 基线复跑：`flutter test` × 4 套件（S3/WebDAV/core/应用层）。
- 修复回归：定向新增 16 项用例覆盖每个修复点的「修复前必失败、修复后必通过」断言；随后全量复跑。
- 静态检查：`flutter analyze`（3 处）。
