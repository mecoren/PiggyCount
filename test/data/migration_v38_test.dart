/// v38 迁移:各实体 sync_id 唯一索引（审计 TBL-M1）。
///
/// 此前 8 张表的 sync_id 只有普通索引，代码层（sync_engine_resolvers /
/// getTransactionBySyncId 等）按唯一假设用 getSingleOrNull()，出现重复行
/// 即抛 "Too many elements" 使 pull 整页回滚。v38 为 8 张表补 UNIQUE 索引，
/// 迁移时对存量重复行做「改写而非删除」的消重（保留组内最小 rowid，
/// 其余回填随机 sync_id），不破坏外键引用、不丢业务数据。
///
/// - 新装库（onCreate）同样创建全部唯一索引
/// - 插入重复 sync_id 必须被 SQLite 拒绝
/// - NULL sync_id 不受唯一约束（legacy 未回填行可共存）
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

  test('schemaVersion 已达 38 及以上', () {
    expect(db.schemaVersion, greaterThanOrEqualTo(38),
        reason: 'db.dart schemaVersion 不应低于 38');
  });

  test('v38: 全部 8 个唯一索引已创建（onCreate 路径）', () async {
    const expectedIndexes = [
      'uq_ledgers_sync_id',
      'uq_accounts_sync_id',
      'uq_categories_sync_id',
      'uq_transactions_sync_id',
      'uq_tags_sync_id',
      'uq_budgets_sync_id',
      'uq_recurring_sync_id',
      'uq_exchange_rate_overrides_sync_id',
    ];
    for (final idx in expectedIndexes) {
      final rows = await db.customSelect(
        "SELECT name FROM sqlite_master WHERE type='index' AND name='$idx'",
      ).get();
      expect(rows, isNotEmpty, reason: '缺少唯一索引 $idx');
    }
  });

  test('v38: 插入重复 sync_id 被拒绝（以 categories 为例）', () async {
    await db.customStatement(
      "INSERT INTO categories (name, kind, sort_order, sync_id) "
      "VALUES ('餐饮', 'expense', 0, 'dup-abc')",
    );
    expect(
      () => db.customStatement(
        "INSERT INTO categories (name, kind, sort_order, sync_id) "
        "VALUES ('交通', 'expense', 1, 'dup-abc')",
      ),
      throwsA(anything),
      reason: 'UNIQUE 约束应拒绝重复 sync_id',
    );
  });

  test('v38: 多行 NULL sync_id 允许共存（legacy 未回填行不受影响）', () async {
    await db.customStatement(
      "INSERT INTO tags (name, sort_order) VALUES ('A', 0)",
    );
    await db.customStatement(
      "INSERT INTO tags (name, sort_order) VALUES ('B', 1)",
    );
    final rows = await db
        .customSelect("SELECT COUNT(*) AS c FROM tags")
        .getSingle();
    expect(rows.data['c'], 2);
  });

  test('v38: ledgers / transactions 同样拒绝重复 sync_id', () async {
    await db.customStatement(
      "INSERT INTO ledgers (name, currency, created_at, sync_id) "
      "VALUES ('默认', 'CNY', 0, 'ledger-dup')",
    );
    await db.customStatement(
      "INSERT INTO transactions (ledger_id, type, amount, happened_at, "
      "category_id, account_id, note, sync_id) "
      "VALUES (1, 'expense', 1.0, 0, NULL, NULL, '', 'tx-dup')",
    );
    // 同账本内重复
    await expectLater(
      db.customStatement(
        "INSERT INTO ledgers (name, currency, created_at, sync_id) "
        "VALUES ('副本', 'CNY', 0, 'ledger-dup')",
      ),
      throwsA(anything),
    );
    await expectLater(
      db.customStatement(
        "INSERT INTO transactions (ledger_id, type, amount, happened_at, "
        "category_id, account_id, note, sync_id) "
        "VALUES (1, 'expense', 2.0, 0, NULL, NULL, '', 'tx-dup')",
      ),
      throwsA(anything),
    );
  });
}
