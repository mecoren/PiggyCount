# 账本管理上传功能设计文档

> 版本：v1.0  日期：2026-08-14
> 关联需求：`/prd/ledger_upload/requirements.md`

---

## 1. 方案选型

| 方案 | 说明 | 结论 |
|------|------|------|
| **A. 批量逻辑在 TransactionsSyncManager** | `uploadAllLedgers()` 仅加在快照同步实现上，UI 以 `syncService is TransactionsSyncManager` 控制入口可见性 | **采用** |
| B. 抽象层加 uploadAllLedgers | `SyncService` 加方法，LocalOnly/SyncEngine 也需实现；当前范围（仅快照类）下多余 | 否 |
| C. UI 层循环调用 | 页面里 for 循环调 `uploadCurrentLedger`；批量逻辑散落 UI，不利复用与测试 | 否 |

串行 vs 并行：**串行**逐个上传。理由：
- 避免并发上传打满 WebDAV/S3 连接数限制
- `uploadCurrentLedger` 内部写 `_recentUpload` / `_statusCache`（Map），串行天然无竞态
- 单个失败可捕获继续，语义与 `restoreAllRemoteLedgers` 的 success/failed 统计一致

## 2. 改动点

### 2.1 服务层：`lib/cloud/transactions_sync_manager.dart`

新增公开方法（不进 `SyncService` 抽象）：

```dart
/// 批量上传所有本地账本到云端（串行，单个失败不中断）。
/// 返回 (success, failed) 统计，语义对齐 restoreAllRemoteLedgers。
Future<({int success, int failed})> uploadAllLedgers() async {
  await _ensureInitialized();
  final ledgers = await db.select(db.ledgers).get();
  var success = 0;
  var failed = 0;
  for (final ledger in ledgers) {
    try {
      await uploadCurrentLedger(ledgerId: ledger.id);
      success++;
    } catch (e) {
      logger.warning('CloudSync', '批量上传账本 ${ledger.id} 失败: $e');
      failed++;
    }
  }
  return (success: success, failed: failed);
}
```

复用点：`uploadCurrentLedger` 上传后已自动把 `_statusCache` 置为 `SyncDiff.inSync`
并写入 `_recentUpload`（CDN 延迟防护），批量调用无需额外状态处理。

### 2.2 UI 层：`lib/pages/main/ledgers_page_new.dart`

**F2 全部上传（对齐 `_handleBatchRestore` 模式）：**

- State 新增 `bool _isUploadingAll = false`（与 `_isRestoring` 同级）
- 本地账本区 `_SectionHeader` 增加 `action` 槽：
  - 可见条件：`localLedgers.isNotEmpty && ref.watch(syncServiceProvider) is TransactionsSyncManager`
  - `TextButton.icon(icon: Icon(Icons.cloud_upload, size: 18), label: ledgersUploadAll)`
  - `onPressed: _isUploadingAll ? null : () => _handleBatchUpload(context)`
- `_handleBatchUpload(context)` 流程：
  1. `AppDialog.confirm`（title=ledgersUploadAll，message=ledgersUploadAllMessage(count)，文案含覆盖警示）
  2. `setState(_isUploadingAll = true)` + toast `ledgersConflictUploading`（复用"上传中..."）
  3. `syncService.uploadAllLedgers()`
  4. 刷新 `ledgerListRefreshProvider` / `statsRefreshProvider` / `syncStatusRefreshProvider`
  5. `AppDialog.info` 结果弹窗（ledgersUploadAllComplete + ledgersUploadAllResult(success, failed)）
  6. catch → `AppDialog.error`；finally → `setState(_isUploadingAll = false)`

**F3 单账本上传（对齐 cloud_sync_page 上传流程，简化版）：**

- `_showLocalLedgerActions` 计算可见性：
  `final canUpload = ref.read(syncServiceProvider) is TransactionsSyncManager;`
- 菜单项：`SimpleDialogOption('upload')`，`Icons.cloud_upload_outlined`，
  位置在 budget（及 members/memberStats）之后、clear 之前
- `_handleUploadLedger(context, ledger)` 流程：
  1. `uploadingLedgerIdsProvider` 加入 `ledger.id`
  2. `syncService.uploadCurrentLedger(ledgerId: ledger.id)`
  3. 成功：toast `mineUploadSuccess`（复用"上传成功"）+ bump `ledgerListRefreshProvider` / `syncStatusRefreshProvider`
  4. 失败：`AppDialog.error`
  5. finally：从 `uploadingLedgerIdsProvider` 移除

### 2.3 本地化：`lib/l10n/app_{en,zh,zh_TW,ko}.arb`

| key | en | zh |
|-----|----|----|
| `ledgersUploadAll` | Upload All | 全部上传 |
| `ledgersUploadAllMessage` | Upload all {count} local ledgers to the cloud? Existing cloud content will be overwritten. | 确认将 {count} 个本地账本上传到云端？云端现有内容将被本地内容覆盖。 |
| `ledgersUploadAllComplete` | Upload Complete | 上传完成 |
| `ledgersUploadAllResult` | Success: {success}, Failed: {failed} | 成功：{success} 个，失败：{failed} 个 |
| `ledgersUploadThis` | Upload to Cloud | 上传到云端 |

复用已有：`ledgersConflictUploading`（上传中...）、`mineUploadSuccess`（上传成功）。
`app_en.arb` 为模板（含 `@` 元数据），其余语言跟随；改完跑 `flutter gen-l10n`。

## 3. 数据流

```
全部上传：确认弹窗 → for each 本地账本 → exportTransactionsJson → 指纹/metadata
         → manager.upload(ledger_<id>.json) → _statusCache[id]=inSync → 统计
         → 刷新 providers → 结果弹窗

单账本：长按菜单 → uploadingLedgerIds += id → uploadCurrentLedger(id)
      → toast + 刷新 providers → uploadingLedgerIds -= id
```

## 4. 错误处理

| 场景 | 行为 |
|------|------|
| 未登录 / 云服务不可用 | `uploadCurrentLedger` 抛 `CloudSyncException`；单账本弹错误框，批量计入 failed |
| 单个账本导出/上传失败 | 批量：记 warning 日志继续下一个；不中断 |
| 页面 dispose（mounted=false） | 上传继续在后台完成，UI 刷新前检查 mounted（对齐现有代码风格） |

## 5. 测试与验证

- 手动验证：WebDAV 配置下全部上传 / 单账本上传 / PiggyCount Cloud 下入口隐藏
- `flutter gen-l10n` 无错误
- `flutter analyze` 无新增告警
- 回归：cloud_sync_page 原上传入口不受影响（共用同一底层 API，未改动）

## 6. 风险

- 账本数量很大时串行上传耗时较长 → 现阶段可接受（toast + 结果弹窗）；未来可加进度提示
- 覆盖语义已通过确认弹窗明确警示，无静默数据丢失路径
