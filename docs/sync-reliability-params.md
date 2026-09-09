# 同步可靠性参数表（重试/超时/并发防护）

> 依据：docs/sync-normalization-audit-2026-09-07.md §四 N11/N12（4 套重试/5 处超时漂移）与 P2-6；
> 实施状态以 2026-09-09 为准。本表是唯一权威口径，改参数必须同步此表。

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
| TSM 附件下载 | 后台附件补齐 | 3 次总尝试，1s/2s/4s | 全异常（三态结果由调用方区分 objectMissing/transientFailure） | 无（内存队列会话级 drain，无多端风暴面） |
| core `RetryHelper` | （当前无生产调用方） | 预设三档 | 异常类型判定（auth/404 不重试） | 25% |

**设计纪律**（不可破坏）：
1. 非幂等写操作只在「失败保证未落盘」的前提下可重试（条件写锚点/服务器未处理请求的证据）；
2. 认证/404/501 类确定性失败不消耗重试预算；
3. 多端共享的重试路径必须有真随机 jitter（防 thundering herd）；
4. 重试逐次经 onRetryEvent/logger 留痕（LOG-06，2026-09-09 落地）。

## 三、并发防护三层（快照写路径）

1. **上传前探测**（`_detectUploadConflict`）：元数据指纹快路径 → 内嵌指纹终审 → 时间戳证据链方向仲裁；探测失败**中止上传**（不盲传）；
2. **条件写**：S3 If-Match 原子（412/404/409 翻译为 CloudPreconditionFailedException）；WebDAV eTag 预检近似（非原子，fail-closed）；Supabase/iCloud 不支持 → 盲写+写后校验（UI 能力矩阵已标注，P1-4）；
3. **写后校验**（`verifyAfterUpload`）：指纹回读，不一致上浮 `CloudUploadResult.verified=false` → TSM 记 soft_fail 指标、不清脏标记，下次 getStatus 走冲突/合并流程。

下载方向：P1-5 完整性硬校验（内嵌指纹终审 + 单次重下自愈 + 持续不一致硬失败），接于三个破坏性入口（恢复/云端账本导入/合并预览）。

## 四、已知非重试面（备案）

- WebDAV 写路径（tmp PUT → MOVE 原子发布）不自动重试——MOVE 不可取消 + 降级交换已内置无损回滚；
- iCloud 写路径不重试——method channel 原生侧行为不可探（P2-3 一并处理时评估）；
- core RetryHelper 为 example/预留设施，生产收编时以本表参数为基准。
