# PiggyCount 同步功能全面排查报告（归一化·监控·优化方案）

- **排查日期**: 2026-09-07
- **排查方式**: 静态代码审查 + 架构分析 + 调用链追踪 + 既有测试证据复核（未修改任何源码）
- **排查范围**: 全部同步功能 —— S3 协议模块、WebDAV 协议模块、Supabase 模块、iCloud 模块、core 同步框架（flutter_cloud_sync）、端到端加密层、app 层快照同步编排（TransactionsSyncManager / StartupSyncChecker / SyncDiffService / ChangeTracker）、云端备份（CloudBackupService / BackupScheduler）、附件二进制同步链路
- **关联文档**: `docs/sync-audit-report-2026-08-17.md`（上一轮增量引擎审计，其中 sync_engine 系列已随 PiggyCountCloud 下线删除）、`docs/test/S3同步功能测试报告_20260907.md`（最近一轮双端实测）、`docs/evidence/sync-interruption-stress-2026-09-04.log`（100 轮中断压测）

---

## 一、总体结论（TL;DR）

1. **同步数据正确性基础扎实**：2026-09-07 双模拟器 S3 实测 8 张同步表 + 附件逐字段 0 差异；100 轮随机中断压测 100% 收敛、失败率 0%。快照同步的核心协议（槽位 = syncId、内容指纹三方恒等、上传顺序协议、冲突拦截 + 条件写 + 写后校验三层并发防护）是健全的。
2. **归一化存在系统性缺口**：S3 与 WebDAV 两个主力后端已高度归一（条件写、认证异常语义、路径防穿越、ETag 归一化），但 **Supabase 与 iCloud 两个后端停留在旧能力集**（无二进制路径、无条件写、无重试、无 HTTPS 强制校验）；**重试机制存在 4 套互不一致的独立实现**（core RetryHelper / S3 内置 / WebDAV 内置 / TSM 附件重试）；**超时参数 5 处各定各的**；**元数据归一化函数 3 处复制粘贴**。PiggyCountCloud 实时协同下线后，增量引擎（sync_engine）整体删除，当前唯一同步路径是「快照同步（Path A）」，这反而让归一化的收口范围变得可控。
3. **同步成功率监控机制完全缺失**：全代码库没有任何成功率指标设施（无计数、无聚合、无展示），仅有的可观测性是 2000 条 / 48 小时 TTL 的环形日志（SharedPreferences）。**99.9% 目标目前既无测量手段、也无基线数据**。且 `PRIVACY.md` 明确承诺「零遥测、零分析、不运营服务器」，监控方案必须设计为**纯本地测量 + 用户主动导出**形态。
4. **最危险的单点缺陷**：iCloud 适配器的「文件不存在」判定用 `msg.contains('404')` 纯子串匹配（`icloud_storage_service.dart:42`）——这正是 WebDAV 侧 WD-M3 审计修掉的同类问题（异常消息内嵌端口号 `:8404` 会被误判为不存在 → `exists()=false` → 触发覆盖上传）。WebDAV 当年认为它危险到足以造成数据覆盖，iCloud 侧同款风险未修。

问题清单按严重度编号（P0 立即修 / P1 短期 / P2 优化），共 19 项，全部给出定位与优化方案。

---

## 二、同步功能全景与模块清单

### 2.1 架构分层

```
┌─ app 层（lib/cloud, lib/providers）────────────────────────────┐
│ TransactionsSyncManager（快照同步编排核心, 3253 行）              │
│ StartupSyncChecker（启动检查: 发现→状态→合并→两阶段回传）         │
│ SyncDiffService（cloudNewer 合并的 diff 计算/应用）              │
│ ChangeTracker（local_changes 变更登记, 证据链 for 方向仲裁）       │
│ CloudBackupService + BackupScheduler（每日 ZIP 全量备份）        │
│ sync_fingerprint（contentFingerprintFromMap 白名单指纹）         │
│ provider_factory（按 CloudServiceConfig 装配后端）               │
├─ 加密层（lib/data/encryption）──────────────────────────────────┤
│ EncryptedCloudStorageService / EncryptedCloudProvider（E2EE 装饰）│
├─ core 框架（packages/flutter_cloud_sync）───────────────────────┤
│ CloudProvider / CloudStorageService / CloudAuthService（接口）    │
│ ConditionalWriteStorage / BinaryCapableStorage（可选能力接口）    │
│ CloudSyncManager（快照 upload/download/getStatus + 写后校验）     │
│ RetryHelper / PathHelper / 异常体系（CloudSyncException 族）      │
├─ 后端 provider ─────────────────────────────────────────────────┤
│ S3: flutter_cloud_sync_s3（自研 SigV4 REST 客户端, 2827 行）     │
│ WebDAV: flutter_cloud_sync_webdav（webdav_client + 信封格式）      │
│ Supabase: flutter_cloud_sync_supabase（SDK storage + DB 元数据） │
│ iCloud: flutter_cloud_sync_icloud（method channel）              │
└────────────────────────────────────────────────────────────────┘
```

已下线：PiggyCountCloud 实时协同（增量 push/pull 引擎、Realtime WS、冲突解析器）——commit `58a277b` 起 overall 移除，残留收尾至 `3ac366a`。当前**唯一生产同步路径**是快照同步（Path A），所有后端走同一 `CloudSyncManager` 或 app 层直连 `provider.storage` 的编排骨架。

### 2.2 各后端模块现状

| 维度 | S3 | WebDAV | Supabase | iCloud |
|---|---|---|---|---|
| 实现方式 | 自研 SigV4 签名 REST（s3_client 1430 行） | webdav_client 1.2.2 + dio | supabase_flutter SDK | 原生 method channel |
| 二进制路径（BinaryCapableStorage） | ✅ 原生字节 | ✅ 原生字节（无 meta 时裸字节） | ❌ 恒 base64 文本（+33% 流量） | ❌ 恒 base64 文本 |
| 条件写（ConditionalWriteStorage） | ✅ If-Match/If-None-Match 原子（412/404/409 翻译） | ⚠️ 「预取 eTag 比对」近似（非原子，已文档备案） | ❌ 无 → 恒盲写+写后校验 | ❌ 无 |
| 幂等读重试 | ✅ 内置（网络/5xx 指数退避+jitter） | ✅ 内置（400ms 起 2 次） | ❌ 零重试 | ❌ 零重试 |
| HTTPS 强制 | ✅（SYNC-04，拒绝 http://） | ✅（P2-7，拒绝 http/davs） | ❌ 无 scheme 校验 | N/A（系统容器） |
| 路径防穿越 | ✅ `..` 段拒绝 + keyPrefix 校验 | ✅ `..` 段拒绝 | ⚠️ 无显式拒绝（userId 拼接可信） | ⚠️ 无显式拒绝 |
| 认证异常类型化 | ✅ CloudAuthException（401/403 分文案） | ✅ 同左 | ⚠️ 靠 SDK 异常字符串（'404'/'not found'） | ⚠️ message 子串匹配 |
| ETag 透出 | ✅ HEAD/PUT 响应 | ✅ PROPFIND getetag | ❌ | ❌ |
| metadata 存储 | x-amz-meta-*（b64 包装自愈） | 信封内嵌（原子）+ sidecar 兼容 | DB 表 file_metadata（需手工建表） | 原生侧 customMetadata |
| 操作超时 | 30s（client 默认） | 60s（_opTimeout） | ❌ 未设置（SDK 默认） | 30s / 下载 90s |
| 初始化探测 | ✅ listObjects maxKeys:1（带 keyPrefix） | ✅ readDir + Digest 兜底 | ❌ 无连接探测 | ✅ isICloudAvailable |

### 2.3 正面发现（避免误报，先列明确不是问题的）

- **三层并发防护体系**（方案C）：M7 冲突探测（时间戳证据链 + 可信度门禁）→ 条件写（S3 原子 / WebDAV 近似）→ 写后校验（verifyAfterUpload + CloudUploadResult.verified 上浮，不清脏标记）。`_detectUploadConflict` 探测失败时**中止上传而非盲传**（审计 A5），这是数据安全优先的正确取舍。
- **指纹体系高度归一**：`contentFingerprintFromMap`（US-5 抽取后单一实现）全序化排序（平局兜底 jsonEncode 比较）、白名单式规范化（兼容缺键旧快照）、内嵌 `contentFingerprint` 自描述（元数据丢失后的权威源）、附件/账户/分类/预算/周期/汇率全覆盖。2026-09-07 实测两端指纹逐一 inSync。
- **附件链路**：内容寻址（sha256 即路径）+ 上传顺序协议（附件先于清单）+ 多形态嗅探（原生二进制/base64/密文）+ sha256 终审 + 原子落盘（tmp+rename）+ 三态下载结果（ok/objectMissing/transientFailure，永缺不空转重试）。
- **恢复互斥体系**：SyncRestoreGuard（计数器、嵌套安全）+ `_ledgerOpsLocks`（同账本 FIFO 互斥）+ `_initGeneration`（初始化代次令牌防复活）+ 防抖防抖上传（2s 窗口 + pending 补跑，保证最后状态必然上云）。
- **ChangeTracker 契约**：v35 部分唯一索引 + v41 存量清理，user-global/ledger-scoped 双通道强类型入口，云→本地合并抑制（深度计数器），markSnapshotPushed 语义对齐快照上传。
- **S3 客户端工程成熟度**：RFC 3986 严格编码（签名与线上路径逐字节一致）、时钟偏差自动补偿重签、ListObjects V1/V2 自动回退 + 三重翻页护栏、桶级 404 区分、条件写网关能力探测记忆（400+NotImplemented 降级 + warning 上报）。
- **WebDAV 原子发布**：tmp PUT → MOVE 覆盖 → 交换式降级（备份可回滚）+ 成功 MOVE 误报探测（W-A）+ 信封格式消除「主文件落位/sidecar 未更新」窗口。

---

## 三、归一化矩阵比对（功能偏差清单）

### 3.1 数据处理逻辑偏差

| # | 偏差点 | 现状 | 影响 |
|---|---|---|---|
| N1 | **二进制传输路径** | S3/WebDAV 实现 BinaryCapableStorage（真字节）；Supabase/iCloud 恒走 `CloudStorageBinaryExt` 的 base64 文本兜底 | 附件/ZIP 备份在这两个后端流量 +33%、内存峰值翻倍、云端文件非原生格式（外部工具不可直读）。备份恢复链路 `downloadBinaryOrFallback` 已做 ZIP 魔数嗅探兼容（cloud_backup_service.dart:365），恢复不出错，但传输成本永久存在 |
| N2 | **metadata 通道** | S3 x-amz-meta-*（与对象同请求原子落盘）/ WebDAV 信封内嵌（原子）/ Supabase **DB 表**（第二次网络请求，表不存在则静默丢失）/ iCloud 原生 customMetadata | Supabase 后端上 `uploadMetadata`（账本名/币种/count/balance/月起始日——发现阶段快路径的全部数据源）写失败仅 `dev.log` warning（supabase_storage_service.dart:274），release 构建无感知 → metadata 恒缺失 → `discoverRemoteLedgers` 快路径全部退化为慢路径全量下载、`getStatus` 每次全量下载算指纹（Major-08 修复对该后端失效） |
| N3 | **metadata 归一化函数三处重复** | core `cloud_sync_manager.dart:20-56`（`_normalizeMetaValue`/`_metaValue`）、app `transactions_sync_manager.dart:2176-2201`（`_normalizeFingerprintMeta`/`_metaValue`）、S3 client `_decodeMetaValue`（s3_client.dart:1277-1294）三套几乎相同的 b64/大小写归一化逻辑 | 漂移风险（US-5 只抽取了 contentFingerprintFromMap，meta 归一化未收口）。任一处补新规则（如新网关的编码怪癖）其余两处必漏 |
| N4 | **ETag 透出** | S3（HEAD/PUT）、WebDAV（PROPFIND）透出 `CloudFile.eTag`；Supabase/iCloud 恒 null | 加密装饰器如实申报 `supportsConditionalWrite=false` → 条件写恒降级盲写。这两个后端的并发覆盖只剩写后校验兜底（成功率高但非原子） |
| N5 | **空数据语义** | 四后端的 404→null/幂等删除语义已对齐（接口契约注释明确），但 Supabase 用 `e.statusCode == '404' || e.message.contains('not found')` 字符串判定（supabase_storage_service.dart:77）；iCloud 用 `msg.contains('404')`（见 P0-2） | 见问题清单 |
| N6 | **上传内容寻址与幂等** | S3/WebDAV PUT 均为 upsert 盲覆盖语义，靠 If-Match 提供条件；Supabase FileOptions(upsert:true) 同为盲覆盖 | 一致（这是接口契约），但条件写能力差异导致并发保障强度不同（见 N4） |

### 3.2 同步策略偏差

| # | 偏差点 | 现状 | 影响 |
|---|---|---|---|
| N7 | **启动检查 only-pull** | StartupSyncChecker 只把 `cloudNewer` 纳入候选；`localNewer`/`different` 静默关闭（unknownDiffLedgers 仅记日志） | 设计上防误弹（方向未知不自动覆盖，正确），但意味着**本地新数据不会在启动时自动推云**（除非 auto_sync 开关 + PostProcessor 防抖链路）。本地有未推送变更 + 云端无更新的用户，每次启动后依赖手动上传或记账触发。归一化建议：启动检查增加「本地较新」的温和提示（可跳过、非弹窗），或文档化该取舍 |
| N8 | **附件去重探测策略** | `uploadAttachmentObjects` 每次快照上传都 `list('attachments')` 全量列举（TSM:1185），单次 list 替代 N 次 exists（T-x 优化）已做 | 大附件库（千级对象）下，WebDAV 每轮 PROPFIND 整目录 XML、S3 ListObjectsV2 全前缀翻页，慢网下防抖后的每次记账都重复整套。优化见 P2-3 |
| N9 | **备份文件命名/认领** | ZIP 备份按本地日期命名当日覆盖；恢复侧 syncId-first 三级认领（H2 已修数字 id 撞号） | 已归一，无问题 |
| N10 | **supabase realtime / database service 死代码** | SupabaseProvider 装配 `_databaseService`/`_realtimeService`，app 层零调用（grep 确认）；core `DatabaseSyncManager`（788 行离线队列编排）同样零生产调用 | 维护成本 + 审计面积。PiggyCountCloud 下线后这些是纯遗留 |

### 3.3 错误处理机制偏差（重试/超时/异常）

| # | 偏差点 | 现状 | 影响 |
|---|---|---|---|
| N11 | **四套重试实现互不一致** | ① core `RetryHelper`（1s 起步/×2/3 次/jitter 25%/异常类型判定）——**生产代码零调用**（仅 example 使用，事实性死代码）；② S3 `S3Client._retry`（幂等操作专用；网络/5xx/时钟偏差重试，PUT **不重试**——s3_client.dart:107 注释明确「非幂等 + A-1 覆盖竞态未修」）；③ WebDAV `_retryIdempotent`（400ms 起/2 次/「时间戳取模」伪 jitter，webdav_storage_service.dart:167-169）；④ TSM `_downloadAttachmentBinWithRetry`（1s/2s/4s 无 jitter/3 次，TSM:1487） | 参数、退避曲线、可重试判定、jitter 策略四个地方四个样。多设备 thundering herd 防护仅 S3 是真随机。核心上传 PUT 在 S3 后端**瞬时网络故障（超时但服务端已落盘）场景下无重试也无探测**——A-1 覆盖竞态在条件写路径已被 412 化解，但「超时=不知道落没落盘」的歧态处理仍未归一（详见 P1-3） |
| N12 | **超时参数五处独立定义** | S3 client 30s（provider 未覆盖默认值）/ WebDAV `_opTimeout` 60s + 探测 60s / iCloud 30s（下载 90s）/ Supabase **未设置**（依赖 SDK 默认）/ app 层 `StartupSyncChecker` 20s（状态）/90s（apply）/5min（publish）/ TSM 附件下载无总超时（依赖后端超时）+ discover 单文件 10s 预算 | 同一「上传账本」动作在四个后端的最坏阻塞时长差一个数量级；大快照（实测 350KB/账本）+ 慢网（<100KB/s 上行）在 S3 的 30s PUT 超时会**必然失败**，而 WebDAV 60s 可过。慢网用户在 S3 后端的快照上传成功率被超时参数直接压低 |
| N13 | **异常类型化程度** | S3/WebDAV：CloudAuthException/CloudConfigurationException/CloudPreconditionFailedException/CloudStorageException 完整分层，401/403 分文案；Supabase：StorageException→CloudStorageException 平铺（认证/权限/网络不可区分）；iCloud：PlatformException→CloudStorageException 平铺 + `_isNotFoundError` 字符串匹配 | Supabase/iCloud 用户看到的是「同步失败: …」原始文本；上层 `_isAuthErrorText`（startup_sync_checker.dart:83-92）只能靠子串猜（`lower.contains('401')`——异常消息内嵌端口 `:8401` 也会命中，仅影响提示文案不影响数据安全） |
| N14 | **完整性校验双轨** | core `CloudSyncManager.download` 内置 P4 完整性校验（metadata 指纹 vs 内容，失败重下重试一次，持续不一致硬失败）——但 app 层（恢复/预览/发现/备份恢复）**全部直连 `provider.storage.download`**，该校验是死代码；app 侧对应物是 `_warnIfRemoteFingerprintMismatch`（TSM:2155+，**软告警不阻断**，理由是 M2 指纹算法升级迁移窗口） | 两套语义（硬失败 vs 软告警）并存且一套从未运行。归一化方向：明确单一完整性策略并让两条下载通道共用（见 P1-5） |

### 3.4 归一化结论

S3/WebDAV 双后端在 2026-08～09 的多轮审计（方案C、SYNC-xx、W-xx、S3-xx 系列）中已收敛到高度一致的行为契约，**剩余归一化债务集中在两端**：
1. Supabase / iCloud 能力集落后（N1/N2/N4/N12/N13）；
2. 横切关注点（重试 N11、超时 N12、meta 归一化 N3、完整性 N14）没有一个统一的单点配置。

---

## 四、问题清单（按严重度排序）

### P0 —— 数据安全 / 目标阻塞级

#### P0-1【监控缺失】同步成功率零测量，99.9% 目标无基线
- **定位**: 全局。grep 全库无 SyncMetrics/成功率/health 相关设施；唯一可观测性 = `lib/services/system/logger_service.dart`（2000 条环形缓冲、48h TTL、SharedPreferences 节流 2s 落盘，`logger_service.dart:157-160`）。
- **现状**: 同步成败只有散落的日志行（`上传完成`/`上传失败`/`附件补齐下载失败 N/M`），无结构化计数。备份调度器连「上次备份成败」都只存日期（`backup_last_date`，成败均算，backup_scheduler.dart:66-68——弱网日当天备份失败后**不再重试**，次日才有机会）。
- **影响**: ① 无法回答「当前成功率是多少」；② 无法发现退化（某后端/某网关组合的成功率滑坡只体现在用户抱怨）；③ 99.9% 验收无从谈起；④ 压测结论（100 轮 0% 失败）只是实验室数据，不等于真实弱网表现。
- **方案**: 见 §五 监控机制设计（含隐私约束下的落地形态）。

#### P0-2【正确性风险】iCloud「不存在」判定用纯数字子串匹配——WebDAV 同款事故模式未修
- **定位**: `packages/flutter_cloud_sync_icloud/lib/src/icloud_storage_service.dart:30-47`：
  ```dart
  bool _isNotFoundError(Object e) {
    ...
    final msg = e.toString().toLowerCase();
    return msg.contains('404') || msg.contains('not found') || ...
  }
  ```
- **问题**: 异常消息内嵌 `host:port`（如 `:8404`）或对象名含 `404` 时，**任何网络/权限错误都被误判为「文件不存在」**。`exists()` 返回 false → 调用方（如 `_detectUploadConflict` 的 meta==null 分支、附件上传的 remoteHas 判断）认为云端无数据 → 触发覆盖上传。WebDAV 侧 WD-M3 审计已用「有结构化状态码只看状态码；无结构化信息仅措辞匹配」修掉完全相同的问题（webdav_storage_service.dart:779-794 注释详述了 `:8404` 案例）；iCloud 侧未同步修复。
- **影响**: iOS 用户 + 文件名/端口含 404 字样的场景下存在**静默覆盖云端数据**的理论路径。当前 iOS 路径 `PlatformException.code` 优先（原生结构化错误码），降低了实际命中面，但 code 缺失的原生实现走 message 兜底分支时风险完全敞开。
- **方案**: 对齐 WebDAV 修复口径——`code` 判定保留并收紧为精确值集合（`'404'`/`'filenotfound'` 等枚举形态而非 contains），message 兜底**删除 `contains('404')` 数字子串**，只保留 `not found`/`nsfilenosuchfileerror` 措辞匹配；同时为 exists/list 的 404 判定补单测（异常消息携带 `:8404` 的反例）。

#### P0-3【正确性风险】Supabase 认证/网络错误不可区分 + statusCode 字符串判定
- **定位**: `packages/flutter_cloud_sync_supabase/lib/src/supabase_storage_service.dart` 全文件——所有 `on supabase.StorageException catch (e)` 分支只产出 `CloudStorageException`；404 判定 `e.statusCode == '404' || e.message.contains('not found')`（:77/:104/:177/:230）。
- **问题**: ① 401/403/网络超时/权限不足统一变 `CloudStorageException`，上层 `_isAuthErrorText` 只能文本猜（N13）；② `e.message.contains('not found')` 在 Supabase 返回的错误 message 内嵌对象路径（路径含 "not found" 子串）时误判，同 P0-2 模式；③ 未设置任何请求超时——Supabase SDK 的 storage 请求依赖底层默认，连接挂起时启动检查靠外层 20s timeout 兜底，但手动同步/自动上传链路**无超时守卫**（S3/WebDAV/iCloud 均有）。
- **方案**: ① StorageException 按 `statusCode`（'401'/'403'→CloudAuthException，401/403 分文案）映射；② 404 判定收敛为 `e.statusCode == '404'` 精确匹配（message 兜底仅保留 not found 措辞且排除路径子串场景）；③ `_op` 同款 CancelToken+timeout 包裹（Supabase SDK 用 http client 可注入 adapter 或在 service 层 Future.timeout 兜底）。

### P1 —— 成功率/归一化结构性问题

#### P1-1【归一化】四套重试机制无统一策略层
- **定位**: N11 全表（retry_helper.dart / s3_client.dart:108-162 / webdav_storage_service.dart:155-174 / TSM:1482-1531）。
- **具体偏差**:
  - WebDAV 的 jitter 是 `DateTime.now().microsecondsSinceEpoch % (baseMs ~/ 2 + 1)`——**时间戳取模不是随机**，同一毫秒内触发的多设备/多操作退避完全同相，thundering herd 防护名存实亡；
  - TSM 附件重试 1s/2s/4s 无 jitter；
  - core RetryHelper 设计最完整（异常类型判定 + 真随机 jitter + 404 不重试）却是死代码；
  - PUT 类非幂等操作在 S3 完全不重试（s3_client.dart:107 注释自认 A-1 覆盖竞态未修）——但**条件写路径**（If-Match 命中即服务器未落盘旧内容、412 即他机已写）实际上使 PUT 具备了安全重试的前置条件：条件写超时后重试，若远端已落盘本次内容，If-Match 会 412（ETag 变了）→ 转冲突流程而非覆盖，**不会丢他机数据**。这个特性没有被利用。
- **方案**:
  1. 把 core RetryHelper 定为唯一重试原语：抽 `RetryPolicy`（元数据探测 / 传输 / 幂等读三档），参数集中在一处；
  2. WebDAV jitter 换 `Random`（对齐 S3 的 P5 实现）；
  3. TSM 附件重试迁移到 RetryHelper；
  4. S3/WebDAV 的**条件 PUT** 增加有限重试（2 次，200ms 退避）——安全性由 If-Match 锚点保证（超时重试最坏转为 412 冲突，不丢数据）；盲 PUT（后端不支持条件写时）维持不重试 + 写后校验兜底现状；
  5. 删除或标记 NoopStorageService 的 UnsupportedError 与 RetryHelper 未用入口的文档状态（P2-5 一并处理）。

#### P1-2【归一化】超时分级缺单点配置，S3 30s PUT 压低慢网成功率
- **定位**: N12 全表。S3 timeout 默认 30s（s3_client.dart:67），`S3Provider.initialize` 未传入覆盖值（s3_provider.dart:105-113）。
- **量化**: 2026-09-07 实测单账本快照 347~350KB；上行带宽 <117KB/s（350KB/30s）即超时。移动网络弱网/跨境 OSS 完全可能落入该区间 → **上传必失败且无重试**（P1-1 第 4 点），错误还可能是「超时但服务端已写入」的歧态（下次 getStatus 才能收敛）。
- **方案**: 定义全后端统一的超时分级（建议）：元数据操作（HEAD/PROPFIND）15-20s；对象传输（PUT/GET）按 contentLength 自适应（如 `30s + 30s/MB`，上限 5min，对齐 StartupSyncChecker._publishTimeout=5min 的既有结论）；探测 60s。S3/WebDAV/iCloud/Supabase 的 client 构造处从同一常量类取值。这单项预计直接消除慢网 S3 用户的一类确定性失败，是 99.9% 目标的最大单项收益。

#### P1-3【监控配套】写后校验 verified=false 与各类「软失败」无计数出口
- **定位**: `CloudUploadResult.verified=false`（cloud_sync_manager.dart:76-88）、`_warnIfRemoteFingerprintMismatch` 软告警（TSM:2155+）、附件 `objectMissing/transientFailure`（TSM:1360-1381）、备份恢复 `failed` 计数（cloud_backup_service.dart:331-334）——这些信号全部只进日志，无任何聚合出口。
- **方案**: 与 P0-1 的 SyncMetricsService 一并埋点（见 §五）；每类软失败单独计数（它们正是 99.9% 与 99% 之间的差距来源：不报错但数据未收敛）。

#### P1-4【归一化】Supabase/iCloud 能力缺口未显式化，盲写降级无用户感知
- **定位**: N1/N2/N4——两后端不支持条件写时，`CloudSyncManager.upload` 仅 `logger?.warning('Conditional write requested but backend lacks support; falling back to blind upload')`（cloud_sync_manager.dart:252-257），用户不知晓并发保护降级；Supabase metadata 写失败零感知（N2）。
- **方案**:
  1. 短期（不改协议）：云服务页后端卡片增加能力矩阵展示（条件写/二进制/重试——探测后标注「本后端并发保护为校验兜底」），把降级从静默变透明；
  2. 中期：Supabase metadata 补迁移引导（检测 file_metadata 表不存在时给出 SQL 提示，README 已有）+ 写失败时 UI banner；iCloud 侧 upload 传 metadata 但 list/getMetadata 依赖原生实现，需在 icloud_method_channel 原生侧确认 customMetadata 落盘（当前 Dart 侧只管传）；
  3. 二进制路径：Supabase SDK 的 uploadBinary/download 本身就是字节接口（supabase_storage_service.dart:36-44 已用 uploadBinary），**实现 BinaryCapableStorage 只需把 download 换成字节下载 + 保留文本兼容**，工作量小收益直接（-33% 流量）。

#### P1-5【一致性】完整性校验双轨（manager 死代码 vs app 软告警）
- **定位**: N14。`CloudSyncManager.download` 的 P4 校验（cloud_sync_manager.dart:362-400，含竞态重试 + 硬失败）因 app 层全部直连 storage 而从未运行；app 侧 `_warnIfRemoteFingerprintMismatch` 是不阻断的软告警（设计理由：指纹算法升级迁移窗口不能把恢复卡死）。
- **方案**: 二选一收口：① 把 manager 的完整性校验抽成可复用函数，app 恢复/预览链路调用（失败语义定为「重下重试一次仍不一致 → 抛异常」，与 manager 现逻辑相同）——恢复是破坏性操作，吃进坏数据比阻断更危险，软告警偏宽；② 或删除 manager 内死代码并文档化 app 层软告警为唯一策略。建议 ①，理由：CDN/网关陈旧副本正是它设计防御的对象，且恢复链路已有空快照守卫等多重阻断先例。

#### P1-6【数据一致性】云端槽位残留 → 重复导入窗口（会话级补删仅内存）
- **定位**: `_staleRemoteSlots`（TSM:74-76）——换名收尾删除失败时登记补删，**进程重启即丢失**（注释自认：「进程重启后丢失（发现弹窗的用户确认仍是最终闸门）」）。2026-09-07 实测即踩中该窗口（报告 §5：B 端发现 12 个账本、12,012 笔，需手工 SQL 清理）。
- **影响**: 换名中断 + 重启的用户，下次启动会把旧槽位当「云端新账本」再次导入，交易×2。虽然弹窗可拒，但默认路径是下载全部。
- **方案**: 把 `_staleRemoteSlots` 持久化（一张小表或 SharedPreferences 键，写入时机与现有登记点相同）；或在发现阶段对「slotKey 与本地任何账本 syncId/名称都不沾边 + uploadedAt 早于本地最早账本创建时间」的条目降权提示（标注「疑似历史残留」）。前者简单且根治。

### P2 —— 性能 / 清理 / 健壮性

#### P2-1【性能】getStatus 每次缓存未命中即全量导出 JSON 算指纹
- **定位**: TSM.getStatus（:1856-1858 `exportTransactionsJson` 全量导出 + jsonDecode）。60s TTL 缓存与 15s recent-upload 窗口覆盖了大部分高频调用，但：UI 的 `syncStatusProvider` 每次 tick 对每个账本独立调用；多账本用户（实测 6 账本×350KB）冷启动首轮 = 6 次全量导出+解析（isolate 解析已优化，导出本身仍主线程 DB 遍历）。
- **方案**: 指纹缓存表（ledgerId → fingerprint + 基于最近 local_changes/updated_at 的失效判断，v40 已给 transactions 补 updated_at 触发器，失效判定有现成信号）；或 getStatus 的本地侧改用 ChangeTracker 证据快速判定「本地无变更时复用上次本地指纹」。

#### P2-2【性能】附件上传每轮 list 全量
- **定位**: N8（TSM:1184-1192）。已从 N 次探测优化为 1 次 list，但 auto_sync 每次记账（防抖后）仍全量列举云端附件目录。
- **方案**: 会话级 remoteNames 缓存 + TTL（附件对象内容寻址、本会话上传成功即加入集合，无需重列）；或 list 失败降级路径维持现状。预计大附件库 + 连续记账场景网络请求量降 90%+。

#### P2-3【性能】iCloud 上传 base64 经 method channel JSON 编码
- **定位**: icloud_storage_service.dart:56-63——`base64Encode(utf8.encode(data))` 后 method channel 再 JSON 包装，大附件内存峰值 ≈ 4×原文件（utf8→base64→JSON escape）。
- **方案**: 原生侧改文件路径传递（Dart 先落 tmp 文件传路径），或 chunked method channel。与 P1-4 二进制路径改造合并考虑。

#### P2-4【健壮性】备份调度成败均记当日已触发
- **定位**: backup_scheduler.dart:66-68（`lastDate == formatDate(now)` 即不再触发，注释「成败均算」）。
- **方案**: 失败时记录失败状态，次日窗口内重试一次（或下次 App 冷启动补一次），配合 P0-1 埋点观测真实备份成功率。

#### P2-5【清理】死代码与三处重复
- core `RetryHelper` 生产零调用（P1-1 收编后即非死代码）；`DatabaseSyncManager`（788 行）零调用；`SupabaseRealtimeService`/`SupabaseDatabaseService` 装配后零调用；`NoopStorageService` 各方法抛 `UnsupportedError`（Error 而非 Exception，`RetryHelper` 只捕 Exception，若未来接入重试链会穿透——统一改抛 CloudConfigurationException）；`_normalizeMetaValue`/`_metaValue` 三处重复（N3，收口到 core 单一实现，S3 client 保留存储层解码、消费层归一化进 core）。
- **方案**: Realtime/DatabaseSyncManager 随 PiggyCountCloud 下线删除（与 58a277b 同系列收尾）；meta 归一化抽到 core 公共函数；Noop 异常类型修正。

#### P2-6【文档】超时/重试参数无集中文档
- 各参数散落在注释里（本报告 N11/N12 表可作为初始版）。建议随 P1-1/P1-2 的统一常量类落一份 `docs/sync-reliability-params.md`，包含每档值、理由、后端差异。

#### P2-7【已确认非问题备案】（避免后续重复排查）
- 共享账本 `is_shared/member_count` 不随快照传输——v9 协议设计内行为（下线云端协同时有意排除，实测报告 §6.1）；
- 汇率覆盖 rate '9.0' vs '9' 同值异形——TEXT 列导入规范化，无数值影响（实测报告 §6.2）；
- `different`（方向未知）不进启动候选——防误弹的设计取舍，云同步页手动处理；
- WebDAV 条件写非原子——接口层文档已备案，写后校验兜底；
- S3 双前缀/keyPrefix 校验、WebDAV 信封格式、加密装饰器 P0-2 条件写密文形态对齐（encrypted_cloud_storage.dart:128-168 修复注释详尽）——均已收敛。

---

## 五、同步成功率监控机制方案（99.9% 目标）

### 5.1 约束条件（决定方案形态）

1. **隐私硬约束**: `PRIVACY.md` 承诺零遥测/零分析/零服务器运营（:127、:166-178）→ **禁止任何自动上报**。监控必须是纯本地测量。
2. **无后台常驻**: 备份调度器注释明确「无后台常驻能力为已声明的非目标」→ 指标只能在 App 运行期采集，冷启动/后台期失败不可观测（如实计入局限）。
3. **多后端**: 指标必须按后端类型（s3/webdav/supabase/icloud）分组——同一代码路径在不同网关上的成功率差异是诊断关键（S3-W2 网关怪癖先例）。

### 5.2 设计：SyncMetricsService（本地结构化指标）

```
表 sync_op_log（v42 迁移）:
  id, ts, backend(s3/webdav/supabase/icloud),
  scenario(枚举),           -- 核心场景，见 5.3
  ledger_id?,               -- 可空（全局操作）
  outcome(enum: success/failed/soft_fail/conflict),  -- soft_fail 见下
  error_class(enum: network_timeout/auth/gateway/precondition/data_corruption/unknown),
  attempts(int),             -- 含重试的总尝试次数
  duration_ms(int),
  bytes?                     -- 传输量（性能归因用）
```

- **soft_fail 单列**（对应 P1-3）：`verified=false`、`objectMissing`、指纹不匹配软告警、备份恢复单账本 failed——「操作报成功但数据未收敛」是 99.9% 与 99% 的差距主体，必须独立于 failed 可查询；
- **outcome=conflict**（412/M7 拦截）不算失败——它是并发保护正确工作的证据；
- **采集点**（最小集，直接挂现有 try/catch 收口处）：
  - TSM._uploadCurrentLedgerCore 成功/verified/冲突/异常四态
  - TSM._downloadAttachmentBinWithRetry 三态 + attempts
  - downloadAndRestoreToCurrentLedger / downloadAndPreview 成败
  - StartupSyncChecker._runInternal 的 failedLedgers/unknownDiffLedgers 计数
  - CloudBackupService.createBackup / restoreBackup 的成功/失败/failed 计数
  - discoverRemoteLedgers 慢路径命中率（观测 metadata 通道健康度，直指 N2）
- **聚合展示**: 云同步页新增「同步健康」卡——近 7/30 天核心场景成功率（`success / (success+failed+soft_fail)`，排除 conflict）、失败 Top 错误类别、各后端分组；数据量小（每行 <100B，日均 <200 行）随 local_changes 同款 30 天清理。
- **导出**: 维护页「诊断包导出」把 sync_op_log + 相关 CloudSync 日志过滤成 JSON/zip，用户主动分享给开发者。零遥测承诺完全保持。
- **验收基线**: 上线后以 30 天窗口建立基线；99.9% 的达成路径不是直接达标，而是「埋点 → 定位 top 失败类 → 消除（P1-2 超时/P1-1 重试是预判 top2）→ 复测」的闭环。实验室侧同步补一个弱网档（如 100KB/s 带宽 + 300ms RTT 的双端实测档位，复用 scripts/live_db 测试资产），把 100 轮压测从「随机中断」扩到「带宽受限」维度。

### 5.3 核心场景定义（99.9% 的分母口径）

| 场景 | 入口 | 说明 |
|---|---|---|
| 快照上传 | uploadCurrentLedger | 含附件对象上传；含手动/防抖/合并回传三触发源 |
| 快照恢复 | downloadAndRestoreToCurrentLedger + downloadRemoteLedger + fullRestore | 破坏性恢复 |
| 启动检查 | StartupSyncChecker.runIfNeeded | 含发现/导入/状态/合并/回传全链 |
| 附件补齐 | drainAttachmentJobs | 后台异步，soft_fail 高发区 |
| 云端备份 | createBackup / restoreBackup | 每日定时 + 手动 |

---

## 六、优化方案汇总（实施优先级）

| 优先级 | 项 | 对应问题 | 预期收益 | 工作量 |
|---|---|---|---|---|
| **P0** | SyncMetricsService 埋点 + 健康卡 + 诊断导出 | P0-1, P1-3 | 成功率可测量，99.9% 有验收手段 | 中（1 表 + ~8 埋点 + 1 卡片） |
| **P0** | iCloud `_isNotFoundError` 去数字子串 + 单测 | P0-2 | 消除理论性静默覆盖路径 | 小 |
| **P0** | Supabase 异常类型化 + 404 精确判定 + 超时 | P0-3 | 认证错误可引导；挂起可恢复 | 小 |
| **P1** | 超时分级统一（元数据 15-20s / 传输按体积自适应 30s+30s/MB 上限 5min） | P1-2, N12 | 直接消除慢网 S3 上传确定性失败——最大单项成功率收益 | 小-中 |
| **P1** | 重试收编 RetryHelper + WebDAV 真 jitter + 条件 PUT 有限重试 | P1-1, N11 | 弱网成功率提升 + 多端重试风暴防护真正生效 | 中 |
| **P1** | 槽位补删持久化 | P1-6 | 消除换名中断→重启的重复导入窗口 | 小 |
| **P1** | 完整性校验收口（manager 校验函数化供 app 恢复链复用） | P1-5, N14 | CDN/网关陈旧副本在破坏性恢复前被拦截 | 中 |
| **P1** | Supabase/iCloud 能力显式化（健康卡能力矩阵 + metadata 迁移引导 + Supabase BinaryCapableStorage） | P1-4, N1/N2/N4 | 降级透明；Supabase 流量 -33%；发现快路径恢复 | 中 |
| **P2** | getStatus 指纹缓存 / 附件 list 会话缓存 / iCloud 路径传文件 | P2-1/2/3 | 大账本/多附件场景 CPU 与请求量下降 | 中 |
| **P2** | 备份失败补试 + 死代码清理 + meta 归一化收口 + 参数文档 | P2-4/5/6 | 维护性、一致性 | 小 |

**建议的实施顺序**: P0 三项并行（互相独立）→ P1-2/P1-1（成功率主攻）→ P1-6/P1-5 → P1-4 → P2。每阶段结束跑一轮 `scripts/live_db` 双端实测（复用 S3 报告的注入/对比资产）+ 扩展弱网档压测，用 SyncMetricsService 的实验室数据验证收敛。

---

## 七、测试与验证现状评估

| 项 | 现状 | 缺口 |
|---|---|---|
| 单元测试 | 126 个 app 测试 + 25 个包测试，覆盖：S3 签名/时钟偏差/条件写/翻页/流式、WebDAV 状态码/信封、指纹全序化、diff 空云守卫、启动检查 publish 守卫、恢复互斥、上传冲突 | iCloud `_isNotFoundError` 无「端口含 404」反例（P0-2）；Supabase 认证异常映射无测试（P0-3）；重试参数无跨后端一致性断言 |
| 集成实测 | 2026-09-07 双模拟器 S3 全链（8 表逐字段 0 差异 + 指纹恒等）；2026-09-04 100 轮中断压测（100% 收敛） | 均为 S3 后端 + 正常带宽档；**WebDAV/Supabase/iCloud 无双端实测记录**；无弱网档（P1-2 的 30s 超时问题恰在此档暴露） |
| 监控验收 | 无 | 99.9% 无测量口径（P0-1） |

测试资产可复用性良好：`scripts/inject_16384_sync_test.py`、`compare_sync_final.py`、webdav_test 自签服务器、pretest_backup 库均可直接支撑后续每阶段回归。

---

## 八、结论

- **数据正确性**: 达标（实测 0 差异、压测 100% 收敛、三层并发防护 + 恢复互斥体系完备）。
- **归一化**: S3/WebDAV 双主力后端已收敛；Supabase/iCloud 存在能力与错误处理的系统性落差（N1/N2/N4/N12/N13 + P0-2/P0-3）；横切关注点（重试/超时/meta 归一化/完整性校验）无统一单点，存在 4 套重试、5 处超时、3 处 meta 归一化的重复与漂移。
- **监控**: 零设施。99.9% 目标当前无测量口径——建议以本报告 §五方案（本地 sync_op_log + 健康卡 + 诊断导出，符合零遥测承诺）作为第一优先级落地，随后按 §六顺序实施优化，每阶段以双端实测 + 弱网档压测闭环验证。
- 全部 19 项问题已给出定位（file:line）、影响分析与方案；本报告遵循「只排查不修改」约束，未改动任何源码。
