# UI 一致性优化设计文档

## 一、需求理解

将 `prd/piggycount.md` 中识别的 UI 一致性问题（P0-P3）系统性修复，建立 `BeeTokens` 作为颜色/间距的唯一来源，消除三层主题中的冲突值，统一散布代码的取色/取距方式。

## 二、关键技术决策

### 决策 1：颜色单一源策略 — 在 `tokens.dart` 中定义静态颜色常量

**问题**：`BeeTokens.scaffoldBackground(context)` 方法依赖 `BuildContext`，但 `BeeTheme.lightTheme()/darkTheme()` 返回 `ThemeData` 时没有 `BuildContext`，因此 `theme.dart` 无法直接调用 Token 方法。这导致 `theme.dart` 必须独立定义颜色值，进而与 `tokens.dart` 不一致。

**方案**：在 `BeeTokens` 类中新增一组 **静态颜色常量**（不依赖 context），`theme.dart` 与 `tokens.dart` 的方法都引用这些常量。

```dart
// tokens.dart 新增
class BeeTokens {
  // 颜色常量（单一来源）— 供 BeeTheme 与 Token 方法共享
  static const Color _scaffoldBackgroundLight = Color(0xFFFAFAFA); // Colors.grey.shade50
  static const Color _scaffoldBackgroundDark = Colors.black;
  static const Color _dividerLight = Color(0x0F000000); // black 6%
  static const Color _dividerDark = Color(0x1FFFFFFF);  // white 12%
  static const Color _cardBackgroundLight = Colors.white;
  static const Color _cardBackgroundDark = Colors.black;

  // 已有方法改为引用常量
  static Color scaffoldBackground(BuildContext context) =>
      isDark(context) ? _scaffoldBackgroundDark : _scaffoldBackgroundLight;

  static Color divider(BuildContext context) =>
      isDark(context) ? _dividerDark : _dividerLight;
  // ...
}
```

```dart
// theme.dart 改为引用 BeeTokens 常量
import 'styles/tokens.dart';
// ...
scaffoldBackgroundColor: BeeTokens._scaffoldBackgroundLight, // 亮色
// dark: BeeTokens._scaffoldBackgroundDark
```

```dart
// main.dart 移除以下覆盖（让 theme.dart 生效）
// scaffoldBackgroundColor: Colors.white,        // ❌ 删除
// dividerColor: Colors.black.withOpacity(0.06), // ❌ 删除
// cardTheme.color: Colors.white,               // ❌ 删除
```

**理由**：
- 保持 `BeeTokens` 现有 API（`static Color xxx(BuildContext)`）不变，向后兼容
- `theme.dart` 不再独立定义颜色值，从根源消除冲突
- `main.dart` 只做动态主色覆盖（`primaryColor`），不再做静态颜色覆盖
- Dart 中以下划线开头的常量是库私有，外部无法直接访问，强迫走 Token 方法

### 决策 2：`cardTheme.borderRadius` 统一为 `radiusXl`

**方案**：`theme.dart` 的 `darkTheme` 第 98 行将 `BeeDimens.radiusLg` 改为 `BeeDimens.radiusXl`，与 `main.dart` 的亮色主题对齐。

**理由**：`radiusXl` 是更现代的圆角值（与 iOS 16+ 大圆角卡片趋势一致），且亮色模式已使用此值；改暗色模式成本最低。

### 决策 3：`Theme.of(context)` 替换映射表

| 原写法 | 替换为 |
|--------|--------|
| `Theme.of(context).colorScheme.primary` | `BeeTokens.primary(context)` |
| `Theme.of(context).scaffoldBackgroundColor` | `BeeTokens.scaffoldBackground(context)` |
| `Theme.of(context).dividerColor` | `BeeTokens.divider(context)` |
| `Theme.of(context).colorScheme.surface` | `BeeTokens.surface(context)` |
| `Theme.of(context).colorScheme.onSurface` | `BeeTokens.textPrimary(context)` |
| `Theme.of(context).colorScheme.error` | `BeeTokens.error(context)` |
| `Theme.of(context).textTheme.titleMedium` | `BeeTextTokens.title(context)` |
| `Theme.of(context).textTheme.bodyMedium` | `BeeTextTokens.body(context)` |
| `Theme.of(context).brightness == Brightness.dark` | 保留 `isDark` 变量，但内部条件颜色改为 Token |

**保留例外**：
- `Theme.of(context).platform` — Token 系统不涉及平台
- `Theme.of(context).textTheme` 中的样式组合（如 `?.copyWith(color: ...)`）— 需具体分析

### 决策 4：硬编码语义色映射

| 原写法 | 替换为 |
|--------|--------|
| `Colors.red` / `Colors.red[700]` | `BeeTokens.error(context)` |
| `Colors.green` / `Colors.green.shade700` | `BeeTokens.success(context)` |
| `Colors.orange` / `Colors.orange[700]` | `BeeTokens.warning(context)` |
| `Colors.blue` / `Colors.blue[50]` | `BeeTokens.info(context)` |
| `Color(0xFF4CAF50)` (annual_report 绿) | `BeeTokens.chartIncome(context)` |
| `Color(0xFFFF5252)` (annual_report 红) | `BeeTokens.chartExpense(context)` |
| `Color(0xFF1E1E1E)` (home_page 暗卡片) | `BeeTokens.surface(context)` 或新增 `surfaceCardDark` 常量 |

**保留例外**：
- 品牌色字面量（`BeeTheme.honeyGold` 等已有常量定义）
- `personalize_page.dart` 主题色板（28 种预设颜色，是数据而非样式）

### 决策 5：`withOpacity` → `withValues(alpha:)` 批量替换

Dart 已弃用 `withOpacity(double)`，新 API 是 `withValues(alpha: double)`。两者语义略有差异（`withValues` 在 Web 上更高效），但值范围都是 0.0-1.0。

**替换规则**：`.withOpacity(0.x)` → `.withValues(alpha: 0.x)`

### 决策 6：间距体系统一策略 — 保留 `.scaled()`，提取重复常量

**方案**：
- 保留 `.scaled()` 自适应缩放机制不变（已在新页面中使用，删除会引入回退）
- 在 `BeeDimens` 中新增语义化间距常量，替代硬编码的 `EdgeInsets.fromLTRB(12, 4, 12, 8)` 等

```dart
// BeeDimens 新增
class BeeDimens {
  static const EdgeInsets cardMargin = EdgeInsets.fromLTRB(12, 4, 12, 8);
  static const EdgeInsets cardPadding = EdgeInsets.all(16);
  static const EdgeInsets headerPadding = EdgeInsets.symmetric(horizontal: 12, vertical: 8);
  // ...
}
```

- `home_page.dart` 三处 `EdgeInsets.fromLTRB(12, 4, 12, 8)` → `BeeDimens.cardMargin`
- `transaction_editor_page.dart` 的 `EdgeInsets.fromLTRB(8, 4, 8, 0)` 改为 `BeeDimens.headerPadding`（与主流对齐）

**理由**：
- `.scaled()` 是项目内部的缩放机制，删除影响范围大
- 提取常量后即可解决"重复字面量"问题，不必动 `.scaled()`

## 三、实现步骤（5 步）

### 步骤 1：建立颜色单一源（P0）

**文件**：`lib/styles/tokens.dart`、`lib/theme.dart`、`lib/main.dart`

1. 在 `BeeTokens` 中新增静态颜色常量（`_scaffoldBackgroundLight/Dark`、`_dividerLight/Dark`、`_cardBackgroundLight/Dark`）
2. 修改 `BeeTokens.scaffoldBackground(context)`、`divider(context)`、`surface(context)` 等方法引用这些常量
3. `theme.dart` 的 `lightTheme`/`darkTheme` 中 `scaffoldBackgroundColor`、`dividerTheme.color`、`cardTheme.color` 改为引用 `BeeTokens._xxx` 常量
4. `theme.dart` 的 `darkTheme` 中 `cardTheme` 的 `borderRadius` 从 `radiusLg` 改为 `radiusXl`
5. `main.dart` 删除 `scaffoldBackgroundColor`、`dividerColor`、`cardTheme.copyWith(color: Colors.white, ...)` 的覆盖；保留 `primaryColor`、`colorScheme.primary` 等动态主色覆盖
6. `main.dart` 第 507 行 `Colors.black.withOpacity(0.06)` 改为 `BeeTokens._dividerLight`（顺便修 P2）

### 步骤 2：修复 splash_page.dart（P0）

**文件**：`lib/pages/auth/splash_page.dart`

替换：
- `Theme.of(context).primaryColor` → `BeeTokens.primary(context)`
- `Colors.white.withOpacity(0.9)` → `BeeTokens.textOnPrimary(context).withValues(alpha: 0.9)`
- `Colors.black.withOpacity(0.1)` → `Colors.black.withValues(alpha: 0.1)`（阴影色保留为 black，因为阴影不应受主题影响）
- `theme.textTheme.headlineMedium` → `BeeTextTokens.boldTitle(context)` 或保留并 `.copyWith(color: BeeTokens.textOnPrimary(context))`

### 步骤 3：批量 Token 统一（P1）

**文件**：34 个混用 `Theme.of` + `BeeTokens` 的文件（清单见 PRD）

按目录分批处理：
1. `lib/pages/main/` (home_page, mine_page, analytics_page, ledgers_page_new) — 最高密度
2. `lib/pages/settings/` (10+ 文件)
3. `lib/pages/cloud/` (5 文件)
4. `lib/pages/category/` (4 文件)
5. `lib/pages/transaction/` (4 文件)
6. 其余 (ai/, account/, auth/, budget/, tag/, data/, maintenance/)

每文件按决策 3 的映射表替换，保留例外项。

### 步骤 4：替换硬编码语义色 + withOpacity（P1 + P2）

**文件**：约 15 个文件（决策 4 表）

1. 替换 `Colors.red/green/orange` 为 `BeeTokens.error/success/warning(context)`
2. 替换 `home_page.dart` 第 301/423/529 行 `Color(0xFF1E1E1E)` 为 `BeeTokens.surface(context)`
3. 替换 `annual_report_page.dart` 中 `Color(0xFF4CAF50)` → `BeeTokens.chartIncome(context)`，`Color(0xFFFF5252)` → `BeeTokens.chartExpense(context)`
4. 批量替换剩余 `withOpacity(x)` → `withValues(alpha: x)`（涉及 `ai_chat_page`、`calendar_page`、`home_page`、`splash_page`、`icon_picker_page`、`log_center_page`、`searchable_dropdown.dart`）

### 步骤 5：间距常量提取（P3）

**文件**：`lib/styles/tokens.dart`（BeeDimens）、`lib/pages/main/home_page.dart`、`lib/pages/transaction/transaction_editor_page.dart`

1. 在 `BeeDimens` 中新增 `cardMargin`、`cardPadding`、`headerPadding` 等语义化常量
2. `home_page.dart` 三处 `EdgeInsets.fromLTRB(12, 4, 12, 8)` 替换为 `BeeDimens.cardMargin`
3. `transaction_editor_page.dart` PrimaryHeader padding 与主流对齐

## 四、边界条件与潜在风险

### 风险 1：视觉回归

**影响**：背景色从 `Colors.white` (#FFFFFF) 改为 `Colors.grey.shade50` (#FAFAFA) 后，亮色模式下页面背景会从纯白变为极淡灰，视觉上有轻微变化。

**缓解**：
- `Colors.grey.shade50` 是 Material 3 推荐背景色，与卡片白色形成层次感
- 修改后让用户在亮/暗模式下验证一遍

### 风险 2：暗色模式卡片圆角变大

**影响**：`radiusLg` → `radiusXl` 后暗色卡片圆角变大，可能影响紧凑布局。

**缓解**：
- 视觉上更现代，且与亮色模式一致
- 在 dark mode 下抽样检查主要卡片页面

### 风险 3：批量替换遗漏

**影响**：34 个文件批量替换可能遗漏部分位置，或误替换保留例外项。

**缓解**：
- 每批文件用 `Grep` 二次验证：替换后再搜 `Theme.of(context).colorScheme.primary`、`Colors.red\b` 等
- 用 `flutter analyze` 兜底，捕获未定义引用、类型不匹配等错误

### 风险 4：`Theme.of(context).textTheme` 替换的语义差异

**影响**：`BeeTextTokens.title(context)` 与 `Theme.of(context).textTheme.titleMedium` 在 fontSize/fontWeight 上可能略有差异。

**缓解**：
- 替换前先 `Read` `BeeTextTokens` 的定义确认映射关系
- 涉及 `?.copyWith(...)` 链式调用的位置，保留原 `textTheme.xxx` 调用方式但 `.copyWith` 中的颜色改用 Token

### 风险 5：`isDark` 变量保留但内部颜色 Token 化

**影响**：`home_page.dart` 中约 20 处 `final isDark = Theme.of(context).brightness == Brightness.dark`，如果直接删除 `isDark` 会破坏非颜色相关的逻辑（如条件渲染）。

**缓解**：
- 保留 `isDark` 变量本身（可能用于非颜色判断）
- 仅将 `isDark ? colorA : colorB` 形式的颜色三元替换为 Token 调用（Token 内部已封装 isDark 判断）

### 风险 6：保留的 `Colors.black` 阴影色

**影响**：阴影通常应为黑色，不应随主题切换。如果误将 `BoxShadow(color: Colors.black...)` 替换为 Token，会导致暗色模式阴影消失。

**缓解**：阴影色 `Colors.black` 保留不动，仅替换 `withOpacity` → `withValues(alpha:)`。

## 五、验证策略

1. 每完成一个步骤，运行 `flutter analyze` 确认无新增错误
2. 步骤 1-2 完成后，运行 `flutter run` 在亮/暗模式下人工验证主页、设置页、splash 页
3. 步骤 3-4 完成后，用 `Grep` 工具二次扫描遗漏：
   - `grep -r "withOpacity" lib/`
   - `grep -rn "Theme.of(context).colorScheme.primary" lib/pages/`
   - `grep -rn "Colors\.red\b\|Colors\.green\b" lib/pages/`
4. 全部完成后跑现有测试套件（如有），确保无破坏

---

## 六、追加决策（2026-09-19 · U1 字号 ratchet / U2 图表无障碍）

证据全在 `docs/optimization-plan-2026-09-19.md` §13 的「U1/U2」一节，这里只留决策与否决。

### D-1 语义节点用「无 child 的 `Semantics`」塞进 `Stack`，而不是包住图表

`Semantics` 是 `SingleChildRenderObjectWidget` 且 `child` 可空（SDK `basic.dart:7945`）；
在 `Stack(fit: StackFit.expand)` 下它的 `RenderProxyBox.performResize()` 取 `constraints.biggest`，
于是拿到整张图表的矩形 —— 读屏命中区域就是图表本身。
**否决「包一层」写法**：那要把 `analytics_bar_chart.dart` / `line_chart.dart` 各约 150 行整体重排缩进，
而本仓 HEAD 不是 `dart format` 产物（`dart format lib test` 曾重排 357 文件，事故记录在 §13），
一次为样式服务的重排会把真实改动埋进 diff 噪声里。

### D-2 摘要文本生成放 `chart_tooltip_bubble.dart`，两图共用

该文件已经承担「折线图与柱状图共用的气泡布局规则」（`chartTooltipLayout`）。
再开一个 `chart_semantics.dart` 是给一个函数建目录。措辞单一来源，两图不会漂移。

### D-3 `hideAmounts` 为真时摘要只念标签、不念数值

「隐藏金额」是既有隐私开关（锁屏/他人围观场景）。无障碍补全不能反过来把它打穿 ——
这条是硬约束，测试里有专门一例。

### D-4 排除轴标签用 `ExcludeSemantics(child: Text(...))`

`Text` **没有** `excludeSemantics` 命名参数（写了就是编译错误，第一版两处都踩）。
轴标签是刻度、不是信息，留在语义树里会和序列摘要混着念。

### D-5 U1 的门禁只数「`fontSize:` 后紧跟数字」的字面量

`fontSize: PiggyChartTokens.xLabelFontSize` 已经在令牌上，数进去会让基线虚高（pages 344 vs 字面量 340）。
注释行跳过（照 `native_image_dispose_contract_test.dart` 的口径）。
守卫自带自检：两处目录合计 <500 处即红 —— 正则或目录写错时，门禁会静默变成"永远绿"，那是最坏结果。
**否决「按文件钉死基线」**（549 处 / 92 个文件的字面量映射）：维护成本高于它能拦住的东西。
目录级合计的漏洞是「pages 减 2、widgets 加 2 蒙混过关」，接受 —— 下一轮真收敛时本来就要逐文件过。

### D-6 不做：金额侧语义、饼图侧语义

`AmountText` 渲染的是 `Text`，金额已在语义树里；`Semantics(label:)` 是**替换**子节点文本而非追加，
包一层是净退化。三个饼图/构成图各有 4-5 个真实 `Text` 图例，读屏念得出分类名，本轮不重复补。
