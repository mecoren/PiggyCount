# 小猪粉主题与 UI 精修 - 设计文档

## 1. 需求理解

本次对 3 项 UI 需求做整体精修：(1) 把「我的」页 ProfileCard 的结余提升为标题式展示、设置子页标题去玻璃、开关组件按 wait-home 风格全量替换；(2) 主题色新增「小猪粉」为默认并重排前三；(3) debug 模式右下角主题切换按钮改为玻璃质感记账按钮。详见同目录 [requirements.md](./requirements.md)。

## 2. 关键技术决策

### 2.1 ProfileCard 标题化（需求 1a）

**决策**：重构 [ProfileCard](../../lib/widgets/biz/profile_card.dart) 内部 Column 结构，在问候语行下方、三列统计上方插入「结余标题区」：小字标签 + 大号金额，视觉对齐资产页 `_buildNetWorthContent`。

**布局**（自上而下）：
1. 头像（既有，保留）
2. 问候语 + 昵称 + 小眼睛（既有，保留）
3. **新增结余标题区**：
   - 标签 `l10n.mineCurrentBalance`（"账本结余"），12pt、`textTertiary` 色
   - 金额用 `AmountText`，约 26pt bold，颜色跟随正负（正=主文字色 / 负=error 色），与资产页一致
4. 记账天数 / 总笔数 二列统计（保留，从三列改为二列，结余已上提）

**理由**：
- 复用既有 `_StatCell` 渲染天数 / 笔数，仅减少一列
- 标签直接复用 `mineCurrentBalance`，无需新增文案
- 金额正负配色与资产页 `singleNw.netWorth >= 0 ? incomeColor : expenseColor` 语义一致（这里用 textPrimary/error 区分，与 ProfileCard 现有 `_StatCell` 配色保持一致）

**保留项**：头像编辑、昵称编辑、小眼睛、头部皮肤层、PiggyCount Cloud 头像同步、`scaled` 缩放。

### 2.2 设置页标题去玻璃（需求 1b）

**决策**：为 20 个设置子页的 `GlassTitleBar` 调用追加 `blur: false` 参数。

**机制验证**：[liquid_glass_title_bar.dart](../../lib/widgets/ui/liquid_glass_title_bar.dart) `_buildBlurLayer` 在 `blur == false` 时返回 `ColoredBox(color: backgroundColor ?? colorScheme.surface)`——纯色实底，无 BackdropFilter，正是「无玻璃效果」。返回键 / 标题 / actions / `bottomOpaque` / 高光线等行为均不变。

**理由**：
- `GlassTitleBar` 已暴露 `blur` 参数（透传到 `LiquidGlassTitleBar`），零架构改动
- 不新建组件，避免引入第三套标题栏（与 `titlebar_glass_unification` 决策一致：只扩展不新增）
- 设置子页 body 顶部 padding 已是 `MediaQuery.padding.top + 56 + 16`，不受 blur 切换影响

**范围**：`lib/pages/settings/` 下 20 处 + `personalize_page.dart`。每处 `appBar: GlassTitleBar(...)` 内补 `blur: false,`。

### 2.3 开关组件全量替换（需求 1c）

**决策**：在 [theme.dart](../../lib/theme.dart) `lightTheme` / `darkTheme` 新增 `switchTheme`（参照 wait-home），并将所有 `Switch.adaptive` / 裸 `Switch` 统一为 `Switch`（Material）。

**switchTheme 规格**（亮/暗一致，accent 取 `primaryColor`）：
| 属性 | 选中态 | 未选中态 |
|---|---|---|
| thumbColor | 白色 | 白色 |
| trackColor | `primaryColor`（纯色） | `onSurfaceVariant` × 0.3(亮) / ×0.35(暗) |
| trackOutlineColor | transparent | transparent |
| trackOutlineWidth | 0 | 0 |
| materialTapTargetSize | shrinkWrap | shrinkWrap |

**与 wait-home 的差异**：wait-home 用 `MaterialTapTargetSize.padded`（默认尺寸）；用户明确要求「不要现在这么大」，故改用 `shrinkWrap` 去掉 8dp 触控内边距，视觉更紧凑。

**替换点**：
- [settings_widgets.dart](../../lib/widgets/biz/settings_widgets.dart) `SettingsToggleItem`：`Switch.adaptive` → `Switch`，移除 `activeTrackColor`（由 switchTheme 接管）
- 4 处页面直接使用的 `Switch` / `Switch.adaptive`：移除多余属性，统一交给 switchTheme

**理由**：
- 主题级 switchTheme 一次配置全 App 生效，避免每个调用点重复样式
- `Switch`（Material）在 iOS/Android 视觉一致，消除 `Switch.adaptive` 在 iOS 端的 CupertinoSwitch 大尺寸差异
- `shrinkWrap` 让开关高度从 ~48dp（含触控补丁）降至 ~32dp，与设置项 row 高度更协调

### 2.4 主题色新增与默认值变更（需求 2）

**决策**：
- 新增颜色常量（不放 PiggyTheme，直接在 personalize_page 列表内联，与现有写法一致）：
  - 小猪粉 `#FF5C8D`（vibrant piggy pink，白字对比度 OK）
  - 渐变蓝 `#2563EB`（区别于晴空蓝 #2196F3 的更深蓝）
- 列表前三位重排：小猪粉 / 晴空蓝（既有 #2196F3）/ 渐变蓝
- [primaryColorProvider](../../lib/providers/theme_providers.dart) 默认值：`Color(0xFF2196F3)` → `Color(0xFF5C8D)`

**老用户兼容**：`primaryColorInitProvider` 仅在 prefs 存在 `primaryColor` 时覆盖；无保存值的新用户走 provider 默认（小猪粉）。已选他色的老用户不受影响。

**本地化**：新增 2 条 arb key，4 语言同步：
| key | zh | zh_TW | en | ko |
|---|---|---|---|---|
| personalizeThemePiggyPink | 小猪粉 | 小豬粉 | Piggy Pink | 피키 핑크 |
| personalizeThemeGradientBlue | 渐变蓝 | 漸變藍 | Gradient Blue | 그라데이션 블루 |

生成方式：手改 4 个 `.arb` + 对应 `app_localizations_*.dart`（项目内既有手写生成文件），或跑 `flutter gen-l10n`。按既有提交习惯手写同步。

**理由**：
- 纯色即可（用户已确认），无需改 `_ThemeCard` 渲染逻辑
- 默认值改 provider 即可，不动持久化逻辑

### 2.5 右下角玻璃记账按钮（需求 3）

**决策**：替换 [app.dart](../../lib/app.dart) 第 957-982 行 `FloatingActionButton.small`，改为自绘玻璃质感「记账」按钮，保持 `if (kDebugMode)` 限定。

**按钮结构**：
```dart
Positioned(
  right: 16,
  bottom: 100,
  child: ClipRRect(
    borderRadius: BorderRadius.circular(24),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.2),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add_circle_outline, size: 22, color: fgColor),
            const SizedBox(height: 1),
            Text(l10n.tabRecord, style: TextStyle(fontSize: 10, color: fgColor)),
          ],
        ),
      ),
    ),
  ),
)
```

- 图标 22px + 文案 10px：与 `_PiggyBottomBar._buildCenterTabItem` 完全一致
- `fgColor`：`isDark ? Colors.white : Colors.black`（与底部栏 inactiveColor 同源）
- 点击：`showTransactionFormBottomSheet(context, initialKind: 'expense')`（与 `onCenterTap` 一致）

**理由**：
- 不复用 FAB（FAB 强制圆形 + 单色，无法承载图标+文字+玻璃）
- `BackdropFilter` 是项目既有玻璃实现（GlassHeader 同款），视觉一致
- 保持 debug-only，release 零影响

## 3. 实现步骤

### 步骤 1：主题色与默认值（需求 2）
- 改 [personalize_page.dart](../../lib/pages/settings/personalize_page.dart) `options` 列表：插入小猪粉 / 晴空蓝 / 渐变蓝 到前三
- 改 [theme_providers.dart](../../lib/providers/theme_providers.dart) `primaryColorProvider` 默认值为 #FF5C8D
- 4 语言 arb + localizations dart 新增 2 条文案
- 跑 `flutter analyze`

### 步骤 2：switchTheme + 开关替换（需求 1c）
- [theme.dart](../../lib/theme.dart) light/dark 新增 `switchTheme`
- [settings_widgets.dart](../../lib/widgets/biz/settings_widgets.dart) `Switch.adaptive` → `Switch`
- 4 处页面 Switch 统一处理
- 跑 `flutter analyze`

### 步骤 3：设置页标题去玻璃（需求 1b）
- 20 处 + personalize_page 的 `GlassTitleBar(...)` 追加 `blur: false,`
- 跑 `flutter analyze`

### 步骤 4：ProfileCard 标题化（需求 1a）
- 重构 [profile_card.dart](../../lib/widgets/biz/profile_card.dart) Column：插入结余标题区，统计改二列
- 跑 `flutter analyze`

### 步骤 5：右下角玻璃记账按钮（需求 3）
- 替换 [app.dart](../../lib/app.dart) 第 957-982 行
- 跑 `flutter analyze`

### 步骤 6：整体验证
- 亮/暗主题抽查：我的页 / 设置子页 / 开关 / 主题色页 / debug 右下角按钮
- `flutter analyze` 0 errors

## 4. 边界条件与潜在风险

| 风险 | 缓解措施 |
|---|---|
| 老用户已选他色，默认值变更不应覆盖其偏好 | `primaryColorInitProvider` 仅在 prefs 有值时覆盖，新默认只影响无保存值的用户 |
| `shrinkWrap` 触控区缩小可能影响点按 | Switch 自身仍有点击区，且整行 `SettingsToggleItem` 的 `onTap` 也会触发 toggle，双保险 |
| ProfileCard 高度变化可能影响「我的」页首屏布局 | ProfileCard 在 ListView 中，高度自适应，无固定高度依赖 |
| 20 处 `blur: false` 改动遗漏 | 用 Grep 全量定位 `lib/pages/settings/` + `personalize_page.dart` 的 `GlassTitleBar(`，逐一确认 |
| 渐变蓝纯色与晴空蓝视觉过近 | 选 #2563EB（blue-600）与 #2196F3（blue-500）区分明显；用户可在主题色页自定义 |
| debug 按钮玻璃在低版本 Android 6- BackdropFilter 性能 | 保持 debug-only，release 不渲染；模糊 sigma 取 12（与 GlassHeader 同档） |
| 新增 arb key 漏翻某语言 | 4 语言表格同步，gen-l10n 后对照检查 |

## 5. 不在本次范围

- 不改 `GlassTitleBar` / `LiquidGlassTitleBar` 架构（仅用既有 `blur` 参数）
- 不删除 `Switch.adaptive` 的导入（仅改调用点）
- 不改底部菜单栏中间记账按钮（需求 3 是新增右下角入口，不替换中间按钮）
- 不改主题色卡片渲染逻辑（纯色即可，无需 LinearGradient）
