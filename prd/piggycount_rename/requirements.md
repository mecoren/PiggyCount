# PiggyCount 重命名需求文档

## 一、项目背景

当前项目名为 **BeeCount**（中文：蜜蜂记账），需要彻底重命名为 **PiggyCount**（中文：小猪记账）。

- **当前状态**：项目中有 200 个文件、2628 处引用包含 "BeeCount" 字符串
- **目标状态**：所有用户可见的 "BeeCount" / "蜜蜂记账" 替换为 "PiggyCount" / "小猪记账"，所有内部代码标识符同步重命名
- **迁移策略**：直接迁移，不考虑向后兼容（用户已确认）

## 二、范围决策（用户已确认）

### 2.1 重命名范围：完整范围

包含以下所有层面：

| 层面 | 当前 | 目标 |
| --- | --- | --- |
| Dart 类名 | `BeeApp`, `BeeTheme`, `BeeTokens`, `BeeDimens`, `BeeShadows`, `BeeDivider`, `BeeChartTokens`, `BeeTextTokens`, `BeeTypography`, `BeeDatabase`, `BeeMenuItem`, `BeePopupMenu`, `BeeIcon`, `BeeCountCloudConfig`, `BeeCountCloudSyncPage` | `PiggyApp`, `PiggyTheme`, `PiggyTokens`, ... `PiggyCountCloudSyncPage` |
| 文件名 | `bee_icon.dart`, `bee_popup_menu.dart`, `beecount_cloud_sync_page.dart`, `beecount_widget_info.xml`, `beecount_widget.xml` | `piggy_icon.dart`, `piggy_popup_menu.dart`, `piggycount_cloud_sync_page.dart`, `piggycount_widget_info.xml`, `piggycount_widget.xml` |
| 包标识符 | `com.tntlikely.beecount` | `com.wait.piggycount` |
| iOS dev 包 | `com.tntlikely.beecount.dev` | `com.wait.piggycount.dev` |
| App Group | `group.com.tntlikely.beecount` | `group.com.wait.piggycount` |
| iCloud 容器 | `iCloud.com.tntlikely.beecount` | `iCloud.com.wait.piggycount` |
| iOS Widget Extension | `BeeCountWidgetExtension` | `PiggyCountWidgetExtension` |
| iOS Widget 目录 | `ios/BeeCountWidget/` | `ios/PiggyCountWidget/` |
| Kotlin 包路径 | `android/app/src/main/kotlin/com/tntlikely/beecount/` | `android/app/src/main/kotlin/com/wait/piggycount/` |
| Kotlin 类名 | `BeeCountWidgetProvider`, `BeeCountSizedWidgetProviders`, `BeeCountRecentWidgetProvider`, `BeeCountQuickAddWidgetProvider`, `BeeCountNetWorthWidgetProvider`, `BeeCountGlanceSmallWidgetProvider`, `BeeCountDashboardWidgetProvider`, `BeeCountBudgetWidgetProvider` | `PiggyCountWidgetProvider`, ... |
| URL Scheme | `beecount://` | `piggycount://` |
| 应用显示名（简中） | 蜜蜂记账 | 小猪记账 |
| 应用显示名（繁中） | 蜜蜂記帳 | 小豬記帳 |
| 应用显示名（英文） | BeeCount | PiggyCount |
| 云服务品牌 | BeeCount Cloud | PiggyCount Cloud |

### 2.2 不变项（明确排除）

以下内容**必须保持不变**，原因如下：

| 不变项 | 原因 |
| --- | --- |
| 加密密文格式标识 `BEECRYPT1:` | 这是数据格式版本标识（magic header），用于自动识别密文/明文。已写入云端历史数据，改名会导致所有已加密数据无法解密 |
| 内部 packages 目录名（`flutter_cloud_sync`, `flutter_ai_kit` 等） | 这些是通用工具包名，不含 "beecount" 字符串，无需改名 |
| 官网域名 `count.beejz.com` | App 代码中保留此常量，DNS 迁移由用户单独处理（参见 `lib/utils/website_urls.dart`） |
| Git 仓库历史 | 不重写 git 历史，仅做前向改名提交 |
| 第三方依赖包名（如 `supabase_flutter`, `home_widget`） | 这些是 pub.dev 包名，不可改名 |

### 2.3 需要决策的开放项

| 开放项 | 默认方案 | 备注 |
| --- | --- | --- |
| 资源文件 `assets/bee.svg`, `assets/images/beeassets_*.png`, `assets/images/beedns_logo.png` | 改名为 `piggy.svg`, `piggyassets_*.png`, `piggydns_logo.png` | 同时更新代码中的引用路径 |
| `flutter_cloud_sync` 包内文件 `beecount_cloud_provider.dart` | 改名为 `piggycount_cloud_provider.dart` | 类名 `BeeCountCloudProvider` → `PiggyCountCloudProvider` |
| 测试文件 `test/cloud/sync/_fakes/fake_beecount_cloud_provider.dart` | 改名为 `fake_piggycount_cloud_provider.dart` | 类名同步改 |
| Supabase 数据库中的 schema/表名 | 暂不改 | 由后端团队单独处理，App 代码中表名通过 Supabase 客户端配置 |
| `README.md`, `README_EN.md`, `CONTRIBUTING.md`, `LICENSE` 等文档 | 全部同步更新 | 包含品牌名、仓库链接等 |

## 三、功能需求

### FR-1：项目配置文件改名

**描述**：修改所有项目级配置文件中的项目名称和包标识符。

**涉及文件**：
- `pubspec.yaml`（`name: beecount` → `name: piggycount`，描述字段）
- `android/app/build.gradle`（namespace, applicationId, resValue app_name）
- `android/app/src/main/AndroidManifest.xml`（package 内的类引用、URL scheme）
- `android/app/src/debug/AndroidManifest.xml`
- `android/app/src/profile/AndroidManifest.xml`
- `ios/Flutter/Debug.xcconfig`（APP_DISPLAY_NAME, PRODUCT_BUNDLE_IDENTIFIER）
- `ios/Flutter/Release.xcconfig`
- `ios/Runner.xcodeproj/project.pbxproj`（PRODUCT_BUNDLE_IDENTIFIER, target name, file references）
- `ios/Runner/Info.plist`（CFBundleURLName, CFBundleURLSchemes, NSUbiquitousContainers）
- `ios/Runner/Runner.entitlements`（iCloud container, App Group）
- `ios/BeeCountWidgetExtension.entitlements`（重命名文件 + 修改内容）
- `ios/Runner/en.lproj/InfoPlist.strings`
- `ios/Runner/zh-Hans.lproj/InfoPlist.strings`
- `ios/Runner/zh-Hant.lproj/InfoPlist.strings`
- `.metadata`（如果包含项目名）
- `analysis_options.yaml`（如果包含项目名）
- `l10n.yaml`

### FR-2：源代码中所有引用旧项目名的更新

**描述**：更新所有 Dart 源代码中的导入路径、命名空间、常量字符串。

**主要工作**：
1. 重命名 15 个 `Bee*` 前缀的 Dart 类为 `Piggy*`
2. 更新所有 import 语句（约 200+ 处）
3. 更新所有类引用（约 2628 处）
4. 更新字符串常量（如 `'BeeCount'`, `'BeeCount Cloud'` 等）
5. 重命名 `bee*` 前缀的文件为 `piggy*`

**关键文件**：
- `lib/main.dart`, `lib/app.dart`, `lib/theme.dart`, `lib/styles/tokens.dart`
- `lib/data/db.dart`（`BeeDatabase` 类）
- `lib/data/encryption/ciphertext_format.dart`（注释中 "BeeCount" → "PiggyCount"，但 `BEECRYPT1:` 保持不变）
- `lib/widgets/ui/bee_popup_menu.dart` → `lib/widgets/ui/piggy_popup_menu.dart`
- `lib/widgets/biz/bee_icon.dart` → `lib/widgets/biz/piggy_icon.dart`
- `lib/pages/cloud/beecount_cloud_sync_page.dart` → `lib/pages/cloud/piggycount_cloud_sync_page.dart`
- `lib/services/export/config_export_service.dart`（`BeeCountCloudConfig` 类）
- `lib/utils/website_urls.dart`（注释中的 "BeeCount-Website" 引用）
- `lib/l10n/app_en.arb`, `app_zh.arb`, `app_zh_TW.arb`, `app_ko.arb`（本地化字符串）
- `packages/flutter_cloud_sync/lib/src/providers/beecount_cloud_provider.dart` → `piggycount_cloud_provider.dart`

### FR-3：目录和文件的重命名

**描述**：重命名所有包含 "beecount" 或 "BeeCount" 的目录和文件。

**目录重命名清单**：
1. `ios/BeeCountWidget/` → `ios/PiggyCountWidget/`
2. `android/app/src/main/kotlin/com/tntlikely/beecount/` → `android/app/src/main/kotlin/com/wait/piggycount/`

**文件重命名清单**（部分关键文件）：
- `ios/BeeCountWidget/BeeCountWidget.swift` → `ios/PiggyCountWidget/PiggyCountWidget.swift`
- `ios/BeeCountWidget/BeeCountWidgetBundle.swift` → `ios/PiggyCountWidget/PiggyCountWidgetBundle.swift`
- `ios/BeeCountWidget/BeeCountBudgetWidget.swift` → `ios/PiggyCountWidget/PiggyCountBudgetWidget.swift`
- `ios/BeeCountWidget/BeeCountDashboardWidget.swift` → `ios/PiggyCountWidget/PiggyCountDashboardWidget.swift`
- `ios/BeeCountWidget/BeeCountNetWorthWidget.swift` → `ios/PiggyCountWidget/PiggyCountNetWorthWidget.swift`
- `ios/BeeCountWidget/BeeCountQuickAddWidget.swift` → `ios/PiggyCountWidget/PiggyCountQuickAddWidget.swift`
- `ios/BeeCountWidget/BeeCountRecentWidget.swift` → `ios/PiggyCountWidget/PiggyCountRecentWidget.swift`
- `ios/BeeCountWidgetExtension.entitlements` → `ios/PiggyCountWidgetExtension.entitlements`
- `android/app/src/main/kotlin/com/tntlikely/beecount/BeeCountWidgetProvider.kt` → `android/app/src/main/kotlin/com/wait/piggycount/PiggyCountWidgetProvider.kt`
- `android/app/src/main/kotlin/com/tntlikely/beecount/BeeCountSizedWidgetProviders.kt` → `.../PiggyCountSizedWidgetProviders.kt`
- `android/app/src/main/kotlin/com/tntlikely/beecount/BeeCountRecentWidgetProvider.kt` → `.../PiggyCountRecentWidgetProvider.kt`
- `android/app/src/main/kotlin/com/tntlikely/beecount/BeeCountQuickAddWidgetProvider.kt` → `.../PiggyCountQuickAddWidgetProvider.kt`
- `android/app/src/main/kotlin/com/tntlikely/beecount/BeeCountNetWorthWidgetProvider.kt` → `.../PiggyCountNetWorthWidgetProvider.kt`
- `android/app/src/main/kotlin/com/tntlikely/beecount/BeeCountGlanceSmallWidgetProvider.kt` → `.../PiggyCountGlanceSmallWidgetProvider.kt`
- `android/app/src/main/kotlin/com/tntlikely/beecount/BeeCountDashboardWidgetProvider.kt` → `.../PiggyCountDashboardWidgetProvider.kt`
- `android/app/src/main/kotlin/com/tntlikely/beecount/BeeCountBudgetWidgetProvider.kt` → `.../PiggyCountBudgetWidgetProvider.kt`
- `android/app/src/main/res/xml/beecount_widget_info.xml` → `piggycount_widget_info.xml`
- `android/app/src/main/res/layout/beecount_widget.xml` → `piggycount_widget.xml`
- `assets/bee.svg` → `assets/piggy.svg`
- `assets/images/beeassets_*.png` → `assets/images/piggyassets_*.png`（共 6 个文件）
- `assets/images/beedns_logo.png` → `assets/images/piggydns_logo.png`
- `lib/widgets/ui/bee_popup_menu.dart` → `lib/widgets/ui/piggy_popup_menu.dart`
- `lib/widgets/biz/bee_icon.dart` → `lib/widgets/biz/piggy_icon.dart`
- `lib/pages/cloud/beecount_cloud_sync_page.dart` → `lib/pages/cloud/piggycount_cloud_sync_page.dart`
- `packages/flutter_cloud_sync/lib/src/providers/beecount_cloud_provider.dart` → `piggycount_cloud_provider.dart`
- `test/cloud/sync/_fakes/fake_beecount_cloud_provider.dart` → `fake_piggycount_cloud_provider.dart`

### FR-4：数据库和 API 端点

**描述**：处理涉及项目名称的数据库和 API 配置。

**关键点**：
- **Supabase**：项目 URL 和 anon key 通过运行时配置注入（参见 `lib/providers/sync_providers.dart`），表名是通用的（`transactions`, `ledgers` 等），**不含 "beecount" 字符串**，无需改名
- **iCloud 容器**：必须从 `iCloud.com.tntlikely.beecount` 改为 `iCloud.com.wait.piggycount`，需要在 Apple Developer Portal 创建新容器
- **App Group**：必须从 `group.com.tntlikely.beecount` 改为 `group.com.wait.piggycount`，影响 iOS Widget 与主 App 的数据共享
- **BeeCount Cloud API**：App 代码中通过 `beecount_cloud_provider.dart` 调用，端点 URL 来自 `lib/utils/website_urls.dart` 的 `count.beejz.com`，DNS 由用户单独迁移
- **URL Scheme**：`beecount://` 改为 `piggycount://`，影响深链处理（参见 `lib/services/platform/app_link_service.dart`）

### FR-5：文档和 README 同步更新

**描述**：更新所有文档中的项目名称。

**涉及文档**：
- 根目录：`README.md`, `README_EN.md`, `CONTRIBUTING.md`, `COMMERCIAL_LICENSE.md`, `PRIVACY.md`, `LICENSE`, `LICENSE_EN`, `THIRD-PARTY-NOTICES.md`
- `docoments/` 目录下 17 个文档（`01-project-overview.md` 等）
- `docs/` 目录下文档（`cloud-setup.md`, `contributing/`, `donate/`, `design/`）
- `packages/*/README.md`, `CHANGELOG.md`
- `.github/` 目录（ISSUE_TEMPLATE, workflows, FUNDING.yml）
- `.vscode/launch.json`
- `assets/header_skins/README.md`, `assets/header_skins/README_EN.md`

## 四、风险分析（按风险等级排序）

### 🔴 风险等级 P0（极高，可能导致数据丢失或应用无法启动）

| 风险 | 影响 | 缓解措施 |
| --- | --- | --- |
| **R1：iCloud 容器改名导致云端数据丢失** | 现有 iCloud 用户的云端同步数据将无法访问（旧容器名硬编码在 entitlements） | 由于用户已确认"直接迁移，不考虑兼容"，仅需在 Apple Developer Portal 创建新容器 `iCloud.com.wait.piggycount`，旧数据无法迁移（iCloud 不支持容器改名） |
| **R2：App Group 改名导致 iOS Widget 与主 App 数据共享断裂** | Widget 无法读取主 App 数据，桌面小组件失效 | 创建新 App Group `group.com.wait.piggycount`，并在 entitlements 中同步更新。已发布用户需重新安装 |
| **R3：Android applicationId 改名导致已发布用户无法升级** | Android 视为新应用，旧版本无法覆盖升级，用户数据丢失 | 用户已确认"直接迁移，不考虑兼容"。建议在 README 和公告中说明，并提供数据导出/导入工具帮助用户迁移 |
| **R4：iOS Bundle ID 改名导致 App Store 视为新应用** | 无法作为已有应用的更新发布，需作为新应用重新提交审核 | 用户已确认接受。需创建新的 App Store Connect 记录 |

### 🟠 风险等级 P1（高，可能导致构建失败）

| 风险 | 影响 | 缓解措施 |
| --- | --- | --- |
| **R5：iOS `project.pbxproj` 文件引用错误** | Xcode 无法找到文件，构建失败。该文件包含 40+ 处 `BeeCount` 引用（file references, target names, build configs） | 必须谨慎修改 `project.pbxproj`，每个 file reference 的 path 和 sourceTree 必须一致。建议在 Xcode 中通过 IDE 操作而非手动编辑 |
| **R6：Kotlin 包路径与 namespace 不一致** | Android 编译失败，找不到 `MainActivity` 等类 | 必须同步移动 Kotlin 文件到新目录 `com/wait/piggycount/`，并更新文件内的 `package` 声明 |
| **R7：Dart 类名重命名后 import 未同步更新** | 编译失败，"Undefined name 'BeeApp'" 等错误 | 使用 IDE 全局重构（Rename Symbol）而非手动改，配合 `flutter analyze` 验证 |
| **R8：iOS Widget Extension target 重命名后 entitlements 路径错误** | 构建签名失败 | 同步更新 `project.pbxproj` 中的 `CODE_SIGN_ENTITLEMENTS` 路径和文件名 |
| **R9：资源文件改名后 pubspec.yaml 的 assets 声明未更新** | 运行时资源加载失败，图标/图片显示空白 | 同步更新 `pubspec.yaml` 中所有 `assets/` 路径声明 |
| **R10：Android Manifest 中硬编码的类路径未更新** | 桌面小组件无法注册，运行时崩溃 | 更新所有 `android:name="com.tntlikely.beecount.BeeCount*Provider"` 为 `com.wait.piggycount.PiggyCount*Provider` |

### 🟡 风险等级 P2（中，可能导致运行时错误或功能异常）

| 风险 | 影响 | 缓解措施 |
| --- | --- | --- |
| **R11：URL Scheme 改名导致深链失效** | 已分享的 `beecount://` 链接无法打开应用 | 同步更新 AndroidManifest.xml 和 iOS Info.plist 中的 scheme 为 `piggycount://`。旧链接无法兼容（用户已确认） |
| **R12：本地化字符串（.arb 文件）遗漏更新** | 部分界面仍显示 "BeeCount" 或 "蜜蜂记账" | 通过 grep 二次扫描所有 `.arb` 文件，确保 4 种语言（en/zh/zh_TW/ko）全部更新 |
| **R13：iOS InfoPlist.strings 遗漏更新** | 桌面图标显示旧名称 | 检查 `en.lproj`, `zh-Hans.lproj`, `zh-Hant.lproj` 三个目录的 strings 文件 |
| **R14：测试文件中的类名引用未同步** | 单元测试编译失败或断言失败 | 同步更新 `test/` 目录下所有测试文件。已有 200+ 处引用需更新 |
| **R15：加密格式 `BEECRYPT1:` 误改** | 所有已加密云端数据无法解密，数据永久丢失 | **明确排除**：在执行计划中标注此常量不可修改。该标识是数据格式版本号，与品牌名无关 |
| **R16：iOS Podfile/Podfile.lock 中的包标识符未更新** | CocoaPods 集成异常 | 检查 `ios/Podfile` 和重新执行 `pod install` |

### 🟢 风险等级 P3（低，影响文档或非关键资源）

| 风险 | 影响 | 缓解措施 |
| --- | --- | --- |
| **R17：文档中项目名遗漏更新** | 文档与实际不一致，用户困惑 | 通过 grep 二次扫描所有 `.md` 文件 |
| **R18：GitHub Issue 模板中的项目名未更新** | 用户提交 issue 时显示旧名称 | 更新 `.github/ISSUE_TEMPLATE/*.yml` |
| **R19：CI/CD 工作流中的项目名未更新** | GitHub Actions 构建脚本中可能引用旧名称 | 检查 `.github/workflows/*.yml` |
| **R20：demo 脚本和示例数据中的项目名未更新** | 演示数据中的项目名过时 | 更新 `demo/` 目录下的 yaml 和 py 文件 |
| **R21：`.vscode/launch.json` 中的项目名未更新** | VS Code 启动配置显示旧名称 | 更新 launch.json 中的 name 字段 |
| **R22：缓存失效** | `.dart_tool/`, `build/` 等缓存目录包含旧名称 | 执行 `flutter clean` 清理缓存后重新构建 |

## 五、验收标准

### AC-1：构建验证
- [ ] `flutter clean` 后 `flutter pub get` 成功
- [ ] `flutter analyze` 无新增错误（已有的 850 个无关警告保持不变）
- [ ] `flutter build apk --flavor prod --release` 成功
- [ ] `flutter build ios --flavor prod --release` 成功（需 macOS 环境）
- [ ] `flutter build appbundle --flavor prod --release` 成功

### AC-2：测试验证
- [ ] `flutter test` 全部通过（当前有 124+ 加密测试，全部需通过）
- [ ] 无任何测试文件中残留 `Bee*` 类名引用

### AC-3：代码扫描验证
- [ ] `grep -r "BeeCount" --include="*.dart"` 在 `lib/`, `test/`, `packages/` 下返回 0 结果（排除 `BEECRYPT1:`）
- [ ] `grep -r "蜜蜂记账" --include="*.dart"` 在 `lib/` 下返回 0 结果
- [ ] `grep -r "beecount" --include="*.xml" --include="*.gradle" --include="*.kt"` 在 `android/` 下返回 0 结果
- [ ] `grep -r "beecount" --include="*.swift" --include="*.plist" --include="*.entitlements" --include="*.pbxproj"` 在 `ios/` 下返回 0 结果

### AC-4：运行时验证
- [ ] 应用在 Android 设备上启动，桌面图标显示"小猪记账"
- [ ] 应用在 iOS 设备上启动，桌面图标显示"小猪记账"
- [ ] iOS 桌面小组件能正常添加并显示数据（验证 App Group 配置正确）
- [ ] `piggycount://` 深链能正常打开应用
- [ ] iCloud 同步功能正常（需新容器已创建）

### AC-5：文档验证
- [ ] 所有 `.md` 文档中无残留 "BeeCount" 或 "蜜蜂记账"（除 git 历史和迁移说明外）
- [ ] README.md 中项目名、链接、描述全部更新

## 六、依赖与前置条件

1. **Apple Developer Portal 操作**：需手动创建新的 App Group `group.com.wait.piggycount` 和 iCloud 容器 `iCloud.com.wait.piggycount`，并更新 signing capabilities
2. **Google Play Console**：需创建新的应用条目（com.wait.piggycount）
3. **App Store Connect**：需创建新的应用条目
4. **DNS 配置**：`count.beejz.com` 域名解析由用户单独处理
5. **备份**：执行前需 `git commit` 当前状态，并打 tag `pre-piggycount-rename` 以便回滚

## 七、非功能性需求

- **可回滚性**：每个阶段产出独立的 git commit，便于定位问题和回滚
- **可验证性**：每个阶段完成后必须能通过 `flutter analyze` 和 `flutter test`
- **完整性**：不允许部分改名后提交（如 Dart 类名改了但 import 没改会导致编译失败）
- **可追溯性**：执行计划中每个步骤都有明确的验证方法
