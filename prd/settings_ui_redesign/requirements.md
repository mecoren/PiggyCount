# 设置页面 UI 改造 - 需求文档

## 1. 用户需求理解

参考 `C:\Develop\project\00_AI\wait-home\mobile` 项目的设置页面设计，对 BeeCount 的设置页面进行 UI 样式改造，**只动样式 UI，要一模一样，功能不能变**。

## 2. 改造范围

经用户确认，本次改造范围如下：

| 范围项 | 内容 |
|---|---|
| 主入口 | `lib/pages/main/mine_page.dart`（MinePage，「我的」Tab） |
| 设置子页 | `lib/pages/settings/` 目录下全部 19 个二级页面 |
| 头部处理 | MinePage 保留头像+问候语+统计内容，重做视觉风格 |
| 标题栏组件 | 完整移植 wait-home 的液态玻璃标题栏组件 |

**不在本次改造范围**：
- 不修改共享组件 `lib/widgets/biz/app_list_tile.dart`、`lib/widgets/biz/section_card.dart`、`lib/widgets/ui/primary_header.dart` 的现有实现（避免波及全 App）
- 不改造其他业务页面（账户、预算、日历、交易等）
- 不改变主题色系统、Token 体系、i18n 体系

## 3. 功能性需求（必须 100% 保留）

### 3.1 MinePage 主入口功能清单

| 分组 | 项目 | 行为 | 路由 / 调用 |
|---|---|---|---|
| 头部 | 头像点击 | 弹窗 | `_showProfileOptions`（4 选项：昵称/相册/拍照/删除） |
| 头部 | 昵称点击 | 弹窗 | `_showEditDisplayName`（TextField + 保存到 `displayNameProvider`） |
| 头部 | 小眼睛点击 | 切换 | 翻转 `hideAmountsProvider`（隐藏金额开关） |
| 头部 | 头像同步 | 云端 | `_syncAvatarToCloud`（仅 BeeCount Cloud 模式调用 `providerInstance.uploadMyAvatar()`） |
| 头部 | 统计展示 | 数据 | 记账天数 / 总记录 / 当前余额（3 列 `_StatCell`） |
| 云同步与备份 | 云服务 | push | `CloudServicePage()` |
| 云同步与备份 | 同步状态 | 条件分叉 | `cfg.type` 为 BeeCount Cloud → `BeeCountCloudSyncPage()`；否则 → `CloudSyncPage()` |
| 功能管理 | 智能记账 | push | `SmartBillingPage()` |
| 功能管理 | 数据管理 | push | `DataManagementPage()` |
| 功能管理 | 自动化 | push | `AutomationPage()` |
| 功能管理 | 外观设置 | push | `AppearanceSettingsPage()` |
| 帮助与信息 | 关于 | push | `AboutPage()` |
| 帮助与信息 | 使用帮助 | 条件分叉 | `kHelpCenterInApp` true → `HelpCenterPage()`；false → `_tryOpenUrl(WebsiteUrls.docs(locale))` |
| 支持我们 | 打赏（仅 iOS） | push | `DonationPage()` |
| 支持我们 | GitHub Star | 弹窗 | `_showGitHubStarGuide` → 跳转 `https://github.com/TNT-Likely/BeeCount` |
| 支持我们 | 年度账单 | push | `AnnualReportPage()` |
| 支持我们 | 分享海报 | 服务调用 | `SharePosterService.showPosterCarouselPreview(context)` |
| 支持我们 | 复制推广文案 | 剪贴板 | `Clipboard.setData` + `showToast(l10n.shareGuidanceCopied)` |
| 支持我们 | 评分（仅 iOS） | 系统调用 | `InAppReview.openStoreListing(appStoreId: '6754611670')` |

### 3.2 设置子页功能清单（必须保留）

每个子页面的所有 `onTap` 回调、`ref.read/watch` Provider 调用、`Navigator.push` 路由目标、条件分支（`Platform.isIOS` / `kHelpCenterInApp` / `_isGooglePlayBuild` / `cfg.type`）、`showToast` 调用、特殊弹窗（`AlertDialog` / `showModalBottomSheet` / `showWheelTimePicker`）、Switch 状态绑定、Slider 值绑定、进度条状态等**全部保留**。

详见 `lib/pages/settings/` 下各文件现有逻辑。

### 3.3 头部皮肤（headerSkinProvider）功能保留

BeeCount 有头部皮肤（headerSkinProvider）功能，用户可选择不同头部背景样式。本次改造中：
- **MinePage**：头部皮肤作为 ProfileCard 的背景保留（圆角 16px 卡片形式）
- **设置子页**：使用 GlassTitleBar 替代 PrimaryHeader，头部皮肤在子页不再显示（视觉一致性优先，皮肤功能在 MinePage 仍可见可切换）

## 4. 非功能性需求（UI 风格要求）

### 4.1 整体布局（必须与 wait-home 一致）

- `Scaffold` 使用 `extendBodyBehindAppBar: true`，内容延伸到标题栏下方
- 标题栏为液态玻璃材质（毛玻璃 + 渐变 + 底部 1px 高光线）
- 顶部 padding 公式：`MediaQuery.of(context).padding.top + kToolbarHeight + 16`
- 底部 padding：`16 + MediaQuery.of(context).padding.bottom`（无底部导航栏 inset）

### 4.2 卡片样式（必须与 wait-home 一致）

- 圆角 **16px**（`BorderRadius.circular(16)`）
- **无阴影、无边框**（靠背景色对比分层）
- 卡片背景色：亮色 `BeeTokens.surface(context)`（白）/ 暗色 `BeeTokens.surface(context)`（#1C1C1E）
- 页面背景色：亮色 `BeeTokens.scaffoldBackground(context)`（grey.shade50）/ 暗色 纯黑
- 卡片内项目之间**不画 Divider**，靠 `vertical: 12~14` 的 padding 分隔
- 分区间距恒为 **24px**，列表底部收尾 **32px**

### 4.3 设置项样式（必须与 wait-home 一致）

**导航项**（带右箭头）：
- 左侧 24px 强调色图标（裸图标，无背景容器）— MinePage 用
- 子页可用变体：图标盒（8dp padding + 10% 强调色背景 + 10px 圆角 + 20px 图标）
- 中间：标题 `bodyMedium w500`（14px）+ 副标题 `bodySmall onSurfaceVariant`（12px）
- 右侧：`Icons.chevron_right_rounded`（颜色 `onSurfaceVariant`）
- 整体 padding：`horizontal: 16, vertical: 14`
- 涟漪圆角 12px

**设置项**（带 trailing 控件，如 Switch / 分段选择器）：
- 同导航项，但 vertical: 12，右侧为 trailing 控件（无 chevron）

### 4.4 分组小标题（必须与 wait-home 一致）

- 字号 12pt / 字重 w600
- 颜色 `onSurfaceVariant`
- 左缩进 8px（比卡片左缘再缩进 8）
- 与卡片间距 8px

### 4.5 标题栏样式（必须与 wait-home 一致）

- 高度 56dp
- 标题字号 17pt / w500 / 颜色 `onSurface`
- 标题左对齐（紧贴 leading 按钮）
- 左侧 leading：MinePage 无 leading（或菜单键）；子页为 `Icons.arrow_back_rounded`
- 渐变毛玻璃：`BackdropFilter sigmaX: 20, sigmaY: 20` + `ShaderMask(BlendMode.dstIn)` 实现顶全显→底透明
- 底部 1px 高光线：`LinearGradient`（中间最亮，两端透明）
- tint 色：亮色 `#FFFFFF alpha 0.20`，暗色 `#181A22 alpha 0.20`

### 4.6 字体与字号

- 列表项标题：14px w500
- 列表项副标题：12px w400
- 分组小标题：12px w600
- 标题栏标题：17px w500

## 5. 约束条件

1. **不可改变任何业务逻辑**：所有 `onTap` / Provider 读写 / 路由跳转 / 条件分支 / 平台判断必须原样保留
2. **不可修改共享组件**：`AppListTile` / `SectionCard` / `PrimaryHeader` 的现有实现保持不变（其他业务页面仍在使用）
3. **保留所有 i18n key 调用**：不得硬编码中文文案，所有文案继续走 `AppLocalizations.of(context).xxx`
4. **保留特殊常量**：`appStoreId: '6754611670'`、GitHub URL、浙ICP备号 `'浙ICP备2025214907号-2A'` 等
5. **代码标识符使用英文**：变量名、函数名、类名、文件名必须英文（项目规则）
6. **复杂代码中文注释**：解释「为什么」而非「做了什么」（项目规则）

## 6. 验收标准

### 6.1 视觉验收

- [ ] MinePage 顶部为液态玻璃标题栏（56dp，毛玻璃效果，底部高光线）
- [ ] MinePage 头像+问候语+统计作为 ProfileCard 出现在 ListView 第一项（保留头部皮肤背景）
- [ ] 所有设置页（MinePage + 19 个子页）的卡片为 16px 圆角、无阴影、无分割线
- [ ] 设置项三段式布局：24px 强调色图标 + 标题/副标题 + trailing/chevron
- [ ] 分组小标题 12pt w600 左缩进 8px
- [ ] 分区间距 24px，列表底部 32px
- [ ] 内容延伸到标题栏下方，滚动时透出毛玻璃效果

### 6.2 功能验收

- [ ] MinePage 所有 14 个设置项 onTap 跳转正确
- [ ] MinePage 头像点击弹窗 4 选项正常
- [ ] MinePage 昵称编辑保存生效
- [ ] MinePage 小眼睛切换隐藏金额
- [ ] 同步状态项根据 `cfg.type` 正确分叉
- [ ] iOS 专属项（打赏、评分）仅在 iOS 显示
- [ ] 所有设置子页的功能（Switch / Slider / 弹窗 / 路由）正常工作
- [ ] 头部皮肤在 MinePage 仍可见可切换
- [ ] i18n 切换语言后设置页文案正确

### 6.3 工程验收

- [ ] `flutter analyze` 无新增 issue
- [ ] 无未使用的 import / 死代码
- [ ] 新增组件文件命名符合项目规范（英文、下划线）
- [ ] 不破坏现有共享组件的其他调用方
