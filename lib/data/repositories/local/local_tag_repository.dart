import 'package:drift/drift.dart' as d;
import 'package:uuid/uuid.dart';

import '../../db.dart';
import '../exceptions.dart';
import '../tag_repository.dart';

/// 本地标签Repository实现
/// 基于 Drift 数据库实现
class LocalTagRepository implements TagRepository {
  static const _uuid = Uuid();
  final PiggyDatabase db;

  LocalTagRepository(this.db);

  // ============================================
  // 基础 CRUD 操作
  // ============================================

  @override
  Future<int> createTag({
    required String name,
    String? color,
    int sortOrder = 0,
    String? syncId,
  }) async {
    // 撞同名抛 DuplicateNameException(name 全局唯一)。静默路径(import /
    // 自动记账等)请改用 [upsertTag]。
    final existing =
        await (db.select(db.tags)..where((t) => t.name.equals(name))).get();
    if (existing.isNotEmpty) {
      throw DuplicateNameException(
        entityType: 'tag',
        name: name,
        existingId: existing.first.id,
      );
    }
    return await db.into(db.tags).insert(
      TagsCompanion.insert(
        name: name,
        color: d.Value(color),
        sortOrder: d.Value(sortOrder),
        syncId: d.Value(syncId ?? _uuid.v4()),
      ),
    );
  }

  @override
  Future<int> upsertTag({
    required String name,
    String? color,
  }) async {
    final existing =
        await (db.select(db.tags)..where((t) => t.name.equals(name))).get();
    if (existing.isNotEmpty) return existing.first.id;
    return await db.into(db.tags).insert(
      TagsCompanion.insert(
        name: name,
        color: d.Value(color),
        sortOrder: const d.Value(0),
        syncId: d.Value(_uuid.v4()),
      ),
    );
  }

  @override
  Future<void> updateTag(
    int id, {
    String? name,
    String? color,
    int? sortOrder,
  }) async {
    await (db.update(db.tags)..where((t) => t.id.equals(id))).write(
      TagsCompanion(
        name: name != null ? d.Value(name) : const d.Value.absent(),
        color: color != null ? d.Value(color) : const d.Value.absent(),
        sortOrder: sortOrder != null ? d.Value(sortOrder) : const d.Value.absent(),
      ),
    );
  }

  @override
  Future<void> updateTagSyncId(int id, String syncId) async {
    await (db.update(db.tags)..where((t) => t.id.equals(id))).write(
      TagsCompanion(syncId: d.Value(syncId)),
    );
  }

  @override
  Future<void> deleteTag(int id) async {
    await db.transaction(() async {
      // 先删除关联关系
      await (db.delete(db.transactionTags)
        ..where((t) => t.tagId.equals(id))).go();
      // 再删除标签
      await (db.delete(db.tags)..where((t) => t.id.equals(id))).go();
    });
  }

  @override
  Future<Tag?> getTagById(int id) async {
    return await (db.select(db.tags)
      ..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  @override
  Future<Tag?> getTagByName(String name) async {
    return await (db.select(db.tags)
      ..where((t) => t.name.equals(name))).getSingleOrNull();
  }

  @override
  Future<List<Tag>> getAllTags() async {
    return await (db.select(db.tags)
      ..orderBy([(t) => d.OrderingTerm(expression: t.sortOrder)])).get();
  }

  @override
  Future<void> batchInsertTags(List<TagsCompanion> tags) async {
    await db.batch((batch) {
      batch.insertAll(db.tags, tags);
    });
  }

  // ============================================
  // 交易-标签关联操作
  // ============================================

  @override
  Future<void> addTagToTransaction({
    required int transactionId,
    required int tagId,
  }) async {
    // 检查是否已存在
    final existing = await (db.select(db.transactionTags)
      ..where((t) => t.transactionId.equals(transactionId) & t.tagId.equals(tagId)))
        .getSingleOrNull();

    if (existing == null) {
      await db.into(db.transactionTags).insert(
        TransactionTagsCompanion.insert(
          transactionId: transactionId,
          tagId: tagId,
        ),
      );
    }
  }

  @override
  Future<void> addTagsToTransaction({
    required int transactionId,
    required List<int> tagIds,
  }) async {
    await db.transaction(() async {
      for (final tagId in tagIds) {
        await addTagToTransaction(transactionId: transactionId, tagId: tagId);
      }
    });
  }

  @override
  Future<void> removeTagFromTransaction({
    required int transactionId,
    required int tagId,
  }) async {
    await (db.delete(db.transactionTags)
      ..where((t) => t.transactionId.equals(transactionId) & t.tagId.equals(tagId)))
        .go();
  }

  @override
  Future<void> removeAllTagsFromTransaction(int transactionId) async {
    await (db.delete(db.transactionTags)
      ..where((t) => t.transactionId.equals(transactionId))).go();
  }

  @override
  Future<void> updateTransactionTags({
    required int transactionId,
    required List<int> tagIds,
  }) async {
    await db.transaction(() async {
      // 先删除所有关联
      await removeAllTagsFromTransaction(transactionId);
      // 再添加新的关联
      if (tagIds.isNotEmpty) {
        await addTagsToTransaction(transactionId: transactionId, tagIds: tagIds);
      }
    });
  }

  @override
  Future<List<Tag>> getTagsForTransaction(int transactionId) async {
    final query = db.select(db.tags).join([
      d.innerJoin(
        db.transactionTags,
        db.transactionTags.tagId.equalsExp(db.tags.id),
      ),
    ])..where(db.transactionTags.transactionId.equals(transactionId));

    final rows = await query.get();
    return rows.map((row) => row.readTable(db.tags)).toList();
  }

  @override
  Future<Map<int, List<Tag>>> getTagsForTransactions(List<int> transactionIds) async {
    if (transactionIds.isEmpty) return {};

    final query = db.select(db.transactionTags).join([
      d.innerJoin(
        db.tags,
        db.tags.id.equalsExp(db.transactionTags.tagId),
      ),
    ])..where(db.transactionTags.transactionId.isIn(transactionIds));

    final rows = await query.get();

    final result = <int, List<Tag>>{};
    for (final row in rows) {
      final transactionTag = row.readTable(db.transactionTags);
      final tag = row.readTable(db.tags);
      result.putIfAbsent(transactionTag.transactionId, () => []).add(tag);
    }

    return result;
  }

  @override
  Future<List<int>> getTransactionIdsByTag(int tagId) async {
    final rows = await (db.select(db.transactionTags)
      ..where((t) => t.tagId.equals(tagId))).get();
    return rows.map((r) => r.transactionId).toList();
  }

  // ============================================
  // 统计查询
  // ============================================

  @override
  Future<int> getTransactionCountByTag(int tagId) async {
    final result = await db.customSelect(
      'SELECT COUNT(*) AS count FROM transaction_tags WHERE tag_id = ?',
      variables: [d.Variable.withInt(tagId)],
      readsFrom: {db.transactionTags},
    ).getSingle();

    final count = result.data['count'];
    if (count is int) return count;
    if (count is BigInt) return count.toInt();
    if (count is num) return count.toInt();
    return 0;
  }

  @override
  Future<Map<int, int>> getAllTagTransactionCounts() async {
    final result = await db.customSelect(
      '''
      SELECT
        t.id as tag_id,
        COALESCE(COUNT(tt.id), 0) as transaction_count
      FROM tags t
      LEFT JOIN transaction_tags tt ON t.id = tt.tag_id
      GROUP BY t.id
      ''',
      readsFrom: {db.tags, db.transactionTags},
    ).get();

    final Map<int, int> counts = {};
    for (final row in result) {
      final tagId = row.data['tag_id'];
      final count = row.data['transaction_count'];

      if (tagId is int) {
        int countInt = 0;
        if (count is int) {
          countInt = count;
        } else if (count is BigInt) {
          countInt = count.toInt();
        } else if (count is num) {
          countInt = count.toInt();
        }
        counts[tagId] = countInt;
      }
    }

    return counts;
  }

  @override
  Future<({int count, double expense, double income})> getTagStats(int tagId,
      {int? ledgerId, DateTime? start, DateTime? end}) async {
    final ledgerFilter = ledgerId != null ? 'AND tx.ledger_id = ?' : '';
    // 半开区间 [start, end):移植 BeeCount #461 的时间维度筛选
    final startFilter = start != null ? 'AND tx.happened_at >= ?' : '';
    final endFilter = end != null ? 'AND tx.happened_at < ?' : '';
    final vars = <d.Variable>[d.Variable.withInt(tagId)];
    if (ledgerId != null) vars.add(d.Variable.withInt(ledgerId));
    if (start != null) vars.add(d.Variable.withDateTime(start));
    if (end != null) vars.add(d.Variable.withDateTime(end));
    final result = await db.customSelect(
      '''
      SELECT
        COUNT(*) as count,
        COALESCE(SUM(CASE WHEN tx.type = 'expense' AND tx.exclude_from_stats = 0 THEN COALESCE(tx.native_amount, tx.amount) ELSE 0 END), 0) as expense,
        COALESCE(SUM(CASE WHEN tx.type = 'income' AND tx.exclude_from_stats = 0 THEN COALESCE(tx.native_amount, tx.amount) ELSE 0 END), 0) as income
      FROM transaction_tags tt
      INNER JOIN transactions tx ON tt.transaction_id = tx.id
      WHERE tt.tag_id = ? $ledgerFilter $startFilter $endFilter
      ''',
      variables: vars,
      readsFrom: {db.transactionTags, db.transactions},
    ).getSingle();

    int parseCount(dynamic v) {
      if (v is int) return v;
      if (v is BigInt) return v.toInt();
      if (v is num) return v.toInt();
      return 0;
    }

    double parseAmount(dynamic v) {
      if (v == null) return 0.0;
      if (v is double) return v;
      if (v is int) return v.toDouble();
      if (v is BigInt) return v.toDouble();
      if (v is num) return v.toDouble();
      return 0.0;
    }

    return (
      count: parseCount(result.data['count']),
      expense: parseAmount(result.data['expense']),
      income: parseAmount(result.data['income']),
    );
  }

  @override
  Future<List<Transaction>> getTransactionsByTag(int tagId) async {
    final query = db.select(db.transactions).join([
      d.innerJoin(
        db.transactionTags,
        db.transactionTags.transactionId.equalsExp(db.transactions.id),
      ),
    ])
      ..where(db.transactionTags.tagId.equals(tagId))
      ..orderBy([d.OrderingTerm(expression: db.transactions.happenedAt, mode: d.OrderingMode.desc)]);

    final rows = await query.get();
    return rows.map((row) => row.readTable(db.transactions)).toList();
  }

  @override
  Future<List<Transaction>> getTransactionsByTagInRange({
    required int tagId,
    required DateTime start,
    required DateTime end,
  }) async {
    final query = db.select(db.transactions).join([
      d.innerJoin(
        db.transactionTags,
        db.transactionTags.transactionId.equalsExp(db.transactions.id),
      ),
    ])
      ..where(
        db.transactionTags.tagId.equals(tagId) &
        db.transactions.happenedAt.isBiggerOrEqualValue(start) &
        db.transactions.happenedAt.isSmallerThanValue(end),
      )
      ..orderBy([d.OrderingTerm(expression: db.transactions.happenedAt, mode: d.OrderingMode.desc)]);

    final rows = await query.get();
    return rows.map((row) => row.readTable(db.transactions)).toList();
  }

  // ============================================
  // 响应式监听
  // ============================================

  @override
  Stream<List<Tag>> watchAllTags() {
    return (db.select(db.tags)
      ..orderBy([(t) => d.OrderingTerm(expression: t.sortOrder)])).watch();
  }

  @override
  Stream<List<({Tag tag, int transactionCount})>> watchTagsWithStats() async* {
    await for (final rows in db.customSelect(
      '''
      SELECT
        t.id as tag_id,
        t.name as tag_name,
        t.color as tag_color,
        t.sort_order as tag_sort_order,
        t.created_at as tag_created_at,
        COALESCE(COUNT(tt.id), 0) as transaction_count
      FROM tags t
      LEFT JOIN transaction_tags tt ON t.id = tt.tag_id
      GROUP BY t.id, t.name, t.color, t.sort_order, t.created_at
      ORDER BY t.sort_order
      ''',
      readsFrom: {db.tags, db.transactionTags},
    ).watch()) {
      final results = <({Tag tag, int transactionCount})>[];

      for (final row in rows) {
        final tag = Tag(
          id: row.read<int>('tag_id'),
          name: row.read<String>('tag_name'),
          color: row.read<String?>('tag_color'),
          sortOrder: row.read<int>('tag_sort_order'),
          createdAt: row.read<DateTime>('tag_created_at'),
        );
        final count = row.read<int>('transaction_count');

        results.add((tag: tag, transactionCount: count));
      }

      yield results;
    }
  }

  @override
  Stream<Tag?> watchTag(int tagId) {
    return (db.select(db.tags)
      ..where((t) => t.id.equals(tagId))).watchSingleOrNull();
  }

  @override
  Stream<List<Tag>> watchTagsForTransaction(int transactionId) {
    return db.customSelect(
      '''
      SELECT t.*
      FROM tags t
      INNER JOIN transaction_tags tt ON t.id = tt.tag_id
      WHERE tt.transaction_id = ?
      ORDER BY t.sort_order
      ''',
      variables: [d.Variable.withInt(transactionId)],
      readsFrom: {db.tags, db.transactionTags},
    ).watch().map((rows) {
      return rows.map((row) {
        return Tag(
          id: row.read<int>('id'),
          name: row.read<String>('name'),
          color: row.read<String?>('color'),
          sortOrder: row.read<int>('sort_order'),
          createdAt: row.read<DateTime>('created_at'),
        );
      }).toList();
    });
  }

  @override
  Stream<List<Transaction>> watchTransactionsByTag(int tagId,
      {int? ledgerId, DateTime? start, DateTime? end}) {
    // drift join + readTable 全字段映射;旧手写映射漏掉 currencyCode/
    // nativeAmount 等列,外币交易在详情页显示会错(移植 BeeCount #461 顺带修复)。
    final query = db.select(db.transactions).join([
      d.innerJoin(
        db.transactionTags,
        db.transactionTags.transactionId.equalsExp(db.transactions.id),
      ),
    ])
      ..where(db.transactionTags.tagId.equals(tagId))
      ..orderBy([
        d.OrderingTerm(
            expression: db.transactions.happenedAt, mode: d.OrderingMode.desc),
      ]);
    if (ledgerId != null) {
      query.where(db.transactions.ledgerId.equals(ledgerId));
    }
    if (start != null) {
      query.where(db.transactions.happenedAt.isBiggerOrEqualValue(start));
    }
    if (end != null) {
      query.where(db.transactions.happenedAt.isSmallerThanValue(end));
    }
    return query.watch().map(
        (rows) => rows.map((row) => row.readTable(db.transactions)).toList());
  }

  // ============================================
  // 辅助方法
  // ============================================

  @override
  Future<bool> isTagNameDuplicate({
    required String name,
    int? excludeId,
  }) async {
    var expression = db.tags.name.equals(name);

    if (excludeId != null) {
      expression = expression & db.tags.id.equals(excludeId).not();
    }

    final query = db.select(db.tags)..where((t) => expression);
    final results = await query.get();
    return results.isNotEmpty;
  }

  @override
  Future<void> updateTagSortOrders(List<({int id, int sortOrder})> updates) async {
    await db.transaction(() async {
      for (final update in updates) {
        await (db.update(db.tags)..where((t) => t.id.equals(update.id)))
            .write(TagsCompanion(sortOrder: d.Value(update.sortOrder)));
      }
    });
  }

  @override
  Future<List<Tag>> getRecentlyUsedTags({int limit = 10}) async {
    // 获取最近使用的标签（按最后使用时间排序）
    final result = await db.customSelect(
      '''
      SELECT t.*, MAX(tx.happened_at) as last_used
      FROM tags t
      INNER JOIN transaction_tags tt ON t.id = tt.tag_id
      INNER JOIN transactions tx ON tt.transaction_id = tx.id
      GROUP BY t.id
      ORDER BY last_used DESC
      LIMIT ?
      ''',
      variables: [d.Variable.withInt(limit)],
      readsFrom: {db.tags, db.transactionTags, db.transactions},
    ).get();

    return result.map((row) {
      return Tag(
        id: row.read<int>('id'),
        name: row.read<String>('name'),
        color: row.read<String?>('color'),
        sortOrder: row.read<int>('sort_order'),
        createdAt: row.read<DateTime>('created_at'),
      );
    }).toList();
  }
}
