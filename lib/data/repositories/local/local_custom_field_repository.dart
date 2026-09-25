import 'package:drift/drift.dart' as d;
import 'package:uuid/uuid.dart';

import '../../../cloud/sync/change_tracker.dart';
import '../../db.dart';
import '../../models/custom_field_values.dart';
import '../custom_field_repository.dart';
import '../exceptions.dart';

/// v46 本地自定义字段仓储实现（Drift）。
///
/// 变更登记：定义是 **ledger-scoped** 实体，用 `recordLedgerChange`
/// （entityType `custom_field`）。删除定义时对每笔被清理值的交易补记
/// `transaction` 的 update —— 值散落在交易行上，不记则其他设备残留幽灵值。
///
/// tracker 用 getter 闭包注入：`LocalRepository.changeTracker` 是构造后才赋值
/// 的可变字段，直接传引用会捕获 null（同 LocalExchangeRateRepository 的避坑）。
class LocalCustomFieldRepository implements CustomFieldRepository {
  static const _uuid = Uuid();

  final PiggyDatabase db;
  final ChangeTracker? Function() trackerGetter;

  LocalCustomFieldRepository(this.db, {required this.trackerGetter});

  // ============================================
  // 字段定义 CRUD
  // ============================================

  @override
  Future<int> createDefinition({
    required int ledgerId,
    required String name,
    required String fieldType,
    int sortOrder = 0,
    String? syncId,
  }) async {
    final trimmed = name.trim();
    final dup = await (db.select(db.customFieldDefinitions)
          ..where((t) =>
              t.ledgerId.equals(ledgerId) & t.name.equals(trimmed)))
        .getSingleOrNull();
    if (dup != null) {
      throw DuplicateNameException(
        entityType: 'custom_field',
        name: trimmed,
        existingId: dup.id,
      );
    }
    final effectiveSyncId =
        (syncId != null && syncId.trim().isNotEmpty) ? syncId.trim() : _uuid.v4();
    return db.transaction(() async {
      final id = await db.into(db.customFieldDefinitions).insert(
            CustomFieldDefinitionsCompanion.insert(
              ledgerId: ledgerId,
              name: trimmed,
              fieldType: fieldType,
              sortOrder: d.Value(sortOrder),
              syncId: d.Value(effectiveSyncId),
            ),
          );
      await _recordDefinitionChange(
        entityId: id,
        entitySyncId: effectiveSyncId,
        ledgerId: ledgerId,
        action: 'create',
      );
      return id;
    });
  }

  @override
  Future<int> upsertDefinition({
    required int ledgerId,
    required String name,
    required String fieldType,
    int? sortOrder,
    String? syncId,
  }) async {
    final trimmed = name.trim();
    // 先按 syncId 锚定（导入/恢复路径的稳定身份优先）。
    if (syncId != null && syncId.trim().isNotEmpty) {
      final bySync = await getDefinitionBySyncId(syncId.trim());
      if (bySync != null) return bySync.id;
    }
    final byName = await (db.select(db.customFieldDefinitions)
          ..where((t) =>
              t.ledgerId.equals(ledgerId) & t.name.equals(trimmed)))
        .getSingleOrNull();
    if (byName != null) {
      // 补全远端标识（本地旧库/seed 缺 syncId）。不记 change：同 syncId 幂等。
      if ((byName.syncId == null || byName.syncId!.isEmpty) &&
          syncId != null &&
          syncId.trim().isNotEmpty) {
        await updateDefinitionSyncId(byName.id, syncId.trim());
      }
      return byName.id;
    }
    return createDefinition(
      ledgerId: ledgerId,
      name: trimmed,
      fieldType: fieldType,
      sortOrder: sortOrder ?? 0,
      syncId: syncId,
    );
  }

  @override
  Future<void> updateDefinition(
    int id, {
    String? name,
    String? fieldType,
    int? sortOrder,
  }) async {
    final row = await getDefinitionById(id);
    if (row == null) return;
    final newName = name?.trim();
    if (newName != null && newName.isNotEmpty && newName != row.name) {
      final dup = await (db.select(db.customFieldDefinitions)
            ..where((t) =>
                t.ledgerId.equals(row.ledgerId) & t.name.equals(newName)))
          .getSingleOrNull();
      if (dup != null) {
        throw DuplicateNameException(
          entityType: 'custom_field',
          name: newName,
          existingId: dup.id,
        );
      }
    }
    await db.transaction(() async {
      await (db.update(db.customFieldDefinitions)..where((t) => t.id.equals(id)))
          .write(CustomFieldDefinitionsCompanion(
        name: (newName != null && newName.isNotEmpty)
            ? d.Value(newName)
            : const d.Value.absent(),
        fieldType: fieldType != null ? d.Value(fieldType) : const d.Value.absent(),
        sortOrder: sortOrder != null ? d.Value(sortOrder) : const d.Value.absent(),
      ));
      if (row.syncId != null && row.syncId!.isNotEmpty) {
        await _recordDefinitionChange(
          entityId: id,
          entitySyncId: row.syncId!,
          ledgerId: row.ledgerId,
          action: 'update',
        );
      }
    });
  }

  @override
  Future<void> deleteDefinition(int id) async {
    final row = await getDefinitionById(id);
    if (row == null) return;
    await db.transaction(() async {
      final syncId = row.syncId;
      // 先清理值再删定义：值以 fieldSyncId 为键散落在交易行与周期模板上，
      // 残留键既无法渲染（定义没了）又会让快照带着幽灵字段。
      if (syncId != null && syncId.isNotEmpty) {
        await _stripValueKeyForLedger(
          ledgerId: row.ledgerId,
          fieldSyncId: syncId,
        );
        // v47：周期账单模板也是值的载体（template_field_values），一并清。
        // 漏掉这步的话，模板残留的幽灵键会被生成器整包注入新生成的实例。
        await _stripTemplateValueKeyForLedger(
          ledgerId: row.ledgerId,
          fieldSyncId: syncId,
        );
      }
      await (db.delete(db.customFieldDefinitions)..where((t) => t.id.equals(id)))
          .go();
      if (syncId != null && syncId.isNotEmpty) {
        await _recordDefinitionChange(
          entityId: id,
          entitySyncId: syncId,
          ledgerId: row.ledgerId,
          action: 'delete',
        );
      }
    });
  }

  @override
  Future<void> updateDefinitionSyncId(int id, String syncId) async {
    await (db.update(db.customFieldDefinitions)..where((t) => t.id.equals(id)))
        .write(CustomFieldDefinitionsCompanion(syncId: d.Value(syncId)));
  }

  @override
  Future<CustomFieldDefinition?> getDefinitionById(int id) {
    return (db.select(db.customFieldDefinitions)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  @override
  Future<CustomFieldDefinition?> getDefinitionBySyncId(String syncId) {
    return (db.select(db.customFieldDefinitions)
          ..where((t) => t.syncId.equals(syncId)))
        .getSingleOrNull();
  }

  @override
  Future<List<CustomFieldDefinition>> getDefinitionsForLedger(int ledgerId) {
    return (db.select(db.customFieldDefinitions)
          ..where((t) => t.ledgerId.equals(ledgerId))
          ..orderBy([
            (t) => d.OrderingTerm.asc(t.sortOrder),
            (t) => d.OrderingTerm.asc(t.id),
          ]))
        .get();
  }

  @override
  Stream<List<CustomFieldDefinition>> watchDefinitionsForLedger(int ledgerId) {
    return (db.select(db.customFieldDefinitions)
          ..where((t) => t.ledgerId.equals(ledgerId))
          ..orderBy([
            (t) => d.OrderingTerm.asc(t.sortOrder),
            (t) => d.OrderingTerm.asc(t.id),
          ]))
        .watch();
  }

  @override
  Future<void> updateDefinitionSortOrders(
      List<({int id, int sortOrder})> updates) async {
    if (updates.isEmpty) return;
    await db.transaction(() async {
      for (final u in updates) {
        await (db.update(db.customFieldDefinitions)..where((t) => t.id.equals(u.id)))
            .write(CustomFieldDefinitionsCompanion(
                sortOrder: d.Value(u.sortOrder)));
        final row = await getDefinitionById(u.id);
        if (row?.syncId != null && row!.syncId!.isNotEmpty) {
          await _recordDefinitionChange(
            entityId: u.id,
            entitySyncId: row.syncId!,
            ledgerId: row.ledgerId,
            action: 'update',
          );
        }
      }
    });
  }

  @override
  Future<bool> isFieldNameDuplicate({
    required int ledgerId,
    required String name,
    int? excludeId,
  }) async {
    var expr = db.customFieldDefinitions.ledgerId.equals(ledgerId) &
        db.customFieldDefinitions.name.equals(name.trim());
    if (excludeId != null) {
      expr = expr & db.customFieldDefinitions.id.equals(excludeId).not();
    }
    final rows =
        await (db.select(db.customFieldDefinitions)..where((t) => expr)).get();
    return rows.isNotEmpty;
  }

  // ============================================
  // 交易值读写
  // ============================================

  @override
  Future<Map<String, dynamic>> getValuesForTransaction(int transactionId) async {
    final row = await (db.select(db.transactions)
          ..where((t) => t.id.equals(transactionId)))
        .getSingleOrNull();
    return CustomFieldValueCodec.decode(row?.customValuesJson);
  }

  @override
  Future<Map<int, Map<String, dynamic>>> getValuesForTransactions(
      List<int> transactionIds) async {
    if (transactionIds.isEmpty) return const {};
    final rows = await (db.select(db.transactions)
          ..where((t) =>
              t.id.isIn(transactionIds) & t.customValuesJson.isNotNull()))
        .get();
    final out = <int, Map<String, dynamic>>{};
    for (final tx in rows) {
      final values = CustomFieldValueCodec.decode(tx.customValuesJson);
      if (values.isNotEmpty) out[tx.id] = values;
    }
    return out;
  }

  @override
  Future<void> setValuesForTransaction(
      int transactionId, Map<String, dynamic>? values) async {
    // null = 不改动（调用方语义）。
    if (values == null) return;
    final tx = await (db.select(db.transactions)
          ..where((t) => t.id.equals(transactionId)))
        .getSingleOrNull();
    if (tx == null) return;
    await db.transaction(() async {
      await (db.update(db.transactions)..where((t) => t.id.equals(transactionId)))
          .write(TransactionsCompanion(
        // 空 map → encode 返回 null → 列写 NULL（清空）。
        customValuesJson: d.Value(CustomFieldValueCodec.encode(values)),
      ));
      if (tx.syncId != null && tx.syncId!.isNotEmpty) {
        await _recordTransactionChange(
          entityId: transactionId,
          entitySyncId: tx.syncId!,
          ledgerId: tx.ledgerId,
        );
      }
    });
  }

  @override
  Future<int> countTransactionsWithValues(int ledgerId) async {
    final row = await db.customSelect(
      'SELECT COUNT(*) AS c FROM transactions '
      'WHERE ledger_id = ? AND custom_values_json IS NOT NULL',
      variables: [d.Variable.withInt(ledgerId)],
      readsFrom: {db.transactions},
    ).getSingle();
    final v = row.data['c'];
    if (v is int) return v;
    if (v is BigInt) return v.toInt();
    if (v is num) return v.toInt();
    return 0;
  }

  // ============================================
  // 内部：值清理与变更登记
  // ============================================

  /// 移除某账本全部交易里指定字段的值。
  ///
  /// LIKE 粗筛（含 `%fieldSyncId%`）+ Dart 精确判定：不依赖 SQLite JSON1，
  /// 也不全表解析。syncId 含 LIKE 通配符时只会多匹配（假阳性），由精判剔除，
  /// 不会漏改。
  Future<void> _stripValueKeyForLedger({
    required int ledgerId,
    required String fieldSyncId,
  }) async {
    final rows = await (db.select(db.transactions)
          ..where((t) =>
              t.ledgerId.equals(ledgerId) &
              t.customValuesJson.isNotNull() &
              t.customValuesJson.like('%$fieldSyncId%')))
        .get();
    if (rows.isEmpty) return;
    for (final tx in rows) {
      final values =
          Map<String, dynamic>.from(CustomFieldValueCodec.decode(tx.customValuesJson));
      if (!values.containsKey(fieldSyncId)) continue;
      values.remove(fieldSyncId);
      await (db.update(db.transactions)..where((t) => t.id.equals(tx.id)))
          .write(TransactionsCompanion(
        customValuesJson: d.Value(CustomFieldValueCodec.encode(values)),
      ));
      if (tx.syncId != null && tx.syncId!.isNotEmpty) {
        await _recordTransactionChange(
          entityId: tx.id,
          entitySyncId: tx.syncId!,
          ledgerId: tx.ledgerId,
        );
      }
    }
  }

  /// v47：移除某账本全部周期账单模板里指定字段的值（同
  /// [_stripValueKeyForLedger] 的粗筛+精判策略）。模板值不是逐行记账的
  /// 业务变更（生成进度/模板整行以快照为准传播），不另记 change。
  Future<void> _stripTemplateValueKeyForLedger({
    required int ledgerId,
    required String fieldSyncId,
  }) async {
    final rows = await (db.select(db.recurringTransactions)
          ..where((t) =>
              t.ledgerId.equals(ledgerId) &
              t.templateFieldValues.isNotNull() &
              t.templateFieldValues.like('%$fieldSyncId%')))
        .get();
    for (final r in rows) {
      final values = Map<String, dynamic>.from(
          CustomFieldValueCodec.decode(r.templateFieldValues));
      if (!values.containsKey(fieldSyncId)) continue;
      values.remove(fieldSyncId);
      await (db.update(db.recurringTransactions)
            ..where((t) => t.id.equals(r.id)))
          .write(RecurringTransactionsCompanion(
        templateFieldValues:
            d.Value(CustomFieldValueCodec.encode(values)),
      ));
    }
  }

  Future<void> _recordDefinitionChange({
    required int entityId,
    required String entitySyncId,
    required int ledgerId,
    required String action,
  }) async {
    final tracker = trackerGetter();
    if (tracker == null || ledgerId <= 0) return;
    await tracker.recordLedgerChange(
      entityType: 'custom_field',
      entityId: entityId,
      entitySyncId: entitySyncId,
      ledgerId: ledgerId,
      action: action,
    );
  }

  Future<void> _recordTransactionChange({
    required int entityId,
    required String entitySyncId,
    required int ledgerId,
  }) async {
    final tracker = trackerGetter();
    if (tracker == null || ledgerId <= 0) return;
    await tracker.recordLedgerChange(
      entityType: 'transaction',
      entityId: entityId,
      entitySyncId: entitySyncId,
      ledgerId: ledgerId,
      action: 'update',
    );
  }
}
