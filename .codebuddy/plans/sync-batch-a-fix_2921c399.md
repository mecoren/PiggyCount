---
name: sync-batch-a-fix
overview: 修复 WebDAV/S3/iCloud/Supabase 备份同步路径（老 JSON + sync_diff_service）的缺失字段：#5 账户扩展字段、#6 交易 tagIds、#7 modified 路径 override 字段。recurringId 因依赖 RecurringTransactions 表同步（独立大改动）暂不纳入。
todos:
  - id: extend-data-models
    content: 扩展 ImportAccount/ImportTag/ImportTransaction 类和 TransactionUpdateBySyncIdData，添加缺失字段（账户扩展字段+syncId、标签 syncId+sortOrder、交易 tagSyncIds+override 字段）
    status: completed
  - id: update-json-export-import
    content: 更新 transactions_json.dart 导出和导入，补全账户扩展字段、标签 syncId、交易 tagIds 和 override 字段，version 升至 7
    status: completed
    dependencies:
      - extend-data-models
  - id: update-import-logic
    content: 更新 data_import_service.dart 的 importAccounts（传扩展字段+更新已存在）、importTags（设 syncId+返回 bySyncId 映射）、importTransactions（用 tagSyncIdToId 解析+设 override 字段）
    status: completed
    dependencies:
      - extend-data-models
  - id: update-batch-update-and-diff
    content: 更新 updateTransactionsBatchBySyncId 写入 override 字段，更新 sync_diff_service modified 路径传 override + 用 tagSyncIdToId 解析标签
    status: completed
    dependencies:
      - extend-data-models
      - update-import-logic
  - id: write-tests
    content: Use [skill:test-driven-development] 编写测试验证账户扩展字段、tagSyncIds、override 字段在导出→导入→diff apply 全链路不丢失
    status: completed
    dependencies:
      - update-json-export-import
      - update-import-logic
      - update-batch-update-and-diff
  - id: code-review
    content: Use [skill:requesting-code-review] 审查全部修改，确认向后兼容性、CSV 路径不受影响、字段一致性
    status: completed
    dependencies:
      - write-tests
---

## 用户需求

修复 WebDAV/S3/iCloud/Supabase 备份同步路径（老 JSON 路径）中缺失的数据字段，包含 3 个已确认问题：

### 问题 #5：老 JSON 账户字段缺失

- `transactions_json.dart` 导出账户只带 `name/type/currency/initialBalance`，缺少 `sortOrder/creditLimit/billingDay/paymentDueDay/bankName/cardLastFour/note/hidden/syncId`
- `ImportAccount` 类只有 4 个字段，`importAccounts` 方法创建时不传扩展字段、已存在时不更新
- 影响：信用卡账户的账单日/还款日/额度、备注、隐藏状态在备份恢复后全部丢失

### 问题 #6：老 JSON 交易 items 缺 tagIds

- `transactions_json.dart` 导出交易 items 时 tags 只用逗号分隔的名称串，没有 tagSyncIds
- `ImportTag` 类没有 `syncId` 字段，`importTags` 不设置 syncId
- 影响：同名 tag 跨设备 rename 后按 name 匹配会错挂

### 问题 #7：sync_diff_service modified 路径漏 override 字段

- `TransactionUpdateBySyncIdData` 没有 override 字段
- `sync_diff_service.dart` modified 路径构建 update 时未传 override
- `updateTransactionsBatchBySyncId` 未写入 override
- `transactions_json.dart` 导出/导入 items 时没有 override 字段
- 影响：共享账本 Editor 视角记的 tx，modified 同步后 override 丢失

### 兼容性约束

- 老 JSON 文件（version 6）无新字段 → 导入解析时全部 nullable，缺失走默认值
- 新 JSON 文件（version 7）带新字段 → 旧版 App 忽略未知字段
- `ImportAccount`/`ImportTransaction`/`ImportTag` 扩展字段全部 optional，不破坏 CSV 导入路径
- `TransactionUpdateBySyncIdData` 扩展字段 optional，唯一调用方是 `sync_diff_service`

## 技术栈

- Flutter + Dart（Drift ORM）
- 现有同步架构：老 JSON 全量快照路径（WebDAV/S3/iCloud/Supabase）+ 新 SyncEngine 增量路径（PiggyCountCloud）
- 本次修改仅涉及老 JSON 路径，不改动新 SyncEngine

## 实现方案

### 整体策略

扩展数据模型类 → 补全导出/导入序列化 → 更新导入逻辑 → 更新 batch update 和 diff apply。所有新增字段 optional，向后兼容老 JSON。

### 关键技术决策

1. **`importTags` 返回类型改为 record**：从 `Map<String, int>` 改为 `({Map<String, int> byName, Map<String, int> bySyncId})`，让调用方同时拿到 name→id 和 syncId→id 映射。只有 2 个调用方（`importData` 和 `sync_diff_service`），改动可控。

2. **`importAccounts` 增加 existing 账户更新**：当前只 create-if-not-exist，不 update。改为：已存在账户也用非 null 扩展字段调用 `updateAccount`。null 字段不传（保持本地原值），非 null 字段更新（含显式 0.0 和 false）。

3. **override 字段用 absent-when-null 模式**：`TransactionUpdateBySyncIdData` 的 override 字段为 null 时，`updateTransactionsBatchBySyncId` 走 `Value.absent()`（保留本地原值），与 `currencyCode`/`nativeAmount` 同模式。

4. **tag 解析优先 syncId 后 name**：`importTransactions` 和 `_resolveTagIds` 先按 `tagSyncIds` 查 `tagSyncIdToId`，miss 后 fallback 到 `tagNames` 查 `tagNameToId`。与新引擎 `_syncTransactionTags` 逻辑一致。

5. **JSON version 升至 7**：仅 `transactions_json.dart` 的 payload version 改为 7，新引擎 `_exportLedgerJson` 保持 version 6（两条路径独立，不影响）。

## 实现注意事项

- **性能**：`importAccounts` 的 existing 更新只在扩展字段非 null 时才调 `updateAccount`，避免无意义的 DB 写入。`importTransactions` 的 tag 解析先查内存 Map（O(1)），miss 才查 DB。
- **向后兼容**：`parseJsonToImportData` 对所有新字段用 `as T?` + `?? 默认值`，老 JSON 不含键时安全降级。
- **日志**：`importAccounts` 更新现有账户时打 debug 日志，与现有 `importTags` 的 updated 计数模式一致。
- **Blast radius**：`importTags` 返回类型变更是 breaking change，但仅 2 个调用方，均在本批次修改。`TransactionUpdateBySyncIdData` 唯一构造点是 `sync_diff_service`，也在本批次修改。

## Agent Extensions

### Skill

- **test-driven-development**
- Purpose: 为每个修复点编写测试用例，验证导出/导入/diff apply 的字段完整性
- Expected outcome: 账户扩展字段、tagSyncIds、override 字段在导出→导入→apply 全链路不丢失
- **requesting-code-review**
- Purpose: 完成全部修改后进行代码审查，验证向后兼容性和字段一致性
- Expected outcome: 确认所有新增字段 optional、老 JSON 兼容、CSV 路径不受影响