/// v33 迁移(sync_gap_closure G2):recurring_transactions 加 sync_id。
///
/// - 列存在(fresh schema 由 Table 定义建列;升级库由 _addColumnIfMissing 补列)
/// - idx_recurring_sync_id 索引存在(onCreate 与 onUpgrade 都会创建)
/// - schemaVersion ≥ 33
///
/// 升级路径的 sync_id 回填(存量行 randomblob(16))无法用 create-all 内存库
/// 直接验证 —— onUpgrade 不会跑;回填语义由 data_import 侧 lastGeneratedDate
/// 取 max 合并兜底,此处只做结构回归。
library;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/data/db.dart';

void main() {
  late PiggyDatabase db;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async => db.close());

  test('v33: recurring_transactions.sync_id 列存在且可写', () async {
    final cols = await db.customSelect(
      "SELECT name FROM pragma_table_info('recurring_transactions') "
      "WHERE name='sync_id'",
    ).get();
    expect(cols, isNotEmpty, reason: 'v33 迁移应给 recurring_transactions 加 sync_id 列');

    await db.customStatement(
      "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    await db.customStatement(
      "INSERT INTO recurring_transactions (ledger_id, type, amount, frequency, "
      "interval, start_date, sync_id) VALUES "
      "(1, 'expense', 10.0, 'monthly', 1, '2026-01-01T00:00:00Z', 'abc123')");
    final rows = await db.customSelect(
      "SELECT sync_id FROM recurring_transactions WHERE ledger_id = 1").get();
    expect(rows.single.read<String>('sync_id'), 'abc123');
  });

  test('v33: idx_recurring_sync_id 索引存在(fresh onCreate)', () async {
    final rows = await db.customSelect(
      "SELECT name FROM sqlite_master WHERE type='index' "
      "AND name='idx_recurring_sync_id'",
    ).get();
    expect(rows, isNotEmpty,
        reason: 'onCreate 也必须建 idx_recurring_sync_id,否则新装 app 永远没有该索引');
  });

  test('schemaVersion 已达 33 及以上', () async {
    expect(db.schemaVersion, greaterThanOrEqualTo(33),
        reason: 'db.dart schemaVersion 不应低于 33');
  });
}
