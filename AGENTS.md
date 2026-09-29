# AGENTS.md

> 本文件是本项目 AI 编码工具的**单一真相源**。其它工具入口若存在，只应引用本文件，不要重复维护规则。

PiggyCount（小猪记账）是开源、隐私可控、**离线优先**的个人记账 / 支出追踪 App。业务数据全部落在本地 SQLite（Drift），云端同步由用户自备（Supabase / WebDAV / S3 / iCloud），开发者不接触用户数据；无广告、无追踪、无埋点。目标平台 Android 5.0+（minSdk 23）与 iOS 15.5+，另含 Android / iOS 桌面小组件。许可证为 BSL 商业源代码许可证（个人 / 学习 / 开源贡献免费，商用需授权）。

## 快速原则

- **中文工作**：对话、commit message、文档、代码注释全部中文。commit 格式 `type(scope): 中文描述`，多批工作常在末尾附日期，如 `fix(sync): 同步一致性 D-1~D-4 修复 + 契约穷举守门测试（2026-09-27）`。
- **Flutter 版本单一来源**：只改 `pubspec.yaml` 的 `environment.flutter`（当前 `3.44.3`），CI 用 `flutter-version-file: pubspec.yaml` 读取。**禁止**在 `.github/workflows/*.yml` 里另写版本号——历史上 `release.yml` 停留 3.27.3 而 `pubspec.lock` 已要求 >=3.44.0，漂移会让下一次打 tag 发版直接失败。
- **应用版本单一来源**：真值在 `pubspec.yaml#version`（当前 `0.7.8`）；`release.yml` 在打 tag 时用 tag 名 `sed` 覆盖（`version: <tag>+<build>`），不要手工两处维护。
- **分层不可破**：UI 只碰 Provider；Provider 注入 Service / Repository；Service 只调 Repository；Repository 是数据库唯一入口。跨层调用一律 review 拒绝。
- **写操作必须经 Repository**：任何改库操作都要走 Repository，由其内部经 `ChangeTracker`（`lib/cloud/sync/change_tracker.dart`）写入 `local_changes`。**绕过 Repository 直接写 DB 是严重 bug**——本地变更不会进 `local_changes`，云端同步静默丢数据。
- **`ChangeTracker` 作用域契约**：调用方只用两个强类型入口——user-global 实体（account / category / tag / exchange_rate_override）走 `recordUserGlobalChange`（自动挂 `ledgerId = 0`），ledger-scoped 实体（transaction / budget / ledger / ledger_snapshot）走 `recordLedgerChange`（必须传 `> 0` 的具体账本 id）。**不要调私有的 `recordChange`**。作用域记错会让变更卡在本地永不推送。云→本地合并路径（apply / restore）必须用 `withRecordingSuppressed` 包裹，否则云端数据会回流成幻影变更。
- **同步是整账本快照（Path A）**：`lib/cloud/sync_service.dart` 定义 `SyncService` 抽象接口，`TransactionsSyncManager`（`lib/cloud/transactions_sync_manager.dart`）是主实现——导出整本账本 JSON 快照上传，拉取走下载 + 恢复 / 合并（`SyncDiffService` 出 diff 预览，`sync_fingerprint.dart` 出内容指纹）。本地内容变化用 `SyncService.markLocalChanged(ledgerId)` 失效缓存；后台自动上传用 `uploadCurrentLedgerDebounced`（2s 窗口收敛，手动 / 合并回传用立即语义的 `uploadCurrentLedger`）。**旧的增量引擎（Path B / `SyncEngine`）已整体下线**——代码里 `sync_engine.*` 之类的注释属历史残留，别按它找文件。Repository 不调用 SyncService，由 UI / Provider 经接口触发。
- **上传禁止盲覆盖**：上传前用 `UploadProbe` 探测方向，冲突抛 `CloudConflictException`（`cloudNewer` / `unknown`），交 UI 让用户确认后再以 `force: true` 重试。恢复临界区由 `SyncRestoreGuard` 把守，`bypassRestoreGuard: true` **只允许恢复/合并已提交后的收尾回传**，用户主动上传入口绝不可传。
- **同步契约有穷举守门测试**：`test/cloud/sync_contract_coverage_test.dart` 校验「指纹白名单 ↔ diff 覆盖字段」逐一对应。相关测试变红通常意味着「某字段进了指纹却没进 diff」或「检测到了却应用不下去」——**不要直接改测试来通过**，先定位真实缺口。
- **改 schema 必须升版本 + 幂等迁移**：`lib/data/db.dart` 的 `schemaVersion`（当前 **48**）递增，`MigrationStrategy` 追加迁移块；迁移必须幂等、可重入。**禁止删除字段**（老用户数据会丢），必须废弃时加 `_deprecated_` 前缀保留。
- **改 Drift 表 / `@JsonSerializable` / `@freezed` 后必跑 build_runner**：`dart run build_runner build --delete-conflicting-outputs`；`*.g.dart` / `*.freezed.dart` **必须提交**，不要加 `.gitignore`。
- **UI 强制走 Design Token**：颜色 / 间距 / 圆角 / 字体全部取 `lib/styles/tokens.dart` 的 `PiggyTokens` / `PiggyDimens` / `PiggyTextTokens` / `PiggyChartTokens` / `PiggyPosterTokens`。直接用 `Colors.white` / `Colors.black` / `Colors.grey.shadeXXX` 在暗黑模式下会出错。
- **文案禁硬编码**：所有面向用户的文案进 `lib/l10n/app_*.arb`，UI 用 `AppLocalizations.of(context)!.key` 引用。缺英文（`app_en.arb`，模板文件）会直接显示 key。
- **零告警门禁**：CI 用 `flutter analyze --fatal-infos`（基线 0 error / 0 warning / 0 info，2026-09-18 起）。本地提交前必须 `flutter analyze` 干净。
- **`packages/` 子包不得反向引用 `lib/`**：子包要能独立复用；`lib/` 可引用子包。
- **尊重并发会话**：同一仓库常有并行会话 WIP；收尾核对改动的归属，不回滚非本批改动。

## 技术栈

| 维度 | 选型 |
| --- | --- |
| 框架 | Flutter 3.44.3（stable）+ Dart SDK `^3.6.0`，`flutter_lints ^5.0.0` |
| 状态与 DI | Riverpod 2.5（`flutter_riverpod`）——唯一状态管理方案，同时承担 DI |
| 本地数据库 | Drift 2.20 ORM + `sqlite3_flutter_libs` / `sqlite3`（`PiggyDatabase`，schemaVersion 48） |
| 路由 | Navigator 1.0（`MaterialPageRoute` + `Navigator.push`），**不用** go_router / auto_route |
| 云同步（自研） | `packages/flutter_cloud_sync`（核心）+ 各 provider 子包：`_supabase` / `_webdav` / `_s3` / `_icloud` |
| AI（自研） | `packages/flutter_ai_kit`（6 种执行策略）+ `_zhipu`（GLM-4 / glm-4v-flash）+ `_openai` |
| 加密 | E2EE = AES-256-GCM + Argon2id（`cryptography`，纯 Dart）；密钥存 `flutter_secure_storage`（iOS Keychain / Android Keystore） |
| 网络 | `dio`（OTA 更新 / 汇率 / AI 调用等复杂 HTTP）+ `http`（轻量场景），自建云后端各用其 provider 子包的客户端 |
| UI / 媒体 | Material 3、`fl_chart` 图表、`table_calendar`、`reorderable_grid_view`、`webview_flutter`、`flutter_svg` / `jovial_svg`、`image_picker` + `flutter_image_compress` + `image_cropper` |
| 平台集成 | `home_widget`（桌面小组件）、`flutter_local_notifications` + `timezone`、`quick_actions`、`local_auth`（应用锁）、`app_links`（`piggycount://`）、`permission_handler`、`in_app_purchase` |
| 导入导出 | `csv`、`excel`、`yaml`、`file_picker`、`archive`、`gbk_codec`（支付宝 / 微信账单） |
| 测试 | `flutter_test` + `mocktail`（不用 mockito，避免 codegen）+ Drift `NativeDatabase.memory()` |
| CI | GitHub Actions：`analyze.yml`（analyze 0-issue 门 + test 同步契约门）、`release.yml`（tag 触发多平台构建发布） |

**版本约束注意**：`dependency_overrides` 钉死 `record_platform_interface: 1.2.0`（修 record_linux 兼容）与 `image_cropper_platform_interface: 7.1.0`（7.2.0 要求 Flutter >= 3.27.6）；`hooks.user_defines.sqlite3.source: system` 让 sqlite3 运行时动态查找，**不要删**——否则构建期会去 GitHub 下载预编译 libsqlite3 而在国内网络失败。`flutter_launcher_icons.ios: false`，iOS 图标手工维护（0.14.x 会重写 `Contents.json`）。

## 架构边界

**五层架构 + 同步旁路**（分层见下；`docoments/04-system-architecture.md` 的同步部分为历史文档，以代码为准）

```text
UI (pages / widgets)
  └─> Provider (Riverpod)
        ├─> Service (业务编排)
        │     └─> Repository (数据访问唯一入口)
        └─> Repository
              └─> Data (Drift / SQLite)
```

| 层 | 位置 | 允许 | 禁止 |
| --- | --- | --- | --- |
| UI | `lib/pages/`、`lib/widgets/` | Provider | 直接访问 Repository / DB / CloudProvider |
| Provider | `lib/providers/`（`all_providers.dart` barrel 导出） | Service、Repository、其他 Provider | 直接访问 DB |
| Service | `lib/services/<module>/` | Repository、其他 Service | 直接访问 DB、Provider |
| Repository | `lib/data/repositories/` | Drift、其他 Repository | Provider、UI、SyncService |
| Data | `lib/data/db.dart` | SQLite | 任何上层 |

- **Repository 三层结构**：抽象接口（`lib/data/repositories/<name>_repository.dart`，无 `I` 前缀）→ 本地实现（`lib/data/repositories/local/local_<name>_repository.dart`）→ 聚合委托（`local_repository.dart` 继承 `BaseRepository`，持 12 个子 Repository：account / ai / attachment / budget / category / custom_field / exchange_rate / ledger / recurring_transaction / statistics / tag / transaction，注入 `ChangeTracker` 与多币种折算等横切逻辑）。
- **多后端抽象**：`CloudProvider` 接口在 `packages/flutter_cloud_sync/lib/src/core/cloud_provider.dart`；`createCloudServices`（`lib/cloud/provider_factory.dart`）按 `CloudServiceConfig` 装配 Supabase / WebDAV / iCloud / S3 四种后端。**PiggyCount Cloud 协议已随云端协同整体下线**（`docoments/` 中相关章节为历史文档）。所有后端统一走快照语义，`lib/cloud/transactions_sync_manager.dart` 是唯一编排入口。
- **写路径**：`Repository → Drift 写入 → ChangeTracker 记 local_changes →（内容代际回调失效指纹缓存）→ 用户 / 后台触发 `SyncService.uploadCurrentLedger(Debounced)` → CloudProvider`。ID 用本地 `id`（int 自增）+ 跨设备 `syncId`（UUID 字符串，各表唯一索引）。
- **同步编排与守卫**：`lib/cloud/` 下 `sync_service.dart`（接口 + `SyncStatus` + 冲突模型）、`transactions_sync_manager.dart`（主实现）、`sync_diff_service.dart`（对比 / 预览 / 应用）、`sync_fingerprint.dart`（指纹，与 diff 字段一一对应）、`transactions_json.dart`（快照序列化）、`sync_restore_guard.dart`（恢复临界区）、`sync_metrics_service.dart`（本地成功率指标）、`startup_sync_checker.dart` + `startup_sync_overlay.dart`（启动检查状态机）、`backend_identity.dart`（后端标识文案）、`gzip_cloud_storage.dart`（传输压缩）；`sync/change_tracker.dart` 记变更；`backup/` 是全量备份（`cloud_backup_service.dart` / `backup_scheduler.dart`）。**修改 push / pull / diff / 指纹逻辑必须补对应单测**，不得移除 `SyncRestoreGuard`、ETag 条件写、去重缓存等既有防线。

## 目录约定

```text
lib/
  ai/                    # AI 集成层（providers / core / privacy）
  cloud/
    sync_service.dart    # SyncService 接口 + SyncStatus + CloudConflictException / UploadProbe
    transactions_sync_manager.dart  # 快照同步主实现（导出/上传/下载/恢复/合并）
    sync_diff_service.dart          # 对比预览与应用（SyncChange / SyncPreview）
    sync_fingerprint.dart           # 内容指纹（与 diff 字段一一对应，契约守门）
    transactions_json.dart          # 账本快照序列化
    sync_restore_guard.dart / sync_metrics_service.dart / backend_identity.dart / gzip_cloud_storage.dart
    startup_sync_checker.dart / startup_sync_overlay.dart / provider_factory.dart
    sync/change_tracker.dart        # 变更登记（user-global ledgerId=0 / ledger-scoped）
    backup/                        # 云端全量备份与恢复、备份调度
  data/
    db.dart              # PiggyDatabase（Drift 表定义 + MigrationStrategy，schemaVersion=48）
    db.g.dart            # codegen 产物（提交）
    repositories/        # 抽象接口 + local/ 本地实现 + local_repository.dart 聚合
    encryption/          # AES-GCM / Argon2 / 密文格式 / 加密云 provider 与存储 / 安全密钥存储
    models/              # 数据模型
    database_health_service.dart   # 只读连接 PRAGMA quick_check 探测损坏
  domain/encryption/     # E2EE 领域服务与设置（encryption_service.dart / encryption_settings.dart）
  l10n/                  # app_zh.arb（官方）+ app_zh_TW.arb + app_en.arb（模板）+ app_ko.arb（社区）
  models/                # 业务模型
  pages/<module>/        # 业务页面（account/ai/attachment/auth/automation/budget/calendar/category/
                         #   cloud/currency/data/donation/main/maintenance/report/settings/tag/transaction）
                         #   页面专用子组件放 pages/<module>/widgets/<page>_<purpose>.dart
  providers/             # Riverpod provider，all_providers.dart 汇总导出
  services/<module>/     # 业务服务（ai/automation/billing/currency/data/export/import/maintenance/
                         #   marketing/payment/platform/security/system/ui/update）
  styles/
    tokens.dart          # PiggyTokens / PiggyDimens / PiggyChartTokens / PiggyPosterTokens / PiggyTextTokens
    header_skins.dart    # 顶部皮肤注册表 + 各 *_skin.dart（CustomPainter / SVG）
  utils/                 # 工具函数（含 platform_info.dart 的 PlatformFeature）
  widget/                # 桌面小组件逻辑
  widgets/               # 通用组件库（ai/analytics/biz/category/charts/currency/posters/ui）
  app.dart               # 应用根 Widget     main.dart # 入口     theme.dart # 主题
packages/                # 8 个本地 path 子包（flutter_ai_kit[_openai|_zhipu]、flutter_cloud_sync[_supabase|_webdav|_s3|_icloud]）
prd/<snake_case_id>/     # 需求与设计文档：requirements.md（验收依据）+ design.md（技术决策与取舍）
docoments/               # 01-17 工程文档（注意目录名就是 docoments）+ INDEX.md
docs/                    # 审计报告 / 优化计划 / 贡献指南（contributing/）/ 设计 token（design/）/ 证据（evidence/）
test/                    # 镜像 lib/ 结构（ai/backup/cloud/data/encryption/maintenance/pages/providers/
                         #   repositories/services/styles/utils/widget/widgets）
```

**文件归属**：业务页面 `lib/pages/<module>/`；通用组件 `lib/widgets/biz/` 或 `lib/widgets/ui/`；Provider `lib/providers/`；业务服务 `lib/services/<module>/`；工具 `lib/utils/`；主题相关 `lib/styles/`。单文件 ≤ 500 行，`build()` ≤ 100 行，超出即拆。

## 常用命令

```bash
# 依赖与代码生成
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # 改 db.dart / freezed / JsonSerializable 后必跑
dart run build_runner watch                                # 开发期监听

# 质量门禁（提交/PR 前本机跑通同等检查）
dart format .                        # 必须无修改
flutter analyze                      # CI 用 `flutter analyze --fatal-infos`（0 issue 门禁）
flutter test                         # 全量测试

# 运行与构建
flutter run --flavor dev             # dev 是默认 flavor
flutter build apk --flavor prod --release
flutter build appbundle --flavor prod --release            # AAB（release.yml 产物）
dart run flutter_launcher_icons      # 生成 Android 图标（iOS 图标手工维护）
flutter gen-l10n                     # 改 .arb 后重新生成本地化类

# 图标素材（scripts/）
python scripts/gen_icons_from_image.py    # 从源图抠图产出 legacy / adaptive / monochrome
python scripts/gen_adaptive_icons.py
python scripts/gen_ios_icons.py
```

- **Windows 本地跑测试的坑**：依赖 `NativeDatabase.memory()`（drift FFI）的用例需要 `sqlite3.dll` 在 PATH 上（CI 的 ubuntu-latest 自带 libsqlite3）。本地先把 DLL 目录加进 PATH 再 `flutter test`（如 `$env:PATH="D:\DevTools\sqlite3-bin;$env:PATH"`）；纯 mock 用例不需要。**不要**给 `flutter_cloud_sync_s3` 子包加 `meta` 依赖——会引发解析冲突导致 `flutter pub get` 静默失败。
- **CI**（`.github/workflows/analyze.yml`）两个 job：`analyze`（`flutter analyze --fatal-infos`）+ `test`（`flutter test`，承担同步契约结构性回归门禁：`test/cloud/sync_contract_coverage_test.dart`、`sync_diff_category_and_zero_amount_test.dart`、`restore_preserves_local_only_columns_test.dart`）。issue-lint / pullfrog 为辅助检查。
- **发版**：`.github/workflows/release.yml` 由 tag 触发（多平台构建 + GitHub Release，tag 名写入 `pubspec.yaml#version` 作为版本真值）；`workflow_dispatch` 手动触发**仅允许从 `wait` 分支**。当前开发主线分支为 `wait`。

## 数据模型与迁移

- **表名复数、字段 camelCase**；主键 `id`（int 自增）+ `syncId`（UUID，跨设备标识，唯一索引）。外键用 `references()`，但 SQLite 默认未启用外键约束。
- **迁移在 `lib/data/db.dart` 的 `MigrationStrategy`**：新增表 / 字段必须升 `schemaVersion` 并追加迁移块，用 `CREATE ... IF NOT EXISTS` 等保证幂等；破坏性变更走重建表。新增索引需评估读写比（高频：`syncId`、`(ledger_id, happened_at)`、`category_id` / `account_id`）。**跨表迁移操作（如 `_updatedAtTouchTables` 建 `updated_at` 触发器）前必须先查 `sqlite_master` 确认表存在**，跳过后续版本才建的表，由对应建表迁移块补齐——否则老用户升级路径上 `CREATE TRIGGER` 作用于不存在的表会让迁移崩溃、App 打不开。
- **查询必须参数化**：用 `Variable<T>` 绑定，**禁止**字符串拼接 SQL。批量写入用 `db.transaction(() async { ... })`。响应式 UI 用 `watch()` 返回 Stream。
- **测试注入内存库**：`PiggyDatabase.forTesting(NativeDatabase.memory())`（跳过文件系统 / 平台副作用）。
- 当前版本演进要点：v44 回收站 `deleted_transactions`（软删搬行）、v45 `transactions.original_amount`、v46 账本自定义字段 `custom_field_definitions` + `transactions.custom_values_json`、v47 周期模板注入 `recurring_transactions.template_field_values`、v48 索引修复型迁移。历史 migrations 明细见 `docoments/07-data-model.md`（该文档版本较旧，以 `db.dart` 为准）。

## UI / 前端约定

- **Design Token 单源**（`lib/styles/tokens.dart`）：`PiggyTokens.scaffoldBackground/surface/surfaceSecondary/textPrimary/textSecondary/divider/success|warning|error|info(context)`；`PiggyDimens.p8/p12/p16`、圆角语义档 `radiusXs(4)/radiusSm(8)/radiusMd(10)/radiusLg(12)/radiusXl(16)/radius2xl(20)/radius3xl(24)`（`radius12/radius16` 为别名）；`PiggyTextTokens.title/body/label(context)`。无 `BuildContext` 的场景（`CustomPainter`、主题定义）用静态常量（仅亮色值，暗黑必须走带 context 的方法）。
- **不允许裸魔法值**：布局尺寸 / 颜色 / 圆角 / 字体一律取 token；新 Token 加进 `tokens.dart` 而不是散落页面。
- **主题色驱动页面背景**：亮色 Scaffold 背景不是写死的常量——由 `PiggyTheme.deriveLightScaffoldBackground(primary)` 从主题色派生同色系淡色（HSL 明度 0.95），`PiggyTokens.scaffoldBackground(context)` 直接读 `Theme.scaffoldBackgroundColor`，换主题色后背景 / AppBar / Tab 栏自动跟随。`PiggyTheme.lightTheme/darkTheme` 必传 `primary`。**已删除的旧常量禁止再引用**：`scaffoldBackgroundLightStatic`、`honeyGold` / `hiveBrown` / `energyOrange` / `paperIvory`。
- **输入型 / 确认型交互走底部抽屉**：项目近一轮 UI 统一为底部抽屉口径（见 `prd/ui_bottom_drawer/`）；新增选择 / 确认交互沿用既有抽屉组件，不要新造 `AlertDialog` 列表。
- **弹窗外壳统一 `AppDialogShell`**：`AppDialog` 纯文本 API 表达不了的自定义内容弹窗（表单 / 选择器等）才用共用外壳 `AppDialogShell`（`lib/widgets/ui/dialog.dart`）；确认 / 通知一律走 `AppDialog` API（见下），禁止手写 `showDialog + AlertDialog/AppDialogShell + Outlined/Filled` 双按钮，禁止手写 `backgroundColor: PiggyTokens.surfaceElevated(context)` + `shape: RoundedRectangleBorder(radiusXl)` 这类逐处复制的样板。
- **确认 / 通知弹窗统一 iOS 警示框**：一律调 `AppDialog.confirm/info/error/warning`。外观：270 宽窄卡片（`PiggyDimens.alertWidth`）+ 标题 `titleLarge w600` 居中 + 说明 `bodySmall` + `textSecondary` 居中（`\\n` 转义由外壳统一处理，arb 里写真换行）+ 底部 iOS 分栏（横竖 1px 中性 hairline，不用 `divider()`，后者暗黑泛主题色；取消正文色｜确认主题 primary；单按钮通知为单个全宽确认钮；说明超长时内部滚动，按钮常驻可见）。
- **删除类确认标 `destructive: true`**：确认侧 error 色 + 动词文案（`okLabel: commonDelete`）。不可逆删除（删账本含云端备份）走 `showDoubleDangerConfirmDialog`（双重 + 倒计时 + 点外部/返回键不可关），保持 friction，**不得降级为单确认**。
- **表单类弹窗不套窄卡片**：含输入框 / 导航行的（如账本编辑框）内容区保持宽卡片，底部按钮用共用 `PiggyDialogActions`（取消｜确认分栏，确认默认 primary）与确认框同一语言。按钮文字颜色必须显式写进 `Text.style`（`bodyLarge` 自带 onSurface 默认色会盖掉按钮 `foregroundColor`）。
- **输入框统一 `piggyFilledDecoration`**：一律调共用装饰（`lib/widgets/ui/piggy_input.dart`，经 `widgets/ui/ui.dart` 导出）——底色 `surfaceInput` + 圆角 `radiusLg` + 待机无边框 + 聚焦主题色 1.5 + 错误 error 色。禁止裸 `InputDecoration` 下划线，也禁止各页自拼 filled 样式（账户编辑页等旧手写处逐步收敛到它）。
- **底部抽屉操作按钮统一双等宽大按钮**：底部一行两个等宽按钮——左侧取消（`OutlinedButton`）+ 右侧确认/保存（`FilledButton`），高 48（`PiggySheetActions.kHeight`），一律用共用组件 `PiggySheetActions`（`lib/widgets/ui/sheet_actions.dart`，经 `widgets/ui/ui.dart` 导出）。例外：云服务三配置表单（Supabase/WebDAV/S3）经用户确认改用 `PiggyDialogActions` iOS 分栏（取消｜保存）与弹窗统一。不要在各抽屉手写右对齐小按钮；抽屉内容含 `TextField` 等 Material 系组件时，外壳必须显式包 `Material`（transparent 路由底不提供 Material 祖先，缺失直接红屏）。
- **单选列表抽屉的选项行规范**（基准实现 `appearance_settings_page.dart` 的 `_showLanguageSheet`）：选项行视觉对齐 `SettingsNavItem`——裸前置标识（图标或原生字符，**不用背景盒**，统一占 24px 槽位居中，保证各选项标题起点同一条竖线）+ 标题 `bodyMedium w500` + 内边距 16/14 + 标识后 12 间距；**高亮只给选中项**：选中项前置标识 / 标题 / 尾部 check 用主色（标题加粗 w600），未选中项一律中性色（`iconSecondary` / `textPrimary`），不要全列表都上主色；语言类选项的前置标识用它自己的**原生字符**（中 / 繁 / EN / 한），不要拿同一个 globe 图标冒充所有语言；单选抽屉选中即应用并收起，不加确认按钮。抽屉内容必须包 `SingleChildScrollView` 兜底——系统大字号 / 应用显示缩放下选项列表可能超出弹层高度（实测溢出 19px），可滚动而不是溢出红条。
- **i18n**：新文案先写 `app_zh.arb`，再补 `app_en.arb`（模板，必填）；`flutter gen-l10n`（或 `flutter pub get`）重新生成本地化类。key 用 camelCase + 模块前缀（`budget_` / `transaction_` …）+ 动作后缀（`_title` / `_desc` / `_btn` / `_hint`）。
- **性能**：长列表用 `flutter_list_view`（支持精准 `jumpToIndex`）而非 `ListView.builder`；列表项 key 用 `ValueKey(item.id)`（**不要拼 index**）；长列表 item / 复杂图表 / 动画用 `RepaintBoundary`；大数据解析放 `compute()` isolate；列表 / 统计类 Provider 加 `autoDispose`。
- **用户设置**存 SharedPreferences；云凭据存 `flutter_secure_storage`（iOS Keychain / Android Keystore），云配置读写集中在 `packages/flutter_cloud_sync/lib/src/config/cloud_service_store.dart`。

## 测试与质量门禁

- **测试分层**：单元（`test/`，Repository / Service / 纯函数）/ Widget（`test/widget/`）/ 页面级回归（`test/pages/`）。测试文件镜像被测路径，如 `test/repositories/local_account_repository_test.dart`。
- **必测场景**：正常路径 / 空数据 / 边界 / 错误路径，外加**同步兼容**——写操作是否产生 `local_changes` 记录。
- **Mock 用 mocktail**，不用 mockito（避免 codegen）。同步相关测试用假 `CloudProvider` / 内存库（见 `test/cloud/`、`test/backup/`）驱动，不要连真实后端。
- **同步相关改动**：修改 push / pull / diff / 指纹逻辑必须同步更新契约覆盖测试的字段清单，并保证 `flutter analyze --fatal-infos` + `flutter test` 全绿。
- **字体令牌 ratchet**：`test/styles/font_size_token_ratchet_test.dart` 钉死硬编码字号「只减不增」，新增裸字号字面量会让它变红。
- **验收证据**：声称完成前提供可复核证据（测试输出 / 门禁结果 / 实机截图），不要仅凭类型通过就下结论。

## Python 脚本与实测工具链（`scripts/`）

- `scripts/` 下是数据注入、图标生成、内存 / 帧率 profile、对比校验等辅助脚本（Python），它们是开发工具，**不参与 App 构建**。
- 包名 / 路径约定（模拟器双端同步实测）：dev 包 `com.wait.piggycount.dev.debug`，本地库 `app_flutter/piggycount.sqlite`，附件 `app_flutter/attachments/`。
- 拉 / 推二进制必须用 `adb exec-out`（`adb shell cat` 会把 `\n` 转成 `\r\n`，拉 sqlite 必坏）；`adb push` 用 Windows 原生路径。
- **清库只删 `piggycount.sqlite*` + `attachments/`，绝不碰 `shared_prefs/`**（含库加密主密钥与云配置）。
- 对比脚本退出码：`0` = 无非预期差异，`2` = 存在不一致，`3` = 契约漂移（三向校验失败）。

## Git 约定

- **分支**：`wait` 是开发主线（release 手动触发仅限此分支）；功能分支 `feature/<name>`、修复 `fix/<desc>`、重构 `refactor/<module>`、文档 `docs/<name>`。
- **Conventional Commits（中文）**：`<type>(<scope>): <简短描述>`，类型 `feat` / `fix` / `refactor` / `style` / `perf` / `test` / `docs` / `chore` / `ci` / `revert`；简短描述 ≤ 50 字符、祈使句，正文说「为什么」。正文要点用列表，批量工作可在标题末尾附日期。
- **PR**：小而专注（目标 ≤ 500 行）；按 `.github/PULL_REQUEST_TEMPLATE.md` 填写；CI 必过（`dart format` 无修改需求、`flutter analyze` 0 issue、`flutter test` 全绿）。
- **提交前自检**：`dart format .` → `flutter analyze` → `flutter test` →（改过 schema / codegen 源）`build_runner build` → 新功能有测试 → 暗黑模式正常 → 文案进 `.arb`。
- **不要主动提交**：除非用户明确要求，否则只改工作区、把结果交用户确认。

## 外部文档

- 贡献与开发流程：`docs/contributing/CONTRIBUTING_ZH.md`（英文 `CONTRIBUTING_EN.md`）
- Design Token 对照：`docs/design/DESIGN_TOKENS.md`；UI 评审：`docs/design/UI_OPTIMIZATION_REVIEW.md`
- 工程文档：`docoments/01-17`（01 项目总览 / 03 技术栈 / 04 系统架构 / 06 数据同步 / 07 数据模型 / 08 数据访问 / 09 错误处理 / 10 测试策略 / 11 性能 / 12 安全 / 13 构建发布 / 14 日志 / 15 开发规范 / 16 已知问题 / 17 版本演进）+ `docoments/INDEX.md`。**注意：这批文档成于 2026-07，同步架构 / 类名（`SyncEngine`、`BeeDatabase`、`BeeTokens` 等）已滞后于代码，遇到冲突一律以代码与 `pubspec.yaml` 为准。**
- 需求与设计留档：`prd/README.md`（索引与进度对照）+ 各 `prd/<id>/{requirements,design}.md`
- 云同步配置：`docs/cloud-setup.md`；加密边界：`docs/encryption-security-boundary.md`
- 优化计划与审计：`docs/optimization-plan-2026-09-19.md`、`docs/sync-comprehensive-audit-*.md`、`docs/s3-webdav-sync-audit-*.md`
- 上游工程：Riverpod <https://riverpod.dev/> · Drift <https://drift.simonbinder.eu/> · Effective Dart <https://dart.dev/guides/language/effective-dart> · Conventional Commits <https://www.conventionalcommits.org/zh-hans/>