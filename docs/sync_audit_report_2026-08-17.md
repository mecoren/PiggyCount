# PiggyCount 同步功能代码审查报告（应用侧，排除 cloud 包）

> 审查日期：2026-08-17
> 审查方式：只读静态分析（未修改任何代码）。对 `lib/cloud/` 应用侧同步编排、同步引擎、实时通道、状态机、序列化、备份、云同步页面、Provider、账户去重、共享账本等模块进行分区并行审查，并对最严重的若干发现做了逐行复核。
> 排除范围（按用户确认）：`packages/flutter_cloud_sync`、`flutter_cloud_sync_s3`、`flutter_cloud_sync_supabase`、`flutter_cloud_sync_webdav`、`flutter_cloud_sync_icloud` 等远程传输实现包（其内部不可见，仅审查应用侧"如何使用"它们）。

---

## 一、审计范围

**纳入审查（应用侧同步代码）：**
- 同步引擎核心：`lib/cloud/sync/sync_engine.dart`、`sync_engine_apply.dart`、`sync_engine_pull.dart`、`sync_conflict_resolver.dart`、`sync_engine_resolvers.dart`、`sync_coordinator.dart`
- 实时/状态/序列化/附件/变更追踪：`sync_engine_realtime.dart`、`sync_engine_serialization.dart`、`sync_engine_status.dart`、`sync_engine_attachments.dart`、`change_tracker.dart`、`entity_serializer.dart`、`sync_events.dart`、`sync_providers.dart`、`sync_engine_profile.dart`
- 应用侧编排：`lib/cloud/transactions_sync_manager.dart`、`transactions_json.dart`、`sync_diff_service.dart`、`sync_fingerprint.dart`、`sync_service.dart`、`startup_sync_checker.dart`、`startup_sync_overlay.dart`
- 备份/页面/Provider/去重/共享账本：`lib/cloud/backup/*`、`lib/pages/cloud/*`、`lib/providers/cloud_mode_providers.dart`、`lib/providers/sync_providers.dart`、`lib/services/data/account_dedup_service.dart`、共享账本相关页面

**排除：** `packages/flutter_cloud_sync*`（远程传输层：S3/Supabase/WebDAV/iCloud/核心）。

---

## 二、发现总览

| 审查维度 | 严重 | 中 | 低/建议 |
|---|---|---|---|
| 同步触发条件 | 1 | 4 | 5 |
| 数据一致性保障 | 2 | 9 | 8 |
| 网络请求处理 | 1 | 6 | 5 |
| 同步冲突解决策略 | 0 | 1 | 2 |
| 本地与远程数据同步逻辑 | 1 | 5 | 3 |
| 同步状态更新机制 | 1 | 4 | 4 |
| 异常捕获与处理 | 1 | 5 | 6 |
| 性能 / 资源泄漏 | 0 | 5 | 9 |
| **合计** | **~7** | **~39** | **~42** |

> 严重级多数为"在异常/边界数据下导致同步卡死、静默丢数据或状态长期失真"的可用性问题；中等级为明确的逻辑/一致性缺陷；低/建议为性能、健壮性、去抖、类型兜底等。

---

## 三、严重 / 高危问题详述（已逐行复核 ✅）

### S1. 单条"毒化 change"会永久阻塞整个 pull cursor（数据同步卡死）
- **位置**：`lib/cloud/sync/sync_engine.dart:1408-1444`（`_applyPullPage`）+ `:1358-1395`（`_runPullLoop`）
- **类型**：本地与远程同步逻辑 / 异常处理
- **复核**：✅ 整页被 `db.transaction` 包住；任一 change 抛不可恢复异常 → 整页回滚、`blocked=true`、cursor 不推进（`:1373-1376` 的 `break`）、下次 pull 从同一 `since` 重拉同一页再砸在同一条 change 上。
- **潜在影响**：服务端只要下发一条持久失败的数据（FK 违例、字段缺失、解密失败后再加密等），**整条增量同步链路永久卡死**，其后所有远端变更再也拉不回来，除非人工改 server 数据。
- **建议**：在 `_applyPullPage` 内对**单条** change 做 try/catch——失败的单条写入 `pullErrors` 并 `skipped++`，其余照常提交、cursor 正常推进；仅当"整页结构性失败"（如 DB 不可用）才回滚整页。

### S2. 解密失败的变更被静默跳过且 cursor 前进 → 永久数据丢失
- **位置**：`lib/cloud/sync/sync_engine.dart:1247-1295`（`_decryptPullResult`）+ `:1380`（`appCursor.commit`）
- **类型**：异常捕获与处理 / 数据一致性
- **复核**：✅ E2EE 开启时单条 payload 解密失败被置 `payload: null`（`:1274-1283`），注释明确"不中断整页"；该 change 在 apply 阶段按"数据损坏"跳过（`payload==null` 非 delete → `return false`）→ 整页成功 → cursor 推进。
- **潜在影响**：该实体在本设备**永远不被写入**，且因 cursor 已前进不会再拉到（除非 server 重发）。密钥轮换/损坏场景下静默丢数据。
- **建议**：解密失败的 change 应归入 `pullErrors`（而非当作普通 skip），并明确提示用户；或在该 change 处停止推进 cursor，避免"丢失且无法恢复"。

### S3. 备份按账本名恢复走 `importTransactionsJson`（疑似追加）→ 交易翻倍
- **位置**：`lib/cloud/backup/cloud_backup_service.dart:331-363`（关键调用 `:361`）
- **类型**：数据一致性
- **复核**：逻辑两路语义不一致——remoteId 命中走"整体覆盖"（`restoreLedgerFromJson`），按名命中却复用本地 id 调 `importTransactionsJson(repo, ledgerId, jsonStr, recordChanges: false)`。若 `importTransactionsJson` 非幂等覆盖，本地同名账本已有交易会被**追加**，整体翻倍且难回滚。
- **潜在影响**：用户从备份恢复时，目标账本交易重复，数据严重失真。
- **建议**：确认 `importTransactionsJson` 是否幂等；若非覆盖，按名命中路径改为与 remoteId 命中相同的"先清空再导入/整体覆盖"，或显式提示用户冲突。

### S4. `AIProviderManager.onConfigChanged` 全局闭包只设不清除（离开云模式仍推送 AI 配置）
- **位置**：`lib/providers/sync_providers.dart:305-318`；全仓 grep `onConfigChanged =` 仅此一处赋值，无任何 `= null` 重置点
- **类型**：同步状态更新机制 / 网络请求处理 / 数据一致性
- **复核**：✅ 该字段是 `ai_provider_manager.dart` 的**静态全局回调**，只在 `config.type == piggycountCloud` 分支内赋值，切换后端/`ref.onDispose` 都不置回 `null`。
- **潜在影响**：用户关闭/切换离开 PiggyCount Cloud 后，AI 配置保存点仍触发该闭包，持续向云端 `updateMyProfileAiConfig` 发起网络请求；且闭包捕获了**首次创建时的 `ref`**，provider 重建后存在指向旧/已 dispose provider 的 stale 引用风险。
- **建议**：在 `syncServiceProvider` 的 `ref.onDispose` 中 `AIProviderManager.onConfigChanged = null`；或在非 PiggyCount Cloud 分支显式置空，使推送与当前激活后端严格对齐。

### S5. diff 计算忽略"无 syncId 的本地交易"，合并时被静默重复/丢失
- **位置**：`lib/cloud/sync_diff_service.dart:128-141, 189-199`
- **类型**：数据一致性
- **复核**：✅ `localBySyncId` 仅收录 `tx.syncId != null`（`:130-134`）。本地存在但 `syncId==null` 的交易（老数据未回填、CSV/本地新建路径未写 syncId）不会进入索引：
  - 在"云端有/本地无"遍历（`:146-187`）中，其云端同 syncId 版本被标 `added`（插入新本地副本）→ **数据重复**；
  - 在"本地有/云端无"遍历（`:190-199`）中因 key 不在 `localBySyncId`，**不会被标 deleted**。
  - 混合场景下结果是"本地无标识交易原样保留 + 云端版本被新增一份"，即**重复**而非纯删除；但若本地全量无 syncId 而云端有（`:88-92` 仅防"云端无 syncId"，不防"本地无 syncId"），则全部被当作 `added`，预览显示大量新增，极易误点"应用"。
- **潜在影响**：本地未同步交易在跨设备合并时产生重复或出现"全量新增"误导，历史主键/附件关联重建。
- **建议**：对 `syncId==null` 的本地交易建 `id→Transaction` 备用索引，按业务键（happenedAt+amount+note）与云端兜底匹配；或显式提示"本地无标识交易将被云端版本替换"而非静默并入。

### S6. 预算/周期规则在 ledger 本地未就绪时被"静默跳过"，但 cursor 已前进 → 永久丢失
- **位置**：`lib/cloud/sync/sync_engine_apply.dart:714-718`（`_applyBudgetChange`）、`:802-806`（`_applyRecurringChange`）；`applyRemoteChange` 所有分支 `return true`（`:28-49`）
- **类型**：本地与远程同步逻辑 / 数据一致性
- **复核**：✅ 本地 ledger 未就绪时 `return` 跳过；但 `_applyPullPage` 把该 change 计为 `applied`（switch 恒 `return true`），整页事务提交、cursor 推进。该 budget/recurring 再也不会被重试。
- **潜在影响**：若 server 的 change 顺序出现"budget 先于 ledger 创建"或 replay 边界场景，该实体**永久丢失**。
- **建议**：对"暂不可应用"的 change 不应计入 applied；更稳妥的做法是**不要推进越过它**（保留 cursor），待 ledger 落地后下次 pull 再应用；或至少能在 `pullErrors` 中标记以便重试。

### S7. 设备页 `deviceId` 缺失时，用户可吊销自己的活动会话
- **位置**：`lib/pages/cloud/devices_page.dart:110`（`_currentDeviceId` 取值）、`:149-161`（`_revokeDevice` 过滤）
- **类型**：数据一致性 / 异常处理
- **复核**：`_currentDeviceId = user?.metadata?['deviceId']?.toString()`；若为 null，过滤条件 `id != _currentDeviceId` 恒为 true，**当前设备的所有会话不再被排除**。
- **潜在影响**：用户可能一键吊销"正在使用的这台设备"，导致当前会话被踢/需重新登录。
- **建议**：`_currentDeviceId == null` 时**禁止**执行任何 revoke（或至少禁止 revoke 与自身指纹匹配的组），并加日志与 UI 提示。

---

## 四、按审查维度的分类清单

### 4.1 同步触发条件
| # | 严重度 | 位置 | 问题 / 影响 / 建议 |
|---|---|---|---|
| T1 | 中 | `transactions_sync_manager.dart:997-1001` | `getStatus` 永远 `forceRefresh:true`。虽有 `_statusCache` 60s 守卫（`:949-953`）可在命中时短路，但**每次缓存未命中都强制全量云端下载+重算**；启动检查对 N 个账本缓存全空时串行全量拉取，易触发远端限流、电量/CPU 陡增。建议：缓存未过期且本地无变更时复用缓存，仅本地有变更才 `forceRefresh`。 |
| T2 | 中 | `startup_sync_checker.dart:872-883` | `_confirmEach` 阶段 2 回传在 `overlay.dismiss()` 后运行且**不 reattach overlay**，5 分钟超时/多账本串行回传期间用户无进度、成功后也无反馈，易误判卡死。建议：阶段 2 重新 attach overlay + `startApplying`，完成 `controller.done()`/`error()`。 |
| T3 | 中 | `piggycount_cloud_sync_page.dart:50-54,101` | 页面进入即 `unawaited(_onRefresh())`（含 reconcile+health+sync），与 bootstrap 自动 sync 无互斥，可能一秒内 2 次 sync。建议：共享去重信号避免重复 reconcile/health。 |
| T4 | 中 | `sync_engine.dart:398` | `sync()` 入口无顶层重入守卫；`uploadAttachments`/`fullPush`/`downloadAttachments`/`syncMyProfile` 不在单飞内，WS 重连与网络恢复并发可跑两遍。建议在 `sync()` 加 per-ledger 守卫或用 `_autoSyncing` 包住。 |
| T5 | 低 | `transactions_sync_manager.dart:1388-1406` | `refreshAllLedgersStatus` 串行遍历无节流，叠加 T1 的 `forceRefresh` 放大请求风暴。建议限并发/复用 TTL。 |
| T6 | 低 | `sync_engine_realtime.dart:679` | 见 S 级状态缓存问题（B7）。 |

### 4.2 数据一致性保障
| # | 严重度 | 位置 | 问题 / 影响 / 建议 |
|---|---|---|---|
| D1 | 中 | `sync_engine_apply.dart:454-470 / 345-354` | 删除 category/account 直接 `delete` 未清理 `transactions` 的 `categoryId/accountId` 引用 → 若启用 FK 则删操作抛错触发 S1 永久阻塞；若未启用则留下悬挂引用。建议删除前置空或确认 `ON DELETE SET NULL`。 |
| D2 | 中 | `sync_engine_apply.dart:104-106` | transaction 在 ledger 未就绪时以 `ledgerId=-1` 插入（无守卫；budget/recurring 有 skip 守卫），产生指向不存在 ledger 的孤儿交易。建议 transaction 也加"ledger 未就绪延迟应用"守卫。 |
| D3 | 中 | `sync_engine_apply.dart:1005-1010` | `_applyLedgerChange` 新建账本漏写 `isShared/myRole/memberCount` 共享字段（仅 `syncLedgersFromServer` 路径正确填充），经此路径新建的共享账本丢失角色信息。建议从 payload 读共享字段或限制该路径仅用于非共享账本。 |
| D4 | 中 | `account_dedup_service.dart:124-162` | 账户合并仅 repoint `transactions`、`recurring_transactions`；若库中存在其它引用账户的表（budgets、计划转账、附件归属等），对应行仍指向**已删除的 dup 账户 id** → 悬空外键。建议 grep 全库 `account_id` 引用点一并 repoint。 |
| D5 | 中 | `account_dedup_service.dart:60-73` | 去重仅按 `name` 分组，会静默合并用户有意建的同名不同账户（如两个"现金"），且不可自动回退。建议引入更强身份键（syncId+name）或二次确认。 |
| D6 | 中 | `sync_engine_serialization.dart:710-724` | 全量快照 JSON（`_exportLedgerJson`）序列化交易时**未传 `attachments`/`recurringSyncId`**，而增量 change 路径都带 → 两条同步路径产出不一致，fullPush 快照不含附件元数据、fullPull 还原拿不到附件。建议补齐参数。 |
| D7 | 低 | `entity_serializer.dart:40,234-238` | 周期交易时间 `toUtc()` 带来跨时区"日界"漂移（`dayOfMonth`/`dayOfWeek` 是日历概念，UTC+8 下"1 号 02:00"变"上月 31 号 18:00"），跨设备 `lastGeneratedDate`（LWW）可能反复覆盖。建议与时区约定一致，或明确按 UTC 解析并校验日界。 |
| D8 | 低 | `entity_serializer.dart:85-103` | `serializeAccount` 无条件发送 `hidden`/`excludeFromStats`/`excludeFromBudget`，DB 列为 null 时下发 null，server 未兜底则误写为 null。建议与 server 约定默认值或给兜底。 |
| D9 | 低 | `change_tracker.dart:166-191` | `recordPulledFromServer` 去重仅按 `(entityType, entitySyncId)`，忽略 ledgerId；user-global 实体 ledgerId 应为 0，但调用方若传入具体 ledgerId 会插入重复"pushed"行。建议明确 ledgerId 规约并纳入去重键。 |
| D10 | 低 | `sync_engine_attachments.dart:322-326` | `_cleanupTxAttachmentFilesOnDisk` 共享判定用 `transactionId.equals(...).not()`，会把**同一交易内**的其它附件行也排除在"共享"之外，同交易两附件同 fileName 时误删共享文件（概率极低）。建议按 `(fileName, attachmentId)` 维度精细处理。 |
| D11 | 低 | `transactions_sync_manager.dart:1300 / 1299` | `getRemoteLedgers` 用 `double.tryParse`/`int.tryParse` 解析本可能是 `num` 的 metadata（`balance`/`count`），JSON 数字反序列化后为 num → 恒 null → 余额/条数显示 0。建议 `b is num ? b.toDouble() : double.tryParse(b?.toString()??'')` 兜底。 |
| D12 | 低 | `transactions_sync_manager.dart:1984-1991` | 损坏 JSON `deserialize` 返回 ledgerId=0（"幽灵 ledger_0.json"）。建议损坏数据走"拒绝恢复"分支而非返回 0。 |
| D13 | 低 | `transactions_sync_manager.dart:451 vs transactions_json.dart:424-439` | `uploadCurrentLedger` 读 `exportMap['balance']`，但 export payload 实际**无 `balance` 键** → metadata 永远不带 balance；属无效读取。建议删除该行或在 export 增加 `balance` 顶层字段。 |
| D14 | 低 | `sync_diff_service.dart:336-350` | `applySyncChanges` 在 `tracker==null` 时跳过 `withRecordingSuppressed`，云端变更可能反向登记为本地编辑回流 local_changes。建议统一抑制语义。 |

### 4.3 网络请求处理
| # | 严重度 | 位置 | 问题 / 影响 / 建议 |
|---|---|---|---|
| N1 | 中 | `sync_engine_realtime.dart:619-621` | `_schedulePull` 只保留**一个** `_pullDebounce` 定时器；账本 A 事件触发的定时器会被 1s 内账本 B 事件 `cancel()` 且不再重调度 → 跨账本 WS 事件互相取消自动 pull，当前未激活账本远端变更长时间不同步。建议按 `ledgerId` 分别持有定时器或累积待拉账本集合。 |
| N2 | 中 | `sync_engine_realtime.dart:16-50` | 订阅 `provider.realtimeEvents` 只 `onError` 日志，**无 `onDone`/重订阅逻辑**；流结束/出错后订阅终止且永不恢复，除非外部再次显式 `startListeningRealtime`。建议 `onDone/onError` 带退避重订阅并暴露"通道已断"给上层。 |
| N3 | 中 | `sync_engine_realtime.dart:10-16` | `startListeningRealtime` 每次 `provider.startRealtime().catchError(...)` 不 await、也不 stop；重复进入（页面重建/恢复）只取消**订阅**而非底层连接，存在双连接/重复事件风险。建议在入口先 stop 或 `dispose` 显式断开。 |
| N4 | 中 | `cloud_service_page.dart:1908-1925` | `_testConnection` 的 PiggyCount Cloud 分支 `await services.provider!.storage.list(path:'')` **无超时**（其它后端都有 10s 超时）→ 服务端假死时弹窗永久卡住。建议加 `.timeout(15s)`。 |
| N5 | 中 | `transactions_sync_manager.dart:987-992` | 未加密但云端为密文时，`getStatus` 每次多一次 `raw.download` 探测（且之后 manager 内部再下载一次）→ split-brain 状态每个账本 2 次全量下载。建议按 ledgerId 短时缓存探测结果。 |
| N6 | 中 | `shared_ledger_providers.dart:32-147` | 成员/邀请/统计/接受等一次性网络调用无超时、无重试、无退避，弱网一次抖动即失败上抛。建议关键写操作加一次指数退避重试。 |
| N7 | 低 | `transactions_sync_manager.dart:1252-1363` | `getRemoteLedgers` 对不支持 metadata 的 Provider 逐文件 `getMetadata` 失败再全量下载，m 个远端账本即 m 次完整下载。建议复用快照解析逻辑或加并发上限。 |
| N8 | 低 | `transactions_sync_manager.dart:590,597-632` | `uploadAttachmentObjects` 在 `map` 闭包内每个 entry 重复 `await getApplicationDocumentsDirectory()`。建议提升到方法开头只取一次。 |
| N9 | 低 | `devices_page.dart:113-122` | 设备页每次刷新发两次 `listDevices`（deduped + sessions）。建议后端支持一次返回后本地分组。 |
| N10 | 低 | `backup_scheduler.dart:30-41` | 定时备份每分钟固定节奏重试，`onCheck` 抛错被吞、无退避；云长期不可达时每分钟无谓尝试。建议连续失败做指数退避。 |

### 4.4 同步冲突解决策略
| # | 严重度 | 位置 | 问题 / 影响 / 建议 |
|---|---|---|---|
| C1 | 中 | `sync_conflict_resolver.dart`（整文件）+ `sync_engine_apply.dart` 各 `_apply*Change` | `SyncConflictResolver.shouldApplyRemote` 恒返回 `true`、`logConflict` 全仓库未被任何调用方引用（死代码）。实际冲突处理是各 apply 方法的**无条件 upsert 覆盖**（服务端 LWW）。若 standalone `pull` 早于本地未推编辑的 push，远端变更直接覆盖本地未推送修改，**本地编辑静默丢失**（无字段级合并）。建议：真正接入 `SyncConflictResolver`（字段级检测/合并或记录 conflict 事件）或删除死代码；standalone `pull` 前确保本地未推变更先 push。 |
| C2 | 低 | `sync_engine_apply.dart:66-73,205-214` | `activePullCache != null` 时对 cache miss 不再回查 DB，直接判定"不存在→插入"；若 pull 期间有并发本地写入新增带 syncId 的行（cache 未含），远端同名 change 会触发 UNIQUE 违例。建议 cache miss 插入加 UNIQUE 兜底（catch 转 update）或首次插入前热路径 DB 校验。 |
| C3 | 低 | `sync_engine.dart:352-355` | `deleteRemoteBackup` 用 `if (!e.toString().contains('404')) rethrow;` 依赖异常文本，脆弱（403 权限会被误吞）。建议捕获具体异常类型。 |

### 4.5 本地与远程数据同步逻辑
| # | 严重度 | 位置 | 问题 / 影响 / 建议 |
|---|---|---|---|
| L1 | 中 | `sync_engine.dart:486-491` | `sync` 在 fullPush 路径对 `pushed` 计数错误：`fullPush` 推送的条数被丢弃，`pushed = localTxCount + extraPushed`；当 `localTxCount==0` 但 fullPush 实际推了分类/预算等时 `pushed==0` → 不触发 `PushCompleted` → 状态缓存不清 → "我的"页显示陈旧 `localNewer`。建议让 `fullPush` 返回实际条数并累加，或以"是否发生过任意推送"为布尔信号。 |
| L2 | 中 | `sync_engine.dart:509-523` | 纯 pull 的同步（他人改了、本机无未推变更）只当 `pushed>0` 才 emit，`pulled>0 && pushed==0` 时**不 emit 任何事件** → 首页/账本列表在"别人改了我拉到了"之后不刷新。建议 `pulled>0` 也 emit `PullCompleted`/`SyncCompleted`。 |
| L3 | 中 | `sync_engine.dart:1118-1128,827-833` | `pushChanges` 成功但 `markPushed`（DB 写）失败 → 异常冒泡使整个 `_doPush` 失败，但远端**已收到**这些 change；下次 `_doPush` 再次推送同一批 → 依赖服务端去重，否则重复实体/计数。建议把 push 与 markPushed 包成两阶段确认，或保证原子语义。 |
| L4 | 中 | `sync_engine_realtime.dart:204-205,226,259-283` | `_handleSharedResourceChange` 对 payload 字段做强类型 `as` cast，server 端字段类型不一致（如 syncId 为 int）即抛 `CastError`，被外层 try 捕获后整条资源变更被丢弃且不重发 → 共享账本镜像表与 Owner 主表不一致。建议安全类型转换/统一归一化。 |
| L5 | 中 | `sync_engine_realtime.dart:597-616` | `_purgeLocalLedgerByExternalId` 在本地 `ledgers` 行已不存在时直接 `return`，**跳过** `ledgerMembers` 与 `sharedLedger*` 镜像表清理 → 孤儿行永久留存。建议即使 `localId` 为 null 也按 `ledgerSyncId` 清理关联子表。 |
| L6 | 低 | `account_dedup_service.dart:149-160` | 去重删除/改 `ledgerId` 不被 changeTracker 记录 → 跨设备短期内账户全局化状态不一致（设计上"可自愈"）。建议对账户行变更也登记 change 或去重后主动 pull 共享资源。 |
| L7 | 低 | `join_shared_ledger_page.dart:99-117` | `onInviteAccepted` 失败仅 `logger.warning` 仍 `pop(true)` 弹"加入成功"，共享资源/历史交易拉取失败用户无感知。建议给弱提示"资源同步中/失败，请下拉刷新"。 |

### 4.6 同步状态更新机制
| # | 严重度 | 位置 | 问题 / 影响 / 建议 |
|---|---|---|---|
| U1 | 中 | `sync_engine_realtime.dart:679` | 自动 pull 后 `_statusCache.remove(int.tryParse(targetLedgerId))`，而 `targetLedgerId` 实为 **syncId（UUID 字符串）**，`int.tryParse('uuid')` 返回 null → `_statusCache.remove(null)` 清除**无效** → 用户调 `getStatus()` 仍命中陈旧缓存（如仍为 `localNewer`），"我的"页长期显示未同步。建议用 `_resolveLedgerIdBySyncId` 取得本地 int id 再 `remove`（同文件 `:657-659` 已这么做，此处遗漏）。 |
| U2 | 中 | `sync_providers.dart:218-295,374-388` | 每次 `PullCompleted(applied>0)` 批量 bump 多个 refresh Provider，且 `db.tableUpdates` 监听**每一条** transactions 提交都 `statsRefreshProvider++`；`localLedgersProvider` 又 watch 它并对每个账本跑 `getLedgerStats`。大批量导入触发 N 次级联重算，UI 卡顿/发热。建议对表变更监听做去抖/同帧合并。 |
| U3 | 中 | `piggycount_cloud_sync_page.dart:657` | 2FA 状态刷新绑定全局 `syncStatusRefreshProvider`，**每次同步**都重拉 `getTwoFactorStatus()`。建议在登录态变化/重新登录时刷新，而非挂在全局 tick。 |
| U4 | 低 | `sync_providers.dart:921-922（定义）,59（watch）` | `syncStatusRefreshByLedgerProvider` 被 watch 但全仓**无任何自增点** → "按账本局部刷新"是死代码，所有刷新走全局 tick。建议精准 bump 或删除该 family。 |
| U5 | 低 | `sync_engine.dart:296-297,312-316` | `getStatus` 的 `unpushedCount` 仅统计 ledger 作用域未推变更，不含 account/category/tag 等 user-global 变更 → 用户改了分类/账户却始终显示 `inSync`。建议合并 user-global 未推计数。 |
| U6 | 低 | `sync_engine.dart:121-132` | `_eventsController` 为 `broadcast(sync: true)`，某 listener（Riverpod）同步抛异常会沿 `_emit` 调用栈反向冒泡，可能中断正常同步后处理。建议 `_emit` 中对 listener 异常做 zone/ try-catch 隔离。 |
| U7 | 低 | `piggycountCloudServerVersionProvider`（`sync_providers.dart:620-634`） | 每次同步都请求 `/version`，叠加其它冗余请求总量可观。建议版本号本地缓存+节流。 |

### 4.7 异常捕获与处理
| # | 严重度 | 位置 | 问题 / 影响 / 建议 |
|---|---|---|---|
| E1 | 中 | `transactions_sync_manager.dart:963-971,1056-1070` | 本地 `exportTransactionsJson` 在账本不存在时抛 `Exception('账本 ... 不存在')`，被 `getStatus` 末尾通用 catch 捕获返回 `error` 态 → 启动检查把该账本计入 `failedLedgers` 弹"网络或超时"，误导用户。建议开头单独 try 并对"账本不存在"返回 `notConfigured`/`noRemote` 语义态。 |
| E2 | 中 | `sync_engine.dart:507` | `syncMyProfile()` 在 `sync()` 内直接 await 且无保护（附件上传/下载都包了 try/catch），它抛错使整个 `sync` 返回 error，丢失本次 pull 结果语义。建议同款包层 try/catch 仅记日志不阻断。 |
| E3 | 中 | `sync_engine_realtime.dart:183-184` | `member_change`（非 removed/joined）每次事件都直接 `await syncLedgersFromServer()` 且无去抖；server 短时广播多条 member_change（批量邀请）会串行触发多次完整 `syncLedgersFromServer`，DB/网络风暴+UI 抖动。建议去抖/合并。 |
| E4 | 低 | `transactions_sync_manager.dart:1009-1020,1044-1055` | `SaltMismatchException` 既被类型捕获（`:1044`）又被字符串 `message.contains('SaltMismatchException')` 兜底（`:1009`），字符串匹配与包内部异常文本强耦合，包改文案即失守。建议以类型捕获为准、字符串仅作文档化兜底。 |
| E5 | 低 | `cloud_sync_page.dart:543-546` | `activeCloudConfigProvider` 加载失败直接渲染 `'$e'` 裸文本，无重试入口/本地化。建议错误分支加 Retry 按钮 `ref.invalidate(...)`。 |
| E6 | 低 | `join_shared_ledger_page.dart:133-145` | `_formatError` 用 `raw.contains(...)` 子串匹配 `'Already a member'` 等做文案映射，依赖服务端英文文案。建议改用结构化错误类型。 |
| E7 | 低 | `cloud_sync_page.dart:300-308`/`app.dart:216-222` | 定时备份成败都写 `backup_auto_last_date`（"当日不重试"），当天唯一一次失败则用户误以为已备份。建议失败不写该标记（或写失败态）以允许重试。 |
| E8 | 低 | `member_stats_page.dart:221` | `stat.userId.substring(0,6)` 在 userId 为空/长度<6 时抛 `RangeError`。建议 `userId.length>=6 ? substring(0,6) : userId`。 |
| E9 | 低 | `transactions_sync_manager.dart:139-161` | `_reinitializeForEncryption` 清空 `_statusCache/_recentLocalChangeAt/_recentUpload` 但漏清 `_pendingAttachmentJobs`、`_discoveredPayloads` → 旧加密态任务/明文缓存泄漏到新状态。建议一并 clear。 |
| E10 | 低 | `sync_engine_realtime.dart:341-359` | `_refreshAllSharedResourcesAfterReconnect` 的 `Future.wait` 在 dispose 后仍在写库/发请求（轻微泄漏）。建议用可取消令牌或检查 `_disposed` 标志。 |

### 4.8 性能 / 资源泄漏
| # | 严重度 | 位置 | 问题 / 影响 / 建议 |
|---|---|---|---|
| P1 | 中 | `sync_engine_status.dart:35-96` | `checkSyncHealth` 多处 `(await (db.select(...).get())).length` 全表物化只为取 count → 大账本下拉刷新时内存/IO 陡增甚至 OOM 风险。建议用 Drift `selectOnly`/`count()` 在 SQL 层计数。 |
| P2 | 中 | `change_tracker.dart:232-237` / `sync_providers.dart:47-50` | `getUnpushedCount()` 执行 `db.select(db.localChanges).get()` 再取 `.length`，`unpushedChangeCountProvider` 每次刷新走全表 → 长期使用 local_changes 数千~数万行时每次全表加载。建议 `SELECT COUNT(*) WHERE pushed_at IS NULL`。 |
| P3 | 中 | `sync_engine_serialization.dart:545-566` | `_pushAllEntities` 内对每笔交易 `categories.cast<Category?>().firstWhere(...)` 线性扫描，整体 O(T×C)；3 万笔×数百分类=千万级比较，主线程明显卡顿。建议构造 `Map<int,Category>`/`Map<int,Account>` 索引 O(1) 查找。 |
| P4 | 中 | `sync_engine.dart:290-293` | `getStatus` 为计数 `.get()` 物化全部交易行只取 `.length`。建议 COUNT 查询。 |
| P5 | 中 | `sync_engine.dart:166, 1385-1387` | `markResolved` 在循环里逐条 await（每页每 change 一次 UPDATE，500 条=500 次串行）；`pendingRecurringBindings` 永不清理可能无限增长。建议批量 `UPDATE ... WHERE change_id IN (...)`；给 pending 加 TTL/上限。 |
| P6 | 低 | `startup_sync_overlay.dart:79-83` | `_setState` 同时 `notifyListeners()` 和 `markNeedsBuild()`，同一状态变更触发两次构建。建议二选一。 |
| P7 | 低 | `cloud_backup_service.dart:107-170` | `createBackup` 全量内存组装 ZIP（整库 JSON+附件二进制）再整体编码上传，无流式/分块 → 大账本内存峰值高、低端机 OOM 风险。建议分块上传/边压边传。 |
| P8 | 低 | `sync_engine_apply.dart:254-263` | 更新交易时 `nativeAmount` 缺键对每个被更新交易再 `SELECT` 一次旧行（一页 500 次 update=500 次额外 SELECT）。建议 `_TxCacheEntry` 预存所需字段。 |
| P9 | 低 | `sync_engine_serialization.dart:233-252` | `_serializeEntityForPush` 的 `'category'` 分支内 `File.readAsBytes`+`provider.uploadCategoryIcon` 把**网络上传塞进"序列化"纯函数**，带来延迟/异常面/重复上传。建议图标上传前置为独立阶段。 |
| P10 | 低 | `sync_engine_attachments.dart:219-245` | `drainCustomIconQueue` 在 dispose 后可能继续写盘/写库（轻微）。建议 drain 前/循环内检查 disposed。 |
| P11 | 低 | `transactions_sync_manager.dart:397-412,963` | `getStatus` 每次除 `exportTransactionsJson` 外还额外 `SELECT MAX(happenedAt)`，可合并进 export 统计。 |
| P12 | 低 | `transactions_sync_manager.dart:1802-1858` | `discoverRemoteLedgers` 对每个候选账本完整下载+解密+解析只为取 meta，未优先用 `getMetadata`。建议先 metadata 后回退。 |
| P13 | 低 | `sync_engine.dart:166`（pendingRecurringBindings） | 见 P5 第二项。 |
| P14 | 低 | `cloud_backup_providers.dart:12-22` / `cloud_backup_service.dart:69` | `cloudBackupServiceProvider` 每次重建返回新实例，`_busy` 互斥随实例存在；配置切换瞬间理论上可并发两个备份。建议 module/family 级单例缓存。 |

---

## 五、已确认健康的设计点（给予信心）

- **push/pull/fullPush/fullPull 单飞**：per-ledger 单飞与 user-global 全局单飞设计正确，有效防止并发重复推送（`sync_engine.dart:963-984,1171-1212,353-373,1487-1510`）。
- **cursor 推进时机**：仅整页 apply 成功后 `appCursor.commit`，`blocked` 时不提交，保证"失败不丢 cursor"——方向正确，仅缺单条毒化隔离（见 S1）。
- **附件/图标下载移出事务**：事务内只 enqueue，commit 后 fire-and-forget 下载，避免网络抖动卡死事务。
- **`_AttachmentSemaphore` 并发限流**：单线程模型下无竞态，随调用结束 GC，无泄漏。
- **`withRecordingSuppressed` 嵌套恢复**：用 `previous` 保存/恢复，支持嵌套且异常安全。
- **dispose 资源回收**：`stopListeningRealtime` 取消定时器并关闭 `_eventsController`，定时器无泄漏。
- **指纹稳定性**：`contentFingerprintFromMap` 对 items/accounts/各类实体做稳定排序+哈希，跨设备可比。
- **序列化往返保真**：金额用 double、时间统一 UTC 导出/local 导入、null 条件键，往返对称。
- **启动检查错误隔离**：单账本 getStatus 失败计入 `failedLedgers`，不误报"已是最新"。
- **账户去重事务与幂等骨架**：整体包在 `db.transaction` 内，任一步失败整体回滚，重跑可自愈。
- **共享账本成员权限门禁**：移除他人仅 owner 且非自己、退出仅自己可触发，客户端门禁合理（服务端应再做最终校验）。

---

## 六、优先级修复路线图

**P0（立即修复，影响数据正确性或导致卡死）：**
1. S1 单条毒化 change 永久阻塞 cursor（加单条隔离）
2. S2 解密失败 change 静默丢数据（归入 pullErrors + 提示/停推 cursor）
3. S6 budget/recurring 跳过却计为 applied 导致永久丢失（不计数/不推进 cursor）
4. S3 备份按名恢复可能交易翻倍（确认 import 幂等或改覆盖）
5. S4 `onConfigChanged` 全局闭包泄漏（dispose 置 null）

**P1（高优先，一致性/状态失真）：**
- S5 diff 忽略无 syncId 本地交易
- S7 设备页 deviceId 缺失可吊销自身
- L1 `pushed` 计数错误导致状态不刷新；L2 纯 pull 不 emit 事件
- D1 删除 category/account 不清理引用（FK 阻塞风险，联动 S1）
- U1 `_statusCache.remove(null)` 陈旧状态；U2 级联重算卡顿
- B/N 类：N1 跨账本 pull 互取消、N2 WS 断后不重订阅、N4 测试连接无超时

**P2（中优先，性能与健壮性）：**
- P1–P5 各类 `.get().length` 全表计数、O(T×C) 序列化、逐条 markResolved
- T1 `forceRefresh` 缓存未命中强制全量下载
- C1 冲突解析死代码/无字段级合并
- 多实例单飞击穿（见下）、D4 去重引用覆盖不全

**P3（低优先，建议与清理）：**
- 死代码（C1 `SyncConflictResolver`、`member_list_page._confirmTransfer` stub）
- 字符串匹配异常文本（E4/E6/C3）
- 各类类型兜底（D11/D12）、去抖（E3/U3/P6）、资源生命周期（P10）

> 附：跨 Agent 交叉确认项——`sync_engine.dart` 的实例级单飞（`_pushInFlight` 等）与仅有 `_syncLedgersInFlight` 为 static 的不对称（Agent B #15）：当存在多个 engine 实例时并发 push 不再互斥，可能向 server 重复写入导致 2–4× 膨胀。建议将全局共享锁也改为 static/进程级单例。

---

*本报告仅基于静态代码审查，未执行运行期验证；部分中/低级问题需结合运行期日志进一步确认触发概率。所有问题位置均指向当前（2026-08-17）源码，未对 `packages/flutter_cloud_sync*` 内部做任何评判。*
