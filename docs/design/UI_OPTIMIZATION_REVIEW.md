# PiggyCount UI 优化评审与实施建议

> 范围：头部组件、底部导航栏、分段控件、对话框、卡片与列表的视觉材质、可读性、间距与排版。
> 目标：在不牺牲可读性的前提下提升视觉层次感与一致性。
> 结论：统一采用「95% 实色 + 头部直渲皮肤」视觉语言；玻璃材质不做全量系统；Mica 不采用。

---

## 0. 修订说明（相对前期口头评估的修正）

前期口头评估称「`PrimaryHeader` 被约 70 个页面引用、玻璃头仅用于首页/分析页」。经代码核验，该判断不成立，本文基于核验后的真实状态撰写：

| 前期口头判断 | 代码核验结果 |
|---|---|
| `PrimaryHeader` 被大量页面引用 | `PrimaryHeader(` 仅在定义处出现（`lib/widgets/ui/primary_header.dart:28`），页面无直接调用 → **`PrimaryHeader` 处于被弃用/孤立状态** |
| 玻璃头仅用于首页/分析页 | 实际 `GlassHeader`/`GlassTitleBar`/`GlassHomeBar` 被 **50+ 个页面**使用（见附录 A） |
| 皮肤个性化在首页/分析页失效 | 玻璃组件**不渲染 `HeaderSkin`**，而 `HeaderSkin` 仅在 `PrimaryHeader` 中渲染且后者未被调用 → **皮肤个性化当前在全部 app 头部均不可见** |
| `pageHorizontalMargin` = 16 | `PiggyDimens.pageHorizontalMargin` 实为 `EdgeInsets.symmetric(horizontal: 12)`（`tokens.dart:611`） |

---

## 1. 结论摘要

1. **统一视觉语言**：以底部导航栏的「95% 实色」为基准，头部组件收敛为「95% 中性实色 + 直渲 `HeaderSkin`」。
2. **玻璃材质**：已有成熟引擎（`GradientBackdropFilter` + `Glass*` 系列），但**全量应用会牺牲皮肤个性化且带来 app 级 `BackdropFilter` 性能开销**，故不作为统一系统；仅保留为可选/降级路径。
3. **Mica**：不采用（详见 §2）。
4. **该方向的三重收益**：恢复被孤立的皮肤个性化、消除 app 级模糊性能开销、与导航栏语言统一。

---

## 2. 材质评估：Glassmorphism vs Mica

| 材质 | 适用性 | 结论与理由 |
|------|--------|-----------|
| **Glassmorphism（玻璃）** | 跨平台，Flutter 可用 `BackdropFilter` 实现 | **不做全量系统，仅保留可选路径**。<br>理由：① 现有玻璃头模糊的是「页面内容」而非皮肤，导致 `HeaderSkin` 在头部不可见（个性化能力退化）；② 50+ 页面常驻 `BackdropFilter` 在滚动时持续重算模糊，存在掉帧风险；③ 若强行让玻璃透出皮肤，亮色皮肤（aurora/sunset/sakura）会使黑标题对比度跌破 WCAG 4.5:1。 |
| **Mica（云母）** | Windows 11 桌面专属材质：不透明、随桌面壁纸/窗口状态变化的静态染色层 | **不采用**。<br>理由：① 无 Flutter 原生 API，且本项目仅 targeting iOS/Android；② 其「静态染色制造景深」的设计意图，可被现有的轻量 tint 表面替代，无需引入桌面专属概念；③ 与项目已选的 Material 3 + 毛玻璃方向背道而驰。 |

> 注：玻璃的「通透景深」可由 `HeaderSkin` 渐变 + 1px 顶部高光线 + 导航栏投影在**不引入模糊**的前提下获得，满足「层次感」目标而不承担其风险。

---

## 3. 当前状态盘点（代码核验）

### 3.1 头部组件架构

- **玻璃头部**（实际被全 app 使用）：
  - `GlassHeader` / `GlassTitleBar` / `GlassHomeBar`（`lib/widgets/ui/glass_title_bar.dart`）均为 `LiquidGlassTitleBar` 的薄包装。
  - 底层 `GradientBackdropFilter`（`lib/widgets/ui/gradient_backdrop_filter.dart`）：
    - `maxSigma` 默认 **20**，`minSigma` 默认 **2**。
    - tint：亮色 `Color(0xFFFFFFFF)`、暗色 `Color(0xFF181A22)`，顶部不透明度 `_Defaults.maxTintOpacity = 0.20` → 底部 `minTintOpacity = 0.0`（`:173-176`）。
    - `bottomOpaque` 选项（`:59`）可令模糊层全程不透明、tint 全程 `maxTintOpacity`，用于隔绝下方彩色组件渗透（设置页/列表页）。
    - 模糊对象为**页面内容**（`Positioned.fill` + `BackdropFilter`），**不渲染皮肤**。
  - 顶部高光线：`GlassHeader` 以 0.5px `onSurface` 描边（`glass_title_bar.dart:353-366`，暗色 α0.15 / 亮色 α0.08）。
- **实体头部 `PrimaryHeader`**（被孤立）：
  - `lib/widgets/ui/primary_header.dart`：实色 `headerBg`（亮=主题色 `primary` / 暗=`Colors.black`，`:64`）+ `HeaderSkin` 装饰层（`:61-62` 读取 `headerSkinProvider`，`:91-92` 渲染 `skin.builder`）。
  - 默认内边距 `EdgeInsets(8,8,8,8)`（`:36`），compact `(8,6,8,6)`。
  - **页面无调用**（grep 仅命中定义处）。

### 3.2 皮肤个性化（`HeaderSkin`）

- 系统位于 `lib/styles/header_skins.dart`，含 20+ 款（aurora/galaxy/sunset/sakura/starry/mountains/waves…）。
- **仅 `PrimaryHeader` 渲染**（读取 `headerSkinProvider`）；因 `PrimaryHeader` 未被任何页面调用，**皮肤当前在全部 app 头部均不可见**。

### 3.3 其他表面

| 表面 | 文件:行 | 现状 |
|------|---------|------|
| 底部导航栏 `_PiggyBottomBar` | `lib/styles/tokens.dart:479`（`tabBarBackground`） | 亮 `Colors.white α0.95` / 暗 `#1C1C1E α0.95` + `tabBarShadow`（悬浮胶囊 + 阴影）。**95% 实色**。 |
| 分段控件 `WaitSlidingSegmentedControl` | `lib/widgets/ui/wait_sliding_segmented_control.dart:158` | `surface.withValues(alpha: 0.55)` 半透明玻璃。 |
| 对话框 `AppDialog` | `lib/widgets/ui/dialog.dart` | 实色 `surfaceElevated`（数据可读性优先）。 |
| 底部抽屉 `ExpandableBottomSheet` | 内嵌 `GlassTitleBar(blur: false)` | 已正确设为纯色，避免分界线。 |

### 3.4 不一致小结

- **材质语言分裂**：头部 = 玻璃（无皮肤，app 级）；导航栏 = 95% 实色；分段 = α0.55 玻璃；皮肤 = 孤立。
- **间距三值共存**：头部水平内边距 `PrimaryHeader` 用 8、`GlassHeader` 用 16（`glass_title_bar.dart:262`）、`pageHorizontalMargin` 令牌 = 12（`tokens.dart:611`）——三者不一致。

---

## 4. 可读性 / 对比度护栏

95% 中性实色基底下，文字 `onSurface` 对比度：亮（深字 on 白 95%）≥ AAA；暗（浅字 on 深灰 95%）≥ AAA。

**风险点**：若 `HeaderSkin` 以全不透明渲染在 95% 中性基底之上（如 `PrimaryHeader` 现状），亮色皮肤（aurora/sunset/sakura）叠深字可能跌破 4.5:1。

**护栏（实施中必须遵守）**：

1. 皮肤渲染于 95% 中性基底之上时，建议皮肤层叠加 ≤0.9 不透明，或基底透明度升至 0.97，确保文字落点近中性。
2. 文字统一使用 `onSurface`；禁止在不可控背景使用次级色作主文。
3. 目标对比度（WCAG 2.1 AA）：正文 ≥ 4.5:1、大字/标题 ≥ 3:1、UI 组件 ≥ 3:1。
4. 实施期加入调试对比度覆盖层，逐屏校验亮/暗模式与典型皮肤下的标题可读性。

---

## 5. 组件调整清单（按优先级）

### P0 — 统一头部 + 恢复皮肤（最高收益）

| # | 组件 / 文件 | 现状 | 建议 |
|---|------|------|------|
| P0-1 | 头部组件归一 | 50+ 页用 `Glass*`；`PrimaryHeader` 孤立 | 新增/复用统一 `PiggyHeader`（95% 中性实色 + 直渲 `HeaderSkin`），替换附录 A 全部 `Glass*` 调用。保留 `Glass*` 为 `@deprecated`/可选（仅当确需 blur 景深）。 |
| P0-2 | `HeaderSkin` 个性化 | 孤立、全 app 不可见 | `PiggyHeader` 内部渲染皮肤，读取 `headerSkinProvider`（参照 `primary_header.dart:61-62, 91-92`），恢复个性化。 |
| P0-3 | `PrimaryHeader` | 孤立 | 逻辑并入 `PiggyHeader` 后标记 `@deprecated` 或删除。 |

### P1 — 对齐高价值表面

| # | 组件 / 文件 | 现状 | 建议 |
|---|------|------|------|
| P1-1 | 底部导航栏 `_PiggyBottomBar` | 95% 实色 + 阴影 | **保持**（撤回原「导航栏改真玻璃」建议），作为全量统一基准。 |
| P1-2 | `WaitSlidingSegmentedControl`（`wait_sliding_segmented_control.dart:158`） | `surface α0.55` | 改为 95% 中性实色（或 `surface α0.90+`），与导航栏统一。 |
| P1-3 | `AppDialog`（`dialog.dart`） | 实色 `surfaceElevated` | **保持实色**（数据可读性优先）；可加 1px 顶部高光线呼应头部语言。 |

### P2 — 间距 / 排版审计

| # | 组件 / 文件 | 现状 | 建议 |
|---|------|------|------|
| P2-1 | `SectionCard`（`section_card.dart:12-13`） | padding/margin 用 `p12`(12) | 已合规；明确两档规则：密集列表 12 / 独立卡片 16（`cardPadding`，`tokens.dart:608`）。 |
| P2-2 | `transaction_list_item.dart`（`116,151,321,399`） | 多处 `fontSize: 11` | 新增 `caption` 令牌(11)；内联间距改 `listRowVertical`(8)。 |
| P2-3 | 头部水平内边距 | 8 / 12 / 16 三值共存 | 归一到单一令牌（建议 `headerHorizontal = pageHorizontalMargin`(12) 或新建 16），全局替换。 |
| P2-4 | 圆角散落 | `BorderRadius.circular(数值)` 字面量 | 统一使用 `radiusXs…radius3xl` 令牌（`tokens.dart:574` 起）。 |

---

## 6. 间距与排版规则（建议落地值）

| 维度 | 令牌 / 值 | 说明 |
|------|-----------|------|
| 头部水平内边距 | 单一令牌（12 或 16，二选一并全量） | 消除 8/12/16 三值分裂 |
| 卡片内边距 | 密集列表 12 / 独立卡片 16（`cardPadding`） | 两档规则 |
| 列表行垂直 | `listRowVertical`(8) | `tokens.dart:600` |
| 列表头垂直 | `listHeaderVertical`(6) | `tokens.dart:599` |
| 字号层级 | title/strongTitle/boldTitle/body/label（已有）+ 新增 `caption`(11) | 消除 `fontSize:11` 散落 |
| 圆角 | `radiusXs…radius3xl`（7 档） | `tokens.dart:574` 起 |

---

## 7. 实施路径

1. **P0** 统一头部 + 恢复皮肤（最大收益：一致性 + 个性化 + 性能）。
2. **P1** 分段控件对齐、导航栏/对话框定型。
3. **P2** 间距/排版令牌审计（消除魔法数字）。
4. **P3** 对比度 QA（调试覆盖层逐屏校验亮/暗模式与典型皮肤下的标题可读性）。

---

## 附录 A：当前 `Glass*` 调用页面清单（需替换为 `PiggyHeader`）

> 来源：grep `GlassHeader\(|GlassTitleBar\(|GlassHomeBar\(`，覆盖 `lib/**/*.dart`。

```
lib/pages/account/net_worth_trend_page.dart
lib/pages/ai/ai_settings_page.dart
lib/pages/account/account_edit_page.dart
lib/pages/ai/ai_provider_manage_page.dart
lib/pages/account/account_detail_page.dart
lib/pages/account/accounts_page.dart
lib/pages/ai/ai_prompt_edit_page.dart
lib/pages/ai/ai_chat_page.dart
lib/pages/ai/ai_model_selection_page.dart
lib/pages/calendar/calendar_page.dart
lib/pages/automation/ios_auto_billing_page.dart
lib/pages/automation/auto_billing_settings_page.dart
lib/pages/budget/budget_edit_page.dart
lib/pages/budget/budget_page.dart
lib/pages/data/import_page.dart
lib/pages/data/import_confirm_page.dart
lib/pages/auth/pin_setup_page.dart
lib/pages/auth/login_page.dart
lib/pages/maintenance/orphan_cleanup_page.dart
lib/pages/data/export_page.dart
lib/pages/transaction/transaction_editor_page.dart
lib/pages/settings/appearance_settings_page.dart
lib/pages/settings/widget_management_page.dart
lib/pages/transaction/search_page.dart
lib/pages/transaction/recurring_transaction_page.dart
lib/pages/transaction/recurring_transaction_edit_page.dart
lib/pages/currency/exchange_rate_page.dart
lib/pages/transaction/category_detail_page.dart
lib/pages/cloud/piggycount_cloud_sync_page.dart
lib/pages/cloud/member_stats_page.dart
lib/pages/cloud/encryption_settings_page.dart
lib/pages/category/icon_picker_page.dart
lib/pages/cloud/devices_page.dart
lib/pages/main/ledgers_page_new.dart
lib/pages/cloud/member_list_page.dart
lib/pages/cloud/cloud_sync_page.dart
lib/pages/main/home_page.dart
lib/pages/category/edit_page.dart
lib/pages/settings/about_page.dart
lib/pages/cloud/join_shared_ledger_page.dart
lib/pages/category/manage_page.dart
lib/pages/cloud/cloud_service_page.dart
lib/pages/cloud/invite_page.dart
lib/pages/main/analytics_page.dart
lib/pages/settings/storage_management_page.dart
lib/pages/category/migration_page.dart
lib/pages/tag/manage_page.dart
lib/pages/settings/app_lock_settings_page.dart
lib/pages/tag/edit_page.dart
lib/pages/settings/config_import_export_page.dart
lib/pages/settings/attachment_preview_page.dart
lib/pages/settings/data_management_page.dart
lib/pages/settings/privacy_policy_page.dart
lib/pages/settings/automation_page.dart
lib/pages/settings/header_skin_page.dart
lib/pages/tag/detail_page.dart
lib/pages/settings/font_settings_page.dart
lib/pages/settings/smart_billing_page.dart
lib/pages/settings/log_center_page.dart
lib/pages/settings/personalize_page.dart
lib/pages/settings/language_settings_page.dart
lib/pages/settings/shortcuts_guide_page.dart
lib/pages/settings/reminder_settings_page.dart
```

---

## 附录 B：关键文件:行号索引

| 关注点 | 位置 |
|--------|------|
| 导航栏 95% 实色 | `lib/styles/tokens.dart:479`（`tabBarBackground`） |
| 间距令牌 p4–p24 | `lib/styles/tokens.dart:558-563` |
| 列表垂直令牌 | `lib/styles/tokens.dart:599-600`（`listHeaderVertical`/`listRowVertical`） |
| 卡片/页面令牌 | `lib/styles/tokens.dart:608`（`cardPadding`）、`:611`（`pageHorizontalMargin` = 12） |
| 圆角令牌 | `lib/styles/tokens.dart:574`（`radiusXs`）起 |
| 模糊默认参数 | `lib/widgets/ui/gradient_backdrop_filter.dart:19-27`；`_Defaults` `:173-176` |
| `GlassHeader` 定义与高光线 | `lib/widgets/ui/glass_title_bar.dart:209`、`354-366` |
| `PrimaryHeader` 皮肤渲染 | `lib/widgets/ui/primary_header.dart:61-62, 91-92`；默认内边距 `:36` |
| `SectionCard` padding/margin | `lib/widgets/biz/section_card.dart:12-13` |
| `transaction_list_item` 小字 | `lib/widgets/biz/transaction_list_item.dart:116,151,321,399` |
| 分段控件半透明 | `lib/widgets/ui/wait_sliding_segmented_control.dart:158` |
