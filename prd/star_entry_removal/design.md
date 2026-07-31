# Star 入口彻底清理设计文档

## 一、需求理解

从"我的"页面彻底移除"给项目 Star ⭐️"设置入口及其引导功能，清理相关 Dart 代码、Provider、PNG 资产、4 个 .arb 文件中的 l10n key，保持代码精简无死代码。

## 二、关键技术决策

| 决策 | 选择 | 理由 |
|------|------|------|
| 删除策略 | 彻底删除而非注释保留 | 用户明确要求"彻底清理"，避免死代码 |
| Provider 删除 | 删除整个 `github_star_provider.dart` 文件 | 该 Provider 仅服务于 Star 入口，无其他调用方 |
| l10n key 删除 | 4 个 .arb 同步删除后重新生成 | 保证 .arb 与 app_localizations*.dart 一致 |
| 引导弹窗删除 | 删除 `_showGitHubStarGuide` 函数 | 仅 mine_page 内部使用 |
| 资产删除 | 删除 `github_star_guide.png` | 仅 Star 引导弹窗使用 |
| 关于页 GitHub 按钮处理 | 保留（URL 已在需求2中替换为 mecoren） | 该按钮属于社媒跳转，不属于 Star 引导 |
| iOS 评分入口处理 | 保留 | 与 Star 入口无关 |

## 三、实现步骤

### 步骤 1：清理 mine_page.dart

**文件**：`lib/pages/main/mine_page.dart`

修改点：
1. 删除 import：`import '../../providers/github_star_provider.dart';`
2. 删除 "GitHub Star" Consumer 块（约 395-408 行）：
   ```dart
   // GitHub Star
   Consumer(
     builder: (context, ref, _) {
       final starCountAsync = ref.watch(githubStarCountProvider);
       final starCount = starCountAsync.valueOrNull ?? 999;
       return SettingsNavItem(
         icon: Icons.star_outline,
         title: AppLocalizations.of(context).mineSupportAuthor,
         subtitle: AppLocalizations.of(context)
             .mineSupportAuthorSubtitle(starCount.toString()),
         onTap: () => _showGitHubStarGuide(context),
       );
     },
   ),
   ```
3. 删除 `_showGitHubStarGuide` 函数（约 492-540 行，从 `/// 显示 GitHub Star 引导弹窗` 注释到函数右大括号）

**注意**：删除 Consumer 块时检查上下文逗号，避免留下空 children 或连续逗号。

### 步骤 2：删除 Provider 文件

**文件**：`lib/providers/github_star_provider.dart`（整个文件删除）

**验证**：删除前全局搜索 `githubStarCountProvider` 引用，确认仅 mine_page.dart 引用。

### 步骤 3：删除引导图资产

**文件**：`assets/images/github_star_guide.png`（删除）

**验证**：全局搜索 `github_star_guide.png` 引用，确认仅 mine_page.dart 中 `_showGitHubStarGuide` 引用（已删除）。

### 步骤 4：清理 l10n key

**文件**：4 个 .arb 文件

移除以下 5 个 key 及其 `@key` 描述块（如有）：
- `mineSupportAuthor`
- `mineSupportAuthorSubtitle`（注意是带占位符的方法，移除 `mineSupportAuthorSubtitle` 及其 `@mineSupportAuthorSubtitle` 描述块、`placeholders` 配置）
- `githubStarGuideTitle`
- `githubStarGuideContent`
- `githubStarGuideButton`

**文件清单**：
- `lib/l10n/app_zh.arb`
- `lib/l10n/app_zh_TW.arb`
- `lib/l10n/app_en.arb`
- `lib/l10n/app_ko.arb`

### 步骤 5：重新生成 l10n 并验证

- 运行 `flutter gen-l10n`
- `flutter analyze` 0 errors
- 全局搜索 `githubStarGuide`、`mineSupportAuthor`、`githubStarCountProvider`、`_showGitHubStarGuide`，确认无残留

## 四、文件清单

| 文件 | 类型 | 描述 |
|------|------|------|
| `lib/pages/main/mine_page.dart` | 修改 | 移除 Star 入口 UI、import、_showGitHubStarGuide 函数 |
| `lib/providers/github_star_provider.dart` | 删除 | 整个文件 |
| `assets/images/github_star_guide.png` | 删除 | Star 引导图 |
| `lib/l10n/app_zh.arb` | 修改 | 移除 5 个 l10n key |
| `lib/l10n/app_zh_TW.arb` | 修改 | 同上 |
| `lib/l10n/app_en.arb` | 修改 | 同上 |
| `lib/l10n/app_ko.arb` | 修改 | 同上 |
| `lib/l10n/app_localizations*.dart` | 自动生成 | `flutter gen-l10n` 重新生成 |

## 五、风险与边界条件

1. **逗号塌陷风险**：删除 Consumer 块后，前一个 `SettingsNavItem`（捐赠）和后一个 `SettingsNavItem`（年度账单）之间逗号需保留一个，避免连续逗号或缺失逗号
2. **l10n 占位符配置风险**：`mineSupportAuthorSubtitle` 是带 `{count}` 占位符的方法，.arb 中有 `@mineSupportAuthorSubtitle` 描述块和 `placeholders` 配置，需一并删除
3. **其他引用风险**：测试代码（test/）中若引用这些 l10n key 或 provider，需同步清理
4. **iOS 评分入口相邻风险**：iOS 评分入口（`Platform.isIOS` 块）与 Star 入口在 SettingsCard 内相邻，删除时不能误删 iOS 评分入口

## 六、验证标准

1. ✅ `grep -rn "githubStarGuide\|mineSupportAuthor\|githubStarCountProvider\|_showGitHubStarGuide" lib/ test/` 返回 0 行
2. ✅ `lib/providers/github_star_provider.dart` 文件不存在
3. ✅ `assets/images/github_star_guide.png` 文件不存在
4. ✅ 4 个 .arb 文件中无相关 key
5. ✅ `flutter gen-l10n` 成功
6. ✅ `flutter analyze` 0 errors
7. ✅ "我的"页面其他设置项布局正常
