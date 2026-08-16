# 账户同步修复需求（account_sync_fix）

## 需求理解

用户反馈「资产管理里的账户同步没有全部同步」，并要求排查两台设备（127.0.0.1:16416 / 127.0.0.1:16384，均 WebDAV 快照同步）之间所有数据的一致性问题，修复同步缺口。

## 实测数据对比结论（2026-08-14，两台设备均配置 WebDAV + auto_sync）

| 实体 | dev1 (16416) | dev2 (16384) | 结论 |
|---|---|---|---|
| 账户 | 6 个（全部 ledger_id=0） | 35 个（账本2~12 各带一套 现金/储蓄卡/支付宝，随机 syncId） | **严重不一致** |
| 同名账户 "11" | syncId=8f4bd5fb... | syncId=e14aaa7e... | 同名不同身份 |
| 支付宝（syncId=ecddd10e 相同） | 余额 0 / sortOrder=2 | 余额 3200 / sortOrder=0 | **同身份数据分叉** |
| 账本 | 3 个 | 12 个 | 9 个账本从未上传云端 |
| 账本 2/3 的 syncId | "2"/"3"（int id 兜底） | 正常 UUID | 历史遗留 |
| 标签 | 14 个 | 18 个（餐饮/交通/购物/旅行 各多 1 个随机 syncId 重复项） | 重复 |
| 预算 budgets | 0 | 45 | **完全不同步** |
| 周期交易 recurring | - | - | **完全不同步**（无 syncId 列，快照也不含） |
| 交易（账本1/2/3） | 8348/1140/1000 | 8348/1140/1000 | 一致 ✓ |
| 分类 | 79，syncId 集合一致 | 79 | 一致 ✓ |

## 根因（代码级）

- **G1 导出缺口**：`exportTransactionsJson` 只导出「被交易引用的账户」，未被任何交易引用的账户永远不上云 → 资产管理里新增的空账户、删除交易后的账户在另一台设备不存在。
- **G2 导入去重策略弱**：`importAccounts` 仅按 name 去重；同名不同 syncId 会被并成一条（身份错乱），同 syncId 不同名不会并（重复）。标签已是「syncId 优先、name 兜底」策略，账户未对齐。
- **G3 账本发现**：云端文件按 `ledger_<本地intId>.json` 命名；dev2 的账本 4-12 从未上传（无入口），dev1 因此看不到。本期已补「全部上传/单个上传」入口；文件名按 intId 的跨设备错位风险记录为遗留风险，不在本期改。
- **G4 实体覆盖缺口**：快照格式（version 7）不含 budgets / recurring_transactions；两台设备预算 0 vs 45。
- **G5 Path B 变更登记缺口**：`updateAccountSortOrders` / `updateAccountValuation` 不写 changeTracker（代码注释表明是刻意设计：排序/估值/隐藏状态本地化），piggycount_cloud 用户这些字段不同步。是否改变该设计需用户决策。

## 本期需求范围

### R1（核心，用户主诉）
- 快照导出包含**全部账户**（账户是 user-global 实体，与账本解耦）。
- 账户导入去重改为「syncId 优先匹配 → name 兜底匹配；name 命中且本地 syncId 为空时回填 syncId」，对齐标签既有策略。

### R2（待用户确认是否纳入本期）
- 预算 budgets 纳入快照导出/导入（格式 version 8）。
- 周期交易 recurring 纳入快照导出/导入（需评估：周期交易含本地 int 外键 category_id/account_id，需按 name/syncId 映射重建）。
- Path B 的 sortOrder/估值变更登记 changeTracker（改变既有「刻意不同步」设计）。

### 验收标准
- dev2 执行「全部上传」→ dev1「全部恢复」后：两台设备账户集合按 syncId 对齐，数量一致；未被交易引用的账户也出现。
- flutter analyze 无新增告警；gen-l10n 通过。
