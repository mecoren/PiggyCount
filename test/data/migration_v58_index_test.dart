/// v58（性能 P4）查询索引守门：
/// 1. onCreate 新装库建齐（见 `transaction_search_query_test.dart`）；
/// 2. onUpgrade 存量库（v57）补齐 —— 本文件重点；
/// 3. 关键查询真的命中索引而不是全表扫描（EXPLAIN 断言，环境无关）。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';

const _v58Indexes = <String>[
  'idx_transactions_ledger_type_happened',
  'idx_transactions_account',
  'idx_transactions_to_account',
  'idx_transactions_ledger_category',
  'idx_budgets_ledger_type_enabled_category',
  'idx_deleted_transactions_ledger_deleted',
];

Future<Set<String>> _indexNames(PiggyDatabase db) async {
  final rows = await db
      .customSelect("SELECT name FROM sqlite_master WHERE type='index' "
          "AND sql IS NOT NULL")
      .get();
  return rows.map((r) => r.read<String>('name')).toSet();
}

Future<String> _planOf(PiggyDatabase db, String sql) async {
  final rows = await db.customSelect('EXPLAIN QUERY PLAN $sql').get();
  return rows.map((r) => r.read<String>('detail')).join('\n');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  test('v58 onUpgrade：存量库（v57 且索引缺失）升级后补齐', () async {
    final dir = await Directory.systemTemp.createTemp('pgy_v58_test');
    final file = File('${dir.path}/test.db');

    // 1. 建全量 schema 后模拟存量库：删掉新索引，user_version 压回 57。
    final seed = PiggyDatabase.forTesting(NativeDatabase(file));
    await seed.customSelect('SELECT 1').get();
    for (final idx in _v58Indexes) {
      await seed.customStatement('DROP INDEX IF EXISTS $idx');
    }
    final afterDrop = await _indexNames(seed);
    for (final idx in _v58Indexes) {
      expect(afterDrop, isNot(contains(idx)), reason: '前置条件：$idx 应已删除');
    }
    await seed.customStatement('PRAGMA user_version = 57;');
    await seed.close();

    // 2. 重新打开 → onUpgrade(from=57, to=58) 跑 v58 分支。
    final db = PiggyDatabase.forTesting(NativeDatabase(file));
    await db.customSelect('SELECT 1').get();
    addTearDown(() => db.close());

    expect(db.schemaVersion, greaterThanOrEqualTo(58));
    final names = await _indexNames(db);
    for (final idx in _v58Indexes) {
      expect(names, contains(idx), reason: '存量库升级必须补建 $idx');
    }
  });

  test('v58 索引生效：统计 / 账户 / 预算查询走索引', () async {
    final db = PiggyDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    addTearDown(() => db.close());

    // 造足够行数，让 planner 有成本模型可依据。
    await db.batch((b) {
      for (var i = 0; i < 400; i++) {
        b.insert(
          db.transactions,
          TransactionsCompanion.insert(
            ledgerId: i % 3 + 1,
            type: i.isEven ? 'expense' : 'income',
            amount: 10.0 + i,
            accountId: Value(i % 7 + 1),
            categoryId: Value(i % 11 + 1),
            happenedAt: Value(DateTime(2026, 1, 1).add(Duration(hours: i))),
          ),
        );
        b.insert(
          db.budgets,
          BudgetsCompanion.insert(
            ledgerId: i % 3 + 1,
            type: const Value('category'),
            categoryId: Value(i % 11 + 1),
            amount: 100.0,
          ),
        );
      }
    });

    final statsPlan = await _planOf(
      db,
      "SELECT SUM(amount) FROM transactions "
      "WHERE ledger_id = 1 AND type = 'expense' "
      "AND happened_at >= 0 AND happened_at < 9999999999999",
    );
    expect(statsPlan, contains('idx_transactions_ledger_type_happened'),
        reason: '统计/预算的共同谓词应命中复合索引。实际计划:\n$statsPlan');

    final accountPlan = await _planOf(
      db,
      'SELECT * FROM transactions WHERE account_id = 3',
    );
    expect(accountPlan, contains('idx_transactions_account'),
        reason: '账户余额查询必须命中 account_id 索引。实际计划:\n$accountPlan');

    final budgetPlan = await _planOf(
      db,
      "SELECT * FROM budgets WHERE ledger_id = 1 AND type = 'category' "
      'AND enabled = 1',
    );
    expect(budgetPlan, contains('idx_budgets_ledger_type_enabled_category'),
        reason: '预算列表查询应命中复合索引。实际计划:\n$budgetPlan');
  });
}
