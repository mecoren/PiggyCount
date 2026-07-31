# UI 优化评审落地 - 需求文档

> 源文档：[docs/design/UI_OPTIMIZATION_REVIEW.md](../../docs/design/UI_OPTIMIZATION_REVIEW.md)
> 关联设计：[design.md](./design.md)

## 1. 用户需求理解

依据评审文档，对项目头部组件、底部导航栏、分段控件、对话框、卡片与列表做一次性视觉一致性优化。核心方向：统一采用「95% 实色 + 头部直渲皮肤」视觉语言；玻璃材质不做全量系统；Mica 不采用。本次覆盖 P0 / P1 / P2 三个优先级。

## 2. 改造范围

### 2.1 总览

| 优先级 | 范围 | 工作量 | 风险 |
|---|---|---|---|
| P0 | 新建 `PiggyHeader` 系列 + 标记 `Glass*`/`PrimaryHeader` deprecated + 迁移 86 处调用 | 大 | 中（亮色皮肤对比度） |
| P1 | 分段控件去模糊改实色 + 对话框加高光线 | 小 | 低 |
| P2 | 新增 `caption`/`headerHorizontal` 令牌 + 替换 `fontSize:11` 散落 + 局部圆角令牌化 | 小 | 低 |

### 2.2 P0 调用清单（86 处 / 68 文件）

经 grep `GlassTitleBar\(|GlassHomeBar\(|GlassHeader\(` 实测统计：

| 组件 | 调用处数 | 文件数 | 备注 |
|---|---|---|---|
| `GlassTitleBar` | 78 | 64 | 含部分文件多实例（如 `category_detail_page` 3 处、`cloud_service_page` 3 处） |
| `GlassHomeBar` | 1 | 1 | `lib/pages/main/ledgers_page_new.dart` |
| `GlassHeader` | 7 | 5 | `home_page` / `analytics_page` / `cloud_service_page`×3 / `transaction_editor_page` |
| **合计** | **86** | **68** | （`glass_title_bar.dart` 自身定义不计） |

### 2.3 P0 涉及文件分组（按迁移批次）

| 批次 | 目录 | 文件数 |
|---|---|---|
| 1 | `pages/main/` | 3（home/analytics/ledgers） |
| 2 | `pages/settings/` | ~20 |
| 3 | `pages/cloud/` | ~10 |
| 4 | `pages/ai/` | 5 |
| 5 | `pages/account/` | 5 |
| 6 | `pages/transaction/` | 5 |
| 7 | `pages/category/` + `pages/tag/` | 7 |
| 8 | `pages/{auth,budget,calendar,currency,data,donation,maintenance,automation}/` | ~12 |
| - | `widgets/ui/expandable_bottom_sheet.dart`（内嵌 GlassTitleBar） | 1 |

### 2.4 P1 涉及文件

| 文件 | 行号 | 改动 |
|---|---|---|
| `lib/widgets/ui/wait_sliding_segmented_control.dart` | 144-187 | 去 `BackdropFilter`/`ClipRRect`，背景改 `tabBarBackground` 95% 实色 |
| `lib/widgets/ui/dialog.dart` | `_show` 内 `AlertDialog.content` | 顶部加 1px 高光线 |

### 2.5 P2 涉及文件

| 文件 | 行号 | 改动 |
|---|---|---|
| `lib/styles/tokens.dart` | `PiggyDimens` / `PiggyTextTokens` | 新增 `headerHorizontal` 令牌、`caption` 文本样式 |
| `lib/widgets/biz/transaction_list_item.dart` | 116, 151, 321, 399 | 4 处 `fontSize: 11` → `PiggyTextTokens.caption(context)` |
| 本次触及的所有文件 | - | `BorderRadius.circular(字面量)` → `PiggyDimens.radiusXs…radius3xl`（仅限本次修改文件） |

## 3. 功能性需求（必须 100% 保留）

### 3.1 P0 通用功能

| 项 | 要求 |
|---|---|
| 返回键 | 所有非一级页面保留返回箭头，点击 `Navigator.maybePop()` |
| 标题文案 | 保留原有 title/subtitle（含多语言） |
| 操作按钮 | 所有 actions（IconButton/TextButton）保留且行为不变 |
| 状态栏样式 | 亮色模式深色图标，暗色模式浅色图标（沿用 `AnnotatedRegion`） |
| 头部皮肤 | `PiggyHeader` 内部读取 `headerSkinProvider` 渲染皮肤，全 app 头部恢复皮肤个性化 |
| 暗色模式 | 头部底色 `#1C1C1E α0.95`，皮肤渲染按 `isDark=true` 分支 |
| 亮色模式 | 头部底色 `Colors.white α0.95`，皮肤渲染按 `isDark=false` 分支 |

### 3.2 P0 自绘头部槽位（必须保留功能）

| 槽位 | 使用页面 | 必须保留的行为 |
|---|---|---|
| `child` | home_page | PiggyIcon + 账本切换胶囊 + 操作按钮 + 余额统计区，点击/长按行为 |
| `child` + `leadingIcon` + `compact` | analytics_page | 周期/类型选择器 |
| `child` ×3 | cloud_service_page | 云连接状态卡片（多处自绘） |
| `bottom` + `bottomHeight` | transaction_editor_page | 支出/收入/转账分段切换 + 取消按钮，切换时表单联动 |
| `bottom` | icon_picker_page | TabBar 切换图标分类 |
| `content` | cloud_service_page | 云连接状态卡片 |

### 3.3 P1 功能保留

| 项 | 要求 |
|---|---|
| 分段控件拖拽 | 保留 `onHorizontalDragStart/Update/End` 拖拽滑动选择行为 |
| 分段控件点击 | 保留 `onTapUp` 点击选择行为 |
| 滑动胶囊 | 保留 `accentColor` 胶囊 + 圆角 + 阴影 |
| 顶部高光线 | 保留渐变高光（与现状一致） |
| 对话框 | 实色背景 `surfaceElevated` 不变；按钮、文案、布局不变 |

### 3.4 P2 功能保留

| 项 | 要求 |
|---|---|
| `transaction_list_item` 视觉 | 4 处 `fontSize: 11` 替换为 `caption` 令牌后，字号/颜色/字重必须与现状完全一致 |
| 圆角 | 替换为令牌的圆角值必须与原字面量数值一致（如 12 → `radiusLg`=12） |

## 4. 非功能性需求

### 4.1 性能

| 项 | 要求 |
|---|---|
| `BackdropFilter` 调用 | `PiggyHeader` 内部禁止使用；分段控件迁移后禁止使用 |
| 滚动流畅度 | 首页/分析页迁移后，滚动 5 秒内无明显掉帧（应优于玻璃版本） |
| RepaintBoundary | `PiggyHeader` 外层包裹 `RepaintBoundary`，与 `GlassHeader` 一致 |

### 4.2 可读性 / 对比度

| 项 | 要求 |
|---|---|
| 文字对比度 | 95% 中性底上 `onSurface` 文字 ≥ WCAG 2.1 AA（正文 4.5:1，大字 3:1） |
| 皮肤层不透明度 | `HeaderSkin` 渲染 Opacity ≤ 0.85（护栏值） |
| 文字颜色 | 统一 `onSurface`；禁止在不可控背景用次级色作主文 |

### 4.3 兼容性

| 项 | 要求 |
|---|---|
| `Glass*` / `PrimaryHeader` | 标 `@Deprecated` 但保留实现，确保未迁移页面仍可编译 |
| `bottomOpaque`/`blur`/`maxSigma` 等参数 | `PiggyHeader` 接受但内部忽略，标记 `@Deprecated` |
| Flutter SDK | 不变更最低 SDK 版本 |

## 5. 验证清单（P3 对比度 QA）

不写代码，按以下清单人工验证。每项需在亮/暗模式各截图一次：

### 5.1 皮肤对比度（在 `header_skin_page` 逐款切换）

| 皮肤 | 亮色模式标题可读性 | 暗色模式标题可读性 |
|---|---|---|
| none（纯实色底） | □ | □ |
| aurora | □ | □ |
| sunset | □ | □ |
| sakura | □ | □ |
| galaxy | □ | □ |
| mountains | □ | □ |
| 其余 14 款 | □ | □ |

### 5.2 主流程页面头部

| 页面 | 验证点 |
|---|---|
| home_page | 自绘头部布局完整，余额统计区无遮挡 |
| analytics_page | 周期/类型选择器可切换 |
| ledgers_page_new | 汉堡键可点击 |
| transaction_editor_page | 支出/收入/转账分段切换正常 |
| 各 settings 页（任选 5 个） | 标题/返回键/actions 完整 |
| 各 cloud 页（任选 3 个） | 标题/返回键完整 |

### 5.3 P1 / P2 验证

| 项 | 验证点 |
|---|---|
| 分段控件 | 拖拽/点击切换正常；95% 实色与导航栏同色 |
| 对话框 | 顶部高光线可见但不突兀；按钮/文案不变 |
| transaction_list_item | 4 处小字字号/颜色与现状一致 |
| 头部水平内边距 | 头部内容左右边缘与页面主体两侧对齐（12px） |

## 6. 验收标准

1. `flutter analyze` 无 error，无新增 warning（除 `@Deprecated` 自身告警）
2. 86 处 `Glass*` 调用全部迁移到 `Piggy*`，grep `GlassTitleBar\(|GlassHomeBar\(|GlassHeader\(` 在 `lib/pages/` 与 `lib/widgets/ui/expandable_bottom_sheet.dart` 下零命中
3. `PrimaryHeader` grep 在 `lib/pages/` 下零命中
4. 5.1 / 5.2 / 5.3 清单全部 □ 勾选
5. 首页滚动 5 秒无明显掉帧
