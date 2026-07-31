# URL 替换与图标改造需求文档

## 一、需求理解

用户要求将仓库内所有 `https://github.com/mecoren/PiggyCount` 链接替换为 `https://github.com/mecoren/PiggyCount`，并将项目中所有"蜜蜂"图标改造为"小猪/小猪存钱罐"图标，使品牌视觉与项目名"PiggyCount（小猪记账）"以及新仓库地址（mecoren）保持一致。

## 二、用户故事

### US-1：仓库 URL 全量切换
- **作为**用户，
- **我希望**应用内所有可见的 GitHub 链接、二维码扫描结果、分享海报都指向新仓库 `mecoren/PiggyCount`，
- **以便**我能正确访问新仓库获取源码、提交 Issue、查看 Releases。

### US-2：推广文案 emoji 更换
- **作为**用户，
- **我希望**"复制推广文案"功能中的 🐝 emoji 改为 🐷，
- **以便**文案视觉与"小猪记账"品牌名一致。

### US-3：PiggyIcon（piggy.svg）替换
- **作为**用户，
- **我希望**关于页头部及各处用到的 `PiggyIcon`（当前实际为蜜蜂 SVG）改为小猪/小猪存钱罐造型，
- **以便**应用品牌图标与产品名"PiggyCount"语义对齐。

### US-4：App Launcher 图标更换
- **作为**用户，
- **我希望**Android / iOS 应用启动器图标从小猪记账当前的蜜蜂图标改为小猪/小猪存钱罐图标，
- **以便**桌面图标与品牌名一致，降低用户认知偏差。

### US-5：分享海报 Logo 更换
- **作为**用户，
- **我希望**分享海报（app_promo_poster 等）中使用的 `assets/logo2.png` 改为小猪图标，
- **以便**分享出去的海报视觉与品牌一致。

## 三、功能需求

### 3.1 URL 全量替换（US-1）

#### 必须实现
- 替换仓库内所有 `https://github.com/mecoren/PiggyCount` 为 `https://github.com/mecoren/PiggyCount`
- 替换仓库内所有 `github.com/mecoren/PiggyCount`（无协议前缀的纯文本形式）为 `github.com/mecoren/PiggyCount`
- 替换 API URL：`https://api.github.com/repos/mecoren/PiggyCount/releases/latest` → `mecoren/PiggyCount`
- 替换 Referer 伪装：`https://github.com/mecoren/PiggyCount/releases` → `mecoren/PiggyCount`
- 涵盖范围：lib/ Dart 代码、l10n .arb 文件、posters、docs/、docoments/、.github/（含 ISSUE_TEMPLATE、FUNDING.yml）、CONTRIBUTING.md、LICENSE/LICENSE_EN、COMMERCIAL_LICENSE.md、packages/*/pubspec.yaml、packages/*/CHANGELOG.md、packages/*/USAGE_GUIDE.md、packages/*/PROJECT_SUMMARY.md、packages/flutter_cloud_sync_icloud/ios/*.podspec
- 重新生成分享海报中嵌入的二维码（数据源 URL 已变更）

#### 不在本次范围
- 不替换 `TNT-Likely/PiggyCount-Cloud`、`TNT-Likely/PiggyCount-Website`、`TNT-Likely/piggycount-openharmony`、`TNT-Likely/BeeShot`、`TNT-Likely/honeycomb` 等其他仓库链接（仅替换 PiggyCount 主仓库）
- 不替换 `LICENSE` / `LICENSE_EN` 中的 Copyright 行 `sunxiao (GitHub: TNT-Likely)`（属于原作者署名，保留）
- 不替换 `CONTRIBUTING.md` 中"项目维护者 sunxiao / TNT-Likely"的署名（属于版权声明）
- 不修改 `.github/FUNDING.yml` 中的 `github: TNT-Likely`（属于 sponsor 账号配置，需用户单独处理）

### 3.2 推广文案 emoji 更换（US-2）

#### 必须实现
- 修改 4 个 l10n .arb 文件中的 `shareGuidanceCopyText`：
  - `app_zh.arb`：`用小猪记账记录生活，开源免费无广告！🐝 下载地址：...` → `🐷`
  - `app_zh_TW.arb`：`用小豬記帳記錄生活，開源免費無廣告！🐝 下載地址：...` → `🐷`
  - `app_en.arb` / `app_ko.arb`：若含有 🐝 emoji 也一并替换为 🐷

#### 不在本次范围
- 不修改其他 l10n key（仅 `shareGuidanceCopyText`）

### 3.3 PiggyIcon（piggy.svg）替换（US-3）

#### 必须实现
- 重写 `assets/piggy.svg`，从蜜蜂造型改为小猪造型（保留 256×256 viewBox、currentColor 主题色支持）
- 保留 `PiggyIcon` widget 接口不变（`color`、`size` 参数）
- 暗黑模式遮罩逻辑保留（圆形浅色遮罩让深色边框可见）
- 验证所有使用 `PiggyIcon` 的位置显示正常（关于页头部等）

### 3.4 App Launcher 图标更换（US-4）

#### 必须实现
- 重新生成 Android `ic_launcher.png`（5 个密度：mdpi 48×48、hdpi 72×72、xhdpi 96×96、xxhdpi 144×144、xxxhdpi 192×192）
- 重新生成 iOS `Assets.xcassets` 中的 AppIcon 集（1024×1024 主图及各尺寸）
- 重新生成 `assets/icon/adaptive_foreground.png`（Android 自适应图标前景）
- 重新生成 `assets/icon/launcher_legacy.png`（旧版启动器图标）
- 重新生成 `assets/icon/adaptive_monochrome.png`（Android 13+ 单色主题图标）
- 重新生成 `assets/icon/preview_themed.png`（主题图标预览）
- 新图标视觉与 `piggy.svg` 风格一致（小猪造型）

#### 不在本次范围
- 不修改 iOS AppIcon Contents.json 结构
- 不修改 Android adaptive icon XML 配置
- 不修改 widget 小组件图标（如 `piggycount_widget`、`quick_add_widget` 等使用的是单独的图标资源）

### 3.5 分享海报 Logo 更换（US-5）

#### 必须实现
- 重新生成 `assets/logo2.png`（应用推广海报使用，建议 512×512 或更高，透明背景）
- 新 Logo 视觉与 piggy.svg 风格一致（小猪造型）
- 验证 app_promo_poster 中显示正常

#### 不在本次范围
- 不修改 `assets/logo.svg`、`assets/logo_216.png`、`assets/logo_512.png`（除非被海报或 launcher 引用）

## 四、非功能需求

### 4.1 兼容性
- URL 替换不破坏现有功能（更新检查、Issue 跳转、分享海报二维码扫描后能正确打开新仓库）
- 图标替换不破坏 `PiggyIcon` 现有调用方
- Launcher 图标生成需满足 Android/iOS 各密度规范

### 4.2 视觉规范
- 新小猪图标风格：简约线条 + currentColor 主题色填充（与原 piggy.svg 一致的视觉语言）
- 暗黑模式下图标边框可见
- Launcher 图标圆角自适应系统裁切

### 4.3 国际化
- 4 个 .arb 文件同步修改（en / zh / zh_TW / ko）

## 五、验收标准

### US-1 验收
1. ✅ `grep -r "mecoren/PiggyCount" .` 在 lib/、l10n/、posters、docs/、docoments/、.github/、packages/ 中无残留（PiggyCount-Cloud / PiggyCount-Website 等其他仓库链接保留）
2. ✅ 应用内"关于页 → GitHub"按钮跳转到 `https://github.com/mecoren/PiggyCount`
3. ✅ 应用更新检查功能能从 `api.github.com/repos/mecoren/PiggyCount/releases/latest` 正确获取版本
4. ✅ 分享海报二维码扫描后打开 `https://github.com/mecoren/PiggyCount`
5. ✅ 复制推广文案后粘贴得到新 URL
6. ✅ `flutter analyze` 0 errors

### US-2 验收
1. ✅ 4 个 .arb 文件中 `shareGuidanceCopyText` 不再包含 🐝
2. ✅ 4 个 .arb 文件中 `shareGuidanceCopyText` 包含 🐷
3. ✅ 复制推广文案功能能正常复制更新后的内容

### US-3 验收
1. ✅ `assets/piggy.svg` 是小猪造型（不再是蜜蜂）
2. ✅ 关于页头部图标显示为小猪
3. ✅ PiggyIcon 在亮色/暗色模式下都正常显示

### US-4 验收
1. ✅ Android 各密度 `ic_launcher.png` 已替换
2. ✅ iOS Assets.xcassets AppIcon 已替换
3. ✅ `assets/icon/` 下 4 个图标资源已替换
4. ✅ 桌面图标视觉为小猪

### US-5 验收
1. ✅ `assets/logo2.png` 已替换为小猪 Logo
2. ✅ app_promo_poster 中 Logo 显示正常

## 六、风险与边界条件

1. **二进制 PNG 资源生成风险**：Launcher 图标和 logo2.png 需要重新生成，使用 AI 图像生成可能有风格不统一问题。需保证所有 PNG 视觉风格一致（同一小猪造型）
2. **二维码内容风险**：分享海报二维码内容由代码生成，替换 URL 字符串即可，但需验证生成的二维码可被扫描识别
3. **License 署名保留风险**：LICENSE 文件中的 Copyright 属于原作者署名，不应在本次替换中修改
4. **FUNDING.yml 风险**：`.github/FUNDING.yml` 中 `github: TNT-Likely` 是 Sponsor 账号 ID，不属于 URL，不替换
5. **多语言 emoji 一致性风险**：4 个 .arb 文件需同步修改，避免遗漏某一语言
6. **自适应图标前景透明边距风险**：Android adaptive icon 前景需保留 18% 安全边距，避免被系统裁切
