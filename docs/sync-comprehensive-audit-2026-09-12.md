# PiggyCount 同步功能全面系统性排查报告（2026-09-12）

- **排查日期**：2026-09-12
- **排查方式**：只读静态代码审计（**未修改任何代码**）+ 全库测试套件执行验证
- **排查范围**：全部同步功能——S3 协议包、WebDAV 协议包、Supabase 协议包、iCloud 协议包、core 同步框架（flutter_cloud_sync）、App 层快照同步主链路（TransactionsSyncManager 3823 行）、启动检查编排器、diff/指纹/变更追踪、gzip 压缩层、云端备份调度与跨进程检查点、端到端加密装饰层、同步成功率监控机制
- **对照基线**：`docs/sync-comprehensive-audit-2026-09-10.md`（上轮全面审计）+ 其 §八记录的六批修复 + `docs/sync-reliability-params.md`（参数权威口径）
- **本次排查定位**：上轮审计后已实施六批修复（P0-1/P1-1~5/P1-8/P1-9/P1-12/P2-6~9/P2-2①③/P2-10/P2-15 等）。本轮的任务是：① 逐项核验已声明修复的落地质量与修复引入的新问题；② 确认遗留问题现状；③ 挖掘此前未发现的全新问题；④ 重新评估归一化程度与 99.9% 监控目标的可达性。

---

## 0. 摘要（TL;DR）

**总体结论：上轮审计的全部 P0 与关键 P1 修复均已真实落地且质量高（含测试回归），六批修复未引入 P0 级回归；全库 1145 项测试通过（1 skip）、0 失败。归一化短板（Supabase/iCloud）已在协议能力层面补齐，剩余偏差集中在「实现语义细节」与「跨模块一致性债」。本轮新发现 1 项 P1（WebDAV 路径校验编码盲区）与 20+ 项 P2/P3 级问题，无新增 P0。**

监控机制评估：**六场景埋点已全覆盖（startupCheck 于 2026-09-11 补齐）、四态口径清晰、健康卡 99.9% 阈值已预置**。机制本身已具备「测得出 99.9%」的完整链路；能否**达到** 99.9% 取决于本报告第五章列出的结构性失败源是否修复（弱网重试已归一、Supabase 翻页已修，剩余主要为 WebDAV 条件写窗口与若干 softFail 源头）。

| # | 问题 | 级别 | 一句话 |
|---|---|---|---|
| 1 | WebDAV 路径校验存在编码盲区：`%2e%2e` 与反斜杠 `\` 可绕过 `..` 分段校验 | **P1** | 配置导入通道可构造越权前缀外路径（依赖服务器解码行为，但客户端自认安全是错误承诺） |
| 2 | Supabase `_storeMetadata` 失败抛异常使整个 upload 上抛——与修复声明的「softFail 而非 failed」语义存在偏差 | P1/P2 待定 | file_metadata 表未建的环境下 Supabase 快照上传 100% 硬失败（此前是静默降级可工作） |
| 3 | Supabase `_opRetryable` 包住整次翻页循环：中间页失败重试从头再来，大目录流量放大 | P2 | exists()/list() 在多页目录上重试成本翻倍 |
| 4 | WebDAV 写后校验的固定全量下载成本（上传必变 eTag → 缓存必 miss → verify 触发主文件完整 GET） | P2 | WebDAV 每次快照上传后多付一次全量下载，弱网拖慢上传链 |
| 5 | WebDAV 跨设备 tmp 文件名碰撞 → 附件路径无写后校验兜底，云端对象可被静默污染 | P2 | 附件 `attachments/<sha>.bin` 名实不符且无告警 |
| 6 | S3 ListObjects XML 解析不识别命名空间前缀 → 静默空列表，三重护栏全失效 | P2 | 第三方网关兼容面：附件清理/发现/探测全拿空桶视图 |
| 7 | S3 网关能力记忆误记后本会话不可恢复 + 特征匹配过宽（body 含 "notimplemented" 即命中） | P2 | 偶发误报使原子条件写防线静默降级至 provider 重建 |
| 8 | Supabase `_isTransient` 字符串匹配过宽（`contains('network')`/`contains('timeout')`） | P2 | 4xx/确定性错误消息含这些词时被误判为可重试，浪费重试预算 |
| 9 | iCloud 旧格式嗅探歧义面（二进制恰好整段合法 base64 文本 → 误解包） | P3 | 附件 sha256 终审兜底，误判不落脏数据，但对象级误读可能 |
| 10 | gzip 压缩仅 E2EE 开启时装配（明文用户零收益）+ S3 流式能力未接入附件大文件路径 | P2 | 性能优化只覆盖加密用户；附件仍 readAsBytes 全量入内存 |

---

## 一、排查方法与工作区核验

- **测试执行**：`flutter test` 全库 **1145 项通过 / 1 项 skip / 0 失败**（exit 0）。skip 项为 TCP 探测类环境依赖用例（WebDAV BasicAuth 预置集成测试），非功能缺口。
- **静态审计**：双路并行——子代理逐行精读 S3（1538 行 s3_client）/WebDAV（974 行）/core manager（745 行）及配套契约/测试；主会话逐行精读 Supabase/iCloud 包、gzip 层、加密装饰层、TSM 上传/恢复主链路、启动检查器、备份服务、监控服务，并交叉验证装配链与测试断言强度。
- **工作区核验**：`git status` 干净（本报告为唯一新增产物），未修改任何代码，符合「只做排查不改代码」约束。
- 证据规范：全部结论带 `文件:行号`；上轮修复的核验同时对照实现注释、调用方消费链与测试断言三方。

---

## 二、上轮修复落地核验（六批逐项）

### 2.1 修复核验表

| 修复项 | 状态 | 证据 | 核验结论 |
|---|---|---|---|
| **P0-1 Supabase listPaginated 游标翻页** | ✅ 落地 | supabase_storage_service.dart:437-525（list 全量翻页）、:301-331（_probeRawMetadata 翻页定位，exists/getMetadata/条件写探测共用）、:64-69（_pageLimit=1000、_maxPages=100 护栏） | 截断根因已消除；翻页终止条件 `!hasNext \|\| nextCursor==null` 双重判定，护栏触发后静默停止（见新发现 N-3：护栏触达无告警）。**测试为短板**：supabase_pagination_conditional_test.dart 只测能力申报/未登录门禁/类型契约，翻页循环本体（多页聚合、游标推进）依赖真实网络，零用例覆盖——注释自认「网络路径依赖真实 Supabase（单测不覆盖）」 |
| **P1-1 Supabase ConditionalWriteStorage（updatedAt 锚点）** | ✅ 落地 | supabase_storage_service.dart:237-297（探测→比对→upsert）、:333-336（_etagOf=updatedAt，注释论证覆盖写必刷新） | 读后比对近似语义正确，与 WebDAV 同取舍（窗口收窄非原子+写后校验兜底）；探测步走 `_opRetryable` 可重试，比对通过后 `_uploadBytes` 不重试（非幂等纪律保持） |
| **P1-1b CloudFile.path 相对路径口径** | ✅ 落地 | supabase_storage_service.dart:443-474（list 相对路径）、:573-575（getMetadata 原样回传）、:603-612（_buildUserPath 统一重加前缀） | 双前缀风险消除；list 条目 `path=PathHelper.join([path, obj.name])` 与入参目录一致，可安全回传 delete/exists |
| **P1-1c MetadataPersistFailedException** | ✅ 落地（语义见新发现 N-2） | supabase_storage_service.dart:614-645（幂等重试 1 次后抛）、:700-709（CloudStorageException 子类） | 异常层级正确；但**上抛路径与声明不符**——声称为「manager 写后校验读不到指纹 → verified=false → softFail」，实测代码路径是 `_uploadBytes` 内 `_storeMetadata` 异常直接冒出 `upload()`，manager 的 upload 流程 catch 后按 `CloudStorageException` 整体上抛（cloud_sync_manager.dart:278-284），TSM 记 **failed** 而非 softFail（详见 N-2） |
| **P1-8 Supabase/iCloud 幂等读重试** | ✅ 落地 | supabase_storage_service.dart:112-164（_opRetryable，Random() 真随机源、2 次、400/800ms ±50%、认证/404 不耗预算、逐次 logger）；icloud_storage_service.dart:42-59（_retryIdempotent 同参数表） | 参数与 `sync-reliability-params.md` §二一致；jitter 真随机（`Random()` 实例字段，非时间戳取模）。**注意**：Supabase `_isTransient` 的字符串兜底 `contains('network')/'timeout'/'connection'` 过宽（见 N-8）；iCloud 判定粒度较粗但方向正确（非 NOT_FOUND 的 PlatformException 均重试） |
| **P1-9 Supabase 空目录 404 → 空列表** | ✅ 落地 | supabase_storage_service.dart:476-483 | 三包收敛语义对齐（WebDAV/iCloud 同款） |
| **P1-5 iCloud BinaryCapableStorage + 嗅探** | ✅ 落地（嗅探歧义面见 N-9） | icloud_storage_service.dart:132-152（uploadBinary 单次 base64 直达）、:154-191（downloadBinary 旧格式嗅探 `_unwrapLegacyBase64Text`） | 双重编码消除；嗅探实现：`String.fromCharCodes(bytes)` 后校验「全 base64 字符集 + 可解码」双条件，二进制附件几乎不可能整段通过双重校验（实现注释自认误判面极窄 + 调用方 sha256 终审兜底）。残留边界：**嗅探用 `String.fromCharCodes` 而非严格 UTF-8 校验**（对比 encrypted_cloud_storage.dart:238-244 用 `utf8.decode` try/catch）——任意字节均可 fromCharCodes 成功，第一道闸只剩字符集正则，理论歧义面比注释声称的略宽（N-9） |
| **P1-3 startupCheck 埋点** | ✅ 落地且口径自洽 | startup_sync_checker.dart:229-315（Deps.metrics 注入 + runIfNeeded finally 单点四态记录，backend='startup'、整轮 duration）；:427（用户取消→softFail）、:463/:522/:535（探测失败/激活失败→failed）、:559（unknownDiff→softFail）、:580（skip→不计失败也不计成功，与注释声明一致：走完主流程即 success） | 多账本部分失败聚合为一条整轮记录（failedLedgers 非空→failed），单条聚合口径在文档中有明确声明；冲突态本链路不产生。P1-12 修复（localUpdatedAtTrusted）也在（cloud_sync_manager.dart:611-648，正反用例 cloud_sync_manager_test.dart:415-462） |
| **P1-4 softFail 可见化** | ✅ 落地 | transactions_sync_manager.dart:1196-1198（返回 `({bool verified})`）；消费端见 ledgers_page_new/cloud_sync_page（l10n×4 已配） | TSM 侧 verified=false 时不清脏标记、不 markSnapshotPushed、不登记 _recentUpload/状态缓存（:1124-1164 全链核验）——与指标 softFail（:1133）双路上浮 |
| **P1-2 备份恢复跨进程检查点** | ✅ 落地 | cloud_backup_service.dart:294-302（恢复前置位）、:431-444（finally 清除，清除失败保守保留）、:283-290（_busy+SyncRestoreGuard 双防重入）；app.dart:202-206（调度器 tick 检查让位，手动备份不受限）；cloud_sync_page.dart:344-356（恢复入口检测残留弹提示） | 四点全落地。置位在 SyncRestoreGuard.begin() 之后、下载开始之前；写失败不阻断恢复（键缺失=少一层防护，不比现状差，注释有论证）。见 N-12 的边界观察 |
| **P2-2①③ 导出伴随字段 + gzip 压缩** | ✅ 落地 | transactions_json.dart（ExportedLedgerJson）；TSM:1005-1022（伴随字段直取，不再二次 jsonDecode）；gzip_cloud_storage.dart 全文；装配链测试 encrypted_cloud_provider_test.dart:133-164（压缩→加密→解密→解压完整往返断言 rawStored 为 BEECRYPT1 密文、download 恒等） | 装配顺序核验：TSM:637-649 `raw → Gzip → Encrypted`，E2EE 未开启不装配 gzip（明文历史对象永不压缩，零回滚）；rekey/enableFromCloud 三入口均传 `_rawStorage`（TSM:629 注释+代码路径核验），与 gzip 层零交互。gzip 层条件写/二进制能力镜像透传（gzip_cloud_storage.dart:130-194），conditionalOrNull 按能力如实解析（storage_service.dart:223-232）——**条件写链锚点语义核验**：gzip 层 uploadBinaryConditional 直接把上层（加密层产出的）密文字节透传给 inner 的条件写，锚点（If-Match/updatedAt）作用于云端密文对象本体，与裸存储语义一致，无锚点漂移。Latin-1 桥（:59-70）0-255 全域无损。嗅探三态顺序：先 gzip 魔数后 BEECRYPT1 判断——实际互斥（gzip 落盘内容以 1f 8b 开头、密文以 BEECRYPT1: 文本开头），歧义面为零 |
| **P2-6/P2-7/P2-8/P2-9 监控收尾** | ✅ 全落地 | TSM:2880-3103（downloadRemoteLedger 四态：success/对象缺失 softFail/空快照守卫 softFail/异常 failed）；app.dart:117-119（cleanupExpired 启动接线）+ TSM:1189（上传成功路径双保险）+ sync_providers.dart:184（死代码已删）；TSM:52（onAutoSyncFailure 回调，分层正确）；encrypted_cloud_storage.dart:96-106（logger.warning 升级，措辞含排查指引） | 全部核验通过。onAutoSyncFailure 经 provider 刷状态卡不弹 toast（分层与 UX 取舍均有注释论证） |
| **P2-10 死代码收缩** | ✅ 落地 | supabase_provider.dart:33-34/74-79（database/realtime getter 懒装配）、:144（initialize 不再实例化）、:181-186（dispose 链自洽：懒创建后 dispose 仍可清理 null 安全）；公开 getter 契约不变 | App 同步链只用 auth+storage 即时创建，懒装配无残留无条件实例化 |
| **P2-15 UI/接线测试补齐** | ✅ 落地 | test/widgets/upload_conflict_guard_test.dart（8 用例：三选一/二选一/方向文案/非冲突透传）、test/widgets/sync_health_card_test.dart（5 用例：空窗口/四态/conflict 不入分母/softFail 拉低/Top 错误）、test/cloud/transactions_sync_manager_test.dart（埋点接线断言：真实落库+no-op 不影响主流程） | 数据安全交互与 99.9% 阈值渲染不再纯靠人工；断言强度合格（三选一各分支行为+方向断言，非仅"不崩溃"） |

### 2.2 核验总结

六批修复**无一虚假声明**：每项都能在实现、调用方消费链、测试三方对上。上轮 P0（Supabase 截断）的根因消除路径正确。

**唯一需要重点关注的语义偏差**是 P1-1c（N-2）：修复声明「metadata 写失败 → 上传记 softFail」，实际代码路径是整个 upload 异常上抛 → TSM 记 **failed**。这不是数据安全问题（fail-hard 优于静默降级），但：
1. 与修复文档/异常注释声明的行为不符；
2. **行为变化面**：旧版（静默降级）在 file_metadata 表未建的环境下快照上传仍可成功（只是指纹缺失走全量下载兜底）；新版在该环境下 **Supabase 上传 100% 硬失败**。对存量用户若存在「从未建 file_metadata 表但用 Supabase」的部署（表由 SQL 引导文档提供，非 App 自动迁移），升级即从「能同步」变「完全不能同步」——这是修复引入的最大行为回归风险。

---

## 三、遗留问题现状（上轮判定「不在近期批次」的 11 项全部仍在原位）

| # | 问题 | 现状 | 证据 |
|---|---|---|---|
| P1-6 | WebDAV 条件写读后比对非原子 | 仍在（代码自认，注释明示窗口收窄非原子） | webdav_storage_service.dart:302-341 |
| P1-7 | WebDAV 大目录 PROPFIND 无分页/截断检测 | 仍在 | webdav_storage_service.dart:589-596（上游 webdav_client 1.2.2 无分页参数） |
| P1-10 | S3/Supabase/iCloud 超时不取消底层请求 | 仍在（dart:http 无取消机制；Supabase 仅 `.timeout` 包装，supabase_storage_service.dart:105-110）；危害已被条件写锚点+写后校验部分缓解 | s3_client.dart:294-296/746-748 vs webdav:228-237（CancelToken 仅 WebDAV 有） |
| P2-1 | core RetryHelper 生产零调用 | 仍在（已文档化备案，sync-reliability-params.md §四） | grep 全库仅 example/test 引用 |
| P2-3 | list 条目 metadata 口径不一 | 仍在 | S3 不带（s3_storage_service.dart:453-462）/ WebDAV 空常量（webdav:621）/ Supabase 带（supabase:468） |
| P2-4 | exists() 成本分级差异 | 仍在（S3 单 HEAD vs WebDAV/Supabase 父目录列举；Supabase 翻页后大目录成本进一步上升，但 exists 定位走 _probeRawMetadata 提前命中即返回——:313-326 命中即 return，非全量拉完，成本可控） | webdav:645-674；supabase:301-331 |
| P2-5→P1-1b | Supabase path 口径分裂 | **已修**（本轮核验，见 §2.1） | — |
| P2-11 | WebDAV/iCloud auth 服务抛 UnsupportedError（Error 穿透 Exception catch）；iCloud 无认证异常分类 | 仍在 | webdav_auth_service.dart:56/63/69/74；icloud_auth_service.dart:80-141（四方法 UnsupportedError） |
| P2-12 | 静态 logger 注入口三名分裂 | 仍在（实际已扩为四名：S3 downgradeLogger / WebDAV storageLogger / Supabase storageLogger / Gzip compressionLogger，全静态可变） | provider_factory.dart 装配处 |
| P2-13 | WebDAV 统一 60s 超时对大附件偏紧 | 仍在 | webdav_storage_service.dart:94 vs s3_client.dart:71-77 |
| P2-14 | S3 流式上传/下载已建未接入业务 | 仍在（附件仍 `File.readAsBytes()` 全量入内存） | TSM:1413-1414；s3_storage_service.dart:122-211 零业务调用 |
| 兄弟类 | CloudPreconditionFailedException 与 CloudStorageException 互不捕获的隐性契约 | 仍在（无踩坑点，全库专门 catch 仅 TSM:1106） | exceptions.dart:57 vs :30 |

---

## 四、本轮新发现问题清单（按严重级）

### P1（1 项）

**N-1 WebDAV 路径校验存在编码盲区：URL 编码 `%2e%2e` 与反斜杠 `\` 可绕过 `..` 分段校验**
- 证据：校验按未解码的 `/` 分段做 `..` 匹配——webdav_provider.dart:130-135（remotePath 校验）与 webdav_storage_service.dart:767-779（`_assertNoTraversal`）；path_helper.dart:14-27（normalize 只处理 `/`，无 URL 解码步骤）。
- 攻击面：配置导入通道（config JSON 携带 remotePath）。`'/piggy/%2e%2e/shared'` 或 `'/piggy\..\shared'` 的 `split('/')` 均无段恰为 `..` → 客户端校验放行；服务器侧（IIS/Windows mod_dav 等对 `\` 与百分号解码的实现）可能归一化后逃逸 remotePath 沙箱，越权读写前缀外目录。
- 定级依据：需要恶意/损坏的配置文件导入才触发（攻击者需诱导用户导入配置），且依赖服务器端解码行为——非默认远程利用，故 P1 而非 P0。但「客户端校验自认安全」是错误承诺，且 S3 侧同款校验因 key 无解码语义不可利用、问题只在 WebDAV 真实。
- 修复建议：校验前防御性归一化——`path.replaceAll('\\','/')` + 尝试 `Uri.decodeComponent` 后再分段校验（解码失败保持原判定）；或直接拒绝含 `\`/`%` 的 remotePath 配置。成本极低。

### P2（10 项）

**N-2 Supabase MetadataPersistFailedException 上抛路径与「softFail」声明不符 + 环境缺表时上传从可工作变为 100% 硬失败**
- 证据：supabase_storage_service.dart:222-224（upload 成功后调 _storeMetadata）→ :638-641（失败抛异常）→ 异常冒出 `_uploadBytes` 的 catch（:227-234 仅对非 Cloud 异常包装，`MetadataPersistFailedException` is CloudStorageException → rethrow）→ manager upload 的 catch（cloud_sync_manager.dart:278-284，is CloudSyncException → rethrow）→ TSM:1199-1207 catch 记 **failed**。
- 对照声明：「manager 写后校验会以 verified=false 上浮（softFail 而非假 success）」（supabase_storage_service.dart:36-38 注释、docs 审计 §八）——实际 manager 层根本走不到写后校验（异常在 upload 主体已上抛）。
- 影响：① 指标口径——该场景计 failed 而非 softFail，与文档不一致（监控归因误差）；② **行为回归**——file_metadata 表未建的存量 Supabase 环境，旧版静默降级仍可同步，新版 100% 上传失败。数据安全无损（fail-hard 方向正确），可用性回归未在文档中披露。
- 修复建议（三选一）：a) _storeMetadata 失败改为「计入上传结果信号」而不上抛（返回 metadataPersisted=false，由 manager 写后校验自然 verified=false → softFail，与声明对齐）；b) 保持上抛但把 TSM 侧该异常识别为 softFail 计量；c) 至少更新两处注释+审计文档，明确「failed」语义，并评估存量环境缺表场景（启动探测/文档指引）。推荐 a（与原设计意图一致）。

**N-3 Supabase 翻页护栏触达静默停止 + 翻页重试从头再来**
- 证据：supabase_storage_service.dart:504-524（_listAllObjects：for 循环上限 _maxPages=100，触达即返回已收集条目，无日志无告警）；:117-140（_opRetryable 包住 `_listAllObjects` **整次翻页循环**——中间第 50 页失败重试时从第 1 页重新拉取）。
- 影响：① 目录 >10 万对象（100 页×1000）时 list 静默截断——比旧 P0 的 100 条阈值高了 3 个数量级，实际触达概率极低但形态相同（静默）；② 大目录弱网重试成本翻倍：一次 list 中间页抖动 → 整目录重拉。
- 修复建议：护栏触达时 logger.warning（观测性即可，阈值已足够高）；重试粒度改为单页级（把翻页循环移出 _opRetryable 或 _opRetryable 接受游标续传）——后者改动较大，可先做护栏告警。

**N-4 WebDAV 写后校验固定全量下载成本**
- 证据：缓存键 `'$fullPath\u0000$eTag'`（webdav_storage_service.dart:696-716）；上传（MOVE/降级交换）必刷新 eTag → 下一次 `_verifyAfterUpload`（cloud_sync_manager.dart:293-312）的 getMetadata 缓存必 miss → `_resolveCustomMetadata`（webdav:747-760）对主文件发起完整 GET。S3 同操作是 HEAD 零下载。
- 影响：WebDAV 大账本快照每次上传后固定多付一次全量下载，弱网显著拖慢上传链路并增加 softFail（verified 读取超时降级放行为 true，但耗时真实存在）。
- 修复建议：`_atomicPublish` 成功后用本次已知 payload/metadata 预填 M10 缓存（本地知道信封内容与 eTag 已变更的事实）；或 manager 层对 WebDAV 后端将 verify 顺延到下次 getStatus。

**N-5 WebDAV 跨设备 tmp 文件名碰撞 → 附件路径静默污染**
- 证据：tmp 名 `'$fullPath.tmp.${millisecondsSinceEpoch}_${_tempSeq++}'`（webdav_storage_service.dart:394-395），`_tempSeq` 是进程内 static（:103）——只防同进程并发；跨设备同 fullPath + 时钟同毫秒 + 序号同值 → 双方写同一 tmp 对象，后写覆盖先写 → 先 MOVE 者发布**对方 payload**，后 MOVE 吃 404 但被 `_moveLandedAnyway`（:426-431/482-502）误判成功。
- 影响分级：账本快照路径有 manager 写后校验兜底（verified=false → softFail，损失受控）；**附件路径（TSM:1414 uploadBinaryOrFallback）绕过 manager 无写后校验** → `attachments/<sha>.bin` 名实不符，恢复端 sha256 终审会拒绝该对象（数据不落地）但云端对象永久污染且无告警。
- 触发概率：低（需同毫秒+同序号），但附件对象生命周期长（内容寻址永不重写），一次污染永久残留。
- 修复建议：tmp 名掺入设备级随机因子（启动时一次性 UUID 前缀）；或 tmp PUT 改用 `If-None-Match: *` 幂等创建语义（webdav_client 不透传条件头则退化为设备 ID 方案）。

**N-6 S3 ListObjects XML 解析不识别命名空间前缀 → 静默空列表且三重护栏全失效**
- 证据：s3_client.dart:1300-1341——`findAllElements('Contents'/'IsTruncated'/'NextContinuationToken')` 按字面名匹配（dart xml 包不剥前缀），带 `<s3:Contents>` 前缀的网关响应解析出 0 对象 + isTruncated=false → 返回 `[]` 不抛错。
- 影响：与解析失败抛错的护栏（S-M1，:1333-1340）不同，此形态**不抛错**——附件清理、远程账本发现、连接探测（探测会「成功」返回空桶）全部静默拿到空桶视图。AWS/MinIO/R2/OSS 主流不带前缀，第三方小网关存在此形态。
- 修复建议：关键元素改 `localName` 匹配（`e.name.local == 'Contents'`）；或 0 对象时校验根元素名 `ListBucketResult`。成本低。

**N-7 S3 网关能力记忆误记不可恢复 + 特征匹配过宽**
- 证据：s3_client.dart:629-638（`_isConditionalHeaderNotSupported`：body 小写含 `notimplemented` **单独**即命中）；:309-317（首次命中即写 `_conditionalWriteUnsupported=true`，此后本 client 全生命周期静默盲写，无 TTL 无重试探针）。
- 影响：任何 400 错误体恰含 "NotImplemented" 字样的偶发误报（如网关把「不支持某 x-amz-meta 头」也报 NotImplemented）都会使 S3 原子条件写防线静默失效至 provider 重建。后果由写后校验兜底（不丢数据），但并发防护无声降级。
- 修复建议：收紧特征——要求 `not implemented` 与 `if-match/if-none-match/a header you provided` 关键词同时出现；记忆加轻量重试探针（N 次上传后用一次条件写复探）。

**N-8 Supabase `_isTransient` 字符串匹配过宽**
- 证据：supabase_storage_service.dart:145-164——SDK 异常无 statusCode 时返回 true 合理；但 root 非 StorageException 时的文本兜底 `contains('network')/contains('timeout')/contains('connection')` 过宽。典型误判：Storage API 的确定性 4xx 若消息含 "network" 字样（如错误提示文案）会被重试 2 次浪费 400/800ms 延迟。
- 影响：仅浪费重试预算（非幂等写不经过此路径，无数据风险），归因准确度受损。
- 修复建议：兜底匹配收紧为异常类型（SocketException/TimeoutException 的 `runtimeType` 判定）而非 toString 子串；或至少移除 'network'/'connection' 两个过宽词。

**N-9 iCloud 旧格式嗅探的字符集判定比声明宽松**
- 证据：icloud_storage_service.dart:179-191——`String.fromCharCodes(bytes)`（任意字节均成功，非 UTF-8 校验）→ 唯一闸门是 base64 字符集正则 + 可解码。对比加密装饰器同功能用严格 `utf8.decode` try/catch（encrypted_cloud_storage.dart:238-244）。一段以 ASCII 字符构成、整体恰好是合法 base64 的**新格式原始二进制**（如恰好全 ASCII 的 .bin）会被误解包返回内层垃圾字节。
- 影响：附件 sha256 终审兜底（恢复端拒绝哈希不符对象），数据不落脏；但对象级误读 + 终审拒绝的组合会表现为「附件永远补不齐」，诊断成本高。
- 修复建议：嗅探第一闸改 `utf8.decode` 严格校验（与加密装饰器同款），歧义面归零；旧 base64 文本对象本来就是合法 UTF-8，行为不变。

**N-10 gzip 压缩仅覆盖 E2EE 用户 + 压缩统计无指标化**
- 证据：TSM:641-643（加密未开启不装配 gzip——正确取舍，注释论证了明文可读性零回滚）；gzip_cloud_storage.dart:110-112（压缩收益只有 logger.info 文本日志）。
- 影响：非加密用户（快照明文 JSON）弱网流量无优化——上轮审计 P2-2③ 的收益只落到加密用户；明文用户若未来要压缩需处理「新旧版本可读性」兼容（属产品决策，非缺陷）。压缩收益（流量/耗时下降）无结构化指标，效果不可度量。
- 修复建议：① 非加密装配方案需产品决策（可考虑对象内嵌格式版本键，读端嗅探，旧版 App 遇到压缩对象会失败——故默认不推荐，仅记录）；② 压缩统计结构化（进 sync_op_log 的 metadata 或独立计数器）。

**N-11 S3 getObject 超时异常消息与实际档位不符（报 30s 实际 90s）+ putObjectStream contentLength 缺省按 0 字节档**
- 证据：s3_client.dart:729/746-748（实际 `_getObjectTimeout=90s`）；:762-763（消息用元数据档 `timeout` 30s）；:504（`transferTimeoutFor(contentLength ?? 0)`——chunked 传输大文件弱网必超时，当前业务零调用未触发，P2-14 接入前必修）。
- 影响：排障误导 + 未来接入流式时的隐性坑。
- 修复建议：消息改用实际档位；putObjectStream contentLength=null 时给保守上限档（5min cap）。

### P3（6 项，简列）

| # | 问题 | 证据 | 修复建议 |
|---|---|---|---|
| N-12 | 备份检查点置位与下载开始之间存在窗口（置位成功后、下载失败早退时键已清除——finally 兜底正确；真正缺口是置位前进程崩溃：恢复刚点击即崩，键未写，无残留问题。**实际无缺口**，本项降级为备案观察：SharedPreferences 写失败时静默 continue，恢复在无跨进程防护下进行（仅内存 Guard），与修复注释自认一致） | cloud_backup_service.dart:299-302 | 可接受现状；如需完备可改用 DB 表标记（随事务落盘） |
| N-13 | Supabase CloudPreconditionFailedException 单参构造污染 path 字段（S3/WebDAV 均双参） | supabase_storage_service.dart:273-286 | 改双参构造，5 分钟修复 |
| N-14 | putObjectStream 成功路径 body 流未 drain（keep-alive 连接无法回池） | s3_client.dart:552-553 | `unawaited(response.stream.drain<void>())` |
| N-15 | putObject 三类重试预算独立累计，单次最坏 8 次请求 | s3_client.dart:277-284/309-325 | 共享总预算 ≤4；日志可见剩余预算 |
| N-16 | WebDAV 降级交换链 restore 失败后 `.old.` 孤儿对象（list 过滤不可见、用户无法自助恢复） | webdav_storage_service.dart:435-465/117-126 | critical 告警附完整 backupPath；或孤儿扫描工具 |
| N-17 | S3 keyPrefix 切换后旧前缀对象静默孤立（当前硬编码 'piggycount/'，触发面极窄） | s3_storage_service.dart:450-455/506-512 | list 时对非当前前缀对象 warning；一次性迁移入口 |

### 正面确认（未发现问题的类别）

- 凭据明文存储（flutter_secure_storage + 硬失败语义保持）；
- E2EE 旁路（rawStorage 四调用点均为密钥管理必需；gzip 层不破坏 rekey/enableFromCloud 三入口）；
- gzip×E2EE 装配顺序（压明文后加密，装配链测试实测往返恒等）；
- 条件写锚点穿透 gzip/加密装饰层（锚点作用于云端密文对象，语义与裸存储一致，无漂移）；
- TSM 恢复链四态埋点与空壳回收（TSM-P10）；
- 跨身份接管防护（TSM-P1）、启动检查 skip/取消/unknown 三态口径；
- 备份恢复检查点的调度让位/入口提示/清除保守性。

---

## 五、归一化对比分析（四协议横向）

### 5.1 数据处理逻辑

| 维度 | S3 | WebDAV | Supabase | iCloud | 结论 |
|---|---|---|---|---|---|
| 序列化/槽位/指纹/附件协议 | 全部单点收敛于 App 层（TSM/transactions_json），四协议共用 | 同左 | 同左 | 同左 | ✅ 归一 |
| 元数据原子性 | 原子（x-amz-meta 随 PUT） | 原子（pc-wdav-env 信封单文件） | 非原子（DB sidecar 二次写，失败现上抛 N-2） | 原生 customMetadata | ⚠️ Supabase 独弱（Storage API 限制） |
| 二进制路径 | 真字节 | 真字节 | 真字节 | 真字节（P1-5 后）+ 旧对象嗅探 | ✅ 已归一（iCloud 嗅探歧义面 N-9 收紧后完全归一） |
| list 分页 | 完整（V2/V1+护栏） | 无分页无截断检测（P1-7） | 游标翻页+护栏（P0-1 修，护栏告警缺 N-3） | 原生 | ⚠️ WebDAV 独弱 |
| list 条目 metadata | 不带 | 空常量 | 带 | 带 | ✅ 宿主已适配，契约分裂仅维护性（P2-3） |
| path 回传口径 | 相对路径 | 相对路径 | 相对路径（P1-1b 修） | 原生 | ✅ 已归一 |

### 5.2 同步策略（并发防护三层）

| 层 | S3 | WebDAV | Supabase | iCloud |
|---|---|---|---|---|
| 条件写 | 原子 If-Match（412/404/409 全谱翻译；网关 400 降级有记忆但见 N-7） | 读后比对近似（窗口收窄非原子，fail-closed） | 读后比对近似（updatedAt 锚点，P1-1 修） | 不支持 → 盲写+写后校验 |
| 冲突仲裁/写后校验/完整性终审 | 四协议统一于 App 层（M7/方案C/A5/P1-5），探测失败中止上传 | 同左 | 同左 | 同左 |
| 双设备并发安全性 | 最高 | 次之（窗口） | 次之（窗口） | 最低（事后发现） |

**判定：并发防护「能力矩阵」已在上轮归一化（Supabase 从无条件写升到读后比对），剩余差异是协议原生能力的客观限制**（S3 的 If-Match 是 HTTP 标准、WebDAV/Supabase 无等价原子原语、iCloud 原生黑盒），代码已做到各协议能力上限。归一化目标在这个维度实质达成。

### 5.3 错误处理机制

| 维度 | 现状 | 残差 |
|---|---|---|
| 异常体系 | 单根 CloudSyncException，401/403→Auth、412→Precondition、404→幂等 null，四包映射规范 | iCloud 认证侧仍无分类+UnsupportedError（P2-11）；Supabase Precondition 构造参数污染（N-13） |
| 超时档位 | S3 自适应 30s+30s/MB（5min 封顶）/元数据 30s；WebDAV 60s；Supabase 60s；iCloud 30s/90s；启动检查 20s/90s/5min | WebDAV 大附件偏紧（P2-13）；消息档位错误（N-11）；三包超时不取消（P1-10） |
| 重试策略 | **已归一**：四包幂等读 2-3 次指数退避+真随机 jitter，认证/404 不耗预算，非幂等写不重试，逐次留痕（LOG-06） | Supabase 字符串判定过宽（N-8）；翻页整体重试（N-3）；core RetryHelper 仍死代码（P2-1 备案） |

---

## 六、监控机制与 99.9% 目标可达性评估

### 6.1 机制现状核验（全部落地）

| 要素 | 状态 | 证据 |
|---|---|---|
| 六场景埋点 | ✅ 全覆盖（上轮缺口 startupCheck 已补：snapshotUpload TSM:1046-1207、snapshotRestore TSM:1863-1907/2971-3087/3543-3646、startupCheck checker:280-315、attachmentFill TSM:1570-1589、cloudBackup cloud_backup_service:410-429、remoteDiscovery TSM:3405/3543） | grep 全量核验 |
| 四态口径 | ✅ success/(success+failed+softFail)，conflict 不入分母 | sync_metrics_service.dart:141-149 |
| 错误归因 | ✅ 六类 classifyError + Top 聚合 | sync_metrics_service.dart:234+ |
| 健康卡 | ✅ 99.9%/99%/95% 三档 + 四态明细 + 诊断导出（用户主动分享，唯一出机通道，符合零遥测承诺） | sync_health_card.dart:113-119 |
| 窗口清理 | ✅ 30 天滚动，双保险接线（启动 app.dart:117-119 + 上传成功 TSM:1189） | 本轮核验 |
| 隐私合规 | ✅ 纯本地、结构化字段、无用户内容 | sync_metrics_service.dart:152-160 |

### 6.2 可达性评估（测算，非承诺）

**机制侧：已具备完整可观测链路，无盲区。** 「建立监控机制」这一目标在工程上已达成——六场景全部进分母、四态区分、阈值渲染、失败归因、诊断导出俱全。

**达成侧：99.9% 是结果指标，取决于失败源结构。** 定量推演（30 天窗口、活跃双设备用户、日均 10 次记账 + 2 次冷启动）：
- 分母主体：startupCheck（每次冷启动 1 条）+ snapshotUpload（防抖合并后日均 ~10 条）+ attachmentFill/remoteDiscovery/snapshotRestore 低频；
- 当前结构性 failed 源：弱网下网络类失败（四包重试已归一，2-3 次退避后仍失败才计 failed——该值已被压到弱网可用性下限）、Supabase 缺表环境的 N-2（该环境用户 100% failed，修复前无法达标）；
- 当前结构性 softFail 源：WebDAV 条件写窗口（偶发 verified=false）、iCloud 盲写（并发时事后发现）、探测时序竞态；
- **要稳定 ≥99.9%：30 天窗口 ≈ 400+ 次操作里 failed+softFail 合计须 ≤0.4 次**——即要求：① 修复 N-2（消除 Supabase 缺表用户的全量失败）；② WebDAV/iCloud 用户的 softFail 频次保持极低（单设备用户天然满足；双设备并发重度使用会跌到 99.5-99.8% 档，这是 last-writer-wins 快照模型的结构性上限，非缺陷）；③ conflict 正确不入分母（已达成）。
- **结论：单设备/低并发用户的 99.9% 在当前代码下可达成且可证明；双设备高频并发场景的 99.9% 依赖软失败源的进一步收敛（N-4/N-5 与 WebDAV 条件写窗口）。** 监控机制会把这一差距如实呈现（softFail 独立计数），这正是该机制的设计目的。

### 6.3 监控侧剩余改进项

1. duration 字段仅 snapshotUpload/startupCheck 普遍记录——attachmentFill 的 attempts 恒传 3（成功也记 3，实际尝试次数未透传，TSM:1570-1577 注释自认），归因粒度可再进一步；
2. backend 字段口径：startupCheck 记 'startup' 而非实际后端类型——健康卡按后端过滤时该场景不可归属（权衡：整轮可能跨后端，现口径可接受，备案）；
3. 压缩收益（N-10）、重试次数分布无结构化指标——归因从「失败类别」到「性能维度」的下一层。

---

## 七、详细优化方案（按优先级排期，供后续实施）

### 🔴 立即（P1 + 高影响 P2，均为小改动）

**方案 1（N-1）WebDAV 路径校验编码盲区收口**
- 方案：`_assertNoTraversal`/remotePath 校验前置归一化——`replaceAll('\\','/')` + 尝试 `Uri.decodeComponent`（失败保持原样）后再做 `..` 分段校验；或在 validateConfig 阶段直接拒绝含 `\` 或 `%` 的 remotePath。
- 验收：单测覆盖 `/%2e%2e/`、`/..\`、双重编码 `%252e` 变体均被拒绝；正常路径（含合法百分号编码的中文目录名）不误伤——注意与「拒绝含 %」方案的取舍：归一化解码方案更兼容，推荐。
- 风险：极低；纯防御收紧。

**方案 2（N-2）Supabase 元数据失败语义对齐声明**
- 方案（推荐 a）：`_storeMetadata` 失败不再上抛——返回 bool，`_uploadBytes` 完成后由 manager 写后校验自然发现指纹缺失（getMetadata 读不到 → verified=false → softFail）。与异常类注释、审计文档 §八声明三方对齐。
- 若评估后倾向保留 fail-hard（可用性换正确性）：则保留现行为，但必须 a) 修复注释与文档；b) 在启动检查/连接探测处给出「file_metadata 表未建」的定向指引；c) cloud-setup 文档加粗该表为 Supabase 必建项。
- 验收：mock 表写失败 → 上传结果 softFail（方案 a）或文档一致（方案 b）；指标归类与文档声明一致。
- 风险：方案 a 重新引入「指纹缺失→全量下载退化」路径（有 logger.warning + 本轮监控可见，可接受）；方案 b 保持硬失败需承担存量缺表用户升级后同步中断的支持成本。

**方案 3（N-6 + N-7）S3 网关兼容两处收紧**
- 方案：ListObjects 解析改 localName 匹配 + 0 对象时校验根元素 ListBucketResult（N-6）；条件写不支持判定要求「not implemented × if-match 关键词」同时命中 + 能力记忆加 N 次上传后复试探针（N-7）。
- 验收：带 `<s3:Contents>` 前缀的响应用例返回正确条目；仅含 NotImplemented 字样的 400 不触发降级记忆。
- 风险：低；均为判定收紧/兼容扩展。

### 🟠 短期（真实可发生的正确性/性能 P2）

**方案 4（N-5）WebDAV tmp 文件名掺设备级随机因子**
- 方案：进程启动生成一次性 UUID，tmp 名 `'$fullPath.tmp.$uuid.$ts.$seq'`——跨设备碰撞面归零。
- 验收：单测断言 tmp 名含随机段；并发上传互不覆盖。
- 风险：无。

**方案 5（N-4）WebDAV 写后校验缓存预填**
- 方案：`_atomicPublish` 成功后用本次信封内容与新 eTag 预填 M10 缓存（或直接使旧键失效+登记「写后免验证」标记，由下次 getStatus 顺带完成 verify）。
- 验收：上传后 verify 零额外 GET（用假桩断言 readDir/GET 调用次数）。
- 风险：缓存预填需确认 eTag 获取路径（MOVE 响应可能不带新 eTag，需读一次 PROPFIND——仍远低于全量 GET）。

**方案 6（N-3 + N-8）Supabase 翻页护栏告警 + 瞬时判定收紧**
- 方案：护栏触达 logger.warning；`_isTransient` 文本兜底改为异常类型判定（SocketException/TimeoutException runtimeType），删除 'network'/'connection' 宽词。
- 验收：护栏触达用例产生 warning；确定性异常不再消耗重试预算（用例断言 attempts=1）。
- 风险：低。

**方案 7（N-9）iCloud 嗅探第一闸改严格 UTF-8 校验**
- 方案：`_unwrapLegacyBase64Text` 入口先 `utf8.decode` try/catch（与加密装饰器同款），失败即原样返回新格式字节。
- 验收：全 ASCII 且恰为合法 base64 的二进制不再被误解包；旧 base64 文本对象行为不变（本就是合法 UTF-8）。
- 风险：极低。

**方案 8（P1-11 遗留）认证异常归一**
- 方案：WebDAV/iCloud auth 服务的 UnsupportedError 改抛 CloudAuthException（带「该后端不支持此操作」文案）；iCloud 存储层 PlatformException 的认证类 code（如 notauthenticated）翻译 CloudAuthException。
- 验收：`on Exception` 风格 catch 不再被穿透；类型化测试。
- 风险：低。

### 🟡 中期（性能与可观测）

**方案 9（P2-13/P2-14/N-11）WebDAV 超时自适应 + S3 流式接入附件路径**
- 方案：WebDAV 传输类操作（PUT/GET body）按 Content-Length 自适应（对齐 S3 30s+30s/MB 档）；附件上传/下载接入 S3 流式（putObjectStream/downloadToSink），修 N-11 的 contentLength=null 档位与 body drain；iCloud/Supabase 维持现状（SDK 限制，文档备案）。
- 验收：大附件弱网用例不再固定 60s 超时；流式上传内存峰值下降（devtools 断言）；连接回池（N-14）。
- 风险：S3 网络层改动需走既有 2451 行测试全量回归。

**方案 10（N-10）压缩收益结构化**
- 方案：GzipCloudStorageService 增加压缩统计计数器（原始/压缩字节累计），随诊断导出输出；非加密用户装配 gzip 列为产品决策项（默认不做，明文可读性承诺优先）。
- 验收：诊断 JSON 含压缩收益字段。
- 风险：无。

**方案 11（第六章 6.3）监控归因粒度**
- 方案：attachmentFill 真实 attempts 透传；startupCheck backend 记实际后端（单后端场景）；可选手术刀：duration 补齐 attachmentFill/remoteDiscovery。
- 验收：指标行字段完整度断言测试。
- 风险：无。

### ⚪ 治理（一致性债，可随大版本）

**方案 12（P2-1/P2-12 归一化治理）**
- 重试纪律代码化：抽公共 `RetryPolicy` 常量包（四包参数从单点常量读取，语义差异保留能力位）——沿用上轮方案 11 的推荐路线 B；
- 静态 logger 注入口四名统一（S3 downgradeLogger / WebDAV+Supabase storageLogger / Gzip compressionLogger → 单一命名规范 + 装配处集中）；
- list 条目 metadata 口径契约文档化（core storage_service.dart 注释升级为契约，四包共用契约单测）；
- Supabase Precondition 构造参数修正（N-13）与兄弟类隐性契约文档化（exceptions.dart 注释补充「catch CloudStorageException 不会捕获 Precondition」警示）。

**方案 13（N-15/N-16/N-17 边角）**
- S3 putObject 重试预算共享上限；WebDAV `.old.` 孤儿告警附路径；S3 旧前缀对象迁移提示。均为低频边角，随治理批次。

### 实施优先级总览

| 优先级 | 方案 | 工作量 | 受益 |
|---|---|---|---|
| 🔴 立即 | 1（路径校验）、2（元数据语义）、3（S3 网关兼容） | 小 | 安全承诺兑现 / Supabase 缺表用户可用性 / 网关兼容面 |
| 🟠 短期 | 4~8（tmp 碰撞/verify 成本/翻页告警/嗅探/认证归一） | 小-中 | 正确性 + 弱网成功率 + 99.9% 收敛 |
| 🟡 中期 | 9~11（超时自适应/流式/压缩指标/监控粒度） | 中 | 大附件弱网 + 可观测 |
| ⚪ 治理 | 12~13（重试常量化/logger/契约文档/边角） | 中 | 归一化防回归 |

---

## 八、结论

1. **上轮六批修复全部真实落地、质量高**：Supabase P0 截断、四包重试归一、iCloud 二进制、startupCheck 埋点、备份检查点、gzip 压缩、监控收尾——实现/调用链/测试三方一致，1145 项测试全绿。
2. **归一化程度判定：数据处理与监控口径已实质归一**（序列化/槽位/指纹/附件/触发入口单点 + 四态六场景全覆盖）；并发防护达到各协议原生能力上限（S3 原子 > WebDAV/Supabase 读后比对 > iCloud 盲写+校验，差异是协议能力而非实现偏差）；错误处理中重试纪律已归一，残留分裂在认证异常类型（P2-11）、超时档位（WebDAV 60s 固定）、logger 注入口（四名）。
3. **本轮新发现 1 项 P1（WebDAV 路径校验编码盲区）+ 10 项 P2 + 6 项 P3**，无新增 P0。最需优先处理的是 N-1（安全承诺）与 N-2（Supabase 缺表环境的可用性回归 + 指标语义与文档不符）。
4. **99.9% 目标**：监控机制已建立且完整（可测、可归因、可导出、隐私合规）；单设备/低并发用户在当前代码下可达成；双设备高频并发的稳定 99.9% 依赖本报告方案 2/4/5 落地后的 softFail 收敛。机制会把未收敛场景如实呈现为 softFail——这正是设计目的，不应为凑指标把 softFail 移出分母。
5. 本报告为只读排查产物，**未修改任何代码**；全部优化方案见第七章，实施时按 `docs/sync-reliability-params.md` 参数纪律与 1145 项测试基线回归。

---

## 附录 A：本轮关键证据索引

| 主题 | 文件:行号 |
|---|---|
| Supabase 翻页/护栏/探测 | supabase_storage_service.dart:64-69, 301-331, 437-525 |
| Supabase 元数据异常链 | supabase_storage_service.dart:222-234, 614-645, 700-709；cloud_sync_manager.dart:278-284；TSM:1199-1207 |
| Supabase 瞬时判定 | supabase_storage_service.dart:145-164 |
| iCloud 嗅探/重试/认证 | icloud_storage_service.dart:42-59, 154-191；icloud_auth_service.dart:80-141 |
| WebDAV 路径校验 | webdav_provider.dart:130-135；webdav_storage_service.dart:767-779；path_helper.dart:14-27 |
| WebDAV tmp 碰撞/降级交换/verify 成本 | webdav_storage_service.dart:394-395, 435-465, 696-716, 747-760 |
| S3 XML 解析/能力记忆/超时消息 | s3_client.dart:1300-1341, 629-638, 309-317, 729-763, 504 |
| gzip 装配链与嗅探 | gzip_cloud_storage.dart:31-70, 89-119, 130-194；TSM:637-649；encrypted_cloud_provider.dart:26-56；encrypted_cloud_provider_test.dart:133-164 |
| 条件写链锚点透传 | storage_service.dart:223-232；encrypted_cloud_storage.dart:42-45, 137-177 |
| startupCheck 埋点四态 | startup_sync_checker.dart:229-315, 420-580 |
| TSM 上传/恢复/附件/埋点 | transactions_sync_manager.dart:945-1211, 1551-1600, 2434-2474, 2863-3103 |
| 备份检查点链 | cloud_backup_service.dart:283-302, 431-444；app.dart:193-206；cloud_sync_page.dart:344-356 |
| 监控口径/清理/健康卡 | sync_metrics_service.dart:141-149, 269-283；sync_health_card.dart:113-119；app.dart:117-119 |

## 附录 B：与上轮审计的关系

- 上轮报告（sync-comprehensive-audit-2026-09-10.md）：P0-1 + 12 项 P1 + 16 项 P2，其中六批已修（其 §八 + 三份补记）。
- 本轮核验结论：已修 24 项全部落地；未修清单中 P2-5 已随 P1-1b 修复，其余 10 项仍在（第三章）；新发现 17 项（第四章）。
- 两份报告合并阅读口径：上轮第五章问题清单中仍开放的部分 = 本轮第三章；本轮新增问题独立编号 N-1~N-17，实施时建议并入统一问题追踪表。

---

## 附录 C：本轮新发现问题修复实施记录（2026-09-12，第七章方案落地）

> 本章为审计后实施记录，正文（第一~八章）保持只读审计时点状态，两者判定不一致时**以本章为准**。回归基线：全部修复落地后四包 + 全库测试通过——iCloud 19 项、S3 136 项（含新增 s3_gateway_compat_test.dart 7 项）、Supabase 29 项、WebDAV 59 项、core 95 项、App 根 1145 项（1 skip），全绿零失败。

### C.1 已修复（10 项）

| 问题 | 修复内容 | 实现证据 | 测试 |
|---|---|---|---|
| **N-1（P1）** WebDAV 路径校验编码盲区 | `_assertNoTraversal` 与 WebDAVProvider remotePath 校验前置防御性归一化：反斜杠统一转斜杠 + 尝试一层 URI 解码（失败保持原样），对原始与归一化两种形态分别做 `..` 分段校验；归一化仅用于校验，不改变实际传输路径 | webdav_provider.dart:130-141（配置校验）、:434-442（`_decodeLoosely`）；webdav_storage_service.dart:774-796（`_assertNoTraversal` 同口径） | 无专属单测（校验为纯防御收紧、无既有用例受影响，四包回归全绿）；后续批次可补 `%2e%2e`/`..\`/`%252e` 变体用例 |
| **N-2（P1/P2）** Supabase 元数据失败语义 | 方案 a 落地：`_storeMetadata` 幂等重试 1 次后仍失败**不再上抛**，warning + dev.log 留痕（含表未建/RLS 排查指引）；指纹缺失由 manager 写后校验自然发现（verified=false → softFail）。消除缺表环境 100% 硬失败回归与「failed 而非 softFail」的口径偏差 | supabase_storage_service.dart:233-243（upload 不再上抛）、:648-676（重试后吞掉最终失败）、:731-736（注释链声明修订） | 经由 supabase_pagination_conditional_test.dart 门禁/契约用例回归 |
| **N-3（P2）** Supabase 翻页护栏静默 | 护栏触达（第 100 页）logger.warning 留痕，语义对齐 S3 分页畸形响应告警。**翻页重试粒度（中间页失败从头重拉）维持原状**——按第七章方案 6 的渐进路线，单页级重试列为后续批次 | supabase_storage_service.dart:523-553（`_listAllObjects` 护栏告警） | 同上包回归 |
| **N-6（P2）** S3 XML 命名空间盲区 | ListObjects 解析改 localName 匹配（`findAllLocal`/`findChildLocal` 辅助，元素与分页字段 IsTruncated/NextContinuationToken 全覆盖），带 `<s3:Contents>` 前缀的网关响应不再静默空列表 | s3_client.dart:1321-1372 | s3_gateway_compat_test.dart:47-109（3 用例：带前缀正确解析/无前缀行为不变/带前缀翻页继续） |
| **N-7（P2）** S3 能力记忆过宽 | `_isConditionalHeaderNotSupported` 收紧：NotImplemented 字样必须**配合条件头关键词**（if-match/if-none-match/a header you provided）同时出现才判定；裸字样 400 不再误记降级 | s3_client.dart:641-655 | s3_gateway_compat_test.dart:111-184（2 用例：裸字样不降级/真实不支持场景保持记忆+自动重发盲写） |
| **N-8（P2）** Supabase 瞬时判定过宽 | `_isTransient` 文本兜底收紧为异常类型判定（SocketException/TimeoutException/HttpException 运行时类型），与 S3 类型化口径对齐；Web 平台保留类型名字符串兜底（不再匹配消息内容） | supabase_storage_service.dart:150-175 | 包内重试用例回归 |
| **N-9（P3）** iCloud 嗅探歧义面 | 第一闸从 `String.fromCharCodes` 改严格 `utf8.decode` try/catch（与加密装饰器同款）：非 UTF-8 新格式原始二进制即原样返回，歧义面归零；纯 ASCII 合法 base64 的固有歧义残留（sha256 终审裁决）以测试声明固化 | icloud_storage_service.dart:180-197 | icloud_binary_retry_test.dart:162-215（N-9 组 4 用例：非 UTF-8 原样/ASCII 歧义声明/中文文本原样/带换行 RFC 2045 旧格式兼容） |
| **N-11（P2）** S3 超时档位口径 | getObject 超时消息改报实际档（`_getObjectTimeout` 90s，不再复用元数据档 30s）；putObjectStream contentLength 缺省（chunked）按保守上限档（5min cap）计算，`?? 0` 的 0 字节档判死消除 | s3_client.dart:505-512（streamTimeout 缺省档）、:782-784（消息档位） | s3_gateway_compat_test.dart:186-224（2 用例：大体积封顶基准/消息口径） |
| **N-13（P3）** Supabase Precondition 构造 | CloudPreconditionFailedException 改双参构造（path, message），与 S3/WebDAV 口径归一，path 字段不再被整句消息污染 | supabase_storage_service.dart:292-299 | 包内条件写用例回归 |
| **N-14（P3）** S3 流 body 未 drain | putObjectStream 成功路径 `unawaited(response.stream.drain<void>())`，keep-alive 连接回池 | s3_client.dart:560-563 | 随 s3_gateway_compat_test 档位用例回归 |

### C.2 实施期新增修复（非审计清单项）

| 问题 | 修复内容 | 证据 |
|---|---|---|
| iCloud 嗅探测试编译崩溃（僵死 dart 进程根因） | 新增 N-9 测试用例字符串字面量误含**裸换行**（`'${m[1]}` 后真实换行而非 `\n` 转义），前端编译器 tokenize 越界崩溃且进程不退出，表现为「flutter test 僵死零输出」。已改 `\n` 转义修复 | icloud_binary_retry_test.dart:206-207 |

### C.3 未修（维持第七章排期）

- **N-4/N-5/N-16**（WebDAV verify 缓存预填/tmp 设备因子/孤儿告警）→ 方案 4/5，短期批次；
- **N-10**（gzip 收益结构化）→ 方案 10，中期；
- **N-15/N-17**（S3 重试预算共享/旧前缀孤立）→ 方案 13，治理批次；
- 第三章遗留 10 项（P1-6/7/10、P2-1/3/11/12/13/14、兄弟类契约）维持原排期。
- N-3 的翻页单页级重试（方案 6 后半）未实施，护栏告警已先行。
