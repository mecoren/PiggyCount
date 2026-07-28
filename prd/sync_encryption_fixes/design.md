# 同步与加密链路修复 设计文档

> 配套文档：[requirements.md](./requirements.md)
> 实现策略：TDD（先写失败测试 → 最小实现 → 通过 → 重构），每个 US 独立可测、独立可提交。

## 0. 全局约束

- **语言**：代码标识符/文件名一律英文；复杂逻辑中文注释，解释「为什么」
- **不破坏既有接口**：`SyncService` / `EncryptionService` / `CloudStorageService` 方法签名保持不变，仅新增异常类型与可选字段
- **异常兼容**：新异常 `SaltMismatchException` 继承自 `DecryptionException`，旧 catch 不退化
- **测试**：每个 US 至少 1 个失败测试先于实现；`flutter analyze` 0 新增 error/warning
- **TDD 循环**：写测试 → 跑（FAIL）→ 写实现 → 跑（PASS）→ 重构 → 提交

---

## 1. 模块依赖与改动文件清单

```
lib/
├── domain/encryption/
│   └── encryption_service.dart          [改] 新增 SaltMismatchException / EnableFromCloudProbeFailedException
├── data/encryption/
│   ├── encryption_service_impl.dart     [改] US-2 抛 SaltMismatchException；US-3 探测失败抛异常而非回退
│   └── encrypted_cloud_storage.dart     [改] 文档说明异常透传契约（无需改逻辑）
├── cloud/
│   ├── sync_fingerprint.dart            [新] US-5 共享指纹函数
│   ├── transactions_sync_manager.dart   [改] US-1 清空再导入；US-2 捕获 SaltMismatch；US-5 引用共享函数；US-6 不缓存错误
│   ├── startup_sync_checker.dart        [改] US-7 填充 diffType；_applyAll 二次确认
│   ├── startup_sync_overlay.dart        [改] US-7 SummaryView 冲突高亮
│   └── sync_service.dart                [改] LedgerCandidate 增加 diffType 字段（若定义在此）
└── pages/cloud/
    ├── cloud_sync_page.dart             [改] US-2 识别 salt_mismatch_need_password 并弹密码对话框
    └── encryption_settings_page.dart    [改] US-3 捕获 EnableFromCloudProbeFailedException 并弹确认

test/
├── cloud/
│   ├── sync_fingerprint_test.dart       [新] US-5 指纹等价性
│   ├── transactions_sync_manager_test.dart [新/改] US-1/US-2/US-6
│   └── startup_sync_checker_test.dart   [改] US-7
├── encryption/
│   └── encryption_service_impl_test.dart [改] US-2/US-3
└── pages/
    └── cloud_sync_page_test.dart        [新] US-2 widget test
```

---

## 2. US-1：恢复前清空账本（事务保护）

### 2.1 关键决策

- **使用 drift 嵌套事务**：`LocalRepository.clearLedgerTransactions` 内部已用 `db.transaction(...)`，drift 嵌套 `db.transaction` 自动复用外层事务，安全
- **保留账本配置**：仅清 `transactions` + `transaction_tags` + `transaction_attachments` 三表，不动 `ledgers` / `accounts` / `categories` / `tags` / `budgets`
- **`deletedDup` 语义**：清空阶段删除的本地交易行数（即被覆盖的本地独有数据量）
- **changeTracker 行为**：清空时登记 `transaction:delete` 变更，避免恢复后云端残留（与现有清空账本逻辑一致）

### 2.2 接口变更

`TransactionsSyncManager.downloadAndRestoreToCurrentLedger` 内部流程改造，**不改签名**：

```dart
@override
Future<({int inserted, int deletedDup})>
    downloadAndRestoreToCurrentLedger({required int ledgerId}) async {
  await _ensureInitialized();
  if (_provider == null) {
    throw fcs.CloudSyncException('云服务不可用，请检查配置或登录状态');
  }
  try {
    final jsonStr = await _provider!.storage.download(
      path: _pathForLedger(ledgerId),
    );
    if (jsonStr == null) {
      return (inserted: 0, deletedDup: 0);
    }

    // 事务包裹：清空 + 导入。drift 嵌套 transaction 复用外层作用域，
    // 任意一步失败整体回滚，避免出现"已清空但未导入"的中间态。
    final result = await db.transaction(() async {
      // 1. 先记录清空前的本地行数（用于 deletedDup 上报）
      // 2. 清空目标账本交易（连带 tags/attachments，并登记 changeTracker）
      final deleted = await repo.clearLedgerTransactions(ledgerId);
      // 3. 导入云端数据（recordChanges=false：恢复是"拉取"，不反向回流）
      final import = await importTransactionsJson(
        repo, ledgerId, jsonStr,
        recordChanges: false,
      );
      return (inserted: import.inserted, deletedDup: deleted);
    });

    _statusCache.remove(ledgerId);
    _recentLocalChangeAt.remove(ledgerId);
    _recentUpload.remove(ledgerId);
    return result;
  } catch (e, stack) {
    logger.error('CloudSync', '下载失败: $ledgerId', e);
    logger.error('CloudSync', '堆栈: $stack');
    if (e.toString().contains('404') ||
        e.toString().contains('not found')) {
      return (inserted: 0, deletedDup: 0);
    }
    rethrow;
  }
}
```

### 2.3 测试要点

- `test/cloud/transactions_sync_manager_test.dart`：
  - `restore_clears_local_before_insert`：本地有 3 条交易，云端 5 条；restore 后本地恰好 5 条（无重复），`deletedDup == 3`
  - `restore_rollback_on_import_failure`：mock importTransactionsJson 抛异常；事务回滚，本地仍为原 3 条
  - `restore_no_cloud_data_returns_zero`：云端 null 返回 (0,0)，不触发清空
  - `restore_404_returns_zero`：download 抛 404 返回 (0,0)，不触发清空

---

## 3. US-2：salt 错配引导重输密码

### 3.1 异常层次

```dart
// lib/domain/encryption/encryption_service.dart
class DecryptionException implements Exception { ... }

/// salt 不匹配异常
/// 继承 DecryptionException 以保持现有 catch(DecryptionException) 兼容，
/// 同时让上层能精确识别"salt 错配 → 引导重输密码"场景。
class SaltMismatchException extends DecryptionException {
  final List<int> expectedSalt;
  final List<int> actualSalt;
  const SaltMismatchException({
    required this.expectedSalt,
    required this.actualSalt,
  }) : super('密文 salt 与当前密钥不匹配，可能需要重新输入密码');
}
```

### 3.2 decrypt 抛出点改造

```dart
// lib/data/encryption/encryption_service_impl.dart:360-366
if (_activeSalt != null && !_listsEqual(_activeSalt!, decoded.salt)) {
  throw SaltMismatchException(
    expectedSalt: decoded.salt,
    actualSalt: _activeSalt!,
  );
}
```

### 3.3 SyncManager 降级处理

```dart
// lib/cloud/transactions_sync_manager.dart getStatus catch 分支
} on SaltMismatchException catch (e) {
  logger.warning('CloudSync', 'salt 错配，需引导重输密码: $ledgerId');
  // 不写入 _statusCache（避免错误状态持续）
  return SyncStatus(
    diff: SyncDiff.error,
    localCount: 0,
    localFingerprint: '',
    message: 'salt_mismatch_need_password',
  );
} catch (e, stack) { ... }
```

`downloadAndRestoreToCurrentLedger` 同样捕获 `SaltMismatchException`，但**rethrow**（下载路径无法降级为状态，需让 UI 层弹密码对话框后重试）。

### 3.4 UI 层密码对话框

新增可复用函数 `promptPasswordAndActivate(BuildContext, EncryptionService)`：

```dart
// lib/pages/cloud/encryption_dialogs.dart [新]
/// 弹密码对话框，验证 + 激活 + 持久化 + 触发 sync 重建
/// 返回 true 表示激活成功，调用方可重试原同步操作
Future<bool> promptPasswordAndActivate(
  BuildContext context, {
  required EncryptionService service,
  required String title,
  String? subtitle,
}) async { ... }
```

`cloud_sync_page.dart` 在 `getStatus` / `download` 失败时检查 `message == 'salt_mismatch_need_password'`，调用上述函数，成功后**最多重试一次**原操作。

### 3.5 测试要点

- `encryption_service_impl_test.dart`：
  - `decrypt_throws_SaltMismatchException_on_mismatch`
  - `decrypt_SaltMismatchException_is_a_DecryptionException`（兼容性）
- `transactions_sync_manager_test.dart`：
  - `getStatus_returns_salt_mismatch_status_without_caching`
  - `download_rethrows_SaltMismatchException`
- widget test：`cloud_sync_page` 识别 salt_mismatch 后弹密码框

---

## 4. US-3：探测失败不自动回退

### 4.1 新异常

```dart
/// enableFromCloud 云端探测失败异常
/// 触发场景：cloudStorage.list() 抛异常（网络/权限）
/// 不再静默回退 enable()，由调用方决定是否作为首设备初始化
class EnableFromCloudProbeFailedException implements Exception {
  final String message;
  final Object? cause;
  const EnableFromCloudProbeFailedException(this.message, {this.cause});
  @override
  String toString() => 'EnableFromCloudProbeFailedException: $message';
}
```

### 4.2 enableFromCloud 改造

```dart
// lib/data/encryption/encryption_service_impl.dart:115-122
final List<CloudFile> files;
try {
  files = await cloudStorage.list(path: '');
} catch (e) {
  // 不再静默回退 enable()：可能孤立其他设备
  throw EnableFromCloudProbeFailedException(
    '云端探测失败，无法判断是否为首设备',
    cause: e,
  );
}
```

**保留**：第 138 行「云端无 BEECRYPT1 密文 → 回退 enable()」逻辑不变（确属首设备场景）。

### 4.3 调用方处理

```dart
// lib/pages/cloud/encryption_settings_page.dart
try {
  final isFirstDevice = await service.enableFromCloud(
    password: password,
    cloudStorage: rawStorage!,
  );
  // ... 原有流程
} on EnableFromCloudProbeFailedException catch (e) {
  // 弹确认对话框
  final confirmed = await _showProbeFailedDialog(context, e.cause);
  if (!confirmed) return; // 用户取消，不开启加密
  // 用户确认作为首设备初始化
  await service.enable(password: password);
  await service.reEncryptExistingCloudData(storage: rawStorage!);
}
```

### 4.4 测试要点

- `encryption_service_impl_test.dart`：
  - `enableFromCloud_throws_ProbeFailed_on_list_error`（mock list 抛异常）
  - `enableFromCloud_falls_back_to_enable_when_no_ciphertext`（保留行为）
- widget test：`encryption_settings_page` 捕获异常后弹确认框

---

## 5. US-5：抽取共享指纹函数

### 5.1 新文件

```dart
// lib/cloud/sync_fingerprint.dart
import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../services/system/logger_service.dart';

/// 从 transactions JSON payload 计算内容指纹
///
/// 规范化规则：
/// - 标签排序后拼接，确保顺序无关
/// - 转账交易忽略 categoryName/categoryKind（避免跨设备分类缺失导致指纹漂移）
/// - 排序键：happenedAt → type → amount → categoryName → categoryKind → note
String contentFingerprintFromMap(Map<String, dynamic> payload) {
  // 原 _contentFingerprintFromMap 的实现，原样搬迁
  ...
}
```

### 5.2 替换点

```dart
// lib/cloud/transactions_sync_manager.dart:614 与 :1138
// 删除两处私有方法，改为：
String fingerprint(String data) {
  final json = jsonDecode(data) as Map<String, dynamic>;
  return contentFingerprintFromMap(json);
}
```

### 5.3 测试要点

- `test/cloud/sync_fingerprint_test.dart` [新]：
  - `fingerprint_stable_for_same_input`（快照测试）
  - `fingerprint_ignores_tag_order`
  - `fingerprint_ignores_category_for_transfer`
  - `fingerprint_matches_old_implementation`（用一组固定输入对比硬编码 SHA256）

---

## 6. US-6：错误状态不缓存

### 6.1 改造

```dart
// lib/cloud/transactions_sync_manager.dart:510-525
} catch (e, stack) {
  logger.error('CloudSync', '获取状态失败: $ledgerId', e);
  logger.error('CloudSync', '堆栈: $stack');

  // 错误状态不写入 _statusCache：
  // 瞬时错误（网络抖动、临时 401）不应持续阻挡，下次调用重新走完整流程。
  // salt_mismatch_need_password 也不缓存（用户重输密码后应立即生效）。
  return SyncStatus(
    diff: SyncDiff.error,
    localCount: 0,
    localFingerprint: '',
    message: e.toString(),
  );
}
```

仅删除一行 `_statusCache[ledgerId] = status;`。

### 6.2 测试要点

- `getStatus_error_not_cached`：第一次 mock 抛异常，第二次 mock 成功；连续两次调用应第二次返回成功状态（证明未读缓存）

---

## 7. US-7：applyAll 冲突高亮与二次确认

### 7.1 数据模型扩展

```dart
// lib/cloud/startup_sync_checker.dart
class LedgerCandidate {
  final Ledger ledger;
  final SyncDiff diffType;  // [新] 来自 getStatus().diff
  LedgerCandidate({required this.ledger, required this.diffType});
}
```

构建候选列表处填充 `diffType`（来自已有 `getStatus` 调用结果，无额外网络开销）。

### 7.2 SummaryView 冲突高亮

```dart
// lib/cloud/startup_sync_overlay.dart SummaryView build
...state.candidates.map((c) {
  final isConflict = c.diffType == SyncDiff.different;
  return Row(children: [
    Icon(
      isConflict ? Icons.warning_amber : Icons.book_outlined,
      size: 14,
      color: isConflict
          ? Colors.orange
          : BeeTokens.textTertiary(context),
    ),
    const SizedBox(width: 6),
    Expanded(child: Text(c.ledger.name, ...)),
    if (isConflict)
      Tooltip(
        message: l10n.startupSyncConflictTooltip, // 新增本地化键
        child: Icon(Icons.info_outline, size: 12,
            color: BeeTokens.textTertiary(context)),
      ),
  ]);
}),
```

### 7.3 _applyAll 二次确认

```dart
Future<void> _applyAll(List<LedgerCandidate> candidates) async {
  // 扫描冲突账本
  final conflictLedgers = candidates
      .where((c) => c.diffType == SyncDiff.different)
      .map((c) => c.ledger.name)
      .toList();

  if (conflictLedgers.isNotEmpty) {
    final confirmed = await _showConflictConfirmDialog(
      context, conflictLedgers);
    if (!confirmed) {
      // 用户取消：回退到 SummaryView 让用户重新选择
      controller.backToSummary();
      return;
    }
  }
  // ... 原 applyAll 逻辑
}
```

文案：`将用云端覆盖 ${conflictLedgers.length} 个账本的本地改动（${前 3 个 + "等 N 个"}），是否继续？`

### 7.4 Overlay 状态扩展

`StartupSyncOverlayController` 增加 `backToSummary()` 方法，状态机新增 `backToSummary` 转换（applying → summary）。

### 7.5 测试要点

- `startup_sync_checker_test.dart`：
  - `applyAll_no_confirmation_when_no_conflict`（全 cloudNewer 不弹框）
  - `applyAll_shows_confirmation_when_has_different`（弹框）
  - `applyAll_cancel_returns_to_summary`
  - `applyAll_confirm_proceeds`
- widget test：`SummaryView` 不同 diffType 显示不同图标

---

## 8. 实施顺序（按依赖与风险）

1. **US-5**（独立、低风险）：先抽取指纹函数，无业务影响，作为热身验证 TDD 流程
2. **US-6**（独立、低风险）：单行删除 + 测试
3. **US-1**（独立、中风险）：恢复路径加清空，事务保护
4. **US-2**（依赖 US-6 的"不缓存错误"原则）：异常层次 + 降级 + UI 对话框
5. **US-3**（独立、中风险）：异常 + UI 确认
6. **US-7**（独立、中风险）：数据模型 + UI + 状态机
7. 集成验证：`flutter analyze` + 全量 `flutter test`

每个 US 完成后立即提交（commit message 格式：`fix(sync): US-X <短描述>`），便于回滚。

---

## 9. 自检清单

- [x] 每个 US 有明确接口契约与测试要点
- [x] 异常层次向后兼容（SaltMismatchException 继承 DecryptionException）
- [x] 不修改既有方法签名
- [x] 事务边界清晰（US-1 用 drift 嵌套 transaction）
- [x] 缓存策略统一（错误状态一律不缓存）
- [x] UI 改动有本地化键规划（startupSyncConflictTooltip 等）
- [x] 实施顺序考虑了依赖关系（US-2 依赖 US-6 的缓存原则）
- [x] 测试覆盖关键路径：成功、失败、回滚、降级、取消
