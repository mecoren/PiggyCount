# 16. 已知问题

> 文档版本：v1.0
> 最后更新：2026-07-25
> 作者：wait
> 信息源：项目源码（d:\DevTools\project\PiggyCount）+ 前 15 篇工程文档中的 [未实现]/[待补充]/[待确认] 标记汇总

---

## 1. 背景

本文档系统化整理 PiggyCount 项目当前已识别的**问题、未实现功能、技术债与改进建议**，按严重程度分级，便于项目维护者：

1. **优先处理严重问题**：尤其是与 [PRIVACY.md](file:///d:/DevTools/project/PiggyCount/PRIVACY.md) 声明不符的实现
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

**问题位置**：[PRIVACY.md](file:///d:/DevTools/project/PiggyCount/PRIVACY.md) 多处声明 vs 项目源码

#### 3.1.1 Android Keystore 声明与实际不符

- **声明位置**：[PRIVACY.md:93](file:///d:/DevTools/project/PiggyCount/PRIVACY.md)
  > "Authentication credentials are stored securely using Android Keystore"
- **实际实现**：
  - ⚠️ **2026-09-19 复核，本条已部分失效**：`lib/` 内已有 `FlutterSecureStorage`（仅用于
    E2EE 密钥，`lib/data/encryption/secure_key_storage.dart:27-31`），"零匹配"不再成立；
    PIN 也已改为 Argon2id + 每次新 salt（`app_lock_service.dart:40-54`，原文称"SHA-256
    未加盐"同样过期）。**仍然成立的部分**：PIN 哈希与应用锁开关仍在 SharedPreferences
    （`app_lock_service.dart:49,62`），未进 Keychain/Keystore。
  - 全部凭证（PIN 哈希、API Token、密码）存储在 `SharedPreferences`（明文 XML 文件）
  - 文件位置：[lib/services/security/app_lock_service.dart:26-37](file:///d:/DevTools/project/PiggyCount/lib/services/security/app_lock_service.dart)、[lib/pages/auth/login_page.dart:69-113](file:///d:/DevTools/project/PiggyCount/lib/pages/auth/login_page.dart)、`packages/flutter_cloud_sync/lib/src/providers/piggycount_cloud_provider.dart:1748-1754`
- **风险**：
  - root 设备/备份提取场景下，所有云服务凭证可被直接窃取
  - **严重违反隐私政策声明，存在合规风险**
- **建议修复**：
  1. 引入 [flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage) 替代 SharedPreferences 存储所有敏感字段
  2. 短期：修订 PRIVACY.md 删除 "Android Keystore" 声明
  3. 长期：实际实现 Keystore/Keychain 集成

#### 3.1.2 License 声明与实际不符

- **声明位置**：[PRIVACY.md:111](file:///d:/DevTools/project/PiggyCount/PRIVACY.md)
  > "PiggyCount is fully open source under the MIT License"
- **实际实现**：[LICENSE](file:///d:/DevTools/project/PiggyCount/LICENSE) 与 [README.md:333](file:///d:/DevTools/project/PiggyCount/README.md)
  > 本项目采用 **商业源代码许可证（Business Source License, BSL）**
  > 商业使用需要付费授权
- **风险**：用户基于 PRIVACY.md 误判许可类型，可能造成商用合规风险
- **建议修复**：立即修订 PRIVACY.md，将 "MIT License" 改为 "Business Source License (BSL)"

#### 3.1.3 Supabase / WebDAV / S3 同步方案未在隐私政策中列出

- **声明位置**：[PRIVACY.md:34-48](file:///d:/DevTools/project/PiggyCount/PRIVACY.md) 仅列出 Supabase 与 WebDAV 两种
- **实际实现**：[README.md:141-152](file:///d:/DevTools/project/PiggyCount/README.md) 支持 5 种同步方案（PiggyCount Cloud / iCloud / Supabase / WebDAV / S3）
- **建议修复**：补全 PiggyCount Cloud、iCloud、S3 的隐私声明

### 3.2 PIN 码安全机制薄弱

**问题位置**：[lib/services/security/app_lock_service.dart:26-37](file:///d:/DevTools/project/PiggyCount/lib/services/security/app_lock_service.dart)

```dart
static String hashPin(String pin) {
  final bytes = utf8.encode(pin);
  return sha256.convert(bytes).toString();  // ← 无 salt、无慢哈希
}
```

#### 3.2.1 无盐 SHA-256 + 4 位 PIN

- **风险**：4 位 PIN 仅 10000 种组合，无盐 SHA-256 可在毫秒级被彩虹表/暴力破解
- **建议修复**：
  1. 引入随机 salt（每个用户独立）
  2. 使用 PBKDF2 / bcrypt / Argon2 等慢哈希算法
  3. 增加 PIN 长度配置（4/6/8 位可选）

#### 3.2.2 无失败次数限制

**问题位置**：[lib/pages/auth/app_lock_screen.dart:75-91](file:///d:/DevTools/project/PiggyCount/lib/pages/auth/app_lock_screen.dart)

- **现状**：`_verifyPin` 失败仅 500ms 抖动后清空，无失败计数、无指数退避、无 wipe 选项
- **风险**：PIN 可被无限次暴力尝试
- **建议修复**：
  1. 失败 5 次后强制等待 30 秒
  2. 失败 10 次后强制等待 5 分钟
  3. 失败 20 次提供 wipe 选项（用户配置启用）

### 3.3 SQLite 数据库明文存储

**问题位置**：[lib/data/db.dart:1240-1260](file:///d:/DevTools/project/PiggyCount/lib/data/db.dart)

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
  - **Android 目前不能开启**：`sqlite3` 的 hook 在 `source: sqlcipher` 下产出的
    `libsqlcipher.so` **没有被复制进 APK**（实测：APK 内只有 `sqlite3_flutter_libs`
    打的上游 `libsqlite3.so`），需要自备 `android/app/src/main/jniLibs/`。取库脚本、
    配方与真机取证见 design §7；是否随包分发那 ~16.5MB 第三方二进制（许可/制品决定）
    未定，因此 `pubspec.yaml` 保持 `source: system`。
  - **iOS 未验证**：本机无 macOS，留给 CI 首次跑通时验证（同样需要自带库）。
- **注意**：整库加密只保护**本机落盘**；云端备份/快照的加密是另一条链路（E2EE，
  见 4.2 节与 `lib/domain/encryption/`），两者不要混为一谈。

---

## 4. 高优先级问题（P1）

### 4.1 网络通信安全

#### 4.1.1 无证书锁定（Certificate Pinning）

- **现状**：全局 Grep `certificatePinning|badCertificateCallback|onCertificateCheck` **零匹配**
- **风险**：理论上中间人攻击（CA 投毒、企业代理 CA、用户安装的根证书）可解密 HTTPS 流量
- **影响范围**：所有云同步后端（PiggyCount Cloud / Supabase / WebDAV / S3）与 AI 调用
- **建议修复**：
  1. 关键服务（如 GitHub Releases 更新检查、PiggyCount Cloud 默认服务）启用证书锁定
  2. 用户自配置服务提供"高级安全模式"选项启用锁定

#### 4.1.2 用户自配置 URL 未强制 HTTPS

- **现状**：用户配置 WebDAV/S3/Supabase/PiggyCount Cloud URL 时无协议校验
- **风险**：用户可填入 `http://`，凭证与数据明文传输
- **建议修复**：URL 输入框强制 `https://` 前缀，提示用户不安全连接风险

### 4.2 AI 隐私保护不足

**问题位置**：[lib/ai/privacy/ai_privacy_consent.dart](file:///d:/DevTools/project/PiggyCount/lib/ai/privacy/ai_privacy_consent.dart)（全文 30 行）

#### 4.2.1 发送前无二次确认

- **现状**：仅在首次启用 AI 时弹同意对话框，后续每次调用直接发送数据
- **风险**：用户可能误触发送包含敏感信息（账户名、金额）的请求
- **建议修复**：在 AI 聊天发送按钮旁显示"将发送给 <服务商>"提示，长按可取消

#### 4.2.2 无敏感数据脱敏

- **现状**：发送给 AI 的上下文（[lib/ai/core/ai_extraction_context.dart](file:///d:/DevTools/project/PiggyCount/lib/ai/core/ai_extraction_context.dart)）包含完整账户名、原始金额、备注
- **风险**：账户名可能包含真实姓名（如 "张三的工资卡"），备注可能包含敏感信息
- **建议修复**：
  1. 账户名发送前替换为 `account_1`、`account_2` 等匿名标识
  2. 备注字段提供"包含敏感信息"标记，默认不发送

#### 4.2.3 同意状态可被篡改

- **现状**：同意状态存 SharedPreferences（`ai_privacy_consent_version` int）
- **风险**：root 用户可手动写入 version 跳过对话框
- **建议修复**：使用 flutter_secure_storage 存储同意状态

### 4.3 截屏保护未实现

- **现状**：全局 Grep `FLAG_SECURE|setWindowFlags|secureWindow` 在整个项目中**零匹配**
- **风险**：
  - Android 系统截屏、录屏、多任务缩略图未通过 `FLAG_SECURE` 阻止
  - 仅通过 `AppLifecycleState.inactive` 触发的模糊屏部分缓解（系统截屏快捷键可能不触发 inactive）
- **建议修复**：在 [android/app/src/main/kotlin/.../MainActivity.kt](file:///d:/DevTools/project/PiggyCount/android/app/src/main/kotlin/com/tntlikely/piggycount/MainActivity.kt) `onCreate` 中添加：
  ```kotlin
  window.setFlags(
    LayoutParams.FLAG_SECURE,
    LayoutParams.FLAG_SECURE
  )
  ```
  并在设置中提供"启用截屏保护"开关

### 4.4 数据库备份未加密

- **现状**：云同步（Supabase/WebDAV/PiggyCount Cloud）上传的是业务数据 JSON / 二进制，未发现任何对备份内容加密后再上传的代码
- **风险**：备份内容受 HTTPS 传输保护，但服务端可见明文
- **建议修复**：
  1. 提供可选的"端到端加密备份"功能
  2. 加密密钥由用户密码派生（PBKDF2），不上传至服务端
  3. PiggyCount Cloud 已支持 AES-256 备份加密，应作为推荐方案

---

## 5. 中优先级问题（P2）

### 5.1 性能优化待补充

#### 5.1.1 transactions 表缺复合索引

**问题位置**：[lib/data/db.dart](file:///d:/DevTools/project/PiggyCount/lib/data/db.dart)

- **现状**：✅ **本节已过期（2026-09-19 核实）**——`(ledger_id, happened_at)` 复合索引已存在：
  `db.dart:1324`（`onUpgrade` 里的 v32 迁移补建）与 `db.dart:1560`（`onCreate` 全新库路径），
  `test/data/repositories/local/transaction_query_benchmark_test.dart` 断言其命中。
  （行号取之于 2026-09-19；`db.dart` 在 B10 加过 `beforeOpen`，日后引用前先 grep
  `idx_transactions_ledger_happened`。）下文保留为历史记录。
- **影响**：首页交易列表按时间倒序分页查询的最热路径，数据量增长后会触发全表扫描
- **建议修复**：在 schemaVersion=32 迁移中补充：
  ```dart
  await m.customStatement(
    'CREATE INDEX IF NOT EXISTS idx_transactions_ledger_happened '
    'ON transactions(ledger_id, happened_at DESC)'
  );
  ```

#### 5.1.2 长列表缺 RepaintBoundary

- **现状**：交易列表、图表组件（`CategoryPieChart` 等）未使用 `RepaintBoundary` 包裹
- **影响**：长列表滚动时可能引发不必要的重绘
- **建议修复**：在 [transaction_list.dart](file:///d:/DevTools/project/PiggyCount/lib/widgets/biz/transaction_list.dart) 的 item 构建器外层加 `RepaintBoundary`

#### 5.1.3 WAL 模式未显式声明

- **现状**：项目代码中**没有**显式 `PRAGMA journal_mode=WAL` 配置
- **影响**：不同平台/版本默认值可能不同
- **建议修复**：在 `DatabaseConnection.delayed` 配置中显式执行 `PRAGMA journal_mode=WAL;`

#### 5.1.4 列表 Key 拼接 index

**问题位置**：[lib/widgets/biz/transaction_list.dart](file:///d:/DevTools/project/PiggyCount/lib/widgets/biz/transaction_list.dart)

- **现状**：`Key('tx-${it.t.id}-$index')` 拼接了 index
- **影响**：列表排序变化时失去复用意义
- **建议修复**：改为纯 `ValueKey(it.t.id)`

### 5.2 同步引擎潜在风险

#### 5.2.1 LWW 冲突解决可能丢数据

**问题位置**：[lib/cloud/sync/sync_conflict_resolver.dart](file:///d:/DevTools/project/PiggyCount/lib/cloud/sync/sync_conflict_resolver.dart)

- **现状**：使用 Last-Write-Wins（最后写入胜出）策略
- **风险**：两台设备同时修改同一笔交易，后同步的覆盖先同步的，无合并机制
- **建议修复**：
  1. 关键字段（金额、备注）提供字段级合并
  2. 冲突时记录到 `sync_conflicts` 表，提供 UI 让用户选择保留版本

#### 5.2.2 sync_pull_errors 表隔离设计风险

**问题位置**：[lib/data/db.dart](file:///d:/DevTools/project/PiggyCount/lib/data/db.dart) `SyncPullErrors` 表

- **现状**：失败的 pull 变更记录到独立表，不影响主表
- **风险**：用户可能不知道有同步失败的记录，长期累积造成数据不一致
- **建议修复**：
  1. UI 层显示同步失败计数（在设置 → 云服务页面）
  2. 提供"重试同步失败项"按钮
  3. 失败超过 7 天的记录提供导出/查看

### 5.3 测试覆盖不足

#### 5.3.1 集成测试用例少

- **现状**：`integration_test/` 目录下用例数量有限
- **建议补充**：
  1. 首次启动 → 创建账本 → 添加交易 → 重启验证数据持久化
  2. 离线添加交易 → 联网 → 验证同步成功
  3. 共享账本加入流程
  4. CSV 导入导出全流程
  5. 多账本切换上下文隔离

#### 5.3.2 无测试覆盖率工具

- **现状**：未集成 `lcov` / `genhtml` 等覆盖率工具
- **建议修复**：
  1. 在 CI 中添加 `flutter test --coverage`
  2. 上传至 [codecov.io](https://codecov.io) 或类似服务
  3. 设定覆盖率阈值（如 70%），低于阈值的 PR 阻止合并

### 5.4 凭证存储改进

#### 5.4.1 全部凭证明文存储

**问题位置**：[lib/services/export/config_export_service.dart:1262-1305](file:///d:/DevTools/project/PiggyCount/lib/services/export/config_export_service.dart)

| SharedPreferences 键 | 内容 | 风险 |
|---|---|---|
| `cloud_supabase_cfg` | URL+anonKey+email+明文 password | 极高 |
| `cloud_webdav_cfg` | URL+username+明文 password | 极高 |
| `cloud_s3_cfg` | endpoint+accessKey+明文 secretKey | 极高 |
| `cloud_piggycount_cloud_cfg` | baseUrl+email+明文 password | 极高 |
| PiggyCount Cloud `_sessionStorageKey` | access_token + refresh_token JSON | 极高 |
| `ai_glm_api_key` / 自定义 provider apiKey | 明文 API Key | 高 |

- **建议修复**：全部迁移到 flutter_secure_storage

#### 5.4.2 配置导出可能泄露凭证

- **现状**：[config_export_service.dart](file:///d:/DevTools/project/PiggyCount/lib/services/export/config_export_service.dart) 导出配置时可能包含明文凭证
- **建议修复**：
  1. 默认导出时移除所有敏感字段
  2. 提供"包含凭证（不推荐）"选项，需用户二次确认
  3. 导出文件可选 AES 加密

---

## 6. 低优先级问题（P3）

### 6.1 代码质量

#### 6.1.1 文件过长

- **现状**：部分文件超过 1000 行（如 [annual_report_page.dart](file:///d:/DevTools/project/PiggyCount/lib/pages/report/annual_report_page.dart)、`piggycount_cloud_provider.dart`、[sync_engine.dart](file:///d:/DevTools/project/PiggyCount/lib/cloud/sync/sync_engine.dart)）
- **建议修复**：按职责拆分为多个文件，单文件控制在 500 行内

#### 6.1.2 TODO/FIXME 标记

- **现状**：项目内 `TODO` / `FIXME` 标记较少（仅 2 处），但可能存在未标记的技术债
- **位置**：
  - [lib/providers/sync_providers.dart](file:///d:/DevTools/project/PiggyCount/lib/providers/sync_providers.dart)
  - [lib/widgets/biz/product_promo_card.dart](file:///d:/DevTools/project/PiggyCount/lib/widgets/biz/product_promo_card.dart)
- **建议修复**：清理所有 TODO，或转换为 GitHub Issue 跟踪

#### 6.1.3 dependency_overrides 钉死版本

**问题位置**：[pubspec.yaml](file:///d:/DevTools/project/PiggyCount/pubspec.yaml) `dependency_overrides`

```yaml
dependency_overrides:
  record_platform_interface: 1.2.0
  image_cropper_platform_interface: 7.1.0
```

- **现状**：为修复 record_linux / image_cropper 兼容性钉死版本
- **风险**：长期不更新可能错过安全修复
- **建议修复**：跟踪上游 issue，待官方修复后移除 override

### 6.2 文档与代码不一致

#### 6.2.1 docs/contributing/CONTRIBUTING_ZH.md 项目结构过时

**问题位置**：[docs/contributing/CONTRIBUTING_ZH.md:307-328](file:///d:/DevTools/project/PiggyCount/docs/contributing/CONTRIBUTING_ZH.md)

```markdown
lib/
├── data/              # 数据层
│   ├── db.dart       # 数据库定义
│   ├── models/       # 数据模型
│   └── repository.dart # 数据仓库   ← 实际是 repositories/
├── pages/            # UI 页面
│   ├── home/         # 首页           ← 实际是 main/
│   ├── charts/       # 图表页          ← 实际在 widgets/charts/
│   ├── ledgers/      # 账本页          ← 实际是 main/ledgers_page_new.dart
│   └── mine/         # 个人中心        ← 实际是 main/mine_page.dart
├── cloud/            # 云服务
│   ├── supabase_auth.dart     ← 文件不存在
│   └── supabase_sync.dart     ← 文件不存在
```

- **建议修复**：更新为实际目录结构，参考 [15-development-guidelines.md](file:///d:/DevTools/project/PiggyCount/docoments/15-development-guidelines.md) 第 5 节

#### 6.2.2 PRIVACY.md 联系方式未填写

**问题位置**：[PRIVACY.md:146](file:///d:/DevTools/project/PiggyCount/PRIVACY.md)

```markdown
- **Email**: (Add your email if you want, or remove this section)
```

- **建议修复**：填写实际邮箱（如 sunxiaoyes@outlook.com）或删除该字段

### 6.3 平台兼容性

#### 6.3.1 鸿蒙版本已停止更新

- **现状**：[README.md:55](file:///d:/DevTools/project/PiggyCount/README.md) 标注 `piggycount-openharmony` 仓库已停止更新
- **影响**：鸿蒙用户无法使用最新版本
- **建议**：明确告知用户，引导至 Android 版本

#### 6.3.2 iOS 不支持应用内 OTA 更新

- **现状**：iOS 版本无应用内更新入口（App Store 政策限制）
- **影响**：iOS 用户必须通过 App Store 更新
- **建议**：在设置 → 关于 中显示"请通过 App Store 更新"

#### 6.3.3 Web 平台未原生支持

- **现状**：PiggyCount 本身无 Web 端，Web 端由 PiggyCount Cloud 独立项目提供
- **建议**：在文档中明确说明

### 6.4 国际化不完整

#### 6.4.1 韩语社区维护

- **现状**：[lib/l10n/app_ko.arb](file:///d:/DevTools/project/PiggyCount/lib/l10n/app_ko.arb) 由社区贡献
- **风险**：可能存在翻译滞后、错误未及时修复
- **建议**：
  1. 在 CI 中添加 .arb 文件 key 一致性检查
  2. 标记未翻译的 key（fallback 到英文）

#### 6.4.2 阿拉伯语/希伯来语 RTL 支持

- **现状**：未支持 RTL 布局
- **影响**：中东地区用户体验差
- **建议**：长期规划支持 RTL

### 6.5 依赖管理

#### 6.5.1 Flutter SDK 版本锁死

- **现状**：CI 中使用 Flutter 3.27.3
- **风险**：长期不升级错过新特性、安全修复
- **建议**：定期升级，参考 [13-build-release.md](file:///d:/DevTools/project/PiggyCount/docoments/13-build-release.md)

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
| 无 Web 端原生 | 由 PiggyCount Cloud 独立项目提供 | 用户需部署 Cloud |

### 7.2 已知技术债

- **本地化字符串重复**：部分 .arb 文件存在重复 key
- **ThemeData 重复构建**：暗黑模式切换时可能重建多次
- **Provider 嵌套过深**：部分页面 `ProviderScope` override 较多

---

## 8. 改进路线建议

### 8.1 短期（1-2 个版本）

1. 🔴 修订 PRIVACY.md，删除"Android Keystore"与"MIT License"错误声明
2. 🔴 引入 flutter_secure_storage，迁移所有敏感凭证
3. 🟠 启用 Android FLAG_SECURE 截屏保护
4. 🟠 PIN 码添加失败次数限制
5. 🟠 用户自配置 URL 强制 HTTPS 校验

### 8.2 中期（季度规划）

1. 🟠 引入 sqlcipher 加密本地数据库
2. 🟠 AI 调用前敏感数据脱敏
3. 🟡 transactions 表添加 `(ledger_id, happened_at)` 复合索引
4. 🟡 长列表添加 RepaintBoundary
5. 🟡 补充集成测试用例
6. 🟡 CI 集成测试覆盖率工具

### 8.3 长期（年度规划）

1. 🟢 关键服务证书锁定
2. 🟢 同步冲突字段级合并
3. 🟢 大文件拆分（annual_report_page、sync_engine 等）
4. 🟢 文档与代码同步检查机制
5. 🟢 多语言 .arb 一致性 CI 检查

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
4. **截图/日志**：日志可在 设置 → 日志中心 查看（参考 [14-logging.md](file:///d:/DevTools/project/PiggyCount/docoments/14-logging.md)）

---

## 10. 信息缺口

- **[待确认]** 部分问题来自代码静态审查，可能存在理解偏差，修复前需再次确认
- **[待补充]** 性能基准测试数据（首屏加载时间、滚动 fps、同步耗时）未在项目内找到，建议建立性能基准
- **[待补充]** 用户反馈的高频 Bug 统计未在工程文档中体现，建议定期从 GitHub Issues 提取并更新本文档
- **[推断]** 同步引擎在弱网/断网恢复场景的具体行为可能存在边界 case，建议补充集成测试覆盖

---

本文档随版本迭代持续更新，新发现的问题请通过 PR 补充至对应优先级章节。
