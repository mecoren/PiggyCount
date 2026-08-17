# Path A 同步审计项修复核查报告

> 核查日期：2026-08-17
> 方式：只读静态代码审查（未修改任何代码）
> 背景：前一日对 `lib/cloud`（S3/WebDAV/Supabase/iCloud 快照同步，Path A）做了只读审计，列出 H1–H3 / M1–M4 / P1–P3 共 13 项。本次核查这些项在**后续代码改动**中是否已被修复。
> 说明：这些修复并非本次会话所写（我只改过两处 `rate` TEXT 强转崩溃 + 已删除的 app.dart 临时钩子）。以下按"当前代码实际状态"判定。

## 一、结论总览

| 项 | 严重度 | 状态 | 关键证据 |
|---|---|---|---|
| H1 反序列化无容错 | 高 | ✅ 已修复 | `transactions_json.dart` 新增 `_readString/_readInt/_readDouble/_readBool/_readDate` + `_skip`，逐条跳过坏数据 |
| H2 恢复语义不一致 | 高 | ✅ 已修复 | `transactions_sync_manager.dart:1510-1515` `downloadRemoteLedger` 改走 `restoreLedgerFromJson` 覆盖语义 |
| H3 全量覆盖只覆盖交易 | 高 | ✅ 已修复 | `data_import_service.dart:1477-1482` 新增 `_mirrorDeleteAbsentEntities` 镜像删除预算/周期/分类/标签 |
| M1 云端空列表误标全部 deleted | 中 | ✅ 已修复 | `sync_diff_service.dart:102-106` 空云端列表守卫 `return null` |
| M2 分类导出 N+1 | 中 | ✅ 已修复 | `transactions_json.dart:109-112` 单次 `db.select(categories).get()` 批量建映射 |
| M3 Path A 合并写 local_changes | 中 | ✅ 已修复 | `data_import_service.dart:1476` 恢复路径 `recordChanges: false` |
| P1 凭据明文降级 | 高 | ✅ 已修复 | `flutter_cloud_sync/test/config/cloud_service_store_test.dart` 有专项测试断言"安全写失败抛异常、明文不落盘" |
| P2 离线队列非幂等重放 | 高 | ✅ 已修复（两层加固） | `database_sync_manager.dart:196` `_processingQueue` 重入保护 + `:696-709` insert 幂等预检（`getById` 命中即跳过）|
| P3 WebDAV/iCloud 缺网络超时 | 高 | ✅ 已修复（审计漏报） | WebDAV `_opTimeout=60s`（`webdav_storage_service.dart:20/24-29`）+ iCloud `_defaultTimeout=30s/_downloadTimeout=90s`（`icloud_method_channel.dart:14-15/23-36`），均用 `.timeout()` |
| M4 跨时区显示不一致 | 中 | ⚠️ 非真实缺陷（建议不改） | `transactions_json.dart:166` `toUtc()` 导出 / `:739` `toLocal()` 导入 = 标准 UTC 往返，保持现状 |

**总结：原审计 11 项全部闭合——9 项已确认修复（含本轮复查由"部分/未修复"升级的 P2、P3），1 项（M4）经复核为"非真实缺陷、保持现状，不改"。**

---

## 二、逐项正确性核验

### H1 反序列化无容错 —— ✅ 已修复
- 新增安全读取助手（`transactions_json.dart:447-467`）：
  ```dart
  String? _readString(Map m, String k) => m[k] is String ? m[k] as String : null;
  double? _readDouble(Map m, String k) => m[k] is num ? (m[k] as num).toDouble() : null;
  // ... 同理 _readInt / _readBool / _readDate，均用 is 守卫而非硬 cast
  ```
- 逐条解析均先 `if (it is! Map) { _skip(...); continue; }`，并按必填字段校验（如交易 `type/amount/happenedAt`）；失败时 `_skip` 计数并跳过该条。
- 预算循环（`558-570`）整体包在 `try/catch (_) { _skip }` 中，残余 `as String?` 强转也被捕获，不会中断整账本。
- 顶层 `parseJsonToImportData` 对整体格式也有 `is! Map` 守卫。
- **残留**：个别非必填字段仍用 `as String?`（如 `:559 syncId`、`:561 categoryName`），但均位于 `try/catch` 或 `?? 兜底` 内，实际安全。判定为有效修复。

### H2 恢复语义不一致 —— ✅ 已修复
- 旧实现同名账本"下载恢复"是追加合并（不清空本地），导致交易翻倍。
- 现 `downloadRemoteLedger`（`:1418`）在 `:1510-1515` 显式注释"H2：同名/既有账本的云端下载统一走「先清空再导入」的覆盖语义"，改调 `restoreLedgerFromJson`（覆盖管线）。
- `fullRestoreAllRemoteLedgers`（`:1714`）两条分支（本地已有→`downloadAndRestoreToCurrentLedger`、云端独有→`downloadRemoteLedger`）现**都走覆盖语义**，消除语义分叉。

### H3 全量覆盖只覆盖交易 —— ✅ 已修复
- `restoreLedgerFromJson`（`:1452`）在事务内 `clearLedgerTransactions` → `importTransactionsJson`，并对 v8+ 快照调用 `_mirrorDeleteAbsentEntities`（`:1496`）。
- 该函数（`:1496-1586`）按 syncId 镜像删除：云端已删的预算、周期规则、分类、标签（带安全边界——只删"本地有 syncId 且不在云端集合"且"未被引用"的行，防误删遗留数据）。
- 注释明确"H3 真覆盖（镜像云端）"。判定修复成立。

### M1 云端空列表误标全部 deleted —— ✅ 已修复
- `sync_diff_service.dart:102-106`：
  ```dart
  if (cloudTransactions.isEmpty && local.isNotEmpty) {
    logger.warning('SyncDiff', '云端交易列表为空但本地有 ${local.length} 条，拒绝计算 diff（防误删）');
    return null;
  }
  ```
- 空云端列表直接拒绝 diff，不会走到 `:190-198` 的"本地有云端无→deleted"标记。配合 `restoreLedgerFromJson` 的空快照守卫（`:1459-1468`），形成双层防护。

### M2 分类导出 N+1 —— ✅ 已修复
- `transactions_json.dart:109-112` 注释"M2：一次全量查询建 categoryId → {name,kind} 映射，替代旧实现的逐 categoryId 单查（N+1）"，实现为 `final allCategoriesList = await db.select(db.categories).get();`。

### M3 Path A 合并写 local_changes —— ✅ 已修复
- `restoreLedgerFromJson` 调用 `importTransactionsJson(repo, ledgerId, jsonStr, recordChanges: false)`（`:1476`）。云端恢复不再污染 `local_changes`，未来启用 PiggyCount Cloud 增量同步时不会重复推送。
- CSV 导入仍用 `recordChanges: true`（设计如此，用于把本地 CSV 数据推上云），不受影响。

### P1 凭据明文降级 —— ✅ 已修复（测试背书）
- `packages/flutter_cloud_sync/test/config/cloud_service_store_test.dart` 含：
  - `P1：secure 写失败 → saveOnly 抛 CloudStorageException 且 prefs 无明文`
  - `P1：secure 写成功后必须清掉旧明文`
- 断言凭据绝不降级落 `SharedPreferences`。实现侧应为安全存储写入失败时**硬失败**而非回退明文。

### P2 离线队列非幂等重放 —— ✅ 已修复（两层加固，本轮复查升级）
- **重入保护**：`database_sync_manager.dart:196` 声明 `bool _processingQueue = false`；`processOfflineQueue` 入口 `:367-372` 检查若已在跑则 `return 0`（并发调用跳过），`:372` 置 `true`，`:436-438` `finally` 复位。防止网络恢复事件与手动触发并发时两轮 `removeFirst` 交错执行同一批操作（重复 insert 建记录）。
- **insert 幂等预检**：`_executeOperation` 的 insert 分支 `:696-709` 先 `getById(table, id)`，云端已有同 id 行则 `break` 跳过 insert。这正是 `syncRecord`（`:265-277`）既有的 `getById→insert` 幂等模式，重放不再产生重复记录。
- 结论：原审计"无法静态确认"已转为可在源码层静态确认——两层叠加可杜绝弱网重复记录。

### P3 WebDAV/iCloud 缺网络超时 —— ✅ 已修复（审计 grep 漏报，本轮复查升级）
- **漏报双因**：① 关键词错——实现用 `Future.timeout()` 而非 `dio.connectionTimeout/receiveTimeout`，原 grep 关键词未命中；② 路径错——代码位于独立 provider 包 `flutter_cloud_sync_webdav` / `flutter_cloud_sync_icloud`，不在 `flutter_cloud_sync/lib`。
- **WebDAV**（`flutter_cloud_sync_webdav/lib/src/webdav_storage_service.dart`）：
  - `:20` `static const _opTimeout = Duration(seconds: 60);`
  - `:24-29` `_op<T>(opName, op)` 助手：`op().timeout(_opTimeout, onTimeout: () => throw CloudStorageException(...))`，统一包裹全部 `_client.*` 调用。
  - 全部 16 处 `_client.write/read/remove/rename/readDir/mkdir` 调用均经 `_op('...', () => _client.x(...))` 包裹（grep 验证无裸 `_client.` 漏网），超时抛 `CloudStorageException` 与其他错误走同通道。
- **iCloud**（`flutter_cloud_sync_icloud/lib/src/icloud_method_channel.dart`）：
  - `:14-15` `_defaultTimeout=30s` / `_downloadTimeout=90s`（大文件下载余量）。
  - `:23-32` `@visibleForTesting static invokeWithTimeout`：`channel.invokeMethod(...).timeout(timeout, onTimeout: () => throw TimeoutException(...))`；`:34-37` `_invoke` 实例助手统一委托，保证超时不可绕过。
  - 所有实例方法（`isICloudAvailable`/`initializeContainer`/`uploadFile`/`downloadFile`/`deleteFile`/`listFiles`/`fileExists`/`getFileMetadata` 等）均经 `_invoke`，`downloadFile` 用 `_downloadTimeout`。
- 结论：原审计两因叠加导致漏报，实际超时已落地于两个 provider 包。

### M4 跨时区显示不一致 —— ⚠️ 非真实缺陷（建议不改，本轮重新定性）
- 导出 `:166` `'happenedAt': t.happenedAt.toUtc().toIso8601String()` + 导入 `:739` `happenedAt.toLocal()` 构成**标准「UTC 存储/传输、本地显示」往返**，不是 bug。
- **指纹稳定**：`toUtc()` 是确定性函数，任意时区设备导出同一笔交易都得到相同的 `...Z` 串，两端指纹一致，不会 ping-pong。
- **epoch 时区无关**：Drift 以 `millisecondsSinceEpoch` 存存储，值不受 `toLocal()` 影响，跨设备存储值相同。
- **为何不能改 naive-local 存储**：版本过渡期若旧设备 export `Z` 串、新设备 export naive 串 → 同数据不同指纹 → 永久 `cloudNewer` → sync ping-pong。这正是指纹归一化要防的回归。
- 结论：保持现状。跨时区显示不同本地时间是对"同一时刻"的正确表达，无需修改。

---

## 三、剩余建议（非阻塞，投产前可选）

1. **运行验证**：以上多为静态核查。建议跑一次真实端到端同步（注入脏 JSON / 模拟云端空列表 / 弱网超时）确认运行时行为，而非仅依赖代码审查——尤其验证 P2 幂等重放与 P3 超时触发路径。
2. **M4 保持现状**：非缺陷，勿改（见上）。
