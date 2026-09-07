import 'package:drift/drift.dart' as d;
import 'package:uuid/uuid.dart';

import '../../db.dart';
import '../recurring_transaction_repository.dart';

const _uuid = Uuid();

/// 本地周期记账Repository实现
/// 基于 Drift 数据库实现
class LocalRecurringTransactionRepository implements RecurringTransactionRepository {
  final PiggyDatabase db;

  LocalRecurringTransactionRepository(this.db);

  @override
  Future<List<RecurringTransaction>> getAllRecurringTransactions() async {
    return await (db.select(db.recurringTransactions)).get();
  }

  @override
  Future<List<RecurringTransaction>> getRecurringTransactionsByLedger(int ledgerId) async {
    return await (db.select(db.recurringTransactions)
          ..where((t) => t.ledgerId.equals(ledgerId)))
        .get();
  }

  @override
  Future<List<RecurringTransaction>> getEnabledRecurringTransactions(int ledgerId) async {
    return await (db.select(db.recurringTransactions)
          ..where((t) => t.ledgerId.equals(ledgerId) & t.enabled.equals(true)))
        .get();
  }

  @override
  Future<int> addRecurringTransaction({
    required int ledgerId,
    required String type,
    required double amount,
    int? categoryId,
    int? accountId,
    int? toAccountId,
    String? note,
    required String frequency,
    required int interval,
    int? dayOfMonth,
    int? dayOfWeek,
    int? monthOfYear,
    required DateTime startDate,
    DateTime? endDate,
    bool enabled = true,
    String? syncId,
    String? currencyCode,
  }) async {
    // 每条新规则分配 syncId（导入路径显式传，UI 路径生成）—— v8 快照与
    // Cloud 引擎都靠它做跨设备锚定；缺失时业务键匹配是兜底而非主路径。
    return await db.into(db.recurringTransactions).insert(
      RecurringTransactionsCompanion.insert(
        ledgerId: ledgerId,
        type: type,
        amount: amount,
        categoryId: d.Value(categoryId),
        accountId: d.Value(accountId),
        toAccountId: d.Value(toAccountId),
        note: d.Value(note),
        frequency: frequency,
        interval: d.Value(interval),
        dayOfMonth: d.Value(dayOfMonth),
        dayOfWeek: d.Value(dayOfWeek),
        monthOfYear: d.Value(monthOfYear),
        startDate: startDate,
        endDate: d.Value(endDate),
        enabled: d.Value(enabled),
        syncId: d.Value(syncId ?? _uuid.v4()),
        currencyCode: d.Value(_normalizeCurrency(currencyCode)),
      ),
    );
  }

  /// 币种统一大写存储(与 transactions.currency_code 一致);空串按 null。
  /// (v42,移植 BeeCount #444)
  static String? _normalizeCurrency(String? code) {
    if (code == null) return null;
    final trimmed = code.trim();
    return trimmed.isEmpty ? null : trimmed.toUpperCase();
  }

  @override
  Future<void> updateRecurringTransaction({
    required int id,
    required int ledgerId,
    required String type,
    required double amount,
    int? categoryId,
    int? accountId,
    int? toAccountId,
    String? note,
    required String frequency,
    required int interval,
    int? dayOfMonth,
    int? dayOfWeek,
    int? monthOfYear,
    required DateTime startDate,
    DateTime? endDate,
    bool? enabled,
    DateTime? lastGeneratedDate,
    String? syncId,
    String? currencyCode,
  }) async {
    await (db.update(db.recurringTransactions)..where((t) => t.id.equals(id)))
        .write(
      RecurringTransactionsCompanion(
        ledgerId: d.Value(ledgerId),
        type: d.Value(type),
        amount: d.Value(amount),
        categoryId: d.Value(categoryId),
        accountId: d.Value(accountId),
        toAccountId: d.Value(toAccountId),
        note: d.Value(note),
        frequency: d.Value(frequency),
        interval: d.Value(interval),
        dayOfMonth: d.Value(dayOfMonth),
        dayOfWeek: d.Value(dayOfWeek),
        monthOfYear: d.Value(monthOfYear),
        startDate: d.Value(startDate),
        endDate: d.Value(endDate),
        enabled: enabled != null ? d.Value(enabled) : const d.Value.absent(),
        lastGeneratedDate: d.Value(lastGeneratedDate),
        // 仅显式传入时回填（name 命中业务键的导入匹配后补身份锚点）；
        // null → absent，避免把已有 syncId 清掉。
        syncId: syncId != null ? d.Value(syncId) : const d.Value.absent(),
        // null 即写 NULL(改回本位币要能清掉旧外币),与本方法其它字段同语义
        currencyCode: d.Value(_normalizeCurrency(currencyCode)),
        updatedAt: d.Value(DateTime.now()),
      ),
    );
  }

  @override
  Future<void> deleteRecurringTransaction(int id) async {
    await (db.delete(db.recurringTransactions)..where((t) => t.id.equals(id)))
        .go();
  }

  @override
  Future<void> toggleRecurringTransaction(int id, bool enabled) async {
    await (db.update(db.recurringTransactions)..where((t) => t.id.equals(id)))
        .write(RecurringTransactionsCompanion(
      enabled: d.Value(enabled),
      updatedAt: d.Value(DateTime.now()),
    ));
  }

  @override
  Future<void> updateLastGeneratedDate(int id, DateTime date) async {
    await (db.update(db.recurringTransactions)..where((t) => t.id.equals(id)))
        .write(RecurringTransactionsCompanion(
      lastGeneratedDate: d.Value(date),
      updatedAt: d.Value(DateTime.now()),
    ));
  }

  @override
  Future<int> getActiveRecurringCountByAccount(int accountId) async {
    final rows = await (db.select(db.recurringTransactions)
          ..where((t) =>
              t.enabled.equals(true) &
              (t.accountId.equals(accountId) | t.toAccountId.equals(accountId))))
        .get();
    return rows.length;
  }

  @override
  Stream<List<RecurringTransaction>> watchAllRecurringTransactions() {
    return (db.select(db.recurringTransactions)).watch();
  }

  @override
  Stream<List<RecurringTransaction>> watchRecurringTransactionsByLedger(int ledgerId) {
    return (db.select(db.recurringTransactions)
          ..where((t) => t.ledgerId.equals(ledgerId)))
        .watch();
  }

  @override
  Future<void> batchInsertRecurringTransactions(
      List<RecurringTransactionsCompanion> items) async {
    await db.batch((batch) {
      batch.insertAll(db.recurringTransactions, items);
    });
  }
}
