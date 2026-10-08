# piggycount

‍

好的，我来系统地检查 PiggyCount 项目的 UI 一致性。先了解项目的结构和主题设置。  
我来全面探索这个项目的 UI 系统和主题架构。先并行执行多个搜索任务。  
我来全面探索这个项目的 UI 系统和主题架构。先并行执行多个搜索任务。  
首先并行执行多个搜索任务：  
首先并行执行多个搜索任务：  
找到关键文件了，现在并行读取所有重要文件和搜索：  
找到关键文件了，现在并行读取所有重要文件和搜索：  
让我获取目录结构和剩余关键文件：  
让我获取目录结构和剩余关键文件：  
让我用 PowerShell 获取目录结构，并读取关键文件：  
让我用 PowerShell 获取目录结构，并读取关键文件：  
让我再获取几个补充信息：  
让我再获取几个补充信息：  
我已收集到足够的信息。让我现在做最后的整理，完成这个任务报告。  
我已收集到足够的信息。让我现在做最后的整理，完成这个任务报告。  
以下是 PiggyCount Flutter 项目的 **UI 系统和主题架构** 全面分析报告。

---

## 一、项目结构总览

### lib/ 下的顶层目录（根据 Glob 结果推断）

根据所有文件路径分析，`lib/` 下的目录结构如下：

|目录/文件|说明|
| ---------------| --------------------------------------------------------------------------------------|
|`lib/main.dart`|应用入口，配置 MaterialApp、主题|
|`lib/app.dart`|主应用页面（BeeApp），底部导航、深链处理|
|`lib/theme.dart`|核心主题定义（BeeTheme），亮/暗主题|
|`lib/theme.dart`​ \| `lib/styles/`|主题 + 样式系统|
|`lib/styles/tokens.dart`|**Design Token 系统** — BeeTokens、BeeTextTokens、BeeTypography|
|`lib/styles/header_skins/`|头部皮肤系统（~19种装饰皮肤）|
|`lib/providers/`|Riverpod 状态管理|
|`lib/providers/theme_providers.dart`|主题相关 Provider|
|`lib/pages/`|页面层（auth, main, settings, account, category, budget, transaction, ai, cloud 等）|
|`lib/widgets/`|复用组件库|
|`lib/widgets/ui/`|**UI 基础组件**（通用UI组件）|
|`lib/widgets/biz/`|**业务组件**（业务相关）|
|`lib/widgets/analytics/`|分析图表组件|
|`lib/widgets/ai/`|AI 相关组件|
|`lib/widgets/category/`|分类组件|
|`lib/widgets/charts/`|图表组件|
|`lib/widgets/currency/`|币种组件|
|`lib/widgets/posters/`|海报组件|
|`lib/widgets/transaction/`|交易组件|
|`lib/data/`|数据层（数据库、仓库）|
|`lib/models/`|数据模型|
|`lib/cloud/`|云同步|
|`lib/l10n/`|国际化|
|`lib/services/`|服务层|
|`lib/utils/`|工具类|
|`lib/widget/`|桌面小组件（不同于 widgets/）|

---

## 二、核心主题系统架构

### 1. `lib/theme.dart` — BeeTheme 类（核心主题定义）

**文件路径**: `lib/theme.dart`

定义品牌色和亮/暗两套 `ThemeData`：

```dart
class BeeTheme {
  // 品牌色（亮色模式）
  static const Color honeyGold = Color(0xFFF8C91C);      // 主色
  static const Color hiveBrown = Color(0xFF8D6E63);      // 辅助色
  static const Color energyOrange = Color(0xFFEF6C00);   // 点缀色
  static const Color paperIvory = Color(0xFFFFF8E1);     // 背景
  static const Color textDark = Color(0xFF333333);        // 文字
  
  // 暗黑模式品牌色（与亮色模式保持一致）
  static const Color honeyGoldDark = honeyGold;
  static const Color hiveBrownDark = hiveBrown;
  static const Color energyOrangeDark = energyOrange;

  static ThemeData lightTheme({TargetPlatform? platform}) { ... }
  static ThemeData darkTheme({TargetPlatform? platform}) { ... }
}
```

**亮色主题** `lightTheme` 的关键配置：

- `colorScheme.primary: honeyGold`​, `secondary: energyOrange`​, `surface: Colors.white`
- `scaffoldBackgroundColor: paperIvory` (0xFFFFF8E1)
- AppBar: 白色背景，0.0 阴影，居中标题
- FAB: 金色背景
- BottomNav: 橙色选中，灰色未选中，透明背景（悬浮胶囊样式）

**暗黑主题** `darkTheme` 的关键配置（注意带有 ⭐ 注释）：

- `scaffoldBackgroundColor: Colors.black`（纯黑，OLED 友好）
- 卡片: `color: Colors.black`​ + `white 10% 边框`
- 分割线: `white 12% 透明度`
- 图标/文字: 白色

### 2. `lib/styles/tokens.dart` — Design Token 系统

**文件路径**: `lib/styles/tokens.dart`

这是一个完整的 **Design Token 系统**，包含以下 Token 类：

|类名|功能|
| ------| ------------------------------------------------------------------------------------------------------------------|
|`BeeTokens`|颜色 Token（~50+ 方法）：Surface、Text、Icon、Border、Card、Semantic、Interactive、Brand、Chart、Overlay、TabBar|
|`BeeDimens`|尺寸 Token：间距、圆角|
|`BeeShadows`|阴影 Token|
|`BeeDivider`|分割线组件 Token|
|`BeeChartTokens`|图表 Token|
|`BeeTextTokens`|文本样式 Token（title, strongTitle, boldTitle, body, label）|
|`BeeTypography`|字体配置 Token（字体系列、fontFamilyFallback）|

Token 分类摘要：

```
BeeTokens 包含 12 类颜色 Token：
1. Surface — scaffoldBackground, surface, surfaceSecondary, surfaceElevated, surfaceHeader, surfaceSheet, surfaceKey, surfaceInput, surfaceChip, surfaceCapsule, surfacePopoverCard, surfaceCategoryIcon, surfaceSelected, surfaceHover
2. Text — textPrimary, textSecondary, textTertiary, textDisabled, textOnPrimary, textLink, textOnHeader, textOnHeaderSecondary
3. Icon — iconPrimary, iconSecondary, iconTertiary
4. Border/Divider — divider, border, borderStrong, borderThemed
5. Card — cardOuterBorderColor, cardInnerDividerColor, cardDivider widget
6. Theme — primary, secondary
7. Semantic — success, warning, error, info
8. Interactive — buttonPrimary, buttonSecondary, buttonPrimaryText, buttonSecondaryText, buttonDisabled, switchActiveTrack, switchInactiveTrack
9. Brand — brandLocal, brandSupabase, brandWebdav, brandIcloud, brandS3, brandCloud
10. Chart — chartIncome, chartExpense, chartTransfer, incomeColor, expenseColor
11. Overlay — overlay, overlayLight
12. TabBar — tabBarBackground, tabBarShadow
```

所有 Token 方法都接受 `BuildContext`​，内部判断 `isDark(context)` 自动适配明暗。

### 3. `lib/main.dart` — 主题组装和 MaterialApp 配置

**文件路径**: `lib/main.dart`

在 `build()` 方法中，主题的组装流程是：

```dart
final primary = ref.watch(primaryColorProvider);   // 动态主题色
final base = BeeTheme.lightTheme(platform: platform);
final theme = base.copyWith(
  colorScheme: base.colorScheme.copyWith(primary: primary),
  primaryColor: primary,
  // 额外覆盖: ListTile, Dialog, TextButton, FilledButton, FAB, BottomNav, Card 等主题
);
// 返回 MaterialApp
MaterialApp(
  theme: theme,                                           // 亮色主题
  darkTheme: BeeTheme.darkTheme(...).copyWith(...),       // 暗黑主题
  themeMode: ref.watch(themeModeProvider),                // 动态模式切换
)
```

**关键发现**：`main.dart`​ 中的 `theme`​ 会覆盖 `BeeTheme.lightTheme`​ 中已经定义的部分样式（如 scaffoldBackgroundColor, colorScheme 等），存在一定程度的重叠定义。例如 `scaffoldBackgroundColor: Colors.white`​（main.dart）覆盖了 `paperIvory`（theme.dart）。

---

## 三、主题状态管理（Riverpod Provider）

### `lib/providers/theme_providers.dart`

**文件路径**: `lib/providers/theme_providers.dart`

|Provider|类型|默认值|用途|
| ----------| ------| --------| -----------------------------------|
|`themeModeProvider`|`StateProvider<ThemeMode>`|`ThemeMode.system`|主题模式（system/light/dark）|
|`themeModeInitProvider`|`FutureProvider<void>`|—|持久化 + 加载主题模式|
|`primaryColorProvider`|`StateProvider<Color>`|`BeeTheme.honeyGold`|可变主色（个性化换装）|
|`primaryColorInitProvider`|`FutureProvider<void>`|—|持久化 + 加载主色 + 推送到云|
|`headerDecorationStyleProvider`|`StateProvider<String>`|`'icons'`|Header装饰样式|
|`headerSkinProvider`|`StateProvider<String>`|`'none'`|头部皮肤|
|`hideAmountsProvider`|`StateProvider<bool>`|`false`|隐私模式|
|`compactAmountProvider`|`StateProvider<bool>`|`false`|金额简洁显示|
|`showTransactionTimeProvider`|`StateProvider<bool>`|`false`|显示交易时间|
|`incomeExpenseColorSchemeProvider`|`StateProvider<bool>`|`true`|收支配色方案（红收绿支/绿收红支）|
|`noteDisplayModeProvider`|`StateProvider<String>`|`'category'`|备注显示方式|

**重要架构特点**：主题色变更会通过 `primaryColorInitProvider` 的监听器自动推送到 PiggyCount Cloud，实现移动端 → Web 端实时同步。

---

## 四、Theme.of(context) / ThemeData 引用分布

共搜索到 **数百处引用**，分布在几乎所有页面和组件文件中。按文件分类：

|目录|引用密度|典型用法|
| -------------------| ----------| -----------------|
|`lib/pages/transaction/`|高|`Theme.of(context).colorScheme.primary`​, `.textTheme`|
|`lib/pages/category/`|高|`.colorScheme.primary`​, `.surface`​, `.outline`|
|`lib/pages/main/` (home, mine)|极高|`.brightness`​, `.colorScheme.primary`​, `.scaffoldBackgroundColor`|
|`lib/pages/settings/`|中|`.textTheme`​, `.colorScheme`|
|`lib/pages/account/`|高|`.primaryColor`​, `.colorScheme`|
|`lib/widgets/biz/`|极高|`.colorScheme.primary`​, `.textTheme`​, `.brightness`|
|`lib/widgets/ui/`|中|`.primaryColor`​, `.colorScheme`|
|`lib/styles/tokens.dart`|核心|`Theme.of(context).colorScheme.primary` 引用最密集|

**值得注意的模式**：

1. 大量使用 `Theme.of(context).colorScheme.primary`​ —— 这些地方实际上已经可以通过 `BeeTokens.primary(context)` 替代（统一走 Token 系统）
2. 部分早期代码仍直接使用 `Colors.red`​, `Colors.green` 等硬编码颜色，而不是通过语义 Token
3. `home_page.dart`​ 中大量使用 `isDark` 变量做条件颜色（约20+处），应该用 Token 替代

---

## 五、自定义颜色使用情况（Color(0x / Colors.）

搜索到 **数百处** 直接使用 `Color(0x...)`​ 或 `Colors.xxx` 的地方：

**主要发现的硬编码颜色模式**：

1. **品牌色（可接受）** ：

   - `Color(0xFFF8C91C)` — honeyGold（主题色）
   - `Color(0xFFF59E0B)`​, `Color(0xFFF97316)` — 警告/点缀色
   - `Color(0xFF4CAF50)`​ / `Color(0xFFFF5252)` — 收入/支出（annual_report_page）
2. **非品牌硬编码颜色（需注意）** ：

   - `Colors.red`​, `Colors.green`​, `Colors.orange` — 大量的硬编码语义色
   - `Colors.black.withOpacity(0.06)`​ — 分割线（应使用 `BeeTokens.divider(context)`）
   - `Colors.black54`​, `Colors.white70`​ — 文字透明度（应使用 `BeeTokens.textSecondary(context)`）
3. **​`styles/tokens.dart`​**​ **中定义的**：

   - 暗色系：`Color(0xFF1C1C1E)`​, `Color(0xFF2C2C2E)`​, `Color(0xFF3C3C3E)`​, `Color(0xFF3A3A3C)` 等
   - 品牌色：`Color(0xFF9E9E9E)`​ (local), `Color(0xFF3ECF8E)` (supabase) 等

---

## 六、pubspec.yaml 主题相关依赖

**文件路径**: `pubspec.yaml`

项目没有直接的主题/UI组件库依赖。主题相关的间接依赖：

```yaml
dependencies:
  flutter_riverpod: ^2.5.1       # 状态管理（主题状态）
  shared_preferences: ^2.3.2     # 主题持久化
  home_widget: ^0.9.2            # 桌面小组件（widget_manager）
  flutter_ai_kit: (path)         # AI 能力包（无主题影响）
  flutter_cloud_sync: (path)     # 云同步（无主题影响）
```

使用了 Material Design (`uses-material-design: true`)，无第三方 UI 库依赖。

字体已从打包字体切换为系统字体（注释掉的 Inter + NotoSansSC）。

---

## 七、统一 Widget 组件库

项目有**完善的复用组件体系**：

### 1. `lib/widgets/ui/` — 通用 UI 基础组件（7个组件）

|文件|组件|用途|
| ------| -----------------| ----------------|
|`ui.dart`|barrel 导出|统一导出入口|
|`primary_header.dart`|PrimaryHeader|页面顶部栏|
|`dialog.dart`|—|通用对话框|
|`toast.dart`|—|Toast 提示|
|`skeleton.dart`|—|骨架屏|
|`wheel_picker.dart`|—|滚轮选择器|
|`wheel_date_picker.dart`|—|滚轮日期选择器|
|`wheel_time_picker.dart`|—|滚轮时间选择器|
|`searchable_dropdown.dart`|—|可搜索下拉框|
|`message_popover_menu.dart`|—|消息弹出菜单|
|`bee_popup_menu.dart`|—|弹出菜单|
|`capsule_switcher.dart`|CapsuleSwitcher|胶囊切换器|
|`speed_dial_fab.dart`|SpeedDialAction|快速拨号FAB|

### 2. `lib/widgets/biz/` — 业务组件（~20个组件）

|文件|组件|
| ------| ----------------|
|`biz.dart`|barrel 导出|
|`amount_text.dart`|金额文本|
|`amount_editor_sheet.dart`|金额编辑弹窗|
|`section_card.dart`|分组卡片|
|`app_list_tile.dart`|列表项组件|
|`app_empty.dart`|空状态组件|
|`transaction_list_item.dart`|交易列表项|
|`transaction_list.dart`|交易列表|
|`day_section_header.dart`|日分组头|
|`account_picker.dart`|账户选择器|
|`category_selector_dialog.dart`|分类选择对话框|
|`tag_chip.dart`|标签 Chip|
|`note_picker_dialog.dart`|备注选择对话框|
|`pin_entry_pad.dart`|PIN 输入面板|
|`bee_icon.dart`|图标组件|
|`info_tag.dart`|信息标签|
|`ledger_card.dart`|账本卡片|
|`product_promo_card.dart`|产品推广卡片|
|`login_2fa_challenge_view.dart`|2FA 验证视图|
|`attachment_picker.dart`|附件选择器|

### 3. `lib/widgets/charts/` — 图表组件

- `category_pie_chart.dart`​, `account_category_pie_chart.dart`
- `asset_composition_chart.dart`​, `balance_trend_chart.dart`​, `line_chart.dart`

### 4. 其他组件目录

- `widgets/analytics/` — 分析相关
- `widgets/ai/` — AI 相关
- `widgets/category/` — 分类选择器
- `widgets/currency/` — 币种选择
- `widgets/posters/` — 海报生成
- `widgets/transaction/` — 交易表单

### 5. 组件引用关系

- `ui/ui.dart`​ 统一导出供 `widgets/biz/` 等使用
- `biz/biz.dart`​ 统一导出供 `pages/` 使用
- 部分组件（如 `category_icon.dart`​, `measure_size.dart`​）位于 `widgets/` 根目录

---

## 八、关键发现总结

### 主题架构是**三层结构**：

```
┌──────────────────────────────────────────────────────┐
│ 第1层: BeeTokens (styles/tokens.dart)                │
│ Design Token 系统 — 所有颜色的唯一来源                │
│ 用法: BeeTokens.surface(context), BeeTokens.textPrimary(context) │
├──────────────────────────────────────────────────────┤
│ 第2层: BeeTheme (theme.dart) + main.dart 叠加       │
│ Flutter ThemeData 定义 — lightTheme / darkTheme      │
│ main.dart 中通过 copyWith 覆盖 theme.dart 的部分值   │
├──────────────────────────────────────────────────────┤
│ 第3层: theme_providers.dart (Riverpod)               │
│ 动态主题状态 — 主题模式、主色、皮肤等                 │
│ 支持跨设备同步 (PiggyCount Cloud)                      │
└──────────────────────────────────────────────────────┘
```

### 值得关注的 UI 一致性问题：

1. **​`theme.dart`​**​ **与** **​`main.dart`​**​ **有重叠定义**：`scaffoldBackgroundColor`​ 在 `BeeTheme.lightTheme`​ 中设为 `paperIvory`​，但在 `main.dart`​ 的 `theme.copyWith`​ 中又设为 `Colors.white`。
2. **硬编码颜色散布**：虽然已有 Token 系统，但许多页面仍直接使用 `Colors.red`​ / `Colors.green`​ / `Colors.orange`​ 等硬编码（如 `annual_report_page.dart`​ 中反复出现的 `Color(0xFF4CAF50)`​ 和 `Color(0xFFFF5252)`）。
3. **​`isDark`​**​ **条件判断散布**：`home_page.dart`​ 等文件中大量使用 `final isDark = Theme.of(context).brightness == Brightness.dark` 后做条件颜色，这些本应通过 Token 系统封装。
4. **Theme.of(context) 与 BeeTokens 并存**：部分新代码使用 `BeeTokens.primary(context)`​，但大量代码仍使用 `Theme.of(context).colorScheme.primary`，两者指向不同值（Token 系统强，Theme 弱）。
5. **组件库完善但使用不一致**：有 `PrimaryHeader`​、`SectionCard`​、`AppListTile`​ 等统一组件，但部分页面仍自己构建类似布局。以下是 PiggyCount Flutter 项目的 **UI 系统和主题架构** 全面分析报告。

---

## 一、项目结构总览

### lib/ 下的顶层目录（根据 Glob 结果推断）

根据所有文件路径分析，`lib/` 下的目录结构如下：

|目录/文件|说明|
| ---------------| --------------------------------------------------------------------------------------|
|`lib/main.dart`|应用入口，配置 MaterialApp、主题|
|`lib/app.dart`|主应用页面（BeeApp），底部导航、深链处理|
|`lib/theme.dart`|核心主题定义（BeeTheme），亮/暗主题|
|`lib/theme.dart`​ \| `lib/styles/`|主题 + 样式系统|
|`lib/styles/tokens.dart`|**Design Token 系统** — BeeTokens、BeeTextTokens、BeeTypography|
|`lib/styles/header_skins/`|头部皮肤系统（~19种装饰皮肤）|
|`lib/providers/`|Riverpod 状态管理|
|`lib/providers/theme_providers.dart`|主题相关 Provider|
|`lib/pages/`|页面层（auth, main, settings, account, category, budget, transaction, ai, cloud 等）|
|`lib/widgets/`|复用组件库|
|`lib/widgets/ui/`|**UI 基础组件**（通用UI组件）|
|`lib/widgets/biz/`|**业务组件**（业务相关）|
|`lib/widgets/analytics/`|分析图表组件|
|`lib/widgets/ai/`|AI 相关组件|
|`lib/widgets/category/`|分类组件|
|`lib/widgets/charts/`|图表组件|
|`lib/widgets/currency/`|币种组件|
|`lib/widgets/posters/`|海报组件|
|`lib/widgets/transaction/`|交易组件|
|`lib/data/`|数据层（数据库、仓库）|
|`lib/models/`|数据模型|
|`lib/cloud/`|云同步|
|`lib/l10n/`|国际化|
|`lib/services/`|服务层|
|`lib/utils/`|工具类|
|`lib/widget/`|桌面小组件（不同于 widgets/）|

---

## 二、核心主题系统架构

### 1. `lib/theme.dart` — BeeTheme 类（核心主题定义）

**文件路径**: `lib/theme.dart`

定义品牌色和亮/暗两套 `ThemeData`：

```dart
class BeeTheme {
  // 品牌色（亮色模式）
  static const Color honeyGold = Color(0xFFF8C91C);      // 主色
  static const Color hiveBrown = Color(0xFF8D6E63);      // 辅助色
  static const Color energyOrange = Color(0xFFEF6C00);   // 点缀色
  static const Color paperIvory = Color(0xFFFFF8E1);     // 背景
  static const Color textDark = Color(0xFF333333);        // 文字
  
  // 暗黑模式品牌色（与亮色模式保持一致）
  static const Color honeyGoldDark = honeyGold;
  static const Color hiveBrownDark = hiveBrown;
  static const Color energyOrangeDark = energyOrange;

  static ThemeData lightTheme({TargetPlatform? platform}) { ... }
  static ThemeData darkTheme({TargetPlatform? platform}) { ... }
}
```

**亮色主题** `lightTheme` 的关键配置：

- `colorScheme.primary: honeyGold`​, `secondary: energyOrange`​, `surface: Colors.white`
- `scaffoldBackgroundColor: paperIvory` (0xFFFFF8E1)
- AppBar: 白色背景，0.0 阴影，居中标题
- FAB: 金色背景
- BottomNav: 橙色选中，灰色未选中，透明背景（悬浮胶囊样式）

**暗黑主题** `darkTheme` 的关键配置（注意带有 ⭐ 注释）：

- `scaffoldBackgroundColor: Colors.black`（纯黑，OLED 友好）
- 卡片: `color: Colors.black`​ + `white 10% 边框`
- 分割线: `white 12% 透明度`
- 图标/文字: 白色

### 2. `lib/styles/tokens.dart` — Design Token 系统

**文件路径**: `lib/styles/tokens.dart`

这是一个完整的 **Design Token 系统**，包含以下 Token 类：

|类名|功能|
| ------| ------------------------------------------------------------------------------------------------------------------|
|`BeeTokens`|颜色 Token（~50+ 方法）：Surface、Text、Icon、Border、Card、Semantic、Interactive、Brand、Chart、Overlay、TabBar|
|`BeeDimens`|尺寸 Token：间距、圆角|
|`BeeShadows`|阴影 Token|
|`BeeDivider`|分割线组件 Token|
|`BeeChartTokens`|图表 Token|
|`BeeTextTokens`|文本样式 Token（title, strongTitle, boldTitle, body, label）|
|`BeeTypography`|字体配置 Token（字体系列、fontFamilyFallback）|

Token 分类摘要：

```
BeeTokens 包含 12 类颜色 Token：
1. Surface — scaffoldBackground, surface, surfaceSecondary, surfaceElevated, surfaceHeader, surfaceSheet, surfaceKey, surfaceInput, surfaceChip, surfaceCapsule, surfacePopoverCard, surfaceCategoryIcon, surfaceSelected, surfaceHover
2. Text — textPrimary, textSecondary, textTertiary, textDisabled, textOnPrimary, textLink, textOnHeader, textOnHeaderSecondary
3. Icon — iconPrimary, iconSecondary, iconTertiary
4. Border/Divider — divider, border, borderStrong, borderThemed
5. Card — cardOuterBorderColor, cardInnerDividerColor, cardDivider widget
6. Theme — primary, secondary
7. Semantic — success, warning, error, info
8. Interactive — buttonPrimary, buttonSecondary, buttonPrimaryText, buttonSecondaryText, buttonDisabled, switchActiveTrack, switchInactiveTrack
9. Brand — brandLocal, brandSupabase, brandWebdav, brandIcloud, brandS3, brandCloud
10. Chart — chartIncome, chartExpense, chartTransfer, incomeColor, expenseColor
11. Overlay — overlay, overlayLight
12. TabBar — tabBarBackground, tabBarShadow
```

所有 Token 方法都接受 `BuildContext`​，内部判断 `isDark(context)` 自动适配明暗。

### 3. `lib/main.dart` — 主题组装和 MaterialApp 配置

**文件路径**: `lib/main.dart`

在 `build()` 方法中，主题的组装流程是：

```dart
final primary = ref.watch(primaryColorProvider);   // 动态主题色
final base = BeeTheme.lightTheme(platform: platform);
final theme = base.copyWith(
  colorScheme: base.colorScheme.copyWith(primary: primary),
  primaryColor: primary,
  // 额外覆盖: ListTile, Dialog, TextButton, FilledButton, FAB, BottomNav, Card 等主题
);
// 返回 MaterialApp
MaterialApp(
  theme: theme,                                           // 亮色主题
  darkTheme: BeeTheme.darkTheme(...).copyWith(...),       // 暗黑主题
  themeMode: ref.watch(themeModeProvider),                // 动态模式切换
)
```

**关键发现**：`main.dart`​ 中的 `theme`​ 会覆盖 `BeeTheme.lightTheme`​ 中已经定义的部分样式（如 scaffoldBackgroundColor, colorScheme 等），存在一定程度的重叠定义。例如 `scaffoldBackgroundColor: Colors.white`​（main.dart）覆盖了 `paperIvory`（theme.dart）。

---

## 三、主题状态管理（Riverpod Provider）

### `lib/providers/theme_providers.dart`

**文件路径**: `lib/providers/theme_providers.dart`

|Provider|类型|默认值|用途|
| ----------| ------| --------| -----------------------------------|
|`themeModeProvider`|`StateProvider<ThemeMode>`|`ThemeMode.system`|主题模式（system/light/dark）|
|`themeModeInitProvider`|`FutureProvider<void>`|—|持久化 + 加载主题模式|
|`primaryColorProvider`|`StateProvider<Color>`|`BeeTheme.honeyGold`|可变主色（个性化换装）|
|`primaryColorInitProvider`|`FutureProvider<void>`|—|持久化 + 加载主色 + 推送到云|
|`headerDecorationStyleProvider`|`StateProvider<String>`|`'icons'`|Header装饰样式|
|`headerSkinProvider`|`StateProvider<String>`|`'none'`|头部皮肤|
|`hideAmountsProvider`|`StateProvider<bool>`|`false`|隐私模式|
|`compactAmountProvider`|`StateProvider<bool>`|`false`|金额简洁显示|
|`showTransactionTimeProvider`|`StateProvider<bool>`|`false`|显示交易时间|
|`incomeExpenseColorSchemeProvider`|`StateProvider<bool>`|`true`|收支配色方案（红收绿支/绿收红支）|
|`noteDisplayModeProvider`|`StateProvider<String>`|`'category'`|备注显示方式|

**重要架构特点**：主题色变更会通过 `primaryColorInitProvider` 的监听器自动推送到 PiggyCount Cloud，实现移动端 → Web 端实时同步。

---

## 四、Theme.of(context) / ThemeData 引用分布

共搜索到 **数百处引用**，分布在几乎所有页面和组件文件中。按文件分类：

|目录|引用密度|典型用法|
| -------------------| ----------| -----------------|
|`lib/pages/transaction/`|高|`Theme.of(context).colorScheme.primary`​, `.textTheme`|
|`lib/pages/category/`|高|`.colorScheme.primary`​, `.surface`​, `.outline`|
|`lib/pages/main/` (home, mine)|极高|`.brightness`​, `.colorScheme.primary`​, `.scaffoldBackgroundColor`|
|`lib/pages/settings/`|中|`.textTheme`​, `.colorScheme`|
|`lib/pages/account/`|高|`.primaryColor`​, `.colorScheme`|
|`lib/widgets/biz/`|极高|`.colorScheme.primary`​, `.textTheme`​, `.brightness`|
|`lib/widgets/ui/`|中|`.primaryColor`​, `.colorScheme`|
|`lib/styles/tokens.dart`|核心|`Theme.of(context).colorScheme.primary` 引用最密集|

**值得注意的模式**：

1. 大量使用 `Theme.of(context).colorScheme.primary`​ —— 这些地方实际上已经可以通过 `BeeTokens.primary(context)` 替代（统一走 Token 系统）
2. 部分早期代码仍直接使用 `Colors.red`​, `Colors.green` 等硬编码颜色，而不是通过语义 Token
3. `home_page.dart`​ 中大量使用 `isDark` 变量做条件颜色（约20+处），应该用 Token 替代

---

## 五、自定义颜色使用情况（Color(0x / Colors.）

搜索到 **数百处** 直接使用 `Color(0x...)`​ 或 `Colors.xxx` 的地方：

**主要发现的硬编码颜色模式**：

1. **品牌色（可接受）** ：

   - `Color(0xFFF8C91C)` — honeyGold（主题色）
   - `Color(0xFFF59E0B)`​, `Color(0xFFF97316)` — 警告/点缀色
   - `Color(0xFF4CAF50)`​ / `Color(0xFFFF5252)` — 收入/支出（annual_report_page）
2. **非品牌硬编码颜色（需注意）** ：

   - `Colors.red`​, `Colors.green`​, `Colors.orange` — 大量的硬编码语义色
   - `Colors.black.withOpacity(0.06)`​ — 分割线（应使用 `BeeTokens.divider(context)`）
   - `Colors.black54`​, `Colors.white70`​ — 文字透明度（应使用 `BeeTokens.textSecondary(context)`）
3. **​`styles/tokens.dart`​**​ **中定义的**：

   - 暗色系：`Color(0xFF1C1C1E)`​, `Color(0xFF2C2C2E)`​, `Color(0xFF3C3C3E)`​, `Color(0xFF3A3A3C)` 等
   - 品牌色：`Color(0xFF9E9E9E)`​ (local), `Color(0xFF3ECF8E)` (supabase) 等

---

## 六、pubspec.yaml 主题相关依赖

**文件路径**: `pubspec.yaml`

项目没有直接的主题/UI组件库依赖。主题相关的间接依赖：

```yaml
dependencies:
  flutter_riverpod: ^2.5.1       # 状态管理（主题状态）
  shared_preferences: ^2.3.2     # 主题持久化
  home_widget: ^0.9.2            # 桌面小组件（widget_manager）
  flutter_ai_kit: (path)         # AI 能力包（无主题影响）
  flutter_cloud_sync: (path)     # 云同步（无主题影响）
```

使用了 Material Design (`uses-material-design: true`)，无第三方 UI 库依赖。

字体已从打包字体切换为系统字体（注释掉的 Inter + NotoSansSC）。

---

## 七、统一 Widget 组件库

项目有**完善的复用组件体系**：

### 1. `lib/widgets/ui/` — 通用 UI 基础组件（7个组件）

|文件|组件|用途|
| ------| -----------------| ----------------|
|`ui.dart`|barrel 导出|统一导出入口|
|`primary_header.dart`|PrimaryHeader|页面顶部栏|
|`dialog.dart`|—|通用对话框|
|`toast.dart`|—|Toast 提示|
|`skeleton.dart`|—|骨架屏|
|`wheel_picker.dart`|—|滚轮选择器|
|`wheel_date_picker.dart`|—|滚轮日期选择器|
|`wheel_time_picker.dart`|—|滚轮时间选择器|
|`searchable_dropdown.dart`|—|可搜索下拉框|
|`message_popover_menu.dart`|—|消息弹出菜单|
|`bee_popup_menu.dart`|—|弹出菜单|
|`capsule_switcher.dart`|CapsuleSwitcher|胶囊切换器|
|`speed_dial_fab.dart`|SpeedDialAction|快速拨号FAB|

### 2. `lib/widgets/biz/` — 业务组件（~20个组件）

|文件|组件|
| ------| ----------------|
|`biz.dart`|barrel 导出|
|`amount_text.dart`|金额文本|
|`amount_editor_sheet.dart`|金额编辑弹窗|
|`section_card.dart`|分组卡片|
|`app_list_tile.dart`|列表项组件|
|`app_empty.dart`|空状态组件|
|`transaction_list_item.dart`|交易列表项|
|`transaction_list.dart`|交易列表|
|`day_section_header.dart`|日分组头|
|`account_picker.dart`|账户选择器|
|`category_selector_dialog.dart`|分类选择对话框|
|`tag_chip.dart`|标签 Chip|
|`note_picker_dialog.dart`|备注选择对话框|
|`pin_entry_pad.dart`|PIN 输入面板|
|`bee_icon.dart`|图标组件|
|`info_tag.dart`|信息标签|
|`ledger_card.dart`|账本卡片|
|`product_promo_card.dart`|产品推广卡片|
|`login_2fa_challenge_view.dart`|2FA 验证视图|
|`attachment_picker.dart`|附件选择器|

### 3. `lib/widgets/charts/` — 图表组件

- `category_pie_chart.dart`​, `account_category_pie_chart.dart`
- `asset_composition_chart.dart`​, `balance_trend_chart.dart`​, `line_chart.dart`

### 4. 其他组件目录

- `widgets/analytics/` — 分析相关
- `widgets/ai/` — AI 相关
- `widgets/category/` — 分类选择器
- `widgets/currency/` — 币种选择
- `widgets/posters/` — 海报生成
- `widgets/transaction/` — 交易表单

### 5. 组件引用关系

- `ui/ui.dart`​ 统一导出供 `widgets/biz/` 等使用
- `biz/biz.dart`​ 统一导出供 `pages/` 使用
- 部分组件（如 `category_icon.dart`​, `measure_size.dart`​）位于 `widgets/` 根目录

---

## 八、关键发现总结

### 主题架构是**三层结构**：

```
┌──────────────────────────────────────────────────────┐
│ 第1层: BeeTokens (styles/tokens.dart)                │
│ Design Token 系统 — 所有颜色的唯一来源                │
│ 用法: BeeTokens.surface(context), BeeTokens.textPrimary(context) │
├──────────────────────────────────────────────────────┤
│ 第2层: BeeTheme (theme.dart) + main.dart 叠加       │
│ Flutter ThemeData 定义 — lightTheme / darkTheme      │
│ main.dart 中通过 copyWith 覆盖 theme.dart 的部分值   │
├──────────────────────────────────────────────────────┤
│ 第3层: theme_providers.dart (Riverpod)               │
│ 动态主题状态 — 主题模式、主色、皮肤等                 │
│ 支持跨设备同步 (PiggyCount Cloud)                      │
└──────────────────────────────────────────────────────┘
```

### 值得关注的 UI 一致性问题：

1. **​`theme.dart`​**​ **与** **​`main.dart`​**​ **有重叠定义**：`scaffoldBackgroundColor`​ 在 `BeeTheme.lightTheme`​ 中设为 `paperIvory`​，但在 `main.dart`​ 的 `theme.copyWith`​ 中又设为 `Colors.white`。
2. **硬编码颜色散布**：虽然已有 Token 系统，但许多页面仍直接使用 `Colors.red`​ / `Colors.green`​ / `Colors.orange`​ 等硬编码（如 `annual_report_page.dart`​ 中反复出现的 `Color(0xFF4CAF50)`​ 和 `Color(0xFFFF5252)`）。
3. **​`isDark`​**​ **条件判断散布**：`home_page.dart`​ 等文件中大量使用 `final isDark = Theme.of(context).brightness == Brightness.dark` 后做条件颜色，这些本应通过 Token 系统封装。
4. **Theme.of(context) 与 BeeTokens 并存**：部分新代码使用 `BeeTokens.primary(context)`​，但大量代码仍使用 `Theme.of(context).colorScheme.primary`，两者指向不同值（Token 系统强，Theme 弱）。
5. **组件库完善但使用不一致**：有 `PrimaryHeader`​、`SectionCard`​、`AppListTile` 等统一组件，但部分页面仍自己构建类似布局。  
   很好的基础信息，现在让我深入检查具体的 UI 一致性问题。  
   现在让我检查各个页面中具体的 UI 一致性问题。  
   我来为你进行全面的 UI 一致性检查。先并行执行多个搜索任务。  
   我来为你进行全面的 UI 一致性检查。先并行执行多个搜索任务。  
   Now let me get the full directory structure and the mixed token usage details.  
   Now let me get the full directory structure and the mixed token usage details.  
   Let me find the settings page and read the other key pages for spacing consistency.  
   Let me find the settings page and read the other key pages for spacing consistency.  
   Let me get more details on the remaining checks.  
   Let me get more details on the remaining checks.  
   让我查看未使用统一组件库的页面以及详细检查混合Token使用情况。  
   让我查看未使用统一组件库的页面以及详细检查混合Token使用情况。  
   现在我已经收集了所有需要的数据，以下是完整的 UI 一致性检查报告。

---

# UI 一致性检查报告 - PiggyCount 项目

## 检查点 1：硬编码颜色检查

### 1.1 直接使用 Color(0x...) 的硬编码颜色

以下文件在 pages/ 中使用了 `Color(0x` 直接硬编码颜色值（不含 token/theme 文件）：

|文件|行数|关键颜色值|
| ------| -------------------------| ------------------------------------------------------|
|`lib/pages/main/home_page.dart`|301, 423, 529|`Color(0xFF1E1E1E)` (深色模式卡片背景，重复3次)|
|`lib/pages/main/mine_page.dart`|945, 952, 959, 966, 972|`0xFFF59E0B`​, `0xFFF97316`​, `0xFF8B5CF6`​, `0xFF818CF8` (自定义颜色)|
|`lib/pages/settings/personalize_page.dart`|25-52|大量 `Color(0x...)` 定义主题色板（共28种主题颜色，此为合理场景）|
|`lib/pages/report/annual_report_page.dart`|446-1546|大量 `Color(0xFF4CAF50)`​(绿), `0xFFFF5252`​(红), `0xFFFFD700`​(金), `0xFFC0C0C0`​(银), `0xFFCD7F32`​(铜), `0xFF666666`(灰)|
|`lib/pages/account/accounts_page.dart`|1778|`Color(0xFF48484A)` (深色模式灰色文字)|

**关键发现：**  `home_page.dart`​ 中深色模式下卡片背景色 `Color(0xFF1E1E1E)`​ 重复了三次（第301、423、529行），应提取为 BeeTokens 常量。`annual_report_page.dart`​ 中的红绿色值 `0xFF4CAF50`​ / `0xFFFF5252` 在整个文件中被广泛重复使用。

### 1.2 使用 Colors.red/green/orange 等具名颜色的硬编码

结果：**大量文件**存在此类问题，主要分布情况如下：

**最常见的使用模式：**

- `Colors.red`​ / `Colors.redAccent`​ / `Colors.red[700]` -- 删除/错误/警告
- `Colors.green`​ / `Colors.green[700]` -- 成功/正常状态
- `Colors.orange`​ / `Colors.orange[700]`​ / `Colors.orange[900]` -- 警告/待处理
- `Colors.blue`​ / `Colors.blue[50]`​ / `Colors.blue[900]` -- 信息/链接
- `Colors.purple` -- 紫（仅 shortcuts_guide_page.dart）
- `Colors.amber` -- 仅 shortcuts_guide_page.dart
- `Colors.pink` -- 无
- `Colors.teal` -- 无
- `Colors.yellow` -- 无

**严重程度较高的文件（6次以上使用）：**

|文件|使用次数|主要颜色|
| ------| ----------| --------------------------|
|`lib/pages/ai/ai_provider_manage_page.dart`|9|`Colors.orange`​, `Colors.red`​, `Colors.green`|
|`lib/pages/automation/ios_auto_billing_page.dart`|10|`Colors.green`​, `Colors.orange`|
|`lib/pages/category/category_manage_page.dart`|7|`Colors.orange`|
|`lib/pages/settings/shortcuts_guide_page.dart`|8|`Colors.orange`​, `Colors.green`​, `Colors.blue`​, `Colors.red`​, `Colors.purple`​, `Colors.amber`|
|`lib/pages/cloud/config_import_export_page.dart`|8|`Colors.green`​, `Colors.orange`|
|`lib/pages/account/account_edit_page.dart`|5|`Colors.red`|
|`lib/pages/main/ledgers_page_new.dart`|5|`Colors.red`​, `Colors.redAccent`​, `Colors.orange`​, `Colors.blue`​, `Colors.orange`|

**代表性代码片段：**

```dart
// ios_auto_billing_page.dart:270-297 - Colors.green 被四处独立使用
color: Colors.green.shade700,
color: Colors.green.withValues(alpha: 0.1),
border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
Icon(Icons.check_circle_outline, color: Colors.green, size: 20),
```

```dart
// budget_progress_bar.dart:56-59 - 状态颜色映射用硬编码 Color
if (rate >= 1.0) return Colors.red[700]!;
if (rate >= 0.9) return Colors.red;
if (rate >= 0.7) return Colors.orange;
return Colors.green;
```

### 1.3 withOpacity 使用情况（推荐用 withValues(alpha:) 替代）

共发现 **25处** `withOpacity` 调用，分布如下：

|文件|行数|
| ------| -----------------------------------|
|`lib/pages/ai/ai_chat_page.dart`|175, 178, 268, 406, 412, 462, 465|
|`lib/pages/calendar/calendar_page.dart`|237, 260, 343, 365|
|`lib/pages/main/home_page.dart`|816, 827, 841, 950, 992|
|`lib/pages/auth/splash_page.dart`|31, 64, 75, 78, 108, 133|
|`lib/pages/category/icon_picker_page.dart`|285|
|`lib/pages/settings/log_center_page.dart`|168, 209, 373|

**需要注意：**  `home_page.dart`​ 的 `withOpacity`​ 调用（第816、827、841、950、992行）全部是作用在 `Theme.of(context).textTheme.bodyMedium?.color`​ 等主题颜色上，而非基础颜色上。同时该项目已有不少文件在使用更新的 `.withValues(alpha:)`​ API。建议统一替换剩余 `withOpacity`。

---

## 检查点 2：混合 Token 使用检查

以下文件同时混用了 `Theme.of(context)`​ 和 `BeeTokens.`​（即同时导入 `styles/tokens.dart`​ 并在 build 中使用 `Theme.of(context)`）：

**共 34 个文件**同时存在这两种用法：

|文件|
| ------|
|`lib/pages/ai/ai_settings_page.dart`|
|`lib/pages/budget/budget_edit_page.dart`|
|`lib/pages/budget/widgets/category_budget_tile.dart`|
|`lib/pages/auth/login_page.dart`|
|`lib/pages/cloud/piggycount_cloud_sync_page.dart`|
|`lib/pages/category/category_edit_page.dart`|
|`lib/pages/category/category_manage_page.dart`|
|`lib/pages/category/icon_picker_page.dart`|
|`lib/pages/main/mine_page.dart`|
|`lib/pages/main/home_page.dart`|
|`lib/pages/data/import_confirm_page.dart`|
|`lib/pages/transaction/recurring_transaction_page.dart`|
|`lib/pages/transaction/category_detail_page.dart`|
|`lib/pages/transaction/search_page.dart`|
|`lib/pages/main/analytics_page.dart`|
|`lib/pages/settings/about_page.dart`|
|`lib/pages/cloud/cloud_service_page.dart`|
|`lib/pages/maintenance/orphan_cleanup_page.dart`|
|`lib/pages/settings/appearance_settings_page.dart`|
|`lib/pages/cloud/cloud_sync_page.dart`|
|`lib/pages/cloud/invite_page.dart`|
|`lib/pages/cloud/join_shared_ledger_page.dart`|
|`lib/pages/tag/tag_detail_page.dart`|
|`lib/pages/tag/tag_manage_page.dart`|
|`lib/pages/tag/widgets/tag_selector.dart`|
|`lib/pages/settings/font_settings_page.dart`|
|`lib/pages/settings/data_management_page.dart`|
|`lib/pages/settings/language_settings_page.dart`|
|`lib/pages/settings/log_center_page.dart`|
|`lib/pages/settings/personalize_page.dart`|
|`lib/pages/settings/reminder_settings_page.dart`|
|`lib/pages/settings/shortcuts_guide_page.dart`|
|`lib/pages/settings/smart_billing_page.dart`|

**代表性问题示例（home_page.dart 第673行 vs 第108-109行）：**

```dart
// 使用 Theme.of(context) （第673行）
backgroundColor: Theme.of(context).scaffoldBackgroundColor,

// 使用了 BeeTokens （第108-109行） - accounts_page.dart 中
backgroundColor: BeeTokens.scaffoldBackground(context),
```

建议统一使用 BeeTokens 的封装方法代替直接 `Theme.of(context)`。

---

## 检查点 3：关键页面的间距一致性

### 3.1 home_page.dart (`lib/pages/main/home_page.dart`)

**自定义 padding/margin 使用情况：**

|位置|代码|间距值|
| ----------| ------| ------------------------|
|第298行|`margin: const EdgeInsets.fromLTRB(12, 4, 12, 8)`|水平12, 上4, 下8|
|第328行|`padding: const EdgeInsets.fromLTRB(16, 12, 12, 12)`|左右16/12, 上下12|
|第420行|`margin: const EdgeInsets.fromLTRB(12, 4, 12, 8)`|同上（与提醒卡片一致）|
|第526行|`margin: const EdgeInsets.fromLTRB(12, 4, 12, 8)`|同上（三者一致）|
|第753行|`padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6)`|水平10, 垂直6|
|第928行|`SizedBox(height: 6)`|6px|
|第1000行|`margin: const EdgeInsets.symmetric(horizontal: 12)`|水平12|

**评估：**  起始提醒卡片的三张卡片间距一致（重用 `EdgeInsets.fromLTRB(12, 4, 12, 8)`），但这是重复的常量硬编码而非抽取的间距常量。

### 3.2 accounts_page.dart (`lib/pages/account/accounts_page.dart`)

|位置|间距值|说明|
| ---------| --------| --------------------|
|第144行|`EdgeInsets.only(left: 12.0.scaled, right: 12.0.scaled, top: 8.0.scaled, bottom: 8.0.scaled)`|使用 `.scaled()` 自适应缩放|

**评估：**  使用了 `ui_scale_extensions.dart`​ 的 `.scaled()`​ 方法，比 `home_page.dart` 更灵活。

### 3.3 transaction_editor_page.dart (`lib/pages/transaction/transaction_editor_page.dart`)

|位置|间距值|说明|
| ---------| --------| -------------------------------|
|第117行|`padding: const EdgeInsets.fromLTRB(8, 4, 8, 0)`|PrimaryHeader 的自定义padding|

**评估：**  与 home_page 默认的 PrimaryHeader padding 不一致。

### 3.4 间距不一致性总结

- `home_page.dart`​ 使用静态 `const EdgeInsets`​ 值（如 `12`​, `16`）
- `accounts_page.dart`​ 使用 `.scaled(context, ref)` 动态缩放
- `transaction_editor_page.dart`​ 使用 `EdgeInsets.fromLTRB(8, 4, 8, 0)` 压缩 header
- 部分页面（如 `auth/splash_page.dart`​）使用 `32`​ 作为水平填充，与主流 `16`​/`12` 不一致

**目前项目存在两种间距体系：**

1. 静态 `const EdgeInsets.all(16)`​ / `symmetric(horizontal: 16)` -- 大部分页面使用
2. 动态 `.scaled(context, ref)` 自适应缩放 -- 主要在一些新页面中使用（accounts, calendar, budget等）

---

## 检查点 4：ui/组件库使用一致性

### 4.1 widgets/ui/ 提供的组件

`lib/widgets/ui` 目录提供了以下12个组件：

|组件文件|功能|
| ----------| -------------------------------|
|`ui.dart`|barrel export（统一导出入口）|
|`primary_header.dart`|主页面头部组件|
|`capsule_switcher.dart`|胶囊切换器|
|`dialog.dart`|通用对话框|
|`toast.dart`|Toast 提示|
|`skeleton.dart`|骨架屏|
|`speed_dial_fab.dart`|浮动速度拨号按钮|
|`bee_popup_menu.dart`|Bee 弹出菜单|
|`wheel_date_picker.dart`|滚轮日期选择器|
|`wheel_picker.dart`|滚轮选择器|
|`wheel_time_picker.dart`|滚轮时间选择器|
|`message_popover_menu.dart`|消息弹出菜单|
|`searchable_dropdown.dart`|可搜索下拉框|

### 4.2 使用 widgets/ui/ 的页面

**68个文件**导入了 `widgets/ui/ui.dart`（占 pages/ 下所有 dart 文件的 92%）。

### 4.3 未使用 widgets/ui/ 的页面（4个文件）

|文件|说明|
| ------| -----------------------------------------------------------|
|`lib/pages/auth/app_lock_screen.dart`|应用锁屏 - 使用 `BeeTokens`​ + `PinEntryPad` 等自定义组件|
|`lib/pages/auth/splash_page.dart`|启动页 - 仅使用原生 Material 组件，甚至没有使用 BeeTokens|
|`lib/pages/budget/widgets/budget_progress_bar.dart`|预算进度条组件 - 使用 `BeeTokens` 但没使用 ui 组件|
|`lib/pages/budget/widgets/category_budget_tile.dart`|分类预算瓦片 - 使用 `BeeTokens` 但没使用 ui 组件|

**重点关注：**  `auth/splash_page.dart`​ 不仅没有使用 `widgets/ui/`​，甚至没有导入 `styles/tokens.dart`（BeeTokens），是完全脱离 Token 体系的页面。

---

## 检查点 5：pages/ 与 widgets/ 目录结构总览

### pages/ 一级子目录和主要文件

```
lib/pages/
  account/          -- 账户管理
    accounts_page.dart, account_edit_page.dart,
    account_detail_page.dart, net_worth_trend_page.dart

  ai/               -- AI 功能
    ai_chat_page.dart, ai_settings_page.dart,
    ai_model_selection_page.dart, ai_prompt_edit_page.dart,
    ai_provider_manage_page.dart

  attachment/       -- 附件
    attachment_preview_page.dart

  auth/             -- 认证与引导
    app_lock_screen.dart, login_page.dart, pin_setup_page.dart,
    splash_page.dart, welcome_page.dart

  automation/       -- 自动化（自动记账）
    auto_billing_settings_page.dart, ios_auto_billing_page.dart

  budget/           -- 预算
    budget_page.dart, budget_edit_page.dart
    widgets/budget_progress_bar.dart, category_budget_tile.dart

  calendar/         -- 日历视图
    calendar_page.dart

  category/         -- 分类管理
    category_edit_page.dart, category_manage_page.dart,
    category_migration_page.dart, icon_picker_page.dart

  cloud/            -- 云同步
    piggycount_cloud_sync_page.dart, cloud_service_page.dart,
    cloud_sync_page.dart, devices_page.dart, invite_page.dart,
    join_shared_ledger_page.dart, member_list_page.dart,
    member_stats_page.dart, sync_preview_dialog.dart

  currency/         -- 汇率
    exchange_rate_page.dart

  data/             -- 数据导入导出
    export_page.dart, import_page.dart, import_confirm_page.dart

  donation/         -- 捐赠
    donation_page.dart

  main/             -- 主界面
    analytics_page.dart, home_page.dart,
    ledgers_page_new.dart, mine_page.dart

  maintenance/      -- 维护工具
    orphan_cleanup_page.dart

  report/           -- 报告
    annual_report_page.dart

  settings/         -- 设置（15个文件）
    about_page.dart, app_lock_settings_page.dart,
    appearance_settings_page.dart, attachment_preview_page.dart,
    automation_page.dart, config_import_export_page.dart,
    data_management_page.dart, font_settings_page.dart,
    header_skin_page.dart, help_center_page.dart,
    language_settings_page.dart, log_center_page.dart,
    personalize_page.dart, privacy_policy_page.dart,
    reminder_settings_page.dart, shortcuts_guide_page.dart,
    smart_billing_page.dart, storage_management_page.dart,
    widget_management_page.dart

  tag/              -- 标签管理
    tag_detail_page.dart, tag_edit_page.dart,
    tag_manage_page.dart
    widgets/tag_selector.dart

  transaction/      -- 交易相关
    category_detail_page.dart,
    recurring_transaction_edit_page.dart,
    recurring_transaction_page.dart, search_page.dart,
    transaction_editor_page.dart
```

**总计：**  18 个功能目录，约 74 个 dart 文件。

### widgets/ 目录结构

```
lib/widgets/
  ui/               -- 通用 UI 组件（12 个文件）
  biz/              -- 业务组件
  charts/           -- 图表组件
  category/         -- 分类相关组件
  transaction/      -- 交易相关组件
```

---

## 核心问题总结

|优先级|问题类型|严重程度|建议|
| --------| -----------------------------------------| ----------| ------------------------------------|
|**高**|`withOpacity` 旧API（25处）|中|全部替换为 `.withValues(alpha:)`|
|**高**|混合 Token 使用（34个文件混用 `Theme.of`​ + `BeeTokens`）|高|统一使用 BeeTokens 封装方法|
|**中**|`Colors.red/green/orange` 等硬编码（约20个文件）|高|提取为语义化的 BeeTokens 颜色常量|
|**中**|`splash_page.dart` 完全脱离 Token 体系|高|导入 BeeTokens 并使用主题颜色|
|**中**|`home_page.dart`​ 中 `Color(0xFF1E1E1E)` 重复3次|中|提取为 BeeTokens 暗色卡片背景色|
|**低**|间距体系不统一（const vs scaled）|中|统一间距策略|
|**低**|`annual_report_page.dart` 大量分散的红绿色值|中|使用预设的语义颜色常量替代 `0xFF4CAF50`​ / `0xFFFF5252`|

---

# UI 一致性检查报告 - PiggyCount 项目

## 检查点 1：硬编码颜色检查

### 1.1 直接使用 Color(0x...) 的硬编码颜色

以下文件在 pages/ 中使用了 `Color(0x` 直接硬编码颜色值（不含 token/theme 文件）：

|文件|行数|关键颜色值|
| ------| -------------------------| ------------------------------------------------------|
|`lib/pages/main/home_page.dart`|301, 423, 529|`Color(0xFF1E1E1E)` (深色模式卡片背景，重复3次)|
|`lib/pages/main/mine_page.dart`|945, 952, 959, 966, 972|`0xFFF59E0B`​, `0xFFF97316`​, `0xFF8B5CF6`​, `0xFF818CF8` (自定义颜色)|
|`lib/pages/settings/personalize_page.dart`|25-52|大量 `Color(0x...)` 定义主题色板（共28种主题颜色，此为合理场景）|
|`lib/pages/report/annual_report_page.dart`|446-1546|大量 `Color(0xFF4CAF50)`​(绿), `0xFFFF5252`​(红), `0xFFFFD700`​(金), `0xFFC0C0C0`​(银), `0xFFCD7F32`​(铜), `0xFF666666`(灰)|
|`lib/pages/account/accounts_page.dart`|1778|`Color(0xFF48484A)` (深色模式灰色文字)|

**关键发现：**  `home_page.dart`​ 中深色模式下卡片背景色 `Color(0xFF1E1E1E)`​ 重复了三次（第301、423、529行），应提取为 BeeTokens 常量。`annual_report_page.dart`​ 中的红绿色值 `0xFF4CAF50`​ / `0xFFFF5252` 在整个文件中被广泛重复使用。

### 1.2 使用 Colors.red/green/orange 等具名颜色的硬编码

结果：**大量文件**存在此类问题，主要分布情况如下：

**最常见的使用模式：**

- `Colors.red`​ / `Colors.redAccent`​ / `Colors.red[700]` -- 删除/错误/警告
- `Colors.green`​ / `Colors.green[700]` -- 成功/正常状态
- `Colors.orange`​ / `Colors.orange[700]`​ / `Colors.orange[900]` -- 警告/待处理
- `Colors.blue`​ / `Colors.blue[50]`​ / `Colors.blue[900]` -- 信息/链接
- `Colors.purple` -- 紫（仅 shortcuts_guide_page.dart）
- `Colors.amber` -- 仅 shortcuts_guide_page.dart
- `Colors.pink` -- 无
- `Colors.teal` -- 无
- `Colors.yellow` -- 无

**严重程度较高的文件（6次以上使用）：**

|文件|使用次数|主要颜色|
| ------| ----------| --------------------------|
|`lib/pages/ai/ai_provider_manage_page.dart`|9|`Colors.orange`​, `Colors.red`​, `Colors.green`|
|`lib/pages/automation/ios_auto_billing_page.dart`|10|`Colors.green`​, `Colors.orange`|
|`lib/pages/category/category_manage_page.dart`|7|`Colors.orange`|
|`lib/pages/settings/shortcuts_guide_page.dart`|8|`Colors.orange`​, `Colors.green`​, `Colors.blue`​, `Colors.red`​, `Colors.purple`​, `Colors.amber`|
|`lib/pages/cloud/config_import_export_page.dart`|8|`Colors.green`​, `Colors.orange`|
|`lib/pages/account/account_edit_page.dart`|5|`Colors.red`|
|`lib/pages/main/ledgers_page_new.dart`|5|`Colors.red`​, `Colors.redAccent`​, `Colors.orange`​, `Colors.blue`​, `Colors.orange`|

**代表性代码片段：**

```dart
// ios_auto_billing_page.dart:270-297 - Colors.green 被四处独立使用
color: Colors.green.shade700,
color: Colors.green.withValues(alpha: 0.1),
border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
Icon(Icons.check_circle_outline, color: Colors.green, size: 20),
```

```dart
// budget_progress_bar.dart:56-59 - 状态颜色映射用硬编码 Color
if (rate >= 1.0) return Colors.red[700]!;
if (rate >= 0.9) return Colors.red;
if (rate >= 0.7) return Colors.orange;
return Colors.green;
```

### 1.3 withOpacity 使用情况（推荐用 withValues(alpha:) 替代）

共发现 **25处** `withOpacity` 调用，分布如下：

|文件|行数|
| ------| -----------------------------------|
|`lib/pages/ai/ai_chat_page.dart`|175, 178, 268, 406, 412, 462, 465|
|`lib/pages/calendar/calendar_page.dart`|237, 260, 343, 365|
|`lib/pages/main/home_page.dart`|816, 827, 841, 950, 992|
|`lib/pages/auth/splash_page.dart`|31, 64, 75, 78, 108, 133|
|`lib/pages/category/icon_picker_page.dart`|285|
|`lib/pages/settings/log_center_page.dart`|168, 209, 373|

**需要注意：**  `home_page.dart`​ 的 `withOpacity`​ 调用（第816、827、841、950、992行）全部是作用在 `Theme.of(context).textTheme.bodyMedium?.color`​ 等主题颜色上，而非基础颜色上。同时该项目已有不少文件在使用更新的 `.withValues(alpha:)`​ API。建议统一替换剩余 `withOpacity`。

---

## 检查点 2：混合 Token 使用检查

以下文件同时混用了 `Theme.of(context)`​ 和 `BeeTokens.`​（即同时导入 `styles/tokens.dart`​ 并在 build 中使用 `Theme.of(context)`）：

**共 34 个文件**同时存在这两种用法：

|文件|
| ------|
|`lib/pages/ai/ai_settings_page.dart`|
|`lib/pages/budget/budget_edit_page.dart`|
|`lib/pages/budget/widgets/category_budget_tile.dart`|
|`lib/pages/auth/login_page.dart`|
|`lib/pages/cloud/piggycount_cloud_sync_page.dart`|
|`lib/pages/category/category_edit_page.dart`|
|`lib/pages/category/category_manage_page.dart`|
|`lib/pages/category/icon_picker_page.dart`|
|`lib/pages/main/mine_page.dart`|
|`lib/pages/main/home_page.dart`|
|`lib/pages/data/import_confirm_page.dart`|
|`lib/pages/transaction/recurring_transaction_page.dart`|
|`lib/pages/transaction/category_detail_page.dart`|
|`lib/pages/transaction/search_page.dart`|
|`lib/pages/main/analytics_page.dart`|
|`lib/pages/settings/about_page.dart`|
|`lib/pages/cloud/cloud_service_page.dart`|
|`lib/pages/maintenance/orphan_cleanup_page.dart`|
|`lib/pages/settings/appearance_settings_page.dart`|
|`lib/pages/cloud/cloud_sync_page.dart`|
|`lib/pages/cloud/invite_page.dart`|
|`lib/pages/cloud/join_shared_ledger_page.dart`|
|`lib/pages/tag/tag_detail_page.dart`|
|`lib/pages/tag/tag_manage_page.dart`|
|`lib/pages/tag/widgets/tag_selector.dart`|
|`lib/pages/settings/font_settings_page.dart`|
|`lib/pages/settings/data_management_page.dart`|
|`lib/pages/settings/language_settings_page.dart`|
|`lib/pages/settings/log_center_page.dart`|
|`lib/pages/settings/personalize_page.dart`|
|`lib/pages/settings/reminder_settings_page.dart`|
|`lib/pages/settings/shortcuts_guide_page.dart`|
|`lib/pages/settings/smart_billing_page.dart`|

**代表性问题示例（home_page.dart 第673行 vs 第108-109行）：**

```dart
// 使用 Theme.of(context) （第673行）
backgroundColor: Theme.of(context).scaffoldBackgroundColor,

// 使用了 BeeTokens （第108-109行） - accounts_page.dart 中
backgroundColor: BeeTokens.scaffoldBackground(context),
```

建议统一使用 BeeTokens 的封装方法代替直接 `Theme.of(context)`。

---

## 检查点 3：关键页面的间距一致性

### 3.1 home_page.dart (`lib/pages/main/home_page.dart`)

**自定义 padding/margin 使用情况：**

|位置|代码|间距值|
| ----------| ------| ------------------------|
|第298行|`margin: const EdgeInsets.fromLTRB(12, 4, 12, 8)`|水平12, 上4, 下8|
|第328行|`padding: const EdgeInsets.fromLTRB(16, 12, 12, 12)`|左右16/12, 上下12|
|第420行|`margin: const EdgeInsets.fromLTRB(12, 4, 12, 8)`|同上（与提醒卡片一致）|
|第526行|`margin: const EdgeInsets.fromLTRB(12, 4, 12, 8)`|同上（三者一致）|
|第753行|`padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6)`|水平10, 垂直6|
|第928行|`SizedBox(height: 6)`|6px|
|第1000行|`margin: const EdgeInsets.symmetric(horizontal: 12)`|水平12|

**评估：**  起始提醒卡片的三张卡片间距一致（重用 `EdgeInsets.fromLTRB(12, 4, 12, 8)`），但这是重复的常量硬编码而非抽取的间距常量。

### 3.2 accounts_page.dart (`lib/pages/account/accounts_page.dart`)

|位置|间距值|说明|
| ---------| --------| --------------------|
|第144行|`EdgeInsets.only(left: 12.0.scaled, right: 12.0.scaled, top: 8.0.scaled, bottom: 8.0.scaled)`|使用 `.scaled()` 自适应缩放|

**评估：**  使用了 `ui_scale_extensions.dart`​ 的 `.scaled()`​ 方法，比 `home_page.dart` 更灵活。

### 3.3 transaction_editor_page.dart (`lib/pages/transaction/transaction_editor_page.dart`)

|位置|间距值|说明|
| ---------| --------| -------------------------------|
|第117行|`padding: const EdgeInsets.fromLTRB(8, 4, 8, 0)`|PrimaryHeader 的自定义padding|

**评估：**  与 home_page 默认的 PrimaryHeader padding 不一致。

### 3.4 间距不一致性总结

- `home_page.dart`​ 使用静态 `const EdgeInsets`​ 值（如 `12`​, `16`）
- `accounts_page.dart`​ 使用 `.scaled(context, ref)` 动态缩放
- `transaction_editor_page.dart`​ 使用 `EdgeInsets.fromLTRB(8, 4, 8, 0)` 压缩 header
- 部分页面（如 `auth/splash_page.dart`​）使用 `32`​ 作为水平填充，与主流 `16`​/`12` 不一致

**目前项目存在两种间距体系：**

1. 静态 `const EdgeInsets.all(16)`​ / `symmetric(horizontal: 16)` -- 大部分页面使用
2. 动态 `.scaled(context, ref)` 自适应缩放 -- 主要在一些新页面中使用（accounts, calendar, budget等）

---

## 检查点 4：ui/组件库使用一致性

### 4.1 widgets/ui/ 提供的组件

`lib/widgets/ui` 目录提供了以下12个组件：

|组件文件|功能|
| ----------| -------------------------------|
|`ui.dart`|barrel export（统一导出入口）|
|`primary_header.dart`|主页面头部组件|
|`capsule_switcher.dart`|胶囊切换器|
|`dialog.dart`|通用对话框|
|`toast.dart`|Toast 提示|
|`skeleton.dart`|骨架屏|
|`speed_dial_fab.dart`|浮动速度拨号按钮|
|`bee_popup_menu.dart`|Bee 弹出菜单|
|`wheel_date_picker.dart`|滚轮日期选择器|
|`wheel_picker.dart`|滚轮选择器|
|`wheel_time_picker.dart`|滚轮时间选择器|
|`message_popover_menu.dart`|消息弹出菜单|
|`searchable_dropdown.dart`|可搜索下拉框|

### 4.2 使用 widgets/ui/ 的页面

**68个文件**导入了 `widgets/ui/ui.dart`（占 pages/ 下所有 dart 文件的 92%）。

### 4.3 未使用 widgets/ui/ 的页面（4个文件）

|文件|说明|
| ------| -----------------------------------------------------------|
|`lib/pages/auth/app_lock_screen.dart`|应用锁屏 - 使用 `BeeTokens`​ + `PinEntryPad` 等自定义组件|
|`lib/pages/auth/splash_page.dart`|启动页 - 仅使用原生 Material 组件，甚至没有使用 BeeTokens|
|`lib/pages/budget/widgets/budget_progress_bar.dart`|预算进度条组件 - 使用 `BeeTokens` 但没使用 ui 组件|
|`lib/pages/budget/widgets/category_budget_tile.dart`|分类预算瓦片 - 使用 `BeeTokens` 但没使用 ui 组件|

**重点关注：**  `auth/splash_page.dart`​ 不仅没有使用 `widgets/ui/`​，甚至没有导入 `styles/tokens.dart`（BeeTokens），是完全脱离 Token 体系的页面。

---

## 检查点 5：pages/ 与 widgets/ 目录结构总览

### pages/ 一级子目录和主要文件

```
lib/pages/
  account/          -- 账户管理
    accounts_page.dart, account_edit_page.dart,
    account_detail_page.dart, net_worth_trend_page.dart

  ai/               -- AI 功能
    ai_chat_page.dart, ai_settings_page.dart,
    ai_model_selection_page.dart, ai_prompt_edit_page.dart,
    ai_provider_manage_page.dart

  attachment/       -- 附件
    attachment_preview_page.dart

  auth/             -- 认证与引导
    app_lock_screen.dart, login_page.dart, pin_setup_page.dart,
    splash_page.dart, welcome_page.dart

  automation/       -- 自动化（自动记账）
    auto_billing_settings_page.dart, ios_auto_billing_page.dart

  budget/           -- 预算
    budget_page.dart, budget_edit_page.dart
    widgets/budget_progress_bar.dart, category_budget_tile.dart

  calendar/         -- 日历视图
    calendar_page.dart

  category/         -- 分类管理
    category_edit_page.dart, category_manage_page.dart,
    category_migration_page.dart, icon_picker_page.dart

  cloud/            -- 云同步
    piggycount_cloud_sync_page.dart, cloud_service_page.dart,
    cloud_sync_page.dart, devices_page.dart, invite_page.dart,
    join_shared_ledger_page.dart, member_list_page.dart,
    member_stats_page.dart, sync_preview_dialog.dart

  currency/         -- 汇率
    exchange_rate_page.dart

  data/             -- 数据导入导出
    export_page.dart, import_page.dart, import_confirm_page.dart

  donation/         -- 捐赠
    donation_page.dart

  main/             -- 主界面
    analytics_page.dart, home_page.dart,
    ledgers_page_new.dart, mine_page.dart

  maintenance/      -- 维护工具
    orphan_cleanup_page.dart

  report/           -- 报告
    annual_report_page.dart

  settings/         -- 设置（15个文件）
    about_page.dart, app_lock_settings_page.dart,
    appearance_settings_page.dart, attachment_preview_page.dart,
    automation_page.dart, config_import_export_page.dart,
    data_management_page.dart, font_settings_page.dart,
    header_skin_page.dart, help_center_page.dart,
    language_settings_page.dart, log_center_page.dart,
    personalize_page.dart, privacy_policy_page.dart,
    reminder_settings_page.dart, shortcuts_guide_page.dart,
    smart_billing_page.dart, storage_management_page.dart,
    widget_management_page.dart

  tag/              -- 标签管理
    tag_detail_page.dart, tag_edit_page.dart,
    tag_manage_page.dart
    widgets/tag_selector.dart

  transaction/      -- 交易相关
    category_detail_page.dart,
    recurring_transaction_edit_page.dart,
    recurring_transaction_page.dart, search_page.dart,
    transaction_editor_page.dart
```

**总计：**  18 个功能目录，约 74 个 dart 文件。

### widgets/ 目录结构

```
lib/widgets/
  ui/               -- 通用 UI 组件（12 个文件）
  biz/              -- 业务组件
  charts/           -- 图表组件
  category/         -- 分类相关组件
  transaction/      -- 交易相关组件
```

---

## 核心问题总结

| 优先级 | 问题类型 | 严重程度 | 建议 |  
|--------|---------|---------|------|  
| **高** | `withOpacity`​ 旧API（25处） | 中 | 全部替换为 `.withValues(alpha:)`​ |  
| **高** | 混合 Token 使用（34个文件混用 `Theme.of`​ + `BeeTokens`​） | 高 | 统一使用 BeeTokens 封装方法 |  
| **中** | `Colors.red/green/orange`​ 等硬编码（约20个文件） | 高 | 提取为语义化的 BeeTokens 颜色常量 |  
| **中** | `splash_page.dart`​ 完全脱离 Token 体系 | 高 | 导入 BeeTokens 并使用主题颜色 |  
| **中** | `home_page.dart`​ 中 `Color(0xFF1E1E1E)`​ 重复3次 | 中 | 提取为 BeeTokens 暗色卡片背景色 |  
| **低** | 间距体系不统一（const vs scaled） | 中 | 统一间距策略 |  
| **低** | `annual_report_page.dart`​ 大量分散的红绿色值 | 中 | 使用预设的语义颜色常量替代 `0xFF4CAF50`​ / `0xFFFF5252` |  
再补充检查一些关键细节。  
现在我来整理完整的分析报告。

---

# 🐝 PiggyCount 项目 UI 一致性审查报告

## 一、总评

项目已有**比较完善的 Design Token 系统**（`BeeTokens`​），但**实际使用严重滞后于设计**：Token 定义得很好，但大量页面代码仍然使用硬编码颜色、旧的 API 或直接 `Theme.of(context)`，导致一致性打了折扣。

---

## 二、架构层面：三层主题体系存在重叠

```
BeeTokens (styles/tokens.dart)   ← 语义化颜色 Token
    ↓
BeeTheme (theme.dart)           ← 亮/暗两套 ThemeData 定义
    ↓
main.dart copyWith                ← 动态覆盖 + Provider 主题管理
```

**核心问题：同一属性在两层中定义不同值**

|属性|theme.dart|main.dart|矛盾？|
| ------| -------------------| -----------| --------|
|`scaffoldBackgroundColor`|`paperIvory` (0xFFFFF8E1)|`Colors.white`| **✅ 矛盾**|
|`cardTheme.borderRadius`|12|16| **✅ 矛盾**|
|`dividerColor`|未设置|`Colors.black.withOpacity(0.06)`| **⚠️ 未对齐 Token**|

> **建议**：将 `main.dart`​ 中与 `BeeTheme`​ 重叠的定义剥离到 `BeeTheme`​ 自身，`main.dart`​ 只做动态色覆盖（`primary`）。

---

## 三、Token 系统使用问题（严重度：高）

### 1. `BeeTokens`​ 与 `Theme.of(context)` 混用

**34 个文件**同时导入了 `tokens.dart`​ 又在 build 中直接调用 `Theme.of(context).colorScheme.xxx`，这意味着：

- 这些页面的部分颜色走 Token 适配，另一部分走 Flutter 默认值
- 当修改 Token 系统时，会有大量遗漏

典型如 `home_page.dart`：

```dart
// 用了 BeeTokens
backgroundColor: BeeTokens.surface(context),

// 同一文件中却直接取 Theme
backgroundColor: Theme.of(context).scaffoldBackgroundColor,
```

### 2. `BeeTokens.scaffoldBackground`​ 与 `theme.dart` 不一致

```dart
// tokens.dart — 亮色模式
static Color scaffoldBackground(BuildContext) => Colors.grey.shade50; // #FAFAFA

// theme.dart — 亮色模式
scaffoldBackgroundColor: paperIvory // #FFF8E1

// main.dart — 覆盖
scaffoldBackgroundColor: Colors.white // #FFFFFF
```

**同一属性有三种不同的值**，取决于代码从哪个路径获取颜色。

---

## 四、硬编码颜色散布（严重度：高）

### 4.1 语义色硬编码（约 15+ 文件）

最典型的问题：用 `Colors.red`​ / `Colors.green`​ / `Colors.orange`​ 替代 `BeeTokens.error/success/warning`：

|文件|问题|
| ------| ---------------------------------|
|`budget_progress_bar.dart:56-59`|进度条颜色用 `Colors.red[700]`​, `Colors.orange`​, `Colors.green`|
|`ios_auto_billing_page.dart:270-297`|四处独立使用 `Colors.green`|
|`shortcuts_guide_page.dart`|混用橙/绿/蓝/红/紫/琥珀 6种颜色|
|`ai_provider_manage_page.dart`|9 处硬编码语义色|

### 4.2 品牌色/业务色硬编码

`annual_report_page.dart`​ 中大量使用 `Color(0xFF4CAF50)`​（绿）和 `Color(0xFFFF5252)`​（红），应使用 `BeeTokens.chartIncome/Expense`

### 4.3 `splash_page.dart` 完全脱离 Token 系统

启动页甚至**没有导入** `tokens.dart`，所有颜色硬编码：

```dart
color: Colors.white,                 // 多处
color: Colors.black.withOpacity(0.1), 
color: Colors.white.withOpacity(0.9),
// 等
```

---

## 五、旧 API 使用（严重度：中）

`withOpacity`​ 已被 Flutter 标记为 deprecated，建议用 `withValues(alpha:)`​。全项目仍有 **35 处**使用旧 API：

|集中地|数量|
| --------| ------|
|`ai_chat_page.dart`|7 处|
|`home_page.dart`|5 处|
|`splash_page.dart`|6 处|
|`calendar_page.dart`|4 处|
|`searchable_dropdown.dart`|5 处|
|`main.dart`|1 处|

---

## 六、间距体系不一致（严重度：中低）

项目中存在 **两种间距策略**并行：

|策略|使用范围|举例|
| ---------| ------------| -----------|
|静态 `const EdgeInsets`|大部分页面|`EdgeInsets.all(16)`​ / `symmetric(horizontal: 12)`|
|动态 `.scaled()`|部分新页面|`EdgeInsets.only(left: 12.0.scaled)`|

- **具体值**也不统一：`horizontal: 16`​（多数页面）vs `horizontal: 32`​（splash_page）vs `horizontal: 12`（accounts_page 部分区域）
- `home_page.dart`​ 在三个卡片处重复编写 `EdgeInsets.fromLTRB(12, 4, 12, 8)`，未提取为常量

---

## 七、组件库使用情况（良好）

`widgets/ui/`​ 提供了 **13 个**通用组件，**92%**  的页面已导入使用，覆盖率较好。

**积极方面**：

- `PrimaryHeader`​、`SectionCard`​、`AppListTile`​ 等正确使用 `BeeTokens`，是好的参考模板
- `SectionCard`​ 使用 `BeeDimens.p12`​ 和 `BeeTokens.surface`，设计合理
- `AppListTile`​ 使用了 `BeeTextTokens.title/label`

**可优化点**：

- `AppListTile`​ 第 38-46 行仍在用 `Theme.of(context).colorScheme.primary`​ 而非 `BeeTokens.primary(context)`，建议统一
- `splash_page.dart`​、`budget_progress_bar.dart` 等 4 个文件未使用组件库

---

## 八、汇总与修复优先级

|优先级|问题|影响范围|预估工作量|
| --------| ---------------------------------------------------| ----------| ------------------|
|🔴 **P0**|`theme.dart`​ / `main.dart`​ / `tokens.dart` 三者不一致（scaffoldBackground等）|全应用|小（改3处值）|
|🔴 **P0**|`splash_page.dart` 完全脱离 Token 体系|1 文件|小|
|🟠 **P1**|34 文件混用 `Theme.of`​ + `BeeTokens`|34 文件|大|
|🟠 **P1**|语义色硬编码（`Colors.red/green`替代 Token）|~15 文件|中|
|🟡 **P2**|`withOpacity` 旧 API|35 处|中|
|🟡 **P2**|`annual_report_page` 硬编码红绿色值|1 文件|小|
|🟢 **P3**|间距体系不一致（const vs scaled）|全应用|大（需设计决策）|

---

## 九、核心建议

1. **立即修复** P0 问题：统一 `theme.dart`​ / `main.dart`​ / `tokens.dart`​ 中 `scaffoldBackgroundColor`​ 为单一来源；为 `splash_page.dart` 接入 Token
2. **重点推进** P1 问题：建议将 `BeeTokens.xxx(context)`​ 逐步推广为获取颜色的**唯一入口**，`Theme.of(context)` 只保留少数无法替代的场景
3. **自动化检测**：可引入 lint 规则，禁止在 `pages/`​ 和 `widgets/`​ 中直接使用 `Colors.red/green/blue`​、`Color(0x`​ 和 `Theme.of(context).colorScheme`，强制走 Token
4. **统一间距**：选择静态间距或 `.scaled()` 动态间距之一，全项目统一
