# 账户去重收敛需求（account_dedup）

## 需求理解

资产管理金额已对齐但账户数量不一致：dev2 (16384) 有 35 个账户，dev1 (16416) 只有 6 个。原因是 dev2 残留旧版"每账本一套默认账户"的历史数据（现金×11、支付宝×11、储蓄卡×10，挂在账本 2~12，随机 syncId），且每个重复账户挂着 97~4430 笔真实交易（合计约 8000+ 笔）。需要在启动时自动将这些重复账户合并收敛为全局账户，使所有设备、云端快照的账户集合一致。

## 实测证据（2026-08-15 拉库对比）

- dev1：6 账户全部 `ledger_id=0`，交易全部引用全局账户（干净模型）
- dev2：35 账户中仅 1 个（"11"）是全局，其余挂在账本 2~12；账本 2 为共享账本（owner）
- `transactions.account_id` / `to_account_id` 无外键约束，`deleteAccount` 是裸删除 → 手动删除会造成 8000+ 笔交易引用悬空
- `recurring_transactions` 同样有 `account_id` / `to_account_id` 引用
- 快照格式账户即全局扁平（导出不含 ledger_id、导入硬编码 `ledgerId: 0`），个人资产统计按"共享账本交易"排除（`_kExcludeJoinedSharedLedgerSql`）而非按账户 scope → "全部收敛为全局账户"与现有数据模型一致

## 需求范围

- R1：启动时（main.dart 引导阶段，runApp 前）自动检测并合并同名重复账户
  - 同名组内保留一个 keeper：优先 `ledger_id=0` → 其次 syncId 非空且 id 最小 → 否则 id 最小
  - 把重复账户的 `transactions.account_id` / `to_account_id`、`recurring_transactions.account_id` / `to_account_id` 重定向到 keeper
  - 删除重复账户行，keeper 的 `ledger_id` 置 0（全局化）
  - 整个合并在一个数据库事务内完成；无重复时快速路径直接返回（每次启动都可安全重跑，可收敛"恢复旧快照再次引入重复"的场景）
- R2：合并后用户在 dev2 执行"全部上传"，dev1 执行"全部恢复"，验证两台设备账户集合按 syncId 对齐

## 验收标准

- dev2 启动一次后账户数 35 → 6，且每组同名仅剩一行、`ledger_id=0`
- 各账本交易笔数合并前后不变；无 `account_id` 悬空引用（孤儿交易数 = 0）
- dev2 全部上传 → dev1 全部恢复后，两台设备账户数、syncId 集合一致，资产管理金额一致
- `flutter analyze` 无新增告警

## 不在本次范围

- `account_sync_id_override` 等共享账本冲突解析覆写列的改写（属解析缓存，验证阶段确认是否受影响）
- 周期交易/预算纳入快照同步（前需求 R2a/R2b，用户未确认）
