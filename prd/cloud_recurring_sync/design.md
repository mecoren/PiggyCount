# Cloud 链路补周期交易同步设计（cloud_recurring_sync）

## 需求理解

把 `recurring_transactions` 作为 ledger-scoped 实体接入 PiggyCount Cloud SyncEngine（序列化/推送/应用/realtime/状态），补齐交易与规则的关联传播，并以独立批兼容未升级的旧服务器。前置依赖 sync_gap_closure 提供的 `recurring.syncId` 列（v33 迁移）；服务端白名单/projection/WS 需另一仓库协同。

## 关键技术决策

1. **完全复刻 budget 的接入形状**（v22 已验证的最小路径），不发明新机制：
   - ledger-scoped：`changeTracker.recordLedgerChange(entityType: 'recurring', ...)`（change_tracker 对 ledger-scoped 类型是通用断言，无需改白名单集合——只有 user-global 集合是封闭枚举）；
   - apply 按 `syncId` upsert/delete，形状对齐 `_applyBudgetChange`（sync_engine_apply.dart:657）；
   - payload 字段与 server `upsert_recurring` projection 一一对应（对齐 serializeBudget 与 server 端的契约注释惯例，entity_serializer.dart:102）。
2. **int 外键序列化为 syncId 字符串**：recurring 的 `categoryId/accountId/toAccountId` 在 payload 中输出 `categorySyncId/accountSyncId/toAccountSyncId`（反查 Categories/Accounts 的 syncId；为 null 时省略），apply 端反向解析为本地 int id，未命中置 null + warning（与交易缺分类的容错策略一致）。这与 transaction payload 的既有做法相同，server 不感知 int id。
3. **lastGeneratedDate 是普通 LWW 字段**（与快照链路"取 max"不同，这是刻意差异）：
   - Cloud 是 server 权威 LWW（按 updated_at），进度字段随规则行整体最后写入胜出即可，客户端不需要自定义合并；
   - 生成器每次生成交易都会 update 规则行（lastGeneratedDate 前移）→ 顺势登记 update change 推送，其他设备拿到新进度后不会重放生成。低频（每规则每天至多一次），无流量顾虑；
   - apply 路径**不回记 changeTracker**（pull → record → push 回环是既有明确禁区，sync_engine_attachments.dart:303 注释同款约束）。
4. **独立批推送（D10 模式）**：`pushUserGlobalEntities` 之外的 ledger 批组装处（sync_engine.dart:957 附近的 ledger-scope 推送）将 recurring change 拆独立批：失败只 warning、不 markPushed，留在 local_changes 重试。旧 server 拒绝未知 entity_type 时主批（transaction/budget/ledger）不受阻塞。
5. **交易关联字段 `recurringSyncId`**：`entity_serializer.serializeTransaction` 增加可空字段（tx.recurringId 反查 recurring.syncId）；`_applyTransactionChange` 解析时若本地规则未拉到（时序：change 流里 transaction 先于 recurring 到达），**延迟绑定**——暂存 pending 映射，`_applyRecurringChange` 落地时回扫补齐（避免严格的 change 顺序依赖；兜底：本地无规则时置 null + warning，规则到位后下一次 edit 同步自然修复）。

## 实现步骤（≤5）

1. **写路径登记**（`lib/data/repositories/local/local_recurring_transaction_repository.dart`、`local_repository.dart:1622`、`services/data/account_dedup_service.dart:121`）：所有 insert/update/delete 后 `recordLedgerChange(entityType: 'recurring', ...)`；启动时对 syncId 为空的 legacy 行回填 UUID + 补 upsert change（对齐 `_backfillLegacyUserGlobalChanges` 的兜底思路，但走 ledger-scoped 版本）。
2. **序列化与推送**（`lib/cloud/sync/entity_serializer.dart`、`sync_engine_serialization.dart`）：`serializeRecurring` + `_serializeEntityForPush` case 'recurring'；`serializeTransaction` 补 `recurringSyncId`；ledger 批组装处拆 recurring 独立批（决策 4）。
3. **应用与 realtime**（`lib/cloud/sync/sync_engine_apply.dart`、`sync_engine_realtime.dart`、`sync_engine_status.dart`）：`_applyRecurringChange`（upsert/delete + syncId→int 解析 + pending 交易回扫绑定）；realtime case 'recurring' 失效；状态计数补 recurring 维度。
4. **服务端协同**（独立仓库，另行排期）：白名单 + projection + WS 广播；联调用 dev server 先行，客户端以"独立批失败不阻塞"保证未升级环境可用。
5. **验证**：`flutter analyze`；单测覆盖 apply 的 syncId 命中/未命中（置 null + warning）/delete、延迟绑定回扫、独立批失败不影响主批；双端真机联调验收标准场景。

## 边界条件与风险

- **服务端未就绪先发客户端**：recurring change 永远推不出去，local_changes 表持续积压该类行（每规则至多数条，量可控）；server 升级后自动追平。发布顺序建议：server 先行或同窗口。
- **change 时序**：transaction 先到、recurring 后到 → 靠延迟绑定回扫兜住；recurring 永不到（如云端被清）→ 交易 recurringId 置 null，展示层需容忍"来源规则缺失"（与快照链路同名风险，UI 已有类似容错——交易缺分类仅 warning）。
- **双机并发生成**（与快照链路同款固有限制）：两端在同步窗口内各自生成 → 交易重复且 syncId 不同，规则 lastGeneratedDate 由 LWW 收敛后不会继续重复。残余重复需人工清理；频率低，接受。
- **删除传播**：规则删除 change 到达时本地有交易仍引用它 → 只删规则行，交易保留（recurringId 变悬空 int，孤儿清理器已有扫描范畴可扩展）；不级联删交易（防误删用户数据）。
- **与 sync_gap_closure 的依赖顺序**：本设计假设 v33 迁移（syncId 列）已合入；若本期先行，则迁移并入本 PRD，sync_gap_closure 反向依赖本需求——二选一，落地前确认。
- **共享账本**：Editor 记的规则引用 Owner 的分类/账户（syncId 语义天然兼容决策 2），但本期不做成员级权限差异（Editor 可建规则、全员可见），后续按共享账本权限模型细化。
