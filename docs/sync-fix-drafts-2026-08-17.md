# PiggyCount 同步修复草案

> 基于 `docs/sync-audit-report-2026-08-17.md` 的 F1/F2/F3，核对真实源码后给出。
> 性质：改法草案，未改任何源码。所有行号对齐 2026-08-17 工作树。

---

## F2【高 / 正确性】backfillUntrackedEntities 去重失效 —— 根因修订

### 报告结论的修订

报告把根因定为"local_changes 缺唯一约束"，建议加 `(entityType, entitySyncId, action)` 唯一约束。
核对源码后，**根因比这更根本**，且"加唯一约束"方案有隐患：

#### 根因（源码实证）

`backfillUntrackedEntities`（`sync_engine_status.dart:158-165`）的去重集来自：

```dart
final allUnpushed = await changeTracker.getUnpushedChangesForLedger(ledgerId);
```

而调用方 `piggycount_cloud_sync_page.dart:92` 传入的是**当前选中账本的具体 id**：

```dart
await engine.backfillUntrackedEntities(ledgerId: ledgerId); // ledgerId = 具体账本,非 0
```

但 user-global 实体（tag/account/category）的 change 记在 `ledgerId=0`（`change_tracker.dart:36,63`）。
`getUnpushedChangesForLedger(具体账本)` 用 `c.ledgerId.equals(ledgerId)` 过滤（`change_tracker.dart:196`），
**取不到任何 user-global 变更** → `allPushedIds` 对 tag/account/category 恒为空 →
每次 backfill 都给**所有**带 syncId 的 user-global 实体重插一条 create。

叠加第二个缺陷：去重只看 **unpushed**（`pushedAt.isNull()`），即便 ledgerId 对了，
一旦某条 create 被 push（markPushed），它就跌出去重集 → 下次 backfill 再次重插。

#### "加唯一约束"方案的隐患

报告建议的全表唯一约束 `(entityType, entitySyncId, action)`：

- **能**止住膨胀（第二次 insert 撞已推送但仍在表内的行 → 抛错 → 被 `status.dart:186` catch 吞掉），
  但仅限 7 天保留期内（`cleanupPushedChanges` 清理后旧行消失，重插再次发生）。
- **会误伤合法编辑流**：`_insert`（`change_tracker.dart:134`）是裸 `insert`，无 `ON CONFLICT`。
  若用户对同一实体连续两次同 action 编辑（如两次 rename，都产 `update`），第二次 insert 会撞约束
  **抛错冒泡到 Repository/UI**。报告未提及此风险。

### 推荐修复：对齐 legacy 范式（零迁移、零编辑流风险）

同文件 `_backfillLegacyUserGlobalChanges`（`sync_engine.dart:840-916`）已经实现了**正确去重范式**：
全表查 local_changes、不按 ledgerId 过滤、含 pushed + unpushed、构建 `knownSyncIds` 集合。
`backfillUntrackedEntities` 应直接复用这个范式。

#### 改动：`sync_engine_status.dart` `backfillUntrackedEntities`（替换 :158-254 去重段）

```dart
Future<int> backfillUntrackedEntities({required int ledgerId}) async {
  // F2 修复:去重必须跨全表(含已推送)且不按 ledgerId 过滤。
  // user-global 实体(tag/account/category/exchange_rate_override)的 change
  // 记在 ledgerId=0,而本方法入参 ledgerId 是具体账本 —— 旧逻辑用
  // getUnpushedChangesForLedger(ledgerId) 构建去重集,取不到 user-global
  // 变更 → 去重集恒空 → 每次 backfill 都给所有 user-global 实体重插 create
  // → local_changes 随健康检查反复膨胀。对齐 _backfillLegacyUserGlobalChanges
  // 的正确范式:全表查 knownSyncIds(含 pushed)。
  final knownUserGlobalSyncIds = (await (db.select(db.localChanges)
            ..where((c) => c.entityType.isIn(
                ['tag', 'account', 'category', 'exchange_rate_override'])))
          .get())
      .map((c) => c.entitySyncId)
      .toSet();
  // recurring 是 ledger-scoped,按账本去重,但仍含已推送。
  final knownRecurringSyncIds = (await (db.select(db.localChanges)
            ..where((c) =>
                c.entityType.equals('recurring') &
                c.ledgerId.equals(ledgerId)))
          .get())
      .map((c) => c.entitySyncId)
      .toSet();

  int backfilled = 0;

  // ---- Tags / Accounts / Categories / ExchangeRateOverride (user-global) ----
  // 用 knownUserGlobalSyncIds 去重(跨 pushed 状态),不再依赖不存在的唯一约束。
  Future<void> backfillUserGlobal<T>({
    required List<T> rows,
    required String? Function(T) getSyncId,
    required int Function(T) getEntityId,
    required String entityType,
  }) async {
    for (final row in rows) {
      final syncId = getSyncId(row);
      if (syncId == null || syncId.isEmpty) continue;
      if (knownUserGlobalSyncIds.contains(syncId)) continue;
      await changeTracker.recordUserGlobalChange(
        entityType: entityType,
        entityId: getEntityId(row),
        entitySyncId: syncId,
        action: 'create',
      );
      backfilled++;
    }
  }

  await backfillUserGlobal(
    rows: await db.select(db.tags).get(),
    getSyncId: (t) => t.syncId,
    getEntityId: (t) => t.id,
    entityType: 'tag',
  );
  await backfillUserGlobal(
    rows: await db.select(db.accounts).get(),
    getSyncId: (a) => a.syncId,
    getEntityId: (a) => a.id,
    entityType: 'account',
  );
  await backfillUserGlobal(
    rows: await db.select(db.categories).get(),
    getSyncId: (c) => c.syncId,
    getEntityId: (c) => c.id,
    entityType: 'category',
  );
  // F3: 补 exchange_rate_override(legacy backfill 同样漏了它)。
  await backfillUserGlobal(
    rows: await db.select(db.exchangeRateOverrides).get(),
    getSyncId: (r) => r.syncId,
    getEntityId: (r) => r.id,
    entityType: 'exchange_rate_override',
  );

  // ---- Recurring (ledger-scoped) ----
  final recurrings = await (db.select(db.recurringTransactions)
        ..where((r) => r.ledgerId.equals(ledgerId)))
      .get();
  for (final r in recurrings) {
    if (r.syncId == null || r.syncId!.isEmpty) continue;
    if (knownRecurringSyncIds.contains(r.syncId)) continue;
    await changeTracker.recordLedgerChange(
      entityType: 'recurring',
      entityId: r.id,
      entitySyncId: r.syncId!,
      ledgerId: ledgerId,
      action: 'upsert',
    );
    backfilled++;
  }

  logger.info('SyncEngine',
      'backfillUntrackedEntities: 共补写 $backfilled 条 sync_change');
  return backfilled;
}
```

要点：
- 去重集 `knownUserGlobalSyncIds` 跨全表 + 含 pushed → 第二次 backfill 看到"已有 change 行"即跳过，膨胀止住。
- 删除旧 `try/catch`（不再依赖不存在的唯一约束；`recordUserGlobalChange` 现在不会被重复调用，无异常可吞）。
- 同时修了 **F3**：补上 `exchange_rate_override` 循环。
- push 路径从 DB 重建 payload（`sync_engine_serialization.dart:14` + `sync_engine.dart:1029-1036`），
  不读 `local_changes.payloadJson` → coalesce/去重不会丢数据。

### 可选加固（非必需，后续可做）

若想从"应用层去重"升级为"DB 层兜底"，加**部分唯一索引**（仅约束未推送行，不误伤已推送后的二次编辑）：

```dart
// db.dart LocalChanges 表声明(uniqueKeys 不支持 WHERE,靠 migration 建部分索引)
// v35 migration:
if (from < 35) {
  // 先清已存在的重复未推送行(保留 id 最小的一条),再建部分唯一索引。
  await customStatement('''
    DELETE FROM local_changes
    WHERE rowid NOT IN (
      SELECT MIN(rowid) FROM local_changes
      WHERE pushed_at IS NULL
      GROUP BY entity_type, entity_sync_id, action
    )
    AND pushed_at IS NULL;
  ''');
  await customStatement('''
    CREATE UNIQUE INDEX IF NOT EXISTS idx_local_changes_unpushed_dedup
    ON local_changes (entity_type, entity_sync_id, action)
    WHERE pushed_at IS NULL;
  ''');
}
```

并把 `_insert`（`change_tracker.dart:134`）改为 `mode: d.InsertMode.insertOrIgnore`，
使同 (entity, action) 的并发未推送 insert 静默合并而非抛错。

> 注意：**必须用部分索引 `WHERE pushed_at IS NULL`**，不能用全表唯一约束 ——
> 全约束会让"push 完同实体同 action 再编辑"抛错（旧行已推送但仍占位 7 天）。
> 部分索引只约束未推送行，push 后旧行退出索引，新编辑可正常插入。

---

## F1【高 / 性能】applyRemoteChange 逐条 await _getDeviceId —— N+1

### 源码实证

- `applyRemoteChange`（`sync_engine_apply.dart:13`）每条 change `await _getDeviceId()`。
- `_getDeviceId`（`sync_engine_resolvers.dart:92-95`）`await provider.auth.currentUser` —— 即使命中内存缓存也是一次微任务往返。
- 唯一调用方：`_applyOneWithBusyRetry`（`sync_engine.dart:1399`）← `_applyPullPage`（`:1363` 循环内）← `_runPullLoop` ← `_doPull`。
- 全库 grep 确认 `applyRemoteChange` 仅此一处 caller（realtime 通道不走它）。

### 修复：pull 入口预解析，字段复用（对齐 activePullCache 范式）

`_doPull` 已经用 `activePullCache` 字段做"pull 内常量、finally 清空"的模式，deviceId 照搬即可，零签名变更。

#### 改动 1：`sync_engine.dart` 主类字段（紧邻 `activePullCache` 声明）

```dart
/// F1: pull 内 deviceId 是常量。_doPull 入口解析一次,pull 内复用,避免逐
/// change await _getDeviceId()(1 万条 change = 1 万次异步往返)。null = 非
/// pull 路径,applyRemoteChange 会 fallback 逐次解析。
String? _pullDeviceId;
```

#### 改动 2：`sync_engine.dart` `_doPull`（:1268-1277）

```dart
final cache = LookupCache();
await cache.prime(db);
activePullCache = cache;
_pullDeviceId = await _getDeviceId(); // F1: 一次解析,pull 内复用

try {
  return await _runPullLoop(ledgerId, nextSince, firstPage: probe);
} finally {
  activePullCache = null;
  _pullDeviceId = null; // F1: 清理,避免泄漏到非 pull 路径
}
```

#### 改动 3：`sync_engine_apply.dart` `applyRemoteChange`（:13）

```dart
Future<bool> applyRemoteChange(PiggyCountCloudSyncChange change) async {
  // F1: pull 内 deviceId 是常量,用 _doPull 预解析的 _pullDeviceId;
  // 非 pull 路径(目前无 caller)fallback 到逐次解析。
  final deviceId = _pullDeviceId ?? await _getDeviceId();
  if (change.updatedByDeviceId == deviceId) return false;
  // ... 后续不变
```

效果：1 万条 change 从 1 万次 `await` 降到 1 次。且 `await` 移出 `db.transaction`（`_applyPullPage:1360`）外，减少事务内异步跳数。

---

## F3【中 / 数据完整性】legacy backfill 漏 exchange_rate_override

### 源码实证

`_backfillLegacyUserGlobalChanges`（`sync_engine.dart:840-916`）只循环 account/category/tag，
但 `exchange_rate_override` 在 user-global 白名单内（`change_tracker.dart:36`），增量推送也推它（`sync_engine.dart:796 _doPushUserGlobalEntities`）。
结果：v19→v27 间创建、从未开云同步的老 `exchange_rate_override` 行（有 syncId 无 local_changes 记录）永不登记 → 永不推送 → 多设备汇率覆盖静默丢失。

### 修复：`sync_engine.dart` `_backfillLegacyUserGlobalChanges`（:843-845 扩展 + 增循环）

```dart
// :843-845 扩展 entityType 过滤
final existingChanges = await (db.select(db.localChanges)
      ..where((c) => c.entityType.isIn(
          ['account', 'category', 'tag', 'exchange_rate_override'])))
    .get();
final knownSyncIds = existingChanges.map((c) => c.entitySyncId).toSet();

// ... 在 tags 循环(:891-908)之后,增加 exchange_rate_override 循环:
// exchange_rate_override(同样 user-global)。syncId 为 null 的脏行兜底生成。
final rateOverrides = await db.select(db.exchangeRateOverrides).get();
for (final r in rateOverrides) {
  var syncId = r.syncId;
  if (syncId == null) {
    syncId = _uuid.v4();
    await (db.update(db.exchangeRateOverrides)
          ..where((row) => row.id.equals(r.id)))
        .write(ExchangeRateOverridesCompanion(syncId: d.Value(syncId)));
  }
  if (!knownSyncIds.contains(syncId)) {
    await changeTracker.recordUserGlobalChange(
      entityType: 'exchange_rate_override',
      entityId: r.id,
      entitySyncId: syncId,
      action: 'upsert',
    );
    backfilled++;
  }
}
```

> F2 的 `backfillUntrackedEntities` 修复草案已同步包含 exchange_rate_override 循环，两处一起改。

---

## 修复顺序建议

1. **F2**（backfill 去重对齐 legacy 范式）—— 根因、零迁移、止住 local_changes 膨胀。**含 F3**。
2. **F1**（deviceId 字段复用）—— 6 行改动、零风险、消除 pull 路径 N+1。
3. F6（push 序列化缓存）/ F5（cursor null 告警）/ F4（注释校正）/ F7（空 catch 记日志）—— 后续小迭代。

F2 的可选 DB 加固（部分唯一索引 v35）建议在 F2 代码修复验证稳定后再做，作为第二道防线。
