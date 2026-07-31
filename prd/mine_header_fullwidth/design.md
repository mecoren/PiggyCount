# MinePage 头部全宽主题色改造 - 设计文档

## 1. 技术决策

### 1.1 布局策略：头部即标题栏

**决策**：去掉 `MinePage` 独立的 `GlassTitleBar`，把 `ProfileCard` 扩展为占据状态栏下方全宽的主题色头部。下方设置列表从头部底部开始滚动。

**理由**：
- 参考图（蜜蜂记账）没有独立标题栏，整个顶部都是蓝色头部区域
- 头像、昵称、统计信息直接在主题色背景上展示，视觉更聚焦
- 与现有 settings_ui_redesign 方案（标题栏 + 白色 ProfileCard）区分，形成更沉浸式个人中心

### 1.2 头部视觉

**决策**：
- `ProfileCard` 去掉水平 margin 和圆角，占满宽度
- 背景使用主题色 `Theme.of(context).colorScheme.primary`
- 保留 `headerSkinProvider` 作为可选装饰层覆盖在主题色之上（如果用户选了皮肤）
- 头像、昵称行、统计数字使用白色/高对比度文字
- 统计恢复为三列：记账天数 / 总笔数 / 账本结余

**权衡**：
- 不再显示「我的」标题文字，但 Tab 栏已高亮当前 Tab，语义足够
- 头部皮肤在主题色之上以半透明/叠加形式呈现，保持功能不丢失

### 1.3 列表与头部衔接

**决策**：
- 身体使用 `Column`：顶部固定 `ProfileCard`，下方 `Expanded` 包裹 `ListView`
- 第一个设置卡片顶部与头部底部直接衔接，通过设置卡片自身的 16px 顶部圆角形成自然过渡
- 列表顶部 padding 为 0，由头部自身高度决定内容起始位置

## 2. 文件改动清单

### 2.1 修改文件

| 文件路径 | 改动要点 |
|---|---|
| `lib/widgets/biz/profile_card.dart` | 去掉圆角和水平边距；背景改为主题色；文字/图标颜色适配深色背景；统计恢复为三列 |
| `lib/pages/main/mine_page.dart` | 移除 `appBar: GlassTitleBar(...)`；`body` 改为 `Column`：顶部 `ProfileCard` + `Expanded(ListView)` |

### 2.2 不修改的文件

- 设置子页（保留 GlassTitleBar）
- `SettingsCard` / `SettingsNavItem` / `SettingsSectionLabel`
- 共享组件 `AppListTile` / `SectionCard` / `PrimaryHeader`

## 3. 实现步骤

1. **改造 `ProfileCard`**：
   - 移除 `ClipRRect` 圆角和水平 margin
   - 背景色改为主题色，皮肤层作为叠加装饰
   - 昵称、统计数字、标签文字改为白色/高对比色
   - 小眼睛图标改为白色
   - 统计改为三列：记账天数 / 总笔数 / 账本结余

2. **改造 `MinePage`**：
   - 移除 `appBar`
   - `body` 改为 `Column`
   - `ProfileCard` 放在 Column 顶部，无额外 padding
   - `Expanded` 包裹 `ListView`，顶部 padding 设为 0

3. **验证**：
   - 运行 `flutter analyze`
   - 核对滚动时头部固定、设置卡片从头部下方开始

## 4. 边界条件与潜在风险

1. **状态栏文字颜色**：主题色头部上状态栏文字需要是白色（暗色状态栏图标）。Flutter 默认根据 AppBar 亮度推断，移除 AppBar 后需手动通过 `SystemChrome.setSystemUIOverlayStyle` 设置。
2. **暗色模式**：主题色在暗色模式下可能不同，文字颜色需要足够对比度。
3. **头部皮肤冲突**：某些皮肤可能是浅色或复杂图案，叠加在主题色上可能改变预期效果。保留皮肤功能，视觉上以皮肤覆盖主题色为准。
4. **刘海屏安全区**：头部内容需要避开状态栏，通过 `MediaQuery.padding.top` 给头像区域加顶部 padding。
