import 'package:drift/drift.dart' as d;
import 'package:uuid/uuid.dart';

import '../../db.dart';
import '../ledger_repository.dart';

const _uuid = Uuid();

/// 本地账本Repository实现
/// 基于 Drift 数据库实现
class LocalLedgerRepository implements LedgerRepository {
  final PiggyDatabase db;

  LocalLedgerRepository(this.db);

  @override
  Stream<List<Ledger>> watchLedgers() => db.select(db.ledgers).watch();

  @override
  Future<List<Ledger>> getAllLedgers() async {
    return db.select(db.ledgers).get();
  }

  @override
  Future<Ledger?> getLedgerById(int id) async {
    final query = db.select(db.ledgers)..where((l) => l.id.equals(id));
    final results = await query.get();
    return results.isEmpty ? null : results.first;
  }

  @override
  Future<int> getLedgerCount() async {
    final row = await db.customSelect('SELECT COUNT(*) AS c FROM ledgers',
        readsFrom: {db.ledgers}).getSingle();
    final v = row.data['c'];
    if (v is int) return v;
    if (v is BigInt) return v.toInt();
    return 0;
  }

  @override
  Future<int> ledgerCount() => getLedgerCount();

  @override
  Future<({int dayCount, int txCount})> getCountsForLedger({
    required int ledgerId,
  }) async {
    final txRow = await db.customSelect(
        'SELECT COUNT(*) AS c FROM transactions WHERE ledger_id = ?1',
        variables: [d.Variable.withInt(ledgerId)],
        readsFrom: {db.transactions}).getSingle();
    // 计算记账天数：今天 - 第一笔记账日期 + 1
    final dayRow = await db.customSelect("""
      SELECT CASE
        WHEN MIN(happened_at) IS NULL THEN 0
        ELSE CAST(julianday('now', 'localtime') - julianday(MIN(happened_at), 'unixepoch', 'localtime') + 1 AS INTEGER)
      END AS c
      FROM transactions WHERE ledger_id = ?1
      """,
        variables: [d.Variable.withInt(ledgerId)],
        readsFrom: {db.transactions}).getSingle();

    int parse(dynamic v) {
      if (v is int) return v;
      if (v is BigInt) return v.toInt();
      if (v is num) return v.toInt();
      return 0;
    }

    return (dayCount: parse(dayRow.data['c']), txCount: parse(txRow.data['c']));
  }

  @override
  Future<({int dayCount, int txCount})> getCountsAll() async {
    final txRow = await db.customSelect(
      'SELECT COUNT(*) AS c FROM transactions',
      readsFrom: {db.transactions},
    ).getSingle();
    // 计算记账天数：今天 - 第一笔记账日期 + 1
    final dayRow = await db.customSelect(
      """
      SELECT CASE
        WHEN MIN(happened_at) IS NULL THEN 0
        ELSE CAST(julianday('now', 'localtime') - julianday(MIN(happened_at), 'unixepoch', 'localtime') + 1 AS INTEGER)
      END AS c
      FROM transactions
      """,
      readsFrom: {db.transactions},
    ).getSingle();

    int parse(dynamic v) {
      if (v is int) return v;
      if (v is BigInt) return v.toInt();
      if (v is num) return v.toInt();
      return 0;
    }

    return (dayCount: parse(dayRow.data['c']), txCount: parse(txRow.data['c']));
  }

  @override
  Future<({double balance, int transactionCount})> getLedgerStats({
    required int ledgerId,
    bool accountFeatureEnabled = true,
    List<Transaction>? transactions,
  }) async {
    // 调用方已持有交易行（如共享同一批数据的批量统计）时直接内存累加，
    // 不再回库。
    if (transactions != null) {
      return _statsFromRows(transactions);
    }

    // 单账本：一条 GROUP BY 聚合 SQL。此前把该账本全部交易行加载进内存
    // 再逐行累加 —— 万笔账本每次状态刷新都全量分配行对象（isolate 间
    // 传输 + GC 压力），SUM/CASE 在 SQLite 引擎内完成只需一行结果。
    // 余额口径与 _statsFromRows 完全一致：nativeAmount ?? amount 兜底、
    // income 加 / expense 减 / **transfer 不计入**（同一账户间转移不
    // 改变账本总余额）。
    final row = await db
        .customSelect(
          'SELECT COUNT(*) AS cnt, '
          "COALESCE(SUM(CASE type WHEN 'income' THEN 1 "
          "WHEN 'expense' THEN -1 ELSE 0 END "
          '* COALESCE(native_amount, amount)), 0) AS balance '
          'FROM transactions WHERE ledger_id = ?1',
          variables: [d.Variable.withInt(ledgerId)],
          readsFrom: {db.transactions},
        )
        .getSingle();
    int parseCount(dynamic v) {
      if (v is int) return v;
      if (v is BigInt) return v.toInt();
      if (v is num) return v.toInt();
      return 0;
    }

    return (
      balance: (row.data['balance'] as num?)?.toDouble() ?? 0.0,
      transactionCount: parseCount(row.data['cnt']),
    );
  }

  /// 从已有交易行内存累加统计（口径与 SQL 聚合版严格一致）。
  static ({double balance, int transactionCount}) _statsFromRows(
      List<Transaction> rows) {
    double balance = 0.0;
    for (final t in rows) {
      final v = t.nativeAmount ?? t.amount;
      if (t.type == 'income') {
        balance += v;
      } else if (t.type == 'expense') {
        balance -= v;
      }
      // transfer 不影响总余额
    }
    return (balance: balance, transactionCount: rows.length);
  }

  @override
  Future<Map<int, ({double balance, int transactionCount})>>
      getAllLedgerStats() async {
    // 一条 GROUP BY 返回所有账本聚合（无交易的账本聚合行缺失，由
    // ledgers 表补零 —— 列表页需要给空账本显示 0/0.00 而非缺条目）。
    final rows = await db
        .customSelect(
          'SELECT l.id AS id, '
          'COALESCE(a.cnt, 0) AS cnt, COALESCE(a.balance, 0) AS balance '
          'FROM ledgers l LEFT JOIN ('
          '  SELECT ledger_id, COUNT(*) AS cnt, '
          "  SUM(CASE type WHEN 'income' THEN 1 WHEN 'expense' THEN -1 "
          '  ELSE 0 END * COALESCE(native_amount, amount)) AS balance '
          '  FROM transactions GROUP BY ledger_id'
          ') a ON a.ledger_id = l.id',
          readsFrom: {db.ledgers, db.transactions},
        )
        .get();
    return {
      for (final row in rows)
        row.read<int>('id'): (
          balance: (row.data['balance'] as num?)?.toDouble() ?? 0.0,
          transactionCount: row.read<int>('cnt'),
        ),
    };
  }

  @override
  Future<int> createLedger({
    required String name,
    String currency = 'CNY',
  }) async {
    // syncId 是跨设备稳定外键。新建账本必须现场写入 UUID，否则 push 侧
    // 的 `ledger.syncId ?? ledger.id.toString()` 会 fallback 到本地 int id，
    // 第二台设备本地 int id 不同 → server 会 auto-create 一个 external_id
    // 为本地 int id 字符串的 duplicate ledger。
    return db.into(db.ledgers).insert(
          LedgersCompanion.insert(
            name: name,
            currency: d.Value(currency),
            syncId: d.Value(_uuid.v4()),
          ),
        );
  }

  @override
  Future<void> updateLedgerName({required int id, required String name}) async {
    await (db.update(db.ledgers)..where((tbl) => tbl.id.equals(id))).write(
      LedgersCompanion(name: d.Value(name)),
    );
  }

  @override
  Future<void> updateLedger({
    required int id,
    String? name,
    String? currency,
    int? monthStartDay,
  }) async {
    final comp = LedgersCompanion(
      name: name != null ? d.Value(name) : const d.Value.absent(),
      currency: currency != null ? d.Value(currency) : const d.Value.absent(),
      monthStartDay: monthStartDay != null
          ? d.Value(monthStartDay.clamp(1, 28))
          : const d.Value.absent(),
    );
    await (db.update(db.ledgers)..where((tbl) => tbl.id.equals(id)))
        .write(comp);
  }

  @override
  Stream<Ledger?> watchLedger(int id) {
    return (db.select(db.ledgers)..where((l) => l.id.equals(id)))
        .watchSingleOrNull();
  }

  @override
  Future<void> deleteLedger(int id) async {
    // 先删除该账本下的所有交易，再删除账本本身
    await db.transaction(() async {
      await (db.delete(db.transactions)..where((t) => t.ledgerId.equals(id)))
          .go();
      await (db.delete(db.ledgers)..where((tbl) => tbl.id.equals(id))).go();
    });
  }

  @override
  Future<int> getMaxLedgerId() async {
    final row = await db.customSelect(
        'SELECT IFNULL(MAX(id), 0) AS m FROM ledgers',
        readsFrom: {db.ledgers}).getSingle();
    final v = row.data['m'];
    if (v is int) return v;
    if (v is BigInt) return v.toInt();
    if (v is num) return v.toInt();
    return 0;
  }

  @override
  Future<int> getNextFreeLedgerId() async {
    final maxId = await getMaxLedgerId();
    return maxId + 1;
  }

  @override
  Future<void> reassignLedgerId({
    required int fromId,
    required int toId,
  }) async {
    if (fromId == toId) return;
    final existsTo = await (db.select(db.ledgers)
          ..where((l) => l.id.equals(toId)))
        .getSingleOrNull();
    if (existsTo != null) {
      throw StateError('目标账本ID已存在: $toId');
    }
    await db.transaction(() async {
      // 先迁移子表中的外键引用
      await db.customUpdate(
        'UPDATE accounts SET ledger_id = ?1 WHERE ledger_id = ?2',
        variables: [d.Variable<int>(toId), d.Variable<int>(fromId)],
        updates: {db.accounts},
      );
      await db.customUpdate(
        'UPDATE transactions SET ledger_id = ?1 WHERE ledger_id = ?2',
        variables: [d.Variable<int>(toId), d.Variable<int>(fromId)],
        updates: {db.transactions},
      );
      // v46：自定义字段定义是 ledger-scoped，账本 ID 迁移时必须跟随，
      // 否则定义会留在旧 id 下（新 id 看不到字段，编辑表单失去录入位）。
      await db.customUpdate(
        'UPDATE custom_field_definitions SET ledger_id = ?1 WHERE ledger_id = ?2',
        variables: [d.Variable<int>(toId), d.Variable<int>(fromId)],
        updates: {db.customFieldDefinitions},
      );
      // 再更新主表ID（SQLite 允许更新 INTEGER PRIMARY KEY 的值）
      await db.customUpdate(
        'UPDATE ledgers SET id = ?1 WHERE id = ?2',
        variables: [d.Variable<int>(toId), d.Variable<int>(fromId)],
        updates: {db.ledgers},
      );
    });
  }

  @override
  Future<int> clearLedgerTransactions(int ledgerId) async {
    // 先查询该账本所有交易ID
    final txIds = await (db.select(db.transactions)
          ..where((t) => t.ledgerId.equals(ledgerId)))
        .map((t) => t.id)
        .get();

    if (txIds.isNotEmpty) {
      // 删除关联的 transaction_tags
      await (db.delete(db.transactionTags)
            ..where((tt) => tt.transactionId.isIn(txIds)))
          .go();

      // 删除关联的 transaction_attachments
      await (db.delete(db.transactionAttachments)
            ..where((a) => a.transactionId.isIn(txIds)))
          .go();
    }

    // 删除 transactions
    final count = await (db.delete(db.transactions)
          ..where((t) => t.ledgerId.equals(ledgerId)))
        .go();
    return count;
  }

  @override
  /// ⚠️ 审计 U12：initial_balance 为各账户**各自币种**的金额，本方法
  /// 裸加不分币种——仅当账本内所有账户同币种时结果正确。当前无调用方。
  Future<double> getTotalInitialBalance(int ledgerId) async {
    final accounts = await (db.select(db.accounts)
          ..where((a) => a.ledgerId.equals(ledgerId)))
        .get();

    double total = 0.0;
    for (final account in accounts) {
      total += account.initialBalance;
    }
    return total;
  }
}
