# 设计文档：「账本设置」统一分区（方案 B）

## 1. 需求理解

在「我的」页新增「账本设置 · {当前账本名}」分区，收敛 6 个账本级设置入口（账本信息、预算、自定义字段、周期记账、订阅管理、储蓄目标），并移除它们在旧菜单中的分散入口。纯 UI 导航重组，不改数据层与同步层。

## 2. 关键技术决策

### D1：分区实现复用现有组件，不新建抽象
沿用 `mine_page.dart` 现有的 `SettingsSectionLabel` + `SettingsCard` + `SettingsNavItem` 三段式结构，与相邻分区视觉完全一致。分区整体包一个 `Consumer`，watch `currentLedgerProvider`：
- `ledger == null`（无账本态）→ 返回 `SizedBox.shrink()`，整段隐藏（含标题与卡片）。
- 标题文案用带参数的 l10n 键：`ledgerSettingsSectionTitle(ledger.name)`。

**理由**：改动最小、视觉零风险；不引入"分区注册表"之类的新抽象（三行相似代码好过过早抽象）。

### D2：账本编辑弹窗提取为公共函数
`_showLedgerEditorDialog` 目前是 `ledgers_page_new.dart` 的私有方法（约 100 行，含 `AppDialogShell`、币种选择器、月起始日 28 宫格选择器）。将其与 `_showCurrencyPicker`、`_showMonthStartDayPicker` 一并提取到 `lib/widgets/biz/ledger_editor_dialog.dart`，签名保持 `Future<({String name, String currency, int monthStartDay})?> showLedgerEditorDialog(BuildContext, {...})`。

调用方两处：
- 账本页长按「编辑」（任意账本，传该账本初值）——行为不变；
- 新分区「账本信息」（读 `currentLedgerProvider` 的 name/currency/monthStartDay 作初值）。

保存写回逻辑（`repo.updateLedger`）留在各调用方，弹窗只负责收集表单——与现状一致，避免把仓储依赖拖进 widget 层。

**理由**：两处共用一份实现，避免复制弹窗代码造成的双份维护；提取而非重写，回归风险最低。

### D3：五个目标页面零改造
`BudgetPage` / `CustomFieldManagePage` / `RecurringTransactionPage` / `SubscriptionPage` / `SavingsGoalsPage` 内部已经通过 `currentLedgerIdProvider` / `currentLedgerProvider` 隐式取当前账本（订阅管理、储蓄目标已验证；预算、自定义字段此前已验证），入口挪动不需要给页面加 `ledgerId` 参数。

**已知语义偏差（R1）**：周期记账页用 `allRecurringTransactionsProvider`，是跨账本列表（行上标注账本名）。本次不改其行为——入口归入账本分区只是导航收敛，页面副标题文案沿用"所有账本"口径，避免误导。

### D4：移除旧入口时同步清理死代码
- `ledgers_page_new.dart`：删 `value: 'budget'` 菜单项及 `_onLocalLedgerAction` 对应分支（含"先切 currentLedger 再 push BudgetPage"的注释块）与 `BudgetPage` import。
- `data_management_page.dart`：删「自定义字段」`SettingsNavItem` 与 `CustomFieldManagePage` import。
- `automation_page.dart`：删「周期记账」「订阅管理」两项及对应 import（页面剩「记账提醒」一项，结构保留）。
- `mine_page.dart`：功能管理分区删「储蓄目标」项；新分区插在「功能管理」之前（云同步之后）。
- 各被移除条目若不再被引用，其 l10n 键保留复用给新分区（同文案直接搬），不新增删除。

### D5：本地化
4 个 arb（`app_en/zh/zh_TW/ko.arb`）新增键：
- `ledgerSettingsSectionTitle`（参数 `{ledgerName}`）
- `ledgerInfoItemTitle` / `ledgerInfoItemSubtitle`
其余条目（预算/自定义字段/周期记账/订阅/储蓄目标）复用现有键。

## 3. 实现步骤（≤5 步）

1. **提取弹窗**：新建 `lib/widgets/biz/ledger_editor_dialog.dart`，把 `_showLedgerEditorDialog` + 两个选择器搬入并导出；`ledgers_page_new.dart` 改调用公共函数（行为不变，先跑通账本页回归）。
2. **arb 增键**：4 个 arb 加 §D5 所列键，`flutter gen-l10n` 重新生成。
3. **我的页加分区**：`mine_page.dart` 云同步卡片之后插入「账本设置 · {账本名}」`Consumer` 分区（6 个 `SettingsNavItem`，「账本信息」调 `showLedgerEditorDialog`，其余 push 现有页面）。
4. **移除旧入口**：按 §D4 清理 4 个文件的菜单项、分支与 import。
5. **验证**：`flutter analyze` + 相关 widget 测试（`test/pages/main/`、`test/widgets/`）+ 手动冒烟：切换账本看标题刷新、无账本态隐藏、账本页编辑回归。

## 4. 边界条件与潜在风险

| 编号 | 风险 | 处置 |
|---|---|---|
| R1 | 周期记账页为跨账本视图，与分区语义不完全一致 | 本次不改页面；副标题沿用现有"所有账本"口径文案 |
| R2 | 长按菜单移除预算后，管理非当前账本预算需先切换 | 与旧实现（先切换再进页）行为等价，接受 |
| R3 | 无账本态（id=0）分区渲染取 `ledger.name` 空引用 | D1 的 `ledger == null` 分支整段隐藏 |
| R4 | 弹窗提取遗漏 `type` 字段等细节 | 现弹窗本就只收集 name/currency/monthStartDay，`type` 不在编辑范围，提取时保持原样 |
| R5 | 同步指纹（账本名/币种/月起始日参与） | 写回路径不变（仍 `repo.updateLedger`），零影响 |

## 5. 不做的事（明确排除）

- 不改任何数据表、provider 作用域、同步逻辑。
- 不把账户/分类/标签/主币种等 **user-global** 项收进分区（它们不跟账本，见 db.dart 注释）。
- 不重构「自动化」页剩余结构。
- 不做"按指定账本打开子页"的 ledgerId 参数化改造。
