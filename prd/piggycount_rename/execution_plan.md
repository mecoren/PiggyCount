# PiggyCount 重命名执行计划

> **For agentic workers:** 本计划按阶段（Phase）划分，每个 Phase 包含多个 Task，每个 Task 包含具体步骤。使用 checkbox (`- [ ]`) 跟踪进度。每个 Phase 完成后必须通过验证才能进入下一阶段。

**Goal:** 将 BeeCount（蜜蜂记账）项目完整重命名为 PiggyCount（小猪记账），覆盖配置、代码、目录、API、文档五个层面。

**Architecture:** 采用从外到内的分阶段策略：先改配置文件（影响构建）→ 再改文件名（影响 import）→ 再改类名（影响引用）→ 最后改文案和文档。每阶段产出独立 git commit，支持回滚。

**Tech Stack:** Flutter 3.27.x / Dart 3.6.x、Android Gradle、iOS Xcode/Xcode project、Kotlin、Swift、Riverpod、Drift、Supabase。

## Global Constraints

- **绝对不可修改** `BEECRYPT1:` 加密格式标识（数据格式版本号，与品牌无关）
- **绝对不可修改** 内部 packages 名（`flutter_cloud_sync`, `flutter_ai_kit` 等）
- **绝对不可修改** 官网域名常量 `https://count.beejz.com`（DNS 由用户单独处理）
- **包标识符**：`com.tntlikely.beecount` → `com.wait.piggycount`（dev: `.dev` 后缀）
- **应用显示名**：简中「小猪记账」、繁中「小豬記帳」、英文「PiggyCount」
- **迁移策略**：直接迁移，不考虑向后兼容
- 每阶段完成后必须通过 `flutter analyze` 和 `flutter test`
- 每阶段产出独立 git commit，commit message 格式：`rename: phase N - <description>`

---

## Phase 0: 准备与备份

### Task 0.1: 创建备份 tag

**Files:**
- N/A（git 操作）

- [ ] **Step 1: 确认当前工作区干净**

Run: `git status`
Expected: "nothing to commit, working tree clean"

- [ ] **Step 2: 创建备份 tag**

Run: `git tag pre-piggycount-rename`
Expected: 无输出（成功）

- [ ] **Step 3: 验证 tag 创建成功**

Run: `git tag -l "pre-piggycount*"`
Expected: `pre-piggycount-rename`

### Task 0.2: 记录当前测试基线

**Files:**
- N/A

- [ ] **Step 1: 运行全量测试，记录基线**

Run: `flutter test`
Expected: 记录通过/失败数量，作为后续验证基线

- [ ] **Step 2: 运行静态分析，记录基线**

Run: `flutter analyze`
Expected: 记录当前 issue 数量

- [ ] **Step 3: 提交 PRD 文档**

Run: `git add prd/piggycount_rename/ && git commit -m "docs: add PiggyCount rename PRD"`
Expected: 提交成功

---

## Phase 1: 配置文件和包标识符（高风险）

> **风险**：R3、R4、R5、R6、R8、R9、R10
> **验证**：本阶段完成后无法通过 `flutter build` 验证（因为代码引用还未更新），仅做静态扫描验证。

### Task 1.1: Flutter pubspec.yaml 改名

**Files:**
- Modify: `pubspec.yaml:1-3`

- [ ] **Step 1: 修改 pubspec.yaml 的 name 和 description**

将 `pubspec.yaml` 第 1-2 行：
```yaml
name: beecount
description: "A new Flutter project."
```
改为：
```yaml
name: piggycount
description: "PiggyCount - A simple personal ledger app."
```

- [ ] **Step 2: 验证修改**

Run: `grep -n "^name:" pubspec.yaml`
Expected: `1:name: piggycount`

### Task 1.2: Android build.gradle 修改

**Files:**
- Modify: `android/app/build.gradle:16,35,51,55,143`

- [ ] **Step 1: 修改 namespace**

将 `android/app/build.gradle` 第 16 行：
```gradle
namespace = "com.tntlikely.beecount"
```
改为：
```gradle
namespace = "com.wait.piggycount"
```

- [ ] **Step 2: 修改 applicationId**

将第 35 行：
```gradle
applicationId = "com.tntlikely.beecount"
```
改为：
```gradle
applicationId = "com.wait.piggycount"
```

- [ ] **Step 3: 修改 dev flavor 的 app_name**

将第 51 行：
```gradle
resValue "string", "app_name", "蜜蜂记账测试版"
```
改为：
```gradle
resValue "string", "app_name", "小猪记账测试版"
```

- [ ] **Step 4: 修改 prod flavor 的 app_name**

将第 55 行：
```gradle
resValue "string", "app_name", "蜜蜂记账"
```
改为：
```gradle
resValue "string", "app_name", "小猪记账"
```

- [ ] **Step 5: 修改 debug buildType 的 app_name**

将第 143 行：
```gradle
resValue "string", "app_name", "蜜蜂记账测试版"
```
改为：
```gradle
resValue "string", "app_name", "小猪记账测试版"
```

- [ ] **Step 6: 验证无残留**

Run: `grep -n "beecount\|蜜蜂记账" android/app/build.gradle`
Expected: 无输出

### Task 1.3: Android AndroidManifest.xml 修改

**Files:**
- Modify: `android/app/src/main/AndroidManifest.xml`

- [ ] **Step 1: 修改 URL scheme**

将第 74 行：
```xml
<data android:scheme="beecount"/>
```
改为：
```xml
<data android:scheme="piggycount"/>
```

- [ ] **Step 2: 修改硬编码的 Widget Provider 类路径**

将第 125 行：
```xml
<receiver android:name="com.tntlikely.beecount.BeeCountWidgetProvider"
```
改为：
```xml
<receiver android:name="com.wait.piggycount.PiggyCountWidgetProvider"
```

- [ ] **Step 3: 修改 widget_info 资源引用**

将第 133 行：
```xml
android:resource="@xml/beecount_widget_info" />
```
改为：
```xml
android:resource="@xml/piggycount_widget_info" />
```

- [ ] **Step 4: 批量修改所有 `.BeeCount*Provider` 引用**

将所有形如：
```xml
android:name=".BeeCountGlanceSmallWidgetProvider"
android:name=".BeeCountNetWorthWidgetProvider"
android:name=".BeeCountQuickAddWidgetProvider"
android:name=".BeeCountBudgetWidgetProvider"
android:name=".BeeCountRecentWidgetProvider"
android:name=".BeeCountNetWorthMediumWidgetProvider"
android:name=".BeeCountNetWorthLargeWidgetProvider"
android:name=".BeeCountBudgetMediumWidgetProvider"
android:name=".BeeCountQuickAddMediumWidgetProvider"
android:name=".BeeCountRecentLargeWidgetProvider"
android:name=".BeeCountDashboardWidgetProvider"
```
批量替换为对应的 `PiggyCount*Provider`。

- [ ] **Step 5: 验证无残留**

Run: `grep -n "beecount\|BeeCount" android/app/src/main/AndroidManifest.xml`
Expected: 无输出

### Task 1.4: Android strings.xml 修改

**Files:**
- Modify: `android/app/src/main/res/values/strings.xml`
- Modify: `android/app/src/main/res/values-en/strings.xml`
- Modify: `android/app/src/main/res/values-zh-rTW/strings.xml`

- [ ] **Step 1: 读取并修改 values/strings.xml**

将所有 `蜜蜂记账` 替换为 `小猪记账`，所有 `BeeCount` 替换为 `PiggyCount`。

- [ ] **Step 2: 读取并修改 values-en/strings.xml**

将所有 `BeeCount` 替换为 `PiggyCount`。

- [ ] **Step 3: 读取并修改 values-zh-rTW/strings.xml**

将所有 `蜜蜂記帳` 替换为 `小豬記帳`。

- [ ] **Step 4: 验证**

Run: `grep -rn "beecount\|BeeCount\|蜜蜂记账\|蜜蜂記帳" android/app/src/main/res/`
Expected: 无输出

### Task 1.5: iOS xcconfig 修改

**Files:**
- Modify: `ios/Flutter/Debug.xcconfig`
- Modify: `ios/Flutter/Release.xcconfig`

- [ ] **Step 1: 修改 Debug.xcconfig**

将内容：
```
APP_DISPLAY_NAME=蜜蜂记账测试版
PRODUCT_BUNDLE_IDENTIFIER=com.tntlikely.beecount.dev
```
改为：
```
APP_DISPLAY_NAME=小猪记账测试版
PRODUCT_BUNDLE_IDENTIFIER=com.wait.piggycount.dev
```

- [ ] **Step 2: 修改 Release.xcconfig**

将内容：
```
APP_DISPLAY_NAME=蜜蜂记账
PRODUCT_BUNDLE_IDENTIFIER=com.tntlikely.beecount
```
改为：
```
APP_DISPLAY_NAME=小猪记账
PRODUCT_BUNDLE_IDENTIFIER=com.wait.piggycount
```

- [ ] **Step 3: 验证**

Run: `grep -n "beecount\|蜜蜂记账" ios/Flutter/*.xcconfig`
Expected: 无输出

### Task 1.6: iOS Info.plist 修改

**Files:**
- Modify: `ios/Runner/Info.plist`

- [ ] **Step 1: 修改 CFBundleURLName**

将第 99 行：
```xml
<string>com.tntlikely.beecount</string>
```
改为：
```xml
<string>com.wait.piggycount</string>
```

- [ ] **Step 2: 修改 CFBundleURLSchemes**

将第 102 行：
```xml
<string>beecount</string>
```
改为：
```xml
<string>piggycount</string>
```

- [ ] **Step 3: 修改 iCloud 容器 key**

将第 109 行：
```xml
<key>iCloud.com.tntlikely.beecount</key>
```
改为：
```xml
<key>iCloud.com.wait.piggycount</key>
```

- [ ] **Step 4: 修改 NSUbiquitousContainerName**

将第 114 行：
```xml
<string>BeeCount</string>
```
改为：
```xml
<string>PiggyCount</string>
```

- [ ] **Step 5: 批量修改隐私描述字符串**

将所有 `蜜蜂记账` 替换为 `小猪记账`（约 5 处：照片库、相机、麦克风、Face ID 描述）。

- [ ] **Step 6: 验证**

Run: `grep -n "beecount\|BeeCount\|蜜蜂记账" ios/Runner/Info.plist`
Expected: 无输出

### Task 1.7: iOS entitlements 修改

**Files:**
- Modify: `ios/Runner/Runner.entitlements`
- Modify: `ios/BeeCountWidgetExtension.entitlements`（稍后重命名）

- [ ] **Step 1: 修改 Runner.entitlements 的 iCloud 容器**

将第 7 行和第 15 行：
```xml
<string>iCloud.com.tntlikely.beecount</string>
```
改为：
```xml
<string>iCloud.com.wait.piggycount</string>
```
（共 2 处）

- [ ] **Step 2: 修改 Runner.entitlements 的 App Group**

将第 19 行：
```xml
<string>group.com.tntlikely.beecount</string>
```
改为：
```xml
<string>group.com.wait.piggycount</string>
```

- [ ] **Step 3: 修改 BeeCountWidgetExtension.entitlements 的 App Group**

将第 7 行：
```xml
<string>group.com.tntlikely.beecount</string>
```
改为：
```xml
<string>group.com.wait.piggycount</string>
```

- [ ] **Step 4: 验证**

Run: `grep -n "beecount" ios/Runner/Runner.entitlements ios/BeeCountWidgetExtension.entitlements`
Expected: 无输出

### Task 1.8: iOS InfoPlist.strings 修改

**Files:**
- Modify: `ios/Runner/en.lproj/InfoPlist.strings`
- Modify: `ios/Runner/zh-Hans.lproj/InfoPlist.strings`
- Modify: `ios/Runner/zh-Hant.lproj/InfoPlist.strings`

- [ ] **Step 1: 修改英文 InfoPlist.strings**

将所有 `BeeCount` 替换为 `PiggyCount`。

- [ ] **Step 2: 修改简体中文 InfoPlist.strings**

将所有 `蜜蜂记账` 替换为 `小猪记账`，`蜜蜂记账测试版` 替换为 `小猪记账测试版`。

- [ ] **Step 3: 修改繁体中文 InfoPlist.strings**

将所有 `蜜蜂記帳` 替换为 `小豬記帳`，`蜜蜂記帳測試版` 替换为 `小豬記帳測試版`。

- [ ] **Step 4: 验证**

Run: `grep -rn "BeeCount\|蜜蜂记账\|蜜蜂記帳" ios/Runner/*.lproj/`
Expected: 无输出

### Task 1.9: iOS project.pbxproj 修改（最高风险）

**Files:**
- Modify: `ios/Runner.xcodeproj/project.pbxproj`

> ⚠️ **警告**：此文件修改错误会导致 Xcode 项目损坏。每步修改后立即 grep 验证。

- [ ] **Step 1: 备份 project.pbxproj**

Run: `cp ios/Runner.xcodeproj/project.pbxproj ios/Runner.xcodeproj/project.pbxproj.bak`

- [ ] **Step 2: 修改 RunnerTests 的 PRODUCT_BUNDLE_IDENTIFIER**

将第 664、682、698 行：
```
PRODUCT_BUNDLE_IDENTIFIER = com.example.beecount.RunnerTests;
```
改为：
```
PRODUCT_BUNDLE_IDENTIFIER = com.example.piggycount.RunnerTests;
```

- [ ] **Step 3: 修改 Widget Extension 的 PRODUCT_BUNDLE_IDENTIFIER**

将第 738 行（dev 配置）：
```
PRODUCT_BUNDLE_IDENTIFIER = com.tntlikely.beecount.dev.BeeCountWidgetExtension;
```
改为：
```
PRODUCT_BUNDLE_IDENTIFIER = com.wait.piggycount.dev.PiggyCountWidgetExtension;
```

将第 781、822 行（prod 配置）：
```
PRODUCT_BUNDLE_IDENTIFIER = com.tntlikely.beecount.BeeCountWidgetExtension;
```
改为：
```
PRODUCT_BUNDLE_IDENTIFIER = com.wait.piggycount.PiggyCountWidgetExtension;
```

- [ ] **Step 4: 修改 INFOPLIST_KEY_CFBundleDisplayName**

将第 726、770、811 行：
```
INFOPLIST_KEY_CFBundleDisplayName = BeeCountWidget;
```
改为：
```
INFOPLIST_KEY_CFBundleDisplayName = PiggyCountWidget;
```

- [ ] **Step 5: 修改 CODE_SIGN_ENTITLEMENTS 路径**

将第 717、761、802 行：
```
CODE_SIGN_ENTITLEMENTS = BeeCountWidgetExtension.entitlements;
```
改为：
```
CODE_SIGN_ENTITLEMENTS = PiggyCountWidgetExtension.entitlements;
```

- [ ] **Step 6: 修改 INFOPLIST_FILE 路径**

将第 725、769、810 行：
```
INFOPLIST_FILE = BeeCountWidget/Info.plist;
```
改为：
```
INFOPLIST_FILE = PiggyCountWidget/Info.plist;
```

- [ ] **Step 7: 修改 target name 和 productName**

将第 288-289 行：
```
name = BeeCountWidgetExtension;
productName = BeeCountWidgetExtension;
```
改为：
```
name = PiggyCountWidgetExtension;
productName = PiggyCountWidgetExtension;
```

- [ ] **Step 8: 修改 Build configuration list 注释**

将第 1007 行：
```
/* Build configuration list for PBXNativeTarget "BeeCountWidgetExtension" */
```
改为：
```
/* Build configuration list for PBXNativeTarget "PiggyCountWidgetExtension" */
```

- [ ] **Step 9: 修改 file reference 路径**

将第 80 行：
```
path = BeeCountWidgetExtension.appex;
```
改为：
```
path = PiggyCountWidgetExtension.appex;
```

将第 84 行：
```
path = BeeCountWidgetExtension.entitlements;
```
改为：
```
path = PiggyCountWidgetExtension.entitlements;
```

- [ ] **Step 10: 修改 group 路径**

将第 128 行：
```
path = BeeCountWidget;
```
改为：
```
path = PiggyCountWidget;
```

- [ ] **Step 11: 修改 remoteInfo**

将第 42 行：
```
remoteInfo = BeeCountWidgetExtension;
```
改为：
```
remoteInfo = PiggyCountWidgetExtension;
```

- [ ] **Step 12: 修改注释中的名称**

将第 109 行：
```
/* Exceptions for "BeeCountWidget" folder in "BeeCountWidgetExtension" target */
```
改为：
```
/* Exceptions for "PiggyCountWidget" folder in "PiggyCountWidgetExtension" target */
```

- [ ] **Step 13: 验证无残留**

Run: `grep -n "beecount\|BeeCount" ios/Runner.xcodeproj/project.pbxproj`
Expected: 无输出

- [ ] **Step 14: 删除备份**

Run: `rm ios/Runner.xcodeproj/project.pbxproj.bak`

### Task 1.10: Phase 1 提交

- [ ] **Step 1: 暂存所有改动**

Run: `git add -A`

- [ ] **Step 2: 提交**

Run: `git commit -m "rename: phase 1 - update config files and package identifiers"`
Expected: 提交成功

---

## Phase 2: 目录和文件重命名（高风险）

> **风险**：R5、R6、R8
> **注意**：本阶段仅做文件系统操作（git mv），不修改文件内容。内容修改在 Phase 3 进行。

### Task 2.1: 重命名 iOS Widget 目录

**Files:**
- Rename: `ios/BeeCountWidget/` → `ios/PiggyCountWidget/`

- [ ] **Step 1: git mv 目录**

Run: `git mv ios/BeeCountWidget ios/PiggyCountWidget`

- [ ] **Step 2: 验证**

Run: `ls ios/PiggyCountWidget/`
Expected: 显示 7 个 .swift 文件 + Info.plist + Assets.xcassets + Previews

### Task 2.2: 重命名 iOS Widget Swift 文件

**Files:**
- Rename: `ios/PiggyCountWidget/BeeCountWidget.swift` → `PiggyCountWidget.swift`
- Rename: `ios/PiggyCountWidget/BeeCountWidgetBundle.swift` → `PiggyCountWidgetBundle.swift`
- Rename: `ios/PiggyCountWidget/BeeCountBudgetWidget.swift` → `PiggyCountBudgetWidget.swift`
- Rename: `ios/PiggyCountWidget/BeeCountDashboardWidget.swift` → `PiggyCountDashboardWidget.swift`
- Rename: `ios/PiggyCountWidget/BeeCountNetWorthWidget.swift` → `PiggyCountNetWorthWidget.swift`
- Rename: `ios/PiggyCountWidget/BeeCountQuickAddWidget.swift` → `PiggyCountQuickAddWidget.swift`
- Rename: `ios/PiggyCountWidget/BeeCountRecentWidget.swift` → `PiggyCountRecentWidget.swift`

- [ ] **Step 1: 逐个 git mv**

Run:
```bash
cd ios/PiggyCountWidget
git mv BeeCountWidget.swift PiggyCountWidget.swift
git mv BeeCountWidgetBundle.swift PiggyCountWidgetBundle.swift
git mv BeeCountBudgetWidget.swift PiggyCountBudgetWidget.swift
git mv BeeCountDashboardWidget.swift PiggyCountDashboardWidget.swift
git mv BeeCountNetWorthWidget.swift PiggyCountNetWorthWidget.swift
git mv BeeCountQuickAddWidget.swift PiggyCountQuickAddWidget.swift
git mv BeeCountRecentWidget.swift PiggyCountRecentWidget.swift
cd ../..
```

- [ ] **Step 2: 验证**

Run: `ls ios/PiggyCountWidget/*.swift`
Expected: 7 个 `PiggyCount*.swift` 文件

### Task 2.3: 重命名 iOS entitlements 文件

**Files:**
- Rename: `ios/BeeCountWidgetExtension.entitlements` → `ios/PiggyCountWidgetExtension.entitlements`

- [ ] **Step 1: git mv**

Run: `git mv ios/BeeCountWidgetExtension.entitlements ios/PiggyCountWidgetExtension.entitlements`

- [ ] **Step 2: 验证**

Run: `ls ios/PiggyCountWidgetExtension.entitlements`
Expected: 文件存在

### Task 2.4: 重命名 Android Kotlin 包目录

**Files:**
- Move: `android/app/src/main/kotlin/com/tntlikely/beecount/*.kt` → `android/app/src/main/kotlin/com/wait/piggycount/`

- [ ] **Step 1: 创建新目录**

Run: `mkdir -p android/app/src/main/kotlin/com/wait/piggycount`

- [ ] **Step 2: git mv 所有 Kotlin 文件**

Run:
```bash
git mv android/app/src/main/kotlin/com/tntlikely/beecount/BeeCountWidgetProvider.kt android/app/src/main/kotlin/com/wait/piggycount/
git mv android/app/src/main/kotlin/com/tntlikely/beecount/BeeCountSizedWidgetProviders.kt android/app/src/main/kotlin/com/wait/piggycount/
git mv android/app/src/main/kotlin/com/tntlikely/beecount/BeeCountRecentWidgetProvider.kt android/app/src/main/kotlin/com/wait/piggycount/
git mv android/app/src/main/kotlin/com/tntlikely/beecount/BeeCountQuickAddWidgetProvider.kt android/app/src/main/kotlin/com/wait/piggycount/
git mv android/app/src/main/kotlin/com/tntlikely/beecount/BeeCountNetWorthWidgetProvider.kt android/app/src/main/kotlin/com/wait/piggycount/
git mv android/app/src/main/kotlin/com/tntlikely/beecount/BeeCountGlanceSmallWidgetProvider.kt android/app/src/main/kotlin/com/wait/piggycount/
git mv android/app/src/main/kotlin/com/tntlikely/beecount/BeeCountDashboardWidgetProvider.kt android/app/src/main/kotlin/com/wait/piggycount/
git mv android/app/src/main/kotlin/com/tntlikely/beecount/BeeCountBudgetWidgetProvider.kt android/app/src/main/kotlin/com/wait/piggycount/
```

- [ ] **Step 3: 重命名 Kotlin 文件名**

Run:
```bash
cd android/app/src/main/kotlin/com/wait/piggycount
git mv BeeCountWidgetProvider.kt PiggyCountWidgetProvider.kt
git mv BeeCountSizedWidgetProviders.kt PiggyCountSizedWidgetProviders.kt
git mv BeeCountRecentWidgetProvider.kt PiggyCountRecentWidgetProvider.kt
git mv BeeCountQuickAddWidgetProvider.kt PiggyCountQuickAddWidgetProvider.kt
git mv BeeCountNetWorthWidgetProvider.kt PiggyCountNetWorthWidgetProvider.kt
git mv BeeCountGlanceSmallWidgetProvider.kt PiggyCountGlanceSmallWidgetProvider.kt
git mv BeeCountDashboardWidgetProvider.kt PiggyCountDashboardWidgetProvider.kt
git mv BeeCountBudgetWidgetProvider.kt PiggyCountBudgetWidgetProvider.kt
cd ../../../../../../../..
```

- [ ] **Step 4: 删除空的旧目录**

Run: `rmdir android/app/src/main/kotlin/com/tntlikely/beecount && rmdir android/app/src/main/kotlin/com/tntlikely`

- [ ] **Step 5: 验证**

Run: `ls android/app/src/main/kotlin/com/wait/piggycount/`
Expected: 8 个 `PiggyCount*.kt` 文件

Run: `ls android/app/src/main/kotlin/com/tntlikely/ 2>&1`
Expected: "No such file or directory"

### Task 2.5: 重命名 Android 资源文件

**Files:**
- Rename: `android/app/src/main/res/xml/beecount_widget_info.xml` → `piggycount_widget_info.xml`
- Rename: `android/app/src/main/res/layout/beecount_widget.xml` → `piggycount_widget.xml`

- [ ] **Step 1: git mv xml 文件**

Run:
```bash
git mv android/app/src/main/res/xml/beecount_widget_info.xml android/app/src/main/res/xml/piggycount_widget_info.xml
git mv android/app/src/main/res/layout/beecount_widget.xml android/app/src/main/res/layout/piggycount_widget.xml
```

- [ ] **Step 2: 验证**

Run: `ls android/app/src/main/res/xml/piggycount_widget_info.xml android/app/src/main/res/layout/piggycount_widget.xml`
Expected: 两个文件都存在

### Task 2.6: 重命名 Dart 文件

**Files:**
- Rename: `lib/widgets/ui/bee_popup_menu.dart` → `lib/widgets/ui/piggy_popup_menu.dart`
- Rename: `lib/widgets/biz/bee_icon.dart` → `lib/widgets/biz/piggy_icon.dart`
- Rename: `lib/pages/cloud/beecount_cloud_sync_page.dart` → `lib/pages/cloud/piggycount_cloud_sync_page.dart`

- [ ] **Step 1: git mv Dart 文件**

Run:
```bash
git mv lib/widgets/ui/bee_popup_menu.dart lib/widgets/ui/piggy_popup_menu.dart
git mv lib/widgets/biz/bee_icon.dart lib/widgets/biz/piggy_icon.dart
git mv lib/pages/cloud/beecount_cloud_sync_page.dart lib/pages/cloud/piggycount_cloud_sync_page.dart
```

- [ ] **Step 2: 验证**

Run: `ls lib/widgets/ui/piggy_popup_menu.dart lib/widgets/biz/piggy_icon.dart lib/pages/cloud/piggycount_cloud_sync_page.dart`
Expected: 三个文件都存在

### Task 2.7: 重命名 packages 内文件

**Files:**
- Rename: `packages/flutter_cloud_sync/lib/src/providers/beecount_cloud_provider.dart` → `piggycount_cloud_provider.dart`

- [ ] **Step 1: git mv**

Run: `git mv packages/flutter_cloud_sync/lib/src/providers/beecount_cloud_provider.dart packages/flutter_cloud_sync/lib/src/providers/piggycount_cloud_provider.dart`

- [ ] **Step 2: 验证**

Run: `ls packages/flutter_cloud_sync/lib/src/providers/piggycount_cloud_provider.dart`
Expected: 文件存在

### Task 2.8: 重命名测试文件

**Files:**
- Rename: `test/cloud/sync/_fakes/fake_beecount_cloud_provider.dart` → `fake_piggycount_cloud_provider.dart`

- [ ] **Step 1: git mv**

Run: `git mv test/cloud/sync/_fakes/fake_beecount_cloud_provider.dart test/cloud/sync/_fakes/fake_piggycount_cloud_provider.dart`

- [ ] **Step 2: 验证**

Run: `ls test/cloud/sync/_fakes/fake_piggycount_cloud_provider.dart`
Expected: 文件存在

### Task 2.9: 重命名资源文件

**Files:**
- Rename: `assets/bee.svg` → `assets/piggy.svg`
- Rename: `assets/images/beeassets_*.png` (6 个) → `assets/images/piggyassets_*.png`
- Rename: `assets/images/beedns_logo.png` → `assets/images/piggydns_logo.png`

- [ ] **Step 1: git mv bee.svg**

Run: `git mv assets/bee.svg assets/piggy.svg`

- [ ] **Step 2: git mv beeassets 文件**

Run:
```bash
git mv assets/images/beeassets_dashboard.png assets/images/piggyassets_dashboard.png
git mv assets/images/beeassets_dashboard_en.png assets/images/piggyassets_dashboard_en.png
git mv assets/images/beeassets_holdings.png assets/images/piggyassets_holdings.png
git mv assets/images/beeassets_holdings_en.png assets/images/piggyassets_holdings_en.png
git mv assets/images/beeassets_logo.png assets/images/piggyassets_logo.png
git mv assets/images/beeassets_logo.svg assets/images/piggyassets_logo.svg
git mv assets/images/beedns_logo.png assets/images/piggydns_logo.png
```

- [ ] **Step 3: 验证**

Run: `ls assets/piggy.svg assets/images/piggyassets_*.png assets/images/piggyassets_*.svg assets/images/piggydns_logo.png`
Expected: 8 个文件都存在

### Task 2.10: Phase 2 提交

- [ ] **Step 1: 暂存**

Run: `git add -A`

- [ ] **Step 2: 提交**

Run: `git commit -m "rename: phase 2 - rename directories and files"`
Expected: 提交成功

---

## Phase 3: Dart 类名和引用更新（最高工作量）

> **风险**：R7、R14、R15
> **策略**：按依赖层级从底到顶修改，每改完一个类立即 `flutter analyze`

### Task 3.1: 更新 tokens.dart 中的 7 个类

**Files:**
- Modify: `lib/styles/tokens.dart`

- [ ] **Step 1: 重命名 BeeTokens → PiggyTokens**

使用 IDE Rename Symbol 或全局替换：
- `class BeeTokens` → `class PiggyTokens`
- 文件内所有 `BeeTokens.` → `PiggyTokens.`

- [ ] **Step 2: 重命名 BeeDimens → PiggyDimens**

- `class BeeDimens` → `class PiggyDimens`
- 文件内所有 `BeeDimens.` → `PiggyDimens.`

- [ ] **Step 3: 重命名 BeeShadows → PiggyShadows**

- `class BeeShadows` → `class PiggyShadows`
- 文件内所有 `BeeShadows.` → `PiggyShadows.`

- [ ] **Step 4: 重命名 BeeDivider → PiggyDivider**

- `class BeeDivider` → `class PiggyDivider`

- [ ] **Step 5: 重命名 BeeChartTokens → PiggyChartTokens**

- `class BeeChartTokens` → `class PiggyChartTokens`

- [ ] **Step 6: 重命名 BeeTextTokens → PiggyTextTokens**

- `class BeeTextTokens` → `class PiggyTextTokens`

- [ ] **Step 7: 重命名 BeeTypography → PiggyTypography**

- `class BeeTypography` → `class PiggyTypography`

- [ ] **Step 8: 验证文件内无残留**

Run: `grep -n "class Bee\|BeeTokens\|BeeDimens\|BeeShadows\|BeeDivider\|BeeChartTokens\|BeeTextTokens\|BeeTypography" lib/styles/tokens.dart`
Expected: 无输出

### Task 3.2: 更新 theme.dart

**Files:**
- Modify: `lib/theme.dart`

- [ ] **Step 1: 重命名 BeeTheme → PiggyTheme**

- `class BeeTheme` → `class PiggyTheme`
- 文件内所有 `BeeTheme.` → `PiggyTheme.`

- [ ] **Step 2: 验证**

Run: `grep -n "BeeTheme" lib/theme.dart`
Expected: 无输出

### Task 3.3: 更新 app.dart

**Files:**
- Modify: `lib/app.dart`

- [ ] **Step 1: 重命名 BeeApp → PiggyApp**

- `class BeeApp` → `class PiggyApp`
- 文件内所有 `BeeApp` → `PiggyApp`

- [ ] **Step 2: 验证**

Run: `grep -n "BeeApp" lib/app.dart`
Expected: 无输出

### Task 3.4: 更新 db.dart

**Files:**
- Modify: `lib/data/db.dart`

- [ ] **Step 1: 重命名 BeeDatabase → PiggyDatabase**

- `class BeeDatabase extends _$BeeDatabase` → `class PiggyDatabase extends _$PiggyDatabase`

> ⚠️ 注意：`_$BeeDatabase` 是 drift 生成的类名，需要同步检查 `lib/data/db.g.dart`

- [ ] **Step 2: 检查 db.g.dart**

Run: `grep -n "BeeDatabase" lib/data/db.g.dart`

如果存在，需要重新生成 drift 代码：
Run: `dart run build_runner build --delete-conflicting-outputs`

- [ ] **Step 3: 验证**

Run: `grep -rn "BeeDatabase" lib/data/`
Expected: 无输出

### Task 3.5: 更新 piggy_popup_menu.dart（原 bee_popup_menu.dart）

**Files:**
- Modify: `lib/widgets/ui/piggy_popup_menu.dart`

- [ ] **Step 1: 重命名 BeeMenuItem → PiggyMenuItem**

- `class BeeMenuItem` → `class PiggyMenuItem`

- [ ] **Step 2: 重命名 BeePopupMenu → PiggyPopupMenu**

- `class BeePopupMenu extends StatelessWidget` → `class PiggyPopupMenu extends StatelessWidget`
- 文件内所有 `BeePopupMenu` → `PiggyPopupMenu`

- [ ] **Step 3: 验证**

Run: `grep -n "BeeMenuItem\|BeePopupMenu" lib/widgets/ui/piggy_popup_menu.dart`
Expected: 无输出

### Task 3.6: 更新 piggy_icon.dart（原 bee_icon.dart）

**Files:**
- Modify: `lib/widgets/biz/piggy_icon.dart`

- [ ] **Step 1: 重命名 BeeIcon → PiggyIcon**

- `class BeeIcon extends StatelessWidget` → `class PiggyIcon extends StatelessWidget`
- 文件内所有 `BeeIcon` → `PiggyIcon`

- [ ] **Step 2: 验证**

Run: `grep -n "BeeIcon" lib/widgets/biz/piggy_icon.dart`
Expected: 无输出

### Task 3.7: 更新 piggycount_cloud_sync_page.dart（原 beecount_cloud_sync_page.dart）

**Files:**
- Modify: `lib/pages/cloud/piggycount_cloud_sync_page.dart`

- [ ] **Step 1: 重命名 BeeCountCloudSyncPage → PiggyCountCloudSyncPage**

- `class BeeCountCloudSyncPage` → `class PiggyCountCloudSyncPage`
- 文件内所有 `BeeCountCloudSyncPage` → `PiggyCountCloudSyncPage`

- [ ] **Step 2: 验证**

Run: `grep -n "BeeCountCloudSyncPage" lib/pages/cloud/piggycount_cloud_sync_page.dart`
Expected: 无输出

### Task 3.8: 更新 config_export_service.dart

**Files:**
- Modify: `lib/services/export/config_export_service.dart`

- [ ] **Step 1: 重命名 BeeCountCloudConfig → PiggyCountCloudConfig**

- `class BeeCountCloudConfig` → `class PiggyCountCloudConfig`
- 文件内所有 `BeeCountCloudConfig` → `PiggyCountCloudConfig`

- [ ] **Step 2: 验证**

Run: `grep -n "BeeCountCloudConfig" lib/services/export/config_export_service.dart`
Expected: 无输出

### Task 3.9: 更新 piggycount_cloud_provider.dart（packages 内）

**Files:**
- Modify: `packages/flutter_cloud_sync/lib/src/providers/piggycount_cloud_provider.dart`

- [ ] **Step 1: 重命名 BeeCountCloudProvider → PiggyCountCloudProvider**

- `class BeeCountCloudProvider` → `class PiggyCountCloudProvider`
- 文件内所有 `BeeCountCloudProvider` → `PiggyCountCloudProvider`

- [ ] **Step 2: 验证**

Run: `grep -n "BeeCountCloudProvider" packages/flutter_cloud_sync/lib/src/providers/piggycount_cloud_provider.dart`
Expected: 无输出

### Task 3.10: 更新 fake_piggycount_cloud_provider.dart（测试文件）

**Files:**
- Modify: `test/cloud/sync/_fakes/fake_piggycount_cloud_provider.dart`

- [ ] **Step 1: 重命名 FakeBeeCountCloudProvider → FakePiggyCountCloudProvider**

- 文件内所有 `FakeBeeCountCloudProvider` → `FakePiggyCountCloudProvider`（或类似的 fake 类名）

- [ ] **Step 2: 验证**

Run: `grep -n "BeeCount" test/cloud/sync/_fakes/fake_piggycount_cloud_provider.dart`
Expected: 无输出（除 `BEECRYPT1:` 外）

### Task 3.11: 批量更新所有 Dart 文件中的引用

> 这是工作量最大的一步。需要更新所有 import 语句、类引用、字符串常量。

**Files:**
- Modify: `lib/**/*.dart`（约 100+ 文件）
- Modify: `test/**/*.dart`（约 20+ 文件）
- Modify: `packages/**/*.dart`

- [ ] **Step 1: 更新所有 import 路径**

将所有：
- `import 'package:beecount/...` → `import 'package:piggycount/...`
- `import 'bee_popup_menu.dart'` → `import 'piggy_popup_menu.dart'`
- `import 'bee_icon.dart'` → `import 'piggy_icon.dart'`
- `import 'beecount_cloud_sync_page.dart'` → `import 'piggycount_cloud_sync_page.dart'`
- `import 'beecount_cloud_provider.dart'` → `import 'piggycount_cloud_provider.dart'`
- `import 'fake_beecount_cloud_provider.dart'` → `import 'fake_piggycount_cloud_provider.dart'`

使用全局搜索替换。在 VS Code 中可使用 `Search and Replace in Files`（Ctrl+Shift+H）。

- [ ] **Step 2: 更新所有类引用**

使用 IDE 的 Rename Symbol 功能逐个更新（或全局替换）：
- `BeeApp` → `PiggyApp`
- `BeeTheme` → `PiggyTheme`
- `BeeTokens` → `PiggyTokens`
- `BeeDimens` → `PiggyDimens`
- `BeeShadows` → `PiggyShadows`
- `BeeDivider` → `PiggyDivider`
- `BeeChartTokens` → `PiggyChartTokens`
- `BeeTextTokens` → `PiggyTextTokens`
- `BeeTypography` → `PiggyTypography`
- `BeeDatabase` → `PiggyDatabase`
- `BeeMenuItem` → `PiggyMenuItem`
- `BeePopupMenu` → `PiggyPopupMenu`
- `BeeIcon` → `PiggyIcon`
- `BeeCountCloudConfig` → `PiggyCountCloudConfig`
- `BeeCountCloudSyncPage` → `PiggyCountCloudSyncPage`
- `BeeCountCloudProvider` → `PiggyCountCloudProvider`

- [ ] **Step 3: 更新所有字符串常量**

将所有 Dart 代码中的字符串：
- `'BeeCount'` → `'PiggyCount'`
- `"BeeCount"` → `"PiggyCount"`
- `'BeeCount Cloud'` → `'PiggyCount Cloud'`
- `'蜜蜂记账'` → `'小猪记账'`
- `'蜜蜂記帳'` → `'小豬記帳'`

- [ ] **Step 4: 更新 ciphertext_format.dart 注释**

将 `lib/data/encryption/ciphertext_format.dart` 中的注释：
- 第 3 行 `/// BeeCount 同步加密的密文格式` → `/// PiggyCount 同步加密的密文格式`

> ⚠️ **绝对不可修改** 第 15 行的 `static const String magicHeader = 'BEECRYPT1:';`

- [ ] **Step 5: 更新 website_urls.dart 注释**

将 `lib/utils/website_urls.dart` 中的注释：
- `BeeCount-Website` → `PiggyCount-Website`（注释中）
- `beecount-cloud` → `piggycount-cloud`（文档路径中）

> ⚠️ **保持不变**：`baseUrl = 'https://count.beejz.com'`

- [ ] **Step 6: 更新 Kotlin 文件内容**

修改 `android/app/src/main/kotlin/com/wait/piggycount/` 下所有 8 个 .kt 文件：
- `package com.tntlikely.beecount` → `package com.wait.piggycount`
- `class BeeCountWidgetProvider` → `class PiggyCountWidgetProvider`
- 其他 7 个类名同步重命名

- [ ] **Step 7: 更新 Swift 文件内容**

修改 `ios/PiggyCountWidget/` 下所有 7 个 .swift 文件：
- `struct BeeCountWidget` → `struct PiggyCountWidget`
- `@main struct BeeCountWidgetBundle` → `@main struct PiggyCountWidgetBundle`
- 其他 5 个 Widget struct 名同步重命名

- [ ] **Step 8: 更新 app_link_service.dart 中的 URL scheme**

检查 `lib/services/platform/app_link_service.dart`：
- `'beecount://'` → `'piggycount://'`
- `'beecount'` → `'piggycount'`

- [ ] **Step 9: 运行 flutter analyze**

Run: `flutter analyze`
Expected: 无新增错误（已有的 850 个无关警告可保持）

- [ ] **Step 10: 运行 flutter test**

Run: `flutter test`
Expected: 全部通过（除可能因 URL scheme 改名导致的少量断言失败需修复）

- [ ] **Step 11: 重新生成 drift 代码（如需要）**

Run: `dart run build_runner build --delete-conflicting-outputs`
Expected: 成功生成

- [ ] **Step 12: 重新生成本地化**

Run: `flutter gen-l10n`
Expected: 成功生成

### Task 3.12: 更新 pubspec.yaml 中的 assets 声明

**Files:**
- Modify: `pubspec.yaml`

- [ ] **Step 1: 查找所有 bee 资源引用**

Run: `grep -n "bee" pubspec.yaml`

- [ ] **Step 2: 更新 assets 路径**

将：
- `assets/bee.svg` → `assets/piggy.svg`
- `assets/images/beeassets_dashboard.png` → `assets/images/piggyassets_dashboard.png`
- `assets/images/beeassets_dashboard_en.png` → `assets/images/piggyassets_dashboard_en.png`
- `assets/images/beeassets_holdings.png` → `assets/images/piggyassets_holdings.png`
- `assets/images/beeassets_holdings_en.png` → `assets/images/piggyassets_holdings_en.png`
- `assets/images/beeassets_logo.png` → `assets/images/piggyassets_logo.png`
- `assets/images/beeassets_logo.svg` → `assets/images/piggyassets_logo.svg`
- `assets/images/beedns_logo.png` → `assets/images/piggydns_logo.png`

- [ ] **Step 3: 验证**

Run: `grep -in "bee" pubspec.yaml`
Expected: 无输出（或仅在注释中）

### Task 3.13: Phase 3 提交

- [ ] **Step 1: 暂存**

Run: `git add -A`

- [ ] **Step 2: 提交**

Run: `git commit -m "rename: phase 3 - update Dart class names and references"`
Expected: 提交成功

---

## Phase 4: 字符串资源和本地化（中风险）

> **风险**：R12、R13

### Task 4.1: 更新 .arb 本地化文件

**Files:**
- Modify: `lib/l10n/app_en.arb`
- Modify: `lib/l10n/app_zh.arb`
- Modify: `lib/l10n/app_zh_TW.arb`
- Modify: `lib/l10n/app_ko.arb`

- [ ] **Step 1: 更新 app_en.arb**

将所有 `"BeeCount"` 替换为 `"PiggyCount"`，`"BeeCount Cloud"` 替换为 `"PiggyCount Cloud"`。

- [ ] **Step 2: 更新 app_zh.arb**

将所有 `"蜜蜂记账"` 替换为 `"小猪记账"`。

- [ ] **Step 3: 更新 app_zh_TW.arb**

将所有 `"蜜蜂記帳"` 替换为 `"小豬記帳"`。

- [ ] **Step 4: 更新 app_ko.arb**

检查并更新韩语中的 BeeCount 引用（如有）。

- [ ] **Step 5: 重新生成本地化代码**

Run: `flutter gen-l10n`

- [ ] **Step 6: 验证**

Run: `grep -l "BeeCount\|蜜蜂记账\|蜜蜂記帳" lib/l10n/*.arb`
Expected: 无输出

### Task 4.2: Phase 4 提交

- [ ] **Step 1: 暂存**

Run: `git add -A`

- [ ] **Step 2: 提交**

Run: `git commit -m "rename: phase 4 - update localization strings"`
Expected: 提交成功

---

## Phase 5: 文档和 README（低风险）

> **风险**：R17、R18、R19、R20、R21

### Task 5.1: 批量更新根目录文档

**Files:**
- Modify: `README.md`, `README_EN.md`, `CONTRIBUTING.md`, `COMMERCIAL_LICENSE.md`, `PRIVACY.md`, `LICENSE`, `LICENSE_EN`, `THIRD-PARTY-NOTICES.md`

- [ ] **Step 1: 批量替换**

对每个文件执行：
- `BeeCount` → `PiggyCount`
- `beecount` → `piggycount`
- `蜜蜂记账` → `小猪记账`
- `蜜蜂記帳` → `小豬記帳`
- `com.tntlikely.beecount` → `com.wait.piggycount`
- `BeeCount Cloud` → `PiggyCount Cloud`

- [ ] **Step 2: 验证**

Run: `grep -l "BeeCount\|beecount\|蜜蜂记账\|蜜蜂記帳" README.md README_EN.md CONTRIBUTING.md COMMERCIAL_LICENSE.md PRIVACY.md LICENSE LICENSE_EN THIRD-PARTY-NOTICES.md`
Expected: 无输出

### Task 5.2: 批量更新 docoments/ 目录

**Files:**
- Modify: `docoments/*.md`（17 个文件）

- [ ] **Step 1: 批量替换**

对 `docoments/` 目录下所有 .md 文件执行同 Step 5.1 的替换。

- [ ] **Step 2: 验证**

Run: `grep -rl "BeeCount\|beecount\|蜜蜂记账\|蜜蜂記帳" docoments/`
Expected: 无输出

### Task 5.3: 批量更新 docs/ 目录

**Files:**
- Modify: `docs/**/*.md`

- [ ] **Step 1: 批量替换**

对 `docs/` 目录下所有 .md 文件执行同 Step 5.1 的替换。

- [ ] **Step 2: 验证**

Run: `grep -rl "BeeCount\|beecount\|蜜蜂记账\|蜜蜂記帳" docs/`
Expected: 无输出

### Task 5.4: 更新 .github/ 目录

**Files:**
- Modify: `.github/**/*.yml`, `.github/**/*.md`

- [ ] **Step 1: 批量替换**

对 `.github/` 目录下所有文件执行同 Step 5.1 的替换。

- [ ] **Step 2: 验证**

Run: `grep -rl "BeeCount\|beecount\|蜜蜂记账\|蜜蜂記帳" .github/`
Expected: 无输出

### Task 5.5: 更新 .vscode/ 和其他配置文件

**Files:**
- Modify: `.vscode/launch.json`
- Modify: `.workbuddy/memory/MEMORY.md`
- Modify: `assets/header_skins/README.md`, `assets/header_skins/README_EN.md`
- Modify: `scripts/**/*.md`, `scripts/**/*.dart`, `scripts/**/*.py`
- Modify: `demo/**/*.py`, `demo/**/*.html`, `demo/**/*.yaml`

- [ ] **Step 1: 批量替换**

对上述所有文件执行同 Step 5.1 的替换。

- [ ] **Step 2: 验证**

Run: `grep -rl "BeeCount\|beecount\|蜜蜂记账\|蜜蜂記帳" .vscode/ .workbuddy/ assets/header_skins/ scripts/ demo/`
Expected: 无输出

### Task 5.6: 更新 packages 文档

**Files:**
- Modify: `packages/*/README.md`, `packages/*/CHANGELOG.md`, `packages/*/LICENSE`, `packages/*/PROJECT_SUMMARY.md`, `packages/*/USAGE_GUIDE.md`

- [ ] **Step 1: 批量替换**

对 `packages/` 目录下所有文档文件执行同 Step 5.1 的替换。

- [ ] **Step 2: 验证**

Run: `grep -rl "BeeCount\|beecount\|蜜蜂记账" packages/ --include="*.md" --include="*.txt"`
Expected: 无输出

### Task 5.7: Phase 5 提交

- [ ] **Step 1: 暂存**

Run: `git add -A`

- [ ] **Step 2: 提交**

Run: `git commit -m "rename: phase 5 - update documentation and README"`
Expected: 提交成功

---

## Phase 6: 验证和清理

### Task 6.1: 全量残留扫描

- [ ] **Step 1: Dart 文件扫描**

Run: `grep -rn "BeeCount\|beecount\|蜜蜂记账\|蜜蜂記帳" --include="*.dart" lib/ test/ packages/ | grep -v "BEECRYPT1"`
Expected: 无输出

- [ ] **Step 2: Android 文件扫描**

Run: `grep -rn "BeeCount\|beecount\|蜜蜂记账\|蜜蜂記帳" --include="*.xml" --include="*.gradle" --include="*.kt" --include="*.properties" android/`
Expected: 无输出

- [ ] **Step 3: iOS 文件扫描**

Run: `grep -rn "BeeCount\|beecount\|蜜蜂记账\|蜜蜂記帳" --include="*.swift" --include="*.plist" --include="*.entitlements" --include="*.pbxproj" --include="*.xcconfig" --include="*.strings" ios/`
Expected: 无输出

- [ ] **Step 4: 配置文件扫描**

Run: `grep -rn "BeeCount\|beecount\|蜜蜂记账\|蜜蜂記帳" --include="*.yaml" --include="*.yml" --include="*.json" --include="*.arb" . | grep -v ".git/" | grep -v "build/" | grep -v ".dart_tool/"`
Expected: 无输出（除 `BEECRYPT1:` 相关）

- [ ] **Step 5: 文档扫描**

Run: `grep -rn "BeeCount\|beecount\|蜜蜂记账\|蜜蜂記帳" --include="*.md" . | grep -v ".git/" | grep -v "prd/piggycount_rename/"`
Expected: 无输出

- [ ] **Step 6: 文件名扫描**

Run（PowerShell）:
```powershell
Get-ChildItem -Path . -Recurse -File | Where-Object { $_.Name -match "beecount|BeeCount" -and $_.FullName -notmatch "\\.git\\|\\build\\|\\.dart_tool\\" } | Select-Object FullName
```
Expected: 无输出

### Task 6.2: 清理并重新构建

- [ ] **Step 1: Flutter clean**

Run: `flutter clean`
Expected: 成功

- [ ] **Step 2: 重新获取依赖**

Run: `flutter pub get`
Expected: 成功

- [ ] **Step 3: 重新生成代码**

Run: `dart run build_runner build --delete-conflicting-outputs`
Expected: 成功

- [ ] **Step 4: 重新生成本地化**

Run: `flutter gen-l10n`
Expected: 成功

### Task 6.3: 全量分析

- [ ] **Step 1: flutter analyze**

Run: `flutter analyze`
Expected: 无新增错误

### Task 6.4: 全量测试

- [ ] **Step 1: flutter test**

Run: `flutter test`
Expected: 全部通过

### Task 6.5: Android 构建验证

- [ ] **Step 1: 构建 dev debug APK**

Run: `flutter build apk --flavor dev --debug`
Expected: 成功

- [ ] **Step 2: 构建 prod release APK**

Run: `flutter build apk --flavor prod --release`
Expected: 成功

- [ ] **Step 3: 构建 prod release AAB**

Run: `flutter build appbundle --flavor prod --release`
Expected: 成功

### Task 6.6: 最终提交

- [ ] **Step 1: 暂存**

Run: `git add -A`

- [ ] **Step 2: 提交**

Run: `git commit -m "rename: phase 6 - final verification and cleanup"`
Expected: 提交成功

- [ ] **Step 3: 创建完成 tag**

Run: `git tag piggycount-rename-complete`

---

## 附录：手动前置操作清单（需用户在开发者门户完成）

> ⚠️ 以下操作无法通过代码完成，必须在执行 Phase 1 之前由用户手动操作。

### A.1 Apple Developer Portal

- [ ] 创建新 App Group: `group.com.wait.piggycount`
- [ ] 创建新 iCloud Container: `iCloud.com.wait.piggycount`
- [ ] 创建新 App ID: `com.wait.piggycount`（启用 iCloud、App Group、CloudKit 能力）
- [ ] 创建新 App ID: `com.wait.piggycount.dev`（同上）
- [ ] 创建新 App ID: `com.wait.piggycount.PiggyCountWidgetExtension`（启用 App Group）
- [ ] 创建新 App ID: `com.wait.piggycount.dev.PiggyCountWidgetExtension`（启用 App Group）
- [ ] 为上述 App ID 创建 Provisioning Profile
- [ ] 下载并安装新的 Provisioning Profile

### A.2 Google Play Console

- [ ] 创建新应用条目：包名 `com.wait.piggycount`
- [ ] 配置应用信息（名称：小猪记账 / PiggyCount）

### A.3 App Store Connect

- [ ] 创建新应用记录：Bundle ID `com.wait.piggycount`
- [ ] 配置应用名称：小猪记账 / PiggyCount

### A.4 DNS 配置（可选，由用户决定时机）

- [ ] 配置 `count.beejz.com` 域名解析指向新服务器（或保持现状）

---

## 执行顺序总结

```
Phase 0 (准备) → Phase 1 (配置) → Phase 2 (文件改名) → Phase 3 (代码引用) → Phase 4 (本地化) → Phase 5 (文档) → Phase 6 (验证)
     ↓               ↓                 ↓                   ↓                   ↓                ↓               ↓
   备份 tag      配置文件修改       git mv 文件        类名+引用更新       .arb 文件       .md 文件       全量回归
                                                                                    ↓
                                                                              用户手动操作（A.1-A.4）
                                                                              必须在 Phase 1 前完成
```

## 风险等级与回滚点

| Phase | 风险等级 | 主要风险 | 回滚方法 |
| --- | --- | --- | --- |
| Phase 0 | 🟢 低 | 无 | N/A |
| Phase 1 | 🔴 高 | R3, R4, R5, R6, R8, R9, R10 | `git reset --hard pre-piggycount-rename` |
| Phase 2 | 🟠 中高 | R5, R6, R8 | `git reset --hard HEAD~1` |
| Phase 3 | 🟠 中高 | R7, R14, R15 | `git reset --hard HEAD~1` |
| Phase 4 | 🟡 中 | R12, R13 | `git reset --hard HEAD~1` |
| Phase 5 | 🟢 低 | R17-R21 | `git reset --hard HEAD~1` |
| Phase 6 | 🟢 低 | R22 | `git reset --hard HEAD~1` |
