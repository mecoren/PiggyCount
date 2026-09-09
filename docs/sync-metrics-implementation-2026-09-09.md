# 同步监控机制实施记录（审计 P0-1 / P1-3 / P1-6 落地）

- **实施日期**: 2026-09-09
- **对应问题**: `docs/s3-webdav-sync-audit-2026-09-08.md` §三 P0-1（同步成功率零测量）、P1-3（软失败无计数出口）、P1-6（槽位补删仅内存）；方案源头 `docs/sync-normalization-audit-2026-09-07.md` §五
- **回归验证**: `flutter analyze` 0 error / 0 warning（661 条 info 为既有基线）；全库 `flutter test test/` **1064 项全过**（含新增 sync_metrics_service 15 项、v43 迁移 2 项）；受影响包（icloud/supabase/s3/webdav）本轮未改动

---

## 一、v43 数据库迁移（db.dart schemaVersion 42 → 43）

| 表 | 用途 | 关键列 |
|---|---|---|
| `sync_op_log` | 同步操作结构化指标（P0-1 存储） | ts(默认当前时间, 建索引 idx_sync_op_log_ts) / backend / scenario / outcome / errorClass / ledgerId / attempts / durationMs |
| `stale_remote_slots` | 换名收尾补删登记（P1-6 持久化，主键 path） | path / createdAt |

onUpgrade（v42→v43：`migrator.createTable` 两表 + ts 索引）与 onCreate（新装库 `createAll` + 同款索引）双路径同构——对齐项目内 v32/v35/v39 的既有纪律。迁移冒烟测试 `test/data/migration_v43_sync_metrics_test.dart` 覆盖两条路径。

## 二、SyncMetricsService（新文件 lib/cloud/sync_metrics_service.dart）

- **场景枚举**（99.9% 分母口径）：snapshotUpload / snapshotRestore / startupCheck / attachmentFill / cloudBackup / remoteDiscovery，label 稳定落库；
- **结果四态**：success / failed / **soft_fail**（P1-3 核心：操作成功但数据未收敛，独立于 failed 可查）/ **conflict**（并发保护拦截，**不计入成功率分母**——它是三层防护正确工作的证据，算失败会把双设备正常并发误报为质量问题）；
- **成功率口径**：`success / (success + failed + soft_fail)`；窗口为空返回 null（UI 显示「暂无数据」而非 0%）；
- **API**：record（fire-and-forget 吞错）/ summarize（窗口 + 按后端分组聚合）/ topErrorClasses（Top 失败归因）/ cleanupExpired（30 天滚动清理）/ exportJson（诊断导出，仅结构化字段）/ classifyError（六类错误归因：precondition → auth → timeout → gateway → dataCorruption → unknown，全链路单点口径）；
- **隐私合规**（PRIVACY.md 零遥测承诺）：纯本地测量、不上云、不自动外发、不落用户内容（账本名/凭据/堆栈一概不进表）。

## 三、埋点接线（全部为纯旁路，metrics 未注入或落库失败均 no-op）

| 位置 | 场景 / 出口 |
|---|---|
| TSM `_uploadCurrentLedgerCore` | snapshotUpload 四态：M7 拦截 → conflict；条件写 412 → conflict；verified=false → **soft_fail**；成功 → success（含 duration/ledgerId）；其余异常 → failed（排除 CloudConflictException 重复计数） |
| TSM `drainAttachmentJobs` | attachmentFill 逐任务：ok → success(attempts=3)；objectMissing → **soft_fail**；transientFailure → failed(attempts=3) |
| TSM `_downloadAndRestoreToCurrentLedger` | snapshotRestore：成功 / 密钥缺失(failed,auth) / 密文损坏(failed,data_corruption) / 网关 404 兜底不计 / 真实失败 → failed |
| TSM `importRemoteLedger` | snapshotRestore：导入成功 → success（带 newLedgerId）；任意异常 → failed |
| TSM `discoverRemoteLedgers` | remoteDiscovery：整轮成功 / 失败 |
| CloudBackupService `createBackup` / `restoreBackup` | cloudBackup / snapshotRestore：备份成功失败；恢复整体成功、**单账本失败 → soft_fail**（保留 P1-3 的部分收敛语义）、整体失败 → failed；metricsBackend 由 provider 从激活配置注入分组键 |

Provider 装配（`sync_providers.dart` / `cloud_backup_providers.dart`）：`syncMetricsServiceProvider` 共享单实例注入 TSM 与备份服务，健康卡/诊断导出同源；上传成功后 `metrics.cleanupExpired()` 与 local_changes 清理同批（滚动窗口近零成本）。顺手清理了 PiggyCountCloud 下线遗留的孤儿 `_bootstrappingConfigs`（既有 unused 警告）。

## 四、UI：同步健康卡（新文件 lib/pages/cloud/sync_health_card.dart）

挂在云同步页（云端备份卡之后，`canUseCloud` 条件下）：

- 近 30 天成功率（≥99.9% verified 图标 / ≥99% check / ≥95% warning / 其余 error）+ 四态明细行（成功 · 失败 · 未收敛 · 并发拦截）；
- Top 3 失败错误类别（网络超时/认证/网关/并发/数据完整性/其他）；
- 「导出诊断数据」：30 天窗口 sync_op_log → JSON（schema:1，仅结构化字段）→ 系统分享面板，用户主动触发，唯一出机通道；
- l10n×3（zh/en/ko 各 8 词条，placeholder 元数据在模板 app_en.arb）。

## 五、P1-6 槽位补删持久化

- 登记（换名收尾删除失败）→ `stale_remote_slots` 表 + 内存 Set 双写，DB 是事实源；落库失败降级旧行为（仅内存，本会话内补删）；
- 装载（初始化成功后）→ 从表恢复到内存缓存再统一补删（reinit/dispose 只清内存缓存，DB 行跨重启存活）；
- 补删成功 → 双侧移除。修复场景：downloadRemoteLedger 换名中断 + 进程重启后，旧槽位不再被「云端账本发现」当新账本重复导入（2026-09-07 双端实测踩中的 12 账本重复问题根因之一）。

## 六、99.9% 目标的达成路径（与 2026-09-07 报告 §五一致，现状更新）

1. ✅ 测量口径落地：核心场景分母 + soft_fail 单列 + conflict 排除已实现；
2. ✅ 展示与导出：健康卡 + 诊断包（用户可主动反馈，替代遥测）；
3. ⏳ 基线建立：功能随版本发布后以 30 天窗口观察 real-world 成功率；
4. ⏳ 差距消除：P1-2 超时自适应（已于 2026-09-08 落地）与 P1-1 重试策略层（部分落地）是预判的 top 失败类，健康卡的 Top 错误类别将验证该判断；实验室侧弱网档压测（带宽受限维度）待补。

## 七、测试清单

| 文件 | 覆盖 |
|---|---|
| `test/cloud/sync_metrics_service_test.dart`（15 项） | 四态计数与成功率口径、conflict 不入分母、空窗口 null、按后端过滤、时间窗口过滤、30 天清理、导出结构化字段（无用户内容断言）、classifyError 六类、label 稳定性、attempts 归一、stale_remote_slots 幂等 |
| `test/data/migration_v43_sync_metrics_test.dart`（2 项） | v42→v43 onUpgrade 两表可用 + ts 索引；onCreate 新装路径 |
| 既有 1064 项全量回归 | cloud/backup/providers 287 + data 93 + 其余全过，零失败 |


---

## 八、第二批实施（同日：P1-5 完整性硬校验 + P1-1 条件 PUT 安全重试 + LOG-06）

### P1-5：下载内容完整性终审（破坏性恢复前的硬闸门）

**问题**：core `CloudSyncManager.download` 的 P4 校验因 App 层全部直连 `provider.storage.download` 是死代码；实际运行的对位物只有「metadata 交叉软告警」——CDN 陈旧副本/网关截断的脏快照可无声流入破坏性恢复。

**实现**（`lib/cloud/transactions_sync_manager.dart` 新增 `_verifyDownloadedSnapshotIntegrity`，接线三个破坏性入口：`downloadAndRestoreToCurrentLedger` / `downloadRemoteLedger` / `downloadAndPreview`）：

- 基准取**快照内嵌指纹**（'contentFingerprint'）而非 metadata——内嵌值与内容同生共死，不存在「算法迁移错位」误报（换基准后软告警时代的 M2 迁移窗口问题不复存在）；
- 内嵌指纹 = 内容重算指纹 → 放行；
- 不一致 → **单次重下自愈**（陈旧副本窗口），返回值采用重下的新内容；仍不一致 → **硬失败**（CloudStorageException，恢复中止）；
- 内容非 JSON → 硬失败；
- 旧快照（v6 前无内嵌指纹）→ 退回 metadata 软告警路径（迁移窗口兼容，维持 M4 既有取舍）。

**测试**（`test/cloud/sync_integrity_hard_verify_test.dart` 6 项，走公共入口端到端验证）：自洽放行 / 非 JSON 硬失败 / 重下自愈采用新内容 / 持续不一致硬失败 / 旧快照兼容不阻断 / 预览链路同口径。

### P1-1 切片：S3 条件 PUT 网络故障安全重试

**安全性论证**（核心）：带 If-Match 锚点时，「超时但服务端已落盘」的 A-1 歧态由锚点化解——远端 ETag 已变 → 重试吃 412 → 翻译为冲突流程（上层走用户确认/合并），**绝不静默覆盖他机数据**；未落盘则重试正常落盘。盲写路径维持不重试纪律（A-1 未修，写后校验兜底）。

**实现**（`packages/flutter_cloud_sync_s3/lib/src/s3_client.dart`）：putObject 的 SocketException/TimeoutException 分支——`(ifMatch != null || ifNoneMatch) && netRetries < 2` 时按既有 `retryDelayForTest` 指数退避重试（≤2 次），并修正超时消息使用 `transferTimeoutFor(data.length)`（自适应档）；盲写原样上抛。

**测试**（`packages/flutter_cloud_sync_s3/test/s3_conditional_retry_test.dart` 5 项）：网络故障一次后重试成功 / 已落盘场景重试吃 412 转冲突（安全性核心用例）/ 持续故障 1+2 次后上抛 / 盲写不重试纪律 / onRetryEvent 逐次留痕。

### LOG-06：重试逐次日志

- S3：`onRetryEvent` 回调（新增字段），`_retryIdempotent` 的网络/5xx/时钟偏差三分支与 putObject 条件重试逐次上报，`S3StorageService` 构造时注入 `logger.info`（重试属正常自愈，非告警）；
- WebDAV：`_retryIdempotent` 重试分支直接 `logger?.info`（带 HTTP 状态码与次数）。

### 顺手修正：WebDAV 既有测试与实现不一致

`webdav_validate_status_test.dart` 的「null 状态放行」断言在 `9ecf378`（09-08 修复批）有意反转 `webdavValidateStatus` 的 null 语义（放行 null 会让 `_statusCodeOf` 拿不到结构化码、错误分类退化到字符串匹配）时未同步更新——修正断言对齐实现，并在用例名中记录理由。

### 回归验证

- `flutter analyze` 全库：0 error / 0 warning；
- 全库 `flutter test test/`：**1070 项全部通过**（基线 1064 + 本批净增）；
- 包套件：S3 129 项全过（含新增 5 项）、WebDAV 59 项全过、test/cloud 242 项全过；
- 一次全库混跑中 `sync_integrity_hard_verify_test`「内容非 JSON」用例偶发失败，单跑与 test/cloud 连跑 3 轮 + 全库重跑均绿——确认为偶发 flaky（非确定性调度），如再现优先怀疑测试并发环境而非实现。

### 本批后剩余待办

- P1-1 尾巴：四套重试收编单一 RetryPolicy 策略层（S3 条件重试与逐次日志已就位，收编主要是参数集中与 TSM 附件重试迁移）；
- P1-4（Supabase/iCloud 能力显式化）、P2-1/2/3/4、SEC-03/06/08、LOG-04/05——方案均已定，按批次推进。
