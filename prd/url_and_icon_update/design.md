# URL 替换与图标改造设计文档

## 一、需求理解

将仓库内所有 `mecoren/PiggyCount` URL 替换为 `mecoren/PiggyCount`，并将项目品牌视觉从"蜜蜂"统一改造为"小猪/小猪存钱罐"，覆盖 SVG 图标、推广文案 emoji、App Launcher 图标、分享海报 Logo。

## 二、关键技术决策

| 决策 | 选择 | 理由 |
|------|------|------|
| URL 替换方式 | 全仓库文本替换 + 重新生成 l10n | URL 是字符串字面量，无运行时拼接，直接文本替换最安全 |
| URL 替换范围 | 仅 `mecoren/PiggyCount` 主仓库 | 其他仓库（PiggyCount-Cloud / PiggyCount-Website 等）不属于本次需求 |
| LICENSE 署名处理 | 保留 Copyright `sunxiao (GitHub: TNT-Likely)` | 原作者署名属版权声明，不属于 URL，不应修改 |
| FUNDING.yml 处理 | 保留 `github: TNT-Likely` | Sponsor 账号 ID 不是 URL，需用户单独在 GitHub 设置中处理 |
| piggy.svg 风格 | 简约线条 + currentColor 主题色填充 | 与原蜜蜂 SVG 视觉语言一致，保留 PiggyIcon 接口 |
| Launcher 图标生成 | AI 图像生成 + 同一 prompt 保证风格一致 | 项目无设计源文件，需重新生成；同 prompt + 同种子保证一致 |
| iOS AppIcon 处理 | 仅替换 1024×1024 主图 PNG | iOS Contents.json 结构不变，只换位图 |
| 二维码 URL | 跟随代码字符串自动变更 | QrImageView 的 data 参数已是字符串字面量，URL 替换后二维码自动指向新地址 |
| l10n 重新生成 | 替换 .arb 后运行 `flutter gen-l10n` | 保证 app_localizations*.dart 同步更新 |

## 三、实现步骤

### 步骤 1：URL 全量替换

**操作**：跨文件文本替换

替换规则（按顺序执行，避免误伤）：
1. `https://github.com/mecoren/PiggyCount` → `https://github.com/mecoren/PiggyCount`（带协议前缀的完整 URL）
2. `https://api.github.com/repos/mecoren/PiggyCount` → `https://api.github.com/repos/mecoren/PiggyCount`（API URL）
3. `github.com/mecoren/PiggyCount` → `github.com/mecoren/PiggyCount`（无协议前缀的纯文本，如海报中显示的短链接）

**覆盖目录**：
- `lib/`（Dart 代码、l10n .arb、posters）
- `docs/`、`docoments/`（文档）
- `.github/`（ISSUE_TEMPLATE、config.yml；**不包含 FUNDING.yml 的 `github: TNT-Likely`**）
- `CONTRIBUTING.md`、`docs/contributing/`（保留维护者署名，仅替换 URL）
- `LICENSE`、`LICENSE_EN`（仅替换 Issues URL 行，保留 Copyright 行）
- `COMMERCIAL_LICENSE.md`
- `packages/*/pubspec.yaml`、`packages/*/CHANGELOG.md`、`packages/*/USAGE_GUIDE.md`、`packages/*/PROJECT_SUMMARY.md`
- `packages/flutter_cloud_sync_icloud/ios/flutter_cloud_sync_icloud.podspec`

**验证**：
```bash
# 期望返回 0 行（PiggyCount-Cloud / PiggyCount-Website 等其他仓库链接不在搜索范围）
grep -rn "mecoren/PiggyCount" lib/ docs/ docoments/ .github/ISSUE_TEMPLATE/ .github/config.yml \
  CONTRIBUTING.md LICENSE LICENSE_EN COMMERCIAL_LICENSE.md packages/
```

### 步骤 2：推广文案 emoji 替换

**文件**：
- `lib/l10n/app_zh.arb`：`shareGuidanceCopyText` 字段，将 `🐝` 替换为 `🐷`
- `lib/l10n/app_zh_TW.arb`：同上
- `lib/l10n/app_en.arb`：若包含 `🐝` 一并替换为 `🐷`
- `lib/l10n/app_ko.arb`：同上

**操作**：运行 `flutter gen-l10n` 重新生成 `app_localizations*.dart`

### 步骤 3：重写 piggy.svg

**文件**：`assets/piggy.svg`

设计要点：
- 保留 `width="256" height="256" viewBox="0 0 256 256"`
- 主体使用 `fill="currentColor"` 以支持 PiggyIcon 的主题色注入
- 描边用 `stroke="#000"` 保证暗黑模式下可见
- 造型：圆润小猪头（含猪鼻、耳朵、眼睛），简约线条风格
- 不使用渐变（保证 currentColor 单色填充有效）

### 步骤 4：生成 App Launcher 图标

**生成策略**：使用 AI 图像生成工具生成一张 1024×1024 高清小猪图标作为主图，再用脚本/工具缩放到各密度尺寸。

**生成资源**：
- `assets/icon/adaptive_foreground.png`（Android 自适应前景，1024×1024，主体居中并保留 18% 安全边距）
- `assets/icon/launcher_legacy.png`（旧版启动器，512×512）
- `assets/icon/adaptive_monochrome.png`（Android 13+ 单色主题，1024×1024，纯白前景透明背景）
- `assets/icon/preview_themed.png`（主题图标预览，512×512）
- `android/app/src/main/res/mipmap-mdpi/ic_launcher.png`（48×48）
- `android/app/src/main/res/mipmap-hdpi/ic_launcher.png`（72×72）
- `android/app/src/main/res/mipmap-xhdpi/ic_launcher.png`（96×96）
- `android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png`（144×144）
- `android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png`（192×192）
- iOS Assets.xcassets/AppIcon.appiconset/ 下各尺寸 PNG

**Android 缩放方式**：使用 `magick`/`convert` 或 Dart 脚本对 1024×1024 主图按比例缩放。考虑到本机环境，使用 PowerShell 调用 .NET System.Drawing 或 Python PIL 进行缩放。

**iOS AppIcon 处理**：iOS 使用单一 1024×1024 主图（iOS 14+ 单尺寸），需先查看现有 Contents.json 决定是否需多尺寸。若现有结构仅需 1024×1024，则单图即可。

### 步骤 5：生成分享海报 Logo

**文件**：`assets/logo2.png`

**生成策略**：与 piggy.svg 风格一致的小猪 Logo，512×512 或更大，透明背景。

### 步骤 6：重新生成 l10n 并验证

- `flutter gen-l10n`
- `flutter analyze` 0 errors
- 手动验证：关于页 GitHub 跳转、更新检查、复制推广文案、分享海报二维码扫描

## 四、文件清单

| 文件 | 类型 | 描述 |
|------|------|------|
| 50+ 文件 | 修改 | URL 文本替换（见步骤 1 覆盖目录） |
| `lib/l10n/app_zh.arb` | 修改 | shareGuidanceCopyText emoji 🐝→🐷 |
| `lib/l10n/app_zh_TW.arb` | 修改 | 同上 |
| `lib/l10n/app_en.arb` | 修改 | 同上（若含 🐝） |
| `lib/l10n/app_ko.arb` | 修改 | 同上（若含 🐝） |
| `assets/piggy.svg` | 重写 | 蜜蜂 → 小猪造型 |
| `assets/logo2.png` | 重新生成 | 小猪 Logo |
| `assets/icon/adaptive_foreground.png` | 重新生成 | Android 自适应前景 |
| `assets/icon/launcher_legacy.png` | 重新生成 | 旧版启动器 |
| `assets/icon/adaptive_monochrome.png` | 重新生成 | Android 13+ 单色主题 |
| `assets/icon/preview_themed.png` | 重新生成 | 主题图标预览 |
| `android/app/src/main/res/mipmap-*/ic_launcher.png` (5 个) | 重新生成 | Android 各密度启动器 |
| iOS `Assets.xcassets/AppIcon.appiconset/*.png` | 重新生成 | iOS AppIcon 各尺寸 |

## 五、风险与边界条件

1. **AI 图像生成风格一致性**：使用同一 prompt + 描述同一小猪造型，对 1024×1024 主图缩放至各尺寸，避免多次生成导致风格漂移
2. **iOS AppIcon 多尺寸**：若 Contents.json 要求多尺寸（如 20/29/40/60/76/83.5/1024），需先 Read 现有 Contents.json 确认结构。若仅 1024×1024（iOS 14+），则单图即可
3. **URL 替换误伤**：替换 `mecoren/PiggyCount` 时不能误伤 `TNT-Likely/PiggyCount-Cloud`、`TNT-Likely/PiggyCount-Website`。规则上 `mecoren/PiggyCount` 是 `TNT-Likely/PiggyCount-Cloud` 等的前缀，需用更精确的正则或边界匹配
4. **暗黑模式 SVG 可见性**：原 PiggyIcon 在暗黑模式下加圆形浅色遮罩，新 SVG 也需在该遮罩下可见（描边为黑色或深色）
5. **二维码扫描兼容**：URL 变长不影响二维码生成，但需保证 QrImageView 的 version 设为 auto
6. **l10n 重新生成**：修改 .arb 后必须运行 `flutter gen-l10n`，否则 app_localizations*.dart 与 .arb 不一致

## 六、验证标准

1. ✅ `grep -rn "mecoren/PiggyCount" lib/ docs/ docoments/ .github/ISSUE_TEMPLATE/ CONTRIBUTING.md LICENSE LICENSE_EN COMMERCIAL_LICENSE.md packages/` 返回 0 行（其他仓库链接保留）
2. ✅ `grep -rn "TNT-Likely/PiggyCount-Cloud\|TNT-Likely/PiggyCount-Website" .` 仍能找到（保留其他仓库链接）
3. ✅ 4 个 .arb 文件中 `shareGuidanceCopyText` 含 🐷 不含 🐝
4. ✅ `assets/piggy.svg` 为小猪造型
5. ✅ `assets/logo2.png` 已替换
6. ✅ Android 5 个 mipmap 密度 + iOS AppIcon 已替换
7. ✅ `flutter gen-l10n` 无错误
8. ✅ `flutter analyze` 0 errors
