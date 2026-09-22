# PiggyCount 同步功能全面系统性排查报告（终版 · 2026-09-12）

- **排查日期**：2026-09-12
- **排查方式**：只读静态代码审计（**未修改任何代码**）——主会话逐行精读 + 双子代理并行深审（① Supabase/iCloud 全模块含 SDK/原生 Swift 源码核对；② 云端备份/gzip/加密装饰层/change_tracker），并与既有基线报告 `docs/sync-comprehensive-audit-2026-09-12.md` 及其附录 C 修复实施记录（HEAD commit `fcf182d`）逐项交叉核验；**子代理的 P1 级发现均经主会话独立二次验证后才收录**（见 §4.1 验证注记）
- **排查范围**：全部同步功能——S3 协议包、WebDAV 协议包、Supabase 协议包、iCloud 协议包、core 同步框架（flutter_cloud_sync）、App 层快照同步主链路（TransactionsSyncManager 3823 行）、启动检查编排器（1486 行）、diff 服务、内容指纹、变更追踪、gzip 压缩层、云端备份（ZIP 上传/恢复/定时调度）、端到端加密装饰层、附件二进制同步、同步成功率监控机制（sync_op_log + 健康卡）
- **本次排查定位**：当前代码态（fcf182d 之后）的**复核型终审**——① 对已落地的十项修复（N-1/2/3/6/7/8/9/11/13/14）做主会话独立验证；② 对四个协议包与 App 层全部同步链路做归一化三维比对（数据处理逻辑 / 同步策略 / 错误处理机制）；③ 审计监控机制对 99.9% 目标的覆盖与可达性；④ 汇总全部「同步失败 / 数据不一致 / 性能瓶颈」问题并给出优化方案。

---

## 0. 摘要（TL;DR）

**总体结论：四协议包（S3/WebDAV/Supabase/iCloud）在数据处理、同步策略、错误处理三个维度已达到「单点收敛 + 协议能力上限」的归一化状态；fcf182d 批次的十项修复经独立复核全部真实在位。本轮新发现（含双子代理深审、P1 级均经主会话二次验证）共 9 项 P1 + 约 25 项 P2/P3，无新增 P0。最重磅的三项是「声明与实现背离」类架构问题：gzip 压缩特性在生产 100% 未生效（GZ-1，装配顺序与注释宣称相反）、ChangeTracker 生产未注入导致 local_changes 全链路空转（CT-1）、rekey 不覆盖备份目录使改密后历史备份永久不可恢复（BKV-2）——三者都是既有审计与测试绿灯未能拦住的「设计在场、实现失位」问题。**

监控机制评估：**六场景埋点全覆盖、四态口径自洽、99.9% 阈值已进 UI**（sync_health_card.dart:116）。机制本身已具备「测得出 99.9%」的完整链路；单设备/低并发用户在当前代码下可达成 99.9%；双设备高频并发场景的稳定 99.9% 除 softFail 源头收敛外，还依赖 CT-1 的裁决——local_changes 空转使墙钟证据门禁退化为「unknown 冲突多弹合并确认」，间接拉低 startupCheck 的 softFail 占比。

**P1 新发现速览（9 项）**：

| # | 问题 | 模块 | 一句话 |
|---|---|---|---|
| GZ-1 | gzip 装配顺序与设计相反，E2EE 链路压缩从未发生（死装饰层） | TSM 装配 + gzip 层 | 加密层在外/压缩层在内 → gzip 恒收到密文按防御分支透传；三层注释与装配链测试（只断言前缀+往返）共同掩盖 |
| CT-1 | ChangeTracker 生产未注入，local_changes 写端 55 处登记全空转 | database_providers.dart:24 | 读端（证据门禁/指纹校验位/markSnapshotPushed）指望它有数据，写端全不生产——中间态是最差组合 |
| BKV-2 | rekey 目标集合不含备份目录，改密后历史备份永久不可恢复 | encryption_service_impl:696-730 | 灾难恢复能力静默失效，且报错形态与网络故障难区分 |
| BKV-1 | createBackup 全内存装配 ZIP，大附件库 OOM | cloud_backup_service.dart:183-226 | 500MB 附件库峰值内存约 1.5GB，崩溃在上传前、当日备份丢失且无检查点 |
| SUP-1 | Supabase 路径遍历防护完全缺失（`..` 段不拒绝） | supabase_storage_service.dart:633-642 | `users/{uid}/` 前缀是唯一租户隔离手段，`../` 可构造跨用户对象键 |
| ICL-2 | `exists()` 容器未初始化/路径校验失败被原生 `try?` 压成 false | ICloudManager.swift:460-464 | 环境故障被误判「文件不存在」→ 诱发覆盖上传 |
| ICL-1 | iCloud 条件写与 eTag 锚点整体缺位（CloudFile.eTag 恒 null） | icloud_storage_service.dart:291-299 | 并发冲突防护只剩写后校验，两机并发静默 last-writer-wins |
| SUP-D1 | database `subscribe()` 裸抛 `UnimplementedError` | supabase_database_service.dart:229-240 | Error 穿透 Exception catch（当前 App 零消费，实害降级为契约缺口） |
| GZ-1 关联测试缺口 | 装配链测试未断言压缩发生 | encrypted_cloud_provider_test.dart:133 | 绿灯掩盖失效的典型样本——断言强度不足也是「测试在、防线不在」 |

---

## 一、排查方法与范围

### 1.1 模块清单与精读覆盖

| 层 | 模块 | 行数 | 覆盖方式 |
|---|---|---|---|
| core | cloud_sync_manager / storage_service 契约 / exceptions / retry_helper | 745/267/67/237 | 主会话逐行 |
| S3 包 | s3_client / s3_storage_service / s3_provider / signature | 1586/524/267/254 | 主会话逐行 |
| WebDAV 包 | webdav_storage_service / webdav_provider / auth | 992/444/80 | 主会话逐行 |
| Supabase 包 | storage(743)/provider(193)/auth(99)/database(420)/realtime(399) | 1854 | 子代理逐行 + 主会话抽查 |
| iCloud 包 | storage(307)/provider(103)/auth(141)/method channel(156) + 原生 Swift 层 | 707+Swift | 子代理逐行（含 SDK/Swift 源码核对） |
| App 层 | transactions_sync_manager / startup_sync_checker / sync_diff_service / sync_fingerprint / sync_metrics_service / sync_service 接口 / provider_factory / sync_providers | 3823/1486/811/343/351/198/161/391 | 主会话逐行 |
| 外围 | cloud_backup_service(588)/backup_scheduler(123)/gzip_cloud_storage(208)/encrypted_cloud_provider+storage/change_tracker(373) | ~1300 | 子代理逐行（附录并入） |

### 1.2 同步功能全景（触发源 → 链路）

1. **快照上传**：手动（云同步页/全量上传）/ 自动（PostProcessor → `uploadCurrentLedgerDebounced` 2s 防抖）/ 合并回传（startup checker merge-then-publish，bypassRestoreGuard 豁免）→ TSM `_uploadCurrentLedgerCore`（TSM-P8 账本锁 + restore guard + 冲突探测 M7 + 条件写锚点 + 写后校验）
2. **快照恢复**：单账本（downloadAndRestore）/ 云端账本导入（downloadRemoteLedger/importRemoteLedger）/ 全量恢复（restoreAll/fullRestoreAll）→ SyncRestoreGuard 临界区 + 内嵌指纹硬校验（P1-5）
3. **启动检查**：runIfNeeded → 云端发现（discover，10s 单文件预算）→ 并发 getStatus（20s/账本）→ 候选合并（两阶段 applyAll / confirmEach）→ 统一回传（5min，H6 新鲜度校验）
4. **附件同步**：上传侧内容寻址 upsert（先附件后清单的顺序协议 + 会话级名字缓存）→ 恢复侧 drain 队列（semaphore 4、3 次退避、sha256 终审、三态结果）
5. **云端备份**：BackupScheduler 每分钟 tick（app.dart）→ ZIP 打包上传 / 恢复（跨进程检查点 cloud_backup_restore_pending）
6. **加密链路**：raw → Gzip（压缩明文）→ Encrypted（压后加密）装饰装配；rekey/enableFromCloud 走 rawStorage 旁路

---

## 二、已落地修复的独立复核（fcf182d 十项）

主会话对本日审计修复批次逐项验证（不完全依赖既有报告声明）：

| 修复项 | 复核证据 | 结论 |
|---|---|---|
| N-1 WebDAV 路径校验编码盲区 | webdav_provider.dart:134-141（remotePath 对原始+`_decodeLoosely` 双形态分段校验）；webdav_storage_service.dart:779-789（`_assertNoTraversal` 反斜杠归一化 + URI 解码双形态） | ✅ 在位 |
| N-2 Supabase 元数据失败语义 | supabase_storage_service.dart:233-243（upload 不再上抛）、648-676（重试 1 次后吞掉、warning 留痕） | ✅ 在位（子代理复核确认「softFail 而非 failed」口径达成；残留 SUP-10 死契约见 §四） |
| N-3 翻页护栏告警 | supabase_storage_service.dart:523-553（触达 warning） | ✅ 在位 |
| N-6 S3 XML localName 匹配 | s3_client.dart:1326-1389（findAllLocal/findChildLocal + IsTruncated/NextContinuationToken 全覆盖） | ✅ 在位 |
| N-7 条件头特征收紧 | s3_client.dart:647-657（NotImplemented 必须配合 if-match/if-none-match/"a header you provided" 关键词） | ✅ 在位 |
| N-8 Supabase 瞬时判定类型化 | supabase_storage_service.dart:150-175（SocketException/TimeoutException/HttpException runtimeType；Web 平台按类型名兜底） | ✅ 在位 |
| N-9 iCloud 嗅探第一闸 | icloud_storage_service.dart:180-197（严格 utf8.decode try/catch） | ✅ 在位 |
| N-11 S3 超时档位口径 | s3_client.dart:505-512（streamTimeout 缺省按 5min cap 档）、782-784（getObject 消息报 90s 实档） | ✅ 在位 |
| N-13 Supabase Precondition 双参构造 | supabase_storage_service.dart:292-299 | ✅ 在位 |
| N-14 S3 流 body drain | s3_client.dart:560-563（成功路径 drain 回池） | ✅ 在位 |

**复核结论：十项修复全部真实落地，与既有报告附录 C 声明一致；修复未引入 P0 级回归。**

---

## 三、跨模块归一化矩阵（三维比对）

### 3.1 数据处理逻辑

| 维度 | S3 | WebDAV | Supabase | iCloud | 归一判定 |
|---|---|---|---|---|---|
| 序列化/槽位/指纹/附件协议 | 单点收敛于 App 层（TSM/transactions_json/sync_fingerprint），四协议共用 | 同左 | 同左 | 同左 | ✅ 完全归一 |
| 元数据原子性 | ✅ 原子（x-amz-meta 随 PUT 同请求） | ✅ 原子（pc-wdav-env-v1 信封单文件，W-I 修复） | ⚠️ **非原子**（file_metadata Postgres 旁路表二次写；N-2 后失败降级 softFail） | ⚠️ **非原子**（sidecar `.metadata.json` 独立对象，且原生 coordinator 协调失效——见 ICL-5） | ❌ 两包欠账 |
| 二进制路径 | ✅ 真字节 | ✅ 真字节 | ✅ 真字节 | ✅ 真字节（P1-5 后）+ 旧格式嗅探（N-9 收紧，残留 ASCII-base64 固有歧义） | ✅ 基本归一；⚠️ E2EE 装饰层 uploadBinary 走文本通道（BKV-3）与 uploadBinaryConditional 真字节通道**形态不一致**（ECS-1，4 态矩阵） |
| 压缩传输（gzip） | —（App 层装饰） | —（同左） | —（同左） | —（同左） | ❌ **GZ-1：装配顺序倒置，E2EE 链路压缩 100% 未生效**（见 §4.1） |
| list 分页 | ✅ V2/V1 双协议 + 1000 页护栏 + token 回放/畸形响应检测 | ❌ 无分页无截断检测（PROPFIND Depth-1，上游 webdav_client 1.2.2 限制，P1-7 遗留） | ✅ 游标翻页 + 100 页护栏 + 告警（N-3 后）；⚠️ 翻页重试从头再来 | 原生 contentsOfDirectory 单次全载（无护栏，量级可控） | ⚠️ WebDAV 独弱 |
| list 目录占位过滤 | ✅ `endsWith('/')` 过滤 | ✅ isDir + 内部产物（.tmp./.old./sidecar）三读路径统一口径 | ❌ **不过滤**（SUP-7：`name/` 占位条目全量回传，拼出尾斜杠路径） | ✅ Swift 侧过滤 | ❌ Supabase 欠账 |
| list 条目 metadata 口径 | 不带 | 空 const {} | 带 | 带 | ⚠️ 契约分裂（P2-3 遗留，宿主已适配） |
| path 回传口径 | 相对路径 | 相对路径 | 相对路径（P1-1b 修） | 原生相对路径 | ✅ 归一 |
| 路径遍历防护 | ✅ `_assertNoTraversal` 分段校验（S3-21 精确化） | ✅ 分段校验 + 编码盲区收口（N-1） | ❌ **零防护**（SUP-1） | ✅ 原生 safeURL（但失败被吞——ICL-2） | ❌ Supabase 安全缺口 |
| 路径空值/尾斜杠防御 | key 构造剥前导斜杠 | `_assertFilePath` 拒空/尾斜杠（W-Y/WD-Y2） | 无等价防御 | 原生层 | ⚠️ 维护性 |
| ETag 透出 | ✅ HEAD/PUT 响应原生 ETag | ✅ PROPFIND getetag 归一化透出 | ⚠️ updatedAt 秒级字符串充当（SUP-4：同秒双写假阴性） | ❌ **恒 null**（ICL-1：原生 lastModified 可用未接） | ❌ 两包锚点断层 |

### 3.2 同步策略（并发防护三层）

| 层 | S3 | WebDAV | Supabase | iCloud |
|---|---|---|---|---|
| 上传前冲突探测（M7） | 四协议统一于 App 层 `_detectUploadConflict`（元数据指纹快路径 → 内嵌指纹终审 → 可信墙钟方向仲裁；探测失败中止上传 A5）——**完全归一** | 同左 | 同左 | 同左 |
| 条件写（方案C） | ✅ **原子** If-Match/If-None-Match（412/404/409 全谱翻译；网关不支持自动降级+能力记忆；条件 PUT 网络故障安全重试 ≤2） | ⚠️ 读后比对近似（非原子、fail-closed、窗口收窄）——P1-6 遗留 | ⚠️ 读后比对近似（updatedAt 锚点）+ 大目录探测逐页扫（SUP-4） | ❌ **不支持** → 恒盲写（manager 有 warning 留痕降级路径） |
| 写后校验（C3） | 四协议统一（verified=false → softFail 指标 + 不清脏标记 + UI 可见化 P1-4）——**完全归一** | 同左 | 同左 | 同左 |
| 下载完整性终审（P1-5） | 内嵌指纹硬校验 + 单次重下自愈（恢复/导入/合并三破坏性入口）——四协议归一 | 同左 | 同左 | 同左 |
| 破坏性操作互斥 | TSM-P8 账本锁 + SyncRestoreGuard 临界区 + 备份调度让位（app.dart tick 检查）——App 层单点，四协议无差别 | 同左 | 同左 | 同左 |

**判定**：并发防护能力矩阵为 S3（原子）> WebDAV/Supabase（读后比对）> iCloud（盲写+事后校验）——差异源于协议原生能力（HTTP 标准 If-Match vs 无等价原语 vs 原生黑盒），**代码已做到各协议能力上限**；但 iCloud 连「最弱形态锚点」（透出 lastModified 供 manager 传递）都没提供，是策略归一化的最后一块缺口（ICL-1）。

### 3.3 错误处理机制

| 维度 | 现状 | 残差 |
|---|---|---|
| 异常体系 | 单根 CloudSyncException；401/403→CloudAuthException（401/403 文案区分，W-X）；412/404/409→Precondition；404→幂等 null | ✅ S3/WebDAV 完整；❌ Supabase `_isNotFound` 保留 `contains('not found')` 宽词（SUP-2）；❌ Supabase database subscribe 裸抛 UnimplementedError（SUP-D1）；❌ WebDAV/iCloud auth 服务抛 UnsupportedError（P2-11 遗留）；❌ Supabase auth 无 catch-all（SUP-A2） |
| 超时档位 | S3 元数据 30s / 传输自适应 30s+30s/MB（5min 封顶）；WebDAV 60s（CancelToken 主动取消）；Supabase 60s（**仅 Future.timeout，不取消传输层**——SUP-3）；iCloud channel 30s/下载 90s；App 启动检查 20s/90s/5min、发现单文件 10s | ⚠️ P1-10 遗留（S3/Supabase/iCloud 超时不取消底层请求）；WebDAV 大附件 60s 偏紧（P2-13）；iCloud upload 30s 对大 ZIP 偏紧（ICL-8） |
| 重试策略 | **已归一**：四包幂等读 2-3 次指数退避 + 真随机 jitter（P5/P1-1），认证/404/501 确定性失败不耗预算，非幂等写不重试（例外：S3 条件 PUT 锚点安全重试 ≤2），逐次留痕（LOG-06） | ⚠️ Supabase `_opRetryable` 包住整次翻页循环（中间页失败从头重拉，N-3 后半遗留）；Supabase 无状态码时保守判瞬时（SUP-11 小瑕疵）；core RetryHelper 生产零调用（P2-1 备案）；Supabase database/realtime 无超时无重试（SUP-D6，App 零消费缓冲） |
| 错误→指标归因 | classifyError 六类 + Top 聚合 + 四态记录——App 层单点归一 | ✅（attachmentFill attempts 恒 3 未透传真实值、startupCheck backend='startup' 不可按后端过滤——口径已备案） |
| 日志留痕 | S3（downgrade/protocol/retry 三回调）/WebDAV（storageLogger）/Supabase（storageLogger）/Gzip（compressionLogger）全部接入应用日志管线 | ⚠️ 四个静态注入口命名分裂（P2-12）；❌ **iCloud 包零 CloudSyncLogger 注入**（原生 print + debugPrint，LOG-01 收编唯一漏网）；❌ Supabase database service 仍走 dev.log（SUP-D3） |

---

## 四、问题清单（本轮复核 + 新发现，按严重级）

> 收录规则：双子代理的 P1 级发现均经主会话独立验证（关键代码亲自重读）后才计入；P2/P3 按子代理证据收录、抽检复核。§4.1 各项附验证注记。

### 4.1 P1（9 项）

**GZ-1 gzip 压缩特性在生产 100% 未生效（装配顺序与设计相反——死装饰层）**【主会话已验证 ✅】
- 证据链：TSM `_initialize`（transactions_sync_manager.dart:643-648）构造 `GzipCloudStorageService(inner: newRawStorage)` 后经 `EncryptedCloudProvider(innerStorageOverride: gzipWrapped)` 包装——即 `provider.storage = Encrypted(inner: Gzip(inner: raw))`，**加密层在外、压缩层在内**。实际数据流：`upload(明文) → Encrypted.upload → encrypt(明文) → Gzip.upload(密文)` → gzip 层 `data.startsWith('BEECRYPT1:')` 防御分支命中（gzip_cloud_storage.dart:97-99）→ **透传**。gzip 层永远收到密文，压缩从未发生；且装配 Gzip 的唯一场景（E2EE 开启）恰好是必然透传的场景，E2EE 关闭时根本不装配——压缩特性零兑现。
- 与注释宣称相反：gzip 类注释（:14-19）、TSM 装配注释（:637-641）、EncryptedCloudProvider 注释（encrypted_cloud_provider.dart:25-32）均宣称「raw → Gzip → Encrypted，压明文后加密」——**三处注释描述的装配方向与代码实际相反**。`encrypted_cloud_provider_test.dart:133` 的装配链测试只断言 `rawStored.startsWith('BEECRYPT1:')` 与往返还原，透传同样满足——**测试绿灯掩盖失效**。
- 影响：性能特性失效（b1d4cd4 承诺的「弱网流量降 85%+」实际为零）；commit 声明与实现背离；误导后续维护者。
- 优化：反转装配为 `Gzip(inner: Encrypted(inner: raw))` 并让 `provider.storage` 返回 Gzip 层（`innerStorageOverride` 语义从「替换加密层 inner」改为「外包一层」，需同步核 `EncryptedCloudProvider.storage` getter 与 rekey/rawStorage 旁路不受影响——rekey 走 `_rawStorage` 天然绕过两层，无交互）。**必须补测试断言**：E2EE 链路下 `rawStored` 解密后首 3 字节为 gzip 魔数（1f 8b 08）且长度显著小于明文。风险：中（涉及上传/下载双向嗅探兼容，需全量回归 gzip/加密往返用例 + 存量云端对象兼容——存量密文未压缩，下载端嗅探透传即可兼容，无迁移风险）。

**CT-1 ChangeTracker 生产未注入，local_changes 全链路空转（防线设计名存实亡）**【主会话已验证 ✅】
- 证据链：database_providers.dart:24 生产构造点为 `LocalRepository(db)`（无 changeTracker 参数）；全库唯一 `ChangeTracker(...)` 实例化在测试（grep 确认 lib 下零生产实例化）。后果五连：① local_repository.dart 55 处 `if (changeTracker != null)` 登记全部跳过 → local_changes 表生产恒空；② TSM `_localChangeEvidence`（:891-923）`dbMax` 恒 null、`unpushed` 恒 0 → 墙钟证据门禁（M1/M7/P1-12 的设计前提）退化为仅内存 `_recentLocalChangeAt`（重启即失）；③ `_localChangeGuard`（:2335-2350）恒返回 `'-1/0'` → P2-1 指纹缓存的「轻量校验位」防线对用户编辑不产生变化信号，失效完全依赖 UI 后处理触发的 markLocalChanged/clearStatusCache；④ `_wireChangeTrackerGeneration` 回调接线因 tracker null 早退；⑤ markSnapshotPushed/cleanupPushedChanges 生产永不执行（TSM:1183-1185 在 `tracker != null` 分支内）。
- 缓解面核实：数据不直接丢失——unknown 冲突走保守人工仲裁（宁可多弹合并确认），指纹比对与全量导出仍工作；v41 清理 6143 行存量数据说明历史上曾有过注入时期（或早期版本路径）。
- 影响：双设备场景方向仲裁从「时间证据自动裁决」退化为「每轮多弹合并确认」（体验受损 + startupCheck softFail 占比上升）；若未来出现绕过 PostProcessor 的编辑路径，同会话内指纹缓存将 stale，`_detectUploadConflict` 指纹相等快速路径可能基于陈旧指纹放行（目前因上传总是重新全量导出而不丢内容，探测结论可能失真）。
- 优化（二选一收敛，不可维持中间态）：(a) 恢复生产注入 `LocalRepository(db, changeTracker: ChangeTracker(db))`，让 373 行实现与 55 处登记点复活；(b) 若增量机制确认随云端协同下线永久移除，则拆除 TSM 对 local_changes 的读端依赖（证据门禁/校验位改基于内容指纹或 v40 updated_at 触碰列），归档 change_tracker 为测试专用。推荐 (a)——改动一行、收益确定（M1/M7/P1-12/P2-1 四条防线的既有投资全部复活）。
- **2026-09-21 进展（(b) 两段均已落地）**：产品侧确认 ChangeTracker 随云端协同下线（`lib/providers/database_providers.dart` 已注明「快照备份路径不注入 tracker」），故按 (b) 推进，TSM 两处 local_changes 读端全部改造完成：
  - **第一段 · 指纹缓存校验位**：改为业务表代际（行数 + MAX(id) + SUM(updated_at)，`_contentGenerationGuard`）并与 local_changes 叠加。实测（5000 笔单账本，debug VM）代际查询 3.89ms vs 全量导出 471.13ms，8 账本每轮省 ≈3.7s。5 项新单测已取证「修复前必失败」。
  - **第二段 · 方向仲裁证据门禁**：`_localChangeEvidence` 由「`MAX(local_changes.created_at)` + 未推送行数」改为「v40 触碰列 `MAX(updated_at)` + `MAX(created_at)` 兜底（补 INSERT）」，作用域含 user-global 表。**`trusted` 门禁不放松**，仍是内容性断言「本地确有未上云内容」，三条证据任一成立：a 本 session 写入登记（原有）；b local_changes 未推送行（原有）；**c 持久写入痕迹晚于「本机上次成功上传本账本的时刻」**（锚点 = `sync_op_log` 中该账本 `snapshot_upload`+`success` 的 MAX(ts)，配合内存 `_recentUpload` 取较新者）。c 刻意使用**同机时钟锚点**而非直接「有写痕迹就信」：方向仲裁中 `localAt > remoteAt` 会静默放行覆盖云端（破坏性方向），而 remoteAt 可能来自他机时钟 —— 放宽会让设备间时钟偏移直接把「本机更晚」判错，静默盖掉对方刚上传的数据，破坏 P1-12 刻意保留的保护；c 的两端都是本机时钟，无偏移风险且结论与 b 同强度。6 项新单测（含锚点正/负例、epoch 秒→毫秒单位断言、多源取最大）。
  - **仍未闭合（新备案）**：`transactions` / `categories` **无 created_at 列**且触发器不覆盖 INSERT → 跨 session 的**纯新增**（记一笔新交易 / 建新分类）不留持久墙钟，只能靠 a（同 session）覆盖；此时该账本若再无其它表触碰则退回 'unknown' → 弹人工确认（保守，不丢数据）。若要彻底闭合，仍是 (a)：生产重新注入 `ChangeTracker(db)`（改动一行，同时复活 55 处登记点、`markSnapshotPushed`、指纹缓存校验位与 tracker 回调四条防线）。锚点还有 30 天滚动清理（`SyncMetricsService.retention`）的时间窗限制。

**BKV-2 rekey（改密）不重加密备份目录，历史备份在改密后永久不可恢复**【子代理发现，证据链完整】
- 证据：encryption_service_impl.dart:696-730（rekey targets 白名单仅 `ledger_*.json` + `attachments/`，不含 `piggycount-bak/`）；消费侧 cloud_backup_service.dart:311-321 恢复时 `decrypt(asText)` 直接抛 DecryptionException → :430 rethrow → UI 显示原始异常文本（cloud_sync_page.dart:448）。
- 影响：E2EE 用户改密后全部历史 ZIP 备份静默不可用，且报错形态与网络故障难区分——灾难恢复承诺在最需要的时刻失效。
- 优化：(a) rekey targets 纳入 `piggycount-bak/`（下载旧密文→解密→新钥重加密→上传，失败走既有 SYNC-13 回滚）；(b) 短期至少改密确认 UI 明示后果 + 恢复侧对 DecryptionException 分类提示「该备份创建于旧密码时期」。

**BKV-1 createBackup 全内存装配 ZIP，大附件库 OOM 风险**【子代理发现】
- 证据：cloud_backup_service.dart:183-226——每附件 `readAsBytes`（:208）全量入内存 `Archive`，`ZipEncoder().encode`（:220）再产完整 ZIP；E2EE 开启叠加 base64（+33%）与 encrypt 再一份；全程主 isolate。
- 影响：500MB 图片附件库峰值内存约 1.5GB，移动端 OOM；崩溃在上传前，当日备份丢失且无检查点。
- 优化：ZIP 流式编码（逐条目写临时文件）或分卷多对象上传；至少先加附件总量阈值告警 + 导出侧对齐恢复侧的 `compute` 后台化（data_import_service.dart:1605 已用 compute，备份侧不对称）。

**SUP-1 Supabase 路径遍历防护完全缺失**
- 证据：supabase_storage_service.dart:633-642（`_buildUserPath` 仅 PathHelper.join，无 `..` 校验）；path_helper.dart:14-27（normalize 不解析相对段）
- 影响：`users/{uid}/` 前缀是唯一租户隔离手段，`path='../otheruser'` 可构造跨用户对象键，配合 delete/exists 越权读写删；也破坏 pathPrefix 沙箱。生产 App 传 pathPrefix=null 用默认前缀 + RLS 未知，风险取决于部署，但客户端自认安全是错误承诺（与 N-1 同性质）。
- 优化：`_buildUserPath` 补 S3 同款分段 `..` 校验 + WebDAV N-1 口径（反斜杠/编码双形态），约 10 行纯函数。

**ICL-2 iCloud exists() 把环境故障误判「文件不存在」**
- 证据：ICloudManager.swift:460-464（`guard let fileURL = try? safeURL(for: path) else { return false }`——容器未初始化 code 1001/路径校验 code 1002 全被压成 false）；dart 侧 :267-280 正常返回 false
- 影响：容器初始化竞态窗口内 exists=false → 调用方触发覆盖上传——这正是 dart 侧注释（:272-274）声称已防住、但被原生 `try?` 架空的场景。
- 优化：原生 fileExists 改回调式，safeURL 错误透传（1001/1002 返回 error）；Dart 侧非 NOT_FOUND 已正确抛，改原生即闭环。

**ICL-1 iCloud 条件写与 eTag 锚点整体缺位**
- 证据：icloud_storage_service.dart:26-27（未实现 ConditionalWriteStorage）；:291-299（CloudFile 构造不填 eTag → TSM `_detectUploadConflict` 拿到的 cloudETag 恒 null → 每次盲写）
- 影响：iOS 双设备并发同账本静默 last-writer-wins，仅剩写后校验 softFail 事后发现。原生已有 lastModified（ISO8601 已回传 :251-253/:295-297）可组装最弱形态锚点。
- 优化：最小改动——getMetadata/list 用 lastModified 填 CloudFile.eTag；进一步可对齐 WebDAV 读后比对模式（探测 lastModified → 比对 → data.write(.atomic)）。

**SUP-D1 Supabase database `subscribe()` 裸抛 UnimplementedError**
- 证据：supabase_database_service.dart:229-240
- 影响：Error 穿透 `on Exception` catch；按接口编程的调用方运行时炸未归类异常。当前 App 层零消费（database/realtime 懒装配，P2-10），实害降级为契约缺口。
- 优化：改抛 CloudConfigurationException；同批补 SUP-D2（`response as List` 强转防御）。

**测试断言强度缺口（GZ-1 的放大器，单列以警示）**
- 证据：encrypted_cloud_provider_test.dart:133——装配链测试标题宣称「压缩→加密两层」，断言仅 `rawStored.startsWith('BEECRYPT1:')` + 往返还原，透传同样满足。
- 影响：这不是孤例——凡「装饰层特性」类测试若只断言往返一致而不断言特性发生（压缩率、调用次数、字节形态），就无法区分「实现」与「透传」。
- 优化：装饰层测试规范补一条——每特性必须断言「可观测的形态特征」（gzip 魔数/长度、mock inner 的调用次数、metadata 键值）。

### 4.2 P2（约 16 项，择要）

| # | 问题 | 证据 | 一句话 |
|---|---|---|---|
| BKV-3+ECS-1 | E2EE 备份 ZIP 走文本通道，uploadBinary 与 uploadBinaryConditional 云端对象形态不一致（4 态矩阵） | encrypted_cloud_storage.dart:126-177 | 注释宣称「真字节路径」不成立；形态矩阵已是回归风险面 |
| BKV-4 | restoreBackup 无整体超时/取消，iCloud 后端无操作级超时——假死会锁死 `_busy`+Guard 直至重启 | cloud_backup_service.dart:283-445 + icloud 包 | iCloud method channel 挂起 → 手动备份此后一直 StateError |
| SCH-1 | 定时备份失败无用户可见反馈（与 onAutoSyncFailure 轻反馈机制不对齐） | app.dart:224-231 | 连续数日失败用户无感知 |
| SUP-6 | Supabase 自定义元数据旁路 Postgres 表，未用 SDK 对象级 FileOptions.metadata | supabase_storage_service.dart:221-231 | 隔离隐式依赖（SUP-5）+非原子+缺表退化三重负担 |
| SUP-7 | list 不过滤目录占位（`name/` 零字节条目） | :526-555 | 发现流程把占位当文件，拼出尾斜杠路径回传 |
| SUP-4 | 条件写锚点 updatedAt 秒级精度 + 探测逐页扫 | :256-318/:357 | 同秒双写假阴性；大目录条件写 N×1000 条 list 流量 |
| SUP-P1 | provider dispose 不释放 SDK 单例 | supabase_provider.dart:179-192 | 切后端后 realtime WebSocket/auth 流后台残留 |
| SUP-3 | Supabase 超时不取消传输层（SDK 内置重试放大） | :109-114 | 超时后请求仍在飞；upsert 幂等故数据无损，多付全量传输 |
| SUP-D3/D4 | database 批量回退 dev.log + 分页静默截断 limit=1000 | :304-319/:180-185 | 半提交无痕迹；第 1001 行静默丢失（App 零消费缓冲） |
| CT-2 | recordPulledFromServer 预检+插入非原子（v35 部分索引不覆盖 server_marker） | change_tracker.dart:256-272 | 并发可双插冗余行（CT-1 修复后才成为现实风险） |
| ICL-5 | sidecar 元数据写入 NSFileCoordinator 协调失效（metadataURL 重新构造绕过协调后 URL） | ICloudManager.swift:253-264/:600-613 | 并发上传同 path 时 sidecar 内容/指纹错配 |
| ICL-4 | iCloud sidecar 与主文件独立对象，同步到达时序不保证 | :254/:298 | 写后校验可能读到未同步旧指纹 → 假阳性 softFail |
| ICL-A1 | authStateChanges 无系统账号变更监听（ubiquityIdentityDidChange 未接） | icloud_auth_service.dart:27-65 | 用户在 iOS 设置退出 iCloud 后 App 仍认为已认证 |
| ICL-8 | upload 30s 单档对大 ZIP 偏紧（base64 膨胀 33%） | :111-152 | 大附件慢网超时误报（原生写继续，窗口期不一致） |
| P1-6/P1-7/P1-10/P2-13/N-3后半/N-4/N-5（遗留确认仍在） | WebDAV 条件写非原子 / PROPFIND 无分页 / 三包超时不取消 / 60s 大文件偏紧 / 翻页整程重试 / verify 全量下载成本 / tmp 跨设备碰撞 | 各包既有备案 | 协议/上游限制为主，已排期（既有方案 4/5/9） |

### 4.3 P3（约 15 项，简列）

GZ-2（gzip 解压后 utf8.decode 未包异常翻译）、GZ-3/SUP-9/P2-12（静态 logger 注入口三处形态分裂）、SUP-8（download 非法 UTF-8 诊断文案缺失）、SUP-10（MetadataPersistFailedException 死契约 + rethrow 死分支）、SUP-11（无状态码保守判瞬时）、SUP-A1/A2/A3（auth 流无回放/catch-all 缺失/MFA 语义粒度）、SUP-R1（realtime connecting 无看门狗，零消费）、SUP-P2/P3（SDK 单例竞态文档/静态 logger 不清理）、BKV-5（_busy 冲突裸 StateError 被 UI 显示为网络失败）、BKV-6（备份内新建账本行与导入非同事务，空壳残留可自愈）、BKV-7（孤儿附件只 warning，BackupOutcome 无缺失数字段）、BKV-8（关密后恢复旧密文备份被误归类「文件损坏」）、SCH-2（backup_time 非法值回落 00:00）、CT-3（getUnpushedCount 全行加载计数）、CT-4（assert-only 契约校验 release 失效）、MET-1（restoreBackup 指标记 snapshotRestore 与 cloudBackup 枚举口径漂移）、ICL-3/6/7、ICL-P1/P3、ICL-A2/A3、N-12~N-17（既有备案维持）。

### 4.4 正面确认（未发现问题的类别）

- **凭据安全**：flutter_secure_storage + 迁移硬失败语义（SEC-03）；WebDAV 强制 HTTPS + 禁自动重定向（S23）+ BasicAuth 预置（W5）+ Digest 兜底；
- **E2EE 旁路**：rawStorage 四调用点均为密钥管理必需；rekey/enableFromCloud 走 rawStorage 天然绕过 gzip 层（GZ-1 修复不与其冲突）；条件写锚点穿透加密装饰层无漂移（P0-2 形态对齐修复在位，encrypted_cloud_storage.dart:150-176）；metadata 加密信封覆盖 S3 小写化、解密失败降级+warning（P2-9）；dispose 级联 + 代次终检防复活；
- **TSM 主链路**：防抖补跑、代次令牌（TSM-P11）、账本锁（TSM-P8）、空壳账本回收（TSM-P10）、跨身份接管防护（TSM-P1）、stale slot 持久化补删（P1-6）、附件顺序协议与三态 drain、原子落盘临时文件序号——全部在位且实现/注释/测试三方一致；
- **启动检查**：两阶段 merge-then-publish、S1 删除复活守卫、H6 回传新鲜度校验、P1-3 失败账本绝不误报「已是最新」、取消/unknown 三态口径自洽；
- **备份恢复侧**：syncId-first 认领（H2）、空快照拒覆盖守卫（P1-1）、附件 sha256 终审+原子落盘、跨进程检查点配对完整（P1-2）、恢复事务 `_purgeStaleLocalChanges`（W4）+ `withRecordingSuppressed`（TBL-S1/M5，且 tracker 为 null 时正确退化为直调——data_import_service.dart:1620-1624 核实）；backup_scheduler 纯函数判定/退避/回拨容差/防重入全部正确；
- **指纹体系**：全序化排序、字段白名单覆盖 9 实体、recurring lastGeneratedDate 排除论证、附件规范化——单一实现双端一致（US-5）；
- **gzip 装饰器本体**（GZ-1 之外）：能力如实申报、二进制透传、Latin-1 桥无损、阈值策略合理——装饰器类内无 bug，问题只在装配位置。

---

## 五、同步成功率监控机制与 99.9% 目标评估

### 5.1 机制核验（全部落地）

| 要素 | 状态 | 证据 |
|---|---|---|
| 六场景埋点 | ✅ snapshotUpload / snapshotRestore / startupCheck / attachmentFill / cloudBackup / remoteDiscovery 全接线 | TSM:1046-1207/1863-1907/2971-3087/3543-3646/1570-1589、checker:280-315、backup_service:410-429 |
| 四态口径 | ✅ success/(success+failed+softFail)，conflict 不入分母 | sync_metrics_service.dart:141-149 |
| 归因 | ✅ classifyError 六类 + Top 聚合 | :236-265 |
| UI 阈值 | ✅ 99.9%/99%/95% 三档图标 + 四态明细 + 诊断导出（用户主动分享，零遥测合规） | sync_health_card.dart:113-119 |
| 滚动清理 | ✅ 30 天窗口双保险（启动 + 上传成功路径） | app.dart:117-119、TSM:1189 |
| 指标注入 | ✅ 共享单例 provider，TSM/备份同源 | sync_providers.dart:176-179/232 |

### 5.2 99.9% 可达性判定（测算）

- **机制侧已达成**：可测、可归因、可导出、隐私合规，六场景全部进分母——「建立监控机制」这一目标在工程上完成。
- **结果侧分层**：
  - 单设备/低并发用户：当前代码即可稳定 ≥99.9%（conflict 不入分母 + 弱网重试归一后 failed 已压到可用性下限）；
  - 双设备高频并发：WebDAV/Supabase 的读后比对窗口 + iCloud 盲写会产生结构性 softFail（数据未收敛的可观测记录），高频并发下会落在 99.5-99.8% 档——这是 last-writer-wins 快照模型的结构性上限，**监控机制如实呈现该差距正是设计目的**；
  - **CT-1 的间接拖累**：local_changes 空转使方向仲裁退化为「unknown → 多弹合并确认」，双设备日常使用的 startupCheck softFail 占比上升、收敛轮次变多——修复 CT-1 是把双设备场景拉回 99.9% 档的**性价比最高的一步**（一行注入，M1/M7/P1-12/P2-1 四条既有防线复活）；
  - **BKV-2 的监控盲区**：改密后历史备份恢复失败会计入 snapshotRestore failed，但用户无法归因到「改密」这一动作——健康卡会显示失败率上升却无从下手；
  - Supabase 缺 file_metadata 表环境：N-2 修复后从「100% failed」恢复为「可工作 + softFail」，不再阻断达标。
- **达标依赖的下一步**（按本报告优先级）：CT-1/GZ-1/BKV-2（声明与实现背离的三项）→ SUP-1/ICL-2/ICL-1（消除误判诱发的覆盖与盲写面）→ N-4/N-5（WebDAV softFail 源头收敛）→ SUP-6（Supabase 元数据对象化）。

---

## 六、优化方案（按优先级排期，供后续实施——本报告不改代码）

### 🔴 立即（P1 九项——「声明与实现背离」三项最优先，均为收益确定的中低改动）

1. **GZ-1 gzip 装配反转**：`provider.storage` 返回 `Gzip(inner: Encrypted(inner: raw))`，数据流改为「压明文 → 加密」。同步动作：① 修三处注释与 commit 语义核对；② 补装配链测试断言「解密后 gzip 魔数 + 压缩率」；③ 核 rekey/enableFromCloud 旁路不受影响（走 rawStorage，天然无交互）；④ 存量云端密文未压缩——下载端嗅探（非 gzip 即透传）天然兼容，无迁移动作。风险中（双向链路回归），收益：E2EE 用户弱网流量恢复设计收益（b1d4cd4 承诺的 85%+ 才真正兑现）。
2. **CT-1 ChangeTracker 生产注入（推荐 a 案）**：`LocalRepository(db, changeTracker: ChangeTracker(db))` 一行改动。同步动作：① 验证 55 处登记点在快照同步模式下无副作用（导入路径已有 withRecordingSuppressed/recordChanges:false 双防线）；② 观察 local_changes 增长与 cleanupPushedChanges 清理闭环；③ 若产品确认增量机制永久下线则改走 b 案（拆除 TSM 读端依赖）。收益：双设备 unknown 冲突显著减少、指纹缓存校验位防线复活。
3. **BKV-2 rekey 覆盖备份目录**：targets 纳入 `piggycount-bak/`，失败走 SYNC-13 回滚；短期先补改密 UI 明示 + 恢复侧 DecryptionException 分类提示。收益：灾难恢复承诺兑现。
4. **SUP-1 路径遍历防护**：`_buildUserPath` 前置分段 `..` 校验 + N-1 同款双形态归一化。验收：`../`、`%2e%2e`、`\..\` 全拒。风险极低。
5. **ICL-2 原生 fileExists 错误透传**：safeURL 失败（1001/1002）返回 error 而非 false。风险低（原生接口变更需过桥测试）。
6. **ICL-1 iCloud eTag 最小接线**：getMetadata/list 用原生 lastModified 填 CloudFile.eTag。验收：冲突探测 cloudETag 非 null。有余力再实现读后比对 ConditionalWriteStorage。
7. **SUP-D1/D2 database 契约收口**：subscribe 改抛 CloudConfigurationException；query 强转防御式。App 零消费，纯包契约，风险低。
8. **BKV-1 短期止血**：先给 createBackup 加附件总量阈值告警 + BackupOutcome 附 attachmentsSkipped（BKV-7 一并）；流式/分卷方案列设计评审。
9. **测试规范固化**（GZ-1 教训）：装饰层/特性类测试必须断言「可观测形态特征」（字节魔数、mock 调用次数、metadata 键值），禁止只断言往返一致。

### 🟠 短期（真实可发生的正确性/性能）

10. **BKV-4/SCH-1 备份可观测与可恢复**：iCloud 补 60s 操作超时；createBackup/restoreBackup 加整体 watchdog（超时释放 _busy）；阻塞弹窗加取消入口；定时备份失败接 onAutoSyncFailure 同款轻反馈。
11. **BKV-3+ECS-1 E2EE 二进制形态统一**：uploadBinary 改走 conditional 真字节通道（与 uploadBinaryConditional 同形态），4 态矩阵收敛为 3 态；补形态对照测试表。
12. **SUP-6+SUP-5 Supabase 元数据对象化迁移**：`FileOptions(metadata:)` 写对象级元数据（读回路径 `_RemoteEntry.metadata` 已就位），file_metadata 表降级兼容读；顺带消除跨用户键风险与缺表退化。
13. **SUP-7/SUP-4**：list 目录占位过滤（对齐 S3）；条件写锚点改 `id`/`id+updatedAt` + SearchOptions.search 免全页扫描。
14. **SUP-P1/SUP-D3/D4**：dispose 释放 SDK 单例；批量回退聚合错误清单 + dev.log 收编；分页截断告警。
15. **ICL-5/ICL-4 iCloud sidecar 原子性**：storeMetadata 接受协调后 URL；getMetadata 读不到 sidecar 标记 metadataMissing 供 manager 区分竞态与真缺失。
16. **既有排期维持**：N-4（WebDAV verify 缓存预填）、N-5（tmp 设备随机因子）、方案 8（P2-11 认证异常归一）。

### 🟡 中期（性能与可观测）

17. **既有方案 9**：WebDAV 超时自适应 30s+30s/MB、S3 流式接入附件路径、readAsBytes 内存峰值（与 BKV-1 流式方案合并评审）。
18. **iCloud 日志收编**（LOG-01 唯一漏网包）：注入 CloudSyncLogger，原生 print/debugPrint 全替换；顺带 ICL-A2 初始化留痕。
19. **ICL-A1 系统账号变更监听**：ubiquityIdentityDidChange NSNotification → EventChannel → authStateChanges 真实事件流。
20. **监控粒度**（既有方案 11 + MET-1）：attachmentFill 真实 attempts 透传；startupCheck backend 记实际后端；restoreBackup scenario 口径与枚举注释统一。

### ⚪ 治理（一致性债）

21. **既有方案 12/13 维持**：RetryPolicy 常量包、四静态 logger 注入口统一命名（GZ-3 一并）、list metadata 契约文档化、异常兄弟类警示；SUP-10 死契约清理；SUP-2 宽词收紧；CT-2/CT-3/CT-4（tracker 复活后的原子性/计数/断言三项）；ICL-P1/P3、BKV-5/6/8、SCH-2。

### 实施优先级总览

| 优先级 | 方案 | 工作量 | 受益 |
|---|---|---|---|
| 🔴 立即 | 1~9（装配反转/tracker 注入/rekey 备份/路径防护/exists/eTag/契约/止血/测试规范） | 小-中 | 压缩兑现 / 双设备收敛 / 灾备兑现 / 安全承诺 / 99.9% 拉升 |
| 🟠 短期 | 10~16（备份可观测/E2EE 形态/Supabase 元数据/iCloud sidecar） | 中 | 正确性 + 弱网成功率 |
| 🟡 中期 | 17~20（流式/日志/账号监听/监控粒度） | 中 | 大附件 + 可观测 |
| ⚪ 治理 | 21（常量化/命名/契约文档/死代码） | 中 | 归一化防回归 |

---

## 七、结论

1. **归一化判定**：数据处理逻辑（序列化/槽位/指纹/附件/触发入口）已单点收敛、完全归一；同步策略（冲突探测/条件写/写后校验/完整性终审/破坏性互斥）达到各协议原生能力上限，唯一实质缺口是 iCloud 连最弱形态锚点都未透出（ICL-1）；错误处理（异常体系/重试纪律/超时档位/日志留痕/指标归因）在 S3/WebDAV 侧完整归一，Supabase/iCloud 侧存在 4 项 P1 与若干 P2 契约偏差——但该两后端当前对用户隐藏（`_kShowSupabaseAndICloud = false`，cloud_service_page.dart:36），生产暴露面收窄，**偏差属「包质量债」而非「用户可感故障」**。
2. **本轮最重要的发现类型是「声明与实现背离」**（GZ-1/CT-1/BKV-2 三连）：三层注释与装配链测试共同掩盖 gzip 失效、55 处登记点因未注入而全空转、rekey 白名单漏掉备份目录——它们的共性是**设计文档、注释、甚至测试标题都宣称特性在位，但没有任何断言验证「特性真正发生」**。修复动作之外，第 9 项「测试必须断言可观测形态特征」应作为防回归规范固化。
3. **S3/WebDAV（实际发布后端）**：经六批修复 + fcf182d 十项收口，三维均达高水位；遗留项（WebDAV 条件写窗口、PROPFIND 无分页、verify 成本、tmp 碰撞）全部为已知、已备案、已排期的协议边界问题，无新发现的正确性缺陷。
4. **App 层主链路**：既有防线（TSM-P8/P10/P11/P14、A5、C3、H6、S1、P1-5、G5）全部在位；**唯一架构级缺口是 CT-1**——防线代码完好但生产未通电；备份侧 BKV-1/BKV-2 是备份链路的两个真实风险点。
5. **监控与 99.9%**：机制完整落地（六场景/四态/阈值/导出/隐私合规）；单设备用户可达成；双设备高频并发受 last-writer-wins 结构性上限约束（99.5-99.8% 档），**修复 CT-1 是拉升双设备达标性价比最高的一步**，其后是 ICL-1/N-4/N-5 的 softFail 源头收敛。监控机制会把未收敛场景如实呈现为 softFail——这正是设计目的，不应为凑指标把 softFail 移出分母。
6. 本报告为**只读排查产物，未修改任何代码**；全部优化方案见第六章，实施时须遵守 `docs/sync-reliability-params.md` 参数纪律并以 1145 项全库测试（1 skip）为回归基线；GZ-1/CT-1 类「通电即改变生产行为」的修复建议单独成批、独立回归。

---

## 附录：证据索引（本轮主会话独立核验关键点）

| 主题 | 文件:行号 |
|---|---|
| core 契约（条件写/二进制能力/归一化） | storage_service.dart:163-267、cloud_sync_manager.dart:180-312/450-695、exceptions.dart:43-62、retry_helper.dart:191-236 |
| S3 客户端（超时/重试/条件写/分页/错误翻译） | s3_client.dart:59-77/134-176/249-399/995-1267/1488-1586 |
| S3 存储（keyPrefix/遍历/元数据 b64） | s3_storage_service.dart:22-68/350-384/441-523 |
| WebDAV 原子发布/降级交换/信封/超时取消 | webdav_storage_service.dart:94-242/303-341/393-480/696-716/774-796 |
| WebDAV provider（HTTPS 强制/重定向拒绝/Digest 兜底） | webdav_provider.dart:113-291/335-348 |
| TSM 主链路（防抖/代次/锁/上传/恢复/附件/发现/导入） | transactions_sync_manager.dart:167-244/296-316/402-691/945-1211/1532-1770/2434-2530/3389-3657 |
| **GZ-1 装配链（gzip 加密顺序）** | transactions_sync_manager.dart:637-651、gzip_cloud_storage.dart:89-119、encrypted_cloud_provider.dart:36-51、encrypted_cloud_storage.dart:110-134 |
| **CT-1 tracker 注入缺口** | database_providers.dart:17-25、local_repository.dart:38/56/134+（55 处登记）、transactions_sync_manager.dart:891-923/2303-2352、change_tracker.dart 全文 |
| **BKV-2 rekey 白名单** | encryption_service_impl.dart:696-730、cloud_backup_service.dart:311-321/430 |
| **BKV-1 备份内存装配** | cloud_backup_service.dart:183-226 |
| 恢复导入抑制/清防（CT-1 缓解面核实） | data_import_service.dart:1613-1624/1657-1664、cloud_backup_service.dart:294-302/431-444 |
| 启动检查（超时档/并发探测/两阶段/S1/H6） | startup_sync_checker.dart:280-596/606-660/700-736/751-980 |
| 指纹（全序化/字段白名单） | sync_fingerprint.dart:43-343 |
| 监控（口径/清理/健康卡） | sync_metrics_service.dart:10-150、sync_health_card.dart:30-130、sync_providers.dart:173-243 |
| 埋点接线 | transactions_sync_manager.dart:258-289/1046-1207、startup_sync_checker.dart:295-315、app.dart:113-121 |
| Supabase/iCloud 深审（子代理，P1 已主会话抽验） | supabase_storage_service.dart:101-114/256-318/633-642、supabase_database_service.dart:229-240、supabase_provider.dart:179-192、icloud_storage_service.dart:26-27/180-204/267-299、ICloudManager.swift:460-464/596-616 |

