# 小猪粉主题与 UI 精修 - 需求文档

## 背景

用户提出 3 项 UI 改造需求，围绕主题色体系、设置页视觉、开关组件、悬浮按钮的整体精修。本次改造需与既有 `titlebar_glass_unification`、`settings_ui_redesign` 决策兼容，不破坏已统一的玻璃标题栏架构。

## 需求清单

### 需求 1：ProfileCard 标题化 + 设置页标题去玻璃 + 开关全面替换

#### 1a. 我的页 ProfileCard 改为「标题式」总计卡

- **现状**：[ProfileCard](../../lib/widgets/biz/profile_card.dart) 顶部为头像 + 问候语，下方三列等权统计（记账天数 / 总笔数 / 账本结余），「账本结余」无标题强调。
- **目标**：参照资产页（[accounts_page.dart](../../lib/pages/account/accounts_page.dart) `_buildNetWorthContent`）的「净资产」标题式结构——小字标签 + 大号金额，将 ProfileCard 的「账本结余」提升为标题式展示，使「总计」成为卡片视觉主体。
- **要点**：
  - 顶部增加小字标题标签（如「账本结余」/「我的资产」），样式对齐资产页 `accountTotalBalance` 标签（12pt、`textTertiary` 色）。
  - 结余金额改为大号加粗展示（对齐资产页 28pt bold 风格，可按卡片比例微调）。
  - 记账天数 / 总笔数作为次要统计保留在下方。
  - 头像、问候语、小眼睛隐藏金额等既有功能 100% 保留。

#### 1b. 设置中的其他页面标题不要玻璃效果

- **现状**：20 个设置子页（[lib/pages/settings/*](../../lib/pages/settings/)）统一使用 `GlassTitleBar`（毛玻璃模糊）。
- **目标**：设置子页标题栏改为纯色实底（无毛玻璃），保留返回键 / 标题 / actions 布局不变。
- **范围**：`lib/pages/settings/` 下 20 处 `GlassTitleBar` 调用 + `personalize_page.dart`。

#### 1c. 按钮开关参考 wait-home 设计，全面替换

- **现状**：[SettingsToggleItem](../../lib/widgets/biz/settings_widgets.dart) 使用 `Switch.adaptive`（iOS 端为 CupertinoSwitch，视觉偏大）；另有 4 处页面直接使用 `Switch` / `Switch.adaptive`。
- **目标**：参照外部项目 `wait-home` 的 `app_theme.dart` 的 `switchTheme`：无描边、选中纯色轨道、白色 thumb；并缩小触控尺寸（`shrinkWrap`），视觉更紧凑。
- **范围**（全量替换）：
  - `lib/widgets/biz/settings_widgets.dart`（SettingsToggleItem）
  - `lib/pages/transaction/recurring_transaction_page.dart`
  - `lib/pages/automation/auto_billing_settings_page.dart`
  - `lib/pages/settings/app_lock_settings_page.dart`
  - `lib/pages/budget/budget_page.dart`
  - `lib/pages/cloud/cloud_service_page.dart`
  - `lib/pages/settings/reminder_settings_page.dart`
  - `lib/pages/settings/smart_billing_page.dart`（2 处）

### 需求 2：主题色新增「小猪粉」为默认 + 调整前三个顺序

- **现状**：[personalize_page.dart](../../lib/pages/settings/personalize_page.dart) 主题色列表第一项为「蜜蜂黄」，[primaryColorProvider](../../lib/providers/theme_providers.dart) 默认值为「晴空蓝」#2196F3。
- **目标**：
  1. 新增「小猪粉」主题色，置于列表**第一位**且作为**新默认值**。
  2. 第二位「晴空蓝」#2196F3（沿用现有 `personalizeThemeBlue`）。
  3. 第三位「渐变蓝」（新增，纯色，仅名字叫渐变蓝）。
  4. 其余既有主题色顺序保留，顺延排在三者之后。
- **默认值变更**：`primaryColorProvider` 默认值由 #2196F3 改为小猪粉。已保存偏好的老用户保留其选择；未保存偏好的用户（含新用户）走小猪粉默认。
- **本地化**：新增 `personalizeThemePiggyPink`、`personalizeThemeGradientBlue` 两条文案（zh / en / zh_TW / ko）。

### 需求 3：右下角按钮改为玻璃质感「记账」按钮（保持 debug-only）

- **现状**：[app.dart](../../lib/app.dart) 第 957-982 行，`kDebugMode` 下右下角 `FloatingActionButton.small`，点击切换亮/暗主题。
- **目标**：改为玻璃质感「记账」按钮：
  - 图标与文字与底部菜单栏中间记账按钮一致：`Icons.add_circle_outline`（22px）+ `l10n.tabRecord` 文案（10px）。
  - 玻璃质感背景（`BackdropFilter` 模糊 + 半透明 + 圆角）。
  - 点击行为：调用 `showTransactionFormBottomSheet`（与底部中间记账按钮一致）。
  - **保持 `kDebugMode` 限定**（release 不显示）。

## 验收标准

- [ ] ProfileCard 顶部出现标题式结余展示，视觉对齐资产页「净资产」结构。
- [ ] 20 个设置子页标题栏为纯色实底，无毛玻璃模糊。
- [ ] 全 App 开关视觉统一、紧凑（无描边、选中主题色轨道、白色 thumb），iOS/Android 一致。
- [ ] 主题色列表前三为：小猪粉（默认）/ 晴空蓝 / 渐变蓝；新用户默认小猪粉。
- [ ] debug 模式下右下角为玻璃记账按钮，点击弹出记账表单；release 不显示。
- [ ] `flutter analyze` 0 errors。
- [ ] 亮/暗主题下视觉均正确。
