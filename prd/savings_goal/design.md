# 储蓄目标（design）

> 关联需求：[requirements.md](./requirements.md)
> 范式来源：`Budgets`（ledger-scoped 数据层模板，`lib/data/db.dart:592-625`）+ `Holdings`（新表/迁移/契约模板，`lib/data/db.dart:92-158`、`test/cloud/sync_contract_holdings_test.dart`）

## 1. 数据层

### 1.1 表定义（`lib/data/db.dart`）

```dart
/// v53: 储蓄目标（账本私有）。进度来源二选一：
/// - accountId 非空 = 账户模式，进度由该账户余额实时给出，币种恒等于账户币种；
/// - accountId 为空 = 手动模式，进度读 savedAmount（UI 用「存入/取出」调整）。
/// 刻意不做存入明细表：本模块只回答「离目标还差多少」，不做流水账。
class SavingsGoals extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get ledgerId => integer()();
  TextColumn get name => text()();
  RealColumn get targetAmount => real()();
  TextColumn get currency => text().withDefault(const Constant('CNY'))();
  IntColumn get accountId => integer().nullable()();
  RealColumn get savedAmount => real().withDefault(const Constant(0.0))();
  DateTimeColumn get startDate => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get targetDate => dateTime().nullable()();
  TextColumn get note => text().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  TextColumn get syncId => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}
```

`updated_at` 走**触发器自动维护**（与 `holdings` 一致），而不是像 `budgets` 那样在 UPDATE 里手动写——触发器已是本仓库的主流做法，漏写风险更低。

### 1.2 迁移（`schemaVersion` 52 → 53）

照 v52 的模板（`lib/data/db.dart:1696-1726`）：

```dart
if (from < 53) {
  await _createTableIfMissing(migrator, 'savings_goals', savingsGoals);
  await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_savings_goals_ledger ON savings_goals (ledger_id)');
  await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS uq_savings_goals_sync_id ON savings_goals (sync_id)');
  await _createUpdatedAtTouchTriggers();
}
```

三处必须同步：

1. `onCreate` 也要建这两个索引（`test/data/migration_index_parity_guard_test.dart` 解析源码逐条比对，漏了直接红）。
2. `_updatedAtTouchTables` 加入 `'savings_goals'`。
3. `test/data/schema_updated_at_test.dart:58` 的 `triggerCount()` 断言 7 → 8。

### 1.3 Repository 三层

| 层 | 文件 | 内容 |
|---|---|---|
| 接口 | `lib/data/repositories/savings_goal_repository.dart` | `watchByLedger` / `getByLedger` / `getById` / `create` / `update` / `delete` / `updateSavedAmount` / `updateSortOrders` |
| 实现 | `lib/data/repositories/local/local_savings_goal_repository.dart` | 裸 Drift 读写，**不持 ChangeTracker**（同 `local_budget_repository.dart:13-15`） |
| 聚合 | `lib/data/repositories/local/local_repository.dart` | `late final LocalSavingsGoalRepository _savingsGoalRepo;` + 构造注册 + `db.transaction` 内 `recordLedgerChange` |

聚合层写方法形状（照 `createBudget`，`local_repository.dart:3737-3775`）：

```dart
@override
Future<int> createSavingsGoal({...}) async {
  late int id;
  late String syncId;
  late int ledgerId;
  await db.transaction(() async {
    final row = await _savingsGoalRepo.create(...);   // 内部生成 UUID syncId
    id = row.id; syncId = row.syncId!; ledgerId = row.ledgerId;
    await changeTracker!.recordLedgerChange(
      entityType: 'savings_goal',
      entityId: id,
      entitySyncId: syncId,
      ledgerId: ledgerId,      // 必须 > 0（assert 在 change_tracker.dart:133-137）
      action: 'create',
    );
  });
  return id;
}
```

同步复核三处：`delete` 必须**预读 syncId** 后再删（同 `deleteBudget`）；`updateSavedAmount` 是「存入/取出」的落点，需要记 `update`；`getSyncEntityReferences()` / `getCategoryRefCounts` / `getAccountRefCounts` **无需改**（储蓄目标不被任何实体引用，也不引用账户以外的东西——`accountId` 只是弱引用，账户删除时用 `onDelete` 级联或置空，见 §1.4）。

另：`lib/data/repositories/base_repository.dart:25-41` 的 `implements` 列表追加 `SavingsGoalRepository`。

### 1.4 账户删除的引用处理

`accountId` 是指向账户的弱引用。账户被删除时两条路：

- **置空**（`UPDATE savings_goals SET account_id = NULL WHERE account_id = ?`）→ 目标自动降级为手动模式，进度回到 `savedAmount`（默认 0，表现为「进度归零」）。
- **级联删除**目标 → 用户的钱没了会困惑。

**选置空**，并在 `LocalRepository.deleteAccount` 的级联段（`local_repository.dart:2459-2468` 已有删持仓的同类逻辑）里加这一段，同时记 `update` 变更。

## 2. 进度纯函数（`lib/utils/savings_goal_progress.dart`）

```dart
class SavingsGoalProgress {
  final double saved;
  final double target;
  final double remaining;
  final double rate;          // 已 clamp 到 [0, 1]，仅用于进度条
  final bool achieved;
  final double? dailyRate;    // 无法估算时为 null
  final int? estimatedDays;
  final DateTime? estimatedDate;
}

SavingsGoalProgress computeSavingsGoalProgress({
  required double saved,
  required double targetAmount,
  required DateTime startDate,
  DateTime? now,              // 注入以便单测
});
```

之所以把入参压成「已解算的 saved + target」而不是直接吃 `SavingsGoal` 行对象：账户模式要把账户余额喂进来，手动模式喂 `savedAmount`，解算在调用方（Provider / 页面）完成，纯函数只做算术，边界可穷举。

UI 文案层（`SavingsGoalsPage` 顶部的汇总）复用同一函数的汇总变体 `summarizeSavingsGoals`，只累加与账本本位币同币种的目标。

**边界注记**：`saved < 0`（账户透支）时 `rate` 为 0 且 `remaining` 恒为 `targetAmount` —— 若按 `target - saved` 计算会出现「还差 1300 / 目标 1000」这种看起来像 bug 的展示（`test/utils/savings_goal_progress_test.dart` 钉住）。

## 3. 同步契约改动清单（快照 v11 → v12）

| 文件 | 改动点 | 参考位置 |
|---|---|---|
| `lib/cloud/transactions_json.dart` | `kSnapshotFormatVersion` 11 → 12；版本历史注释追加；`savingsGoalItems` 导出段；payload 键 `savingsGoals`；`parseJsonToImportData` 解析段；`ImportData` 增字段；`ImportSavingsGoal` 类 | 常量 `:36`、版本历史 `:12-28`、budget 段 `:487-507` 与 `:887-913`、holding 段 `:216-238` 与 `:817-852` |
| `lib/cloud/sync_fingerprint.dart` | `savingsGoalCanon`（字段白名单 + 缺键默认 + 稳定排序）；最终 `jsonEncode` map 加 `'savingsGoals'`；count map 加计数 | `holdingCanon :227-263`、encode map `:419-440`、count `:444-454` |
| `lib/cloud/sync_diff_service.dart` | `SyncEntityKind` 加 `savingsGoal`；`_syncEntityChangeType` 词汇映射（必须与 ChangeTracker 的 `entityType` 逐字一致）；`lostSections`；`cloudSyncIdPresent`；`computeEntityDeletes` 的 `offer(...)` 段带 `sectionAbsent('savingsGoals', 12)`；apply 侧 `importSavingsGoals`；`stillReferenced` 返回 false；删除 switch 走 `repo.deleteSavingsGoal` | 枚举 `:33-41`、映射 `:50-58`、段 `:567-585`、apply `:958-968`、守卫 `:1397-1414`、删除 `:1426-1468` |
| `lib/services/data_import_service.dart` | `importSavingsGoals`（按 syncId 幂等 upsert，账户用 `accountSyncId`/`accountName` 解析，解析不到则 `accountId = null`） | `importBudgets` / `importHoldings` |
| `lib/cloud/sync/change_tracker.dart` | **不改**（ledger-scoped 不走 user-global 白名单） | — |

**段门控是本条最容易漏的地方**：`sectionAbsent('savingsGoals', 12)` 保证 v12 之前的旧快照（压根没有这个段）不会被判成「本地目标全删」。若不传引入版本，老用户首次同步会把自己的目标删光。

**格式升级重传**：复用 `shouldRepublishSnapshotForFormatUpgrade`（`lib/cloud/transactions_sync_manager.dart:2594-2641`）与 `_detectUploadConflict` 的旧格式放行分支（`:2986-3003`），无需改代码；但要审阅一次门控语义（白名单式指纹天然忽略旧快照缺失段，跨版本可比）。

## 4. UI

| 组件 | 复用 | 签名位置 |
|---|---|---|
| 页面外壳 | `Scaffold` + `PiggyTitleBar` + `extendBodyBehindAppBar` | `lib/pages/account/investment_holdings_page.dart:36-42` |
| 表单外壳 | `showPiggyFormSheet` / `PiggyFormSheet` | `lib/widgets/ui/form_sheet.dart:206` |
| 进度条 | `BudgetProgressBar` | `lib/pages/budget/widgets/budget_progress_bar.dart:15` |
| 金额显示 | `AmountText` | `lib/widgets/biz/amount_text.dart:9-30` |
| 日期选择 | `showWheelDatePicker` | `lib/widgets/ui/wheel_date_picker.dart:26` |
| 币种选择 | `showCurrencyPickerSheet` | `lib/widgets/currency/currency_picker_sheet.dart:16` |
| 输入框装饰 | `piggyOutlinedDecoration` | `lib/widgets/ui/piggy_input.dart:56-65` |
| 危险确认 | `AppDialog.confirm(destructive: true)` | `lib/widgets/ui/dialog.dart:9-150` |
| 空态 / 卡片 | `AppEmpty` / `SectionCard` | 同持仓页 |

进度条**直接复用 `BudgetProgressBar`**（不新增组件）：它的「已用/总量 + 分档配色 + clamp」语义与目标进度同构，只是「已用」换成「已存」。

页面结构（`lib/pages/savings_goal/savings_goals_page.dart`）：

```text
Scaffold
├─ PiggyTitleBar(l10n.savingsGoalPageTitle)
├─ body: 汇总卡（仅本位币目标）→ 目标卡片列表 / AppEmpty
└─ FloatingActionButton.extended → showSavingsGoalFormBottomSheet
```

卡片 `lib/widgets/savings_goal/savings_goal_card.dart`：名称 + 来源标签（账户名 / 手动）+ 进度条 + `已存 / 目标` + 右侧「剩余 X」或「已达成」徽章。

Provider `lib/providers/savings_goal_providers.dart`：

- `savingsGoalsProvider`：`StreamProvider`，`ref.watch(currentLedgerIdProvider)` + `repo.watchSavingsGoalsByLedger(ledgerId)`（写库自动刷新）。
- `savingsGoalSummariesProvider`：`FutureProvider`，把目标行 × 账户余额解算成 `(goal, progress)` 列表，依赖 `savingsGoalsProvider` + `statsRefreshProvider`（账户余额变化信号）。
- `savingsGoalRefreshProvider`：`StateProvider<int>` 手动失效 tick。

## 5. l10n

新增前缀 `savingsGoal*`，四个 arb 都追加到文件末尾的持仓段之后：`lib/l10n/app_en.arb`（模板，`:4385` 之后、末尾 `}` 之前）、`app_zh.arb`、`app_zh_TW.arb`、`app_ko.arb`；带 `{count}` / `{name}` 的键在**模板**里补 `@…placeholders`。生成物 `lib/l10n/app_localizations*.dart` 由 `flutter gen-l10n` 生成，不手改。

命名草案：`savingsGoalPageTitle` / `savingsGoalEmpty` / `savingsGoalAddTitle` / `savingsGoalName` / `savingsGoalTargetAmount` / `savingsGoalSourceAccount` / `savingsGoalSourceManual` / `savingsGoalSaved` / `savingsGoalRemaining` / `savingsGoalAchieved` / `savingsGoalDeposit` / `savingsGoalWithdraw` / `savingsGoalEstimatedDate` / `savingsGoalTotalTarget` / `savingsGoalTotalSaved` / `savingsGoalForeignExcluded(count)` / `savingsGoalDeleteConfirm(name)` / `savingsGoalCurrencyLockedByAccount`。

## 6. 实施顺序

1. `db.dart`：表 + v53 迁移 + onCreate 索引 + 触发器纳管 → `dart run build_runner build`。
2. 三层 Repository + 聚合委托 + `base_repository.implements`。
3. `utils/savings_goal_progress.dart` 纯函数。
4. 契约四处（`transactions_json` / `sync_fingerprint` / `sync_diff_service` / `data_import_service`）+ 版本 12。
5. Provider + 页面 + 卡片 + 入口（`mine_page`）。
6. l10n 四语言 + `flutter gen-l10n`。
7. 测试五件 + 基线两处（`schema_updated_at_test` 触发器数、索引 parity）。
8. `flutter analyze --fatal-infos` + `flutter test`。

## 7. 风险与取舍

| 取舍 | 理由 |
|---|---|
| 不做存入明细表 | 明细表的真实成本是第 2 张表 + 契约再扩一段 + 一整套流水 UI；而「离目标还差多少」用余额或单列累计就能回答。上一轮竞品分析把它估成「1 张表 + 1 个进度组件」，本设计守住这个成本口径。 |
| 账户模式锁定币种 | 放开就需要在视图期做汇率折算，而目标达成与否是**长期**判断，用瞬时汇率折会让进度条随行情抖动；锁定后逻辑完全无汇率依赖。 |
| 账户模式复用账户余额 | 等于把「这个账户就是攒钱罐」的直觉固化下来，零额外记账动作；不使用「账户余额 − 初始余额」，因为初始余额对用户就是「攒钱罐里已有的钱」。 |
| 账户删除置空而非级联删目标 | 删除账户是资产结构调整，不该顺手销毁用户的动机数据；降级为手动模式（进度归零）比整条消失更可控。 |
| 进度条复用 `BudgetProgressBar` | 语义同构，避免第二套配色/高度口径漂移。 |
| 触发器维护 `updated_at` | 与 `holdings` 一致，避免 `budgets` 那种「UPDATE 里手写 `updatedAt`」的漏写面。 |
