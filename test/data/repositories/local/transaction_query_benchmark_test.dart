// B 组基准测试:用 10,000 条交易验证月度查询命中复合索引。
//
// 用 EXPLAIN QUERY PLAN 断言索引命中(环境无关),同时打印耗时作为基线供后续
// keyset 分页决策参考(不断言绝对耗时,避免 CI 波动误报)。
import 'package:drift/drift.dart' show Value, Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PiggyDatabase db;
  late LocalRepository repo;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
  });

  tearDown(() async => db.close());

  test('10000 条交易:月度查询 EXPLAIN 命中 idx_transactions_ledger_happened',
      () async {
    final ledgerId = await db.into(db.ledgers).insert(
          LedgersCompanion.insert(name: 'L'),
        );
    // 批量插入 10000 条,分布在 2026 全年
    await db.batch((b) {
      for (var i = 0; i < 10000; i++) {
        b.insert(
          db.transactions,
          TransactionsCompanion.insert(
            ledgerId: ledgerId,
            type: 'expense',
            amount: 1.0 * i,
            // 分散到 365 天,7 月集中 1000 条模拟真实月度查询
            happenedAt: Value(DateTime(2026, (i % 12) + 1, (i % 28) + 1, 10)),
          ),
        );
      }
    });

    // EXPLAIN QUERY PLAN:月度查询应走复合索引
    final plan = await db
        .customSelect(
          'EXPLAIN QUERY PLAN SELECT * FROM transactions '
          'WHERE ledger_id = ? AND happened_at >= ? AND happened_at < ? '
          'ORDER BY happened_at DESC',
          variables: [
            Variable<int>(ledgerId),
            Variable<DateTime>(DateTime(2026, 7, 1)),
            Variable<DateTime>(DateTime(2026, 8, 1)),
          ],
        )
        .get();
    final planText = plan.map((r) => r.data['detail'] as String).join('\n');

    expect(
      planText,
      contains('idx_transactions_ledger_happened'),
      reason: '月度查询应命中复合索引。实际计划:\n$planText',
    );

    // 实测耗时(基线参考,不断言)
    final sw = Stopwatch()..start();
    await repo.getTransactionsByLedgerInRange(
      ledgerId: ledgerId,
      start: DateTime(2026, 7, 1),
      end: DateTime(2026, 8, 1),
    );
    sw.stop();
    // ignore: avoid_print
    print('10000 条数据月度查询耗时: ${sw.elapsedMilliseconds}ms (基线参考)');
  });
}
