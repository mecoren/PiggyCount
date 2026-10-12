# 工程债清理批次（2026-10-12）— 设计文档

需求见同目录 `requirements.md`。行号基于 2026-10-12 代码状态。

## 一、R1 守门测试：扫描范围与白名单

**测试文件**：`test/utils/platform_info_purity_test.dart`（新）。

**扫描范围**：`lib/**/*.dart` 与 `packages/**/*.dart`（排除 `.g.dart` / `.freezed.dart`
生成物——它们不含平台判断；排除测试目录自身）。

**断言**：正则 `\bPlatform\.(isIOS|isAndroid|isWindows|isLinux|isMacOS|isFuchsia)\b`
在以下文件外零命中：

- `lib/utils/platform_info.dart`（抽象自身的实现，允许）；
- 白名单显式列名的文件（每条附理由，评审时逐条过）。

**当前唯一候选白名单**：`lib/services/update/update_permissions.dart:28-30` 的
`Platform.version`（Android API 级判定）——注意它用的是 `Platform.version` 不是
`Platform.isX`，正则本就抓不到，**所以白名单可能为空**。若为空，测试就断言
「除 platform_info.dart 外全库零命中」，这是最强的形态；`PlatformInfo` 缺的能力
（如 API 级判定）记为后续项，不在本批次扩 `PlatformInfo` 面——扩了就得给桌面 /
web 语义，超出清理批次范围。

**为什么值得一个测试**：`Platform.is` 是会被悄悄用回去的（`dart:io` 的引力），
`contrast_token_test` / `font_size_token_ratchet_test` 已确立「源码扫描 + CI 常驻」
范式，本测试是同一范式在平台抽象上的复制，边际成本接近零。

## 二、R2 壳页面清理的连带面

### automation_page 删除

- 删除 `lib/pages/settings/automation_page.dart`。
- `lib/pages/main/mine_page.dart:404-414` 的「自动化功能」`SettingsNavItem`
  （→ AutomationPage）改为直接放「记账提醒」`SettingsNavItem`
  （icon `Icons.notifications_outlined`，title 复用 `l10n.reminderSettingsTitle`
  或既有提醒键——实施时以 l10n 现有键为准，不新造）。
- l10n：`automationPageTitle`（若有）、`automation` 键在四个 arb 中删除
  （先 grep 确认无其他引用；`mineAutomation*` 之类的 section 标题键保留，
  它现在装的就是记账提醒）。
- 风险点：`test/pages/` 或 deep link 测试若有 push AutomationPage 的用例，
  改道为直接断言 mine_page 入口存在。

### app_icon_page 删除

- 删除 `lib/pages/settings/app_icon_page.dart`。
- `lib/pages/settings/about_page.dart:204-215` 的入口整块移除。
- l10n：该页 title 用的是 `l10n.appName`（无专属键），**无键可删**；
  确认 `about_page` 无其他引用残留。
- `PiggyIcon`（`lib/widgets/biz/piggy_icon.dart`）是共用组件，**不动**。
- 决策记录：应用图标切换是「未来功能」，没做就不放入口；哪天做多图标
  （Android alternate + iOS Alternate Icons 需 platform channel），
  在 about_page 重新加入口，PRD 另立。

## 三、R3 测试补强的选路规则

实施时先 grep `test/pages/` 与 `test/services/`：

- 若「新建支出 → 首页列表可见」已覆盖 → 改补「编辑已存在交易 → 保存 → 列表与统计
  刷新」路径（这条目前只有 `recent_entry_inherit_test.dart` 的继承窗口侧面覆盖）。
- 若两条都已覆盖 → 补「回收站恢复 → 交易回到列表」的页面级路径
  （F1-a 的 `recycle_bin_round_trip_test.dart` 是 repository 级，页面级无人守）。

选定后照 `recent_entry_inherit_test.dart` 的基建：`PiggyDatabase.forTesting(
NativeDatabase.memory())` + `ProviderScope(overrides:)` + `MaterialApp(locale: zh)` +
**固定时长 pump**（LoggerService 2s 节流定时器让 `pumpAndSettle` 不收敛，
385-388 行有记录，新测试照抄该手法）。

## 四、R4 文档更正的精确落点

| 文件 | 行 | 改法 |
|---|---|---|
| `prd/README.md` | 96 | 「测了没改」段改写为「已改到位（2026-09-19 后，`tokens.dart:196-198` + 双门禁）」，从 5 余量中移除对比度半句，保留真机无障碍三条 |
| `prd/README.md` | 99 | 「剩 27 处」改为「已清零（2026-10-12 核实），新增 `platform_info_purity_test.dart` 守门防复发」 |
| `prd/README.md` | 13 | `subscription_and_overspend_alerts` 状态「实施中」→「已落地」 |
| `prd/ui_consistency_optimization/requirements.md` | 68 | U2-b 行「测了没改」→「已改到位」，证据列补 `contrast_token_test.dart` |
| `prd/README.md` | 新增节 | 「本轮（2026-10-12）」两行：F1-b（`refund_reimbursement`，实施中）+ 本批次 |

## 五、批次边界（防范围蔓延）

本批次全部项满足：**不动数据模型、不动同步契约、不动协议**。任何实施中发现的
「顺手能改」若不满足这三条，记入 `docs/` 后续项，不夹带——这是
`transaction_model_completion/design.md` §五定下的硬约束，本批次继承。
