# 退款关联 + 报销状态（F1-b）— 需求文档

> 本文是 `transaction_model_completion`（F1）移交项「F1-b」的接手版。移交理由与该文件
> 第五节「接手清单」以本文为准；F1-a（软删除 / 回收站）已落地，不在本文范围。

## 一、背景

对标：钱迹把「退款 + 报销」作显性卖点；Firefly III #7697 明确指出**退款应回补预算**。
本仓现状（2026-10-12 核实）：`transactions` 表 21 列，无 `refund_of_id` / `reimburse_status`；
退款只是收入分类名（`seed_service.dart` 的 `reimbursement` / `refund` 分类 key）与默认标签
（`tag_seed_service.dart` 的 `tagDefaultReimbursement` 等），无任何关联建模。
`type == 'adjustment'` 是账户余额调整，**不是冲正**，没有链接字段，不要拿它当退款机制。

移交清单（`transaction_model_completion/design.md` §五）要求的两列：

- `refund_of_id`（自引用，nullable）：收入行指向它冲正的那笔支出行；
- `reimburse_status`（`none` / `pending` / `reimbursed`）：报销状态机。

## 二、需求范围

### R1 退款关联（refund_of_id）

- 收入交易可关联**同一账本内**的一笔支出交易（1:1；一笔支出被多笔退款冲正取最后一笔，
  不做部分退款的多次拆分——那需要 amount 级冲正台账，属独立立项）。
- 关联在交易编辑器中可选、可更换、可清除（三态，与 `originalAmount` 的 `d.Value` 语义一致）。
- 原交易被软删进回收站后：关联不断（归档行 PK 保留），**编辑回显**的摘要行改为
  「原交易已删除」提示（列表不做逐行存在性查询，零成本口径）；恢复原交易后关联
  自然复原。彻底 purge 原交易后关联字段**不清洗**（保留指向，回显按已删除处理），
  避免 purge 反过来要改别的行。

### R2 报销状态（reimburse_status）

- 三态：`none`（默认，不涉及报销）/ `pending`（待报销）/ `reimbursed`（已报销）。
- 入口在交易编辑器的「账单标记」面板扩展一项（与 `excludeFromStats` / `excludeFromBudget`
  并列），不新增顶层表单项——报销是标记属性，不是主流程字段。
- 列表 / 详情回显徽标（`待报销` / `已报销`），样式照 `txFlagExcludedTag` 徽标范式。

### R3 预算回补（口径写死）

- 分类预算 / 总预算的 `used` 计算中，把「`refund_of_id` 非空且 `type='income'`」的金额
  **按负值冲减**，且只冲减退款行**自身 `category_id`** 对应的分类。
- 跨月口径：原交易在 3 月、退款在 4 月 → 冲减发生在**退款发生月**的预算，不回改 3 月。
- 用户想把退款算到别的分类：记账时把退款行的分类选成目标分类即可（本文不 join 原交易
  分类，理由见 design.md 决策 3）。
- 统计侧**不**特殊处理：退款行作为普通收入进统计（想剔除的人自己用 `excludeFromStats`，
  该开关已存在于余额 / 统计 SQL，F1-b 复用不新增口径）。

### R4 云同步（两列必须进快照）

- `transactions_json.dart` 导出 / 导入新增 `refundOfId`（仅非 null 写键）、
  `reimburseStatus`（恒写，与 `excludeFromStats` 同款）。
- `kSnapshotFormatVersion` 13 → **14**，版本历史补一条。
- `sync_fingerprint.dart` 字段白名单加两键；`sync_diff_service.dart` 的 `_compareTx`
  加两字段**严格比较**（新字段无历史包袱，不用「缺键不改动」模式）。
- 升级重传门控（`shouldRepublishSnapshotForFormatUpgrade`）按既有语义自动收敛：
  旧端 v13 快照内容一致 → 一次性全量重传为 v14。**不**新增门控代码。
- 守门测试：`sync_contract_coverage_test.dart` 夹具表加两键（Tier 1 指纹变 + Tier 2
  diff 检出）；新建 `test/cloud/sync_contract_refund_test.dart` 做「检测得到 + 应用得
  下去 + 再 diff 为空」的成对断言（结构照 `sync_contract_custom_field_test.dart`）。

### R5 迁移与模型

- `schemaVersion` 55 → **56**：`transactions` 加两列 + `refund_of_id` 索引；
  `onCreate` 同步对齐；`test/data/migration_v56_test.dart`（直升 + 存量零回填断言，
  照 `migration_v55_test.dart` 范式）。
- Repository 三态语义：`addTransaction` 整行插入带两列；`updateTransaction` 两列按
  `d.Value` 三态（不改动 / 写 / 清空）；`TransactionUpdateBySyncIdData` 加两字段供
  云合并路径 `updateTransactionsBatchBySyncId` 应用。
- ChangeTracker：两列随 `addTransaction` / `updateTransaction` 既有记账点自动进
  `local_changes`，**不新增记账点**（写操作仍一律经 Repository）。

## 三、验收标准

1. `migration_v56_test.dart`：`onCreate` 与 `onUpgrade` 两条路都建列 + 建索引，存量行
   两列为默认值（`refund_of_id IS NULL`、`reimburse_status = 'none'`），迁移幂等可重入。
2. 同步守门：`sync_contract_coverage_test.dart` 两键夹具通过（含豁免理由 >12 字规则）；
   `sync_contract_refund_test.dart` 成对断言通过；旧快照（缺两键）导入不炸、按默认值落。
3. 预算回补：分类预算 / 总预算 SQL 测试钉住「关联退款按负值冲减、跨月按退款月、软删
   原交易不影响冲减、`excludeFromBudget` 与回补可叠加」。
4. UI：编辑器可选 / 改 / 清关联与报销状态，回显正确；列表徽标三态（`退款` /
   `待报销` / `已报销`），「原交易已删除」在编辑回显的摘要行提示
   （`test/widgets/refund_editor_ui_test.dart` 四例钉住）。
5. `flutter analyze`（`--fatal-infos`）0 issue + 全量 `flutter test` 绿。

## 四、明确不做

- **部分退款 / 多次冲正台账**（一笔支出被 N 笔退款分次冲）：需要金额级冲正余额模型，
  超出 1:1 自引用，独立立项。
- **报销的附件 / 审批流**：只做状态标记，不做企业报销工作流。
- **退款行进预算的 join 原交易分类口径**：见 design.md 决策 3（按退款行自身分类冲减）。
- 迁移回填历史数据：旧数据没有关联信息，`NULL` / `'none'` 即正确默认，不回填。
