# 顶部状态标题栏玻璃风格统一 - 设计文档

## 1. 需求理解

将全 App 59 处顶部栏（53 处类型 A `PrimaryHeader` + 5 处类型 B 扩展 `PrimaryHeader` + 1 处原生 `AppBar`）统一为玻璃风格的 `GlassTitleBar`，并解决"标题栏底部无滚动内容时被下方彩色组件染色"的问题。详见同目录 [requirements.md](./requirements.md)。

## 2. 关键技术决策

### 2.1 扩展 `GlassTitleBar` 而非新建组件

**决策**：在现有 [glass_title_bar.dart](../../lib/widgets/ui/glass_title_bar.dart) 基础上扩展，新增 `subtitle` / `bottom` / `content` / `showTitleSection` / `leadingIcon` / `leadingPlain` / `compact` / `scrollOffsetListenable` 参数。

**理由**：
- 现有 21 个设置页已用 `GlassTitleBar`，扩展后参数向后兼容，零改动
- 避免引入第三套顶部栏组件（已有 `PrimaryHeader` + `GlassTitleBar` 两套）
- 复用底层 `LiquidGlassTitleBar` 的渐变模糊能力

### 2.2 通过 `LiquidGlassTitleBar` 第二行机制承载扩展槽位

**决策**：`LiquidGlassTitleBar` 已有 `showSecondRow` / `secondRowLeading` / `secondRowTrailing` 的两行能力，但形态不匹配。新增独立扩展点：
- `subtitle`：作为第一行标题下方小字渲染，第一行高度从 56dp 增至 80dp
- `bottom`：作为标题栏底部独立槽位（PreferredSize 子区域），高度由 `bottomHeight` 参数声明
- `content` + `showTitleSection=false`：完全替换标题行，由调用方自绘（用于类型 B 首页/分析页）

**理由**：
- 复用 `LiquidGlassTitleBar` 现有 `RepaintBoundary` + `Stack` 三层结构（层 A 模糊 / 层 B 内容 / 层 C 高光线）
- `preferredSize` 动态计算：`firstRowHeight(56 或 80) + bottomHeight(若有)`
- 现有 `showSecondRow`/`secondRowLeading`/`secondRowTrailing` 等 API 保留供未来搜索行使用，不冲突

### 2.3 底部颜色隔离方案：双模式模糊

**决策**：在 [gradient_backdrop_filter.dart](../../lib/widgets/ui/gradient_backdrop_filter.dart) 新增"底部不透明"模式，由 `GlassTitleBar` 根据是否传入 `scrollOffsetListenable` 自动切换：

| 模式 | 触发条件 | 渐变 | 适用场景 |
|---|---|---|---|
| 渐变透明（现状） | 传了 `scrollOffsetListenable` | 顶 alpha=1.0 → 底 alpha=0.0 | body 有滚动内容透过（首页/分析页等） |
| 底部不透明（新增） | 未传 `scrollOffsetListenable` | 顶 alpha=1.0 → 底 alpha=1.0（恒定） | body 第一个组件是彩色卡片（设置页/列表页等） |

**实现方式**：`GradientBackdropFilter` 新增 `bottomOpaque` 参数（默认 `false` 保持兼容）。当 `bottomOpaque=true` 时，`ShaderMask` 的渐变 stops 改为 `[0.0, 1.0]` 全程 alpha=1.0，tint 也全程 `maxTintOpacity`。

**理由**：
- 不破坏现有 21 个 GlassTitleBar 页面的视觉（默认 `bottomOpaque=false`，渐变透明行为不变）
- 仅在替换 `PrimaryHeader` 的页面启用 `bottomOpaque=true`（因为 `PrimaryHeader` 原本就是不透明实底）
- 复用 `ShaderMask` + `BackdropFilter` 现有架构，不引入新依赖

### 2.4 替换模式：统一为 `Scaffold.appBar` + `extendBodyBehindAppBar`

**决策**：53 处类型 A 替换时，从「`PrimaryHeader` 在 body Column 第一个子节点」改为「`GlassTitleBar` 在 `Scaffold.appBar` + `extendBodyBehindAppBar: true` + body padding 偏移」，与现有 21 个 GlassTitleBar 页面保持一致。

**替换模板**：
```dart
// 替换前（PrimaryHeader 在 body 内）
return Scaffold(
  body: Column(
    children: [
      PrimaryHeader(
        title: l10n.xxx,
        showBack: true,
        actions: [...],
      ),
      Expanded(child: ...),
    ],
  ),
);

// 替换后（GlassTitleBar 在 appBar）
return Scaffold(
  extendBodyBehindAppBar: true,
  appBar: GlassTitleBar(
    title: l10n.xxx,
    showBack: true,
    actions: [...],
    bottomOpaque: true, // 关键：无滚动内容时底部不透明
  ),
  body: Padding(
    padding: EdgeInsets.only(
      top: MediaQuery.of(context).padding.top + 56 + 16,
    ),
    child: ..., // 原 Expanded 内容
  ),
);
```

**理由**：
- 与现有 21 个 GlassTitleBar 页面模式一致，便于后续维护
- `extendBodyBehindAppBar: true` 让毛玻璃能模糊 body 内容（当有滚动内容透过时）
- body padding 用 `MediaQuery.padding.top + 56 + 16` 与现有页面一致

### 2.5 类型 B 处理：扩展槽位 + 保留头部皮肤

**决策**：
- `transaction_editor_page` / `icon_picker_page`：用新增的 `bottom` 槽位承载分段选择器/TabBar，`preferredSize` 包含 bottom 高度
- `cloud_service_page`：用新增的 `content` 槽位承载连接状态卡片
- `home_page` / `analytics_page`：用 `showTitleSection=false` + `content` 完全自绘头部，头部皮肤逻辑迁移到 `content` builder 中

**理由**：
- 5 处类型 B 的扩展内容形态各异，统一用槽位方式暴露，避免在组件内硬编码
- 头部皮肤逻辑（`headerSkinById` + `skin.builder`）封装为独立函数供 `content` builder 调用

### 2.6 状态栏样式处理

**决策**：`GlassTitleBar` 内部增加 `AnnotatedRegion<SystemUiOverlayStyle>` 包装，根据主题亮度自动设置状态栏图标颜色（亮色模式深色图标，暗色模式浅色图标），与 `PrimaryHeader` 现有行为对齐。

**理由**：现有 21 个 GlassTitleBar 页面可能依赖系统默认状态栏样式，替换 53 处 PrimaryHeader 后必须保证状态栏样式正确。

## 3. 实现步骤

### 步骤 1：扩展 `GradientBackdropFilter` 支持底部不透明

修改 [gradient_backdrop_filter.dart](../../lib/widgets/ui/gradient_backdrop_filter.dart)：
- 新增 `bottomOpaque` 参数（默认 `false`）
- 当 `bottomOpaque=true` 时，`ShaderMask` 渐变改为全程 alpha=1.0，tint 全程 `maxTintOpacity`
- 不破坏现有 21 个 GlassTitleBar 页面的默认行为

### 步骤 2：扩展 `LiquidGlassTitleBar` 支持扩展槽位

修改 [liquid_glass_title_bar.dart](../../lib/widgets/ui/liquid_glass_title_bar.dart)：
- 新增 `subtitle` 参数：渲染在 title 下方，第一行高度 56→80
- 新增 `bottom` 槽位 + `bottomHeight` 参数：`preferredSize` 包含 bottom 高度
- 新增 `content` 槽位 + `showTitleSection` 参数：完全替换标题行
- 新增 `leadingIcon` / `leadingPlain` / `compact` 参数
- 新增 `bottomOpaque` 参数：透传给 `GradientBackdropFilter`
- 新增 `AnnotatedRegion` 包装处理状态栏样式
- 新增 `scrollOffsetListenable` 参数（已存在，确认是否需要调整）

### 步骤 3：扩展 `GlassTitleBar` 薄包装暴露新参数

修改 [glass_title_bar.dart](../../lib/widgets/ui/glass_title_bar.dart)：
- 透传 `subtitle` / `bottom` / `bottomHeight` / `content` / `showTitleSection` / `leadingIcon` / `leadingPlain` / `compact` / `bottomOpaque` / `scrollOffsetListenable`
- 默认 `bottomOpaque=true`（GlassTitleBar 用于替换 PrimaryHeader 的场景，默认底部不透明）
- 现有 21 个调用不传 `bottomOpaque`，需评估是否需要显式设为 `false` 保持视觉一致

### 步骤 4：第一批替换 5 个典型类型 A 页面

替换以下页面，验证扩展组件稳定性 + 替换模式可复用：
- [category_manage_page.dart](../../lib/pages/category/category_manage_page.dart) — A2（带 actions）
- [tag_manage_page.dart](../../lib/pages/tag/tag_manage_page.dart) — A1（带 subtitle + actions）
- [accounts_page.dart](../../lib/pages/account/accounts_page.dart) — A3（compact + actions）
- [ai_settings_page.dart](../../lib/pages/ai/ai_settings_page.dart) — A1（带 subtitle）
- [budget_page.dart](../../lib/pages/budget/budget_page.dart) — A3（compact + actions）

每页替换后跑 `flutter analyze` + 人工抽查视觉。

### 步骤 5：第二批替换剩余 48 处类型 A + 1 处 AppBar

按目录分批替换（cloud/ → ai/ → account/ → category/ → tag/ → transaction/ → budget/ → calendar/ → data/ → currency/ → automation/ → auth/ → maintenance/ → donation/ → main/ledgers_page_new → cloud/encryption_settings_page 的 AppBar）。

每批替换后跑 `flutter analyze`。

> 类型 B 的 5 处替换（第三批）单独执行，因扩展槽位功能复杂，需逐页验证。本设计文档暂不覆盖第三批细节，待第一批验证通过后补充。

## 4. 边界条件与潜在风险

### 4.1 关键风险

| 风险 | 缓解措施 |
|---|---|
| 现有 21 个 GlassTitleBar 页面因 `bottomOpaque` 默认值变化导致视觉退化 | 步骤 3 中评估默认值，必要时让现有 21 页面显式传 `bottomOpaque: false` 保持渐变透明 |
| 类型 B `content` 槽位放在 `appBar` 中受 `preferredSize` 限制 | 类型 B 替换时 `preferredSize` 必须包含 content 高度，或改用 `SliverAppBar` 方案（第三批设计时决策） |
| `subtitle` 导致标题栏高度变化，body padding 不同页面有差异 | 替换时 body padding 统一用 `MediaQuery.padding.top + (subtitle ? 80 : 56) + 16`，提取常量复用 |
| `bottom` 槽位高度计算与 `PreferredSize` 标准模式不兼容 | `bottom` 子组件需自行实现 `PreferredSizeWidget` 或通过 `bottomHeight` 参数声明高度 |
| 状态栏图标颜色在亮/暗主题切换时未跟随 | `AnnotatedRegion` 用 `Theme.of(context).brightness` 动态计算 |

### 4.2 不在本次设计范围

- 不删除 `PrimaryHeader` 组件（保留供第三批未替换的类型 B 临时使用）
- 不改造 `LiquidGlassTitleBar` 的搜索框/第二行 API（保留供未来使用）
- 不改变现有 21 个 GlassTitleBar 页面的 `extendBodyBehindAppBar` 模式
- 不引入 `SliverAppBar` 方案（类型 B 第三批设计时再评估）

## 5. 验证方式

### 5.1 第一批验证清单

- [ ] `flutter analyze` 0 errors
- [ ] 5 个替换页面视觉正确（亮/暗主题）
- [ ] 5 个替换页面功能 100% 保留（返回键、actions、subtitle 文案）
- [ ] 5 个替换页面标题栏底部不被下方彩色组件染色
- [ ] 现有 21 个 GlassTitleBar 页面零改动且视觉无退化
- [ ] 横竖屏切换无布局错乱

### 5.2 第二批验证清单

- [ ] `flutter analyze` 0 errors
- [ ] 48 处类型 A + 1 处 AppBar 全部替换完成
- [ ] 抽查 5-8 个页面视觉与功能正确
- [ ] 全 App 顶部栏风格统一为玻璃风格（除 5 处类型 B）

## 6. 后续工作（第三批，单独设计）

5 处类型 B 替换涉及扩展槽位功能保留，复杂度高，待第一批扩展组件稳定后单独设计：
- `home_page` / `analytics_page` 的 `content` 自绘头部 + 头部皮肤迁移
- `transaction_editor_page` / `icon_picker_page` 的 `bottom` 槽位（TabBar/分段选择器）
- `cloud_service_page` 的 `content` 槽位（连接状态卡片）
