# SQLCipher 整库加密 —— 设计文档

> 与 `requirements.md` 配套。**本文件不动代码**，只给技术决策、落点与取舍。
> 所有 file:line 与包版本都是 2026-10-05 在本工作区/Pub 缓存里**实读**的；
> 引用前请复核（行号会漂）。

## 一、现状（实读证据）

| 事实 | 证据 |
|---|---|
| drift 版本 | `pubspec.lock` → **drift 2.35.0** / drift_dev 2.35.0（`pubspec.yaml` 声明 `^2.20.2`） |
| sqlite3 版本 | `pubspec.lock` → **sqlite3 3.5.2**、`sqlite3_flutter_libs 0.5.42` |
| 生产连接 | `lib/data/db.dart:2031-2054` `_openConnection()` → `NativeDatabase.createInBackground(file)`（`:2052`，跑在**第二个 isolate**） |
| 连接级 PRAGMA | `lib/data/db.dart:702-721` `migration.beforeOpen`（WAL + `journal_size_limit`；注释称 `NativeDatabase(file, setup:)` 与 `createInBackground` **互斥**） |
| 健康探测 | `lib/data/database_health_service.dart:53-...`：**只读连接**在后台 isolate 里跑 `PRAGMA quick_check`（`_probeOffMain`），不用 `PiggyDatabase` |
| 库文件 | `piggycount.sqlite`（`db.dart:2034`、`database_health_service.dart:54`），旁路 `-wal`/`-shm`（`database_health_service.dart:57`） |
| 应用侧密钥设施 | `lib/data/encryption/`（E2EE AES-GCM/Argon2）、`lib/services/system/app_lock_service.dart`（PIN Argon2id 哈希）——**已有 secure storage 使用先例** |
| `hooks` 现状 | `pubspec.yaml:128-131`：`hooks.user_defines.sqlite3.source: system`（**AGENTS 明说不要删**：否则构建期去 GitHub 下预编译 libsqlite3，国内网络直接失败） |
| `pubspec.lock` 状态 | 当前**不含**镜像地址（`flutter-io.cn` 出现 0 次），CI 的「镜像守卫」是绿的；改依赖后必须复查此点 |

### 关键发现：drift 原生支持 SQLCipher 密钥落点

`drift-2.35.0/lib/native.dart:25-30`（实读）：

```dart
/// Signature of a function that can perform setup work on a [database] before
/// drift is fully ready.
///
/// This could be used to, for instance, set encryption keys for SQLCipher
/// implementations.
typedef DatabaseSetup = void Function(Database database);
```

`:157-177` 的 `createInBackground` **有 `setup` 形参**（还有 `isolateSetup` / `sqlite3` / `readPool`）：

```dart
static QueryExecutor createInBackground(File file, {
  bool logStatements = false,
  bool cachePreparedStatements = _cacheStatementsByDefault,
  DatabaseSetup? setup,        // ← 这里
  SqliteResolver sqlite3 = _NativeDelegate._defaultResolver,
  bool enableMigrations = true,
  IsolateSetup? isolateSetup,
  int readPool = _defaultReadPoolSize,
})
```

并且文档明说：`setup` / `isolateSetup` / `sqlite3` **都在后台 isolate 里执行**，
且 `readPool` 的每个读 isolate 也会拿到 `setup`（`:152-156`、`:202-212`）。

> **修正既有注释**：`db.dart:707` 写的「`NativeDatabase(file, setup:)` 与
> `createInBackground` 互斥」在 drift 2.35.0 **不成立** —— 官方 API 里两者是同一个
> 工厂的形参与实现关系。M18 当初因此把 PRAGMA 全塞进 `beforeOpen`，结论对
> （`beforeOpen` 也确实每条连接都跑），但**依据要更正**；SQLCipher 的 key 应当放
> `setup`（它在 drift 完全就绪之前执行，正是密钥该待的位置）。

## 二、选型：加密 native 库从哪来（本设计的核心矛盾）

`sqlite3` 3.x 已**内置**加密构建的支持。`sqlite3-3.5.2/lib/src/hook/compile/description.dart:29-43`（实读）：

```dart
switch (userDefines['source']) {
  case null:
  case 'sqlite3':     return fromGitHub(LibraryType.sqlite3);
  case 'sqlite3mc':   return fromGitHub(LibraryType.sqlite3mc);
  case 'sqlcipher':   return fromGitHub(LibraryType.sqlcipher);
  case 'test-sqlite3': ... case 'test-sqlcipher': ...
  case 'system':      return LookupSystem((userDefines['name_$os'] ?? userDefines['name'] ?? 'sqlite3'));
  ...
}
```

`sqlite3-3.5.2/doc/hook.md`（实读原文要点）：

- 每个平台有 **三套** 预编译二进制：上游 SQLite / **SQLite3MultipleCiphers** / **SQLCipher 社区版**；
  选择方式是 `hooks.user_defines.sqlite3.source: sqlite3mc`（默认 `sqlite3`），
  **`sqlcipher` 也可选**；还提供 `test-sqlite3mc` / `test-sqlcipher`。
- ⚠️ 同一份文档明确：SQLite3MC / SQLCipher **有各自许可**，且 SQLCipher 构建在
  Windows/Linux/Android **链接 OpenSSL**。
- `source: system` 支持 **`name`**：`name: sqlcipher` 会去找 `libsqlcipher.so` /
  `libsqlcipher.dylib` / `sqlcipher.dll`；也可用 `name_$os` 分平台。
- 需要内网制品库时可用 **`url_pattern`** 覆盖下载地址。

### 三条可选路径

| 路径 | 做法 | 优点 | 代价 / 风险 |
|---|---|---|---|
| **A. hook + `source: sqlcipher`** | 改 `hooks.user_defines.sqlite3.source: sqlcipher` | 官方支持、零自研构建、Dart 侧代码不用动 | **构建期从 GitHub releases 下预编译资产** → 正是 AGENTS 记录过的「国内网络直接失败」；加密版 SQLite 可能落后上游；许可/OpenSSL 待复核 |
| **B. hook + `source: sqlite3mc`** | 同上，选 SQLite3MultipleCiphers | 多算法（ChaCha20/AES 等）、社区活跃、同样零自研 | 同 A 的下载与许可问题；API/限制与 SQLCipher 略不同 |
| **C. 自带 native 库 + `source: system, name: sqlcipher`** | 各平台由 Gradle/CocoaPods 打包 `libsqlcipher`（如借助平台依赖），Dart 侧沿用 `source: system` | **不碰构建期网络**，与现有 `source: system` 约束天然兼容 | 要自己维护各平台 native 依赖与版本；iOS/Android 打包细节多 |

**被排除的路径 D**：`sqlcipher_flutter_libs`。镜像上它最后一个版本是
**`0.7.0+eol`**，其 pubspec 描述原文为 **"Not used anymore, update to version 3.x of
package:sqlite3 instead"** —— 作者已明确弃用，改推 `sqlite3` 3.x 的 hook 方案
（即 A/B）。若确要用它，只能钉 `0.6.8`（非 EOL，env `sdk >=2.12`、`flutter >=1.10.1`），
并承担「用废弃插件 + 与 sqlite3 3.x 并存两份 native 库」的风险。

**定案（2026-10-05 修订）**：改走 **A —— `hooks.user_defines.sqlite3.source: sqlcipher`**。
先前倾向 C 的唯一理由是"躲开构建期 GitHub 下载"，但实测该理由不成立：

- `sqlite3-3.5.2` 的 GitHub release 有 **53 个资产**，含
  `libsqlcipher.{arm,arm64,ia32,x64}.android.so`、**`libsqlcipher.arm64.ios.dylib`**、
  `libsqlcipher.arm64.{macos.dylib,linux.so}`、`sqlcipher.{x64,ia32,arm64}.windows.dll`
  —— **iOS 也有独立 dylib**，于是 C 的"iOS 静态链接 vs `dlopen`"难题（以及 `source`
  只能取单值 define 的分平台困境）**自动消失**；
- 构建期网络在本机可达（`github.com` 200），CI（GitHub Actions）本身跑在 GitHub 上，
  所以 A 的失败面只剩"**无法访问 GitHub 的本地开发机**"。

**A 的代价与缓解**：不可访问 GitHub 的环境用 **`url_pattern`** 指向内部制品源；或临时
改回 `source: system`（此时整库加密不可用、降级为明文库，app 仍能跑）。已同步改
`pubspec.yaml` 的 hook 与注释（把该取舍写在注释里，免得下个会话又"修"回去）。

**许可闸门（不变）**：SQLCipher / SQLite3MultipleCiphers 各有许可、SQLCipher 构建在
Windows/Linux/Android 链接 OpenSSL。**代码可在"密钥缺省即不加密"的前提下先落，但不得
默认启用**；启用（= 对外承诺整库加密）前需项目所有者 / 法务给结论。
若法务更认可 **MIT 且不链 OpenSSL** 的方案，一行改成 `source: sqlite3mc`
（SQLite3MultipleCiphers，同样支持 SQLCipher 方案），本设计其余部分不变。

## 三、连接层落点

### 3.1 密钥的生成与保存

新增 `lib/data/encryption/database_key_service.dart`：

- 首次启用时生成 **32 字节随机密钥**（`Random.secure()`），以 **hex** 形式存
  `flutter_secure_storage`（Android Keystore / iOS Keychain；与 `secure_key_storage.dart`
  同一后端）。
- 连接时用 SQLCipher 的 **raw key** 语法绕开 KDF：`PRAGMA key = "x'<64位hex>'"`。
  （**待验证项**：所选构建对 raw key 语法的支持，见 §7。）
- 密钥**只**在连接建立的 `setup` 里出现，绝不进日志/异常/导出（`requirements.md` §三.4）。

### 3.2 把 key 交给每条连接

`lib/data/db.dart` 的 `_openConnection()` 改为：

```dart
final key = await DatabaseKeyService.instance.loadKey();  // 无则 null（未启用）
return NativeDatabase.createInBackground(
  file,
  setup: (raw) {
    if (key != null) raw.execute("PRAGMA key = \"x'$key'\"");   // 必须最先
    // 其余连接级 PRAGMA（WAL / journal_size_limit）继续留在 beforeOpen，
    // 那里每条连接也会跑，语义不变（M18 的既有结论）。
  },
);
```

要点：

- `setup` 在 **open 之后、drift 就绪之前**执行（drift 文档原话），是 key 的正确位置；
- `setup` 会被**发送到后台 isolate**，因此**不能闭包捕获不可跨 isolate 的对象**——
  只传 `String key`（drift 文档 `:152-156` 明确警告）；
- `readPool > 0` 时每个读 isolate 同样执行 `setup`（当前 `readPool` 未启用，保持默认）。

## 四、影响面：必须先堵的三个坑

1. **健康探测会误报「库损坏」（最危险）**
   `lib/data/database_health_service.dart` 的只读探测**不使用 drift**，直接开库跑
   `PRAGMA quick_check`。加密库上不先 `PRAGMA key`，SQLite 会报「file is not a database」
   → 现有判定链路会落到 `DbHealth.unreadable`（`:109-115`）→ 弹出「数据可能已损坏」
   并可能引导用户**隔离/重建一个其实健康的库**。
   **必须**：探测连接在开库后立即注入同一 key；并补一条「加密库 → 返回 ok」的测试。

2. **性能基线脚本失效**
   `docs/evidence/mem-baseline-2026-09-19.md` 的五步流程（adb 拉库 → `seed_mem_baseline.py`
   灌语料 → 推回）用的是**裸 sqlite3**。加密后拉下来的是密文，脚本打不开。
   **处理**：该流程文档写明「只在未加密构建上跑」，或让脚本接受 `--key`。

3. **「清除全部数据」要连密钥一起清**
   `AppLockService.wipeAllData` 已删库文件与安全存储；加密后**密钥也必须删**，
   否则会留下一个「无法打开、且用户以为已清空」的孤儿密钥，或反之留下可解的新库。

其余核对（**不受影响**，但要在实现期回归验证）：

- `lib/cloud/backup/cloud_backup_service.dart`、`lib/services/attachment_export_import_service.dart`
  都是通过**应用连接**读写业务数据（不是拷贝 `.db` 文件）→ 加密对它们透明；
- 全仓**没有**「只复制主 `.db` 文件」的代码（AGENTS 已记录，WAL 检查点相关），
  加密不引入新风险；
- drift 的 `beforeOpen`（WAL 等）与 `setup` 共存，互不覆盖。

## 五、迁移：明文 ⇄ 密文

### 5.1 启用（明文 → 密文，一次性、幂等、可回退）

> **已实测（2026-10-05）**：`PRAGMA rekey` **不能**给明文库加密 —— 引擎直接拒绝并指路：
> *"PRAGMA rekey can only be run on an existing encrypted database. **Use
> sqlcipher_export() and ATTACH to convert** encrypted/plaintext databases."*
> 因此设计稿先前"rekey 为首选"的假设**作废**；`rekey` 的正当用途是**已加密库换钥**
> （钥匙轮换，实测可用）。证据：`test/data/db_encryption_sqlcipher_test.dart`。
>
> **明文 → 密文只能走 `ATTACH` + `sqlcipher_export()`**（同样已实测通过）：

明文 → 密文的标准做法是 `ATTACH` + `sqlcipher_export()`（**待验证**：所选构建是否提供该函数）：

1. 先 `wal_checkpoint(TRUNCATE)`（把 `-wal` 内容并回主文件，避免只搬主文件丢数据）；
2. 用**明文**打开老库，`ATTACH DATABASE '<db>.enc' AS enc KEY "x'<hex>'"`；
3. `SELECT sqlcipher_export('enc')`；`DETACH enc`；
4. `PRAGMA integrity_check` 校验新库；
5. **原子替换**：`piggycount.sqlite` → `piggycount.sqlite.pre-enc`，`.enc` → `piggycount.sqlite`，
   删除 `-wal`/`-shm`；写完**迁移完成标记**（secure storage 或 prefs）后再删 `.pre-enc`；
6. 任何一步失败 → 回滚（`.pre-enc` 复名回主文件），保持明文可用并提示。

幂等：以「迁移完成标记 + 库文件是否已加密（读前 16 字节头）」双条件判断；
中途崩溃重启后能继续或回滚（迁移在**临时文件**上做，主文件在最后一步才被替换）。

### 5.2 关闭（密文 → 明文）

对称：带 key 打开加密库 → `ATTACH '<db>.plain' AS plain KEY ''` → `sqlcipher_export('plain')`
→ 校验 → 原子替换 → **删除安全存储里的密钥**（并确认用户理解「关闭后落盘恢复明文」）。

> 关闭能力列在 R6；评审时也可决定**不提供**（只提供「重置为空库 + 从云端恢复」），
> 那样实现面更小。这是 §7 的待定项之一。

## 六、性能与验证计划

- **成本**：SQLCipher 对每页做 AES，读写吞吐与 CPU 上升，冷启动多一次 KDF（用 raw key
  可免 KDF）。**具体数字必须真机实测**（本项目当前只有模拟器/桌面）。
- **验证顺序**：先在**桌面/模拟器**把「落盘不可读 + 应用可读 + 迁移往返 + 健康探测」
  四条打通，再上真机跑 `scripts/profile_cold_start.py` / `profile_frames.py`
  与 `docs/evidence/perf-baseline-*.md`（对照本轮加固前的构建）。
- **不能省的负向验证**：去掉 `setup` 里的 `PRAGMA key` 后，新测试必须**变红**
  （证明门禁真的在守密钥，而不是恒绿）。

## 七、待定问题（逐条落定后才进入实现）

### 已定 / 已验证（2026-10-05）

- **native 库来源：A 试过 → 卡在 Android 打包，暂时回退 `source: system`**。
  实测（2026-10-05，在本机 Android 模拟器 + debug APK 上做的，证据逐条如下）：

  | 步骤 | 观察 |
  |---|---|
  | hook 解析 | ✅ 生效：`.dart_tool/flutter_build/<hash>/native_assets.json` 写着 `"android_x64": {"package:sqlite3/src/ffi/libsqlite3.g.dart": ["absolute","libsqlcipher.so"]}`，hook 也真的下载了 3 个 ABI 的 `libsqlcipher.so` 与 `sqlcipher.dll` |
  | APK 产物（保留 `sqlite3_flutter_libs`） | ❌ 只有 `lib/x86_64/libsqlite3.so`（1.55MB，二进制内**没有** `sqlcipher`/`cipher_export` 字样）→ 是插件的**上游** SQLite；APK 内无任何 `cipher` 条目 |
  | 设备侧 | ❌ `run-as … find` 全应用数据域无 `libsqlcipher.so`；`/data/data/<pkg>/lib` 不存在（`extractNativeLibs=false`） |
  | 移除 `sqlite3_flutter_libs` 后重建 | ❌ APK 的 `lib/x86_64/` 只剩 `libflutter.so`/`libdartjni.so` 等，**一个 SQLite 库都没有** → 应用起不来 |
  | 桌面单测（Windows） | ✅ hook 给的 `sqlcipher.dll` 是真 SQLCipher：落盘密文/raw key/`sqlcipher_export`/`rekey` 四条语义全部实测通过 |

  → 结论：**hook 的 native 资产没有被复制进 Android 产物**。因此 `source: sqlcipher`
  在 Windows 单测有效、在 Android **无效**；Android 上 `PRAGMA key` 会被当未知 pragma
  **静默忽略**（这正是"看起来加密、实际没加密"的最坏状态）。
  `pubspec.yaml` 已回退到 `source: system` 并**保留 `sqlite3_flutter_libs`**（它目前是
  Android 上唯一真正进 APK 的 SQLite 库），同时把上面这段取舍与证据写进 hook 注释。
- **加密代码与测试留在仓库里，靠运行时能力探测决定是否启用**：
  `test/support/sqlcipher_support.dart` 用 `PRAGMA cipher_version` 判断当前库是不是
  SQLCipher（普通 SQLite 返回空），不是就**带原因跳过** —— 在默认配置（`source: system`）
  下 19 例加密测试跳过、206 例照跑；把 hook 改成 `sqlcipher` 后它们会真正执行。
- **本机具备验证条件（先前判断有误，已更正）**：完整 Android SDK（build-tools / ndk /
  platforms / emulator / system-images）+ `java` + `adb`，`adb devices` 有**两个已连接设备**
  （`127.0.0.1:16384`、`:16416`），且 `github.com` 可达。→ Android 端可 build + 装机端到端验证；
  **iOS 仍无构建环境（无 macOS）**，真机性能数字仍欠。
- **已验证的引擎语义**（`test/data/db_encryption_sqlcipher_test.dart`，4 例）：
  ① 落盘非明文（文件头不是 `SQLite format 3`）、无 key / 错 key 打不开；
  ② raw key 语法 `PRAGMA key = "x'<hex>'"` 被接受（免 KDF）；
  ③ **明文 → 密文只能走 `ATTACH` + `sqlcipher_export()`** —— `PRAGMA rekey` 被引擎拒绝
  （原文指路 sqlcipher_export），设计稿原假设作废；④ `rekey` 的正当用途 = 已加密库**换钥**。
- **测试基座兼容性已实测**：换 native 库后全量 `flutter test` → **1821 通过 / 3 失败 / 1 skip**，
  失败的 3 个仍是既有 `entity_reference_guard_test.dart`（与本主题无关）。即
  **加密版 native 库可同时服务「明文内存库（测试）」与「加密文件库（生产）」** —— §7 原第 6 条
  的疑问就此关闭。
- **许可 = 上线闸门（不变）**：代码可在"密钥缺省即不加密"下先落，**不得默认启用**；
  启用前需项目所有者 / 法务结论。若法务偏好 MIT + 不链 OpenSSL，一行改 `source: sqlite3mc`。
- **已交付**：`lib/data/encryption/database_key_service.dart`（32B → 64 位 hex 进安全区；
  **不自动建钥**；存量损坏视为无密钥）+ 6 例测试 `test/data/database_key_service_test.dart`。
  **接线仍未动** —— 因为下面三件必须**一起**落（只注入 key 而库还是明文 = app 打不开自己的库）。

### 已落地（代码 + 测试；默认配置下休眠）

1. ✅ **连接层接线**：`db.dart` 的 `_openConnection` 在开库前 `prepareKeyForOpen`，并用
   `NativeDatabase.createInBackground(…, setup:)` 注入 `PRAGMA key`（密钥缺省 → 与加密前逐字一致）。
2. ✅ **迁移 bootstrap**：`DbEncryptionMigration`（明文→密文 `ATTACH` + `sqlcipher_export` +
   integrity 校验 + 原子替换 + 回退），并覆盖**三种中断态**（主库缺失 / 留底残留 / 临时库残留）；
   「`rekey` 不给明文库加密」这条边界也有守门断言。
3. ✅ **健康探测适配**：只读探测连接带同一把钥匙，且**只对非明文文件注入** —— 否则"用户刚开启
   加密、迁移还没跑"的那次启动会把健康的明文库误报成 `corrupted`（会诱导隔离数据）。
   测试：`db_encryption_migration_test.dart`（11 例）、`database_health_encrypted_test.dart`
   （6 例）、`db_encryption_sqlcipher_test.dart`（4 例）、`database_key_service_test.dart`（6 例）。

### 仍待做（按此顺序；第 1 条是当前的硬阻塞）

1. ✅ **Android 打包已解决并实测通过（走 C 路线）**。配方两条命令：
   ```bash
   python scripts/fetch_sqlcipher_android_libs.py   # 校验 sha256 后落到 jniLibs/<abi>/
   # 然后 pubspec.yaml：hooks.user_defines.sqlite3 加一行 name_android: sqlcipher
   ```
   - 原理：官方替代品 `sqlcipher_flutter_libs` **已 EOL**（`0.7.0+eol`），所以自备库；
     `source: system` 时 hook 会把 `name_$targetOS`（见 sqlite3 包
     `lib/src/hook/compile/description.dart:44-49`）交给 `LookupSystem`，Android 上即
     `dlopen('libsqlcipher.so')` —— 而该文件由 Gradle 从 `jniLibs/` 打进 APK。
   - 实测证据（Android 15 / x86_64 模拟器，debug APK）：
     APK 内 `lib/x86_64/libsqlcipher.so` = 5.67MB 且二进制含 `sqlcipher`/`cipher_export`；
     装机后运行态日志（SharedPreferences `app_logs`）为
     **`SQLite 引擎: SQLCipher 4.18.0 community (SQLite 3.53.4)`**。
   - 配套护栏：
     `test/data/sqlcipher_android_packaging_contract_test.dart` —— 一旦有人打开
     `name_android: sqlcipher` 却没带齐三个 ABI 的库就直接失败（那时应用**连 SQLite
     都加载不了**，起不来）；未启用时该测试恒真。
2. ✅ **端到端已在真机（Android 模拟器）跑通**，用的是
   `tool/db_encryption_device_probe.dart` 这个**非 UI 探针入口**：

   ```bash
   python scripts/fetch_sqlcipher_android_libs.py      # 取库（sha256 校验）
   # pubspec: hooks.user_defines.sqlite3 加 name_android: sqlcipher
   flutter build apk --debug -t tool/db_encryption_device_probe.dart
   adb install -r build/app/outputs/flutter-apk/app-x86_64-dev-debug.apk
   adb logcat -s flutter | Select-String DbProbe
   ```

   **为什么不用点开关**：本机模拟器是 MuMu（虚拟 GPU + Mesa/Vulkan），Flutter 画面在它上面
   出不来 —— 实测窗口/surface 都在、无锁屏、`topResumedActivity` 正常、Dart 日志齐全，但
   整屏纯黑且 `dumpsys gfxinfo` 只有 3 帧（试过关 Impeller 无效）。所以改成"跑生产代码 +
   打日志断言"，比点 UI 更强：它走的是同一个密钥层/迁移服务，且不依赖任何渲染。

   实测结果（2026-10-05，Android 15 / x86_64 / 真实 16.6MB 库、40008 笔）：

   | 检查点 | 观测 |
   |---|---|
   | 引擎 | `SQLCipher 4.18.0 community (SQLite 3.53.4)` |
   | 加密前文件头 | `53 51 4c 69 74 65 20 66 6f 72 6d 61 74 20 33 00`（明文 SQLite 头） |
   | 密钥落安全区 | `key stored: true (len=64)`（真 Keystore 路径） |
   | 迁移耗时 | 密文 **3726ms** / 解回明文 ~2330ms（16.6MB、40008 行）|
   | 加密后文件头 | `d6 f2 d2 d4 34 22 dd fc …` → **非明文**（验收 1）|
   | 持钥可读 | `sqlite_master=74 transactions=40008`（验收 2）|
   | 关闭（R6） | 密钥删除、文件头**回到明文**、行数不变（验收 6）|

   ⚠️ 探针自带安全网：动手前先复制一份 `<db>.probe-backup`，成功后删除；失败则**保留密钥**
  （宁可加密可用，也不留打不开的死库）。**探针跑完记得把现场恢复**：当年探针是在
  「临时启用」状态下跑的，跑完要摘掉 `name_android` 并删掉 `jniLibs`；但**自 2026-10-06 起
  本仓库已正式启用**（`name_android: sqlcipher` + 三 ABI 库入库），所以现在跑探针
  **不需要**再恢复 —— 恢复反而会把仓库打回"半启用"状态。
3. ✅ **制品决定已落定，并已正式启用（2026-10-06）** —— 选**入库**方案：
   - `android/app/src/main/jniLibs/{arm64-v8a,armeabi-v7a,x86_64}/libsqlcipher.so`
     已提交进仓库（合计 ~16.45MB）；`pubspec.yaml` 的
     `hooks.user_defines.sqlite3` 已打开 `name_android: sqlcipher`。
   - **为什么是入库而不是构建期拉取**：实测 `github.com/.../releases/download/...` 会
     302 到 `objects.githubusercontent.com`，**国内直连超时**（`WinError 10060`），
     脚本直接跑必然失败；入库换来「clone 即可构建」，与本项目一贯避免构建期外网
     下载的原则一致（同 `source: system` 的初衷）。
   - **取库脚本已配套更新**：`python scripts/fetch_sqlcipher_android_libs.py --mirror https://ghfast.top/`
     —— 随 `sqlite3 3.5.2 → 3.7.0` 更新了三个 sha256（旧值全部失效），并新增
     `--mirror` 参数（走镜像同样按包内 sha256 逐字节校验）。
   - **本次验证**：APK 内三个 ABI 均出现 `libsqlcipher.so`；真机（Android 15）启动正常、
     CloudSync 正常读库；`flutter analyze --fatal-infos` 0 issue、1842 测试全绿。
4. **iOS 构建**：无 macOS，留给 CI 首次跑通时验证（iOS 侧同样需要自带库）。
4. ✅ **R5 启动分流已落地**（采用判据②："曾启用"标记）。原先的坑：加密库 + 无密钥时
   探测返回 `unreadable`，而 `database_recovery_overlay` 对**非 ok** 就弹「数据可能
   已损坏」并给出隔离入口 —— 那等于诱导用户把**唯一可能被解开**的密文搬走。现在：
   - `DbHealth.keyUnavailable` 新枚举值：**非明文 + 无密钥 + 本机曾启用过加密** →
     直接判「密钥不可得」（连探测都不做，避免得到 `file is not a database` 那句
     会被误读成损坏的话）；
   - 弹窗按该状态换标题/正文/重置确认文案，并把「导出**损坏**文件」改成
     「导出**加密**文件（留存）」—— 文件没坏，说"损坏"会让用户以为拿到的是废文件
     而**不留档**；
   - 判据为何必须带"曾启用"：单看"非明文 + 无密钥"与"文件根本不是库"在文件层面
     无法区分，而两者的正确出口**相反**（一个绝不能隔离、一个正需要隔离重置）。
     因此既有审计语义（垃圾文件 → `unreadable` → 隔离入口）原样保留。
   - 分层上的取舍：**开库路径**（`DbEncryptionMigration`）仍对"非明文 + 无钥"一律抛
     `DbEncryptionKeyMissingException`（带不带标记都抛）—— 那里只需要一个**可识别**
     的异常，而不是让 drift 抛"not a database"；"到底算缺钥还是算坏了"由健康探测
     决定，因为只有它会决定要不要给用户隔离出口。
   - 测试：健康探测 4 例 + 恢复弹窗 2 例 + 状态机 2 例（含"没启用过就不算 keyMissing"）。
5. **许可结论**仍待产品口径落定；开关 UI 已落地（见下）。
6. **验收对照（`requirements.md` §三）**：
   - 1（落盘非明文）/ 2（持钥可读）/ 6（关闭后回明文且再开启仍通过）→ 真机探针实测（见上表）；
   - 3（幂等 + 回退 + 中途崩溃收敛）→ `test/data/db_encryption_migration_test.dart`（含三种中断态）；
   - 4（密钥不进日志/异常/导出产物）→ 迁移与密钥层全程不打印密钥，`database_key_service_test.dart` 覆盖；
   - 5（清除数据仍可用）→ **由既有 `AppLockService.wipeAllData` 天然满足**：它删
     `piggycount.sqlite*` + `prefs.clear()`（连带"曾启用/待关闭"两个标记）+
     `_secure.deleteAll()`（连带数据库密钥）→ 清完重启得到**全新的明文空库**，
     不会留下"有标记无密钥"的错配；
   - 7（健康探测不误报）→ `database_health_encrypted_test.dart` + 上面第 4 条的 R5 分流；
   - 8（静态门禁）→ 每批出口跑 `flutter analyze`（均 0 issue）。
7. ✅ **开关 UI（R2/R6）已落地**：`LocalDbEncryptionSection`（挂在加密设置页顶部）
   + `LocalDbEncryptionService`（六态状态机：unsupported/disabled/pendingEnable/
   enabled/pendingDisable/keyMissing）+ `DbEncryptionSettings`（关闭意图，prefs）。
   语义要点：
   - 加密/解密都是**开库前的文件级迁移**，所以点完只登记，**重启后生效**，UI 如实
     显示 `pending*`，不假装已生效；
   - **关闭绝不先删钥**：先写意图 → 下次启动 `migrateEncryptedToPlaintext` → 明文
     复核通过 → 才删钥（顺序反了中途崩溃就丢数据）；
   - 关闭失败 → **回退到"保持加密可用"**（库完好、钥还在、清掉意图），比让应用打不开好；
   - 引擎不支持时开关禁用并如实说明；`keyMissing` 时禁用并给出「勿清除数据、用云端
     备份重建」。测试见 `test/data/local_db_encryption_service_test.dart`（10 例）与
     `db_encryption_migration_test.dart` 的「关闭加密（R6）」组（6 例）。

### 早期列过、现已作废的条目（保留以免重蹈）

- ~~`PRAGMA rekey` 作为首选迁移路径~~ → 已被实测否定（见 §5.1）。
- ~~选型 C（自带库 + `source: system`）~~ → 因 release 含 iOS dylib 而不必要（见 §2）。
- ~~本环境无法验证 native 栈~~ → 本机有 SDK + 模拟器 + GitHub 可达。

### 仍然有效的早期条目

- **打包**：Release 构建（Android AAB / iOS）要用同一 hook 跑通；`sqlite3_flutter_libs` 是否
  移除待定（它与 `libsqlcipher` 是不同 soname 的两个库，暂不冲突，只是多几 MB）。
- **兜底搬迁**：万一某平台资产缺失，改用「逐表 `SELECT` → 目标库 INSERT」的自实现搬迁
  （更慢但可控）。
- **CI 首次跑通**：GitHub Actions 能取资产（它本来就在 GitHub 上），但要在 release.yml 的
  构建产物上确认 native 库确实进了 APK/IPA。

### 产品口径待定（不阻塞代码，但阻塞"启用"）

8. **关闭加密**是否提供（R6），以及「重置为空库」还是「从云端恢复」作为密钥丢失的主出口。
9. **密钥备份**：是否提供「导出恢复密钥」（用户抄写）？会引入新的泄漏面，倾向**不做**，
   但要把「密钥丢失 = 本地数据不可读」在 UI 上写清楚。
