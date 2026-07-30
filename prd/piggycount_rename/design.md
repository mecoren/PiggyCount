# PiggyCount 重命名设计文档

## 一、设计目标

将 BeeCount（蜜蜂记账）项目**完整、可验证、可回滚**地重命名为 PiggyCount（小猪记账），覆盖配置文件、源代码、目录文件、数据库/API、文档五个层面，共 22 项风险点。

## 二、总体策略

### 2.1 分阶段执行

将整个重命名拆分为 **6 个独立阶段**，每个阶段产出可独立验证的 git commit：

```
Phase 0: 准备与备份           → git tag pre-piggycount-rename
Phase 1: 配置文件和包标识符   → 风险最高，优先处理
Phase 2: 目录和文件重命名     → 影响 import 路径
Phase 3: Dart 类名和引用更新  → 工作量最大
Phase 4: 字符串资源和本地化   → 用户可见文案
Phase 5: 文档和 README        → 风险最低
Phase 6: 验证和清理           → 全量回归
```

### 2.2 关键原则

1. **从外到内**：先改配置文件（影响构建）→ 再改文件名（影响 import）→ 再改类名（影响引用）→ 最后改文案和文档
2. **批量替换优先**：能用 IDE 全局重构或脚本批量处理的，不手动逐个改
3. **每阶段验证**：每个 Phase 完成后必须通过 `flutter analyze` 和 `flutter test`
4. **明确不变项**：`BEECRYPT1:` 加密格式标识、内部 packages 名、官网域名常量 保持不变

## 三、五大类改名步骤清单（按风险等级排序）

### 📋 类别 1：项目配置文件改名（对应需求 FR-1）

**风险等级：P0 + P1（最高）**
- 涉及 R3、R4（包标识符导致已发布用户无法升级）
- 涉及 R5、R6、R8、R9（构建失败）

#### 1.1 Flutter 项目配置

| 文件 | 改动内容 | 风险 |
| --- | --- | --- |
| `pubspec.yaml` | `name: beecount` → `name: piggycount`；`description` 字段更新 | R9（assets 引用） |
| `.metadata` | 检查并更新项目名（如有） | 低 |

#### 1.2 Android 配置

| 文件 | 改动内容 | 风险 |
| --- | --- | --- |
| `android/app/build.gradle` | `namespace` = `com.wait.piggycount`；`applicationId` = `com.wait.piggycount`；`resValue "string", "app_name", "蜜蜂记账测试版"` → `"小猪记账测试版"`；`resValue "string", "app_name", "蜜蜂记账"` → `"小猪记账"`；debug buildType 的 app_name 同步 | R3、R6 |
| `android/app/src/main/AndroidManifest.xml` | URL scheme `beecount` → `piggycount`；所有 `android:name="com.tntlikely.beecount.BeeCount*Provider"` → `com.wait.piggycount.PiggyCount*Provider`；`android:name=".BeeCount*Provider"` → `.PiggyCount*Provider`；`@xml/beecount_widget_info` → `@xml/piggycount_widget_info` | R10 |
| `android/app/src/debug/AndroidManifest.xml` | 检查是否有 beecount 引用 | 低 |
| `android/app/src/profile/AndroidManifest.xml` | 检查是否有 beecount 引用 | 低 |
| `android/app/src/main/res/values/strings.xml` | `widget_name` 等字符串中的 "蜜蜂记账" → "小猪记账" | R12 |
| `android/app/src/main/res/values-en/strings.xml` | "BeeCount" → "PiggyCount" | R12 |
| `android/app/src/main/res/values-zh-rTW/strings.xml` | "蜜蜂記帳" → "小豬記帳" | R12 |

#### 1.3 iOS 配置

| 文件 | 改动内容 | 风险 |
| --- | --- | --- |
| `ios/Flutter/Debug.xcconfig` | `APP_DISPLAY_NAME=小猪记账测试版`；`PRODUCT_BUNDLE_IDENTIFIER=com.wait.piggycount.dev` | R4 |
| `ios/Flutter/Release.xcconfig` | `APP_DISPLAY_NAME=小猪记账`；`PRODUCT_BUNDLE_IDENTIFIER=com.wait.piggycount` | R4 |
| `ios/Runner.xcodeproj/project.pbxproj` | 所有 `PRODUCT_BUNDLE_IDENTIFIER` 改为新值；`BeeCountWidgetExtension` target name → `PiggyCountWidgetExtension`；file reference 路径更新；`INFOPLIST_KEY_CFBundleDisplayName` 更新；`CODE_SIGN_ENTITLEMENTS` 路径更新 | **R5、R8（最高风险）** |
| `ios/Runner/Info.plist` | `CFBundleURLName`: `com.tntlikely.beecount` → `com.wait.piggycount`；`CFBundleURLSchemes`: `beecount` → `piggycount`；`NSUbiquitousContainers` key: `iCloud.com.tntlikely.beecount` → `iCloud.com.wait.piggycount`；`NSUbiquitousContainerName`: `BeeCount` → `PiggyCount`；所有 `蜜蜂记账` → `小猪记账`（隐私描述字符串） | R11、R1 |
| `ios/Runner/Runner.entitlements` | `iCloud.com.tntlikely.beecount` → `iCloud.com.wait.piggycount`（2 处）；`group.com.tntlikely.beecount` → `group.com.wait.piggycount` | **R1、R2（数据丢失）** |
| `ios/BeeCountWidgetExtension.entitlements` | **文件重命名**为 `PiggyCountWidgetExtension.entitlements`；内容中 `group.com.tntlikely.beecount` → `group.com.wait.piggycount` | R2、R8 |
| `ios/Runner/en.lproj/InfoPlist.strings` | `BeeCount` → `PiggyCount` | R13 |
| `ios/Runner/zh-Hans.lproj/InfoPlist.strings` | `蜜蜂记账` → `小猪记账`；`蜜蜂记账测试版` → `小猪记账测试版` | R13 |
| `ios/Runner/zh-Hant.lproj/InfoPlist.strings` | `蜜蜂記帳` → `小豬記帳`；`蜜蜂記帳測試版` → `小豬記帳測試版` | R13 |
| `ios/Podfile` / `Podfile.lock` | 检查并执行 `pod install` 重新生成 | R16 |

### 📋 类别 2：源代码中所有引用旧项目名的更新（对应需求 FR-2）

**风险等级：P1 + P2（高）**
- 涉及 R7（编译失败）
- 涉及 R14（测试失败）
- 涉及 R15（加密格式误改 — 必须避免）

#### 2.1 Dart 类名重命名映射表（15 个类）

| 原类名 | 新类名 | 文件位置 |
| --- | --- | --- |
| `BeeApp` | `PiggyApp` | `lib/app.dart` |
| `BeeTheme` | `PiggyTheme` | `lib/theme.dart` |
| `BeeTokens` | `PiggyTokens` | `lib/styles/tokens.dart` |
| `BeeDimens` | `PiggyDimens` | `lib/styles/tokens.dart` |
| `BeeShadows` | `PiggyShadows` | `lib/styles/tokens.dart` |
| `BeeDivider` | `PiggyDivider` | `lib/styles/tokens.dart` |
| `BeeChartTokens` | `PiggyChartTokens` | `lib/styles/tokens.dart` |
| `BeeTextTokens` | `PiggyTextTokens` | `lib/styles/tokens.dart` |
| `BeeTypography` | `PiggyTypography` | `lib/styles/tokens.dart` |
| `BeeDatabase` | `PiggyDatabase` | `lib/data/db.dart` |
| `BeeMenuItem` | `PiggyMenuItem` | `lib/widgets/ui/bee_popup_menu.dart`（文件同步重命名） |
| `BeePopupMenu` | `PiggyPopupMenu` | `lib/widgets/ui/bee_popup_menu.dart`（文件同步重命名） |
| `BeeIcon` | `PiggyIcon` | `lib/widgets/biz/bee_icon.dart`（文件同步重命名） |
| `BeeCountCloudConfig` | `PiggyCountCloudConfig` | `lib/services/export/config_export_service.dart` |
| `BeeCountCloudSyncPage` | `PiggyCountCloudSyncPage` | `lib/pages/cloud/beecount_cloud_sync_page.dart`（文件同步重命名） |

**重构策略**：
- 优先使用 IDE 的 "Rename Symbol" 功能（VS Code: F2，Android Studio: Shift+F6）
- 每个类重命名后立即更新对应文件名
- 通过 barrel export 文件（`biz.dart`, `ui.dart`）传播重命名

#### 2.2 关键常量和字符串更新

| 文件 | 改动 | 风险 |
| --- | --- | --- |
| `lib/data/encryption/ciphertext_format.dart` | **仅更新注释** "BeeCount 同步加密" → "PiggyCount 同步加密"。`BEECRYPT1:` 常量**绝对不可修改** | **R15（数据丢失）** |
| `lib/utils/website_urls.dart` | 注释中 `BeeCount-Website` → `PiggyCount-Website`。`baseUrl` 常量 `https://count.beejz.com` **保持不变**（DNS 由用户处理） | 低 |
| `lib/main.dart` | `BeeApp` → `PiggyApp`；`BeeTheme` → `PiggyTheme`；其他字符串引用 | R7 |
| `lib/data/db.dart` | `BeeDatabase` → `PiggyDatabase`；类内注释 | R7 |
| `lib/styles/tokens.dart` | 7 个 `Bee*` 类同步重命名 | R7 |

#### 2.3 包内文件重命名

| 原文件 | 新文件 | 类名 |
| --- | --- | --- |
| `packages/flutter_cloud_sync/lib/src/providers/beecount_cloud_provider.dart` | `piggycount_cloud_provider.dart` | `BeeCountCloudProvider` → `PiggyCountCloudProvider` |
| `packages/flutter_cloud_sync/lib/src/providers/` (barrel export) | 更新 export 语句 | - |

#### 2.4 本地化字符串更新（4 种语言）

| 文件 | 改动 |
| --- | --- |
| `lib/l10n/app_en.arb` | 所有 `"BeeCount"` → `"PiggyCount"`；`"BeeCount Cloud"` → `"PiggyCount Cloud"`（约 61 处） |
| `lib/l10n/app_zh.arb` | `"蜜蜂记账"` → `"小猪记账"`（约 42 处） |
| `lib/l10n/app_zh_TW.arb` | `"蜜蜂記帳"` → `"小豬記帳"`（约 42 处） |
| `lib/l10n/app_ko.arb` | 检查并更新（约 61 处） |
| `lib/l10n/app_localizations*.dart` | 重新生成：`flutter gen-l10n` |

### 📋 类别 3：目录和文件的重命名（对应需求 FR-3）

**风险等级：P1（高）**
- 涉及 R5、R6、R8（构建失败）

#### 3.1 目录重命名

| 原目录 | 新目录 | 说明 |
| --- | --- | --- |
| `ios/BeeCountWidget/` | `ios/PiggyCountWidget/` | iOS Widget Extension 源码目录 |
| `android/app/src/main/kotlin/com/tntlikely/beecount/` | `android/app/src/main/kotlin/com/wait/piggycount/` | Kotlin 包目录（需创建中间目录 `com/wait/piggycount/`） |
| `android/app/src/main/kotlin/com/tntlikely/` | 删除（如无其他类） | 清理空目录 |

#### 3.2 iOS Swift 文件重命名（7 个文件）

| 原文件 | 新文件 |
| --- | --- |
| `ios/BeeCountWidget/BeeCountWidget.swift` | `ios/PiggyCountWidget/PiggyCountWidget.swift` |
| `ios/BeeCountWidget/BeeCountWidgetBundle.swift` | `ios/PiggyCountWidget/PiggyCountWidgetBundle.swift` |
| `ios/BeeCountWidget/BeeCountBudgetWidget.swift` | `ios/PiggyCountWidget/PiggyCountBudgetWidget.swift` |
| `ios/BeeCountWidget/BeeCountDashboardWidget.swift` | `ios/PiggyCountWidget/PiggyCountDashboardWidget.swift` |
| `ios/BeeCountWidget/BeeCountNetWorthWidget.swift` | `ios/PiggyCountWidget/PiggyCountNetWorthWidget.swift` |
| `ios/BeeCountWidget/BeeCountQuickAddWidget.swift` | `ios/PiggyCountWidget/PiggyCountQuickAddWidget.swift` |
| `ios/BeeCountWidget/BeeCountRecentWidget.swift` | `ios/PiggyCountWidget/PiggyCountRecentWidget.swift` |

**Swift 文件内部需同步更新**：
- `struct BeeCountWidget` → `struct PiggyCountWidget`
- `@main struct BeeCountWidgetBundle` → `@main struct PiggyCountWidgetBundle`
- 所有 `BeeCount*Widget` struct 名同步重命名

#### 3.3 Kotlin 文件重命名（8 个文件）

| 原文件 | 新文件 |
| --- | --- |
| `BeeCountWidgetProvider.kt` | `PiggyCountWidgetProvider.kt` |
| `BeeCountSizedWidgetProviders.kt` | `PiggyCountSizedWidgetProviders.kt` |
| `BeeCountRecentWidgetProvider.kt` | `PiggyCountRecentWidgetProvider.kt` |
| `BeeCountQuickAddWidgetProvider.kt` | `PiggyCountQuickAddWidgetProvider.kt` |
| `BeeCountNetWorthWidgetProvider.kt` | `PiggyCountNetWorthWidgetProvider.kt` |
| `BeeCountGlanceSmallWidgetProvider.kt` | `PiggyCountGlanceSmallWidgetProvider.kt` |
| `BeeCountDashboardWidgetProvider.kt` | `PiggyCountDashboardWidgetProvider.kt` |
| `BeeCountBudgetWidgetProvider.kt` | `PiggyCountBudgetWidgetProvider.kt` |

**Kotlin 文件内部需同步更新**：
- `package com.tntlikely.beecount` → `package com.wait.piggycount`
- 所有 `class BeeCount*Provider` → `class PiggyCount*Provider`

#### 3.4 Android 资源文件重命名

| 原文件 | 新文件 |
| --- | --- |
| `android/app/src/main/res/xml/beecount_widget_info.xml` | `piggycount_widget_info.xml` |
| `android/app/src/main/res/layout/beecount_widget.xml` | `piggycount_widget.xml` |

#### 3.5 Dart 文件重命名

| 原文件 | 新文件 |
| --- | --- |
| `lib/widgets/ui/bee_popup_menu.dart` | `lib/widgets/ui/piggy_popup_menu.dart` |
| `lib/widgets/biz/bee_icon.dart` | `lib/widgets/biz/piggy_icon.dart` |
| `lib/pages/cloud/beecount_cloud_sync_page.dart` | `lib/pages/cloud/piggycount_cloud_sync_page.dart` |

#### 3.6 资源文件重命名

| 原文件 | 新文件 |
| --- | --- |
| `assets/bee.svg` | `assets/piggy.svg` |
| `assets/images/beeassets_dashboard.png` | `assets/images/piggyassets_dashboard.png` |
| `assets/images/beeassets_dashboard_en.png` | `assets/images/piggyassets_dashboard_en.png` |
| `assets/images/beeassets_holdings.png` | `assets/images/piggyassets_holdings.png` |
| `assets/images/beeassets_holdings_en.png` | `assets/images/piggyassets_holdings_en.png` |
| `assets/images/beeassets_logo.png` | `assets/images/piggyassets_logo.png` |
| `assets/images/beeassets_logo.svg` | `assets/images/piggyassets_logo.svg` |
| `assets/images/beedns_logo.png` | `assets/images/piggydns_logo.png` |

#### 3.7 测试文件重命名

| 原文件 | 新文件 |
| --- | --- |
| `test/cloud/sync/_fakes/fake_beecount_cloud_provider.dart` | `fake_piggycount_cloud_provider.dart` |

### 📋 类别 4：数据库和 API 端点变更（对应需求 FR-4）

**风险等级：P0 + P2**
- 涉及 R1、R2（数据丢失）
- 涉及 R11（深链失效）

#### 4.1 数据库相关

| 项 | 当前 | 目标 | 影响 |
| --- | --- | --- | --- |
| Supabase 表名 | `transactions`, `ledgers`, `accounts` 等通用名 | **不变** | 无 |
| Supabase 项目 URL | 通过运行时配置注入 | **不变**（用户单独配置） | 无 |
| Drift 数据库文件名 | 检查 `lib/data/db.dart` 中的数据库文件名 | 若含 "beecount" 则改 | 需进一步检查 |

#### 4.2 iCloud 配置

| 项 | 当前 | 目标 | 影响 |
| --- | --- | --- | --- |
| iCloud 容器 ID | `iCloud.com.tntlikely.beecount` | `iCloud.com.wait.piggycount` | R1（旧数据无法访问） |
| iCloud 容器名 | `BeeCount` | `PiggyCount` | Info.plist 中的 `NSUbiquitousContainerName` |

#### 4.3 App Group

| 项 | 当前 | 目标 | 影响 |
| --- | --- | --- | --- |
| App Group ID | `group.com.tntlikely.beecount` | `group.com.wait.piggycount` | R2（Widget 数据共享断裂） |

**前置操作**（需在 Apple Developer Portal 手动完成）：
1. 创建新 App Group: `group.com.wait.piggycount`
2. 创建新 iCloud 容器: `iCloud.com.wait.piggycount`
3. 将新 App ID `com.wait.piggycount` 关联到上述 Group 和 Container
4. 重新生成 Provisioning Profile

#### 4.4 URL Scheme 和深链

| 项 | 当前 | 目标 | 影响 |
| --- | --- | --- | --- |
| Android URL Scheme | `beecount://` | `piggycount://` | R11 |
| iOS URL Scheme | `beecount` | `piggycount` | R11 |
| iOS CFBundleURLName | `com.tntlikely.beecount` | `com.wait.piggycount` | 低 |
| `lib/services/platform/app_link_service.dart` | 检查是否有硬编码 `beecount://` | 同步更新 | R11 |

#### 4.5 BeeCount Cloud API

| 项 | 当前 | 目标 | 备注 |
| --- | --- | --- | --- |
| API 域名常量 | `https://count.beejz.com` | **保持不变** | DNS 由用户处理 |
| Provider 类名 | `BeeCountCloudProvider` | `PiggyCountCloudProvider` | 代码层 |
| 配置类名 | `BeeCountCloudConfig` | `PiggyCountCloudConfig` | 代码层 |

### 📋 类别 5：文档和 README 同步更新（对应需求 FR-5）

**风险等级：P3（低）**

#### 5.1 根目录文档

| 文件 | 改动 |
| --- | --- |
| `README.md` | 项目名、徽章、链接、描述（约 28 处） |
| `README_EN.md` | 同上（约 34 处） |
| `CONTRIBUTING.md` | 项目名引用（约 3 处） |
| `COMMERCIAL_LICENSE.md` | 项目名（约 9 处） |
| `PRIVACY.md` | 项目名（约 17 处） |
| `LICENSE` | 项目名（约 3 处） |
| `LICENSE_EN` | 项目名（约 3 处） |
| `THIRD-PARTY-NOTICES.md` | 检查是否有 BeeCount 引用 |

#### 5.2 `docoments/` 目录（17 个文档）

| 文件 | 引用数 |
| --- | --- |
| `01-project-overview.md` | 32 |
| `02-glossary.md` | 11 |
| `03-tech-stack.md` | 28 |
| `04-system-architecture.md` | 21 |
| `05-core-modules.md` | 14 |
| `06-data-sync-and-offline.md` | 39 |
| `07-data-model.md` | 8 |
| `08-api-and-data-access.md` | 20 |
| `09-error-handling.md` | 15 |
| `10-testing-strategy.md` | 21 |
| `11-performance.md` | 46 |
| `12-security.md` | 72 |
| `13-build-release.md` | 92 |
| `14-logging.md` | 38 |
| `15-development-guidelines.md` | 47 |
| `16-known-issues.md` | 53 |
| `17-version-evolution.md` | 47 |
| `INDEX.md` | 84 |

**策略**：批量替换 `BeeCount` → `PiggyCount`、`蜜蜂记账` → `小猪记账`、`beecount` → `piggycount`

#### 5.3 `docs/` 目录

| 文件/目录 | 改动 |
| --- | --- |
| `docs/cloud-setup.md` | 约 17 处 |
| `docs/cloud-setup_EN.md` | 约 21 处 |
| `docs/contributing/CONTRIBUTING_ZH.md` | 约 16 处 |
| `docs/contributing/CONTRIBUTING_EN.md` | 约 19 处 |
| `docs/donate/README_ZH.md` | 约 1 处 |
| `docs/donate/README_EN.md` | 约 1 处 |
| `docs/design/DESIGN_TOKENS.md` | 约 2 处 |

#### 5.4 `.github/` 目录

| 文件 | 改动 |
| --- | --- |
| `.github/FUNDING.yml` | 检查 |
| `.github/PULL_REQUEST_TEMPLATE.md` | 检查 |
| `.github/ISSUE_TEMPLATE/*.yml` | 7 个模板文件，约 22 处 |
| `.github/workflows/release.yml` | 约 8 处 |
| `.github/workflows/issue-lint.yml` | 检查 |
| `.github/workflows/pullfrog.yml` | 检查 |

#### 5.5 其他文件

| 文件 | 改动 |
| --- | --- |
| `.vscode/launch.json` | 项目名（约 5 处） |
| `.workbuddy/memory/MEMORY.md` | 项目名（约 1 处） |
| `assets/header_skins/README.md` | 项目名（约 1 处） |
| `assets/header_skins/README_EN.md` | 项目名（约 1 处） |
| `scripts/README.md` | 项目名 |
| `scripts/i18n/README.md` | 项目名 |
| `scripts/i18n/check_status.dart` | 项目名（约 2 处） |
| `scripts/gen_store_test_data.py` | 项目名（约 7 处） |
| `demo/_generate.py` | 项目名（约 2 处） |
| `demo/applink_test.html` | 项目名（约 2 处） |
| `demo/100-records/store_setup_zh.yaml` | 项目名 |
| `demo/100-records/store_setup_en.yaml` | 项目名 |
| `demo/10000-records/store_setup_zh.yaml` | 项目名 |
| `demo/10000-records/store_setup_en.yaml` | 项目名 |
| `packages/*/README.md` | 各包的 README |
| `packages/*/CHANGELOG.md` | 各包的 CHANGELOG |
| `packages/*/LICENSE` | 各包的 LICENSE |
| `packages/*/PROJECT_SUMMARY.md` | flutter_cloud_sync 的项目摘要（约 10 处） |
| `packages/*/USAGE_GUIDE.md` | flutter_cloud_sync 的使用指南（约 2 处） |

## 四、关键技术决策

### 4.1 加密格式标识 `BEECRYPT1:` 保持不变

**决策**：不重命名 `BEECRYPT1:` magic header。

**理由**：
1. 这是数据格式版本号，类似 `PNG\x0D\x0A` 或 `\x1f\x8b`（gzip）
2. 已写入云端历史密文，改名导致所有已加密数据无法解密
3. 项目 memory 明确记录：`Encrypted ciphertext must use format 'BEECRYPT1:<base64(salt)>:<base64(nonce(12) || ciphertext || mac(16))>'`
4. 该标识与品牌名无关，仅是巧合包含 "BEE" 前缀

**实施**：在 `ciphertext_format.dart` 中仅更新注释，常量值保持不变。

### 4.2 内部 packages 名称保持不变

**决策**：不重命名 `flutter_cloud_sync`, `flutter_ai_kit`, `flutter_cloud_sync_supabase` 等内部包名。

**理由**：
1. 这些是通用工具包名，不含 "beecount" 字符串
2. 改名会涉及 9 个 pubspec.yaml 和所有 import 路径，工作量巨大但收益为零
3. 包名是技术标识，不是品牌资产

### 4.3 官网域名 `count.beejz.com` 保持不变

**决策**：App 代码中保留 `https://count.beejz.com` 常量。

**理由**：
1. 域名迁移涉及 DNS、CDN、SSL 证书等基础设施变更
2. App 代码只需指向一个可访问的 URL，DNS 切换后旧域名可重定向到新域名
3. 用户可在 `lib/utils/website_urls.dart` 的 `baseUrl` 常量中未来单独修改

### 4.4 iOS `project.pbxproj` 修改策略

**决策**：使用文本编辑器谨慎手动修改，不依赖 Xcode IDE。

**理由**：
1. `project.pbxproj` 是文本格式，但结构复杂（UUID 引用、build phase、file reference 交叉引用）
2. 在 Windows 环境下无法使用 Xcode
3. 通过 grep 精确定位每个 `BeeCount` 引用，逐个评估修改影响

**实施**：
- 修改前备份原文件
- 每个修改都通过 grep 验证上下文
- 修改后通过 `xcodebuild -list` 验证 target 名称正确

### 4.5 Dart 类名重构策略

**决策**：采用 "Rename Symbol" + barrel export 传播。

**理由**：
1. 手动改 15 个类名 + 2628 处引用极易遗漏
2. IDE 的 Rename Symbol 能自动找到所有引用并同步更新
3. barrel export（`biz.dart`, `ui.dart`, `tokens.dart`）确保外部引用通过统一入口

**实施顺序**：
1. 先改底层（`tokens.dart` 中的 7 个类）
2. 再改中层（`theme.dart`, `db.dart`, `app.dart`）
3. 再改组件层（`bee_popup_menu.dart`, `bee_icon.dart`）
4. 最后改业务层（`beecount_cloud_sync_page.dart`, `config_export_service.dart`）
5. 每改完一个类，运行 `flutter analyze` 验证

### 4.6 资源文件改名策略

**决策**：所有 `bee*` 前缀的资源文件改名为 `piggy*`，并同步更新 `pubspec.yaml` 的 assets 声明和代码中的引用路径。

**理由**：
1. 保持文件名与品牌一致
2. 避免遗留 "bee" 痕迹

**注意**：图标内容（如 `bee.svg` 的图形）不在本次范围，仅改文件名。

## 五、文件结构映射

### 改名前 → 改名后目录结构对比

```
改名前：                                    改名后：
ios/BeeCountWidget/                        ios/PiggyCountWidget/
  ├── BeeCountWidget.swift                   ├── PiggyCountWidget.swift
  ├── BeeCountWidgetBundle.swift             ├── PiggyCountWidgetBundle.swift
  ├── BeeCountBudgetWidget.swift             ├── PiggyCountBudgetWidget.swift
  ├── BeeCountDashboardWidget.swift          ├── PiggyCountDashboardWidget.swift
  ├── BeeCountNetWorthWidget.swift           ├── PiggyCountNetWorthWidget.swift
  ├── BeeCountQuickAddWidget.swift           ├── PiggyCountQuickAddWidget.swift
  ├── BeeCountRecentWidget.swift             ├── PiggyCountRecentWidget.swift
  └── Info.plist                             └── Info.plist
ios/BeeCountWidgetExtension.entitlements   ios/PiggyCountWidgetExtension.entitlements

android/.../kotlin/com/tntlikely/beecount/ android/.../kotlin/com/wait/piggycount/
  ├── BeeCountWidgetProvider.kt              ├── PiggyCountWidgetProvider.kt
  ├── BeeCountSizedWidgetProviders.kt        ├── PiggyCountSizedWidgetProviders.kt
  ├── BeeCountRecentWidgetProvider.kt        ├── PiggyCountRecentWidgetProvider.kt
  ├── BeeCountQuickAddWidgetProvider.kt      ├── PiggyCountQuickAddWidgetProvider.kt
  ├── BeeCountNetWorthWidgetProvider.kt      ├── PiggyCountNetWorthWidgetProvider.kt
  ├── BeeCountGlanceSmallWidgetProvider.kt   ├── PiggyCountGlanceSmallWidgetProvider.kt
  ├── BeeCountDashboardWidgetProvider.kt     ├── PiggyCountDashboardWidgetProvider.kt
  └── BeeCountBudgetWidgetProvider.kt        └── PiggyCountBudgetWidgetProvider.kt

android/.../res/xml/beecount_widget_info.xml   → piggycount_widget_info.xml
android/.../res/layout/beecount_widget.xml     → piggycount_widget.xml

lib/widgets/ui/bee_popup_menu.dart           → lib/widgets/ui/piggy_popup_menu.dart
lib/widgets/biz/bee_icon.dart                → lib/widgets/biz/piggy_icon.dart
lib/pages/cloud/beecount_cloud_sync_page.dart → lib/pages/cloud/piggycount_cloud_sync_page.dart

packages/flutter_cloud_sync/lib/src/providers/
  beecount_cloud_provider.dart                 → piggycount_cloud_provider.dart

test/cloud/sync/_fakes/
  fake_beecount_cloud_provider.dart            → fake_piggycount_cloud_provider.dart

assets/bee.svg                                → assets/piggy.svg
assets/images/beeassets_*.png (6 个)          → assets/images/piggyassets_*.png
assets/images/beedns_logo.png                 → assets/images/piggydns_logo.png
```

## 六、验证策略

### 6.1 每阶段验证

每个 Phase 完成后执行：

```bash
# 1. 静态分析
flutter analyze

# 2. 单元测试
flutter test

# 3. 残留扫描（按文件类型）
# Dart 文件
grep -rn "BeeCount\|蜜蜂记账\|蜜蜂記帳" --include="*.dart" lib/ test/ packages/
# Android 文件
grep -rn "beecount\|BeeCount\|蜜蜂记账" --include="*.xml" --include="*.gradle" --include="*.kt" android/
# iOS 文件
grep -rn "beecount\|BeeCount\|蜜蜂记账" --include="*.swift" --include="*.plist" --include="*.entitlements" --include="*.pbxproj" --include="*.xcconfig" ios/
```

### 6.2 最终验证

完成所有 Phase 后执行：

```bash
# 1. 清理并重新获取依赖
flutter clean
flutter pub get

# 2. 重新生成本地化
flutter gen-l10n

# 3. 重新生成 drift 代码
dart run build_runner build --delete-conflicting-outputs

# 4. 全量分析
flutter analyze

# 5. 全量测试
flutter test

# 6. Android 构建
flutter build apk --flavor prod --release
flutter build appbundle --flavor prod --release

# 7. 残留扫描（排除加密格式标识 BEECRYPT1:）
grep -rn "BeeCount\|beecount\|蜜蜂记账\|蜜蜂記帳" --include="*.dart" --include="*.yaml" --include="*.xml" --include="*.gradle" --include="*.kt" --include="*.swift" --include="*.plist" --include="*.entitlements" --include="*.pbxproj" --include="*.xcconfig" --include="*.arb" . | grep -v "BEECRYPT1" | grep -v ".git/" | grep -v "build/" | grep -v ".dart_tool/"
```

预期：除 `BEECRYPT1:` 外，无任何残留。

## 七、回滚策略

如果某个阶段出现无法修复的问题：

```bash
# 回滚到指定阶段
git log --oneline
git reset --hard <phase-commit-hash>

# 或回滚到起点
git reset --hard pre-piggycount-rename
```

每个 Phase 的 commit message 格式：`rename: phase N - <phase description>`
