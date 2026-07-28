# 设置页面 UI 改造 - 设计文档

## 1. 技术决策

### 1.1 整体策略：移植 + 新建，不污染共享组件

**决策**：将 wait-home 的液态玻璃标题栏组件**完整移植**到 BeeCount 的 `lib/widgets/ui/` 目录，并在 `lib/widgets/biz/` 新建设置专用组件（`SettingsCard` / `SettingsNavItem` / `SettingsToggleItem` / `SettingsSectionLabel`），**不修改**现有 `AppListTile` / `SectionCard` / `PrimaryHeader`。

**理由**：
- 现有共享组件被全 App 大量使用（账户页、预算页、交易页等），直接修改会引发不可控的回归风险
- wait-home 的设置项样式与 BeeCount 现有 `AppListTile`（36×36 圆形图标盒）差异较大，强行复用会破坏其他页面
- 新建专用组件可在设置页内统一风格，同时保持改动隔离、可回滚

### 1.2 标题栏移植策略

**决策**：完整移植 wait-home 的 3 个文件：
- `lib/widgets/ui/gradient_backdrop_filter.dart`（无级渐变模糊）
- `lib/widgets/ui/liquid_glass_title_bar.dart`（液态玻璃标题栏核心）
- `lib/widgets/ui/glass_title_bar.dart`（薄包装：`GlassTitleBar` + `GlassHomeBar`）

**适配点**：
- wait-home 依赖 `AppDimens`（如 `titleBarHeight=56`、`blurTitleBarMax=20`、`space16` 等），BeeCount 移植时将这些常量**内联为字面量**或映射到 `BeeDimens`，避免引入 wait-home 的整套 Token 体系
- wait-home 的 `LiquidGlassTitleBar` 包含搜索框、第二行、功能键等设置页不需要的能力，移植时**保留完整 API**（未来可复用），但设置页仅用到 `title` / `showBack` / `onBack` / `actions` 字段

### 1.3 MinePage 头部处理

**决策**：
- 顶部用 `GlassTitleBar`（标题「我的」，无 leading，可带右侧 actions）替代原 `PrimaryHeader` 的标题区
- 头像+问候语+统计作为 **ProfileCard** 出现在 ListView 第一项
- ProfileCard 背景保留 `headerSkinProvider`（用户选择的头部皮肤），圆角 16px
- ProfileCard 内部布局：左侧头像 + 右侧问候语/昵称/小眼睛，底部 3 列统计 `_StatCell`

**理由**：
- 保留头部皮肤功能（功能不能变）
- 视觉上贴合 wait-home「灰底白卡」风格
- 头像/问候语/统计内容完整保留，仅容器从全宽 PrimaryHeader 改为 16px 圆角卡片

### 1.4 设置子页头部处理

**决策**：所有 `lib/pages/settings/` 下的子页，将 `PrimaryHeader(showBack: true, title: ...)` 替换为：
```dart
Scaffold(
  extendBodyBehindAppBar: true,
  appBar: GlassTitleBar(
    title: l10n.xxx,
    showBack: true,
    onBack: () => Navigator.of(context).maybePop(),
  ),
  body: ListView(
    padding: EdgeInsets.fromLTRB(
      16,
      MediaQuery.of(context).padding.top + 56 + 16,
      16,
      16 + MediaQuery.of(context).padding.bottom,
    ),
    children: [...],
  ),
)
```

**权衡**：子页不再显示头部皮肤背景（视觉一致性优先），但皮肤功能在 MinePage 仍可见可切换，功能未丢失。

### 1.5 设置项组件设计

新建 `lib/widgets/biz/settings_widgets.dart`，包含 4 个组件：

```dart
// 分组小标题：12pt w600 onSurfaceVariant，左缩进 8px
class SettingsSectionLabel extends StatelessWidget {
  final String label;
  // ...
}

// 设置分组卡片：16px 圆角，无阴影无边框，无默认 padding（children 自带 padding）
class SettingsCard extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsets? margin;
  // ...
}

// 导航项：24px 强调色图标 + 标题/副标题 + chevron_right_rounded
// padding: horizontal 16, vertical 14；涟漪圆角 12
class SettingsNavItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;        // 覆盖默认 chevron
  final bool useIconBox;         // true = 子页风格（图标盒），false = 主页风格（裸图标）
  // ...
}

// 开关项：导航项变体，trailing 为 Switch.adaptive
class SettingsToggleItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool useIconBox;
  // ...
}
```

**理由**：
- 4 个组件覆盖所有设置项场景（导航 / 开关 / 自定义 trailing）
- `useIconBox` 参数兼容 wait-home 主页（裸图标）与子页（图标盒）两种风格
- 组件签名贴近 BeeCount 现有 `AppListTile`（leading / title / subtitle / onTap / trailing），降低子页改造工作量

## 2. 文件改动清单

### 2.1 新增文件（5 个）

| 文件路径 | 内容 | 来源 |
|---|---|---|
| `lib/widgets/ui/gradient_backdrop_filter.dart` | 无级渐变模糊背景组件 | 移植自 wait-home |
| `lib/widgets/ui/liquid_glass_title_bar.dart` | 液态玻璃标题栏核心 | 移植自 wait-home（适配 BeeCount Token） |
| `lib/widgets/ui/glass_title_bar.dart` | `GlassTitleBar` + `GlassHomeBar` 薄包装 | 移植自 wait-home |
| `lib/widgets/biz/settings_widgets.dart` | `SettingsSectionLabel` / `SettingsCard` / `SettingsNavItem` / `SettingsToggleItem` | 新建 |
| `lib/widgets/biz/profile_card.dart` | MinePage 头部 ProfileCard（头像+问候语+统计+头部皮肤背景） | 新建（从 mine_page.dart 抽取） |

### 2.2 修改文件（20 个）

| 文件路径 | 改动要点 |
|---|---|
| `lib/pages/main/mine_page.dart` | 重写为 `Scaffold + GlassTitleBar + ListView`，头部改用 ProfileCard，4 个分组改用 SettingsCard + SettingsNavItem |
| `lib/pages/settings/about_page.dart` | PrimaryHeader → GlassTitleBar；SectionCard/AppListTile → SettingsCard/SettingsNavItem |
| `lib/pages/settings/appearance_settings_page.dart` | 同上；Switch 项改用 SettingsToggleItem；弹窗保留 |
| `lib/pages/settings/app_lock_settings_page.dart` | 同上 |
| `lib/pages/settings/automation_page.dart` | 同上 |
| `lib/pages/settings/config_import_export_page.dart` | 同上 |
| `lib/pages/settings/data_management_page.dart` | 同上；进度条 trailing 保留 |
| `lib/pages/settings/font_settings_page.dart` | 同上；Slider 保留 |
| `lib/pages/settings/header_skin_page.dart` | 同上；GridView 保留 |
| `lib/pages/settings/help_center_page.dart` | 同上（WebView 主体不变） |
| `lib/pages/settings/language_settings_page.dart` | 同上 |
| `lib/pages/settings/log_center_page.dart` | 同上 |
| `lib/pages/settings/personalize_page.dart` | 同上；GridView 保留 |
| `lib/pages/settings/privacy_policy_page.dart` | 同上 |
| `lib/pages/settings/reminder_settings_page.dart` | 同上；SwitchListTile 改用 SettingsToggleItem；Android 专用的 OutlinedButton 行保留 |
| `lib/pages/settings/shortcuts_guide_page.dart` | 同上 |
| `lib/pages/settings/smart_billing_page.dart` | 同上；Slider 保留 |
| `lib/pages/settings/storage_management_page.dart` | 同上 |
| `lib/pages/settings/widget_management_page.dart` | 同上 |
| `lib/pages/settings/attachment_preview_page.dart` | 同上 |

### 2.3 不修改的文件

- `lib/widgets/biz/app_list_tile.dart`（共享组件，保持原样）
- `lib/widgets/biz/section_card.dart`（共享组件，保持原样）
- `lib/widgets/ui/primary_header.dart`（共享组件，保持原样）
- `lib/styles/tokens.dart`（Token 体系不变）
- `lib/theme.dart`（主题不变）
- 其他业务页面（账户、预算、交易、日历等）

## 3. 实现步骤

### 步骤 1：移植液态玻璃标题栏组件

新建 3 个文件：
- `lib/widgets/ui/gradient_backdrop_filter.dart`：从 wait-home 完整移植，将 `AppDimens.blurTitleBarMax`（20）/ `blurTitleBarMin`（2）替换为字面量或 BeeCount 等价 Token
- `lib/widgets/ui/liquid_glass_title_bar.dart`：完整移植，将 `AppDimens.titleBarHeight`（56）/ `space16`（16）/ `space12`（12）/ `space8`（8）/ `iconSizeLg`（24）/ `iconSizeMd`（20）/ `iconSizeSm`（16）/ `touchTarget`（48）/ `durationSlow`（220）/ `durationNormal`（150）替换为字面量
- `lib/widgets/ui/glass_title_bar.dart`：完整移植（薄包装，无需改 Token）

### 步骤 2：新建设置专用组件

新建 `lib/widgets/biz/settings_widgets.dart`，实现 4 个组件：
- `SettingsSectionLabel`：12pt w600 `onSurfaceVariant`，左缩进 8px
- `SettingsCard`：16px 圆角，`BeeTokens.surface` 背景，无阴影无边框，无默认 padding
- `SettingsNavItem`：24px 强调色图标（`useIconBox=true` 时套 8dp padding + 10% accent 背景 + 10px 圆角盒）+ 标题/副标题 + `chevron_right_rounded`，padding `horizontal:16 vertical:14`，涟漪圆角 12
- `SettingsToggleItem`：导航项变体，trailing 为 `Switch.adaptive`

### 步骤 3：新建 ProfileCard 并重写 MinePage

- 新建 `lib/widgets/biz/profile_card.dart`：从 `mine_page.dart` 抽取 `_MinePageHeader` 内容，包装为 16px 圆角卡片，背景使用 `headerSkinProvider`，保留头像/问候语/统计/小眼睛全部交互
- 重写 `lib/pages/main/mine_page.dart`：
  - `Scaffold(extendBodyBehindAppBar: true, appBar: GlassTitleBar(title: l10n.mineTitle, ...), body: ListView(...))`
  - ListView 顶部放 ProfileCard，下方 4 个分组改用 `SettingsCard + SettingsNavItem`
  - 所有 onTap / ref.watch / 条件分支原样保留

### 步骤 4：批量改造设置子页

对 `lib/pages/settings/` 下 19 个子页统一改造：
- `PrimaryHeader(showBack: true, title: ...)` → `GlassTitleBar(title: ..., showBack: true, onBack: ...)`
- `Scaffold` 添加 `extendBodyBehindAppBar: true`
- `ListView` padding 改为 `EdgeInsets.fromLTRB(16, statusBar+56+16, 16, 16+bottomSafe)`
- `SectionCard(margin: EdgeInsets.zero, child: Column[AppListTile, BeeTokens.cardDivider, AppListTile, ...])` → `SettingsCard(children: [SettingsNavItem, SettingsNavItem, ...])`（去掉 Divider）
- Switch 项：`AppListTile(trailing: Switch.adaptive(...))` → `SettingsToggleItem(...)`
- 自定义 trailing（进度条 / 状态图标）：`AppListTile(trailing: ...)` → `SettingsNavItem(trailing: ...)`
- 弹窗（`AlertDialog` / `showModalBottomSheet` / `showWheelTimePicker`）原样保留
- GridView（ personalize_page / header_skin_page）原样保留，仅外层容器跟随

### 步骤 5：验证与回归

- 运行 `flutter analyze`，确保无新增 issue
- 人工核对每个设置页的 onTap 跳转、Switch 状态、弹窗、条件分支
- 检查 i18n 切换（zh / zh_TW / en / ko）后文案正确
- 检查暗色模式下视觉一致性
- 检查 iOS / Android 平台差异项（打赏、评分、提醒页 Android 专用按钮）

## 4. UI 规格速查表

### 4.1 颜色

| 语义 | 亮色 | 暗色 | Token |
|---|---|---|---|
| 页面背景 | grey.shade50 (#FAFAFA) | Colors.black | `BeeTokens.scaffoldBackground(context)` |
| 卡片表面 | Colors.white | #1C1C1E | `BeeTokens.surface(context)` |
| 强调色 | 用户主题色（默认 #F8C91C） | 同亮色 | `Theme.of(context).colorScheme.primary` |
| 标题文字 | #111827 | Colors.white | `BeeTokens.textPrimary(context)` |
| 次要文字 | black54 | white 70% | `BeeTokens.textSecondary(context)` |
| 标题栏 tint | #FFFFFF alpha 0.20 | #181A22 alpha 0.20 | 内联 |

### 4.2 间距

| 用途 | 值 |
|---|---|
| 页面水平 padding | 16 |
| 卡片圆角 | 16 |
| 分区间距 | 24 |
| 分组标题与卡片间距 | 8 |
| 列表底部收尾 | 32 |
| 设置项水平 padding | 16 |
| 设置项垂直 padding（导航项） | 14 |
| 设置项垂直 padding（带 trailing 项） | 12 |
| 图标与文字间距 | 12 |
| 分组标题左缩进 | 8 |
| 涟漪圆角 | 12 |
| 图标盒 padding | 8 |
| 图标盒圆角 | 10 |

### 4.3 字号

| 角色 | 字号 | 字重 |
|---|---|---|
| 标题栏标题 | 17 | w500 |
| 列表项标题 | 14 | w500 |
| 列表项副标题 | 12 | w400 |
| 分组小标题 | 12 | w600 |
| 设置项图标 | 24 | - |
| 图标盒内图标 | 20 | - |

### 4.4 组件结构示例

**MinePage 结构**：
```
Scaffold(extendBodyBehindAppBar: true)
├─ appBar: GlassTitleBar(title: '我的')
└─ body: ListView
   ├─ ProfileCard (headerSkin 背景, 16px 圆角)
   │  ├─ Row: 头像 + 问候语/昵称 + 小眼睛
   │  └─ Row: 3 列 _StatCell
   ├─ SizedBox(height: 24)
   ├─ SettingsSectionLabel('云同步与备份')
   ├─ SizedBox(height: 8)
   ├─ SettingsCard
   │  ├─ SettingsNavItem(icon: cloud_queue, title: '云服务', ...)
   │  └─ SettingsNavItem(icon: cloud_sync, title: '同步状态', trailing: 状态图标, ...)
   ├─ SizedBox(height: 24)
   ├─ SettingsSectionLabel('功能管理')
   ├─ ... 
   └─ SizedBox(height: 32)
```

**设置子页结构**：
```
Scaffold(extendBodyBehindAppBar: true)
├─ appBar: GlassTitleBar(title: l10n.xxx, showBack: true)
└─ body: ListView
   ├─ SettingsSectionLabel('分组1')
   ├─ SizedBox(height: 8)
   ├─ SettingsCard
   │  ├─ SettingsNavItem(useIconBox: true, icon: ..., title: ..., onTap: ...)
   │  ├─ SettingsNavItem(useIconBox: true, ...)
   │  └─ SettingsToggleItem(useIconBox: true, ...)
   ├─ SizedBox(height: 24)
   ├─ ...
   └─ SizedBox(height: 32)
```

## 5. 边界条件与潜在风险

### 5.1 风险点 1：`extendBodyBehindAppBar` 与现有 `PrimaryHeader` 冲突

- **风险**：MinePage 原 `PrimaryHeader` 自带 SafeArea + 主题色背景，与新 `GlassTitleBar` 的 `extendBodyBehindAppBar` 模式不兼容
- **缓解**：MinePage 完全移除 `PrimaryHeader`，改用 `ProfileCard`（独立卡片）承载原头部内容；ProfileCard 自行处理 SafeArea（通过 `MediaQuery.padding.top` 计算 ListView 顶部 padding 时已包含状态栏高度）

### 5.2 风险点 2：头部皮肤在子页消失

- **风险**：用户已选择的头部皮肤在设置子页不再显示，可能产生「功能丢失」感知
- **缓解**：皮肤功能本身未删除（MinePage 仍可见可切换），仅视觉呈现位置变化；在 ProfileCard 中突出展示皮肤背景，强化「皮肤仍生效」的感知

### 5.3 风险点 3：暗色模式下卡片与背景对比度

- **风险**：wait-home 暗色模式页面背景纯黑、卡片 #181818，对比度较低；BeeCount 暗色模式页面背景纯黑、卡片 #1C1C1E，对比度也较低
- **缓解**：直接复用 BeeToken 现有暗色值（#1C1C1E），与原 `SectionCard` 暗色表现一致，用户已习惯

### 5.4 风险点 4：`LiquidGlassTitleBar` 移植后搜索框/第二行 API 未使用

- **风险**：移植的 `LiquidGlassTitleBar` 包含搜索框、第二行、功能键等设置页用不到的能力，可能产生「死代码」警告
- **缓解**：保留完整 API（未来其他页面可复用），构造时仅传 `showSearch: false` / `showActions: false` / `showSecondRow: false`；`flutter analyze` 不会对未使用的可选参数报警告

### 5.5 风险点 5：iOS 平台特定项（打赏、评分）

- **风险**：`Platform.isIOS` 条件分支散落在 MinePage 中，改造时容易遗漏
- **缓解**：在改造 MinePage 时**逐行对照原文件的 onTap / 条件分支**，使用 TodoWrite 跟踪每个设置项的迁移；改造完成后人工核对 iOS 专属项是否正确显示/隐藏

### 5.6 风险点 6：`reminder_settings_page.dart` 不使用 SectionCard 的特例

- **风险**：该页原直接用 `Container + SwitchListTile + OutlinedButton`，与其他子页结构不同
- **缓解**：统一改造为 `SettingsCard + SettingsToggleItem`；Android 专用的 `OutlinedButton` 行保留为 `SettingsCard` 内的 `Padding` 子节点

### 5.7 风险点 7：i18n key 遗漏

- **风险**：批量改造时可能误删 i18n 调用，导致文案硬编码或缺失
- **缓解**：所有文案必须通过 `AppLocalizations.of(context).xxx` 调用；改造后运行 `flutter gen-l10n` 确认无 key 缺失；切换 4 种语言（zh / zh_TW / en / ko）人工验证

## 6. 验证计划

1. `flutter analyze` 无新增 issue
2. 启动 App，进入「我的」Tab，核对 MinePage 视觉与功能
3. 逐个进入 19 个设置子页，核对视觉与功能
4. 切换暗色模式，核对暗色视觉
5. 切换 4 种语言，核对 i18n
6. 在 iOS 模拟器核对打赏、评分项；在 Android 模拟器核对提醒页 Android 专用按钮
7. 切换不同头部皮肤，核对 ProfileCard 背景变化
