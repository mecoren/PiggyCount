# 16. 已知问题

> 文档版本：v1.3
> 最后更新：2026-10-21
> 作者：wait
> 信息源：项目源码（本仓库）+ 前 15 篇工程文档中的 [未实现]/[待补充]/[待确认] 标记汇总
>
> ⚠️ **2026-10-17 同步说明**：正文保留 2026-07-25 的历史审查结论，但已逐条标注
> 「已过期 / 已修复」的条目**不再是待办**。本轮同步涉及：PiggyCount Cloud /
> SyncEngine / 共享账本已整体下线（当前为 Supabase / WebDAV / S3 / iCloud 四种快照
> 同步）；`schemaVersion` 已到 **58**；搜索已 SQL 下推、统计已 SQL GROUP BY、
> v58 已补齐查询索引；AI 已支持查账；PIN 已升级 Argon2id；Android 整库加密已启用。
> 具体以源码与 `AGENTS.md` 为准。

---

## 1. 背景

本文档系统化整理 PiggyCount 项目当前已识别的**问题、未实现功能、技术债与改进建议**，按严重程度分级，便于项目维护者：

1. **优先处理严重问题**：尤其是与 [PRIVACY.md](../PRIVACY.md) 声明不符的实现
2. **规划迭代路线**：将中低优先级问题纳入后续版本
3. **新开发者避坑**：开发时避免重复踩已知坑

> ⚠️ **重要说明**：本文档列出的问题**部分由代码静态审查发现**，可能存在理解偏差。任何修复前应再次确认问题是否复现，避免误判。

---

## 2. 问题分级标准

| 等级 | 含义 | 处理时限 |
|---|---|---|
| 🔴 **P0 严重** | 数据丢失、安全漏洞、隐私政策不符 | 立即修复 |
| 🟠 **P1 高** | 影响核心功能、潜在数据风险 | 下一个版本 |
| 🟡 **P2 中** | 影响体验、性能瓶颈 | 季度规划 |
| 🟢 **P3 低** | 代码质量、可维护性 | 长期演进 |

---

## 3. 严重问题（P0）

### 3.1 隐私政策与代码实现严重不符

**问题位置**：[PRIVACY.md](../PRIVACY.md) 多处声明 vs 项目源码

#### 3.1.1 Android Keystore 声明与实际不符

- **声明位置**：[PRIVACY.md:93](../PRIVACY.md)
  > "Authentication credentials are stored securely using Android Keystore"
- **现状（2026-10-17 复核：已修复）**：
  - PIN 哈希为 Argon2id + 随机 salt，存 `flutter_secure_storage`
    （`lib/services/security/app_lock_service.dart:119,139`；SharedPreferences 仅保留旧值迁移路径）。
  - 云服务凭据统一经 `CloudServiceStore` 写安全存储
    （`packages/flutter_cloud_sync/lib/src/config/cloud_service_store.dart`）。
  - AI 服务商 apiKey 存安全存储；配置导入也已改为直接进安全存储（2026-10-17）。
  - 应用锁开关等非敏感状态仍在 SharedPreferences，属可接受范围。以下为历史结论，保留备查。
- **风险**：
  - root 设备/备份提取场景下，所有云服务凭证可被直接窃取
  - **严重违反隐私政策声明，存在合规风险**
- **建议修复（已完成）**：
  1. ✅ 引入 [flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage) 存储敏感字段
  2. ✅ PRIVACY.md 的 "Android Keystore" 表述已与实现对齐
  3. ✅ Keystore / Keychain 集成已落地

#### 3.1.2 License 声明与实际不符

- **声明位置**：[PRIVACY.md:111](../PRIVACY.md)
  > "PiggyCount is fully open source under the MIT License"
- **实际实现**：[LICENSE](../LICENSE) 与 [README.md:333](../README.md)
  > 本项目采用 **商业源代码许可证（Business Source License, BSL）**
  > 商业使用需要付费授权
- **风险**：用户基于 PRIVACY.md 误判许可类型，可能造成商用合规风险
- **现状（2026-10-17）**：✅ 已修复 —— `PRIVACY.md` 现明确「not MIT-licensed … BSL」，
  与 `LICENSE`、README 一致。
- **建议修复（已完成）**：修订 PRIVACY.md，将 "MIT License" 改为 "Business Source License (BSL)"

#### 3.1.3 Supabase / WebDAV / S3 同步方案未在隐私政策中列出

- **现状（2026-10-17 复核：已修复）**：`PRIVACY.md` 的 Cloud sync 一节已列出
  WebDAV / S3-compatible / Supabase。Supabase 与 iCloud 后端在 UI 上仍被
  `_kShowSupabaseAndICloud = false` 隐藏（`lib/pages/cloud/cloud_service_page.dart:33-38`），
  当前无用户可达入口；若日后重新暴露，需同步补声明。

### 3.2 PIN 码安全机制薄弱

> ⚠️ **2026-10-17 复核：本条已过期**。PIN 现为 **Argon2id**（3 迭代 / 64MB / 2 并行）+
> 每次 `setPin` 生成新 16 字节 salt，哈希与 PIN 长度写入 `flutter_secure_storage`；
> 旧无盐 SHA-256 仅保留在迁移期用于验证旧 PIN，验证成功后自动升级。失败退避也已实现：
> 5 次锁 30 秒、10 次锁 5 分钟，另有可选 wipe（连续失败达阈值清库）。以下为 2026-07-25
> 的原始结论，保留备查。

**问题位置**：[lib/services/security/app_lock_service.dart:26-37](../lib/services/security/app_lock_service.dart)

```dart
static String hashPin(String pin) {
  final bytes = utf8.encode(pin);
  return sha256.convert(bytes).toString();  // ← 历史实现：无 salt、无慢哈希
}
```

#### 3.2.1 无盐 SHA-256 + 4 位 PIN

- **现状（2026-10-17）**：✅ 已修复 —— Argon2id + 随机 salt，支持 4/6 位 PIN。
- **历史风险**：4 位 PIN 仅 10000 种组合，无盐 SHA-256 可在毫秒级被彩虹表/暴力破解
- **建议修复（已完成）**：
  1. 引入随机 salt（每个用户独立）
  2. 使用 PBKDF2 / bcrypt / Argon2 等慢哈希算法
  3. 增加 PIN 长度配置（4/6 位可选）

#### 3.2.2 无失败次数限制

**问题位置**：[lib/pages/auth/app_lock_screen.dart](../lib/pages/auth/app_lock_screen.dart)

- **现状（2026-10-17）**：✅ 已修复 —— 失败 5 次锁 30 秒、10 次锁 5 分钟；
  连续失败达阈值且用户开启 wipe 开关时清空本机数据。
- **历史风险**：PIN 可被无限次暴力尝试
- **建议修复（已完成）**：
  1. 失败 5 次后强制等待 30 秒
  2. 失败 10 次后强制等待 5 分钟
  3. 失败 20 次提供 wipe 选项（用户配置启用）

### 3.3 SQLite 数据库明文存储

**问题位置**：[lib/data/db.dart:1240-1260](../lib/data/db.dart)

```dart
LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final file = File(p.join(dir.path, 'piggycount.sqlite'));
    return NativeDatabase.createInBackground(file);  // ← 明文 SQLite
  });
}
```

- **风险**：root 过的 Android 设备 / 已越狱 iOS 设备 / 备份提取场景下，账本数据可直接被读取
  （库文件是明文 SQLite）。
- **现状（2026-10-05 更新：已实现，opt-in）**：
  - 整库加密（SQLCipher）已落地：密钥进系统安全区、开库前每条连接 `PRAGMA key`、
    **明文 ⇄ 密文双向**原子迁移（临时文件 + 校验 + 原子替换 + 中断回退）、健康探测适配、
    密钥丢失引导（R5）、六态开关 UI。需求/设计见 `prd/sqlcipher_db_encryption/`，
    实现与实测证据见其 `design.md` §7。
  - **默认关闭**：不显式开启就不生成密钥，行为与加密前逐字一致。这是刻意的 ——
    凭空建钥会让"库看起来该加密、文件其实还是明文"成为默认状态。
  - **Android 已于 2026-10-06 启用**：三个 ABI 的 `libsqlcipher.so` 已入库随包分发
    （`android/app/src/main/jniLibs/`），`hooks.user_defines.sqlite3.name_android: sqlcipher`；
    实测 APK 内出现 `libsqlcipher.so`、运行态报告 SQLCipher 4.18.0。整库加密仍为
    **用户手动开启（opt-in，默认关闭）**。
  - **iOS 未验证**：本机无 macOS，留给 CI 首次跑通时验证（同样需要自带库）。
- **注意**：整库加密只保护**本机落盘**；云端备份/快照的加密是另一条链路（E2EE，
  见 4.2 节与 `lib/domain/encryption/`），两者不要混为一谈。

---

## 4. 高优先级问题（P1）

### 4.1 网络通信安全

#### 4.1.1 无证书锁定（Certificate Pinning）

- **现状**：全局 Grep `certificatePinning|badCertificateCallback|onCertificateCheck` **零匹配**
- **风险**：理论上中间人攻击（CA 投毒、企业代理 CA、用户安装的根证书）可解密 HTTPS 流量
- **影响范围**：所有云同步后端（Supabase / WebDAV / S3 / iCloud）与 AI 调用
- **建议修复**：
  1. 关键服务（如 GitHub Releases 更新检查、PiggyCount Cloud 默认服务）启用证书锁定
  2. 用户自配置服务提供"高级安全模式"选项启用锁定

#### 4.1.2 用户自配置 URL 未强制 HTTPS

- **现状（2026-10-17 复核：已修复）**：新增 `lib/utils/secure_url.dart`，配置表单保存时校验
  （`lib/pages/cloud/cloud_service_page.dart` 的 Supabase / WebDAV 表单 `isExplicitHttpUrl`
  拦显式 `http://`、`normalizeCloudUrl` 补协议；S3 表单不拦，靠
  `packages/flutter_cloud_sync_s3/lib/src/s3_provider.dart:120-128` 的 `useSSL` 判定兜底）。
  **provider 层另有硬拦**（真正落盘后的二道关）：WebDAV
  `packages/flutter_cloud_sync_webdav/lib/src/webdav_provider.dart:155-159`、Supabase
  `packages/flutter_cloud_sync_supabase/lib/src/supabase_provider.dart:103-110`、S3 同上，
  均抛 `CloudConfigurationException`。AI provider Base URL 同样强制 HTTPS（仅回环地址放行，
  `lib/ai/providers/ai_provider_factory.dart:27-31`）。`CloudServiceStore` 本身**不做** URL 校验。
- **风险（历史）**：用户可填入 `http://`，凭证与数据明文传输
- **建议修复（已完成）**：URL 输入框强制 `https://` 前缀，提示用户不安全连接风险

### 4.2 AI 隐私保护不足

**问题位置**：[lib/ai/privacy/ai_privacy_consent.dart](../lib/ai/privacy/ai_privacy_consent.dart)（全文 30 行）

#### 4.2.1 发送前无二次确认

- **现状（2026-10-17 复核：已修复）**：发送前二次确认已落地（会话级确认 +
  `AiProviderFactory` 二道关），实现见 `lib/ai/privacy/ai_send_confirm.dart`、
  `lib/widgets/ai/ai_send_confirm_dialog.dart`，守门测试 `test/ai/ai_send_confirm_test.dart`。
- **风险（历史）**：用户可能误触发送包含敏感信息（账户名、金额）的请求
- **建议修复（已完成）**：发送前显示"将发送给 <服务商>"提示并需用户确认

#### 4.2.2 无敏感数据脱敏

- **现状（2026-10-17 复核：已修复）**：账户名默认脱敏为 `account_1…` 别名，
  落库前再映射回真实名（`lib/ai/core/ai_extraction_context.dart:38-39,98,121-136`）；
  备注支持"敏感"标记，标记后 AI 外发与列表展示均按掩码处理。
- **风险（历史）**：账户名可能包含真实姓名，备注可能包含敏感信息
- **建议修复（已完成）**：
  1. ✅ 账户名发送前替换为 `account_1`、`account_2` 等匿名标识
  2. ✅ 备注字段提供"包含敏感信息"标记，默认不发送

#### 4.2.3 同意状态可被篡改

- **现状（2026-10-17 复核：已修复）**：同意版本号存 `flutter_secure_storage`
  （`lib/ai/privacy/ai_privacy_consent.dart:19-20,42-61`），旧明文 int 读到即迁移并清理。
- **风险（历史）**：root 用户可手动写入 version 跳过对话框
- **建议修复（已完成）**：使用 flutter_secure_storage 存储同意状态

### 4.3 截屏保护（原「未实现」，2026-10-10 已实现）

> ⚠️ **2026-10-10 复核：本条已过期，功能已落地**。
> [android/app/src/main/kotlin/.../MainActivity.kt](../android/app/src/main/kotlin/com/wait/piggycount/MainActivity.kt)
> 的 `onCreate` 现调用 `applyScreenshotProtection(true)`（即 `window.addFlags(FLAG_SECURE)`）——
> 系统截屏、录屏、投屏与多任务缩略图均无法采集本应用画面。原「建议修复」的第二条（设置中提供开关）
> 也已补上：`lib/services/security/screenshot_protection_service.dart` + 设置页
> 「应用锁 → 防截屏保护」（**默认开启**，关闭走单次危险确认）。以下为 2026-07-25 的原始审查结论，保留备查。

- **现状（审查时）**：全局 Grep `FLAG_SECURE|setWindowFlags|secureWindow` 在整个项目中**零匹配**
- **风险（当时）**：
  - Android 系统截屏、录屏、多任务缩略图未通过 `FLAG_SECURE` 阻止
  - 仅通过 `AppLifecycleState.inactive` 触发的模糊屏部分缓解（系统截屏快捷键可能不触发 inactive）
- **建议修复（已照此实施）**：在 [android/app/src/main/kotlin/.../MainActivity.kt](../android/app/src/main/kotlin/com/wait/piggycount/MainActivity.kt) `onCreate` 中添加：
  ```kotlin
  window.setFlags(
    LayoutParams.FLAG_SECURE,
    LayoutParams.FLAG_SECURE
  )
  ```
  并在设置中提供"启用截屏保护"开关

### 4.4 数据库备份未加密

- **现状（2026-10-17）**：✅ 可选 E2EE 已实现 —— `lib/domain/encryption/` 用
  AES-256-GCM + Argon2id 派生密钥，开启后四后端快照以 `BEECRYPT1:` 密文上传
  （`EncryptedCloudProvider` 装饰），密钥不上传服务端；关闭时与明文行为一致。
- **历史风险**：备份内容受 HTTPS 传输保护，但服务端可见明文
- **建议修复（已完成）**：
  1. 提供可选的"端到端加密备份"功能
  2. 加密密钥由用户密码派生（PBKDF2/Argon2id），不上传至服务端
  3. PiggyCount Cloud 方案已随云端协同整体下线，不再作为推荐项

---

## 5. 中优先级问题（P2）

### 5.1 性能优化待补充

#### 5.1.1 transactions 表缺复合索引

**问题位置**：[lib/data/db.dart](../lib/data/db.dart)

- **现状**：✅ **本节已过期（2026-09-19 核实）**——`(ledger_id, happened_at)` 复合索引已存在：
  `db.dart:1324`（`onUpgrade` 里的 v32 迁移补建）与 `db.dart:1560`（`onCreate` 全新库路径），
  `test/data/repositories/local/transaction_query_benchmark_test.dart` 断言其命中。
  （行号取之于 2026-09-19；`db.dart` 在 B10 加过 `beforeOpen`，日后引用前先 grep
  `idx_transactions_ledger_happened`。）下文保留为历史记录。
- **2026-10-17 补充**：v58 又补齐 `idx_transactions_ledger_type_happened`、
  `idx_transactions_account`、`idx_transactions_to_account`、
  `idx_transactions_ledger_category`、`idx_budgets_ledger_type_enabled_category`、
  `idx_deleted_transactions_ledger_deleted`；守门测试见
  `test/data/migration_v58_index_test.dart` 与 `test/performance/sql_query_baseline_test.dart`。
- **影响**：首页交易列表按时间倒序分页查询的最热路径，数据量增长后会触发全表扫描
- **建议修复**：在 schemaVersion=32 迁移中补充：
  ```dart
  await m.customStatement(
    'CREATE INDEX IF NOT EXISTS idx_transactions_ledger_happened '
    'ON transactions(ledger_id, happened_at DESC)'
  );
  ```

#### 5.1.2 长列表缺 RepaintBoundary

- **现状（2026-10-17：已修复）**：交易行在 `transaction_list.dart` 的两个调用点
  （日卡片 / 平铺旧风格）均包 `RepaintBoundary`；`CategoryPieChart`、
  `AccountCategoryPieChart`、`AssetCompositionChart`、`AnalyticsBarChart`、`LineChart`
  的 `build` 统一先包一层 `RepaintBoundary`。
- **注意**：收益需真机滚动 / 帧率基线复核，当前只落地隔离层，未声称提速数字。

#### 5.1.3 WAL 模式未显式声明

- **现状（2026-10-17）**：✅ 已在 `lib/data/db.dart` 的 `beforeOpen` 显式
  `PRAGMA journal_mode=WAL`，并用 `PRAGMA journal_size_limit=...` 限制 `-wal` 保留上限；
  `synchronous` 刻意保持 FULL（掉电不丢最后几笔）。
- **历史风险**：不同平台/版本默认值可能不同
- **建议修复（已完成）**：在连接初始化时显式执行 `PRAGMA journal_mode=WAL;`

#### 5.1.4 列表 Key 拼接 index

**问题位置**：[lib/widgets/biz/transaction_list.dart](../lib/widgets/biz/transaction_list.dart)

- **现状（2026-10-17 复核：已修复）**：`lib/widgets/biz/transaction_list.dart:774`
  已改为纯 `Key('tx-${it.t.id}')`，不再拼接 index。

### 5.2 同步引擎潜在风险

> ⚠️ **2026-10-17 复核**：PiggyCount Cloud / SyncEngine / 增量 pull 已整体下线，
> 当前是整账本快照同步（Path A）。本节关于 LWW、cursor、SyncEngine 的描述属历史记录；
> 快照路径的冲突处理见 `lib/cloud/sync_diff_service.dart` 与 `sync_restore_guard.dart`。

#### 5.2.1 LWW 冲突解决可能丢数据

**问题位置**：`lib/cloud/sync/sync_conflict_resolver.dart`

- **现状**：使用 Last-Write-Wins（最后写入胜出）策略
- **风险**：两台设备同时修改同一笔交易，后同步的覆盖先同步的，无合并机制
- **建议修复**：
  1. 关键字段（金额、备注）提供字段级合并
  2. 冲突时记录到 `sync_conflicts` 表，提供 UI 让用户选择保留版本

#### 5.2.2 sync_pull_errors 表隔离设计风险

**问题位置**：[lib/data/db.dart](../lib/data/db.dart) `SyncPullErrors` 表

- **现状**：失败的 pull 变更记录到独立表，不影响主表
- **风险**：用户可能不知道有同步失败的记录，长期累积造成数据不一致
- **建议修复**：
  1. UI 层显示同步失败计数（在设置 → 云服务页面）
  2. 提供"重试同步失败项"按钮
  3. 失败超过 7 天的记录提供导出/查看

### 5.3 测试覆盖不足

#### 5.3.1 集成测试用例少

- **现状（2026-10-17）**：目录已建立（`integration_test/recent_entry_inherit_test.dart` 等），
  2026-10-17 又补了设备端搜索 SQL 下推与回收站闭环；用例数量仍在增长。
- **建议补充**：
  1. 首次启动 → 创建账本 → 添加交易 → 重启验证数据持久化
  2. 离线添加交易 → 联网 → 验证同步成功
  3. CSV 导入导出全流程
  4. 多账本切换上下文隔离

#### 5.3.2 无测试覆盖率工具

- **现状（2026-10-17）**：✅ 已接入 CI 并设行覆盖门禁 —— `analyze.yml` 用
  `flutter test --coverage`，`scripts/coverage_summary.py` 写 Job Summary（行覆盖率 +
  最低 20 文件），并上传 `coverage-lcov` artifact。全量实测行覆盖 **44.1%**
  （32024/72687，`lib/` 下 374 个文件；2026-10-21 本批复测 44.3%，32170/72691，
  与基线同档）；CI 阈值 `--fail-under 43`（基线下方约 1 个百分点，只拦断崖式下滑，
  后续随基线上行逐步抬高）。Dart 的 lcov 不产出函数 / 分支记录，摘要中这两项显示
  “—”，门禁只按行覆盖率判定。
- **建议修复（已完成）**：
  1. 在 CI 中添加 `flutter test --coverage`
  2. 上传覆盖率报告（当前用 GitHub Actions artifact，未接 codecov）
  3. 设阈值并用 `--fail-under` 阻止低覆盖 PR（2026-10-17 已设 43）

### 5.4 凭证存储改进

#### 5.4.1 全部凭证明文存储

- **现状（2026-10-17 复核：已修复）**：
  - 云服务凭据统一经 `CloudServiceStore` 写 `flutter_secure_storage`，读取时迁移旧明文并清理
    （`packages/flutter_cloud_sync/lib/src/config/cloud_service_store.dart`）。
  - AI 服务商 `apiKey` 存安全存储（`lib/ai/providers/ai_provider_manager.dart:14-30`）；
    配置导入也不再写明文 prefs（`lib/services/export/config_export_service.dart:2397-2410`）。
  - E2EE 密钥、PIN 哈希、AI 同意版本号均已在安全存储。
- **历史问题（保留备查）**：云配置、AI Key、PIN 曾以明文存 SharedPreferences。

#### 5.4.2 配置导出可能泄露凭证

- **现状（2026-10-17 复核：已修复）**：默认导出把凭据替换为 `****`
  （`_sensitiveFieldNames` 递归兜底），仅当用户显式勾选 `includeCredentials` 才写真实值
  （`config_export_service.dart:89-139,1321-1325`）。
- **剩余可选项**：导出文件本身未做 AES 加密，可按需后续补充。

---

## 6. 低优先级问题（P3）

### 6.1 代码质量

#### 6.1.1 文件过长

- **现状（2026-10-17）**：部分文件超过 1000 行（如 [annual_report_page.dart](../lib/pages/report/annual_report_page.dart)、`lib/data/db.dart`、`lib/cloud/transactions_sync_manager.dart`、`lib/services/data_import_service.dart`）
- **建议修复**：按职责拆分为多个文件，单文件控制在 500 行内

#### 6.1.2 TODO/FIXME 标记

- **现状（2026-10-17 复核）**：`lib/` 内仅剩 1 处 TODO —— `lib/data/db.dart:945`
  的 **TODO-M18**（`cache_size` / `mmap_size` 需真机内存基线后再定，见
  `prd/mem_baseline_and_leaks/`）。此前 `sync_providers.dart` 与
  `product_promo_card.dart` 的两处已清理。
- **建议修复**：真机基线出来后给 M18 定论，顺手移除标记。

#### 6.1.3 dependency_overrides 钉死版本

**问题位置**：[pubspec.yaml](../pubspec.yaml) `dependency_overrides`

```yaml
dependency_overrides:
  jni_flutter: 1.0.3
```

- **现状（2026-10-17）**：仅钉 `jni_flutter: 1.0.3`（1.0.4 已被 pub 撤回，
  `path_provider_android` 仍会选到它）；record / image_cropper 的历史 pin 已移除。
- **风险**：长期不更新可能错过安全修复
- **建议修复**：跟踪上游 issue，待官方修复后移除 override

### 6.2 文档与代码不一致

#### 6.2.1 docs/contributing/CONTRIBUTING_ZH.md 项目结构过时

- **现状（2026-10-17 复核：已修复）**：`CONTRIBUTING_ZH.md` 与 `CONTRIBUTING_EN.md`
  的项目结构树已按当前 `lib/`（ai / cloud / data / domain / l10n / models / pages /
  providers / services / styles / utils / widget / widgets + `packages/`）重写，
  不再出现 `repository.dart` / `supabase_sync.dart` 等已删除路径。

#### 6.2.2 PRIVACY.md 联系方式未填写

- **现状（2026-10-17 复核：已修复）**：占位提示已替换为 `user@example.com`，
  并保留 GitHub Issues / Discussions 两个有效入口。

### 6.3 平台兼容性

#### 6.3.1 鸿蒙版本已停止更新

- **现状**：[README.md:55](../README.md) 标注 `piggycount-openharmony` 仓库已停止更新
- **影响**：鸿蒙用户无法使用最新版本
- **建议**：明确告知用户，引导至 Android 版本

#### 6.3.2 iOS 不支持应用内 OTA 更新

- **现状**：iOS 版本无应用内更新入口（App Store 政策限制）
- **影响**：iOS 用户必须通过 App Store 更新
- **建议**：在设置 → 关于 中显示"请通过 App Store 更新"

#### 6.3.3 Web 平台未原生支持

- **现状（2026-10-17）**：PiggyCount 本身无 Web 端；原 PiggyCount Cloud 独立项目已随云端协同下线，本仓库不构建 Web 端。
- **建议**：文档保持「Android / iOS 客户端」口径，不再提 Cloud Web 端

### 6.4 国际化不完整

#### 6.4.1 韩语社区维护

- **现状**：[lib/l10n/app_ko.arb](../lib/l10n/app_ko.arb) 由社区贡献
- **风险**：可能存在翻译滞后、错误未及时修复
- **现状（2026-10-17）**：✅ CI 已加 ARB key 一致性门禁
  （`scripts/i18n/check_arb_consistency.dart`），4 语言键集合 / 非故意空值 / 占位符不一致会直接红；
  `flutter gen-l10n` 生成的 locale 文件随仓库提交。
- **建议**：
  1. 在 CI 中添加 .arb 文件 key 一致性检查（已完成）
  2. 标记未翻译的 key（fallback 到英文）

#### 6.4.2 阿拉伯语/希伯来语 RTL 支持

- **现状**：未支持 RTL 布局
- **影响**：中东地区用户体验差
- **建议**：长期规划支持 RTL

### 6.5 依赖管理

#### 6.5.1 Flutter SDK 版本锁死

- **现状（2026-10-17）**：Flutter 版本单一来源在 `pubspec.yaml#environment.flutter`
  （当前 **3.47.6**），CI 用 `flutter-version-file` 读取，不再手写版本号。
- **风险**：长期不升级错过新特性、安全修复
- **建议**：定期升级，参考 [13-build-release.md](13-build-release.md)

#### 6.5.2 部分依赖未及时升级

- **建议**：定期运行 `flutter pub outdated` 检查可升级依赖

---

## 7. 已知限制（非问题）

### 7.1 设计限制（无需修复）

| 限制 | 原因 | 影响 |
|---|---|---|
| iOS 不支持应用内 OTA | App Store 政策禁止 | iOS 用户走 App Store |
| 同步引擎不支持 P2P | 架构选择，依赖云端中转 | 无网络时无法跨设备同步 |
| AI 默认使用智谱 GLM | 国内可访问、无需翻墙 | 海外用户需自行配置 OpenAI 等 |
| 桌面小组件功能有限 | iOS WidgetKit / Android AppWidget 限制 | 仅展示不能交互 |
| 无 Web 端原生 | 本仓库不构建 Web 端 | 使用 Android / iOS 客户端 |

### 7.2 已知技术债

- **本地化字符串重复**：部分 .arb 文件存在重复 key
- **ThemeData 重复构建**：暗黑模式切换时可能重建多次
- **Provider 嵌套过深**：部分页面 `ProviderScope` override 较多

---

## 8. 改进路线建议

### 8.1 短期（1-2 个版本）

1. ✅ 修订 PRIVACY.md 的 License 声明（MIT → BSL，已完成）
2. ✅ 引入 flutter_secure_storage：E2EE 密钥、PIN 哈希、云服务凭据、AI Key 均已进安全存储
3. ~~🟠 启用 Android FLAG_SECURE 截屏保护~~ ✅ 已完成（2026-10-10，并在设置页提供开关）
4. ✅ PIN 码失败退避 + wipe 开关（Argon2id，已实现）
5. ✅ 用户自配置 URL 强制 HTTPS 校验（表单层 `lib/utils/secure_url.dart` + 三后端 provider 层硬拦）

### 8.2 中期（季度规划）

1. ✅ 启用 SQLCipher 加密本地数据库（Android 2026-10-06 启用，opt-in 默认关闭）
2. ✅ AI 调用前敏感数据脱敏（账户名别名 + 备注敏感标记）
3. ✅ transactions 表复合索引（v32 + v58 已补齐）
4. ✅ 长列表 / 图表添加 RepaintBoundary（2026-10-17，收益待真机基线复核）
5. 🟡 补充集成测试用例（目录已建立，持续补充）
6. ✅ CI 集成测试覆盖率工具（report-only + artifact）

### 8.3 长期（年度规划）

1. 🟢 关键服务证书锁定
2. 🟢 同步冲突字段级合并（快照同步下语义不同）
3. 🟢 大文件拆分（annual_report_page、db.dart、transactions_sync_manager 等）
4. 🟢 文档与代码同步检查机制
5. ✅ 多语言 .arb 一致性 CI 检查（E4 已落地）

---

## 9. 问题反馈渠道

发现新问题请通过：

- **GitHub Issues**：[https://github.com/mecoren/PiggyCount/issues](https://github.com/mecoren/PiggyCount/issues)
- **GitHub Discussions**：[https://github.com/mecoren/PiggyCount/discussions](https://github.com/mecoren/PiggyCount/discussions)
- **Telegram**：[https://t.me/piggycount](https://t.me/piggycount)

提交 Bug 时请包含：

1. **环境信息**：操作系统、设备型号、应用版本、云服务配置
2. **复现步骤**：详细到可重现
3. **预期与实际**：分别说明
4. **截图/日志**：日志可在 设置 → 日志中心 查看（参考 [14-logging.md](14-logging.md)）

---

## 10. 信息缺口

- **[待确认]** 部分问题来自代码静态审查，可能存在理解偏差，修复前需再次确认
- **[已补充 2026-10-17]** SQL 层基线在 `test/performance/sql_query_baseline_test.dart`
  （1 万笔 / 24 个月，EXPLAIN 断言 v58 索引 + 打印耗时）；设备侧首屏 / FPS 基线见
  `docs/evidence/perf-baseline-2026-10-05.md`。
- **[待补充]** 用户反馈的高频 Bug 统计未在工程文档中体现，建议定期从 GitHub Issues 提取并更新本文档
- **[推断]** 快照同步（Path A）在弱网/断网恢复场景的边界 case，建议继续补充集成测试覆盖

---

本文档随版本迭代持续更新，新发现的问题请通过 PR 补充至对应优先级章节。
