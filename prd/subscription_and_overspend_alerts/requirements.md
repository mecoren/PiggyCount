# 订阅视图 + 到期/超支提醒（requirements）

> 状态：实施中（2026-10-08）
> 上游依据：竞品差距分析中「P0 · 半成品收口」第 1、2 条与「P1 · 核心空白」第 8 条（订阅管理派生视图）
> 关联设计：[design.md](./design.md)

## 1. 背景

PiggyCount 已有三块彼此独立的能力，但都没有连起来：

| 已有能力 | 落点 | 缺什么 |
|---|---|---|
| 周期账单生成 | `lib/services/data/recurring_transaction_service.dart` | 只会「到期静默生成交易」，不会提前提醒 |
| 预算进度条 | `lib/data/repositories/local/local_budget_repository.dart`、`lib/widget/views/budget_view.dart` | 只有「进 App 才看得到」的进度条，超支无推送 |
| 本地通知基建 | `lib/utils/notification_util.dart`（`scheduleDailyReminder` / `scheduleOnceReminder` / `showNotification`） | 只被「每日记账提醒」与「信用卡还款提醒」用到 |

结果：用户在 App 外感知不到超支与扣款；在 App 内也看不到「我到底订了多少东西、一年花多少」。

本需求**不新增任何数据表、不改 schema、不触碰同步契约**，只做「接线 + 派生视图」。

## 2. 目标

1. **订阅视图（零识别）**：以现有周期账单为唯一数据源，派生一个「订阅管理」页，展示订阅清单与年支出汇总。
2. **周期账单到期提醒**：扣款日前 N 天推送本地通知。
3. **预算超支实时推送**：每笔支出落库后检测，超支即推，同一预算同一周期只推一次。
4. **两个全局开关**：可在设置中分别关闭到期提醒与超支提醒，并随配置导出/导入迁移。

## 3. 非目标（明确不做，勿扩范围）

- ❌ **不新增任何数据表 / 列**：无 `schemaVersion` 递增、无迁移、无 `build_runner`。开关与水位只存 SharedPreferences。
- ❌ **不做历史交易自动识别订阅**（不扫流水找「同金额按月重复」），不做「手动把某笔交易标记为订阅」。
- ❌ **不做 80% 预警**、不做可配置阈值；只推 100% 超支。
- ❌ **不做 per-预算 / per-账单单条开关**，只做全局总开关。
- ❌ 不改 `RecurringTransactionService.calculateNextDate` 的既有语义（含 issue #135 口径，已被生成逻辑与既有单测锁定）。
- ❌ 不新增平台通知代码（复用现有通知渠道，通知 ID 见 §4.4）。
- ❌ 不做共享账本残留收口（另排任务）。
- ❌ 不做小组件联动、不做通知点击深链跳转。

## 4. 需求与验收标准

### 4.1 订阅视图（零识别）

**收纳口径**：当前账本下 `enabled = true` 且 `type = 'expense'` 的周期账单。收入型、转账型、已停用的一律不收录。

**每条订阅展示**：
- 分类图标（走既有 `CategoryIconWidget` 口径，兼容自定义图片图标；无分类时用通用占位）
- 名称：`note` 非空取 `note`，否则取分类显示名，都没有则用「未命名周期账单」类兜底文案
- 金额（带币种口径：模板为外币时标 ISO 码，同周期账单列表既有做法）
- 周期描述：复用既有频率文案（`recurringTransactionMonthly` / `recurringTransactionEveryNMonths(n)` 等）
- **下次扣款日**（新口径，见 design.md §2）
- 点击以**表单抽屉**打开对应周期账单编辑器（`showRecurringFormBottomSheet`，见 §4.6）

**顶部汇总卡**：
- 订阅条数
- **年支出**：按频率与间隔折算后求和
- **月均支出**：年支出 / 12

**折算规则（纯函数，需单测）**：
| 频率 | 每年次数 |
|---|---|
| daily | 365 / interval |
| weekly | 52 / interval |
| monthly | 12 / interval |
| yearly | 1 / interval |

> interval 为 0 或负数时按 1 处理（脏数据兜底），金额为 0 时计入条数但不计入金额。

**多币种口径**：模板币种 ≠ 账本本位币的订阅**只计数、不计入合计**，并在汇总卡下方给出一行提示「另有 N 个外币订阅未计入合计」。
理由：模板币种要到「生成那一天」才按当日有效汇率折成本位币（见 `lib/services/data/recurring_transaction_service.dart` 生成路径的币种注释），视图期没有可靠汇率，硬折会给出错误数字。列表条目仍照常显示外币 ISO 码与金额。

**空态**：无订阅时展示引导文案 + 说明「订阅来自周期账单」，并提供跳转创建入口。

**验收**：
- 停用某条周期账单后，订阅列表与年支出同步减少。
- 新建一条「每 3 个月 100 元」的支出周期账单，年支出增加 400，月均增加 33.33。
- 收入型与转账型周期账单不出现在订阅列表。

### 4.2 周期账单到期提醒

- 触发规则：**扣款日（下次发生日）前 3 天**，当天 **10:00** 发一条单次本地通知。若「扣款日 − 3 天」的 10:00 已过去，则**跳过本次**（不补发、不提前到今刻），等下一周期。
- 通知文案：包含扣款方名称、金额与「N 天后扣款」，全语言化。
- 通知 ID：`3000 + recurringId`（`3000..3999` 段，见 §4.4）。
- 仅对 `enabled = true` 的周期账单调度；收入型与转账型**不提醒**（只提醒支出）。
- `endDate` 已过、或无法算出下次发生日 → 不调度，并取消该模板既有调度。

**三条路径必须全覆盖**（缺一即为 bug）：
1. **模板变更**：新增 / 编辑 / 启停 / 删除成功后，对该模板重调度或取消。
2. **应用启动**：启动链中恢复全部启用模板的调度。
3. **前台恢复**：应用从后台回到前台时，若发现待发通知里该段整体缺失，则重调度（沿用既有 >6 小时节流）。

**开关关闭**：取消 `3000..3999` 段全部待发通知；开关开启时立即全量重调度。

**验收**：
- 关闭开关后 `getPendingNotifications()` 中不再有 3000 段通知。
- 新建模板、改频率、停用、删除四个动作后，待发通知与模板状态一致。
- 杀进程重开 App 后调度仍在。
- **提醒日 == 生成逻辑算出的下一个扣款日**（同源），包括「改过 `dayOfMonth` / `monthOfYear`」的模板 —— 门禁测试：`test/services/data/recurring_next_due_date_test.dart` 的「与 `calculateNextDate` 同源」交叉断言组。

### 4.3 预算超支实时推送

- 触发时机：**每笔支出写入后的统一后处理出口**，检测该账本的总预算与各分类预算。
- 判定：`BudgetUsage.rate >= 1.0`（`rate` 已由 Repository 算好，含 `exclude_from_budget` 排除与子分类归并）。
- 去重：**同一预算 → 同一预算周期只推一次**；跨周期后自然恢复可推。
- 通知 ID：`4000 + budgetId`（`4000..4999` 段）；总预算与各分类预算各自独立一条。
- 通知文案：包含预算名称（总预算 → 「本月总预算」，分类预算 → 分类显示名）、已用金额与预算金额，全语言化。
- 开关关闭：直接短路返回，不做预算聚合查询。
- 异常容错：任何异常只记日志，绝不影响记账主流程。

**验收**：
- 超支时收到一条通知；同一周期再记一笔不重复推。
- 跨到下一预算周期后再次超支可再推一次。
- 开关关闭时不推、且不产生额外预算查询。
- 未超支（rate < 1.0）不推。
- 覆盖率：手动记账、AI 文本/语音/图片、深链/分享自动记账、周期账单自动生成，五条入口都要能触发。

### 4.4 通知 ID 段约定

| 段 | 用途 | 来源 |
|---|---|---|
| `1001` | 每日记账提醒 | `lib/providers/reminder_providers.dart` |
| `2000..2999` | 信用卡还款提醒（`2000 + accountId`） | `lib/providers/credit_card_reminder_providers.dart` |
| `3000..3999` | **周期账单到期提醒（`3000 + recurringId`）** | 本需求 |
| `4000..4999` | **预算超支提醒（`4000 + budgetId`）** | 本需求 |
| `9999` | 设置页测试通知 | `lib/pages/settings/reminder_settings_page.dart` |

> 新增段必须避开 `auto_billing` 已占用的 ID 段，避免互相覆盖。

### 4.5 设置与迁移

- 位置：`lib/pages/settings/reminder_settings_page.dart` 首个卡片内，与「每日记账提醒」并列新增两个开关：
  - 「预算超支提醒」——副标题说明「支出超出预算时通知」
  - 「周期账单到期提醒」——副标题说明「扣款前 3 天提醒」
- 默认值：**均为关闭**（避免升级后突然收到通知）。
- 持久化：SharedPreferences，key 为 `budget_overspend_reminder_enabled` / `recurring_due_reminder_enabled`。
- 迁移：纳入 `lib/services/export/config_export_service.dart` 的 `AppSettingsConfig`（序列化 / 反序列化 / 采集 / 写 YAML / 导入回写五处同步），导出 key 为 `budget_overspend_reminder_enabled` / `recurring_due_reminder_enabled`。

**验收**：导出配置后在新设备导入，两个开关状态保持。

### 4.6 表单形态：周期账单编辑器统一为抽屉

订阅条目点击与「新建订阅」都要用**项目统一的悬浮卡片表单抽屉**，而不是整屏页 —— 与预算 `showBudgetFormBottomSheet`、账户 `showAccountFormBottomSheet`、记账 `showTransactionFormBottomSheet` 同口径（AGENTS.md「表单抽屉一律用悬浮卡片外壳」）。

- 统一入口：`showRecurringFormBottomSheet(context, {recurring})`（`lib/pages/transaction/recurring_transaction_edit_page.dart`），编辑页本体 `RecurringTransactionEditPage` 只作为抽屉内容（返回 `PiggyFormSheet`，不再自带 `Scaffold` / `PiggyTitleBar` / 底部保存条）。
- 三个调用点同批切换：周期记账列表「+」、周期记账列表条目点击、订阅页条目点击 / 新建订阅。
- 编辑态的「删除」从标题栏图标改为**表单主体末尾的 error 色描边按钮**（`PiggySheetActions.kHeight` 高、`radiusLg`、`fs16/w600`），与预算 / 账户抽屉一致。
- 保存按钮不做 `_isFormValid()` 门控（必填校验交给 `Form.validate()` + `_hasAttemptedSave`），并新增 `_saving` 忙碌态（`confirmBusy`，防连点）。

**验收**：抽屉契约测试 `test/widgets/recurring_form_drawer_test.dart` 覆盖三条入口（列表「+」/ 列表条目 / 订阅条目）——都断言出现 `PiggyFormSheet`、出现居中标题与「取消｜保存」，编辑态出现主体内「删除」按钮。

### 4.7 工程门禁

- `flutter analyze --fatal-infos` 零 error / 零 warning / 零 info。
- `flutter gen-l10n` 通过；四份 arb（`app_en.arb` 模板 / `app_zh.arb` / `app_zh_TW.arb` / `app_ko.arb`）键齐全。
- 新增单测全绿，且不破坏同步契约守门测试（`test/cloud/sync_contract_coverage_test.dart`）。

## 5. 验收检查表（Done 定义）

- [ ] 订阅页可从「自动化」页进入，汇总卡数值与手工折算一致
- [ ] 订阅页空态与跳转创建入口可用
- [ ] 周期账单新建/编辑走表单抽屉（三个入口），编辑态删除按钮在表单主体内
- [ ] 到期提醒：新/改/启停/删模板后调度一致；启动与前台恢复后调度仍在；开关关闭即清空 3000 段
- [ ] 超支提醒：超支推一次、同周期不重复、跨周期可再推、开关关闭短路
- [ ] 两个开关在设置页可见可切，且配置导出/导入往返一致
- [ ] 无 schema 变更、无新依赖、同步契约测试未受影响
- [ ] 四语言文案齐全，无硬编码面向用户字符串
