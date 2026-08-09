---
name: app-background-light-blue
overview: "将应用亮色模式页面/标题栏背景统一改为淡蓝色 #e5eefe（卡片内部保持 #f9f9f9），并将暗黑模式改为淡蓝系深色调背景。同时让交易记账「记一笔」底部抽屉背景与页面背景融为一体。云服务（cloud_service_page）的服务卡片选中态边框与对勾标记统一改用用户主题色，与首页「明细」外层卡片的边框风格保持一致。"
todos:
  - id: light-background
    content: "修改 tokens.dart 亮色 scaffold 背景为淡蓝 #E5EEFE，卡片保持 #F9F9F9，并更新相关注释"
    status: completed
  - id: light-appbar
    content: 修改 theme.dart lightTheme 的 AppBar 背景为淡蓝，复用 scaffoldBackgroundLightStatic
    status: completed
    dependencies:
      - light-background
  - id: dark-background
    content: "修改 tokens.dart 暗色背景为深蓝系常量（页面 #151A24、卡片 #1C2330）并同步注释"
    status: completed
    dependencies:
      - light-background
  - id: dark-theme-appbar
    content: 修改 theme.dart darkTheme 背景/AppBar/卡片为深蓝常量，并同步 primary_header.dart 暗色 headerBg
    status: completed
    dependencies:
      - dark-background
  - id: dark-surface-align
    content: 对齐 tokens.dart 其余暗色 surface（sheet/key/popover 等）到淡蓝系深色调
    status: completed
    dependencies:
      - dark-theme-appbar
  - id: transaction-sheet-bg
    content: 修改 transaction_editor_page.dart 的「记一笔」ExpandableBottomSheet 传入 backgroundColor = scaffoldBackground，让弹窗与页面背景同色
    status: completed
    dependencies:
      - light-background
      - dark-background
  - id: cloud-service-selection-border
    content: 修改 cloud_service_page.dart 的服务卡片选中态边框与对勾圆点颜色：由 PiggyTokens.success 绿色改为用户主题色 primaryColorProvider，与首页「明细」外层卡片边框色一致
    status: completed
    dependencies:
      - transaction-sheet-bg
  - id: verify
    content: 运行 flutter analyze 验证编译通过并核对亮暗两套背景与卡片对比，以及「记一笔」弹窗与页面背景的融合效果
    status: pending
    dependencies:
      - dark-surface-align
      - transaction-sheet-bg
---

## 需求

- 亮色模式：整个应用页面背景改为淡蓝色 `#e5eefe`；卡片内部保持 `#f9f9f9`（当前已是该值，无需改动）。
- 普通页面顶部标题栏（AppBar 背景，当前纯白 `Colors.white`）也改为淡蓝 `#e5eefe`，与页面背景融为一体。
- 暗黑模式：改用淡蓝系深色调（不再用纯黑），保持卡片/弹窗与页面背景的层级对比。

## 核心功能

- 背景色体系集中于 `lib/styles/tokens.dart`（Token 常量）与 `lib/theme.dart`（ThemeData），改动单一来源即可全局生效。
- 卡片内部保持 `#f9f9f9` 不变，仅页面背景、AppBar、暗色背景调整为蓝调。
- 暗色模式采用深蓝灰基调，保证卡片/弹窗/页面层级对比清晰。

## 技术栈

- Flutter（Dart），Riverpod 状态管理，现有 Design Token 体系。
- 背景色由 `PiggyTokens`（`lib/styles/tokens.dart`）静态常量统一管理，`lib/theme.dart` 的亮/暗 ThemeData 引用这些常量。

## 实现方案

### 1. 亮色模式（`lib/styles/tokens.dart` + `lib/theme.dart`）

- `PiggyTokens.scaffoldBackgroundLightStatic`：`0xFFF3F3F3` -> `0xFFE5EEFE`（淡蓝页面背景）。
- `PiggyTokens.cardBackgroundLightStatic`：保持 `0xFFF9F9F9`（卡片内部，符合要求）。
- `lib/theme.dart` `lightTheme`：
- `scaffoldBackgroundColor` 已继承 `scaffoldBackgroundLightStatic`，自动生效。
- `appBarTheme.backgroundColor`：`Colors.white` -> 淡蓝 `0xFFE5EEFE`（复用 `scaffoldBackgroundLightStatic`，保持单一来源）。
- `cardTheme.color` / `dialogTheme.backgroundColor` 保持 `cardBackgroundLightStatic`（#f9f9f9）。

### 2. 暗黑模式（淡蓝系深色调）

- 在 `lib/styles/tokens.dart` 定义/调整深蓝常量：
- `scaffoldBackgroundDarkStatic`：`Colors.black` -> `0xFF151A24`（深蓝灰页面背景）。
- `cardBackgroundDarkStatic`：`Colors.black` -> `0xFF1C2330`（略亮深蓝卡片，与页面形成层级对比）。
- `lib/theme.dart` `darkTheme`：`scaffoldBackgroundColor` / `appBarTheme.backgroundColor` / `cardTheme.color` 同步使用上述深蓝常量。
- `lib/widgets/ui/primary_header.dart` 第 65 行 `headerBg = isDark ? Colors.black : primary`：`Colors.black` 改为复用深蓝页面背景常量（该文件已 import tokens.dart）。
- 评估 `tokens.dart` 中其余暗色 surface（`surfaceSheet`/`surfaceKey`/`surfaceHeader`/`surfacePopoverCard` 等硬编码 `Colors.black`/`#1C1C1E`/`#2C2C2E`）一并对齐到淡蓝系，避免弹窗/底部弹层与蓝色页面对比失衡；弹层/键盘/弹窗建议用 `cardBackgroundDarkStatic`（#1C2330）同级。

### 3. 「记一笔」弹窗背景与页面融合（用户追加）

- 用户在亮色模式下截图反馈：交易记账「记一笔」弹窗背景仍沿用默认卡片色 `#F9F9F9`，与淡蓝页面背景对比突兀，希望弹窗整体背景与页面背景融为一体。
- 影响范围：`transaction_editor_page.dart` 中的 `ExpandableBottomSheet` 调用点（`showTransactionFormBottomSheet` -> `TransactionEditorPage(renderAsBottomSheet: true)` -> `ExpandableBottomSheet`）。
- 其他 2 处 `ExpandableBottomSheet` 用法（`account_edit_page.dart`、`category_selector.dart`）未做改动，避免破坏既有 BottomSheet 的卡片浮层语义。

实现方案：
- 在 `ExpandableBottomSheet` 调用处新增 `backgroundColor: PiggyTokens.scaffoldBackground(context)`。
- `ExpandableBottomSheet.build` 内部第 95 行已经支持 `backgroundColor` 参数，无需修改该组件代码。
- 标题栏 `PiggyTitleBar` 通过 `backgroundColor: bgColor` 已联动跟随，所以标题栏也会同步变成淡蓝/深蓝，与弹窗内容融合。
- 弹窗内部的胶囊/卡片/icon 背景（如 `surfaceCapsule`/`surfaceCategoryIcon` 等）保持原有 token，使内部控件仍有清晰的视觉层级。

### 4. 文档一致性

- 更新 `tokens.dart` 中相关注释（如 `#FAFAFA` -> 淡蓝 `#E5EEFE`、暗色 `#000000` -> 深蓝），保持文档与实现一致。

## 性能与风险

- 改动集中于 Token 常量与 ThemeData，无运行时开销，通过单一来源自动传播到全部页面。
- `Colors.white` 在代码中有大量引用，但绝大多数为海报/文字/主题色背景，不属于页面背景，不做改动，避免无关回归。
- 暗色 surface 家族的调整需逐个核对（sheet/key/popover），确保层级对比仍清晰。
- 「记一笔」弹窗改为页面背景色后，弹窗不再有「悬浮卡片」的视觉差异；用户已确认此为预期行为。其他 BottomSheet 用法保持卡片色不变，互不影响。
- 弹窗内部分段控件（`WaitSlidingSegmentedControl`）、分类 icon 容器、tabs 等均使用语义化 token，在淡蓝背景上仍可清晰区分。

## 目录结构

```
lib/
├── pages/
│   └── transaction/
│       └── transaction_editor_page.dart  # [MODIFY] ExpandableBottomSheet 显式传 backgroundColor = scaffoldBackground
└── widgets/
    └── ui/
        ├── expandable_bottom_sheet.dart   # 无改动（已支持 backgroundColor 参数）
        └── primary_header.dart            # [MODIFY] 暗色 headerBg 由 Colors.black 改为深蓝页面背景常量
```

## 验证

- 运行 `flutter analyze` 确认无编译错误。
- 亮色：页面背景淡蓝 #e5eefe，卡片 #f9f9f9，标题栏淡蓝；「记一笔」弹窗背景淡蓝，与页面融为一体。
- 暗色：页面/卡片/标题栏均为淡蓝系深色调且层级分明；「记一笔」弹窗背景深蓝，与页面融为一体。