# PiggyCount 同步功能代码检查报告

> 审计范围：除 PiggyCount Cloud 增量引擎以外的全部同步相关代码
> 审计方式：分模块精读 + 行号交叉核验 + 关键缺陷实证（Dart 脚本）
> 审计约束：**只读，未修改任何源代码**
> 日期：2026-08-13

---

## 1. 检查范围说明

**纳入审计**（快照式同步后端 + 框架层 + 状态/触发/启动检查）：
- `lib/cloud/transactions_sync_manager.dart`（1470 行，快照同步主实现）
- `lib/cloud/transactions_json.dart`（导入导出序列化）
- `lib/cloud/sync_service.dart`、`sync_fingerprint.dart`、`startup_sync_checker.dart`、`startup_sync_overlay.dart`、`sync_diff_service.dart`
- `lib/providers/sync_providers.dart`（Riverpod 装配）
- `lib/services/billing/post_processor.dart`（自动同步触发）
- `lib/pages/cloud/cloud_sync_page.dart`、`sync_preview_dialog.dart`、`cloud_service_page.dart`（UI 层，非 Cloud 专属）
- `packages/flutter_cloud_sync/`（框架：provider / manager / core / config / utils）
- `packages/flutter_cloud_sync_{s3,webdav,icloud,supabase}/`

**明确排除**（用户指定）：
- `lib/cloud/sync/`（PiggyCount Cloud 增量引擎）、`packages/flutter_cloud_sync/lib/.../piggycount_cloud_provider.dart`、
  `lib/pages/cloud/piggycount_cloud_sync_page.dart`、共享账本相关页面。

**严重程度定义**：
- **P0**：数据丢失 / 安全泄漏（需紧急修复）
- **P1**：功能严重缺陷，导致同步失败或静默数据风险（高）
- **P2**：数据一致性 / 健壮性缺陷（中）
- **P3**：性能 / 健壮性改进建议（低）

---

## 2. 已确认问题清单

### P1 — 重要

#### P1-1 下载恢复时整账本硬覆盖，存在本地数据丢失风险
- **位置**：`lib/cloud/transactions_sync_manager.dart:514-521`（`downloadAndRestoreToCurrentLedger`）
- **类型**：数据完整性 / 危险操作
- **代码事实**：
  ```dart
  final deletedDup = await db.transaction(() async {
    final deleted = await _clearLedgerTransactions(ledgerId);   // 先清空本地全部交易
    return (deleted, await importTransactionsJson(repo, ledgerId, jsonStr));
  });
  ```
- **潜在影响**：从云端拉取快照恢复"当前账本"时，先清空本地全部交易再整体导入远端 JSON。事务仅保证"导入失败则回滚清空"，但**导入成功时若远端快照较旧 / 为空 / 不完整**，本地较新的编辑会被永久丢弃。由于是整账本全量替换（LWW 在账本粒度），这是快照同步的典型隐患，且对用户完全无提示。
- **改进建议**：
  1. 恢复前做差异比对，向用户展示"将用云端 N 条覆盖本地 M 条（其中 X 条本地较新）"的确认对话框；
  2. 至少先备份本地账本到临时表/本地快照文件，恢复失败可回退；
  3. 仅当远端指纹确实较新且用户确认后才执行清空。

#### P1-2 S3 带空格 prefix 的 list 操作签名 403（同步完全失败）
- **位置**：`packages/flutter_cloud_sync_s3/lib/src/s3_client.dart:550-562`（`_buildUri`）与 `s3_signature.dart:99-105`（`_createCanonicalRequest`）编码不一致
- **类型**：网络请求 / 签名错误
- **代码事实**：
  - 发送侧：`uri = uri.replace(queryParameters: queryParameters)` —— Dart 的 `Uri.replace` 将查询串空格编码为 **`+`**；
  - 签名侧：`Uri.encodeComponent(e.value)` —— 空格编码为 **`%20`**；
  - 二者不一致，S3 SigV4 校验签名时收到的查询串（`+`）与签名的（`%20`）不符 → **403 Forbidden**。
- **实证**：已用 Dart 脚本验证 `uri.replace(queryParameters:{'prefix':'my folder'})` 落网为 `my+folder`，而签名用 `Uri.encodeComponent` 为 `my%20folder`。
- **潜在影响**：任何包含空格的 `prefix`/`delimiter`/`continuation-token`（如 `My Ledger/sync.json`）的 `listObjects` 直接 403。list 是查找同步文件的基础操作，**会导致 S3 后端在含空格路径下完全无法同步**。
- **改进建议**：统一编码口径 —— 发送前将查询串中的 `+` 替换为 `%20`（或对 value 显式用 `Uri.encodeComponent` 构造查询串后拼接），确保发送串与签名串逐字节一致；补充带空格 key/prefix 的单元测试。

#### P1-3 启动检查网络异常被吞并，伪装成"已是最新"
- **位置**：`lib/cloud/startup_sync_checker.dart:290-294`（catch 仅 log+continue）→ 308-312 走到"无候选账本，全部都是最新"
- **类型**：错误处理 / 状态误报
- **代码事实**：
  ```dart
  } catch (e) {
    // 单账本 getStatus 失败不影响其他账本
    deps.log('StartupSyncChecker: 账本 ${ledger.name} ... getStatus 失败: $e');
  }
  checked++;
  ...
  if (candidates.isEmpty) {
    deps.log('StartupSyncChecker: 无候选账本，全部都是最新');
    controller.done(deps.getUpToDateMessage());   // 向用户显示"已是最新"
    return;
  }
  ```
- **潜在影响**：若 `getStatus` 因**网络中断 / 鉴权失败 / 超时**抛异常，该账本被静默剔除；当所有账本都因此失败时，UI 直接提示"已全部是最新"并自动消失。用户误以为同步完成，实际云端有更新却未拉取，且**无任何错误提示**——属于"静默失败"，危害高于显式报错。
- **改进建议**：
  1. 区分"确实 inSync"与"检查失败"：catch 中记录失败账本，若存在失败则在汇总页明确提示"N 个账本同步状态检查失败（网络/鉴权）"；
  2. 失败账本不应计入"已是最新"，应进入"需重试/手动检查"状态而非跳过。

#### P1-4 启动同步检查零超时，存在软死锁风险
- **位置**：`lib/cloud/startup_sync_checker.dart`（全文件 grep `timeout` 仅见 `Future.delayed(Duration.zero)` 让出线程，无任何网络超时守卫）
- **类型**：健壮性 / 可用性
- **潜在影响**：启动检查对每个账本串行调用 `getStatus`（含网络请求）。管理器层**没有总超时或单请求超时**。若某个后端（尤其 S3/WebDAV）连接挂起，启动覆盖层（overlay）可能长时间不消失甚至卡死，阻塞用户进入 App。
- **改进建议**：
  1. 为每个 `getStatus` 调用包裹 `timeout(const Duration(seconds: 20))`；
  2. 增加整体启动检查的总时限（如 45s），超时则降级为"后台重试"，先放行用户进入 App；
  3. overlay 提供"跳过并稍后同步"按钮。

---

### P2 — 中等

#### P2-1 内容指纹漏算关键字段，脏检测漏报
- **位置**：`lib/cloud/sync_fingerprint.dart:26-62`（`contentFingerprintFromMap`）
- **类型**：数据一致性 / 脏检测
- **代码事实**：指纹仅取白名单字段（`happenedAt/type/amount/categoryName/categoryKind/note/tags/tagSyncIds/override/accountNames`），**忽略** `excludeFromStats`、`excludeFromBudget`、`currencyCode`、`nativeAmount`，且**完全不遍历顶层** `categories`/`tags`/`accounts` 元数据（函数只迭代 `items`）。
- **潜在影响**：这些字段实际会被 `transactions_json.dart` 序列化进快照并参与同步；但指纹变化检测不会因它们改变而触发。后果：用户仅修改"不计入统计/预算"标记或币种/原币种金额后，自动同步的脏标记不翻转，**这些改动不会被自动推送**，只能靠手动全量上传才生效。两端可能因此长期不一致而无提示。
- **改进建议**：将 `excludeFromStats/excludeFromBudget/currencyCode/nativeAmount` 纳入指纹；顶层元数据变更也应参与指纹（或显式声明"顶层元数据不参与同步"并在文档中说明）。

#### P2-2 downloadRemoteLedger 同名账本复用未清空即追加导入
- **位置**：`lib/cloud/transactions_sync_manager.dart:1176-1239`（`reuseExistingByName` 分支 → 1239 `importTransactionsJson`）
- **类型**：行为不一致 / 潜在重复键
- **代码事实**：与 P1-1 不同，此路径在复用同名本地账本 ID 后**直接 `importTransactionsJson` 而不先 `_clearLedgerTransactions`**。
- **潜在影响**：把远端快照"追加"进一个已存在的本地账本。若 `importTransactionsJson` 为纯 insert 而非 upsert，遇到主键冲突会抛异常；即便 upsert，"下载远端账本到本账本"究竟是"合并"还是"替换"语义不清，与 P1-1 的"清空+导入"行为不一致，易引发用户困惑与重复数据。
- **改进建议**：明确该接口的语义（merge vs replace），在文档/注释中固定，并在 UI 上区分"合并到现有账本"与"覆盖现有账本"两种操作。

#### P2-3 恢复导入时 recordChanges 默认 true，误写变更历史
- **位置**：`lib/cloud/transactions_json.dart:490`（`recordChanges` 默认 `true`）
- **类型**：副作用 / 数据污染
- **潜在影响**：从云端恢复/导入交易时，若沿用默认 `recordChanges=true`，会把"恢复导入"动作本身记录为本地变更历史（如改动时间线、最近修改列表），污染用户的真实编辑轨迹，也可能再次触发"本地有改动"的脏标记。
- **改进建议**：恢复/导入路径应显式传 `recordChanges: false`。

#### P2-4 云凭据明文持久化（未加密 SharedPreferences）
- **位置**：`packages/flutter_cloud_sync/lib/src/config/cloud_service_store.dart`（全类）+ `cloud_service_config.dart:246`（`encodeCloudConfig = jsonEncode(c.toJson())`）
- **类型**：安全
- **代码事实**：`supabasePassword`、`webdavPassword`、`s3SecretKey`、`s3AccessKey`、`piggycountCloudPassword` 等以**明文 JSON** 存入 `SharedPreferences`，无加密（未使用 EncryptedSharedPreferences / Keychain 封装）。
- **潜在影响**：Android 上 SharedPreferences 默认未加密，设备 root / 备份提取 / 恶意应用可读；iOS 虽在沙箱但越狱/备份可提取。对记账类 App，云密码泄露意味着用户全部财务数据云端凭据暴露。
- **改进建议**：凭据字段使用平台安全存储（Android EncryptedSharedPreferences / iOS Keychain），或至少对 secret 字段做 envelope 加密后再落盘；`obfuscatedUrl()` 已做展示脱敏，但落盘仍需加密。

#### P2-5 _computeLocalUpdatedAt 用 happenedAt.max() 误代"最后更新时间"
- **位置**：`lib/cloud/transactions_sync_manager.dart:374-384`
- **类型**：同步方向判断精度
- **代码事实**：
  ```dart
  ..addColumns([db.transactions.happenedAt.max()])
  ... dbMax = row?.read(db.transactions.happenedAt.max());
  ```
- **潜在影响**："本地更新时间"取的是**交易发生日期的最大值**，而非数据最后修改时间。编辑一条历史交易（改金额/备注但不改 happenedAt）不会反映到该值；而预排的未来日期交易会把它"抬高"。用于 LWW/方向判定的启发式会因此偏误，可能错误判定"本地较新/较旧"。
- **改进建议**：维护真正的 `updatedAt` 列（或最后修改时间戳），用其 max 作为本地更新时间；或在导入/编辑时显式维护账本级 `lastModified`。

#### P2-6 count 强转无空安全，崩溃并被启动检查吞并
- **位置**：`lib/cloud/transactions_sync_manager.dart:699`
- **类型**：健壮性 / 错误放大
- **代码事实**：`final localCount = (localMap['count'] as num).toInt();` —— 若 JSON 缺失 `count` 或值为 `null`，`as num` 抛 `CastError`。
- **潜在影响**：该异常发生在 `getStatus` 指纹计算内，会被 P1-3 的 catch 静默吞掉 → 账本被误判为"已是最新"。旧版本导出 / 格式不完全兼容时极易触发，表现为"永远不提示有更新"。
- **改进建议**：`final localCount = (localMap['count'] as num?)?.toInt() ?? 0;`，并对导出结构做版本/字段兼容校验。

#### P2-7 WebDAV HTTPS 未强制，Basic Auth 明文传输风险
- **位置**：`packages/flutter_cloud_sync_webdav/lib/src/webdav_provider.dart:60-78`（接受任意 `url`，含 `http://`）
- **类型**：安全 / 传输
- **潜在影响**：WebDAV 使用 HTTP Basic Auth，凭据以 Base64（可逆）随每个请求发送。若用户配置 `http://` 地址，密码在链路上明文裸奔，且易遭中间人劫持。
- **改进建议**：强制 `https://`（或在 UI 层对 `http://` 显式二次确认并醒目警告）；`webdav.newClient(..., debug:false)` 当前已关闭调试日志，但错误回显 `throw CloudConfigurationException('Failed to initialize WebDAV: $e', e)` 中的 `$e` 需确认不含凭据，建议对错误串做脱敏后再回显。

#### P2-8【框架层·非激活路径】Supabase batchDelete 缺 user_id 过滤（跨用户越权删除）
- **位置**：`packages/flutter_cloud_sync_supabase/lib/src/supabase_database_service.dart:326-351`
- **类型**：安全 / 越权
- **代码事实**：`delete()`（107-138）与 `update()`（70-104）都在 `autoFilterByUser` 下追加 `eq('user_id', user.id)`，而 `batchDelete` **无任何 user_id 过滤**，仅按入参 `filters` 删除。
- **激活状态**：经 grep，`SupabaseDatabaseService` / `batchDelete` 在 `lib/` 中**无任何调用**（仅框架内定义与 CHANGELOG 提及）；`lib/` 中唯一 `realtimeEvents` 引用位于被排除的 `lib/cloud/sync/`。即：当前快照同步走 Storage 而非 Database，**该缺陷不在激活路径上**，属框架潜伏风险。
- **潜在影响**：一旦该数据库服务被启用且 `batchDelete` 的 filters 未自行包含 `user_id`，将删除**所有用户**的匹配行，构成跨用户数据破坏。
- **改进建议**：为 `batchDelete` 增加 `autoFilterByUser`（默认 true）并强制追加 `eq('user_id', user.id)`，与 `delete`/`update` 保持一致。

#### P2-9【框架层】retry_helper 对"文件不存在"仍重试
- **位置**：`packages/flutter_cloud_sync/lib/src/utils/retry_helper.dart:215`
- **类型**：性能 / 重试策略
- **代码事实**：`_shouldRetry` 对**任意** `CloudStorageException` 返回 `true`，而 `CloudFileNotFoundException` 是其子类（404/不存在）。
- **潜在影响**：对确定性的"文件不存在"错误仍按重试上限反复请求，浪费网络往返并延迟失败反馈。
- **改进建议**：在 `_shouldRetry` 中显式 `if (exception is CloudFileNotFoundException) return false;`（重试框架已定义该子类却未使用，属设计遗漏）。

---

### P3 — 建议

| 编号 | 位置 | 类型 | 建议 |
|---|---|---|---|
| P3-1 | `sync_fingerprint.dart:48` | 精度 | `amount` 以字符串排序（`'100.0'` vs `'20.0'` 字典序错误）；建议按数值排序或补齐小数位后排序 |
| P3-2 | `packages/flutter_cloud_sync/lib/src/core/exceptions.dart` | 可观测性 | 异常类未保存 `StackTrace`，排障困难；建议在构造时捕获并保留 `stackTrace` |
| P3-3 | `retry_helper.dart` | 退避 | 重试无指数退避 / jitter，高并发下易对后端造成重试风暴；建议加入 |
| P3-4 | `supabase_realtime_service.dart` / `icloud` 等 | 资源 | 部分 `StreamController`/channel 需确认在 provider dispose 时被关闭，避免泄漏（realtime service 自身已 `dispose`，但调用方需配对） |
| P3-5 | 冲突策略 | 一致性 | 当前仅 LWW，无冲突 UI / 三方合并；对双端并发编辑建议至少提供"选择保留哪侧"的界面 |
| P3-6 | `startup_sync_checker.dart` / `getStatus` | 性能 | 逐账本串行 `getStatus` + 串行 `exportTransactionsJson`，多账本用户启动慢；可考虑并行 + 增量指纹缓存 |

---

## 3. 已排除 / 未复现的初报项（避免误报）

经逐条复核源码，以下初报项**不成立或不在本次审计的激活路径上**，已从报告中剔除：

1. **iCloud 元数据写入竞态**：`ICloudStorageService.upload`（`icloud_storage_service.dart:50-67`）经 `ICloudMethodChannel.uploadFile`（`icloud_method_channel.dart:45-55`）**将 data 与 metadata 打包为同一次 method call** 发送，Dart 层不存在"先写文件后写元数据"的竞态窗口；若存在竞态仅可能在原生 iOS 侧，超出本次 Dart 层审计范围。
2. **Supabase Realtime 回声 / 重复订阅**：`SupabaseRealtimeService` 当前**未被快照同步路径调用**（其唯一 `lib/` 引用位于被排除的 `lib/cloud/sync/`）。且其 `channel()` 对已存在名称返回缓存、无重复订阅；`onPostgresChanges` 回调无自我回声回路。快照同步基于 Storage 文件而非 DB CDC，回声问题在激活路径上不成立。
3. **snapshotSyncCompletedProvider 为死信号**：初报称无写入。经 grep 确认 `lib/services/billing/post_processor.dart:130/174/218` 处 `syncDone.state++` 确有写入，属初报误判，已纠正。

---

## 4. 优先级修复建议（供参考）

1. **立即（P1）**：P1-2（S3 编码）、P1-3（错误吞并）、P1-4（超时）、P1-1（恢复确认）。
2. **近期（P2）**：P2-4（凭据加密）、P2-1（指纹字段）、P2-5/P2-6（updatedAt/count 健壮性）、P2-7（HTTPS 强制）。
3. **框架层**：P2-8、P2-9 修复后即使当前未激活也能避免未来启用时踩坑。

---

## 5. 修复记录（2026-08-13，第二次迭代）

上一轮为只读审计，本轮按用户要求"优化一下"已实际修复下列问题（未提交，待用户确认）：

| 编号 | 状态 | 改动文件 |
|---|---|---|
| P1-2 S3 查询串编码 | ✅ 已修复 | `packages/flutter_cloud_sync_s3/lib/src/s3_client.dart` `_buildUri`：改用 `Uri.encodeComponent` 手动构造查询串 + `uri.replace(query:)`，与签名侧逐字节一致；新增回归测试 `s3_client_test.dart`（带空格 prefix 断言 `%20` 非 `+`） |
| P1-3 启动检查错误吞并 | ✅ 已修复 | `lib/cloud/startup_sync_checker.dart`：候选收集循环记录 `failedLedgers`；全部失败时走 `controller.error(...)` 明确提示，不再误报"已是最新" |
| P1-4 启动检查零超时 | ✅ 已修复 | 同上：`getStatus` 加 20s 超时，`downloadAndPreview` / `downloadAndRestoreToCurrentLedger` / `applyPreviewChanges` 加 30s 超时，超时按失败账本处理 |
| P1-1 下载恢复空覆盖 | ✅ 已修复 | `lib/cloud/transactions_sync_manager.dart` `downloadAndRestoreToCurrentLedger`：远端快照无交易且本地非空时拒绝清空覆盖（日志 + 早退） |
| P2-1 指纹漏字段 | ✅ 已修复 | `lib/cloud/sync_fingerprint.dart`：指纹纳入 `excludeFromStats` / `excludeFromBudget` / `currencyCode` / `nativeAmount` |
| P2-3 恢复路径 recordChanges | ✅ 已修复 | `transactions_sync_manager.dart` 两处下载导入显式传 `recordChanges: false` |
| P2-6 count 空安全 | ✅ 已修复 | `transactions_sync_manager.dart:699` → `(localMap['count'] as num?)?.toInt() ?? 0` |
| P2-7 WebDAV HTTPS 强制 | ✅ 已修复 | `webdav_provider.dart`：`initialize` 拒绝非 `https`/`davs` 地址并给出明确错误 |
| P2-8 Supabase batchDelete 越权 | ✅ 已修复 | `supabase_database_service.dart` + 接口 `database_service.dart`：新增 `autoFilterByUser`（默认 true）并强制追加 `eq('user_id', ...)` |
| P2-9 retry 404 仍重试 | ✅ 已修复 | `retry_helper.dart`：`_shouldRetry` 显式排除 `CloudFileNotFoundException` |
| P3-1 金额字符串排序 | ✅ 已修复 | `sync_fingerprint.dart`：排序键 amount 改为数值比较 |
| P3-3 retry jitter | ✅ 已修复 | `retry_helper.dart`：重试等待加入 0~25% 随机 jitter |
| P2-4 凭据明文持久化 | ✅ 已修复 | `packages/flutter_cloud_sync/lib/src/config/cloud_service_store.dart`：含凭据配置迁移到 `flutter_secure_storage`（Android EncryptedSharedPreferences / iOS Keychain），保留 SharedPreferences 明文迁移与降级路径；框架包 pubspec 新增 `flutter_secure_storage: ^9.2.2` |
| P2-5 updatedAt 用 happenedAt.max 代替 | ⏸ 暂缓 | 需数据库 schema 变更（新增 `updatedAt` 列 + 迁移），风险较高，未在本轮实施 |
| P3-5 冲突 UI | ⏸ 暂缓 | 功能级改动（合并/保留选择界面），建议独立迭代 |

**验证结果**（本机执行）：
- `flutter analyze`：改动的 lib 与 4 个框架包全部 **No issues found**（仅存改动前既有的 info 级提示）
- 单测：`sync_fingerprint_test` 11/11 ✅、`startup_sync_checker_test` 38/38 ✅、`transactions_sync_manager_test` ✅（本机缺 sqlite3.dll，临时下载官方 DLL 后全过）、S3 包 26/26 ✅（含新增回归用例）、`retry_helper_test` 19/19 ✅

> 注：本机 `flutter test` 跑 drift native 用例需要 `sqlite3.dll`（环境缺少，非代码问题）；临时 DLL 已清理，未残留任何文件。

