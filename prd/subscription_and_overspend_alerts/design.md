# 订阅视图 + 到期/超支提醒（design）

> 状态：实施中（2026-10-08）
> 需求与验收：[requirements.md](./requirements.md)

## 1. 总体策略：接线，不造轮子

三块能力全部复用现有实现，新增代码只有「纯函数 + 薄 Service + 一个派生页面」：

| 需求 | 复用什么 | 新增什么 |
|---|---|---|
| 订阅视图 | `RecurringTransactionRepository.getEnabledRecurringTransactions`、分类图标口径 | 年化折算纯函数 + 一个 Provider + 一个页面 |
| 到期提醒 | `RecurringTransactionService` 的频率推进规则、`CreditCardReminderService` 的「调度 + 启动恢复 + prefs 存开关」范式 | `nextDueDateAfter` 纯函数 + `RecurringDueReminderService` |
| 超支推送 | `LocalBudgetRepository.getBudgetOverview` / `BudgetUsage.rate`、`periodContaining` 的周期语义 | `BudgetOverspendNotifier` + `PostProcessor` 一处接线 |

**零数据模型改动**：不新增 Drift 表/列 → 无 `schemaVersion` 递增、无迁移、无 `build_runner`；开关与水位只进 SharedPreferences。因此不存在「指纹白名单 / diff 字段 / `ChangeTracker` 契约 / 同步守门测试」的连带成本。

## 2. 关键决策一：`nextDueDateAfter` 必须与 `calculateNextDate` 同源，但不能改后者

### 问题

`RecurringTransactionService.calculateNextDate`（`lib/services/data/recurring_transaction_service.dart`）的语义是**「本次是否需要生成」**：

```text
nextDate <= now  → 返回 nextDate（该生成）
nextDate >  now  → 返回 null（还没到）
```

而「扣款前 3 天提醒」需要的是**严格晚于 now 的下一次发生日**。直接复用 `calculateNextDate` 拿不到未来日期（它对未来一律返回 null）；另起一套日期推算则极易与生成逻辑漂移 —— 一旦漂移，提醒日与实际扣款日错位，用户收到「3 天后扣款」却等了 5 天。

### 方案

在同一个文件里并列新增纯函数，**共用同一套推进规则**：

```dart
DateTime? nextDueDateAfter(RecurringTransaction recurring, {DateTime? now});
```

口径（逐条对应 `calculateNextDate` 的既有实现）：

1. `interval < 1` 一律按 1 处理（脏数据兜底，防死循环）。
2. `lastGenerated == null` 视为首笔；基准日 `baseDate = max(startDate, 今天零点)`（issue #135：不回溯补历史）。
3. 首个发生日：
   - daily / weekly → `baseDate`
   - monthly → `buildMonthly(baseDate.year, baseDate.month, targetDay)`；若早于 `baseDate` 则再进 `interval` 个月
   - yearly → `buildYearly(baseDate.year, targetMonth, targetDay)`；若早于 `baseDate` 则再进 `interval` 年
4. 后续发生日：从**上一个发生日**按频率推进 `interval`（daily/weekly 加天数；monthly/yearly 用 `buildMonthly/buildYearly`）。
5. **`targetDay` / `targetMonth` 取自首次的 `baseDate` 并固定不变** —— 否则 1 月 31 日在 2 月被夹成 28 号后，后续就永久变成 28 号了（`calculateNextDate` 也是这么做的）。
6. 从首个发生日开始向前滚，返回**第一个严格 `> now`** 的日期；滚动次数上限 2000 次（防御）。
7. `endDate` 已过（`now > endDate`）或候选日超过 `endDate` → 返回 `null`。
8. **`calculateNextDate` 一个字都不改** —— 它被生成逻辑与既有单测锁定（含 issue #135 口径）。

### 实现补充：外币订阅不进合计

订阅视图的汇总只累加「模板币种 == 账本本位币」的项，外币项由 `SubscriptionItem.isForeign` 标记、只计数；UI 在汇总卡下方给出「另有 N 个外币订阅未计入合计」。原因见 requirements §4.1（视图期无可靠汇率，硬折会给出错误数字）。因此 `SubscriptionItem` 需要 `isForeign` 字段，provider 负责按账本本位币打标。

### 为什么放在 Service 而不是 utils

推进规则（月/年构建、`dayOfMonth` / `monthOfYear` 语义、首笔特例）是 `RecurringTransactionService` 的私有知识，抽出去会造成两处并行维护。放同文件、共用私有 `_buildMonthly` / `_buildYearly`，是唯一能让两者不漂移的写法。

## 3. 关键决策二：超支检测挂在 `PostProcessor` 单一出口

### 为什么

记账写入入口有六处（手动编辑器、AI 文本/语音/图片、深链/分享自动记账、周期账单自动生成），且**手动编辑器走的是 `PostProcessor.sync`（仅同步）而不是 `run` 系列**（`lib/pages/transaction/transaction_editor_page.dart` 保存后调 `PostProcessor.sync`）——按入口逐个插桩必然漏掉一个。

而 `PostProcessor` 的六个公开方法（`run` / `runC` / `runR` / `sync` / `syncC` / `syncR`）**全部收敛到 `_doSync` / `_doSyncC` / `_doSyncR` 三个私有方法**，在这三处各加一行即天然零遗漏。

### 代价与缓解

代价：分类 / 账户 / 预算等非交易变更也会触发一次检测。

缓解：`BudgetOverspendNotifier.checkAfterWrite` 的**第一步就是读开关**，关闭时立即返回（一次 SharedPreferences 读，且实例已缓存）；开关打开时才做一次预算聚合 SQL（复用既有查询，已按 `ledger_id` + 时间区间走索引），量级远低于一次记账的写库开销。检测以 fire-and-forget 方式发起，不增加记账路径延迟。

### 去重水位

- key：`budget_overspend_notified_<budgetId>_<periodStartIso8601>`
- 命中即跳过；跨周期后 key 自然不再匹配 → 自动恢复可推。
- **清理**：仅在实际推送时顺带 `prefs.remove` 掉该预算下非当前周期的旧 key，避免「每次检测都 O(#keys) 扫描」。

## 4. 关键决策三：提醒服务构造注入 `NotificationUtil`

既有 `CreditCardReminderService` 是纯 static + `NotificationFactory.getInstance()` 直取，不可测。新代码不复制这个形状：

```dart
class RecurringDueReminderService {
  RecurringDueReminderService({
    required dynamic repository,          // PiggyRepository（只读周期账单）
    NotificationUtil? notificationUtil,   // 默认 NotificationFactory.getInstance()
  });
}
```

单测塞入 fake `NotificationUtil` 即可断言「调度了什么时间 / 是否被取消」，无需新增工厂 seam，也不动既有信用卡服务（避免顺带重构扩大爆炸半径）。

## 5. 通知 ID 段

| 段 | 用途 | 新/旧 |
|---|---|---|
| `1001` | 每日记账提醒 | 旧 |
| `2000 + accountId` | 信用卡还款提醒 | 旧 |
| `3000 + recurringId` | 周期账单到期提醒 | **新** |
| `4000 + budgetId` | 预算超支提醒 | **新** |
| `9999` | 设置页测试通知 | 旧 |

均避开 `auto_billing` 已占用的 ID 段，互不覆盖。

## 6. 文件级改动清单

### 新增

| 文件 | 职责 |
|---|---|
| `lib/utils/subscription_estimate.dart` | 纯函数：`countPerYear(frequency, interval)`、`annualizedAmount`、`monthlyAverage`、汇总；值对象 `SubscriptionItem` |
| `lib/providers/subscription_providers.dart` | `subscriptionItemsProvider`（当前账本 → 启用支出型周期账单 → 带下次扣款日的订阅项）、`subscriptionSummaryProvider` |
| `lib/pages/transaction/subscription_page.dart` | 订阅管理页：汇总卡 + 列表 + 空态 |
| `lib/services/system/recurring_due_reminder_service.dart` | 到期提醒编排：`rescheduleAll`（全库收敛）/ `cancelForTemplate` / `cancelAllPending` |
| `lib/services/system/budget_overspend_notifier.dart` | 超支检测：开关短路 → 预算聚合 → 水位判重 → 发通知 |
| `test/utils/subscription_estimate_test.dart` | 年化折算与汇总单测 |
| `test/services/recurring_next_due_date_test.dart` | `nextDueDateAfter` 四频率 + 边界单测 |
| `test/services/budget_overspend_notifier_test.dart` | 超支去重 / 开关 / 跨周期单测（fake 通知 + 假仓库） |
| `test/services/recurring_due_reminder_service_test.dart` | 调度时间 / 取消 / endDate 单测（fake 通知） |

### 修改

| 文件 | 改动 |
|---|---|
| `lib/services/data/recurring_transaction_service.dart` | 新增 `nextDueDateAfter` + 抽私有 `_buildMonthly` / `_buildYearly` 供两条路径共用；`calculateNextDate` 行为不变 |
| `lib/data/repositories/budget_repository.dart` | `BudgetOverview` 增 `DateTime? periodStart` / `periodEnd`（**可选**，避免波及 12 处既有构造点；注释写明「本地计算字段，不进快照/指纹/diff」） |
| `lib/data/repositories/local/local_budget_repository.dart` | `getBudgetOverview` 用既有 `_monthStartDayOf` + `periodContaining` 填充新字段 |
| `lib/services/billing/post_processor.dart` | `_doSync` / `_doSyncC` / `_doSyncR` 各加一行 fire-and-forget 调用（`unawaitedLog`） |
| `lib/services/system/reminder_monitor_service.dart` | 前台恢复时若开关开启且 pending 缺 3000 段，触发一次重调度（沿用 >6h 节流） |
| `lib/providers/reminder_providers.dart` | `ReminderSettings` 增 `budgetOverspendEnabled` / `recurringDueEnabled`（默认 false）；notifier 增两个 `updateXxx`，开启到期提醒即全量重调度、关闭即取消 3000 段 |
| `lib/pages/settings/reminder_settings_page.dart` | 首个 `SettingsCard` 内新增两个 `SettingsToggleItem` |
| `lib/pages/settings/automation_page.dart` | 「周期记账」项后新增「订阅管理」`SettingsNavItem` |
| `lib/pages/transaction/recurring_transaction_page.dart` | 启停开关成功后重调度/取消；新增/编辑改走表单抽屉（`showRecurringFormBottomSheet`），返回后重调度 |
| `lib/pages/transaction/recurring_transaction_edit_page.dart` | **表单形态改抽屉**：新增 `showRecurringFormBottomSheet`；`RecurringTransactionEditPage.build` 从 `Scaffold`+`PiggyTitleBar`+底部保存条改为 `PiggyFormSheet`（字段容器 `ListView` → `Column(stretch)`）；删除按钮从标题栏移到表单主体末尾；新增 `_saving` 忙碌态 |
| `lib/services/export/config_export_service.dart` | `AppSettingsConfig` 五处同步（`toMap` / `fromMap` / 采集 / YAML 写 / 导入回写） |
| `lib/l10n/app_en.arb`（模板）/ `app_zh.arb` / `app_zh_TW.arb` / `app_ko.arb` | 新增订阅页、到期/超支通知、设置开关文案 |
| `lib/l10n/app_localizations*.dart` | `flutter gen-l10n` 生成后提交（不手改） |
| `prd/README.md` | 索引表登记本需求 |

### 启动链接线

`lib/main.dart` 的 `_initNotificationChain` 里 `Future.wait` 增加一条 `_restoreRecurringDueReminders(container)`，与既有 `_restoreUserReminder` / `_restoreCreditCardReminders` 并列，静默失败不阻塞首屏。

> 注意：**开关默认关闭**，恢复链第一步读开关，关闭时不读库、不调度。

### 实现补充：为什么 `rescheduleAll` 不做「只处理某账本」

初版带 `ledgerId?` 形参（模板变更后按账本收敛），评审发现它与「孤儿清理」自相矛盾：传 `ledgerId` 时 `activeIds` 只含该账本，随后清理会把**其它账本**的 3000 段全部取消。而三条生产路径（启动恢复 / 前台补种 / 开关打开）本来就该全库收敛，模板变更后的收敛量也不大 —— 直接删掉形参，只保留全库语义（见该方法的文档注释）。触发点：模板变更（编辑页保存 / 列表启停）、启动链、前台恢复、开关打开。

### 实现补充：配置导入后的收敛时机

两个新开关随配置导入写入 SharedPreferences，但 `ReminderSettingsNotifier` 是应用级单例、不会因导入而重建，调度收敛要等**下一次启动**（启动链 `_restoreRecurringDueReminders`）——与仓库既有的「部分配置需重启生效」（`configImportRestartMessage`）口径一致，本次不额外加导入后 reload 钩子。

## 7. 文案与 i18n

- UI 代码一律 `AppLocalizations.of(context).xxx`。
- Service 内无 `BuildContext`：沿用仓库既有范式 `lookupAppLocalizations(PlatformDispatcher.instance.locale)`（同 `lib/services/automation/auto_billing_service.dart`）。
- `app_en.arb` 是模板：**先加 en，再同步 zh / zh_TW / ko**，缺 key 会直接显示 key 名。
- 带占位符的 key 需在 `app_en.arb` 写 `@key.placeholders` 元数据。

## 8. 测试计划（TDD：先失败用例，再实现）

| 用例组 | 断言重点 |
|---|---|
| `nextDueDateAfter` | 四频率 + `interval>1`；首笔未生成（`startDate` 在过去/未来）；月底（1/31 → 2/28 → 3/31 不塌陷）；闰年 2/29；`endDate` 已过 → null；候选日超 `endDate` → null；`interval=0` 不死循环 |
| 年化折算 | 四频率 × interval；0 金额计入条数不计金额；汇总求和 |
| 超支检测 | rate≥1 推一次；重复调用不重推；跨周期再推；开关关闭不推且不查库；未超支不推；水位 key 清理旧周期 |
| 到期提醒 | 调度时间 = 扣款日 − 3 天 10:00；提前窗口已过则跳过；`enabled=false` 取消；`endDate` 已过取消；开关关闭时 `rescheduleAll` 不调度 |
| 订阅页 Widget | 空态渲染；列表条数与年支出汇总数值正确（Drift 内存库 + `ProviderContainer`） |
| 抽屉契约（`test/widgets/recurring_form_drawer_test.dart`） | 三入口（列表「+」/ 列表条目 / 订阅条目）都出 `PiggyFormSheet` + 居中标题 + 「取消｜保存」；编辑态主体内有「删除」；「取消」可收起 |

Riverpod 3 注意点（AGENTS.md）：`StateNotifierProvider` 从 `package:flutter_riverpod/legacy.dart` 引入；`StreamProvider` 需 `container.listen` 保活；`ProviderContainer(retry: (_, __) => null)` 关掉自动重试。

## 9. 风险与取舍

| 风险 | 处置 |
|---|---|
| 提醒日与扣款日漂移 | `nextDueDateAfter` 与 `calculateNextDate` 同文件同规则，共享月/年构建私有函数；单测覆盖月底/闰年 |
| `PostProcessor` 单点收口带来额外开销 | 开关前置短路；fire-and-forget；仅开关开启时一次聚合 SQL |
| 通知轰炸 | 只推 100% 超支；**同预算同周期只推一次**；默认关闭开关；到期提醒只在有扣款方时推 |
| 与并发会话冲突 | 只改本清单列出的文件；`calculateNextDate` 等既有逻辑只读不改 |
| iOS/Android 权限被拒 | `showNotification` 静默降级，不弹引导（沿用既有行为） |
| 表单抽屉内容超长（周期账单 12+ 字段），「取消｜保存」需要滚动才可见 | 这是 `PiggyFormSheet` 的既定行为（标题与按钮行随卡片滚动，壳里不钉 footer）。不接受就给壳加粘性底栏 —— 那会改动云同步 / 加密 / 预算 / 账户四处共用外壳，属独立决策，本批不做 |
| 抽屉里再弹选择器（分类 / 账户 / 币种 / 日期） | 与账户编辑抽屉同款做法（账户抽屉内也弹币种选择器 / 日期选择器），`showModalBottomSheet` 可嵌套弹出，行为已验证 |
| 水位 key 膨胀 | 推送时清理同预算的旧周期 key |
| iOS 待发通知上限 64 条 | 与既有信用卡还款提醒同量级、共用同一限额；模板数极多的用户可能被系统丢弃末尾若干条。`rescheduleAll` 每次都按同一顺序重排，最坏情况稳定在「前 N 条」，不会随机丢。后续若成问题再引入「只调最近 N 条」的裁剪 |

## 10. 明确不做

见 [requirements.md](./requirements.md) §3。特别地：不动 `schemaVersion`、不加依赖、不做历史交易识别、不做 per-预算开关、不改 `calculateNextDate` 语义。
