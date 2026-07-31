# 首页性能与同步一致性修复 — 设计文档

## 一、需求理解

修复首页删除最后一笔交易后残留旧记录（P1）、大账本全量物化卡顿（P2），并清理扫描出的同步一致性与 N+1 问题。核心约束：遵循 systematic-debugging（根因已查明）与 TDD（先 RED 测试再改代码）；不引入 keyset 分页等大改动，先用索引 + 基准验证。

## 二、关键技术决策

### 决策 1：A 组 — 用 `snapshot.hasData` 区分"空"与"未加载"

**选择**：将 `hasStreamData = streamData != null && streamData.isNotEmpty` 改为 `hasStreamData = snapshot.hasData`。

**理由**：
- `snapshot.data != null` 在 Drift stream 首次 emit `[]` 时也会为真，但语义上 `hasData` 更明确表达"流已返回过数据"。
- 保留 `cachedFullData` 作为 `!hasStreamData` 时的预加载兜底，避免首屏闪白。
- 不改动 `_txStream` 复用逻辑（line 1029-1038），避免引入新的重建问题。

**配套**：E 组 AC-E1 移除 `Future.microtask`，改为 build 内同步 `ref.read(cachedTransactionsProvider.notifier).state = null`。Riverpod 允许在 build 中通过 `ref.read` 同步写 state，且 `_streamBuilderKey++` 已强制 StreamBuilder 重建，同步清缓存让本帧就拿到 null，消除 race window。

### 决策 2：B 组 — v32 迁移加复合索引，基准测试用 EXPLAIN 验证

**选择**：v32 迁移仅加 `idx_transactions_ledger_happened ON transactions(ledger_id, happened_at)`。

**理由**：
- 该复合索引覆盖最高频查询模式 `WHERE ledger_id = ? AND happened_at >= ? AND happened_at < ? ORDER BY happened_at DESC`。SQLite 复合索引前缀匹配 + 索引天然有序，可同时加速 filter 与 orderBy。
- 不加 `account_id` / `category_id` 单列索引到 v32（移至 F 组可选），避免单次迁移膨胀；本期聚焦用户报告的月度查询卡顿。
- 基准测试用 `db.customSelect('EXPLAIN QUERY PLAN ...')` 断言计划含 `USING INDEX idx_transactions_ledger_happened`，而非仅断言耗时（耗时受 CI 环境波动大）。

**keyset 分页**：本期不做。基准测试会记录 10k 条月度查询耗时作为基线，若 > 50ms 再开后续任务。

### 决策 3：C 组 — 三处删除路径补 `transaction_tag_overrides` 级联

**选择**：在三处删除路径补一行 `delete(transactionTagOverrides)..where(transactionSyncId.isIn/equals(syncIds))`。

**关键点**：
- `transaction_tag_overrides` 主键是 `(transactionSyncId, tagSyncId)`，是 **text syncId**，不是 int id。因此必须先拿到 tx 的 syncId 再删。
- 单条路径 `deleteTransaction(id)` 当前只接收 int id，需先 `select` 拿 syncId 再删 overrides，或改为在调用方 `deleteTransactionBySyncId` 处补删。权衡：在 `deleteTransaction` 内部补一次 `SELECT sync_id` 查询最稳妥（保证所有调用路径都覆盖），增加 1 次轻量 SELECT 可接受。
- 批量路径 `deleteTransactionsBatchBySyncIds` 已有 `syncIds` 入参，直接 `isIn(syncIds)` 删，零额外查询。
- sync_engine_apply delete 路径已有 `syncId`（`change.entitySyncId`），直接 `equals(syncId)` 删。

### 决策 4：D 组 — 照抄 `getTransactionsByDate` 批量模式重写 `getTransactionsByDateRange`

**选择**：将 `getTransactionsByDateRange` 的 for 循环 N+1 改为：
1. 一次 `select(transaction_tags).where(transactionId.isIn(txIds))` 拿所有 tagRelations
2. 一次 `select(tags).where(id.isIn(tagIds))` 拿所有 tags
3. 一次 `select(transaction_attachments).where(transactionId.isIn(txIds))`
4. 一次 `select(accounts).where(id.isIn(accountIds))`
5. 一次 `select(categories).where(id.isIn(categoryIds))`（同时修 `getTransactionsByDate` 的 category N+1）

**理由**：与 `getTransactionsByDate`（lines 1040-1100）已验证的批量模式完全一致，降低风险。返回结构（tuple 字段顺序、tags 列表、attachments 列表）保持不变。

**`_deleteAttachmentsForTransaction`**：改为一次 `select(transaction_attachments).where(fileName.isIn(fileNames)).get()`，结果按 fileName 分组计数，>1 的跳过删除。

### 决策 5：E 组 — 导入强制生成 syncId + autoDispose

- E3：`DataImportService.importTransactions` 在构造 `TransactionsCompanion` 时，若 `syncId` 为 absent/null，用 `Uuid().v4()` 填充（与 `LocalTransactionRepository.insertTransactionCompanion:651-653` 一致）。
- E2：`lastCountsAllProvider` / `lastMonthlyTotalsProvider` 加 `.autoDispose`。family provider 自动按 (ledgerId, month) 回收。

### 决策 6：测试策略（TDD）

每组先写 RED 测试：
- A：widget test，mock stream emit []，断言空状态。
- B：migration test（断言索引存在）+ benchmark test（EXPLAIN 含 USING INDEX）。
- C：repository test，插 override → 删 tx → 断言 overrides 表清空。
- D：用 Drift `logStatements` 包装 db，断言 `getTransactionsByDateRange` 的 SELECT 次数不随 tx 数量增长（如 10 条 vs 50 条 SELECT 次数相同）。

## 三、实现步骤（≤5 步）

1. **测试先行**：新建 4 个测试文件（A 空列表、B 迁移+基准、C 级联、D N+1），运行确认全部 RED。
2. **A+E1 修复**：改 `home_page.dart` 的 `hasStreamData` 判断 + 移除 microtask；跑 A 测试转 GREEN。
3. **C+D 修复**：改 `local_transaction_repository.dart`（3 处级联 + 2 处 N+1 重写）+ `sync_engine_apply.dart`（1 处级联）；跑 C/D 测试转 GREEN。
4. **B 修复**：db.dart 加 v32 迁移 + `schemaVersion = 32`；跑迁移测试 + 基准测试转 GREEN。
5. **E2/E3 + F 清理**：autoDispose + 导入强制 syncId + 死代码删除；跑全量测试 `flutter test` 确认无回归。

## 四、边界条件与潜在风险

1. **v32 迁移回滚**：索引创建用 `CREATE INDEX IF NOT EXISTS`，幂等；若中途失败 SQLite 事务保护，无数据损坏风险。旧版本用户升级路径 `from < 32` 安全。
2. **`deleteTransaction` 多一次 SELECT**：在 `db.transaction` 外调用时会增加 1 次查询；批量删除路径不受影响（已有 syncIds）。可接受。
3. **autoDispose 行为变化**：`lastMonthlyTotalsProvider` 加 autoDispose 后，若 UI 在 build 中 `ref.watch` 仍会保持订阅；只有真正无监听者时才回收。需验证首页/统计页不丢失缓存语义。
4. **DataImportService 强制 syncId**：已存在的导入数据（历史 null-syncId）仍需 `sync_diff_service` 的兜底匹配；本期不补 diff 层匹配，仅堵新增入口。AC-E4 测试用新导入路径验证不重复。
5. **基准测试环境差异**：CI 与本地耗时绝对值不可比，故用 `EXPLAIN QUERY PLAN` 断言索引命中，耗时仅打印不断言。
6. **不触碰 transaction_list 全量分组**：`_buildFlatItems` 的全量内存分组本期不动（用户明确要求"仍有卡顿时再做 keyset/窗口化"），索引会让 DB 查询变快，hydration 与分组在 10k 量级可接受。

## 五、影响面

| 文件 | 改动类型 |
|------|---------|
| `lib/pages/main/home_page.dart` | A 组判断修正 + E1 microtask 移除 |
| `lib/data/db.dart` | B 组 v32 迁移 + schemaVersion |
| `lib/data/repositories/local/local_transaction_repository.dart` | C 组 3 处级联 + D 组 N+1 重写 |
| `lib/cloud/sync/sync_engine_apply.dart` | C 组 1 处级联 |
| `lib/providers/statistics_providers.dart` | E2 autoDispose |
| `lib/services/data_import_service.dart` | E3 强制 syncId |
| `lib/providers/ui_state_providers.dart` | F 组删死代码（可选） |
| `test/` 新增 4 个测试文件 | A/B/C/D 各一 |
