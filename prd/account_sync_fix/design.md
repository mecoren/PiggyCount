# 账户同步修复设计（account_sync_fix）

## 技术决策

1. **导出全量账户（G1）**：账户本就是 user-global（`ledger_id=0`，导入路径已硬编码 0），直接在 `exportTransactionsJson` 中把「被交易引用的账户集合」改为 `SELECT * FROM accounts` 全量导出。每个账本快照都带全量账户，恢复任意一个快照即可收敛账户集合。
   - 取舍：多账本快照有冗余（N 份快照 × 同一份账户列表）。账户数量级小（几十条），冗余可接受；换来「恢复任意单个账本即可同步账户」的简单语义，无需新增全局索引文件和迁移逻辑。
2. **导入去重对齐标签策略（G2）**：`importAccounts` 改为
   - ① incoming.syncId 非空且命中本地 syncId → 同一账户，更新非空字段；
   - ② 否则按 name 命中 → 更新非空字段；若本地 syncId 为空且 incoming.syncId 非空 → **回填本地 syncId**（收敛身份，下次同步即可按 syncId 锚定）；
   - ③ 都未命中 → 新建。
   - 风险：两台设备各自独立创建的同名账户（如 "11"，syncId 不同）在互相恢复时仍按 name 合并并保留本地 syncId —— 身份无法自动仲裁，属既有行为，不恶化。快照的 last-writer-wins 覆盖余额等字段是快照同步的固有语义。
3. **不动的东西**：`ledger_<intId>.json` 命名、budgets/recurring 覆盖、Path B sortOrder/估值登记 —— 均待用户确认后另开需求。

## 实现步骤（≤5）

1. `lib/cloud/transactions_json.dart`：`exportTransactionsJson` 账户查询改为全量 `db.select(db.accounts)`；保留 `accountIdToName` 映射构建（仍需按 id → name 给交易条目用）；payload version 保持 7（账户数组语义只是变全，旧客户端可正常消费）。
2. `lib/services/data_import_service.dart`：`importAccounts` 增加 syncId 索引与三级匹配（syncId → name+回填 → 新建）；`updateAccount` 调用保持「仅非空字段覆盖」。
3. 自测：dev2 全部上传 → dev1 全部恢复 → 拉库对比账户 syncId 集合。
4. `flutter analyze` + `flutter gen-l10n`。
5. 清理临时对比目录 `.tmp_sync_check`。

## 边界与风险

- **余额覆盖**：快照恢复是 last-writer-wins，dev2 上传的支付宝余额 3200 会覆盖 dev1 的 0（反之亦然）。这是快照同步既有语义，用户需按「先上传的为准」操作。
- **旧快照兼容**：云端旧 JSON 只含被引用账户，恢复旧快照不会补齐全量账户 —— 需重新「全部上传」生成新快照。
- **name 兜底合并**：跨语言设备（Cash vs 现金）name 不匹配会各建一条 —— 既有行为，本次不解决（标签也如此）。
- **hidden/sortOrder 随快照传输**（字段已在导出格式里），恢复端按非空覆盖应用。
