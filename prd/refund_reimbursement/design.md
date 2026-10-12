# 退款关联 + 报销状态（F1-b）— 设计文档

需求见同目录 `requirements.md`。本文只记技术决策、代价与排雷点。
所有行号基于 2026-10-12 代码状态。

## 一、两列进 `transactions` 主表，不建关联表

退款对原交易是 1:1（部分退款明确不做，见 requirements 第四节），一张自引用列足够。
建 `transaction_refunds` 关联表是为「一对多 / 金额级冲正」预留的结构，本期用不上，
且要多过一遍同步契约（新实体段 = 新守门文件），成本翻倍。

| 决策 | 取舍 |
|---|---|
| `refund_of_id INTEGER` nullable，无 FK 约束（本库连接未开 FK，`grep foreign_keys` 零命中，F1-a 已证实） | 软删 / purge 不级联，语义在 UI 与查询侧兜底（见第四节） |
| `reimburse_status TEXT NOT NULL DEFAULT 'none'` | 三态字符串，不建 enum 表；值域在代码常量 + 迁移注释里钉死 |

列定义照 `toAccountId`（`lib/data/db.dart:265`，nullable integer 行内外键语义先例）
与 `recurringId`（268，nullable integer 可选锚点先例）；加列用 `_addColumnIfMissing`，
范式与 v54 一致。

## 二、同步契约改动面（v14）

按移交清单逐条落，行号为当前代码：

1. **导出**（`lib/cloud/transactions_json.dart:253-373` 的 items map）：
   - `refundOfId`：仅非 null 写键（照 `originalAmount` 314 / `recurringSyncId` 334-336 的
     条件写范式）——99% 的交易没有退款关联，恒写纯浪费。
   - `reimburseStatus`：**恒写**（照 `excludeFromStats` 301 / `excludeFromBudget` 302）——
     状态字段要「缺键 = 旧端没这个字段」与「明确 none」可区分，恒写最稳；diff 用严格
     比较（见下），缺键会被判差异从而触发一次修正，正是升级期想要的行为。
2. **导入**（`parseJsonToImportData` 交易段 1156-1250）：`_readInt(m,'refundOfId')` /
   `_readString(m,'reimburseStatus') ?? 'none'`。`_readX` 助手（706-719）类型不符返回
   null 不抛，旧快照缺键 → 默认值，**不跳过条目**。
3. **指纹白名单**（`lib/cloud/sync_fingerprint.dart:107-147` 的 items 段 return 块）：
   加 `refundOfId`（`?? 0`——注意 0 不是合法 id，与 null 区分开）、`reimburseStatus`
   （`?? ''`）。**必须落在这个 return 块里**，`sync_contract_coverage_test.dart` 的
   `deriveFingerprintKeys()`（40-67）是从该块派生键集合的，块外写不生效。
4. **diff**（`lib/cloud/sync_diff_service.dart` 的 `_compareTx` 701-895）：两字段走
   **策略 ① 严格比较**（`local != cloud`），与 `excludeFromStats`（835-838）同款。
   新字段没有旧快照缺键的历史包袱，不需要「缺键不改动」模式。
5. **格式版本**：`kSnapshotFormatVersion` 13 → 14（`transactions_json.dart:49`，版本
   历史注释 12-48 补一条）。旧端读到更高 version 不崩（白名单式忽略未知键），
   **升级门控自动收敛**：`shouldRepublishSnapshotForFormatUpgrade`
   （`transactions_sync_manager.dart:2668-2715`）三条件之「云端 version < 当前」满足、
   「按当前算法重算云端指纹 == 本地」由白名单式函数天然成立（忽略旧快照缺失键）→
   一次性 force 重传。**不新增门控代码**，但要在 PR 说明里写清「上线后首轮每本账本
   会提示一次 outOfSync 并自动重传」。
6. **守门测试**：`sync_contract_coverage_test.dart` 的 `cases` 表（158-307）加两键
   夹具（`_with()` 变体工厂 531-600，新参数必须 `= _unset` 默认值，否则 null 被当成
   显式清空造成伪差异、Tier 2 假通过——初版踩坑记录在 524-530）；新建
   `test/cloud/sync_contract_refund_test.dart` 做 P1-2 式成对断言（照
   `sync_contract_custom_field_test.dart` 的四条锁定结构）。

## 三、迁移（v56）与 Repository 三态

- 迁移块照 v54 加列范式（`lib/data/db.dart:1864-1876`）：`_addColumnIfMissing`
  （2076）+ 索引 SQL 常量置顶（照 v55 的 `createTransactionsLedgerCreatedIndexSql`，
  721）。索引建 `refund_of_id`——预算回补查询要按它过滤。
- `onCreate`（1908-2022）同步建列 + 建索引，与 v55 索引补建（2017-2022）并列追加。
- Repository：
  - `addTransaction`（`local_transaction_repository.dart:332-379`）：整行插入带两列。
  - `updateTransaction`（482-553）：`refundOfId` / `reimburseStatus` 按 `d.Value` 三态
    （照 `originalAmount` 511-520 / `accountId` 498-505），`reimburseStatus` 的
    `d.Value(null)` 语义 = 重置为 `'none'`。
  - `TransactionUpdateBySyncIdData`（`transaction_repository.dart:27-80`）：加两字段，
    云合并 `updateTransactionsBatchBySyncId`（1584+）应用时带上。
- ChangeTracker：两列随既有记账点（`local_repository.dart` 的 addTransaction 586-592 /
  updateTransaction 707-713 等）自动进 `local_changes`，**不新增记账点**——
  `change_tracking_gaps_test.dart` 的 C1-C4 缺口清单因此不变。

## 四、删除交互（与回收站的交叉）

- **软删原交易**：归档行进 `deleted_transactions`（PK 保留），`refund_of_id` 指向的
  id 暂时不在 `transactions`。此时原支出本身也不计预算用量了，退款若继续冲减会把
  用量做成负数（语义倒挂）——**预算回补 SQL 因此带 EXISTS 守卫**（被引原交易必须
  仍在 `transactions`），软删期间不冲减，**恢复归档行后关联与冲减自然复原**
  （id 不变，不需要改任何行）。彻底 purge / 合并时只勾了退款行（原交易本地不存在）
  同样落在守卫外，不冲减、不悬空。
- **purge 原交易**：`refund_of_id` 成悬空指向。刻意不清洗（requirements R1）——
  徽标继续显示「原交易已删除」，EXISTS 守卫保证它不参与任何冲减；清洗要跨表
  update，且 purge 与冲减语义纠缠（清洗了就不冲减，用户看不懂）。
- **删退款行自己**：走既有软删路径，无特殊逻辑。

## 五、预算回补 SQL（真正的改造点）

`local_budget_repository.dart` 两处（总预算 185-192 / 分类预算 203-214）当前口径
`type='expense' AND exclude_from_budget = 0`。改为对关联退款按负值冲减：

```sql
-- 概念口径（分类预算 used，行内别名以实际查询为准）
SUM(CASE WHEN type = 'expense' THEN amount ELSE 0 END)
  - COALESCE(SUM(CASE WHEN refund_of_id IS NOT NULL AND type = 'income'
                       THEN amount ELSE 0 END), 0)
```

- 只认**退款行自身 `category_id`**，不 join 原交易分类（决策 3）：join 会把「原交易
  在 A 分类、退款记在 B 分类」的歧义带进来，且跨月 join 让 SQL 从单表聚合变子查询，
  统计口径更难钉。用户控制权 = 记账时选对分类。
- 跨月按退款发生月冲减（requirements R3），单表聚合天然成立。
- `exclude_from_budget = 1` 的退款行**不参与冲减**（用户显式排除的不冲），
  与支出侧排除语义对称。
- 测试钉住：`test/data/repositories/` 或 `test/services/` 下新增
  `budget_refund_offset_test.dart`（分类 / 总预算 / 跨月 / 软删 / exclude 叠加）。

## 六、UI 落点（无现成范式，三处新建）

1. **关联选择器**：收入交易的编辑器（`transaction_editor_page.dart` 的
   `_persistTransaction` 961-1059 之前）加「关联原交易」入口——一个列出本账本
   **支出交易**的选择器（金额 + 分类 + 日期，倒序，带搜索）。选完回显一行
   「冲正：{日期} {分类} ¥{金额}」，右侧清除。复用现有选择器组件范式
   （`CategorySelector` / tag selector 的 bottom sheet 模式）。
2. **报销状态**：扩展 `_showFlagsDialog`（`amount_editor_sheet.dart:2196` 附近，
   账单标记面板）加第三项「报销状态」三选。回显走
   `TransactionEditUtils.editTransaction`（`lib/utils/transaction_edit_utils.dart:8-57`）。
3. **徽标**：`transaction_list_item.dart` 在 `txFlagExcludedTag` 徽标区追加
   `待报销` / `已报销` / `退款` / `退款·原交易已删除` 四种态（色系区分：
   报销用主色系、退款用信息色系，具体色值取 `PiggyTokens`，不新造）。

`recurringId` 在 UI 完全不展示的现状（grep 零命中）说明「行内关联列 + 徽标」
没有可抄范式，以上三处都是新建，但都是局部组件，不动保存主链路结构。

## 七、l10n

四个 arb 同步（`app_en.arb` 模板 + `app_zh.arb` / `app_zh_TW.arb` / `app_ko.arb`）。
新键分组 `refund*`（关联选择器 / 徽标 / 清除）与 `txFlag*`（`app_zh.arb:3279-3285`
报销状态项并入该组的对话框 / 徽标键）。占位符元数据照 `@txConvertedPreview`
（3291-3296）写法。

## 八、风险与排雷

| 风险 | 处置 |
|---|---|
| 上线首轮每本账本提示一次 outOfSync | 门控自动 force 重传后收敛；PR 说明写清，不做额外 UI |
| 旧端（v13）写入不含新键 → 本地回退丢失两列 | 与既有加字段先例（M2 / TSM-P3）同款，接受；这正是要升格式版本的原因 |
| 白名单键加了但漏 diff 字段（或反之） | coverage_test 的 Tier1/Tier2 双向夹具自动抓，漏一个就红 |
| `_with()` 工厂新参数忘加 `= _unset` | 照 524-530 踩坑记录，评审时专项核对 |
| 预算 SQL 改动波及既有统计 | 回补只在 `refund_of_id IS NOT NULL` 分支生效，存量数据全 NULL → 行为逐位不变；测试对既有预算用例全量回归 |
