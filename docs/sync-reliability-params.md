# 同步可靠性参数表（重试/超时/并发防护）

> 依据：docs/sync-normalization-audit-2026-09-07.md §四 N11/N12（4 套重试/5 处超时漂移）与 P2-6；
> 实施状态以 2026-09-09 为准，2026-09-11 归一化批次更新（Supabase/iCloud 补齐，见文末变更记录）。
> 本表是唯一权威口径，改参数必须同步此表。

## 一、超时分级

| 层 | 操作 | 值 | 出处 | 说明 |
|---|---|---|---|---|
| S3 | 元数据（HEAD/PROPFIND 级） | 30s | `s3_client.timeout` | 签名请求基础预算 |
| S3 | 对象传输（PUT/GET body） | **自适应**：`30s + 30s/MB`，上限 5min | `s3_client.transferTimeoutFor` | P1-2：350KB 快照弱网 117KB/s 下旧固定 30s 必超时 |
| S3 | 流式下载消费期 | 首字节 30s + 停滞检测（timeout×4） | `downloadStream(stallTimeout)` | 首字节可重试；消费期不整体超时 |
| WebDAV | 单次操作 | 60s | `webdav_storage_service._opTimeout` | CancelToken 主动取消（MOVE 除外，webdav_client 1.2.2 限制） |
| WebDAV | 初始化探测 | 60s | `webdav_provider._probeTimeout` | 同上取消语义 |
| Supabase | 单次操作 | 60s | `supabase_storage_service._opTimeout` | P0-3 补齐（SDK 未暴露底层配置） |
| iCloud | 常规 method channel | 30s | `icloud_method_channel._defaultTimeout` | |
| iCloud | 下载 | 90s | `icloud_method_channel._downloadTimeout` | |
| App | 启动检查单账本状态 | 20s | `startup_sync_checker._statusTimeout` | 超时按检查失败计，绝不当「已是最新」 |
| App | 启动检查 apply（下载/合并） | 90s | `startup_sync_checker._applyTimeout` | |
| App | 启动检查回传（merge-then-publish） | 5min | `startup_sync_checker._publishTimeout` | 慢速 S3+多附件专门调优 |
| App | 发现阶段单文件 | 10s 总预算 | `discoverRemoteLedgers mdDeadline` | 快路径失败不再落慢路径 |
| App | 附件下载单任务 | 后端超时 ×3 次内部重试 | `TSM._downloadAttachmentBinWithRetry` | 1s/2s/4s 退避无 jitter（会话内后台任务，无风暴风险） |

## 二、重试策略

| 实现 | 范围 | 参数 | 可重试判定 | jitter |
|---|---|---|---|---|
| S3 `_retry` | 幂等读（GET/HEAD/DELETE/LIST） | 3 次，1s/2s/4s | 网络异常 + 5xx（501 等确定性码经 neverRetryStatusCodes 立即上抛）+ 时钟偏差（补偿后立即重试） | 真随机 50%~100% 区间（P5） |
| S3 putObject 条件重试 | **仅带 If-Match/If-None-Match**（P1-1, 2026-09-09） | ≤2 次，复用同退避表 | SocketException/TimeoutException；安全性由锚点保证（已落盘则重试吃 412 转冲突） | 同上 |
| S3 putObject 盲写 | 无条件头 | **0 次**（不重试纪律） | —— | A-1 覆盖竞态未修，写后校验兜底 |
| WebDAV `_retryIdempotent` | read/readDir/remove 幂等读 | 2 次，400ms/800ms | 无结构化状态码（连接层）或 5xx；4xx 立即上抛 | 真随机（P1-1 修复，时间戳取模同相问题） |
| Supabase `_opRetryable`（2026-09-11 补齐） | download/downloadBinary/list/exists/getMetadata/delete 幂等操作 | 2 次，400ms/800ms（对齐 WebDAV） | 连接层故障（无状态码）/超时/5xx；认证与 404 确定性失败立即上抛；盲写不重试 | 真随机 ±50% |
| iCloud `_retryIdempotent`（2026-09-11 补齐） | download/downloadBinary/list/exists/getMetadata/delete | 2 次，400ms/800ms（对齐 WebDAV） | 非 NOT_FOUND 的 PlatformException 瞬时故障（daemon 未就绪）；NOT_FOUND 立即上抛转幂等语义 | 真随机 ±50% |
| TSM 附件下载 | 后台附件补齐 | 3 次总尝试，1s/2s/4s | 全异常（三态结果由调用方区分 objectMissing/transientFailure） | 无（内存队列会话级 drain，无多端风暴面） |
| core `RetryHelper` | （当前无生产调用方） | 预设三档 | 异常类型判定（auth/404 不重试） | 25% |

**设计纪律**（不可破坏）：
1. 非幂等写操作只在「失败保证未落盘」的前提下可重试（条件写锚点/服务器未处理请求的证据）；
2. 认证/404/501 类确定性失败不消耗重试预算；
3. 多端共享的重试路径必须有真随机 jitter（防 thundering herd）；
4. 重试逐次经 onRetryEvent/logger 留痕（LOG-06，2026-09-09 落地）。

## 三、并发防护三层（快照写路径）

1. **上传前探测**（`_detectUploadConflict`）：元数据指纹快路径 → 内嵌指纹终审 → 时间戳证据链方向仲裁；探测失败**中止上传**（不盲传）；
2. **条件写**：S3 If-Match 原子（412/404/409 翻译为 CloudPreconditionFailedException）；WebDAV eTag 预检近似（非原子，fail-closed）；**Supabase 读后比对近似（2026-09-11 补齐，updatedAt 锚点，非原子，对齐 WebDAV 取舍）**；iCloud 不支持 → 盲写+写后校验（UI 能力矩阵已标注，P1-4）；
3. **写后校验**（`verifyAfterUpload`）：指纹回读，不一致上浮 `CloudUploadResult.verified=false` → TSM 记 soft_fail 指标、不清脏标记，**返回值上浮 UI 差异化提示（P1-4 softFail 可见化，2026-09-11）**，下次 getStatus 走冲突/合并流程。

下载方向：P1-5 完整性硬校验（内嵌指纹终审 + 单次重下自愈 + 持续不一致硬失败），接于三个破坏性入口（恢复/云端账本导入/合并预览）。

## 四、已知非重试面（备案）

- WebDAV 写路径（tmp PUT → MOVE 原子发布）不自动重试——MOVE 不可取消 + 降级交换已内置无损回滚；
- iCloud 写路径不重试——method channel 原生侧行为不可探（P2-3 一并处理时评估）；
- Supabase 盲写（upsert 覆盖）不重试——非幂等；条件写路径的探测步进重试（2026-09-11）；
- core RetryHelper 为 example/预留设施，生产收编时以本表参数为基准。

## 五、变更记录

- **2026-09-11（第二批：监控收尾 + 判定加固）**：
  - P1-12：core `getStatus` 新增 `localUpdatedAtTrusted` 参数 —— 不可信墙钟（全部已推送/recordChanges:false 导入）不做时间戳方向断言，让位 count 兜底或 unknown；TSM `_localUpdatedAtTrusted` 透传（cloud_sync_manager.dart / transactions_sync_manager.dart）。
  - P2-6：`downloadRemoteLedger` 补 snapshotRestore 四态埋点（主路 success/对象缺失 softFail/空快照守卫 softFail/异常 failed）——批量恢复失败率进健康卡分母。
  - P2-7：指标清理兜底接线到 PiggyApp 启动（原 `syncMetricsCleanupProvider` 无消费者已删）。
  - P2-8：自动防抖上传失败轻反馈 —— TSM 新增 `onAutoSyncFailure` 回调（分层：TSM 不依赖 UI 框架），provider 接线刷状态卡（不弹 toast）。
  - P2-9：E2EE 元数据信封解密失败从 debugPrint 升级 logger.warning（release 可留痕）。
- **2026-09-11**（归一化批次，对照 docs/sync-comprehensive-audit-2026-09-10.md）：
  - Supabase：list/exists/getMetadata 改 listPaginated 游标翻页（P0-1，消除 SDK 默认 100 条静默截断）；补幂等读重试（P1-8）；补 ConditionalWriteStorage 读后比对近似（P1-1，updatedAt 锚点）；CloudFile.path 改相对路径口径（P1-1b）；_storeMetadata 失败上抛 MetadataPersistFailedException（P1-1c，幂等 upsert 重试 1 次后）；空目录 list 404 → 空列表（P1-9）。
  - iCloud：补 BinaryCapableStorage（P1-5，单次编码 + 原始字节落盘 + 旧 base64 文本嗅探）；补幂等读重试（P1-8）。
  - App 层：startupCheck 场景埋点补齐（P1-3，四态，backend=startup）；uploadCurrentLedger 返回 verified（P1-4 softFail UI 可见化）；备份恢复跨进程检查点 cloud_backup_restore_pending（P1-2，调度器让位 + 恢复入口提示）。

- **2026-09-11（第三批：性能）**：
  - P2-2①：`exportTransactionsJson` 返回类型 `String → ExportedLedgerJson`（jsonStr + fingerprint/count/balance/ledgerName/currency/monthStartDay 伴随字段，编码前旁路收集）——上传链路（`_uploadCurrentLedgerCore`/`_localFingerprintWithCache`/备份 ZIP 打包/序列化器）不再对同一几百 KB~MB 级 JSON 整串 jsonDecode 取 4 个元信息字段。
- **2026-09-11（第四批：性能）**：
  - P2-2③：快照 gzip 压缩传输——新增 `GzipCloudStorageService` 装饰器（lib/cloud/gzip_cloud_storage.dart），E2EE 开启时装配链 raw → Gzip → Encrypted（压明文、压后加密，与备份链路「ZIP→加密」同序）。阈值：≥2KB 且压缩比 ≤60% 才存压缩形态，否则原文；附件二进制/元数据/列举全部透传（gzip 层镜像实现 BinaryCapableStorage/ConditionalWriteStorage，附件真字节与条件写锚点不退化）。Latin-1（码点=字节）无损桥过文本通道。加密未开启不装配（历史明文永不压缩，旧版本可读性无回滚风险）。rekey/enableFromCloud 三入口均传 rawStorage（无 gzip 层）——全量重加密读写未压缩形态，不受影响（嗅探端透传非 gzip 字节）。重复 JSON 实测压缩率 ~10-15%，弱网流量/耗时同比例下降。
