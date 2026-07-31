# Star 入口彻底清理需求文档

## 一、需求理解

用户要求彻底移除应用内"给项目 Star ⭐️"设置入口及其相关引导功能，包括代码、Provider、UI 入口、引导弹窗、本地资产、国际化字符串等所有相关元素。

## 二、用户故事

### US-1：移除 Star 入口 UI
- **作为**用户，
- **我希望**"我的"页面不再显示"给项目 Star ⭐️"设置项，
- **以便**避免被引导去 GitHub Star 项目（项目已迁移至 mecoren，且用户不再需要此推广入口）。

### US-2：彻底清理相关资产和代码
- **作为**项目维护者，
- **我希望**移除 Star 引导相关的所有代码、Provider、资产和 l10n key，
- **以便**项目代码精简，无死代码、无未使用资产。

## 三、功能需求

### 3.1 移除 Star 入口 UI（US-1）

#### 必须实现
- 从 `lib/pages/main/mine_page.dart` 中移除 "GitHub Star" Consumer 块（约 395-408 行）：
  ```dart
  // GitHub Star
  Consumer(
    builder: (context, ref, _) {
      final starCountAsync = ref.watch(githubStarCountProvider);
      ...
    },
  ),
  ```
- 移除 `_showGitHubStarGuide` 函数定义（约 493-540 行）
- 移除 `import '../../providers/github_star_provider.dart';`

### 3.2 彻底清理相关资产和代码（US-2）

#### 必须实现

**Dart 代码**：
- 删除 `lib/providers/github_star_provider.dart`（整个文件）

**本地资产**：
- 删除 `assets/images/github_star_guide.png`

**l10n key**（4 个 .arb 文件 + 重新生成 app_localizations*.dart）：
- 移除 `mineSupportAuthor`（"给项目 Star ⭐️"）
- 移除 `mineSupportAuthorSubtitle`（含占位符 `{count}`）
- 移除 `githubStarGuideTitle`（"如何给项目 Star"）
- 移除 `githubStarGuideContent`
- 移除 `githubStarGuideButton`（"前往 GitHub"）

  4 个文件：
  - `lib/l10n/app_zh.arb`
  - `lib/l10n/app_zh_TW.arb`
  - `lib/l10n/app_en.arb`
  - `lib/l10n/app_ko.arb`

**引用清理**：
- 全局搜索确认无其他位置引用上述 l10n key 或 `githubStarCountProvider` / `_showGitHubStarGuide`

#### 不在本次范围
- 不删除 GitHub 跳转按钮本身（关于页的 GitHub 社媒按钮保留，跳转 URL 已在需求2中改为 mecoren/PiggyCount）
- 不删除应用评分入口（iOS 的 `_rateApp`）
- 不删除复制推广文案入口
- 不删除分享海报入口

## 四、非功能需求

### 4.1 兼容性
- 不破坏"我的"页面其他设置项的布局
- 不破坏 l10n 文件结构（.arb JSON 合法）
- 不引入未使用 import 警告

### 4.2 国际化
- 4 个 .arb 文件同步移除相同 key
- 重新生成 `app_localizations*.dart` 后无未定义引用

## 五、验收标准

### US-1 验收
1. ✅ "我的"页面不再显示"给项目 Star ⭐️"设置项
2. ✅ "我的"页面其他设置项布局正常（捐赠、年度账单、分享海报、复制推广文案、iOS 评分等）

### US-2 验收
1. ✅ `lib/providers/github_star_provider.dart` 已删除
2. ✅ `assets/images/github_star_guide.png` 已删除
3. ✅ 4 个 .arb 文件中无 `mineSupportAuthor`、`mineSupportAuthorSubtitle`、`githubStarGuideTitle`、`githubStarGuideContent`、`githubStarGuideButton` key
4. ✅ `lib/pages/main/mine_page.dart` 不再 import `github_star_provider.dart`
5. ✅ `lib/pages/main/mine_page.dart` 不再定义 `_showGitHubStarGuide`
6. ✅ `grep -rn "githubStarGuide\|mineSupportAuthor\|githubStarCountProvider\|_showGitHubStarGuide" lib/` 返回 0 行
7. ✅ `flutter gen-l10n` 无错误
8. ✅ `flutter analyze` 0 errors

## 六、风险与边界条件

1. **l10n key 残留风险**：移除 .arb key 后必须运行 `flutter gen-l10n`，否则 app_localizations*.dart 仍保留旧 key 定义但 .arb 已无定义，编译时 Dart 代码引用旧 key 不会报错，但运行时取不到值
2. **其他引用风险**：需全局搜索确认无其他位置（如测试代码）引用这些 key 或 provider
3. **布局塌陷风险**：移除 Consumer 块后需检查 SettingsCard children 列表是否仍合法（无连续逗号、无空 children）
4. **iOS 评分入口保留风险**：iOS 评分入口（`_rateApp`）与 Star 入口相邻，移除时不能误删
