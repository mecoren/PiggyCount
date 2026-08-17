# PiggyCount 同步代码审计报告

> 审计范围：除专属实时云通道（`piggycount_cloud_provider.dart`、`sync_engine_realtime.dart`）之外的全部同步相关代码。
> 审计日期：2026-08-17
> 约束：仅审查、不修改任何源码。
> 结论性质：静态代码审查 + 调用链分析，未在真机/模拟器上运行。

---

## 一、覆盖的代码清单

| 文件 | 角色 |
|---|---|
| `lib/cloud/sync/sync_engine.dart` | 核心编排器（push / pull / sync / fullPush / fullPull） |
| `lib/cloud/sync/sync_engine_apply.dart` | pull 路径：远端变更 → 本地 Drift apply |
| `lib/cloud/sync/sync_engine_resolvers.dart` | syncId ↔ 本地 int id 解析 + `_getDeviceId` |
| `lib/cloud/sync/sync_engine_status.dart` | 健康检查 + `backfillUntrackedEntities` |
| `lib/cloud/sync/sync_engine_pull.dart` | `AppCursorStore` / `SyncErrorStore` / `LookupCache` |
| `lib/cloud/sync/sync_engine_serialization.dart` | push 序列化 + fullPush |
| `lib/cloud/sync/sync_engine_attachments.dart` | 附件上传/下载/清理 + 分类图标 |
| `lib/cloud/sync/sync_engine_profile.dart` | profile / avatar 同步 |
| `lib/cloud/sync_fingerprint.dart` | 快照内容指纹 |
| `lib/cloud/sync/change_tracker.dart` | 本地变更追踪（`local_changes` 表） |
| `lib/cloud/transactions_json.dart` | 快照导出/导入（fullPush/fullPull 路径） |
| `lib/cloud/startup_sync_checker.dart` | 启动两阶段收敛（Path A） |
| `lib/cloud/sync_diff_service.dart` | 快照 diff（Path A） |

---

## 二、已确认问题（按严重度排序）

### F1 【高 / 性能】`applyRemoteChange` 每条变更都做一次异步 `_getDeviceId()` —— 严重 N+1

- **位置**：`sync_engine_apply.dart:13`（在 `for` 循环内逐条调用）；`_getDeviceId` 实现见 `sync_engine_resolvers.dart:92-95`。
- **问题**：`applyRemoteChange` 开头 `final deviceId = await _getDeviceId();` 对**每一条** pull 下来的 change 都执行一次。而 `_getDeviceId()` 内部 `await provider.auth.currentUser` 是一个 async 调用（即便命中内存缓存，也是一次 `await` 微任务往返）。deviceId 在一次 pull 内是恒定常量，却按 change 数量线性放大。
- **影响**：一次拉取 1 万条变更 = 1 万次异步往返，仅用于读取一个不变的值。与 pull 路径精心设计的 `LookupCache`（消除 DB 层 N+1）形成鲜明反差，是该优化的一处遗漏。大账本首次同步 / 重放（replayAllChanges）会明显变慢。
- **建议**：在 `pull` 入口（或 `_runPullLoop`）一次性解析 `deviceId` 并作为参数传入 `applyRemoteChange`，或一个 `_currentDeviceId` 字段在 pull 开始时赋值、结束时清空。

### F2 【高 / 正确性】`backfillUntrackedEntities` 依赖一个并不存在的唯一约束

- **位置**：`sync_engine_status.dart:158-254`，关键注释在 `:168-170` 与 `:187`。
- **问题**：注释明确写道“重复的会被 unique 约束拦住 —— 重复 insert catch 住 = 无害重复”。但 `local_changes` 表（`lib/data/db.dart:225-235`）并无任何唯一约束（`entityType/entityId/entitySyncId/ledgerId/action` 均为普通列）。因此 `recordUserGlobalChange` / `recordLedgerChange` 在重复调用时**不会**因唯一约束失败，而是**直接插入第二条行**。
- **雪崩逻辑**：函数内的去重只依赖内存里的 `allUnpushed` 集合（`:159-165`），它只含**未推送**的 change。当一条被 backfill 的 create change 被推送（markPushed）后，它不再属于“未推送”，于是**第二次**调用 `backfillUntrackedEntities` 时该实体 syncId 不在 `allUnpushed` 中 → 再次插入一条 create change。云侧 upsert 是幂等的（数据不坏），但本地 `local_changes` 持续膨胀、重复行被重复推送、未来 `getUnpushedChangesForLedger` 返回量变大、健康检查计数失真。
- **触发条件**：云同步页反复下拉触发健康检查 → 检测到差异 → 反复 backfill（并非极端场景，用户多拉几次即触发）。
- **建议**：
  1. 在 `local_changes` 表加唯一约束 `(entityType, entitySyncId, action)`（彻底修复，符合代码原意）；
  2. 或：backfill 前先查**全部**含该 syncId 的 change（含已推送），而非仅未推送集合，避免重插。
  同时建议把 `recordUserGlobalChange` 的“已存在则跳过”语义落到数据库约束上，而不是靠 try/catch。

### F3 【中 / 数据完整性】`_backfillLegacyUserGlobalChanges` 漏掉 `exchange_rate_override`

- **位置**：`sync_engine.dart:840-916`（`_backfillLegacyUserGlobalChanges` 仅循环 account / category / tag）。
- **问题**：`exchange_rate_override` 是 user-global 实体（白名单 `recordUserGlobalChange` 已包含它，见 `change_tracker.dart`），增量推送 `_doPushUserGlobalEntities`（`:796`）也会推送它；但 legacy backfill **只补 account/category/tag**。于是：v19→v27 之间创建、从未开过云同步的老 `exchange_rate_override` 行（有 syncId 但无 `local_changes` 记录）永远不会被登记 → 永远推不上云 → 多设备间汇率覆盖静默丢失。
- **建议**：在 `_backfillLegacyUserGlobalChanges` 增加 `exchange_rate_override` 循环（类似 account 处理）；另外 `backfillUntrackedEntities`（F2）同样漏了它，应一并补上。

### F4 【中 / 行为不符注释】pull 页大小注释写 50，代码实际用 500

- **位置**：注释 `sync_engine.dart:1113`（“小颗粒度:单页 limit 50(原 500)”）；实际代码 `:1259` 与 `:1303` 均为 `limit: 500`。
- **问题**：注释声称“单页 50 让 retry 范围 + UI 反馈更可控”，与实现相反。纯文档缺陷，但会误导后续维护者；且该分页大小关系到失败整页回滚的代价（一页 500 条 change 整页回滚 = 500 条不入本地）。
- **建议**：要么把注释改为“单页 500（原 500）”，要么若确实想要小颗粒度则把代码改为 50 并相应调整注释。属于“意图与实现不一致”。

### F5 【中 / 状态持久化缺口】`AppCursorStore._key()` 返回 null 时静默 no-op

- **位置**：`sync_engine_pull.dart:62-71`（`_key()`），影响 `read()` `:30-32`、`commit()` `:39-41`、`migrateFromProviderCursor()` `:48-49`。
- **问题**：当 `auth.currentUserId == null || auth.currentDeviceId == null` 时 `_key()` 返回 null。此时 `read()` 直接返回 0，`commit()` / `migrateFromProviderCursor()` 直接 return —— **不写 SharedPreferences、不报错、不告警**。若在某段窗口内（如设备注册尚未完成、或登录态瞬时为空）发生 pull，cursor 不会被持久化，下次 pull 从 0 起拉全部 change（upsert 幂等不坏数据，但浪费带宽、重复应用、可能触发 UI 重刷 / 重复下载）。
- **建议**：`_key()` 为 null 时至少 `logger.warning` 一次，便于排查；并评估 cursor 是否应改为按 userId 即可持久（deviceId 缺失不应完全阻断 cursor 持久化）。

### F6 【中 / 性能】增量 push 路径 `_serializeEntityForPush` 逐条 N+1 查询

- **位置**：`sync_engine.dart:_doPush` 循环 `:1020-1065` 逐 change 调 `_serializeEntityForPush`；后者实现 `sync_engine_serialization.dart:14-332`，每条 change 单独 SELECT 父 ledger / category / account / toAccount / 每个 tag（`tagNames` 循环内还逐 tag 单查）。
- **问题**：pull 路径通过 `LookupCache` 消灭了 DB N+1，但 **push 路径没有对等优化**。`fullPush` / `_pushAllEntities` 预载了 categories/accounts/tags 列表（好），但**增量 `_push`** 仍按 change 重新逐条查库。N 条未推送变更 ≈ N×~8 次 SELECT。
- **影响**：大量本地编辑后首次增量 push（或健康检查的“本地比云端新”场景）会变慢，量级随未推送 change 数线性增长。
- **建议**：为 push 路径构造与 pull 对称的轻量缓存（预载 account/category/tag/transaction 的 syncId→id 映射），`_serializeEntityForPush` 内部改查缓存。

### F7 【低~中 / 可诊断性】多处空 `catch (_)` 吞掉异常细节

- `sync_engine.dart:1137` `} catch (_) {}` —— 复用 in-flight pull 时吞掉错误（意图可接受，但根因丢失）。
- `transactions_json.dart:567` `} catch (_) {}` —— budget 解析失败仅 `_skip` 计数，**异常对象与堆栈被完全丢弃**，损坏快照难以诊断。
- `sync_engine_attachments.dart:260`（图标存在性检查）与 `:340`（缩略图清理）`catch (_) {} / /* best effort */`，错误细节丢失。
- `sync_diff_service.dart:404` `} catch (_) {}` —— monthStartDay 更新失败静默忽略。
- **建议**：这些吞异常处至少 `logger.debug('...', e)` 记录异常，便于线上排查。

### F8 【低 / 并发脆弱性】`pendingCustomIconJobs` 被 apply 与 unawaited drain 共享

- **位置**：apply 事务内 enqueue（`sync_engine_apply.dart:_applyCategoryChange`），`sync_engine.dart:1336` `unawaited(drainCustomIconQueue())` 后台处理。
- **问题**：Dart 单 isolate 下不存在数据竞争，但“共享可变列表 + fire-and-forget”模式脆弱——若未来 pull 被并行化、或 drain 中途抛未捕获异常，job 可能丢失/重复。当前可接受，仅作风险标记。

### F9 【低 / 健壮性】`syncMyProfile` 吞掉全部错误仅返回 `anyChanged`

- **位置**：`sync_engine_profile.dart:99-102`。
- **问题**：任何 profile / avatar 同步异常被 catch 后返回 `anyChanged`，不重抛。符合“非致命”设计，但服务端持续返回非法 avatar URL 等情况会**每轮同步无限静默重试**而无任何 UI 提示。建议对 avatar 下载失败做退避 / 计数上限。

### F10 【信息 / 设计确认】冲突解决为服务端 LWW，本地变更在 pull 时无条件让位

- **位置**：`sync_conflict_resolver.dart` 中 `shouldApplyRemote` 直接 `return true`，`logConflict` 仅打日志。
- **说明**：这是设计选择（服务端 `server_received_at` 为准的 Last-Writer-Wins），并非 bug。但需注意：**离线编辑后在 pull 到达前若远端有同实体变更，本地离线编辑会被静默覆盖**（无本地优先路径）。对记账类应用，若用户在意离线编辑不丢，应在 UI 层增加“待解决冲突”提示，而非依赖当前“服务器必胜”模型。

---

## 三、审计中确认的正面设计（避免误报）

- **单飞锁充分**：push / fullPush / fullPull / pull / syncLedgersFromServer 均有 per-ledger（或 static 跨实例）in-flight 去重，避免重复推送造成的云端膨胀（见 `sync_engine.dart` 各 `_*InFlight` 字段）。
- **cursor 安全**：仅在**整页 apply 成功**后才 `appCursor.commit`；失败页 → `SyncErrorStore.record` + `blocked` 终止、cursor 不前进（`:1318-1332`、`:1375-1388`）。
- **N+1 防护（pull 路径）**：`LookupCache`（`:242-274`）一次性 prime 全表，apply 内优先查缓存，10k 条从 ~10 万次 SELECT 降至 ~5 次，设计正确。
- **防回环**：`withRecordingSuppressed` / `recordPulledFromServer` 确保 pull→本地→push 不会把云端数据回灌成新 change（`_applyAccountChange:441` 等处）。
- **fullPull 防回流**：`importTransactionsJson(..., recordChanges: false)`（`:1475`）避免拉取的快照被反向推回。
- **附件并发与重试**：`uploadAttachments` / `downloadAttachments` / `drainCustomIconQueue` 均用 `Semaphore(4)` + 指数退避重试，且 `_cleanupTxAttachmentFilesOnDisk` 校验“是否有其它交易仍引用同文件”再删，避免误删共享附件。
- **快照导入容错（H1）**：`parseJsonToImportData` 对脏字段用 `_readString/_readInt/...` 安全读取、必填缺失则跳过并计数，单条损坏不拖垮整账本恢复。

---

## 四、优先级与修复建议汇总

| 编号 | 严重度 | 类型 | 一句话修复 |
|---|---|---|---|
| F1 | 高 | 性能 | pull 入口一次性取 deviceId，按 change 传参而非逐条 `await` |
| F2 | 高 | 正确性 | `local_changes` 加 `(entityType,entitySyncId,action)` 唯一约束，或 backfill 前查全量 change 去重 |
| F3 | 中 | 数据完整性 | legacy backfill 与 `backfillUntrackedEntities` 均补 `exchange_rate_override` |
| F5 | 中 | 状态持久化 | `_key()` 为 null 时告警；评估 cursor 是否可仅按 userId 持久 |
| F6 | 中 | 性能 | push 路径增加与 pull 对称的序列化缓存 |
| F4 | 中 | 文档/意图 | 校正 pull 分页大小注释（50 vs 500） |
| F7 | 低~中 | 可诊断性 | 空 catch 至少 `logger.debug(e)` |
| F8 | 低 | 并发 | 图标队列模式加固/加测试 |
| F9 | 低 | 健壮性 | profile/avatar 失败加重试上限 |
| F10 | 信息 | 设计 | 评估是否需 UI 层“冲突待解决”提示 |

**最高优先**：F1（大账本同步性能）+ F2（本地 `local_changes` 随健康检查反复膨胀，真实会触发）。两者都源于“注释/设计假设与运行时不变量不符”，建议先修 F2 的约束缺失（根因），再处理 F1/F3/F6 的性能与完整性缺口。

---

## 五、未覆盖 / 建议下一步

- `backup/`（backup_scheduler / cloud_backup_service / cloud_backup_providers）未按本审计深入走查，建议单独一轮。
- `transactions_sync_manager.dart`、`flutter_cloud_sync*` 系列包属排除范围（实时云通道与底层云平台引擎），如后续要扩大范围可再议。
- 建议在 CI 加一个“`local_changes` 唯一约束 + 无空 catch”的 lint / 单测护栏，防止同类回归。
