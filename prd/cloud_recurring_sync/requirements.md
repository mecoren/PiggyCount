# Cloud 链路补周期交易同步需求（cloud_recurring_sync）

## 需求理解

`recurring_transactions` 在 PiggyCount Cloud 实体同步链路中完全缺失（sync_engine_apply 的 entityType 分发表无此类型，server 白名单亦未放开）。快照链路已由 sync_gap_closure PRD 覆盖，但 Cloud 用户（增量 + realtime + 共享账本生态）换设备/多设备时周期规则仍会丢失。本需求把 recurring 作为 ledger-scoped 实体接入 Cloud SyncEngine，模式对齐 budget（v22 已验证的路径）。

## 现状盘点（代码级）

| 接入点 | budget 的先例 | recurring 现状 |
|---|---|---|
| 变更登记 | CRUD 走 `recordLedgerChange(entityType: 'budget')` | `local_recurring_transaction_repository` CRUD 不登记任何 change |
| 序列化 | `serializeBudget` + `_serializeEntityForPush` case | 无 |
| 应用 | `_applyBudgetChange`（按 syncId upsert/delete） | 无 |
| realtime | 失效通知 | 无 |
| 状态统计 | `sync_engine_status` 计数 | 无 |
| server | entity_type 白名单 + projection + WS 事件 | 均无（**独立服务端仓库，需协同**） |
| syncId | v22 迁移加列回填 | 由 sync_gap_closure 的 v33 迁移提供（**前置依赖**） |

另发现两处隐性写路径必须一并登记，否则同步不完整：

- `local_repository.dart:1622`（生成交易后更新 lastGeneratedDate 等）；
- `account_dedup_service.dart:121-124`（账户去重重映射 recurring 的 accountId/toAccountId）——漏登则去重结果不传播，其他设备引用旧账户。

交易与规则的关联：Cloud 链路 transaction payload（`entity_serializer.dart`）**不含 recurring 关联字段**，即使规则同步了，另一台设备上交易的 `recurringId` 也是断的。

## 需求范围

### R1 实体接入（客户端）
- recurring 作为 ledger-scoped 实体：序列化（syncId/type/amount/frequency/interval/dayOfMonth/dayOfWeek/monthOfYear/startDate/endDate/enabled/lastGeneratedDate + categorySyncId/accountSyncId/toAccountSyncId 字符串引用）、push、apply（upsert/delete 按 syncId，int 外键按 syncId 反查本地 id，未命中置 null + warning）、realtime 失效、状态计数。
- 全部写路径登记 changeTracker：repo CRUD、生成器更新 lastGeneratedDate、账户去重重映射。

### R2 交易关联修复
- transaction payload 增加 `recurringSyncId`（可空）；apply 端解析为本地 recurringId 回填。
- 与快照链路 sync_gap_closure 的 `recurringSyncId` 字段语义一致（同名同义）。

### R3 旧服务器兼容（D10 模式）
- recurring change 独立批推送（对齐 exchange_rate_override：旧 server 拒绝未知 entity_type，混批会阻塞主批；独立批失败仅 warning 不标已推，留待重试）。

### R4 服务端（协同项，独立仓库）
- entity_type 白名单放开 `recurring`；`upsert_recurring` / `delete_recurring` projection；WS 变更事件广播。
- LWW 语义与 budget 一致：server 按 (ledger_id, entity_sync_id) 以 updated_at 最后写入胜出。

## 非目标

- 共享账本内 recurring 的成员权限语义（Editor 能否建规则等）——本期随既有 transaction 权限模型，不单独设权。
- 快照链路的 recurring（已由 sync_gap_closure 覆盖）。
- 周期规则"生成出的交易"的幂等去重强化——沿用 lastGeneratedDate 进度 + 交易 syncId 去重既有机制。

## 验收标准

- dev1（Cloud 模式）创建/修改/删除周期规则，dev2 秒级收到 realtime 失效并拉取一致；断网期间的操作重连后收敛。
- dev2 上生成器跑一轮后，dev1 拉到的规则 lastGeneratedDate 更新，且不会重放生成交易。
- 新生成的交易在另一台设备上点击可跳转/展示其周期规则来源（recurringId 关联不断）。
- 账户去重后，另一台设备上规则的账户引用同步切换。
- 未升级 server 的环境：recurring 批推送失败仅 warning，account/category/tag/transaction 主批不受影响（D10 回归验证）。
- `flutter analyze` 无新增告警；sync_engine 相关单测通过。
