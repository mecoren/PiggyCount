/// v45 迁移（账本明细原始金额 `transactions.original_amount`）语义：
///
/// - 加列后**回填** `original_amount = amount` —— 产品口径是「每条明细都有
///   原始金额」，未填写即等于记账金额（差异 0）；
/// - 写入路径同样兜底（`LocalRepository.addTransaction` / `updateTransaction` /
///   快照导入），读取侧的 COALESCE 只作旧快照、手工插库的防御。
///
/// in-memory db 由 create_all 建出 v45 全 schema（列已存在），这里用
/// 「插 NULL 行 + 执行 onUpgrade 里同一段回填 SQL」验证语义
/// （SQL 与 db.dart `if (from < 45)` 块保持一字不差，改一处必须同步另一处）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/models/transaction_original_amount.dart';

/// 与 db.dart `if (from < 45)` 块内的 DDL 一致。
const addOriginalAmountSql =
    'ALTER TABLE transactions ADD COLUMN original_amount REAL;';

/// 与 db.dart `if (from < 45)` 块内的回填 SQL 一致。
const backfillOriginalAmountSql =
    'UPDATE transactions SET original_amount = amount WHERE original_amount IS NULL;';

void main() {
  late PiggyDatabase db;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async => db.close());

  Future<void> seedLedger() => db.customStatement(
      "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");

  test('迁移 SQL 常量形态：加可空 REAL 列 + 只回填 NULL 行', () {
    expect(addOriginalAmountSql, contains('original_amount REAL'));
    // 不加 NOT NULL —— 回填前的存量行仍是 NULL，列必须允许。
    expect(addOriginalAmountSql.toUpperCase(), isNot(contains('NOT NULL')));
    // WHERE IS NULL 守卫：绝不覆盖用户已填的原始金额。
    expect(backfillOriginalAmountSql.toUpperCase(),
        contains('WHERE ORIGINAL_AMOUNT IS NULL'));
  });

  test('v45 schema：transactions 带可空 original_amount 列', () async {
    final cols =
        await db.customSelect('PRAGMA table_info(transactions)').get();
    final byName = {for (final r in cols) r.read<String>('name'): r};

    expect(byName.keys, contains('original_amount'));
    expect(byName['original_amount']!.read<int>('notnull'), 0);
  });

  test('存量行回填后 = 记账金额，差异 0', () async {
    await seedLedger();
    await db.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount) "
        "VALUES (100, 1, 'expense', 12.0)");
    // 模拟刚加完列、回填前的 v44 存量行。
    await db.customStatement(
        'UPDATE transactions SET original_amount = NULL WHERE id = 100');

    await db.customStatement(backfillOriginalAmountSql);

    final row = (await db.select(db.transactions).get()).single;
    expect(row.originalAmount, 12.0);
    expect(row.effectiveOriginalAmount, 12.0);
    expect(row.originalAmountDiff, 0.0);
  });

  test('回填不覆盖用户已填值（WHERE IS NULL 守卫）', () async {
    await seedLedger();
    await db.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, original_amount) "
        "VALUES (101, 1, 'expense', 12.0, 20.0)");

    await db.customStatement(backfillOriginalAmountSql);

    final row = (await db.select(db.transactions).get()).single;
    expect(row.originalAmount, 20.0);
    expect(row.originalAmountDiff, 8.0);
  });
}
