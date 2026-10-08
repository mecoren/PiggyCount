# 首页性能与同步一致性修复 — 需求文档

## 一、需求理解

用户报告两个问题：（P1）删除账本最后一笔交易后首页仍显示旧记录；（P2）每次交易变更都会重新物化整个账本，且数据库缺复合索引导致大账本卡顿。用户同时要求排查项目中其他同步与功能性问题并一并处理。

经全量扫描，共发现 **14 处问题**，按严重程度分组如下。本需求文档定义每组的验收标准。

## 二、问题清单与验收标准

### A 组 — P1 首页空列表回退缓存（用户原始报告）

**问题**：[home_page.dart:1042-1043](../../lib/pages/main/home_page.dart#L1042-L1043) 用 `streamData != null && streamData.isNotEmpty` 判断流是否返回。当 Drift stream 合法 emit `[]`（删除最后一笔后）时被当作"未加载"，回退到启动时缓存的 `cachedFullData`（不随单笔删除更新），导致旧记录残留。

**验收标准**：
- AC-A1：stream 已 emit 空列表时，首页显示空状态（`AppEmpty`），而非缓存旧数据。
- AC-A2：stream 尚未 emit（`snapshot.data == null`）时，仍使用 `cachedFullData` 预加载避免闪白。
- AC-A3：新增回归测试 `test/pages/main/home_empty_stream_test.dart`，覆盖"有缓存 + 流 emit []"场景，断言渲染空状态。

### B 组 — P2 全量物化 + 缺复合索引（用户原始报告）

**问题**：
1. [local_transaction_repository.dart:95](../../lib/data/repositories/local/local_transaction_repository.dart#L95) `watchTransactionsWithCategoryAll` 查询全部交易并 JOIN + 二次 hydration。
2. [transaction_list.dart:290](../../lib/widgets/biz/transaction_list.dart#L290) `_buildFlatItems` 每次 build 全量内存分组。
3. [db.dart](../../lib/data/db.dart) transactions 表只有 `idx_transactions_sync_id`，**无** `(ledger_id, happened_at)` 复合索引，月度/年度/日期范围查询全表扫描。

**验收标准**：
- AC-B1：v32 迁移新增 `idx_transactions_ledger_happened ON transactions(ledger_id, happened_at)` 复合索引。
- AC-B2：新增迁移测试 `test/data/migration_v32_test.dart`，断言索引存在。
- AC-B3：新增基准测试 `test/data/repositories/local/transaction_query_benchmark_test.dart`，用 10,000 条数据测量月度查询耗时，并断言索引命中（`EXPLAIN QUERY PLAN` 含 `USING INDEX`）。
- AC-B4：keyset 分页 / 窗口化订阅 **本期不实现**（用户明确要求"仍有卡顿时再做"），仅在基准测试仍不达标时记录为后续任务。

### C 组 — P1 同步：删除交易漏删 transaction_tag_overrides（新发现）

**问题**：`TransactionTagOverrides` 表用 `transactionSyncId`（text）作主键。三处删除路径只按 int id 删 `transactionTags` + `transactionAttachments` + 主表，**漏删 `transaction_tag_overrides`**，留下孤儿行，导致共享账本 Editor 视角 `_hydrateSharedOverridesFull` LEFT JOIN 挂载幽灵标签。

涉及文件：
1. [local_transaction_repository.dart:576-587](../../lib/data/repositories/local/local_transaction_repository.dart#L576-L587) `deleteTransaction`（单条，被 `deleteTransactionBySyncId` 复用）
2. [local_transaction_repository.dart:1481-1507](../../lib/data/repositories/local/local_transaction_repository.dart#L1481-L1507) `deleteTransactionsBatchBySyncIds`（批量）
3. `sync_engine_apply.dart:73-81` `_applyTransactionChange` delete 路径（远端推送）

**验收标准**：
- AC-C1：三处删除路径均清理 `transaction_tag_overrides`（按 `transactionSyncId` 删除）。
- AC-C2：新增测试 `test/repositories/delete_tx_overrides_cascade_test.dart`：插入带 override 的 tx → 删除 → 断言 overrides 表无残留。
- AC-C3：sync_engine_apply 删除路径同步覆盖，新增/复用 e2e 测试用例。

### D 组 — P1/P2 Repository N+1 查询（新发现）

**问题**：
1. [local_transaction_repository.dart:1322-1365](../../lib/data/repositories/local/local_transaction_repository.dart#L1322-L1365) `getTransactionsByDateRange` 教科书级 N+1：每条 tx 4 次 SELECT，tag 查询嵌套 N×M。100 条 → 500 次 SELECT。
2. [local_transaction_repository.dart:1043-1053](../../lib/data/repositories/local/local_transaction_repository.dart#L1043-L1053) `getTransactionsByDate` 的 category 仍逐条 SELECT（tags/attachments/accounts 已批量化）。
3. [local_transaction_repository.dart:613-617](../../lib/data/repositories/local/local_transaction_repository.dart#L613-L617) `_deleteAttachmentsForTransaction` 文件引用计数逐个查。

**验收标准**：
- AC-D1：`getTransactionsByDateRange` 重写为批量查询（照抄 `getTransactionsByDate` 模式），返回结果顺序与字段不变。
- AC-D2：`getTransactionsByDate` 的 category 查询批量化。
- AC-D3：`_deleteAttachmentsForTransaction` 引用计数一次 `isIn` 查询。
- AC-D4：现有 `local_transaction_repository_test.dart` 全部通过；新增 N+1 回归测试断言查询次数不随 tx 数量线性增长（用 Drift `logStatements` 计数）。

### E 组 — P2 状态管理 / 缓存陈旧（新发现）

**问题**：
1. [home_page.dart:627-636](../../lib/pages/main/home_page.dart#L627-L636) 账本切换用 `Future.microtask` 异步清缓存，当前 build 已读到旧 cache，配合 A 组 bug 导致切换后第一帧显示旧账本数据。
2. [statistics_providers.dart:32,68](../../lib/providers/statistics_providers.dart#L32) `lastCountsAllProvider` / `lastMonthlyTotalsProvider`（family）非 autoDispose，永久驻留 + 切账本时短暂陈旧。
3. [sync_diff_service.dart:119-124](../../lib/cloud/sync_diff_service.dart#L119-L124) 本地 `syncId == null` 的交易（CSV 导入产生）不进 `localBySyncId`，云端推送同条 → 误判 added → 本地重复。
4. [local_repository.dart:1100,1139](../../lib/data/repositories/local/local_repository.dart#L1100) null-syncId 交易的 mutation 跳过 change log，永不触发 sync push。

**验收标准**：
- AC-E1：账本切换时同步清空 `cachedTransactionsProvider`（移除 microtask）。
- AC-E2：`lastCountsAllProvider` / `lastMonthlyTotalsProvider` 加 autoDispose。
- AC-E3：`DataImportService.importTransactions` 导入时强制生成 syncId（对齐 `insertTransactionCompanion`），消除 null-syncId 入库。
- AC-E4：新增测试：CSV 导入后开云同步，同条云端推送不产生重复。

### F 组 — P3 清理项（低优先，建议一并处理）

1. [main.dart:424](../../lib/main.dart#L424) `appLinks.uriLinkStream.listen` 返回的 subscription 未保存/cancel。
2. [ui_state_providers.dart:187](../../lib/providers/ui_state_providers.dart#L187) `cachedTransactionsWithCategoryProvider` 是死代码（无写入，仅一处 invalidate）。
3. `sync_engine_realtime.dart:394-448` `fetchAndStoreSharedResources` 逐条 insert，可改 batch。
4. db.dart 缺 `account_id` / `category_id` / `to_account_id` 单列索引（级联删除/统计用）。

**验收标准**：F 组为可选优化，不设硬性 AC；若实施需保证现有测试不回归。

## 三、本期范围决策点（需用户确认）

- **必做**：A、B（索引+基准，不含 keyset 分页）、C、D 组。
- **建议做**：E 组（E3/E4 涉及同步正确性，优先级实际可达 P2）。
- **可选**：F 组。

用户需确认是否纳入 E、F 组，以及 B 组是否需要"若基准不达标再做 keyset 分页"的兜底实现。
