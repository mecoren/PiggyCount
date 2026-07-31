# UI 优化评审落地 - 设计文档

> 源文档：[docs/design/UI_OPTIMIZATION_REVIEW.md](../../docs/design/UI_OPTIMIZATION_REVIEW.md)
> 范围：P0 统一头部 + 恢复皮肤 / P1 对齐高价值表面 / P2 间距排版审计
> 目标：在不牺牲可读性的前提下，恢复被孤立的皮肤个性化、消除 app 级模糊性能开销、与底部导航栏视觉语言统一。

---

## 1. 需求理解

评审文档已对项目现状做了代码核验，结论是当前 app 头部存在三重割裂：
1. **材质分裂**：头部 = 玻璃（模糊页面内容、不渲染皮肤）；导航栏 = 95% 实色；分段控件 = α0.55 半透明
2. **皮肤孤立**：`PrimaryHeader` 是唯一渲染 `HeaderSkin` 的组件，但它未被任何页面调用 → 全 app 头部均无皮肤个性化
3. **间距三值共存**：头部水平内边距 8（PrimaryHeader）/ 12（pageHorizontalMargin）/ 16（GlassHeader）

本次落地按文档建议方向：以导航栏的「95% 实色」为基准，头部收敛为「95% 中性实色 + 直渲 HeaderSkin + 1px 高光线」，分段控件对齐，间距令牌化。

## 2. 关键技术决策

### 2.1 新建 `PiggyHeader` 系列组件，保留 `Glass*` 标 `@Deprecated`

**决策**：在 [lib/widgets/ui/piggy_header.dart](../../lib/widgets/ui/piggy_header.dart) 新建三个组件，与 `Glass*` 一一对应、API 兼容：

| 新组件 | 替换 | 实现PreferredSize | 用法 |
|---|---|---|---|
| `PiggyTitleBar` | `GlassTitleBar` | 是 | `Scaffold.appBar` |
| `PiggyHomeBar` | `GlassHomeBar` | 是 | `Scaffold.appBar`（汉堡键） |
| `PiggyHeader` | `GlassHeader` | 否 | `Scaffold.body` 第一个子节点 |

`Glass*` 与 `PrimaryHeader` 全部加 `@Deprecated('Use PiggyTitleBar/PiggyHomeBar/PiggyHeader instead')`，但保留实现以便分批迁移；不在本次删除。

**理由**：
- 三组件 API 完全对应 → 50+ 页面的迁移是机械替换（`Glass X(` → `Piggy Y(`），可分批合入、可回滚
- 保留 `Glass*` 作为 `@Deprecated` 可选路径，符合文档「保留为可选/降级路径」的结论
- 不引入第四套头部组件——`PiggyHeader` 内部共享同一 `_PiggyHeaderShell` 渲染逻辑

### 2.2 视觉层结构：四层 Stack，无 BackdropFilter

**决策**：`_PiggyHeaderShell` 用 `Stack` 渲染四层，**完全去掉 `BackdropFilter`**：

```
Stack
 ├─ 层 A：95% 中性实色背景（复用 PiggyTokens.tabBarBackground）
 ├─ 层 B：HeaderSkin 装饰层（Opacity 0.85，Positioned.fill）
 ├─ 层 C：SafeArea(bottom: false) + 前景内容
 └─ 层 D：0.5px 底部高光线（onSurface α0.15 暗 / α0.08 亮，沿用 GlassHeader）
```

**理由**：
- 去掉 `BackdropFilter` → 消除滚动时持续的模糊重算，性能收益直接
- 复用 `tabBarBackground` token → 与底部导航栏同色，视觉语言统一
- 高光线沿用 `GlassHeader` 既有参数 → 视觉零退化
- 皮肤层 `Opacity 0.85` 是文档 §4 护栏的最低保险：即便皮肤亮色饱和（aurora/sunset/sakura），文字落点仍接近中性，确保 ≥4.5:1

### 2.3 皮肤渲染：直渲 `HeaderSkin`，不改 builder 契约

**决策**：`_PiggyHeaderShell` 是 `ConsumerWidget`，内部：

```dart
final skin = headerSkinById(ref.watch(headerSkinProvider));
final primary = ref.watch(primaryColorProvider);
// ...
if (skin != null)
  Positioned.fill(
    child: Opacity(
      opacity: 0.85,
      child: skin.builder(primary, isDark),
    ),
  ),
```

**理由**：
- `HeaderSkin.builder(Color primary, bool isDark)` 契约不变 → 20+ 款皮肤零改动
- 皮肤本身已按「跟随主题色」设计，在 95% 中性底上呈现「主题色装饰 + 中性底」的层次，符合文档「在不引入模糊的前提下获得通透景深」的目标
- 0.85 不透明度同时解决文档 §4 的「亮色皮肤叠深字跌破 4.5:1」风险

### 2.4 `bottomOpaque` / `blur` / `maxSigma` 等参数保留但忽略

**决策**：`PiggyTitleBar` / `PiggyHeader` 保留 `bottomOpaque`、`blur`、`maxSigma`、`minSigma`、`showHighlightLine`、`scrollOffsetListenable` 参数（均为 `@Deprecated` 内部忽略），让调用点可零改动迁移。

**理由**：迁移阶段不强制清理这些参数；待全量替换完成、`Glass*` 删除时再一并清理。

### 2.5 P1-2 分段控件：去模糊，改 95% 实色

**决策**：[wait_sliding_segmented_control.dart:144-187](../../lib/widgets/ui/wait_sliding_segmented_control.dart#L144-L187) 改造：
- 移除 `BackdropFilter` 与 `ClipRRect`（无模糊需求）
- `color: surface.withValues(alpha: 0.55)` → `color: PiggyTokens.tabBarBackground(context)`（95% 实色）
- 保留：顶部高光线渐变、外圆角 `radiusLg`、外边框 `outline α0.3`、滑动胶囊

**理由**：与导航栏/头部同色，消除材质分裂；去 `BackdropFilter` 后分段控件在列表滚动时不再触发额外模糊重算。

### 2.6 P1-3 对话框：加 1px 顶部高光线

**决策**：[dialog.dart](../../lib/widgets/ui/dialog.dart) 在 `AlertDialog` 的 `content` 顶部增加 1px `onSurface α0.08`（亮）/`α0.15`（暗）的高光线，呼应头部语言。背景保持 `surfaceElevated` 实色。

**理由**：文档明确「保持实色（数据可读性优先）；可加 1px 顶部高光线呼应头部语言」。

### 2.7 P2-2 新增 `caption` 文本令牌

**决策**：在 [tokens.dart](../../lib/styles/tokens.dart) `PiggyTextTokens` 新增：

```dart
static TextStyle caption(BuildContext ctx) =>
    Theme.of(ctx).textTheme.bodySmall?.copyWith(
      fontSize: 11,
      color: PiggyTokens.textTertiary(ctx),
    ) ??
    TextStyle(fontSize: 11, color: PiggyTokens.textTertiary(ctx));
```

替换 [transaction_list_item.dart](../../lib/widgets/biz/transaction_list_item.dart) 4 处 `fontSize: 11` 字面量。

**理由**：消除散落魔法数字；`textTertiary` 已是该处既有颜色，与现有视觉零差异。

### 2.8 P2-3 头部水平内边距归一为 12

**决策**：在 `PiggyDimens` 新增 `headerHorizontal = EdgeInsets.symmetric(horizontal: 12)`（值与 `pageHorizontalMargin` 一致），`PiggyHeader` / `PiggyTitleBar` / `PiggyHomeBar` 内部 padding 全部使用此令牌。

**理由**：
- 文档建议「12 或 16 二选一」；选 12 的理由：与 `pageHorizontalMargin` 一致 → 头部内容与页面主体两侧对齐，视觉上更整齐
- 比 `GlassHeader` 现状的 16 略紧凑 4px，但与导航栏/页面边距对齐的收益更大
- 不直接复用 `pageHorizontalMargin` 是为了语义分离（未来若头部需要独立调整不必牵动页面边距）

### 2.9 P2-4 圆角令牌化：仅审计本任务触及文件

**决策**：本次只在新增/修改的文件中把 `BorderRadius.circular(字面量)` 改为 `PiggyDimens.radiusXs…radius3xl`；不做全项目圆角审计（工作量过大、视觉零收益）。

**理由**：避免范围蔓延；其他文件的圆角字面量留待后续独立 PR。

## 3. 实施步骤

### 步骤 1：新建 `PiggyHeader` 系列组件（P0 核心）
- 新建 [lib/widgets/ui/piggy_header.dart](../../lib/widgets/ui/piggy_header.dart)
- 含 `PiggyTitleBar` / `PiggyHomeBar` / `PiggyHeader` + 私有 `_PiggyHeaderShell`
- 复用 `tabBarBackground` / `headerSkinProvider` / `primaryColorProvider`
- 单元自验：在 `home_page` 临时挂一个 `PiggyHeader`，确认皮肤可见、文字可读

### 步骤 2：标记 `Glass*` / `PrimaryHeader` 为 `@Deprecated`
- [glass_title_bar.dart](../../lib/widgets/ui/glass_title_bar.dart) 三个 class 加 `@Deprecated`
- [primary_header.dart](../../lib/widgets/ui/primary_header.dart) 加 `@Deprecated`
- 触发项目内 86 处调用点的 lint 警告，作为迁移进度追踪

### 步骤 3：分批迁移 `Glass*` → `Piggy*`（P0-1）
按目录分 8 批，每批独立可编译可验证：
1. `pages/main/` (home/analytics/ledgers) — 含 `GlassHeader` 自绘用法
2. `pages/settings/` (~20 文件，最大批)
3. `pages/cloud/` (~10 文件)
4. `pages/ai/` (5 文件)
5. `pages/account/` (5 文件)
6. `pages/transaction/` (5 文件)
7. `pages/category/` + `pages/tag/` (7 文件)
8. 其余：auth/budget/calendar/currency/data/donation/maintenance/automation (~12 文件)

迁移规则：
- `GlassTitleBar(...)` → `PiggyTitleBar(...)`，丢弃 `bottomOpaque`/`blur`/`maxSigma`/`minSigma`/`showHighlightLine`/`scrollOffsetListenable` 参数
- `GlassHomeBar(...)` → `PiggyHomeBar(...)`
- `GlassHeader(...)` → `PiggyHeader(...)`
- 内嵌 `ExpandableBottomSheet` 的 `GlassTitleBar(blur: false)` 用法 → `PiggyTitleBar()`（已无 blur 概念）

### 步骤 4：P1 分段控件 + 对话框
- 改造 [wait_sliding_segmented_control.dart](../../lib/widgets/ui/wait_sliding_segmented_control.dart)
- 改造 [dialog.dart](../../lib/widgets/ui/dialog.dart) 加高光线

### 步骤 5：P2 间距/排版令牌化
- [tokens.dart](../../lib/styles/tokens.dart) 新增 `caption` token 与 `headerHorizontal` 令牌
- 替换 [transaction_list_item.dart](../../lib/widgets/biz/transaction_list_item.dart) 4 处 `fontSize: 11`
- 审计本次触及文件的 `BorderRadius.circular(字面量)`

### 步骤 6：P3 对比度 QA（人工验证清单）
不写代码，输出验证清单（见需求文档 §5）。

## 4. 边界条件与潜在风险

### 4.1 亮色皮肤对比度风险
**风险**：aurora/sunset/sakura 等亮色皮肤在 95% 白底 + 0.85 不透明度下，可能让深色标题文字对比度跌破 WCAG 4.5:1。
**缓解**：0.85 是保守值；QA 阶段在 `header_skin_page`（皮肤选择页）逐款切换亮/暗模式 + 主流程标题文字截图验证。若个别皮肤仍不达标，再单独降低该皮肤的内部饱和度（不在本次范围）。

### 4.2 `GlassHeader` 的 `child` 自绘模式迁移
**风险**：home_page / analytics_page / cloud_service_page 使用 `GlassHeader(child: ...)` 自绘头部，迁移到 `PiggyHeader(child: ...)` 时，前景内容布局需保持一致。
**缓解**：`PiggyHeader` 的 `child` API 与 `GlassHeader` 完全一致；迁移后逐页对比截图。

### 4.3 `transaction_editor_page.dart` 的 `bottom` 槽位
**风险**：该页用 `GlassHeader(bottom: ...)` 承载支出/收入/转账分段选择器，`PiggyHeader` 必须保留 `bottom` + `bottomHeight` 参数。
**缓解**：参数 API 一一对应；`preferredSize` 计算逻辑照搬。

### 4.4 `ExpandableBottomSheet` 内嵌的 `GlassTitleBar(blur: false)`
**风险**：[expandable_bottom_sheet.dart](../../lib/widgets/ui/expandable_bottom_sheet.dart) 用 `GlassTitleBar(blur: false)` 表达「纯色无模糊」语义；迁移后 `PiggyTitleBar` 默认就是纯色，需确认视觉效果一致。
**缓解**：`PiggyTitleBar` 默认 95% 实色，与原 `blur: false` 行为等价；迁移后该调用点删除 `blur: false` 参数即可。

### 4.5 `GlassHeader` 的 `scrollOffsetListenable` 滚动渐显
**风险**：原 `GlassHeader` 支持随滚动渐显模糊；`PiggyHeader` 是实色，无渐显需求。若有页面依赖该行为，迁移后视觉会变。
**缓解**：grep 确认 `scrollOffsetListenable` 实际使用情况；若仅 home_page 用且用于「滚动时头部加深」，则 `PiggyHeader` 可通过 `AnimatedContainer` 加 1px 投影模拟，但本次先按「不实现渐显」迁移，留待 QA 反馈再补。

### 4.6 状态栏图标颜色
**风险**：`PrimaryHeader` 现状根据 `isDark` 自动设置状态栏图标亮暗；`GlassHeader` 同样。
**缓解**：`_PiggyHeaderShell` 沿用 `AnnotatedRegion<SystemUiOverlayStyle>` 逻辑，零变更。

### 4.7 暗色模式下 95% `#1C1C1E` 与 `Colors.black` scaffold 的边界
**风险**：暗色模式 scaffold 是 `Colors.black`，头部是 `#1C1C1E α0.95`，两者有微小色差；高光线在暗色下可能不够明显。
**缓解**：这正是导航栏现状，视觉上已验证可接受；本次不调整。

## 5. 验证策略

- **编译验证**：每个步骤完成后 `flutter analyze` 必须无 error
- **视觉验证**：步骤 1 完成后在 `header_skin_page` 切换所有皮肤 + 亮/暗模式截图
- **回归验证**：步骤 3 每批迁移完成后，相关页面进入一次确认无布局错乱
- **性能验证**：步骤 3 完成后，首页/分析页滚动 5 秒，观察是否掉帧（应优于玻璃版本）
- **对比度 QA**：步骤 6 输出清单，逐项人工确认

## 6. 不在本次范围

- 删除 `Glass*` / `PrimaryHeader` 实现（仅标 `@Deprecated`，待下个 PR 清理）
- 全项目圆角字面量审计（仅限本次触及文件）
- 重新设计任何皮肤的内部饱和度（仅靠 0.85 Opacity 护栏）
- Mica 材质（文档已否决）
- 玻璃全量系统（文档已否决）
