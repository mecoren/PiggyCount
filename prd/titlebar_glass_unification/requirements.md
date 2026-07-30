# 顶部状态标题栏玻璃风格统一 - 需求文档

## 1. 用户需求理解

将全 App 的顶部状态标题栏统一为玻璃风格（与设置页一致的 `GlassTitleBar` 组件），替换现有的 `PrimaryHeader`（主题色实底）和唯一的原生 `AppBar`。同时要求：**标题栏底部没有滚动内容透过时，不被其他组件颜色影响**（即底部不应被下方紧贴的彩色组件染色）。

## 2. 改造范围

经调研，全项目共 **59 处** 顶部栏需要统一，分布在 45 个文件中：

| 类型 | 数量 | 现组件 | 处理方式 |
|---|---|---|---|
| 类型 A（单纯标题栏） | 53 处 | `PrimaryHeader` | 替换为 `GlassTitleBar` |
| 类型 B（扩展头部） | 5 处 | `PrimaryHeader` + `content`/`bottom` | 扩展 `GlassTitleBar` 支持对应槽位后替换 |
| 原生 AppBar | 1 处 | `AppBar` | 替换为 `GlassTitleBar` |

### 2.1 类型 A 细分（53 处）

| 子型 | 数量 | 参数组合 | 示例页面 |
|---|---|---|---|
| A0 最简形式 | 约 18 处 | title + showBack | account_edit_page、login_page、export_page、import_page 等 |
| A1 带 subtitle | 约 11 处 | title + subtitle + showBack | ai_settings_page、cloud_sync_page、account_detail_page 等 |
| A2 带 actions | 约 12 处 | title + showBack + actions | category_manage_page、ledgers_page_new、calendar_page 等 |
| A3 紧凑形式 | 6 处 | compact=true | net_worth_trend_page、accounts_page、budget_page 等 |
| A4 带 leadingIcon | 1 处 | leadingIcon + leadingPlain | auto_billing_settings_page |

### 2.2 类型 B 清单（5 处）

| 文件 | 行号 | 使用的扩展参数 | 用途 |
|---|---|---|---|
| `lib/pages/main/home_page.dart` | 674 | `showTitleSection=false` + `content` | 首页自绘头部（PiggyIcon + 账本切换 + 余额统计） |
| `lib/pages/main/analytics_page.dart` | 458 | `showTitleSection=false` + `content` + `leadingIcon` + `compact` | 分析页周期/类型选择器 |
| `lib/pages/transaction/transaction_editor_page.dart` | 109 | `bottom` | 支出/收入/转账分段选择器 |
| `lib/pages/category/icon_picker_page.dart` | 45 | `bottom` | 图标分类 TabBar |
| `lib/pages/cloud/cloud_service_page.dart` | 95 | `content` | 云连接状态卡片 |

### 2.3 原生 AppBar（1 处）

- `lib/pages/cloud/encryption_settings_page.dart:234` — 加密设置页

## 3. 功能性需求（必须 100% 保留）

### 3.1 通用功能

| 项 | 要求 |
|---|---|
| 返回键 | 所有非一级页面保留返回箭头，点击 `Navigator.maybePop()` |
| 标题 | 保留原有 title 文案（含多语言） |
| 副标题 | 11 处使用 subtitle 的页面必须保留副标题文案 |
| 操作按钮 | 所有 actions（IconButton / TextButton）保留且行为不变 |
| 状态栏样式 | 亮色模式深色图标，暗色模式浅色图标（沿用 `PrimaryHeader` 现有 `AnnotatedRegion` 行为） |
| 头部皮肤 | 类型 B 的 `home_page`、`analytics_page` 头部皮肤渲染逻辑保留 |

### 3.2 类型 B 扩展槽位（必须保留功能）

| 槽位 | 使用页面 | 必须保留的行为 |
|---|---|---|
| `bottom` | transaction_editor_page | 支出/收入/转账分段切换 + 取消按钮，切换时表单联动 |
| `bottom` | icon_picker_page | TabBar 切换图标分类，与下方 GridView 联动 |
| `content` | home_page | PiggyIcon + 账本切换胶囊 + 操作按钮 + 余额统计区，点击/长按行为全部保留 |
| `content` | analytics_page | 周期选择器 + 类型选择器 + 分享按钮 |
| `content` | cloud_service_page | 云连接状态卡片（仅非本地模式显示） |

### 3.3 不允许变更的功能

- 不改变任何页面的路由、push/pop 行为
- 不改变任何按钮的回调逻辑
- 不改变 i18n 文案
- 不改变主题色系统、Token 体系
- 不改变 `PrimaryHeader` 组件本身（保留给类型 B 未替换前继续可用，避免波及未替换页面）

## 4. 非功能性需求

### 4.1 视觉一致性

- 所有页面顶部栏统一为玻璃毛玻璃风格
- 56dp 单行 / 80dp 双行（含 subtitle）/ 56dp + bottom 槽位 / content 自绘四种形态
- 标题左对齐紧贴 leading 按钮（与现有 21 个 GlassTitleBar 页面一致）
- 底部高光线（`showHighlightLine`）保留

### 4.2 底部颜色隔离（核心需求）

**场景**：当 `extendBodyBehindAppBar: true` 且 body 第一个组件是彩色卡片/容器时，`GlassTitleBar` 当前的渐变模糊（顶 alpha=1.0 → 底 alpha=0.0）会让 body 颜色从标题栏底部透出，造成"标题栏底部被染色"的视觉问题。

**要求**：
- 当标题栏下方**无滚动内容透过**时（即未传 `scrollOffsetListenable`），底部应保持不透明，隔绝下方组件颜色
- 当标题栏下方**有滚动内容透过**时（即传了 `scrollOffsetListenable`），保留渐变透明效果，让滚动内容自然过渡

### 4.3 性能

- 毛玻璃模糊仍用 `BackdropFilter` + `ShaderMask` 实现，不引入新依赖
- 标题栏用 `RepaintBoundary` 隔离，避免滚动时重绘
- 不允许因扩展组件导致现有 21 个 GlassTitleBar 页面出现性能退化

### 4.4 兼容性

- `GlassTitleBar` 现有 21 处调用必须零改动继续工作（参数向后兼容）
- `PrimaryHeader` 组件保留，不删除（未替换的类型 B 页面继续使用，直到第三批替换完成）
- 现有 body padding 模式 `MediaQuery.of(context).padding.top + 56 + 16` 继续适用

## 5. 边界条件与潜在风险

### 5.1 边界条件

| 场景 | 处理 |
|---|---|
| 亮/暗主题切换 | 标题栏 tint 颜色需跟随主题（已由 `GradientBackdropFilter` 处理） |
| 多语言导致标题过长 | `maxLines: 1` + `TextOverflow.ellipsis`，与现状一致 |
| 含 subtitle 的页面标题栏高度变化 | body padding 需从 `+56` 改为 `+80`，否则内容被遮挡 |
| 类型 B `bottom` 槽位高度变化 | `preferredSize` 需动态计算（firstRow + subtitle + bottom） |
| 横竖屏切换 | `LayoutBuilder` 已处理无界约束回退，无需特殊处理 |
| 无障碍大字号 | 标题栏高度固定 56/80dp，大字号下可能被截断（与现状一致，不引入新问题） |

### 5.2 潜在风险

| 风险 | 等级 | 缓解措施 |
|---|---|---|
| 类型 B 替换后布局错乱 | 高 | 第三批单独处理，每页替换后单独验证 |
| `preferredSize` 计算错误导致 body padding 不准 | 中 | 扩展组件时统一暴露 `firstRowHeight` / `secondRowHeight` 常量 |
| 状态栏图标颜色丢失 | 中 | `GlassTitleBar` 需补 `AnnotatedRegion` 包装 |
| 53 处替换工作量巨大、易遗漏 | 高 | 分批替换，每批跑 `flutter analyze` + 人工抽查 |
| 类型 B 的 `content` 槽位放在 `appBar` 中受 `preferredSize` 限制 | 高 | `content` 模式下 `preferredSize` 需包含 content 高度，或改为 `SliverAppBar` 方案 |
| `PrimaryHeader` 头部皮肤渲染逻辑在 `GlassTitleBar` 中缺失 | 中 | 类型 B 替换时需将皮肤逻辑迁移到 `GlassTitleBar` 的 `content` 槽位 |

## 6. 验收标准

- [ ] 全项目 59 处顶部栏统一为玻璃风格
- [ ] `flutter analyze` 0 errors（warning 不增量）
- [ ] 现有 21 个 GlassTitleBar 页面零改动继续工作
- [ ] 类型 B 5 个页面功能 100% 保留（手动验证）
- [ ] 无滚动内容透过时，标题栏底部不被下方彩色组件染色
- [ ] 亮/暗主题下视觉正确
- [ ] 横竖屏切换无布局错乱

## 7. 实施节奏

经用户确认采用分批替换：

| 批次 | 范围 | 验证点 |
|---|---|---|
| 第一批 | 扩展 `GlassTitleBar` 组件 + 5 个典型类型 A 页面 | 组件扩展点稳定 + 替换模式可复用 |
| 第二批 | 剩余 48 处类型 A + 1 处 AppBar | 全部类型 A 替换完成 |
| 第三批 | 5 处类型 B | 扩展槽位功能保留 |
| 每批收尾 | `flutter analyze` + 人工抽查 3-5 个页面 | 无回归 |
