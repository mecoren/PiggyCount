# 储蓄目标（requirements）

> 状态：已实施（2026-10-09；schema v53 · 快照格式 v12）
> 上游依据：竞品差距分析「P1 · 填补核心空白」第 7 条（储蓄目标 / 存钱计划）；「如果只能做三件」第 3 项的后半段
> 关联设计：[design.md](./design.md)

## 1. 背景

「个人财务生命周期」目前只覆盖到「钱花在哪」与「钱放在哪」，缺「钱要攒去哪」：

| 已有能力 | 落点 | 缺什么 |
|---|---|---|
| 预算（限制） | `lib/data/repositories/local/local_budget_repository.dart` | 只告诉你「不许超」，不告诉你「为之攒」 |
| 账户与净资产 | `lib/data/repositories/local/local_account_repository.dart` | 只反映余额快照，没有「离目标还差多少」的动机层 |
| 投资持仓 | `lib/data/repositories/local/local_holding_repository.dart` | 管「已投的钱」，不管「准备攒的钱」 |

预算是约束、目标是激励，两者是同一枚硬币的两面；本项目只有前者。竞品（随手记 / MoneyWiz / Monarch）几乎全员具备目标模块，本项也是「个人财务生命周期」这块最大空白里成本最低的一半（另一半投资持仓已于 `b6f6eb1a` 落地）。

## 2. 目标

1. **目标清单**：按账本维护储蓄目标（名称、目标金额、币种、目标日期、备注），带进度可视化。
2. **两种进度来源**（同一张表内二选一，互斥）：
   - **账户模式**：目标关联一个储蓄账户，进度 = 该账户当前余额（实时，随记账自动变化）。
   - **手动模式**：不关联账户，进度 = 目标行上的手动累计额，通过「存入 / 取出」快捷操作调整。
3. **进度洞察**：进度条、已存 / 剩余、达成状态、按当前速度的预计达成日。
4. **全链路可同步**：作为 ledger-scoped 实体进快照契约（格式版本 v11 → **v12**）。

## 3. 非目标（明确不做，勿扩范围）

- ❌ **不做存入明细流水**：不建第二张表记录每一次存入。账户模式用账户余额、手动模式用单列累计值。
- ❌ **不做自动扣款 / 自动划转**：不自动生成转账交易、不自动从账户扣钱。
- ❌ **不做目标与分类的联动**（如「旅行」目标自动统计旅行分类支出）——那是支出统计，不是储蓄。
- ❌ **不做多账户聚合目标**（一个目标关联多个账户）。
- ❌ **不做目标模板 / 周期复投 / 利息复利计算**。
- ❌ **不做小组件联动、不做通知提醒**（本批不碰通知基建）。
- ❌ **不做目标排序拖拽**（保留 `sortOrder` 列，UI 本批只按创建顺序展示）。
- ❌ 不做共享账本相关（该能力已整体下线）。

## 4. 需求与验收标准

### 4.1 数据模型

`lib/data/db.dart` 新增表 `savings_goals`（**ledger-scoped**，照 `Budgets` 范式）：

| 列 | 类型 | 约束 | 说明 |
|---|---|---|---|
| id | int | PK autoIncrement | |
| ledgerId | int | required | 账本作用域（同步时是快照段门控依据） |
| name | text | required | 目标名称 |
| targetAmount | real | required | 目标金额（> 0） |
| currency | text | default `'CNY'` | 目标币种（ISO 大写）；UI 创建时填当前账本本位币 |
| accountId | int | nullable | 关联储蓄账户；**非空 = 账户模式** |
| savedAmount | real | default 0 | 手动累计额；**仅 accountId 为空时生效** |
| startDate | datetime | default now | 起算日（速度估算的基准） |
| targetDate | datetime | nullable | 期望达成日（可为空，仅用于对照，不做校验） |
| note | text | nullable | 备注 |
| sortOrder | int | default 0 | 预留排序 |
| syncId | text | nullable | 跨设备唯一标识（新建即生成，同 Budget） |
| createdAt | datetime | default now | |
| updatedAt | datetime | default now | 由触发器 `trg_savings_goals_touch_updated_at` 自动维护 |

索引：`idx_savings_goals_ledger(ledger_id)`、`uq_savings_goals_sync_id(sync_id)`（唯一）。onCreate 与迁移必须同时建（见 design.md §2）。

### 4.2 进度口径（纯函数，需单测）

**账户模式**（`accountId != null`）：`saved = 该账户当前余额`（同币种，见 §4.3）。
**手动模式**（`accountId == null`）：`saved = savedAmount`。

派生量：

| 量 | 口径 |
|---|---|
| `rate` | `saved / targetAmount`，UI 展示时 clamp 到 `[0, 1]`，但**不 cap 已存金额文本**（超额存钱要看得见） |
| `remaining` | `max(targetAmount - saved, 0)`；**但 `saved < 0`（账户透支）时恒为 `targetAmount`** —— 否则会出现「还差 1300 / 目标 1000」这种看起来像 bug 的展示 |
| `achieved` | `saved >= targetAmount`（`targetAmount > 0`） |
| `dailyRate` | `saved / max(自 startDate 起的天数, 1)` |
| `estimatedDays` | `dailyRate > 0 ? ceil(remaining / dailyRate) : null` |
| `estimatedDate` | `estimatedDays != null ? now + estimatedDays 天 : null` |

边界：`targetAmount <= 0` → `rate = 0`、不算达成（脏数据兜底，不崩不出现 NaN）；`saved < 0`（账户透支）→ `rate` 按 0 展示、`remaining = targetAmount`。

**验收**：
- 目标 10000、已存 2500 → 进度 25%、剩余 7500。
- 目标 10000、已存 12000 → 标记「已达成」，文本显示「已存 12000」（不被截成 10000）。
- 目标 0（脏数据）→ 进度 0%、不判达成。
- 起算 10 天、已存 1000、目标 2000 → 日均 100、预计还需 10 天。

### 4.3 币种口径

- **账户模式**：目标币种**强制等于关联账户的币种**。编辑页选中账户后币种自动带出并锁定（用户若要换币种必须先换账户），因此不需要汇率折算——避免把「视图期汇率」引入一个纯展示模块。
- **手动模式**：币种可自由选择（默认账本本位币）；`savedAmount` 即该币种金额。
- 列表页汇总（总目标额 / 总已存）**只汇总与账本本位币同币种的目标**，其余只计数不计入，并提示「另有 N 个外币目标未计入合计」（沿用订阅视图 `prd/subscription_and_overspend_alerts/requirements.md §4.1` 的同款口径与理由）。

### 4.4 页面与交互

**入口**：「我的 → 储蓄目标」（`lib/pages/main/mine_page.dart` 的设置项列表，与「行情与投资」并列）。

**列表页** `lib/pages/savings_goal/savings_goals_page.dart`：
- 顶部汇总卡：目标数、总目标额、总已存、总体进度条（仅本位币目标）。
- 每条目标卡片 `SavingsGoalCard`：名称、来源标记（账户名 / 手动）、进度条、已存 / 目标、剩余或「已达成」徽章。
- 空态：`AppEmpty` + 引导文案。
- 新增：`FloatingActionButton.extended`（同 `InvestmentHoldingsPage`）。
- 点击卡片 → 打开编辑抽屉。

**表单抽屉** `showSavingsGoalFormBottomSheet`（`lib/pages/savings_goal/savings_goal_edit_page.dart`，用 `PiggyFormSheet` 外壳，同 `showHoldingFormBottomSheet`）：
- 字段：名称、目标金额、进度来源（账户 / 手动，两颗 `ChoiceChip`）、账户选择（抽屉 + `PiggyOptionRow`）、币种（`showCurrencyPickerSheet`，账户模式下锁定）、目标日期（`showWheelDatePicker`）、起算日、备注。
- 手动模式下额外提供「存入 / 取出」快捷按钮：弹一个金额输入，调整的是**表单草稿**（点「保存」才落库，中途取消可撤销），不生成交易。
- 保存走 `ref.read(repositoryProvider)`；成功后 `pop(true)` + `ref.read(savingsGoalRefreshProvider.notifier).state++`。
- 编辑态末尾提供删除（`AppDialog.confirm(destructive: true)` 或双重危险确认，与同层功能一致）。

**验收**：
- 新增（手动模式）→ 列表与汇总卡同步更新。
- 关联账户后进度随该账户余额变化（在该账户下记一笔收入/支出，回到目标页进度应变化）。
- 账户模式下币种选择器不可用且显示账户币种。
- 删除目标后列表与汇总更新，且该删除会进入同步变更（见 §4.5）。

### 4.5 同步契约（ledger-scoped）

快照格式版本 **11 → 12**，新增 `savingsGoals` 段：

- `lib/cloud/transactions_json.dart`：导出段 + payload 键 + 解析段 + `ImportData.savingsGoals`；版本常量与版本历史注释。
- `lib/cloud/sync_fingerprint.dart`：`savingsGoalCanon` + 最终 encode map + 计数。
- `lib/cloud/sync_diff_service.dart`：`SyncEntityKind` 增成员、词汇映射、`lostSections`、`cloudSyncIdPresent`、`offer` 段（`sectionAbsent('savingsGoals', 12)`）、apply 合并导入、`stillReferenced`、删除 switch。
- `lib/services/data_import_service.dart`：`importSavingsGoals`（按 `syncId` 幂等 upsert，沿用 `importBudgets` 形状）。
- `lib/cloud/sync/change_tracker.dart`：**无需改**（ledger-scoped 走 `recordLedgerChange`，不参与 user-global 白名单）。
- 写路径必须走 `LocalRepository` 聚合层 `db.transaction` + `recordLedgerChange(ledgerId: <具体非零>)`；**禁止**绕过 Repository 写库。

**格式升级一次性重传**（AGENTS.md 口径）：v12 改变了指纹算法值，云端若仍是 v11 快照，两端指纹永不相等。复用既有门控 `shouldRepublishSnapshotForFormatUpgrade`（重算指纹 == 本地指纹才一次性 force 全量重传；内容确实不同时一律不自动覆盖），**不需要新增代码**，但必须在测试里钉住 v12 的段缺失语义。

**验收**：
- 新建 / 改名 / 改金额 / 删除目标后，`local_changes` 出现 `entityType = 'savings_goal'`、`ledgerId = 该账本` 的记录（删除为 `action = 'delete'`）。
- 导出快照含 `savingsGoals` 段与 `version = 12`；导入往返字段零丢失。
- 旧快照（无该段）在 diff 里**不得**被判为「本地目标全删」（段引入版本门控）。

## 5. 兼容与迁移

- `schemaVersion` **52 → 53**；迁移块 `if (from < 53)` 建表 + 两个索引 + 纳管触发器，全部幂等（`_createTableIfMissing` / `CREATE INDEX IF NOT EXISTS` 模式）。
- onCreate 同步补两个索引（`test/data/migration_index_parity_guard_test.dart` 会校验）。
- 触发器数断言 `test/data/schema_updated_at_test.dart` 由 7 → 8。
- 不删任何既有列；无老用户数据需要回填。

## 6. 测试矩阵

| 层 | 测试文件 | 覆盖 |
|---|---|---|
| 迁移 | `test/data/savings_goal_migration_test.dart` | v52 形态库 → 打开后建表/索引/触发器；重开幂等 |
| Repository | `test/data/local_savings_goal_repository_test.dart` | CRUD + `recordLedgerChange` 作用域（create/update→upsert、delete→delete、ledgerId 正确）+ 软删除/账户级联（若涉及） |
| 纯函数 | `test/utils/savings_goal_progress_test.dart` | §4.2 全部边界（含 targetAmount ≤ 0、saved < 0、达成、速度估算） |
| 契约 | `test/cloud/sync_contract_savings_goal_test.dart` | 导出↔指纹键派生一致、每个可同步字段影响指纹、段门控（旧快照不判全删）、实体删除语义（四条，照抄 `sync_contract_holdings_test.dart`） |
| 页面 | `test/pages/savings_goals_page_test.dart` | 空态 / 有数据渲染 / 表单保存真落库（照抄 `investment_holdings_page_test.dart` 的 `pumpPage/settlePage/l10nOf` 三件套） |
| 既有基线 | `test/data/schema_updated_at_test.dart` | 触发器数 8 |

门禁：`flutter analyze --fatal-infos` 零 issue；`flutter test` 全绿。
