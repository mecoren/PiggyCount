# 账户去重收敛设计（account_dedup）

## 技术决策

1. **实现为幂等服务而非 Drift schema 迁移**：`AccountDedupService.run(db)` 每次启动都跑，先做廉价检测（全量读 accounts，按 name 分组判断是否存在同名多行或 `ledger_id!=0`），无目标状态时零写入直接返回。相比 onUpgrade 一次性版本迁移，可重复自愈"恢复旧快照再次引入重复账户"的场景，且不占 schema 版本号。
2. **触发点在 main.dart 引导阶段、runApp 之前**：dedup 完成后才进入 UI 与启动同步检查，杜绝与 StartupSyncChecker 的 getStatus 指纹计算、上传导出并发读写账户表。异常 try/catch 隔离，失败仅记日志不阻塞启动。
3. **keeper 选择规则（组内确定性）**：① `ledger_id=0`（已是全局）→ ② `syncId` 非空中 id 最小（保住与对端设备共享的身份锚点，dev2 的支付宝 id4 即此例）→ ③ id 最小。keeper 保留自身 `syncId` 与 `initial_balance`（被吸收账户的期初余额不累加，避免与已挂交易重复计资；期初余额语义上属于用户手设开账值，遗留重复行均为种子账户、期初为 0）。
4. **单事务合并**：drift `transaction()` 内逐个 dup 执行两条 `UPDATE ... SET account_id=keeper WHERE account_id=dup`（transactions 与 recurring_transactions 各两条），再删 dup 行、置 keeper `ledger_id=0`。SQLite 单事务内约 8000 行 UPDATE，耗时可忽略；任一步失败整体回滚，不留半合并状态。
5. **不排除共享账本**：实测账本 2（共享，owner）的账户同样需要收敛——快照导出/导入本就把账户拍平为全局、资产统计按交易侧排除共享账本，账户行的 ledger scope 纯属遗留。

## 实现步骤（≤5）

1. 新建 `lib/services/data/account_dedup_service.dart`：`run(PiggyDatabase)` 返回 `(mergedGroups, movedTxRefs, deletedAccounts)`；含快速路径与事务合并。
2. `lib/main.dart` 在 container 创建后、runApp 前接入（try/catch + logger，失败不阻塞启动）。
3. `flutter analyze` 验证。
4. dev2 热重启（`R` 会重跑 main 引导）触发迁移，拉库验证：账户 35→6、交易笔数不变、孤儿引用 0。
5. dev2 全部上传 → dev1 全部恢复 → 双设备拉库比对账户数 / syncId 集合 / 金额。

## 边界与风险

- **测试受限**：本机缺 sqlite3.dll 无法跑 drift 单测；以双真机拉库对比作为验证证据。
- **override 列残留**：`transactions.account_sync_id_override` 若指向被删账户的 syncId 会悬空；该列属共享账本冲突解析缓存，验证阶段统计受影响行数，若非零再评估改写（本期不改）。
- **keeper 期初余额不累加**：理论上被吸收账户若有非零期初余额会"丢失"该值；种子重复行期初均为 0，真实用户重复主要来自旧版种子，风险低，文档明示。
- **name 跨语言不合并**：Cash 与 现金 视为不同账户（与导入策略一致，保持简单）。
