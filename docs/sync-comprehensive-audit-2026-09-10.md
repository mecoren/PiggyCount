# PiggyCount 同步功能全面系统性排查报告

- **排查日期**：2026-09-10
- **修复状态**：2026-09-11 已实施两批 —— 第一批 **P0-1、P1-1（Supabase 条件写/元数据/path 口径）、P1-2、P1-3、P1-4、P1-5（iCloud）、P1-8、P1-9**（§八修复记录）；第二批 **P1-12、P2-6、P2-7、P2-8、P2-9**（监控收尾 + 方向判定加固 + 可观测化，见 §八补记）。其余 P1/P2 项维持排查结论原状，待后续批次。
- **排查方式**：静态代码审计（只读，**未修改任何代码**）
- **排查范围**：全部同步功能——S3 协议包、WebDAV 协议包、Supabase 协议包、iCloud 协议包、core 同步框架（flutter_cloud_sync）、App 层快照同步主链路（TransactionsSyncManager）、启动检查编排器、diff/指纹/变更追踪、云端备份调度、端到端加密装饰层、同步成功率监控机制
- **对照基线**：`docs/sync-normalization-audit-2026-09-07.md`、`docs/s3-webdav-sync-audit-2026-09-08.md`、`docs/sync-metrics-implementation-2026-09-09.md`、`docs/sync-reliability-params.md`

---

## 0. 摘要（TL;DR）

**总体结论：核心快照同步链路（S3/WebDAV 双主力后端）经多轮审计修复后质量较高，无 P0 级「无防护数据丢失/明文泄密」问题；但归一化在 Supabase 与 iCloud 两个后端上存在明显断层，且监控机制有一个场景级缺口。**

最需要处理的五件事：

| # | 问题 | 级别 | 一句话 |
|---|---|---|---|
| 1 | Supabase `list()` 未传翻页参数，SDK 默认 `limit:100` **静默截断** | **P0** | 第 101 个对象起 `exists()` 误判不存在 → 触发覆盖/重复上传，多账本+多附件用户在 Supabase 下发现/清理流程漏对象 |
| 2 | startupCheck 场景（每次冷启动、**最高频链路**）**零埋点**，不进 99.9% 分母 | P1 | 监控口径与「99.9% 目标」声明不符，启动链路质量完全不可观测 |
| 3 | softFail（写后校验不一致，数据在云端但未确认收敛）**无操作级用户提示**，UI 呈现为「上传成功」 | P1 | 99.9% 与 99% 之间的差距主体对用户不可见 |
| 4 | Supabase/iCloud **零重试、无条件写、Supabase 元数据非原子**三连 | P1 | 弱网下 Supabase 同步成功率系统性低于 S3/WebDAV，是归一化断层最集中的后端 |
| 5 | 备份恢复跨账本无原子性、崩溃无检查点 | P1 | 进程在恢复中途崩溃后，半恢复 DB 可能被定时备份打包**覆盖当日好备份** |

99.9% 目标评估：**当前机制（本机 `sync_op_log` 表 + 健康卡 + 诊断导出）设计合理且已覆盖 5/6 核心场景，但要达成 99.9% 并能证明之，需补齐 startupCheck 埋点、修复 Supabase P0/P1 缺陷、接线指标清理死代码**（详见第六章路径测算）。

---

## 0.5 补充核验（2026-09-10 收尾批）

排查覆盖面收尾时对两个此前仅浅读的 App 层模块做了逐行深读复核，结论：**无新增 P0/P1 问题，报告主体结论不变**。

- **sync_fingerprint.dart（343 行，全文精读）**：白名单式内容指纹实现质量高——所有数组（items/accounts/categories/tags/budgets/recurring/rateOverrides）均按「syncId 优先 + 业务键兜底 + 规范化串全序化平局处理」排序，跨设备输入顺序无关（历史修复 P3-1/全序化平局/审计 S11 附件参与指纹均已落地且论证充分）；`lastGeneratedDate` 刻意排除（本机生成进度非数据本体）与序列化携带不矛盾（导入侧 max 合并用）。无发现问题。
- **sync_diff_service.dart（811 行，全文精读）**：diff/合并链路已含关键防护——M1 空快照守卫（拒绝把全部本地交易误标 deleted）、M3 云→本地全程抑制 change 记录（withRecordingSuppressed，防合并回流触发重复上传）、H1 业务键唯一兜底配对（认领失败整条放弃不误写）、SYNC-05 deleted 默认不选中、合并范围对齐指纹 8 类实体（防「每次启动误弹云端有更新」）、added 批量 500 条/批（万条级账本导入从几十分钟降到秒级）。一处已在报告正文 P2-1 归类过的延伸观察：`_applySyncChangesInternal` 中「元数据合并（importCategories/Accounts/Tags/Recurrings/Budgets/RateOverrides + monthStartDay）」整体无事务包裹、失败计数仅日志——与备份恢复逐账本软失败（P1-2）同族，即「合并链路的元数据部分失败不回滚、不阻断交易合并」，属已知取舍（幂等 upsert 重跑自愈），不新增条目。

工作区核验：`git status` 仅新增本报告文件，**未修改任何代码**，符合「只做排查不改代码」的约束。

---

## 一、排查范围与方法

### 1.1 同步功能模块全景

```
App 层（lib/）
├─ cloud/transactions_sync_manager.dart   快照同步主实现（TSM，3774 行）
│   ├─ 上传/恢复/发现/换名收尾/附件对象同步
│   └─ 冲突仲裁（M7）+ 条件写锚点（方案C）+ 完整性终审（P1-5）
├─ cloud/transactions_json.dart          序列化（导出/导入 JSON，905 行）
├─ cloud/startup_sync_checker.dart       启动检查编排器（1407 行）+ overlay
├─ cloud/sync_diff_service.dart         diff 预览/合并（811 行）
├─ cloud/sync_fingerprint.dart           指纹算法（343 行）
├─ cloud/sync/change_tracker.dart        本地变更追踪（373 行）
├─ cloud/sync_metrics_service.dart       同步成功率本地监控（351 行）★监控机制
├─ cloud/sync_service.dart               SyncService 接口 + 冲突异常契约
├─ cloud/sync_restore_guard.dart         恢复临界区守卫
├─ cloud/provider_factory.dart          后端装配工厂（S3/WebDAV/Supabase/iCloud）
├─ cloud/backup/                         云端 ZIP 备份（服务+调度器+providers）
├─ data/encryption/                      E2EE 装饰层（EncryptedCloudProvider/Storage、
│                                         Argon2id、AES-256-GCM、rekey 检查点）
└─ providers/sync_providers.dart         Riverpod 装配/dispose 链/自动同步开关

协议实现层（packages/）
├─ flutter_cloud_sync/                   core：CloudSyncManager、接口、异常、
│   │                                    RetryHelper（生产零调用）、配置存储
│   └─ database_sync_manager/realtime    死代码（对 App 而言）
├─ flutter_cloud_sync_s3/                S3 自研客户端（SigV4，3005 行）
├─ flutter_cloud_sync_webdav/            WebDAV（webdav_client+dio，1504 行）
├─ flutter_cloud_sync_supabase/          Supabase（supabase_flutter 托管，1606 行）
└─ flutter_cloud_sync_icloud/            iCloud（method channel，616 行）
```

### 1.2 排查方法与证据可信度

- 三路并行深度审计（协议包对比 / core+备份+加密 / 接线+埋点+测试+文档），全部结论带 `文件:行号` 证据；
- 本报告中的 **P0 与关键 P1 结论均经人工复核源码确认**（Supabase list/exists/_classify、TSM 上传链路/冲突仲裁/完整性校验、健康卡 99.9% 阈值、启动检查超时档等）；
- 既有测试与历史审计文档作为对照（当前测试套 1000+ 项，见 `docs/sync-metrics-implementation-2026-09-09.md` §回归验证）。

---

## 二、同步功能全景：触发入口与数据处理链路

### 2.1 触发入口全景（核查结果）

上传路径 14 个入口全部收敛到 `uploadCurrentLedger` / `uploadCurrentLedgerDebounced` / `uploadAllLedgers`：

| 触发源 | 方法 | force | bypassRestoreGuard | 评价 |
|---|---|---|---|---|
| 手动上传（账本页/云同步页） | uploadCurrentLedger | false 首试，冲突后用户三选一可变 true | false | ✅ 冲突闸门完整 |
| 全量上传（双重确认） | 逐账本 upload | true（用户显式确认） | false | ✅ |
| 启动检查 merge-then-publish 回传 | uploadLedger | true | **true**（全库唯一豁免点，`startup_sync_checker.dart:1193-1198`） | ✅ 有安全论证（合并事务已提交）+ H6 云端指纹新鲜度校验 |
| downloadRemoteLedger 换名收尾 | 直调 `_uploadCurrentLedgerCore`（锁内） | true | 有意绕过（H3 备案：事务已提交） | ✅ 有备案 |
| 批量上传 uploadAllLedgers | 逐账本 upload | **false**（审计 A4 已修复，曾强制 true） | false | ✅ 冲突单独计数 |
| 自动记账后（PostProcessor 3 处） | debounced（2s 窗口+补跑） | false | false | ✅ 自动路径冲突静默跳过，交状态卡展示 |
| 导入完成/新建账本等 | debounced | false | — | ✅ |

恢复/备份/启动类入口 9 个（启动检查、云同步页下载/全量下载/备份恢复、账本页恢复所有远程、定时备份调度等），均见 `lib/app.dart`、`lib/pages/cloud/cloud_sync_page.dart`、`lib/pages/main/ledgers_page_new.dart`。

**结论：触发入口归一化良好**——所有入口收敛到 TSM 单点实现，`bypassRestoreGuard` 全库仅一处豁免且有注释论证，`force:true` 只出现在用户显式确认或合并事务已提交的路径。

### 2.2 数据处理链路（各后端共用，天然归一）

- **序列化**：统一走 `exportTransactionsJson`（`transactions_json.dart:48`），全账本快照 JSON（交易/账户/分类/标签/周期/预算/附件清单/汇率），白名单式内容指纹内嵌 `contentFingerprint` 键——**与内容同生共死**，是元数据丢失时的权威终审依据。
- **槽位命名**：统一 `ledger_<syncId>.json`（syncId 为就地生成并 TOCTOU 防并发回填的 UUID，`transactions_sync_manager.dart:696-734`），账本跨设备身份稳定，无撞槽风险。
- **附件**：内容寻址 `attachments/<sha256>.bin`，上传顺序协议（附件先于清单 JSON）、上传前批量 list 去重、恢复端 drain 补齐（3 次退避）。
- **指纹三层**：① 内嵌 `contentFingerprint`（终审）→ ② 对象元数据 `fingerprint`（快路径）→ ③ WebDAV legacy sidecar 回退。
- **E2EE**：`EncryptedCloudProvider` 装饰 storage 全方法（upload/uploadBinary/条件写/download/downloadBinary/getMetadata），密文 `BEECRYPT1:` 格式，AES-256-GCM（MAC 即完整性），Argon2id（t=3,m=64MB,p=2）派生密钥，salt 随密文明文存放（设计如此，多设备凭密码可解）；改密有检查点+回滚（S24）。
- **压缩**：仅备份链路有（先 ZIP 后加密，顺序正确）；**主快照同步无压缩**（见性能章节）。

---

## 三、归一化排查结论

### 3.1 数据处理逻辑：主体归一，元数据与二进制路径有断层

**已归一**：序列化、槽位、指纹、附件协议、加密装饰均单点实现（TSM/core 层），四协议共用同一业务数据处理逻辑——这是「接口在 core、实现在协议包」分层的正确结果。

**断层 1：元数据（指纹/count）写入的原子性分四级**（直接影响 getStatus 快路径与冲突判定可靠性）：

| 后端 | 机制 | 原子性 | 证据 |
|---|---|---|---|
| S3 | `x-amz-meta-*` 对象元数据 | **原子**（随 PUT 同请求） | s3_client.dart:708-713 |
| WebDAV | `pc-wdav-env-v1` 信封内嵌 | **原子**（单文件） | webdav_storage_service.dart:128-176 |
| Supabase | `file_metadata` DB sidecar 表 | **非原子**（主对象上传后第二次写，失败仅 warning 静默降级） | supabase_storage_service.dart:420-437 |
| iCloud | 原生 customMetadata | 原生决定（黑盒） | icloud_storage_service.dart:77-81 |

后果：Supabase 下元数据写失败 → 指纹永久缺失 → `getStatus` 反复退化为全量下载（流量放大）+ `_detectUploadConflict` 走内嵌指纹终审（多一次全量下载）。

**断层 2：附件/二进制路径**（core 框架的 `CloudStorageBinaryExt.uploadBinaryOrFallback` 分派，storage_service.dart:237-266）：
- S3/WebDAV/Supabase 实现 `BinaryCapableStorage` → 真字节；
- **iCloud 未实现** → base64 文本兜底，且 `icloud_storage_service.dart:74-75` 内部再 `base64Encode(utf8.encode(...))` 一次 → **双重编码**，有效带宽约 2.2×；
- E2EE 开启时统一收敛为「base64 封文本信封再加密」（设计如此，四协议一致）。

**断层 3：list 条目元数据口径**：WebDAV/S3 的 `list()` 条目不带 metadata（发现流程对每文件补 getMetadata），Supabase 带 `file.metadata`——同一发现流程在不同后端请求数不同（Supabase 还受 P0 截断影响）。

### 3.2 同步策略：冲突防护分层明显不均

**归一的部分**：
- 冲突仲裁（M7，`_detectUploadConflict`，transactions_sync_manager.dart:2381-2474）四协议统一：元数据指纹快路径 → 内嵌指纹终审 → 只信「未推送 local_changes 行」佐证的墙钟方向仲裁 → 探测失败**中止上传**（A5 策略，宁可重试不可盲传）。
- 批量上传 A4 修复后不再强制覆盖，conflicts 单独计数。
- 同账本「上传↔恢复」经 `_ledgerOpsLocks` FIFO 互斥（TSM-P8）。

**不均的部分——并发防护三层（探测/条件写/写后校验）在各后端的实际形态**：

| 后端 | 条件写 | 实质 | 证据 |
|---|---|---|---|
| S3 | **原子 If-Match/If-None-Match** | 412/404/409 全谱翻译为 `CloudPreconditionFailedException`；网关 400+NotImplemented 时记忆能力后**静默降级盲写**+写后校验，降级有日志 | s3_client.dart:277-396、690-720 |
| WebDAV | **读后比对近似（非原子）** | 先 PROPFIND 读 eTag 比对再普通 upload——「比对→落盘」窗口内他机写入仍会被覆盖；fail-closed（eTag 未知时拒写） | webdav_storage_service.dart:302-341 |
| Supabase | **缺失** | `upsert:true` 盲覆盖（supabase_storage_service.dart:101-104），仅靠写后校验**事后**发现 | — |
| iCloud | **缺失** | 直接覆盖 | — |

即：**「双设备并发使用」场景下数据安全性 S3 ≈ 完整防护 > WebDAV ≈ 收窄窗口 > Supabase/iCloud = 事后才知道**。softFail（verified=false）在 Supabase/iCloud 的发生概率结构性高于 S3。

**list() 语义差异（含本次排查最高危问题）**：
- 递归深度：S3 递归扁平 vs WebDAV/Supabase 仅直接子项（已文档化，宿主已适配二次列举 attachments 目录）；
- 分页：S3 完整分页（V2/V1+三重护栏）vs **Supabase 无翻页且 SDK 默认 limit:100 静默截断（P0，详见第五章）** vs WebDAV 单次 PROPFIND 无截断检测；
- `CloudFile.path` 口径：S3/WebDAV 可回传，**Supabase 带 `users/{uid}/` 用户前缀不可直接回传**（supabase_storage_service.dart:289，回传会双前缀）——宿主绕开方式是普遍取 basename，但契约分裂仍在。

### 3.3 错误处理机制：异常体系统一、超时/重试策略四分五裂

**异常体系（归一良好）**：单根 `CloudSyncException`，401/403→`CloudAuthException`、412→`CloudPreconditionFailedException`、404→null 幂等语义，S3/WebDAV/Supabase 三包映射规范；core manager 把非 Cloud 异常统一包 `CloudStorageException`。两点注意：
- `CloudPreconditionFailedException` 与 `CloudStorageException` 是**兄弟类**——catch 存储异常不会捕获它（当前各处刻意如此，防被当可重试故障，但属隐性契约，新代码易踩）；
- iCloud 是唯一无结构化错误分类的包（认证失败也包成 `CloudStorageException`）；WebDAV/iCloud 的 auth 服务对不支持方法抛 `UnsupportedError`（Error 而非 Exception，可穿透常规 catch）。

**超时档位（不统一，共 7 档）**：

| 层 | 值 |
|---|---|
| S3 | 元数据 30s；对象传输自适应 30s+30s/MB、5min 封顶；流式下载首响应 30s+停滞检测 |
| WebDAV | 统一 60s（CancelToken 主动取消，MOVE 除外——webdav_client 1.2.2 限制） |
| Supabase | 统一 60s（仅 `.timeout` 包装，**不取消**底层请求） |
| iCloud | 30s/90s 双档 |
| App 启动检查 | 状态 20s / apply 90s / 回传 5min（startup_sync_checker.dart:271-286） |

S3 的体积自适应超时是弱网实测调优成果（`sync-reliability-params.md`），WebDAV 60s 固定档对大附件上传偏紧；**S3/Supabase/iCloud 超时后请求仍在飞**（仅 WebDAV 取消）——超时后 PUT 后台完成可能与下一次条件写产生竞态（有 412 锚点防护，但 Supabase/iCloud 无锚点）。

**重试策略（四种互不相同）**：

| 实现 | 范围 | 参数 |
|---|---|---|
| S3 `_retry` | 幂等读 3 次（1s/2s/4s + 50%~100% jitter）；条件 PUT 安全重试 ≤2；盲写 0 | s3_client.dart:134-191 |
| WebDAV `_retryIdempotent` | 幂等读 2 次（400ms/800ms ±50% jitter） | webdav_storage_service.dart:193-217 |
| **Supabase** | **零重试**（`_op` 仅超时包装） | supabase_storage_service.dart:69-75 |
| **iCloud** | **零重试** | — |
| core `RetryHelper` | **生产零调用**（仅 example 使用）；判定矩阵不含裸 SocketException/TimeoutException/5xx | retry_helper.dart:191-236 |

后果：同一弱网抖动，S3 可自愈 3 次、WebDAV 2 次、Supabase/iCloud 直接失败进指标——**Supabase/iCloud 的 network_timeout 失败率会系统性偏高，直接拖累 99.9% 目标**。重试纪律本身（非幂等写仅在「保证未落盘」前提下重试、确定性失败不耗预算、多端路径必须真随机 jitter）在 `sync-reliability-params.md` 有权威口径且 S3/WebDAV 遵守，但无统一执行点。

**错误恢复/中断恢复**：
- 上传侧：写后校验 verified=false → 不清脏标记、走 softFail（正确）；改密有检查点跨进程恢复（S24，R1 接线在 `ensureInitialized`）；stale_remote_slots 表跨重启补删旧槽位（P1-6）。
- 恢复侧：下载完整性硬闸门（内嵌指纹终审+一次重下自愈+持续不一致硬失败，P1-5）接于三个破坏性入口；恢复临界区 `SyncRestoreGuard` 阻止恢复中上传——但它是**内存态**，进程崩溃即失守（见 P1-2 备份章节）。
- 附件：内存队列 `_pendingAttachmentJobs` 进程重启即丢，但初始化时全量重扫 DB 缺文件自愈（A2 修复，`_ensureInitialized` 内 enqueueAllMissingAttachmentJobs）。

---

## 四、监控机制现状与 99.9% 目标差距

### 4.1 现有机制（设计良好）

- **数据面**：`sync_op_log` 表（v43，30 天滚动窗口，`ts` 索引），字段 backend/scenario/outcome/errorClass/ledgerId/attempts/durationMs——纯结构化，无用户内容，符合 PRIVACY.md 零遥测承诺。
- **口径**：`successRate = success / (success + failed + softFail)`，**conflict（412/M7 拦截）不入分母**（并发保护正确工作 ≠ 失败）——口径定义清晰合理（sync_metrics_service.dart:49-53, 141-149）。
- **四态模型**：success / failed / **softFail**（报成功但未收敛：verified=false、objectMissing、指纹自检不一致——99.9% 与 99% 的差距主体）/ conflict。
- **错误归因**：`classifyError` 六类（precondition/auth/timeout/gateway/corruption/unknown），Top 失败类别聚合。
- **展示**：健康卡（sync_health_card.dart:113-119）**已有 99.9%/99%/95% 三档图标阈值**（≥99.9% verified ✅），四态明细行 + Top 错误 + 诊断导出（用户主动分享，唯一出机通道）。
- **失败安全**：指标记录 fire-and-forget，落库失败只记 warning，绝不阻断同步主流程。

### 4.2 六场景埋点覆盖核查（亲验 + 全量 grep）

| 场景 | 埋点 | 位置 |
|---|---|---|
| snapshotUpload | ✅ 四态完整（conflict/softFail/success/failed，CloudConflictException 防重复计数） | TSM:1003/1090/1112/1115/1182 |
| snapshotRestore | ✅（恢复/云端导入/备份恢复单账本，失败→softFail） | TSM:1839-1883/3516-3598；cloud_backup_service.dart:388-406 |
| **startupCheck** | ❌ **零埋点**（枚举定义了但 `StartupSyncChecker` 全程不 record，实施文档接线表也漏了该行） | 全 lib/ 仅 sync_metrics_service.dart:20,37 与 db.dart:293 出现该词 |
| attachmentFill | ✅ 三态（ok/objectMissing/transient，attempts 透传） | TSM:1551-1560（drainAttachmentJobs 内） |
| cloudBackup | ✅（CloudBackupService **内部**埋点，metrics 经 provider 注入） | cloud_backup_service.dart:90-103/216/224 |
| remoteDiscovery | ✅（TSM.discoverRemoteLedgers 内部——启动页/云同步页/remoteLedgersProvider 三条发现路径全覆盖） | TSM:3357/3495 |

### 4.3 差距结论

1. **口径缺口**：startupCheck 不进分母 → 健康卡显示的「99.9%」实际只覆盖 5/6 场景。启动检查是每次冷启动必经链路，其失败/超时/取消完全不可观测——恰是用户感知最强的链路（overlay 卡死、重复弹「云端有更新」都发生在这里）。
2. **归因能力**：errorClass 六类够用，但 duration 只在 snapshotUpload 场景普遍记录，startupCheck/diff 等长链路无耗时分布 → 无法定位「启动检查慢在哪一段」。
3. **清理链路死代码**：`syncMetricsCleanupProvider`（sync_providers.dart:185-188）**全 lib 无消费者**——当前主清理依赖 TSM 上传成功路径（TSM:1168 `metrics?.cleanupExpired()`），对「长期只恢复不写入」的设备，30 天窗口外旧行永不清理（有索引，无大碍，但属接线遗漏）。
4. **软失败可见性**：softFail 只在 30 天聚合可见，单次操作无提示（见 P1-4）。
5. **达成 99.9% 的量化路径**（测算，非承诺）：
   - 分母现状：snapshotUpload + snapshotRestore + attachmentFill + cloudBackup + remoteDiscovery；
   - 当前结构性失败源：① Supabase/iCloud 零重试 → network_timeout 类失败（修复 3.3 节重试缺口可消除大部分）；② Supabase 元数据非原子 → softFail/全量下载退化（修复元数据原子性）；③ Supabase list 截断 → exists 误判连锁（P0 修复）；④ WebDAV 条件写窗口 → 偶发 verified=false softFail；
   - 分子扩容：补 startupCheck 埋点后，启动链路每次成功冷启动贡献一次 success 记录，日常使用下样本量最大的场景将主导成功率——**这既是机遇（快速逼近 99.9%）也是风险（启动失败一票即拉低）**，必须先修复启动链路的超时档与重试再纳入统计。

---

## 五、问题清单（分级，含证据）

### P0（1 项）

**P0-1 Supabase `list()` SDK 默认 limit:100 静默截断**
- 证据：`supabase_storage_service.dart:282-283` 调用 `_client.storage.from(bucket).list(path: fullPath)` 未传 `SearchOptions`；storage_client 2.8.0 默认 `limit: 100, offset: 0`；`:310-341` 的 `exists()` 也是「父目录 list 后 any() 匹配」实现；`:344-380` 的 `getMetadata()` 同样依赖该 list。
- 影响：目录超 100 对象后——① `exists()` 对第 101+ 个文件误判不存在 → 附件上传跳过逻辑失效/重复上传；② `getMetadata()` 返回 null → 冲突探测退化（内嵌指纹终审多一次全量下载）；③ `discoverRemoteLedgers` 漏发现账本；④ backup 列表漏项。多账本（每账本一个 JSON）+ 附件（每附件一对象）用户极易超过 100。
- 注意：`list()` 的 `CloudFile.path` 还带 `users/{uid}/` 前缀（:289），与 S3/WebDAV 口径分裂。

### P1（12 项）

| # | 问题 | 一句话影响 | 证据 |
|---|---|---|---|
| P1-1 | Supabase/iCloud 无条件写 + Supabase 元数据非原子 | 双设备并发覆盖静默丢失仅事后发现；Supabase 指纹缺失→全量下载退化 | supabase_storage_service.dart:101-104, 420-437 |
| P1-2 | 备份恢复跨账本软失败无原子性、崩溃无检查点 | 半恢复 DB 可能被定时备份打包覆盖当日好备份 | cloud_backup_service.dart:368-371, 280/410 |
| P1-3 | startupCheck 零埋点 | 最高频链路不进成功率分母，监控口径不符 99.9% 声明 | 见 §4.2 |
| P1-4 | softFail 无操作级用户反馈 | verified=false 时 UI 弹「上传成功」，脏标记未清用户不知 | TSM:1103-1113；ledgers_page_new.dart:1247-1251 |
| P1-5 | iCloud 无 BinaryCapableStorage + 双重 base64 | 附件/ZIP 备份带宽 ~2.2×，弱网超时概率放大 | icloud_storage_service.dart:74-75；storage_service.dart:237-266 |
| P1-6 | WebDAV 条件写非原子 | 比对→落盘窗口内并发写入仍被覆盖（已收窄未消除，代码自认） | webdav_storage_service.dart:315-340 |
| P1-7 | WebDAV 大目录 PROPFIND 无分页/截断检测 | 服务器截断时拿到不完整列表，静默 | webdav_storage_service.dart:595-596 |
| P1-8 | Supabase/iCloud 零重试 | 弱网抖动直接失败进指标，系统性拖累成功率 | supabase_storage_service.dart:69-75 |
| P1-9 | Supabase 空目录 list 404 上抛（其他三包收敛为 []） | 目录不存在被当存储故障，宿主被迫 catch 吞错 | supabase_storage_service.dart:297-298 vs webdav:627-634 |
| P1-10 | S3/Supabase/iCloud 超时不取消底层请求 | 超时后 PUT 后台完成，与后续操作竞态 | 对比 webdav_storage_service.dart:229-237 |
| P1-11 | UI/providers 层零自动化测试 | 冲突三选一/健康卡/注入/dispose 链全靠人工回归 | test/ 全目录 grep 无 widget/provider 测试 |
| P1-12 | core getStatus 方向判定用裸墙钟时间戳 | 跨设备时钟偏移致 UI 状态误判（上传路径已有证据门禁，此处未对齐） | cloud_sync_manager.dart:602-613 |

### P2（16 项，归一化/性能/维护性）

| # | 问题 | 证据/说明 |
|---|---|---|
| P2-1 | RetryHelper 生产零调用，判定矩阵不含裸网络异常/5xx；S3 与 WebDAV 重试参数各自为政 | retry_helper.dart:191-236；仅 example 使用 |
| P2-2 | 全量导出+指纹计算+jsonDecode/jsonEncode 在主 isolate；快照同步无压缩（gzip） | transactions_json.dart:48-464；TSM:974-979 两次处理同一大 JSON |
| P2-3 | list 条目 metadata 口径不一（S3/WebDAV 不带、Supabase 带） | s3_storage_service.dart:456-461 vs supabase:294 |
| P2-4 | exists() 网络成本数量级差异（S3 单 HEAD；WebDAV/Supabase 父目录全量列举） | webdav:644-673；supabase:310-341 |
| P2-5 | CloudFile.path 跨包回传口径分裂（Supabase 带用户前缀不可回传） | supabase_storage_service.dart:289, 312-319 |
| P2-6 | downloadRemoteLedger 恢复单元无独立埋点（三调用方失败率不可观测） | TSM:2836 |
| P2-7 | syncMetricsCleanupProvider 死代码 | sync_providers.dart:185-188 无消费者 |
| P2-8 | 自动防抖上传失败全静默（仅日志，无状态刷新/提示） | TSM:228-230 |
| P2-9 | E2EE 元数据信封解密失败静默降级（每次 getStatus 全量下载，release 仅 debugPrint） | encrypted_cloud_storage.dart:96-103 |
| P2-10 | DatabaseSyncManager/RealtimeService/CloudDatabaseService/SupabaseDatabaseService 死代码仍导出；SupabaseProvider 无谓实例化 realtime 服务 | 全 lib 零引用（grep）；supabase_provider.dart:137,149 |
| P2-11 | 认证异常 UnsupportedError vs CloudAuthException 分裂；iCloud 无认证异常分类 | webdav_auth_service.dart:56-75；icloud_storage_service.dart:83 |
| P2-12 | 静态 logger 注入口三名（downgradeLogger/storageLogger×2）；SupabaseProvider 静态可变状态 | provider_factory.dart:42,75,126 |
| P2-13 | WebDAV 统一 60s 超时对大附件偏紧（S3 有 30s+30s/MB 自适应） | sync-reliability-params.md §一 |
| P2-14 | S3 流式上传/下载能力已建未接入业务大文件路径（附件仍 readAsBytes→uploadBinary） | TSM:1389-1391 |
| P2-15 | 备份 ZIP 无对象元数据，listBackups 靠文件名正则 | cloud_backup_service.dart:211-212, 249-259 |
| P2-16 | 杂项：config fromJson 未知 type 静默回退 local 无痕迹；docs 两份仅分隔符不同的同名审计文件；cloud_mode_providers 恒 local 历史壳 | cloud_service_config.dart:128-134 |

**未发现的问题类别（正面确认）**：凭据明文存储（实际走 flutter_secure_storage+硬失败语义）、绕过加密的用户数据旁路（rawStorage 四个调用点均为密钥管理必需）、批量上传强制覆盖（A4 已修）、上传冲突探测失败盲传（A5 已改中止）、恢复中上传半恢复态（TSM-P8 锁+guard）、附件 NULL 锚点漏传（T9 已修）、旧槽位残留误导入（P1-6 表已修）。

---

## 六、详细优化方案（按问题逐条，供后续实施排期）

> 排查任务不修改代码，以下为可直接执行的方案设计。每条含：方案 → 步骤 → 验收标准 → 风险。

### 6.1 阶段一：直接守护 99.9% 目标（P0 + 监控缺口）

**方案 1（P0-1）Supabase list 翻页修复 + path 口径修正**
- 方案：`list()` 传入 `SearchOptions(limit: 100, offset: …)` 循环翻页直到返回数 < limit（或加显式上限如 1000 防御异常目录）；`exists()`/`getMetadata()` 改为 SDK 单对象信息查询（如可用）或翻页 list；`CloudFile.path` 改为**剥除用户前缀后的相对路径**（与 S3/WebDAV 对齐：name=basename、path=相对路径），`_buildUserPath` 负责重新加前缀。
- 验收：单测构造 >100 对象目录，list 全量返回、exists 第 101+ 个返回 true；`CloudFile.path` 直接回传 delete/exists 幂等。
- 风险：翻页增加请求数（>100 对象时 2+ 次调用）；需确认 storage_client SearchOptions 版本兼容。

**方案 2（P1-3）startupCheck 埋点补齐**
- 方案：`StartupSyncCheckerDeps` 注入 metrics（沿用 TSM 的旁路注入模式，null 全 no-op）；`runIfNeeded` 整轮出口记一条 startupCheck（success/failed，failedLedgers 数量>0 或顶层异常为 failed；用户主动 skip 不算失败也不算成功——建议单独决策：skip 不入分母）；可选加 durationMs（启动检查是长链路，耗时分布有诊断价值）。
- 验收：单测断言整轮结束写表；健康卡分母场景齐全；实施文档接线表补行。
- 风险：无（埋点旁路设计已验证安全）。

**方案 3（P1-4）softFail 操作级用户反馈**
- 方案：`uploadCurrentLedger` 的 verified=false 分支上抛轻量事件（或返回结构化结果），UI 把「上传完成」提示改为「已上传但未能确认收敛，下次同步时将自动比对」；云同步页/账本页两处 toast 接线；健康卡已有聚合不动。
- 验收：widget 测试覆盖提示文案；softFail 场景（mock 写后校验不一致）走 UI 出现差异化提示。
- 风险：提示文案需避免引发用户恐慌（数据已在云端，非丢失）。

**方案 4（P1-8/P1-9）Supabase/iCloud 重试对齐 + Supabase 空目录收敛**
- 方案：Supabase `_op` 增加幂等读重试（download/list/getMetadata/exists：2-3 次指数退避+jitter，对齐 WebDAV 参数表；上传不重试——非幂等）；iCloud method channel 读操作同款；`_classify` 前置把空目录 404 判定收敛为 list 返回 []。参数以 `sync-reliability-params.md` 为唯一口径更新（该文档自述「改参数必须同步此表」）。
- 验收：单测模拟连续 2 次 5xx/超时后成功，操作成功且 attempts=3；空目录 list 返回 [] 不抛。
- 风险：jitter 必须真随机（WebDAV 曾因时间戳取模同相翻车，P1-1 已修，复用其实现）。

**方案 5（P1-1 部分）Supabase 元数据原子性加固**
- 方案（按可行性排序）：① 上传时把指纹等关键元数据**同时内嵌进对象内容**（快照已有 contentFingerprint——补齐点其实在「发现/状态快路径」对元数据的依赖）；② `_storeMetadata` 失败从静默 warning 升级为**计入返回结果**（上传结果标记 metadataPersisted=false），让上层可把该次上传记 softFail 而非 success；③ 重试 `_storeMetadata`（幂等 upsert，可安全 2 次）。
- 验收：DB 表写失败场景（mock）→ 上传结果 softFail + 下次 getStatus 不反复全量下载（修复后元数据补写）。
- 风险：Supabase Storage 无对象级自定义元数据的原子写能力（FileOptions 无 metadata 原生持久化——需确认 2.8.0 metadata 选项实际落地形态，方案②不依赖该能力）。

### 6.2 阶段二：数据一致性纵深

**方案 6（P1-2）备份恢复检查点 + 半恢复态防护**
- 方案：① 恢复开始前在本地 DB 写「恢复进行中」标记（ledgerId 级或批次级，随事务落盘而非内存）；② 启动/定时备份触发时检查该标记——存在则跳过本日自动备份（保留手动）并在 UI 提示「上次恢复未完成，建议重跑」；③ 恢复全部完成清除标记。替代/增强 `SyncRestoreGuard` 的进程内存语义。
- 验收：测试模拟恢复中途 kill 进程 → 重启后定时备份不触发、用户见到提示；重跑恢复后标记清除。
- 风险：标记表需纳入 v44 迁移；重跑恢复的幂等性已具备（覆盖语义），无需回滚逻辑。

**方案 7（P1-7）WebDAV list 截断检测**
- 方案：单次 PROPFIND 后无截断信号可判——务实做法是给 `list()` 结果加上限守护（如返回条目数 ≥ 某阈值时 log warning 提示可能截断）+ 文档化各 WebDAV 服务器行为；有条件的 PROPFIND 请求可加 `Depth: 1, Propfind` 分页（多数服务器不支持，属尽力而为）。
- 验收：warning 有测试；宿主发现流程对超阈目录行为可观测。
- 风险：低（观测性增强，不改语义）。

**方案 8（P1-10）超时取消能力对齐**
- 方案：S3 换用可取消的 HTTP 调用形态（package:http 的 Client 不支持 token 取消——需要 http 包升级或自管 HttpClient+取消句柄；成本高可先做 P2 观测）；Supabase SDK 不暴露底层 client，**短期不可行**，建议文档化为已知限制。优先级实际上低于其他项，主要价值是消除「超时后 PUT 后台完成」的竞态解释成本。
- 验收：S3 侧超时用例断言连接被主动关闭（难验证，可用日志回调确认）。
- 风险：重构 S3 网络层动 SigV4 签名链路，回归成本大——建议列入 backlog 而非近期。

**方案 9（P1-12）getStatus 时间戳判定加固**
- 方案：core manager 的方向判定复用 TSM `_localChangeEvidence` 的「未推送行佐证」思想——local_changes 无未推送行时方向输出 unknown 而非按墙钟；或把方向判定整体上提到 App 层（core 只报指纹异同）。改动小、与上传路径口径对齐。
- 验收：core manager 单测加「时钟偏移场景」——两设备时间差大时不再误判 localNewer/cloudNewer。
- 风险：TSM getStatus 缓存语义需同步回归。

**方案 10（P2-9）E2EE 元数据解密失败可观测化**
- 方案：解密失败降级路径从 debugPrint 升级为注入 logger warning（加密包已有 logger 注入模式可复用）+ 降级结果计入该次 getStatus 的软信号（不上抛，保持兼容旧密文场景）。
- 验收：warning 进应用日志管线；单测覆盖降级路径。
- 风险：无。

### 6.3 阶段三：归一化治理与性能

**方案 11（P2-1/P2-12）重试与超时统一治理**
- 方案：把「重试纪律」从文档口径变为代码强制——两条路线二选一：A. RetryHelper 收编为四包公共实现（补 SocketException/TimeoutException/5xx 判定，各包 `_op` 统一接入，参数从 `sync-reliability-params.md` 单点常量读取）；B. 保留各包私有实现，但抽公共 `RetryPolicy` 常量包（参数集中定义）。推荐 B（改动小，S3 的条件写安全重试逻辑难以通用化）。同时统一静态 logger 注入口命名。
- 验收：参数表与代码常量一一对应（可用单测断言常量等于文档值）；新包接入只读常量不抄数字。
- 风险：参数统一可能改变 S3/WebDAV 现有已实测调优的行为——保持「各包语义参数从公共常量取、能力位差异保留」。

**方案 12（P2-2）序列化性能优化**
- 方案：① `exportTransactionsJson` 的 map 构建与 `jsonEncode` 移入 `compute` isolate（导出函数已无 DB 依赖段可拆：先取原始行再 isolate 组装+编码——parseSnapshotIsolate 已有先例，transactions_json.dart:522）；② TSM 上传路径消除二次处理——`jsonDecode(exportedJson)` 仅为取 fingerprint/count，改为导出时返回结构化产物（JSON 串+指纹+count 三元组，`rememberLocalFingerprint` 已有同类形态可对齐）；③ 快照 gzip 压缩（S3/WebDAV/Supabase 均支持 content-encoding 或直接压字节；JSON 压缩率典型 5-10×，弱网收益直接）。
- 验收：1 万条交易账本导出主 isolate 无卡帧（devtools timeline）；压缩后端到端往返一致（指纹对明文算，需确认压缩不破坏指纹链路——建议指纹在压缩前算、解压后验）。
- 风险：③ 动指纹校验链路（内嵌指纹在明文 JSON 内、传输的是压缩字节——天然兼容）；E2EE 信封顺序需「压缩→加密」重排验证。

**方案 13（P2-3/P2-4/P2-5）存储接口语义契约收紧**
- 方案：core `CloudStorageService` 接口注释升级为**契约文档**（name=basename、path=相对路径可回传、list 带不带 metadata、exists 成本分级、空目录返回 []），各包实现按契约回归；Supabase path 前缀问题随方案 1 一并修；宿主「basename 绕开」的防御性代码在契约成立后可简化（另开 cleanup 任务）。
- 验收：四包共用一组契约单测（core 包 test 挂 abstract 套件，各包跑同一断言集）——这是归一化的「防回归闸门」。
- 风险：低。

**方案 14（P2-6/P2-7/P2-8）监控收尾**
- `downloadRemoteLedger` 出口埋点（snapshotRestore 场景，与三个调用方现有返回值统计互补）；`syncMetricsCleanupProvider` 接线到 app 启动一次性 `cleanupExpired()`（或直接删除，由 TSM 路径+启动接线双保险）；自动上传失败在状态卡给出轻提示（下次 getStatus 刷新时机即可，不需新 UI）。

**方案 15（P1-11）测试补齐（UI/providers 层）**
- 优先级排序：① 冲突三选一对话框（upload_conflict_helper）——数据安全相关交互；② syncServiceProvider 重建 dispose 链（metrics 注入断言、F5 连接池释放）；③ 健康卡阈值渲染（99.9/99/95 档）；④ 加密恢复流（enableFromCloud 引导）。另外补六场景「埋点接线」断言测试（当前 metrics 测试只测服务本身，不测业务模块确实调用了埋点——三处代理审计均确认此缺口）。

**方案 16（P2-10/P2-16）死代码与文档清理**
- `DatabaseSyncManager`/`RealtimeService`/`CloudDatabaseService` 从 core 导出面收缩或标注 `@experimental`（独立包对外发布需权衡——建议保留实现、移出 App 使用的 barrel 导出、README 注明「记录级同步未在 PiggyCount 启用」）；SupabaseProvider 去掉 realtime 实例化（App 装配路径）；合并两份同名审计文档；cloud_mode_providers 历史壳清理。

### 6.4 实施优先级总览

| 优先级 | 项 | 预估工作量 | 主要受益 |
|---|---|---|---|
| 🔴 立即 | 方案 1（P0-1 Supabase 翻页） | 小 | 消除数据正确性风险 |
| 🔴 立即 | 方案 2（startupCheck 埋点） | 小 | 监控口径补全 |
| 🔴 立即 | 方案 4（Supabase/iCloud 重试+404 收敛） | 中 | 成功率直接提升 |
| 🟠 短期 | 方案 3（softFail 提示）、方案 5（元数据加固） | 中 | 用户可见性/一致性 |
| 🟠 短期 | 方案 6（备份恢复检查点） | 中 | 备份安全 |
| 🟡 中期 | 方案 9/10/14（监控收尾、判定加固、可观测） | 小-中 | 稳定性 |
| 🟡 中期 | 方案 12（性能：isolate+消除二次解析+gzip） | 中 | 大账本/弱网体验 |
| ⚪ 治理 | 方案 7/11/13/15/16 | 中 | 归一化防回归、维护性 |

---

## 七、结论

1. **归一化程度总体判定：App 层业务逻辑高度归一（序列化/槽位/冲突仲裁/触发入口单点收敛），协议层 S3↔WebDAV 双双经过对齐打磨，Supabase 与 iCloud 是归一化断层所在**——前者四个维度落后（翻页截断 P0、零重试、无条件写、元数据非原子），后者受原生通道限制但缺 Dart 层兜底（双重 base64、无认证异常分类）。
2. **同步失败主要风险源**（按影响排序）：Supabase list 截断连锁（P0）→ Supabase/iCloud 弱网零重试 → 备份恢复中断无检查点 → WebDAV 条件写窗口。
3. **数据不一致主要风险源**：双设备并发在 Supabase/iCloud 的盲覆盖（事后才知道）；softFail 对用户不可见；时钟偏移下 UI 状态误判（上传路径已有防护、状态展示未对齐）。
4. **性能瓶颈**：主 isolate 全量导出+编码（大账本卡 UI）、同一大 JSON 两次解析/编码、无压缩传输、WebDAV/Supabase exists 的目录级列举成本、iCloud 双重编码。
5. **监控机制**：设计良好（本地、四态、conflict 不入分母、隐私合规），距离「可证明的 99.9%」缺三件事——startupCheck 埋点、指标清理接线、以及把 Supabase 的结构性失败源修掉；健康卡 UI 阈值已按 99.9% 预置。
6. 本报告为只读排查产物，未修改任何代码；全部优化方案见第六章，实施前建议按 `docs/sync-reliability-params.md` 的参数纪律与现有测试基线（1000+ 项）走回归。

---

## 附录 A：关键证据索引

| 主题 | 文件:行号 |
|---|---|
| 成功率口径（conflict 不入分母） | lib/cloud/sync_metrics_service.dart:49-53, 141-149 |
| 健康卡 99.9% 阈值 | lib/pages/cloud/sync_health_card.dart:113-119 |
| 六场景埋点位置 | TSM:1003-1182 / 1839-1883 / 1551-1560 / 3357-3495；cloud_backup_service.dart:90-103 |
| startupCheck 零埋点 | 全 lib/ grep（仅 sync_metrics_service.dart:20,37 与 db.dart:293 出现） |
| 上传冲突仲裁（M7/方案C/A5） | transactions_sync_manager.dart:2381-2474 |
| 完整性终审（P1-5） | transactions_sync_manager.dart:2524-2574 |
| 条件写链路 | cloud_sync_manager.dart:244-262；s3_client.dart:277-396, 690-720；webdav_storage_service.dart:302-341 |
| Supabase P0 截断 | supabase_storage_service.dart:282-283, 310-341, 344-380 |
| Supabase 元数据非原子 | supabase_storage_service.dart:420-437 |
| Supabase 零重试/超时 | supabase_storage_service.dart:34, 69-75 |
| 重试矩阵/超时档 | docs/sync-reliability-params.md §一/§二（S3: s3_client.dart:134-191；WebDAV: webdav_storage_service.dart:193-217） |
| iCloud 双重编码 | icloud_storage_service.dart:74-75；storage_service.dart:237-266 |
| E2EE 装饰与 rekey | encrypted_cloud_storage.dart:44-45, 96-103, 134-174；encryption_service_impl.dart:390-565 |
| 备份恢复软失败/检查点缺失 | cloud_backup_service.dart:280-413（esp. 368-371） |
| 启动检查超时档 | startup_sync_checker.dart:271-286（状态 20s/apply 90s/回传 5min） |
| 指标清理死代码 | sync_providers.dart:185-188（无消费者）；主清理 TSM:1168 |
| 槽位命名与 syncId | transactions_sync_manager.dart:681-734 |

## 附录 B：排查覆盖的文件清单（主要）

- App 层：lib/cloud/ 全部 13 个文件（TSM 3774 行逐段精读核心链路）、lib/cloud/backup/ 3 个、lib/data/encryption/ 7 个、lib/providers/sync_providers.dart、lib/pages/cloud/（sync_health_card 全文、cloud_sync_page/encryption 相关入口）
- 协议包：packages/flutter_cloud_sync{,_s3,_webdav,_supabase,_icloud}/lib 全部源文件
- 测试：test/ 同步相关 40+ 文件覆盖面盘点（未执行，仅静态盘点）
- 文档：docs/ 与 docoments/ 同步审计/测试报告清单盘点

---

## 八、修复记录（2026-09-11 归一化批次）

用户授权后按本报告第六章方案实施的修复，全部完成并回归验证（全库 1115 项测试 + 四协议包 93/59/129/29/15 项全过，flutter analyze 0 error）：

| 报告项 | 修复内容 | 文件 | 测试 |
|---|---|---|---|
| **P0-1** | Supabase `list()` 改 `listPaginated` 游标翻页（护栏 100 页）；`exists()`/`getMetadata()`/条件写探测共用翻页定位——不再被 SDK 默认 limit:100 截断误判 | packages/flutter_cloud_sync_supabase/lib/src/supabase_storage_service.dart | supabase_pagination_conditional_test.dart（8 新用例） |
| P1-1（条件写） | Supabase 实现 `ConditionalWriteStorage` 读后比对近似（updatedAt 锚点，对齐 WebDAV 取舍：窗口收窄非原子 + 写后校验兜底） | 同上 | 能力申报 + 互斥契约用例 |
| P1-1（path 口径） | `CloudFile.path` 改调用方视角相对路径（可回传 delete/exists，消除 users/{uid}/ 双前缀风险） | 同上 | — |
| P1-1（元数据） | `_storeMetadata` 幂等重试 1 次后失败抛 `MetadataPersistFailedException`（CloudStorageException 子类）——manager 写后校验读不到指纹 → verified=false → softFail，替代静默降级 | 同上 | 子类契约用例 |
| P1-8 | Supabase `_opRetryable`（2 次、400/800ms ±50% 真随机 jitter，对齐 WebDAV 参数表）；iCloud `_retryIdempotent` 同参数——四协议重试策略归一 | supabase_storage_service.dart / icloud_storage_service.dart | iCloud 重试用例（瞬时故障 2 次自愈/预算耗尽上抛/404 不耗预算） |
| P1-9 | Supabase list 404 → 空列表（对齐 WebDAV/iCloud 收敛语义） | supabase_storage_service.dart | — |
| **P1-5（iCloud）** | 实现 `BinaryCapableStorage`：`uploadBinary` 单次 base64 直达原生契约（原生解码落盘**原始字节**，消除双重编码 +33% 体积）；`downloadBinary` 带旧格式嗅探（base64 文本对象解包兼容） | icloud_storage_service.dart | 新格式原样/旧格式解包/404→null 用例 |
| **P1-3** | startupCheck 埋点：Deps 注入 metrics（与 TSM 同实例），`runIfNeeded` finally 单点四态记录（backend='startup'，整轮 duration）；failed（探测失败/激活后哨兵）/softFail（取消/方向未知）细分 | startup_sync_checker.dart / app.dart 接线 | 5 新用例，文件 71 项全过 |
| **P1-4** | softFail 可见化：`uploadCurrentLedger` 返回 `({bool verified})`；UI 三处差异化提示「已上传但未确认收敛」（账本页 toast / 云同步页批量汇总 / 弹窗文案）；l10n×4 | sync_service.dart / transactions_sync_manager.dart / ledgers_page_new.dart / cloud_sync_page.dart / app_localizations* | 54 项相关测试全过 |
| **P1-2** | 备份恢复跨进程检查点 `cloud_backup_restore_pending`（SharedPreferences）：恢复前置位、终态清除；调度器 tick 检查让位（手动备份不受限）；恢复入口检测残留 → 弹「重新执行一次恢复即可修复」提示 | cloud_backup_service.dart / app.dart / cloud_sync_page.dart | 2 新用例（成功清除/损坏备份失败路径清除），备份 15 项全过 |

**实施偏差与备案**：
- 条件写锚点采用 `updatedAt`（Supabase PaginatedFile 无 etag 字段）——比对语义等价（覆盖写必刷新 updatedAt），已在 `_etagOf` 注释论证；
- Supabase 元数据原子性受限于 Storage API（无对象级原子元数据写），采用「失败可见化（softFail 上浮）+ 幂等重试」替代方案 ②，与报告 6.1 方案 5 的推荐路径一致；
- 修复后监控口径：六场景全部进 99.9% 分母（startupCheck 于 2026-09-11 补齐），Supabase/iCloud 的结构性失败源（截断/零重试/元数据静默）已消除。

### §八补记：第二批修复（2026-09-11 监控收尾 + 判定加固）

| 报告项 | 修复内容 | 文件 | 测试 |
|---|---|---|---|
| **P1-12** | core `getStatus` 新增 `localUpdatedAtTrusted`：不可信墙钟（全部已推送/recordChanges:false 导入来源）不做时间戳方向断言，让位 count 兜底（内容性证据不受时钟偏移影响）或 unknown；TSM `_localUpdatedAtTrusted` 与墙钟同源透传 | cloud_sync_manager.dart / transactions_sync_manager.dart | 2 新用例（不可信→不断言 localNewer / 可信→回归保护），core 23 项过 |
| P2-6 | `downloadRemoteLedger` 补 snapshotRestore 埋点：主路 success、对象缺失→softFail（与 drainAttachmentJobs 的 objectMissing 同口径）、空快照守卫→softFail、异常→failed——三条批量恢复调用方的失败率首次进健康卡分母 | transactions_sync_manager.dart | 既有 34 项 TSM 测试回归 |
| P2-7 | 指标清理兜底接线 PiggyApp 启动（`cleanupExpired()` fire-and-forget）；原 `syncMetricsCleanupProvider` 死代码删除 | app.dart / sync_providers.dart | — |
| P2-8 | 自动防抖上传失败轻反馈：TSM 新增 `onAutoSyncFailure` 回调（TSM 不依赖 UI 框架的分层约束），provider 接线刷 `syncStatusRefreshProvider`——状态卡显示真实差异，不弹 toast（后台失败属常态） | transactions_sync_manager.dart / sync_providers.dart | — |
| P2-9 | E2EE 元数据信封解密失败从 debugPrint 升级 logger.warning（release 留痕 + 措辞含「核对密码一致性」排查指引） | encrypted_cloud_storage.dart | 测试补 binding 初始化（logger 桥需要） |

回归：全库 1115 项 + core 包 95 项全绿，analyze 0 error。

### §八补记二：第四批修复（2026-09-11 性能：gzip 压缩传输）

| 报告项 | 修复内容 | 文件 | 测试 |
|---|---|---|---|
| **P2-2③** | 快照 gzip 压缩装饰器：E2EE 开启时装配 raw→Gzip→Encrypted（压明文后加密）；≥2KB 且压缩比 ≤60% 阈值；download 嗅探三态（gzip 解压/BEECRYPT1 透传/其余原样）；Latin-1 无损桥过文本通道；能力接口镜像（附件真字节/条件写锚点不因新层断裂）；加密未开启不装配（明文可读性零回滚风险） | lib/cloud/gzip_cloud_storage.dart（新）、encrypted_cloud_provider.dart（innerStorageOverride）、transactions_sync_manager.dart（装配）、provider_factory.dart（压缩统计日志） | gzip 专项 12 项 + 装配链 2 项（压缩→加密→解密→解压完整往返），全库 1129 项全绿 |

实施偏差与备案：UTF-8 传输 gzip 字节的早期方案会重编码破坏字节流（测试首跑抓出），改 Latin-1（每字节一码点）无损桥；装配位置选在加密装饰器的 inner 而非独立 provider 包装——rekey/enableFromCloud 全部传 rawStorage，与压缩层零交互（核验三入口源码确认），无兼容裂口。
